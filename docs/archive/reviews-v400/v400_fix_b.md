# v4.0 代理 B 修复报告（实时落盘）

基线 afbe6a6。范围：独占 `lib/core/resource/` 三新文件 + 6 repository 接入 + translate_api 翻译增量。

## V400-B-01 resource_cache.dart（新建）

- 契约全量签名实现：`json/putFile/file/filePath/cacheUrlFile/clearJson/clearLists` + `init()` 幂等；TTL 常量 `kJsonTtl=168h` / `kListTtl=90s` / `kFilePermanent`。
- Hive 箱 `resource_json`（String 值，main.dart openSafe 由 C 负责开箱；init 幂等补开，失败留痕不崩）。
- in-flight 合并：同 key 并发合并为单个 Future（歌词重复请求根治）。
- 失效回退：fetch 失败且有旧值（哪怕过期）→ 返回旧值副本（带 `__stale: true` 标记）+ debugPrint 留痕；无旧值 rethrow（B4：禁止静默吞异常）。
- 文件缓存：`StoragePermissionService.instance.resolveRoot()/cache/resource/<kind>/`（每次实测可写，不缓存路径）；`cacheUrlFile` Dio 流式下载 → `.part` → 原子 rename，已存在直接返回路径（幂等），失败清残留返回 null。
- key 维度：JSON 键含 userid（CachedApiCall 拼）；文件键 = URL FNV-1a 哈希 + kind（音质/类型维度在 kind）。

## V400-B-02 cached_api.dart（新建）

- `CachedApiCall(api)`：`get(path,{query,ttl,stale})` / `post(path,data,{query,ttl,stale})` 统一走 `ResourceCache.json`；键 = path + 排序 query + `|u=<userid>`（第 23 条）。
- ttl 传 `kListTtl` 即 90 秒列表；`stale:false` 关闭失效回退。
- 写操作禁止走本类（防重/异常语义在 PlaylistRepository._write）。

## V400-B-03 lyric_translation_stream.dart（新建）+ 翻译增量

- `LyricTranslationStream.instance.patches`（broadcast）/ `emit(patch)` / `dispose` 对称；`LyricTranslationPatch(lyricId, startIndex, values)`。
- `lyric_repository.ensureTranslation`：每批 40 行译文完成**立即** emit patch（实时插行，不等整批）；批失败重试一次（504 场景），仍失败留痕不崩不入缓存；命中持久缓存也 emit（UI 秒显）。
- `original` 模式零 API：语义在 full_player_page（A 档 v399-A3 既有，未触碰）；repository 侧无改动需求。

## V400-B-04 六 repository 接入

| Repository | 状态 | 说明 |
|---|---|---|
| home_repository | ✅ | `_cachedGet` 改走 `ResourceCache.json`（kListTtl，列表语义）；`fetchDailyRecommend` 保持直连不缓存（登录态强相关） |
| lyric_repository | ✅ | `findCandidate`/`_fetchLyricByFormat` 改走 `ResourceCache.json`（30min TTL，替换 LyricPersistentCache+MemoryCache 双写）；`ensureTranslation` 接增量 emit |
| mv_repository | ✅ | `findBySong`/`fetchDetail` 改走 `ResourceCache.json`（kJsonTtl）；`_hashToVideoId` 内存缓存保留（会话级互转） |
| playlist_repository | ✅ | `fetchDetail`/`fetchTracks.fetch` 改走 `ResourceCache.json`（kListTtl）；写操作与 `_invalidatePlaylistCaches` 保留，失效改调 `ResourceCache.clearLists` |
| search_repository | ✅ | `_cachedGet` 改走 `ResourceCache.json`（kListTtl）；搜索历史 Hive 不动 |
| player_repository | ✅ | `fetchDetail`(/privilege/lite) 接 `ResourceCache.json`（kListTtl，含 userid 维度）；resolveUrl 链路属写语义/直连特殊档，不缓存（正确行为） |

## 迁移清单（其余 7 个 repository，不强改）

- `mv_collection_repository` / `comment_repository` / `artist_repository` / `rank_repository` / `album_repository` / `download_repository` / `auth_repository`：
  1. 构造处加 `final _cached = CachedApiCall(_api);`
  2. 读接口的 `MemoryCache.instance.get/set(key,…)` 对替换为 `_cached.get(path, query: …, ttl: kListTtl 或 kJsonTtl)`
  3. 写操作不动；登录态强相关接口保持直连 `_api.get`
  4. 清理后 `MemoryCache` import 可移除（若该文件已无其它使用）

## 供 C 调用的确切 API（预加载/播放完成缓存）

```dart
import 'core/resource/resource_cache.dart';
import 'core/resource/lyric_translation_stream.dart';

// ① 预加载 JSON（URL/歌词/封面元数据）：
await ResourceCache.instance.json(key, () async => {...});            // 168h
await ResourceCache.instance.json(key, fetch, ttl: kListTtl);         // 90s
// ② 播放完成后永久缓存实际文件（audio_handler 完成分支）：
final path = await ResourceCache.instance.cacheUrlFile(url, 'audio'); // kind: audio/mv/cover/lyric；失败返回 null
await ResourceCache.instance.putFile(key, bytes);                     // 字节直写
await ResourceCache.instance.filePath(key);                           // 查已缓存路径
// ③ 设置页清缓存：
await ResourceCache.instance.clearJson();
await ResourceCache.instance.clearLists();
// ④ 翻译增量订阅（lyric_view 可选接入，不接则行为同 v3.9.9）：
LyricTranslationStream.instance.patches.listen((p) { /* p.lyricId/p.startIndex/p.values */ });
```

注意：main.dart 需 C 侧在 openSafe 列表加 `await openSafe('resource_json', stringValues: true);`（init() 幂等，未加也不崩，仅首次自动补开）。

## analyze 逐文件结果（dart analyze /opt/dart/bin，2026-11-08）

说明：沙箱无 Flutter SDK / 未 pub get，三方符号（flutter/riverpod/hive/dio/debugPrint/Provider/Ref/Box）报错均为**预期噪音**；项目自有类零错误。预存警告（基线同样存在、非本次引入）已用 HEAD 版本文件对照验证。

| 文件 | 结果 |
|---|---|
| lib/core/resource/resource_cache.dart | 项目自有错误 0；全部 error 为 dio/flutter/hive 符号噪音 |
| lib/core/resource/cached_api.dart | No issues（相对路径 ../api 修正后） |
| lib/core/resource/lyric_translation_stream.dart | No issues |
| lib/features/home/data/home_repository.dart | 项目自有错误 0（flutter/riverpod/debugPrint 噪音） |
| lib/features/search/data/search_repository.dart | 项目自有错误 0（Hive/debugPrint 噪音；_api 未用为恒等字段已标注 ignore） |
| lib/features/mv/data/mv_repository.dart | 新增 0；仅基线既有 prefer_final_locals info（228 行，HEAD 同在） |
| lib/features/playlist/data/playlist_repository.dart | 新增 0；3 项警告均为基线既有（HEAD 297/329/98 行同位置验证一致） |
| lib/features/player/data/player_repository.dart | 新增 0；unnecessary_null_comparison 为基线既有（HEAD 314 行验证一致） |
| lib/features/lyric/data/lyric_repository.dart | 项目自有错误 0（foundation/debugPrint 噪音；_api 未用已标注 ignore） |
| lib/core/api/translate_api.dart | 未触碰（git diff 为空）；dead_code 警告为基线既有 |

## 未做项原因

- pubspec/Manifest/Kotlin/main.dart/prefetch/arb：契约禁改（main 开箱归 C）。
- 其余 7 repository：任务书要求只给迁移清单（见上）。
- dart analyze 为 Flutter 项目会报三方/Flutter 符号缺失噪音；以「项目自有类零错误」为准逐文件核对。
