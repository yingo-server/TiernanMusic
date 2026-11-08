# v3.9 播放页重写契约表（代理①产出，只读清点）

依据纪律：所有列出的类/方法签名均经 file_read 全文核实；analyze 噪音=Flutter/三方包未解析符号。

## 1. Provider 契约（播放链路，player_provider.dart 全文核实）

| Provider | 类型 | 字段/语义 | 消费方 |
|---|---|---|---|
| audioHandlerProvider | Provider\<TiernanAudioHandler\> | engineError:String?、isEngineReady、player、errors、currentSongStream、queue.stream、onSongStarted、verificationRequired、previewStream、actualQualityStream | 全部播放 UI |
| audioPlayerProvider | StreamProvider\<AudioPlayer?\> | 引擎未就绪 yield null；**必须 StreamProvider**（player_provider.dart:41-47 注释：普通 Provider 会永久缓存 null → P0-1） | 进度/时长/播放态派生 provider |
| currentSongProvider | StreamProvider\<Song?\> | currentSongStream | full_player、mini_player、queue_sheet、currentLyricProvider |
| playerErrorProvider | StreamProvider\<String\> | errors 流，main.dart 监听 Toast | main.dart |
| actualQualityProvider | StreamProvider\<AudioQuality?\> | 实际音质（可能降级） | full_player 音质角标 |
| previewProvider | StreamProvider\<bool\> | 60 秒试听标记 | full_player「试听」角标 |
| verificationStreamProvider | StreamProvider\<ApiException?\> | 20028 事件 | verification_listener |
| queueProvider | StreamProvider\<List\<Song\>\> | handler.songs 快照 + queue.stream 触发重发 | queue_sheet |
| position/bufferedPosition/duration/isPlaying/shuffle/repeat | StreamProvider（引擎 null 时稳定空值流） | Duration / Duration? / bool / LoopMode | full_player、mini_player |
| audioEngineReadyProvider | Provider\<bool\> | handler.isEngineReady | 可用于空态引导 |
| playerControllerProvider | Provider\<PlayerController\> | playSong/playQueue/next/prev/togglePlay/seekTo/toggleShuffle/cycleRepeatMode（签名已核实，player_provider.dart:186-225） | 全部按钮 |
| playHelperProvider | Provider\<PlayHelper\> | playHomeSong/Queue、playPlaylistSong/Queue、playSong、playQueue | 各列表页 |
| lyricRepositoryProvider | Provider\<LyricRepository\>（core/providers.dart:16） | findCandidate({hash,keywords,albumAudioId,durationSec})、fetchLyric(candidate,{format='krc'})、ensureTranslation(lyric,lyricId,targetLang) | currentLyricProvider |
| localeProvider / lyricModeProvider | StateNotifierProvider（core/theme/settings_provider.dart） | Locale?（null=跟随系统）/ LyricDisplayMode{original,bilingual,translation} | currentLyricProvider、_CoverOrLyric |
| songMvProvider | FutureProvider.family.autoDispose\<MvInfo?,String\>（mv_provider.dart:19） | key=albumAudioId；MvInfo 字段：videoId/name/artist/sdHash/bestHash | full_player._MvEntry |

评论系统私有 provider（仅存在于 comments_page.dart 内部）：
- `_commentRepoProvider` Provider\<CommentRepository\>（:15）
- `_commentsProvider` StateNotifierProvider.family\<_CommentsController, AsyncValue\<CommentPage\>, _CommentArgs\>（:16）——非公开、非全局；**重写若要跨页读评论数，需新增公开 provider，不得猜名**。

## 2. 按钮契约（full_player_page.dart 逐行核实）

| 按钮 | onPressed |
|---|---|
| 收起 | Navigator.pop()（:108） |
| 更多菜单 download | showDownloadSheet(context, song)（song!=null） |
| 更多菜单 addToPlaylist | showAddToPlaylistSheet(context, TrackRef{name,hash,albumId,albumAudioId}) |
| 更多菜单 queue | showQueueSheet(context) |
| 评论入口（_MvEntry，始终渲染） | `context.push('/comments/song/${Uri.encodeComponent(albumAudioId)}')`（:341-343） |
| MV 入口 | context.push('/mv/{bestHash??sdHash??videoId}?videoId=&title=&artist=')（:357-363） |
| 封面/歌词切换 | 手势 + TextButton（:470/:486），_fadeCtrl.forward(from:0) |
| 歌词行点击 | controller.seekTo(Duration(milliseconds: line.startMs))（:447） |
| 进度条 | 本地 _dragMs 拖动；onChangeEnd → controller.seekTo（:567-573） |
| 随机/上一首/播放暂停/下一首/循环 | controller.toggleShuffle / prev / togglePlay / next / cycleRepeatMode（:605-640） |

mini_player.dart：InkTap → context.push('/player')；长按/队列按钮 → showQueueSheet；播放暂停 → controller.togglePlay；下一首 → controller.next。
queue_sheet.dart：itemTap → pop 后 `controller.playQueue(queue, i)`（isCurrent 直接 return）。

## 3. 模型字段与单位（models.dart / Song.fromJson 实测注释核实）

- Song：hash、albumId、albumAudioId（= MixSongID，**不是 Audioid**）、name、artist、cover、`duration: Duration`（/search Duration=**秒**；/privilege/lite info.duration=**毫秒**；models.dart:128-165 分字段显式换算）、quality: AudioQuality、localPath（String?，绝对路径或 content://，Uri.parse 统一处理）。
- AudioQuality 枚举 value/label：128/320/flac/high/super；fallbackOrder super→…→128；fromString 兼容 'hires'/'master'。
- PlayableResult{url, quality, isPreview}；bitRate 单位 **bps**（阈值 ≥500000→flac、≥192000→q320，player_repository.dart:270-286）。
- KrcLine/KrcWord：startMs/durationMs 全部 **毫秒**；offset 正值=歌词提前（解析时已做减法，视图不得再加，krc_parser.dart:265-270）。
- Comment{id,userName,avatar,content,likeCount,createTime,replyCount,specialChildId?,isMine}；like 是对象{count,…}（comment_repository.dart:238-244）。
- 评论分页页大小 30（`_page*30>=total` 判 hasMore，comments_page.dart:97/:112）。

## 4. 路由参数（app_router.dart 全文核实）

- `/player` → FullPlayerPage（无参数）
- `/comments/:type/:id` → CommentsPage(resourceType, resourceId)；type∈{song,playlist,album}，song 的 id=**mixsongid**（=album_audio_id）；playlist 用 id query `?user=`仅歌单路由
- `/mv/:hash` + query videoId/title/artist → MvPlayerPage
- `/playlist/:id`（query user=listid）、`/artist/:id`、`/album/:id`、`/rank/:rankId`（非数字→错误页）、`/login`、`/downloads`
- MainShell = VerificationListener + shell + MiniPlayer + NavigationBar（app_router.dart:133-163）

## 5. 评论入口可达链路（为什么曾「评论系统没了」）

链路：FullPlayerPage._MvEntry（:336-346 OutlinedButton.icon「评论」）→ push `/comments/song/{albumAudioId}` → app_router.dart:56-63 GoRoute → CommentsPage。
- 历史 bug（UI-04，已在现文件修复）：评论按钮原写在 `_MvEntry` 的「无 MV early return」之后 → `albumAudioId.isEmpty` 或无 MV 的歌整个入口消失。现评论按钮在 early return 前渲染，仅依赖 albumAudioId 非空。
- **当前仍可达断点**：`albumAudioId.isEmpty` 时 `_MvEntry` 返回 SizedBox.shrink（:334）——评论入口再次整块消失，评论与 MV 判定耦合在同一组件里；重写必须把评论入口从 MV 可用性中解耦（歌曲缺 albumAudioId 时也应显示或给不可用原因）。
- 歌单/专辑评论入口：路由支持 type=playlist/album，但播放页只发 song 类型；song_tile 及各详情页是否有入口未在本清单范围内逐一核对（代理③补核）。

## 6. 引擎/播放契约（audio_handler.dart 全文核实）

- ensureEngineReady()：JustAudioBackground.init（bootstrap.dart:62-70，无 handler 参数，androidStopForegroundOnPause=false）成功后才建 AudioPlayer；失败 → engineError 置位 + _errorController.add + ErrorLogger 落盘，返回 false；**playQueue/playSong/skipToNext/prev 首行 `if(!await ensureEngineReady()) return;` 静默放弃**（audio_handler.dart:214/:245/:532/:550）。
- _playAt 世代：_playToken；_loading 互斥闸门只在 finally 释放，_pendingIndex 排队（:298-303/:449-457）。
- pause/stop/onNotificationDeleted 作废世代（_playToken++）但**不开闸**（V3-13）。
- 20028：catch → _pendingSongIndex + _verificationController.add → MainShell 的 VerificationListener → CaptchaPage pop(true) → retryPendingPlayback()。
- 失败自动跳歌：_failureStreak < _songs.length，canAdvance 需 token==_playToken。
- localPath 存在且可用（content:// 或 File.existsSync）→ 离线分支；装载失败回退在线（PL-01），成功后 clearLocalPath。

## 7. 重写必须保留的契约（代理②/③执行清单）

1. **Provider 单一来源**：只 watch 第 1 节列出的已有 provider；currentSongProvider.valueOrNull==null 即空态；audioPlayerProvider 必须保持 StreamProvider 语义（派生 provider 不得改成读一次性 getter）。
2. **PlayerController 方法签名**：8 个方法见 player_provider.dart:186-225；togglePlay 内含引擎未就绪时 ensureEngineReady 重试逻辑——UI 不得绕过自行 new AudioPlayer/Repository。
3. **路由**：`/comments/song/{Uri.encodeComponent(albumAudioId)}`、`/mv/{hash}?videoId&title&artist`、pop 收起；路由表在 app_router.dart 已存在，重写页面无需新增。
4. **评论入口**：独立于 MV 判定渲染；id 一律 albumAudioId（mixsongid）；未登录走 loginToComment/ensureLoggedIn；分页 30、footer 重试范式（_pageError/retryLoadMore）。
5. **单位**：歌词/进度毫秒（KrcLine.onTapLine 已是 ms，直接 Duration(milliseconds:)）；Song.duration 是 Duration；展示 _fmt 用 m:ss。
6. **音质/试听角标**：actualQualityProvider.label + previewProvider 试听徽章 + engineError banner（V37-PLAY-03，重写不得丢）。
7. **歌词**：currentLyricProvider 返回记录 `(lyric: KrcLyric?, error: String?)`；翻译跟随 localeProvider（zh_CN 缺省）；LyricView(mode: lyricModeProvider, onTapLine→seekTo)。
8. **l10n**：全部文案 context.l10n；Hero tag 'album-art'（mini_player ↔ full_player 封面过渡）。
9. **三态**：未播放空态含「未在播放/未知艺术家」+ 去首页动作；失败含原因（playerError/engineError）+ 重试；播放页当前缺失「去首页」空态动作与显式 loading 态。

## 8. 可疑断点清单（供代理②③核对）

| # | 断点 | 位置 | 说明 |
|---|---|---|---|
| B1 | 评论入口与 MV 组件耦合 | full_player_page.dart:333-335 | albumAudioId 为空时评论入口整块消失（见 §5） |
| B2 | skipToNext/prev/playSong 入口静默 return | audio_handler.dart:214/:245/:532/:550 | 引擎未就绪时队列未装载、无 playbackState error（v37 diag H1 残留：ensureEngineReady 内已有上报，但 handler 方法首行 return 无声） |
| B3 | PlayerController.togglePlay 引擎 null 分支 | player_provider.dart:197-203 | ensureEngineReady 失败静默 return，UI 无反馈 |
| B4 | queue_sheet 点击 → playQueue(queue,i) 整队重装 | queue_sheet.dart:107-111 | 未做世代/时序校验，快速连点两次会整队重放（代理③修） |
| B5 | _CommentArgs/_commentRepoProvider 私有 | comments_page.dart:15-16 | 跨页复用评论数据需公开化；发送评论发送前还会 fetchComments(pageSize:1) 拿 childrenId（comment_repository.dart:104-124，零评论时用 id 兜底，勿删） |
| B6 | fetchCount(hash) 从未被 UI 调用 | comment_repository.dart:60-66 | 评论数徽章缺失（死代码或待接线，重写决定去留） |
| B7 | currentLyricProvider 在 full_player_page.dart 顶层定义 | full_player_page.dart:22-41 | 重写文件时必须迁移，歌单/mini 等无引用，安全 |
| B8 | isPreview 与 actualQuality 由 handler 广播，切歌先重置 | audio_handler.dart:318-322 | 重写角标逻辑不得自行维护第二状态源（原则 5） |
| B9 | dart analyze | 全清单文件 | 869 issues 全部为 Flutter/三方包未解析噪音 + 既有 override 警告与 unnecessary_null_comparison(player_repository.dart:289)；**无项目自有类真错误**（复检于本契约产出时） |

## 9. 已核实签名（防猜 API，代理②③直接引用）

- `showQueueSheet(BuildContext)` / `showDownloadSheet(context, Song)` / `showAddToPlaylistSheet(context, TrackRef)` — TrackRef{name,hash,albumId,albumAudioId} 必填构造（playlist_repository 导出，full_player_page:15/:141-147 使用处核实）。
- `LyricView({required KrcLyric lyric, required Duration position, LyricDisplayMode mode, ValueChanged<int>? onTapLine})`（lyric_view.dart:22-29）。
- `LyricRepository.findCandidate({String? hash, String? keywords, String? albumAudioId, int? durationSec})`、`fetchLyric(LyricCandidate,{String format='krc'})`、`ensureTranslation(KrcLyric,String,String)`（lyric_repository.dart:22-35/:57/:133）。
- `CommentRepository.fetchComments({required type, required id, int page=1, int pageSize=30})`、`sendComment({type,id,content,name?})`、`sendFloorReply({specialId,tid,content,pid?,resourceType,name?})`、`deleteComment({required cid, mixsongid?, specialId?, tid?, resourceType=song})`、`fetchFloor({specialId,tid,type=song,mixsongid?,page=1})`。
- `CommentArgsShim(type,id,specialId,tid)` + `CommentFloorPage({required args, required comment})`（comment_floor_page.dart:16-39）。
