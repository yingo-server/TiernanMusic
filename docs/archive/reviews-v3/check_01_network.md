# 检查 1/3：网络层与直连协议

> 范围：`lib/core/direct/kg_crypto.dart`、`kg_client.dart`、`kg_direct_api_client.dart`、`kg_play_api.dart`、`lib/core/api/kugou_api_client.dart`、`lib/core/api/translate_api.dart`、基准 `docs/api_verified.md`
> 对照源：`/var/minis/workspace/KuGouMusicApi/util/{helper,crypto,request}.js`、`module/*.js`
> 只读检查；未修改代码；未发起任何网络请求；事实依据仅来自代码、Node 源码与既有实测记录。

---

## lib/core/direct/kg_crypto.dart

### A. 签名算法对齐 Node helper.js
- 结论：✅ 通过
- 位置：`kg_crypto.dart:57-67`（android）、`kg_crypto.dart:79-84`（web）、`kg_crypto.dart:94-97`（register）、`kg_crypto.dart:104-113`（keyOf）、`kg_crypto.dart:119-129`（paramsKey）
- 依据：
  - Node `signatureAndroidParams`（helper.js:61-79）= `Object.keys(params).sort().map(k=>`${k}=${typeof v==='object'?JSON.stringify(v):v}`).join('')`，再 `md5(salt + paramsString + (data||'') + salt)`。
  - Dart `KgSignature.android` 先 `params.keys.toList()..sort()`，再拼 `k=v`（Map/List 走 jsonEncode），最后 `md5('$salt$sb$data$salt')` → 一致。
  - Node `signatureWebParams`（helper.js:40-47）先 map 成 `k=v` **再 sort 整个字符串**；Dart `KgSignature.web` 同样先 map 再 `..sort()` → 一致。
  - Node `signatureRegisterParams`（helper.js:93-99）只取 **values** 并 sort；Dart `KgSignature.register` 用 `params.values` → 一致。
  - Node `signKey`（helper.js:135-140）= `md5(hash + salt + appid + mid + (userid||0))`；Dart `keyOf` → 一致。
  - Node `signParamsKey`（helper.js:168-179）= `md5(appid + salt + clientver + data)`；Dart `paramsKey` → 一致。

### B. 盐值与平台常量
- 结论：✅ 通过
- 位置：`kg_crypto.dart:24-48`
- 依据：Node `util/config.json` appid=1005/clientver=20489/liteAppid=3116/liteClientver=11440；`helper.js:63` android salt `OIlwieks28dk2k092lksi2UIkp`；`helper.js:41` web salt `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`；`helper.js:138` signKey salt `57ae12eb6890223e355ccfcb74edf70d` / lite `185672dd44712f60bb1736df5a377e82`；`helper.js:171` signParamsKey salt lite `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`；Dart 常量逐一对应。

### E. 二进制 / AES / RSA 处理
- 结论：✅ 通过
- 位置：`kg_crypto.dart:196-213`（rsaEncryptPkcs1）、`kg_crypto.dart:219-237`（rsaEncryptRawHex）、`kg_crypto.dart:246-263`（aesEncryptHex）、`kg_crypto.dart:268-286`（aesEncryptCbcHex）、`kg_crypto.dart:288-296`（aesEncryptCbcAuto）、`kg_crypto.dart:298-322`（aesDecryptCbcHex）、`kg_crypto.dart:333-356`（aesDecryptPlaylistB64）、`kg_crypto.dart:363-375`（randomString）
- 依据：
  - `rsaEncrypt2`（Node crypto.js:264-270）= PKCS1-v1_5 + `forge.util.bytesToHex`（**小写**）→ Dart `rsaEncryptPkcs1` 默认 `uppercase=false` 输出小写 → 一致（注册接口 `p` 参数需小写）。
  - `cryptoRSAEncrypt`（Node crypto.js:247-262）= **无 PKCS1 填充**，右补零到 keyLength 后 modPow，hex 小写 → Dart `rsaEncryptRawHex` 一致。
  - `playlistAesEncrypt`（Node crypto.js:272-285）= key=`md5(seed)[0:16]`、iv=`md5(seed)[16:32]`、AES-CBC/PKCS7、**Base64** 输出 → Dart `aesEncryptHex` 一致。
  - `cryptoAesEncrypt`（Node crypto.js:188-213）= tempKey 16 位 → realKey=`md5(tempKey)`（32 hex 字符）、iv=realKey 末 16、hex 输出 → Dart `aesEncryptCbcHex`/`aesEncryptCbcAuto` 一致。
  - `cryptoAesDecrypt`（Node crypto.js:222-239）→ Dart `aesDecryptCbcHex` 一致。
  - `playlistAesDecrypt`（Node crypto.js:287-304）→ Dart `aesDecryptPlaylistB64` 一致。
  - `randomString`：Node util.js:34-45 `Math.ceil((len-1)*Math.random())` 取索引 1..35；Dart `kg_crypto.dart:365-372` 同样 `ceil` 后 `clamp(0,35)` → 分布一致（均取不到字符 '1'）。

### F. uuid 取值
- 结论：✅ 通过
- 位置：`kg_crypto.dart:355-362`（uuidV4）、`kg_client.dart:148`
- 依据：Node request.js:94 `const uuid = '-'`；Dart `defaultParams['uuid'] = '-'` → 一致。

---

## lib/core/direct/kg_client.dart

### B. 成功判定（`KgResponse.isOk`）
- 结论：❌ 问题
- 位置：`kg_client.dart:44`
- 依据：Dart `bool get isOk => status == 200 && body['status'] == 1;` 硬编码 `status == 1`。Node request.js:234 的失败判据是 `response.data.status === 0 || (response.data?.error_code && response.data.error_code !== 0)`，即 **`status` 只要不是 0 就算成功**。`docs/api_verified.md:22` 明确记录歌词接口成功语义为 `status=200`（`errcode=200`），该响应 `status` 既非 0 也非 1 → Node 判成功，Dart `isOk` 判失败。

### C. 错误码读取范围
- 结论：❌ 问题
- 位置：`kg_client.dart:47-50`
- 依据：Dart `errorCode` 只读 `body['error_code'] ?? body['errcode']`，**未读 `err_code`**。而 `kg_direct_api_client.dart:44-49` 的注释明确记载 mcomment 系列接口用 `err_code` 表达业务错误（实测 `status=1, err_code=60102`）。即 `KgResponse.errorCode` 对该类接口恒返回 0，无法用于判定。

### F. signature 位置与超时
- 结论：✅ 通过（signature 位置正确）/ ⚠️ 存疑（超时配置）
- 位置：`kg_client.dart:180-183`（签名写入 allParams）、`kg_client.dart:205-215`（queryParameters + headers）、`kg_client.dart:125-131`（Dio BaseOptions）
- 依据：
  - Node request.js:146-160 把 `signature` 写进 `params`（axios 以 query 发送）；Dart 同样放进 `allParams` 并作为 `queryParameters` 发送 → 一致。
  - Node request.js:103 的 `kg-rc/kg-thash/kg-rec/kg-rf` 放 **headers**；Dart `kg_client.dart:191-197` 同样放 headers → 一致。
  - Node request.js:130 `headers['clienttime'] = params.clienttime`（同步签名后的 params）；Dart `kg_client.dart:189` 用本地 `clienttime` 变量，与 `allParams['clienttime']` 同源 → 一致。
  - ⚠️ Dio BaseOptions 仅设 `connectTimeout: 15s` / `receiveTimeout: 25s`，**无 `sendTimeout`**；Node axios 侧无显式超时（默认 0 = 不限）。设备注册、云歌单、歌词下载等较慢接口存在被 25s 截断的条件。

### 设备注册（register_dev）
- 结论：✅ 通过
- 位置：`kg_client.dart:296-330`、`kg_client.dart:412-450`
- 依据：Node `module/register_dev.js` 使用 `rsaEncrypt2`（小写 hex）、body 为 `playlistAesEncrypt` 的 base64、响应为二进制需 base64 后 AES 解密 → Dart `kg_client.dart:392-400` 处理一致；`uid` 传字符串 `'0'` 与 `kg_client.dart:328` 一致。

### `submitFingerprintVerification`
- 结论：✅ 通过
- 位置：`kg_client.dart:268-296`
- 依据：Node request.js:220-257 命中 `ssa-code` 时生成 sid/edt 并附加；Dart 用 `EdtGenerator` 生成并 POST `/verifyservice/v3/get_verify_info`，结构对应 Node 的 `generate_simulate` + 验证接口。

### `requestWithVerify` 触发条件
- 结论：⚠️ 存疑
- 位置：`kg_client.dart:225-266`、`kg_client.dart:299`
- 依据：Node request.js:234-246 对**任意** `status===0` 或 `error_code != 0` 的失败，只要响应带 `ssa-code` 就生成 sid/edt；Dart `_needsVerify` 仅在 `r.errorCode == 20028` 时返回 true。20006（签名错）、60102（业务失败）等错误码即便带 `ssa-code` 也不会触发验证流程。

