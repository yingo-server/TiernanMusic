# UI 层数据流 & 资源泄漏审查（窄范围·只读）

> 范围：home_page / search_page / playlist_detail_page / library_page / comments_page
> / mv_player_page / mv_provider / full_player_page / mini_player / queue_sheet
> / app_router / song_tile。
> 审查只读，不改代码。结论按**严重度**排序：CRITICAL → HIGH → MEDIUM → LOW → INFO。
> 标记：✓ 一致 / ⚠️ 有隐患 / ✗ 明确缺陷。

---

## 严重度总览

| # | 严重度 | 结论 | 一句话 |
|---|--------|------|--------|
| A3 | **CRITICAL ✗** | 歌单详情页永远加载失败 | `_playlistRepoProvider` 全程未 override，直接 `throw` |
| B9 | **HIGH ✗** | VideoPlayerController 泄漏 | `initialize()` 抛异常时新 controller 未 dispose |
| B10 | **HIGH ✗** | 评论区 loadMore 在 build 中重复触发 | 无 loading 保护，`_page++` 在 await 前，可能跳页/重复请求 |
| A5 | **MEDIUM ⚠️** | full_player 传的是 video_id 不是 hash | 依赖 resolvePlayUrl 兜底才能播；且清晰度列表反而不显示 |
| A1 | **MEDIUM ⚠️** | 专辑 Tab 点击无效 | `_albumItem` 产出 `albumId`(驼峰)，`HomeSong` 只认 `albumid/album_id/AlbumID` |
| B8 | **MEDIUM ⚠️** | Banner 定时器页面不可见仍在跑 | StatefulShellRoute IndexedStack 保活，切 Tab 不 dispose |
| A2 | **LOW ⚠️** | globalCollectionId 回退 & 榜单跳转 | 三来源均非空；但回退到数字 id、榜单用 rankid 当歌单 id 有风险 |
| A4 | **LOW ⚠️** | 未知 type 静默降级为 song | 且 UI 中目前无任何入口 push 到 `/comments/:type/:id` |
| A6 | **INFO** | 三组件订阅一致，无重复订阅 bug | 仅 MiniPlayer/全屏页不可见时仍有 position tick 重建 |
| B7 | **INFO ✓(除B9)** | 控制器/Stream/监听 dispose 基本齐全 | 仅 mv 的 controller 在异常路径漏 dispose |

---

## A. UI ↔ 数据流一致性

### A3 — PlaylistDetailPage 的 provider 与仓库参数（**CRITICAL ✗**）

结论：**参数匹配 ✓，但页面整体不可用 ✗**。

- 参数层面：`playlistDetailProvider(id)→fetchDetail(id)`、`playlistTracksProvider(id)→fetchTracks(id)`，路由 `/playlist/:id` 把 `state.pathParameters['id']` 透传，`PlaylistRepository.fetchDetail(String globalCollectionId)` / `fetchTracks(String globalCollectionId, …)` 均为单个 String 位置参数 —— **签名与传参完全匹配 ✓**
  （`playlist_detail_page.dart:15,20`；`playlist_repository.dart:17,26`；`app_router.dart:41-44`）。
- **致命缺陷**：`_playlistRepoProvider` 定义为 `Provider<PlaylistRepository>((ref) => throw UnimplementedError())`
  （`playlist_detail_page.dart:10-11`），而全仓库 `lib/` 内**没有任何地方 override 它**（`main.dart:116-118` 的 overrides 只有 `kgDeviceProvider`）。
  → 任意 `ref.watch(_playlistRepoProvider)` 都会抛 `UnimplementedError`，两个 FutureProvider 立即进入 error 态，
  歌单详情页永远显示 `ErrorRetry`，歌曲列表永远显示错误占位。

修复建议：要么把 `_playlistRepoProvider` 改成真实构造
`Provider<PlaylistRepository>((ref) => PlaylistRepository(ref.watch(kugouApiClientProvider)))`（与 library/search 页一致），
要么在 `main.dart` 的 overrides 里注入实现。**当前所有歌单入口（首页歌单/搜索结果/专辑）点击后都会白屏报错。**

---

### A1 — Search 5 个 Tab 的 provider 与模型映射

各 Tab 使用的 provider（`search_page.dart`）：

| Tab | provider | 数据源 |
|-----|----------|--------|
| 单曲 song | `searchRepositoryProvider`（在 `_SongResultTabState` 内命令式分页，`search_page.dart:330-390`） | `searchSongs` |
| 歌单 special | `_playlistSearchProvider(keyword)`（FutureProvider.family，`:524`） | `searchPlaylists` |
| 专辑 album | `_genericSearchProvider((keyword,'album'))`（`:604`） | `searchByType(...,'album')` |
| 歌手 author | `_genericSearchProvider((keyword,'author'))` | `searchByType(...,'author')` |
| MV mv | `_genericSearchProvider((keyword,'mv'))` | `searchByType(...,'mv')` |

模型一致性结论：**渲染字段基本对得上（✓），但专辑 id 映射断裂（⚠️ 见下）**。
album/author/mv 三者经 `searchByType` → `_albumItem/_authorItem/_mvItem`（`search_repository.dart:100-165`）归一化成 `HomeSong`，
`_GenericResultTab` 只读 `s.name / s.singer / s.cover`（`search_page.dart:566-587`）：

- **专辑**：`name←albumname`、`singer←singer`、`cover←img` 均能正确取到 → 专辑名/歌手名/封面**不会空 ✓**
- **歌手**：`name←AuthorName`、`singer←统计串('x 专辑 · y 歌曲')`、`cover←Avatar` ✓
- **MV**：`name←MvName`、`singer←SingerName`、`cover←Pic(补全为 mvthumb URL)`、`hash←MvHash` ✓

**⚠️ 专辑点击无效（数据流断点）**：
`_albumItem` 产出的 map 里字段名是驼峰 `albumId`（`search_repository.dart:118`），
但 `HomeSong.fromJson` 解析专辑 id 只用 `json['albumid'] ?? json['album_id'] ?? json['AlbumID']`（`models.dart:119`），
三者都不含驼峰 → `HomeSong.albumId == null`。
于是 `search_page.dart:594-595` 的 `else if (type == 'album' && s.albumId != null)` 条件恒假 → **点击专辑结果无任何反应**。
（MV 因 `_mvItem` 用的是 `hash` 键，恰好命中 `HomeSong` 的 `hash` 解析，所以 MV 跳转正常。）
修复建议：`_albumItem` 改用 `albumid`/`album_id` 键，或在 `models.dart:119` 增加 `json['albumId']` 兜底。

---

### A2 — HomePage 歌单跳转 `globalCollectionId` 是否三来源非空

结论：**三来源均为非空 ✓（有回退隐患 ⚠️）**。

- 跳转：`context.push('/playlist/${p.globalCollectionId}')`（`home_page.dart:306`）。
- 解析：`globalCollectionId: globalId.isNotEmpty ? globalId : numericId`（`models.dart:186`），
  `globalId` 依次取 `global_collection_id`（/top/playlist）、`global_specialid`（/yueku extra）、`gid`（search special）（`models.dart:178-180`）。
- HomePage 的 `data.playlists` 来自 `/top/playlist`（主）或 `/yueku`（回落）（`home_repository.dart:60-73`），
  两者都带全局 id 字段，因此正常数据下 `globalCollectionId` 恒非空 ✓；search 歌单用 `gid`，同样非空 ✓。
- **⚠️ 隐患 1**：若某条数据三个全局字段都缺，会**回退成数字 specialid**（`numericId`），
  数字 id 传给 `/playlist/detail` 的 `ids=` 参数会拿不到正确歌单（模型注释明确“数字 specialid 不能当路由参数用”）。
- **⚠️ 隐患 2**：若全局字段与数字字段**都为空**，`globalCollectionId` 为空串 → `'/playlist/'` 缺少 path 段，
  无法匹配 `/playlist/:id`，go_router 会抛 “no route” 型错误（无专门兜底页）。
- **⚠️ 隐患 3（同文件另一入口）**：`_RankRow` 用 `context.push('/playlist/${r.id}')`（`home_page.dart:370`），
  此处 `r.id` 是 `rankid`（`models.dart:228`），拿榜单 id 当公共歌单全局 id 传，`/playlist/detail` 大概率查不到。
  建议榜单单独走榜单详情路由。

---

### A4 — CommentsPage 的 resourceType → CommentResourceType 映射

结论：**字符串映射完整 ✓，但未知值静默降级、且当前无入口（⚠️）**。

- 枚举：`enum CommentResourceType { song, playlist, album }`（`comment_repository.dart:3`）。
- 映射：`switch (widget.resourceType){ 'playlist'=>playlist, 'album'=>album, _=>song }`（`comments_page.dart:95-98`）。
  → `'song'`（走 `_`）、`'playlist'`、`'album'` 三者都能正确映射 ✓。
- **⚠️ 传错/拼错**（如 `'mv'`、`'Song'`、`'songs'`）会**静默落到 `_ => song`**，不会崩，但会去拉 `/comment/music`，
  评论区内容与资源不符且无任何提示。建议对无法识别的 type 断言/记录日志或改用 `CommentResourceType.values.byName` 并容错。
- **⚠️ 补充**：全仓库 `grep '/comments/'` 只有路由定义（`app_router.dart:47`），**没有任何 UI 代码 push 到这个路由**——
  评论页当前在 App 内不可达（属接线缺失，非本次逻辑错误，供参考）。

---

### A5 — MvPlayerPage 的 `hash` 参数：两处跳转传的到底是 hash 还是 video_id

结论：**Search 传 hash ✓；full_player 传的是 video_id ✗（靠兜底才不炸，但反向破坏了清晰度列表）**。

- 路由：`/mv/:hash` → `MvPlayerPage(hash: …)`（`app_router.dart:57-62`）。
- **Search MV Tab**：`context.push('/mv/${s.hash}')`（`search_page.dart:593`），其中 `s.hash == MvHash`（`_mvItem`，`search_repository.dart:143`）→ **传的是视频 hash ✓**。
- **full_player `_MvEntry`**：`context.push('/mv/${Uri.encodeComponent(mv.videoId)}')`（`full_player_page.dart:240`），
  `mv.videoId` 来自 `MvInfo.videoId = video_id / mv_hash / id`（`mv_repository.dart:175`），即**优先是数字 video_id，不是 hash ✗**。
- 为什么没直接崩：`resolvePlayUrl` 做了互转兜底——非 32 位十六进制就当 video_id，先 `fetchDetail` 换 `bestHash` 再请求 `/video/url`（`mv_repository.dart:76-92`）。
  所以 full_player 那条**虽然传错参数但在能取到详情时仍可播放**，代价是多一次 `/video/detail` 请求。
- **⚠️ 真正的双向隐患**：`MvPlayerPage` 顶部的清晰度列表用 `mvDetailProvider(widget.hash)`（`mv_player_page.dart:97`），
  而 `mvDetailProvider`→`fetchDetail(hash)`，`/video/detail` **只认 video_id**（`mv_repository.dart:56`）。
  - full_player case（传 video_id）：`fetchDetail(video_id)` 成功 → 清晰度**能显示**，但 `/video/url` 走兜底 ✓
  - search case（传 hash）：`resolvePlayUrl(hash)` 直接可用，但 `fetchDetail(hash)` 返回 `invalid param` → 被 catch 成 null → **清晰度列表为空 ✗**
  即“两处必须传 hash”会让清晰度永远不显示，而“传 video_id”又依赖兜底。**根因是 MvPlayerPage 只收一个参数却要同时喂给只认 hash 的 `/video/url` 与只认 video_id 的 `/video/detail`。**
  修复建议：`MvPlayerPage` 同时接收 `videoId` 与 `hash` 两个参数（或内部首次先 fetchDetail 拿全量信息后统一用 hash），
  full_player 传 `mv.bestHash`（或 videoId+bestHash），search 传 `s.hash` 的同时设法带上 videoId。

---

### A6 — QueueSheet / MiniPlayer / FullPlayerPage 对 currentSong/position 的使用一致性

结论：**三者用法一致、无“重复订阅”类 bug ✓；仅存在不可见时的多余重建（INFO）**。

provider 均为 `StreamProvider`（`player_provider.dart:32-69`）。各处 `ref.watch(...).value ?? 默认值` 的写法一致：
- `MiniPlayer`：watch `currentSongProvider / isPlayingProvider / positionProvider / durationProvider`（`mini_player.dart:35-40`）。
- `FullPlayerPage`：根 build watch `currentSongProvider / actualQuality / isPlaying / shuffle / repeat`；
  `_CoverOrLyric` watch `positionProvider`（`full_player_page.dart` 内）；`_ProgressBar` watch `position/buffered/duration`。
- `QueueSheet`：watch `queueProvider / currentSongProvider`（`queue_sheet.dart:33-34`）。

- **不是 bug**：`positionProvider` 被 MiniPlayer、`_ProgressBar`、`_CoverOrLyric` 多处 watch，但它们是不同 Widget 订阅同一个 broadcast stream，
  Riverpod 会正确分发，不是“重复订阅导致重复请求”。
- **INFO 可优化**：`MiniPlayer` 常驻于 `MainShell` 底部（`app_router.dart`），即便 `/player` 全屏页盖在上面、它不可见，
  仍每秒因 `positionProvider` tick 重建；`_CoverOrLyric` 在看封面（非歌词）时也照常 watch `positionProvider`。
  可考虑在不可见/封面态用 `select` 或条件订阅减少重建。

---

## B. 资源泄漏 & 生命周期

### B7 — 各文件控制器 / 订阅 / 监听 dispose 清点

| 文件 | 资源 | 是否 dispose |
|------|------|--------------|
| home_page | `PageController _controller`（:119）、`Timer _timer`（:131） | ✓ dispose 内 cancel + dispose（:143-147） |
| search_page | `TextEditingController _controller`、`FocusNode _focusNode`、`Timer _debounce` | ✓ 全部 dispose/cancel（:50-54） |
| search_page(`_SongResultTab`) | `ScrollController _scroll`（:330）+ `addListener`（:347） | ✓ dispose（:359） |
| playlist_detail | 无 controller（ConsumerWidget） | — |
| library_page | 无 controller（无 TextEditing/Scroll/Animation），仅 `setState(_loadRecent)` | — |
| comments_page | `TextEditingController _inputCtrl` | ✓ dispose（:104-106） |
| mv_player | `VideoPlayerController _controller` | ✓ dispose（:58），**但异常路径漏 dispose（见 B9）** |
| full_player | `AnimationController _fadeCtrl`（`_CoverOrLyric`） | ✓ dispose |
| mini_player / queue_sheet / song_tile / app_router | 无有状态资源 | — |

> 没有发现 `StreamBuilder`/`ref.listen`/手动 `StreamController` 的使用（位置进度用 StreamProvider 的 `ref.watch`，无需手动取消）。
> 唯一遗漏是 `mv_player` 里“新建但 initialize 失败”的 `VideoPlayerController`（B9）。

---

### B8 — HomePage Banner 自动轮播 Timer 页面不可见时是否仍在跑

结论：**⚠️ 会。dispose 有 cancel，但切 Tab 不会触发 dispose**。

- Timer：`Timer.periodic(4s,…)`，`_BannerCarouselState.initState→_startAutoPlay`（`home_page.dart:124-141`），
  `dispose(){ _timer?.cancel(); _controller.dispose(); }`（:143-147）→ **生命周期结束时确实 cancel ✓**。
- **问题**：`HomePage` 位于 `StatefulShellRoute.indexedStack` 的第一分支（`app_router.dart:13-21`），IndexedStack 会**保活所有分支**。
  用户切到搜索/音乐库/设置 Tab 时，`HomePage` 及其 `_BannerCarousel` **不会 dispose**，于是每 4s 的 `animateToPage` 在后台继续跑，
  白白消耗（离屏仍触发布局/动画与 `setState`）。只有整个 App 销毁才 cancel。
- 建议：用 `TickerMode.of(context)` / `VisibilityDetector` / `WidgetsBindingObserver(AppLifecycleState)`+`routeObserver` 判断可见性，
  不可见时 `_timer?.cancel()`、可见时重启；或改用 `PageController` 前判断 `TickerMode`。

---

### B9 — MvPlayerPage 切清晰度时旧 controller 是否 dispose & `_resolve` 并发保护

结论：**旧 controller 正常路径会 dispose ✓；但异常路径泄漏 ✗；并发保护“有效但过粗” ⚠️**。

- 旧 controller：`final old = _controller; … setState(_controller = controller); old?.dispose();`（`mv_player_page.dart:80-85`）→ 切换成功时旧实例被释放 ✓。
  `dispose()` 里 `_controller?.dispose()`（:58）也覆盖页面销毁 ✓。
- **✗ 泄漏点**：`_resolve` 中
  ```
  final controller = VideoPlayerController.networkUrl(...);
  await controller.initialize();   // ← 若这里抛异常
  await controller.play();
  ...
  } catch (e) { if (mounted) setState(() => _error = '$e'); }  // 没有 controller.dispose()
  ```
  （`mv_player_page.dart:73-88`）当 `initialize()`（或 `play()`）抛异常时，`catch` 只设错误、**没有 dispose 这个新建的 `controller`** → 每次失败重试泄漏一个未释放的原生播放器。
  修复建议：把 `controller` 声明提前，`catch` 里 `await controller?.dispose()`（或 `try/finally` 确保失败分支释放）。
- 并发保护：`if (_resolving) return; _resolving = true; … finally { _resolving = false; }`（:65-89）→ 能阻止重入 ✓。
  但副作用是：初始 `_resolve(widget.hash)`（initState 内）尚未完成时用户点清晰度会被**静默丢弃**（既不排队也不提示）；
  且 `_resolving` 未 setState，UI 无 loading 反馈。属体验问题，不构成泄漏。

---

### B10 — CommentsPage 滚动到底自动 loadMore 是否重复触发

结论：**✗ 会重复触发/跳页（无 loading 保护，且在 build 中产生副作用）**。

- 触发点：`ListView.builder` 的 `itemBuilder` 里，当 `index == page.comments.length` 且 `comments.length < total` 时**直接调用**
  `ref.read(_commentsProvider(_args).notifier).loadMore()`（`comments_page.dart:140-147`）。
- `_CommentsController.loadMore()`：`_page++; await load();`（`comments_page.dart:55-58`）——**先自增页码再 await，且没有 `_loading` 标志**。
- 后果：
  1. `loadMore()` 在 **build 期间**调用（Flutter 反模式），同一帧内该尾项每次被重排在尾都会再触发一次；
  2. 上一次请求还在飞时若因任意 `setState`/重建再次构建尾项 → **又 `_page++` 又发一次请求**，导致页码连跳（漏页）、重复追加、并发写 `state`；
  3. 失败无保护：`load()` 的 catch 只在 `state.value==null` 才记错误，`loadMore` 失败会**静默**吞掉，但 `_page` 已前进。
- 修复建议：控制器加 `bool _loading` 互斥（`if(_loading||!hasMore) return;`），把触发改到 `ScrollController` 监听或 `NotificationListener<ScrollEndNotification>`，
  **不要在 `itemBuilder` 里发请求**；`_page` 在请求成功后再自增。

---

## 附：可复用的一致性观察

- `search` 单曲 Tab 与 `home`、`playlist` 都通过 `playHelperProvider.playHomeQueue/playPlaylistQueue` 起播，`List<HomeSong>` 类型对齐，无模型错配（`play_helper.dart:30/44/75`）。
- `song_tile.dart` 纯 StatelessWidget，无资源；`isPlaying`/`trailing` 全部由外部传入，无内部状态。
- `mv_provider.dart` 三个 FutureProvider 均 `autoDispose`，无泄漏；`mvDetailProvider` 把异常吞成 null 属有意隐藏清晰度按钮，但结合 A5 会误藏（见 A5）。
