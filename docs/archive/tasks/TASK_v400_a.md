# v4.0 代理 A：文案精简 + 歌词翻译实时插入（只读契约 + 改 4 类文件）

先完整读 `docs/TASK_v400_arch.md`（跨代理冻结契约）、`QUALITY_STANDARD.md`（33 条）。

## 角色与文件边界（严禁越界）
独占：`lib/l10n/app_*.arb`（**只改值，不改键/结构**）、`lib/features/lyric/presentation/lyric_view.dart`、`lib/features/player/presentation/full_player_page.dart`（仅文案引用）、`lib/features/mv/presentation/mv_player_page.dart`（仅文案引用）。
**不改 UI 结构**（用户明确：只改文字）、不改 `lib/core/resource/**`、`lib/core/prefetch/**`、`main.dart`、任何 repository。

## ⚠️ 共同纪律（见契约）
ARM64 无 Flutter：禁装 SDK/flutter/pub get/下载 tarball；**pubspec 一行不许动**；只允许 dart analyze；Flutter/三方符号报错是预期噪音、**项目自有类报错即真错误**；Icons.* 常量必须验证存在（v3.9.10 教训）；业务文件完整 file_read 禁止 grep 筛源码；触碰文件收尾 analyze 逐文件贴报告——缺一即失败；跨文件双向核对；禁 git commit/push；只用 file_edit；标 `V400-A-xx`；报告 `docs/v400_fix_a.md` 实时落盘。

## 任务 A1：按钮文案精简（只改 arb 的**值**，11 语言同步）
用户反馈「部分按钮文字描述过多，如收藏/评论/MV 等」。逐项把值压缩为 2~4 字或图标化短词（不动 UI 控件、不动键名）：
- `addToPlaylist`: 添加到歌单 → 收藏（11 语言同义短词）
- `mvCollectAdd` / `mvCollectRemove`: 收藏 MV/取消收藏 → 收藏/取消（若与 favorite 冲突则用短词区分）
- `downloadMv`: 下载 MV → MV
- `downloadLyric`: 下载歌词 → 歌词
- `showCover`: 查看封面 → 封面
- `playAll`: 播放全部 → 全播
- `comments` / `comment`: 保持「评论」（已短）
- `collectResultUnknown`: 保留（错误提示需完整，非按钮）
- `loginRequiredHint`: 保留（说明文案非按钮）
- 先 file_read 完整读 `app_zh_CN.arb` 与全部 11 个 arb，列出**所有实际用作按钮 label 的键**（从 full_player_page/mv_player_page/queue_sheet/song_tile 的 Text(...) 引用确认），逐个精简；未作按钮的不动。
- 只改值；重跑 `python3 tool/gen_l10n_min.py` 贴输出；逐文件 JSON 校验（键集不变）。

## 任务 A2：歌词翻译实时插入 + 更小字体
用户要求「歌词加载应该很快，翻译改为实时插入且字体更小」。
- 完整 file_read：`lyric_view.dart`、`lyric_repository.dart`、`translate_api.dart`、`cache_manager.dart`
- **调用契约（冻结，B 实现）**：`LyricTranslationStream.instance.patches` 是 `Stream<LyricTranslationPatch>`，`patch.values` 是某批译文，`patch.startIndex` 是起始行号。A 只订阅，不实现模块。
- 落地：
  1) 原文歌词先秒显（不等翻译）；译文按 `patches` 事件逐批写入当前 lyric 的 `line.translation`，**插入而非整页重建后等全批**
  2) 译文 `fontSize` 从 14 降到 12（字体更小），与原文字号层次分明
  3) 译文未到的行保持原文展示，不显示占位/加载条
  4) build 零副作用；StreamSubscription 在 dispose 对称取消；滚动位置不因插入跳变
- 若 B 的模块在你运行时尚未落盘，**按冻结签名写调用即可**，不要自己造 stream（避免双实现）。

## 完成后
8 行内汇报：精简的键数与 11 语言覆盖、翻译实时插入实现、analyze 逐文件结果、gen_l10n 输出、未做项原因。
