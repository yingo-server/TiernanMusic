# v3.3 迭代任务书·第 3 批（审查①）：文件存储/播放/歌单专项复核

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（**含第九章第 33 条：kapi 返回不可作为原生网关实测依据**——kapi 经 Node 包装，实测必须直打原生域名）。

## ⚠️ 硬性规则
1. 只允许完整 file_read + Dart SDK 文档；禁 grep 审代码（巡检类 grep 除外，需说明）
2. 禁编译/测试/装包/clone/修改代码/git 操作
3. 允许 dart analyze（过滤缺包噪音；**新增 Flutter 符号必须核对 import 头**）
4. 三态实测允许（native_probe.sh 直打原生域）；kapi 返回只能对照、不能作判定依据（第 33 条）
5. 禁读本迭代之外的旧报告（可读 QUALITY_STANDARD.md、PROGRESS.md、TASK_v33_*.md、v33_fix_*.md）
6. 实时落盘到指定报告，读完一个写一个

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `defd4a4`（含 v33_fix1/2 修复）

## 报告文件
`docs/v33_review_1.md`

## 复核范围（验证第 1/2 批修复正确性，只报回归/新缺陷/修复不完整）
1. `lib/core/utils/error_logger.dart`（日志外置+B-21/B-22）
2. `lib/core/image/app_image_cache.dart`（缓存外置+字节上限）
3. `lib/features/download/data/public_media_store.dart`（目录/临时文件/清缓存）
4. `lib/core/direct/kg_endpoints_playlist.dart`（V33-01 歌单修复）
5. `lib/features/playlist/data/playlist_repository.dart`
6. `lib/features/player/data/player_repository.dart`（V33-02 播放排查结论）
7. `lib/features/player/data/audio_handler.dart`
8. `lib/core/widgets/splash_screen.dart` + `splash_handwriting.dart`（手写动画）
9. `lib/features/mv/data/mv_repository.dart`（缩略图）
10. `lib/core/utils/friendly_error.dart` + `lib/features/auth/data/`（captcha 改造）

## 复核重点
A. **存储外置回归**（第 23/25/20 条）：
   - 外置路径在 Android 10+ 的 MediaStore 与 ≤9 的直接路径两条策略下都成立？
   - 字节上限的 LRU 淘汰是否会把「正在使用」的文件删掉（竞态）？
   - 清缓存走 emptyCache 后是否有组件持有已删文件的 File 句柄？
   - 日志串行锁是否可能死锁（同步锁内做 IO）？
B. **歌单修复**（第 5/13 条）：userid 数字化后签名是否同步（signature 参与串里的 userid 类型）；autoDispose family 在登录切换后是否正确重建
C. **播放排查**：结论是否闭环（每个环节有实测证据）；修复是否引入新问题（URL cleartext 域名表、试听判定改动对 VIP 的影响）
D. **手写动画**（第 20/24/26 条）：controller 生命周期、循环停止条件、离开 splash 是否停止、路径解析性能（是否在 build 内解析）
E. **缩略图**（第 25 条）：memCacheWidth 补齐覆盖率、BoxFit.fill 清零、空串守卫
F. **captcha gateway 改造**：签名/x-router/三态实测证据是否完整

## 落盘格式
```
### <文件>:<行> <标题>
- 级别：P0/P1/P2
- 事实：<代码原文>
- 违反：QUALITY_STANDARD 第 N 条
- 后果：<用户可见>
```
末尾问题清单+统计。完成后 5 行内汇报。
