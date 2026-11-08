# v5.1 B2 合并裁决（三视角交叉·进行中）

基线：B1 修复后主线 `ffe9d33`。范围：`lib/core/direct/**` 全部 14 文件 / 4316 行。
视角报告：
- `v51_cross_b2_a.md`（功能正确性 / 原生网关与签名，运行中）
- `v51_cross_b2_b.md`（鲁棒与质量，**已到**：76 条：P1×12 / P2×40 / P3×24，复核通过 18 项）
- `v51_cross_b2_c.md`（用户路径与一致性，运行中）

## B 视角 P1 的主代理预裁决（A/C 到达后复核）
1. **真 P1**：`kg_play_api.dart:40/72` 两处 `requestWithVerify` 结果不判 `KgResponse.status` 即解析；`kg_client.dart:293-303` 网络异常折成 `status=502 + body{status:0}` 的假响应 → `PlayUrlResult.fromResponse` 返回「无 URL 的成功结果」→ 播放静默跳歌。B1 刚把异常契约统一到 `evaluateResponse`，此处未跟上。**修法方向：在 KgClient 层对非 2xx/异常统一抛 `ApiException` 包装的 DioException，或 PlayUrlResult.fromResponse 显式拒绝 status!=200。**
2. **待裁决**：`kg_client.dart:293-303` 的 502 假响应是多轮实测确立的历史契约（上层靠 body.status 判），直接改可能破坏 20028 验证重试链；须结合 C 视角「播放失败用户路径」结论。
3. **真 P1（部分）**：`kg_endpoints_playlist.dart` / `comment.dart` 写端点无本地提交锁——上层 `_directOrFallback(write:true)` 只禁回退，`PlaylistRepository._write` 有 `_inFlight` 防重，但 `CommentRepository` 的写操作是否受同一闸门保护需 A/C 核实（跨层契约，不重复造）。
4. **待核实**：`aesEncryptHex` 命名/返回 Base64 与 playlistAesEncrypt 派生式不一致——历史 P0-4（RSA-PKCS1）多轮复核通过，须读 Node `util/crypto.js` 对照后再判，不凭命名定缺陷。
5. **真 P2 升级候选**：`kg_providers.dart` dfid 三写（Hive/SecureStorage/内存）失败静默吞——B1 已确认「dfid 三写」是根因链，写失败无人检查会让设备身份再次分裂。
6. **误报候选**：`registerDev()` 把失败包装成 HTTP 200 业务响应——这是直连层统一 `_wrap` 的输入形态，后续 `evaluateResponse` 会判 `status:0` 失败；须确认调用方是否绕过策略。

## 交叉共识待补
A/C 到达后填：三视角共识 / 双视角 / 单视角、矛盾项裁决、误报清单、P0/P1 最终修复集。

## CI 状态说明（非代码问题）
`eca6227`、`ffe9d33` 两次 CI 整条失败均为 **GitHub Releases 侧 Gradle/Kotlin 依赖下载 504**；
`analyze` 步骤每次 0 error、Architecture guard 通过。待外部恢复后自然绿，不为此改代码。
