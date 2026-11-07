import '../api/kugou_api_client.dart' show KugouApiClient;
import 'resource_cache.dart';

/// API 调用聚合入口（v4.0-B，V400-B-02）。
///
/// 代替 repository 内散落的 `_api.get(...) + MemoryCache.instance`：
/// 一次调用同时获得「网络 + 持久缓存 + in-flight 合并 + 失效回退」。
/// 缓存键拼入 [KugouApiClient.userid]（第 23 条：登录态强相关接口
/// 跨账号不得串数据；匿名恒 '0'，与登录态维度合并覆盖）。
///
/// 写操作（收藏/加歌/删除等）**禁止**走本类——写不进缓存且需要
/// 防重与异常翻译语义（PlaylistRepository._write 已有），误用会掩盖失败。
class CachedApiCall {
  CachedApiCall(this._api);

  final KugouApiClient _api;

  /// 缓存键：path + 排序后的 query + userid 维度（第 23 条）。
  String _keyOf(String path, Map<String, dynamic>? query) {
    final buf = StringBuffer(path);
    if (query != null && query.isNotEmpty) {
      final sorted = query.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final e in sorted) {
        buf..write('&')..write(e.key)..write('=')..write(e.value);
      }
    }
    return '$buf|u=${_api.userid}';
  }

  /// GET 聚合（契约签名）。[ttl] 传 kListTtl 即 90 秒列表；
  /// 传 null 走 kJsonTtl（168h）。[stale] = false 时禁用失效回退
  ///（登录态强相关接口不建议缓存，调用方直接用 _api.get）。
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) {
    final key = _keyOf(path, query);
    return ResourceCache.instance.json(
      key,
      () => _api.get(path, query: query),
      ttl: ttl ?? kJsonTtl,
      staleOnError: stale,
    );
  }

  /// POST 聚合（契约签名）。POST 的 JSON 响应同样可缓存（如翻译/批量接口）。
  Future<Map<String, dynamic>> post(
    String path,
    dynamic data, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) {
    final key = _keyOf(path, query);
    return ResourceCache.instance.json(
      key,
      () => _api.post(path, data, query: query),
      ttl: ttl ?? kJsonTtl,
      staleOnError: stale,
    );
  }
}
