# v3.4 迭代任务书·第 4 批（审查②）：UI 专档——细节处理与易用性

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条，含第九章第 33 条：kapi 返回不可作原生实测依据）。

## ⚠️ 硬性规则
1. 只允许完整 file_read（逐行首到末）+ Dart SDK 文档
2. 禁编译/测试/装包/clone/修改代码/git 操作；巡检类 grep 需说明
3. 允许 dart analyze（`export PATH=$PATH:/opt/dart/bin`），过滤缺 Flutter 包噪音；**新增 Flutter 符号必须核对 import 头**（v3.2.1 P0 教训）
4. 禁读 v34 之前旧报告正文（可读问题清单段落 + QUALITY_STANDARD/PROGRESS/TASK_v33_*/v33_*）
5. 实时落盘：读完一个文件立刻 append 到本任务报告

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `ac188b2`（tag v3.3.0）

## 报告文件
**`docs/v34_review_2_ui.md`**

## 本档定位
用户要求：**UI 单开一档，包括细节处理和易用性**。本档不看数据层/网络层，专审用户看得见摸得着的一切。

## 范围（逐个完整读，共 ~20 文件；core/widgets 先 ls 清单再逐个读）
1. `lib/features/player/presentation/full_player_page.dart`
2. `lib/features/player/presentation/mini_player.dart`
3. `lib/features/player/presentation/queue_sheet.dart`
4. `lib/features/lyric/presentation/lyric_view.dart`
5. `lib/core/widgets/splash_screen.dart` + `splash_handwriting.dart`（新手写动画）
6. `lib/features/home/presentation/home_page.dart`
7. `lib/features/search/presentation/search_page.dart`
8. `lib/features/library/presentation/library_page.dart`
9. `lib/features/playlist/presentation/playlist_detail_page.dart`
10. `lib/features/comment/presentation/comments_page.dart`
11. `lib/features/comment/presentation/comment_floor_page.dart`
12. `lib/features/download/presentation/download_page.dart`
13. `lib/features/download/presentation/download_sheet.dart`
14. `lib/features/settings/presentation/settings_page.dart`
15. `lib/features/auth/presentation/login_page.dart`
16. `lib/features/auth/presentation/captcha_page.dart`
17. `lib/core/router/app_router.dart`（过渡动画/手势返回）
18. `lib/l10n/app_zh.arb` 抽查 + `app_en.arb`（文案质量而非键齐全性——键齐全性已验收过）

## 审查维度（易用性为本档特色，不套旧模板）

### A. 细节处理
- 手势：边缘滑动、长按、双击有没有该有的反馈；dismissible 方向是否合理
- 动效：页面切换时长/曲线一致性；列表项点击水波纹是否全员有；AnimatedSwitcher 的 key 稳定性
- 微文案：按钮用动词还是名词；错误提示是否给出下一步动作（「重试」vs 干巴巴的错误码）；数量文案的单复数
- 触控目标：IconButton 是否 ≥48dp；相邻可点元素间距（误触面）
- 滚动边界：OverScrollGlow/BouncingPhysics 在列表内的统一性

### B. 易用性（用户任务流视角，走一遍真实任务）
1. 「搜索一首歌 → 播放 → 收藏到歌单」全程点击数与反馈点
2. 「下载一首歌 → 文件管理器找到它」的目录提示是否清晰
3. 「登录 → 看歌单 → 切账号」的登录态感知（哪里知道自己是哪个号）
4. 「MV 观看 → 收藏 MV」入口可达性
5. 空态文案是否告诉用户「怎么会有内容」（而不只是「暂无数据」）
6. 设置页每项的可发现性（开关意义不明处标出）

### C. 视觉一致性
- 同类信息的展示密度（播放页 vs 搜索页的歌单行）
- 颜色 token：是否有硬编码色绕过主题
- 图标语义：同动作不同图标/同图标不同动作
- 亮暗主题切换的边界（AppBar、Dialog、Toast、Sheet 四处）

### D. 新改动回归
- 手写动画在「快速双击返回/立刻切深链」下的行为
- 歌单/库页刷新修复后的实际体验（登录→进库页，是否秒出）
- MV 缩略图选档后清晰度是否够（320 是否过糊）

## 落盘格式
```
### <文件>:<行> <标题>
- 级别：P1/P2/P3
- 事实：<代码/交互描述>
- 违反：QUALITY_STANDARD 第 N 条（或「易用性：用户任务流 X」）
- 后果：<用户可见>
```

## 统计与产出
末尾：问题清单按级别 + 「易用性任务流走查表」（任务/点击数/断点/反馈缺失）。
完成后 5 行内汇报：总数/最高优先的 3 条/任务流走查结论。
