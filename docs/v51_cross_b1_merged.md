# v5.1 B1 合并裁决（三视角交叉）

基线：v5.0.0 LTS（tag `71b4d73`）后主线 `08d05a6`。范围：`core/foundation`、`core/domain`、`core/config`、`core/api`（7 文件 / 719 行）。
视角报告：`v51_cross_b1_a.md`（功能正确性，28 条：P1×8/P2×15/P3×5）、`v51_cross_b1_c.md`（用户路径，40 条：P1×11/P2×21/P3×8）、`v51_cross_b1_b.md`（鲁棒与质量，运行中，待补）。

## 交叉共识（A+C 同指，优先级最高）
1. **20028 / 成功判定未真正单点**：`errors.dart:26` 字面量、`response_policy.dart:10` 常量、`kugou_api_client.dart:76` 字面量、`kugou_api_client.dart:38-90` 完整复制旧 `_wrap`；`requiresVerification` 与 `ApiException.needsVerification` 两条出口。→ **裁定：真 P1**，M4 只搬了直连 `_wrap`，基类拦截器仍是第二套判定，且 `evaluateResponse` 与旧 `_wrap` 逐分支不等价（status 字符串、`err_code` 非数值、`_hasData` 放行非零 error_code、`ssaCode as String?` 裸强转）。
2. **CookieJar 降级被缓存且无退出条件**（`kugou_api_client.dart:132-147`）+ cookie 域仍是 kapi 中转域（`app_config.dart:11-16`）→ 冷启动登录态静默变匿名。→ **裁定：P1**。
3. **翻译链路**：超时直接抛无「保留原文」降级、畸形响应静默、按行对齐无条数校验、目标语言硬编码中文、切歌无世代。→ **裁定：P1（超时/条数/世代）**，i18n 提示词归 P2。
4. **音质 `fromString` 未知值静默降 q128**、注释自述「数据一致性红线」却无留痕；`quality.dart` 残留 Flutter foundation 导入。→ **裁定：P2**（设置页写入值有白名单，未知值主要来自 Hive 损坏/旧版残留），但需补留痕。
5. **Song 模型**：`==/hashCode` 只比 hash（设计如此，v5.0 前多份报告确认通过，防重依赖此语义）、歌名前缀剥离依赖 artist 精确相等、单位白名单、裸字符串化。→ **裁定：P2**（`==` 项为**误报**，标注依据：队列去重与 `_pendingSongHash` 均依赖 hash 唯一标识）。

## 主代理裁决：误报 / 降级
- **A 报「`kugou_api_client.dart:18` 默认 baseUrl=kapi = P0」→ 降为 P2（防御性注释问题，非运行期）**：装配层 `kugouApiClientProvider` 恒注入 `kgDirectApiProvider`，`AuthRepository` 显式传直连实例，全仓仅两个构造点且都可控；kapi 值仅 CookieJar 的 URI 域占位与未移植路径的 -404 兜底，运行期不可达。但注释「运行期绝不调用」与默认参数并存易误导，补注释即可。
- **C 报「`song.dart:1` 相对 import 风格不一致」→ 误报**：Dart 库内相对 import 合法，且 M1 已把 12 消费方全部改直连，路径有效性校验 0 无效。
- **C 报「`ApiException` 无用户反馈出口」→ 误报**：`friendly_error.dart` 是翻译出口，异常类职责不含 UI。
- **C 报「应用名三套硬编码无 i18n」→ P3**：`appName` l10n 键存在，配置层字符串是包名/UA 常量。

## 待 B 视角补齐
B（鲁棒与质量）尚在运行；其报告到达后补「三视角共识」列并重算 P0/P1 总数，然后主代理按下列顺序亲修：
1. `kugou_api_client` 拦截器改调 `evaluateResponse`（删第二套判定）；统一 `kVerificationRequired` 常量与 `requiresVerification` 出口
2. `evaluateResponse` 修：status 归一、`err_code` 非数值不当成功、`ssaCode` 安全取、非零 error_code 不被 `_hasData` 无条件放行
3. `sharedCookieJar` 降级不缓存内存 jar、路径就绪后重建
4. 翻译超时/畸形返回「原文显式降级」+ 条数校验 + 切歌世代（与 lyric_repository 现有防线对接）
5. 音质 `fromString` 未知值留痕；删 `quality.dart` 无用 Flutter 导入

## 复核通过（A/C 共 27 项，摘）
- domain 上移后 12+ 消费方 import 全部指向现存新位置、无悬空旧路径
- `ApiException` 字段契约（ssaCode/verifyUrl/body）完整
- 7/7 文件逐文件 `dart analyze` 过滤噪音后项目自有类 0 错误
- `AudioQuality` 九档 + 族内降级枚举齐备、`Song` 本地/在线字段完整
- CookieJar 持久化目录创建失败不抛（但降级缓存问题见上）
