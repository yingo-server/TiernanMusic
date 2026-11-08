import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../storage/storage_permission.dart';
import '../utils/error_logger.dart';

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
    // v5.1 B3-A：in-flight 以 **fullKey**（含 scope 前缀）分键，
    // 避免同一业务键不同 TTL 的两个请求互相复用错误 TTL 的结果。
    final isList = ttl == kListTtl;
    final fullKey = '${isList ? _listPrefix : _jsonPrefix}$key';
    final pending = _inFlight[fullKey];
    if (pending != null) return pending;
    await init();
    final box = _safeBox;
    final stored = _readStored(box, fullKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = stored != null &&
        now < stored.$1 + ttl.inMilliseconds;

    if (fresh) return stored.$2;

    final fut = _doFetch(fullKey, fetch, box,
        staleOnError: staleOnError, staleBody: stored?.$2);
    _inFlight[fullKey] = fut;
    try {
      return await fut;
    } finally {
      _inFlight.remove(fullKey);
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
        // V402-R3（复核② P1-2）：`__stale` 此前无任何消费方=假降级。
        // 回退本身即带用户可见留痕：经 ErrorLogger 落盘（verbose 开关
        // 打开后日志里可见），并在返回值打标供调用方按需感知。
        // 不抛、不吞：网络失败时旧值可用是明确降级（第 9/11/16 条）。
        unawaited(ErrorLogger.instance.log(
          'stale cache used for $fullKey',
          StackTrace.current,
          source: 'resource_cache',
          context: 'fetch failed: $e',
        ));
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

  /// V402（用户口径）：确定性文件名 = FNV-1a(`url + '|' + bytes`) + 长度 + 扩展名。
  /// 永久文件缓存的身份是 **`(URL, JSON 声明字节数)` 二元组**——不同清晰度、
  /// 试听/全曲、CDN 截断即使复用同一 URL，只要声明字节数不同就是不同资源，
  /// 绝不互相覆盖/误复用（第 3/23 条）。bytes=0（未声明）由调用方禁止入库。
  static String _hashName(String url, {int bytes = 0}) {
    final identity = '$url|$bytes';
    var h = 0x811c9dc5;
    for (final c in identity.codeUnits) {
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
    return '${h.toRadixString(16)}_${url.length}_$bytes$suffix';
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

  /// 从 URL 下载并永久缓存（V402：`(url, declaredBytes)` 身份严格校验）。
  ///
  /// 规则（用户 2026-11-08 口径）：
  /// 1. 只有请求 JSON 返回的 URL **及其附带字节数完全相同**才允许写入/复用；
  /// 2. declaredBytes<=0（JSON 未声明）**拒绝入库**——身份不可判定（第 14 条）；
  /// 3. 下载完成后校验磁盘实际长度 == declaredBytes，不等则删 `.part` 不入库；
  /// 4. Content-Length 若与声明不符直接放弃（不下载大文件后发现不对）。
  /// 失败返回 null 并留痕（失效回退由调用方继续走网络流）。
  Future<String?> cacheUrlFile(
    String url,
    String kind, {
    int declaredBytes = 0,
  }) async {
    if (url.isEmpty) return null;
    if (declaredBytes <= 0) {
      debugPrint('[resource] cacheUrlFile($kind) rejected: no declared bytes');
      return null;
    }
    try {
      final dir = await _dirOf(kind);
      final name = _hashName(url, bytes: declaredBytes);
      final target = File('${dir.path}/$name');
      if (await target.exists()) {
        // 复用前也校验：同名文件可能因上次中断留下半截（第 14 条）
        if (await target.length() == declaredBytes) return target.path;
        await target.delete();
      }

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 10),
      ));
      final part = File('${target.path}.part');
      final head = await dio.head(url);
      final cl = int.tryParse(
          '${head.headers.value('content-length') ?? ''}') ??
          0;
      if (cl > 0 && cl != declaredBytes) {
        debugPrint('[resource] cacheUrlFile($kind) rejected: '
            'Content-Length=$cl != declared=$declaredBytes');
        return null;
      }
      await dio.download(url, part.path);
      final actual = await part.length();
      if (actual != declaredBytes) {
        debugPrint('[resource] cacheUrlFile($kind) rejected: '
            'downloaded=$actual != declared=$declaredBytes');
        await part.delete();
        return null;
      }
      await part.rename(target.path);
      debugPrint('[resource] cached url file: ${target.path}');
      return target.path;
    } catch (e) {
      debugPrint('[resource] cacheUrlFile($kind) failed: $e');
      try {
        final part = File(
            '${(await _dirOf(kind)).path}/${_hashName(url, bytes: declaredBytes)}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
      return null;
    }
  }

  /// v5.0 M3：按命名空间精确失效（替代「按 scope 全清」的粗放策略）。
  /// 键格式见 cache_keys.dart；shared 域（无 ns）由 clearJson 兜底。
  Future<void> invalidateNs(String ns) async {
    await init();
    final box = _safeBox;
    if (box == null) return;
    final needle = ':$ns:u=';
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.contains(needle))
        .toList();
    await box.deleteAll(keys);
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
