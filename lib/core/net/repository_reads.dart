/// v5.0 M5：读路径缓存统一门面（REFACTOR_PLAN_V5 §八 M5）。
///
/// repository 的**只读**请求经本类走 ResourceGateway（三级缓存 + 键唯一
/// 事实源 + ns 失效）；写/登录链路保留裸调用（防重与异常契约不同）。
/// [get]/[post] 直接返回缓存层结果（命中即不发网络），禁止二次请求。
library;

import '../api/kugou_api_client.dart' show KugouApiClient;
import '../cache/cache_keys.dart';
import '../cache/resource_gateway.dart';

/// 便捷 TTL（值源自 cache_keys.cacheTtl，唯一事实源）。
final Duration readListTtl = cacheTtl(CacheScope.list);
final Duration readJsonTtl = cacheTtl(CacheScope.json);

class RepositoryReads {
  const RepositoryReads(this._api, this.ns);

  final KugouApiClient _api;
  final String ns;

  String get _userid => _api.userid.isEmpty ? '0' : _api.userid;

  /// GET 读：默认 90s 列表语义；[json] = true 走 168h（详情/歌词等稳定资源）。
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

  /// POST 读（酷狗部分列表接口是 POST 语义）：键含 body 摘要避免串数据。
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
      extra: body is String ? body : body.toString(),
      fetch: () => _api.post(path, body, query: query),
      staleOnError: stale,
    );
  }

  Future<void> invalidate() => ResourceGateway.instance.invalidateNs(ns);
}
