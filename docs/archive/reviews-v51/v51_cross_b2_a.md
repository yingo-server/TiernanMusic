# v5.1 B2 视角 A：功能正确性（lib/core/direct）

- 范围：`docs/TASK_v51_b2_b8.md` B2 段列出的 14 个 `lib/core/direct/*.dart`（共 4316 行）。
- 视角：链路闭环、参数/返回契约、状态机、单位与字段形态；主判据为原生网关唯一、签名形态、写操作防重、dfid 三写、二进制 body、`_wrap`→ResponsePolicy 迁移等价性。
- 依据：`docs/QUALITY_STANDARD.md`（33 条，优先）、`docs/REVIEW_SPEC.md`；Node module 仅作参数形态参照，kapi 返回未作为任何判定依据（第 33 条）。
- 只读审查：未修改任何代码文件；未运行构建/测试/服务。

---

## 逐文件结论

### `lib/core/direct/edt_generator.dart`（281 行，完整读 1–281）
- 复核：AES-128-CBC 固定 IV `kugousecurity123` + PKCS7（第 226–246 行）与 RSA-OAEP `OAEPEncoding.withSHA256(RSAEngine())`（第 255–279 行）符合既定口径；`generate()` 明文含 `mid/userid/dfid/webgl/webdriver/ts/data`，`ts` 为 `DateTime.now().millisecondsSinceEpoch`（第 95 行），单位明确。
- 待对照 Node `util/generate_simulate.js` 后补充（不与 kapi 返回相关，第 33 条不受影响）。

### `lib/core/direct/kg_client.dart`（615 行，完整读 1–615）
- 复核：`request()` 默认基址 `KgConfig.gateway=https://gateway.kugou.com`、`_registerDeviceOnce` 用 `https://userservice.kugou.com`、`submitFingerprintVerification` 用 `https://verifyservice.kugou.com`，均为原生域；`clienttime` 为秒（第 201 行）；`signature` 写入 `allParams` → `queryParameters`（第 237–243、263 行）；`requestWithVerify` 重试链为「首请求→ssaCode→`/verifyservice/v3/get_verify_info` 提交 sid/edt→成功才重发一次」，且注释明确写操作禁用（第 334–381 行）。
- 复核：`Uint8List` 二进制 body 直传并设 `application/octet-stream`（第 226–232、266–278 行）；设备注册响应为二进制时 `base64.encode(raw)` → `KgCrypto.aesDecryptPlaylistB64(base64, aes.key)`（第 540–552 行），与 Node `playlistAesDecrypt` 的 `md5(seed)[:16]`/`[16:32]` 派生一致；注册成功写 `device.dfid` 并 `_persistDfid()`（第 448–455、555–562 行）。
- 参数对照发现的问题见下方逐条（与 Node `util/request.js`、`module/register_dev.js`、`module/get_verify_info.js`、`module/verify_user_info.js` 对照；第 33 条：未用 kapi 返回）。

### `lib/core/direct/kg_client.dart:405-419` `submitFingerprintVerification` 把「取验证信息」当作「提交验证」，重试链断在第一步
- 级别：P1
- 违反：QUALITY_STANDARD 第 27 条（原生网关调用方式必须逐一实测，参数/路径形态不得推测）、第 3 条（跨层契约：失败返回语义）、REVIEW_SPEC 三.1
- 依据：`submitFingerprintVerification()` 把 `sid/edt` POST 到 `/verifyservice/v3/get_verify_info`，并以 `r.body['status'] == 1` 判定验证已完成；但 Node `module/get_verify_info.js` 的 `dataMap` 固定 `sid:''`、`edt:''`，该端点用于**获取**验证码数据，不接收指纹；Node `module/verify_user_info.js` 才是向 `https://verifyservice.kugou.com/v4/verify_user_info` 提交 `sid/edt`（并带 `v_type/verifycode/pk/params`）的端点。`requestWithVerify()` 第 360–372 行在 `ok==false` 时直接返回首次失败响应，在 `ok==true` 时重发原请求，两种分支都没有真正完成风控验证；`ssaCode` 仅来自 `body['ssaCode']/body['ssa_code']/headers['ssa-code']`（第 43–44、67 行）。
- 影响：命中 `ssa-code` 风控的请求（含 20006/20028）无法自动解除验证；用户侧表现为搜索/播放等读接口持续报错或被迫走兜底，且首请求被重复发送一次也无法通过风控。
- 证据等级：静态推演（Node 源码对照 + 本文件控制流；未实测原生网关）

### `lib/core/direct/kg_client.dart:408` 验证请求的 `clientver` 与 Node 参照不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（调用参数集合须逐一实测）
- 依据：`submitFingerprintVerification` 传 `params: {'clientver': lite ? 11440 : 20489}`；Node `module/verify_user_info.js` 的 `params` 为 `{clientver: 11510}`，`module/get_verify_info.js` 不声明 `clientver`。此外默认参数注入仍会带 `appid=1005/clientver=20489/clienttime/...`，与 Node 的 `clientver=11510` 查询参数不同。
- 影响：即便路径修正，验证请求的版本号形态仍与参照不一致，可能继续被判定为非法客户端请求，风控无法通过。
- 证据等级：静态推演（Node 源码对照；参数差异为实锤，网关判定未实测）

### `lib/core/direct/kg_client.dart:227-243` `Uint8List` 请求体的签名 data 为空串，Node 为原始字节
- 级别：P1
- 违反：QUALITY_STANDARD 第 28 条（签名位置与算法、请求体序列化必须实测对照）、REVIEW_SPEC 三.2
- 依据：`data is Uint8List` 时 `bodyStr = null`（第 227–232 行），随后 `KgSignature.android(allParams, data: bodyStr ?? '')`（第 239–242 行）用空串参与 MD5；而 Node `util/request.js` 的 `signatureAndroidParams` 对 `Buffer.isBuffer(data)` 明确用 `wordArrayFromBuffer(data)` 把**原始二进制字节**喂进 hasher。Node `module/mv_collect_del.js` 与 `module/playlist_del.js` 的二进制/文本 body 差异正是 B2 关注的形态之一。本文件第 218–224 行注释亦承认二进制 body 是后补的能力，但签名链未同步。
- 影响：所有以 `Uint8List` 发二进制体的端点（MV 收藏/删除等写操作）签名与服务端计算值不一致，直连返回签名错误并可能触发风控，写操作失败或静默走兜底。
- 证据等级：静态推演（与 Node `util/request.js:64-76`、`util/helper.js:60-76` 逐行对照；未实测原生网关）

### `lib/core/direct/kg_client.dart:266-277` 二进制 body 的 Content-Type 与 Node 写端点不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（请求头形态须实测对照）
- 依据：`data is Uint8List` 时固定 `contentType: 'application/octet-stream'`；Node `module/mv_collect_del.js` / `playlist_del.js` 等 AES body 端点通过 `useAxios` 未声明该头（axios 对 Buffer 默认不发 Content-Type），而 Node `util/request.js` 的 `createCloudRequest` 明确用 `application/json;charset=utf-8`。本范围后续端点文件将逐项核对二进制路径的实际 header 契约。
- 影响：请求头形态与参照不一致可能让网关按不同 body 解析规则处理，造成直连失败；在写操作上表现为收藏/删除无效果。
- 证据等级：静态推演（Node 源码对照；头差异为实锤，网关行为未实测）

### `lib/core/direct/kg_client.dart:281-289` `DioException` 被转成 HTTP 502 的「业务体」，上层异常契约被削弱
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）、第 9 条（失败可观测）
- 依据：`on DioException` 返回 `KgResponse(status:502, body:{'status':0,'error':'${e.message}'})`，不抛 `DioException`/`ApiException`；`requestWithVerify._needsVerify` 第 389 行要求 `r.status == 200` 才进入验证链，故所有网络层异常都不触发验证。第 292 行解析失败也只生成 `{'status':0,'error':'响应解析失败'}` 而丢弃 HTTP 状态。
- 影响：断网/超时/证书错误被折叠为统一的 502 业务失败，上层无法区分「网络不可达」与「服务端业务失败」，可能给出错误提示或错误地触发 kapi 兜底。
- 证据等级：静态推演（本文件控制流；未实测）

### `lib/core/direct/kg_crypto.dart`（402 行，完整读 1–402）
- 复核：三盐齐全（android `OIlwieks28dk2k092lksi2UIkp`、lite、web `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`、register `1014`，第 27–42、88–93 行）；`paramsKey` 为 `md5(appid+salt+clientver+data)` 且 `clienttime` 由调用方以秒传入；`rsaEncryptPkcs1` 用 PKCS1-v1.5、小写 hex（第 165–180 行），`rsaEncryptRawHex` 右补零无填充（第 188–205 行）；`aesEncryptHex` 用 `md5(seed)[:16]`/`[16:32]`（第 213–243 行），与 Node `playlistAesEncrypt` 一致。
- 复核：网关常量仅 `https://gateway.kugou.com` 与 `https://userservice.kugou.com`（第 45–47 行），无 kapi 中转域。

### `lib/core/direct/kg_crypto.dart:61-69` `KgSignature.android` 的 Map/List 值序列化与 Node 不完全一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（签名参数集合/序列化形态）
- 依据：Dart 对 `params[k]` 仅当 `v is Map || v is List` 时 `jsonEncode(v)`；Node `util/helper.js:60-67` 对 `typeof params[key] === 'object'`（含 `null` 以及任意对象）统一 `JSON.stringify`，`null` 会变字符串 `"null"` 而 Dart 会输出 `"null"` 的 `$v` 结果同为 `null`（此处一致），但 `jsonEncode` 与 JS `JSON.stringify` 对 Map 的键顺序/转义（如非 ASCII、斜杠）不保证一致；`KgSignature.web` 第 80–84 行更完全用 `$k=${params[k]}` 不序列化对象。鉴于端点参数多为标量，此项列为边界形态差异。
- 影响：若任一端点在 query 中传 Map/List（如复杂过滤条件、批量 id），android/web 签名与服务端不一致，直连静默失败并滑向兜底。
- 证据等级：静态推演（Node 源码对照；未实测具体端点）

### `lib/core/direct/kg_crypto.dart:213-243` `aesEncryptHex(key:..., iv:...)` 返回 `key: ''`，解密侧无法拿到 seed
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回值契约/失败语义）、第 30 条（命名即文档）
- 依据：显式传 `key` 与 `iv` 时 `AesResult(str:..., key: seed ?? '')` 返回空 key（第 242 行）；`AesResult.key` 的语义在随机分支是「seed」，在显式分支为空。`kg_client._registerDeviceOnce` 依赖 `aes.key` 解密响应（第 549 行）；若调用方用显式 key/iv 重载（端点文件中如出现），解密将用 `md5('')` 派生，得到错误明文。另 `aesEncryptHex` 名称与「hex 输出」不符，实际返回 Base64，易误用。
- 影响：任何显式 key/iv 的 AES 请求，其加密响应无法被正确解密，设备注册/云歌单类链路数据不可读。
- 证据等级：静态推演（本文件返回值 + `kg_client` 调用链；未实测）

### `lib/core/direct/kg_direct_api_client.dart`（662 行，完整读 1–662）
- 复核：`fallbackToKapi = false` 常量（第 104 行）使 `super.get/post`（kapi 基址）在所有已分派/未分派路径都不可达；未移植路径抛 `-404` 的 `DioException(error: ApiException)`（第 284–293、370–379 行）；`get/post` 分派表中所有评论写、歌单写均带 `write: true`（第 212–230、303–315 行）。`_wrap` 已迁到 `evaluateResponse`（第 84–88 行），`setCredentials` 对 dfid 做 `kg.dfid` + `kg.device.dfid` 双写（第 43–50 行）。
- 迁移等价性与分派契约问题如下。

### `lib/core/direct/kg_direct_api_client.dart:84-88` `_wrap` 迁移后，无 `status` 的裸 Map 响应被一律判失败
- 级别：P1
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径必须逐端点实测确认）、第 3 条（返回契约）、REVIEW_SPEC 三.4
- 依据：`_wrap` 现在无条件返回 `evaluateResponse(r.body, ssaCode: r.ssaCode)`；`lib/core/domain/response_policy.dart:26-33` 的 `_codeOf(null) == 0`，第 76 行 `final status = _codeOf(body['status']) ?? -1` 对**无 status 字段**的响应得到 `status = 0`；第 100 行 `if (status == 0 || status == 2 || ec != 0) return fail(ec)` 因此必然失败，使同文件第 103–109 行「无 status 空包失败 / 无 status 但有数据成功」两个分支永远不可达。REVIEW_SPEC 三.4 明确 `comment / comment/count` 为「裸 Map」成功响应，`kg_client.dart:292-298` 对非 Map JSON 又包成 `{'data': ...}`（同样无 status）。文件自身第 84 行上方注释仍写着「成功判定看 status == 1」「有数据就不算失败」，与迁移后的实际行为不符。
- 影响：`/comment/count`、评论裸 Map 等端点即使原生网关正常返回数据，也被判为 `ApiException(0)` 并因 `fallbackToKapi=false` 直接抛错；评论数、评论列表显示失败/为空，用户可见。
- 证据等级：静态推演（`response_policy.dart` + `kg_client.dart` 解包链 + 本文件 `_wrap`；原生返回形态未实测，按 REVIEW_SPEC 既定口径）

### `lib/core/direct/kg_direct_api_client.dart:91-98` 迁移后遗留 `_hasData` 与新策略的成功口径不等价
- 级别：P2
- 违反：QUALITY_STANDARD 第 32 条（死代码）、第 29 条（成功判定口径）
- 依据：本类 `_hasData(body)` 只检查 `body['data']`，迁移后已无任何调用方；`response_policy.dart:113-126` 的同名函数在 `data` 非 Map/List 时改为「任意非 meta 键存在即算有数据」。因此 `status=1 + errcode=151/152/200/201` 且只带一条非 meta 提示字段（无有效 data）的响应，旧口径判失败、新口径判成功。
- 影响：警告码/限流类响应可能被当作成功返回空数据，UI 显示「加载成功但空白」，且不再触发错误提示或兜底。
- 证据等级：静态推演（两处函数逐行对照；未实测具体响应）

### `lib/core/direct/kg_direct_api_client.dart:299-366` `post` 分派表缺多个 `get` 表已有的写/读路径，按方法调用即 -404
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（跨层接口契约：输入/失败语义）、第 27 条（接口只走原生网关）
- 依据：`post()` 的 switch 只有 24 个 case；`get()` 表中存在而 `post()` 缺失的路径包括 `song/url`、`playlist/track/all`、`video/url`、`playlist/add`、`playlist/del`、`playlist/tracks/add`、`playlist/tracks/del`、`user/playlist`、`playlist/track/all/new`、`comment/playlist`、`comment/album`、`register/dev`、`captcha/sent`、`login/cellphone`、`login/token`、`login/qr/*`、`user/detail`、`get/verify/info`、`search/hot`、`yueku/banner`、`video/detail`、`artist/audios`、`rank/list`、`top/song` 等。`post` 未命中即抛 -404「接口尚未移植到原生网关」；`KugouApiClient.post` 的调用方若对其中任一路径用 POST，链路直接断。
- 影响：任何以 POST 调用这些路径的业务功能（如播放器取 `/song/url`、登录/验证码、歌单写）会被判「未移植」而失效；用户看到播放失败/操作报错。
- 证据等级：静态推演（两张分派表逐项对照；实际调用方方法逐项核对见后续「复核通过项/问题」）

### `lib/core/direct/kg_direct_api_client.dart:304-315,212-230` `write: true` 只覆盖分派表，未覆盖 `captcha/sent`、`verify/user/info`、`register/dev` 等状态改变型端点
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作必须幂等或有防重机制）、第 3 条
- 依据：`get` 表中 `captcha/sent`、`register/dev`、`login/*`、`get/verify/info` 未标 `write: true`；`post` 表中 `login`、`verify/user/info` 未标 `write: true`。当前 `fallbackToKapi=false` 使 `write` 分支与常规分支同效（都抛 DioException），但 `write` 语义只保护「kapi 回退」这一条重复提交路径；若端点内部使用 `kg.requestWithVerify`（验证后原样重发）则不受此标志保护。
- 影响：人机验证自动重试链对这些端点仍可能把同一短信/验证/登录请求发送两次；用户可能收到两条验证码或产生重复验证提交。
- 证据等级：静态推演（分派表 + `kg_client.requestWithVerify` 控制流；端点是否调用该链在后续文件中逐项核对）

### `lib/core/direct/kg_endpoints_artist_album.dart`（166 行，完整读 1–166）
- 复核：`artistDetail`/`artistAudios` 使用 `https://openapi.kugou.com` 原生域；`artistAudios` 保持 `/kmr/v1/audio_group/author` + `kg-tid:220`，`clienttime` 秒级且 `key=signParamsKey(clienttime)`（第 44–82 行）；`rankAudio` 保持 gateway `/openapi/kmr/v2/rank/audio` + `kg-tid:369` 且未开 `clearDefaultParams`（第 142–165 行）。与 Node `artist_audios.js`/`rank_audio.js` 对照，路径、头、`sort/pagesize/page/area_code` 形态一致。

### `lib/core/direct/kg_endpoints_artist_album.dart:108-118` `albumDetail` 的 `is_buy` 未按 Node 归一，false/空串会进入 body
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数集合/形态须与实测参照一致）、第 13 条（外部输入形态不可假设）
- 依据：Dart 为 `'is_buy': q['is_buy'] ?? 0`；Node `module/album_detail.js` 为 `is_buy: params?.is_buy || 0`，会把 `false`、`''`、`'0'`、`0` 全部归一为数字 `0`。Dart 仅在 `q['is_buy'] == null` 时用 0，调用方若传 `false`、空串或字符串 `'0'`，`jsonEncode` 后分别为 `false`/`""`/`"0"`，与参照的 `0` 不同。
- 影响：专辑详情请求因 `is_buy` 形态异常被网关按非购买态处理或参数校验失败，付费/已购专辑详情字段缺失。
- 证据等级：静态推演（Node 源码对照；未实测网关对非数值 is_buy 的判定）

### `lib/core/direct/kg_endpoints_artist_album.dart:121-139` `albumSongs` 把字符串 `'0'/'false'` 的 is_buy 误判为未购买
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数形态）、第 13 条
- 依据：Dart 把 `isBuy == '0' || isBuy == 'false'` 也归为 `''`；Node `module/album_songs.js` 是 `params?.is_buy || ''`，字符串 `'0'`/`'false'` 在 JS 中为 truthy，应原样透传。两者对字符串形态结果相反。
- 影响：调用方以字符串形态传已购标记时，请求被当作未购买，付费专辑曲目列表少歌或为空。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_endpoints_artist_album.dart:157-165` `rank_audio` 丢弃 `rank_cid` 入参
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（输入取值范围契约）、第 28 条
- 依据：Dart 固定 `'rank_cid': 0`；Node `module/rank_audio.js` 为 `rank_cid: params.rank_cid || 0`，允许上层指定榜单子分类。`q` 中的 `rank_cid` 在本方法内完全未读取。
- 影响：需要按 `rank_cid` 过滤的榜单子页恒返回默认分类，用户看到的榜单内容与选择不一致。
- 证据等级：静态推演（Node 源码对照；未核对上层是否传该参数）

### `lib/core/direct/kg_endpoints_auth.dart`（426 行，完整读 1–426）
- 复核：账号端点全部走酷狗原生域（`gateway.kugou.com`、`login-user.kugou.com`、`loginserviceretry.kugou.com`、`verifyservice.kugou.com`）；`loginQrKey`/`loginQrCheck` 用 web 签名且 `signature` 进 query；`loginCellphone` 的 `clienttime_ms` 为毫秒、`p3/token` 里的 `clienttime` 为秒（第 178–183 行），`pk` 大小写与 Node `cryptoRSAEncrypt(...).toUpperCase()` 一致；`verifyUserInfo` 用 `/v4/verify_user_info` + `clientver:11510` + `baseUrl: https://verifyservice.kugou.com`（第 384–390 行），与 Node 参照一致。
- 复核：`captchaSent` 改为 `https://gateway.kugou.com` + `x-router: login.user.kugou.com`（第 59–72 行），仍是原生网关，未使用 kapi。

### `lib/core/direct/kg_endpoints_auth.dart:393-418` `_afterLogin` 严格比较 `status != 1`，字符串/浮点成功码不落登录态
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据形态不可假设）、第 3 条（返回契约）、第 29 条（成功判定逐端点确认）
- 依据：`_afterLogin` 第 396 行以 `if (body['status'] != 1) return;` 为唯一入口，只有 Dart `int 1` 能通过；`response_policy.dart:26-33` 与 `KgResponse.errorCode`（`kg_client.dart:48-53`）都明确要兼容字符串 `'1'`、`1.0` 等形态。`loginCellphone/login/loginToken` 在 `kg.request()` 后无条件调用 `_afterLogin(r, key)`；登录响应即使已被 `evaluateResponse` 判成功（`status='1'`），也不会解密 `secu_params`，更不会写 `kg.token/userid/t1/vipType/vipToken`。
- 影响：上游登录成功码为字符串/浮点形态时，直连层显示登录接口成功但本机无 token，随后所有需登录的请求以匿名态发出；用户表现为「登录成功却仍提示未登录」、收藏/评论/歌单失败。
- 证据等级：静态推演（形态兼容性对照为实锤；上游实际返回类型未实测，标注未实测）

### `lib/core/direct/kg_endpoints_auth.dart:37-51` `registerDev()` 只回写 `device.dfid`，未同步登录态 dfid 与 CookieJar
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 27 条（dfid 参与签名/风控维度须一致）
- 依据：`registerDev()` 调 `kg.registerDevice()`，`kg_client.registerDevice` 只写 `device.dfid` 并触发 `onDfidRegistered`（Hive 持久化）；本方法仅构造返回体 `{'status':1,'data':{'dfid': ...}}`，未写 `kg.dfid`、未调 `super.setCredentials(dfid: ...)`（CookieJar）。而 `KgDirectApiClient.setCredentials` 第 43–50 行明确把 dfid 同时写入 `kg.dfid`、`kg.device.dfid` 与父类 CookieJar（三写口径）。`kg_client.request()` 第 203 行与 `submitFingerprintVerification` 第 398–402 行只取 `device.dfid`，父类 `KugouApiClient.dfid`/CookieJar 仍为空串。
- 影响：注册成功后，依赖父类 `dfid`/CookieJar 的路径（登录态恢复、kapi 参考路径相关字段、上层读取）与签名所用 dfid 不一致，可能触发风控或被判定为新设备。
- 证据等级：静态推演（本文件 + `kg_client` + `kg_direct_api_client` + `kugou_api_client` 控制流；上层是否另行回填将在后续文件核对）

### `lib/core/direct/kg_endpoints_auth.dart:286-302` 二维码登录成功只写 `kg.token/userid`，不落 `t1/vipType/vipToken`
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（登录态单一来源）、REVIEW_SPEC 三.7（三态兼容）
- 依据：`loginQrCheck` 在 `data.status == '4'` 时仅写 `kg.token` 与 `kg.userid`；同文件 `_afterLogin`（第 393–418 行）与 Node `module/login_qr_check.js` 的 cookie 回填均会处理 token/userid，本类其它登录路径还额外写 `kg.t1`、`kg.vipType`、`kg.vipToken`。`KgClient.t1` 被 `loginToken`（第 200 行）用作 t1 明文，`vipType/vipToken` 用于三态判定；二维码登录后这些字段保持旧账号/默认值 `0`/空串。
- 影响：二维码登录后的 VIP 用户被当非会员（音质/权益判定失真），且 `login/token` 刷新用不到真实 t1，登录态恢复链路可能失败。
- 证据等级：静态推演（本文件字段写入链 + `kg_client.dart` 字段注释；上游 QR 响应字段集未实测）

### `lib/core/direct/kg_endpoints_auth.dart:86-91` lite 模式下 `loginCellphone` 的 `key` 用 lite 盐，而 Node 恒用标准版常量
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（签名参数/盐值形态须实测）
- 依据：Dart `KgSignature.paramsKey(dateTime, lite: lite)`，`paramsKey` 在 `lite=true` 时用 `androidSaltLite`、`liteAppid=3116`、`liteClientver=11440`；Node `module/login_cellphone.js` 为 `signParamsKey(dateTime)`，其 `isLite` 来自环境变量，但本请求同时固定 `baseURL: https://loginserviceretry.kugou.com`、`User-Agent: ...11440...`，未随 lite 切换 appid/clientver。若 `kg.lite` 在运行期被置真，Dart 的 key 与服务端按标准版算出的值不一致。
- 影响：lite 通道的验证码登录因 key 不匹配被拒，用户无法登录。
- 证据等级：静态推演（Node 源码 + `KgSignature.paramsKey`；`kg.lite` 是否会被置真在 `kg_providers/kg_play_api` 继续核对）

### `lib/core/direct/kg_endpoints_comment.dart`（301 行，完整读 1–301）
- 复核：三个评论写端点 `commentSend`/`commentFloorSend`/`commentDel` 均为 `/index.php` + `clearDefaultParams:true` + `notSignature:true`（第 92–94、151–153、196–198 行），符合 REVIEW_SPEC 三.2 的 5 处白名单；`key` 分别为 `paramsKey(clienttime+mid+data)` 与 `paramsKey(clienttime+mid)`，与 Node `_comment.js` 的 `signParamsKey` 一致；`commentCount` 用 web 签名 + `x-router: sum.comment.service.kugou.com`（第 43–64 行），与 Node `comment_count.js` 一致。所有请求经 `KgClient.request` 落 `gateway.kugou.com` 原生域。

### `lib/core/direct/kg_endpoints_comment.dart:43-64` `comment/count` 的裸 Map 成功响应被 `_wrap` 判为失败（迁移回归）
- 级别：P1
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径逐端点确认）、第 3 条
- 依据：本仓库 `docs/api_verified.md` 记录 `/comment/count` 匿名态原生返回 `{"hash":710442}`（无 `status`、无 `error_code`）；`kg_client.dart:292-298` 解码后 body 即该 Map。`response_policy.evaluateResponse` 第 76 行 `status = _codeOf(body['status']) ?? -1`，`_codeOf(null)` 返回 0；第 100 行 `if (status == 0 || status == 2 || ec != 0) return fail(ec)` 必然抛 `ApiException(0)`，第 103–109 行的「无 status 但带数据成功」分支不可达。`_directOrFallback` 因 `fallbackToKapi=false` 不再兜底，直接抛 DioException。
- 影响：歌曲评论数恒为失败；`CommentRepository.fetchCount` 只能拿到异常，评论区显示「0 条评论」或加载失败，用户可见。
- 证据等级：静态推演（代码控制流为实锤；响应形态依据本仓库 `docs/api_verified.md` 原生实测记录，非 kapi，第 33 条不冲突；本轮未实测）

### `lib/core/direct/kg_endpoints_comment.dart:91-94,150-153,195-198` clearDefaultParams 写端点的 `clienttime` 请求头与签名/query 的 clienttime 不同源
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（请求头与参数形态须与实测参照一致）、第 15 条（单位/时间源显式）
- 依据：三个方法各自在方法入口用 `DateTime.now().millisecondsSinceEpoch ~/ 1000` 生成本地 `clienttime`，用于 `key=paramsKey(...)` 和 query `clienttime`；而 `kg_client.request()` 第 201 行**另一次** `DateTime.now()` 生成 `clienttime`，且第 248–257 行无条件把它写进请求头 `clienttime`。Node `util/request.js:174` 明确 `headers['clienttime'] = params.clienttime`（从最终 params 同步），而不是另取当前时间。跨秒边界时 header 的秒值与 query/key 的秒值不同。
- 影响：发评论/回复/删评论在秒边界上出现 key 与 header 时间不一致，服务端校验失败；用户看到偶发的「发送失败」，重试可能重复提交。
- 证据等级：静态推演（时间源逐行对照；网关是否校验 header 未实测）

### `lib/core/direct/kg_endpoints_comment.dart:265-300` `commentFloor` 的 `mixsongid` 会下发空串，且忽略显式 `code`
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（参数集合/空值语义）、REVIEW_SPEC 三.4
- 依据：Dart 为 `if (q['mixsongid'] != null) 'mixsongid': q['mixsongid']`，Node `module/comment_floor.js:44-47` 用 `isNonEmpty(params.mixsongid)` 才下发；Node 还允许 `params.code` 显式指定码并据此选择 `/m.comment.service/v1/hot_replylist`，Dart 的 `useServiceEndpoint` 只看 `resource_type`，且 `_commentCodeOf` 不读 `q['code']`。
- 影响：上层传空串 `mixsongid` 时楼中楼请求带空参数，可能返回「歌曲不存在」而恒空；显式 code 的场景（如自定义评论池）被静默改回歌曲码。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_endpoints_home.dart`（198 行，完整读 1–198）
- 复核：所有基址均为酷狗原生域（`gateway.kugou.com`、`ocean.kugou.com`、`musicadservice.kugou.com`、`msearch.kugou.com`）；`everydayRecommend` 的 `platform` 放 query、`topPlaylist` 的 `dateTime` 为秒级字符串且 `key=paramsKey(dateTime)`（第 82–122 行）、`videoDetail` 开 `clearDefaultParams:true` 且 `uuid=md5(dfid+mid)`（第 180–197 行），与 Node 对照一致。
- 复核：`topPlaylist` 内层 `special_recommend` 补齐 `sort/ugc/is_selected/withrecommend/area_code`（第 110–119 行），与 Node `top_playlist.js` 逐字段一致。

### `lib/core/direct/kg_endpoints_home.dart:83-122` `top/playlist` 的原生实测记录自相矛盾，且已无任何兜底
- 级别：P2
- 违反：QUALITY_STANDARD 第 28/29 条（调用方式与成功形态必须可追溯到实测记录）、REVIEW_SPEC 三.1 既知约束
- 依据：本文件注释称「2026-11-06 实测 gateway + x-router 直连可用，status=1 / error_code=0」；但本仓库 `docs/api_verified.md`（2026-11-03 原生匿名态实测）仍记录 `top/playlist | ⚠️ ec=200101 | 直连不可用，保留 kapi 回退`，并在「已知端点行为」重申「直连恒 ec=200101 → 保留 kapi 回退」。`kg_direct_api_client.dart:104` 已把 `fallbackToKapi` 永久置 false，第 233 行 `case 'top/playlist'` 与第 330 行 post 分派均直接抛错，kapi 回退已不存在。本轮未做原生实测，无法裁决两份记录。
- 影响：若原生网关仍返回 200101，首页/歌单广场的推荐歌单恒失败且无兜底数据，用户看到空白或错误态；若已修复，则仅实测记录未同步。
- 证据等级：未实测（仓库内两份原生记录冲突，非 kapi 返回；第 33 条未用作判定）

### `lib/core/direct/kg_endpoints_home.dart:154-158` `yuekuBanner` 注释描述的 kapi 回退路径已不可达
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释须解释真实原因）、第 9 条（失败可观测）、第 3 条（失败返回语义）
- 依据：注释写「匿名态恒返回 error_code=31136 … 失败由 _wrap 抛出 → _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空」；但 `kg_direct_api_client.dart:104` `fallbackToKapi = false`，`_directOrFallback` 第 122–128 行在 `!fallbackToKapi` 时直接 `throw _asDioException(...)`，不会执行 `kapi()`。`evaluateResponse` 对 `status=1 + ec=31136` 判失败（非白名单码）。`kg_direct_api_client.dart:445-447` 有同样过时注释。
- 影响：匿名态首页 banner 请求不再被容错为空，而是把 `DioException` 传给上层；若上层未特判 31136，首页顶部出现常驻错误提示/重试态。
- 证据等级：静态推演（控制流为实锤；上游 31136 行为标注未实测）

### `lib/core/direct/kg_endpoints_home.dart:98-104` `topPlaylist` 忽略 `q['userid']`，且 `category_id` 空值语义与 Node 不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（参数集合/空值形态）、第 3 条
- 依据：Dart 固定 `'userid': int.tryParse(kg.userid) ?? 0`，完全不读 `q['userid']`；Node `module/top_playlist.js:23` 为 `userid: params?.userid || cookie.userid || 0`。Dart `'categoryid': q['category_id'] ?? 0` 在 `q['category_id'] == ''` 时下发空串，Node 的 `|| 0` 会落 0；`module_id/page/pagesize/withtag/withsong/sort` 同样用 `??` 而非 truthy 归一。
- 影响：上层按指定 userid 或空字符串参数请求推荐时，服务端收到不同参数集，推荐内容与所选账号/分类不一致。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_endpoints_home.dart:180-197` `videoDetail` 为无调用方的重复实现
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 1 条（单一职责）
- 依据：`KgDirectApiClient` 持有 `late final _epHome = KgEndpointHome(kg)`，但其 `get` 分派 `case 'video/detail'` 调用的是主类自实现的 `_videoDetail(q)`（`kg_direct_api_client.dart:445-472`），二者路径、参数、签名逻辑重复；`_epHome.videoDetail` 在本文件外无任何调用点。
- 影响：两份实现未来单独修改会行为分叉（一处修参数、一处仍错），MV/视频详情请求结果不可预期；当前不直接产生用户可见故障。
- 证据等级：静态推演（分派表 + 方法定义对照）

### `lib/core/direct/kg_endpoints_media.dart`（131 行，完整读 1–131）
- 复核：`kmrAudioMv` 用 `https://openapi.kugou.com/kmr/v1/audio/mv` + `KG-TID:38`；`videoUrl` 用 `https://trackermv.kugou.com/v2/interface/index`；`songUrl` 用 `https://trackercdn.kugou.com/v5/url`；`privilege` 用 gateway + `x-router: media.store.kugou.com`，均为原生域。`songUrl`/`privilege` 参数统一走 `KgSharedParams`（第 72–90、97–130 行）。
- `/v5/url` 的 `quality / free_part / hash_offset` 细节在 `kg_play_api.dart` 与 `KgSharedParams` 中集中核对。

### `lib/core/direct/kg_endpoints_media.dart:69-85` `songUrl` 注释宣称的 20028 kapi 兜底已不存在
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释解释真实行为）、第 9 条（失败可观测）
- 依据：第 79–80 行写「直连仍可能遇 20028 … `_directOrFallback` 已兜底回退 kapi」；`kg_direct_api_client.dart:104` 已把 `fallbackToKapi` 置 false，`_directOrFallback` 第 122–128 行对 `needsVerification` 更明确直接抛 `DioException`，不会调用 `kapi()`。`docs/api_verified.md` 又记录「song/url ✅ 直连无 20028」，三处口径不一致。
- 影响：若播放地址请求真命中 20028，播放器无法自动切换到可播地址，直接报错/跳过歌曲；注释误导排查方向。
- 证据等级：静态推演（控制流为实锤；20028 是否出现标注未实测）

### `lib/core/direct/kg_endpoints_media.dart:97-111` `privilege` 空 hash 返回 502 体，但 `_wrap` 只看 body 判失败码 -1
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（失败返回语义）、第 8 条（异常契约单一）
- 依据：空 hash 时返回 `KgResponse(status:502, body:{'status':0,'error_code':-1,'error':'缺少歌曲 hash'})`；`KgDirectApiClient._wrap` 只把 `r.body` 交给 `evaluateResponse`，完全忽略 `r.status`（HTTP 层），`response_policy` 以 `error_code=-1` 生成 `ApiException(-1)`，`_directOrFallback` 再包成 DioException。最终上层看到的错误码不是调用的 `-1` 之外的业务语义，而是「请求失败」类通用错误；与 Node `privilege_lite.js` 直接 reject `{status:502,error_code:-1}` 的失败对象形态不同。
- 影响：选择空 hash 曲目时音质面板收到通用网络错误，无法给出「缺少歌曲 hash」的明确提示；并可能被上层当作网络故障触发重试。
- 证据等级：静态推演（控制流 + Node 参照；未实测）

### `lib/core/direct/kg_endpoints_media.dart:20-38` `kmrAudioMv` 过滤空 id，Node 会保留空对象项
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（参数集合逐项对照）
- 依据：Dart 对 `album_audio_id` 串 split 后 `.where(e.isNotEmpty && e != 'null')`；Node `module/kmr_audio_mv.js` 为 `(params?.album_audio_id || '').split(',').map(s => ({album_audio_id:s}))`，空串时产生 `[{'album_audio_id':''}]`。Dart 在空输入时发 `data: []`，Node 发含一项的数组。
- 影响：上层未带有效 album_audio_id 时，原生网关收到不同结构的 `data`，MV 关联列表可能为空或与参照不一致。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_endpoints_playlist.dart`（288 行，完整读 1–288）
- 复核：`playlistDel` 为 AES body + RSA-PKCS1 `p` + 二进制响应解密（第 18–65 行），与 Node `playlist_del.js` 同构；`playlistDetail` 走 `https://pubsongs.kugou.com/v3/get_list_info`、`playlistTrackAll` 走 `https://pubsongs.kugou.com/v2/get_other_list_file_nofilt`；其余 cloudlist 路径走 gateway + x-router，均为原生域。
- 复核：所有歌单写端点在 `kg_direct_api_client.get()` 分派中均带 `write: true`（第 221–230 行），且本文件所有写端点都直接调 `kg.request()`，未使用 `kg.requestWithVerify()`，故验证自动重试不会重复提交。

### `lib/core/direct/kg_endpoints_playlist.dart:18-65` `playlistDel` 的 AES 二进制响应解密在 `kg_client` 里已被损坏
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（跨层返回契约：rawBytes 必须是原始响应字节）、第 29 条（返回结构须实测留样）
- 依据：`playlistDel` 从 `res.rawBytes` 取字节后 `base64Encode(bytes)` 解密；`kg_client.request()` 先执行 `final raw = utf8.decode(res.data!, allowMalformed: true)`（第 292 行）再 `jsonDecode`，解析失败时把 `raw` 截前 200 字符塞进 `body.error`，但 `KgResponse.rawBytes: res.data` 仍保留原字节，故此处解密本身可工作；**但** `kg_client.request()` 对二进制 body 请求设置了 `contentType: 'application/json;charset=utf-8'`（字符串 data 分支，第 274–277 行），而 Node `playlist_del.js` 的 `useAxios` 不声明 Content-Type（axios 对字符串默认 `application/x-www-form-urlencoded` 或不发）。同时 Node 明确 `responseType:'arraybuffer'`。头形态不一致会影响服务端按 form/JSON 解析 AES Base64 文本。
- 影响：删除/取消收藏歌单的直连请求可能被网关按错误 content-type 拒绝，`playlistDel` 解密失败后返回原始 `KgResponse`，`evaluateResponse` 把二进制乱码判失败；用户看到删除失败或需反复重试（写操作重试有重复提交风险）。
- 证据等级：静态推演（Node 源码 + `kg_client.request` 头构造对照；未实测原生网关）

### `lib/core/direct/kg_endpoints_playlist.dart:18-65` `playlistDel` 的 `uid` 用字符串 `'0'`，Node 用数值 0
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数形态/单位）、REVIEW_SPEC 三.3
- 依据：Dart `final userid = kg.userid.isEmpty ? '0' : kg.userid`，随后 `jsonEncode({'aes': aes.key, 'uid': userid, ...})` 生成 `"uid":"0"`；Node `module/playlist_del.js` 的 `userid = ... || 0`、`rsaEncrypt2({aes,uid:userid,token})` 生成 `"uid":0`。注意 `kg_client` 自己的 `_registerDeviceOnce` 明确要求 `uid` 必须是字符串 `"0"`（第 465 行），但那是 `/risk/v3/r_register_dev` 端点，不是 `/v2/delete_list`。
- 影响：`p` 解密后 uid 类型与参照不符，服务端身份绑定/校验可能失败，删除歌单无效。
- 证据等级：静态推演（Node 源码对照 + 本仓库注册端点注释区分；未实测）

### `lib/core/direct/kg_endpoints_playlist.dart:69-101` `playlistAdd` 的 `type` 归一与 Node 不一致，且缺 `is_pri` 条件分支
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数集合/空值语义）
- 依据：Dart `type = int.tryParse('${q['type'] ?? 0}') ?? 0`，随后 `type == 0` 决定 query；Node `module/playlist_add.js` 用 `params.type || 0` 判 `dataMap.type`，又用**原始** `params.type === 0` 决定 query 与 `is_pri: params.is_pri || 0`。Dart 传字符串 `'0'` 时 `type=0` 会进入新建歌单 query 分支，Node 的字符串 `'0'` 为 truthy，`dataMap.type='0'` 且 query 为空；Dart 还固定 `'is_pri': 0`，丢弃 `q['is_pri']`。`source` 固定 1，Node 允许 `source=0`。
- 影响：上层以字符串传 type/source 或要求私密歌单时，请求参数集与参照不同，新建/收藏歌单失败或得到错误可见性。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_endpoints_playlist.dart:252-288` `playlistTrackAll` 自造 `specialid` 分支，与 Node 参数集不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数集合须实测对照）、第 3 条
- 依据：Dart 在 `rawId` 不以 `collection_` 开头时改传 `specialid`；Node `module/playlist_track_all.js` 恒传 `global_collection_id: params.id`，无 `specialid` 分支。本仓库 `docs/api_verified.md` 对 `playlist/track/all` 只记录「pubsongs/v2/get_other_list_file_nofilt ✅ st=1」，未记录 specialid 参数的实测依据；文件注释「传纯数字时上游返回空」未给原生实测记录。
- 影响：数字 specialid 歌单（榜单/官方歌单）走未验证参数，上游可能返回空列表但 `status=1`，`_wrap` 判成功 → 用户看到歌单空白且无错误提示。
- 证据等级：静态推演（Node 源码 + 仓库实测记录对照；specialid 分支标注未实测）

### `lib/core/direct/kg_endpoints_playlist.dart:204-226` `playlistDetail` 抛裸 `ApiException`，异常契约与分派层不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（跨层异常形态单一）、第 3 条
- 依据：`ids.isEmpty` 与 `ids.length > 10` 直接 `throw ApiException(-2, ...)`；`KgDirectApiClient._directOrFallback` 的 `on ApiException` 分支会统一包装为 `DioException`（第 114–128 行），但本异常在 `direct()` 工厂内抛出，仍属于 `try` 作用域，能被包装；然而 `kg_direct_api_client.post()` 分派 `playlist/detail` 调用 `_playlistDetail({...q,...d})` 时若 `q/d` 为空，将先于 `super.get/post` 返回 -404 之外的裸业务错误码 `-2`，上层 `friendly_error` 等只能按通用异常处理。Node `playlist_detail.js` 对此不前置拒绝，直接发 `data: []`。
- 影响：歌单详情参数缺失时用户看到通用失败提示而非明确的「缺少歌单 id」，且空 data 请求不再有上游可观测错误。
- 证据等级：静态推演（异常链 + Node 参照；未实测）

### `lib/core/direct/kg_endpoints_search.dart`（153 行，完整读 1–153）
- 复核：搜索全部走 `https://complexsearch.kugou.com`（v3/song、v1/album、v1/{type}）、歌词 `https://lyrics.kugou.com`（`/search`、`/download`）；`searchLyric` 用 `clearDefaultParams:true + notSignature:true`（第 92–94 行），`lyric` 带 `ver:1 & charset:utf8`（第 125–132 行）。`duration` 单位换算为毫秒（第 90、103 行），与注释一致。

### `lib/core/direct/kg_endpoints_search.dart:92-108` `searchLyric` 的路径与参数集偏离 Node，且依赖注释中的原生实测记录
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（端点/参数须逐一实测对照）、第 29 条（返回结构须实测留样）
- 依据：Dart 请求 `https://lyrics.kugou.com/search` 并只在 `durationSec > 0` 时下发 `duration`，完全省略 Node `module/search_lyric.js` 固定下发的 `album_audio_id:0`、`duration:0`、`hash:''`；Node 为 `/v1/search`。文件注释给出的「/v1/search 恒空响应 + x-kg-errcode 20010；/search 返回 x-kg-errcode 200 与 candidates」属于原生实测记录，但本仓库 `docs/api_verified.md` 只记「lyric/search ✅ st=200 errcode=200」，未留 `/search` 路径与返回样本。`kg_client.request()` 对空响应体生成 `body={'status':0,'error':'响应解析失败',...}`，`evaluateResponse` 判失败，header `x-kg-errcode` 未参与成功判定。
- 影响：若原生网关仍按 `/v1/search` 语义返回空体（或需要 `duration=0` 等固定字段），歌词搜索恒失败；用户搜歌词无结果，且无 kapi 兜底。
- 证据等级：未实测（Node 参数差异为实锤；仓库内两份原生记录不完整，第 33 条：未用 kapi 返回判定）

### `lib/core/direct/kg_endpoints_search.dart:136-147` `decode=true` 时 KRC 内容未解密
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（返回契约：decodeContent 字段形态）、REVIEW_SPEC 三.4
- 依据：`lyric(decode:true)` 只在 `fmt == 'lrc' || contenttype != '0'` 时做 `base64.decode`；Node `module/lyric.js:23-26` 对 `contenttype == 0` 的 KRC 明确调用 `decodeLyrics(res.body.content)`（跳过前 4 字节、XOR 固定密钥、zlib 解压）。Dart 在 `contenttype == '0'` 且 `fmt == 'krc'`（默认 fmt）时不写 `decodeContent`。`kg_client.request()` 第 292 行还把响应体按 `utf8.decode(allowMalformed:true)` 再 `jsonDecode`，`/download` 的 KRC 二进制/Base64 内容在 JSON 内不受影响，但后续无 XOR/inflate 实现。
- 影响：逐字 KRC 歌词下载后上层拿不到解码文本，播放器只能显示无歌词/空白，逐字滚动功能失效。
- 证据等级：静态推演（Node 源码 + 本文件分支；未实测原生返回）

### `lib/core/direct/kg_endpoints_search.dart:121-124` `lyric` 参数缺失时抛裸 `ApiException`，与上层 DioException 契约不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）
- 依据：`lyric()` 直接 `throw ApiException(-1, '歌词下载参数缺失（id/accesskey）')`；`KgDirectApiClient._directOrFallback` 的 `catch (e)` 分支（第 137–155 行）会包装成 DioException，但其 `on ApiException` 分支（第 115–128 行）也会包装，形态最终一致；问题在于 `kg_direct_api_client.get` 的 `case 'lyric'` 把 `direct()` 作为工厂传入，`try` 内能捕获，所以最终形态是 DioException。此项经复核**不构成契约破坏**，仅记录为已核对项，不列为问题。
- 证据等级：静态推演

### `lib/core/direct/kg_media_direct.dart`（89 行，完整读 1–89）
- 复核：`images` 用 `https://expendablekmr.kugou.com` 原生域 + `clearDefaultParams:true + notSignature:true`，签名 `KgSignature.android(params)` 后以 `signature` 放 query（第 36–49 行）；`videoDetail` 用 gateway + `x-router: kmr.service.kugou.com` + `clearDefaultParams:true`（第 61–87 行），与 Node `video_detail.js` 一致。

### `lib/core/direct/kg_media_direct.dart:15-49` `images` 的 query 编码/签名输入与 Node 不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 28 条（签名位置、参数序列化与 URL 编码形态须实测对照）
- 依据：Node `module/images_audio.js` 先按 key 排序、对 `JSON.stringify(data)` 做 `encodeURIComponent` 生成 query，再以**未编码的 paramsMap** 调 `signatureAndroidParams(paramsMap)`，最后把 `signature` 作为唯一 `params` 交给 `useAxios`（`notSign:true, clearDefaultParams:true`）。Dart 用 `KgSignature.android(params)` 签名时 `params['data']` 是 `List<Map>`，其 `jsonEncode` 结果进入 MD5；随后 `Uri(queryParameters:q).query` 对 `data` 的 JSON 字符串做**百分号编码**并按键重新排序，把 `signature` 也放入同一个 query。二者「签名输入」一致（未编码 JSON），但 Node 的 URL 里 `data` 是 `encodeURIComponent` 编码、键按字典序，Dart 的 `Uri` 编码对 `/`、空格、`+` 等字符处理与 `encodeURIComponent` 不同（Dart 默认不编码 `/`，`encodeURIComponent` 编码 `%2F`）；且 `Uri` 未保留 Node 的排序（Map 插入序 appid→clientver→count→data→… 恰好已排序，signature 追加在末尾）。
- 影响：封面图接口因 query 编码差异被网关解析成不同参数值/签名校验失败，歌曲封面批量查询返回空或错误，列表封面空白。
- 证据等级：静态推演（Node 源码逐行对照；未实测原生网关）

### `lib/core/direct/kg_media_direct.dart:19-31` `images` 的 data 项字段集与 Node 不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（参数集合）
- 依据：Dart 每项为 `{hash, album_id, album_audio_id}`；Node `module/images_audio.js` 每项为 `{audio_id, hash, album_audio_id, filename}`，且 `album_id` 由 `params.audio_id` 拆分填入 `audio_id` 键。Dart 的 `albumId` 参数被写成 `album_id`，`filename`/`audio_id` 缺失，签名输入与 query 内容都与参照不同。
- 影响：上游按 `audio_id/filename` 定位封面时拿不到匹配项，返回空 data；用户看到封面占位图。
- 证据等级：静态推演（Node 源码对照；未实测）

### `lib/core/direct/kg_play_api.dart`（495 行，完整读 1–495）
- 复核：`/v5/url` 走 `https://trackercdn.kugou.com` 原生域，`KgSharedParams.songUrl` 中 `hash` 小写、`key=signKey(hash,mid,userid,appid)`、`IsFreePart` 试听开关、`quality` 魔法档补 `magic_` 前缀、蝰蛇档原样、`clienttime` 由 `kg_client` 秒级注入（第 166–200 行）；`privilege` 的 `need_hash_offset:1`、`resource[].page_id:0`、`qualities` 恒完整表（第 232–252 行）与 Node `privilege_lite.js` 一致；`PlayUrlResult.fromResponse` 读取 `hash_offset{start_ms,end_ms,clip_hash,start_byte,end_byte,offset_hash}`（第 366–405 行），试听判定用区间时长 ≤65s 或 `/p_0_`（第 414–417 行）。
- 复核：`KgPlayApi.songUrl/privilege` 用 `client.requestWithVerify`（第 44、72 行），两个端点均为 GET/读操作，自动重试不产生重复提交。

### `lib/core/direct/kg_play_api.dart:38-58` `songUrl` 的「无 signature 实测驳回」注释引用的 `notSign` 结论与 Node 源码不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（调用方式须以可追溯实测记录为准）
- 依据：注释称 Node `util/request.js` 只认 `notSignature`，`notSign` 拼写不生效，故 `/v5/url` 实际带签名；而 `module/song_url.js` 确实写 `notSign: true`，`util/request.js:190` 用 `!options.notSignature` 判断，拼写不生效属实。但 `Module song_url_auth.js` 也用 `notSign`，且 `KgSharedParams.songUrl` 的 `clientver=11430`、`version=11430` 与 `song_url.js` 一致；注释引用的实测记录位于 `docs/batch4_fix_1_network.md`，本任务禁止读历史审查报告，无法复核该原生 curl 记录。本项仅标注仓库内可追溯性缺口。
- 影响：若实测记录不可复核，后续维护可能再次误删 signature 导致 `/v5/url` 返回 20006；用户播放全部失败。
- 证据等级：未实测（Node 拼写事实为实锤；原生 curl 记录按规则未读）

### `lib/core/direct/kg_play_api.dart:82-94` `privilege` 的输出未按 hash 与请求顺序对齐
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回契约/顺序语义）、第 23 条（缓存键维度）
- 依据：Dart 对 `res.body['data']` 的每条记录再对 `wanted` 每档生成 `PrivilegeItem`，结果为「上游返回顺序 × 音质档」的扁平列表；Node `module/privilege_lite.js:180-190` 明确按 `hashList.map((hash,index) => ...)` 用请求 hash 顺序，并在 `data.find(hash)` 匹配不到时回退 `data[index]`，输出 `quality_vip` 数组每项对应一个 hash。Dart 既未按请求 hash 对齐，也未给 `PrivilegeItem` 标注「缺档」（多 hash 时条目数与顺序与调用方期望不符）。
- 影响：批量查询权益时上层按 index 取用会张冠李戴（A 歌的 VIP 判定套到 B 歌），音质按钮显示错误或播放被错误拦截。
- 证据等级：静态推演（Node 源码对照；未实测上游返回顺序）

### `lib/core/direct/kg_play_api.dart:215-252` `privilege` 忽略 `qualities` 入参，恒下发完整上游表
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（输入取值范围契约）、第 30 条（命名即文档）
- 依据：方法签名 `qualities` 被注释说明为「输出过滤需求」，但 `KgSharedParams.privilege(... qualities: qualities)` 的实现（第 215、232–252 行）完全未读取 `qualities`，恒返回 `upstreamQualities`。`KgPlayApi.privilege` 第 84 行又把同一 `qualities` 当作 `wanted` 输出过滤。两处语义不同名，调用方传 `'all'` 或单档时上游请求不变。
- 影响：请求单档权益时仍下发 9 档全表，响应体积与解析量增大；`all` 与默认无差别，用户感知为音质面板加载偏慢。
- 证据等级：静态推演（本文件参数流；未实测）

### `lib/core/direct/kg_providers.dart`（109 行，完整读 1–109）
- 复核：`kgClientProvider` 注入 `onDfidRegistered`，注册成功写 Hive `device` box 并 fire-and-forget 同步 SecureStorage（第 85–100 行）；`kgPlayApiProvider` / `kgDirectApiProvider` 都 `ref.watch(kgClientProvider)`，未 new 裸 `KugouApiClient()`；`lib/app/di.dart` 的 `kugouApiClientProvider` 返回 `kgDirectApiProvider`。
- 复核：`PlayerRepository.ensureDfid` 走 `_api.get('/register/dev')`（即直连注册），成功后写 SecureStorage + `kgClientProvider.device.dfid` + `KgDeviceStore.saveDfidSync`（`player_repository.dart:78-118`）；`KgDirectApiClient.setCredentials` 另写 `kg.dfid`/`kg.device.dfid`/CookieJar（`kg_direct_api_client.dart:43-50`），dfid 三写链在主要路径上闭合。

### `lib/core/direct/kg_providers.dart:85-99` dfid 注册回调只写 Hive/SecureStorage，未写 `kg.dfid` 与父类 CookieJar
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 27 条
- 依据：`onDfidRegistered` 回调只调用 `KgDeviceStore.saveDfidSync(dfid)` 与 `SecureStorage.instance.saveDfid(dfid)`；`KgClient` 有独立字段 `dfid`（`kg_client.dart:190`），`KugouApiClient` 有 `dfid` 字段及 CookieJar（`kugou_api_client.dart:150,174`），二者在 `KgDirectApiClient.setCredentials` 才被写入。原生注册路径 `kg.registerDevice()` → `device.dfid` + `_persistDfid()` 触发本回调，不会再调 `setCredentials`。`PlayerRepository.ensureDfid` 额外写 `device.dfid`/Hive/SecureStorage，同样不写 `kg.dfid`/CookieJar。
- 影响：注册后 `KugouApiClient.dfid` 与 CookieJar 仍为空串；登录恢复 `restoreSession` 用 `cred.dfid`（可能为空）覆盖 `device.dfid`，设备标识在冷启动后回退，触发风控/播放降权。
- 证据等级：静态推演（provider + `kg_client` + `auth_repository` + `player_repository` 全链；未实测冷启动）

### `lib/core/direct/kg_providers.dart:91-97` SecureStorage 的 dfid 写入是 fire-and-forget，无完成确认
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（生命周期/资源对称）、第 5 条
- 依据：`onDfidRegistered` 是同步 `void Function(String)` 回调，内部 `SecureStorage.instance.saveDfid(dfid).catchError(...)` 不 await；`KgClient.registerDevice()` 随即返回 true，`KgEndpointAuth.registerDev()` 立刻构造成功响应。进程被杀或用户立即触发登录时，SecureStorage 可能尚未落盘；注释本身承认「异步 put 不保证在进程被杀前完成」。`AuthRepository.restoreSession` 以 SecureStorage 的 `cred.dfid` 为准调 `setCredentials` 覆盖 `device.dfid`。
- 影响：注册成功后立刻退出/切号，下次冷启动拿到旧/空 dfid 覆盖新值，播放与登录签名用错设备标识，出现 20028 或试听降权。
- 证据等级：静态推演（异步链 + 恢复链；未实测）


---

## 复核校正（本节结论覆盖上文对应条目）

逐条回读上层调用链（`player_repository.dart`、`auth_repository.dart`、`auth_providers.dart`、`verification_service.dart`、`home_repository.dart`、`lyric_repository.dart`、`krc_decoder.dart`、`rank_repository.dart`、`playlist_repository.dart`、`mv_collection_repository.dart`、`cached_api.dart`、`repository_reads.dart`、`app/di.dart`、`response_policy.dart`、`kugou_api_client.dart`、`secure_storage.dart`）后，对上文条目作如下校正。只保留有代码事实支撑者，其余撤回或降级。

- **保留 P1（4 条）**：`kg_direct_api_client.dart:84-88` 与 `kg_endpoints_comment.dart:43-64`（同一根因的两处落点，均保留）；`kg_client.dart:405-419` 验证链断；`kg_endpoints_auth.dart:393-418` 登录成功码形态。
- **新增 P1（1 条）**：`kg_crypto.dart:165-205` 二进制 MV 收藏端点误选无填充 RSA（下详，见「补充问题」）。
- **降级 P1→P3**：`kg_endpoints_search.dart:136-147`「KRC 未解密」——Node `module/lyric.js` 在 `contenttype != 0` 时同样只做 Base64 解码，Dart 行为一致；`contenttype == 0` 时 Dart 不写 `decodeContent`，但 `LyricRepository._fetchLyricByFormat` 会回退到 `KrcDecoder.decodeDetailed(raw)`（`krc_decoder.dart:33-84`，跳过 krc1 头 + 16 字节 XOR + zlib），与 Node `decodeLyrics` 等价。链路闭环，撤回用户可见后果，仅记为契约表述差异。
- **降级 P1→P3**：`kg_media_direct.dart:15-49`、`kg_media_direct.dart:19-31` —— `KgMediaDirect` 全仓仅 1 个文件引用（即声明文件本身），`images()`/`videoDetail()` 无调用方，参数差异当前不可达用户路径，合并为一条死代码问题。
- **降级 P1→P2**：`kg_endpoints_playlist.dart:18-65`「二进制响应解密已损坏」的表述自相矛盾，重写为「字符串 body 的 Content-Type 与 Node 不一致」（`rawBytes` 实际保留原字节，解密本身可工作）。
- **降级 P1→P3**：`kg_client.dart:227-243`「Uint8List 签名 data 为空串」——当前唯一二进制 body 调用方 `mv_collection_repository.dart:118-130` 传 `notSignature: true`，签名分支不执行，缺陷不可达；保留为潜在契约缺陷。
- **降级 P1→P2**：`kg_direct_api_client.dart:299-366`「post 分派表缺路径」——核对后当前 POST 调用方仅 `rank/audio`（`rank_repository.dart`）、`login`、`verify/user/info`、评论写三件套，全部在 post 表内；`CachedApiCall.post`/`MusicApi.write` 无调用方。无当前用户可见故障，降为契约缺口。
- **降级 P2→撤回**：`kg_endpoints_media.dart:97-111`「空 hash 错误文案丢失」——`response_policy.msgOf()` 优先读 `body['error']`，`'缺少歌曲 hash'` 会被完整带进 `ApiException.message`，无后果。
- **降级 P2→撤回**：`kg_endpoints_playlist.dart:204-226`「裸 ApiException 破坏契约」——异常在 `direct()` 工厂调用时抛出，处于 `_directOrFallback` 的 `try` 内，被 `on ApiException` 包装为 DioException，形态一致。
- **降级 P2→撤回**：`kg_direct_api_client.dart:304-315`「write:true 未覆盖 captcha/sent 等」——`fallbackToKapi=false` 且这些端点均未用 `requestWithVerify`，不存在重复提交路径；转入「复核通过项」。
- **降级 P2→P3**：`kg_endpoints_home.dart:83-122`「top/playlist 无兜底」——`HomeRepository.fetchTopPlaylists` 捕获异常后回落原生 `/yueku`，并非无数据；仅剩实测记录未同步。
- **降级 P2→P3**：`kg_endpoints_home.dart:154-158`「banner 常驻错误」——`HomeRepository.fetchBanners` 捕获全部异常并 `debugPrint` 后返回空列表，行为符合设计；仅注释失真。
- **降级 P2→P3**：`kg_endpoints_media.dart:69-85`「song/url 20028 无兜底」——`PlayerRepository._resolveViaDirect` 在 20028 时 `break` 并抛带 ssaCode 的 ApiException 交 UI 验证流程；仅注释失真。
- **降级 P2→P3**：`kg_endpoints_auth.dart:86-91`「lite 盐」——全仓 `kg.lite` 无任何写入方，恒为 false，分支不可达（lite 相关分支同时为死代码）。
- **降级 P2→P3**：`kg_endpoints_artist_album.dart:108-118`、`:121-139`「is_buy 形态」——`AlbumRepository.fetchDetail/fetchSongs` 均不传 `is_buy`，差异不可达。
- **降级 P2→P3**：`kg_endpoints_playlist.dart:69-101`「playlistAdd type 归一」——`PlaylistRepository.collectPlaylist` 传 int 0/1 且不传 `is_pri/source`，差异不可达；但 `uid` 字符串问题（`:18-65`）保留 P2。
- **降级 P2→P3**：`kg_play_api.dart:82-94`「privilege 输出顺序」——`KgPlayApi.privilege` 在 `lib/features` 无调用方（`kgPlayApiProvider` 只用于 `songUrl`），结果不可达；与 `:215-252` 合并为死代码/契约项。
- **降级 P2→P3**：`kg_crypto.dart:213-243`「显式 key/iv 返回空 key」——B2 范围内三处 `aesEncryptHex` 调用均不传 key/iv，分支不可达。
- **降级 P2→P3**：`kg_providers.dart:91-97`「fire-and-forget」——`PlayerRepository.ensureDfid` 与 `AuthRepository.getDfid/_handleLoginSuccess` 都会显式 `await` 写 SecureStorage，回调里的写入是冗余二次写；残留风险降为整洁度。
- **降级 P2→P2（保留，措辞校正）**：`kg_endpoints_auth.dart:37-51`、`kg_providers.dart:85-99` dfid 三写——承认 `AuthRepository.restoreSession`/`_handleLoginSuccess` 会调 `KgDirectApiClient.setCredentials` 补齐 `kg.dfid`+`device.dfid`+CookieJar；问题收窄为「直接调用 `/register/dev` 的那一次会话内，直到下一次 setCredentials 之前，`kg.dfid` 与 CookieJar 仍是旧值」。
- **撤回**：`kg_endpoints_search.dart:121-124`（原文已标注「不构成契约破坏」，不计入问题清单）。
- **补充**：`edt_generator.dart` 与 `KuGouMusicApi/util/generate_simulate.js`（351 行完整读）逐行对照结论：明文格式、固定 IV、AES-128-CBC/PKCS7、RSA-OAEP SHA-256/MGF1-SHA256、哨兵 `0xffffffff - floor(random*20)`、贝塞尔 n+1 点、抖动 `max(0.5, 3-t*2.5)`、`_randomString` 的 `ceil((len-1)*random())` 偏斜、`ts=Date.now()` 毫秒均一致；唯一差异是 Node 对 webglHash 缺省调 `generateWebGLHash()`，Dart 由调用方必传（`verification_service.dart:41-49` 传 `_api.webglHash`，常量 `11664606328242161144`）。本文件无问题。

## 补充问题（复核后新增）

### `lib/core/direct/kg_crypto.dart:165-205` 二进制 MV 收藏端点误选无填充 RSA
- 级别：P1
- 违反：QUALITY_STANDARD 第 28 条（RSA 填充形态须逐一实测对照）、第 3 条（跨层契约）
- 依据：`KgCrypto` 同时提供 `rsaEncryptPkcs1`（`PKCS1Encoding(RSAEngine())`，对应 Node `rsaEncrypt2`）与 `rsaEncryptRawHex`（右补零 `modPow`，对应 Node `cryptoRSAEncrypt`）。B2 内 `kg_client._registerDeviceOnce` 与 `kg_endpoints_playlist.playlistDel` 都正确选了 `rsaEncryptPkcs1`；但唯一发二进制 body 的调用方 `mv_collection_repository.dart:108-112` 用 `KgCrypto.rsaEncryptRawHex(...).toUpperCase()` 生成 query `p`，而 Node `module/mv_collect_del.js:16` 用 `rsaEncrypt2(...).toUpperCase()`（PKCS1-v1_5）。同一加密协议族内填充形态不一致，服务端无法解出 `{aes,uid,token}`。
- 影响：收藏/取消收藏 MV 的直连请求被拒；该仓库在 `setCollected` 解密失败后以 `res.status == 200` 兜底返回 true，用户看到「已收藏/已取消」但服务端状态未变。
- 证据等级：静态推演（Node 源码 + 调用方填充选择 + 本文件两个函数实现；未实测原生网关）

### `lib/core/direct/kg_client.dart:302-317` `KgResponse` 对二进制响应只给 rawBytes，不校验解密后的业务状态
- 级别：P2
- 违反：QUALITY_STANDARD 第 29 条（返回结构须实测留样，成功判定逐端点确认）、第 3 条
- 依据：`request()` 对非 JSON 二进制响应生成 `body={'status':0,'error':'响应解析失败',...}` 并把原字节放 `rawBytes`，不解析业务体。B2 内 `kg_endpoints_playlist.playlistDel` 解密后要求 `decoded.containsKey('status')` 才替换 body（第 54–60 行）；但 `mv_collection_repository.dart:134-145` 只判断「解密不抛异常」即 `return true`，不看 `decrypted['status']`，且失败时以 HTTP 200 兜底为成功。同一二进制返回契约在两个写端点上语义不一致。
- 影响：MV 收藏在服务端返回 `status=0` 的业务失败时仍被判成功，UI 收藏态与服务端不一致且不会提示重试。
- 证据等级：静态推演（本文件 + 两处调用方分支；未实测原生存留样）

### `lib/core/direct/kg_endpoints_home.dart:180-197` / `lib/core/direct/kg_direct_api_client.dart:445-472` 两份 `videoDetail` 均为未接线实现
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 1 条（单一职责）
- 依据：`KgDirectApiClient.get/post` 的 `case 'video/detail'` 调用主类自实现 `_videoDetail(q)`；`KgEndpointHome.videoDetail` 与 `KgMediaDirect.videoDetail` 各自再写一份同构实现，均无调用点。`dart analyze` 对 `kg_direct_api_client.dart` 另报 6 个 `unused_element/unused_field` 警告（见下）。
- 影响：三份实现未来单独修改会行为分叉；当前不产生用户可见故障。
- 证据等级：静态推演（分派表 + 方法定义 + analyze 输出）

### `lib/core/direct/kg_media_direct.dart:15-87` 整个 `KgMediaDirect` 扩展无调用方
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：全仓仅本文件出现 `KgMediaDirect`；`images()` 无任何 `.images(` 调用点，`videoDetail()` 亦无。其 `images` 与 Node `module/images_audio.js` 的参数集差异（`{hash,album_id,album_audio_id}` vs `{audio_id,hash,album_audio_id,filename}`）与 `Uri(queryParameters:)` / `encodeURIComponent` 编码差异因此不可达。
- 影响：无当前用户可见后果；死实现会在后续被误接入时直接产生封面空白。
- 证据等级：静态推演（调用点统计 + Node 源码对照）

## 问题清单（按级别排序，共 30 条：P0=0 / P1=5 / P2=13 / P3=12）

### P1（5）
1. `kg_direct_api_client.dart:84-88` — `_wrap`→`evaluateResponse` 后无 `status` 裸 Map 必判失败（迁移行为不等价）。
2. `kg_endpoints_comment.dart:43-64` — `/comment/count` 原生实测裸 Map `{"hash":710442}` 因此恒失败。
3. `kg_client.dart:405-419` — `submitFingerprintVerification` 把 sid/edt 发给「取验证信息」端点，验证重试链断在第一步。
4. `kg_endpoints_auth.dart:393-418` — `_afterLogin` 只认 `int 1`，字符串/浮点成功码不落 token/t1/VIP。
5. `kg_crypto.dart:165-205` — 二进制 MV 收藏误用无填充 RSA（对照 Node `rsaEncrypt2`）。

### P2（13）
6. `kg_client.dart:408` — 验证请求 `clientver=20489/11440`，Node `verify_user_info.js` 为 11510。
7. `kg_client.dart:266-277` — `Uint8List` 分支 `contentType` 与调用方声明的 `application/json` 并存，Node 只发 `application/json`。
8. `kg_client.dart:281-289` — `DioException` 折成 502 业务体，网络异常与业务失败不可区分。
9. `kg_client.dart:302-317` — 二进制响应只给 rawBytes，MV 收藏以「解密不抛异常」当业务成功。
10. `kg_crypto.dart:61-69` — `KgSignature.android/web` 对 Map/List 值的序列化与 Node `JSON.stringify` 不保证一致。
11. `kg_direct_api_client.dart:299-366` — post 分派表缺 get 表中 20+ 路径，当前无调用方命中但契约不完整。
12. `kg_endpoints_comment.dart:91-195` — 评论写端点 `clienttime` 头来自 `kg_client` 第二次取时，与 query/key 的 clienttime 不同源。
13. `kg_endpoints_search.dart:92-108` — `/search`（歌词）路径与固定参数集偏离 Node，仓库内原生实测留样不完整。
14. `kg_endpoints_playlist.dart:18-65` — `playlistDel` 字符串 AES body 的 Content-Type 与 Node 不一致。
15. `kg_endpoints_playlist.dart:18-65` — `playlistDel` 的 `p` 里 `uid` 为字符串 `'0'`，Node 为数值 0。
16. `kg_endpoints_playlist.dart:252-288` — 自造 `specialid` 分支，Node 与仓库实测记录均无依据。
17. `kg_endpoints_auth.dart:37-51` + `kg_providers.dart:85-99` — 原生注册只写 `device.dfid`/Hive/SecureStorage，`kg.dfid` 与 CookieJar 要等下一次 `setCredentials` 才同步。
18. `kg_endpoints_auth.dart:286-302` — 二维码 `status=4` 只写 token/userid，不写 t1/vipType/vipToken（上层 `loginByQrToken` 再走 `/login/token` 只能部分补齐）。

### P3（12）
19. `kg_client.dart:227-243` — `Uint8List` 签名 data 为空串（当前二进制调用方 `notSignature:true`，不可达）。
20. `kg_crypto.dart:213-243` — `aesEncryptHex(key:,iv:)` 返回 `key:''`，且函数名与实际 Base64 输出不符。
21. `kg_direct_api_client.dart:91-98` — 迁移后遗留 `_hasData`（analyze: unused_element）。
22. `kg_play_api.dart:38-58` — `/v5/url` 保留 signature 的实测依据指向禁止阅读的历史报告，可追溯性缺口。
23. `kg_play_api.dart:82-94,215-252` — `KgPlayApi.privilege` 无调用方，`qualities` 入参在 `KgSharedParams.privilege` 中完全未被读取。
24. `kg_endpoints_artist_album.dart:108-139,157-165` — `is_buy` 形态归一与 `rank_cid` 透传与 Node 不一致（当前调用方不传，不可达）。
25. `kg_endpoints_home.dart:83-122` — `top/playlist` 直连可用/恒 200101 两份原生记录冲突且注释引用历史报告。
26. `kg_endpoints_home.dart:98-104` — `topPlaylist` 丢弃 `q['userid']`，`??` 与 Node `||` 空值语义不同。
27. `kg_endpoints_home.dart:154-158` / `kg_endpoints_media.dart:69-85` — 两处注释仍描述「回退 kapi」，而 `fallbackToKapi=false` 已使该路径不可达。
28. `kg_endpoints_comment.dart:265-300` — `commentFloor` 下发空 `mixsongid`、忽略显式 `code`。
29. `kg_endpoints_media.dart:20-38` — `kmrAudioMv` 过滤空 id，Node 保留空对象项。
30. `kg_endpoints_playlist.dart:69-101` / `kg_endpoints_auth.dart:86-91` / `kg_providers.dart:91-97` / `kg_endpoints_home.dart:180-197` / `kg_media_direct.dart:15-87` — 归一差异与死代码/重复实现（含 lite 恒 false 分支、fire-and-forget 冗余写、`videoDetail` 三份实现、整个 `KgMediaDirect` 扩展）。

## 复核通过项（本范围确认到位的设计，共 14 项）

1. **原生网关唯一**：`lib/core/direct` 14 文件内 `344977` 出现 0 次；所有 `baseUrl` 字面量均为 `*.kugou.com`（gateway / userservice / verifyservice / login-user / loginserviceretry / trackercdn / trackermv / openapi / pubsongs / complexsearch / lyrics / msearch / ocean / musicadservice / expendablekmr / collectservice 路由），`h5.kugou.com` 仅作二维码 URL 内容不是请求基址。`KgConfig.gateway/registerGateway` 无 kapi 域。
2. **kapi 仅参考**：`fallbackToKapi = false` 使 `super.get/post`（`AppConfig.kugouApiBase`）在所有分派与未分派路径都不可达；未移植路径显式抛 `-404`，并写明「kapi 仅作参考，运行期不调用」。第 27 条满足。
3. **三盐与签名位置**：android `OIlwieks28dk2k092lksi2UIkp`、lite `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`、web `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`、register `1014` 齐全；`signature` 统一进 `allParams` → `queryParameters`（非 header）；`signParamsKey = md5(appid+salt+clientver+data)`，`clienttime` 全为 `~/1000` 秒级。
4. **clearDefaultParams 白名单**：仅 `/index.php`×3（评论写）、`/v1/video`、`/search`（歌词）、`images` 使用；`artistAudios`/`rankAudio` 明确不开，与 `docs/api_verified.md`「签名需 defaultParams+body 合并」一致。
5. **edt_generator 与 Node 逐行一致**：AES-128-CBC 固定 IV `kugousecurity123`、PKCS7、RSA-OAEP SHA-256/MGF1-SHA256、哨兵、行为事件序列、毫秒 ts、webgl 由调用方注入。M2 下沉后无行为漂移。
6. **`/v5/url` 参数完整**：`hash` 小写、`key=signKey(hash,mid,userid,appid)`、`IsFreePart`、`page_id/pid/ppage_id` 按 lite 分流、`version/clientver=11430`、`quality` 魔法档补 `magic_` 前缀而蝰蛇档原样、`need_hash_offset` 在 privilege body 中恒为 1；`PlayUrlResult` 完整读取 `hash_offset{start_ms,end_ms,clip_hash,start_byte,end_byte,offset_hash}`，试听判定用区间时长 ≤65s 或 `/p_0_`，单位标注为 ms/byte。与 `module/song_url.js`、`privilege_lite.js` 逐字段一致。
7. **7 个端点域文件的域/路径/头**：artist_detail/audios 落 `openapi.kugou.com` 且 audios 保持 v1 + `kg-tid:220`；rank/audio 保持 `/openapi/kmr/v2/rank/audio` + `kg-tid:369`；pubsongs 去掉 gateway 前缀；search 走 complexsearch v3/song；lyrics `/download` 带 `ver:1&charset=utf8`；评论走 `x-router: m.comment.service.kugou.com`，计数走 `sum.comment.service.kugou.com` + web 签名；均与 Node module 与 `docs/api_verified.md` 一致。
8. **二进制 body 与 RSA 填充（主路径）**：`KgClient` 有 `Uint8List` 直传分支并保留 `rawBytes`；设备注册响应 `base64.encode(raw)` → `aesDecryptPlaylistB64(base64, aes.key)`，`md5(seed)[:16]/[16:32]` 派生与 Node `playlistAesEncrypt/Decrypt` 一致；`_registerDeviceOnce` 与 `playlistDel` 均用 PKCS1-v1_5（`rsaEncryptPkcs1`），登录 `pk` 用无填充 `rsaEncryptRawHex` 与 Node `cryptoRSAEncrypt` 一致；注册 `p` 为小写 hex、`uid` 为字符串 `"0"`、`platid=2`、签名含 body。
9. **写操作防重**：所有评论写与歌单写在 `get/post` 分派中均 `write: true`；`_directOrFallback` 对 `write` 与 `needsVerification`/`20034` 直接抛包装异常，不回退；本范围所有写端点都直接 `kg.request()`，无一使用 `requestWithVerify`，验证自动重发不会重复提交；`PlaylistRepository._write` 另有 `_inFlight` 进程内去重与 `maybeSucceeded` 语义。
10. **dfid 三写在主链路闭合**：`KgDirectApiClient.setCredentials` 同时写 `kg.dfid`、`kg.device.dfid` 与父类 CookieJar；`kgClientProvider.onDfidRegistered` 写 Hive `device` box 并同步 SecureStorage；`PlayerRepository.ensureDfid` 写 SecureStorage + `device.dfid` + Hive；`AuthRepository.restoreSession/_handleLoginSuccess` 再经 `setCredentials` 补齐；`SecureStorage.clearCredentials` 有意保留 dfid（设备级而非账号级）。
11. **`_wrap` 迁移单点**：`KgDirectApiClient._wrap` 与 `KugouApiClient` 响应拦截器都只调 `evaluateResponse`，成功/失败/20028 判定统一；`ApiException` 定义与 `kVerificationRequired` 收敛在 `core/foundation`，`requiresVerification` 为全仓唯一出口。
12. **异常契约**：`_directOrFallback` 把直连/回退异常统一包装为 `DioException(error: ApiException)`，`TypeError/NoSuchMethodError` 明确 rethrow；`KgDirectApiClient.get/post` 未命中分派也走同一包装；`AuthRepository`/`verification_service` 的 `DioException.error` 读取链成立。
13. **装配注入**：`kgPlayApiProvider`/`kgDirectApiProvider` 都 `ref.watch(kgClientProvider)`，`app/di.dart` 的 `kugouApiClientProvider` 返回 `kgDirectApiProvider`；B2 范围内无 `new KugouApiClient()`；`AppConfig.kugouApiBase` 未在 direct 中出现。
14. **第 33 条遵守**：本报告全部判定依据为 Dart 源码、`docs/QUALITY_STANDARD.md`/`REVIEW_SPEC.md`/`api_verified.md`（原生 curl 记录）与 Node `module/*.js`/`util/*.js` 源码；未读取任何 kapi 返回、未启动 kapi/Node 服务、未据 kapi 包装结果修改任何参数结论。

## 逐文件 `dart analyze` 结果

环境：`export PATH=$PATH:/opt/dart/bin`（Dart SDK 3.13.7 stable），命令 `dart analyze lib/core/direct/<file>`，逐文件独立执行。项目无 `.dart_tool/package_config.json`，故 `package:dio/*`、`package:flutter/*`、`package:qr_flutter/*`、`package:hive/*`、`package:flutter_riverpod/*`、`package:pointycastle/*` 全部报 `uri_does_not_exist` 及其派生的 `undefined_*`/`non_type_*`，属任务书允许的「Flutter/三方包符号缺失预期噪音」。下表「项目自有类错误」均为 0。

| # | 文件 | 原始输出 | 噪音（三方包缺失及派生） | 项目自有类错误 | 结论 |
|---|---|---|---|---|---|
| 1 | `edt_generator.dart` | 25 issues | 25（`pointycastle/asn1.dart`、`export.dart` + MD5Digest/OAEPEncoding/RSAPublicKey 等派生） | 0 | 通过 |
| 2 | `kg_client.dart` | 12 issues | 12（`dio/dio.dart` + Dio/BaseOptions/Response/Options/DioException 派生） | 0 | 通过 |
| 3 | `kg_crypto.dart` | 55 issues | 55（pointycastle 两个 URI + ASN1/PaddedBlockCipher/PKCS1Encoding 等派生） | 0 | 通过 |
| 4 | `kg_direct_api_client.dart` | 15 issues | 8 error（dio/flutter/qr_flutter 三个 URI + debugPrint/DioException/RequestOptions 派生）；7 warning 为项目自有告警：`_hasData`/`_commentCodeOf`/`_maskMobile`/`_qrPngBase64`/`_afterLogin` unused、`_qrSrcappid` unused_field、`:166` dead_code | 0 | 通过（告警已计入 P3 第 21 条） |
| 5 | `kg_endpoints_artist_album.dart` | 2 issues | 0（2 条均为项目自有 `unused_import`：`dart:convert`、`kg_direct_api_client.dart`） | 0 | 通过 |
| 6 | `kg_endpoints_auth.dart` | 5 issues | 5（flutter/foundation、qr_flutter URI + debugPrint/QrPainter/QrVersions 派生） | 0 | 通过 |
| 7 | `kg_endpoints_comment.dart` | 1 issue | 0（1 条项目自有 `unused_import`：kg_direct_api_client.dart） | 0 | 通过 |
| 8 | `kg_endpoints_home.dart` | 2 issues | 0（2 条项目自有 `unused_import`：dart:convert、kg_direct_api_client.dart） | 0 | 通过 |
| 9 | `kg_endpoints_media.dart` | 2 issues | 0（2 条项目自有 `unused_import`：dart:convert、kg_direct_api_client.dart） | 0 | 通过 |
| 10 | `kg_endpoints_playlist.dart` | 1 issue | 0（1 条项目自有 `unused_import`：kg_direct_api_client.dart） | 0 | 通过 |
| 11 | `kg_endpoints_search.dart` | 1 issue | 0（1 条项目自有 `unused_import`：kg_direct_api_client.dart） | 0 | 通过 |
| 12 | `kg_media_direct.dart` | `No issues found!` | 0 | 0 | 通过 |
| 13 | `kg_play_api.dart` | 1 issue | 0（1 条项目自有 `unused_import`：`../domain/quality.dart`） | 0 | 通过 |
| 14 | `kg_providers.dart` | 14 issues | 14（flutter/foundation、flutter_riverpod、hive 三个 URI + Box/Hive/Provider/debugPrint 派生） | 0 | 通过 |

合计：14/14 文件已逐文件执行并贴出结果；过滤三方包噪音后**项目自有类错误 0**（任务书判定为通过）；项目自有 warning 共 16 条（15 条 unused/1 条 dead_code，均为 `dart analyze` 静态告警，不计为错误）。

## 未做项与证据边界

- 未做原生 `probe` 三态 cookie 实打与真机日志核对：任务书禁止启动服务/构建/跑测试，且第 33 条禁止以 kapi 返回作依据；凡涉及「上游实际返回形态」的结论一律标注「静态推演 / 未实测」，未把任何推测写成实测。
- 未读 `docs/batch*`、`docs/v3*review*`、`docs/v4*review*`、`docs/v37*` 及其它批报告（通用规则 7），因此 `kg_play_api.dart:38-58`、P3 第 25 条所指的历史实测记录无法复核，已按「可追溯性缺口」如实标注。
- 未修改任何代码文件、未执行 `pub get`/flutter/构建/测试；唯一写入文件为 `docs/v51_cross_b2_a.md`。
