# 第5批·审查③：UI/状态/发布合规复核（v3.0 终审 C 视角）

## ⚠️ 硬性规则（违反任一 = 任务失败）
1. 先完整读 `docs/QUALITY_STANDARD.md`（32 条原则）。每条结论标注「违反第 N 条」。
2. 只允许**完整 file_read** + Dart SDK 文档。
3. **禁止**：grep/rg 筛代码、编译、跑测试、装包、clone、修改代码、git 操作。
4. 允许 `dart analyze`（`export PATH=$PATH:/opt/dart/bin`），过滤缺包噪音。
5. **禁止读 docs/batch1~4_*、docs/check_*、docs/review_b*_*.md**。可读：QUALITY_STANDARD.md、REVIEW_SPEC.md、api_verified.md、本任务书。
6. **实时落盘**到 `docs/v3_review_b1_ui.md`。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `bc4a521`（tag v3.0.0）

## 报告文件
`docs/v3_review_b1_ui.md`

## 范围（逐个完整读）
1. `pubspec.yaml`（版本 3.0.0+30、依赖声明完整性）
2. `lib/main.dart`
3. `lib/core/router/app_router.dart`
4. `lib/core/providers.dart`
5. `lib/core/config/app_config.dart`
6. `lib/core/widgets/` 全部文件（先 ls 清单）
7. `lib/features/auth/presentation/login_page.dart`
8. `lib/features/auth/presentation/captcha_page.dart`
9. `lib/features/settings/presentation/settings_page.dart`
10. `lib/features/settings/presentation/settings_providers.dart`
11. `lib/features/library/presentation/library_page.dart`
12. `lib/features/player/presentation/full_player_page.dart`
13. `lib/features/player/presentation/mini_player.dart`
14. `lib/features/player/presentation/queue_sheet.dart`
15. `lib/features/download/presentation/download_page.dart`
16. `lib/features/download/presentation/download_sheet.dart`
17. `lib/l10n/app_zh.arb` + 抽查 `app_en.arb`、`app_ja.arb`（键完整性抽查）
18. `lib/features/comment/presentation/comments_page.dart`
19. `lib/features/search/presentation/search_page.dart`

## 复核重点
A. **发布合规**：版本号 3.0.0+30 一致性；`.arb` 键在 10 语言是否齐全（抽查缺失即 P1，l10n 生成会失败）；
   依赖声明（pubspec 的 dependencies 是否覆盖全部 import 的 package）。
B. **生命周期**（第 20 条）：dispose/Timer/Subscription/mounted 全量核对。
C. **状态刷新**：ref.watch vs read、登录态变化传播。
D. **布局**：Row 溢出、Flexible/ellipsis、字体放大适配。
E. **i18n**：硬编码中文（第 30 条：用户可见文案必须走 l10n）。
F. **死代码**（第 32 条）：未使用 import/widget/provider。
G. **触控目标与可访问性**：48dp、对比度。
H. **路由**：参数校验、深链兜底。

## 落盘格式
级别/事实/违反条款/后果。末尾问题清单 + 统计表。完成后 5 行内汇报。
