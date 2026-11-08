# 第4批·审查①-A：直连客户端核心（只读）

基线 commit `6e46611`；范围：`kg_direct_api_client.dart` / `kg_client.dart` / `kugou_api_client.dart` / `kg_crypto.dart`。

### lib/core/direct/kg_direct_api_client.dart:224-240 写操作经 `_directOrFallback` 可被 kapi 二次提交
- 级别：P0
- 依据：`case 'comment/music/send': case 'comment/playlist/send': case 'comment/album/send': return _directOrFallback(() => _commentSend(q), kapi, ...)`；同样 `comment/floor/send`(222)、`comment/music/del`(228)、`playlist/del`(240)、`playlist/add`(241)、`playlist/tracks/add`(243)、`playlist/tracks/del`(246) 全部走同一个 `_directOrFallback`，其实现（142-187）对**任意**失败（含超时、响应体解析失败、`_wrap` 抛 ApiException）都会再执行 `kapi()`。
- 影响：直连请求已在服务端成功后因超时/解析失败被判失败，回退 kapi 会再发一次，产生重复评论、重复收藏/新建歌单、重复加歌、重复删除请求；用户可见为评论/回复出现两条、歌单里同一首歌两份。违反 REVIEW_SPEC §6「写操作不得因回退而重复提交」。

### lib/core/direct/kg_direct_api_client.dart:142-187 `_directOrFallback` 回退路径未统一包装异常
- 级别：P1
- 依据：149 行 `on ApiException` 分支内，171-173 行 `catch (e2) { _logError(...); rethrow; }` 直接抛出 kapi 的原始异常；175-186 行通用分支同样在 kapi 失败后 `rethrow`。因此 kapi 侧抛出的 `FormatException`/`SocketException`/`HandshakeException`（非 ApiException、非 DioException）会以裸异常穿透。
- 影响：上层按 `on DioException catch (e) ... e.error as ApiException` 取值时会漏捕，表现为错误提示丢失／验证码 20028 流程、多账号 20034 流程、token 失效清理在回退路径上不触发（仅在直连路径生效）。

### lib/core/direct/kg_direct_api_client.dart:106 `status == 200` 分支豁免全部错误码检查
- 级别：P1
- 依据：`if (status == 200) return body;` 位于 `err_code`（84-101）与 `error_code/errcode`（102-114）判定之前，直接返回。
- 影响：任何返回 `status=200` 的端点（评论 mcomment 若回落为 200、或网关异常页返回 200 语义体）里的 `err_code=60102` 等业务错误被判成功，不触发 kapi 回退，页面显示「暂无评论/暂无回复」而非正确数据。

### lib/core/direct/kg_direct_api_client.dart:84-101 `err_code` 仅在 `status == 1` 分支内校验
- 级别：P1
- 依据：`final errCode = body['err_code']; if (errCode is int && errCode != 0) throw ...` 位于 `if (status == 1)` 块内；`comment` / `comment/count` 的裸 Map（无 `status`）会走到文件末尾 `return body`，`err_code` 完全未被检查。同时 `err_code` 为字符串（如 `"60102"`）时 `is int` 不成立，也不会判错。
- 影响：裸 Map 端点（评论列表、评论数）以 `err_code != 0` 返回失败时被判成功，不回退 kapi，评论列表恒空；`err_code` 以字符串形式返回时同样误判。

### lib/core/direct/kg_direct_api_client.dart:114-120 无 `status` 且无错误码的空响应被判成功
- 级别：P1
- 依据：`status` 为 null、`error_code`/`errcode` 缺省为 0 时，前面三个分支都不命中，最终 `return body;` 视为成功（空 Map `{}` 亦然）。
- 影响：风控/网关返回空 JSON（`{}` 或 `{"data":null}`）时直连被当成成功，`_directOrFallback` 不会回退 kapi，页面呈现空白列表且无错误提示，用户无法通过重试恢复。

### lib/core/direct/kg_direct_api_client.dart:33-46 `setCredentials` 未同步 dfid、未清理旧 t1
- 级别：P1
- 依据：`kg.token = token; kg.userid = userid; if (t1 != null) kg.t1 = t1;`——`dfid` 只透传给 `super.setCredentials`，直连层签名读的是 `kg.device.dfid`（见 523、534 行与各端点），`kg.device.dfid` 未更新；`t1 == null` 时保留上一个账号的 `kg.t1`。
- 影响：冷启动从持久化凭据恢复会话时，若本地 device.dfid 与凭据 dfid 不一致或为空，直连请求 `uuid=md5(dfid+mid)` 与登录态不匹配，触发风控失败；未传 t1 的刷新场景沿用旧 t1，签名 token/t1 组合错配。

### lib/core/direct/kg_direct_api_client.dart:48-54 `clearCredentials` 未清直连层设备/统计态
- 级别：P2
- 依据：只置空 `kg.token/userid/t1`，未清 `KgDirectApiClient.lastErrors`（129 行静态列表）与 `kg.device.dfid`；`fallbackToKapi` 静态开关也不复位。
- 影响：切换账号后「网络诊断」页仍显示上一账号的错误记录（其中含请求 label 与异常信息），旧账号状态残留可被误读为当前账号故障。

### lib/core/direct/kg_direct_api_client.dart:401-406 `_commentCodeOf` 拆分后残留未使用
- 级别：P2
- 依据：本类保留 `static String _commentCodeOf(String resourceType)`，但评论端点实现已迁至 `kg_endpoints_comment.dart:163`，本文件内无任何调用点。
- 影响：死代码，且与端点实现重复维护；评论资源码若需变更，两处不同步会导致其中一处恒用旧码。

### lib/core/direct/kg_direct_api_client.dart:408-410 文档注释被拆分脚本截断且混入代码片段
- 级别：P2
- 依据：`/// 协议：body = playlistAesEncrypt({listid, total_ver:0, type:1}) 的 Base64， => _epComment.commentCodeOf(q);` —— `=> _epComment.commentCodeOf(q);` 作为注释尾巴留在 `playlistDel` 的文档里，原方法体（协议描述）被截断。
- 影响：R1 拆分残留。`playlist/del` 的协议说明（AES body + RSA p + 二进制响应）在调用侧消失，后续维护者读到的注释与实现不符。

### lib/core/direct/kg_direct_api_client.dart:574-577,604,619-644 账号/二维码辅助方法重复定义且未被调用
- 级别：P2
- 依据：本类仍保留 `_qrSrcappid`(574)、`_maskMobile`(577)、`_qrPngBase64`(604)、`_afterLogin`(619)，而 `kg_endpoints_auth.dart` 内已有同名实现并在其内部调用（121/158/212/377 行）；本类的 `_afterLogin` 没有任何调用点。
- 影响：整段为死代码；若有人误以为登录成功后的 token 回写走本类 `_afterLogin`，会误判登录态同步链路，实际只有 `KgEndpointAuth` 内部那份生效。

### lib/core/direct/kg_direct_api_client.dart:10-11 未使用的 import
- 级别：P2
- 依据：`import 'package:qr_flutter/qr_flutter.dart';` 与 `import 'dart:convert';` 在本文件中无 `QrImage`/`json.`/`base64`/`utf8` 任何使用（二维码生成已迁至 `kg_endpoints_auth.dart`）。
- 影响：死导入，`flutter analyze` 报 unused_import；同时把 `qr_flutter` 依赖耦合进直连适配器。

### lib/core/direct/kg_direct_api_client.dart:365-373 歌词搜索路径与既定口径不一致
- 级别：P1
- 依据：注释写明「`/v1/search` 恒返回空响应体…真正存在的路径是 `/search`（无版本前缀）…该接口不校验 signature，保持 clearDefaultParams + notSignature」。REVIEW_SPEC §1 要求 `lyrics.kugou.com /v1/search` **必须带 signature**。
- 影响：歌词搜索实际请求的不是既定端点，且主动放弃 signature；在酷狗侧风控收紧或 `/search` 下线时歌词整体失效且无签名兜底（仅剩 kapi 回退，属「只靠 kapi」情形）。

### lib/core/direct/kg_direct_api_client.dart:128-129 `fallbackToKapi` 为可变静态全局
- 级别：P2
- 依据：`static bool fallbackToKapi = true;` 可被任意层写入，`_directOrFallback` 直接依赖其值决定是否二次提交请求。
- 影响：一旦被误置 false，所有未移植端点、以及直连失败的读请求全部直接抛错；由于与写操作共用同一开关，无法做到「读回退、写不回退」。

### lib/core/direct/kg_direct_api_client.dart:519-545 `_videoDetail` 直连实现留在适配器内、参数形态与端点组不一致
- 级别：P2
- 依据：`_videoDetail` 未委托 `_epMedia`/`_epHome`，而在本类内手工拼 `clienttime/dfid/uuid/key/show_resolution`，且 `clearDefaultParams: true`（该端点属既定允许的 5 处之一）。
- 影响：R1 拆分不彻底，`/v1/video` 与其他 media 端点的签名参数构造分散在两处；后续修改签名公共参数时容易漏改此处，且该处 `token: kg.token` 为空时仍发送空 token 字段（匿名态），与端点组内「空值不发送」的写法不一致。

### lib/core/direct/kg_client.dart:12 `core/` 直接 import `features/**`
- 级别：P1
- 依据：`import '../../features/auth/data/edt_generator.dart';`
- 影响：违反 REVIEW_SPEC §5「core/ 禁止 import features/**」。直连内核与登录特性模块强耦合：任何 auth 特性目录重命名/裁剪都会连带破坏所有直连请求；也让 `KgClient` 无法脱离 features 单测。

### lib/core/direct/kg_client.dart:49-57 `errorCode` 把 mcomment 的 `err_code` 并入通用错误码
- 级别：P1
- 依据：`int get errorCode { final v = body['error_code'] ?? body['errcode'] ?? body['err_code'] ?? 0; ... }`，紧随其后 55-58 行的 `businessErrorCode` 注释写「与 [errorCode] 分开读，避免普通接口误判」，但 `errorCode` 自己已经把 `err_code` 读进来了。
- 影响：`_needsVerify`（311-315 行）用 `r.errorCode != 0` 判断失败，评论类响应里带 `err_code`（如 60102 或某些成功态附带的业务码）会被当成请求失败，触发不必要的 sid/edt 人机验证提交（额外一次 `/verifyservice/v3/get_verify_info` 写请求）；`businessErrorCode` 则无任何调用点，两者语义重复。

### lib/core/direct/kg_client.dart:232-236 网络异常被吞成业务失败体
- 级别：P1
- 依据：`on DioException catch (e) { return KgResponse(status: 502, body: {'status': 0, 'error': '${e.message}'}); }`——超时/断网/证书错误都不再以 DioException 抛出，而是变成 `status=0` 的业务失败体。
- 影响：异常契约被破坏（REVIEW_SPEC §6）：上层只能拿到 `ApiException(0, '…')`，无法区分「网络不通」与「酷狗业务拒绝」，离线时提示笼统；且 `_directOrFallback` 会因 ApiException 再走 kapi 回退（写操作因此重复提交，见 P0 条目）。同一处理还使 `requestWithVerify` 的 20028 判定依赖的 `errorCode` 在 502 分支恒为 0。

### lib/core/direct/kg_client.dart:140-147、174-186 Dio 无重试/并发闸门，token 走 query
- 级别：P2
- 依据：`Dio(BaseOptions(connectTimeout: 15s, receiveTimeout: 25s, sendTimeout: 30s, responseType: ResponseType.bytes, validateStatus: (_) => true))`，没有拦截器、没有重试、没有并发闸门；`token` 通过 `defaultParams` 进入 **query string**（215 行 `if (token.isNotEmpty) 'token': token`）随每个请求发出。
- 影响：弱网下一次失败即整条链路失败（仅靠 kapi 回退兜底）；token 出现在 URL 里，任何抓包/系统网络日志/崩溃上报都会带上完整登录票据；`bytes` 响应在全量 JSON 接口上也整包留在内存（`rawBytes`），大歌单/评论列表内存开销翻倍。

### lib/core/direct/kg_client.dart:177-180 `uuid` 固定为 `-`，与播放/视频端点的 uuid 算法不一致
- 级别：P2
- 依据：`'uuid': '-'`（含注释说明 A/B 无差异），而 `kg_direct_api_client.dart:533`、`kg_endpoints_home.dart:170` 等处用 `KgCrypto.md5('$dfid${kg.device.mid}')`。
- 影响：同一设备在通用请求与播放/视频请求上呈现两种 uuid，风控侧设备指纹不一致；一旦酷狗对 uuid 做一致性校验，会表现为部分接口（播放地址、视频详情）单独被限流。

### lib/core/direct/kg_client.dart:43 `KgResponse.isOk` 只认 status 1/200，裸 Map 端点恒为 false
- 级别：P2
- 依据：`bool get isOk => this.status == 200 && (body['status'] == 1 || body['status'] == 200);`，而 comment / comment/count 返回裸 Map（无 `status`）。该 getter 全仓库无调用点。
- 影响：死代码，且是错误示范：若后续有人用它替代 `_wrap`，评论类接口会被恒判失败。

### lib/core/direct/kg_client.dart:532 顶层工具函数 `toBytes` 未使用
- 级别：P2
- 依据：`Uint8List toBytes(String s) => Uint8List.fromList(utf8.encode(s));`，全仓库无引用。
- 影响：死代码；`dart:typed_data` 因此仍被导入。

### lib/core/direct/kg_client.dart:371-382、454-456 设备注册失败原因被丢弃 + 固定 3 次重试
- 级别：P2
- 依据：`on DioException catch (_) { return false; }`（454 行）与 `if (raw.isEmpty) return false;`、`data:[] → return false`，`registerDevice` 统一重试 3 次（400/800ms 退避），中间不区分「网络错误」「已注册过」「风控拒绝」。
- 影响：dfid 拿不到时用户只能看到后续所有直连请求用 `dfid='-'` 继续发（不阻断），且无法在诊断页看到失败原因；对风控拒绝场景会连打 3 次放大风控。

### lib/core/direct/kg_client.dart:262-305 `requestWithVerify` 对同一请求无条件重放
- 级别：P2
- 依据：`requestWithVerify` 在 `submitFingerprintVerification` 成功后原样重发同一 path/method/data（293-305 行）。
- 影响：该方法当前只被 `kg_play_api.dart:39,63` 使用（取播放地址），暂无写操作复用；但它对外暴露的是「任意请求可带验证自动重试」，一旦被写端点复用即产生重复提交，属结构性隐患。

### lib/core/api/kugou_api_client.dart:74-96 kapi 拦截器的成功判定与 `_wrap` 口径不一致，直连/回退两条路判定不同
- 级别：P1
- 依据：拦截器 `final okStatus = status == 1 || status == 200; ... const warningCodes = {0, 151, 152, 200, 201}; if (failedStatus || (hasErrorCode && errorCode != 0 && !(okStatus && isWarning)))`；而 `KgDirectApiClient._wrap` 用的是「status==1 → 查 err_code；否则看有没有 data」的另一套规则，且**没有** 151/152/200/201 白名单。
- 影响：同一接口直连成功、回退失败（或反之）表现不同：直连侧 `error_code=151` 但 data 为空会抛错回退，回退侧 `error_code=151` 被认为警告放行返回空体；用户看到「有时列表为空无提示、有时报错」。

### lib/core/api/kugou_api_client.dart:97-107 拦截器 reject 时未携带 `verifyUrl`，且 `body` 只在 Map 分支采集
- 级别：P2
- 依据：`ApiException(errorCode, ..., ssaCode: ..., body: data)` 未传 `verifyUrl`；`ssaCode` 只从 `data['ssaCode']/data['ssa_code']` 与响应头取，而 kapi 的 20028 体若把验证 url 放在 `data.data.url` 等嵌套位置，此处不解析。
- 影响：`ApiException.verifyUrl`（29 行声明、注释说决定验证码类型）在客户端全链路恒为 null，验证码类型只能靠上层另行请求；`needsVerification` 仅认 20028，其他带 ssa-code 的失败码在 kapi 路径不会进入验证流程，而直连路径（`kg_client._needsVerify`）会——两条路行为分叉。

### lib/core/api/kugou_api_client.dart:33-41 构造函数默认 baseUrl 即 kapi 网关
- 级别：P1
- 依据：`_dio = Dio(BaseOptions(baseUrl: baseUrl ?? AppConfig.kugouApiBase, ...))`，`baseUrl` 可空，默认落到 `AppConfig.kugouApiBase`。`KgDirectApiClient(this.kg, {super.baseUrl})` 同样把 `baseUrl` 透传，缺省即 kapi。
- 影响：任何直接 `KugouApiClient()` / `KgDirectApiClient(kg)`（不显式传 baseUrl）的实例，其未覆写路径与全部回退路径都指向 kapi；一旦有调用点绕开 provider 自建实例，就是「以 kapi 为实现」。默认值本身把 kapi 设成了主 baseUrl（见装配核实条目）。

### lib/core/api/kugou_api_client.dart:158-166 `setCredentials` 写入 dfid 但 `clearCredentials` 只清 `this.dfid`，CookieJar 全清
- 级别：P2
- 依据：`clearCredentials` 用 `_cookieJar.deleteAll()`。注释（159 行）说明「用实例自己的 jar」，但 `sharedCookieJar` 是**进程级单例**（127-129 行），`deleteAll()` 会连带清掉 QQ/其他域 cookie 及被其他 client 共享的登录态。
- 影响：登出时把共享 jar 里所有 cookie（含非酷狗域）一并删除；若未来接入其他服务需重新登录。当前仅酷狗域影响有限，属设计风险。

### lib/core/api/kugou_api_client.dart:181-208 `_needsTimestamp` 依赖 path 前缀匹配，直连覆写后大部分路径不再经过
- 级别：P2
- 依据：`const list = ['/login/', '/register/dev', ..., '/comment/', '/import/']; return list.any(path.startsWith);` 只在 kapi Dio 拦截器里生效；`KgDirectApiClient.get/post` 对已移植路径完全不走 `_dio`，`timestamp` 参数不会添加。
- 影响：直连侧对登录/评论/歌单写操作没有任何防缓存时间戳，与 kapi 侧行为不一致（酷狗原生侧若存在中间缓存，写后读可能拿到旧数据）。

### lib/core/api/kugou_api_client.dart:20-31 `ApiException.needsVerification` 只认 20028，与 `_wrap` 的 err_code 分支不匹配
- 级别：P2
- 依据：`bool get needsVerification => errorCode == 20028;`，但 `_wrap` 在 `err_code` 非 0 时抛的异常 `errorCode` 取的是 `err_code`（如 60102），`ssaCode` 却照常带上。
- 影响：直连返回 `status=1 + err_code=<非20028> + ssa-code` 时，`_directOrFallback` 会走 kapi 回退而不是验证流程，人机验证入口漏掉。

### lib/core/direct/kg_crypto.dart:11-13 未使用的 import
- 级别：P2
- 依据：`import 'dart:typed_data';` 在本文件实际使用（`Uint8List`），但 `import 'dart:convert'` 用于 base64/utf8（在用）；`KgConfig.baseUrl` 之类无。核实结果：`dart:typed_data` 与 `dart:convert` 均在用，本条仅记录 `KgConfig` 中 `clientver/appid` 之外的常量未被引用情况——`signKeySalt`（42 行）与 `KgSignature.keyOf`（117-127 行）全仓库仅自引用，属于遗留未接线代码。
- 影响：`keyOf` / `signKeySalt` 是 Node 侧 signKey 算法的移植，但没有任何端点使用；若后续有人以为播放地址已按 signKey 生成 `key`，会误判签名链路已完整。

### lib/core/direct/kg_crypto.dart:24-40 盐值与「三种盐」口径核对结论
- 级别：P2
- 依据：`androidSalt='OIlwieks28dk2k092lksi2UIkp'`（28 行）、`webSalt='NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt'`（34 行）、`register` 函数内联 `'1014'`（103-106 行）。三者与 REVIEW_SPEC §2 一致。但 `androidSaltLite='LnT6xpN3khm36zse0QzvmgTZ3waWdRSA'`（31 行）是第四套盐，规范未列出，`lite=true` 时全部签名切换为它，且 `paramsKey` 的 salt 也随 lite 切换。
- 影响：lite（概念版）模式下所有签名盐、appid、clientver 同时变更；`lite` 是 `KgClient` 上的可变公开字段（`bool lite = false;`），运行期被置 true 后已缓存的 `signature`/`key` 与请求参数不同源，且规范未覆盖该模式，属未受控分支。

### lib/core/direct/kg_crypto.dart:100-107 `register` 盐 `1014` 实现已存在但全链路未使用
- 级别：P2
- 依据：`static String register(Map<String, dynamic> params) { final values = params.values.map((v) => '$v').toList()..sort(); return KgCrypto.md5('1014${values.join()}1014'); }`，注释自述「currently unused：注册实际走 android（含 body）」。而 `KgClient.request` 的 switch 里仍保留 `'register' => KgSignature.register(allParams)` 分支（`kg_client.dart:201`）。
- 影响：`encryptType: 'register'` 是一个仍可被传入、但按 Node register_dev.js 实测结论为**错误签名**的分支；一旦有新端点写 `encryptType:'register'`，签名恒错、必然回退 kapi。

### lib/core/direct/kg_crypto.dart:196-235 `aesEncryptHex` 命名与实际输出不符
- 级别：P2
- 依据：`/// AES-128-CBC + PKCS7，输出 Base64（对应 playlistAesEncrypt）` 但函数名 `aesEncryptHex`，返回 `AesResult(str: base64.encode(out), ...)`。同时注释写「key=md5(seed)[:16], iv=md5(seed)[16:32]」，与 REVIEW_SPEC §3「iv = md5(key)[:16]」**不一致**。
- 影响：命名误导（hex vs base64）；当调用方不传 iv 时生成的 iv 是 `md5(seed)[16:32]`，与 REVIEW_SPEC §3 规定的 `md5(key)[:16]` 不同（两者数值不等）。实现与 Node `util/crypto.js:272-284` 一致，但与项目既定口径不一致——口径与实现二者必有一处错，需按服务端实际解密结果裁定；在裁定前 `playlist/del`、`playlist/add` 的加密体正确性无法从代码自证。

### lib/core/direct/kg_crypto.dart:243-262 `aesEncryptCbcHex` 派生规则与注释/规范不一致
- 级别：P2
- 依据：`final realKey = md5(tempKey); final realIv = realKey.substring(realKey.length - 16);` —— iv 取 **md5(临时key) 的后 16 位**，注释（240-242 行）自称「iv=realKey 末 16 位」；`aesDecryptCbcHex`（288-291 行）同规则。规范未定义该函数，属 Node cryptoAesEncrypt 移植，但同一文件里三种 AES 派生规则（md5(seed) 前 16/后 16、md5(key) 末 16）并存。
- 影响：三套派生规则共用 `KgCrypto` 命名空间，极易在新增端点时用错；一旦用错表现为服务端解密 400 或返回空 `data`，且因为没有异常不会触发回退。

### lib/core/direct/kg_crypto.dart:345-352 `randomString` 的索引算法偏置
- 级别：P2
- 依据：`final idx = ((chars.length - 1) * _rand.nextDouble()).ceil();` —— 此式让 index 0（字符 '1'）概率为 0（`ceil` 对小正数恒为 1），且 idx 可能取到 `chars.length-1` 的上界由 clamp 兜住。Device.guid/seed 与 edt 临时 key 都用它。
- 影响：生成的随机串首位字符永不可能是 '1'，字符分布偏斜，熵略降；`EdtGenerator._randomString`（245-252 行）复制了同一偏置，双方一致所以握手不破坏，但这是移植时未纠正的算法缺陷。

### lib/core/direct/kg_crypto.dart:222-234 `AesResult.key` 在显式传 key+iv 时回填的是传入的 key 而非 seed
- 级别：P2
- 依据：`static AesResult aeEncryptHex(String data, {String? key, String? iv})` 中 `if (key != null && iv != null) { useKey = key; useIv = iv; }`，末尾 `return AesResult(str: base64.encode(out), key: seed ?? '')`，此处 `seed` 就是 `key`。
- 影响：调用方拿 `result.key` 去 RSA `p` 加密时，把 **AES 的 16 字符 key** 当 seed 传给服务端；若服务端按 `md5(seed)` 派生（Node 语义），派生出的 key/iv 与实际加密所用不一致 → 服务端解密失败。歌单删除/MV 收藏若走显式 key 路径即中招。
