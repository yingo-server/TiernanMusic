# 第4批·修复③：UI/UX 与合规打包（版本 3.0.0 LTS）

## 角色
你是**修复代理**。按报告逐条改代码，不重新审查、不扩大范围。

## 绝对禁止
- 禁止下载 Flutter/Dart SDK、禁止装包、禁止 git clone、禁止构建、禁止跑测试、禁止起 Node/kapi
- 禁止 git commit / git push / 禁止打 tag（主代理统一做）
- 禁止修改 `lib/core/direct/**`（网络层）和 `lib/features/*/data/**`（另一代理负责）
- 禁止改动与本任务无关的文件

## 工作目录
`/var/minis/workspace/TiernanMusic`

## 输入报告（先完整读）
1. `docs/batch4_review_3_ui_b.md`（音乐库/设置/认证/歌单/评论/下载/路由/组件）
2. `docs/batch4_review_3_ui.md`（首页/搜索/播放器）

## 目标文件（只改这些）
- `lib/features/library/presentation/library_page.dart`
- `lib/features/settings/presentation/settings_page.dart`
- `lib/features/settings/presentation/settings_providers.dart`
- `lib/features/auth/presentation/login_page.dart`
- `lib/features/auth/presentation/captcha_page.dart`
- `lib/features/playlist/presentation/playlist_detail_page.dart`
- `lib/features/comment/presentation/comments_page.dart`
- `lib/features/comment/presentation/comment_floor_page.dart`
- `lib/features/download/presentation/download_page.dart`
- `lib/features/download/presentation/download_sheet.dart`
- `lib/features/home/presentation/home_page.dart`
- `lib/features/search/presentation/search_page.dart`
- `lib/features/player/presentation/*.dart`（full_player_page / mini_player / queue_sheet）
- `lib/core/router/app_router.dart`
- `lib/core/widgets/*.dart`
- `lib/l10n/*.arb`（10 语言）

## 优先修（P1 + 高价值 P2）
1. 生命周期：`dispose` 缺失、`Timer`/`StreamSubscription` 未取消、异步回调后无 `mounted` 检查
2. 状态刷新：`ref.watch` vs `ref.read` 误用、登录态变化后 UI 不更新
3. 布局溢出：`Row` 缺 `Flexible`/`Expanded`、长文案无 `ellipsis`（`queue_sheet.dart:44-53` 已知）
4. i18n：硬编码中文用户可见文案 → 全部走 `context.l10n`，10 个 `.arb` 同步补键
5. 错误态：失败无重试入口、原始异常拼进 Toast（`playlist_detail_page.dart:404-412` 已知）
6. 队列缺失操作：`queue_sheet.dart` 无「移除单曲 / 清空队列」→ 补上
7. `mini_player.dart` 高度跳变无 `AnimatedSize` 过渡
8. 死代码：`_tracksReloadProvider` 无写入方 → 清理
9. 硬编码色值 → 走 Material 3 色 token

## 版本升级到 3.0.0 LTS（必做）
- `pubspec.yaml`：`version: 2.0.0+1` → `3.0.0+30`
- `lib/core/config/app_config.dart` 若有版本常量同步改
- 设置页「关于」显示的版本号走 `package_info_plus` 则无需改
- **不要**改 `docs/keystore_setup.md`、不要动 `.github/workflows/*`

## 修复要求
- 每处改动前先 `file_read` 完整读该文件
- 每处改动加注释编号：`// F4-31（审查③-B，P1）：<一句话>`
- 只用 `file_edit` 工具改，不要用 sed/python
- `.arb` 补键时 10 个语言全部补齐，缺一个都会导致 l10n 生成失败
- 改动必须能编译

## 报告
改完写 `docs/batch4_fix_3_ui.md`：逐条列「编号 / 文件:行 / 改了什么」。未修的写明原因。

完成后 5 行内汇报：修了几条，哪些没修及原因。
