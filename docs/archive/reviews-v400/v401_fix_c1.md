# v4.0.1 C-1 修复报告（PrefetchEngine 模块）

基线 dd53d93 · 标 V401-C1-xx · 实时落盘

## V401-C1-01 新建 `lib/core/prefetch/prefetch_engine.dart`

- 冻结签名 5 个成员全部落地：`instance` / `enqueueSongs(songs,{spacing=100ms})` /
  `updateUpcoming(queue,currentIndex,{window=15})` / `onPlaybackCompleted(url,kind)` /
  `dispose()`；另加 `attach(KugouApiClient)`（依赖显式注入，第 2 条；不注入只收集不请求）。
- 预热只预请求 JSON，不下载文件：全部走 `CachedApiCall.get` →
  `ResourceCache.instance.json(key, fetch, ttl: kJsonTtl 默认 168h)`；
  缓存键由 CachedApiCall._keyOf 拼 path+query+userid，与 repository 读写同键，
  不自拼键、不造双实现。
- 三类预请求端点（均项目内已实测/已使用，第 28 条）：
  1. `/song/url`（player_repository.kapi 回退路径同参：hash/album_id/album_audio_id/quality）
  2. `/search/lyric`（lyric_repository 同参，30min→此处默认 168h，歌词候选 JSON）
  3. `/album/detail`（api_verified.md 实测 st=1 data=list[1]，album_id 非空才请求）。
  「封面 JSON」说明：song.cover 在 Song.fromJson 解析阶段已得 URL 字符串，
  项目无独立封面 JSON 接口，为封面再造未实测端点违背第 28 条——不请求，已注明。
- 已命中缓存直接跳过：由 ResourceCache.json 命中判定（fresh → 不发网络）；
  本模块再以 `_requested` hash 集合作上游去重闸门（幂等，第 21 条）；
  in-flight 合并由 ResourceCache._inFlight 兜底，同 hash 不重打。
- 失败留痕不崩：_prefetchOne 三段各自 try/catch + debugPrint（第 6/9 条），
  Future 永不 error 完成，fire-and-forget 安全，不阻塞调用方。
- 循环上界：单次 enqueueSongs 入队上限 60（常量 `_maxEnqueuePerCall`，
  第 25 条）；pending 队列空即停 Timer。
- Timer 对称释放：`_startDrain` 建 / `_disposeTimer` cancel+null（第 20 条）；
  dispose 后 `_disposed` 门禁一切回调与入队（第 18 条）。
- updateUpcoming 重入安全：队列变化/切歌重复调用只对未请求过 hash 生效；
  currentIndex 越界按队首处理（第 14 条边界校验）；新歌插 pending 队头
  （upcoming 优先于启动预热余量，第 24 条）；shuffle 由调用方传当前队列序，
  本模块不重排（第 1 条单一职责）。
- onPlaybackCompleted：调 `ResourceCache.instance.cacheUrlFile(url, kind)`，
  外层再 catchError 兜底并留痕，不崩。

## analyze 收尾（/opt/dart/bin/dart analyze，逐文件）

- `lib/core/prefetch/prefetch_engine.dart`：6 项 error，全部为
  `package:flutter` / debugPrint 符号无法解析 —— Flutter/三方符号噪音
  （契约口径：项目自有类报错即真错误）。对照基线：B 落地的
  `resource_cache.dart` 同法分析同样报 Dio/BaseOptions/debugPrint 等 20 项
  同类噪音。**项目自有类（PrefetchEngine/CachedApiCall/ResourceCache/Song）
  无任何报错** → 真错误 0。
- 本任务未触碰其它文件（C-2 接线范围：main.dart / audio_handler.dart / presentation）。

## 边界遵守

- 未改 main.dart / audio_handler.dart / presentation / repository / arb /
  pubspec / Manifest / Kotlin / 播放列表文件；未 git commit/push；
  仅 file_write 新建（新文件，无 file_edit 对象）；未装 SDK / 未 pub get。
