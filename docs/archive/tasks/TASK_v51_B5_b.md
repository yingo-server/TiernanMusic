# v5.1 交叉审查·第 B5 批（3 代理并行 · 范围一次读完不重复）

先完整读 `docs/TASK_v51_cross_common.md`（通用规范）与 `docs/QUALITY_STANDARD.md`（33 条原则）。

## 本批范围（34 文件 / 11583 行）
  - lib/features/album/data/album_repository.dart  ○（跨文件契约抽查）
  - lib/features/album/presentation/album_page.dart  ✅（本代理通读）
  - lib/features/artist/data/artist_repository.dart  ○（跨文件契约抽查）
  - lib/features/artist/presentation/artist_page.dart  ○（跨文件契约抽查）
  - lib/features/auth/data/account_manager.dart  ✅（本代理通读）
  - lib/features/auth/data/auth_providers.dart  ○（跨文件契约抽查）
  - lib/features/auth/data/auth_repository.dart  ○（跨文件契约抽查）
  - lib/features/auth/data/captcha_types.dart  ✅（本代理通读）
  - lib/features/auth/data/slider_solver.dart  ○（跨文件契约抽查）
  - lib/features/auth/data/verification_service.dart  ○（跨文件契约抽查）
  - lib/features/auth/presentation/captcha_page.dart  ✅（本代理通读）
  - lib/features/auth/presentation/login_guard.dart  ○（跨文件契约抽查）
  - lib/features/auth/presentation/login_page.dart  ○（跨文件契约抽查）
  - lib/features/auth/presentation/verification_guard.dart  ✅（本代理通读）
  - lib/features/auth/presentation/verification_listener.dart  ○（跨文件契约抽查）
  - lib/features/comment/data/comment_repository.dart  ○（跨文件契约抽查）
  - lib/features/comment/presentation/comment_floor_page.dart  ✅（本代理通读）
  - lib/features/comment/presentation/comments_page.dart  ○（跨文件契约抽查）
  - lib/features/download/data/download_repository.dart  ○（跨文件契约抽查）
  - lib/features/download/data/download_store.dart  ✅（本代理通读）
  - lib/features/download/data/download_task.dart  ○（跨文件契约抽查）
  - lib/features/download/data/public_media_store.dart  ○（跨文件契约抽查）
  - lib/features/download/download_provider.dart  ✅（本代理通读）
  - lib/features/download/presentation/download_page.dart  ○（跨文件契约抽查）
  - lib/features/download/presentation/download_sheet.dart  ○（跨文件契约抽查）
  - lib/features/library/data/recent_play_store.dart  ✅（本代理通读）
  - lib/features/library/presentation/library_page.dart  ○（跨文件契约抽查）
  - lib/features/playlist/data/playlist_repository.dart  ○（跨文件契约抽查）
  - lib/features/playlist/presentation/add_to_playlist_sheet.dart  ✅（本代理通读）
  - lib/features/playlist/presentation/playlist_detail_page.dart  ○（跨文件契约抽查）
  - lib/features/search/data/search_repository.dart  ○（跨文件契约抽查）
  - lib/features/search/presentation/search_page.dart  ✅（本代理通读）
  - lib/features/settings/presentation/settings_page.dart  ○（跨文件契约抽查）
  - lib/features/settings/presentation/settings_providers.dart  ○（跨文件契约抽查）

## 分工（**避免三个代理重复读同一文件**）
三个代理**视角不同、文件侧重不同**：
- 视角 A（功能正确性）：认证/下载/歌单/评论/搜索/歌手/专辑/设置/音乐库的**功能与契约**
- 视角 B（鲁棒与质量）：鲁棒性：并发写防重、缓存与失效、异常与降级、权限与存储边界、死代码
- 视角 C（用户路径与一致性）：用户路径：登录→切号→下载→收藏→评论全流程的断点与反馈、三态分离

每人**通读自己负责的文件子集**（上面清单已按你的子集标注 ✅/○），
并对**其余文件**只做「跨文件契约抽查」（≤8 个文件，读定义签名与调用点即可）。
三份报告由主代理合并裁决。

## 已审条目索引（**不要重复报告**）
`docs/v51_cross_b1_merged.md`、`b2_merged.md`、`b3_merged.md`、
以及 `docs/v51_cross_b3_b.md`、`b3_c.md`。
读它们只为「不要重复报」，**不得据此改代码、不得照抄其结论**。

## 交付
1. 报告落盘 `docs/v51_cross_B5_b.md`（视角B），**实时逐文件 append**。
2. 每条问题：级别 / 违反第 N 条 / 代码事实 / 用户可见后果 / 证据等级（静态推演或已实测）。
3. 逐文件 `dart analyze` 结果贴进报告（过滤 Flutter/三方包缺失噪音后**项目自有类 0 错误**为合格）。
4. 禁止：装 SDK、pub get、构建、测试、起服务、改 pubspec/Manifest/Kotlin、git commit。
5. 禁止读 B1–B3 的**视角报告正文**（只读 merged 索引）；禁止读其他批次的报告。
