/// v5.0 M3：缓存键唯一事实源（REFACTOR_PLAN_V5 §4.1）。
///
/// 全仓**禁止**再自行拼 TTL 前缀或用户维度字符串；所有缓存读写
/// 必须经此文件生成键。维度（第 23 条）：
/// - ns：命名空间（home/playlist/lyric/translate/player/mv/...），写后失效按 ns 精确批量删除
/// - u：用户身份（登录态变化后旧账号数据不再命中）
/// - path + 排序后的 query：请求身份
/// - v：schemaVer（上游响应结构变更时整体失效，不解析半个新半旧）
/// - scope：json / list / file，决定层级与 TTL
library;

const int kCacheSchemaVer = 1;

enum CacheScope { json, list, file }

Duration cacheTtl(CacheScope scope) => switch (scope) {
      CacheScope.json => const Duration(hours: 168),
      CacheScope.list => const Duration(seconds: 90),
      CacheScope.file => const Duration(days: 36500), // 永久（不淘汰，仅失效回退）
    };

/// 生成稳定键。query 按 key 字典序排列，值统一字符串化；null 视为空串。
String cacheKey({
  required String ns,
  required CacheScope scope,
  required String path,
  Map<String, dynamic>? query,
  String userid = '0',
  String? extra,
  int schemaVer = kCacheSchemaVer,
}) {
  final q = <String, String>{};
  query?.forEach((k, v) {
    if (v == null) return;
    q[k] = v is Iterable ? v.join(',') : '$v';
  });
  final sorted = q.keys.toList()..sort();
  final qs = sorted.map((k) => '$k=${q[k]}').join('&');
  final p = path.startsWith('/') ? path : '/$path';
  final tail = extra == null || extra.isEmpty ? '' : ':$extra';
  return '${scope.name}:$ns:u=$userid:$p:$qs:v$schemaVer$tail';
}

/// 命名空间前缀，用于写后按 ns 精确失效（删前缀猜谜的替代）。
String cacheNsPrefix(String ns) => ':$ns:u=';

/// 文件缓存身份 = (URL, 声明字节数)。bytes<=0 视为身份不可判定。
String fileIdentity(String url, int declaredBytes) => '$url|$declaredBytes';
