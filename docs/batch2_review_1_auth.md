# 第 2 批审查① · 认证与验证链路（只读）

基线：`73e72c0`（CI 全绿）
范围：`lib/features/auth/**`、`lib/core/direct/kg_endpoints_auth.dart`、`lib/core/direct/kg_direct_api_client.dart` 的认证路径、`lib/core/direct/kg_client.dart` 的登录态字段、`lib/core/api/kugou_api_client.dart`、`lib/core/storage/secure_storage.dart`、`lib/main.dart` 的登录态同步、`lib/core/router/app_router.dart` 的登录路由。
方式：逐文件完整阅读；不运行构建/测试；不引用第 1 批报告。
结论：**P0 2 项、P1 10 项、P2 6 项**。认证主链（密码登录 → 20028 → CaptchaPage → verify_user_info → 重试）在当前默认直连实现下**没有任何一条能完整走通**（A2-01 使验证页不弹，A2-03 使 SID 无效；A2-02 的验证参数只能靠 kapi 回退兜底）。

| 编号 | 级别 | 一句话 |
|---|---|---|
| A2-01 | P0 | 直连 20028 的 ssaCode 被丢弃，密码登录永远不会弹出验证页 |
| A2-02 | P1 | 直连分支丢弃全部验证参数，实际依赖 kapi 回退；回退关闭/命中例外码时失败 |
| A2-03 | P0 | SID 使用 pointycastle OAEP 默认 SHA-1，上游要求 SHA-256 |
| A2-04 | P1 | 20034 多账号响应体同样丢失，账号选择弹层不可达 |
| A2-05 | P1 | 切号刷新请求携带旧账号 token/userid，且目标账号 t1 无处可取 |
| A2-06 | P1 | 扫码成功即写 kg.token/userid，换登录失败不回滚 |
| A2-07 | P1 | 直连异常统一包 DioException，但登录页/评论页按 ApiException 解包 |
| A2-08 | P1 | 腾讯验证所需 txappid 从未从响应解析，v_type=23 无可用 UI |
| A2-09 | P1 | 20010 被无条件当作 token 失效，可能清掉有效会话 |
| A2-10 | P1 | 主入口异步回填 t1 存在竞态，可把新账号 t1 清空 |
| A2-11 | P1 | `loginBySms` 不处理 20028，短信风控无验证入口 |
| A2-12 | P1 | `_handleLoginSuccess` 中 `AccountManager.upsert` 未保护，服务端已登录但 UI 报失败 |
| A2-13 | P2 | QR 轮询吞掉全部异常，过期/错误状态无法呈现；status=4 失败后停在“登录成功” |
| A2-14 | P2 | dfid 在 SecureStorage / Cookie / KgDevice 三处来源分裂，直连可能用 `-` |
| A2-15 | P2 | 退出登录保留 `acct_token_<userid>`，凭证仍留在设备 |
| A2-16 | P2 | 冷启动 authState 仍 loading 时 `ensureLoggedIn` 误判未登录 |
| A2-17 | P2 | CaptchaPage WebView 无加载失败回调；txappid 缺失时落入“未知类型”死路 |
| A2-18 | P2 | 验证相关死代码/未使用导入/重复注释（`runWithVerification` 0 调用点等） |

---

## P0（A2-01、A2-03；A2-02 已降级 P1，因直连失败后仍有 kapi 回退，暂列本节末尾便于对照）

### A2-01 直连 20028 的 ssaCode 被丢弃，密码登录永远不会进入验证页

**位置**
- `lib/features/auth/data/auth_repository.dart:132-138`（`loginByPassword` 的 20028 分支）
- `lib/features/auth/data/auth_repository.dart:359-369`（`_errorResponseData` 只读 `e.response?.data`）
- `lib/core/direct/kg_direct_api_client.dart:156-161`（直连把 `ApiException` 重新包成 `DioException`，**不设置 response**）
- `lib/core/api/kugou_api_client.dart:20-35`（`ApiException.ssaCode` 是既有字段）

**证据**
```dart
// auth_repository.dart:134-137
if (err is ApiException && err.errorCode == captchaErrorCode) {
  final data = _errorResponseData(e);
  final ssaCode = '${data?['ssaCode'] ?? data?['data']?['ssaCode'] ?? data?['ssa_code'] ?? ''}';
  throw CaptchaRequiredException(ssaCode, err.message);
}
```
```dart
// kg_direct_api_client.dart:158-161
throw DioException(
  requestOptions: RequestOptions(path: label),
  error: e,
); // 没有 response / body
```
```dart
// auth_repository.dart:359-364
Map<String, dynamic>? _errorResponseData(DioException e) {
  final data = e.response?.data; // 直连包装的 DioException.response == null
```

`KgResponse.ssaCode`（`kg_client.dart:48-49`）已经能从响应头/体取到 ssaCode，并把它放进了 `ApiException.ssaCode`；但仓库层没有读 `err.ssaCode`，只读 `e.response`。而 `_directOrFallback` 对 20028 **明确不回退 kapi**（`kg_direct_api_client.dart:154-156`），所以不存在“回退后拿到带 response 的异常”的兜底。

**影响**
密码登录命中风控 20028 时，`ssaCode` 恒为空串；`login_page.dart:395-400` 走 `_showError`，只弹一条“需要完成人机验证”的 Toast，`CaptchaPage` 永远不会打开，也没有任何重试入口。密码登录在风控场景下 100% 卡死。

---

### A2-02（P1） `verify/user/info` 参数全部走 query，直连层只读 body

**位置**
- `lib/features/auth/data/verification_service.dart:50-76`（eventid/v_type/sid/edt/verifycode 全放进 `query`，body 传 `{}`）
- `lib/core/direct/kg_direct_api_client.dart:310-341`（`post` 把 body 解成 `d`，`case 'verify/user/info'` 只把 `d` 传给端点）
- `lib/core/direct/kg_endpoints_auth.dart:331-406`（端点所有字段都从 `d` 读取）

**证据**
```dart
// verification_service.dart:57-76
final query = <String, dynamic>{
  'eventid': session.eventId,
  'v_type': vType,
  'platid': 2,
  'wasm': 1,
  'sid': edt.sid,
  'edt': edt.edt,
  if (verifycode != null) 'verifycode': verifycode,
  if (vType == 32 && verifycode != null) 'code': verifycode,
};
final data = await _api.post('/verify/user/info', {}, query: query);
```
```dart
// kg_direct_api_client.dart:312-314、339-341
final d = data is Map<String, dynamic> ? data : const <String, dynamic>{};
...
case 'verify/user/info':
  return _directOrFallback(
      () => _verifyUserInfo(d), kapi, '/verify/user/info');
```
```dart
// kg_endpoints_auth.dart:331-345
Future<KgResponse> verifyUserInfo(Map<String, dynamic> d) {
  final vType = int.tryParse('${d['v_type'] ?? 23}') ?? 23;
  ...
  'eventid': d['eventid'],
  'sid': sid,
  'edt': edt,
```
直连分支收到的 `d` 永远是 `{}`：`eventid` 为 null、`v_type` 恒 23、`sid/edt` 为空、`verifycode/code` 不存在。`query` 在直连分支被完全丢弃（同一文件里 `artist/detail`、`album/*` 都有 `{...q, ...d}` 的合并，唯独验证没有）。

`_wrap` 对 status=1/200 的响应会放行；若上游对缺参请求返回 status=1 且 data 非空，`VerificationService.submit` 还会**误判验证通过**，随后登录重试继续 20028，用户侧表现为“验证通过但一直登录失败”。

**影响**
直连分支永远不会按真实 session 提交：如果 `/v4/verify_user_info` 对空 eventid 返回 20010 一类普通错误，`_directOrFallback` 会回退 kapi，而 kapi 会把 `query` 里的完整参数送达，验证实际靠**回退**才成立（默认 `fallbackToKapi = true`）；这带来三个问题：
1. 每次都先发一次无效直连请求，多一次 RTT 和一次风控计数；
2. 若直连返回 status=1（宽松成功语义）则不会回退，`submit` 拿到假成功；
3. 若直连返回 20028/20034（`_directOrFallback` 明确不回退）或将来关闭回退，验证直接失败。

因此直连实现（R1 拆分后的 `_epAuth.verifyUserInfo`）在验证链路上是**死的**，当前只有 kapi 回退在真正工作。

---

### A2-03 SID 使用 RSA-OAEP 默认 SHA-1，与上游 SHA-256 不一致

**位置**
- `lib/features/auth/data/edt_generator.dart:256-272`
- 同文件 `:14` 的注释自己写着 “RSA-OAEP(md=SHA-256, mgf1=SHA-256)”
- 上游对照：`KuGouMusicApi/util/generate_simulate.js` 的 `rsaKey.encrypt(key, 'RSA-OAEP', { md: forge.md.sha256.create(), mgf1: { md: forge.md.sha256.create() } })`

**证据**
```dart
// edt_generator.dart:268
final oaep = OAEPEncoding(RSAEngine())
  ..init(
    true,
    PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, exponent)),
  );
```
`pointycastle 3.9.1`（`pubspec.yaml` 声明 `^3.9.1`）的 `OAEPEncoding` 是一个工厂构造：
```dart
factory OAEPEncoding(AsymmetricBlockCipher engine,
        [Uint8List? encodingParams]) =>
    OAEPEncoding.withSHA1(engine, encodingParams);

factory OAEPEncoding.withSHA256(...) => ...SHA256Digest();
```
即 `OAEPEncoding(RSAEngine())` 固定走 `withSHA1`；代码没有使用 `OAEPEncoding.withSHA256(...)`。它也没有传 MGF1 摘要，`withSHA1` 下 MGF1 同样是 SHA-1。

**影响**
`sid` 是用 SHA-1 的 OAEP 填充加密 16 字节 AES key，服务端按 SHA-256 做 OAEP 解码时哈希算法不匹配，私钥解密会失败。即使 A2-01/A2-02 全部修好，`/verify/user/info` 仍会因 `sid` 无效而失败。`EdtGenerator` 同时被 `VerificationService.buildSidEdt` 和 `KgClient.submitFingerprintVerification` 使用，影响面覆盖两条验证路径。

---

## P1

### A2-04 20034 多账号响应体丢失，账号选择弹层不可达

**位置**
- `lib/features/auth/data/auth_repository.dart:101-113`
- `lib/core/direct/kg_direct_api_client.dart:154-161`（20034 与 20028 一起被直接包装、不回退）
- `lib/features/auth/presentation/login_page.dart:238-247`（收到 `MultiAccountException` 才弹选择框）

**证据**
```dart
// auth_repository.dart:104-108
if (err.errorCode == 20034 || err.message.contains('多个')) {
  final data = _errorResponseData(e);
  final list = data?['data']?['users'] ?? data?['users'];
  if (list is List) { throw MultiAccountException(...); }
}
rethrow;
```
`_errorResponseData(e)` 与 A2-01 同因：直连包装的 DioException 没有 `response`，`data` 为 null，`list` 为 null，最终 `rethrow`。

**影响**
同一手机号归属多个账号时，短信登录不弹账号选择框，直接显示原始 DioException；用户无法完成登录。该错误只在直连默认路径发生（kapi 回退路径有 response），因此测试若只覆盖 kapi 会漏掉。

---

### A2-05 切号刷新请求携带旧账号 token/userid，且目标账号 t1 无处可取

**位置**
- `lib/features/auth/data/auth_providers.dart:55-68`（`switchAccount` 先 `loginByToken`，此前没有切换凭证）
- `lib/core/direct/kg_client.dart:174-186`（每次请求自动附上当前 `kg.token` / `kg.userid`）
- `lib/core/direct/kg_direct_api_client.dart:34-47`（`setCredentials` 只在登录成功后才调用）
- `lib/features/auth/data/account_manager.dart:26-33`（`AccountRecord.toJson` 不持久化 `t1`）
- `lib/features/auth/data/auth_providers.dart:64`（`loginByToken` 直接使用目标账号 token）

**证据**
```dart
// auth_providers.dart:62-67
final token = await ...getAccountToken(userid);
final user = await repo.loginByToken(token: token, userid: userid);
...
await AccountManager.instance.switchTo(userid);
```
```dart
// kg_client.dart:184-185
if (token.isNotEmpty) 'token': token,
if (userid.isNotEmpty && userid != '0') 'userid': userid,
```
```dart
// account_manager.dart:30-33
Map<String, dynamic> toJson() => {
      'userid': userid,
      'nickname': nickname,
      'avatar': avatar,
    }; // 没有 t1
```
`switchAccount` 在发请求前既没有 `setCredentials`，也没有设置 `kg.t1`。此时 `kg.token`/`kg.userid` 仍是**当前旧账号**，`loginToken` 的默认参数会把旧 token 带进新账号的刷新请求；同时 `loginToken` 的 `t1Plain`（`kg_endpoints_auth.dart:189-190`）取的是旧账号 `kg.t1` 或空串，目标账号的 t1 从未持久化（`AccountRecord.t1` 只在内存构造时赋值，序列化丢弃，读取后也不再恢复）。

**影响**
- 旧账号 token 被发送到目标账号的 `/login/token` 请求中，属于跨账号凭证混用；服务端若以 query token 鉴权会刷新出旧账号或直接拒绝。
- 目标账号的 `t1` 缺失/错误，刷新签名与实际账号不匹配。
- `KgDirectApiClient.setCredentials` 只在成功后执行；失败时旧账号的 `kg.token/userid/t1` 原样保留，`switchAccount` 抛错后 UI 仍是旧账号，但 `AccountManager` 指针也未切换（`peek` + `switchTo` 的顺序保证了指针，但客户端字段未动）。

---

### A2-06 扫码成功即写 kg.token/userid，换登录失败不回滚

**位置**
- `lib/core/direct/kg_endpoints_auth.dart:252-276`（`loginQrCheck` 在 status==4 时直接写 `kg.token` / `kg.userid`）
- `lib/features/auth/presentation/login_page.dart:570-585`（`loginByQrToken` 失败只 Toast）
- `lib/features/auth/data/auth_repository.dart:173-184`（`loginByToken` 失败时不做清理）

**证据**
```dart
// kg_endpoints_auth.dart:270-275
if (data is Map && '${data['status']}' == '4') {
  final token = '${data['token'] ?? ''}';
  final userid = '${data['userid'] ?? ''}';
  if (token.isNotEmpty) kg.token = token;
  if (userid.isNotEmpty && userid != '0') kg.userid = userid;
}
```
```dart
// login_page.dart:577-584
await ref.read(loginControllerProvider.notifier).loginByQrToken(
      token: res.token ?? '',
      userid: res.userid ?? '',
    );
widget.onSuccess();
} catch (e) {
  if (mounted) _showError(context, e);
}
```
`loginByQrToken` 内部走 `/login/token`，可能因空 token/userid、t1 缺失、风控等失败；失败路径只 Toast，没有 `clearCredentials()`，也没有把 `kg.token/userid` 回滚。

**影响**
扫码后 UI 仍是未登录（`authState` 保持 null），但直连客户端已携带扫码账号的 token/userid；此后匿名请求（搜索、播放、评论）都会以该账号身份发出。若用户以为扫码失败而改用别的账号，存在账号身份串用与隐私风险。

---

### A2-07 直连异常统一包 DioException，但登录页/评论页按 ApiException 解包

**位置**
- `lib/core/direct/kg_direct_api_client.dart:150-200`（所有直连 `ApiException` 都转为 `DioException(error: e)`）
- `lib/features/auth/presentation/login_page.dart:158-164`（`_showError` 只识别 `ApiException` / `CaptchaRequiredException`）
- `lib/features/comment/presentation/comments_page.dart:374-395`（`on ApiException catch` 才弹验证页）
- `lib/features/auth/data/auth_repository.dart:132`（登录仓库是少数正确解包 `e.error` 的地方）

**证据**
```dart
// login_page.dart:158-164
void _showError(BuildContext context, Object e) {
  final msg = e is ApiException
      ? e.message
      : e is CaptchaRequiredException
          ? e.message
          : '$e';
```
```dart
// comments_page.dart:374-377
} on ApiException catch (e) {
  if (mounted && e.needsVerification && (e.ssaCode?.isNotEmpty ?? false)) {
```
直连 `post('/comment/.../send')` 失败时抛的是 `DioException`，`on ApiException` 永远不命中，落到 `catch (e)` 显示 `$e`。

**影响**
- 登录页所有直连错误显示为 `DioException [unknown]: null\nError: ApiException(...)` 技术文本，而不是 `friendlyError` 的中文文案。
- 评论/回复的 20028 验证分支在直连默认路径下是死代码：用户发评被风控后不会弹 `CaptchaPage`，只看到原始异常。
- 与 A2-01 同类：异常契约只在仓库层做了 `.error` 解包，表现层没有统一。

---

### A2-08 腾讯验证所需 txappid 从未从响应解析，v_type=23 无可用 UI

**位置**
- `lib/features/auth/data/captcha_types.dart:90-126`（`VerifySession` 只解析 eventId/vType/type/typeList/sessionId/business/verifyUrl，没有 `txappid` / `mobile`）
- `lib/features/auth/presentation/captcha_page.dart:83-99`（只从 `verifyUrl` 正则抓 `txappid=`）
- `lib/features/auth/presentation/captcha_page.dart:169-174`（拿不到 appId 直接退化为“未知验证类型”）
- `lib/features/auth/data/captcha_types.dart:133-140`（`VerifyCode.tencent` 明确要求 `txappid`）

**证据**
```dart
// captcha_page.dart:95-99
String? _extractTxAppId(VerifySession s) {
  final url = s.verifyUrl ?? '';
  final m = RegExp(r'txappid=([0-9A-Za-z_-]+)').firstMatch(url);
  if (m != null) return m.group(1);
  return null;
}
```
```dart
// captcha_page.dart:170-173
final appId = _txAppId;
if (appId == null) {
  // 没有 txappid 无法初始化，退化为未知类型提示
  return _buildUnknown(theme, s);
}
```
`VerifySession.fromJson` 里对 `data['txappid']`、`data['mobile']` 没有任何读取；`CaptchaType.fromVType(23)` 会把 v_type=23 归为腾讯，但只要 `url` 里没有 `?txappid=` 参数就必然落到 unknown。

**影响**
`/get/verify/info` 的 `url` 是 `KGCodeTX|...` 形式（`captcha_types.dart:5-8` 的注释与 `fromVerifyUrl` 的 `startsWith` 都按此前缀设计），并不保证带 `txappid=` 查询参数。腾讯验证（风险控制默认类型）在 App 内没有可用 UI；用户只能点“直接尝试提交指纹验证”（无 verifycode），随后仍失败。

---

### A2-09 20010 被无条件当作 token 失效，可能清掉有效会话

**位置**
- `lib/features/auth/data/auth_repository.dart:262-267`
- `lib/features/auth/data/auth_repository.dart:222-233`（`restoreSession` 命中即 `logout()`）

**证据**
```dart
bool _isTokenInvalidCode(int code, String message) {
  const invalidCodes = {1011, 20010, 30791, 401};
  if (invalidCodes.contains(code)) return true;
  return code == -1 && message.contains('token');
}
```
```dart
if (!networkError && confirmedInvalid) {
  await logout();
  return null;
}
```
`20010` 在酷狗网关是通用的“参数缺失/参数错误”码（本项目其他位置也按通用错误处理），并不专指 token 失效；`login_by_token` 在 `t1` 为空、`dfid` 为 `-`、`userid` 类型异常时同样可能返回 20010。

**影响**
冷启动或切号后，只要 `/login/token` 因参数问题返回 20010，`restoreSession` 会执行 `logout()`：删除 SecureStorage 的 token/userid/t1/auth、清 CookieJar、清当前账号指针。一次参数性失败即可把有效登录态彻底清空，用户必须重新登录，且原账号的 `acct_token_*` 仍留在设备上（见 A2-15），状态更混乱。

---

### A2-10 主入口异步回填 t1 存在竞态，可把新账号 t1 清空

**位置**
- `lib/main.dart:244-260`

**证据**
```dart
SecureStorage.instance.readCredentials().then((c) {
  client.t1 =
      (c != null && c.userId == user.userid) ? (c.t1 ?? '') : '';
}).catchError(...);
```
闭包捕获的是触发这次监听的 `user`；`readCredentials()` 是异步的。若在读回前发生“退出→登录另一个账号”，读回的 `c.userId` 是新账号，与旧 `user.userid` 不等，三元表达式落到 `''`，把**新账号**刚由 `setCredentials` 写好的 `kg.t1` 清空。

**影响**
快速切号/退出后立即登录时，新账号的后续 `/login/token`、写操作签名使用空 t1，可能被服务端判为参数错误（并触发 A2-09 的登出）。同一竞态也会在 `restoreSession` 与登录监听同时触发时出现。

---

### A2-11 `loginBySms` 不处理 20028，短信风控无验证入口

**位置**
- `lib/features/auth/data/auth_repository.dart:83-113`（只处理 20034，其余 `rethrow`）
- `lib/features/auth/presentation/login_page.dart:238-248`（短信 Tab 只捕获 `MultiAccountException`）
- 对照 `auth_repository.dart:132-138`（密码登录有 20028 分支）

**证据**
```dart
// loginBySms
} on DioException catch (e) {
  final err = e.error;
  if (err is ApiException) {
    if (err.errorCode == 20034 || err.message.contains('多个')) { ... }
    rethrow;
  }
  rethrow;
}
```
短信登录接口 `/login/cellphone` 与密码登录同属登录风控面；`KgResponse.ssaCode` 对任意失败响应带 header 都会返回，但这里从未读取 20028。

**影响**
短信验证码登录命中 20028 时只显示通用错误，不弹验证页、不重试；且 `login_page` 的短信 Tab 没有 `on CaptchaRequiredException` 分支，即使仓库抛出也无法进入 `CaptchaPage`。

---

### A2-12 `_handleLoginSuccess` 中 `AccountManager.upsert` 未保护，服务端已登录但 UI 报失败

**位置**
- `lib/features/auth/data/auth_repository.dart:331-340`
- `lib/features/auth/data/account_manager.dart:126-140`（`upsert` 内 `_b` 在 box 未打开时抛 `StateError`）

**证据**
```dart
// auth_repository.dart:331-336
await _storage.saveAccountToken(userid: userid, token: token); // 有 try/catch
await AccountManager.instance.upsert(AccountRecord(...));      // 无 try/catch
```
`AccountManager.instance.upsert` 访问 `_b`，`_box == null` 时 `throw StateError('AccountManager 未初始化...')`。这条路径发生在 token/userid 已写入 SecureStorage、`_api.setCredentials` 已执行之后。

**影响**
若 `AccountManager.init()` 失败（Hive box 打开失败、启动异常路径），登录请求已经在服务端成功、凭证已经落盘、直连客户端已带 token，但 `upsert` 抛出导致 `loginBySms`/`loginByPassword` 抛错，`LoginController._finish` 不执行，UI 停在登录页。用户重试会再次登录，账号列表仍缺失。

---

## P2

### A2-13 QR 轮询吞掉全部异常，过期/错误状态无法呈现；status=4 失败后停在“登录成功”

**位置**
- `lib/features/auth/presentation/login_page.dart:566-590`（`_checkOnce` 的 `catch (_) {}`）
- `lib/features/auth/presentation/login_page.dart:590-596`（`_statusText` 只在 status==0 时显示过期）
- `lib/features/auth/data/auth_repository.dart:168-184`（`checkQr` 依赖 `res['data']['status']`）

**证据**
```dart
} catch (_) {
  // 轮询失败忽略，下次再试
}
```
```dart
String get _statusText => switch (_status) {
  0 => context.l10n.qrExpired,
  2 => context.l10n.qrScanSuccess,
  4 => context.l10n.loginSuccess,
  _ => context.l10n.qrScanHint,
};
```
`checkQr` 的 status 来自响应体；若直连 `_wrap` 因顶层 `status==0`/`error_code!=0` 抛出（`kg_direct_api_client.dart:120-145`），轮询层只看到异常，`_status` 不会更新为 0，`_pollTimer` 也不会停，界面永远停在“请扫码”。

另外 status==4 时先 `_pollTimer?.cancel()`，若随后 `loginByQrToken` 失败，只 Toast；`_status` 保持 4，`build` 的刷新按钮只在 `_status==0 || _error!=null` 展示，用户没有任何重试入口（只能切 Tab 再切回触发 `_loadQr`）。

**影响**
过期二维码无法提示/停止轮询；扫码成功但换登录失败时 UI 显示“登录成功”却未登录，且无刷新按钮。

---

### A2-14 dfid 在 SecureStorage / Cookie / KgDevice 三处来源分裂，直连可能用 `-`

**位置**
- `lib/features/auth/data/auth_repository.dart:66-81`（`getDfid` 只读写 SecureStorage）
- `lib/features/auth/data/auth_repository.dart:318-330`（把 dfid 交给 `_api.setCredentials`）
- `lib/core/direct/kg_direct_api_client.dart:34-47`（只写父类 `dfid` 字段，不写 `kg.device.dfid`）
- `lib/core/direct/kg_client.dart:168-183`（请求签名与 `dfid` 头取 `device.dfid`，空则 `-`）

**证据**
```dart
// kg_direct_api_client.dart:39-45
await super.setCredentials(
    token: token, userid: userid, t1: t1, auth: auth, dfid: dfid);
```
`super.setCredentials` 只执行 `if (dfid != null) this.dfid = dfid;`（`kugou_api_client.dart:198-204`），没有同步 `kg.device.dfid`。正常路径靠 `KgClient.registerDevice` 成功时 `_persistDfid` 写 Hive；但一旦设备注册走的是 kapi 回退（`_registerDev` 失败 → `super.get('/register/dev')`），拿到的 dfid 只进 SecureStorage 和父类字段，`kg.device.dfid` 仍为空。

**影响**
直连请求使用 `dfid='-'` 与签名，服务端视为新设备/匿名设备，风控概率升高；同一 App 内 kapi 与直连使用两个不同 dfid，设备身份不可复现。

---

### A2-15 退出登录保留 `acct_token_<userid>`，凭证仍留在设备

**位置**
- `lib/core/storage/secure_storage.dart:74-90`（按账号 token 的存取/删除）
- `lib/core/storage/secure_storage.dart:58-65`（`clearCredentials` 只删 token/userid/t1/auth，不含 `acct_token_*`）
- `lib/features/auth/data/auth_repository.dart:282-296`（`removeAccount=false` 时只 `clearCurrent`）

**证据**
```dart
Future<void> clearCredentials() async {
  await Future.wait([
    _storage.delete(key: _kToken),
    _storage.delete(key: _kUserId),
    _storage.delete(key: _kT1),
    _storage.delete(key: _kAuth),
  ]);
}
```
`logout()` 默认 `removeAccount: false`，只删除当前凭证与账号指针，不删除该 userid 的 `acct_token_<userid>`。

**影响**
“退出登录”后，旧账号 token 仍留在 flutter_secure_storage 的 `acct_token_<userid>` 键中；多账号列表也保留。设备被他人使用时，虽然 UI 不提供切回入口（未登录时 `otherAccounts` 为空），但残留凭证扩大了攻击面，且与“退出”语义不符。

---

### A2-16 冷启动 authState 仍 loading 时 `ensureLoggedIn` 误判未登录

**位置**
- `lib/features/auth/presentation/login_guard.dart:15-20`
- `lib/features/auth/data/auth_providers.dart:20-40`（build 内先 `AccountManager.init()` 再 `restoreSession()`，包含网络刷新）

**证据**
```dart
final user = ref.read(authStateProvider).valueOrNull;
if (user != null) return true;
```
`authStateProvider` 的 build 会 `await AccountManager.init()`，随后 `restoreSession()` 发 `/login/token`（最长 15s 连接 + 25s 接收超时）。这段时间 `valueOrNull == null`，但并不是“未登录”。

**影响**
冷启动后立即点收藏/发评论等受守卫操作，已登录用户被弹“请先登录”，跳去登录页；`restoreSession` 完成后 `authState` 变化不会撤销这个弹窗。弱网下窗口可达数十秒。

---

### A2-17 CaptchaPage WebView 无加载失败回调；txappid 缺失时落入“未知类型”死路

**位置**
- `lib/features/auth/presentation/captcha_page.dart:205-225`（`InAppWebView` 只注册 `onLoadStop`，无 `onReceivedError` / `onReceivedHttpError`）
- `lib/features/auth/presentation/captcha_page.dart:226-232`（`_webViewReady` 为 false 时全屏遮罩）
- `lib/features/auth/presentation/captcha_page.dart:169-174`（无 appId → unknown）

**证据**
```dart
onLoadStop: (_, __) => setState(() => _webViewReady = true),
...
if (!_webViewReady || _submitting)
  Container(
    color: Colors.black54,
    child: const Center(child: CircularProgressIndicator()),
  ),
```
`TCaptcha.js` 加载失败、WebView 被杀、网络中断时 `onLoadStop` 不会触发，`_webViewReady` 永远 false，遮罩上的转圈永久覆盖页面，用户无法关闭（只能点 AppBar 关闭）。

**影响**
腾讯验证页在弱网/脚本被拦截时表现为永久 loading；叠加 A2-08，实际用户很可能既看不到验证码也提交不了，只能退出。

此外该页所有文案（“人机验证”“开始验证”“验证未通过，请重试”等）为硬编码中文，与项目 10 语言 i18n 体系不一致；`_snack` 用 `ScaffoldMessenger`，与项目“统一 Toast”约定不一致。

---

### A2-18 验证相关死代码/未使用导入/重复注释

**位置与证据**
- `lib/features/auth/presentation/verification_guard.dart:18`：`runWithVerification` 在 `lib/` 内 **0 个调用点**（`rg` 仅命中定义与文档注释），整条“捕获 20028 → 打开验证 → 自动重试”的通用守卫从未被使用；实际只有登录页、评论页、播放监听三处各自实现。
- `lib/features/auth/data/slider_solver.dart:14-215`：`SliderSolver` / `TrajectoryGenerator` 无任何调用点；`image` 依赖（`pubspec.yaml`）仅为该文件引入。滑块求解能力未接入 `CaptchaPage`（`_buildByType` 对 geetest/酷狗滑块直接走 `_buildExternal`）。
- `lib/core/direct/kg_endpoints_auth.dart:9`：`import 'kg_direct_api_client.dart';` 在文件内无任何符号引用（仅注释提到），属于未使用导入，`flutter analyze` 会产生 warning。
- `lib/core/direct/kg_direct_api_client.dart:604`：`_qrPngBase64` 私有方法无调用点（二维码创建已委托 `_epAuth.qrPngBase64`），属于 unused_element。
- `lib/features/auth/data/verification_service.dart:66-70`：同一段 “P1-6（审查①）…POST…” 注释连续重复两遍。
- `lib/features/auth/data/account_manager.dart:12、22`：`AccountRecord.t1` 字段只在构造/内存使用，`toJson` 不写、`fromJson` 不读，实际是死字段；与 A2-05 的 t1 丢失直接相关。

**影响**
代码维护与 CI 风险：未使用导入/私有成员在严格 `flutter analyze` 配置下会阻断 CI；`runWithVerification` 与滑块求解器给人“能力已具备”的错觉，实际验证链路只有三条分散且不完整的实现。

---

## 覆盖与未覆盖说明

已完整阅读并交叉核对：
`auth_repository.dart`、`auth_providers.dart`、`account_manager.dart`、`secure_storage.dart`、`captcha_types.dart`、`verification_service.dart`、`edt_generator.dart`、`slider_solver.dart`、`captcha_page.dart`、`login_page.dart`、`login_guard.dart`、`verification_guard.dart`、`verification_listener.dart`、`kg_endpoints_auth.dart`、`kg_direct_api_client.dart`、`kg_client.dart`、`kg_crypto.dart`、`kugou_api_client.dart`、`main.dart`、`app_router.dart`，以及设置页账号区块与评论页 20028 分支（下游消费点）。

未执行：构建、测试、真机/接口实测；A2-03 的 pointycastle 默认摘要结论来自 `pointycastle` 源码（`lib/asymmetric/oaep.dart`：`factory OAEPEncoding(engine, [encodingParams]) => OAEPEncoding.withSHA1(...)`），其余结论均来自仓库内代码路径与本地 `KuGouMusicApi` 参考实现的逐行对照。
