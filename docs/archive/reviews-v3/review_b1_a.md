# 批1检1 · 认证账号审查报告（批 1/3 · 纯读）

范围：`lib/features/auth/**`、`lib/core/api/kugou_api_client.dart`、`lib/core/storage/secure_storage.dart`、`lib/core/utils/permission_gate.dart`、`lib/main.dart`（共 9+2 个辅助文件）。
严重度排序：**编译阻塞 > 功能失效 > 安全 > 体验瑕疵 > 代码质量**。

---

## 1. 编译阻塞

### B1-1 ⛔ 未定义方法：`CaptchaPage` 调用 `KugouApiClient.getVerifyInfo` 不存在的路径（次要阻塞风险：验证流程整段死代码引用不存在的 API 形态）
- 位置：`lib/features/auth/presentation/captcha_page.dart:75` → `_service.getVerifyInfo(widget.ssaCode)`
- 该调用链（`verification_service.dart:21` → `_api.get('/get/verify/info', …)`）本身可编译；但**对照** `auth_repository.dart:118-130` 的 `getVerifyInfo` 返回 `VerifyInfo`（v_type/txappid/mobile），与 `verification_service.dart` 的 `VerifySession`（type/verifyUrl/eventId/typeList/sessionid/business）是**两套互不复用的模型**。`auth_repository.getVerifyInfo`、`auth_repository.submitVerify`、`auth_repository.buildTencentVerifyCode` 三个方法在全仓库无任何调用点（已用 rg 确认），属未使用公共 API（DART 公共成员不报 analyzer warning，但审查应记录）。
- 修法：删除 `auth_repository.dart` 中 `getVerifyInfo` / `submitVerify` / `buildTencentVerifyCode`（第 118–163 行），统一以 `VerificationService` + `captcha_types.dart` 为唯一实现；或在 `VerifyInfo` 上加 `@Deprecated` 指向 VerificationService。

### B1-2 ⛔ `KgClient.token/userid/t1` 与登录态同步不完整（auth 链路功能失效，见 F2-1）中 `kgClientProvider` 的存在性
- `main.dart:150-163` 的 `ref.listen` 中 `ref.read(kgClientProvider)` 在**未登录/未创建 client 时**被 try/catch 吞掉（`catch (e) { debugPrint('[auth-sync] $e') }`），若 provider 首次懒加载会直接创建 client——`kg_providers.dart:94` 的 `kgDirectApiProvider` 是普通 Provider，`read` 恒成功。但 `KgClient` 有独立的 `t1` 字段（`kg_client.dart:132`），auth 同步**只写了 token/userid，未写 t1**（见 F2-1）。

无发现会导致 `flutter analyze` 报错的硬编译错误；`flutter_inappwebview 6.1.5` 的 `addJavaScriptHandler(callback: (args) {...})` 签名（`List<dynamic> args → dynamic?`）与代码 `callback: (args) { ...; return null; }` 兼容——上一代理的疑虑可排除。但见 B1-1 的双模型隐患。

---

## 2. 功能失效（登录态最高风险）

### F2-1 ⛔ 退出登录不清 CookieJar 自身实例、且 `AuthRepository.logout` 漏删 dfid + 漏清 KgClient
- 位置：`lib/core/api/kugou_api_client.dart:200-212`
  ```dart
  Future<void> clearCredentials() async {
    await sharedCookieJar.deleteAll();
    mid = '';
    userid = '';
    dfid = '';
  }
  ```
  **问题 1**：`clearCredentials` 永远清的是 `sharedCookieJar`。`AuthRepository` 在无参构造时 `KugouApiClient()` → `_cookieJar = sharedCookieJar` 恰好一致；但实际运行中的 `kugouApiClientProvider` 是 `KgDirectApiClient(kg)`（`providers.dart:9-10` → `kg_providers.dart:94`），其构造 `KgDirectApiClient(this.kg, {super.baseUrl})` **未传 cookieStoragePath**，同样走 sharedCookieJar——这里一致，OK。但若任何调用方传了 `cookieStoragePath`，`clearCredentials` 将清错 jar。应改为 `await _cookieJar.deleteAll();`。
  **问题 2（严重）**：`SecureStorage.clearCredentials()`（`secure_storage.dart:56-63`）删除 token/userid/t1/auth，**不删 dfid**——这是有意保留（dfid 是设备标识），可接受，无问题。真正的问题在 `AuthRepository.logout`（`auth_repository.dart:283-290`）：清了 SecureStorage + `KugouApiClient.clearCredentials`，但：
  - **不重置 `KgClient.token/userid/t1`**（`kg_client.dart:132` 的 `t1`）。虽然 `main.dart:150` 的 `ref.listen` 会在 authState 变化时把 `client.token/userid` 清空，但 **`client.t1` 不会被清**，且 listen 只挂在 `TiernanMusicApp.build` 的 ref 上（挂载期有效，OK），**t1 残留是实打实的退出不彻底**。
  - **不删除 AccountManager 的 `_kCurrent`**：`logout(removeAccount: false)` 时 SecureStorage 清了、但 `accounts` 盒里 `_kCurrent` 仍指向旧账号，下次 `restoreSession` 返回 null 后若 UI 调 `switchAccount` 仍能以旧 token 登录，与「已退出」的 UI 状态矛盾。
- 精确修法（`auth_repository.dart` logout）：
  ```dart
  Future<void> logout({bool removeAccount = false}) async {
    final cred = await _storage.readCredentials();
    if (removeAccount && cred != null) {
      await AccountManager.instance.remove(cred.userId);
    } else {
      await AccountManager.instance.clearCurrent(); // 新增：清 _kCurrent
    }
    await _storage.clearCredentials();
    await _api.clearCredentials();
  }
  ```
  `AccountManager` 新增：
  ```dart
  Future<void> clearCurrent() async {
    await _b.delete(_kCurrent);
  }
  ```
  并在 `main.dart` 的 `ref.listen` 回调中补一行（或改在 auth_providers.logout 里）：
  ```dart
  client.token = user?.token ?? '';
  client.userid = user?.userid ?? '0';
  client.t1 = user?.token == null ? '' : (client.t1); // 退出时清空：见下
  ```
  更干净的写法：`main.dart` listen 内改为
  ```dart
  final user = next.value;
  client.token = user?.token ?? '';
  client.userid = user?.userid ?? '0';
  client.t1 = ''; // AuthUser 不携带 t1，退出即清；登录恢复走 restoreSession→loginByToken 再刷新
  ```
  或给 `AuthUser` 增加 `t1` 字段后同步。**任选其一，但必须显式处理 t1**。

### F2-2 ⛔ 登录成功未把 `auth` cookie 写入 SecureStorage，`restoreSession` 恢复时丢 auth
- 位置：`auth_repository.dart:_handleLoginSuccess`（第 300-322 行）只 `saveCredentials(token/userId/t1/dfid)`，**不传 `auth`**；服务端下发的 `auth` cookie 存在 CookieJar 里（持久化到 documents/cookies），这部分靠 CookieJar 恢复，可接受。但 `KugouApiClient.setCredentials` 支持 `auth` 参数而仓库从不传，属一致性问题：CookieJar 持久化的 auth cookie 与显式 `setCredentials` 写入的并存，键重复时以 `saveFromResponse` 最后一次为准，行为可预期。**降级为记录项**，建议 `_handleLoginSuccess` 中从响应体提取 `d['auth']` 后一并保存：
  ```dart
  final auth = d['auth']?.toString();
  await _storage.saveCredentials(token: token, userId: userid, t1: t1, auth: auth, dfid: dfid);
  await _api.setCredentials(token: token, userid: userid, t1: t1, auth: auth, dfid: dfid);
  ```

### F2-3 ⚠️ `restoreSession` 降级逻辑：`loginByToken` 失败后用 `getUserDetail` 兜底，可能把「网络抖动」误判为已登录、又把「token 真失效」误清
- 位置：`auth_repository.dart:249-274`
  - 第一层：`loginByToken` 失败（任何异常，包括超时）→ 落到 `getUserDetail()`。**超时/断网时 getUserDetail 也会失败 → 进入 `await logout()` → 直接把本地凭证全清掉**。弱网下用户每次冷启动都可能被登出。
  - 修法：区分错误类型，仅当确认凭证无效（ApiException 401 类/特定 error_code）才 logout：
    ```dart
    } on DioException catch (e) {
      final err = e.error;
      final confirmed = err is ApiException &&
          (err.errorCode == 1011 || err.errorCode == 20010 || err.message.contains('token'));
      if (!confirmed) return AuthUser(userid: cred.userId, token: cred.token, nickname: '', avatar: '');
      await logout();
      return null;
    } catch (_) {
      await logout();
      return null;
    }
    ```
    （error_code 具体值需抓包核对，此处给出结构；核心是「网络错误不得清凭证」。）

### F2-4 ⚠️ 密码登录验证码重试：`pop(true)` 返回值被消费 ✅（该点通过）
- `login_page.dart:383-401`：`CaptchaRequiredException` → 有 ssaCode 时 push `CaptchaPage`，`ok == true && mounted` 则 `_login()` 自动重试原请求——**已实现自动重试**。但注意重试后 `return` 跳出 `finally` 前置路径 OK；若 `ssaCode` 为空仅弹 toast（合理）。
- 隐患：`CaptchaPage` 内部同时提供 `onVerified` 回调（页内重试）与 pop(true)（页外重试），两条路并存；`login_page` 走 pop(true) 路径，页内重试路径未被登录页使用，行为正确但属双轨冗余（见 Q5-3）。

### F2-5 ⚠️ 二维码轮询：dispose 时停止 ✅，但切 Tab（TabBarView 惰性）期间仍在轮询
- `login_page.dart:591` `dispose → _pollTimer?.cancel()` ✅；`AutomaticKeepAliveClientMixin.wantKeepAlive=true`（第 470-472 行）意味着**切到短信/密码 Tab 后二维码页不 dispose、Timer 继续每 2s 打 `/login/qr/check`**，直到 status 0/4。用户停留 10 分钟 = 300 次无效请求。
- 修法：监听 `_tabController` 索引，非 qr 时暂停。在 `LoginPage` 的 initState 中：
  ```dart
  _tabController.addListener(() {
    if (!_tabController.indexIsChanging && mounted) setState(() {});
  });
  ```
  并让 `_QrLoginTab` 接收 `active` 参数：`_QrLoginTab(onSuccess: _onLoginSuccess, active: _mode == _LoginMode.qr)`，在 `_QrLoginTabState.didUpdateWidget` 中 `active ? _startPolling() : _pollTimer?.cancel()`。

### F2-6 ⚠️ QR 成功后 `loginByQrToken` 若抛错，用户看不到任何提示
- `login_page.dart:604-613`：`res.status == 4` → `await loginByQrToken(...)` 无 try/catch（外层 catch `_ => {}` 吞掉，`_checkOnce` 的 `catch (_) {}` 在第 616 行）。token 失效/网络错时状态显示「登录成功」但实际没进 `/home`。
- 修法：
  ```dart
  if (res.status == 4) {
    _pollTimer?.cancel();
    try {
      await ref.read(loginControllerProvider.notifier).loginByQrToken(
            token: res.token ?? '', userid: res.userid ?? '');
      widget.onSuccess();
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }
  ```

### F2-7 ⚠️ 短信登录多账号：`MultiAccountException` 流程 ✅ 基本完整
- `login_page.dart:246-263`：捕获后 `_showAccountPicker(e.users)`，选择后递归 `_login(userid: chosen)` ✅；`auth_repository.dart:88-108` 解析 20034/users ✅。**遗漏**：递归时 `_loading` 已在 finally 里复位，但 `loginControllerProvider` 的 `state = AsyncLoading` 会再次设置，OK。唯一问题：若用户在底部弹层取消（chosen == null），无任何提示即静默返回——可接受。

### F2-8 ⚠️ 并发：连续快速点登录 ✅ 基本防护到位
- 三个 Tab 均用 `onPressed: _loading ? null : _login` 禁用按钮 ✅。剩余缝隙：`onSubmitted: (_) => _login()`（键盘回车，`login_page.dart:436`）在 `_loading` 时不检查——密码 Tab 回车可绕过按钮禁用造成重复请求。修法：
  ```dart
  onSubmitted: (_) { if (!_loading) _login(); },
  ```

### F2-9 ⚠️ 验证页 v_type 分支与 WebView
- `captcha_page.dart`：tencent(23)/sms(32)/liveness(22)/face(34)/unknown 走 `_buildByType`，未知类型兜底 `_buildUnknown` ✅。注意 `v_type=38` 在 `captcha_types.dart:fromVType` 无映射 → unknown → `_buildUnknown` 显示「直接尝试提交指纹验证」按钮（`_submitWithCode(s, null)`），不会崩溃 ✅。
- **JS 回调 mounted 检查**：`captcha_page.dart:140-153` 的 `addJavaScriptHandler` callback 内直接 `_submitWithCode(s, code)`，`_submitWithCode` 内有 `if (!mounted) return;` ✅（第 395 行附近）。WebView 若已被 pop，handler 回调触发 `_submitWithCode` → `setState` 前的 mounted 检查可防崩溃 ✅。
- `_extractTxAppId`（第 92-98 行）只解析 `txappid=([0-9]+)`；若服务端返回的 txappid 含字母会提取失败 → 退化为 unknown。建议放宽为 `txappid=([0-9A-Za-z_-]+)`。

---

## 3. 安全

### S3-1 ⚠️ Token/密码无明文落盘 ✅，但错误提示可能泄露
- SecureStorage 用 `AndroidOptions(encryptedSharedPreferences: true)`（`secure_storage.dart:9-11`）✅；token/密码不写 Hive；Hive 只存 nickname/avatar/settings ✅。
- **但**：`AccountRecord.toJson`（`account_manager.dart:26-32`）把**多账号列表的 token 明文写入 Hive box `accounts`**（未加密，Hive 明文二进制可被 root 读取）。与「token 进 SecureStorage」的三层规范冲突。修法：`AccountRecord` 去掉 token 持久化，切换账号时重新走短信/密码登录；或对 token 做 AES 加密后存 Hive。
- `Toast` 错误显示 `'$e'`（`login_page.dart:157` `_showError` 的 fallback `'$e'`）：`DioException.toString()` 包含 `Error: …` 请求信息（ Dio 5 的 toString 会带 error 字段，error 是 `ApiException` 只含 message ✅，但底层 socket 错误如 `SocketException: host …` 会展示）。建议 fallback 改为通用文案：
  ```dart
  final msg = e is ApiException ? e.message
      : e is CaptchaRequiredException ? e.message
      : e is MultiAccountException ? context.l10n.selectAccount
      : context.l10n.operationFailed;
  ```

### S3-2 ✅ 日志
- 全 auth 链路无 `print(token)` / `debugPrint` 输出凭证；`KugouApiClient` 不打印请求体。通过。

---

## 4. 体验瑕疵

### X4-1 ⚠️ 60s 倒计时未处理切 Tab / dispose ✅ dispose 已清（`login_page.dart:216`），但**切走短信 Tab 再回来**，倒计时继续走（widget 未 dispose），这是合理行为 ✅。真正的瑕疵：`_sendCode` 失败后无冷却但可立即重发 ✅ 合理；倒计时文本 `resendIn(_countdown)` 每秒 `setState` 导致整页重建——切到 `ListView` 重建 TextField，**输入中的验证码会保留（controller 持有）✅**。通过，无修改。

### X4-2 ⚠️ 手机号校验 `^1\d{10}$` 限大陆号段 ✅（与 `phoneHintCn` 一致）；若面向海外（有 10 语言 ARB），应放宽。建议文案与校验一致即可，不改。

### X4-3 ⚠️ 二维码轮询 2s 固定间隔略激进（酷狗常见 3s）；且 `_checkOnce` 网络慢时可能重叠请求（Timer.periodic 不等上次完成）。修法改自驱动循环：
  ```dart
  Future<void> _pollOnce() async {
    if (!mounted) return;
    await _checkOnce();
    if (mounted && _status != 0 && _status != 4) {
      _pollTimer = Timer(const Duration(seconds: 3), _pollOnce);
    }
  }
  ```

---

## 5. 代码质量

### Q5-1 `catch (_) {}` 清单（吞错）：
- `auth_repository.dart:65`（getDfid 兜底返回 '-'，可接受但 '-' 作为 dfid 发请求会被服务端拒绝，建议返回空并让调用方判断）
- `auth_repository.dart:320-322`（写 settings 盒失败吞掉 → 设置页显示旧昵称，可接受）
- `login_page.dart:616`（QR 轮询吞错，配合 F2-6 修）
- `main.dart` 多处启动兜底 catch ✅ 设计如此（有 debugPrint），通过。
- `verification_service.dart:63-66`：`if (e.error is ApiException) return false; rethrow;` ✅ 未吞。

### Q5-2 `AuthRepository.getDfid` 返回 `'-'` 占位符（第 66 行）会被写进 SecureStorage 与 cookie，后续 `readDfid` 拿到 '-' 永远不再重试获取。修法：失败时返回空串且不落盘：
```dart
} catch (_) {}
return ''; // 不写 '-'
```

### Q5-3 未使用代码：`auth_repository.getVerifyInfo/submitVerify/buildTencentVerifyCode`（见 B1-1）；`KugouApiClient.webglHash` 供 VerificationService 用 ✅ 在用；`PermissionGate.requestWithPrompt/openSettings`（`permission_gate.dart:70-90`）在 settings_page 外无调用——保留，无碍。

### Q5-4 dispose 检查 ✅ 全通过：
- `_LoginPageState.dispose`：_tabController ✅
- `_SmsLoginTabState`：_timer + 2 个 controller ✅
- `_PasswordLoginTabState`：2 个 controller ✅
- `_QrLoginTabState`：_pollTimer ✅（切 Tab 不停见 F2-5）
- `_CaptchaPageState`：_smsCodeCtrl ✅；InAppWebView 由框架管理 ✅

### Q5-5 ARB key 一致性 ✅：登录 UI 用到的 30 个 l10n key（phoneInvalid/codeInvalid/smsCodeSent/resendIn/selectAccount/qrExpired/qrScanSuccess/loginSuccess/qrScanHint/qrExpiredShort/refreshQr/qrLoadFailed 等）在 `app_zh.arb` 全部存在（已逐一核对）；`captcha_page.dart` 硬编码中文（『人机验证』『重试』等）未走 l10n——与登录页不一致，建议补 key。

### Q5-6 `main.dart` ref.listen 同步 KgClient：只同步 token/userid，漏 t1（见 F2-1）；`next.isLoading` 跳过 ✅ 正确防误清。

---

## 通过项汇总
1. SecureStorage key 读写一致（`_kToken/_kUserId/_kT1/_kAuth/_kDfid` 常量统一）且启用 encryptedSharedPreferences。
2. 登录成功链路 `saveCredentials` + `api.setCredentials` 均调用；AccountManager.upsert 并设 current ✅。
3. 共享 CookieJar（`sharedCookieJar`）设计正确，解决了「多实例各建 jar 导致登录态不可见」问题；`kgDirectApiProvider` 未传自定义路径，实际全走共享 jar ✅。
4. 多账号选择（20034 → bottom sheet → 带 userid 重登）完整。
5. 密码登录 20028 → CaptchaPage → pop(true) → 自动重试原登录 ✅。
6. QR 状态映射 0/1/2/4 齐全，过期显示刷新按钮 ✅。
7. 所有 Timer/TabController/TextEditingController dispose 齐全。
8. ARB key 与登录 UI 完全一致；10 语言文件齐全。
9. 密码不落盘、日志无凭证输出。
10. `main.dart` 启动兜底（runApp 一定执行、看门狗、错误页）设计良好。

## 修复优先级
| 级别 | 项 |
|---|---|
| P0 | F2-1（退出不清 t1/_kCurrent/KgClient）、F2-3（弱网误清凭证） |
| P1 | S3-1（accounts 盒明文 token）、F2-6（QR 成功后吞错）、B1-1（双验证模型去重） |
| P2 | F2-5（切 Tab 停轮询）、F2-9（txappid 正则）、Q5-2（dfid='-'） |
| P3 | X4-3（QR 自驱动轮询）、F2-2（auth cookie 持久化）、Q5-5（captcha_page l10n）、F2-8（回车并发） |
