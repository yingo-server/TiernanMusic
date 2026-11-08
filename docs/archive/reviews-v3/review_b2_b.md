# 审查报告：评论 / 歌单 / MV 模块（批2检2，纯读）

基线：commit `bcfd024`，工作目录 `/var/minis/workspace/TiernanMusic`。
全部 10 个指定文件已用 file_read 从头到尾完整阅读；另用 rg 只定位了入口调用点（未筛选阅读文件内容）。

严重度排序：🔴 编译阻塞 → 🟠 功能失效 → 🟡 体验瑕疵 → ⚪ 代码质量。

---

## 🔴 编译阻塞

无。

---

## 🟠 功能失效

### 1. 评论页无任何入口，整个评论功能不可达
- `lib/core/router/app_router.dart:47` 定义了 `/comments/:type/:id`，但全仓库没有任何 `context.push('/comments/…')` 或 `CommentsPage(` 的调用点（rg 全库仅路由声明一处）。`CommentRepository.fetchCount` 也无调用者。
- 歌单详情页、专辑页、全屏播放器均没有"评论"按钮。
- **修法**（示例，加在全屏播放器操作区 `lib/features/player/presentation/full_player_page.dart` 的 `_MvEntry` 旁）：
  ```dart
  OutlinedButton.icon(
    onPressed: () => context.push(
      '/comments/song/${Uri.encodeComponent(song!.albumAudioId)}'),
    icon: const Icon(Icons.comment_outlined),
    label: Text(context.l10n.comments),
  )
  ```
  歌单详情页同理：`context.push('/comments/playlist/${Uri.encodeComponent(detail.id)}')`（注意用 `detail.id`，它来自 `global_collection_id`）。

### 2. 拉到底后下拉刷新，再也加载不出更多（`_hasMore` 不复位）
- `lib/features/comment/presentation/comments_page.dart:52-56`：`load({bool refresh = false})` 里 `if (refresh) _page = 1;` 只重置页码，**没有重置 `_hasMore`**。第一次翻完整列表后 `_hasMore=false`，之后下拉刷新 `_page` 回到 1，但 `loadMore()` 在 `if (_loadingMore || !_hasMore) return;` 直接返回 —— 刷新后的列表永远只有第一页。
- **修法**：
  ```dart
  Future<void> load({bool refresh = false}) async {
    if (refresh) {
      _page = 1;
      _hasMore = true;   // ← 补这行
    }
    ...
  ```

### 3. 刷新与加载更多并发会串页/重复追加
- `comments_page.dart:44-97`：`load(refresh: true)`（RefreshIndicator）与 `loadMore()` 之间没有任何互斥。用户在 loadMore 请求在途时下拉刷新：refresh 把 `_page` 置 1，随后在途的 loadMore 返回旧页数据追加到**刷新后的第一页**后面（重复/乱序），且 `_page = next` 会把页码写成旧页+1。
- **修法**（互斥 + 代次计数）：
  ```dart
  int _generation = 0;
  Future<void> load({bool refresh = false}) async {
    if (refresh) { _page = 1; _hasMore = true; }
    final gen = ++_generation;
    try {
      final result = await _repo.fetchComments(...);
      if (gen != _generation) return;   // 已被更新的请求取代
      ...
  ```
  `loadMore()` 同样捕获 `gen`，返回后 `if (gen != _generation) return;` 再落 state / 推进 `_page`。

### 4. 删除评论缺 `tid`，楼层回复删不掉；也没有"自己的/别人的"区分
- `comments_page.dart:186-200` `_deleteComment` 只传 `comment.id` 与 `specialId`，**从不传 `tid`** → 删楼层回复（需要 cid + special_id + tid）必然失败。
- `comment_repository.dart:95-105` `Comment.isMine` 字段解析了但从未赋值（恒 false），UI 在登录态下对**所有**评论都显示删除菜单（`comments_page.dart:344-352`）——点删别人的评论只会收到服务端报错。
- **修法**：
  - `Comment.fromJson` 补：`isMine: '${json['userid'] ?? ''}' == _api.userid`（需把 userid 传入或在 UI 层比对 `authStateProvider` 的 userid 与 `json['userid']`/`user_id`）。
  - UI 层：`onDelete: _isLoggedIn && comment.isMine ? ... : null`。
  - 删楼层回复时传 tid：`deleteComment(comment.id, specialId: comment.specialChildId, tid: reply 的 cid)`（楼中楼页面接入时补）。

### 5. 发送评论遇 20028 完全走不到验证流
- `lib/features/auth/presentation/verification_listener.dart:30-40` 只监听 `verificationStreamProvider`，而该流（`lib/features/player/player_provider.dart:45-50`）只订阅 `audioHandlerProvider.verificationRequired` —— **只有播放链路**会发事件。评论发送的 `ApiException(20028)` 在 `comments_page.dart:_send` 的 `catch (e)` 里被 `Toast.show(commentFailed('$e'))` 吞掉，用户看到的是裸错误码，无验证弹窗、无重试。
- 好的一面：**没有自动重试**，因此不存在"循环弹验证"的问题（符合"禁止自动重试（审核中）"的红线）。但验证能力对评论缺失。
- **修法**（不自动重试，只弹验证、把重试决定留给用户）：
  ```dart
  } on ApiException catch (e) {
    if (mounted && e.needsVerification && (e.ssaCode?.isNotEmpty ?? false)) {
      final ok = await showCaptcha(context, e.ssaCode!); // 复用 CaptchaPage
      if (mounted) {
        Toast.show(context, context.l10n.commentVerifiedRetryHint); // 提示用户手动再点发送
      }
      return;
    }
    if (mounted) Toast.show(context, context.l10n.commentFailed('$e'));
  }
  ```
  注意 `_directOrFallback`（`kg_direct_api_client.dart:75-91`）在直连 20028 时会**先回退 kapi 再抛出**，等于同一业务请求打两次（一次直连、一次中转）——风控场景下这本身有加重风控的风险，建议对 `e.needsVerification` 的直连失败**不回退**直接 rethrow。

### 6. 收藏/取消收藏歌单、添加歌曲到歌单：仓库方法齐全但无 UI 入口（死代码）
- `playlist_repository.dart:64-93` 的 `collectPlaylist` / `deletePlaylist` / `addTracks` / `removeTracks` 全仓库无调用者。审查点 13/14 要求的 UI 入口与确认弹窗**不存在**。且无入口意味着 `/playlist/add type=1`、`/playlist/tracks/add` 的 `data` 拼接格式问题（见 ⚪ 第 18 条）暂时不暴露。
- **修法**：在歌单详情页 AppBar `actions` 加收藏按钮：
  ```dart
  IconButton(
    icon: const Icon(Icons.favorite_border),
    onPressed: () async {
      final confirm = await showDestructiveConfirm(context,
          title: l10n.collect, message: l10n.collectPlaylistConfirm,
          confirmLabel: l10n.confirm);
      if (confirm) await repo.collectPlaylist(
        name: detail.name,
        listCreateGid: detail.id, // global_collection_id
      );
    },
  )
  ```

### 7. 歌单歌曲只取第一页（100 首），无加载更多
- `playlist_repository.dart:26-34` `fetchTracks` 有 `page/pageSize` 参数，但 `playlist_detail_page.dart:40-43` 的 `playlistTracksProvider` 只调 `fetchTracks(id)` 一次；`PlaylistTracks.total` 解析了 `data.count` 却没被用来翻页。超过 100 首的公共歌单被静默截断，"播放全部"也只播前 100 首。
- **修法**：仿照评论页做 StateNotifier 分页（`loadMore` 追加 `fetchTracks(id, page: n)`），或一次性把 pageSize 提到上游上限并在 UI 上明示"仅显示前 N 首"。

---

## 🟡 体验瑕疵

### 8. 加载更多 footer 永远转圈
- `comments_page.dart:168-176`：footer 的显示条件是 `page.comments.length < page.total`，与 `_hasMore` 无关。`_hasMore=false` 后 footer 仍是 `CircularProgressIndicator`，用户会以为还在加载。
- **修法**：footer 按 `_hasMore` 分支：true → spinner；false → `Text(context.l10n.noMore)`。需要把 `_hasMore` 暴露进 `CommentPage` 或 state。

### 9. 楼中楼只能看数量不能进入
- `comments_page.dart:361-366` 显示 `repliesCount(comment.replyCount)` 但是纯 `Text`，不可点。`CommentRepository.fetchFloor`（`comment_repository.dart:42-55`）已实现却无调用者。
- **修法**：包 `GestureDetector`/`InkWell`，push 楼中楼页（传 `comment.specialChildId` + `comment.id`）。

### 10. 回复楼中楼成功后列表不刷新、replyCount 不变
- `comments_page.dart:255-262`：`sendFloorReply` 成功后只弹 toast，没有 `load(refresh: true)`，也不给该评论 `replyCount+1`。顶层评论发送路径有刷新（`sendComment` 内），两条路径行为不一致。
- **修法**：`sendFloorReply` 成功后 `await ref.read(_commentsProvider(_args).notifier).load(refresh: true);`

### 11. 清晰度切换失败后旧画面停住且被暂停，需手动再点播放
- `mv_player_page.dart:75-105` `_resolve`：切清晰度时先 `old.pause()`，新 controller `initialize()` 失败进 catch，旧的仍留在 `_controller`（已暂停）。画面不黑屏（好），但恢复体验差。
- **修法**：catch 里若 `_controller != null && _controller != created`，恢复 `await _controller!.play();` 并只在"首次解析失败"时显示全屏错误 UI（切档失败用 toast）。

### 12. MV 全屏时未隐藏状态栏
- `mv_player_page.dart:57-61` 只设置了横屏方向，没有 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`。横屏时状态栏仍占位（AppBar 为 null 但 SystemUiOverlay 仍在）。
- **修法**：进入横屏分支时 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`，dispose/竖屏时 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`。返回手势：横屏下 controls 隐藏时无返回按钮，但系统返回（Navigator.pop）仍可用，可接受；建议 controls 隐藏超过 3s 自动恢复时同时保证返回浮层可见。

### 13. 未登录：发送按钮不禁用也不跳登录，仅 toast
- `comments_page.dart:223-229, 292-296`：`IconButton.filled(onPressed: _send)` 恒可用；`_send` 内 `if (!_isLoggedIn) { Toast.show(pleaseLoginFirst); return; }`。能看不能发的约束满足了，但"跳登录"的引导缺失。
- **修法**：未登录时 `onPressed: () => context.push('/login')`（或弹登录引导 BottomSheet），输入框 hint 已是 `loginToComment`，一致即可。

### 14. 首页"乐库推荐"跳歌单传的是 `r.id`，需确认是 global_collection_id
- `home_page.dart:364`：`context.push('/playlist/${r.id}')`。`home/data/models.dart:179-184` 注释说全局 ID 优先级 `global_collection_id > global_specialid > gid`，若 `r.id` 就是该字段则正确；但搜索页用 `p.globalCollectionId`（`search_page.dart:597`），两处口径不同，建议统一改 `r` 的模型也暴露 `globalCollectionId` 再跳转，避免数字 specialid 传进 `/playlist/detail` 触发 20010（直连 `_playlistDetail` 只认 `collection_…` 形式，`kg_direct_api_client.dart:565-583` 有实测注释佐证）。

---

## ⚪ 代码质量

### 15. `_onScroll` 阈值 300px 在短列表会瞬时多次触发（无害但可优化）
- `comments_page.dart:118-124`：有 `_loadingMore/_hasMore` 双守卫，重复加载被挡住 ✅；但列表不足一屏时 `maxScrollExtent=0`，`pixels >= -300` 恒真，会在 build 后立即连发 loadMore（被守卫串行化）。可加 `pos.maxScrollExtent > 0` 条件。

### 16. `load()` 的错误路径：刷新失败时旧数据被吞掉错误
- `comments_page.dart:57-61`：`catch` 里只在 `state.value == null` 时置 error。刷新失败静默保留旧数据（下拉刷新无任何失败反馈，RefreshIndicator 直接收回）。
- **修法**：`catch` 里若 `refresh && state.value != null`，通过 toast/事件通知失败。

### 17. classifies / hotWords 解析正确但 UI 从未消费
- `comment_repository.dart:136-152` 对 `classify_list[]{id,label,cnt}` 与 `hot_word_list[]{content,count}` 的解析与实测字段一致 ✅（热词的 `count` 被丢弃，`hotWords` 只是 `List<String>`）。但 `comments_page.dart` 完全没渲染分类标签与热词 chips。解析层合格，展示层缺失。

### 18. `addTracks` 的 `data` 拼接会错位（现在无调用者，接入前必须修）
- `playlist_repository.dart:84-89`：
  ```dart
  .map((t) => [t.name, t.hash, t.albumId, t.albumAudioId]
      .where((e) => e != null && e.isNotEmpty).join('|'))
  ```
  格式是**位置参数** `名称|hash|album_id|album_audio_id`，`where` 跳过空字段会导致后字段前移（album_id 空时 album_audio_id 落到 album_id 位）。
- **修法**：
  ```dart
  .map((t) => [t.name, t.hash, t.albumId ?? '', t.albumAudioId ?? ''].join('|'))
  ```

### 19. 删除评论对 playlist/album 走 `/comment/music/del` 且直连无此 case
- `comment_repository.dart:95-105`：路径写死 `/comment/music/del`；`kg_direct_api_client.dart` 的 get/post switch 均无 `comment/music/del` → 永远回退 kapi。若 kapi 不支持 playlist/album 删评，需补直连实现或区分路径。

### 20. `sendComment` 支持可选 `name` 参数但 UI 从不传
- `comments_page.dart:_send` → `sendComment(text)`；`name` 形参（`comment_repository.dart:67`）为死参数，可删或用于匿名昵称场景。

---

## ✅ 通过项（逐条对应审查点）

| 审查点 | 结论 | 位置 |
|---|---|---|
| A1 分页守卫 | `_loadingMore`/`_hasMore` 存在且 loadMore 串行化；ScrollController 在 initState 挂、dispose 移除，itemBuilder 不触发请求 ✅（并发与 _hasMore 复位问题见 🟠2/3） | comments_page.dart:52-124 |
| A2 `_page` 重置 | `load(refresh:true)` 置 `_page=1` ✅ | comments_page.dart:52 |
| A3 `special_child_id` 来源 | 发楼中楼取**评论列表项的** `comment.specialChildId`（`special_child_id` 字段），未误用响应里的 `special_id` ✅ | comments_page.dart:257-264; comment_repository.dart:175-177 |
| A4 回复参数 | `sendFloorReply` 传 `special_id`(=special_child_id)+`tid`+`pid`(可选)+`resource_type`(枚举 name) ✅ | comment_repository.dart:71-87 |
| A7 `/comment/count` 裸 Map | `fetchCount` 直接 `data[hash]`（含大小写兜底），不期待 status/data 包裹 ✅ | comment_repository.dart:33-40 |
| A8 like 对象 | `like is Map ? like['count'] ?? like['likenum'] : ...` ✅ | comment_repository.dart:186-189 |
| A9 分类/热词 | `classify_list`→`{id,label,cnt}`；`hot_word_list`→`{content,count}`，字段名与实测一致 ✅ | comment_repository.dart:136-152 |
| A10 未登录 | 能看评论；发送被拦截并 toast `pleaseLoginFirst`；hint 显示 `loginToComment` ✅（引导可加强，见 🟡13） | comments_page.dart:155, 292-296 |
| B11 `global_collection_id` | 首页/搜索跳转均传 `globalCollectionId`（`collection_…` 形式），models 明确"数字 specialid 不能当路由参数" ✅（home_page:364 待确认，见 🟡14） | home_page.dart:303, search_page.dart:597, models.dart:179-184 |
| B12 歌单结构区分 | `PlaylistTracks.fromJson` 同时兼容 `data.songs[]`（公共）与 `data.info[]`（用户）✅；`timelen` 毫秒 `~/1000` ✅ | playlist_repository.dart:152-168, 214-224 |
| B15 封面失败 | `CachedNetworkImage.errorWidget` → surfaceContainerHighest 色块 ✅ | playlist_detail_page.dart:73-77 |
| C16 video_id↔hash | 播放器 MV 按钮传**视频 hash**（`mv.bestHash`）作 path、videoId 作 query；`resolvePlayUrl` 对非 32 位 hex（video_id）先经 `/video/detail` 换 hash，`/video/url` 只收 hash ✅ | full_player_page.dart:280-291, mv_repository.dart:62-94 |
| C17 dispose | 清晰度切换：新 controller 初始化成功后才 `old?.dispose()`；失败时 `created?.dispose()` 防泄漏；`_resolving` 防重入 ✅ | mv_player_page.dart:75-105 |
| C19 无 MV | `songMvProvider` 返回 null 时按钮 `SizedBox.shrink`，不显示 MV 入口 ✅ | full_player_page.dart:257-264 |
| C20 `/video/detail` data 数组 | `raw is List` 取首项 ✅ | mv_repository.dart:196-206 |
| D21 resourceType 映射 | `'playlist'→playlist, 'album'→album, _→song`，与 `CommentResourceType` 及直连 `_commentFloor` 的分支一致 ✅ | comments_page.dart:135-141 |
| D22 未登录看评论 | 列表不依赖登录态；回复/删除入口在未登录时为 null 隐藏 ✅ | comments_page.dart:170-175 |
| D23 主题对比度 | 歌单头图黑色渐变遮罩（transparent→black87）+ 标题 shadow；chips 用 black38 底白字；MV 页纯黑白高对比 ✅ | playlist_detail_page.dart:66-100, mv_player_page.dart |

## 直连 case 抽查（kg_direct_api_client.dart）
- `/comment/music` → POST `/mcomment/v1/cmtlist`，`p/pagesize/show_classify/show_hotword_list/mixsongid` 齐 ✅
- `/comment/count` → gateway + x-router（三标签域名证书问题的正确处理），song 传 `hash`、playlist 传 `childrenid=special_id` ✅
- `/comment/floor` → song 走 `/mcomment/v1/hot_replylist` 且必带 `childrenid`（=special_child_id），playlist/album 走 `/m.comment.service/…` 前缀 ✅
- `/playlist/detail` → `pubsongs.kugou.com /v3/get_list_info`，`data:[{global_collection_id}]`（1..10 项），注释明确数字 specialid 会 20010 ✅
- `/playlist/track/all` → `/v2/get_other_list_file_nofilt`，按 `collection_` 前缀自动切 `global_collection_id`/`specialid` 参数键 ✅
- `/kmr/audio/mv` → `openapi.kugou.com`，body `data:[{album_audio_id}]`（非 mixsongid）✅
- `/video/detail` → `kmr.service` x-router，`data:[{video_id}]` ✅；`/video/url` → `trackermv.kugou.com`，key 签名齐 ✅

## 结论
评论/歌单/MV 的**数据层（Repository + 直连 case）质量高**，实测字段口径（like 对象、classify_list、data 数组、timelen 毫秒、collection_ 前缀）全部对齐。主要问题集中在**展示/交互层**：评论页无入口（功能整体不可达）、`_hasMore` 不复位、刷新与加载更多并发、删评缺 tid 与 isMine、20028 验证流未覆盖评论、歌单收藏/加歌无 UI 且 `addTracks` 拼接会错位、歌单歌曲无分页。建议优先修 🟠1（评论入口）与 🟠2/3（分页状态）。
