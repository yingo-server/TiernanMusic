# 第4批·审查③-续：音乐库/设置/认证/歌单/评论/下载/路由与组件（只读）

先完整读 `/var/minis/workspace/TiernanMusic/docs/REVIEW_SPEC.md`，其「绝对禁止」「工作方式」「本项目既定口径」全部适用，违反任一条即任务失败。

## 背景
上一轮已审完 home_page / search_page / 播放器三页（full_player_page、mini_player、queue_sheet），成果在 `docs/batch4_review_3_ui.md`。**不要重写那个文件，也不要重审已覆盖页面。** 本轮审下列剩余文件，写入新文件。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `6e46611`

## 关键前提（本轮新增，务必落实·最高优先级）
**所有接口必须优先使用酷狗原生网关，禁止以 kapi 中转（kapi.344977.xyz）作为实现。** UI 层不得出现任何 kapi 痕迹：
- 检查 UI / provider / repository 是否有硬编码的 `kapi.344977.xyz` 或经 `AppConfig.kugouApiBase` 拼接的地址出现在非兜底位置
- 检查页面是否对「kapi 回退成功」与「直连成功」有不同处理（应无差异）
- 发现 UI 或 provider 层绕过 `data/` 直接发请求 → 记为问题（违反分层）

## 报告文件
**`docs/batch4_review_3_ui_b.md`**（每读完一个文件立刻 append；禁止读完全部再统一写）

## 范围（逐个 file_read 完整读，禁止 grep）
1. `lib/features/library/presentation/library_page.dart`
2. `lib/features/settings/presentation/settings_page.dart`
3. `lib/features/settings/presentation/settings_providers.dart`
4. `lib/features/auth/presentation/login_page.dart`
5. `lib/features/auth/presentation/captcha_page.dart`
6. `lib/features/playlist/presentation/playlist_detail_page.dart`
7. `lib/features/comment/presentation/comments_page.dart`
8. `lib/features/comment/presentation/comment_floor_page.dart`
9. `lib/features/download/presentation/download_page.dart`
10. `lib/features/download/presentation/download_sheet.dart`
11. `lib/core/router/app_router.dart`
12. `lib/core/widgets/` 目录下所有文件（先 `ls` 看清单，再逐个完整读）

## 核对重点
A. 交互可达性：每个入口是否真能到达（被 early return 吞掉、条件判断写反、按钮无 onPressed）
B. 状态刷新：`ref.watch` vs `ref.read` 误用、登录态变化后 UI 不更新、Provider 依赖链断开
C. 生命周期：dispose、Timer、StreamSubscription、`mounted` 检查、异步回调后 setState
D. 布局健壮性：固定高度 + 字体放大、横向溢出 Row、长文案无 ellipsis/Flexible
E. i18n：硬编码中文用户可见文案、10 语言键缺失或漏用
F. 错误态：失败有无重试入口、空态/加载态是否区分、错误信息是否泄露技术细节
G. Material 3：控件选型、色 token（避免硬编码色值）、触控目标 ≥48dp、对比度
H. 路由：深链参数校验、不存在路由的兜底、返回栈异常

## 落盘格式
```
### <文件>:<行号> 简述
- 级别：P1/P2/P3
- 依据：<代码片段>
- 影响：<用户可见后果>
```
末尾追加「问题清单」按 P1/P2/P3 排序。不改代码、不跑构建。完成后 3 行内汇报问题数。
