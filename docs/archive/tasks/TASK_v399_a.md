# v3.9.9 任务书 A：播放页收藏/歌词缓存/翻译自动化（修复代理）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）与 `docs/PROGRESS.md` 末段。

## ⚠️ 硬性规则（违反即失败）
- **绝对禁止**：装 Flutter SDK / flutter 命令 / dart pub get / 下载任何 SDK / 改 pubspec.yaml 一行（本沙箱 ARM64 无 Flutter，上一代理因此被取消）
- 只允许 `dart analyze`（/opt/dart/bin）；Flutter/三方符号报错是预期噪音，**项目自有类报错即真错误**
- **触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**
- 跨文件改动双向核对；禁 git commit/push；只用 file_edit；改动标 `V399-xx` 编号
- i18n 新键 11 语言全补 + 重跑 `python3 tool/gen_l10n_min.py` 贴输出
- 只使用项目内已存在且已读定义确认签名的类/方法；禁止猜 API
- 报告 `docs/v399_fix_a.md` **实时落盘**

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `755dcea`

## 任务一：播放页收藏功能（V399-A1，P1）
用户反馈播放页没有收藏到歌单的可达入口。现状：`add_to_playlist_sheet.dart` 已有弹层实现（含 `_createAndAdd` 基线快照逻辑），但入口只有搜索结果的 SongTile 菜单。
- 完整 file_read：`full_player_page.dart`、`add_to_playlist_sheet.dart`、`playlist_repository.dart`（TrackRef/collectPlaylist/addTracks 签名）、`player_provider.dart`
- 在播放页功能入口行（`_EntryButtonsRow`）加「收藏到歌单」按钮：用当前 `currentSongProvider` 的 song 构造 TrackRef（hash/albumId/albumAudioId 从 Song 字段取，先读 models.dart 确认字段名与单位），调 `showAddToPlaylistSheet(context, trackRef)`
- 未登录先走 login_guard（现有 ensureLoggedIn 模式，先读定义）
- l10n：新增键 11 语言全补（如无复用 addToPlaylist 键）

## 任务二：歌词接入缓存（V399-A2，P1）
用户反馈歌词每次都拉网络。现状：`lyric_repository.dart` 有 MemoryCache 但歌词可能没接。
- 完整 file_read：`lyric_repository.dart`、`cache_manager.dart`、`krc_parser.dart`
- 歌词（KRC/LRC）与翻译结果接入持久缓存（Hive，参照 lyric_translations 箱模式）：key=id:lang 或 id:kind，TTL 参照 cache_manager 既有策略
- 缓存命中不发网络；网络失败时若有旧缓存返回旧值并标注（降级可观测，第 9/16 条）

## 任务三：翻译自动化+翻译缓存（V399-A3，P1）
用户要求「翻译启用自动化，非必要不翻译，翻译缓存」。
- 语义：**已有译文缓存/上游自带翻译（内嵌 language）时绝不调翻译 API**；只对「无任何译文」的歌词自动翻译；翻译结果必须入持久缓存（已有 lyric_translations 箱，核对 key 是否含模型维度——B-29 已修）
- 完整 file_read：`translate_api.dart`、`lyric_repository.dart`、`cache_manager.dart`
- 落地：翻译触发前查持久缓存 → 命中直接用；未命中且歌词含上游译文 → 直接用上游；都无 → 调 API 并写缓存
- 批量翻译沿用现有条数防御（V34-03）

## 完成后
报告末尾 8 行内汇报：V399-A1/A2/A3 各自改动、analyze 逐文件结果、l10n 输出、未做项原因。
