/// v5.0 M5 / v5.1 B3 修复：读路径统一门面（REFACTOR_PLAN_V5 §八 M5）。
///
/// 与 [CachedApiCall] 共用 [ResourceGateway.json]，键/TTL/ns/失效只有
/// 一个事实源（cache_keys.dart）。[get]/[post] 直接返回缓存层结果，
/// 命中即不发网络；写/登录链路保留裸调用（防重与异常契约不同）。
library;

import '../api/kugou_api_client.dart' show KugouApiClient;
import '../cache/cache_keys.dart';
import '../cache/resource_gateway.dart';
import '../resource/cached_api.dart' show CachedApiCall;

class RepositoryReads {
  const RepositoryReads(this._api, this.ns);

  final KugouApiClient _api;
  final String ns;

  String get _userid => _api.userid.isEmpty ? '0' : _api.userid;

  /// GET 读：[json] = true 走 168h，默认 90s 列表语义。
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    bool json = false,
    bool stale = true,
  }) {
    return ResourceGateway.instance.json(
      ns: ns,
      scope: json ? CacheScope.json : CacheScope.list,
      path: path,
      query: query,
      userid: _userid,
      fetch: () => _api.get(path, query: query),
      staleOnError: stale,
    );
  }

  /// POST 读：键含 body 身份（与 CachedApiCall 同一算法）。
  Future<Map<String, dynamic>> post(
    String path,
    Object body, {
    Map<String, dynamic>? query,
    bool json = false,
    bool stale = true,
  }) {
    return ResourceGateway.instance.json(
      ns: ns,
      scope: json ? CacheScope.json : CacheScope.list,
      path: path,
      query: query,
      userid: _userid,
      extra: CachedApiCall.bodyIdentity(body),
      fetch: () => _api.post(path, body, query: query),
      staleOnError: stale,
    );
  }

  Future<void> invalidate() => ResourceGateway.instance.invalidateNs(ns);
}
