# v4.0 代理 B：统一缓存模块 + API 聚合（独占 core/resource 与 6 个 repository）

先完整读 `docs/TASK_v400_arch.md`（**冻结契约，签名不得改**）、`QUALITY_STANDARD.md`（33 条）。

## 角色与文件边界（严禁越界）
独占新建/修改：
- `lib/core/resource/resource_cache.dart`、`cached_api.dart`、`lyric_translation_stream.dart`
- `lib/features/home/data/home_repository.dart`、`lyric/data/lyric_repository.dart`、`mv/data/mv_repository.dart`、`playlist/data/playlist_repository.dart`、`search/data/search_repository.dart`、`player/data/player_repository.dart`、`lib/core/api/translate_api.dart`
不改：arb（A）、`lyric_view.dart`/两个播放页（A）、`core/prefetch/**`/main/home_page/library_page/player_provider/audio_handler/queue_sheet（C）、pubspec/Manifest/Kotlin。

## ⚠️ 共同纪律（见契约）
ARM64 无 Flutter：禁装 SDK/flutter/pub get/下载 tarball；**pubspec 一行不许动**；只允许 dart analyze；Flutter/三方符号报错噪音、**项目自有类真错误**；Icons.* 必须验证存在；业务文件完整 file_read 禁止 grep 筛源码；触碰文件收尾 analyze 逐文件贴报告——缺一即失败；跨文件双向核对；禁 git commit/push；只用 file_edit；标 `V400-B-xx`；报告 `docs/v400_fix_b.md` 实时落盘。

## 任务 B1：`lib/core/resource/resource_cache.dart`（核心）
严格按契约实现 `ResourceCache`：
- `json(key, fetch, {ttl=kJsonTtl=168h, staleOnError=true})`：
  - JSON 缓存到 Hive 箱 `resource_json`（先读 main.dart 的 openSafe 模式确认箱开法——**由 C 负责在 main 开箱，你只实现 init() 幂等**）
  - **in-flight 合并**：同 key 并发只发一个 fetch（歌词重复请求根治）
  - fetch 失败：有旧值（哪怕过期）返回旧值 + debugPrint 留痕（失效回退，第 9/16 条）
  - 90s 列表用 `kListTtl`；API 返回 JSON 默认 168h
- 实际文件永久缓存：`putFile/file/filePath/cacheUrlFile`——缓存目录用 `StoragePermissionService.resolveRoot()`（先 file_read 确认签名）的 `cache/` 子目录；`cacheUrlFile` 用 Dio 流式下载，返回本地绝对路径；已存在直接返回（**永久，不淘汰**）
- `clearJson()` / `clearLists()` 供设置页清缓存（C 接入，你只需提供方法）
- 缓存 key 必须含用户维度（userid）与音质/语言维度（第 23 条）；失效回退的旧值也要带 `stale: true` 标记在返回体里（若映射结构允许）

## 任务 B2：`cached_api.dart` — API 调用聚合
- `CachedApiCall(this._api)` 包装 `KugouApiClient.get/post`（先完整读其定义确认签名）
- `get/post` 统一走 `ResourceCache.json`，ttl 可覆盖
- **6 个 repository 接入**：把散落的 `_api.get(...) + MemoryCache.instance` 替换为 `CachedApiCall`（或按业务保留直连但套 `ResourceCache.json`），最小侵入，逐个完整读后改
- 本期接入范围：home/lyric/mv/playlist/search/player repository；其余 7 个在报告里给迁移清单（不强改）

## 任务 B3：`lyric_translation_stream.dart` + 翻译增量
- 按契约实现 `LyricTranslationStream` / `LyricTranslationPatch`（broadcast StreamController，dispose 对称）
- `translate_api.dart` 与 `lyric_repository.dart`：每批译文完成即 `emit(patch)`（**实时插入**，不等整批）；失败批重试一次（504 场景），重试仍失败留痕但不崩
- 翻译结果写持久缓存（B-29 模型维度键已有，核对）；命中缓存也 emit 一次（让 UI 秒显）
- 「非必要不翻译」保持 v3.9.9 A 档语义：original 模式零 API

## 任务 B4：失效回退
所有 `ResourceCache.json` 调用点统一：上游失败 → 旧缓存 → 再抛。禁止静默吞异常。

## 完成后
8 行内汇报：模块 3 文件方法清单、6 repository 接入状态、预加载模块对接点（供 C 调用的确切 API）、analyze 逐文件结果、未做项原因。
