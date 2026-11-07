# v4.0 代理 A 修复报告（实时落盘，V400-A-xx）

基线 afbe6a6。冻结契约 + QUALITY_STANDARD 已完整阅读。

## V400-A-01 引用面确认（A1 前置）
- 完整 file_read：full_player_page.dart(831 行)、mv_player_page.dart(603 行)、queue_sheet.dart(184 行)、song_tile.dart(221 行)、lyric_view.dart(294 行)、lyric_repository.dart(285 行)、krc_parser.dart(304 行)、translate_api.dart(75 行)、app_zh_CN.arb(617 行)、11 个 arb 目标键全量列出。
- 按钮类键引用确认（Text/label/tooltip）：
  - `addToPlaylist` → full_player_page.dart:263(PopupMenuItem)/457(OutlinedButton label)/461(登录守卫 action 参数)、search_page.dart:589(label)、add_to_playlist_sheet.dart:172(标题)。作按钮 label，需精简。
  - `mvCollectAdd`/`mvCollectRemove` → mv_player_page.dart:363-364(IconButton tooltip) 与 249/258(Toast 拼接)。按钮 tooltip 需精简；258 行是错误 Toast 前缀「收藏 MV：异常」，精简为「收藏」后语义仍通。
  - `downloadMv`/`downloadLyric`/`downloadCover`/`downloadSong` → download_sheet.dart:88-104（下载弹层条目 title，属按钮/可点条目），需精简。
  - `showCover`/`showLyrics` → full_player_page.dart:611-612（TextButton label），需精简。
  - `playAll` → rank_detail_page/album_page/artist_page/playlist_detail_page 的按钮 label，需精简。
  - `playMv` → full_player_page.dart:486（按钮 label），「播放 MV」→「MV」。
  - `comments`/`comment` 保持；`collectResultUnknown`/`loginRequiredHint` 不动（非按钮）。
- `downloadCover`/`downloadSong`/`downloadCoverLabel`/`downloadLyricLabel`/`downloadMvLabel` 同类按钮，一并精简（任务书「逐个精简所有实际用作按钮的键」）。

## V400-A-02 i18n 文案精简（已完成）
- 改动 11 键 × 11 语言 = 121 处值；键集 362 不变，逐文件 JSON 解析通过：
  - `addToPlaylist` 添加到歌单→收藏 / Save / Merken / 保存 / 담기 …
  - `mvCollectAdd` 收藏 MV→收藏；`mvCollectRemove` 取消收藏→取消（与 `favorite`=收藏 同词，按钮有红心图标区分，文案不再写「MV」保持 2 字）
  - `downloadMv` 下载 MV→MV、`downloadLyric` 下载歌词→歌词、`downloadCover` 下载封面→封面、`downloadSong` 下载歌曲→歌曲（同为下载弹层条目 title，一并精简）
  - `showCover` 查看封面→封面、`showLyrics` 查看歌词→歌词（切换按钮，图标已示意含义）
  - `playAll` 播放全部→全播、`playMv` 播放 MV→MV
- 未动：`comments`/`comment`（已短）、`collectResultUnknown`、`loginRequiredHint`（非按钮）。
- `python3 tool/gen_l10n_min.py` 输出：`wrote lib/l10n/app_localizations.dart: 362 keys, 11 locales`
- 说明：11 个 arb 均以 `json.dump(indent=2)` 保序写回（只改值），生成器离线脚本不受影响。

## V400-A-03 歌词翻译实时插入（已完成）
- `lyric_view.dart`（V400-A-03）：
  - 新增可选参数 `lyricId` / `songHash`（不破坏既有调用）。
  - initState 订阅 `LyricTranslationStream.instance.patches`（冻结契约，B 实现，未自造 stream）；`_onTranslationPatch` 按批写入 `line.translation` 后仅 setState 一次（插入而非整页重建等待）。
  - 世代校验（原则 18）：`songHash`（切歌必变）+ `lyricId`（candidate.id）双键匹配，越界/空译文/已有译文行跳过；换词 didUpdateWidget 同步 `_boundLyric`/`_boundSongHash`。
  - dispose 对称 cancel 订阅（原则 20）；build 零副作用；插入不动滚动位置（`_scrollTo` 仅由行号变化触发，`_estimateLineHeight` 译文分支自然生效）。
  - 双语模式译文 fontSize 14→12；纯译文模式同步 12。
- `full_player_page.dart`（V400-A-04）：
  - `currentLyricProvider` record 增加 `lyricId`（candidate.id）与 `songHash`（原则 18：翻译 await 后校验当前歌曲 hash，切歌即作废本次结果）；`_CoverOrLyric` 把两值透传 LyricView。未改任何 UI 结构。

## V400-A-05 analyze 逐文件报告（dart analyze，Flutter/三方符号报错为预期噪音）
| 文件 | issues | 项目自有类错误 |
|---|---|---|
| lib/features/lyric/presentation/lyric_view.dart | 86 | 0（全部 material.dart 缺失引发的 Flutter 符号噪音） |
| lib/features/player/presentation/full_player_page.dart | 329 | 0（同上；基线 afbe6a6 同文件本就有 ConsumerState/AnimationController 等同类报错） |
| lib/features/mv/presentation/mv_player_page.dart | 251 | 0（video_player/flutter 符号噪音，本批未改此文件逻辑） |
| lib/features/player/presentation/queue_sheet.dart | 61 | 0 |
| lib/core/widgets/song_tile.dart | 55 | 0 |
| lib/features/lyric/data/lyric_repository.dart | 6 | 0（flutter/foundation + debugPrint 噪音） |
| lib/features/lyric/data/krc_parser.dart | 2 | 0 |
| lib/core/api/translate_api.dart | 5 | 0（dio 缺失噪音 + 既有 dead_code 警告，非本批引入） |
- 专项核查：`LyricTranslationStream/LyricTranslationPatch/lyricId/songHash/KrcLyric/currentLyricProvider` 相关 0 error。
- 本批未使用任何 Icons.* 新常量（无 v3.9.10 类图标风险）；flutter/material 缺失属沙箱无 SDK 的预期噪音。

## V400-A-06 gen_l10n 输出
```
wrote /var/minis/workspace/TiernanMusic/lib/l10n/app_localizations.dart: 362 keys, 11 locales
```
11 个 arb 逐文件 `json.load` 解析通过、非 @ 键数均 362 不变。

## V400-A-07 未做项与原因
- 未改 UI 结构（用户明确要求）；mv_player_page/queue_sheet/song_tile 本批零改动（文案精简全部落在 arb 值，无需改代码）。
- 未装 Flutter SDK / pub get / 动 pubspec（契约纪律）。
- 禁 git commit/push，全部改动留在工作区。
- 过程说明：中途 stash/恢复与代理 B 实时落盘发生过一次冲突，已用 `git checkout stash -- <A 独占文件>` 恢复 A 文件并 drop stash，B 文件（lib/core/resource/**、各 repository）未受影响；恢复后已完整复读 lyric_view.dart 与 full_player_page.dart 核对无损伤。

