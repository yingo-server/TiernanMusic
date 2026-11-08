# v5.1 交叉审查·第 B4 批（3 代理并行 · 范围一次读完不重复）

先完整读 `docs/TASK_v51_cross_common.md`（通用规范）与 `docs/QUALITY_STANDARD.md`（33 条原则）。

## 本批范围（43 文件 / 9550 行）
  - lib/app/bootstrap.dart  ✅（本代理通读）
  - lib/app/di.dart  ○（跨文件契约抽查）
  - lib/app/router.dart  ○（跨文件契约抽查）
  - lib/core/audio/audio_service_bootstrap.dart  ✅（本代理通读）
  - lib/core/audio/preferred_quality.dart  ○（跨文件契约抽查）
  - lib/core/image/app_image_cache.dart  ○（跨文件契约抽查）
  - lib/core/theme/app_theme.dart  ✅（本代理通读）
  - lib/core/theme/settings_provider.dart  ○（跨文件契约抽查）
  - lib/core/utils/error_logger.dart  ○（跨文件契约抽查）
  - lib/core/utils/friendly_error.dart  ✅（本代理通读）
  - lib/core/utils/permission_gate.dart  ○（跨文件契约抽查）
  - lib/core/utils/toast.dart  ○（跨文件契约抽查）
  - lib/core/utils/update_checker.dart  ✅（本代理通读）
  - lib/core/widgets/confirm_dialog.dart  ○（跨文件契约抽查）
  - lib/core/widgets/empty_state.dart  ○（跨文件契约抽查）
  - lib/core/widgets/error_retry.dart  ✅（本代理通读）
  - lib/core/widgets/gradient_chip.dart  ○（跨文件契约抽查）
  - lib/core/widgets/list_skeleton.dart  ○（跨文件契约抽查）
  - lib/core/widgets/section_header.dart  ✅（本代理通读）
  - lib/core/widgets/shimmer.dart  ○（跨文件契约抽查）
  - lib/core/widgets/song_tile.dart  ○（跨文件契约抽查）
  - lib/core/widgets/splash_handwriting.dart  ✅（本代理通读）
  - lib/core/widgets/splash_screen.dart  ○（跨文件契约抽查）
  - lib/features/home/data/home_repository.dart  ○（跨文件契约抽查）
  - lib/features/home/data/models.dart  ✅（本代理通读）
  - lib/features/home/presentation/home_page.dart  ○（跨文件契约抽查）
  - lib/features/lyric/data/krc_decoder.dart  ○（跨文件契约抽查）
  - lib/features/lyric/data/krc_parser.dart  ✅（本代理通读）
  - lib/features/lyric/data/lyric_repository.dart  ○（跨文件契约抽查）
  - lib/features/lyric/presentation/lyric_view.dart  ○（跨文件契约抽查）
  - lib/features/mv/data/mv_collection_repository.dart  ✅（本代理通读）
  - lib/features/mv/data/mv_repository.dart  ○（跨文件契约抽查）
  - lib/features/mv/mv_provider.dart  ○（跨文件契约抽查）
  - lib/features/mv/presentation/mv_player_page.dart  ✅（本代理通读）
  - lib/features/player/data/audio_handler.dart  ○（跨文件契约抽查）
  - lib/features/player/data/player_repository.dart  ○（跨文件契约抽查）
  - lib/features/player/play_helper.dart  ✅（本代理通读）
  - lib/features/player/player_provider.dart  ○（跨文件契约抽查）
  - lib/features/player/presentation/full_player_page.dart  ○（跨文件契约抽查）
  - lib/features/player/presentation/mini_player.dart  ✅（本代理通读）
  - lib/features/player/presentation/queue_sheet.dart  ○（跨文件契约抽查）
  - lib/features/rank/data/rank_repository.dart  ○（跨文件契约抽查）
  - lib/features/rank/presentation/rank_detail_page.dart  ✅（本代理通读）

## 分工（**避免三个代理重复读同一文件**）
三个代理**视角不同、文件侧重不同**：
- 视角 A（功能正确性）：播放/歌词/首页/榜单/MV 的**数据流与契约**（model 字段、provider 依赖、状态机）
- 视角 B（鲁棒与质量）：鲁棒性：异常契约、资源申请/释放对称、并发与世代、边界值、死代码
- 视角 C（用户路径与一致性）：用户路径：真实操作序列的断点（进入→操作→反馈）、空/加载/失败三态、可观测性

每人**通读自己负责的文件子集**（上面清单已按你的子集标注 ✅/○），
并对**其余文件**只做「跨文件契约抽查」（≤8 个文件，读定义签名与调用点即可）。
三份报告由主代理合并裁决。

## 已审条目索引（**不要重复报告**）
`docs/v51_cross_b1_merged.md`、`b2_merged.md`、`b3_merged.md`、
以及 `docs/v51_cross_b3_b.md`、`b3_c.md`。
读它们只为「不要重复报」，**不得据此改代码、不得照抄其结论**。

## 交付
1. 报告落盘 `docs/v51_cross_B4_a.md`（视角A），**实时逐文件 append**。
2. 每条问题：级别 / 违反第 N 条 / 代码事实 / 用户可见后果 / 证据等级（静态推演或已实测）。
3. 逐文件 `dart analyze` 结果贴进报告（过滤 Flutter/三方包缺失噪音后**项目自有类 0 错误**为合格）。
4. 禁止：装 SDK、pub get、构建、测试、起服务、改 pubspec/Manifest/Kotlin、git commit。
5. 禁止读 B1–B3 的**视角报告正文**（只读 merged 索引）；禁止读其他批次的报告。
