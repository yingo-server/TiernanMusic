import '../api/kugou_api_client.dart' show KugouApiClient;
import '../cache/cache_keys.dart';
import '../cache/resource_gateway.dart';

/// v5.1 B3 三视角共识修复：**唯一读实现**。
///
/// 此前 CachedApiCall 与 RepositoryReads 各自拼键/TTL/ns/失效，预加载键
/// 永不命中、写后失效只清一侧。现在全部经 [ResourceGateway.json]，
/// 键由 cache_keys.cacheKey 生成，TTL 由 cacheTtl(scope) 决定，
/// 失效由 invalidateNs(ns) 精确删除（含内存层）。
///
/// 写操作禁止走本类（防重与异常契约另有语义）。
class CachedApiCall {
  CachedApiCall(this._api, {this.ns = 'common'});

  final KugouApiClient _api;
  final String ns;

  String get _userid => _api.userid.isEmpty ? '0' : _api.userid;

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) {
    // ttl 参数保留兼容旧调用方；scope 由 ttl 是否为 90s 判定，
    // 但**最终 TTL 仍取 cacheTtl(scope)**，不允许第二套数值口径。
    final scope = ttl == cacheTtl(CacheScope.list)
        ? CacheScope.list
        : CacheScope.json;
    return ResourceGateway.instance.json(
      ns: ns,
      scope: scope,
      path: path,
      query: query,
      userid: _userid,
      fetch: () => _api.get(path, query: query),
      staleOnError: stale,
    );
  }

  Future<Map<String, dynamic>> post(
    String path,
    dynamic data, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) {
    final scope = ttl == cacheTtl(CacheScope.list)
        ? CacheScope.list
        : CacheScope.json;
    return ResourceGateway.instance.json(
      ns: ns,
      scope: scope,
      path: path,
      query: query,
      userid: _userid,
      // POST 身份摘要：与 RepositoryReads 统一为 body 字符串（同一事实源）；
      // 请求体不含凭证，缓存键不写敏感原文。
      extra: data == null ? null : bodyIdentity(data),
      fetch: () => _api.post(path, data, query: query),
      staleOnError: stale,
    );
  }

  /// 写后失效（与 RepositoryReads.invalidate 完全同一路径）。
  Future<void> invalidate() => ResourceGateway.instance.invalidateNs(ns);

  /// 稳定请求体身份：Map 键排序、Iterable 保序、字符串带类型标记。
  /// 公开给 RepositoryReads 复用，保证 POST 读键完全一致（第 5 条）。
  static String bodyIdentity(Object v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '$k=${bodyIdentity(v[k] ?? '')}').join(',')}}';
    }
    if (v is Iterable) return '[${v.map((e) => bodyIdentity(e)).join(',')}]';
    if (v is String) return 's:$v';
    return '$v';
  }
}
