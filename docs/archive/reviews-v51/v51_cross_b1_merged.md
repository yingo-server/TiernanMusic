# v5.1 B1 合并裁决（三视角交叉）

基线：v5.0.0 LTS（tag `71b4d73`）后主线 `08d05a6`。范围：`core/foundation`、`core/domain`、`core/config`、`core/api`（7 文件 / 719 行）。
视角报告：`v51_cross_b1_a.md`（功能正确性，28 条：P1×8/P2×15/P3×5）、`v51_cross_b1_b.md`（鲁棒与质量，52 条：P1×15/P2×19/P3×18）、`v51_cross_b1_c.md`（用户路径，40 条：P1×11/P2×21/P3×8）。**三份齐，共 120 条，P0 全 0。**

## 三视角共识（A+B+C 同指，最高优先级）
1. **成功判定双套且互相矛盾**：`kugou_api_client.dart:38-90` 拦截器完整保留旧 `_wrap`，与 `response_policy.dart` 的 `evaluateResponse` 各自判一次，同一响应可得相反结论；`response_policy` 的 `ssaCode as String?` 裸强转、`codeOf` 把 double/空白/非数值错误码折叠为 0、`status` 未归一（字符串绕过）、`err_code` 非数值静默当成功。三视角共 9 条 P1 指向此处。**裁定：真 P1，优先修。**
2. **20028 未单点**：`errors.dart:26` 字面量、`response_policy.dart:10` 常量、`kugou_api_client.dart:76` 字面量；`requiresVerification` 与 `ApiException.needsVerification` 两条出口。**裁定：真 P1。**
3. **CookieJar 降级被永久缓存**（`kugou_api_client.dart:132-147`）无退出条件 → 冷启动静默匿名；cookie 域仍绑 kapi。**裁定：P1**（A/C/B 的第 10/28 条）。
4. **翻译链路**：504 直接抛无「保留原文」降级、畸形响应静默、按行对齐无条数校验、无切歌世代。**裁定：P1**（A/C/B 的第 14/15/34 条）。
5. **re-export 潜伏项**（B 第 13 条）：`kugou_api_client.dart:4` 仍 `export '../foundation/errors.dart'`，15 个引用方隐式依赖；按规划书 M1「放弃兼容层」应删并全部改直连。**裁定：本批一并做**（不向复杂度妥协）。

## 主代理裁决：误报 / 降级 / 修法修正
- **「`status==1` + 非零 error_code 被 `_hasData` 放行 = P1」→ 部分误报，修法修正**：代理因禁读历史报告（防锚定）不知道 `error_code=151/152/200/201 + 有数据` 是**实测成功语义**（PLY-10/11、F4-xx 多轮复核通过，comment 警告码）。一刀切「非零即 fail」会破坏已验证行为。**正确修法：显式警告码白名单**（`{0,151,152,200,201}`）+ 有数据才放行；20028 等真实错误码不再被放行。这比代理建议更正确。
- **A 报「默认 baseUrl=kapi = P0」→ 降 P2**：装配层 `kugouApiClientProvider` 恒注入 `kgDirectApiProvider`，`AuthRepository` 显式传直连实例，两个构造点均可控，运行期不可达；仅注释与防御性问题。
- **B 报「`app_config.dart:10` 注释与 Dio 真实请求冲突 = P1」→ 降 P2**：同上，Dio 实例虽以 kapi 为 baseUrl 构造，但所有 Provider 注入的是直连子类，未移植路径抛 -404 而非打 kapi。注释需澄清，非运行期违纪。
- **C 报「`song.dart` 相对 import 风格不一致」→ 误报**：库内相对 import 合法，全库路径有效性 0 无效。
- **C 报「ApiException 无用户反馈出口」→ 误报**：`friendly_error.dart` 是翻译出口。
- **「Song `==` 只比 hash」→ 误报**：队列去重、`_pendingSongHash`、`Song==` 契约均依赖 hash 唯一标识（v5.0 前多份复核通过）。

## 主代理亲修顺序（已执行）
1. `response_policy.dart` 重写：status/code 归一、警告码白名单、err_code 非数值判失败、`ssaCode` 安全取、`requiresVerification` 复用 `needsVerification`
2. `kugou_api_client.dart` 拦截器改调 `evaluateResponse`（删第二套判定）+ CookieJar 降级不缓存 + 删 re-export、15 引用方全部直连 foundation
3. `errors.dart` 去字面量、统一 `kVerificationRequired`
4. `translate_api.dart` 504/畸形显式降级 + 条数校验 + 留痕
5. `quality.dart` 未知音质留痕 + 删无用 Flutter 导入

## 复核通过（A/C 共 27 项，摘）
- domain 上移后 12+ 消费方 import 全部指向现存新位置、无悬空旧路径
- `ApiException` 字段契约（ssaCode/verifyUrl/body）完整
- 7/7 文件逐文件 `dart analyze` 过滤噪音后项目自有类 0 错误
- `AudioQuality` 九档 + 族内降级枚举齐备、`Song` 本地/在线字段完整
- CookieJar 持久化目录创建失败不抛（但降级缓存问题见上）
