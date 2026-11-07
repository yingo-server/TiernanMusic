# v3.9.9 C 档修复报告：歌单顺序异常排查（V399-C1）

基线 `755dcea`；任务书 `docs/TASK_v399_c.md`。

## 一、假设排查（逐条实证）

### a) 分页合并乱序 —— 排除（代码实证）
`playlist_repository.dart` `fetchTracks()`（L60-115）：整条链路是 **串行 await**——
`final firstTracks = await fetch(page);` 之后 `while` 循环逐页 `await fetch(p)` + `songs.addAll(t.songs)`。
Dart 的 await 是顺序执行的，不存在「page 2 先回、插入顺序错」的可能。
合并方向：按页号升序拼接（第 1 页在前），**不反转任何一页**（F4-13 已把旧的 reversed 插队首改掉）。
结论：合并逻辑本身就是按上游给定页序拼接，无乱序可能。

### b) 排序参数错传/漏传 —— 排除（对照 Node 源码 + 原生实测）
逐字段对照 `/var/minis/workspace/KuGouMusicApi/module/playlist_track_all.js`：

| 字段 | Node | kg_endpoints_playlist.dart `playlistTrackAll()` | 一致 |
|---|---|---|---|
| begin_idx | (page-1)*pagesize | (page-1)*pagesize | ✅ |
| pagesize / plat / type / mode / personal_switch / area_code / extend_fields | 同 | 同 | ✅ |
| id | global_collection_id | isCollection ? global_collection_id : specialid | ✅（且 Node 无 sort/order 类字段） |

Node `playlist_track_all_new.js`（用户歌单）vs `kg_endpoints_playlist.dart userPlaylistTracks()`：
listid/userid/type/page/pagesize/area_code/allplatform/show_cover/token 七项逐字段一致，页大小默认 300 亦一致。
**关键：两个 Node 模块的 dataMap/paramsMap 里根本不存在任何 sort/order 字段**——
不存在「漏传排序参数」这回事；上游排序是服务端既定的。
另注：`_parseTracksResource` 里的 `'sort': 0` 属于**加歌写操作**的资源项字段（playlist_tracks_add.js，
PLY-05 补齐），与列表顺序无关，不是嫌疑参数。

### c) 渲染层无序集合 —— 排除（代码实证）
- `PlaylistTracks.songs` 是 `List<PlaylistSong>`（playlist_repository.dart），从未进 Map/Set。
- 渲染：`SliverChildBuilderDelegate` 直接 `tracks.songs[index]`，`childCount = songs.length`，
  SongTile 无 key（Widget 无状态，不参与复用重排）。
- 播放队列 `_emitQueue` / `playQueue` 均按 List 原序 `map`，audio_handler 仅在
  `shuffleModeEnabled` 时用 `_randomIndex()` 洗牌——那是显式随机播放功能，非缺陷。
- 消费方 PlayHelper `_songFromPlaylist` 逐项转换，保持索引顺序。

### d) 缓存混装 —— 排除（代码实证）
MemoryCache 键：公共歌单 `/playlist/track/all?id=<gid>&page=<p>&pagesize=100`、
用户歌单路径**根本不进缓存**（`fetchUserTracks` 直连无 cacheKey）。
键含全部影响结果维度（第 23 条）；`get<T>` 命中同键返回同一份完整 JSON，
不存在「不同次请求的分页数据混装」路径——缓存值是单页响应体，按页号分键，页与页不串。

## 二、根因判定：以上都不是 → **其他（e）：仓库层的「排序改写」**

真根因在 `fetchTracks()` 的 `newestFirst: true` 语义（playlist_repository.dart L60-69 注释 +
playlist_detail_page.dart `playlistTracksProvider` 传 `newestFirst: true, allPages: true`）：
**它假设「page=1 最新、页越大越旧、页内从新到旧」，并把该假设当作排序依据**——
但代码实际只是按页号升序拼接，没有做任何改写；真正的漂移源头不是这里。

### 上游稳定性实测（本次实锤，三重验证）

**公共歌单（直打原生 pubsongs.kugou.com，用 tool/kg_probe.py 复刻直连签名，非 kapi——第 33 条合规）：**
- 串行拉 page1+page2，重复 6 次：**6 次全序列 hash 级完全一致**（47 首，head/tail 全同）
- tool/kg_probe.py 原生参数复刻（与 Dart playlistTrackAll 逐字段相同），3 跑一致

**并发对照实验（证明 a 不成立）：**
- 并发打 page1+page2 × 4 次：4 次结果彼此相同、且内部分片仍按响应序拼接（作业闭包捕获
  seq 但 append 无跨页竞争）——头部是 page2 的歌（证明并发确实乱序了），但**每次乱出的
  序都一样**。6 次串行结果彼此一致。→ 服务端分页响应**稳定**，「上游顺序漂移」不成立。
  （若上游本身漂移，6 次串行不可能全部一致。）

**结论链**：上游顺序稳定（6/6 一致） + 我们合并按页序（串行 await） + 渲染按 List 序
（无 Map/Set、无 shuffle 联动） + 缓存按页分键（无混装）——
四个假设全排除后，唯一能产生「同一歌单刷新顺序漂移」的剩余路径是：
**服务端对带登录态的请求（用户歌单/收藏歌单）返回顺序与匿名不同**，或
**shuffleModeEnabled 被外部（蓝牙/系统媒体会话）打开后用户看到的是随机队列**。
前者无法在本地验证（需带 cookie 的原生实测，本环境 cookie 过期），后者在
`audio_handler.skipToNext` 的 shuffle 分支是既有功能语义。

### 防御性修复（V399-C1）：给「上游给定顺序」加确定性保证

虽然上游在实测窗口内稳定，但「同一歌单多次刷新顺序一致」这个用户可感知的契约，
值得在客户端加一道**与上游无关的确定性防线**（第 3 条契约先行 + 第 5 条单一事实）：
**在 `PlaylistTracks.fromJson` 出口处，对 songs 做稳定排序——以上游返回序为唯一依据**
（即：不加任何自定义比较器，保持原序；但如果上游某页响应里带 `sort`/`sequence`/
`pubtime` 等可比较字段，也不引入——避免引入上游字段语义分歧）。

实际落点（改动最小、零风险）：
1. `playlist_repository.dart fetchTracks()`：补注释明确「顺序保证 = 串行分页合并 + 页内原序」，
   `newestFirst` 参数名改为 `upstreamOrder`（命名即文档，第 30 条——它根本不做倒序，
   旧名误导了三代维护者以为这里有排序逻辑）。
2. `playlist_detail_page.dart`：`playlistTracksProvider` 传参同步改名。
3. 用户歌单 `fetchUserTracks`：**补齐与 Node 一致的调用形态已一致，无需改**；
   但补一行注释，写明该接口单页默认 300，用户歌单歌曲顺序 = 上游返回序，客户端不改写。

（后续实测补充见文末「补充实测」。）

## 补充实测（落盘后继续排查，修正第二节结论）

**登录态（用户歌单）原生实测**：用 `.test_creds/cj_vip.txt` cookie 直打
`cloudlist.service.kugou.com`（`/v7/get_all_list` 拿到真实 listid=1「默认收藏」18 首，
再连打 `/v4/get_list_all_file_v3` 3 跑）——**hash 序列 3/3 完全一致**。
即：匿名公共歌单（6/6）与登录态用户歌单（3/3）上游顺序**均稳定**。
上一节「登录态请求顺序可能不同」的猜测**不成立**。

### 四假设终判

| 假设 | 判定 | 依据 |
|---|---|---|
| a) 分页合并乱序 | ❌ 排除 | fetchTracks 全串行 await；并发对照实验虽证明「并发会乱序」，但现有代码没有并发 |
| b) 排序参数错传/漏传 | ❌ 排除 | Node 两模块均无 sort/order 字段；Dart 参数逐字段与 Node 一致 |
| c) 渲染层无序集合 | ❌ 排除 | List 直渲，无 Map/Set，无 shuffle 联动（shuffle 是显式随机播放功能） |
| d) 缓存混装 | ❌ 排除 | 公共歌单按页分键完整值缓存；用户歌单不进缓存 |

### 最终根因判定：**其他（e）**

a–d 四条静态+实测均排除，且服务端两通道均稳定。剩余可解释「用户截屏漂移」的
两条本地可改路径：

1. **shuffleModeEnabled 外部置位**：`audio_handler.skipToNext` 在
   `_player.shuffleModeEnabled` 时随机跳歌；蓝牙耳机/车载/系统媒体会话可通过
   AudioService 把 shuffle 置 on。用户看到的「顺序变化」若发生在**播放跳歌**
   场景（而非列表页静态展示），就是随机播放开着——这是功能语义，不是缺陷；
   但 UI 上没有醒目的 shuffle 指示，用户无从知晓（可感知性问题，非本次范围）。
2. **列表页静态顺序**：从代码路径看已具备完全的顺序一致性保证
   （串行合并 + 原序渲染 + 分页缓存按页分键）。用户截屏若指列表页漂移，
   在本环境无法复现（两通道上游 9 跑全一致）——需要用户提供 verbose 日志
   （`TierNanMusic/logs`）或具体歌单 ID 复测。

### 已做修复（V399-C1，最小且零行为风险）

1. `playlist_repository.dart fetchTracks()`：参数 `newestFirst` → `upstreamOrder`
   （第 30 条命名即文档——旧名误导三代维护者以为这里有排序逻辑，实际自 F4-13
   起就是「按上游页序拼接」）；doc 注明顺序保证依据（串行合并 + 页内原序 +
   上游 6 跑实测稳定）。**行为零变化**（参数语义本就如此）。
2. `playlist_repository.dart fetchUserTracks()`：补顺序保证注释（上游给定序、
   不改写、不经缓存、Node 参数逐字段一致、登录态 3 跑实测稳定）。
3. `playlist_detail_page.dart playlistTracksProvider`：传参同步改名 +
   注释同步（跨文件双向核对：全仓 grep `newestFirst` 仅此两处消费/定义）。

改动刻意**不引入**自定义排序（sort by sort/sequence/pubtime 等）：上游顺序
已是唯一权威（第 5 条），客户端任何重排反而制造第二事实源。

### 未做项
- shuffle 无 UI 指示（若最终证实用户看到的是播放队列漂移，根因在此）→
  属 UI 功能项，超出本任务书范围，留 v3.9.x UI 批。
- 登录态公共歌单（收藏的公共歌单带 cookie 打 pubsongs）未实测（cookie 为
  cloudlist 通道验证，pubsongs 登录态未留样）→ 标注未验证，不影响结论
  （匿名 6 跑已证稳定，登录态差异无机制依据）。

## analyze 逐文件报告

```
$ dart analyze lib/features/playlist/data/playlist_repository.dart lib/features/playlist/presentation/playlist_detail_page.dart
```

（结果见下方汇报行；过滤规则：Flutter SDK/三方符号报错为预期噪音，项目自有类报错即真错误。）

## 汇报（8 行内）
1. **根因判定：其他（e）**——a 分页合并乱序 / b 排序参数错传 / c 渲染无序集合 / d 缓存混装
   四假设逐一实证排除：fetchTracks 全串行 await 按页升序拼接（无并发插页）；Node 两模块
   本就无 sort/order 字段且 Dart 参数逐字段一致；渲染 List 直读无 Map/Set；缓存按页分键
   完整值且用户歌单根本不进缓存。
2. **实测依据（非 kapi，第 33 条合规）**：原生 pubsongs 直连（kg_probe.py 复刻签名）公共
   歌单 6 跑串行全序列 hash 级一致；登录态 cloudlist 直连用户歌单（listid=1，18 首）3 跑
   一致——上游顺序稳定，客户端代码路径已具备顺序一致性保证。
3. **并发对照实验**：并发打分页确实会乱序（page2 先回则其歌排前），但 4 次并发结果彼此
   相同、且现有代码无并发——证明「漂移」只能来自本地未复现的运行态（最可能：shuffleMode
   被蓝牙/系统媒体会话置位后的随机跳歌，属功能语义无 UI 指示）。
4. **修复（V399-C1，零行为变化）**：`fetchTracks` 参数 `newestFirst`→`upstreamOrder`
   （第 30 条：旧名误导，实际自 F4-13 起就不做倒序）；补「顺序保证」注释（串行合并+页内
   原序+上游实测稳定）；`fetchUserTracks` 补顺序保证注释；`playlist_detail_page.dart`
   provider 传参同步。刻意不引入客户端重排（第 5 条：上游顺序是唯一事实源）。
5. **analyze 逐文件**（/opt/dart/bin/dart analyze，未装 Flutter SDK、未动 pubspec）：
   - playlist_repository.dart：剩余 error 全部为 dio/flutter/riverpod 包缺失噪音
     （uri_does_not_exist、DioException/debugPrint/Provider 未定义），项目自有类零报错 ✅
   - playlist_detail_page.dart：同上，剩余 error 全为 Flutter SDK/三方符号噪音
     （CachedNetworkImage/BoxFit/Padding/Shadow 等），项目自有类零报错 ✅
6. 跨文件双向核对：`grep newestFirst` 全仓仅定义+调用两处，均已同步；无其它消费方。
7. 未做项：①shuffle 无 UI 指示（若用户看到的是播放队列漂移，根因在此）→ UI 功能项留
   v3.9.x；②登录态公共歌单（pubsongs 带 cookie）未留样 → 标注未验证，无机制依据表明
   与匿名态不同。
8. 禁守纪：未动 pubspec.yaml、未装 SDK、未 git commit/push、只用 file_edit、改动均标
   V399-C1；报告实时落盘于 docs/v399_fix_c.md。
