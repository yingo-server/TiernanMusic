# 第 5 批·审查①：直连层全量复核（v3.0 终审 A 视角）

- 基线：commit `bc4a521`（tag v3.0.0）
- 依据：`docs/QUALITY_STANDARD.md`（32 条）、`docs/REVIEW_SPEC.md`、`docs/api_verified.md`
- 方式：逐文件完整 file_read；未编译、未跑测试、未安装依赖、未修改代码

---

## 1. lib/core/direct/kg_direct_api_client.dart（666 行，已完整阅读）

### kg_direct_api_client.dart:214-249 `fallbackToKapi const false` 后 kapi 闭包与回退分支全为死代码
- 级别：P3
- 事实：`static const bool fallbackToKapi = false;`。`get`/`post` 每个 case 仍构造 `final kapi = () => super.get(path, query: query);` 并作为实参传入；`_directOrFallback` 内 `if (write || !fallbackToKapi || ...) throw ...` 恒真，`try { return await kapi(); }`（两处）永不可达；`_directOrFallback` 的 `kapi` 形参永不被调用。
- 违反：QUALITY_STANDARD 第 32 条（不可达分支/死代码零容忍）；第 31 条（注释仍称「先直连，失败则回退 kapi」与实现相反）
- 后果：读者按注释以为 kapi 仍是有效兜底，排障时去查 kapi 侧日志/网络，方向错误；每处 case 无谓分配闭包。

### kg_direct_api_client.dart:283-302 / 373-381 未移植路径抛 `ApiException` 而非 `DioException`，异常契约与主路径不一致
- 级别：P1
- 事实：`get`/`post` 落到 switch 末尾时 `throw ApiException(-404, '接口 /$n 尚未移植…')`；而同文件 `_directOrFallback` 对一切失败统一 `throw _asDioException(label, e)`，注释明确写「上层（AuthRepository/verification_guard）只捕获 DioException 并从 .error 取 ApiException。直连若裸抛会被上层泛 catch 吞掉」。
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一稳定，回退路径与主路径形态一致）；第 9 条（失败必须可观测）
- 后果：凡调用未移植路径（如 `/user/playlist` 之外的新接口、`/search/complex` 等），Repository 的 `on DioException` 捕不到，走到泛 catch 后被当作未知错误吞掉或显示通用「网络错误」，`-404` 语义（功能未移植）永远无法呈现给用户，也无法进入 lastErrors 诊断列表。

### kg_direct_api_client.dart:104-107 `err_code` 统一提前校验会误杀「err_code 存在但为成功码」的裸 Map 响应（需按端点核实）
- 级别：P2
- 事实：`final errCode = body['err_code']; if (errCode != null && codeOf(errCode) != 0) throw ApiException(...)`。该判定先于 status 判定、先于 `_hasData` 警告码放行逻辑。
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径必须逐端点实测，不可一律）；第 16 条（「失败」与「确实为空」语义混同）
- 后果：任何在成功响应里携带非 0 `err_code` 的端点（酷狗 mcomment 系列在同一响应中既给 `err_code` 又给有效 `list`）会被整包判失败并丢弃已返回的数据，用户看到空评论列表而非内容。api_verified.md 只记录了 comment/count 的裸 Map 形态，未记录成功响应中 err_code 的取值集合 → 属未实测即下结论。

### kg_direct_api_client.dart:145-173 空响应体判定位置过晚，`status == 0` 且 `error_code == 0` 的空包仍以 code 0 抛错
- 级别：P3
- 事实：`if (status == 0 || status == 2 || errorCode != 0) throw ApiException(errorCode, msgOf(), ...)` 位于 `if (body.isEmpty)` 之前；当 `body == {'status': 0}` 时抛出的 ApiException.errorCode 为 0、message 取自不存在的字段，回落为「请求失败」。
- 违反：QUALITY_STANDARD 第 31 条（注释与实现顺序不一致：PLY-11 声称空包单独判定，实际被前一支抢先）
- 后果：诊断页只能看到 code 0 +「请求失败」，无法区分「风控空包」与「业务拒绝」，线上排障信息丢失（非用户可见，故 P3）。

### kg_direct_api_client.dart:466-489 `_videoDetail` 绕过端点组、直接内联在客户端类里（R1 拆分遗漏）
- 级别：P3
- 事实：其余端点均 `=> _epXxx.yyy(q)` 委托到 `kg_endpoints_*.dart`，唯 `_videoDetail` 保留完整请求构造（60 余行）在本类内；且 `kg_endpoints_media.dart` 中有同域 `videoUrl`，`video/detail` 无对应端点类。
- 违反：QUALITY_STANDARD 第 1 条（单一职责：本类应只做路由/委托）；第 30 条（文件内两种组织方式并存，命名与结构不符）
- 后果：维护者按「端点实现在 kg_endpoints_*」的约定去改 video/detail 会改错文件，改动丢失或重复实现（P3，仅维护成本）。

### kg_direct_api_client.dart:32-42 `setCredentials` 与 `clearCredentials` 不对称：dfid 只写不清
- 级别：P2
- 事实：`setCredentials` 中 `if (dfid != null && dfid.isNotEmpty) kg.dfid = dfid;`；`clearCredentials` 仅重置 `kg.token / kg.userid / kg.t1`，未处理 `kg.dfid`（也无 `kg.auth` 的清理，而 `setCredentials` 形参含 `auth`）。
- 违反：QUALITY_STANDARD 第 20 条（生命周期双向对称）；第 5 条（同一事实多份存储、仅一处更新）
- 后果：切换账号/退出登录后旧账号 dfid 残留并继续参与 `uuid=md5(dfid+mid)` 计算与签名，直连请求携带上一账号设备标识；酷狗侧风控按 dfid 归并，可能把新账号与旧账号关联或直接触发风控拒绝，表现为登录后部分接口 20010/空包。
- 补充：dfid 属设备级标识，保留本身合理，但代码与注释均未声明「dfid 故意不随账号清理」，属隐式约定。

### kg_direct_api_client.dart:669-681 `_qrPngBase64` / `_maskMobile` / `_qrSrcappid` / `_commentCodeOf` / `_afterLogin` 为委托层残留
- 级别：P3
- 事实：`_qrPngBase64`、`_maskMobile`、`_qrSrcappid`、`_commentCodeOf`、`_afterLogin` 在本文件中均无调用点（`get/post` 的 switch 全部直接委托 `_epAuth` / `_epComment`），端点组类各自持有实现。
- 违反：QUALITY_STANDARD 第 32 条（未使用方法/字段/常量零容忍）
- 后果：`_afterLogin` 与 `_epAuth` 内同名逻辑并存，若两者行为已分叉，后来者改错一处即造成「登录成功但 token 不落盘」类故障；提升误改概率。

### kg_direct_api_client.dart:10-23 导入疑似冗余（`dart:convert`、`qr_flutter`）
- 级别：P3
- 事实：本文件正文未见 `json`/`base64` 使用，`QrPainter` 等 QR 绘制类型已随 `_epAuth.qrPngBase64` 迁出；`package:qr_flutter/qr_flutter.dart` 仅由注释/委托间接相关。
- 违反：QUALITY_STANDARD 第 32 条（未使用导入）
- 后果：拖慢冷启动编译、误导依赖方向（核心网络层看起来依赖 UI 二维码库）。注：以 `dart analyze` 的 unused_import 为准，本项待确认。

### kg_direct_api_client.dart:189-190 `_directOrFallback` 的 `write` 语义在 fallbackToKapi=false 下已无区分度
- 级别：P3
- 事实：`if (write || !fallbackToKapi || e.needsVerification || e.errorCode == 20034)` —— `!fallbackToKapi` 恒真，`write` 与两个特判条件均为冗余；但 7 处 `write: true` 调用点仍保留。
- 违反：QUALITY_STANDARD 第 32 条（冗余条件）；第 22 条（并发/防重前提失去显式表达）
- 后果：读者误以为「写操作防重」仍由该参数保障，实际上防重完全依赖「永不回退」这一偶然属性；一旦将来恢复 kapi 回退，写操作会因 `write` 逻辑仍在而侥幸正确，但非写操作的重复提交风险无人评估。

---

## 2. lib/core/direct/kg_client.dart（542 行，已完整阅读）

### kg_client.dart:166-171 / 176-186 `KgClient.dfid` 只写不读：登录 dfid 永远进不了签名与请求头
- 级别：P2
- 事实：`String dfid = '';`（注释称「登录态 dfid（与 token/userid 同步…直连层签名取 kg.device.dfid，登录刷新后需保持一致）」）。全类所有签名/头构造均取 `device.dfid`：`request()` 的 `defaultParams['dfid']`、`reqHeaders['dfid']`、`submitFingerprintVerification` 的 `dfid: device.dfid.isEmpty ? '0' : device.dfid`、`_registerDeviceOnce` 的 `params['dfid']`。类内无任何 `dfid`（非 device）的读点。而 `KgDirectApiClient.setCredentials` 写入的正是 `kg.dfid`。
- 违反：QUALITY_STANDARD 第 5 条（同一事实两处存储、只在一处被修改，另一处权威不生效）；第 32 条（无人读取的状态）；第 31 条（注释与实际取值来源相反）
- 后果：`setCredentials(dfid: …)` 是空操作，`kg.dfid` 永远不会出现在请求里。目前设备 dfid 由 `device.dfid` 提供、功能可用，因此无直接故障；但「PLY-12 登录 dfid 同步」这一修复实际未生效，若某天账号体系要求「登录 dfid ≠ 设备 dfid」（酷狗登录响应确实可能刷新 dfid），评论/云歌单等风控敏感接口会开始返回 20010，而代码与注释都声称已同步，排障方向被彻底带偏。

### kg_client.dart:268-312 `requestWithVerify` 内重试会重放**同一请求**，对写操作等同重复提交（当前无写路径调用，属潜在风险）
- 级别：P2
- 事实：`request()` 发出 → 命中 `_needsVerify` → `submitFingerprintVerification` → 再次 `request(...)` 原样重发。方法本身不区分读写，签名 `Future<KgResponse> requestWithVerify(path, {… int retries = 1})` 无 `write` 保护。当前调用点只有 `KgPlayApi.songUrl` / `KgPlayApi.privilege`（均为读）。
- 违反：QUALITY_STANDARD 第 21 条（写操作必须具备防重机制——此处无任何机制，契约也未声明「不得用于写」）；第 3 条（契约缺「幂等」声明）
- 后果：目前无用户可见后果；一旦有写端点改用该方法（最可能是有验证要求的评论/收藏），首次请求在服务端已成功但响应带 ssa-code 时会被原样重发 → 重复评论、歌单两条同名。`_directOrFallback` 的「写不回退」防重**覆盖不到**这一层（重试发生在 `KgClient` 内部，对外仍是一次调用）。

### kg_client.dart:213-226 DI 回流：core 层 import features 层实现
- 级别：P2
- 事实：`import '../../features/auth/data/edt_generator.dart';`，用于 `submitFingerprintVerification` 里的 `EdtGenerator.generate(...)`。
- 违反：QUALITY_STANDARD 第 4 条（分层单向依赖，core 不得依赖业务模块）；REVIEW_SPEC 第五节（`core/` 禁止 import `features/**`）
- 后果：直连层无法脱离 auth 业务单独测试/复用；`features/auth` 改名或重构会直接编译失败于 core 层（架构级回流）。

### kg_client.dart:398-408 `_persistDfid` 空捕获且无日志
- 级别：P3
- 事实：`try { onDfidRegistered?.call(dfid); } catch (_) { /* 持久化失败不影响本次请求 */ }` —— 无日志、无返回值、无降级标记。
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常：至少记录日志或返回明确语义）；第 9 条（失败不可观测）
- 后果：dfid 落盘失败后每次冷启动都重新注册设备，用户表现为「偶尔又要重新登录/频繁风控」，日志里查不到任何线索。

### kg_client.dart:196-206 网络异常被折叠为 `status: 502` 假响应，丢失异常类型
- 级别：P2
- 事实：`} on DioException catch (e) { return KgResponse(status: 502, body: {'status': 0, 'error': '${e.message}'}); }`，不保留 `e.type`（超时/DNS/证书），也不设 rawBytes。
- 违反：QUALITY_STANDARD 第 6 条（异常应转译为有语义的领域异常，而非压缩成字符串）；第 15 条（错误分类信息丢失）
- 后果：`_wrap` 只能抛出 `ApiException(0, '连接超时')` 之类文本；「无网络」「DNS 失败」「TLS 失败」在诊断页与用户提示里不可区分，离线场景被显示为通用请求失败。

### kg_client.dart:52-56 / 62-66 `isOk` 与 `businessErrorCode` 疑似无调用点
- 级别：P3
- 事实：`bool get isOk => this.status == 200 && (body['status'] == 1 || body['status'] == 200);`、`int get businessErrorCode`。成功判定已统一由 `KgDirectApiClient._wrap` 实现（后者连 status==200 都单独分支），两套口径并存。
- 违反：QUALITY_STANDARD 第 32 条（未使用成员）；第 5 条（成功判定两个权威，且 `isOk` 不含 `err_code` 校验、与 `_wrap` 不一致）
- 后果：若将来有人改用 `isOk`，mcomment 的 `status=1 + err_code=60102` 会被判成功，评论失败被当成成功展示。

### kg_client.dart:145-158 默认参数 `uuid` 恒为 `'-'`，与 `dfid` 语义绑定缺失（注释与实现范围不符）
- 级别：P3
- 事实：`'uuid': '-'` 有 5 行注释说明「Node 版虽注入 uuid=guid…维持既往实测结论」，但 `_videoDetail` 内又自行计算 `uuid: KgCrypto.md5('$dfid${kg.device.mid}')`，`_registerPayload` 里 `uuid: device.guid` —— 同一请求族存在三种 uuid 取值。
- 违反：QUALITY_STANDARD 第 2 条（魔法值与隐式约定应集中）；第 31 条（三处取值无统一说明）
- 后果：新增端点时无法判断该用哪种 uuid，选错即静默失败（酷狗对 uuid 不一致主要回 20010/空包），排查成本高。

### kg_client.dart:84-92 `calculateMid` 逐位 BigInt 累加，且不校验 `guid` 长度
- 级别：P3
- 事实：`for (var i = 0; i < digest.length; i++) { … base.pow(digest.length - 1 - i) … }`；`KgDevice.fromJson` 用 `'${j['guid'] ?? ''}'` 兜底，guid 为空串时 `KgCrypto.md5('')` 仍能算出固定 mid。
- 违反：QUALITY_STANDARD 第 14 条（边界数据未校验）
- 后果：Hive 中 guid 损坏/缺失时全设备共用同一个空串派生的 mid，服务端把多台设备视为同一设备，风控命中率上升且表现为随机失败。非崩溃，故 P3。

---

## 3. lib/core/direct/kg_crypto.dart（402 行，已完整阅读）

复核结论：三种盐（android `OIlwieks28dk2k092lksi2UIkp` / web `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt` / register `1014`）、`paramsKey = md5(appid+salt+clientver+data)`、`keyOf = md5(hash+salt+appid+mid+userid)` 均与 REVIEW_SPEC 第二节一致；`playlistAesEncrypt` 的 key=`md5(seed)[:16]`、iv=`md5(seed)[16:32]`、base64 输出一致；RSA-PKCS1 与裸 RSA 分离正确；`clienttime` 由调用方传秒级（本文件不涉及）。以下为遗留问题。

### kg_crypto.dart:212-243 `aesEncryptHex` 名称与实现相反（输出 base64 而非 hex），且与同文件 `aesEncryptCbcHex` 仅一字之差
- 级别：P3
- 事实：`static AesResult aesEncryptHex(String data, {String? key, String? iv})` 结尾 `return AesResult(str: base64.encode(out), key: seed ?? '');`；文档亦写「AES-128-CBC + PKCS7，输出 Base64（对应 playlistAesEncrypt）」。同文件另有 `aesEncryptCbcHex`（真 hex、AES-256、key 为 32 位 hex 串）。
- 违反：QUALITY_STANDARD 第 30 条（名称必须表达意图，名称与行为不符是最高频误导来源）
- 后果：两个函数名仅差一个 `Cbc`，一个 hex 一个 base64、密钥长度也不同；新增歌单/MV 写接口时极易选错 → 服务端解密失败，表现为收藏/删歌恒失败且无明确错误码。

### kg_crypto.dart:90-95 `register` 签名注释称「currently unused」，实际在 `KgClient.request` 的 `encryptType` 分支中可达
- 级别：P3
- 事实：注释「currently unused：注册实际走 [android]（含 body）…保留时勿在新代码中误用为注册路径」；而 `kg_client.dart:229-233` 有 `'register' => KgSignature.register(allParams)` 分支，任何调用方传 `encryptType: 'register'` 即会走该盐值。
- 违反：QUALITY_STANDARD 第 31 条（注释与代码不符）；第 32 条（保留不可用实现）
- 后果：注释制造「此路径不存在」的错觉；若未来按 `encryptType` 字面语义误用 register 签名打 `/risk/v3/r_register_dev`，注册恒失败（该接口实测要求 android 签名且包含 body），表现为「设备注册一直拿不到 dfid → 直连大面积风控失败」。

### kg_crypto.dart:391-399 `randomString` 取整方式使字符表首字符概率≈0
- 级别：P3
- 事实：`final idx = ((chars.length - 1) * _rand.nextDouble()).ceil(); sb.write(chars[idx.clamp(0, chars.length - 1)]);` —— `nextDouble()` 取值 [0,1)，乘 35 后取 ceil，结果落在 0..35，但 `0` 仅在 `nextDouble()==0` 时出现（概率 2⁻⁵³），`chars[0]='1'` 实际不可用；`ceil` 还使各字符概率不均（中间字符被两次区间覆盖）。
- 违反：QUALITY_STANDARD 第 17 条（数值分布需精确可控）；第 31 条（注释「randomString：字符表…」未说明偏差）
- 后果：seed/临时 key 熵下降且分布可被预测，弱化了「随机 seed 防重放」的初衷；dfid 注册的 imei/临时 key 也取自该函数，长期运行可能提高风控命中率（P3，无直接崩溃）。

### kg_crypto.dart:330-333 `aesDecryptCbcHex` 遇到奇数长度/非法 hex 时静默丢弃末位或抛 `FormatException`
- 级别：P3
- 事实：`for (var i = 0; i + 1 < data.length; i += 2) { cipherBytes.add(int.parse(...)); }` —— 奇数长度末位被丢弃；`int.parse` 对非 hex 字符抛 FormatException（未被本函数捕获）。
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界未校验）
- 后果：上游返回畸形密文时，前者静默产出错误明文（`_afterLogin` 里 `dec is Map` 判空后不合并 token，表现为登录成功但未登录）；后者向上冒泡成未包装异常。二者都难定位。

### kg_crypto.dart:145-149 / 205-207 每次 RSA 都要重新 base64 解码 + ASN.1 解析公钥
- 级别：P3
- 事实：`_rsaPublicKey(lite)` 内 `base64.decode(...)`、`ASN1Parser(...).nextObject()`，被 `rsaEncryptPkcs1` 与 `rsaEncryptRawHex` 每次调用（设备注册最多 3 次重试，登录每次一次）。
- 违反：QUALITY_STANDARD 第 24 条（惰性构建/按需计算：不变量应缓存）
- 后果：单次多出约 1KB 的 DER 解析，登录与注册路径的 CPU 抖动；非热路径，故 P3。

### kg_crypto.dart:107-121 `KgSignature.android` 对 Map/List 值使用 `jsonEncode`，而 `web` 使用 `'$v'`（Dart toString）
- 级别：P3
- 事实：android：`v is Map || v is List ? jsonEncode(v) : v`；web：`.map((k) => '$k=${params[k]}')`，Map 值会渲染成 `{a: b}`（无引号、无花括号 JSON 形态）。
- 违反：QUALITY_STANDARD 第 2 条（同一语义两种隐式编码方式）；第 8 条（签名契约不稳定）
- 后果：一旦某 web 签名端点需要传 Map/List（评论写接口的 `data` 若改为嵌套结构），签名必然不匹配 → 服务端 20006/签名错误，评论发送静默失败。

---

## 4. lib/core/direct/kg_endpoints_search.dart（153 行，已完整阅读）

对照 `module/search.js`（83 行）与 `module/lyric.js`（35 行）：song/album/else 三分支的参数集合、`platform=AndroidFilter`、lite 时 `clientver=201`、`sorttype/searchsong` 归一化均一致；差异在于 song 分支改打 `complexsearch.kugou.com/v3/search/song`（Node 为 gateway `/v2/search/song` + `x-router`），代码注释与 `api_verified.md` 均有实测记录，可接受。

### kg_endpoints_search.dart:120-140 `lyric` 的 decode 分支无 else（KRC 交给 Repository 兜底，影响收窄）
- 级别：P3
- 事实：`if (fmt == 'lrc' || (ct.isNotEmpty && ct != '0')) { body['decodeContent'] = utf8.decode(base64.decode(content), allowMalformed: true); }` —— **没有 else 分支**。Node `module/lyric.js:22` 为 `… ? Buffer.from(content,'base64').toString() : decodeLyrics(content)`：`fmt=krc && contenttype==0` 时 Node 会解出明文写进 `decodeContent`。Dart 该分支不写 `decodeContent`。但 `LyricRepository._fetchLyricByFormat` 在 `decodeContent` 缺失时会对 `content` 调 `KrcDecoder.decodeDetailed`（KRC XOR+zip 已在客户端实现），故功能可自愈；`catch (_) {}` 空捕获仍存在。
- 违反：QUALITY_STANDARD 第 28 条（分支与 Node 不一致）；第 6 条（空捕获）
- 后果：`contenttype` 缺失且 `fmt=krc` 时，Node 会走 base64 分支、Dart 不写 `decodeContent`；客户端随后按 KRC 解密 `content`，若上游该次返回的是 base64 明文则解密失败 → 回落 LRC（F4-28 已兜底），用户看到的是 LRC 而非逐字 KRC 歌词（丢逐字与翻译行）。

### kg_endpoints_search.dart:19-33 song 搜索改打 `/v3`，但 `q` 里 Node 支持的 `iscorrection/privilegefilter/area_code` 直接用 `??` 透传未经类型归一
- 级别：P3
- 事实：`'iscorrection': q['iscorrection'] ?? 1, 'privilegefilter': q['privilegefilter'] ?? 0, 'area_code': q['area_code'] ?? 1` —— 若调用方从路由/深链传来字符串 `'0'`，会以字符串进入签名与 query；Node 侧 `iscorrection ?? 1` 同样不转，故与 Node 一致，但 album 分支却做了 `'${q['sorttype']}' == '1'` 归一，同文件两套风格。
- 违反：QUALITY_STANDARD 第 13 条（外部参数未统一类型）、第 30 条（同文件风格不一致）
- 后果：字符串参数进入签名串后与 Node 服务端期望的数值形态不同，酷狗对 `iscorrection="0"` 与 `0` 的响应未实测；若上游按数值处理会返回 20010，表现为搜索空白（低频，P3）。

### kg_endpoints_search.dart:84-103 `searchLyric` 使用 `clearDefaultParams + notSignature`，与 REVIEW_SPEC「`/v1/search` 必须带 signature」冲突且未在 api_verified.md 留样
- 级别：P2
- 事实：`kg.request('/search', baseUrl: 'https://lyrics.kugou.com', method: 'GET', clearDefaultParams: true, notSignature: true, params: {...})`。REVIEW_SPEC 第二节「clearDefaultParams: true 只允许用于 5 处已验证端点：`/search`（歌词）…」，代码用的是无版本 `/search`（属白名单）✓；但同文件 `lyric()` 的 `/download` 走默认签名，而 REVIEW_SPEC 明文写「`lyrics.kugou.com` `/v1/search`（**必须带 signature**）」。
- 违反：QUALITY_STANDARD 第 29 条（凡涉及上游行为的结论必须可追溯到实测记录，未实测须标注）；第 3 条（契约与规范文档不一致，未收敛）
- 后果：后续任何按 REVIEW_SPEC 行事的人会给歌词搜索补上 signature，酷狗对带签名的 `/search` 是否返回同样结果未经实测——一旦上游对签名串更敏感，歌词搜索整条链路静默失败，歌词页无候选、只能显示空。

### kg_endpoints_search.dart:41-49 / 86-96 `search` 与 `searchLyric` 无关键词空值校验
- 级别：P3
- 事实：`final keyword = '${q['keywords'] ?? q['keyword'] ?? ''}';` 后直接发请求；`searchLyric` 直接 `'keyword': '${q['keywords'] ?? ''}'`（`lyric()` 有 id/accesskey 校验，二者风格不一致）。
- 违反：QUALITY_STANDARD 第 14 条（边界数据校验）、第 3 条（同组端点契约不一致）
- 后果：空关键词搜索打到上游，返回 20010/空列表，UI 显示「无结果」而非「请输入关键词」，用户以为搜不到歌。

### kg_endpoints_search.dart:1-7 `import 'kg_direct_api_client.dart';` 未被使用，形成 core 内部循环依赖
- 级别：P3
- 事实：该文件未引用 `KgDirectApiClient` 任何符号（仅用 `KgClient`、`KgConfig`、`ApiException`），而 `kg_direct_api_client.dart` 又 import 本文件。六个 `kg_endpoints_*.dart` 均如此。
- 违反：QUALITY_STANDARD 第 32 条（未使用导入）、第 4 条（依赖应单向）
- 后果：编译期循环导入使两端无法独立演化；`dart analyze` 报 unnecessary_import 噪音掩盖真实告警。

### kg_endpoints_search.dart:105-112 `lyric` 的 id/accesskey 校验用字符串比较 `'null'`，未校验 `decode` 之外的其他外部输入
- 级别：P3
- 事实：`if (id.isEmpty || id == 'null' || accesskey.isEmpty || accesskey == 'null') throw ApiException(-1, ...)`；`fmt` 直接 `'${q['fmt'] ?? 'krc'}'` 拼进 query，未限制取值集合。
- 违反：QUALITY_STANDARD 第 14 条（边界校验不完整）
- 后果：`fmt=xxx` 会被原样发给 `/download`（Node 同样不校验），服务端返回空 content，客户端把空当「无歌词」；属边缘态，P3。

> 基线说明：复核开始时 HEAD=`bc4a521`（v3.0.0），复核期间前进到 `f6f9531`（v3.2.0+32）/ `a668bbe`。直连层 12 个文件行数与字节数在两基线间**未变化**（kg_direct_api_client 666/30616、kg_client 542/17570、kg_crypto 402/15392、search 153/6043、playlist 288/11020），故以上结论对当前工作区代码仍然成立。5e050a3 的修复集中在播放世代/音质阈值/详情捕获，属 function 批次，与直连层无交集。

---

## 5. lib/core/direct/kg_endpoints_playlist.dart（288 行，已完整阅读）

逐端点对照 `module/playlist_del.js`（52 行）、`playlist_add.js`（33）、`playlist_tracks_add.js`（42）、`playlist_tracks_del.js`（26）、`user_playlist.js`（25）、`playlist_track_all_new.js`（25）、`playlist_detail.js`（21）、`playlist_track_all.js`（20）：URL / method / x-router / `p` 大写 hex / `signParamsKey(clienttime)` / `scene='false;null'` / `total_ver=979` / `extend_fields` 均一致；P0-4（RSA 改 PKCS1）、P0-5（resource 对象数组）、PLY-05（补 number/size/sort/timelen/bitrate）、PLY-06（去路径前缀）、PLY-07（gid 上限 10）四处修复**复核通过**，与 Node 逐字段吻合。

### kg_endpoints_playlist.dart:62-96 `playlistAdd` 两处与 Node 分叉：`source` 硬编码、`type` 缺省时走了「新建」的 params 分支
- 级别：P2
- 事实：Dart `'source': 1,` 为常量，且 `final type = int.tryParse('${q['type'] ?? 0}') ?? 0;` 缺省即 0，于是 `params` 走 `type == 0` 分支（带 `last_time/last_area/userid/token`）。Node `playlist_add.js`：`source: params.source === 0 ? 0 : params.source || 1`、`params: params.type === 0 ? {…} : {}`（`type` 未传时 `undefined === 0` 为 false，走空 params），另外 `if (params.type === 0) dataMap['is_pri'] = params.is_pri || 0;` 会带上调用方 `is_pri`（Dart 恒为 0）。
- 违反：QUALITY_STANDARD 第 28 条（参数形态必须与实测/Node 一致）；第 2 条（可用入参被硬编码吞掉）
- 后果：调用方传 `source=0`（本地新建/导入场景）时实际按 `source=1` 提交，服务端把自建歌单当作「收藏」处理；`type` 缺省时 Dart 附带的 `last_time/last_area` 与 Node 的「空 params」是两条不同事务，新建歌单可能 20010 或建出非私密歌单；私密歌单（`is_pri=1`）永远建不出来。

### kg_endpoints_playlist.dart:62-96 `playlistAdd` 的 `list_create_userid/list_create_listid` 用 `!= null` 判空，空串会照发
- 级别：P3
- 事实：`if (q['list_create_userid'] != null) 'list_create_userid': '${q['list_create_userid']}'`；Node 用 `compact()`（过滤 `''`）。
- 违反：QUALITY_STANDARD 第 16 条（空值与缺失未分离）
- 后果：调用方从深链拿到 `list_create_gid=` 空串时，Dart 下发 `list_create_gid: ''`，服务端按「收藏指定歌单」处理却找不到目标，返回 20010，用户点收藏无反应。

### kg_endpoints_playlist.dart:151-158 / 118-123 / 128-137 `listid` 在三个写端点传字符串，而 `playlistDel` 传数字
- 级别：P3
- 事实：`playlistTracksAdd`：`'listid': '${q['listid'] ?? ''}'`；`playlistTracksDel`：`'listid': '${q['listid'] ?? ''}'`；`userPlaylistTracks`：`'listid': '${q['listid'] ?? q['id'] ?? ''}'`；而 `playlistDel`：`'listid': int.tryParse('${q['listid'] ?? 0}') ?? 0`。Node 四个模块一律透传 `params.listid`（一般为数字）。
- 违反：QUALITY_STANDARD 第 17 条（标识符形态跨层必须一致且可追溯）；第 30 条（同文件同类字段两种类型）
- 后果：云歌单接口对 `listid` 的字符串/数字宽容度未实测；若某一端点按严格类型校验，表现为「加歌成功提示但歌单里没有」或 20010，且四个端点里只有一个能复现，排查成本极高。

### kg_endpoints_playlist.dart:40-59 `playlistDel` 解密失败静默返回原始响应，写操作无法区分「已删除」与「响应不可解析」
- 级别：P2
- 事实：`try { … if (decoded.containsKey('status')) return …; } catch (_) { /* 解密失败不影响判定 */ }` 之后 `return res;` —— `res.body` 由 `KgClient.request` 在 JSON 解析失败时置为 `{'status': 0, 'error': '响应解析失败', 'raw': base64…}`，`_wrap` 据此抛 `ApiException(0, '响应解析失败')`，`write:true` 使其不再重试。
- 违反：QUALITY_STANDARD 第 6 条（空捕获无日志）、第 8 条（同一端点两种响应体形态，异常语义不稳）、第 16 条（「失败」与「结果未知」混同）
- 后果：M1（AES 解密 key 派生与实际响应不一致、或上游回了明文 JSON）时删除其实已成功，UI 却提示「删除失败」，用户重复点删除 → 第二次 404/已删除；且日志里没有任何解密失败痕迹。

### kg_endpoints_playlist.dart:158-166 `playlistTracksAdd` 空 data 会发出 `data: []`，与 Node 的空占位数组不同
- 级别：P3
- 事实：`_parseTracksResource` 首行 `if (raw.trim().isEmpty) return const [];`；Node `('' ).split(',')` 产出 `[{number:1,name:'',hash:'',…}]`。
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失语义混同）；第 28 条（与 Node 形态不一致）
- 后果：调用方漏传 data 时，Node 版会被服务端判为「无效行」返回明确错误，Dart 版发空数组，行为取决于上游对空数组的处理（可能直接 200 但什么都没加），用户看到「添加成功」而歌单未变。

### kg_endpoints_playlist.dart:246-288 `_parseTracksResource` 以逗号切分，歌名含逗号时被拆成两条歌曲
- 级别：P3
- 事实：`raw.split(',')` 后再 `split('|')`；`f0(0)` 为歌名。歌名如「Hello, World」会被切成 `Hello` 与 ` World|hash|…` 两条资源。
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界未校验/未定义转义）
- 后果：批量加歌时歌单多出错误条目（空 hash 行），用户看到歌单里出现无标题行且无法播放。注：Node 同缺陷，属移植继承，非本批回归。

### kg_endpoints_playlist.dart:216-244 `playlistDetail` 用 `baseUrl: pubsongs.kugou.com` 且不带 `x-router`，`tags` 等可选词条缺失（与 Node 等价，确认无回归）
- 级别：P3（记录项，非缺陷）
- 事实：Node `playlist_detail.js` 用 gateway + `x-router: pubsongs.kugou.com`；Dart 直连原生域名等价。`data` 数组 1..10 校验与 `ids` 过滤一致。
- 违反：—
- 后果：无用户可见后果，仅记录「已核对一致」，避免下一批重复审查。

---

## 6. lib/core/direct/kg_endpoints_comment.dart（301 行，已完整阅读）

对照 `module/_comment.js`（258 行）、`comment_music.js`、`comment_count.js`、`comment_floor.js`、`comment_playlist.js`、`comment_album.js`、`comment_music_del.js`。F4-04（`/v1/cmtlist` + x-router）、F4-05（`is_t`/`pid`/`//@` 拼接）、F4-06（del 改 GET）、F4-16（hash 真值判定）、F4-17（extdata/source/childrenname）、F4-18（cid 别名）**复核通过**，`/index.php` 三处 `clearDefaultParams + notSignature` 与规范白名单一致；`key` 算法 send=`clienttime+mid+data`、reply/del=`clienttime+mid` 与 Node 一致。

### kg_endpoints_comment.dart:109-113 发评论 body 的 `album_audio_id` 被转成字符串（**复核后撤回，非缺陷**）
- 级别：—（撤回，不计入统计）
- 事实：Dart `'album_audio_id': '${q['mixsongid']}'`。Node `_comment.js:118` 的 `firstValue(params.mixsongid, params.album_audio_id)` 取的是 **HTTP query 传入的参数**（express 下 `params` 全为字符串），`JSON.stringify` 后同样是 `"album_audio_id":"32100650"`。两侧 body 文本一致，`key` 也一致。
- 违反：—
- 后果：无。此前按「Node 保持数值」判断属误读（Node 的 `params` 来自 query 而非 JSON body）。

### kg_endpoints_comment.dart:236-247 `commentDel` 未实现 Node 的 `cid` 必填校验与 `mixsongid → special_id` 回查
- 级别：P2
- 事实：Dart 直接用 `kg.request('/index.php', … 'cid': cid 仅在非空时下发, 'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}')`。Node `comment_music_del.js`：`if (!cid) return badRequest(...)`；`if (!specialId && mixsongid) { 调 comment_music(pagesize:1) 取 list[0].special_child_id }`；`if (!specialId) return badRequest(...)`。
- 违反：QUALITY_STANDARD 第 3 条（契约未声明必填项，失败语义模糊）；第 16 条（缺参数被当作空字符串发出去，服务端报「歌曲不存在」而非「缺少评论 ID」）
- 后果：从「我的评论」或歌曲评论列表直接删除时，若调用方只带 `mixsongid + cid`（Node 支持的形态），Dart 会发出 `childrenid=` 空值，服务端返回 err_code=10002，UI 提示删除失败；用户只能去歌单/评论页手动定位后再删。

### kg_endpoints_comment.dart:276-296 `commentFloor` 的 service 端点判定只看 `resource_type`，不看显式 `code`
- 级别：P3
- 事实：Dart `final isPlaylistOrAlbum = resourceType == 'playlist' || resourceType == 'album';`。Node `comment_floor.js`：`useServiceEndpoint = resourceType==='playlist' || resourceType==='album' || code===playlistCode || code===albumCode`，且 `code` 可由调用方显式传入覆盖。
- 违反：QUALITY_STANDARD 第 28 条（分支条件与 Node 不一致）；第 3 条（契约未覆盖「显式传 code」这一输入）
- 后果：调用方按 Node 习惯只传 `code=ca53b9…`（歌单码）而不传 resource_type 时，Dart 打到 `/mcomment/v1/hot_replylist` 并附歌曲 code → 楼中楼列表为空，用户看到「暂无回复」而实际有回复。

### kg_endpoints_comment.dart:265-270 / 271 `commentFloor` 中 `childrenid`、`tid`、`mixsongid` 直接透传 null，`commentMusic` 的 `mixsongid` 同
- 级别：P3
- 事实：`'childrenid': q['special_id'], 'tid': q['tid'], if (q['mixsongid'] != null) 'mixsongid': q['mixsongid']`；`commentMusic` 的 `'mixsongid': q['mixsongid']` 无判空（Node `comment_music.js` 同样直接透传，但 Node 侧 undefined 会被 axios 丢弃）。
- 违反：QUALITY_STANDARD 第 14 条（边界参数未归一，依赖框架对 null 的隐式处理）
- 后果：依赖 Dio 对 null query 值的丢弃行为才能与 Node 等价；一旦升级 Dio 或改用手工拼 query，就会发出 `childrenid=null`，服务端报资源不存在，评论列表空白。

### kg_endpoints_comment.dart:1-6 `import 'kg_direct_api_client.dart';` 未使用（且与主类循环依赖）；`_commentCodeOf` 与主类同名静态方法重复
- 级别：P3
- 事实：本文件未引用 `KgDirectApiClient`；主类 `kg_direct_api_client.dart:415-421` 另有一份 `_commentCodeOf`，全仓无调用（本文件用的是自己的私有版本）。
- 违反：QUALITY_STANDARD 第 32 条（未使用导入 + 重复实现）；第 5 条（同一映射两个权威）
- 后果：歌单/专辑评论码修正时只改一处，另一处注释与实现脱节；下一个改动者可能改到死代码那份。

### kg_endpoints_comment.dart:178-186 `commentFloorSend` 的 `tid` 空串下发（Node 会 compact 掉）
- 级别：P3
- 事实：`'tid': '${q['tid'] ?? ''}'` 恒下发；Node 用 `compact()` 过滤 `''` 与 `undefined`。
- 违反：QUALITY_STANDARD 第 16 条（空值与缺失未分离）；第 28 条（参数集合与 Node 不一致）
- 后果：回复主楼时多发一个 `tid=`；服务端把空 tid 当作楼层标识时，回复可能被挂到楼层 0 而非主楼，表现为「回复成功但对方收不到提醒」。

---

## 7. lib/core/direct/kg_endpoints_media.dart（131 行，已完整阅读）

对照 `module/song_url.js`、`module/privilege_lite.js`、`module/kmr_audio_mv.js`：`/v5/url` 的 `page_id/pid/ppage_id/version=11430/clientver=11430/quality=magic_*`、`/v2/get_res_privilege/lite` 的 `page_id=0`/`qualities` 数组、MV 的 `data:[{album_audio_id}]` 均与 Node 一致；`videoUrl` 的 `keyOf` 与 `trackermv` 原生域一致。

### kg_endpoints_media.dart:47-62 `videoUrl` 不 lowerCase hash（**复核后撤回，非缺陷**）
- 级别：—（撤回，不计入统计）
- 事实：`'hash': hash` 与 `key: KgSignature.keyOf(hash: hash, …)` 均用原串。Node `module/video_url.js` 用 `encryptKey: true`，由 `util/request.js:134-136` 调 `signKey(params['hash'], …)`，`util/helper.js:135-139` 的 `signKey` **不对 hash 做小写归一**。Dart 与 Node 行为一致。
- 违反：—
- 后果：无。保留此条仅为记录「已核对、勿在下一批重复上报」。

### kg_endpoints_media.dart:96-131 `privilege` 前置拦截返回 502 假响应而非抛异常，与同层其他前置校验（直接 throw ApiException）不一致
- 级别：P3
- 事实：`return Future.value(const KgResponse(status: 502, body: {'status': 0, 'error_code': -1, 'error': '缺少歌曲 hash'}));`；而同文件外 `playlistDetail`/`lyric` 采用 `throw ApiException(...)`。
- 违反：QUALITY_STANDARD 第 8 条（同一层异常契约应单一）；第 3 条（契约未声明前置校验用哪种形态）
- 后果：依赖 `_wrap` 把 502 再翻译成 ApiException，链路多一跳；若将来有人直接调用 `KgEndpointMedia.privilege`（不经 `_directOrFallback`）拿到的是「HTTP 502 的成功对象」，会被当成网络错误而非参数错误。

### kg_endpoints_media.dart:24-32 `kmrAudioMv` 的 `fields` 透传空串，且 `data` 元素 `album_audio_id` 为字符串
- 级别：P3
- 事实：`'fields': q['fields'] ?? '',`、`ids.map((s) => {'album_audio_id': s})`（源自 split 的字符串）。
- 违反：QUALITY_STANDARD 第 13 条（外部标识符类型未归一）
- 后果：与 Node 的 `String(...)` 形态一致时无影响；若上游对 `album_audio_id` 做数值校验，MV 列表为空，用户看不到歌曲关联 MV（P3）。

### kg_endpoints_media.dart:75-78 / 96-99 注释仍以「回退 kapi」描述行为
- 级别：P3
- 事实：`// 直连仍可能遇 20028（与 IP/风控相关），_directOrFallback 已兜底回退 kapi。`、`// 上游回 20010 → _wrap 判失败 → 回退 kapi（同样失败），白白多打两次请求且错误文案失真。`
- 违反：QUALITY_STANDARD 第 31 条（注释与实现相反，`fallbackToKapi` 恒 false）
- 后果：误导后续维护者按「有兜底」评估影响面，实际 20028 直接抛给用户。

---

## 8. lib/core/direct/kg_play_api.dart（460 行，已完整阅读）

`KgSharedParams.songUrl` 与 `module/song_url.js` 逐字段一致（`album_id/area_code/hash 小写/ssa_flag/version=11430/page_id/quality=magic_*/album_audio_id/behavior/pid/cmd/pidversion/IsFreePart/ppage_id/cdnBackup/module/clientver/key`），F4-07/F4-08/F4-09 三项修复复核通过；`PlayUrlResult` 的 `hash_offset` 全字段读取与 `isPreview` 双条件判定合理。

### kg_play_api.dart:203-214 `privilege` 的 `album_id` 被转成数值，Node 实际下发查询串原文（字符串）
- 级别：P2
- 事实：Dart `final albumId = int.tryParse(i < albumIds.length ? albumIds[i].trim() : '') ?? 0; resource.add({'album_id': albumId})`，注释称「F4-10：album_id 缺失时下发**数值** 0（Node `|| 0`），而不是字符串 '0' —— 上游按字符串解析会返回 20010」。Node `privilege_lite.js:170`：`album_id: albumIdList[index] || 0`，即**有值时是字符串**（来自 `String(params.album_id).split(',')`），只有缺失时才落到数值 0。
- 违反：QUALITY_STANDARD 第 28 条（参数形态必须与实测一致）；第 31 条（注释对 Node 行为的描述与源码相反，且据此改了实现）
- 后果：把「字符串 → 数值」当作修复依据，等于在未实测的前提下改变了既有正确形态。若上游按字符串比较 `album_id`（Node 一直如此且工作正常），批量权益查询会整体 20010，VIP/免费档判定全失效 → 用户看到所有歌都「需要会员」。

### kg_play_api.dart:112-127 `privilege()` 对每个 hash × 每个音质展开，同一 `hash` 的 `PrivilegeItem` 复制 N 份
- 级别：P3
- 事实：`for (final e in list.whereType<Map>()) for (final q in wanted) PrivilegeItem.fromJson(..., quality: q)`；`wanted` 缺省为 `defaultQualities`（7 档）。
- 违反：QUALITY_STANDARD 第 24 条（惰性构建/按需计算）；第 25 条（未设条目上限）
- 后果：一次 100 首的批量权益查询生成 700 个对象，全部构造 `Map.from`；列表页滚动时 GC 压力上升（P3）。

### kg_play_api.dart:132-141 `upstreamQualities` 与 `defaultQualities` 两表并存且顺序不同，注释解释成本高
- 级别：P3
- 事实：`upstreamQualities = ['128','320','flac','high','viper_atmos','viper_tape','viper_clear','super','multitrack']`，`defaultQualities = ['128','320','flac','high','viper_tape','viper_clear','viper_atmos']`，注释仅说明「与上游表顺序不同：蝰蛇三档在后」。
- 违反：QUALITY_STANDARD 第 2 条（魔法值/常量集中但语义未命名）；第 31 条（未说明为何顺序重要）
- 后果：修改其中一张表（例如新增 `viper_*` 音质）时极易只改一处，导致「请求了但输出不显示」或反之，表现为某音质静默消失。

### kg_play_api.dart:436-441 `isFree` 未覆盖概念版 freeListen 分支，与 Node `obtainable` 语义不同
- 级别：P3
- 事实：`bool get isFree => exists && privilege == 0 && status != 0;`。Node：`obtainable = freeListen || (exists && !neesuvip && relateItem.status !== 0)`，其中 `freeListen = isLite && quality == '128' && neesuvip`。
- 违反：QUALITY_STANDARD 第 8 条（同一判定两套语义，回退路径与主路径不一致）；第 16 条（「可播」语义未覆盖全部登录态）
- 后果：仅概念版（`kg.lite=true`）受影响：付费歌曲的 128 档被判为不可播，UI 显示「VIP 专享」，而客户端实际可以免费听标准音质。本 App 若只发布标准版，属潜在缺陷（P3）。

### kg_play_api.dart:299-302 `hasUrl` 使用 `bestUrl!` 非空断言
- 级别：P3
- 事实：`bool get hasUrl => bestUrl != null && bestUrl!.isNotEmpty;`
- 违反：QUALITY_STANDARD 第 12 条（非空断言应避免——此处可写成 `final u = bestUrl; return u != null && u.isNotEmpty;`）
- 后果：逻辑上安全（getter 两次求值可能取到不同结果，但因 urls/backupUrls 为 final 列表，实际不会崩）；仅可读性/规范问题。

### kg_play_api.dart:24-33 `/v5/url` 使用 `requestWithVerify`（会在 20028 时重发）
- 级别：P3（记录项）
- 事实：`final res = await client.requestWithVerify('/v5/url', method: 'GET', …)`。
- 违反：QUALITY_STANDARD 第 21 条（幂等性：GET 播放地址幂等，重发安全，本项**不构成**问题）
- 后果：无；仅记录「读操作重试安全」的判定依据，避免下一批误判为重复提交。

---

## 9. lib/core/direct/kg_endpoints_artist_album.dart（166 行，已完整阅读）

对照 `module/artist_detail.js`、`artist_audios.js`、`artist_albums.js`、`album_detail.js`、`album_songs.js`、`rank_audio.js`：URL、`kg-tid`（36/220/255/369）、`area_code='all'`、`sort` 映射（audios hot→1 否则 2；albums hot→3 否则 1）、`fields` 串、`is_buy` 空串语义、`rank_id` 缺省丢键 均与 Node 一致；F4-03（openapi 原生域）、F4-24、F4-25 复核通过。

### kg_endpoints_artist_album.dart:42-44 歌手单曲 `pagesize` 被静默截断到 100
- 级别：P3
- 事实：`var ps = int.tryParse('${q['pagesize'] ?? 30}') ?? 30; if (ps > 100) ps = 100;`。Node `artist_audios.js` 原样透传 `params?.pagesize || 30`（超限时由上游回 20010）。
- 违反：QUALITY_STANDARD 第 16 条（「请求 200 条得到 100 条」与「请求 100 条」语义混同，未告知调用方）；第 11 条（降级未声明触发条件）
- 后果：调用方按 pagesize=200 计算分页总页数，实际每页只有 100 条 → 后一半歌曲永远加载不到，用户看到歌手页曲目「少了」且无提示。

### kg_endpoints_artist_album.dart:44-60 `artistAudios` 已 `baseUrl: openapi`，同时还带 `x-router: openapi.kugou.com`
- 级别：P3
- 事实：`baseUrl: 'https://openapi.kugou.com'` 与 `headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'}` 并存；Node 两者都有（原样移植）。
- 违反：—（与 Node 一致，记录项）
- 后果：无；仅记录「非缺陷」，避免下一批把冗余头当问题重复上报。

### kg_endpoints_artist_album.dart:137-170 `rankAudio` 忽略调用方 `rank_cid`，恒发 0
- 级别：P3
- 事实：`'rank_cid': 0,` 常量。Node `rank_audio.js`：`rank_cid: params.rank_cid || 0`。
- 违反：QUALITY_STANDARD 第 28 条（可配置参数被硬编码，与 Node 不一致）
- 后果：按分类筛选榜单（`rank_cid≠0`）时始终返回全部分类，用户选「华语」仍看到混合榜（P3，功能面窄）。

### kg_endpoints_artist_album.dart:19-32 `artistDetail` 未带 `F4-03` 的 `data.author_id` 数值化，且无空 id 校验
- 级别：P3
- 事实：`data: {'author_id': '${q['id'] ?? q['author_id'] ?? ''}'}`，缺失时发 `author_id: ''`；Node 为 `params.id`（缺失则 JSON 丢弃该键）。
- 违反：QUALITY_STANDARD 第 14 条（边界参数未校验）
- 后果：歌手页参数异常（深链缺 id）时会向 openapi 发空 author_id，返回 `data:{}` 并被 `_wrap` 判成功 → 页面渲染空歌手，用户以为歌手不存在。

---

## 10. lib/core/direct/kg_endpoints_home.dart（198 行，已完整阅读）

`rank/list`（ocean 原生域 `/v6/rank/list`）、`top/song`（musicadservice `/container/v1/newsong_publish`）、`everyday/recommend`（`platform` 走 query）、`search/hot`（msearch `/api/v3/search/hot_tab`）、`top/playlist`（F4-11 补齐 `special_recommend` 内层 5 字段）、`yuekuBanner`（F4-12 `vip_type`）均已与 `api_verified.md` 记录对齐；`clienttime` 秒级 ✓；`paramsKey` 参与 `top/playlist`/`videoDetail` ✓。

### kg_endpoints_home.dart:186-198 `videoDetail` 与 `kg_direct_api_client._videoDetail`、`kg_media_direct.videoDetail` 三份实现并存（本份无人调用）
- 级别：P3
- 事实：本文件 `videoDetail(q)` 与 `kg_direct_api_client.dart:470-500 _videoDetail(q)` **逐字段相同**（含 `uuid: md5(dfid+mid)`、`key: paramsKey(clienttime)`、`clearDefaultParams: true`）；`kg_media_direct.dart:63-89 KgMediaDirect.videoDetail(videoId)` 是第三份（`data` 只收单个 id，不 split）。分派在 `get('video/detail')` → `_videoDetail`，本份与 media_direct 那份无调用点。
- 违反：QUALITY_STANDARD 第 5 条（同一请求三份权威，必然分叉）；第 32 条（死代码）
- 后果：任何对 `/v1/video` 的修正（如 `show_resolution` 换字段、`uuid` 换算法）只改一处就会留下两份旧实现；将来若有人改用 `KgMediaDirect.videoDetail`（参数是单 id），批量 MV 只会返回第一条，其余静默丢失。

### kg_endpoints_home.dart:57-76 `topSong` 的 `rank_id` 用 `q['type'] ?? q['rank_id'] ?? 21608` 三元兜底，未校验数值
- 级别：P3
- 事实：`'rank_id': q['type'] ?? q['rank_id'] ?? 21608`（可能是字符串 `'36'`）；Node `top_song.js` 用 `params.type || 21608`（`'0'` 之类会落到默认）。`'userid': int.tryParse(...) ?? 0` 与 Node 数值一致 ✓。
- 违反：QUALITY_STANDARD 第 13 条（外部参数未归一为数值）
- 后果：深链传 `type=` 空串时 Dart 发出 `rank_id: ''`（`??` 不拦空串），上游回 20010，新歌页空白；Node 会落到 21608 正常返回。

### kg_endpoints_home.dart:82-86 `everydayRecommend` 只下发 `platform`，丢弃 Node 的其它可选参数
- 级别：P3
- 事实：`params: {'platform': '${q['platform'] ?? 'ios'}'}`，未透传 `q['page']/q['pagesize']` 等（Node `everyday_recommend.js` 亦主要依赖 platform，但 `api_verified.md` 未记录该端点参数全集）。
- 违反：QUALITY_STANDARD 第 29 条（参数集合未留样）
- 后果：若上游对每日推荐支持分页/去重参数，本实现无法使用；现状无用户可见影响（P3）。

### kg_endpoints_home.dart:24-37 残留错位注释「/// 歌手详情（module/artist_detail.js）」位于 `rankList` 上方
- 级别：P3
- 事实：`/// 歌手详情（module/artist_detail.js）` 之后是空行 + `Future<KgResponse> rankList(...)`。
- 违反：QUALITY_STANDARD 第 31 条（注释与代码不符）；第 30 条
- 后果：读者按注释去 rankList 里找歌手详情逻辑，误导排查方向。

---

## 11. lib/core/direct/kg_endpoints_auth.dart（413 行，已完整阅读）

签名/加密细节复核**通过**：`loginCellphone`/`login` 的 `pk` 大写、`userDetail` 大写、`loginToken` 与 `verifyUserInfo` 小写，与 Node `login_cellphone.js:27`/`login.js:16`/`user_detail.js:6`（大写）与 `login_token.js:21`/`verify_user_info.js`（小写）逐一吻合；`t1/t2` 固定 key/iv、`params` 走 `aesEncryptCbcAuto`、`clienttime_ms` 毫秒、`key=paramsKey(clienttime)` 亦一致。

### kg_endpoints_auth.dart:404-412 `_afterLogin` 从未写入 `vipType`/`vipToken`，与 `kg_client.dart` 注释（F4-12）相反
- 级别：P1
- 事实：`_afterLogin` 只写 `kg.token / kg.userid / kg.t1`。`kg_client.dart:172-175` 声明：「由 KgEndpointAuth._afterLogin 从登录响应的 data.vip_type / vip_token 写入」。直连层 12 个文件内再无任何对 `kg.vipType`/`vipToken` 的写点。
- 违反：QUALITY_STANDARD 第 5 条（声明了单一来源却无人写入）；第 32 条（无人写入的状态）；第 31 条（注释描述不存在的行为）
- 后果：`yuekuBanner` 的 `vip_type` 恒为 0（`int.tryParse(kg.vipType) ?? 0`），登录的 VIP 用户被上游当作非会员 → 会员专属 banner 拿不到；F4-12 声称修好的「三态兼容」实际未生效，属于「修了字段但没接线」。

### kg_endpoints_auth.dart:244-258 `loginQrCheck` 在端点层直接改写 `kg.token/kg.userid`，绕过 `_afterLogin` 与 `setCredentials`
- 级别：P2
- 事实：`if ('${data['status']}' == '4') { ... kg.token = token; kg.userid = userid; }`，未写 `t1`、未写 `vipType`、未同步 `kg.dfid`，也未走父类 `setCredentials`（CookieJar 不更新）。
- 违反：QUALITY_STANDARD 第 5 条（登录态有两个写入点且字段集不同）；第 1 条（端点职责混入状态管理）
- 后果：扫码登录后内存登录态有 token 却无 t1，`/login/token` 刷新走 `|dateNow` 分支；同时 CookieJar 里仍是旧 cookie，任何走 `super.get` 残路（如 404 未移植路径以外的 kapi 调用）会携带旧身份，出现「已登录但部分接口 401/匿名」的裂脑。

### kg_endpoints_auth.dart:60-70 `captchaSent` 与 `loginToken` 使用明文 HTTP 域名
- 级别：P1
- 事实：`baseUrl: 'http://login.user.kugou.com'`（`captchaSent`、`loginToken`）。`loginCellphone` 用 `https://loginserviceretry.kugou.com`、`login` 走 gateway，只有这两处是 http。
- 违反：QUALITY_STANDARD 第 27 条（接口只走原生网关，且原生网关均为 https）；第 3 条（安全契约未声明）；属安全类缺陷
- 后果：短信验证码请求（含手机号）与 token 刷新请求（body 内 `p3` 密文、`pk`）在公共 WiFi 下可被旁路观察与篡改；攻击者回一个伪造的 `status=1` + 自造 token 即可诱导客户端把会话指向自己控制的身份（会话劫持），用户无任何感知。Node 同样使用 http，但 Node 是本地服务、本 App 是移动端直连公网，风险等级不同。

### kg_endpoints_auth.dart:316-330 `userDetail` 直接向响应体注入 `userid` 字段
- 级别：P3
- 事实：`if (inner is Map<String, dynamic>) { inner['userid'] = userid.toString(); }`（注释说明上游无该字段、上层依赖它）。
- 违反：QUALITY_STANDARD 第 1 条（端点层改写业务数据）；第 3 条（契约靠运行时补字段维持）
- 后果：响应体被就地改写后，`_wrap` 返回的 body 与上游真实返回不一致；任何「打印原始响应排障」的日志都会看到不存在的字段，掩盖上游缺字段这一事实（P3）。

### kg_endpoints_auth.dart:335-353 `getVerifyInfo` 与 `KgClient.submitFingerprintVerification` 对同一端点两套实现（sid/edt 一个为空、一个为真实值）
- 级别：P3
- 事实：本文件发 `'sid': '', 'edt': ''`；`kg_client.dart:320-340` 发 `sid: edt.sid, edt: edt.edt` 且带 `i:''`、`wasm:1`。两处 `baseUrl` 也不同（一处 gateway 默认、一处 `verifyservice.kugou.com`）。
- 违反：QUALITY_STANDARD 第 5 条（同一端点两套权威）；第 8 条（异常/请求形态不一致）
- 后果：验证页取事件信息与自动重试取事件信息可能来自不同行为的上游路径，出现「验证页能过、自动重试仍 20028」；排障时无法判断是哪一份实现失败。

---

## 12. lib/core/direct/kg_providers.dart（98 行，已完整阅读）

装配链复核**通过**：`kugouApiClientProvider → kgDirectApiProvider → KgDirectApiClient(kgClientProvider)`（`lib/core/providers.dart:9-11`），全仓无生产路径使用裸 `KugouApiClient()`；`kgDeviceProvider` 由 main 覆盖；`onDfidRegistered` 接 `saveDfidSync` 落盘。

### kg_providers.dart:33-40 / 44-52 `loadSync`、`openBox` 的空捕获
- 级别：P3
- 事实：`catch (_) {}`（loadSync 解析失败直接重新生成设备；openBox 吞掉 Hive 异常）。
- 违反：QUALITY_STANDARD 第 6 条（空捕获）、第 9 条（失败不可观测）
- 后果：`device` box 记录损坏时静默换设备（guid+mid 全变），服务端视为新设备并重置风控计数；用户表现为「莫名其妙要重新验证/登录」，日志无痕。

### kg_providers.dart:54-58 `KgDeviceStore` 声明为单例类但全部方法为 static
- 级别：P3
- 事实：`class KgDeviceStore { KgDeviceStore._(); static final instance = KgDeviceStore._(); … static KgDevice loadSync … }`；全类无实例方法，`instance` 无调用点。
- 违反：QUALITY_STANDARD 第 32 条（无用的实例入口）；第 30 条（命名暗示有状态单例，实则纯函数集合）
- 后果：读者以为存在单例状态需要维护/释放，实际没有；`instance` 是持续维护成本的来源（P3）。

### kg_providers.dart:77-82 `kgDeviceProvider` 兜底 `KgDevice.generate()` 不持久化，且注释承认「仅防崩」
- 级别：P2
- 事实：`return KgDevice.generate();`（每次读取生成新 guid/mid/dfid=''）。任何遗漏 override 的 `ProviderContainer`（测试、后台 isolate、二次 `ProviderScope`）都会拿到不同设备。
- 违反：QUALITY_STANDARD 第 4 条（隐式依赖：正确性依赖 main 的 override）；第 5 条（同一事实两个来源）
- 后果：一旦 override 失效，同一台手机上每次启动都是「新设备」，登录态因 cookie 与 mid 不匹配而失效，用户被反复踢下线。

---

## 13. 跨层复核（任务 C / D：写操作、防重、凭证）

### lib/features/comment/data/comment_repository.dart:97-146 三个评论写接口全部走 `post()`，而 `KgDirectApiClient.post` 没有这些分支 → 一律抛 `ApiException(-404)`
- 级别：P0
- 事实：`sendComment` → `_api.post('/comment/music/send' | '/comment/playlist/send' | '/comment/album/send', {}, query: …)`；`sendFloorReply` → `_api.post('/comment/floor/send', …)`；`deleteComment` → `_api.post('/comment/music/del', …)`。而 `kg_direct_api_client.dart` 的 **post** switch 只有 15 个 case（rank/audio、comment/music、kmr/audio/mv、everyday/recommend、top/playlist、privilege/lite、search、comment/floor、playlist/detail、login、verify/user/info、artist/detail、artist/albums、album/detail、album/songs），**不含任何评论写路径**；它们只出现在 **get** switch（因为 `_write` 约定用 get 触发写分派）。不匹配即落到 `post` 末尾 `throw ApiException(-404, '接口 /… 尚未移植到原生网关…')`。
- 违反：QUALITY_STANDARD 第 8 条（异常契约与主路径不一致：这里连 DioException 都不是）；第 32 条（get/post 两套分派表不对称）；第 27 条（功能等于「未移植」）
- 后果：**发评论、楼中楼回复、删除评论全部 100% 失败**，用户点发送后看到「接口 /comment/music/send 尚未移植到原生网关（kapi 仅作参考，运行期不调用）」。这是本批最严重的功能级缺陷，且与 playlist 的 get 分派形成鲜明反差 —— 同一份代码里两种调用约定并存。

### lib/features/mv/data/mv_collection_repository.dart:104-146 `setCollected` 完全忽略 `collect` 形参，取消收藏实际又发了一次「收藏」
- 级别：P0
- 事实：`Future<bool> setCollected(int videoId, {required bool collect})` 的 body 内只出现 `/v1/collect`，`collect` 参数从未参与 URL/payload 选择；Node `mv_collect.js` 用 `/v1/collect`、`mv_collect_del.js` 用 `/v1/cancel_collect`（`ctype:2` 相同、UA 的 `MV/Care` 与 `MV/UnCare` 区分）。
- 违反：QUALITY_STANDARD 第 3 条（契约声明了「收藏/取消」两种语义，实现只有一种）；第 21 条（写操作语义与 UI 相反 → 重复提交、状态不可逆）；第 32 条（未使用形参）
- 后果：用户在「我的 MV」里取消收藏，界面提示成功、列表刷新后 MV 仍在（服务端被再收藏一次）；反复操作收藏数只增不减，属服务端状态被错误改写，用户无法取消收藏。

### lib/features/mv/data/mv_collection_repository.dart:120-124 MV 收藏的 `p` 用裸 RSA，与刚修好的 playlistDel（PKCS1）不一致
- 级别：P1
- 事实：`final p = KgCrypto.rsaEncryptRawHex(jsonEncode({'aes': aes.key, 'uid': userid, 'token': token})).toUpperCase();`；Node `mv_collect.js`/`mv_collect_del.js` 用 `rsaEncrypt2(...)`，而 `util/crypto.js:264-270` 明确是 `'RSAES-PKCS1-V1_5'`。`kg_endpoints_playlist.dart:23-27` 的 P0-4 已把同一错误修掉并写注释。
- 违反：QUALITY_STANDARD 第 28 条（同一加密协议两处实现不一致）；第 5 条（同一协议两个权威）
- 后果：MV 收藏/取消收藏的 `p` 服务端解不出 `{aes,uid,token}` → 操作恒失败；由于此路径只判 HTTP 200，用户看到的还是「收藏成功」。P0-4 的修复没有推广到同构端点，属**修复不彻底**。

### lib/features/mv/data/mv_collection_repository.dart:139-146 请求体发 Base64 文本，Node 发的是二进制
- 级别：P1
- 事实：`data: bodyStr`（Base64 字符串），`KgClient.request` 会以 `contentType: application/json` 发送该字符串；Node：`data: Buffer.from(aesEncrypt.str, 'base64')`（二进制），并 `responseType: 'arraybuffer'`。
- 违反：QUALITY_STANDARD 第 28 条（请求体形态必须与实测一致）
- 后果：即使 `p` 修好，服务端拿到的仍是 base64 文本而非密文字节 → 解密失败 → 收藏依然不生效；与上一条叠加使 MV 收藏功能整体不可用。

### lib/features/mv/data/mv_collection_repository.dart:143-146 只以 HTTP 200 判定成功，且解密结果被丢弃
- 级别：P2
- 事实：`try { … KgCrypto.aesDecryptPlaylistB64(...) } catch (_) {}` 后 `return res.status == 200;`（解密结果未使用、业务 `status`/`error_code` 未检查）。
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径必须逐端点核对，不可只看 HTTP）；第 6 条（空捕获）；第 16 条（失败与成功不可区分）
- 后果：服务端返回 `status:0/error_code:xxx`（HTTP 仍 200）时 UI 显示「收藏成功」；用户收藏没生效却以为生效，退出重进发现丢失。

### lib/features/playlist/data/playlist_repository.dart:265-292 `_write` 的防重锁与 `maybeSucceeded` 语义（复核通过，含两处小瑕疵）
- 级别：P3
- 事实：`_inFlight.add(dedupeKey)` → `finally { _inFlight.remove(dedupeKey); }` 成对；`_toWriteException` 按 `DioExceptionType` 区分 `maybeSucceeded`；成功路径 `_invalidatePlaylistCaches()`。瑕疵一：命中在飞锁时抛 `maybeSucceeded: true`（其实一条都没发出）。瑕疵二：`on ApiException` 分支被声明在 `on DioException` 之后（当前类型不重叠，可编译），但直连层把几乎所有失败都包成 `DioException`，该分支实际只在 `-404` 场景生效。
- 违反：QUALITY_STANDARD 第 16 条（在飞拒绝被描述为「可能已生效」）；第 8 条（异常分支覆盖不全）
- 后果：用户连点两次「收藏」，第二次提示「可能已生效，请刷新确认」并把用户赶去手动确认，体验与事实不符（P3）。

### lib/features/auth/data/auth_repository.dart:69-73 `AuthRepository` 默认 `KugouApiClient()`（裸客户端）
- 级别：P3
- 事实：`AuthRepository({KugouApiClient? api, SecureStorage? storage}) : _api = api ?? KugouApiClient()`；`authRepositoryProvider` 已注入 `kugouApiClientProvider`，故生产路径安全，但默认值仍是「整体走 kapi 中转」的实例。
- 违反：QUALITY_STANDARD 第 2 条（依赖必须显式注入，不得内部构造协作者）；REVIEW_SPEC「Repository 不得 new 裸 KugouApiClient()」
- 后果：任何直接 `AuthRepository()`（测试、脚本、未来新增的 provider）都会整体走 kapi，与「接口只走原生网关」口径相反，且不会有任何报错提示。

### lib/features/comment/data/comment_repository.dart:99-109 发送前查询 `special_child_id` 失败被静默吞掉
- 级别：P3
- 事实：`try { … } catch (_) { /* 查询失败不阻断发送，childrenid 交给直连层兜底 */ }`，而直连层并无兜底（`childrenid` 为空串照发）。
- 违反：QUALITY_STANDARD 第 6 条（空捕获）、第 31 条（注释声称有兜底，实际没有）
- 后果：歌曲评论列表接口抖动时，发送的 `childrenid` 为空 → 服务端 err_code=10002/400，用户看到「发送失败」却不知原因；重试仍失败（每次都要先查列表）。
