/// v5.0 M3：三级缓存统一门面（REFACTOR_PLAN_V5 §4）。
///
/// 旧四套类（MemoryCache / LyricPersistentCache / LyricTranslationCache /
/// AppImageCache）不再是消费方直接依赖；所有缓存读写与失效经此门面，
/// 内部按 [CacheScope] 分派到 内存 / 磁盘 JSON / 永久文件三层。
library;

import '../resource/resource_cache.dart';
import 'cache_keys.dart';

class ResourceGateway {
  ResourceGateway._();
  static final instance = ResourceGateway._();

  /// L1 内存（进程内，压力/切号即清）。
  final Map<String, Object> _memory = <String, Object>{};

  T? memoryGet<T extends Object>(String key) {
    final v = _memory[key];
    return v is T ? v : null;
  }

  void memoryPut(String key, Object value) => _memory[key] = value;

  /// L2 磁盘 JSON：统一的 168h / 90s 语义 + in-flight 合并 + 失效回退。
  Future<Map<String, dynamic>> json({
    required String ns,
    required String path,
    required Future<Map<String, dynamic>> Function() fetch,
    Map<String, dynamic>? query,
    String userid = '0',
    String? extra,
    CacheScope scope = CacheScope.json,
    bool staleOnError = true,
  }) {
    final key = cacheKey(
      ns: ns,
      scope: scope,
      path: path,
      query: query,
      userid: userid,
      extra: extra,
    );
    return ResourceCache.instance.json(
      key,
      fetch,
      ttl: cacheTtl(scope),
      staleOnError: staleOnError,
    );
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

  /// 切号/登出：用户维度整体失效（缓存键含 u=，旧账号数据不再命中）。
  void onUserChanged() {
    _memory.clear();
  }

  /// 清缓存设置页：只清 JSON/列表与内存，**永久文件不动**。
  Future<void> clearTransient() async {
    _memory.clear();
    await ResourceCache.instance.clearJson();
    await ResourceCache.instance.clearLists();
  }
}
