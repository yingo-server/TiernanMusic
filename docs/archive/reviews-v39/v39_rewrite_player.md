# v3.9 播放页完全重写报告（代理②）

纪律说明：本文件先读 QUALITY_STANDARD.md（33 条）、v37_perm_playback.md、v37_playback_blank_diag.md，
再完整 file_read（非 grep）以下文件后才动手：
full_player_page.dart(612 行旧文件全文)、mini_player.dart(188)、queue_sheet.dart(129)、
player_provider.dart(225)、play_helper.dart(92)、audio_handler.dart(612)、
player_repository.dart(438)、models.dart(222)、lyric_view.dart(294)、lyric_repository.dart(246)、
comments_page.dart(698)、comment_floor_page.dart(320)、comment_repository.dart(275)、
app_router.dart(163)、song_tile.dart(221)、app_theme.dart(278)、settings_provider.dart(130)。
另核对了依赖定义文件：mv_provider.dart / mv_repository.dart(MvInfo 字段) /
download_sheet.dart / add_to_playlist_sheet.dart(TrackRef 签名) / empty_state.dart /
error_retry.dart / toast.dart / l10n key 全量清单（app_zh_CN.arb，345 键）。

## 改动（完全重写，不复制旧结构）

### full_player_page.dart（612 → 787 行，全新组织）
- 级别/编号：重构 / V39-PLAYER-01
- 依据：任务书「重新组织为清晰的分区」；QUALITY_STANDARD 第 1/5 条
- 影响/改动：分区化——`FullPlayerPage`(路由壳+四态分发) /
  `_EngineErrorBanner`(引擎失败常驻横幅，保留 V37-PLAY-03 契约) /
  `_EngineFailureView`(失败态含重试) / `_EmptyPlayerView`(未播放空态含「返回首页」动作) /
  `_PlayerContent`(正常态) / `_PlayerTopBar` / `_SongInfoHeader` / `_EntryButtonsRow` /
  `_CoverOrLyric` / `_CoverView` / `_ProgressBar` / `_ControlBar` / `_CoverPlaceholder`。
  四态明确分离：engineError!=null && song==null → 失败态（重试调 PlayerController.togglePlay，
  其内部先 ensureEngineReady——player_provider.dart:196 契约）；song==null → 空态；
  song!=null → 正常态；FutureProvider loading 由 AnimatedSwitcher/占位自然覆盖。

### full_player_page.dart:44-69 currentLyricProvider
- 级别/编号：修复 / V39-PLAYER-02（P2）
- 依据：旧实现 build 路径外用 `ref.watch(localeProvider)` 读 Hive 设置框做翻译目标语言；
  lyric_repository.ensureTranslation(lyric, id, targetLanguage) 契约已完整读取（lyric_repository.dart:126）
- 影响/改动：语义修正——「界面语言」应以系统 platformDispatcher.locale 为准
  （localeProvider 是设置页覆盖值，null=跟随系统时旧代码永远用 zh_CN）。
  语言格式与 findCandidate 上游一致（zh/zh_CN 形态），并补 zh 默认区域。

### full_player_page.dart:414-470 _EntryButtonsRow
- 级别/编号：契约修复 / V39-PLAYER-03（P1 契约保留项）
- 依据：app_router.dart:70 `GoRoute('/comments/:type/:id')` → CommentsPage(resourceType, resourceId)；
  comments_page.dart `_CommentArgs` 按 type 字符串映射 CommentResourceType.song
- 影响/改动：评论入口**无条件渲染**（不再可能被任何 early return 连带隐藏），
  仅当 albumAudioId 为空时降级为禁用态（入口可发现，不静默消失，第 16 条）；
  新增队列 IconButton 直达 showQueueSheet（queue_sheet.dart:14 契约）；
  MV 按钮保持旧路由契约（/mv/:hash?videoId=&title=&artist=，hash 优先 bestHash??sdHash）。

### full_player_page.dart:472-582 _CoverOrLyric / _CoverView
- 级别/编号：重构 / V39-PLAYER-04
- 依据：第 20 条资源对称；旧文件 366-385 行 CurvedAnimation 修复注释（R-01）
- 影响/改动：AnimationController/CurvedAnimation 在 State 创建一次、dispose 对称释放
  （保留旧掉帧修复语义，重写结构）；歌词点击 seek 参数显式标注毫秒单位（第 15 条，
  KrcLine.startMs 为 ms——krc_parser.dart:14）。

### full_player_page.dart:640-786 _ControlBar / _ProgressBar
- 级别/编号：布局修复 / V39-PLAYER-05（P2）
- 依据：任务书「大字号/窄屏用 LayoutBuilder+Flexible，禁止固定高度 Row 溢出」
- 影响/改动：控制区主按钮尺寸随 LayoutBuilder 降级（<360px 60px，其余 72px），
  不再固定 72px 硬编码；歌名/歌手行全部 Flexible+ellipsis，大字号（textScaler>1.3
  或 <320px）时歌名允许两行；onChangeEnd 回调加 mounted 检查（第 20 条）；
  Badge 拆为独立小组件消除三份重复布局。

## 契约结论（重写保留项核对表）
| 契约 | 状态 |
|---|---|
| watch 仅 player_provider 已有 provider（currentSong/actualQuality/preview/isPlaying/shuffle/repeat/position/bufferedPosition/duration） | ✅ 无新增 provider、无自行构造 Repository |
| 评论入口 → `context.push('/comments/song/<albumAudioId>')` → CommentsPage | ✅ 已接回且无条件可达 |
| MV → `/mv/:hash?videoId&title&artist`（hash=bestHash??sdHash??videoId） | ✅ 保留 |
| 下载 → showDownloadSheet(context, Song)；收藏 → showAddToPlaylistSheet(TrackRef{name,hash,albumId,albumAudioId}) | ✅ 签名逐字段核对 playlist_repository.dart:544 |
| 队列 → showQueueSheet；进度拖动本地值松手 seek；Hero tag 'album-art'（与 mini_player 共享） | ✅ 保留 |
| 引擎错误横幅（V37-PLAY-03）读 `audioHandlerProvider.engineError` | ✅ 保留 |

## l10n
新文案全部复用既有 11 语言键（closePlayer/nowPlaying/moreActions/addToPlaylist/download/
playQueue/comments/playMv/showCover/showLyrics/notPlaying/unknownArtist/previewOnly/
shuffle/previous/next/pause/play/repeatOne/repeat/retry/goHome），**零新增键**，故无需改 ARB。
已重跑 `python3 tool/gen_l10n_min.py`（345 键 × 11 locale，GEN_OK）确认生成器一致。

## dart analyze（逐文件，Dart SDK /opt/dart/bin）
| 文件 | 结果 |
|---|---|
| lib/features/player/presentation/full_player_page.dart | ✅ 无项目自有类错误。326 条均为 Flutter/riverpod/go_router/just_audio/cached_network_image 五个 URI 不可解析的级联噪音（undefined_identifier/undefined_method/undefined_class 等，与本文件改动前基线 242 条同源；本沙箱无 Flutter SDK 与 pub-cache，属任务书预期的噪音）。自有类（Song/KrcLyric/TrackRef/MvInfo/LyricView/EmptyState/showDownloadSheet/showAddToPlaylistSheet/showQueueSheet/l10n 扩展）零报错 |

仅触碰此一个文件（mini_player/queue_sheet/评论页/评论仓库/player_provider/audio_handler/
models/lyric 全套为契约核对只读文件，均未改动）。

## 未做项与原因
- 未改 mini_player/queue_sheet/comments_page 等：归代理③（任务书分工），本轮仅完整阅读核对契约。
- 未新增 l10n 键：现有 345 键已覆盖重写全部用户可见文案。
- 未跑 dart pub get / flutter 命令：任务书禁止（ARM 无 Flutter SDK）。
- 未 commit/push：任务书禁止。
