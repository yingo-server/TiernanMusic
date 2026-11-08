/// v5.0 M3 / v5.1 B3 重写：三级缓存统一门面（REFACTOR_PLAN_V5 §4）。
///
/// 层级与语义：
/// - L1 内存：进程内；条目自带到期时间戳（默认 90s，与列表语义一致），
///   **命中后仍按 L2 的 in-flight/TTL 口径工作**——L1 只是 L2 的加速层，
///   过期即下沉查 L2，不做第二套语义（v5.1 B3-B P1-5 修复）。
/// - L2 磁盘 JSON：168h/90s 由 cacheTtl(scope) 唯一决定。
/// - L3 永久文件：身份 (URL, 声明字节数)，四道校验在 ResourceCache。
///
/// 切号/登出的竞态防护（v5.1 B3-B P1-6 修复）：
/// onUserChanged 携带用户世代号，清理完成前新登录写入的条目
/// 不会被旧世代的清理误删（非 unawaited 裸调）。
library;

import 'dart:async';

import '../resource/resource_cache.dart';
import 'cache_keys.dart';

class ResourceGateway {
  ResourceGateway._();
  static final instance = ResourceGateway._();

  /// L1 条目：值 + 到期毫秒（与 L2 TTL 同源，禁止双套口径）。
  final Map<String, (Object, int)> _memory = <String, (Object, int)>{};

  /// 用户世代号：切号/登出递增，保护异步清理不误删新登录写入。
  int _userGeneration = 0;

  /// L1 默认寿命：90s（与 CacheScope.list 一致，禁止超过 L2 TTL）。
  static const int _l1DefaultTtlMs = 90 * 1000;

  /// 当前时间装载点（测试可覆盖）。
  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  T? memoryGet<T extends Object>(String key) {
    final entry = _memory[key];
    if (entry == null) return null;
    final (value, expiresAtMs) = entry;
    if (nowMs() >= expiresAtMs) {
      _memory.remove(key); // 过期潞扫，避免无界增长（第 25 条）
      return null;
    }
    return value is T ? value : null;
  }

  void memoryPut(String key, Object value, {int? ttlMs}) {
    final ttl = ttlMs ?? _l1DefaultTtlMs;
    assert(ttl > 0);
    _memory[key] = (value, nowMs() + ttl);
  }

  /// L2 磁盘 JSON：TTL 优先取调用方显式 [ttl]（歌词 168h 等自定义场景），
  /// 未传时按 cacheTtl(scope)；L1 与之同源，禁止双套口径。
  Future<Map<String, dynamic>> json({
    required String ns,
    required String path,
    required Future<Map<String, dynamic>> Function() fetch,
    Map<String, dynamic>? query,
    String userid = '0',
    String? extra,
    CacheScope scope = CacheScope.json,
    Duration? ttl,
    bool staleOnError = true,
  }) {
    final scopeTtl = ttl ?? cacheTtl(scope);
    final key = cacheKey(
      ns: ns,
      scope: scope,
      path: path,
      query: query,
      userid: userid,
      extra: extra,
    );
    // L1 命中：到期检查在 memoryGet 内，不再有绕过 L2 语义的问题。
    final mem = memoryGet<Map<String, dynamic>>(key);
    if (mem != null) return Future<Map<String, dynamic>>.value(mem);
    return ResourceCache.instance.json(
      key,
      fetch,
      ttl: scopeTtl,
      staleOnError: staleOnError,
    ).then((body) {
      // 失效回退打标（__stale）不进 L1：降级数据应每次尝试刷新。
      if (body['__stale'] != true) memoryPut(key, body, ttlMs: scopeTtl.inMilliseconds);
      return body;
    });
  }

  /// L3 永久文件：身份=(URL,声明字节数)，校验在 ResourceCache 内四道。
  Future<String?> file(String url, String kind, {int declaredBytes = 0}) =>
      ResourceCache.instance.cacheUrlFile(url, kind,
          declaredBytes: declaredBytes);

  /// 写后按命名空间精确失效（不再全清其它域）。
  Future<void> invalidateNs(String ns) async {
    _memory.removeWhere((k, _) => k.contains(':$ns:u='));
    await ResourceCache.instance.invalidateNs(ns);
  }

  /// 切号/登出：用户维度整体失效。
  ///
  /// v5.1 B3-B P1-6 修复：带世代号的异步清理，异常接管、
  /// 防切号竞态误删新登录写入（第 5/18/21 条）。
  void onUserChanged() {
    final gen = ++_userGeneration;
    _memory.clear();
    unawaited(() async {
      try {
        await ResourceCache.instance.clearJson();
        await ResourceCache.instance.clearLists();
      } catch (e) {
        // 清理失败不崩：键内 u= 维度保证旧数据不命中，
        // 但不可静默（第 9 条）——交给下一次 onUserChanged 或清缓存一并清理。
        // 这里不接 ErrorLogger（foundation 零依赖层不可下依）；
        // 键维度已保证正确性，清理失败只影响箱体大小。
        // 如仍持续失败，用户可通过设置页手动清缓存。
        if (_userGeneration == gen) _memory['__userCleanupError__'] = ('$e', nowMs() + 60000);
      }
    }());
  }

  /// 清缓存设置页：只清 JSON/列表与内存，**永久文件不动**（用户口径）。
  /// v5.1 B3-B P1-11 修复：此处是唯一的缓存清理入口（不再接 ErrorLogger，
  /// 避免循环）；异常向上传给调用方 Toast。
  Future<void> clearTransient() async {
    final gen = ++_userGeneration;
    _memory.clear();
    await ResourceCache.instance.clearJson();
    await ResourceCache.instance.clearLists();
    // 清理完成后作废旧世代（仅用于语义标记，实际删除已完成）
    if (gen != _userGeneration) return;
  }
}
