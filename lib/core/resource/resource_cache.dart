import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../features/download/data/storage_permission_service.dart';

/// TTL 常量（v4.0 冻结契约，TASK_v400_arch.md）。
const kJsonTtl = Duration(hours: 168); // 一切 API 返回的 JSON
const kListTtl = Duration(seconds: 90); // 本次启动的首页/歌单列表
const kFilePermanent = null; // 实际资源文件永久（占位常量，按契约保留）

/// 统一缓存（v4.0-B，V400-B-01）。
///
/// 职责（TASK_v400_b.md B1/B4）：
/// - JSON 持久缓存（Hive 箱 `resource_json`，main.dart openSafe 由 C 负责开箱；
///   [init] 幂等，箱未开时自行打开——单个 openBox 失败只留痕不崩）
/// - in-flight 合并：同 key 并发只发一个 fetch（歌词重复请求根治，第 18/22 条）
/// - 失效回退：fetch 失败时若箱里有旧值（哪怕过期）返回旧值并留 debugPrint
///  （第 9/11/16 条），旧值副本带 `__stale: true` 标记供调用方感知
/// - 实际资源文件永久缓存：`<resolveRoot()>/cache/resource/<kind>/<hash><ext>`
///   （第 25 条：文件缓存根实测可写；永久不淘汰，淘汰交由设置页 clear*）
///
/// 缓存键维度（第 23 条）：JSON 键由调用方（CachedApiCall）拼入 userid；
/// 文件键由 URL 全文哈希 + kind 构成，音质/类型维度在 kind 中体现。
class ResourceCache {
  ResourceCache._();
  static final instance = ResourceCache._();

  static const _boxName = 'resource_json';
  static const _jsonPrefix = 'json:';
  static const _listPrefix = 'list:';
  /// 内存中同 key 的 in-flight 请求（第 22 条：Dart 单 isolate，Map 即互斥点）
  final _inFlight = <String, Future<Map<String, dynamic>>>{};

  Box<String>? _box;

  /// 幂等初始化：main.dart 已开箱则直接引用，否则补开（单失败留痕不抛）。
  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    try {
      _box = Hive.isBoxOpen(_boxName)
          ? Hive.box<String>(_boxName)
          : await Hive.openBox<String>(_boxName);
    } catch (e) {
      debugPrint('[resource] openBox($_boxName) failed: $e');
      _box = null;
    }
  }

  Box<String>? get _safeBox => (_box != null && _box!.isOpen) ? _box : null;

  /// JSON 缓存（冻结契约签名）。
  ///
  /// - 命中未过期 → 直接返回，不发网络；
  /// - 未命中/过期 → 调 [fetch]（同 key 并发合并为一个 in-flight）；
  /// - fetch 失败 → 有旧值（哪怕过期）返回旧值副本（带 `__stale: true`）
  ///   并留痕；无旧值 → 原样 rethrow（禁止静默吞异常，B4/第 6 条）。
  Future<Map<String, dynamic>> json(
    String key,
    Future<Map<String, dynamic>> Function() fetch, {
    Duration ttl = kJsonTtl,
    bool staleOnError = true,
  }) async {
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final isList = ttl == kListTtl;
    final fullKey = '${isList ? _listPrefix : _jsonPrefix}$key';
    await init();
    final box = _safeBox;
    final stored = _readStored(box, fullKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = stored != null &&
        now < stored.$1 + ttl.inMilliseconds;

    if (fresh) return stored.$2;

    final fut = _doFetch(fullKey, fetch, box,
        staleOnError: staleOnError, staleBody: stored?.$2);
    _inFlight[key] = fut;
    try {
      return await fut;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<Map<String, dynamic>> _doFetch(
    String fullKey,
    Future<Map<String, dynamic>> Function() fetch,
    Box<String>? box, {
    required bool staleOnError,
    required Map<String, dynamic>? staleBody,
  }) async {
    try {
      final data = await fetch();
      // 拿到新值后写入（写失败只留痕，不掩盖成功结果——缓存是加速器）
      if (box != null) {
        try {
          await box.put(
            fullKey,
            jsonEncode({
              'storedAt': DateTime.now().millisecondsSinceEpoch,
              'body': data,
            }),
          );
        } catch (e) {
          debugPrint('[resource] put($fullKey) failed: $e');
        }
      }
      return data;
    } catch (e) {
      // 失效回退（第 11 条）：触发条件=fetch 失败且存在旧值；
      // 次优行为=返回旧值副本并标 `__stale`；恢复条件=下次 fetch 成功覆盖。
      if (staleOnError && staleBody != null) {
        debugPrint('[resource] fetch($fullKey) failed, stale fallback: $e');
        // 副本打标（第 16 条：降级必须可感知），不污染箱内原始值
        return Map<String, dynamic>.from(staleBody)..['__stale'] = true;
      }
      rethrow;
    }
  }

  /// 读箱并验证形态（第 13/14 条：损坏缓存等同未命中，删除防反复）。
  (int, Map<String, dynamic>)? _readStored(Box<String>? box, String key) {
    if (box == null) return null;
    final raw = box.get(key);
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      box.delete(key);
      return null;
    }
    if (decoded is! Map) return null;
    final storedAt = decoded['storedAt'];
    final body = decoded['body'];
    if (storedAt is! int || body is! Map) return null;
    return (storedAt, Map<String, dynamic>.from(body));
  }

  // ---------- 实际资源文件永久缓存 ----------

  /// 文件缓存根：`<resolveRoot()>/cache/resource/<kind>/`。
  /// resolveRoot 每次实测可写性（V399-B2 口径），此处不缓存路径。
  Future<Directory> _dirOf(String kind) async {
    final root = await StoragePermissionService.instance.resolveRoot();
    final dir = Directory('$root/cache/resource/$kind');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 确定性文件名：FNV-1a（32 位步进避免 JS/大整数问题）+ 长度 + 扩展名。
  /// 同一 URL 永远映射同一文件名（第 3 条：幂等）。
  static String _hashName(String url) {
    var h = 0x811c9dc5;
    for (final c in url.codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0xFFFFFFFF;
      h ^= (c >> 8) & 0xff;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    final ext = url.contains('?')
        ? url.substring(url.indexOf('?'))
        : '';
    final dot = ext.lastIndexOf('.');
    final suffix =
        (dot >= 0 && dot < ext.length - 1 && ext.length <= 8)
            ? ext.substring(dot)
            : '';
    return '${h.toRadixString(16)}_${url.length}$suffix';
  }

  /// 写入字节永久缓存（契约签名）。写失败留痕不抛（缓存可重建）。
  Future<void> putFile(String key, List<int> bytes) async {
    try {
      final dir = await _dirOf('raw');
      final f = File('${dir.path}/${_hashName(key)}');
      await f.writeAsBytes(bytes, flush: true);
    } catch (e) {
      debugPrint('[resource] putFile($key) failed: $e');
    }
  }

  /// 读字节永久缓存（契约签名，永久不淘汰）。
  Future<List<int>?> file(String key) async {
    try {
      final dir = await _dirOf('raw');
      final f = File('${dir.path}/${_hashName(key)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (e) {
      debugPrint('[resource] file($key) failed: $e');
      return null;
    }
  }

  /// 内部缓存目录绝对路径（契约签名）。文件不存在返回 null。
  Future<String?> filePath(String key) async {
    try {
      final dir = await _dirOf('raw');
      final f = File('${dir.path}/${_hashName(key)}');
      return await f.exists() ? f.path : null;
    } catch (e) {
      debugPrint('[resource] filePath($key) failed: $e');
      return null;
    }
  }

  /// 从 URL 下载并永久缓存（契约签名）。
  ///
  /// 供 C 在 audio_handler「完整播放完成」分支调用（v4.0 契约模块二）。
  /// 已存在直接返回路径（幂等，第 21 条）；下载到 `.part` 临时文件后
  /// 原子 rename，避免半截文件被当作完整缓存（第 14 条边界校验）。
  /// 失败返回 null 并留痕（失效回退由调用方继续走网络流）。
  Future<String?> cacheUrlFile(String url, String kind) async {
    if (url.isEmpty) return null;
    try {
      final dir = await _dirOf(kind);
      final name = _hashName(url);
      final target = File('${dir.path}/$name');
      if (await target.exists()) return target.path;

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        // 大文件流式下载，给足接收时间（第 15 条：单位显式，秒）
        receiveTimeout: const Duration(minutes: 10),
      ));
      final part = File('${target.path}.part');
      await dio.download(url, part.path);
      await part.rename(target.path);
      debugPrint('[resource] cached url file: ${target.path}');
      return target.path;
    } catch (e) {
      debugPrint('[resource] cacheUrlFile($kind) failed: $e');
      // 清理半截临时文件（第 20 条：资源对称清理）
      try {
        final part = File(
            '${(await _dirOf(kind)).path}/${_hashName(url)}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 清全部 JSON 缓存（设置页清缓存入口，C 接入）。
  Future<void> clearJson() async {
    await init();
    final box = _safeBox;
    if (box == null) return;
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(_jsonPrefix))
        .toList();
    await box.deleteAll(keys);
  }

  /// 仅清 90 秒列表缓存（设置页入口；写操作后也可调用）。
  Future<void> clearLists() async {
    await init();
    final box = _safeBox;
    if (box == null) return;
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(_listPrefix))
        .toList();
    await box.deleteAll(keys);
  }
}
