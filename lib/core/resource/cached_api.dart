import '../api/kugou_api_client.dart' show KugouApiClient;
import '../cache/cache_keys.dart';
import 'resource_cache.dart';

/// v5.0 M3：Bridge-N 前置——API 调用聚合入口。
///
/// 全部键由 [cacheKey] 生成（唯一事实源），含 ns/userid/排序 query/schemaVer；
/// POST 键补请求体摘要（此前 POST 只按 query 分键，不同 body 串数据）；
/// 写操作禁止走本类（防重与异常翻译另有语义）。
class CachedApiCall {
  CachedApiCall(this._api, {this.ns = 'common'});

  final KugouApiClient _api;

  /// 命名空间：写后失效按 ns 批量清理（第 23 条）。
  final String ns;

  String _keyOf(String path, Map<String, dynamic>? query,
      {Object? body, CacheScope? scope}) {
    return cacheKey(
      ns: ns,
      scope: scope ?? CacheScope.json,
      path: path,
      query: query,
      userid: _api.userid.isEmpty ? '0' : _api.userid,
      extra: body == null ? null : _bodyDigest(body),
    );
  }

  /// 请求体摘要：稳定 JSON 字符串（Map 键排序）取 FNV 短哈希，
  /// 避免把 token/正文直接写进缓存键（第 14 条：缓存键不含凭证）。
  String _bodyDigest(Object body) {
    final s = body is String ? body : _stableJson(body);
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  String _stableJson(Object v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '"$k":${_stableJson(v[k] ?? '')}').join(',')}}';
    }
    if (v is Iterable) return '[${v.map((e) => _stableJson(e)).join(',')}]';
    if (v is String) return '"$v"';
    return '$v';
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? ttl,
    bool stale = true,
  }) {
    final scope = ttl == kListTtl ? CacheScope.list : CacheScope.json;
    final key = _keyOf(path, query, scope: scope);
    return ResourceCache.instance.json(
      key,
      () => _api.get(path, query: query),
      ttl: ttl ?? kJsonTtl,
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
    final scope = ttl == kListTtl ? CacheScope.list : CacheScope.json;
    final key = _keyOf(path, query, body: data, scope: scope);
    return ResourceCache.instance.json(
      key,
      () => _api.post(path, data, query: query),
      ttl: ttl ?? kJsonTtl,
      staleOnError: stale,
    );
  }
}
