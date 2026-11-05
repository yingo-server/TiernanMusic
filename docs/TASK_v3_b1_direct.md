# 第5批·审查①：直连层全量复核（v3.0 终审 A 视角）

## ⚠️ 硬性规则（违反任一 = 任务失败）
1. 先完整读 `docs/QUALITY_STANDARD.md`（32 条原则）。每条结论必须标注「违反第 N 条」。
2. 只允许**完整 file_read**（从第 1 行到最后一行）+ 查阅 Dart SDK 文档（https://api.dart.dev）。
3. **禁止**：grep/rg 筛代码、编译、跑测试、装任何 SDK/包、git clone、修改代码、git 操作。
4. 允许 `dart analyze` 查语法（`export PATH=$PATH:/opt/dart/bin`），但缺 Flutter 包产生的
   uri_does_not_exist/undefined_class 等是噪音要过滤，只看结构错误。
5. **禁止读 docs/batch1~4_*、docs/check_*、docs/review_b*_*.md**（防锚定）。可读：
   QUALITY_STANDARD.md、REVIEW_SPEC.md、api_verified.md、本任务书。
6. 上游参考：`/var/minis/workspace/KuGouMusicApi/module/*.js`（只读）。
7. **实时落盘**：每读完一个文件立即 append 到本任务指定的报告，禁止最后统一写。

## 背景
代码已经过多轮修复，本批是**复核**：重点不是找新问题，而是验证修复是否正确、是否引入回归。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 commit `bc4a521`（tag v3.0.0）

## 报告文件
`docs/v3_review_b1_direct.md`

## 范围（逐个完整读）
1. `lib/core/direct/kg_direct_api_client.dart`
2. `lib/core/direct/kg_client.dart`
3. `lib/core/direct/kg_crypto.dart`
4. `lib/core/direct/kg_endpoints_search.dart`
5. `lib/core/direct/kg_endpoints_playlist.dart`
6. `lib/core/direct/kg_endpoints_comment.dart`
7. `lib/core/direct/kg_endpoints_media.dart`
8. `lib/core/direct/kg_endpoints_artist_album.dart`
9. `lib/core/direct/kg_endpoints_home.dart`
10. `lib/core/direct/kg_endpoints_auth.dart`
11. `lib/core/direct/kg_play_api.dart`
12. `lib/core/direct/kg_providers.dart`

## 复核重点
A. `fallbackToKapi` 已改为 `const false`，未移植路径抛 `ApiException(-404)`——
   检查所有 `_directOrFallback` 调用点在这个新语义下是否自洽（kapi 闭包传入但永不执行，
   是否有死代码/误导注释需要标记）。
B. `_wrap` 新逻辑：err_code 提前校验（含字符串）、status==200 分支、空 Map 判失败——
   对照各端点真实返回形态（api_verified.md），是否有端点会被误判失败。
C. `write: true` 的 7 个写操作调用点 + Repository 层 `_write` 的防重锁与
   `PlaylistWriteException.maybeSucceeded` 语义——对照 QUALITY_STANDARD 21 条。
D. `setCredentials` dfid 同步、`clearCredentials` 对称性。
E. 每个端点参数与 Node module/*.js 对照（抽查 8 个关键端点：search/song、playlist/detail、
   playlist tracks add/del、comment send/reply/del、song/url、lyric download）。
F. 签名：三种盐、signature 在 query、clienttime 秒级、clearDefaultParams 仅 5 处。
G. 加密：playlistAesEncrypt、edt_generator OAEP-SHA256、KRC XOR+zip。
H. 死代码（第 32 条）：未使用方法/字段/注释残留。

## 落盘格式
```
### <文件>:<行> <标题>
- 级别：P0/P1/P2
- 事实：<代码原文>
- 违反：QUALITY_STANDARD 第 N 条
- 后果：<用户可见>
```
末尾：问题清单按级别排序 + 统计表。

完成后 5 行内汇报：总数/各级别数/最严重的 3 条。
