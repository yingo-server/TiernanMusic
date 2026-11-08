# 第5批·审查②：功能链路复核（v3.0 终审 B 视角）

## ⚠️ 硬性规则（违反任一 = 任务失败）
1. 先完整读 `docs/QUALITY_STANDARD.md`（32 条原则）。每条结论必须标注「违反第 N 条」。
2. 只允许**完整 file_read** + 查阅 Dart SDK 文档。
3. **禁止**：grep/rg 筛代码、编译、跑测试、装包、clone、修改代码、git 操作。
4. 允许 `dart analyze`（`export PATH=$PATH:/opt/dart/bin`），过滤缺 Flutter 包噪音。
5. **禁止读 docs/batch1~4_*、docs/check_*、docs/review_b*_*.md**。可读：QUALITY_STANDARD.md、REVIEW_SPEC.md、api_verified.md、本任务书。
6. **实时落盘**到 `docs/v3_review_b1_function.md`，读完一个文件写一个。

## 背景
代码已多轮修复，本批是**复核**：验证修复正确性 + 找回归。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `bc4a521`（tag v3.0.0）

## 报告文件
`docs/v3_review_b1_function.md`

## 范围（逐个完整读）
1. `lib/features/player/data/audio_handler.dart`
2. `lib/features/player/data/player_repository.dart`
3. `lib/features/player/data/models.dart`
4. `lib/features/player/player_provider.dart`
5. `lib/features/player/play_helper.dart`
6. `lib/features/lyric/data/krc_parser.dart`
7. `lib/features/lyric/data/krc_decoder.dart`
8. `lib/features/lyric/data/lyric_repository.dart`
9. `lib/features/lyric/presentation/lyric_view.dart`
10. `lib/features/playlist/data/playlist_repository.dart`
11. `lib/features/playlist/presentation/playlist_detail_page.dart`
12. `lib/features/comment/data/comment_repository.dart`
13. `lib/features/search/data/search_repository.dart`
14. `lib/features/home/data/home_repository.dart`
15. `lib/features/home/data/models.dart`
16. `lib/features/mv/data/mv_repository.dart`

## 复核重点
A. **audio_handler**（重点，多轮修改）：
   - `_playToken` 世代校验是否覆盖**所有** await 后写入点
   - `_loading` 闸门是否单点释放（F4-14/15/16 修复验证）
   - `setAudioSource` 竞态：旧请求后完成是否还会覆盖新源
   - 离线→在线回退分支、试听判定、失败跳歌
B. **playlist_repository**（重点）：
   - `_write` 防重锁 `_inFlight` 的正确性（Set 并发 add/remove 时序）
   - `PlaylistWriteException.maybeSucceeded` 的分类是否与网络层异常语义一致
   - `_safeName`/`_safeId` 分隔符处理（第 14 条）
   - `collectPlaylist` 的 GET 分派注释与实际行为是否一致
C. **KRC 解析**（多轮修改）：逐字时间基准、翻译三种结构、`copyWith(localPath: null)` 语义
D. **数据模型**：毫秒/秒单位显式（第 15 条）、裸强转（第 13 条）、空集合语义（第 16 条）
E. **缓存**：key 维度完整（第 23 条）、TTL、可变对象泄露
F. **分页状态机**：刷新与加载更多竞态（第 18 条）

## 落盘格式
同第5批审查①任务书（级别/事实/违反条款/后果）。
末尾问题清单 + 统计表。完成后 5 行内汇报。
