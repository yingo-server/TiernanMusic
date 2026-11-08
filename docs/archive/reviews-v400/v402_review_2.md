# v4.0.2 复核②：缓存/预加载模块正确性（只读）

日期：2026-11-08 ｜ 基线：当前工作区 ｜ 方式：逐文件通读（未 grep 筛源码、未改任何代码）
范围：resource_cache / cached_api / lyric_translation_stream / prefetch_engine / main / settings_page / lyric_repository / lyric_view / audio_handler，对照冻结契约 docs/TASK_v400_arch.md 与 QUALITY_STANDARD.md。

---

## 1. ResourceCache 闭环核查 —— 通过（附 1 个 P1）

| 契约点 | 证据 | 结论 |
|---|---|---|
| 168h JSON TTL | `kJsonTtl = Duration(hours: 168)`，`json()` 默认 TTL，`fresh = now < storedAt + ttl`（resource_cache.dart:17,96-100） | ✅ |
| 90s 列表 TTL | `kListTtl = 90s`；`isList = ttl == kListTtl` 决定 `list:` 前缀（:19,95-96）；home/search/playlist/fetchDetail 均显式传 kListTtl | ✅ |
| cacheUrlFile 永久文件 | `_dirOf(kind)` → `.part` 下载后原子 `rename`；已存在幂等返回；失败清理半截文件（:214-244） | ✅ |
| in-flight 合并 | `_inFlight[key]` Map，命中直接 `return pending`，finally 移除（:101-110）；单 isolate 前提成立 | ✅ |
| staleOnError 回退 | `_doFetch` catch 内 `staleBody != null` 时返回副本加 `__stale:true`，不污染箱内原值；无旧值 rethrow 不吞异常（:115-124） | ✅ 闭环成立 |
| `__stale` 消费 | **全仓 `__stale` 仅出现在 resource_cache.dart 的 3 处注释/打标点**；6 个 repository、UI 层均未读取该标记 | ❌ P1-2：假降级 |
| 损坏缓存自愈 | `_readStored` 解码失败/形态不对 → `box.delete` 防反复（:136-152） | ✅ |
| init 幂等竞态 | main.dart `openSafe('resource_json')` 先开箱；`ResourceCache.init()` 幂等（已开则引用），`json()` 内部兜底 `await init()`；无双重 openBox 窗口 | ✅ |
| clearJson 范围 | 只删 `json:` 前缀；`list:` 靠 90s 自愈——设计自洽 | ✅ |

## 2. CachedApiCall —— 通过（附 2 个 P2）

- 键维度：`path + 排序后 query + |u=userid`（cached_api.dart:23-33），query 按 key 排序 ✅；userid 由 main.dart applyAuth 写入 `client.userid = user?.userid ?? '0'`，切号键维度随之切换 ✅。
- 6 repository 接入：home / search / playlist（detail、track/all、track/all/new）/ player（privilege/lite）/ mv（kmr/audio/mv、video/detail）/ lyric（search/lyric、/lyric，30min 自定 TTL）✅。
- 写后失效：`PlaylistRepository._write` 成功后 `_invalidatePlaylistCaches()` → `ResourceCache.clearLists()` + MemoryCache 定向清除（playlist_repository.dart:359-408）✅；MV 收藏走直连客户端不经 CachedApiCall，无旧列表问题 ✅；登录态强相关的 `/everyday/recommend`、`/user/playlist` 刻意不走缓存（home_repository.dart:105-125）✅。
- **P2-4**：`post()` 的键 `_keyOf(path, query)` 不含请求体 `data` —— 同 path+query 不同 body 会串缓存（当前调用面暂未踩中，属埋雷）。
- 次要观察：`userid` 初始值为 `''` 而非注释声称的 `'0'`，首帧前的请求与匿名 `'0'` 是两个键——只造成一次重复请求，无害。

## 3. PrefetchEngine —— 通过（附 1 个 P2）

- 端点：`/song/url`、`/search/lyric`、`/album/detail` 均在 api_verified.md 实测表内，为原生分派路径 ✅；封面不造未实测端点，理由在注释中成立 ✅。
- 节流：`Timer.periodic(100ms)` 每 tick 消费一首（`_drainOne`），同步入队即刻返回、不阻塞首帧 ✅；`_startDrain` 先 cancel 再续期、`_disposeTimer` 对称、`dispose()` 置 `_disposed` 后所有回调先检存活 ✅。
- 上限：`_maxEnqueuePerCall = 60`，`taken >= 60 - _pending.length` 截断（有界）✅；`updateUpcoming(window:15)` 越界 index 按队首兜底、去重集共享、upcoming 插队头 ✅。
- **P2-3**：预热 `/song/url` 的 JSON **没有任何消费方**——播放时 resolveUrl 走直连 KgPlayApi（`play.songUrl`），不经 CachedApiCall，键也对不上（kapi 侧还有 signKey/时效语义）。预热把带签名时效的播放地址以 168h 缓存，既白耗 60 首配额中的大半请求，也埋下「过期 URL 被当新鲜缓存」的语义错误。`/search/lyric`、`/album/detail` 预热与播放侧同键，真正有效。
- 次要观察：`enqueueSongs` 与 `updateUpcoming` 混用时 `_startDrain` 会重置周期（100ms 计时从头算），轻微但不违规。

## 4. `_lastPlayUrl` / `_emitQueue` / completed —— 装载分支覆盖完整，但 completed 有 P1

逐分支核对 audio_handler.dart：

| 分支 | `_lastPlayUrl` | 证据 |
|---|---|---|
| 在线主分支 | `= result.url`（装载成功后） | `_playAt` 在线分支 |
| 离线主分支 | `= ''`（本地文件无需缓存） | 离线分支 |
| 离线失效→在线回退 | `= result.url` | PL-01 回退分支 |
| 试听（freePart 60s） | **同样被 `= result.url` 写入**，`_isPreview=true` 仅发流不拦缓存 | ⚠️ |
| 特殊音质（蝰蛇/魔法） | 经 `_resolveViaDirect` 成功后同在线主分支写入 | ✅ |
| stop() | `= ''` 显式清空 ✅ | stop() |
| onNotificationDeleted | 未清（但引擎已 stop，completed 不会触发） | 观察 |

`_emitQueue` 每次队列变化调 `updateUpcoming(_songs, _index)`，去重由 PrefetchEngine 承担 ✅。

- **P1-1（重点，实锤）**：`processingStateStream` completed 分支只判 `_lastPlayUrl.startsWith('http')` 即调 `onPlaybackCompleted(_lastPlayUrl, 'audio')`，**未检查 `_isPreview`**。VIP/付费曲走官方 60 秒试听通道播完后，60 秒片段会被 `cacheUrlFile` 下载并以「完整歌曲」身份写入永久缓存（永不淘汰）。
- **P2-6**：`playSong` 可在旧曲播放中装载新曲并提前写入新曲 `_lastPlayUrl`；此时旧曲自然播完触发 completed，会把**从未完整播放过的新曲 URL** 当完整播放缓存（错歌文件入缓存）。窗口小但存在。

## 5. 清缓存 / init 竞态 —— 通过

- `_clearCache`：清 MemoryCache、翻译缓存、`json:`+`list:`、旧 Hive 缓存箱、临时目录（排除 downloads_tmp）；**未触碰 `cache/resource/` 永久文件目录**，与「实际资源永久缓存」契约一致 ✅。异常不外泄路径原文 ✅。
- `resource_json` 开箱：main.dart openSafe 先行 → runApp → 首帧后 `unawaited(ResourceCache.init())`；任何更早的 `json()` 调用自带幂等 init（isBoxOpen 检查），无开箱竞态 ✅。

## 6. 翻译 stream —— 通过（附 1 个 P2）

- 504/失败重试一次：批翻译 catch 内重试一次，仍败不入缓存 ✅。
- 命中缓存也 emit：缓存命中且 `hit>0` 时 emit patch，UI 秒显 ✅。
- dispose cancel：`LyricView.dispose` 中 `_patchSub?.cancel()` 对称 ✅；broadcast 流无监听丢批有文档化兜底 ✅。
- 代际校验：`_onTranslationPatch` 校验 songHash + `p.lyricId == widget.lyricId` + 下标范围 ✅；didUpdateWidget 换词刷新 `_boundLyric/_boundSongHash` ✅。
- **P2-5**：当 `widget.lyricId == null`（emit 侧 lyricId 为空串/候选缺失场景）时 lyricId 匹配被跳过，代际校验仅剩「下标合法」；且 songHash 校验比较的是 State 内已同步的 `_boundSongHash` 与 widget 值（didUpdateWidget 同步后恒等），实际不构成独立防线——切歌瞬间旧歌补丁存在写入新歌词的理论通道。
- 批内偏移 `missing[i+j]`、返回条数不等不入缓存等防御（F4-32/V34-03）复检无误 ✅。

---

## 问题清单（P0/P1/P2）

### P1-1 completed 未排除试听：60 秒试听片段被永久缓存（重点）
- 位置：audio_handler.dart `processingStateStream` completed 分支 + `_playAt` 各分支无条件写 `_lastPlayUrl`。
- 用户可见后果：付费/VIP 曲试听播完即把 60 秒片段以完整歌曲名义永久写入 `cache/resource/audio/`，永不淘汰、无法通过清缓存删除；若未来接通「缓存优先播放」读路径，用户会反复听到 60 秒残缺版且以为下载/缓存损坏。当前仅表现为磁盘静默膨胀（试听多的用户每天数 MB～数十 MB）。
- 建议修法：completed 分支加 `if (!_isPreview)`（并在装载失败/作废世代时同步清 `_lastPlayUrl`）。

### P1-2 `__stale` 标记无任何消费方 = 假降级
- 位置：resource_cache.dart 打标点；全部 repository/UI 未读。
- 用户可见后果：网络故障时 UI 静默展示最长 168h 前的旧数据（首页/搜索/详情），无任何「数据可能过期」提示、无埋点可查，用户与开发都无法区分「实时数据」与「失效兜底」，违背第 16 条「降级必须可感知」。
- 建议修法：CachedApiCall 返回前检测 `__stale` 并统一上报埋点 + 触发一次 UI 级「展示的是离线数据」提示（或在 repository 层消费后删标记）。

### P2-3 预热 `/song/url` JSON 无消费方且缓存语义错误
- 位置：prefetch_engine.dart `_prefetchOne` 第 1 步。
- 用户可见后果：60 首预热配额中大半请求白打（播放走直连 KgPlayApi，键与路径都不同），徒增启动期流量与服务器压力；缓存的签名 URL 168h 后早已失效，构成语义地雷。
- 建议修法：预热删去 `/song/url` 一步（只留 /search/lyric 与 /album/detail），或播放侧 kapi 回退路径改为同键读缓存并校验 URL 时效。

### P2-4 CachedApiCall.post 键不含请求体
- 位置：cached_api.dart `_keyOf(path, query)` 被 post() 复用。
- 用户可见后果：未来任何「同 path+query、不同 body」的 POST（如批量翻译、批量接口）会互相命中对方的缓存响应，返回错误数据且 168h 内不自愈。
- 建议修法：post 的键追加 `data` 的稳定序列化哈希。

### P2-5 lyric_view 代际校验在 lyricId 缺失时退化
- 位置：lyric_view.dart `_onTranslationPatch`；lyric_repository emit 侧 lyricId 可能为空。
- 用户可见后果：切歌瞬间到达的旧歌译文补丁，在新歌候选 id 缺失（widget.lyricId=null）且下标恰好合法时写入新歌词视图，出现 A 歌词配 B 译文的错行；刷新可恢复。
- 建议修法：emit 侧保证 lyricId 非空（候选缺失就不 emit），View 侧 songHash 校验改用补丁未携带时的「订阅世代号」而非同源字段比对。

### P2-6 换曲窗口内旧曲 completed 误缓存新曲 URL
- 位置：audio_handler.dart completed 分支读共享字段 `_lastPlayUrl`。
- 用户可见后果：用户点播新歌而旧曲恰好自然播完时，新歌（可能只播了几秒就被切走）的 URL 被当「完整播放」永久缓存，污染永久缓存语义。
- 建议修法：completed 时校验 `_lastPlayUrl` 归属（如附带本曲 token/hash 快照一致才缓存）。

---

## 统计
- 实锤问题：6 条（P1×2，P2×4）
- 通过项：TTL 双档、in-flight 合并、staleOnError 回退、cacheUrlFile 原子写、init 幂等、键排序+userid 维度、6 repository 接入、写后失效、预热端点合法性、节流/dispose 对称/上限 60/window 15、_lastPlayUrl 全分支赋值+stop 清空、清缓存不删永久文件、翻译 504 重试/命中即 emit/dispose cancel —— 13 项通过
- P0：0
