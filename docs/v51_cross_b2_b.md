# v5.1 交叉审查 B2 · 视角 B：鲁棒与代码质量

- 批次：B2 `lib/core/direct/**`（14 文件 / 4316 行）
- 视角：B 鲁棒与代码质量（异常契约 6/8/9、外部数据形态 13/14、并发/闸门/资源对称 18/19/20/22、写幂等 21、缓存键 23/25、实测依据 28/29、注释一致 31、死代码 32）
- 判据：`docs/QUALITY_STANDARD.md`（32 条，冲突时优先）/ `docs/REVIEW_SPEC.md`
- 只读审查；唯一写文件为本报告；不改任何代码文件；未实测项如实标注
- 逐文件实时落盘，末尾附问题清单、复核通过项、逐文件 `dart analyze` 结果

---

## 逐文件审查

### 1) `lib/core/direct/edt_generator.dart`（281 行，完整读取）

### edt_generator.dart:58,74,176-178 静态可变 `_sentinel` 被每次 generate 覆写，隐含单调用者前提未声明
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明；第 5 条状态单一来源）
- 依据：`static int _sentinel = 0xffffffff;`（58）是类级可变状态，`generate()` 在 74 行 `_sentinel = 0xffffffff - _ri(0, 19);` 覆写它；`_fs3/_fs5/_fs6`（176-178）在 `_generateEdtData` 内读取该全局值。整个生成链没有把 sentinel 作为参数传递，也没有任何注释声明「同一时刻只允许一个 generate 在跑」。当前实现靠 Dart 单 isolate 内 `generate()` 全同步、无 await 才不发生交错；前提既未写明也未在代码中保护。
- 影响：一旦该方法被改为异步（或在生成路径引入任何 await / 重入回调），两次并发生成的哨兵值会互相污染，产出的 edt 与服务端解密/风控校验不一致，表现为行为验证接口静默失败（用户侧为登录/验证反复失败）。当前同步路径下不触发，故标 P2。
- 证据等级：静态推演（代码事实为实锤，交错后果为推演）

### edt_generator.dart:71-72,77,87 `fixedKey` / `timestampMs` 两个注入入口零消费
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍，「仅供以后可能用」的抽象）
- 依据：`generate` 签名声明 `String? fixedKey, int? timestampMs`（71-72），仅在 77 行 `final key = fixedKey ?? ...`、87 行 `final ts = timestampMs ?? DateTime.now()...` 使用。对 `lib/` 与 `test/` 全部 .dart 做符号计数核对：这两个标识符只出现在本文件内（各 2 次，均为声明+自身使用），`EdtGenerator.generate` 的所有调用方（kg_client.dart、features/auth/data/verification_service.dart）均不传这两个参数；也没有任何注释说明它们对应的测试/复现用途。
- 影响：无直接用户可见后果；但 `fixedKey` 作为外部可注入的 AES key 无长度契约（非 16 字节会令 `AESEngine` 抛错），却无人使用，属于无人维护的可误用入口与整洁度问题。
- 证据等级：实锤

### edt_generator.dart:70-95,108 外部来源的 mid/userid/dfid/webglHash 未经形态校验即拼入明文
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验；关联第 13 条）
- 依据：`generate` 的文档注释明确 `dfid` 为「register_dev 返回的设备 id」、`mid` 为设备 MID、`webglHash` 为字符串十进制，即网络/平台通道来源；实现仅用 `_nz()`（108 行 `v.isEmpty ? '0' : v`）把空串替换为 `'0'`，随后直接拼接 `'mid=...;userid=...;dfid=...;webgl=...;...;data=$data'`（95-98）并加密。没有对分隔符 `;`、`=`、`:`、控制字符或长度做任何校验/转义。`data` 与字段共用 `:`、`,` 分隔体系，也未见长度上限（第 25 条）。
- 影响：上游 register_dev 返回异常字符串（含分隔符、超长、带空白）时，明文结构被破坏而本层无任何报错或日志（第 9 条），服务端只能整体拒绝 sid/edt，用户侧表现为验证码/登录验证反复失败且无法定位。
- 证据等级：静态推演（字段来源为代码注释实锤；上游异常形态未实测）

### edt_generator.dart:45,47-53,258 `_publicKeyPem` 名称/注释与实现内容不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条、第 31 条（命名即文档；注释解释「为什么」而非误导）
- 依据：注释写「RSA-2048 公钥（SPKI / PEM）」、常量名 `_publicKeyPem`，实际内容只是一段无 `-----BEGIN PUBLIC KEY-----` 装甲行的裸 base64 DER 文本；258 行用 `base64.decode(_publicKeyPem.replaceAll(RegExp(r'\s'), ''))` 直接按 DER 解析。文件头注释（3-12 行）声称「逐行对照 KuGouMusicApi/util/generate_simulate.js 移植」，但未给出该上游来源的版本/路径校验信息，也未记录 sid/edt 在原生网关上的实测回包（第 28/29 条）。
- 影响：无直接用户可见后果；维护者按 PEM 名称去替换密钥时极易带入装甲行导致 `FormatException`，且无法追溯密钥来源与三态实测样本。
- 证据等级：实锤（命名/内容不符）；未实测（无原生回包留样）

**本文件复核通过项（候选）**：268-270 行 `OAEPEncoding.withSHA256(RSAEngine())` 及 A2-03 注释明确写出「上游用 SHA-256、pointycastle 默认 SHA1 会解密失败」的为什么，属第 31 条正向例；`_bezierPath` 中 `n = _ri(30,60)` 保证 `t = i/n` 绝不除零；`_randomString` 的 `idx.clamp` 保证字符表不越界。

### 2) `lib/core/direct/kg_client.dart`（615 行，完整读取）

### kg_client.dart:339-345 契约声明「命中 20028 时重试」与实现「任意失败+ssa-code 就重试」不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 3 条（契约先行，失败语义明确）
- 依据：方法文档首行（339）写「带验证自动处理的请求：命中 20028 时提交 sid/edt 后重试一次」，但 394-398 行 `_needsVerify` 注释明确「对齐 Node request.js:234-246：任意失败响应（status==0 或 error_code!=0）只要带 `ssa-code` 头/体⋯⋯而非只认 20028。实测 20006（签名错风控）也会带 ssa-code」，实现 `failed && ssaCode.isNotEmpty` 也完全不看 20028。即注释把触发条件收窄到 20028，实际连签名错误（20006）都会提交一次行为指纹并重发原请求。
- 影响：调用方/维护者按「仅风控 20028」理解该方法，签名错误等本地可修的故障也会被静默地额外打一次 verifyservice + 重发业务请求，用户侧表现为一次请求多出数百毫秒到数秒延迟且日志上没有可对应的 20028 记录；排查时按注释去找 20028 会一无所获。
- 证据等级：实锤（注释与实现均在本文件内）

### kg_client.dart:341-343,345-380 写端点禁用声明无强制；`retries` 可任意放大，且两个实际调用方是 GET/权益读，写端契约未被消费
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作必须幂等或有防重机制）、第 31 条
- 依据：340-343 行注释声明「**写操作禁止使用本方法**⋯⋯写端点必须直接调 [request]」，但这是纯文档约定：`requestWithVerify` 的签名（345-355）没有 `method` 白名单、没有断言、没有 `isWrite` 参数，`retries` 是公开可选 `int`，实现（356-380）无条件把首请求的 `method/data/params` 原样重发。对 `lib/`+`test/` 全部 .dart 的符号核对：`requestWithVerify` 仅 3 处出现（本文件声明 1 处 + kg_play_api.dart:40、:72 两处调用）；两处调用分别是 `songUrl`（GET /v5/url）与 `privilege`（POST 权益查询），均为读语义，当前无写端点调用它。也就是说「禁止写操作」的契约在本批次范围内既无代码强制，也未被任何写端点实际验证；同时 `retries > 1` 时 356-380 只做一次首请求 + 一次重试（不循环），参数名暗示的次数上限并未实现。
- 影响：当前用户可见后果为 0（无写调用方），但契约靠注释维系：任何新增写端点误用该方法即可在服务端已执行、响应带 ssa-code 的情况下重复提交（重复评论/重复收藏）；`retries` 与实际重试次数不符会让调用方误判上限。按分级纪律只记 P2。
- 证据等级：实锤（声明、调用点统计）；重复提交后果为静态推演

### kg_client.dart:293-303 DioException 被吞成 status=502 的假响应，异常契约与上层 `-404/-1` 分支不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 8 条（异常契约单一稳定、回退与主路径形态一致）、第 9 条（失败可观测）
- 依据：`request()` 在 293 行捕获 `DioException` 后只写 verbose 日志（verboseMode 默认关），随后 `return KgResponse(status: 502, body: {'status': 0, 'error': '${e.message}'})`（301-304）。`DioException` 的类型、堆栈、`e.response?.statusCode` 全部丢失；失败被伪装成一个「正常返回的 KgResponse」，只靠 status 502/body.status=0 表达。本层没有抛 `DioException`/领域异常，也没有非 verbose 的可检索日志。这与 `kg_direct_api_client.dart` 中 `_directOrFallback` 对 `-404`（未移植路径）、`-1` 等哨兵值的处理（需逐文件核对，见后文）分属两套失败形态；上层拿不到「超时/无网/DNS/证书」与「业务拒绝」的区分。
- 影响：用户断开网络或请求超时时，上层拿到的是一个业务失败响应而非网络异常，友好错误提示与重试策略无法区分「无网络，请检查连接」和「服务端拒绝」；用户只看到笼统失败/空列表，且线上没有可检索日志（verbose 关即零痕迹）。
- 证据等级：静态推演（代码事实实锤；上层表现由 `_directOrFallback` 读完后复核）

### kg_client.dart:305-313 JSON 解析失败被静默降级为 `{'status':0,'error':'响应解析失败'}`，无形态校验与日志
- 级别：P2
- 违反：QUALITY_STANDARD 第 6/9 条、第 13/14 条（外部数据形态）、第 8 条
- 依据：`jsonDecode(raw)` 在 312 行用 `catch (_)` 无条件吞掉任何异常，返回 `body = {'status': 0, 'error': '响应解析失败', 'raw': raw.substring(0, raw.length.clamp(0, 200))}`。`raw` 来自 `utf8.decode(res.data!, allowMalformed: true)`，即二进制响应（本文件多处注释说明注册/MV 收藏返回 AES 密文字节）也会被 UTF-8 宽松解码并尝试 JSON；解析失败时丢弃 `rawBytes` 之外的全部形态信息，只保留前 200 字符片段，不留任何日志。
- 影响：上游返回 HTML 错误页、gzip 残留或 AES 二进制时，用户看到的是「失败/空结果」而非可诊断错误；线上无法通过日志定位是哪一类返回形态变化（第 9 条）。二进制 body 的合法响应被当成解析失败，会掩盖真实成功。
- 证据等级：静态推演（第 13/14 条相关形态来自本文件注释；上游异常形态未实测）

### kg_client.dart:196-200,470-480 三处登录态字段（`dfid`/`vipType`/`t1`）与 dfid 落盘回调的异常被空捕获吞掉
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 6 条、第 9 条
- 依据：`KgClient` 自身持有 `String dfid = ''`（194），同时 `KgDevice.dfid`（78）是签名实际读取的唯一来源（注释 192-193 也写「直连层签名取 kg.device.dfid」）；对全仓符号核对：`kg.dfid` 仅 2 处出现且都在 kg_direct_api_client.dart，`client.dfid` 零出现，即本字段是无人读取的第二份状态。`_persistDfid()`（472-480）在 `onDfidRegistered?.call(dfid)` 外层 `catch (_) { // 持久化失败不影响本次请求 }`，完全空捕获、无日志；`kg_providers.dart:87` 注入的落盘回调若抛错，`device.dfid` 已在内存中更新而 Hive 未落盘，重启后 dfid 丢失且无任何痕迹。
- 影响：dfid 注册成功后本进程签名正常，但落盘失败时用户重启 App 会重新注册/拿不到 dfid，部分需要 dfid 的接口静默降级；故障无日志、无法统计（第 9 条）。
- 证据等级：实锤（空捕获/双状态）；重启后果为静态推演

### kg_client.dart:535-560 设备注册失败路径多处空捕获，`retries` 无上限约束且失败原因不可观测
- 级别：P2
- 违反：QUALITY_STANDARD 第 6/9 条、第 25 条（重试次数上限须为常量且有据）
- 依据：`_registerDeviceOnce` 在 537 行 `on DioException catch (_) { return false; }`（无日志）、549 行 AES 解密 `catch (_)` 后走明文回退、558 行明文解析 `catch (_) { return false; }`；`registerDevice({int retries = 3})`（454）把重试次数作为公开入参，默认 3 但不是具名常量，调用方（kg_endpoints_auth.dart:39）不传；每次失败只 `return false`，上层只得到布尔，无法区分网络异常/解密失败/`data:[]`/HTTP 非 200（代码未校验 `res.statusCode`）。
- 影响：注册连续失败（服务端拒绝、密钥失效、返回形态变化）时用户侧是「无 dfid 但仍继续用默认 '-' 发请求」，所有依赖 dfid 的接口静默走降级路径；线上无日志可定位注册失败原因。
- 证据等级：实锤（空捕获与布尔吞因）；用户后果为静态推演

### kg_client.dart:38-53 已确认删除的 `isOk` 说明作为 15 行审查过程注释留在产品代码里
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，不复述历史过程）、第 32 条（死代码注释）
- 依据：`KgResponse` 文档注释里写「V35-A1（第 A 批，P2）：⚠️ 本 getter 与 `_wrap` 的判定口径**不一致**⋯⋯全仓零调用方（第 32 条死代码），保留会诱导调用方绕过 _wrap。已确认删除依据：`rg isOk` 仅此一处声明。若未来需要⋯⋯请命名 `isHttpOk`⋯⋯」，但文件内根本不存在 `isOk` getter（`isOk` 字面量全仓 4 处，均不在本文件）。整段描述的是一个已不存在的成员与「已确认删除」的审查流程。
- 影响：无直接用户可见后果；维护者读到 15 行与当前代码无关的历史讨论，会误判存在 `isOk` 或误以为 `_wrap` 在本类里。
- 证据等级：实锤

### kg_client.dart:615 顶层 `toBytes` 零消费
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：文件末 `Uint8List toBytes(String s) => Uint8List.fromList(utf8.encode(s));`；对 `lib/`+`test/` 全部 .dart 统计 `toBytes(` 仅此 1 处，`toBytes` 全仓仅 1 处，无任何 import 或调用。
- 影响：无用户可见后果；导出一个无人使用的公共工具函数，属「以后可能用」的遗留抽象。
- 证据等级：实锤

### kg_client.dart:436-451,492-493,566 「24-24 成功率」「均经 A/B 实测」等实测结论无留样
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条（调用方式与返回结构必须实测并留样、三态样本）
- 依据：436-451 行的大段注释声称「【实测结论 / 24-24 成功率的完整步骤】」「踩过的坑（均经 A/B 实测确认，勿改）」，包含 platid 2 约 50% 成功率、`uid` 字符串 `"0"`、小写 hex、二进制响应等结论；代码里没有指向任何 probe 脚本/样本文件/日志编号，仓库 `docs/api_verified.md` 只列了匿名态端点表（不含 r_register_dev 三态样本），`tool/` 下的 probe 脚本（仅核对文件名）也不含 register_dev 专用脚本。返回结构注释写 `data:{dfid}`，但 564-571 行实现同时接受 `data is Map` 与 `data:[]` 两种形态，三态（匿名/非 VIP/VIP）回包未见留样。
- 影响：无直接用户可见后果，但第 28/29 条要求的「任何涉及上游返回什么的结论可追溯到实测记录」不成立；后续上游改形态时无人能确认哪条 A/B 结论过期，误改参数会导致注册静默失败（这类失败在本文件里被吞成 `false`）。
- 证据等级：未实测（仅能确认留样缺失；结论真伪不在本次可执行范围内）

**本文件复核通过项（候选）**：`BaseOptions` 显式设置 connect/receive/send 三个超时（第 25 条上限）；`_kgVerboseBodyLimit = 4*1024` 对 verbose 日志体做截断且 verbose 关闭时 `_logVerboseRequest` 首行直接返回（第 24/25 条）；246-286 行对 `Uint8List` 二进制 body 走 `application/octet-stream` 直传、签名 `data` 传空串，避免把字节编码成 JSON 整数数组；`KgDevice.fromJson` 用 `'${j[...] ?? ''}'` 对持久化字段做了字符串化容错（但缺类型分支校验，见下条）。

### kg_client.dart:136-144 `KgDevice.fromJson` 对持久化数据只做 `'${...}'` 字符串化，未按类型分支校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条（外部数据禁止裸类型强转、所有边界必须校验）
- 依据：`factory KgDevice.fromJson(Map<String, dynamic> j)` 是 Hive 持久化读取边界，6 个字段全部 `'${j['guid'] ?? ''}'` 模板字符串化；若 `j['mid']` 是 `Map`/`List`/`num` 损坏数据，`guid` 与 `mid` 会被写成 `'{...}'`/`'[..]'`，`calculateMid` 不再被重新计算，`device.mid` 直接作为所有请求头与签名字段发出。没有 `is String` 分支、没有 guid→mid 一致性校验、没有空值拒绝。
- 影响：Hive 数据损坏或版本迁移后，所有直连请求带着非法 mid/guid 发出，服务端一律签名/风控失败，用户表现为整个 App 全部接口空结果，且本层不报错不留日志。
- 证据等级：静态推演（边界存在为实锤；损坏数据未实测）

### 3) `lib/core/direct/kg_crypto.dart`（402 行，完整读取）

### kg_crypto.dart:211-243 `aesEncryptHex` 名称/返回类型与实现（Base64 输出、seed 派生 key）不一致，且不满足任务书约定的 playlistAesEncrypt 派生式
- 级别：P1
- 违反：QUALITY_STANDARD 第 30 条（命名即文档）、第 3 条（契约先行）、第 28 条（实现必须与实测签名形态一致）
- 依据：函数名 `aesEncryptHex`、返回 `AesResult{str, key}`；但注释（211-214）明确「输出 Base64（对应 playlistAesEncrypt）」「seed 缺省时随机生成 6 位小写；派生：key=md5(seed)[:16], iv=md5(seed)[16:32]」，实现 240 行 `return AesResult(str: base64.encode(out), key: seed ?? '')`，即 `str` 是 Base64 而非 hex，`key` 是 6 位 seed 而非 AES key。对照 `docs/REVIEW_SPEC.md` 第 3 节约定 `playlistAesEncrypt`：`key = md5(seed)[:16]`，`iv = md5(key)[:16]`，输出 base64——本函数 iv 取的是 `md5(seed)[16:32]`（同一个 md5 的后半），不是 `md5(key)[:16]`；且 `aesDecryptPlaylistB64`（331-345）与 `_aesDecryptPlaylistBytes`（348-366）用的是与加密相同的 `md5(seed)[0:16]/[16:32]` 派生（自洽但与规范口径不同）。`kg_client.dart:484` 用其返回值 `aes.key` 作为 `aesDecryptPlaylistB64(..., aes.key)` 的 seed，注释又写「响应是二进制⋯用 seed 派生 key/iv 解密」，全链路只在本文件内自洽。同时 `AesResult.key` 的语义在 kg_client.dart:484-489 被当作 RSA 载荷里的 `'aes': aes.key` 传给服务端，若服务端按「key」而非「seed」解释则解密必然失败。
- 影响：命名误导会让新调用方把 `str` 当 hex 再解析、把 `key` 当真实 AES 密钥；一旦按 `REVIEW_SPEC` 的 `md5(key)[:16]` iv 规则接入别的端点，加解密互不相容，用户侧表现为设备注册/歌单删除/MV 收藏的二进制响应解密失败 → 静默 `false`/空结果（这些失败路径在 kg_client 里都被空捕获）。当前三个调用方因共用同一派生函数而可工作（未实测）。
- 证据等级：静态推演（命名/实现/规范不一致为实锤；跨端点解密失败为推演；未实测）

### kg_crypto.dart:85-92 `KgSignature.register` 注释声明「currently unused」，但 `kg_client.dart:253` 仍是可到达的分支
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 32 条（死代码）
- 依据：`KgSignature.register` 文档写「currently unused：注册实际走 [android]（含 body）⋯⋯保留时勿在新代码中误用为注册路径」；但 `KgClient.request` 的签名 switch（252-256）含 `'register' => KgSignature.register(allParams)` 分支，`encryptType` 是公开 `String` 入参。对全仓统计：`'register'` 字面量只在 kg_client.dart 出现 1 次（switch 分支自身），`KgSignature.register(` 共 2 次（kg_client.dart 的 switch + test/core_test.dart 一处），即生产调用方零，但分支并非不可达。注释把「可达但无人调用」写成「unused」，且没有任何实测依据说明何时该用 register 盐。
- 影响：无直接用户可见后果；维护者若按注释认为该路径已删，就不会审计 `encryptType: 'register'` 的调用方；反之若有人启用它，`register` 忽略 `data`（body 不进签名），会与注释所说的「注册实际走 android 含 body」产生静默签名错误。
- 证据等级：实锤

### kg_crypto.dart:26-28,33-34,42-43,102,114-117,136-153,202,232 `lite` 全链路常量零消费（无任何写入 true 的生产代码）
- 级别：P2
- 违反：QUALITY_STANDARD 第 32 条（死代码/无人写入的状态）、第 28 条（未经实测的分支参数）
- 依据：`KgConfig.liteAppid(3116)`、`liteClientver(11440)`、`androidSaltLite`、`signKeySaltLite`、`_publicKeyPemLite` 被 `KgSignature.android/paramsKey/keyOf`、`KgCrypto._rsaPublicKey(lite:true)`、`KgClient.request/registerDevice`、`kg_play_api.dart`、`kg_media_direct.dart`、`kg_endpoints_home.dart`、`kg_endpoints_search.dart`、`kg_direct_api_client.dart` 等 11+ 处按 `lite ? ... : ...` 读取；但对 `lib/`+`test/` 全部 .dart 的赋值统计：`KgClient.lite` 只在 202 行声明为 `bool lite = false;`，生产代码中没有任何 `client.lite = true` / `kg.lite = true` 写入（全仓 `lite =` 命中均为函数默认形参 `lite = false` 和本字段声明）。即整个「概念版 lite」通道恒 false，所有 lite 常量、lite 公钥、lite 盐、page_id/pid 的 lite 分支永不可达。仓库里唯一提到 lite 实测的是 `docs/v37_lite_channel_probe.md`（仅文件名，按纪律未读历史报告），`docs/api_verified.md` 无 lite 记录。
- 影响：无直接用户可见后果（恒 false 时行为等价标准版）；但 11 个文件里数十个 lite 分支与 5 个 lite 专属常量构成大面积无人验证的死路径，任何一次误置 true 都会把 appid/clientver/盐/公钥/签名全部切到未实测通道，用户侧表现为所有直连接口静默失败并回退。
- 证据等级：实锤（赋值统计）；未实测（lite 通道真伪不在本次可执行范围）

### kg_crypto.dart:1-11,57-68 「逐行移植」对照表与实现存在未声明的偏差（android 签名 Map/List 值 jsonEncode、web 签名不做 jsonEncode）
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（签名形态必须逐一实测）、第 31 条（注释与实际约束一致）
- 依据：文件头写「逐行移植自 KuGouMusicApi util/helper.js + util/crypto.js」并列 signKey→keyOf、signParamsKey→paramsKey 对照表；`android()`（57-68）对 `v is Map || v is List` 做 `jsonEncode(v)` 再拼 `k=v`，`web()`（78-82）却直接 `'$k=${params[k]}'`（List/Map 会变成 Dart 的 `toString()`，如 `[128, 320]` 而非 JSON `[128,320]`）。两个函数对复杂值形态处理不同，注释只解释「web 要先拼 k=v 再 sort」，未说明复杂值差异，也未给出该差异的实测依据。`paramsKey` 的 `data` 未做秒级校验/注释（对照 REVIEW_SPEC「signParamsKey 的 clienttime 必须是秒」），只在调用点各自传值。
- 影响：无直接用户可见后果（当前调用方传的多为标量），但把 Map/List 参数交给 web 签名时会产出与 Node 不一致的签名，服务端返回 `status=0`/20006 且直连层把这类失败当成业务错误（无专门日志），排查时按「逐行移植」注释不会怀疑签名形态。
- 证据等级：静态推演（代码差异实锤；服务端结果未实测）

### kg_crypto.dart:129-140,215-243,293-327 三个加解密入口对外部 key/iv/hex 无长度与形态校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条（外部数据与边界校验）、第 10 条（编程错误不得进入业务降级）
- 依据：`_rsaPublicKey` 在 155-161 行用 `as ASN1Sequence`、`elements![1] as ASN1BitString`、`integer as BigInt` 一连串裸强转，密钥常量损坏/替换时抛的是 `CastError` 而非领域异常；`aesEncryptHex(..., key: , iv: )`（215-221）与 `_aesCbcHex`（271-289）把传入 key/iv 直接 `utf8.encode` 作为 AES 密钥，未校验 16/32 字节；`aesDecryptCbcHex`（293-300）对奇数长度 hex、`int.parse(..., radix:16)` 无 try/catch，非法字符直接抛 `FormatException`；`aesDecryptPlaylistB64`（331-345）的 `base64.decode` / `jsonDecode` 异常直接抛给调用方，而 kg_client.dart:548-560 又用 `catch (_)` 吞掉。这些入口都是公开静态方法，无输入契约注释。
- 影响：上游返回密文形态变化或调用方传错 key 时，错误要么以语言级异常冒泡到 UI（崩溃/红屏），要么被上层空捕获成 `false`，两种形态都不稳定（第 8 条），用户侧表现为偶发功能失效且无日志。
- 证据等级：静态推演（缺少校验为实锤；崩溃/静默取决于调用点）

**本文件复核通过项（候选）**：`rsaEncryptRawHex`（194-209）显式检查 `bytes.length > keyLength` 并抛 `ArgumentError`，且 `padLeft(keyLength*2,'0')` 保证定长 hex；`md5/_md5Bytes` 统一走 UTF-8 + 小写 hex；`uuidV4` 正确设置 version/variant 位；`web()` 的 70-77 行注释解释了「先格式化再 sort」的历史陷阱与原因（第 31 条正向例）。

### 4) `lib/core/direct/kg_direct_api_client.dart`（662 行，完整读取）

**特别核对项（结论）**：
- `-404` 未移植路径：`get()` 289-300 行与 `post()` 362-372 行均 `throw _asDioException('/$n', ApiException(-404, '接口 /$n 尚未移植⋯'))`；`_asDioException`（164-169）构造 `DioException(requestOptions: RequestOptions(path: label), error: ApiException)`。两处包装形态一致且 DioException 的 `type` 为默认 `DioExceptionType.unknown`、`response/statusCode=null`，与 `_directOrFallback` 里其它失败路径相同，异常契约在此处**到位**（上层 `on DioException` 可捕获，`response_policy.apiExceptionOf` 能从 `.error` 取到 ApiException）。全仓 `-404` 字面量仅本文件 297/312/368 三处，无上层按 -404 特殊处理。
- `_wrap`→ResponsePolicy：80-84 行 `_wrap` 已只做 `evaluateResponse(r.body, ssaCode: r.ssaCode)` → `throw outcome.failure!` / 返回 `outcome.body`，成功判定单点已迁移；但类内 `_hasData`（89-95）与 `_commentCodeOf`（417-421）、`_qrSrcappid`（592）、`_maskMobile`（595-599）、`_qrPngBase64`（617）均已成为零消费遗留（见下）。

### kg_direct_api_client.dart:89-95 `_hasData` 在 ResponsePolicy 迁移后成为零消费死代码，且注释仍写「用于判断 151/152」
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 31 条
- 依据：`static bool _hasData` 声明于 89 行，注释「响应里是否带有有效数据（用于判断 151/152 警告码是否可忽略）」；`_wrap` 在 80-84 行已改为调用 `evaluateResponse`（`response_policy.dart` 内自带同名私有 `_hasData`，语义还更严格：排除 error/errmsg 等元键）。对全仓统计 `_hasData(` 共 3 处：本文件声明 1 处、response_policy.dart 声明+调用各 1 处，本类的 `_hasData` 零调用。
- 影响：无直接用户可见后果；但注释声称的 151/152 判定已不在此处，维护者若改本地 `_hasData` 会以为能影响成功判定，实际无效。
- 证据等级：实锤

### kg_direct_api_client.dart:417-421,592,595-599,617 四个 R1 拆分后的遗留私有成员零消费
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：R1 把实现移到 `kg_endpoints_*.dart` 后，`_commentCodeOf`（417，同名实现已搬至 kg_endpoints_comment.dart）、`_qrSrcappid`（592，kg_endpoints_auth.dart 有同名常量）、`_maskMobile`（595，kg_endpoints_auth.dart 有同名实现）、`_qrPngBase64`（617，仅声明+本文件 `Future<String> _qrPngBase64(String data) => _epAuth.qrPngBase64(data);` 一次定义，无调用）在 `lib/`+`test/` 全仓统计中各自只在本文件出现（含自身声明），无任何调用点。`import 'package:qr_flutter/qr_flutter.dart';`（12）与 `import 'dart:convert';`（7）在本文件中也无对应符号（QrPainter 在 kg_endpoints_auth.dart，本文件无 jsonDecode/jsonEncode/utf8/base64）。
- 影响：无用户可见后果；死代码 + 未使用 import，且 QR 相关 import 让 core 层多一个 UI 依赖（第 4 条分层方向亦不佳）。
- 证据等级：实锤

### kg_direct_api_client.dart:3-4 文件头注释「未移植的路径回退到父类（kapi 中转）」与实际永久禁回退相反
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 27 条口径标注
- 依据：头注释写「未移植的路径回退到父类（kapi 中转）」；实际 `static const bool fallbackToKapi = false;`（102，注释写明「永久为 false；运行期绝不发起请求」），`get()`/`post()` 的默认分支（289-300、362-372）直接抛 -404 不回退，`_directOrFallback` 的所有失败分支在 `!fallbackToKapi` 下都走 `throw _asDioException(...)`。`kapi` 闭包（177、307）虽被构造但永不执行。
- 影响：维护者按头注释判断「未移植接口仍可用，只是走 kapi」，新增/排查端点时不会意识到任何未列入 switch 的路径都是 100% 失败；用户侧表现为对应功能直接报错而非降级可用。
- 证据等级：实锤

### kg_direct_api_client.dart:102,119-160 `fallbackToKapi=false` 使全部 kapi 闭包与回退分支成为不可达代码，且 kapi 异常包装分支永不执行
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（不可达分支）、第 27 条（中转网关只能作显式兜底）
- 依据：`fallbackToKapi` 是 `static const bool = false`；`_directOrFallback` 的 ApiException 分支（127-146）与泛 catch 分支（147-159）里 `if (write || !fallbackToKapi || ...) throw ...` 与 `if (write || !fallbackToKapi) throw ...` 恒真，其后的 `try { return await kapi(); } catch (e2) { throw _asDioException(...) }` 两段永远不可达。同时 `get/post` 每个 case 都构造 `kapi` 闭包传入（约 60 处）。
- 影响：无直接用户可见后果；但「回退路径异常统一包装为 DioException」这一异常契约（142-145 注释）在编译期就不可达，等于没有生效的保障；代码量与维护误导。
- 证据等级：实锤（常量恒 false 是编译期事实）

### kg_direct_api_client.dart:118-137,164-169 直连业务失败被二次包装成 `DioException(error: ApiException(-1, ...))`，错误码在泛 catch 分支被抹平
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一且稳定、跨层保留可枚举类型）、第 9 条
- 依据：`_directOrFallback` 的 `on ApiException catch (e)` 分支保留 `e`（含 `errorCode`/`ssaCode`）并 `throw _asDioException(label, e)`；但泛 `catch (e)` 分支（147-159）对任何非 `TypeError/NoSuchMethodError` 的异常（例如 `FormatException`、`StateError`、`CastError`、Dio 层异常对象）一律 `throw _asDioException(label, e)`，而 `_asDioException` 对非 ApiException 统一 `ApiException(-1, '$e')`。即同一调用在「业务失败」与「解析/状态异常」两条路径上分别给出 `errorCode=真实码` 与 `errorCode=-1`，且 `-1` 与未移植路径 `-404`、空响应体 `-1` 共用同一错误码空间，上层无法区分。
- 影响：上层按 20028/20034 做的验证/多账号处理在泛 catch 路径上永远命中 `-1` 而失效，用户遇到登录风控时不会弹出验证码、遇到多账号冲突时不会清理 token，只显示通用失败。
- 证据等级：静态推演（代码事实实锤；上层表现依据 auth_repository.dart 中 20034 处理，未在本批完整读取该文件，标推演）

### kg_direct_api_client.dart:105-112,164-169 `lastErrors` 为无上限共享静态列表且 `debugPrint` 日志包含完整异常文本
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 25 条（资源上限）、第 20 条（生命周期对称）
- 依据：`static final List<String> lastErrors = <String>[];` 是类级可变全局状态，`_logError` 每次 `insert(0,msg)` + `length > 20 removeLast()`（有上限 20，此点合规），但没有任何 dispose/清空点，`msg` 由 `'[时间戳] $where: $e'` 拼成并 `debugPrint`。异常文本 `$e` 可能含完整 URL/query（含 token、signature、dfid），`_logError('$label (kapi 回退)', e2)` 同理；与 `ErrorLogger` 的脱敏入口（kg_client.dart:294-299 注释「脱敏由 ErrorLogger 入口统一执行」）不一致，这里直连链绕过 ErrorLogger。
- 影响：release 下 debugPrint 通常不落盘，但诊断页读取 `lastErrors` 时会展示/可能导出含 token 的完整异常文本（凭据泄露面）；列表跨账号切换不清空，切号后诊断页能看到上一账号的错误信息。
- 证据等级：静态推演（第 25 条上限 20 合规，仅记录全局状态与脱敏缺口；泄露后果取决于诊断页展示方式，未实测）

### kg_direct_api_client.dart:307 `post` 对非 Map body 静默替换为空 Map，写请求参数丢失且无日志
- 级别：P1
- 违反：QUALITY_STANDARD 第 13/14 条（外部数据边界必须校验）、第 9 条（失败可观测）、第 10 条（编程错误不得进业务降级）
- 依据：`final d = data is Map<String, dynamic> ? data : const <String, dynamic>{};`（307）——`post` 是公开覆写方法，`data` 为 `dynamic`；若调用方传 `Map<String,String>`、`List`、`String`（例如表单编码 body 或 JSON 字符串），`d` 静默变空 Map，且 `post` 的 `login`/`artist/detail`/`album/songs` 等 case 用 `{...q, ...d}` 组装参数继续发请求；`super.post(path, data, ...)` 的 kapi 闭包倒是传原始 data（但恒不可达）。无 `is! Map` 报错、无日志。
- 影响：写/登录类请求在参数类型不匹配时不是失败提示，而是带着缺失参数发出，服务端返回业务错误或（更糟）按缺省参数执行；用户看到「登录失败/评论没发出」且无任何可检索日志。
- 证据等级：静态推演（代码事实实锤；具体调用方形态未在 B2 范围内逐一核对）

### kg_direct_api_client.dart:71-84,89-95 `_wrap` 文档仍写「成功判定看 status==1」「errcode 151/152 有数据不算失败」，实现已完全委托 ResponsePolicy（歌词 status=200、mcomment err_code 等口径不同）
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）
- 依据：`_wrap` 的文档（71-78）先写「成功判定看 **`status == 1`**」「errcode/error_code 为 151/152 等警告码时⋯」，随后才有「v5.0 M4：成功/异常判定已上移 evaluateResponse（Bridge-N 单点）。本层只保留适配，禁止在此重写业务语义」。实现（80-84）只有 `evaluateResponse`，而 `response_policy.dart` 的判定还包含 `status==200`（歌词）、`err_code`（mcomment）、空响应体失败、`_warningCodes={0,151,152,200,201}` 等。注释与实现描述两套口径。
- 影响：无直接用户可见后果；维护者按「status==1」注释排查歌词/评论接口时会被误导。
- 证据等级：实锤

### kg_direct_api_client.dart:385-390,471-499,511-530 大量「实测」注释无三态留样、无可追溯记录
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条（调用方式与返回结构必须实测留样；匿名/普通/VIP 三态样本）
- 依据：`_searchLyric`（385-390）写「10 种参数/UA/Referer/签名组合全部一样空」；`_artistAudios`（471-480）写「实测 v1 匿名可返回 30 首，pagesize 上限 100」并描述 v2 data 形态；`_rankAudio`（511-520）写「【实测】data 是 Map：{total, songlist[]}」及逐字段结构；`_yuekuBanner`（约 526-530）写「匿名态恒返回 error_code=31136」。这些结论均只以注释存在，未指向 `docs/api_verified.md`（该文件只有匿名态端点表与关键发现）、probe 脚本或样本文件；全仓无「普通用户/VIP」的返回留样（第 29 条要求三态）。且 `_yuekuBanner` 注释仍写「失败由 _wrap 抛出 → _directOrFallback 回退 kapi」，与 `fallbackToKapi=false` 矛盾（见上）。
- 影响：无直接用户可见后果，但涉及上游返回结构的结论不可追溯；VIP/登录态字段形态变化会直接让解析静默返回空列表（本层无形态校验日志），用户侧表现为 VIP 用户某些页空白。
- 证据等级：未实测（留样缺失为实锤；三态回包真伪不在本次可执行范围）

**本文件复核通过项（候选）**：`_directOrFallback` 对 `write: true` 一律禁回退（133/151 行），write case 覆盖评论写三件套、歌单增删/加歌删歌等（第 21 条正向例，但注意其保护的只是 kapi 回退，不含 kg_client 的 20028 重试）；泛 catch 中 `if (e is TypeError || e is NoSuchMethodError) rethrow;`（150）落实第 10 条；`lastErrors` 保留 20 条上限（第 25 条）；`-404` 两处 DioException 包装形态一致（第 8 条，特别核对项通过）。

### 5) `lib/core/direct/kg_endpoints_artist_album.dart`（166 行，完整读取）

### kg_endpoints_artist_album.dart:1,6 两个未使用 import（含对主类的反向依赖）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（未使用的导入）、第 4 条（分层单向依赖）
- 依据：`import 'dart:convert';`（1）在整个文件里没有任何 `jsonEncode/jsonDecode/utf8/base64` 符号；`import 'kg_direct_api_client.dart';`（6）在本文件没有任何 `KgDirectApiClient` 类型引用（`KgDirectApiClient` 字样只出现在 14 行注释）。端点组本应由主类组合，此 import 形成「被组合者 import 组合者」的反向依赖（当前无环，但方向错误）。
- 影响：无直接用户可见后果；未使用导入与反向依赖增加维护/耦合成本。
- 证据等级：实锤

### kg_endpoints_artist_album.dart:10,39-43,55-62,133-146 「实测结论」全部只以注释存在，无三态留样
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条
- 依据：文件头（10）写「【实测结论见各方法注释与 docs/api_verified.md】」；`artistDetail`（26-29）写「curl 三种形态逐字段对比」、`artistAudios`（39-43）写「实测 v1 匿名可返回 30 首，pagesize 上限 100」、55-62 写 A/B/C 三种签名形态实测、`rankAudio`（133-146）写「【实测】data 是 Map：{total, songlist[]}」及字段清单。但 `docs/api_verified.md` 只有一行「rank/audio ✅ st=1 {total,songlist[]}」与「artist/audios ✅ st=1 data=list(3)」的匿名态摘要，没有 A/B/C 请求形态记录、没有回包留样、没有普通用户/VIP 三态样本。注释里 `v2 结构` 的描述也无样本来源。
- 影响：无直接用户可见后果，但「上游返回什么」的结论不可追溯；上游字段形态变更时（例如 data 从 List 变 Map）本层不做校验、上层解析静默得空列表，用户看到歌手页空白且无线上留痕。
- 证据等级：未实测（留样缺失实锤；回包真伪不在可执行范围）

### kg_endpoints_artist_album.dart:80 注释「Postg」拼写错误且未说明 albumSongs 与 artistAlbums 的路径差异
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」）、第 30 条
- 依据：`/// 歌手专辑（module/artist_albums.js）Postg /kmr/v1/author/albums，kg-tid: 36`（80）中 `Postg` 为无意义词；该方法实际 `kg.request('/kmr/v1/author/albums', method:'POST', ...)` 且 `baseUrl` 缺省走 `KgConfig.gateway`（与 `artistDetail`/`artistAudios` 明确 `baseUrl:'https://openapi.kugou.com'` 相反），注释既未说明为什么其余歌手端点落 openapi 原生域而这个仍走 gateway + x-router（第 27 条要求写明原因），也未记录该差异是否实测。
- 影响：无直接用户可见后果；维护者无法判断这是有意保留还是漏改，容易按「口径 27」误改导致直连静默失败。
- 证据等级：实锤

### kg_endpoints_artist_album.dart:15-17 类声明后连续 3 个空行与文件内散布的多余空行
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（整洁度）
- 依据：17-19 行连续空行、多处方法间仅空行无说明，属 R1 拆分残留；无功能影响，仅列为整洁度事实。
- 影响：无用户可见后果。
- 证据等级：实锤

**本文件复核通过项（候选）**：`artistAudios` 对 `pagesize` 显式夹到 100（45-46 行，第 25 条上限）；`clienttime` 用 `~/1000` 明确秒级并在注释写明（第 15 条单位显式）；`albumSongs` 的 `isBuyParam` 对 0/'0'/false/'false' 统一映射空串并注释了 Node 行为（第 31 条正向例）；`rankAudio` 对 `rankId == null` 时省略键而不是填 0（注释说明 Node `JSON.stringify` 行为）；所有 `q[...]` 取参用 `'${... ?? ''}'` 字符串化 + `int.tryParse ?? default`，无裸强转（第 13/14 条部分到位）。

### 6) `lib/core/direct/kg_endpoints_auth.dart`（426 行，完整读取）

### kg_endpoints_auth.dart:9,17 未使用 import（对被组合主类的反向依赖）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条
- 依据：`import 'kg_direct_api_client.dart';`（9）在本文件无 `KgDirectApiClient` 类型引用（仅 17 行注释出现该词）；`dart:convert` 等其余 import 均有 `jsonEncode/base64Encode` 使用。
- 影响：无用户可见后果；端点组反向 import 主类，维护时易形成循环依赖。
- 证据等级：实锤

### kg_endpoints_auth.dart:37-53 `registerDev()` 把注册失败包装成 HTTP 200 + `status:0` 的业务响应，且注释口径（kapi 兜底）与实现（原生注册）不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 8/9 条（异常契约与失败可观测）、第 31 条、第 27/33 条口径
- 依据：`registerDev()` 调 `kg.registerDevice()`（原生 userservice 注册，见 kg_client.dart:454-480），失败时 `return KgResponse(status: 200, body: {'status':0,'error':'设备注册失败'})`（49-52）。`kg.registerDevice` 内部把 DioException/解密失败/`data:[]` 全部吞成 `false`（无日志）；此处再把 `false` 伪装成 HTTP 200 响应，最终由 `_wrap`→`evaluateResponse` 抛 `ApiException(-1,'设备注册失败')`，真实失败原因（网络/密钥/形态）全部丢失。相对地，`lib/features/player/data/player_repository.dart:84-89` 的 `ensureDfid` 注释仍写「`/register/dev` 走 kapi 中转（第 33 条⋯）⋯走 kapi 兜底」——但 B2 范围内 `KgDirectApiClient.get('register/dev')` 已分派到 `_epAuth.registerDev()` 原生实现且 `fallbackToKapi=false`。注释描述的运行路径与代码不符。
- 影响：设备注册失败时用户看到的是通用「设备注册失败」而非「无网络/服务端拒绝」，重试也没有可区分的原因；排查人员按 `ensureDfid` 注释去查 kapi 中转会完全找错方向。
- 证据等级：实锤（包装与注释矛盾）；上层提示为静态推演

### kg_endpoints_auth.dart:383-399 `_afterLogin` 的解密失败用 `debugPrint` 留痕后仍继续写入登录态，属静默降级
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 11 条（降级必须有触发/退出条件）、第 8 条
- 依据：`_afterLogin` 在 `body['status'] != 1` 或 `data` 非 Map 时直接 `return`；`secu_params` 解密 `catch (e) { debugPrint('secu_params 解密失败: $e'); }`（397-399）后不做任何标记，继续执行 401-413 行 `token/userid/t1/vipType/vipToken` 回写。`dec is String` 时把整段解密文本当 token 写入 `data['token']`（394-395）。`debugPrint` 在 release 构建不落盘（项目脱敏入口 ErrorLogger 未被使用），且失败后仍可能用响应里明文的 token 完成登录，甚至把错误的字符串当 token 写入 `kg.token`。主类 `kg_direct_api_client.dart:640-655` 存在同名 `_afterLogin`（走 `_logError` 留痕），但 R1 拆分后实际调用的是本文件版本（`_afterLogin(` 在本文件 126/163/218 三处调用），两份实现行为不一致。
- 影响：登录响应加密字段解密失败时，用户可能进入「看似登录成功但 token 无效」的半登录态：请求带错 token 被服务端拒绝，界面却显示已登录；线上无日志（release）无法定位。
- 证据等级：静态推演（代码事实实锤；release 日志行为与半登录态为推演）

### kg_endpoints_auth.dart:258-284 `loginQrCheck` 对二维码登录回包 `data` 的形态与登录态字段无校验，且直接改写全局 kg.token
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 5/18 条（异步结果未校验世代）
- 依据：`loginQrCheck` 轮询（注释「自行加入时间戳以绕过缓存」）后 `final data = r.body['data']; if (data is Map && '${data['status']}' == '4') { final token = '${data['token'] ?? ''}'; ... if (token.isNotEmpty) kg.token = token; ... }`（275-282）。没有校验 `r.status`、业务 `status`/`error_code`，没有校验 token 长度/形态，也没有世代标识：用户在二维码页切到账号密码登录或退出登录后，晚到的轮询响应仍会把旧二维码的 token 覆写 `kg.token`/`kg.userid`。
- 影响：外部回包异常或轮询晚到会污染登录态，用户出现「显示 A 账号但请求实际用 B 账号/无效 token」的权限混乱，且无日志。
- 证据等级：静态推演（代码事实实锤；世代冲突后果为推演）

### kg_endpoints_auth.dart:352-380 `getVerifyInfo` / `verifyUserInfo` 把外部 `eventid`/`sid`/`edt` 未校验即透传，`Uri.decodeComponent` 异常可冒泡
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 8 条
- 依据：`getVerifyInfo`（350-365）直接 `'eventid': q['eventid']`（可为 null/Map/List）、`'platid': q['platid'] ?? 2`；`verifyUserInfo`（368-380）对 `sid`/`edt`/`verifycode` 用 `Uri.decodeComponent('${d[...] ?? ''}')`，`Uri.decodeComponent` 对非法百分号转义会抛 `FormatException`（未捕获），`vType` 只 `int.tryParse ?? 23`，其它分支（非 23/32）仍照常发请求且带空 `sid/edt`。这些参数来自 `/get/verify/info` 的网络回包（外部数据边界）。
- 影响：风控验证回包里 sid/edt 含异常转义时，用户点「提交验证」直接抛语言级异常（未经 `_asDioException` 包装，因为端点方法在 `_directOrFallback` 的 direct 闭包里、会被泛 catch 转成 `ApiException(-1)`），表现为验证失败且无法区分是输入问题还是服务端拒绝。
- 证据等级：静态推演（外部来源与无校验实锤；异常形态未实测）

### kg_endpoints_auth.dart:240-256 `loginQrCreate` 自行合成 `status:200` 成功响应，绕过 `_wrap`/ResponsePolicy 且二维码渲染失败静默返回空 base64
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 16 条（空集合与缺失语义分离）、第 3 条
- 依据：`loginQrCreate` 不发网络请求，直接构造 `KgResponse(status:200, body:{'code':200,'status':200,'data':{'url':url,'base64':b64,'key':key}})`；`b64 = wantImg ? await qrPngBase64(url) : ''`（244），`qrPngBase64`（416-425）在 `picData == null` 时返回 `''`，无日志。合成响应里 `status:200` 与 ResponsePolicy 的「歌词类 status==200」口径耦合，靠 `errcode` 缺省为 0 判成功（`_warningCodes` 含 200）。UI 拿到 `base64:''` 无法区分「未请求图片」「渲染失败」「渲染中」三种状态。
- 影响：二维码渲染失败时用户看到空白/无二维码的登录页，没有错误提示也没有日志；`qrimg` 参数缺失时同样静默返回空串。
- 证据等级：静态推演（合成响应与空串实锤；UI 表现未实测）

### kg_endpoints_auth.dart:10,26-29,56-62 「实测结论」注释无留样；V33-03 的 TLS 结论指向被禁止读取的历史报告
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条
- 依据：文件头（10）写「【实测结论见各方法注释与 docs/api_verified.md】」；`captchaSent`（56-62）写「实测 https 直连 TLS hostname mismatch（batch4 M7）」，引用的是 `docs/batch4_*` 历史审查报告（本任务硬性规则禁止读 `docs/batch*`），且 `docs/api_verified.md` 未收录 `captcha/sent` 条目；`loginQrKey`/`loginQrCheck` 的三态（匿名/普通/VIP）回包无留样；`loginCellphone`/`login`/`loginToken` 三个登录端点的请求参数集合、t1/t2/t3 固定常量来源、加密盐仅以「与 Node 版一致」说明，无 probe 记录。
- 影响：无直接用户可见后果，但涉及「上游返回什么 / 请求形态」的结论不可追溯；上游改登录协议时无人能判断哪条常量过期，登录会静默失败（失败被 `_afterLogin` 的 `status!=1` 直接 return 吞掉）。
- 证据等级：未实测（留样缺失实锤；结论真伪不在可执行范围）

### kg_endpoints_auth.dart:412-413 `kg.vipToken` 是无人读取的第二份状态
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（无人写入/读取的状态）、第 5 条
- 依据：`kg.vipToken` 在 kg_client.dart:200 声明、本文件 412-413 写入；对 `lib/`+`test/` 全仓统计 `vipToken` 只出现在这 4 处（1 声明 + 3 本文件），零读取。`kg.vipType` 尚有 kg_endpoints_home.dart:160-161 消费（三态判定），`vipToken` 完全没有。
- 影响：无用户可见后果；留了一个「以后可能用」的字段，与 `kg.dfid` 同属第 32 条事实。
- 证据等级：实锤

**特别核对项（ensureDfid 的 Completer 并发收敛与重试上限，跨范围代码事实核对）**：`lib/features/player/data/player_repository.dart:60-117` 的 `ensureDfid` 用 `_registering` 布尔 + `_registeringFuture = completer.future`（81-82）让并发等待者汇聚到同一事务，`finally`（113-116）无条件 `_registering=false; _registeringFuture=null; completer.complete();`。核对结论：① 失败路径 `catch (e) { rethrow; }`（111-112）后仍只 `completer.complete()` 而非 `completeError`，等待者 `await pending` 的 `catch (_) {}`（69-71）拿到的是「成功完成」，于是 72 行 `return ensureDfid()` 重读缓存/再试一轮；② 重试上限 `_registerRetries >= 3` 的检查（75-77）**只在 `_registering==true` 且 `pending==null` 的分支**执行，而 `finally` 已把 `_registering` 置 false、`_registeringFuture` 置 null，正常并发下等待者醒来时该分支不可达；③ 多个等待者同时重入时每轮都会各自 `return ensureDfid()`，`_registerRetries` 只在「前一注册者已失败落库」的窄分支累加，109 行成功后归零。因此 Completer 确实做了并发收敛，但重试上限并未覆盖「注册事务持续失败」的主路径，`completer.complete()` 也不区分成功/失败——该事实属 B5 范围，本报告只作特别核对记录，不在此重复计问题（避免超范围计数）。

**本文件复核通过项（候选）**：`loginCellphone`/`login`/`loginToken` 的 `clienttime_ms` 用毫秒、`clienttime` 用 `~/1000` 秒并在注释标明（第 15 条）；`userDetail` 注释写明「实测响应无 userid，回填供 AuthRepository」的为什么（第 31 条正向例）；`loginQrCheck` 自行加 `_t` 时间戳绕过缓存（第 23 条相关）。

### 7) `lib/core/direct/kg_endpoints_comment.dart`（301 行，完整读取）

### kg_endpoints_comment.dart:6,14 未使用 import（反向依赖主类）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条
- 依据：`import 'kg_direct_api_client.dart';`（6）在本文件无类型引用（仅 14 行注释）。
- 影响：无用户可见后果；反向依赖与死 import。
- 证据等级：实锤

### kg_endpoints_comment.dart:73-120,125-171,175-197 三个写端点无本地提交锁/去重键，仅靠上层 `_directOrFallback(write:true)` 禁 kapi 回退
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作必须幂等或有防重机制）、第 22 条（并发假设未写明）
- 依据：`commentSend`、`commentFloorSend`、`commentDel` 都是直接 `return kg.request(...)`，无 in-flight 去重、无幂等键、无请求序号；`clienttime` 是秒级 `DateTime.now() ~/ 1000`（74/126/176），同一秒两次请求的 `key = paramsKey(clienttime + mid [+ data])` 完全相同，服务端若以 key 判重则第二次会被当成重放，若不判重则重复发评论。`KgDirectApiClient` 的 `write: true` 只禁止「直连失败后回退 kapi 重发」，不阻止 UI 重复点击/多次调用，也不阻止 `KgClient.requestWithVerify` 的 20028 重试（本文件均未使用该方法，此点是正向的）。代码里没有任何注释声明「调用方负责防重」的并发前提。
- 影响：用户双击发送、网络抖动后重试、或 UI 重入时，同一评论/回复可能被提交两次（服务端重复评论），或第二次被判重放后收到失败提示但实际已发出（结果未知）；删除评论重试会二次删除。
- 证据等级：静态推演（无防重代码实锤；重复提交取决于 UI 与服务端判重，均未在本次可执行范围实测）

### kg_endpoints_comment.dart:73-120 写端点的 `params`/`data` 混入未经形态校验的外部值，`images` 列表元素不校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条
- 依据：`commentSend` 的 `contentData` 用 `'${q['content'] ?? ''}'` 字符串化、`'images': images is List ? images : const <String>[]`（88）——List 内元素可为 Map/int/null，直接 `jsonEncode` 发出；`params` 里 `'mixsongid': q['mixsongid']`（32）、`'p': q['page'] ?? 1`、`'pagesize': q['pagesize'] ?? 30`（34-35）等来自 Repository/UI 的 query 直接透传，未做类型/范围校验；`commentFloorSend` 的 `'is_t': isTopLevel`（165）直接取 `q['is_t'] ?? q['isT']` 原值（可为字符串/Map），`'childrenid': q['special_id']`（commentFloor 288）等同样裸传。`_nonEmpty` 只做字符串化真值判断，不做类型分支（第 13 条）。
- 影响：上游或 UI 参数形态异常时请求体/query 变成 Map 的字符串表示或 null，服务端返回业务错误，用户看到「评论发不出去/列表为空」且本层无形态校验日志可定位。
- 证据等级：静态推演（外部来源与裸传实锤；服务端反应未实测）

### kg_endpoints_comment.dart:22-29,44-56,278-290 「四种形态 curl 对比」「TLS 证书不匹配」「0 差异」等实测结论无留样、无三态样本
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条
- 依据：`commentMusic`（22-27）写「【实测 2026-11-06】三种形态 curl 对比（mixsongid=32100650）」并列出 A/B/C/D 四种结果；`commentCount`（44-49）写 openssl/python/curl 的证书结论与「与 kapi 逐字段一致（0 差异）」；`commentFloor`（278-283）写「实测 song 分支必须带 childrenid⋯与 kapi 逐字段一致（0 差异）」。这些结论均只以注释存在，`docs/api_verified.md` 只有匿名态一行摘要（「comment/music ✅ st=1 顶层 list」「comment/count ✅ {"hash":710442}」），无 curl 记录、无回包留样、无匿名/普通/VIP 三态样本；「与 kapi 逐字段一致」本身还触犯第 33 条（kapi 返回经 Node 包装，不可作为原生网关的实测依据），注释未标注「kapi 包装结果，需原生复核」。
- 影响：无直接用户可见后果，但「上游返回什么」不可追溯且以 kapi 包装结果作对照；上游改形态时评论列表会静默空列表（本层无形态校验）。
- 证据等级：未实测（留样缺失实锤；第 33 条相关对照口径违规实锤）

### kg_endpoints_comment.dart:10,17-19 文件头「实测结论见 docs/api_verified.md」与拆分后残留空行
- 级别：P3
- 违反：QUALITY_STANDARD 第 31/32 条
- 依据：文件头 10 行写「【实测结论见各方法注释与 docs/api_verified.md】」，但 `docs/api_verified.md` 无评论写端点（commentsv3/add、commentsv2/reply、delcomment）的实测条目，也无 TLS/curl 形态对比；17-19 行为连续多余空行。
- 影响：无用户可见后果；注释指向不存在的留样，误导后来者以为写端点已实测。
- 证据等级：实锤

**本文件复核通过项（候选）**：三个写端点均显式 `clearDefaultParams:true, notSignature:true` 并自带 `key = KgSignature.paramsKey(clienttime + mid [+data])`，与 REVIEW_SPEC「/index.php×3 评论写」的签名口径一致；`commentDel` 按 Node 默认改回 GET 且注释写明原因（第 31 条正向例）；`_nonEmpty` 把 null/''/'null'/'undefined' 统一判缺失，`_childName` 收敛四个别名，避免空值下发；三个写端点都走 `kg.request` 而非 `requestWithVerify`（第 21 条部分到位）。

### 8) `lib/core/direct/kg_endpoints_home.dart`（198 行，完整读取）

### kg_endpoints_home.dart:146-148 `yuekuBanner` 注释声称「失败回退 kapi → fetchBanners 容错置空」，与 `fallbackToKapi=false` 矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 9 条
- 依据：注释（146-148）写「匿名态恒返回 error_code=31136⋯失败由 _wrap 抛出 → _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空」；实际 `KgDirectApiClient.fallbackToKapi` 是编译期常量 false（kg_direct_api_client.dart:102），`_directOrFallback` 在 `!fallbackToKapi` 下直接 `throw _asDioException(label, e)`，kapi 闭包永不执行。即 banner 失败实际上变成抛给上层的 DioException，而不是「回退 kapi 后置空」。同时注释里的「vip_type=0 与 1 均复现」只是两种 vip_type，不构成第 29 条要求的匿名/普通/VIP 三态留样。
- 影响：维护者按注释认为 banner 恒走容错置空，实际上上游一返 31136 就把异常抛给首页层；若上层没有对应 catch，用户看到整块首页报错而非空 banner，且排查方向被注释误导。
- 证据等级：实锤（常量与注释）；首页表现未实测（上层不在 B2 范围）

### kg_endpoints_home.dart:1,6,38,17-19 R1 拆分残留：两个未使用 import、一个错置的「歌手详情」注释、多处连续空行
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 31 条
- 依据：`import 'dart:convert';`（1）无对应符号（本文件无 jsonEncode/jsonDecode/utf8/base64）；`import 'kg_direct_api_client.dart';`（6）无类型引用（仅 14 行注释）；38 行孤立的 `/// 歌手详情（module/artist_detail.js）` 挂在 `rankList` 前面，与该方法（榜单列表）完全无关，是从别处复制残留；17-19、33-36 行连续多余空行。
- 影响：无用户可见后果；错置注释把 rankList 标成歌手详情，误导维护者。
- 证据等级：实锤

### kg_endpoints_home.dart:55,89-92,133,146,173-175 「与 kapi 结构一致 / 实测」注释未标注第 33 条口径，且 F4-11 实测依据指向禁止读取的历史报告
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条、第 33 条、第 31 条
- 依据：`topSong`（55）写「与 kapi /top/song 结构逐字段一致（0 差异）」、`searchHot`（133）写「与 kapi /search/hot 结构一致」、`videoDetail`（173-175）写「与 kapi /video/detail 结构一致（既往验证 + 本轮复核）」——三处都以 kapi 返回作原生网关的对照结论，未按第 33 条标注「kapi 包装结果，需原生复核」。`topPlaylist`（89-92）写「【实测 2026-11-06】gateway + x-router 直连可用⋯见 docs/batch4_fix_1_network.md F4-11」，而 `docs/batch4_*` 属本任务禁止读取的历史审查报告，仓库内无可追溯的原生回包留样；`docs/api_verified.md` 反而还写着「top/playlist ⚠️ ec=200101 直连不可用，保留 kapi 回退」，与 89-92 行「直连可用、special_list 35 条」的结论**直接冲突**且两处都没有样本。`yuekuBanner`（146）的「匿名态恒 31136」也无三态留样。
- 影响：无直接用户可见后果，但同一端点在代码注释与实测记录里给出相反结论，后续按 `docs/api_verified.md` 恢复 kapi 回退或按注释改参数都会让首页/推荐歌单静默失败或空列表；第 33 条要求的口径标注缺失。
- 证据等级：未实测（冲突与标注缺失为实锤；端点真伪不在可执行范围）

### kg_endpoints_home.dart:46-49,97-101,154-157 请求参数直接透传 `q[...]` 且 `userid` 解析失败静默落 0
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 16 条（缺失与零值语义分离）
- 依据：`topSong` 的 `'rank_id': q['type'] ?? q['rank_id'] ?? 21608`、`'page': q['page'] ?? 1`（46-48）直接把 dynamic 放进 body；`'userid': int.tryParse('${q['userid'] ?? kg.userid}') ?? 0`（49）把「未登录（'0'）」「参数损坏（非数字）」「登录态缺失」三种事实统一映射成数值 0。`topPlaylist`（97-101）同样 `int.tryParse(kg.userid) ?? 0`；`yuekuBanner`（157）`'userid': q['userid'] ?? kg.userid` 干脆把字符串形式的 userid 原样下发；`vip_type` 用 `int.tryParse(kg.vipType) ?? 0`，VIP 值不可解析时静默按非会员发请求（161）。
- 影响：登录态字段损坏或上游期望数值/字符串不一致时，个性化推荐/banner 按匿名用户返回，VIP 用户看不到会员专属位；本层无日志，用户只看到「内容变了/少了」。
- 证据等级：静态推演（映射事实实锤；上游反应未实测）

**本文件复核通过项（候选）**：`topPlaylist` 把 `clienttime` 明确 `~/1000` 秒级并写明历史陷阱「此前误用 YYYYMMDDHH→ec=200101」（第 15/31 条正向例）；对三标签域名的 TLS 限制（yueku/everydayRecommend/topPlaylist/videoDetail）均写明「为什么保持 gateway + x-router」，符合第 27 条「仅尚未移植路径可显式兜底且必须写明原因」的说明义务；`videoDetail` 的 `clearDefaultParams:true` 与 REVIEW_SPEC 允许清单一致。

### 9) `lib/core/direct/kg_endpoints_media.dart`（131 行，完整读取）

### kg_endpoints_media.dart:88,109 两处注释声称「_directOrFallback 已兜底回退 kapi / 回退 kapi（同样失败）」，与 `fallbackToKapi=false` 矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）
- 依据：`songUrl`（88）写「直连仍可能遇 20028（与 IP/风控相关），_directOrFallback 已兜底回退 kapi」；`privilege`（107-109）写「此前照发 resource: []，上游回 20010 → _wrap 判失败 → 回退 kapi（同样失败），白白多打两次请求」。实际 `KgDirectApiClient.fallbackToKapi` 恒 false（kg_direct_api_client.dart:102）且 `get/post` 的 kapi 闭包永不执行。也就是说 20028 发生时直连抛 `ApiException`→`DioException`，由上层验证流程处理，绝无 kapi 回退。
- 影响：维护者按注释会以为播放地址在风控时还有 kapi 兜底，排查「风控后无播放地址」时会去找不存在的中转请求；用户实际看到的是播放失败/需验证，与注释描述不一致。
- 证据等级：实锤

### kg_endpoints_media.dart:112-118 `privilege` 空 hash 时返回合成 `KgResponse(status:502, body:{status:0,...})`，把本地校验错误伪装成 HTTP 502 业务响应
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一且稳定）、第 3 条、第 9 条
- 依据：空 `resource` 时 `return Future.value(const KgResponse(status:502, body:{'status':0,'error_code':-1,'error':'缺少歌曲 hash'}))`；注释（105-109）说明这是对齐 Node 的 `Promise.reject({status:502, error_code:-1, error:'缺少歌曲 hash'})`。但 `KgClient.request` 在 DioException 时也返回 `status:502` + `body:{'status':0,...}`（kg_client.dart:301-304），两种完全不同的失败（本地参数缺失 vs 网络异常）共用同一形态且都不写日志；`KgResponse.status` 是 HTTP 状态语义，此处 502 是伪造的（未发生任何 HTTP 请求）。`error_code:-1` 又与 `_asDioException` 的泛 catch `ApiException(-1,...)`、ResponsePolicy 空响应体 `-1` 同码。
- 影响：用户传空 hash（例如解析失败的歌曲）时看到的是「网络/服务失败」类提示而不是明确的「缺少歌曲 hash」，且线上日志无法区分本地校验与真实 502；上层若按 502 做重试会反复打本地失败。
- 证据等级：静态推演（形态实锤；上层重试/提示表现未实测）

### kg_endpoints_media.dart:1,6,15 两个未使用 import（含反向依赖主类）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条
- 依据：`import 'dart:convert';`（1）无对应符号；`import 'kg_direct_api_client.dart';`（6）无类型引用（仅 15 行注释）。`kg_play_api.dart show KgSharedParams` 有实际使用。
- 影响：无用户可见后果；死 import 与反向依赖。
- 证据等级：实锤

### kg_endpoints_media.dart:33,47,66-67,127,10 「匿名/VIP 实测」「与 kapi 逐字段一致 0 差异」无三态留样且未标注第 33 条口径
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条、第 33 条
- 依据：`kmrAudioMv`（30-33）写「匿名/VIP 实测 200 status=1，与 kapi 逐字段一致（0 差异）」、`videoUrl`（44-47）同样、`songUrl`（85-87）写「匿名/VIP 实测 200 status=1」、`privilege`（124-127）写「与 kapi 逐字段一致 0 差异」；文件头（10）指向 `docs/api_verified.md`（只有匿名态一行摘要）。没有匿名/普通用户/付费用户三态回包留样，没有 probe 记录，且所有「与 kapi 一致」的对照都未标注「kapi 包装结果，需原生复核」。`docs/api_verified.md` 写「song/url ✅ st=1 需 key；直连无 20028」，与本文件 88 行「直连仍可能遇 20028」结论冲突。
- 影响：无直接用户可见后果，但涉及上游返回结构与风控码的结论既不可追溯又互相矛盾；VIP 曲的 `status=2 + fail_process` 形态（api_verified.md 提到）在本层无任何校验/注释，解析静默异常时用户看到播放按钮无反应。
- 证据等级：未实测（留样缺失与注释冲突实锤；端点真伪不在可执行范围）

### kg_endpoints_media.dart:38-41,45,99-100 `videoUrl` 的 hash 与 `privilege` 的逗号串未做形态校验/长度上限
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 25 条（资源上限）
- 依据：`videoUrl` 直接 `final hash = '${q['hash'] ?? ''}'`（39）并用于 `keyOf(hash:)` 与 query，空串也照发；`kmrAudioMv` 把 `'${q[...] ?? ''}'.split(',')` 的结果无上限地 `.map(...).toList()`（22-25、37）构造 body；`privilege` 把 `q['hash']`/`q['album_id']` 的逗号串同样无长度上限地拆成 List（99-100）交给 `KgSharedParams.privilege`；`KgSharedParams.privilege` 本身对 hash 只过滤空串/'null'，没有条目数上限。这些是来自 Repository/UI 的外部边界。
- 影响：异常超长参数会构造巨大请求体/查询串，触发超时或风控，用户看到 MV/权益信息加载失败；无日志可定位是参数形态问题。
- 证据等级：静态推演（缺少校验实锤；上游反应未实测）

**本文件复核通过项（候选）**：`songUrl`/`privilege` 明确复用 `KgSharedParams`（避免两份参数拷贝，第 5 条单一来源正向例）；`privilege` 对空 `resource` 做前置拦截，避免无谓请求（第 24 条按需计算）；`videoUrl` 注释写明 downurl 的 http→代理转换留在 Repository 层、直连层原样返回（第 1/4 条分层说明）。

### 10) `lib/core/direct/kg_endpoints_playlist.dart`（288 行，完整读取）

### kg_endpoints_playlist.dart:20-67 删除歌单（写操作）响应解密失败被空捕获吞掉，结果未知时原样返回未解密响应
- 级别：P1
- 违反：QUALITY_STANDARD 第 6/9 条（禁止吞异常、失败可观测）、第 21 条（写操作结果未知语义）、第 8 条
- 依据：`playlistDel` 是 `write:true` 的写端点（kg_direct_api_client.dart:221-223），POST `/v2/delete_list` 后响应为 AES 二进制；48-64 行 `try { ... aesDecryptPlaylistB64(...); if (decoded.containsKey('status')) return KgResponse(...); } catch (_) { // 解密失败不影响判定 }`，随后 `return res;`。`res` 此时是 kg_client.dart:305-313 把二进制宽松 UTF-8 解码后 `jsonDecode` 失败的产物 `{'status':0,'error':'响应解析失败','raw':...}`，或 HTTP 502 的伪造响应。即「服务端可能已删除歌单，但本地无法确认」这一结果未知状态被伪装成普通业务失败，且没有任何日志/标记。上层若按失败提示用户重试，就会二次提交删除请求。
- 影响：用户在网络抖动/密钥派生不一致时点「删除歌单」，界面报失败但服务端已删除；用户重试可能收到「歌单不存在」或把另一个同 id 对象再删一次，且线上无日志可定位解密失败。
- 证据等级：静态推演（空捕获与返回形态实锤；服务端是否已执行未实测）

### kg_endpoints_playlist.dart:106-132,134-152 加歌/删歌写端点无防重机制，`_parseTracksResource` 对空/畸形数据静默产出空数组或 0 值
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条、第 13/14 条、第 16 条
- 依据：`playlistTracksAdd` 用 `_parseTracksResource('${q['data'] ?? q['songs'] ?? ''}')`（111），后者（265-287）对空串返回 `const []`，对缺字段用 `f0(i)=''`、`int.tryParse(...) ?? 0` 静默补 0（`hash`、`album_id`、`mixsongid` 全可为 0/空），无条目数上限（第 25 条），然后照常发 POST；`playlistTracksDel` 对 `fileids` 逗号串 `int.tryParse(e.trim()) ?? 0`（145）把非数字 id 静默变成 0 并下发。两个写端点都没有提交锁/去重键/请求序号，与评论写端点同构；上层 `write:true` 只禁 kapi 回退。
- 影响：UI 重复点击或自动重试会把同一批歌加两遍/删两次；畸形数据发出后服务端可能按 0 id 操作，用户看到「歌单里多出两首同名」或「删错歌」，且无日志说明是入参形态问题。
- 证据等级：静态推演（无防重与静默 0 值实锤；服务端行为未实测）

### kg_endpoints_playlist.dart:213,216 `playlistDetail` 直接裸抛 `ApiException`，绕过 `_asDioException` 的 DioException 包装契约
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（同一层异常形态必须一致）、第 3 条
- 依据：`playlistDetail` 在 ids 为空或 >10 时 `throw ApiException(-2, ...)`（213/216）。该异常在 `KgDirectApiClient._directOrFallback` 的 `on ApiException catch (e)` 分支会被捕获并 `_asDioException`，此处形态最终仍统一（**特别核对**：比 media 端点的合成 502 更符合契约）；但错误码 `-2` 是本文件自造、全仓无其它消费方，且异常在端点方法内直接抛出而非由 `_wrap` 产生，属本地校验与业务失败混在同一错误码空间。相对地 `privilege`（kg_endpoints_media.dart:112）同类本地校验却返回合成 KgResponse。两处同一类本地校验的异常形态不一致。
- 影响：上层若只 `on DioException` 捕获（B2 注释声明的契约），直接调用端点组时拿不到裸 ApiException；-2 无专门语义，UI 只能显示通用错误，用户不知道是「缺少 gid」还是「一次最多 10 个」。
- 证据等级：静态推演（形态差异实锤；上层捕获未在本批完整核对）

### kg_endpoints_playlist.dart:6,15 未使用 import（反向依赖主类）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条
- 依据：`import 'kg_direct_api_client.dart';`（6）无类型引用（仅 15 行注释）；`dart:convert`/`kg_crypto.dart`/`errors.dart` 均有实际使用。
- 影响：无用户可见后果；死 import 与反向依赖。
- 证据等级：实锤

### kg_endpoints_playlist.dart:10,190-200,238-242 「实测」载荷结论无三态留样
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条
- 依据：`playlistDetail`（190-200）写「实测：载荷必须是 {"data":[{"global_collection_id":"<gid>"}]}⋯旧写法 v1/v2/v3 都返回 20010」；`playlistTrackAll`（238-242）写「【实测】global_collection_id 只接受 collection_... 形式」；文件头（10）指向 `docs/api_verified.md`（只有匿名态「playlist/detail ✅ st=1 data=list[1]」与「playlist/track/all ✅ st=1」两行）。歌单写端点（delete_list/add_list/add_song/delete_songs）在 `api_verified.md` 完全没有条目，也没有匿名/普通/VIP 三态回包留样；AES 二进制响应的结构注释只写「用同一 seed 解密」，无样本。
- 影响：无直接用户可见后果，但写端点的成功判定（尤其 `decoded.containsKey('status')`）没有实测依据支撑，上游返回结构变化会走「解密失败→吞掉→通用失败」路径，用户看到删除失败却可能已生效。
- 证据等级：未实测（留样缺失实锤；结论真伪不在可执行范围）

**本文件复核通过项（候选）**：`playlistDel` 的 RSA 用 `rsaEncryptPkcs1`（注释说明此前误用无填充裸 RSA，第 31 条正向例）；`playlistDetail` 对 gid 数量显式 1..10 校验并抛明确错误（第 25 条上限正向例，尽管形态与其它本地校验不一致）；`playlistTracksDel` 注释写明「去掉 cloudlist.service/ 前缀避免与 x-router 叠加 404」的历史陷阱。

### 11) `lib/core/direct/kg_endpoints_search.dart`（153 行，完整读取）

### kg_endpoints_search.dart:23-26 `q['type'] as String` 裸强转（跨层外部输入），非法形态直接抛 CastError 并被泛 catch 抹成 -1
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 10 条、第 8 条
- 依据：`final type = ['special','lyric','song','album','author','mv'].contains(q['type']) ? q['type'] as String : 'song';`（23-26）。`List<String>.contains(Object?)` 只保证值在白名单里时是 String（此处白名单恰好是 String 常量，故实际不会因 contains 命中非 String），但写法仍是裸 `as String`；更重要的是 `q` 是 `KgDirectApiClient.get/post` 透传的 `Map<String,dynamic>`，未声明 type 的取值范围契约，其它分支 `'/v1/search/$type'`（68）会把 type 直接拼进 URL。对比 `lyric()` 对 id/accesskey 做了显式空值校验，此处没有。
- 影响：调用方传 `type: 123`/null 时落到默认 `'song'`（尚可），但维护者误改白名单为 dynamic 或调用方传自定义 String 子类/枚举时，`as String` 抛 `CastError`，被 `_directOrFallback` 泛 catch 转成 `ApiException(-1)`，用户看到「搜索失败」且无日志指向参数形态。
- 证据等级：静态推演（代码事实实锤；异常形态为推演）

### kg_endpoints_search.dart:138-148 歌词 `decode=true` 的 Base64 解码失败被完全空捕获，静默返回无 `decodeContent` 的「成功」响应
- 级别：P1
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（静默降级必须留痕）、第 3/16 条
- 依据：`lyric()` 在 `decode=true` 且 `fmt=='lrc' || ct != '0'` 时执行 `try { body['decodeContent'] = utf8.decode(base64.decode(content), allowMalformed: true); } catch (_) {}`（143-147）——空体捕获，无日志、无错误标记、无降级值。`body` 是 `r.body`，函数随后 `return r`，上层拿到 `status:200` 的成功响应但 `decodeContent` 缺失，无法区分「上游未给 content」「fmt 不匹配」「Base64 损坏」三种事实。
- 影响：歌词内容损坏或非 Base64 时，用户看到「歌词加载成功但一片空白/一直转圈」，没有任何错误提示与可检索日志；上层若按 `decodeContent` 存在与否做重试，会反复打同一请求。
- 证据等级：静态推演（空捕获实锤；UI 表现未实测）

### kg_endpoints_search.dart:121-123 `lyric` 参数缺失裸抛 `ApiException(-1)`，与 media 端点同类本地校验的合成 KgResponse 形态不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）
- 依据：`if (id.isEmpty || id=='null' || accesskey.isEmpty || accesskey=='null') throw ApiException(-1, '歌词下载参数缺失（id/accesskey）');`（121-123）；B2 范围内同类本地校验至少有三种形态：本处裸 ApiException(-1)、kg_endpoints_playlist.dart:213/216 裸 ApiException(-2)、kg_endpoints_media.dart:112 合成 `KgResponse(status:502, error_code:-1)`、kg_client.dart:301 网络异常的 `KgResponse(status:502, status:0)`。虽然最终经 `_directOrFallback` 大多被包成 DioException，但错误码与 `status` 语义各不相同，且裸 ApiException 在端点组被直接调用时不符合「上层只 on DioException」的声明契约。
- 影响：上层按 `DioException.error` 里的 errorCode 做分支时，-1 同时表示「参数缺失」「空响应体」「泛异常」，无法给出「请先选择歌词」之类的准确提示；用户只看到通用失败。
- 证据等级：静态推演（形态差异实锤；上层提示未实测）

### kg_endpoints_search.dart:6,15 未使用 import（反向依赖主类）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 4 条
- 依据：`import 'kg_direct_api_client.dart';`（6）无类型引用（仅 15 行注释）；`dart:convert` 有 `base64.decode`/`utf8.decode` 使用。
- 影响：无用户可见后果；死 import。
- 证据等级：实锤

### kg_endpoints_search.dart:31-33,85-92,11 「与 kapi 结构完全一致（0 差异）」「10 种组合实测」无原生留样且未标注第 33 条口径
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条、第 33 条、第 15 条
- 依据：`search`（31-33）写「实测：kapi /search 返回的是 version=3 结构⋯与 kapi 结构完全一致（0 差异）」，把 kapi 包装结果当作原生 v3 结构的对照依据且未标注需原生复核；`searchLyric`（85-92）写「10 种参数/UA/Referer/签名组合全部一样空」「返回 x-kg-errcode:200 与 candidates 数组」，无样本；`duration 传毫秒：搜索结果 Duration 是秒，服务端候选 duration=269792` 与实现（108-110）`'duration': q['duration_ms'] ?? durationSec * 1000` 的自造单位换算无实测记录（第 15 条要求单位显式，此处只有注释且字段名 `duration` 承载毫秒）。文件头（11）指向的 `docs/api_verified.md` 只有匿名态「search/song ✅ st=1」「lyric/search ✅ st=200 errcode=200」摘要，无三态留样。
- 影响：无直接用户可见后果，但单位换算与成功语义（status=200 vs errcode=200）若与上游不符，直连会静默失败并落到空歌词；排查时无可追溯样本。
- 证据等级：未实测（留样/标注缺失实锤；上游行为不在可执行范围）

**本文件复核通过项（候选）**：`search` 对 `type` 做白名单收敛、默认 `'song'`（避免任意字符串拼进路径，部分落实第 14 条）；`lyric` 对 `id/accesskey` 空值与字符串 `'null'` 前置拒绝（第 14/16 条正向例）；`searchLyric` 的 `clearDefaultParams:true, notSignature:true` 与歌词搜索口径一致；`decode=true` 时按 `contenttype` 字符串 `"0"` 判定 KRC/LRC（注释写明上游形态反常，第 31 条正向例）。

### 12) `lib/core/direct/kg_media_direct.dart`（89 行，完整读取）

### kg_media_direct.dart:1-89 整个 `KgMediaDirect` 扩展零消费（无 import、无调用方），且与 `KgEndpointMedia/Home` 的 videoDetail 实现重复
- 级别：P2
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 5 条（同一事实多处实现）
- 依据：对 `lib/`+`test/` 全部 .dart 统计：`KgMediaDirect` 只在本文件声明 1 次；`kg_media_direct`（导入路径）零出现，即没有任何文件 import 本文件；`images(` 全仓仅本文件 1 处（定义），`expendablekmr.kugou.com`、`author_image/audio` 全仓仅本文件；`videoDetail(` 的 4 处分别是本文件定义、kg_endpoints_home.dart 的实现与委托、kg_direct_api_client.dart 的转发，扩展方法本身无调用。同时 59-89 行的 `videoDetail` 与 `kg_endpoints_home.dart:171-197` 的 `videoDetail` 是同一端点（`/v1/video`，同 x-router、同 `clearDefaultParams`、同字段集合）的第二份拷贝，主类实际分派到后者（`_epHome.videoDetail` / `_videoDetail`）。
- 影响：无当前用户可见后果（死代码不执行），但两份实现可各自漂移：维护者改了 home 版参数，扩展版仍保留旧形态；一旦有人 import 本文件给封面/视频详情用，未实测的 `images` 端点（签名手工拼在 URL query 里、`notSignature:true`）会直接成为主路径，用户可能看到封面加载失败。
- 证据等级：实锤（零 import/零调用统计）；未实测（images 端点行为不在可执行范围）

### kg_media_direct.dart:18-26,44-49 `images()` 对输入逗号串无上限、无形态校验，且手工把签名拼进 path 的 query 再让 Dio 追加 queryParameters
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 25 条（资源上限）、第 28 条（签名形态实测）
- 依据：`hash.split(',')`/`albumId.split(',')`/`albumAudioId.split(',')`（18-20）无长度上限，逐个构造 `data` List（21-27），`count` 默认 5 但无上限校验；签名 `KgSignature.android(params, lite: lite)`（43）在 `params` 的 Map/List 值上先 `jsonEncode` 再拼（与 `KgClient.request` 的签名逻辑一致），但随后把 `q` 用 `Uri(queryParameters: q).query` 拼进 `path`（47），并 `clearDefaultParams:true, notSignature:true` 调 `request()`——`KgClient.request` 会再把 `allParams` 作为 `queryParameters` 追加到已含 `?` 的 URL 上（形成双重 query 拼装）。该形态没有任何实测注释或探针记录，注释只写「该接口签名拼在 query 末尾，参数不做默认注入」。
- 影响：该扩展虽当前零消费，一旦被调用，签名参数与 Dio 追加的 query 可能重复/被覆盖，服务端返回 20006 或直接拒绝，用户看到封面/视频详情空白；超长输入还会构造巨大 URL。
- 证据等级：静态推演（零消费为实锤；双重 query 后果为推演、未实测）

### kg_media_direct.dart:69-72 「与 kapi /video/detail 一致」未标注第 33 条口径，TLS 结论无样本
- 级别：P3
- 违反：QUALITY_STANDARD 第 28/29 条、第 33 条、第 31 条
- 依据：`videoDetail` 注释写「实测 200 status=1，data 数组与 kapi /video/detail 一致」，以 kapi 包装结果作对照且未标注需原生复核；同一 TLS/证书结论在 kg_endpoints_home.dart:173-175 与 kg_endpoints_media.dart:124-127 各有一份文字拷贝，均无 probe 记录或三态留样。
- 影响：无当前用户可见后果（死代码）；重复且不可追溯的「实测」注释会误导后续把它当依据。
- 证据等级：未实测（标注缺失实锤）

**本文件复核通过项（候选）**：`videoDetail` 明确 `clearDefaultParams:true` 且 `clienttime` 用秒级（第 15 条）；对三标签域名 TLS 限制写出「为什么保持 gateway + x-router」，属第 27 条说明义务的正向例（但与 home 版重复）。

### 13) `lib/core/direct/kg_play_api.dart`（495 行，完整读取）

**特别核对项：requestWithVerify 的 20028 重试与写端点契约**：本文件是 `requestWithVerify` 仅有的两个调用方（40 行 `songUrl` GET /v5/url、72 行 `privilege` POST /v2/get_res_privilege/lite），均为读语义；`KgClient` 的「写操作禁止使用本方法」注释（kg_client.dart:341-343）在本文件未被违反。但 `privilege` 是 POST 且带 `data` body，重试会把同一权益查询原样重发——对读端点无重复提交风险，只是多一次请求；`KgClient._needsVerify` 实际按「任意失败 + ssa-code」而非「20028」触发（见 kg_client 段），本文件两处调用都会在 20006 等签名错误时额外打一次 verifyservice 并重发。契约声明与实际触发条件不一致的问题记在 kg_client.dart，本文件不重复计数。

### kg_play_api.dart:40-56,72-94 两个调用点未检查 `KgResponse.status`/业务失败即解析，风控或网络异常被伪装成「成功但无数据」
- 级别：P1
- 违反：QUALITY_STANDARD 第 8/9 条（异常契约、失败可观测）、第 16 条（失败与确实为空语义分离）
- 依据：`songUrl` 拿到 `res` 后直接 `return PlayUrlResult.fromResponse(res);`（56），`PlayUrlResult.fromResponse` 对 `url/backupUrl` 缺失、`bitRate` 非数值、`hash_offset` 非 Map 一律静默给空/0（328-380）；`privilege` 拿 `final data = res.body['data']; final list = data is List ? data : const [];`（81-82），随后 `list.whereType<Map>()`（89）生成条目，`data` 非 List 时返回空 `List<PrivilegeItem>`。两个方法都不看 `res.status`（KgClient 的 DioException 会返回 502）、不看 `res.errorCode`、不抛 ApiException、不记日志，也不经过 `_wrap`→`evaluateResponse` 单点判定（kg_direct_api_client.dart:80）。
- 影响：网络超时/DioException、20028 风控、业务 `status=0` 时，播放侧拿到 `hasUrl=false`、`errorCode` 可能非 0 的空结果，权益侧拿到空权益列表；上层无法区分「无网络」「需要验证码」「该歌曲确实无此音质」，用户看到播放失败或音质档位错误/灰掉，且无日志可定位。这与 `KgDirectApiClient` 走 `_wrap` 的失败形态完全不同（第 8 条跨路径不一致）。
- 证据等级：静态推演（代码事实实锤；上层表现未实测）

### kg_play_api.dart:113-115 `viperQualities` 常量零消费；320 行 `clipDurationMs` getter 零消费
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：`static const List<String> viperQualities`（113）注释写「VIP 态 /v5/url 实测真实返回 URL」，但全仓 `KgSharedParams.viperQualities` 零出现，`viper_tape/viper_clear/viper_atmos` 另在 `upstreamQualities`（120-123）与 `defaultQualities`（127）里各列一遍；`int get clipDurationMs`（320）全仓仅本文件声明 1 处，零调用。`magicQualities` 有 162 行消费（正向）。
- 影响：无用户可见后果；「实测」结论挂在无人使用的常量上，VIP 音质 wire 名在两处列表里重复维护。
- 证据等级：实锤

### kg_play_api.dart:49-53,111,118-123,133-137,145-149,300-305,342 「实测」结论无三态留样，F4-01 依据指向禁止读取的历史报告
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条、第 31 条
- 依据：`songUrl`（49-53）写「实测（curl 直打 trackercdn⋯）无 signature 返回 20006」，但把依据指向 `docs/batch4_fix_1_network.md「F4-01 实测驳回」`（本任务禁止读 `docs/batch*` 历史报告），仓库内无可追溯的 curl 记录；`upstreamQualities`（118-123）写「实测（curl gateway/v2/get_res_privilege/lite）只有整表下发才会返回⋯」、`qualityLevels`（133-137）写「实测 relate_goods：128→level2⋯」、`PlayUrlResult` 的 `hash_offset` 结构（300-305、342）写「实测 /v5/url（IsFreePart=1）返回 {clip_hash,...}」、`viperQualities`（111）写「VIP 态实测真实返回 URL」——均无匿名/普通/VIP 三态回包留样与样本路径；`docs/api_verified.md` 只有匿名态「privilege/lite ✅ st=1 relate_goods 7 项」「song/url ✅ st=1」摘要。
- 影响：无直接用户可见后果，但涉及「上游返回什么」的结论不可追溯；上游改 `relate_goods` 形态或 `hash_offset` 单位时，解析静默得空/0（本文件多处 `?? 0`），用户看到音质档位错乱、试听片段时长错误，且无日志。
- 证据等级：未实测（留样缺失实锤；结论真伪不在可执行范围）

### kg_play_api.dart:9,92-97 文件头声称「kg_direct_api_client.dart 里的同名实现复用 KgSharedParams」，实际主类已改为委托 `_epMedia`，注释滞后
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）
- 依据：文件头（9-11）与 `KgSharedParams` 类注释（92-93）均写「`kg_direct_api_client.dart` 与 KgPlayApi 共用」「kg_direct_api_client.dart 里的同名实现复用它」；实际 `kg_direct_api_client.dart:579-583` 的 `_songUrl`/`_privilege` 只是 `=> _epMedia.songUrl(q)` / `_epMedia.privilege(q)`，真正复用 `KgSharedParams` 的是 `kg_endpoints_media.dart:71-100`（有 `show KgSharedParams` import）。主类不再有「同名实现」。
- 影响：无用户可见后果；维护者按注释去主类找参数构造会找不到，误以为存在第三份拷贝。
- 证据等级：实锤

### kg_play_api.dart:197-200,245-257 外部 `hash`/`qualities` 参数无条目数上限与白名单校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条、第 25 条
- 依据：`KgSharedParams.privilege` 对 `hashes` 逐项 `trim().toLowerCase()` 后只过滤空串/'null'（197-200），未校验 hash 长度/字符集/条目数上限；`parseQualities(dynamic raw)`（245-257）对 List 元素一律 `'$e'` 字符串化、对字符串按逗号拆分，同样无上限与白名单；`songUrl` 的 `quality` 只做 `magic_` 前缀补齐（162-164），任意字符串原样作为 `/v5/url` 的 `quality` 下发。`qualities` 参数传入 `KgPlayApi.privilege` 后还决定 `wanted` 输出档位数量（85-86）。
- 影响：异常超长列表会构造巨大权益请求体（超时/风控），非法 quality 会让服务端返回业务错误；本层无日志，用户看到音质信息加载失败或档位异常。
- 证据等级：静态推演（无校验实锤；上游反应未实测）

**本文件复核通过项（候选）**：`/v5/url` 与 `/v2/get_res_privilege/lite` 的参数构造确实只在 `KgSharedParams` 一处（第 5 条单一来源）；`parseQualities` 对空串/'null' 做语义过滤；`PlayUrlResult.fromResponse` 对 `url`/`bitRate`/`hash_offset` 用 `is List`/`is Map`/`int.tryParse` 分支而非裸强转（第 13 条部分到位）；`PrivilegeItem.fromJson` 的 `_pickRelate` 在缺档时返回空表并标记 `exists=false`，不借用别档（第 16 条正向例）；`isPreview` 用 `endMs-startMs` 区间判定并注释历史陷阱（第 31 条正向例）。

### 14) `lib/core/direct/kg_providers.dart`（109 行，完整读取）

### kg_providers.dart:27-35 `loadSync` 对持久化设备 JSON 的解析失败完全空捕获，并立刻覆盖旧记录
- 级别：P1
- 违反：QUALITY_STANDARD 第 6/9 条（禁止吞异常、失败可观测）、第 13/14 条、第 5 条
- 依据：`loadSync(Box<String> box)` 读 `box.get(_key)`，若非 null 则 `try { return KgDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>); } catch (_) {}`（30-33）——`jsonDecode` 的形态用 `as Map<String,dynamic>` 裸强转、失败空捕获无日志；随后 34-35 行 `KgDevice.generate()` 生成全新 guid/mid/dev/mac 并 `box.put(_key, jsonEncode(device.toJson()))` 直接覆盖损坏的旧记录。旧 dfid 也随之丢失（新设备 `dfid=''`），且用户/线上都不知道曾发生数据重建。
- 影响：Hive 设备记录损坏或版本迁移时，用户冷启动后设备身份（guid/mid/dfid）全部更换，服务端按新设备风控 → 触发人机验证、播放降权/试听、已登录账号的设备绑定失效；旧设备数据被静默覆盖，无法追溯。
- 证据等级：静态推演（覆盖与空捕获实锤；风控后果为推演，依据 kg_providers.dart:89-92 的注释）

### kg_providers.dart:56-73,87-98 dfid 三写链路里 Hive/SecureStorage 的写入失败被静默吞或只 debugPrint，返回值无人检查
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 6/9 条、第 20 条（异步副作用生命周期）
- 依据：`saveDfidSync`（56-73）在 `box==null` 时 `return false`（59）、`catch (_) { return false; }`（70-71），无日志；调用方 `kgClientProvider` 的 `onDfidRegistered`（87-98）第一行 `KgDeviceStore.saveDfidSync(dfid);` **忽略 bool 返回值**，随后 `SecureStorage.instance.saveDfid(dfid).catchError((e) { debugPrint(...) })` 是 fire-and-forget（注释 95 行自认），release 下 debugPrint 不落盘。`KgClient._persistDfid`（kg_client.dart:472-480）又对回调整体 `catch(_){}`。另 `lib/features/player/data/player_repository.dart:96-108` 的 ensureDfid 三写也有 `catch(_) { debugPrint(...) }`。即内存 `device.dfid` 已更新，但 Hive（自称「唯一权威源」）与 SecureStorage 任一写入失败都无可见反馈、无重试、无一致性校验。
- 影响：落盘失败后 `restoreSession` 会用 SecureStorage 旧 dfid 反向覆盖内存新值（这正是 89-92 注释描述的历史故障），用户冷启动后设备标识来回跳变，触发风控验证/播放降权/试听；线上无日志可定位是哪一写失败。
- 证据等级：静态推演（忽略返回值/空捕获实锤；跳变后果依据本文件注释与推演）

### kg_providers.dart:40-42,46-53 `saveSync`/`save`/`openBox` 三个入口零消费，且 `openBox` 的异常空捕获
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条、第 6 条
- 依据：全仓统计 `KgDeviceStore.saveSync` / `KgDeviceStore.save(` / `KgDeviceStore.openBox` 均 0 次调用（`openBox` 仅在 58 行被 `saveDfidSync` 内部调用，作为公开 API 无外部消费）；`openBox`（48-53）用 `try { if (Hive.isBoxOpen(boxName)) ... } catch (_) {}` 空捕获返回 null，调用方只得到 `false`。文件头（16-18）还写「提供同步的 loadSync / saveSync」，但 saveSync 无人使用。
- 影响：无直接用户可见后果；死代码与「设备 box 未打开」故障不可观测（saveDfidSync 直接返回 false，上层忽略）。
- 证据等级：实锤

### kg_providers.dart:78-81 `kgDeviceProvider` 兜底 `KgDevice.generate()` 静默生成不持久化设备，与「首次启动生成并固定」的类注释冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 5 条
- 依据：类注释（13-14）写「首次启动生成并固定，避免每次请求被判定为新设备」；`kgDeviceProvider` 在未被 main() override 时 `return KgDevice.generate()`（80），注释自认「内存临时设备，不持久化」。一旦启动编排漏了 override（属 B4 范围，未在本批核对），每次 Provider 重建都会产生新 guid/mid 且不落盘，与「固定」语义相反，且没有任何日志/断言提示 override 缺失。
- 影响：启动编排异常时用户每次进入 App 都被判新设备，反复触发风控验证/播放降权，且没有可检索日志说明是 override 缺失。
- 证据等级：静态推演（兜底行为实锤；override 是否遗漏未实测，不在 B2 范围）

**本文件复核通过项（候选）**：`KgDeviceStore` 把 Hive box 名与 key 收敛为常量（第 2 条）；`saveDfidSync` 先读回已有 JSON 再只改 `dfid` 字段、不覆盖其它设备字段（第 5 条局部正向例）；`onDfidRegistered` 的 89-92 行注释明确写出「SecureStorage 旧值反向覆盖 Hive 新值」的历史陷阱与为什么必须同步（第 31 条正向例）。

---

## 特别核对项汇总（用户点名）

| 核对项 | 结论 |
|---|---|
| `requestWithVerify` 20028 重试对写端点的契约声明与实际调用方 | 声明见 kg_client.dart:339-343（「命中 20028」「写操作禁止」），实现 `_needsVerify` 按「任意失败+ssa-code」触发；调用方仅 kg_play_api.dart:40（GET /v5/url）与 :72（POST 权益查询），无写端点。声明触发条件与实现不符（P2，记 kg_client.dart）；写禁用无代码强制、全仓未消费（P2，记 kg_client.dart）；两调用方不检查失败即解析（P1，记 kg_play_api.dart）。 |
| `-404` 未移植路径的 DioException 包装 | kg_direct_api_client.dart:289-300（get）/362-372（post）均 `throw _asDioException('/$n', ApiException(-404,...))`，与 `_directOrFallback` 失败路径形态一致，**包装到位**；但文件头仍写「回退 kapi」、kapi 回退分支恒不可达（P2/P3 已记）。 |
| `ensureDfid` 的 Completer 并发收敛与重试上限 | 位于 B5 范围 player_repository.dart:60-117；本视角只读核对：`_registeringFuture = completer.future` 收敛到单一事务（到位），但 `finally` 只 `completer.complete()`（无 completeError）、`_registerRetries >= 3` 检查位于 finally 后置 false 后不可达的窄分支。仅作事实记录，未计入本报告问题总数。 |
| `KgConfig` lite 常量是否零消费 | `liteAppid/liteClientver/androidSaltLite/signKeySaltLite/_publicKeyPemLite` 在 8 个文件按 `lite ? ... : ...` 读取，但 `KgClient.lite` 全仓唯一写入是声明 `bool lite = false`，生产代码零 `= true`。整条 lite 通道恒 false、分支不可达（P2，记 kg_crypto.dart）；`KgConfig` 本身非零消费。 |
| `kg_crypto` 命名与实现一致性 | `aesEncryptHex` 输出 Base64、返回 `AesResult.key` 实为 6 位 seed、iv 派生与 REVIEW_SPEC 的 `md5(key)[:16]` 不一致（P1，记 kg_crypto.dart）；`KgSignature.register` 注释写 unused 但 kg_client.dart:253 分支可达（P3）；「逐行移植」对照表与 web/android 复杂值处理差异未说明（P2）。 |

