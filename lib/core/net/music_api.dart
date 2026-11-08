/// v5.0 M4：Bridge-N 门面（REFACTOR_PLAN_V5 §5）。
///
/// 组合「传输 + 缓存聚合 + 响应策略」三件事，向 L4 提供**唯一**网络入口。
/// 目标：L4 data 层不再直接持有 KugouApiClient、不再自行判成功/失败、
/// 不再自行拼缓存键。渐进迁移期间旧调用方仍可用，但新代码一律经本门面。
library;

import '../api/kugou_api_client.dart' show KugouApiClient;
import '../domain/response_policy.dart';
import '../foundation/errors.dart';
import '../resource/cached_api.dart';

/// 命名空间 → 门面。由 [MusicApi.forNs] 缓存，避免每域新建。
class MusicApi {
  MusicApi._(this._client);

  final KugouApiClient _client;
  final Map<String, CachedApiCall> _domains = <String, CachedApiCall>{};

  static MusicApi? _instance;
  static MusicApi of(KugouApiClient client) =>
      _instance ??= MusicApi._(client);

  /// 传输客户端（仅供确实需要裸请求的写操作/登录链路；读一律走 [read]）。
  KugouApiClient get transport => _client;

  CachedApiCall _domain(String ns) =>
      _domains.putIfAbsent(ns, () => CachedApiCall(_client, ns: ns));

  /// 读（GET）：缓存键/TTL/in-flight/失效回退/命名空间全部由门面决定。
  Future<Map<String, dynamic>> read(
    String ns,
    String path, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) =>
      _domain(ns).get(path, query: query, ttl: ttl, stale: stale);

  /// 写（POST）：**不缓存**、防重由调用方闸门负责；失败统一抛 [ApiException]。
  Future<Map<String, dynamic>> write(
    String path,
    dynamic data, {
    Map<String, dynamic>? query,
  }) =>
      _client.post(path, data, query: query);

  /// 响应成功/异常判定唯一入口（L4 不得自行判 status/error_code）。
  ApiOutcome evaluate(Map<String, dynamic> body, {String? ssaCode}) =>
      evaluateResponse(body, ssaCode: ssaCode);

  /// 写后按命名空间失效（歌单/收藏等）。
  Future<void> invalidate(String ns) =>
      _invalidateNs == null
          ? Future<void>.value()
          : _invalidateNs!(ns);

  /// 由 app/di 注入 ResourceGateway.invalidateNs，避免 core/net 反向依赖 core/cache。
  static Future<void> Function(String ns)? _invalidateNs;
  static void attachInvalidator(Future<void> Function(String ns) fn) =>
      _invalidateNs = fn;
}
