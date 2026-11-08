# v5.1 B2 视角 C：用户路径与一致性 审查报告

- 批次：B2 · 视角 C（用户可见后果 / 三态 / i18n / 生命周期 / 跨模块契约 / v5.0 回归）
- 范围：`docs/TASK_v51_b2_b8.md` B2 段列出的 `lib/core/direct/*.dart` 共 14 文件 4316 行，逐文件 `file_read` 完整阅读
- 依据：`docs/QUALITY_STANDARD.md`（33 条，优先）、`docs/REVIEW_SPEC.md`
- 纪律：只读源码；唯一写入本文件；不给修复建议；每读完一个文件即时追加；末尾问题清单 + 复核通过项 + 逐文件 `dart analyze`
- 证据口径：静态阅读为主；凡涉及「上游真实返回」结论均标注「未实测」（第 28/29/33 条）

## 逐文件审查记录

### 文件 1/14 `lib/core/direct/edt_generator.dart`（281 行，已从头读到尾）

- 本文件为行为指纹 sid/edt 生成器，是「登录验证 / 20028 验证」用户路径的最上游凭证来源。本轮先记录本文件内可静态确认的事实，跨模块调用链结论在读到调用方文件后以「补充」形式追加。

### edt_generator.dart:65,76 哨兵与 key 为静态可变全局，调用方无任何防重/世代标识
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 22 条（并发假设必须写明）
- 依据：`static int _sentinel = 0xffffffff;` 由 `generate()` 首行无条件覆写，`_fs3/_fs5/_fs6` 又在 `_generateEdtData()` 内读取该全局；`generate()` 全程同步无 `await`，因此单 isolate 内不会交错，但类注释与签名均未声明「必须同步调用、不可跨 await」这一前提；`key` 通过 `_rand`（`math.Random.secure()` 静态单例）生成。
- 影响：当前版本无用户可见故障；但若后续把 `generate()` 改成异步（例如把 RSA 放 isolate）或引入缓存/复用，指纹中的哨兵与行为序列会串到另一次请求上，表现为风控校验失败而用户无感知原因。按分级纪律只记 P3。
- 证据等级：静态推演

### edt_generator.dart:76,238 `fixedKey` 未校验长度即作为 AES 密钥
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 3 条（契约先行：输入取值范围）
- 依据：`final key = fixedKey ?? ...substring(0, 16);` 之后 `_aesEncryptBase64(plaintext, key)` 直接 `Uint8List.fromList(utf8.encode(key))` 送入 `AESEngine()`；只有默认分支保证 16 字节，外部传入的 `fixedKey` 无长度约束、无契约说明。
- 影响：仅当调用方传入非 16 字节 `fixedKey` 时 AES 初始化抛错，指纹生成中断 → 依赖该凭证的接口整体回退；当前生产调用方是否使用 `fixedKey` 待调用方核对（见后续补充）。
- 证据等级：静态推演

### edt_generator.dart:1-14 注释声称「逐行对照 generate_simulate.js」，但方案结论无实测留样
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（调用方式必须逐一实测）、第 29 条（返回结构必须实测并留样）
- 依据：文件头注释逐行列出与 Node 版函数的映射，并在 `edt_generator.dart:255` 附近写明「A2-03（审查②）：上游 generate_simulate.js 用 RSA-OAEP(SHA-256, MGF1-SHA256)」，这是审查结论而非原生网关实测记录；本仓库内该结论未附匿名/普通/VIP 三态样本。
- 影响：无直接用户可见后果；但 v5.0 下沉后的加密方案若与上游不一致，用户表现为「登录/验证请求被拒、反复触发验证」，且线上无留样可定位。按纪律标注「未实测」。
- 证据等级：未实测

### 文件 2/14 `lib/core/direct/kg_client.dart`（615 行，已从头读到尾；跨模块对照另完整读了 `lib/core/foundation/errors.dart`、`lib/core/domain/response_policy.dart`、`lib/core/domain/quality.dart`、`lib/core/config/app_config.dart`）

跨模块契约基准（B1 现状，实锤）：`errors.dart:4` 定义 `kVerificationRequired = 20028`，`ApiException.needsVerification` 是唯一判定；`response_policy.dart:51` 的 `evaluateResponse` 用 `_codeOf` 把 `int/num/纯整数字符串（含首尾空白）` 归一，`_ssaOf` 取 `ssaCode/ssa_code/ssaCodeStr` 与外部响应头；`evaluateResponse` 还在 `error_code` 不可解析时判失败、`error_code=20028` 时任何 status 都失败。`requiresVerification(Object? e)` 只认 `ApiException`/Dio 包装异常。

### kg_client.dart:58-60 `KgResponse.errorCode` 与 B1 `evaluateResponse` 的错误码归一契约不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一且稳定）、第 13 条（外部数据禁止裸类型强转）、第 3 条（契约先行：失败语义）
- 依据：`int get errorCode { final v = body['error_code'] ?? body['errcode'] ?? body['err_code'] ?? 0; return v is int ? v : int.tryParse('$v') ?? 0; }`——不可解析的错误码（如 `'20028 '` 之外的脏值、`Map/List`、`true`）被吞成 `0`；B1 `response_policy.dart:_codeOf` 对同形态返回 `null` 并判失败。`_needsVerify` (394-399) 与后续端点层判定直接用 `r.errorCode`，与 B1 的失败口径分岔。
- 影响：上游返回形态异常时，同一次响应在 direct 层被当作「无错误码」，20028 风控不触发验证提交、也不进入 B1 的失败分支；用户表现为点播/搜索/评论等请求静默失败或拿到空结果，且无「需要验证」提示。
- 证据等级：静态推演（B1 与 direct 层源码对照，实锤于代码事实；上游是否真的返回脏错误码未实测）

### kg_client.dart:394-399 `_needsVerify` 对字符串型 status 与 `status==2` 不识别，且未复用 `requiresVerification`
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常/风控判定口径必须一致）、第 5 条（状态单一来源：20028 判定唯一出口）
- 依据：`final failed = r.body['status'] == 0 || r.errorCode != 0; return failed && (r.ssaCode?.isNotEmpty ?? false);` 与 `_wrap` 迁移后的 `evaluateResponse` 五分支不同：B1 把 `status` 归一为数值并覆盖 `status==2`、`err_code != 0`、`body.isEmpty` 等失败态；`errors.dart:4` 注释明确「全仓 20028 唯一常量；判定必须走 ApiException.needsVerification 或 response_policy.requiresVerification」，而本文件既未 import `response_policy.dart`，也只靠 `ssa-code` 头/体启发式判定（`kg_client.dart:391-393` 自述「不只认 20028」）。
- 影响：20028（或 20006 风控）返回 `status` 为字符串 `'0'`、或 `status==2` 且无 error_code 时，`failed` 为 false，验证→提交→重试闭环根本不启动；用户路径（点播/搜索/登录）直接落到失败/回退，看不到验证入口。反之，任何带 ssa-code 的普通失败也会被拿去提交指纹，浪费一次风控往返。
- 证据等级：静态推演（与 B1 源码对照实锤；上游是否返回字符串型 status 未实测）

### kg_client.dart:69-70 `KgResponse.ssaCode` 少取 B1 认可的 `ssaCodeStr`，且对空串/非字符串未过滤
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（跨层契约一致性）、第 14 条（外部数据边界校验）
- 依据：`(body['ssaCode'] ?? body['ssa_code'] ?? headers['ssa-code'])?.toString()`；B1 `response_policy.dart:_ssaOf` 还取 `ssaCodeStr`、只对非空 String 与 num 取值、外部响应头值作为兜底。若上游只给 `ssaCodeStr`，direct 层 `ssa == null` → `requestWithVerify` 直接返回原始失败（约 366-368 行），而 B1 侧却能拿到 ssaCode 生成 `ApiException`。
- 影响：同一份 20028 响应在两条路径上判定不一致，用户遇到风控时有时弹验证、有时静默失败，呈现随机性。
- 证据等级：静态推演

### kg_client.dart:401,410-427 注释写 `/verify/user/info`，实际请求 `/verifyservice/v3/get_verify_info`；成功判定用严格 `== 1`
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」且不得与代码矛盾）、第 8 条（成功判定口径统一）
- 依据：`/// 生成 sid/edt 并提交 /verify/user/info` 对应 `request('/verifyservice/v3/get_verify_info', baseUrl: 'https://verifyservice.kugou.com', ...)`；结尾 `return r.body['status'] == 1;`，未走 `evaluateResponse`，也不检查 `r.status == 200`、`error_code`。B1 `errors.dart` 的 `ApiException.verifyUrl` 描述的是 `/get/verify/info` 返回的 url（`KGCodeTX| / KGCodeGT|`），与本直连路径不是同一端点。
- 影响：维护者/后续 UI 验证流程按注释去找「验证码 url」会找不到；上游若返回字符串 `'1'` 或 status=1 但 error_code 非 0，`ok=false` → 不重试，用户点播/搜索仍在验证后失败，且没有任何提示说明验证已提交成功但重试被放弃。
- 证据等级：静态推演（端点返回形态未实测）

### kg_client.dart:340-385 `requestWithVerify` 的 20028 闭环只在直连内部重试一次，失败不上抛为带 `ssaCode` 的 `ApiException`
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约跨层一致）、第 9 条（失败必须可观测）、第 11 条（降级触发/退出条件）
- 依据：`if (!ok) return first;` 与 `return request(...)` 原样返回 `KgResponse`；`ssa` 只在本方法局部使用，未随响应或异常传给上层；`_needsVerify` 判定「任意带 ssa-code 的失败」而非 B1 的 `requiresVerification`。B1 `ApiException` 明确带 `ssaCode`/`verifyUrl`/`body` 供 UI 验证流程使用，而直连层在验证提交失败、或重试仍失败时，返回的是裸 `KgResponse`，UI 拿不到 `needsVerification` 语义。
- 影响：用户在高风控路径（新设备首次点播/搜索）触发 20028 后，即使指纹提交失败或重试再失败，界面也只能显示通用失败/回退到 kapi，无法进入滑块/验证码验证页，形成「反复失败但永远不弹验证」的死锁。
- 证据等级：静态推演（UI 侧消费方式待上层文件确认，本范围内实锤于「无 ApiException 上抛」）

### kg_client.dart:41-52 `isOk` 的整段文档注释指向一个已被删除的 getter
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍，含注释掉/遗留半成品）、第 31 条（注释与代码一致）
- 依据：41-52 行「HTTP 200 + 业务 status 成功 … 本 getter 与 `_wrap` 的判定口径不一致 … `rg isOk` 仅此一处声明」——`KgResponse` 类中实际只剩 `errorCode`/`businessErrorCode`/`ssaCode` 三个 getter，无 `isOk`，也无 `_wrap`（`_wrap` 属 kg_direct_api_client 层）。注释仍在教后来者「细节判定仍由各端点的 `_wrap` 负责」。
- 影响：无直接用户可见后果；但 v5.0 `_wrap`→ResponsePolicy 迁移后残留的旧注释会误导后续维护者按旧口径加回 `isOk`，间接造成成功判定不一致。
- 证据等级：实锤

### kg_client.dart:192-194 与 219-224 `KgClient.dfid` 字段与 `device.dfid` 双份事实，签名实际只读 `device.dfid`
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）
- 依据：`String dfid = '';` 注释写「登录态 dfid（与 token/userid 同步…直连层签名取 kg.device.dfid）」；但 `request()` 的 `defaultParams['dfid']`、`reqHeaders['dfid']`、`_registerDeviceOnce` 的参数/头、`submitFingerprintVerification` 的 `dfid:` 全部取 `device.dfid`，本字段在本文件内没有任何读取点。
- 影响：若登录态写入只更新了 `KgClient.dfid`（切号/登录刷新路径），直连请求与指纹仍带旧设备 dfid，用户表现为登录后收藏/评论/点播仍属匿名或触发风控；是否发生取决于上层装配（见 kg_providers / kg_endpoints_auth 复核）。
- 证据等级：静态推演（本文件内零读取为实锤；上层写入位置待后续文件确认）

### kg_client.dart:469-477 `_persistDfid` 的空 catch 静默吞掉持久化失败
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 6 条（禁止吞掉异常）
- 依据：`try { onDfidRegistered?.call(dfid); } catch (_) { // 持久化失败不影响本次请求 }`，无日志、无降级值、无返回标记；`registerDevice` 仍返回 `true`。
- 影响：dfid 未落盘时用户本次能正常播放，但下次冷启动又重新走设备注册（3 次重试 + 退避），表现为首次打开变慢、偶发被风控要求验证；线上无日志可定位。
- 证据等级：实锤

### kg_client.dart:293-305 网络异常被折叠成 HTTP 502 + `status:0`，无 `error_code`、无 `ssaCode`
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（回退路径与主路径的异常形态必须一致）、第 9 条
- 依据：`on DioException catch (e) { ... return KgResponse(status: 502, body: {'status': 0, 'error': '${e.message}'}); }`——与成功/业务失败响应同为 `KgResponse`，上层若只看 `body` 会得到 `errorCode == 0`，`evaluateResponse` 判 `fail(0)`，即 `ApiException(0, ...)`；`requiresVerification` 恒 false。
- 影响：断网/超时与「业务返回空数据」在 UI 上归为同一类失败，用户无法区分「网络不通」与「内容为空」，重试引导不准确。
- 证据等级：实锤

### 文件 3/14 `lib/core/direct/kg_crypto.dart`（402 行，已从头读到尾）

### kg_crypto.dart:203-208 `aesEncryptHex` 显式传入 key+iv 时返回的 `AesResult.key` 是原始 key，而非解密端期望的 seed
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：返回语义）、第 15 条（单位/含义必须显式）
- 依据：`if (key != null && iv != null) { useKey = key; useIv = iv; }` 后 `return AesResult(str: base64.encode(out), key: seed ?? '');`，其中 `seed` 就是传入的 `key`；而 `aesDecryptPlaylistB64(base64Str, seed)`（约 326 行）把 `seed` 先 `md5(seed)` 再取前后 16 位派生 key/iv。也就是说 `key` 字段在「自动生成」分支是 seed，在「显式指定」分支是真实 AES key，同名两种语义。
- 影响：调用方若按文档把 `AesResult.key` 传给解密函数（MV 收藏/歌单删除的二进制响应解密路径），派生出的 key/iv 完全不同，解密抛错 → 用户点收藏/删除后看到操作失败或状态不刷新；是否命中取决于后续端点是否用显式 key+iv（待端点文件核对）。
- 证据等级：静态推演（同文件两函数对照实锤；上层实际调用形态待后续文件确认）

### kg_crypto.dart:83-88 `KgSignature.register` 自述「currently unused」仍保留
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）
- 依据：`/// currently unused：注册实际走 [android]（含 body）… 保留时勿在新代码中误用为注册路径。` 但 `kg_client.dart:257` 的签名 switch 仍保留 `'register' => KgSignature.register(allParams)` 分支，故该 API 不是不可达，只是无生产调用方；整类 `register` 签名是「以后可能用」的抽象。
- 影响：无直接用户可见后果；但 v5.0 重构后若新端点误选 `encryptType: 'register'`，将用「只排序值」的签名（1014 盐）打网关，表现为新功能直连恒失败并静默回退。
- 证据等级：实锤

### kg_crypto.dart:1-13 头注释「逐行移植自 helper.js + crypto.js」，三态样本与签名盐实测记录未落到本层
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条
- 依据：三种盐（android/web/register 1014）与「signature 放 query 参数」在本层仅以常量与函数存在；`KgSignature.android` 注释只说明算法，未附匿名/非 VIP/VIP 三态返回留样；`web()` 注释的「实测签名不一致」结论也无样本引用。
- 影响：无直接用户可见后果；一旦上游改签名规则，三态下直连会静默失败并落到兜底，线上缺少可追溯留样。按第 33 条标注「未实测」。
- 证据等级：未实测

### 文件 4/14 `lib/core/direct/kg_direct_api_client.dart`（662 行，已从头读到尾；为核对跨模块契约另完整读 `lib/core/api/kugou_api_client.dart`、`lib/core/utils/friendly_error.dart`）

（本文件另完整读了 `lib/core/api/kugou_api_client.dart`、`lib/core/utils/friendly_error.dart` 以核对跨模块契约；复核通过项统一列于报告末尾。）

### kg_direct_api_client.dart:74-95 `_wrap` 已迁移 `evaluateResponse`，但注释与 `_hasData` 仍保留旧口径
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与代码矛盾）、第 32 条（死代码）
- 依据：74-79 行仍写「成功判定看 `status == 1`」「`errcode`/`error_code` 为 151/152 等警告码时，只要响应里有数据就不算失败」；80-81 行才写「v5.0 M4：成功/异常判定已上移 evaluateResponse…禁止在此重写业务语义」。`_hasData`（89-95 行）在本类内仅此一处声明，而 `response_policy.dart` 有同名同职责的私有 `_hasData`（还额外排除 error 类键）；本类中的 `_hasData` 零调用。
- 影响：无直接用户可见故障，但 v5.0 重构后的注释与新实现给出相反判定口径；维护者按旧注释加回「151/152 + 任意 data」放行会把 B1 刚收紧的失败判定再次放宽，风控 20028 可能被误当成功。
- 证据等级：实锤

### kg_direct_api_client.dart:57-63 `clearCredentials()` 未清空 `kg.dfid` 与 `kg.device.dfid`，切号后仍带上一账号设备指纹
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源 / 登录态三态一致性）
- 依据：退出登录只 `kg.token=''`、`kg.userid='0'`、`kg.t1=''`，然后 `super.clearCredentials()`（父类只清自己的 `userid`/`dfid` 与 cookie jar）；而 `setCredentials` 在 dfid 非空时把 dfid 写进 `kg.dfid` 和 `kg.device.dfid`（46-52 行），`KgClient.request` 的 `defaultParams['dfid']` 与 `reqHeaders['dfid']` 恒取 `kg.device.dfid`。`kg.vipType` / `kg.vipToken` 也未复位。
- 影响：用户 A 退出、用户 B（或匿名）登录/浏览时，所有直连请求与风控指纹仍带用户 A 的 dfid 与 VIP 标记；表现为切号后 VIP 音质/权益判定串号、触发 20028 验证、收藏/评论落到错误账号上下文。
- 证据等级：实锤（本文件 + kg_client.dart 对照）

### kg_direct_api_client.dart:290-300,363-371 未移植端点抛 `-404` 且 `fallbackToKapi=false`，异常文案含内部术语
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测且用户可理解）、i18n 一致性
- 依据：两处 `throw _asDioException('/$n', ApiException(-404, '接口 /$n 尚未移植到原生网关（kapi 仅作参考，运行期不调用）'))`；`friendly_error.dart:friendlyError` 对未知 `errorCode` 直接 `return api.message`，即把这句中文技术文案原样上屏；文案硬编码中文，未走 `AppLocalizations`，与 10 语支持（`app_config.dart:supportedLocales`）不一致。
- 影响：用户在 10 种语言下看到中文「kapi/原生网关」字样；且「尚未移植」在开发视角是明确信号，在用户视角是莫名其妙的失败。未移植路径一旦被触发，功能直接失效且无回退。
- 证据等级：实锤

### kg_direct_api_client.dart:114,119-160 注释「先直连，失败则回退 kapi」与 `fallbackToKapi=false` 永久关闭相矛盾；回退分支成不可达代码
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条、第 32 条（死代码 / 不可达分支）
- 依据：`/// 先直连，失败则回退 kapi` 与 `static const bool fallbackToKapi = false;`；`_directOrFallback` 的两个 catch 内 `if (write || !fallbackToKapi || ...) throw ...;` 使 `return await kapi();`（140 行、155 行）在任何调用下都不可达，因为 `!fallbackToKapi` 恒 true。`kapi` 闭包、`kapi 回退` 日志、「PLY-09 回退路径异常统一包装」整段为遗留实现。
- 影响：无直接用户可见故障（这正是既定「只走原生网关」口径）；但 v5.0 重构后残留的死分支和矛盾注释会让后续维护者误以为存在兜底，掩盖直连恒失败问题。
- 证据等级：实锤

### kg_direct_api_client.dart:592,595-598 两个私有成员 `_qrSrcappid` / `_maskMobile` 无调用点
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码）
- 依据：`static const int _qrSrcappid = 2919;` 与 `String _maskMobile(String mobile)` 在本文件内各只出现声明一次（全文件计数为 1），实现已下沉到 `_epAuth`（`kg_endpoints_auth.dart` 待核对是否重复定义）。
- 影响：无直接用户可见后果；登录/二维码参数若需调整，改这里不起作用而改到 `_epAuth`，造成「改了没生效」的回归。
- 证据等级：实锤（本文件内计数）

### kg_direct_api_client.dart:7,14 `dart:convert` 与 `qr_flutter` 导入在本文件零使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（未使用的导入）
- 依据：`import 'dart:convert';`、`import 'package:qr_flutter/qr_flutter.dart';`；本文件 `jsonEncode/jsonDecode` 计数为 0，`QrImage/QrPainter` 计数为 0，二维码生成已委托 `_epAuth.qrPngBase64`。
- 影响：无用户可见后果；v5.0 拆分后残留的依赖会让直连层仍被误认为依赖 UI 组件（第 4 条分层单向依赖的阅读误导）。
- 证据等级：实锤

### kg_direct_api_client.dart:637-661 `_afterLogin` 用严格 `body['status'] != 1` 判成功，绕过 B1 `evaluateResponse`
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（成功判定口径统一）、第 13 条（外部数据形态归一）
- 依据：`if (body['status'] != 1) return;`——B1 `response_policy.dart:_codeOf` 会把字符串 `'1'`、num `1.0`、带空白 `' 1 '` 归一为 1；此处严格相等。`_afterLogin` 在 `_wrap` 之后再被 `_epAuth` 调用（待核对），一旦上游返回字符串 status，`_wrap` 判成功而 `_afterLogin` 直接 return，`kg.token/userid/t1` 不回写。
- 影响：用户登录页显示「登录成功」，但直连层仍处于匿名态（`kg.userid='0'`），后续点播/评论/收藏需登录的接口全部按匿名请求，出现「刚登录就提示请登录」或 VIP 音质不生效。
- 证据等级：静态推演（`_epAuth` 调用时序待第 6 个文件核对）

### kg_direct_api_client.dart:76-79,382-384 中文硬编码注释与实测口径混用，`duration` 单位说明未在类型/字段上体现
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）
- 依据：`/// duration 传毫秒：搜索结果 Duration 是秒，服务端候选 duration=269792。` 仅注释说明；`_searchLyric(q)` 直接把 `q` 透传给 `_epSearch.searchLyric`，Map 中 `duration` 无单位后缀、无类型转换，与「秒」的另一处字段同名。
- 影响：上层若按搜索结果的「秒」把 duration 回填到歌词搜索，候选匹配偏差约 1000 倍，用户看到歌词匹配到错误歌曲；单位完全依赖注释而非命名。
- 证据等级：静态推演

### 文件 5/14 `lib/core/direct/kg_endpoints_artist_album.dart`（166 行，已从头读到尾）

### kg_endpoints_artist_album.dart:1 `dart:convert` 导入零使用；主类同组注释重复
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：本文件 166 行内无 `jsonEncode/jsonDecode/base64/utf8` 调用（全部参数直接以 Map 交 `kg.request`）；`kg_direct_api_client.dart` 已对 `artistDetail/artistAlbums/albumDetail/albumSongs/artistAudios/rankAudio` 写了同名同内容的「实测」注释，本文件又完整重复一遍（如 v1/v2 差异、`kg-tid`、`is_buy` 说明）。
- 影响：无直接用户可见后果；两份注释若不同步（v5.0 R1 拆分后的典型回归），维护者按主类注释改参数而实际生效在本文件，产生「改了没生效」。
- 证据等级：实锤

### kg_endpoints_artist_album.dart:36-39,51-56,88-96 「实测 A/B/C 三形态」「实测直连 200」无留存样本与三态区分
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条
- 依据：`artistAudios` 注释列 A/B/C 三种参数形态结论与「实测 v1 匿名可返回 30 首」，`artistDetail` 注释写「curl 三种形态逐字段对比」，`rankAudio` 注释写「【实测】data 是 Map…」；全仓范围内本文件未附匿名/普通用户/付费用户三态样本链接或留样文件引用（仅指向 `docs/api_verified.md` 这一通用文档）。`artistAudios` 的 `kg-tid: 220` + `openapi.kugou.com` 与 REVIEW_SPEC 表一致，但 `albumSongs` 用 `/v1/album_audio/lite` + gateway（无 `baseUrl`）与 `artistAlbums` 用 `/kmr/v1/author/albums` + gateway 也未见「为什么一个直连原生域、另两个走 gateway」的理由。
- 影响：v5.0 重构后若上游调整返回结构，付费/VIP 用户进入歌手页/专辑页可能得到空列表而 `_wrap` 仍判成功（注释自己写明「解析会得到空列表且不会触发回退」），且线上无三态留样可定位。按第 33 条标注「未实测」。
- 证据等级：未实测

### kg_endpoints_artist_album.dart:121-140 `albumSongs` 的 `is_buy` 归一化把 `false/0/'0'` 变成空串，而 `albumDetail` 原样透传 `q['is_buy'] ?? 0`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失语义分离）、第 3 条（同一字段跨端点契约不一致）
- 依据：`albumSongs` 中 `isBuyParam` 对 0/false/'0'/'false'/null 一律取 `''`；`albumDetail` 中 `'is_buy': q['is_buy'] ?? 0`。两个端点同属专辑页一次用户路径（先进详情、再拉歌曲），同一业务字段一个传 0、一个传空串。
- 影响：用户在付费专辑页看到详情正常但曲目为空/少歌（注释自述「0 会被上游当非购买态过滤掉曲目」），或反过来详情侧按 0 判定为未购买、隐藏已购内容，呈现页面上下不一致。
- 证据等级：静态推演（上游 `is_buy` 语义未实测）

### kg_endpoints_artist_album.dart:143-165 `rankAudio` 缺 `baseUrl` 走 gateway，与主类注释「POST gateway」一致，但 `rankId` 解析失败时静默丢键
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界校验）、第 9 条（失败可观测）
- 依据：`final rankId = int.tryParse('${q['rankid'] ?? q['rank_id'] ?? ''}');` 后 `if (rankId != null) 'rank_id': rankId`——上层传入非法/空 rankid 时不报错、不记日志，直接发一个没有 `rank_id` 的请求；注释还写「此前填 0 会让上游回落到某个默认榜」，说明该键决定榜单内容。
- 影响：用户从榜单入口点进详情，若 id 形态异常会看到「默认榜」或空榜而非目标榜单，且界面无任何错误提示，误以为内容本身为空。
- 证据等级：实锤

### 文件 6/14 `lib/core/direct/kg_endpoints_auth.dart`（426 行，已从头读到尾；为核对 20028→提交→重试闭环另完整读 `lib/features/auth/data/verification_service.dart`、`captcha_types.dart`、`auth_repository.dart`）

### kg_endpoints_auth.dart:316-334 `getVerifyInfo` 用默认 gateway，而同路径的 `kg_client.submitFingerprintVerification` 用 `verifyservice.kugou.com`，两处无「为什么不同」的说明
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，含上游反常行为）、第 5 条（同一端点唯一形态）
- 依据：`kg.request('/verifyservice/v3/get_verify_info', method:'POST', ...)` 未传 `baseUrl` → 默认 `KgConfig.gateway`；`kg_client.dart:410-412` 对同一路径用 `baseUrl: 'https://verifyservice.kugou.com'` 且 `params: {'clientver': ...}`，`verifyUserInfo`（约 369 行）也用 `https://verifyservice.kugou.com`。三处同名/近名端点分落两个域、参数集不同，本文件注释只写「对应 module/get_verify_info.js」未说明差异理由。
- 影响：无已证实的用户可见故障；但 v5.0 后若其中一个域被上游限流，维护者无法从代码判断该改哪一处，验证类型查询与提交会出现单点失败。按第 28 条标注「未实测」。
- 证据等级：未实测（三处代码形态对照实锤；gateway 是否可路由该路径未实测）

### kg_endpoints_auth.dart:337-368 `verifyUserInfo` 对 sid/edt/verifycode 无条件 `Uri.decodeComponent`，而 `VerificationService.submit` 把 Base64 原值同时放 body 与 query
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界校验）、第 13 条
- 依据：`final sid = Uri.decodeComponent('${d['sid'] ?? ''}');`、`final edt = Uri.decodeComponent(...)`、`'verifycode': Uri.decodeComponent('${d['verifycode'] ?? ''}')`、`'code': Uri.decodeComponent(...)`；`VerificationService.submit` 直接把 `edt.sid`（RSA-OAEP 结果的 Base64，可含 `+`、`/`、`=`）放进 `query` 并以 `query` 作为 body 与 query 双发，未做 `Uri.encodeComponent`。Dio 对 query 会做 percent-encoding，但 body 是原始 Map；本端点对 body 值再解码一次，`+` 在 form 解码语义下会被转成空格（若上游或 Dio 做过一次 form 解码）。另 `vType` 非 23/32 时 `verifycode`/`code` 被静默丢弃。
- 影响：用户完成滑块/短信验证后提交，sid/edt 中的特殊字符被再次解码导致服务端校验失败，验证→提交→重试闭环停在提交步，表现为「验证通过却仍反复要求验证」。
- 证据等级：静态推演（上层传值与本层解码为实锤；服务端/ Dio 实际编码链未实测）

### kg_endpoints_auth.dart:383-413 与主类 `kg_direct_api_client.dart:637-661` 存在两份 `_afterLogin`，主类那份是死代码
- 级别：P2
- 违反：QUALITY_STANDARD 第 32 条（死代码）、第 5 条（状态单一来源）
- 依据：`KgDirectApiClient._afterLogin` 在 662 行文件内无任何调用点（所有 `_epAuth.login*` 内部调用的是 `KgEndpointAuth._afterLogin`）；两份实现内容近乎相同，但**只有 `KgEndpointAuth` 版本**回写 `kg.vipType` / `kg.vipToken`（407-413 行），主类版本没有。
- 影响：三态（匿名/非 VIP/VIP）判定依赖 `vipType`；若 v5.0 拆分后某条登录路径误调主类版本，VIP 用户登录成功但音质/权益仍按非 VIP，且无任何提示。当前生产路径走 `_epAuth`，属重构残留风险。
- 证据等级：实锤

### kg_endpoints_auth.dart:385 `_afterLogin` 严格 `body['status'] != 1` 判成功，与 B1 `evaluateResponse` 归一不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（成功判定单点）、第 13 条（外部数据形态归一）
- 依据：`if (body['status'] != 1) return;`；而 `KgDirectApiClient._wrap` 已用 `evaluateResponse`（`_codeOf` 支持 `'1'`、`1.0`、带空白），`_wrap` 先于 `_afterLogin` 判定：`KgEndpointAuth.login*` 内部 `await kg.request(...)` → `_afterLogin(r, ...)` → `return r` → `_directOrFallback` 才对 `r` 调 `_wrap`。因此字符串型 `status='1'` 的登录响应会「`_wrap` 判成功、`_afterLogin` 不回写 token」。
- 影响：登录页显示成功并落盘 token，但直连 `kg.token/userid/t1/vipType` 全部保持匿名；紧接着点播/评论/收藏等需登录接口按匿名发送，用户遇到「刚登录就要求登录」或 VIP 档位不生效。
- 证据等级：静态推演（调用时序实锤；上游是否返回字符串 status 未实测）

### kg_endpoints_auth.dart:260-283 二维码登录成功态（`status=='4'`）只回写 token/userid，未回写 t1/vip 三态，也未走 `_afterLogin`
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（登录态三态一致）
- 依据：`if (data is Map && '${data['status']}' == '4') { ... kg.token = token; kg.userid = userid; }`——`kg.t1`、`kg.vipType`、`kg.vipToken`、`kg.dfid` 均未更新；`AuthRepository.checkQr` 会把 `t1` 返回给上层但直连层不知。
- 影响：扫码登录用户与密码/短信登录用户在同一次会话里状态不同：刷新登录态（`loginToken` 里 `t1Plain = kg.t1.isNotEmpty ? ... : '|$dateNow'`）缺 t1、VIP 音质与权益判定按非会员；用户需再触发一次 token 刷新才恢复。
- 证据等级：实锤

### kg_endpoints_auth.dart:239-253 `loginQrCreate` 本地合成 `status: 200` 响应，与 B1 `evaluateResponse` 的「status==200 且 ec 在白名单」耦合
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回形态契约）、第 8 条
- 依据：返回 `body: {'code':200,'status':200,'data':{...}}`，无 `error_code`/`errcode`；`evaluateResponse` 分支 4 `if (status == 200) { if (_warningCodes.contains(ec)) return ok; ... }`，`ec` 由 `_codeOf(null) = 0` 得到，`0 ∈ _warningCodes` 才放行。也就是说这个本地合成端点能否被上层消费，依赖 B1 白名单仍包含 0；同时 `AuthRepository.getQrKey` 读的是 `d2['key'] / d2['qrcode_img'] / d2['base64']`，本实现返回 `data.url/base64/key`，`qrcode_img` 字段缺失（靠 `base64` 兜底）。
- 影响：B1 未来收紧 200 分支（例如不允许 ec=0）或上层只读 `qrcode_img` 时，用户扫码登录页显示空白二维码，且这是纯本地生成、没有网络错误提示可依赖。
- 证据等级：静态推演（B1 白名单与 AuthRepository 字段读取均为实锤）

### kg_endpoints_auth.dart:285-314 `userDetail` 修改上游响应 `inner['userid']`，且匿名态 userid 被硬编码为 '0'
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（「未登录」与「已登录但无内容」语义分离）、第 14 条（外部数据边界）
- 依据：`inner['userid'] = userid.toString();` 其中 `userid = int.tryParse(...) ?? 0`；`AuthRepository.getUserDetail` 用 `'${d['userid'] ?? ''}'` 构造 `AuthUser`。匿名调用时把 `'0'` 写进响应，上层拿到 `userid='0'` 而非空。
- 影响：上层若以 `userid.isNotEmpty` 判断登录态，匿名用户会被判定为已登录（id 为 `0`），账号三态错乱，UI 显示错误的「已登录」入口。
- 证据等级：静态推演

### kg_endpoints_auth.dart:1-10,15-20 「R1 重构：行为与拆分前完全一致」与同文件两份重复实现、主类同名私有方法矛盾
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与代码一致）
- 依据：文件头写「从 kg_direct_api_client.dart 拆出…行为与拆分前完全一致」，但主类 `kg_direct_api_client.dart:591-598` 仍保留 `_qrSrcappid` / `_maskMobile` 的副本、`:637-661` 保留 `_afterLogin` 副本；本文件也各有一份。`kg_direct_api_client.dart` 的 `dart:convert`、`qr_flutter` 导入仍存在。
- 影响：无直接用户可见后果；v5.0 拆分后的重复实现会让「改一处没生效」成为高发回归（已在 VIP 字段上实际发生，见上一条）。
- 证据等级：实锤

### kg_endpoints_auth.dart:38-52 `registerDev` 失败时返回 HTTP 200 + `status:0` 且无 `error_code`，`getDfid()` 的上层静默吞异常
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条
- 依据：`return KgResponse(status: 200, body: {'status':0,'error':'设备注册失败'})`；`AuthRepository.getDfid()` 用 `try { ... } catch (_) {}` 且「失败返回空串且不落盘」，直连 `_wrap` 会把该体转成 `ApiException(0, '设备注册失败')`，但上层 `catch (_)` 无任何日志。
- 影响：设备注册连续 3 次失败时用户无任何提示，后续所有直连请求以 `dfid='-'` 发送，容易被 20028 风控反复拦截；登录/首启路径耗时增加且无线索定位。
- 证据等级：实锤

### 文件 7/14 `lib/core/direct/kg_endpoints_comment.dart`（301 行，已从头读到尾；为核对「评论发送」用户路径另完整读 `lib/features/comment/data/comment_repository.dart`，确认 `sendComment/sendFloorReply/deleteComment` 均以 `_api.post(path, {}, query: query)` 传参，故主类 `post()` 只取 `q` 与实际契约一致，前一条疑问已撤销，不计入问题）

### kg_endpoints_comment.dart:64-118 评论写端点未使用 `requestWithVerify`，20028 时抛出后由 UI 决定是否重试，但 `write:true` 且无提交锁
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作必须幂等或有防重机制）、第 8 条（异常契约单一）
- 依据：`commentSend` / `commentFloorSend` / `commentDel` 全部 `kg.request(...)`（正确避开自动重试），`_directOrFallback(..., write: true)` 禁止 kapi 回退；但 `commentSend` 无幂等键/去重锁，客户端时间戳 `clienttime` 每次都重新生成、`key` 随内容变化。`KgClient.requestWithVerify` 的注释明确「写端点必须直接调 request，把 20028 上抛交给 UI 验证流程处理」，而 UI 的「验证成功后重试原请求」会重新调用 `commentSend`，生成新的 `clienttime` 与 `key`，服务端若首次已执行则形成重复评论。
- 影响：用户发评论命中 20028 → 完成滑块验证 → 重试，出现两条相同评论；或首次请求已成功但响应被风控拦截时同样重复。删除评论重试则表现为二次删除报错。
- 证据等级：静态推演（UI 重试链路依据 `VerificationService` 注释与本层无锁；服务端幂等性未实测）

### kg_endpoints_comment.dart:31-42 歌曲评论列表用 `/v1/cmtlist` + x-router，歌单/专辑评论用 `/m.comment.service/v1/cmtlist`，两套路径成败口径不同
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（同类端点唯一事实源）、第 8 条
- 依据：`commentMusic` 走 `'x-router': 'm.comment.service.kugou.com'` + `/v1/cmtlist`（注释 A/B/C/D 四种 curl 实测），`commentPlaylist` / `commentAlbum`（248-283 行）走 `/m.comment.service/v1/cmtlist` 且**不带 x-router**；`commentFloor` 对 playlist/album 又用 `/m.comment.service/v1/hot_replylist`。B1 `evaluateResponse` 对 mcomment 统一先看 `body.containsKey('err_code')`，而注释写「歌单评论 code 配 /m.comment.service 端点才返回 err_code=0」，说明不同路径的返回形态依赖。
- 影响：用户从歌曲评论页切到歌单/专辑评论页，同一个「发送/回复」动作在一处成功、另一处返回 err_code 60102 被判失败；由于 `write:true` 且 `fallbackToKapi=false`，界面直接报错，呈现入口间不一致。
- 证据等级：静态推演（路径差异实锤；上游返回未实测）

### kg_endpoints_comment.dart:52-62 `commentCount` 返回裸 Map 但 `fetchCount` 用 hash 大小写三次查找
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合/缺失语义分离）、第 13 条
- 依据：`commentCount` 用 `KgClient.request` 解析 body：`jsonDecode(raw)` 若非 Map 则包成 `{'data': decoded}`；`CommentRepository.fetchCount` 读 `data[hash] ?? data[hash.toUpperCase()] ?? data[hash.toLowerCase()]`，未取 `data['data']`。若上游返回 `{'data': {hash: n}}` 形态，`fetchCount` 得到 0 且无错误。B1 `evaluateResponse` 分支 7「无 status 但带数据：裸 Map 成功」正是为此设计，说明裸 Map 是预期形态。
- 影响：用户看到评论数恒为 0，无法判断是「确实无评论」还是解析错位；计数与评论列表条数不一致。
- 证据等级：静态推演（上游裸 Map 形态未实测）

### kg_endpoints_comment.dart:1-4,8-12 「R1 重构：行为与拆分前完全一致」+ 主类重复 `_commentCodeOf` 实现
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 31 条
- 依据：`kg_direct_api_client.dart:417-421` 有 `static String _commentCodeOf(...)` 且零调用；本文件 218-223 行有同名同值实现。`dart:convert` 在本文件只用于 `jsonEncode`（真实使用），非死导入；主类与端点组的注释重复（如「实测 A/B/C/D」只在端点组）。
- 影响：无直接用户可见后果；资源类型码若需新增（如 MV 评论），改主类副本不生效。
- 证据等级：实锤

### 文件 8/14 `lib/core/direct/kg_endpoints_home.dart`（198 行，已从头读到尾）

### kg_endpoints_home.dart:140-159 注释仍写「失败由 _wrap 抛出 → _directOrFallback 回退 kapi → fetchBanners 容错置空」，与 `fallbackToKapi=false` 冲突且引用了禁止阅读的历史报告文件
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与代码矛盾）、第 9 条（失败可观测）
- 依据：`/// 【实测 2026-11-06】匿名态恒返回 error_code=31136… 失败由 _wrap 抛出 → _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空。`；而 `kg_direct_api_client.dart:103` `static const bool fallbackToKapi = false;`，`_directOrFallback` 内 `!fallbackToKapi` 恒真，直接 `throw _asDioException(...)`，kapi 分支永不可达。注释还引用 `docs/batch4_fix_1_network.md`（本任务禁止读的历史报告）。同类注释在 `topPlaylist`（约 90 行）也写「此前注释恒 200101 已不成立 —— 见 docs/batch4_fix_1_network.md F4-11」。
- 影响：匿名/非 VIP 用户进首页时 banner 请求必然抛 `ApiException(31136)`，绝不会「回退 kapi」；若上层 `fetchBanners` 确实捕获并置空，用户看到的是**无 banner 的首页**且日志里只有一条被 `_logError` 记录的 31136，维护者按注释会去查 kapi 回退链路而误判。用户可见后果为首页内容缺失且无提示。
- 证据等级：实锤

### kg_endpoints_home.dart:151-157 `yuekuBanner` 依赖 `kg.vipType`，但退出登录不清空 VIP 字段，且 `vip_type` 单位/取值无三态契约
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（登录态单一来源）、三态一致性
- 依据：`'vip_type': int.tryParse(kg.vipType) ?? 0`；`kg.vipType` 只在 `KgEndpointAuth._afterLogin` 写入（`vipType != null && vipType.isNotEmpty` 才更新），`KgDirectApiClient.clearCredentials()`（57-63 行）未复位 `vipType/vipToken`；`KgClient.vipType` 默认 `'0'`。注释写「匿名/非 VIP 为 0」但代码无「非 VIP 登录成功时显式写 0」的保证。
- 影响：VIP 账号退出后以匿名态进入首页，banner 仍按 VIP 请求会员专属位；或 VIP 登录后上游返回 `vip_type=''` 时保留上一账号值，首页 banner 串号。用户看到不属于当前账号的推荐位。
- 证据等级：静态推演（上游 `vip_type` 取值未实测）

### kg_endpoints_home.dart:169-197 与主类 `kg_direct_api_client.dart:555-573` 存在两份 `videoDetail` 实现
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（唯一事实源）、第 32 条（重复实现）
- 依据：主类 `_videoDetail(q)` 内联了 `clienttime`/`dfid`/`data` 构造并调 `kg.request('/v1/video', ...)`；本文件 `videoDetail(q)` 是逐字段相同的另一份。主类 `get()` 的 `case 'video/detail'` 调 `_videoDetail(q)`（277-278 行），**不**委托 `_epHome.videoDetail`，故本文件的实现是无人调用的副本（MV 播放/详情路径实际走主类那份）。
- 影响：MV 播放用户路径（hash→video_id 反查后拉视频详情）的真实实现藏在主类，维护者改端点组不生效；若两份参数未来漂移，MV 清晰度/分辨率字段解析不一致且无编译错误。
- 证据等级：实锤

### kg_endpoints_home.dart:1-12,28-30 「R1 重构：行为与拆分前完全一致」与残留空注释 `/// 歌手详情（module/artist_detail.js）`
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条、第 32 条
- 依据：本文件是「首页与榜单端点」，30 行却留着 `/// 歌手详情（module/artist_detail.js）` 孤立注释，下面紧跟 `rankList`；`dart:convert` 在本文件零使用（无 jsonEncode/jsonDecode）。
- 影响：无用户可见后果；v5.0 拆分残留误导后续维护。
- 证据等级：实锤

### kg_endpoints_home.dart:80-125 `topPlaylist` 的「实测可用」结论与 REVIEW_SPEC 既知约束冲突且无三态留样
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条、第 33 条（kapi 包装结果不得作原生实测依据）
- 依据：注释写「【实测 2026-11-06】gateway + x-router 直连可用…special_list 35 条（旧实现 4 字段版本只剩 30 条）」，并引用 `docs/batch4_fix_1_network.md`；而 `docs/REVIEW_SPEC.md` 的既知约束写「`top/playlist`（`/v2/special_recommend`）直连恒 `200101`，保留 kapi 回退」。两者结论相反，且本文件未附匿名/普通/VIP 三态样本；当前 `fallbackToKapi=false` 使该端点一旦回到 200101 就直接抛错给首页。
- 影响：用户打开首页「推荐歌单」板块时若上游恢复 200101，板块整块报错且无回退；由于注释与规范冲突，线上定位时被误导为「已实测可用」。按第 33 条标注「未实测（kapi 包装结果需原生复核）」。
- 证据等级：未实测

### 文件 9/14 `lib/core/direct/kg_endpoints_media.dart`（131 行，已从头读到尾）

### kg_endpoints_media.dart:82-85 `songUrl` 注释声称「直连仍可能遇 20028，_directOrFallback 已兜底回退 kapi」，与实际永久关闭的回退冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与代码矛盾）、第 8 条（风控异常契约）
- 依据：`// 直连仍可能遇 20028（与 IP/风控相关），_directOrFallback 已兜底回退 kapi。`；实际 `kg_direct_api_client.dart:103` `fallbackToKapi = false`，且 `_directOrFallback` 对 `e.needsVerification` 显式 `throw _asDioException(label, e)`（133-137 行），不会回退。`/song/url` 走 `get()` 分派（203 行）未标 `write`，但仍命中「不回退」分支。
- 影响：用户点播遇到 20028 时，播放地址请求直接抛 `ApiException(20028)`；若播放器未挂验证监听器，表现为「点歌无反应/一直转圈」而非弹出验证页。维护者按注释以为有 kapi 兜底，会误判风控故障范围。
- 证据等级：实锤（注释与常量/分支对照；UI 是否挂监听器在本范围外）

### kg_endpoints_media.dart:75-80 `songUrl` 把 `quality` 默认硬编码 `'128'`，与 B1 `AudioQuality` 九档/设置页来源无对接校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（输入取值范围契约）、第 16 条
- 依据：`quality: '${q['quality'] ?? '128'}'` 直接透传给 `KgSharedParams.songUrl`；`lib/core/domain/quality.dart` 定义 5 通用档 + 3 蝰蛇 + 6 魔法共 14 个枚举值（其中设置页九档为关注点），`AudioQuality.fromString` 对未知值降级 `q128` 并调 `QualityDiagnostics.onUnknownValue`。本端点对 `q['quality']` 无任何白名单/归一，缺失即 128。
- 影响：设置页选了「Hi-Res/臻品母带/蝰蛇」但上层若漏传或传了别名 `'hires'`，直连实际按 128k 请求，界面显示已生效而音质没变（正是 `quality.dart` 注释所警告的数据一致性红线）；此类静默错误用户只能靠听感发现。
- 证据等级：静态推演（上层是否传值待 `player_repository` 核对，本范围外）

### kg_endpoints_media.dart:43-45 注释引用 `AppConfig.proxyMvUrl`，而 `app_config.dart` 全文只有 `proxyBase`
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与代码一致）
- 依据：`// downurl 为 http://，代理转换在 Repository 层 AppConfig.proxyMvUrl 完成`；完整读过的 `lib/core/config/app_config.dart` 中只有 `kugouApiBase` / `translateApiBase` / `proxyBase` / `translateModel` 等常量，无 `proxyMvUrl`。
- 影响：无直接用户可见故障；但 MV 播放链路（hash→video_id→downurl）的代理转换位置按注释会找错文件，v5.0 后若代理常量改名，排查 Android 9+ 明文 http 播放失败时会被误导。
- 证据等级：实锤

### kg_endpoints_media.dart:1-11,37-41 `dart:convert` 零使用；`videoUrl` 声明 `async` 但只有一个 `await` 后立即 `return r`
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码/冗余）
- 依据：本文件无 `jsonEncode/jsonDecode/base64/utf8` 调用；`Future<KgResponse> videoUrl(Map q) async { final r = await kg.request(...); return r; }` 等价于直接返回 `kg.request(...)`，无后置处理。
- 影响：无用户可见后果；MV 播放路径多一层无意义包装，掩盖「hash 反查后无任何返回形态校验」这一事实（见下条）。
- 证据等级：实锤

### kg_endpoints_media.dart:36-62 `videoUrl` 不做 `hash` 空值/形态校验，直接以空 hash 请求 `trackermv.kugou.com`
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（数据边界校验）、第 9 条
- 依据：`final hash = '${q['hash'] ?? ''}';` 后无 `_nonEmpty` 检查即发请求，`key` 用 `KgSignature.keyOf(hash: hash, ...)`；对比同文件 `privilege`（约 106-118 行）有「空 hash 前置拦截」并返回明确 `error: '缺少歌曲 hash'`，同一文件两个端点边界策略不一致。
- 影响：用户从歌曲页点 MV 但 hash 缺失（部分榜单/电台条目无 MV hash）时，会发出一个必然失败的请求，界面显示通用网络错误而非「该歌曲无 MV」，MV 播放入口表现不一致。
- 证据等级：实锤

### kg_endpoints_media.dart:22-35,93-110 `kmrAudioMv` 与 `privilege` 的「实测匿名/VIP 200 status=1，0 差异」未附三态留样
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条
- 依据：`kmrAudioMv` 注释写「匿名/VIP 实测 200 status=1，与 kapi 逐字段一致（0 差异）」、`videoUrl` 同样写「匿名/VIP 实测…与 kapi 逐字段一致（0 差异）」；`kg_crypto.dart` 无相关样本链接，`docs/REVIEW_SPEC.md`/第 33 条明确 kapi 包装结果不得作原生网关实测依据。三态中的「普通用户（非 VIP）」在注释里缺席。
- 影响：MV 播放（hash→video_id 反查）与音质权益在非 VIP 态的真实返回无留样；上游返回形态变化时 `evaluateResponse` 可能把「有 status=1 但无数据」判成功，表现为 MV 详情空白/音质降级且无线索。按第 33 条标注「未实测」。
- 证据等级：未实测

### 文件 10/14 `lib/core/direct/kg_endpoints_playlist.dart`（288 行，已从头读到尾）

### kg_endpoints_playlist.dart:48-59 `playlistDel` 解密失败被空 catch 吞掉，回退到未解密的二进制响应体
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 8 条（异常契约一致）
- 依据：`try { ... KgCrypto.aesDecryptPlaylistB64(base64Encode(bytes), aes.key) ... } catch (_) { // 解密失败不影响判定 } return res;`；`KgClient.request` 对二进制响应会先 `utf8.decode(allowMalformed: true)` 再 `jsonDecode`，失败时构造 `body = {'status': 0, 'error': '响应解析失败', 'raw': ...}`。因此解密失败时 `_wrap` 拿到的是 `ApiException(0, '响应解析失败')`，而 `playlistDel` 是 `write: true`（`kg_direct_api_client.dart:222-224`）禁回退。
- 影响：用户点「删除/取消收藏歌单」时，服务端可能已删除成功，但客户端返回「响应解析失败」并回滚 UI，出现「删了又回来」或提示失败却已生效的静默错误；无任何日志指向解密环节。
- 证据等级：实锤（解密与 `KgClient.request` 二进制解析链路对照）

### kg_endpoints_playlist.dart:65-95 `playlistAdd` 的 `type` 缺省 0 且 `type==1` 分支 query 为空，写操作无防重键
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作幂等/防重）、第 3 条
- 依据：`final type = int.tryParse('${q['type'] ?? 0}') ?? 0;`；`params: type == 0 ? {last_time, last_area, userid, token} : const {}`，即收藏公共歌单（type=1）时 `last_time/last_area` 不发；`playlistAdd` / `playlistTracksAdd` / `playlistTracksDel` 均无去重键或提交锁，均标 `write: true`。`clienttime` 每次新生成，重试或用户快速双击会生成不同 `key`。
- 影响：用户点「收藏歌单」或「添加歌曲到歌单」时双击/验证后重试，产生两个同名歌单或歌单内重复曲目；type 参数缺失时意外走「新建歌单」而不是「收藏」，表现为歌单列表多出一个空歌单。
- 证据等级：静态推演（服务端幂等性未实测）

### kg_endpoints_playlist.dart:196-214 `playlistDetail` 的越界/缺参抛裸 `ApiException`，被 `_directOrFallback` 泛 catch 二次包装
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一）、第 9 条
- 依据：`throw ApiException(-2, '歌单详情缺少 global_collection_id')` / `throw ApiException(-2, '...最多 10 个 gid...')` 在 `_directOrFallback` 的 `try` 内由 `direct()` 闭包同步抛出；`catch (e)` 分支 `_logError(label, e)` 后 `throw _asDioException(label, e)` 再包一层 DioException。最终形态与 `on ApiException` 分支一致，但错误文案硬编码中文、`errorCode=-2` 在 `friendly_error.dart` 无映射（未知码直接 `return api.message`）。
- 影响：用户从排行榜/分享链接进入歌单详情，参数异常时看到「歌单详情缺少 global_collection_id」这类开发术语，且 10 种界面语言下均为中文；`lastErrors` 里也会留下无用户价值的记录。
- 证据等级：实锤

### kg_endpoints_playlist.dart:265-287 `_parseTracksResource` 把 `timelen` 固定为 0，且 `bitrate/size` 全 0，单位无显式标注
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）、第 17 条（数值精度）
- 依据：`'timelen': 0, 'bitrate': 0, 'size': 0, 'sort': 0, 'number': 1`，注释写「补齐 Node 必带的 number/size/sort/timelen/bitrate 五字段」但全部填 0；`f0(2)/f0(3)` 用 `int.tryParse(...) ?? 0` 把无法解析的 album_id/mixsongid 静默变 0。`timelen` 未标秒/毫秒，`bitrate` 未标 kbps，`size` 未标字节。
- 影响：用户把歌曲加入自建歌单后，服务端若依赖 `timelen`/`bitrate` 展示时长与音质，列表里显示 0:00 或音质标识缺失；非法 id 变 0 会让加歌落到错误曲目而不报错。
- 证据等级：静态推演（服务端是否回显这些字段未实测）

### kg_endpoints_playlist.dart:157-159,170-172 残留孤立注释 `/// 歌单评论（module/comment_playlist.js）` 与「R1 行为完全一致」
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条、第 32 条
- 依据：157-159 行注释下紧跟 `playlistDetail` 的文档，二者无关（评论实现已移到 `kg_endpoints_comment.dart`）；`import '../foundation/errors.dart' show ApiException;` 为真实使用（playlistDetail 抛异常），非死导入。
- 影响：无用户可见后果；v5.0 拆分残留。
- 证据等级：实锤

### kg_endpoints_playlist.dart:19-47 `playlistDel` 的 AES 二进制响应解析无三态留样，且 p 参数大小写与注册路径相反
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条
- 依据：`rsaEncryptPkcs1(...).toUpperCase()`（大写 hex），而 `kg_client.dart:481-484` 注册路径明确注释「`p` 用小写 hex（对齐 Node forge.util.bytesToHex）」；两者是否各自对应不同 Node 模块未见留样说明。另「响应是 AES 加密二进制」的结论无匿名/普通/VIP 三态样本。
- 影响：用户删除歌单时若上游 p 大小写敏感，直连恒失败且无回退（`write:true`）；当前只能标注「未实测」。
- 证据等级：未实测

### 文件 11/14 `lib/core/direct/kg_endpoints_search.dart`（153 行，已从头读到尾）

### kg_endpoints_search.dart:98-101 `searchLyric` 把 `duration` 当秒又乘 1000，变量名 `durationSec` 与注释「duration 传毫秒」自相矛盾
- 级别：P1
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）
- 依据：文件注释「duration 传毫秒：搜索结果 Duration 是秒，服务端候选 duration=269792」；代码 `final durationSec = int.tryParse('${q['duration'] ?? 0}') ?? 0;` → `'duration': q['duration_ms'] ?? durationSec * 1000`。即 `q['duration']` 被解释为**秒**，再乘 1000 转毫秒；但 `q['duration']` 这个键名在主类 `kg_direct_api_client.dart:384` 的注释里被称为「duration 传毫秒」，且 `q['duration_ms']` 若已存在则原样使用（单位毫秒）。同名 `duration` 在两处含义相反。
- 影响：上层若按搜索结果把 `duration=269`（秒）传进来，发出 `269000` ms 是对的；但若按注释把毫秒 `269792` 传进来，发出 `269792000` ms（约 75 小时），歌词候选匹配失效 → 用户搜歌词/播放时匹配到错误歌词或匹配不到。单位差 1000 倍正是第 15 条所述难定位缺陷。
- 证据等级：实锤（同文件注释与运算对照；上层实际传值形态待 B5/B8 核对）

### kg_endpoints_search.dart:20-24 `search` 的 `type` 用 `contains(q['type'])` 判类型，非 String 输入与 `special/lyric` 分支共用 `/v1/search/$type`
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界校验）、第 3 条
- 依据：`['special','lyric','song','album','author','mv'].contains(q['type']) ? q['type'] as String : 'song'`；未列入白名单的 type 静默退化为「歌曲搜索」，用户/深链传入拼写错误时无任何反馈；`type == 'lyric'` 走 `/v1/search/lyric`，而文件注释与 `searchLyric` 明确写「lyrics.kugou.com 上 `/v1/search` 恒返回空响应体 + 20010」，两者是不同域但同名版本化路径，易混。
- 影响：用户在搜索页选「歌词」标签（若上层用 `type: 'lyric'` 走 `/search` 而非 `/search/lyric`）会得到空结果，界面显示「无结果」而不是错误提示；拼写错误的 type 会返回歌曲结果，呈现错位内容。
- 证据等级：静态推演（上层 type 取值待 B8 核对）

### kg_endpoints_search.dart:120-124 `lyric` 缺参抛裸 `ApiException` 且文案硬编码中文
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约）、i18n 一致性
- 依据：`throw ApiException(-1, '歌词下载参数缺失（id/accesskey）')` 在 `_directOrFallback` 的 `direct()` 闭包内，会被泛 `catch (e)` 包成 DioException；`friendly_error.dart` 对 `errorCode == -1` 无映射，直接返回 `api.message`。
- 影响：用户点播歌曲但歌词 id/accesskey 缺失（部分音源/版权曲目）时，10 种语言界面统一看到中文「歌词下载参数缺失（id/accesskey）」这类开发术语，而非「暂无歌词」。
- 证据等级：实锤

### kg_endpoints_search.dart:144-148 `decode=true` 时 Base64 解码失败被完全空 catch 吞掉
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条
- 依据：`try { body['decodeContent'] = utf8.decode(base64.decode(content), allowMalformed: true); } catch (_) {}`——`decodeContent` 不写入、无日志、无错误标记；`_wrap` 只判 `evaluateResponse(r.body)`，看不到解码失败。
- 影响：用户播放 KRC/LRC 歌词时，上游返回损坏内容 → 界面显示空白歌词页且状态是「加载成功」，无法区分「歌曲无歌词」与「解码失败」；线上无日志。
- 证据等级：实锤

### kg_endpoints_search.dart:105-117 `searchLyric` 用 `clearDefaultParams + notSignature`，与 REVIEW_SPEC「歌词 `/v1/search` 必须带 signature」的口径需区分路径
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 31 条（注释与规范口径）
- 依据：本实现打的是 `https://lyrics.kugou.com/search`（无 `/v1` 前缀），注释写「该接口不校验 signature」；而 REVIEW_SPEC 表格写「`lyrics.kugou.com` | `/v1/search`（**必须带 signature**）、`/download`（需 `ver:1&charset=utf8`）」。两者针对不同路径，`/download` 参数已带 `ver:1` 与 `charset:'utf8'`，但注释未说明「为什么此路径免签」与「与 /v1/search 的关系」以外的对照记录，也无三态留样。
- 影响：无直接用户可见故障；v5.0 后若上游对 `/search` 也开始校验签名，搜歌词将全量静默失败并落到「无结果」；按第 33 条标注「未实测」。
- 证据等级：未实测

### kg_endpoints_search.dart:1-4,8-12 「R1 行为完全一致」与主类同名注释并存，两份注释对 `duration` 单位说明口径不同
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条
- 依据：文件头「从 kg_direct_api_client.dart 拆出（R1 重构）；…行为与拆分前完全一致」；而 `kg_direct_api_client.dart:376-384` 仍保留同名 `_searchLyric` 文档注释（含「duration 传毫秒」），两份注释并存且单位说明口径不同（主类说传毫秒、本文件实现按秒乘 1000）。
- 影响：间接助长上一条 P1 单位错位——维护者按主类注释改调用方传值后，歌词搜索匹配全错。
- 证据等级：实锤

### 文件 12/14 `lib/core/direct/kg_media_direct.dart`（89 行，已从头读到尾）

### kg_media_direct.dart:52-89 第三份 `videoDetail` 实现（`KgClient` 扩展），且无 `x-router` 之外的 baseUrl 差异说明
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（同一端点唯一事实源）、第 32 条（重复实现）
- 依据：`extension KgMediaDirect on KgClient` 的 `videoDetail({required String videoId})` 与前两份实现（`kg_direct_api_client.dart:555-573` 的 `_videoDetail(Map q)`、`kg_endpoints_home.dart:169-197` 的 `videoDetail(Map q)`）逐字段相同：`/v1/video` + `clearDefaultParams:true` + `x-router: kmr.service.kugou.com` + `show_resolution:1`。三者差别仅在入参（`String videoId` vs `Map q` 支持逗号串）与主类/端点组版本支持多 id。MV 播放路径的 hash→video_id 反查若走扩展方法，只能一次查 1 个 video_id。
- 影响：MV 播放/批量清晰度获取时，同一端点三份实现参数能力不一致；维护者改其中一份（例如补 `resolution` 字段）不生效，用户表现为部分入口能看到高清档、部分入口只有默认清晰度，且无编译错误。
- 证据等级：实锤

### kg_media_direct.dart:36-47 `images` 把 query 手工拼进 path 字符串，签名形态依赖 `KgSignature.android` 的隐式 jsonEncode 且与 REVIEW_SPEC 白名单不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 27/28 条（请求形态须实测）、第 2 条（显式优于隐式）
- 依据：`return request('/v2/author_image/audio?${Uri(queryParameters: q).query}', baseUrl: 'https://expendablekmr.kugou.com', clearDefaultParams: true, notSignature: true)` 未传 `params`；`KgClient.request` 仍执行 `_dio.request('$baseUrl$path', queryParameters: allParams, ...)`，`allParams` 为空 Map，实际请求靠 **path 内已编码的 query 串**发送。签名 `KgSignature.android(params, lite: lite)` 对 `params['data']`（`List<Map>`）内部 `jsonEncode`，`q` 也把 List/Map `jsonEncode`，二者恰好一致但这一致性没有任何注释或契约保证；`clearDefaultParams: true` 不在 REVIEW_SPEC 列出的 5 处已验证端点内（`/search` 歌词、`/index.php`×3 评论写、`/v1/video`）。
- 影响：用户浏览歌曲封面/歌手图时，若上游对 query 顺序或编码敏感，直连返回失败或空 `cover`，界面显示占位图；因 `clearDefaultParams` 端点不在 REVIEW_SPEC 的 5 处已验证白名单内，属未验证形态。
- 证据等级：未实测

### kg_media_direct.dart:17-29 封面查询的 hash/album_id/album_audio_id 按逗号索引对齐，长度不等时静默补 '0'
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条、第 17 条（标识符精度）
- 依据：`final albums = albumId.split(','); final aas = albumAudioId.split(',');`；`hash.split(',')` 过滤空串，但 albums/aas 不过滤也不 trim；`i < albums.length ? albums[i] : '0'` 缺项补 `'0'`。当调用方传入的 album_id 列表比 hash 短或顺序不同，所有对应项错位且无校验。
- 影响：用户看到歌曲封面串到另一首歌（错图），这类「看起来成功但内容错」的问题在列表滚动时最明显且无错误日志。
- 证据等级：实锤

### kg_media_direct.dart:56-62 注释引用的证书实测结论无三态留样（与 home/主类注释三处重复）
- 级别：P3
- 违反：QUALITY_STANDARD 第 29 条、第 31 条
- 依据：`/// 实测 200 status=1，data 数组与 kapi /video/detail 一致`；同一段证书说明在 `kg_endpoints_home.dart:164-168` 与 `kg_direct_api_client.dart:544-548` 各出现一次，三处均无匿名/普通/VIP 样本引用，且第 33 条明确 kapi 包装结果不能作原生实测依据。
- 影响：MV 播放入口的清晰度返回在非 VIP 态无留样；上游变化时出现空白清晰度列表且线上难定位。按「未实测」标注。
- 证据等级：未实测

### 文件 13/14 `lib/core/direct/kg_play_api.dart`（495 行，已从头读到尾）

### kg_play_api.dart:40,72 `KgPlayApi` 用 `requestWithVerify` 自动重试，而 `KgEndpointMedia.songUrl/privilege` 走 `_directOrFallback` → `evaluateResponse`，两条播放路径的 20028 语义不同
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一）、第 5 条（同一端点唯一事实源）
- 依据：`KgPlayApi.songUrl` 用 `client.requestWithVerify('/v5/url', ...)`，命中 `kg_client.dart:394-399` 的启发式 `_needsVerify` 后自动提交指纹并重试一次，返回 `PlayUrlResult`（`errorCode: res.errorCode`、`ssaCode: res.ssaCode`）；而 `kg_direct_api_client.dart:203 case 'song/url'` 走 `_directOrFallback(() => _epMedia.songUrl(q), ...)`，`_wrap` 用 `evaluateResponse` 抛 `ApiException(20028)` 并包装成 DioException 给 UI。两者一个「内部静默重试」，一个「上抛给验证流程」，且 `requestWithVerify` 重试失败后不上抛带 ssaCode 的异常。
- 影响：同一首歌、同一 20028 风控，从播放器 A 路径进入会自动重试（可能成功），从 Repository/`get('/song/url')` 路径进入会直接失败或弹验证；用户表现为点播时好时坏、验证页时有时无。
- 证据等级：实锤（两处源码对照）

### kg_play_api.dart:365-370 试听判定把「60s 片段」放宽到 ≤65s，且 `clipDurationMs` 与 `isPreview` 用不同算式
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条（单位/阈值具名）、第 17 条（数值精度）
- 依据：`isPreview: (endMs > 0 && (endMs - startMs > 0 ? endMs - startMs : endMs) <= 65000) || urls.any((u) => u.contains('/p_0_'))`；`int get clipDurationMs => endMs > startMs ? endMs - startMs : endMs;`（320 行）。`65000` 是魔法值（任务书关注「试听 60s」），无具名常量；当 `startMs > endMs`（异常数据）时 `isPreview` 用 `endMs` 判定而 `clipDurationMs` 也用 `endMs`，但区间起点 `startMs` 被丢弃。
- 影响：60s 试听片段若上游给 `start_ms=120000,end_ms=180000`（高潮片段），`isPreview` 正确判 true 但 `clipDurationMs` 为 60000；若上游给 61–65s 的整曲短歌，会被误标为试听，用户在下载择长时按「试听片段」处理而放弃整曲，或播放 60s 后意外停止且无「试听」提示。
- 证据等级：静态推演（上游区间取值未实测）

### kg_play_api.dart:339-351 `previewFileSize` 取整个响应的 `filesize`，`offsetFileSize` 用 `end_byte - start_byte`，两者单位/含义不同却直接供下载侧「择长」比较
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（返回语义契约）、第 15 条（单位显式）、第 17 条
- 依据：`final previewSize = b['filesize'] is int ? ... : int.tryParse(...) ?? 0;`（整个试听响应体声明的文件大小）；`final offsetStartByte = ms('start_byte'); final offsetEndByte = ms('end_byte'); final offsetSize = offsetEndByte > offsetStartByte ? offsetEndByte - offsetStartByte : (offsetEndByte > 0 ? offsetEndByte : 0);`。注释写「API 声明的字节数（试听片段 vs 高潮片段），供下载侧择优比较」，但 `previewFileSize` 是整响应 `filesize`、`offsetFileSize` 是 `start_byte/end_byte` 区间的字节跨度，二者并非同类量；`ms()` 这一函数名（毫秒）被用于读 `start_byte/end_byte`（字节），命名与单位错位。
- 影响：下载择长时若按这两个值比较长短，会 consistently 选中错误文件（把整曲大小当片段大小），用户下载到 30s 试听而非完整歌曲/高潮片段，且文件大小显示与真实不符。
- 证据等级：实锤（字段来源与命名对照；下载侧如何消费待 B7 核对，本范围外）

### kg_play_api.dart:24-30,145-152 `quality` 默认 `'128'`，`songUrl` 只补 `magic_` 前缀，未校验九档/非法值
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（输入取值范围）、第 16 条
- 依据：`String quality = '128'`；`if (!q.startsWith('magic_') && magicQualities.contains(q)) q = 'magic_$q';` 之外无任何校验；`magicQualities` 同时含带前缀与不带前缀 12 项，`viperQualities` 常量在本文件声明但 `songUrl` 中**零引用**（仅作为列表存在）。B1 `AudioQuality.fromString` 对未知值降级 `q128` 并触发 `QualityDiagnostics.onUnknownValue`，本层既未 import 该钩子也未复用 `AudioQuality`。
- 影响：设置页选「音质九档」中任一档，若上层传别名或空串，直连按 128 请求且无任何留痕；用户看到设置已生效但音质没变。`viperQualities` 死常量还暗示蝰蛇档有特殊处理，实际没有。
- 证据等级：实锤（本文件内 `viperQualities` 无引用；上层传值待 B4/B8 核对）

### kg_play_api.dart:60-92 `privilege` 的 `qualities` 入参只用于输出循环，未传给 `KgSharedParams.privilege`
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（参数契约）、第 32 条（无人写入的状态）
- 依据：`final body = KgSharedParams.privilege(client: client, hashes: hashes, albumIds: albumIds, qualities: qualities);`；而 `KgSharedParams.privilege` 的 `qualities` 参数在方法体内**完全未使用**，请求体恒 `'qualities': upstreamQualities`。`qualities` 随后又被用于 `final wanted = qualities.isEmpty ? defaultQualities : qualities;`。也就是说 `qualities` 只影响输出条数，不影响请求；但 `kg_endpoints_media.dart:privilege` 仍显式调 `KgSharedParams.parseQualities(q['qualities'])` 并传入，制造「传了会生效」的假象。
- 影响：调用方按调用方需求传单档 qualities 时，以为只查该档，实际服务端返回完整表后才过滤；虽然结果条数对，但请求体与文档契约不符，v5.0 后若有人删掉 `upstreamQualities` 而改用入参，权益判定会整档失真（VIP 音质误判）。
- 证据等级：实锤

### kg_play_api.dart:328-383 `PlayUrlResult.fromResponse` 不调用 `evaluateResponse`，把失败响应当作「空结果」返回
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（成功/失败判定单点）、第 9 条
- 依据：`factory PlayUrlResult.fromResponse(KgResponse res)` 直接读 `res.body` 构造 `PlayUrlResult(errorCode: res.errorCode, message: ..., ssaCode: res.ssaCode)`，没有 `outcome.isOk` 检查；`KgPlayApi.songUrl` 在 `requestWithVerify` 之后直接 `return PlayUrlResult.fromResponse(res)`，不抛 `ApiException`。B1 `response_policy.dart` 明确「成功/失败/风控判定全部收敛于此」，该文件 import 了 `../domain/quality.dart` 却未 import `response_policy.dart`。
- 影响：播放器经 `KgPlayApi` 点播时，20028 / error_code != 0 的响应变成一个 `hasUrl == false` 的结果对象，UI 若只判断「无 URL」会显示「歌曲暂无资源」而不是「需要人机验证」；用户无法完成验证→重试闭环，且 `lastErrors` 无记录。
- 证据等级：实锤

### kg_play_api.dart:48-53,130-135 多处「实测」结论引用 `docs/batch4_fix_1_network.md` 等历史审查报告，且无三态留样
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条、第 29 条、第 33 条
- 依据：注释「实测（curl 直打 trackercdn…）无 signature 时返回 errcode 20006…见 docs/batch4_fix_1_network.md F4-01 实测驳回」；`upstreamQualities` 注释「实测（curl gateway/...）只有整表下发才会返回…」；`qualityLevels` 注释「实测 relate_goods…」。均无匿名/普通/VIP 三态样本，且引用的文档属本任务禁止阅读的历史报告；`/v5/url` 三态（尤其 VIP 才返回 URL 的蝰蛇档）注释自述「VIP 态实测真实返回 URL」但无留样。
- 影响：音质九档与 VIP 权益的真实返回口径若变化，直连会静默按 128 或判缺档，用户表现为音质档位失效；按第 33 条标注「未实测」。
- 证据等级：未实测

### 文件 14/14 `lib/core/direct/kg_providers.dart`（109 行，已从头读到尾）

### kg_providers.dart:79-87 `kgDeviceProvider` 兜底分支生成**未持久化**设备，注释自述「main() 正常时永远 override」，但无生命周期保证
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 20 条（生命周期）
- 依据：`final kgDeviceProvider = Provider<KgDevice>((ref) { // 兜底：main() 正常时永远会被 override；此处仅为防崩（内存临时设备，不持久化…） return KgDevice.generate(); });`；`kgClientProvider` 直接 `ref.watch(kgDeviceProvider)`。若 bootstrap 中 `Hive.box('device')` 尚未 open 或 override 顺序晚于首个 `kgClientProvider` 读取，本次进程会用临时 device，且 `KgDevice.generate()` 每次生成新 guid/mid。
- 影响：用户冷启动时偶然进入该分支，设备身份每次启动都变，dfid 注册结果无法与 mid 对应，表现为首次点播被 20028 风控、试听 60s 降权、登录需反复验证；且因未落盘，重启无法自愈。
- 证据等级：静态推演（main/bootstrap override 时序属 B4 范围，本范围内确认兜底路径存在且不持久化）

### kg_providers.dart:85-99 dfid 三写链中 SecureStorage 采用 fire-and-forget，失败仅 debugPrint，无 `await` 也无重试
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（单一事实源）、第 9 条、第 21 条（状态写入完整性）
- 依据：`client.onDfidRegistered = (dfid) { KgDeviceStore.saveDfidSync(dfid); SecureStorage.instance.saveDfid(dfid).catchError((e) { debugPrint(...); }); };`；`KgDeviceStore.saveDfidSync` 返回 `bool` 但调用方**忽略返回值**，`openBox()` 返回 null 或 `catch` 失败时静默返回 false（`kg_providers.dart:60-76`）；`KgClient._persistDfid` 又以空 catch 包住整个回调（kg_client.dart:472-477）。三处写入（Hive device box / SecureStorage / kg.device.dfid）任一失败都无用户可见或可检索日志（debugPrint 不落盘）。
- 影响：注释自己写明「SecureStorage 里的旧值会反向覆盖 Hive 的新值，设备标识每次冷启动来回跳变，触发风控验证/播放降权/试听」；当 fire-and-forget 写入在进程被杀前未完成或 Hive 未开箱时，这一后果就会发生，且线上无留痕。
- 证据等级：实锤

### kg_providers.dart:30-38 `loadSync` 的 `jsonDecode(raw) as Map<String, dynamic>` 裸强转，异常后静默生成新设备
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（磁盘读取边界校验）、第 5 条
- 依据：`return KgDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>);` 在 `try` 内，`catch (_) {}` 后 `final device = KgDevice.generate(); box.put(...)` 直接覆盖旧记录；磁盘内容损坏、编码变更、手写类型不符都会走此分支，且无日志。`KgDevice.fromJson` 本身用 `'${j[...] ?? ''}'` 兜底，但外层 `as Map<String, dynamic>` 在 `jsonDecode` 返回 `Map<String, Object?>` 之外形态时先抛。
- 影响：用户升级 App 后若 device box 内容格式不兼容，设备身份被静默重置（旧 dfid 丢失），下次启动重新走注册/风控，出现「升级后突然要求验证、VIP 试听」；原数据被覆盖不可恢复。
- 证据等级：静态推演（磁盘损坏/格式漂移为边界条件；覆盖写入与空 catch 为实锤）

### kg_providers.dart:2-4,17 `KgDeviceStore.save`/`openBox`/`loadSync` 的 Hive 写入无返回检查，且 `save` 与 `saveSync` 语义重复
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（重复实现）、第 9 条
- 依据：`static Future<void> save(Box<String> box, KgDevice device) => box.put(...)` 在本文件零调用，与 `saveSync` 内容完全一致；`box.put()` 的 Future 在 `loadSync`/`saveSync` 中未 await、未检查（同步 API 返回 Future）。
- 影响：无直接用户可见故障；但「立刻落盘」的注释与未等待的 put 之间存在语义差，v5.0 后若写入失败，首启设备身份仍可能丢。
- 证据等级：实锤

### kg_providers.dart:102-109 `kgPlayApiProvider` / `kgDirectApiProvider` 各自 `ref.watch(kgClientProvider)`，无 `KgPlayApi` 与 `KgDirectApiClient` 的登录态同步契约
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（三态一致性）、第 3 条
- 依据：两个 Provider 都基于同一个 `KgClient` 实例，但 `KgDirectApiClient.setCredentials/clearCredentials` 才负责把 token/userid/dfid/vip 同步到 `kg`；`KgPlayApi` 直接读 `client.userid`/`client.lite`/`client.device`。若 UI 只通过 `kgPlayApiProvider` 播放而未先经 `KgDirectApiClient.setCredentials`（例如冷启动恢复会话路径只注入了 `KugouApiClient`），`KgPlayApi.songUrl` 的 `key` 用 `userid='0'`。
- 影响：已登录/VIP 用户点播时按匿名请求 `/v5/url`，只能拿到 128k 或 60s 试听，设置页显示 VIP 音质已生效但实际降权；三态表现不一致。
- 证据等级：静态推演（DI 装配顺序属 B4 范围，本范围确认两条 Provider 无显式同步）

### 补充（analyze 实锤追加，仍属「只报问题」）

### kg_direct_api_client.dart:622 `_qrPngBase64` 为本类第 5 个无人调用的私有成员
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：`dart analyze lib/core/direct/kg_direct_api_client.dart` 输出 `warning - kg_direct_api_client.dart:622:18 - The declaration '_qrPngBase64' isn't referenced.`；同次输出还确认 `_hasData`(89)、`_commentCodeOf`(417)、`_qrSrcappid`(592)、`_maskMobile`(595)、`_afterLogin`(637) 均为 `unused_element/unused_field`，并报 `166:5 Dead code`（`_asDioException` 中 `if (e is DioException) return e;` 因 DioException 类型缺失被判死代码，属缺包噪音，但「DioException 已识别时应原样返回」这一分支本应可达）。
- 影响：无直接用户可见后果；与前述「R1 拆分残留」同类，登录/二维码/评论码/成功判定的真实实现都在端点组，主类 5 个副本全是陷阱。
- 证据等级：实锤（analyze 输出）

### kg_endpoints_artist_album.dart:6 / kg_endpoints_comment.dart:6 / kg_endpoints_home.dart:6 / kg_endpoints_media.dart:6 / kg_endpoints_playlist.dart:6 / kg_endpoints_search.dart:6 六个端点组文件均导入 `kg_direct_api_client.dart` 但零使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条（分层单向依赖的阅读误导）
- 依据：逐文件 `dart analyze` 各输出 `warning - ...:6:8 - Unused import: 'kg_direct_api_client.dart'.`；`artist_album/home/media` 另报 `1:8 Unused import: 'dart:convert'.`；`kg_play_api.dart:14` 报 `Unused import: '../domain/quality.dart'.`（证实 `AudioQuality` 未在播放层被使用，见该文件音质九档条目）。
- 影响：无直接用户可见故障；但 6 个 core/direct 端点组反向 import 主适配类，形成 `KgDirectApiClient ↔ KgEndpointXxx` 的双向依赖表象（实际靠 `late final` 组合），v5.0 重构后易被误读为循环依赖而改错方向。
- 证据等级：实锤（analyze 输出）

## 问题清单（按级别排序）

共 81 条：P0 0 / P1 15 / P2 37 / P3 29。逐条详情见上方「逐文件审查记录」。

- [P1] kg_client.dart:340-385 `requestWithVerify` 的 20028 闭环只在直连内部重试一次，失败不上抛为带 `ssaCode` 的 `ApiException`
- [P1] kg_client.dart:394-399 `_needsVerify` 对字符串型 status 与 `status==2` 不识别，且未复用 `requiresVerification`
- [P1] kg_client.dart:58-60 `KgResponse.errorCode` 与 B1 `evaluateResponse` 的错误码归一契约不一致
- [P1] kg_direct_api_client.dart:57-63 `clearCredentials()` 未清空 `kg.dfid` 与 `kg.device.dfid`，切号后仍带上一账号设备指纹
- [P1] kg_endpoints_auth.dart:385 `_afterLogin` 严格 `body['status'] != 1` 判成功，与 B1 `evaluateResponse` 归一不一致
- [P1] kg_endpoints_comment.dart:64-118 评论写端点未使用 `requestWithVerify`，20028 时抛出后由 UI 决定是否重试，但 `write:true` 且无提交锁
- [P1] kg_endpoints_media.dart:82-85 `songUrl` 注释声称「直连仍可能遇 20028，_directOrFallback 已兜底回退 kapi」，与实际永久关闭的回退冲突
- [P1] kg_endpoints_playlist.dart:48-59 `playlistDel` 解密失败被空 catch 吞掉，回退到未解密的二进制响应体
- [P1] kg_endpoints_playlist.dart:65-95 `playlistAdd` 的 `type` 缺省 0 且 `type==1` 分支 query 为空，写操作无防重键
- [P1] kg_endpoints_search.dart:98-101 `searchLyric` 把 `duration` 当秒又乘 1000，变量名 `durationSec` 与注释「duration 传毫秒」自相矛盾
- [P1] kg_play_api.dart:328-383 `PlayUrlResult.fromResponse` 不调用 `evaluateResponse`，把失败响应当作「空结果」返回
- [P1] kg_play_api.dart:339-351 `previewFileSize` 取整个响应的 `filesize`，`offsetFileSize` 用 `end_byte - start_byte`，两者单位/含义不同却直接供下载侧「择长」比较
- [P1] kg_play_api.dart:40,72 `KgPlayApi` 用 `requestWithVerify` 自动重试，而 `KgEndpointMedia.songUrl/privilege` 走 `_directOrFallback` → `evaluateResponse`，两条播放路径的 20028 语义不同
- [P1] kg_providers.dart:30-38 `loadSync` 的 `jsonDecode(raw) as Map<String, dynamic>` 裸强转，异常后静默生成新设备
- [P1] kg_providers.dart:79-87 `kgDeviceProvider` 兜底分支生成**未持久化**设备，注释自述「main() 正常时永远 override」，但无生命周期保证
- [P2] kg_client.dart:192-194 与 219-224 `KgClient.dfid` 字段与 `device.dfid` 双份事实，签名实际只读 `device.dfid`
- [P2] kg_client.dart:293-305 网络异常被折叠成 HTTP 502 + `status:0`，无 `error_code`、无 `ssaCode`
- [P2] kg_client.dart:401,410-427 注释写 `/verify/user/info`，实际请求 `/verifyservice/v3/get_verify_info`；成功判定用严格 `== 1`
- [P2] kg_client.dart:469-477 `_persistDfid` 的空 catch 静默吞掉持久化失败
- [P2] kg_client.dart:69-70 `KgResponse.ssaCode` 少取 B1 认可的 `ssaCodeStr`，且对空串/非字符串未过滤
- [P2] kg_crypto.dart:203-208 `aesEncryptHex` 显式传入 key+iv 时返回的 `AesResult.key` 是原始 key，而非解密端期望的 seed
- [P2] kg_direct_api_client.dart:290-300,363-371 未移植端点抛 `-404` 且 `fallbackToKapi=false`，异常文案含内部术语
- [P2] kg_direct_api_client.dart:637-661 `_afterLogin` 用严格 `body['status'] != 1` 判成功，绕过 B1 `evaluateResponse`
- [P2] kg_direct_api_client.dart:74-95 `_wrap` 已迁移 `evaluateResponse`，但注释与 `_hasData` 仍保留旧口径
- [P2] kg_endpoints_artist_album.dart:121-140 `albumSongs` 的 `is_buy` 归一化把 `false/0/'0'` 变成空串，而 `albumDetail` 原样透传 `q['is_buy'] ?? 0`
- [P2] kg_endpoints_artist_album.dart:143-165 `rankAudio` 缺 `baseUrl` 走 gateway，与主类注释「POST gateway」一致，但 `rankId` 解析失败时静默丢键
- [P2] kg_endpoints_auth.dart:239-253 `loginQrCreate` 本地合成 `status: 200` 响应，与 B1 `evaluateResponse` 的「status==200 且 ec 在白名单」耦合
- [P2] kg_endpoints_auth.dart:260-283 二维码登录成功态（`status=='4'`）只回写 token/userid，未回写 t1/vip 三态，也未走 `_afterLogin`
- [P2] kg_endpoints_auth.dart:285-314 `userDetail` 修改上游响应 `inner['userid']`，且匿名态 userid 被硬编码为 '0'
- [P2] kg_endpoints_auth.dart:337-368 `verifyUserInfo` 对 sid/edt/verifycode 无条件 `Uri.decodeComponent`，而 `VerificationService.submit` 把 Base64 原值同时放 body 与 query
- [P2] kg_endpoints_auth.dart:38-52 `registerDev` 失败时返回 HTTP 200 + `status:0` 且无 `error_code`，`getDfid()` 的上层静默吞异常
- [P2] kg_endpoints_auth.dart:383-413 与主类 `kg_direct_api_client.dart:637-661` 存在两份 `_afterLogin`，主类那份是死代码
- [P2] kg_endpoints_comment.dart:31-42 歌曲评论列表用 `/v1/cmtlist` + x-router，歌单/专辑评论用 `/m.comment.service/v1/cmtlist`，两套路径成败口径不同
- [P2] kg_endpoints_comment.dart:52-62 `commentCount` 返回裸 Map 但 `fetchCount` 用 hash 大小写三次查找
- [P2] kg_endpoints_home.dart:140-159 注释仍写「失败由 _wrap 抛出 → _directOrFallback 回退 kapi → fetchBanners 容错置空」，与 `fallbackToKapi=false` 冲突且引用了禁止阅读的历史报告文件
- [P2] kg_endpoints_home.dart:151-157 `yuekuBanner` 依赖 `kg.vipType`，但退出登录不清空 VIP 字段，且 `vip_type` 单位/取值无三态契约
- [P2] kg_endpoints_home.dart:169-197 与主类 `kg_direct_api_client.dart:555-573` 存在两份 `videoDetail` 实现
- [P2] kg_endpoints_media.dart:36-62 `videoUrl` 不做 `hash` 空值/形态校验，直接以空 hash 请求 `trackermv.kugou.com`
- [P2] kg_endpoints_media.dart:75-80 `songUrl` 把 `quality` 默认硬编码 `'128'`，与 B1 `AudioQuality` 九档/设置页来源无对接校验
- [P2] kg_endpoints_playlist.dart:196-214 `playlistDetail` 的越界/缺参抛裸 `ApiException`，被 `_directOrFallback` 泛 catch 二次包装
- [P2] kg_endpoints_playlist.dart:265-287 `_parseTracksResource` 把 `timelen` 固定为 0，且 `bitrate/size` 全 0，单位无显式标注
- [P2] kg_endpoints_search.dart:120-124 `lyric` 缺参抛裸 `ApiException` 且文案硬编码中文
- [P2] kg_endpoints_search.dart:144-148 `decode=true` 时 Base64 解码失败被完全空 catch 吞掉
- [P2] kg_endpoints_search.dart:20-24 `search` 的 `type` 用 `contains(q['type'])` 判类型，非 String 输入与 `special/lyric` 分支共用 `/v1/search/$type`
- [P2] kg_media_direct.dart:17-29 封面查询的 hash/album_id/album_audio_id 按逗号索引对齐，长度不等时静默补 '0'
- [P2] kg_media_direct.dart:36-47 `images` 把 query 手工拼进 path 字符串，签名形态依赖 `KgSignature.android` 的隐式 jsonEncode 且与 REVIEW_SPEC 白名单不符
- [P2] kg_media_direct.dart:52-89 第三份 `videoDetail` 实现（`KgClient` 扩展），且无 `x-router` 之外的 baseUrl 差异说明
- [P2] kg_play_api.dart:24-30,145-152 `quality` 默认 `'128'`，`songUrl` 只补 `magic_` 前缀，未校验九档/非法值
- [P2] kg_play_api.dart:365-370 试听判定把「60s 片段」放宽到 ≤65s，且 `clipDurationMs` 与 `isPreview` 用不同算式
- [P2] kg_play_api.dart:60-92 `privilege` 的 `qualities` 入参只用于输出循环，未传给 `KgSharedParams.privilege`
- [P2] kg_providers.dart:102-109 `kgPlayApiProvider` / `kgDirectApiProvider` 各自 `ref.watch(kgClientProvider)`，无 `KgPlayApi` 与 `KgDirectApiClient` 的登录态同步契约
- [P2] kg_providers.dart:85-99 dfid 三写链中 SecureStorage 采用 fire-and-forget，失败仅 debugPrint，无 `await` 也无重试
- [P3] edt_generator.dart:1-14 注释声称「逐行对照 generate_simulate.js」，但方案结论无实测留样
- [P3] edt_generator.dart:65,76 哨兵与 key 为静态可变全局，调用方无任何防重/世代标识
- [P3] edt_generator.dart:76,238 `fixedKey` 未校验长度即作为 AES 密钥
- [P3] kg_client.dart:41-52 `isOk` 的整段文档注释指向一个已被删除的 getter
- [P3] kg_crypto.dart:1-13 头注释「逐行移植自 helper.js + crypto.js」，三态样本与签名盐实测记录未落到本层
- [P3] kg_crypto.dart:83-88 `KgSignature.register` 自述「currently unused」仍保留
- [P3] kg_direct_api_client.dart:114,119-160 注释「先直连，失败则回退 kapi」与 `fallbackToKapi=false` 永久关闭相矛盾；回退分支成不可达代码
- [P3] kg_direct_api_client.dart:592,595-598 两个私有成员 `_qrSrcappid` / `_maskMobile` 无调用点
- [P3] kg_direct_api_client.dart:622 `_qrPngBase64` 为本类第 5 个无人调用的私有成员
- [P3] kg_direct_api_client.dart:7,14 `dart:convert` 与 `qr_flutter` 导入在本文件零使用
- [P3] kg_direct_api_client.dart:76-79,382-384 中文硬编码注释与实测口径混用，`duration` 单位说明未在类型/字段上体现
- [P3] kg_endpoints_artist_album.dart:1 `dart:convert` 导入零使用；主类同组注释重复
- [P3] kg_endpoints_artist_album.dart:36-39,51-56,88-96 「实测 A/B/C 三形态」「实测直连 200」无留存样本与三态区分
- [P3] kg_endpoints_artist_album.dart:6 / kg_endpoints_comment.dart:6 / kg_endpoints_home.dart:6 / kg_endpoints_media.dart:6 / kg_endpoints_playlist.dart:6 / kg_endpoints_search.dart:6 六个端点组文件均导入 `kg_direct_api_client.dart` 但零使用
- [P3] kg_endpoints_auth.dart:1-10,15-20 「R1 重构：行为与拆分前完全一致」与同文件两份重复实现、主类同名私有方法矛盾
- [P3] kg_endpoints_auth.dart:316-334 `getVerifyInfo` 用默认 gateway，而同路径的 `kg_client.submitFingerprintVerification` 用 `verifyservice.kugou.com`，两处无「为什么不同」的说明
- [P3] kg_endpoints_comment.dart:1-4,8-12 「R1 重构：行为与拆分前完全一致」+ 主类重复 `_commentCodeOf` 实现
- [P3] kg_endpoints_home.dart:1-12,28-30 「R1 重构：行为与拆分前完全一致」与残留空注释 `/// 歌手详情（module/artist_detail.js）`
- [P3] kg_endpoints_home.dart:80-125 `topPlaylist` 的「实测可用」结论与 REVIEW_SPEC 既知约束冲突且无三态留样
- [P3] kg_endpoints_media.dart:1-11,37-41 `dart:convert` 零使用；`videoUrl` 声明 `async` 但只有一个 `await` 后立即 `return r`
- [P3] kg_endpoints_media.dart:22-35,93-110 `kmrAudioMv` 与 `privilege` 的「实测匿名/VIP 200 status=1，0 差异」未附三态留样
- [P3] kg_endpoints_media.dart:43-45 注释引用 `AppConfig.proxyMvUrl`，而 `app_config.dart` 全文只有 `proxyBase`
- [P3] kg_endpoints_playlist.dart:157-159,170-172 残留孤立注释 `/// 歌单评论（module/comment_playlist.js）` 与「R1 行为完全一致」
- [P3] kg_endpoints_playlist.dart:19-47 `playlistDel` 的 AES 二进制响应解析无三态留样，且 p 参数大小写与注册路径相反
- [P3] kg_endpoints_search.dart:1-4,8-12 「R1 行为完全一致」与主类同名注释并存，两份注释对 `duration` 单位说明口径不同
- [P3] kg_endpoints_search.dart:105-117 `searchLyric` 用 `clearDefaultParams + notSignature`，与 REVIEW_SPEC「歌词 `/v1/search` 必须带 signature」的口径需区分路径
- [P3] kg_media_direct.dart:56-62 注释引用的证书实测结论无三态留样（与 home/主类注释三处重复）
- [P3] kg_play_api.dart:48-53,130-135 多处「实测」结论引用 `docs/batch4_fix_1_network.md` 等历史审查报告，且无三态留样
- [P3] kg_providers.dart:2-4,17 `KgDeviceStore.save`/`openBox`/`loadSync` 的 Hive 写入无返回检查，且 `save` 与 `saveSync` 语义重复

## 复核通过项（本范围确认到位的设计）

1. **原生网关唯一**：`KgConfig.gateway/registerGateway`、`kg_endpoints_*` 与 `kg_play_api.dart` 全部指向 `*.kugou.com` 原生域（complexsearch / pubsongs / openapi / trackercdn / trackermv / ocean / musicadservice / msearch / lyrics / login-user / userservice / verifyservice）；`AppConfig.kugouApiBase` 只在父类 CookieJar 域名占位出现（app_config.dart:14 注释与 `KugouApiClient` 实现一致），`fallbackToKapi = false` 使运行期不调用 kapi（第 27 条）。
2. **`_wrap` 已收敛到 B1 `evaluateResponse`**：`kg_direct_api_client.dart:82-86` 只做 `KgResponse → body/ssaCode` 适配，父 `KugouApiClient` 的拦截器同样调用 `evaluateResponse`（`kugou_api_client.dart:44-56`），直连与回退路径的成功/失败判定单点一致（第 8 条）。
3. **异常契约跨层可解包**：`_asDioException` 统一包成 `DioException(error: ApiException)`；`friendly_error.dart:unwrapApi`、`response_policy.dart:apiExceptionOf / requiresVerification`、`AuthRepository._errorResponseData` 均能取出 `ssaCode`/`errorCode`，20028 与 20034 在 `_directOrFallback` 中显式不回退（第 8/21 条）。
4. **写操作禁止回退**：评论发送/回复/删除、歌单增删、加歌删歌、登录/验证提交全部分派带 `write: true`；`KgClient.requestWithVerify` 文档明确「写端点必须直接调 request」，评论/歌单端点确实只用 `kg.request`（第 21 条，自动重试防重部分）。
5. **dfid 三写已接线**：`KgDirectApiClient.setCredentials` 同时写 `kg.dfid`、`kg.device.dfid` 与父类 cookie；`kg.registerDevice` 成功后写 `device.dfid` 并由 `kg_providers.dart` 的 `onDfidRegistered` 同步 Hive + SecureStorage（第 5 条，写入失败可观测性另列为问题）。
6. **签名形态**：`signature` 统一放 `queryParameters`（`kg_client.dart:257-260`），`clienttime` 全部用 `~/ 1000` 秒级；`clearDefaultParams` 仅用于歌词 `/search`、评论写 `/index.php`×3、`/v1/video`、`/v2/author_image/audio`（最后一处已列为未验证形态）；三种盐与 `signParamsKey = md5(appid + salt + clientver + data)` 与 REVIEW_SPEC 一致（第 15/28 条）。
7. **二进制 body 支持**：`kg_client.dart:246-290` 对 `Uint8List` 直传字节并设 `application/octet-stream`，`responseType: ResponseType.bytes` 保留 `rawBytes`；`playlistDel` 用 `rawBytes` 解密（第 14 条，解密失败吞异常另列为问题）。
8. **三态在签名层有降级**：`KgClient.request` 的 `defaultParams` 在匿名时不带 `token/userid`，`userid` 非空且非 `'0'` 才下发；`KgSharedParams.songUrl` 的 `key` 匿名态固定字符串 `'0'`；`KgDevice.webgl` 缺失时指纹生成降级 `'0'`（第 16 条的部分实现）。
9. **资源上限**：`_kgVerboseBodyLimit = 4 * 1024`、`lastErrors` 上限 20、`registerDevice` 重试 3 次带退避、`requestWithVerify` 重试 1 次（第 25 条）。
10. **试听/高潮片段字段完整读取**：`PlayUrlResult` 读 `hash_offset` 的 `start_ms/end_ms/clip_hash/offset_hash/start_byte/end_byte`，`isPreview` 改用区间时长而非仅 `end_ms`，并声明不下载即可比较字节数（第 24 条；两字段语义错位另列为问题）。
11. **播放地址/权益参数共用 `KgSharedParams`**：`KgPlayApi` 与 `kg_endpoints_media.dart` 都调用同一构造，`hash` 统一小写、`resource[].page_id=0`、空 hash 前置拦截、`qualities` 恒下发完整表（第 5 条）。
12. **MV hash→video_id 链路分派齐全**：`kmr/audio/mv`（`/kmr/v1/audio/mv`）、`video/detail`（`/v1/video`）、`video/url`（`trackermv.kugou.com/v2/interface/index`）在 `get/post` 分派表均有 case；`videoUrl` 的 `key` 用 `KgSignature.keyOf(hash, mid, userid)`（第 27 条）。
13. **登录族端点齐备**：设备注册、短信验证码、密码/验证码/token 三种登录、二维码 key/create/check、user/detail、get/verify/info、verify/user/info 全部在 `get/post` 分派表；`captchaSent` 已从明文 http 改为 https + x-router（Android 9+ cleartext）。
14. **注释中的实测纪律**：多处记录 A/B/C/D 参数形态对比、TLS 证书三标签域名限制、`v1` vs `v2` 返回结构差异、`IsFreePart`/`signature` 的实测驳回，属可追溯的「为什么」记录（第 31 条；三态留样缺失另列为问题）。
15. **`dart analyze` 项目自有类 0 错误**：14 文件均无「项目自有类未定义/类型不匹配」错误；`kg_media_direct.dart` 为 `No issues found!`。

## 逐文件 `dart analyze` 结果

命令：`export PATH=$PATH:/opt/dart/bin && dart analyze <file>`（仅静态语法检查；未安装依赖、未 pub get、未构建）。噪音过滤口径：`uri_does_not_exist` 与由缺失的 Flutter/Dio/pointycastle/Riverpod/Hive 包导致的 `undefined_*` 全部归为预期噪音；**项目自有类报错**为判定通过与否的标准。

| # | 文件 | 输出摘要（过滤后） | 项目自有类错误 | 结论 |
|---|---|---|---|---|
| 1 | `lib/core/direct/edt_generator.dart` | 25 issues：2 条 `uri_does_not_exist`（pointycastle/asn1、pointycastle/export）+ 23 条由该缺失包派生的 `MD5Digest/PaddedBlockCipherImpl/ASN1Parser/OAEPEncoding/RSAPublicKey` 等 `undefined_method` / `cast_to_non_type` / `non_type_as_type_argument` | 0 | 通过（仅三方包噪音） |
| 2 | `lib/core/direct/kg_client.dart` | 12 issues：1 条 `uri_does_not_exist`（dio/dio.dart）+ 11 条 `Dio/BaseOptions/ResponseType/Response/Options/DioException` 派生未定义 | 0 | 通过 |
| 3 | `lib/core/direct/kg_crypto.dart` | 55 issues：2 条 `uri_does_not_exist`（pointycastle）+ 53 条 `MD5Digest/ASN1*/RSA*/AESEngine` 等派生未定义 | 0 | 通过 |
| 4 | `lib/core/direct/kg_direct_api_client.dart` | 15 issues：3 条 `uri_does_not_exist`（dio、flutter/foundation、qr_flutter）+ 5 条 `debugPrint/DioException/RequestOptions` 派生；**warning**：`_hasData`(89)、`_commentCodeOf`(417)、`_qrSrcappid`(592)、`_maskMobile`(595)、`_qrPngBase64`(622)、`_afterLogin`(637) 未引用，`166:5 Dead code`（DioException 类型缺失导致的噪音） | 0 | 通过；6 条死代码 warning 已转为本报告 P3 问题 |
| 5 | `lib/core/direct/kg_endpoints_artist_album.dart` | 2 issues：均为 `unused_import` warning（`1:8 dart:convert`、`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 6 | `lib/core/direct/kg_endpoints_auth.dart` | 5 issues：2 条 `uri_does_not_exist`（flutter/foundation、qr_flutter）+ 3 条 `debugPrint/QrPainter/QrVersions` 派生未定义 | 0 | 通过 |
| 7 | `lib/core/direct/kg_endpoints_comment.dart` | 1 issue：`unused_import` warning（`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 8 | `lib/core/direct/kg_endpoints_home.dart` | 2 issues：`unused_import` warning（`1:8 dart:convert`、`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 9 | `lib/core/direct/kg_endpoints_media.dart` | 2 issues：`unused_import` warning（`1:8 dart:convert`、`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 10 | `lib/core/direct/kg_endpoints_playlist.dart` | 1 issue：`unused_import` warning（`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 11 | `lib/core/direct/kg_endpoints_search.dart` | 1 issue：`unused_import` warning（`6:8 kg_direct_api_client.dart`） | 0 | 通过；warning 已转为 P3 |
| 12 | `lib/core/direct/kg_media_direct.dart` | `No issues found!` | 0 | 通过（零警告） |
| 13 | `lib/core/direct/kg_play_api.dart` | 1 issue：`unused_import` warning（`14:8 ../domain/quality.dart`） | 0 | 通过；warning 佐证音质九档未在播放层接入 |
| 14 | `lib/core/direct/kg_providers.dart` | 14 issues：3 条 `uri_does_not_exist`（flutter/foundation、flutter_riverpod、hive）+ 11 条 `Box/Hive/Provider/debugPrint` 派生未定义 | 0 | 通过 |

合计：14/14 文件已逐文件执行 `dart analyze`，项目自有类错误 0；噪音均为缺失三方包，warning 均为本报告已记录的死代码/未用导入。

## 未做项与原因

- **未做真机/网络实测**：任务书与 QUALITY_STANDARD 第 8 章禁止启动本地服务、构建、跑测试；且第 33 条要求原生网关三态留样，本次只能静态阅读。所有涉及「上游真实返回」的条目均标注「未实测」或「静态推演」，不作实锤。
- **未读 B1/B3–B8 其它批报告与 `docs/v51_cross_b*_merged.md`**：通用规范第 7 条与交叉机制禁止，防锚定；为核对跨模块契约只读了当前磁盘上的业务代码源文件（`core/foundation/errors.dart`、`core/domain/response_policy.dart`、`core/domain/quality.dart`、`core/config/app_config.dart`、`core/api/kugou_api_client.dart`、`core/utils/friendly_error.dart`、`features/auth/data/{verification_service,captcha_types,auth_repository}.dart`、`features/comment/data/comment_repository.dart`），均完整 `file_read`。
- **上层消费方（B4/B5/B7/B8 范围）未逐行审**：DI 装配顺序、播放器验证监听器、下载择优、设置页音质九档、搜索页 type 传值只在本报告中标为「待上层核对」的静态推演，证据等级已如实标注。
- **未修改任何代码文件**：唯一写入 `docs/v51_cross_b2_c.md`；未执行 `pub get` / `flutter` / 构建 / 测试 / 服务启动。

