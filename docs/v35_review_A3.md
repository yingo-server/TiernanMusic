# v3.5 A 批·审查③：auth 全链（登录/登出/恢复/多账号/20028 验证/滑块/登录端点签名）

基线 2140bf7。依据 QUALITY_STANDARD.md（33 条）。禁编译；dart analyze 噪音过滤仅适用于 Flutter SDK 符号，项目自有类报错即真错误。跨文件改动双向核对（调用方↔被调方）。

核心输入：`docs/v34_review_3_cross.md` 的「登录态传播路径图」与三条事件流清点（唯一同代输入，已逐条验证，结论见文末）。

覆盖文件：auth_repository / auth_providers / account_manager / verification_service / captcha_types / edt_generator / slider_solver / secure_storage / login_page / captcha_page / login_guard / verification_guard / verification_listener / kg_endpoints_auth / kg_direct_api_client（_wrap、_directOrFallback）/ kg_client（requestWithVerify、submitFingerprintVerification）/ kg_providers（kgClientProvider、onDfidRegistered）/ kugou_api_client（拦截器）/ core/providers / main.dart 登录态监听 / settings_page 账号管理段 / kg_play_api（requestWithVerify 调用方）/ audio_handler（20028 分支）。

---

### lib/features/auth/presentation/captcha_page.dart:91,298-312,352-354,379,383 i18n 改造后页面仍硬编码中文——arb 键与页面双向脱钩
- 级别：P2
- 事实：V34-UI 批（commit b145f1b「captcha i18n」）向全部 arb 加入 `captchaLoadFailed / captchaSmsTitle / captchaSmsHint / captchaSmsCodeLabel / captchaSmsCodeHint / captchaExternalHint / captchaUnknownType / captchaNoVerifyUrl / captchaHint` 等 9 个键，但 captcha_page.dart 实际渲染处仍是硬编码中文串：
  - L91 `_error = '获取验证信息失败：$e'`（同时把技术文本 `$e` 直出上屏，L10N 键 `captchaLoadFailed` 已备好未用）
  - L298 `'短信验证'`、L301 `'请输入接收到的验证码完成验证'`、L311-312 `'验证码'/'6 位数字'`
  - L352 `'该验证类型需要在酷狗官方 App 内完成。\n建议：…'`
  - L379 `'未知验证类型（v_type=${s.vType}）'`（键 `captchaUnknownType(type)` 已存在）、L383 `'服务端未返回验证 url'`
  grep 全 `lib/features`+`lib/core`：上述 9 键零引用（仅生成物 app_localizations.dart 携带）。违反第 30 条（键名与实现脱节）、双向核对纪律（arb 加键 ↔ 页面换用，只做了单向）。
- 影响：英文/德/日/韩等全部语言界面在此页弹中文；9 组翻译成死键（第 32 条精神）；`$e` 技术串上屏（V34-UI-02 在同文件其它分支修了，此处漏网）。

### lib/features/auth/data/slider_solver.dart（全文件）+ TrajectoryGenerator：从未接线的死代码
- 级别：P2
- 事实：grep 全项目 `SliderSolver`、`detectOffset`、`TrajectoryGenerator`、`generateRotation`——除定义文件外零引用。commit c1efe76「20028 全链路打通 + 滑块算法 + EDT 生成器」中 EDT 生成器已接入（kg_client.dart:338 submitFingerprintVerification），滑块识别+轨迹生成整文件悬空：酷狗滑块类验证（v_type=23 走 TCaptcha WebView、KGCodeKG/KGCodeKG2 走「官方 App 完成」分支）没有任何路径调用它。
- 算法本身另有两处疑点（因死代码不单独定级，接线前必改）：
  1. `_matchScore` 的暗区偏好 `center > 200 ? 8 : 0` 假设缺口比周围暗——酷狗滑块缺口常为**高亮/白底**（抠图露底），偏好方向可能相反，需真机截图验证（第 33 条：不得以推测为准）。
  2. `detectOffset` 假设拼图块永远在背景左侧且缺口纵向与拼图顶部对齐（`searchTop = py`），对旋转类（KGCodeKG2）完全不适用——而文件头注释宣称「适用于酷狗自研/旋转滑块」。
- 违反：第 32 条（死代码零容忍）；第 30 条（注释宣称与实现能力不符）。
- 影响：210 行不可达代码长期滞留；若未来有人「接线」，按当前算法接大概率拖不准，反而引入新问题。

### lib/features/auth/presentation/verification_guard.dart（全文件）runWithVerification 零调用方 + verification_service.dart:91 sessionFromException 死方法
- 级别：P3
- 事实：`runWithVerification` 全项目仅注释与 kg_direct_api_client.dart:163 的注释提及，无任何调用。`sessionFromException` 同样零调用。两处是 20028 链路早期设计的遗留，实际生效路径是：播放→VerificationListener（流）、登录→login_page 内联 catch、评论→comments_page 内联 catch、通用写操作→kg_client.requestWithVerify（仅 GET）。
- 违反：第 32 条（死代码）；kg_direct_api_client.dart:163 注释指向的「上层 verification_guard」已名不副实（第 30 条）。
- 影响：新人按 runWithVerification 的 doc-comment 包写操作会得到一个**从未被测试过**的重试路径（且其自动重试对写操作有重复提交风险，V3-10 红线在 guard 文件里没有任何防护说明）。

### lib/main.dart:296-302 V34-C-02 重试闭包捕获旧 `next`，重试可回灌过期登录态（世代未校验）
- 级别：P2
- 事实：`ref.listen(authStateProvider, (_, next) { … try applyAuth() catch → Future.delayed(200ms, () => applyAuth()) })`。`applyAuth` 是捕获外层 `next` 的闭包。200ms 重试窗口内若来了**新的** auth 事件（如 restoreSession 完成→登录态落定，或用户点了登出）：旧事件的重试会以旧 `next.value` 覆盖 `client.token/userid`，并 `MemoryCache.instance.clear()`+invalidate——把新事件刚写入的 token 回滚为旧值。违反第 18 条（异步结果未校验世代；同文件 `c.userId == user.userid` 已展示作者有世代意识，此处漏了）。相邻事件顺序：Riverpod listen 每次变化回调独立，无法靠「再来一次事件」补救。
- 影响：低概率但后果与 V34-C-02 原始 P1 相同（token 丢失/回退），且发生在登录成功瞬间（build 首帧 error 事件触发重试 + 登录成功事件几乎同时）——恰是冷启动最拥挤的时序。
- 附：重试成功路径不做「事件是否仍最新」检查，多余的 MemoryCache.clear 亦会造成一次无谓全量缓存冷启动。

### lib/features/auth/data/auth_providers.dart:36-47 build 期 `SecureStorage.readCredentials()` 裸调用无防护，插件层失败 → authState 进入 AsyncError 且静默当登出
- 级别：P2
- 事实：`build()` 内 `try { final cred = await SecureStorage.instance.readCredentials(); … } catch (_) { … }` 只包住了补 t1 段；随后 `return ref.read(authRepositoryProvider).restoreSession()`。restoreSession 内部第一行 `await _storage.readCredentials()` **没有 try**——secure_storage 插件异常（Keystore 损坏、Android EncryptedSharedPreferences 解密失败是实测常见故障）直接从 build 抛出 → authStateProvider = AsyncError。main.dart 监听 `next.isLoading` return、`valueOrNull` 为 null → applyAuth 按「登出」清空 client.token 并 invalidate home/library。用户实际有凭证却全程按匿名运行，且 AsyncError 状态无任何 UI 呈现（与 V34 报告 settings_provider 强转崩启动同类，但此处不崩、更隐蔽）。restoreSession 内部 `catch (_)` 兜不到——它兜的是 build 内 await 之后的异常，readCredentials 在函数体首行 await，抛出点在所有 try 之外。
- 违反：第 6 条（catch 必须转译/降级——此处异常逃逸出降级体系）；第 14 条（Keystore 读取是边界）；第 9 条（降级无留痕）。
- 影响：Keystore 故障机型表现为「每次冷启动都是未登录」，重启无法自愈，日志仅有一条无关 debugPrint。

### lib/features/auth/data/auth_repository.dart:291-293 saveAccountToken 失败被 `catch (_) {}` 吞掉，多账号切换 token 静默丢失
- 级别：P3
- 事实：`try { await _storage.saveAccountToken(userid: userid, token: token); } catch (_) {}`——空捕获。B-11 后 acct_token_* 是多账号切换的**唯一**凭证源（Hive 故意不存 token），写失败时：本次登录正常，用户不会察觉；下次在账号管理里切到该账号 → switchAccount 读 token 为 null → StateError「该账号需要重新登录」→ settings_page F4-41 分支直接把该账号从列表删除。一次磁盘满/Keystore 异常 = 账号从多账号列表永久消失（且 remove 时不提示原因）。对比同文件 clearCredentials 的删除路径（有注释有对称性），此处是「写入/清除对称」中写入侧的静默失败。
- 违反：第 6 条（空捕获）；第 9 条（失败不可观测）；第 20 条（写入/清除对称性只做了一半）。
- 影响：偶发、难复现的「账号列表越用越少」，线上无任何日志。

### lib/features/auth/data/auth_repository.dart:70-71 多账号识别依赖 `err.message.contains('多个')` 中文串匹配
- 级别：P3
- 事实：`if (err.errorCode == 20034 || err.message.contains('多个'))`——20034 之外再靠**中文错误文案**判断多账号归属。kapi 包装文案与原生网关文案不保证一致（第 33 条：kapi 返回不可作为原生依据；此处恰用 Node 层转译出的中文文案做逻辑分支）。若原生返回不同文案（或未来错误信息改版），20034 分支失效前还有 `err.message` 兜底，兜底本身基于不可靠契约。
- 违反：第 3 条（契约模糊：错误码之外的字符串匹配是隐式契约）；第 33 条精神。
- 影响：20034 直连路径正常时无感；文案一变，多账号用户只看到报错、无法选择账号（回归 v3.2 时代缺陷形态）。

### lib/features/auth/presentation/captcha_page.dart:26-37,39-40 typeHint 参数与 onVerified 默认流程不一致
- 级别：P3
- 事实：`typeHint` 参数全项目零传入（4 个调用点均不传），构造后无任何消费（`_extractTxAppId` 只看 `session.verifyUrl`）——死参数。另：登录流（login_page:410）传 `api: kugouApiClientProvider`，页内 `VerificationService(widget.api, ref.read(kgClientProvider))` 的直连客户端来自另一个 provider——但 kugouApiClientProvider 底层就是 kgDirectApiProvider→kgClientProvider，二者共享同一 KgClient 实例，mid/token 一致 ✅（双向核对通过，无第二客户端问题）。
- 违反：第 32 条（typeHint 死参数）。
- 影响：仅整洁度。

### lib/features/auth/data/verification_service.dart:44-49 buildSidEdt 的 userid/dfid 与直连链路来源不一致（双源）
- 级别：P3
- 事实：VerificationService 用 `_api.userid`（KugouApiClient 字段，经 kapi cookie/setCredentials 维护）与 `SecureStorage.readDfid()`；而 KgClient.submitFingerprintVerification（播放链路实际生效的实现）用 `kg.userid` 与 `kg.device.dfid`。两条 edt 指纹链来源不同：①SecureStorage dfid 与 Hive device box 是 V34 已记录的双源（B-10 后 Hive 为权威，此处仍读 SecureStorage）；②`_api.userid` 只在 AuthRepository.setCredentials 时更新，而 kg.userid 在每次登录响应 _afterLogin 时更新——**登录成功但 _handleLoginSuccess 尚未执行完毕**（或 logout 后半途）的窗口内，两者可能不同。kg_client.dart:339 的实现已统一走 device/userid，verification_service 这份是被 CaptchaPage 使用的**另一份平行实现**，行为不保证一致（第 5 条：同一指纹数据两个事实源）。
- 影响：验证提交的 userid/dfid 维度与风控期望偶发错位 → 验证提交被判异常，表现为「验证通过但原请求仍 20028」。

### lib/features/auth/data/auth_repository.dart:196-206 getUserDetail 返回 token 恒空，restoreSession 二级降级路径用其构造 AuthUser 时 token 有来源混用
- 级别：P3
- 事实：`getUserDetail()` 固定 `token: ''`。restoreSession 首层 `catch (_)` 兜底里 `AuthUser(userid: cred.userId, token: cred.token, nickname: detail.nickname, …)` 用 cred.token 补回（正确）；但该分支之前 V34 已记录的「编程错误进业务降级」双层 `catch (_)` 仍在（L236-258），未修。此处仅补一条核对结论：降级链 token 无混用 ✅，但双层空捕获残留与 V34-C-12 相同，本轮确认**未修复**（v34 清单第 12 条沿用有效）。
- 影响：同 v34 第 12 条。

### lib/features/auth/presentation/login_page.dart:577-584 二维码 status==4 后 token/userid 可能为空仍强制 loginByQrToken
- 级别：P3
- 事实：`loginByQrToken(token: res.token ?? '', userid: res.userid ?? '')`——直连 loginToken 对空 token 有 `kg.token.isNotEmpty ? kg.token : ''` 兜底，等于**静默用上一个会话的旧 token 换登录态**。正常流程 kg.token 在登出时已清空，风险窗口是「A 账号二维码扫码成功但响应缺 token 字段」时拿 B 残留 token 登录（kg.token 未清的异常时序下）。且失败仅 `_showError`，二维码状态已显示「登录成功」（`_statusText` 4 → loginSuccess）先于 loginByQrToken 完成——status==4 时 UI 立即显示登录成功，token 换取失败后提示的是 Toast，主状态文案矛盾。
- 违反：第 3 条（状态契约：轮询状态 4 ≠ 登录成功，注释自己也承认「status==4 只表示扫码成功」，但 UI 文案表仍把 4 映射为 loginSuccess——注释与实现自相矛盾）。
- 影响：弱网/响应异常时「显示登录成功但实际没登录」。

### lib/core/direct/kg_endpoints_auth.dart:129-137 / kg_client.dart:355-375 20028 指纹直提链与 UI 验证链行为不一致（verifycode 缺失类型）
- 级别：P3
- 事实：kg_client.submitFingerprintVerification 命中 ssa-code 后**只提交 sid/edt 指纹**（data 无 verifycode，v_type 未传——`get_verify_info` 请求体也没有 v_type），成功即重试原请求；而 UI 链（VerificationService）先查 `/get/verify/info` 拿 v_type 再按类型带 verifycode 提交 `/v4/verify_user_info`。对照 Node verify_user_info.js：v_type 缺省 23 时服务端要求 verifycode；kg_client 的直提相当于赌「仅指纹即可通过」。两条链对同一 20028 事件可能得出不同结论（播放链 GET 用直提链，登录链用 UI 链），且直提链成功判定只看 `r.body['status'] == 1`，与 UI 链多条件判定（codeDesc success）不一致。
- 违反：第 4 条（成功判定不统一）；第 5 条（同一验证两套事实源）。
- 影响：播放被风控时若服务端要求真验证码，直提链恒失败→requestWithVerify 原样返回失败响应→上游照旧抛 20028 给 UI 弹窗（有兜底，不致命），但每次播放多一次无效验证往返（首播延迟）。

### lib/features/auth/data/account_manager.dart:60-66 init() 兼容清洗每次启动重写 list + token 字段双轨
- 级别：P3
- 事实：`init()` 每次启动执行 `_saveList(accounts)`（名为「历史版本清洗」，实际**无条件**重写整盒）；AccountRecord.token 字段注释声明「仅内存使用、不持久化」，但 upsert 时 auth_repository 传入 token，toJson 不含 token ✅（核对通过）；可 `AccountRecord.token` 仍被 settings_page 展示路径间接依赖？核对：settings_page 只读 nickname/avatar/userid ✅。真正问题是无条件重写：每次冷启动多一次盒写放大，且若上次写盘损坏（半写），本次把损坏数据「再存一遍」而非修复。轻微。
- 违反：第 26 条精神（无谓写放大）；第 32 条（兼容清洗无版本标记，永远执行）。
- 影响：极轻微，记录备查。

### lib/features/auth/data/edt_generator.dart:62-73 静态可变 `_sentinel` 与重复调用
- 级别：P3
- 事实：`static int _sentinel` 每次 generate() 重置为 `0xffffffff - _ri(0,19)`。单 isolate 顺序调用无问题；但 requestWithVerify（播放链）与 VerificationService（UI 链）可能近乎同时各调一次 generate——Dart 单线程下 generate 无 await 点，两次调用不会交错，实际安全 ✅（双向核对：generate 是纯同步函数）。记录为「并发假设已成立」而非问题。
- 影响：无（核对结论项）。

### 三态实测（第 33 条）：本环境只能做无凭证匿名态直打，登录态/VIP 态需真机复核
- 级别：实测纪律记录
- 事实：环境内 `native_probe.sh` 不存在（全仓 grep 零命中；tool/ 下仅 kg_probe.py 等 Python 探针）。以 curl 直打原生域（匿名态）：
  - `GET https://login-user.kugou.com/v2/qrcode?appid=1001&type=1&plat=4&srcappid=2919` → `{"data":null,"status":0,"error_code":20010}` —— 域名可达、TLS 正常、签名缺失报 20010（参数缺失），说明 **loginQrKey 的 URL/参数形态能被原生网关接受**（非 DNS/风控层拒绝）✅
  - `GET https://login-user.kugou.com/v2/get_userinfo_qrcode?…qrcode=nonexistentkey123` → 20010 同上 ✅（缺 qrcode 合法 key 属参数性失败，形态对）
  - `POST https://verifyservice.kugou.com/v4/verify_user_info?clientver=11510`（空 sid/edt/eventid）→ `{"status":0,"error_code":20006,"data":"err appid(srcappid) or clientver or mid or dfid"}` —— **20006 的 error 文案与 kg_client.dart:326 注释「实测 20006（签名错风控）也会带 ssa-code」吻合**，且证实该端点校验 srcappid/mid/dfid 维度——侧面印证 verification_service.dart:44 双源 dfid 风险（上一条）是真实风控维度而非理论。
  - 结论局限：无 t1/dfid/有效签名，20010/20006 只能证明「域可达+参数形态可解析」，不能证明登录成功路径；恢复态/VIP 态实测（restoreSession、/v5/login_by_token、多账号）**未完成，需真机三态复核**，本报告相关结论均标注「未实测」。

---

## v34_review_3_cross.md 核心输入验证结论

### 登录态传播路径图逐点验证
| 图上标注 | 验证结果 |
|---|---|
| main listen 同步体被 try/catch 吞（P1 #2） | **已修复**（V34-C-02：独立防护+200ms 重试+留痕），但重试引入新世代竞态（本轮 P2，见上） |
| token 经 main 旁路灌入 player（P1 #4） | **半修复**：main listen 现在直接写 `kgClientProvider` 实例字段（token/userid/t1），player 依赖的 KgPlayApi/kgClient 由此获得 token——行为闭环 ✅；但传播仍经 UI 层 listen 而非 provider 依赖图，V34-C-06 的架构批评**仍然成立**（未改） |
| MemoryCache 90s 串数据（P1 #3） | **已修复**：applyAuth 内 `MemoryCache.instance.clear()`，登录/登出/切号三条路径都经过 main listen（switchAccount→state 赋值→listen ✅、logout→AsyncData(null)→listen ✅、登录→LoginController._finish→setUser→listen ✅，三条路径双向核对均达 listen） |
| AccountManager.onCurrentAccountChanged 仅 library_page 订阅 | **仍然成立**：grep 全项目仍只有 library_page.dart:45 一个订阅者；settings_page 靠显式 `_loadAccount()` 手工刷新——切号后设置页若停在后台无刷新机制，与图一致 |
| 生命周期 resume 不校验登录态（#5） | **仍然成立**：didChangeAppLifecycleState 仍只转发 downloadManager，auth 无 resume 校验 |
| 三条流清点 | 流 1 订阅者与图一致 ✅；流 2 一致 ✅；流 3 一致 ✅；无新增订阅者漏记 |

### v34 auth 类条目复核（本轮范围内的）
| v34 条目 | 现状 |
|---|---|
| #9 auth_providers 登出→登录 t1 世代竞态 | **已缓解**：main listen 的补 t1 有 `c.userId == user.userid` 世代校验；但 authStateNotifier.build 的补 t1（L36-43）仍无世代校验，且 logout 与 state 赋值之间在途请求窗口仍在——残余 P3，不再单列 |
| #10 AuthRepository 裸 new | **仍成立**（构造默认 `api ?? KugouApiClient()` 未改） |
| #11 getDfid 空捕获 | **仍成立**（L77 `catch (_) {}`，现返回 '' 且不落盘——有注释改善，但失败仍零留痕） |
| #12 restoreSession 编程错误进降级 | **仍成立**（见上） |
| #13 nickname/avatar 第三副本 | **仍成立**（L352-356 写 settings box、auth_providers.logout 删键，均未改） |

---

## 问题清单（按级别）

**P2（4）**
1. captcha_page.dart i18n 键与页面脱钩：9 键死、5 处硬编码中文 + `$e` 直出（b145f1b 单向改动未双向核对）
2. slider_solver.dart 全文件死代码（含算法两处未经实测的假设）
3. main.dart:296 V34-C-02 重试闭包捕获旧 `next`，200ms 窗口可回灌过期登录态（世代未校验）
4. auth_providers.dart build 期 readCredentials 逃逸出降级体系 → Keystore 故障机型静默永久匿名（无留痕）

**P3（9）**
5. auth_repository.dart:291 saveAccountToken 空捕获 → 多账号 token 静默丢失、账号列表越用越少
6. auth_repository.dart:70 多账号识别靠 `message.contains('多个')` 中文串匹配（kapi 文案契约）
7. verification_guard.dart / sessionFromException / CaptchaPage.typeHint 三处死代码
8. verification_service.dart:44 edt 指纹 userid/dfid 双源，与播放链实现不一致（20006 实测证实 dfid 是风控维度）
9. auth_repository.dart:196 getUserDetail 相关：v34 #12 双层空捕获**未修**，本轮确认沿用
10. login_page.dart:577 二维码 status==4 UI 文案即「登录成功」+ 空 token 时静默用旧 kg.token 兜底
11. kg_client.submitFingerprintVerification 与 UI 验证链 v_type/verifycode/成功判定三重不一致，播放链每次风控多一次无效往返
12. account_manager.init 无条件重写 list（无版本标记的「兼容清洗」）
13. v34 #10/#11/#13 在本轮范围内确认未修复（裸 new / getDfid 空捕获 / settings 第三副本）

**核对通过项（无问题，记录防回退）**
- kapi 回退永久关闭（fallbackToKapi=false），auth 端点全部直连原生域；20028/20034 异常不回退直接上抛 ✅
- 直连异常契约：`_asDioException` 统一 DioException+ApiException，20028/20034 上层捕获链完整（login_page/comments/verification_listener 三处双向核对均能接住）✅
- loginByPassword 20028 后重试为幂等登录请求（会话创建类，无重复提交风险）✅；播放链 requestWithVerify 仅 GET 使用 ✅（V3-10 写操作红线守住了）
- edt_generator：AES-128-CBC IV=`kugousecurity123`（16 字节）✅、key=md5[:16] ✅、RSA-OAEP **withSHA256** 显式指定 ✅（A2-03 修复在位）
- KgDirectApiClient.setCredentials 双写 kg.token/kg.device.dfid（V3-09 在位）✅；clearCredentials 清 kg 字段 ✅
- SecureStorage.clearCredentials 保留 dfid（F-1）、删四键+acct_token（B-11）✅；logout 两分支（removeAccount/clearCurrent）与存储删除对称 ✅
- switchAccount peek→token→loginByToken→switchTo 顺序（F3 在位）；settings F4-41 失效账号移除在位 ✅
- 多账号路径双向核对：AccountManager.remove ↔ auth_providers.switchAccount StateError ↔ settings_page catch ✅
- 三态实测：匿名态原生域探活 3 条（见上）；恢复态/VIP 态未实测，标注待真机复核

## 统计
- 本轮新增 13 条：P2×4、P3×9；另有 7 项核对通过项、3 项 v34 条目沿用确认
- 最高优先：captcha i18n 脱钩（用户可见中英混排）＞ 登录态重试世代竞态 ＞ Keystore 静默匿名
- dart analyze 未执行（禁编译纪律）；本档范围内未发现 Flutter SDK 符号类报错需核对 import 的情况
