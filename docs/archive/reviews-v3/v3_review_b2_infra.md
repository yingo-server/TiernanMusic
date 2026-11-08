# 第6批·审查①：core 基础设施全量复核（v3.0 终审 B-2 视角）

## 审查元信息

- 工作目录：`/var/minis/workspace/TiernanMusic`
- 基线 commit：`8c6a084`（当前 HEAD `420664e`；`git diff --stat 8c6a084 HEAD -- lib/` 为空，
  `lib/core` 源码与基线完全一致，仅 docs/ 新增了 b1 报告，故本报告结论对基线成立）
- 判定依据：`docs/QUALITY_STANDARD.md`（32 条）
- 方法：每个文件均 `file_read` 从第 1 行读到末行；行号定位为事后核对，未抽样。
- **未读取** `docs/batch1~4_*`、`docs/check_*`、`docs/v3_review_b1_*`（防锚定）。
- 范围勘误：任务书列的 `lib/core/storage/app_image_cache.dart` **不存在**，
  实际位于 **`lib/core/image/app_image_cache.dart`**（已 `ls` 确认，按此路径审）。

### 已完整阅读的文件

| 文件 | 行数 |
|---|---|
| `lib/core/api/kugou_api_client.dart` | 212 |
| `lib/core/api/translate_api.dart` | 63 |
| `lib/core/utils/error_logger.dart` | 274 |
| `lib/core/utils/toast.dart` | 139 |
| `lib/core/utils/friendly_error.dart` | 33 |
| `lib/core/storage/secure_storage.dart` | 102 |
| `lib/core/image/app_image_cache.dart` | 73 |
| `lib/core/audio/preferred_quality.dart` | 18 |
| `lib/core/theme/app_theme.dart` | 278 |
| `lib/core/providers.dart` | 25 |
| `lib/core/direct/kg_providers.dart` | 98 |
| `lib/core/router/app_router.dart` | 134 |
| 佐证（为判定单一来源/缓存键/生命周期而完整读） | `cache_manager.dart` 110、`app_config.dart` 56、`settings_provider.dart` 105、`audio_service_bootstrap.dart` 74、`permission_gate.dart` 92、`main.dart` 336、`kg_client.dart` 547、`kg_direct_api_client.dart` 681（仅取凭证/日志段落，直连层结论不重复评审）、`auth_repository.dart` 390、`auth_providers.dart` 134、`account_manager.dart` 188、`lyric_repository.dart` 236、`player_repository.dart` 25–94、`storage_permission_service.dart` 1–80、`settings_page.dart` 118–147 |

### 一句话结论

基础设施层**没有新增崩溃点，但存在两类系统性缺陷**：
(1) **设备身份 dfid 有 4 份权威存储、5 个写入点**，互相覆盖；
(2) **日志落公共 Documents 目录，而脱敏正则对 JSON 引号形态与手机号可证明失效**，
同时业务侧唯一的接口错误入口 `logApi()` 无人调用——「有脱敏的管道没输入、
有输入的场景没脱敏」。

---

## 一、分层与依赖注入（第 1 / 2 / 4 条）

### B-01 `lib/core/providers.dart`:3 core 公共 provider 文件反向 import features
- 级别：P2
- 事实：
  ```dart
  import '../features/lyric/data/lyric_repository.dart';
  ...
  final lyricRepositoryProvider = Provider<LyricRepository>((ref) =>
      LyricRepository(ref.watch(kugouApiClientProvider), ref.watch(translateApiProvider)));
  ```
  `LyricRepository` 自身又 `import '../../../core/api/kugou_api_client.dart'` 与
  `core/cache/cache_manager.dart`（`lyric_repository.dart`:7–10）。
- 违反：第 4 条（分层单向依赖，不得回流）。
- 后果：`core/providers.dart` 是全局 API 装配点，却是 **core→features→core 的双向依赖**；
  任何 lyrics 业务改动都要重编 core 装配，core 无法被单独裁剪/测试。用户侧表现为
  「一个歌词小改动导致整个 app 需全量重建、内测包启动路径随之变化」，属于维护成本而非功能故障，故定 P2 而非 P1。

### B-02 `lib/core/router/app_router.dart`:5–19 路由层直接 import 16 个 features 页面
- 级别：P2
- 事实：`login_page / artist_page / album_page / rank_detail_page / home_page /
  full_player_page / search_page / settings_page / playlist_detail_page / comments_page /
  mv_player_page / library_page / mini_player / download_page` 全部在 core 文件顶部静态 import。
- 违反：第 4 条。
- 后果：core 层与界面层紧耦合，路由表与页面构造函数形成「编译期全连接」——
  任一页面的构造参数变更会同时打断 core 编译；无法在不引入 UI 的前提下复用路由常量。

### B-03 `lib/core/audio/preferred_quality.dart`:4 「读设置」这件 core 事依赖 features 的枚举
- 级别：P2
- 事实：
  ```dart
  import '../../features/player/data/models.dart';
  AudioQuality preferredQuality() { ... AudioQuality.fromString(v) ... }
  ```
- 违反：第 4 条（core/audio 引用业务模块 player）。
- 后果：core 的音频层必须连带 player 业务模型才能编译；`AudioQuality` 一旦增加音质档位，
  core 音频层随之需要重建。文件注释自称「单一事实源」，但它同时是跨层的第二份权威读路径（见 B-35）。

### B-04 `lib/core/utils/error_logger.dart`:8 日志器依赖下载业务模块
- 级别：P2
- 事实：
  ```dart
  import '../../features/download/data/storage_permission_service.dart';
  ```
  仅用其中的 `StoragePermissionService.instance.currentStrategy()`（:158）与 `apiLevel()`（:268）。
- 违反：第 4 条。
- 后果：全局错误处理（最先初始化、最不该失败的一层）被绑死在「下载」业务上；
  下载模块的依赖（permission_handler / 原生通道）异常会经此路径传染日志器，
  用户侧表现为「出错时连日志都写不出来」。同一个 core 文件还第二次跨层调用
  `features/download`（`permission_gate.dart`:8 亦同），说明这不是孤例而是既成模式。

### B-05 `lib/core/utils/permission_gate.dart`:8 权限门卫同样是 core→features
- 级别：P3
- 事实：`import '../../features/download/data/storage_permission_service.dart';`
- 违反：第 4 条。
- 后果：权限判定被拆成「core 的 UI 门卫 + features 的判定服务」两半，二者必须成对发布；
  单独引用 core 的调用方会缺判定实现。无直接用户可见后果，故 P3。

### B-06 `lib/core/utils/toast.dart`:6 轻提示依赖 l10n 生成层
- 级别：P3
- 事实：`import '../../l10n/l10n.dart';`，仅 `copy()` 用到 `context.l10n.copiedToClipboard`。
- 违反：第 1 条（一个单元只做一件事：Toast 既做提示又做剪贴板复制并自带文案）。
- 后果：无用户可见后果；但 core 最底层的提示组件被绑定到生成代码，l10n 重建会波及 core。

### B-07 `lib/core/api/kugou_api_client.dart`:147 + `lib/main.dart`:88 Cookie 存储路径是可变全局，晚设置即静默退化
- 级别：P1
- 事实：
  ```dart
  static CookieJar get sharedCookieJar => _sharedJar ??= _createCookieJar(null);   // :144
  static String? cookieStoragePath;                                                // :147
  ```
  `main()` 在 `runApp` 前 `KugouApiClient.cookieStoragePath = cookieDir.path`（main.dart:88）。
  `_createCookieJar` 失败时 `catch (_) {}` 后直接 `return CookieJar()`（:123–131，内存 jar）。
  **首次访问 `sharedCookieJar` 的那一刻**决定此后整个进程是否持久化 cookie；
  之后再改 `cookieStoragePath` 已无效，且**没有任何日志**。
- 违反：第 2 条（隐式依赖：持久化与否取决于「谁先构造客户端」这一时序）；
  并连带第 9 条（静默降级不留痕）。
- 后果：一旦 `getApplicationDocumentsDirectory()` 慢于第一帧的客户端构造（冷启动/低端机常见），
  整个进程使用内存 CookieJar → **用户下次冷启动被判定未登录**，需要重新扫码/短信登录；
  且日志里查不到任何线索。

### B-08 `lib/core/api/kugou_api_client.dart`:40–45 基类默认打到 kapi 中转域，且默认构造是「合法路径」
- 级别：P2
- 事实：
  ```dart
  _dio = Dio(BaseOptions(baseUrl: baseUrl ?? AppConfig.kugouApiBase, ...))
  ```
  `AppConfig.kugouApiBase = 'https://kapi.344977.xyz'`（app_config.dart:15）；
  `AuthRepository({KugouApiClient? api}) : _api = api ?? KugouApiClient()`（auth_repository.dart:57–58）。
- 违反：第 2 条（可空依赖在内部自行构造协作者）+ 第 27 条（中转网关不得作为实现）。
- 后果：任何一处漏注入 `kugouApiClientProvider` 的调用点会**静默走第三方中转**并把
  token/userid 交给中转服务器；因为直连子类对未移植路径抛 `-404`，这类漏注入只会表现为
  「接口全部报未移植」，排查方向被误导。当前仅 auth_repository 的可选参数构成风险面，
  且生产路径已注入，故 P2。

### B-09 `lib/core/providers.dart`:11–12 `TranslateApi` 无注入点、硬编码第三方地址与模型
- 级别：P2
- 事实：
  ```dart
  final translateApiProvider = Provider<TranslateApi>((ref) => TranslateApi());
  ```
  `TranslateApi()` 内部自建 `Dio`，地址取 `AppConfig.translateApiBase`
  （`https://index-translate.bilibili.com/v1/chat/completions`），模型取
  `AppConfig.translateModel`，两者均为 `const`，**无设置项、无开关、无替换点**。
- 违反：第 2 条（依赖必须由构造参数或注入传入）。
- 后果：歌词翻译必然把整段歌词发往固定的第三方服务，用户无法关闭、无法换源；
  该域名限流/改协议时翻译整体失效，且只能改代码发版才能修复。

---

## 二、状态单一来源（第 5 条）：dfid / token / cookie

### B-10 `lib/core/storage/secure_storage.dart`:16–17 + `lib/core/direct/kg_providers.dart`:54 dfid 有 4 份权威存储、5 个写入点
- 级别：P1
- 事实：
  | 存储/字段 | 写入点 |
  |---|---|
  | `SecureStorage._kDfid`（key `dfid`） | `saveDfid()`（secure_storage:67）← auth_repository:74、player_repository:54 |
  | 同上，随登录凭证一并写 | `saveCredentials(dfid:)`（secure_storage:40）← auth_repository:322 |
  | Hive box `device` 的 `device.dfid` | `KgDeviceStore.saveDfidSync()`（kg_providers:54–71）← `KgClient.onDfidRegistered`（kg_providers:84–88） |
  | `KgClient.dfid`（内存） | `KgDirectApiClient.setCredentials`（`kg_direct_api_client.dart`:45） |
  | `KugouApiClient.dfid` + Cookie `dfid` | `KugouApiClient.setCredentials`（:185–204） |

  且两处注册路径拿到的 dfid 不同源：`AuthRepository.getDfid()` / `PlayerRepository.ensureDfid()`
  走 **kapi `'/register/dev'`** 并只写 SecureStorage；`KgClient.registerDevice()`
  走 **userservice 原生 `risk/v3/r_register_dev`** 并只写 Hive。
  而签名/请求头全部读 `device.dfid`（`kg_client.dart`:190、:210、:262）。
  `KgDirectApiClient.setCredentials` 又把 SecureStorage 里的 dfid **反向覆盖** `kg.device.dfid`
  （`kg_direct_api_client.dart`:44–49）。
- 违反：第 5 条（同一份事实只能有一处权威存储；在多于一处被修改即判定为缺陷）。
- 后果：可直接推导出的顺序是——首次播放/登录注册出 dfid-A 写入 SecureStorage，
  登录时 `setCredentials` 用它覆盖 Hive 的 dfid-B；此后原生注册又生成 dfid-C 只写 Hive；
  下次冷启动 `restoreSession` 又拿 SecureStorage 里的 dfid-A 覆盖回去。
  即 **每次冷启动设备标识在两个值之间来回跳变**。酷狗侧判为新设备 → 播放地址被降权、
  频繁触发短信/人机验证、`/song/url` 只返回试听片段。这是本批影响最大的基础设施缺陷。

### B-11 `lib/core/storage/secure_storage.dart`:58 登出只清 4 个键，账号 token 与 dfid 永久残留
- 级别：P1
- 事实：
  ```dart
  Future<void> clearCredentials() async {
    await Future.wait([
      _storage.delete(key: _kToken), _storage.delete(key: _kUserId),
      _storage.delete(key: _kT1),    _storage.delete(key: _kAuth),
    ]);   // 未删 _kDfid，未删 acct_token_<userid>
  }
  ```
  `deleteAccountToken`（:85）只在 `AuthRepository.logout(removeAccount: true)` 时调用
  （auth_repository.dart:288–292）；普通「退出登录」走 `removeAccount: false`，
  只 `clearCurrent()` + `clearCredentials()`，`acct_token_*` 全部保留。
- 违反：第 5 条（凭证事实存在两处：当前会话凭证与按 userid 的账号 token，登出只清一处）；
  同时违反第 20 条（写入/清除不对称：`saveCredentials` 会写 dfid，`clearCredentials` 不删 dfid）。
- 后果：用户点「退出登录」后，其 token 仍以可解密形式留在设备上；任何人打开
  「账号切换」即可用 `switchAccount()`（auth_providers.dart:79–96）**无需密码/验证码直接恢复该账号**。
  共享设备/转手设备场景下等于账号仍处于登录态。属于安全残留，定 P1。

### B-12 `lib/core/direct/kg_providers.dart`:74–78 设备身份兜底每次启动重新生成
- 级别：P2
- 事实：
  ```dart
  final kgDeviceProvider = Provider<KgDevice>((ref) {
    return KgDevice.generate();   // 注释：内存临时设备，不持久化
  });
  ```
  `main()` 只有在 `kgDeviceProvider.overrideWithValue(dev)` 成功时才注入真实设备；
  `device == null` 的极端分支（main.dart:143–158）只写 `_startupError`，不阻止 runApp
  （`overrides` 用 `if (dev != null)` 条件构造，main.dart:160–162）。
- 违反：第 5 条（「设备身份」存在持久化与进程内两份，后者可静默生效）
  + 第 9 条（该降级无日志、无用户提示）。
- 后果：Hive 设备箱打开失败时，App 仍能启动但**每次冷启动都是全新 guid/mid、dfid 为 `-`**，
  表现为「登录态随机丢失、每次都要重新验证、播放权限异常」，且日志中无任何痕迹。

### B-13 `lib/core/direct/kg_providers.dart`:35 设备首次落盘不等待写入完成
- 级别：P2
- 事实：
  ```dart
  final device = KgDevice.generate();
  box.put(_key, jsonEncode(device.toJson()));   // 返回的 Future 被丢弃
  return device;
  ```
- 违反：第 9 条（写入失败不可观测）+ 第 5 条（内存身份与持久化身份可能不一致）。
- 后果：首次启动若进程在 put 落盘前被杀（首帧前后本是最容易被杀的时间窗），下次启动重新生成，
  再次成为「新设备」。用户表现为「装好第一次登录成功，杀掉重开却掉登录」。

### B-14 `lib/core/direct/kg_providers.dart`:54–71 / :86 `saveDfidSync` 的失败被完全吞掉
- 级别：P2
- 事实：
  ```dart
  static bool saveDfidSync(String dfid) { ... }   // 空串/box 未开/异常 → false
  client.onDfidRegistered = (dfid) { KgDeviceStore.saveDfidSync(dfid); };  // 返回值未检查
  ```
- 违反：第 6 条（捕获后既不转译、也不记录）+ 第 9 条。
- 后果：注册成功但落盘失败时，App 静默继续用 `dfid='-'` 请求；用户看到的是
  「刚登录就提示需要验证 / 歌曲只有试听」，日志里查不到原因。

### B-15 `lib/core/cache/cache_manager.dart`:64 内存缓存键不含用户身份
- 级别：P2
- 事实：
  ```dart
  static String keyOf(String path, [Map<String, dynamic>? query]) => '$path?...';
  ```
  键 = path + 排序后的 query；无 userid、无账号世代。跨账号正确性依赖人工清缓存
  （`settings_page.dart`:134 `MemoryCache.instance.clear()` 只在「清除缓存」里做，
  `main.dart`:210 只在内存压力时做）。
- 违反：第 23 条（缓存键必须覆盖全部影响结果的维度——用户身份是第一维）。
- 后果：`/playlist/track/all`、`/user/playlist` 等按账号裁剪的响应一旦进缓存，
  **切号/退出登录后 90 秒内仍返回上一账号的数据**；目前靠「用户主动清缓存」兜底，
  属人工补救而非键维度。

### B-16 `lib/core/api/kugou_api_client.dart`:185–204 `setCredentials` 三处状态各自更新
- 级别：P2
- 事实：
  ```dart
  await _cookieJar.saveFromResponse(uri, cookies);
  this.userid = userid;
  if (dfid != null) this.dfid = dfid;
  ```
  同名事实同时存在于：CookieJar、`this.userid/dfid` 字段、`KgClient.token/userid/dfid`
  （`kg_direct_api_client.dart`:33–50 覆写里再同步一次）、`SecureStorage`。
  `clearCredentials()` 只清 `_cookieJar` 与两个字段，不动 SecureStorage（后者由
  `AuthRepository.logout` 另行调用），两条清理路径必须成对调用才等价。
- 违反：第 5 条。
- 后果：任何一处忘记成对调用（例如未来新增「强制下号」入口只调 `api.clearCredentials()`），
  就会出现「cookie 已清、内存字段已清、SecureStorage 仍有 token」的半登出态：
  冷启动 `restoreSession` 把用户又登回去，用户看到「退出登录无效」。

---

## 三、失败可观测与日志安全（第 9 / 6 / 14 条）

### B-17 `lib/core/utils/error_logger.dart`:189 脱敏正则对 JSON 引号形态完全失效，落盘目录是公共可分享区
- 级别：P1（凭据泄露风险；当前入口收窄，未见已被触发的调用点，故不判 P0）
- 事实：
  ```dart
  static String _redact(String s) {
    s = s.replaceAllMapped(RegExp(
      r'((?:authorization|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|sign(ature)?|cookie|session(?:_id)?)\s*[=:]\s*)(?:"([^"]*)"|(\S+))',
      caseSensitive: false), (m) => '${m.group(1)}***');
  ```
  键名后要求 `\s*[=:]`，但 JSON 形态是 `"token":"..."`——键名闭合引号夹在中间，`\s*[=:]` 不匹配。
  实测（同正则等价实现，逐条验证）：
  ```
  {"token":"abc123","userid":"9"}          -> {"token":"abc123","userid":"9"}     ← 未脱敏
  {"access_token":"abc123"}                -> {"access_token":"abc123"}           ← 未脱敏
  .../login/token?token=abc&userid=9       -> .../login/token?token=***           ← 正常
  Cookie: token=abc; userid=9              -> Cookie: *** userid=9                ← 正常
  mobile=13800138000                       -> mobile=13800138000                  ← 未脱敏
  ```
  日志落点：Android 10+ 写 **MediaStore Downloads**、≤9 写 **公共 Documents**
  （:41–49 注释明示「文件管理器可见，且用户可能分享」）。
  `logApi()` 的 `body` 也被同一正则处理（:217），而登录/刷新 token 的响应体正是 JSON。
- 违反：第 9 条（可观测性不得以泄露凭据为代价；「脱敏」这一承诺在 JSON 形态上不成立）
  + 第 14 条（落盘属于数据边界，未按敏感级别处理）。
- 触发路径（诚实界定）：`ErrorLogger.log()` 目前只有两个入口——
  `FlutterError.onError`（main.dart:44）与 `runZonedGuarded`（main.dart:169），
  二者传入的是未捕获异常的 `toString`/`context`；`logApi()`（:207）本来正是
  「把接口响应体交给脱敏函数」的现成入口，**只因当前无人调用**（见 B-41）才没有立刻被触发。
  一旦有调用点把响应体、或带查询串的 `DioException` 文本交给 `log()`/`logApi()`，
  凭据即以明文进入日志。
- 后果：日志的落点是 MediaStore Downloads / 公共 Documents（文件管理器可见、
  用户会用来「把日志发给客服」）。脱敏函数在 JSON 形态上可证明失效（上方实测），
  等于**这条通往公开目录的管道没有任何有效的凭据过滤**；
  一旦任何异常文本里带出 `"token":"…"` 或 `mobile=…`，就是明文凭据/手机号被用户转发出去。
  风险等级取决于「是否有人调用」，故定 P1 并要求与 B-41 一并修复。

### B-18 `lib/core/utils/error_logger.dart`:189 脱敏不覆盖手机号，与「日志脱敏」目标不符
- 级别：P2
- 事实：同一正则的键白名单只有 `authorization/token/api_key/secret/sign/cookie/session`，
  没有 `mobile|phone|tel|userid|dfid`；`log()` 的 `context` 由调用方自由拼接（:79–84），
  `AuthRepository.sendSmsCode(mobile)` 的错误上下文会原样带出 11 位号码。
- 违反：第 9 条（可观测性设计未定义「哪些字段属敏感」）。
- 后果：与 B-17 同一条落盘通道，手机号长期留存在可分享文件中；属于隐私泄露面，
  但因不含登录凭据，单独定 P2。

### B-19 `lib/core/direct/kg_direct_api_client.dart`:138 诊断列表只写不读、且不脱敏
- 级别：P1
- 事实：
  ```dart
  static final List<String> lastErrors = <String>[];
  void _logError(String where, Object e) {
    final msg = '[${DateTime.now().toIso8601String()}] $where: $e';
    lastErrors.insert(0, msg);
    if (lastErrors.length > 20) lastErrors.removeLast();   // 上限有，读者无
  }
  ```
  全仓检索 `lastErrors` 只有本文件 3 处（写入/截断/声明），**没有任何读取方**——
  「供『网络诊断』页展示」的注释（:137）没有对应实现。
- 违反：第 9 条（失败要么用户可见、要么日志可查；这里是「写进一个没人读的内存表」）
  + 第 32 条（无人读取的状态即死代码）。
- 后果：用户在设置页点「网络诊断」看不到任何直连失败记录，只能拿到「最近未发生错误」类
  的空结论；出问题时既没有 UI 反馈也没有可检索的日志（`debugPrint` 在 release 不落盘），
  等同于**直连失败完全不可观测**。同时该表还保存了未脱敏的异常文本，若将来接上 UI 会直接
  把 token 展示给用户。

### B-20 `lib/core/utils/error_logger.dart`:101 私有目录不可用时日志被直接丢弃
- 级别：P2
- 事实：
  ```dart
  await init();
  if (await _appendPublic(fileName, text)) return;
  final dir = _fallbackDir;
  if (dir == null) return;      // 只 debugPrint 过一次，release 无输出
  ```
  `_recent` 里保留了这条文本（上限 200，诊断页 `settings_page.dart`:773 会读），
  但那只是**进程内**副本，重启即失、且无法导出成文件提供给开发者。
- 违反：第 9 条（失败必须可观测，二者至少其一——此处的「日志」在最常见形态
  「用户把日志文件发给客服」上不成立）。
- 后果：当公共目录写入失败且私有目录创建失败（存储被占满、目录被清理工具删掉）时，
  **可导出的崩溃日志彻底消失**，只剩一个重启即清的诊断页列表。用户报「闪退」时
  开发者手里只有 200 条近期文本，且下一次启动就没了。

### B-21 `lib/core/utils/error_logger.dart`:264 API 级别兜底默认 29，判错分区
- 级别：P2
- 事实：
  ```dart
  static Future<int> get apiLevel async {
    try { final level = await StoragePermissionService.instance.apiLevel();
          if (level > 0) return level; } catch (_) {}
    return 29;   // 通道与服务都失败时假定 Android 10+
  }
  ```
  同时 `StoragePermissionService._apiLevelFromOsVersion` 对 Android 9 返回 `9`（而非 API 28），
  注释却写「Android 9 == API 28」（storage_permission_service.dart:60–66）。
- 违反：第 6 条（空体捕获）+ 第 15 条（版本名与 API level 两种单位混用，未在类型/命名上区分）。
- 后果：通道异常时一律按 `level>=29` 走 MediaStore 分支，在 Android 9 真机上
  MediaStore `appendText` 必然失败 → 日志静默降级；且 `_apiLevel` 被缓存，
  一次误判影响整个进程。用户侧表现为「这台老机器永远没有日志」。

### B-22 `lib/core/utils/error_logger.dart`:66 并发写入无串行/锁
- 级别：P2
- 事实：`log()` 是 `async`，多处 `unawaited(log(...))`（:243、:252），每次独立执行
  「读长度 → 可能轮转 rename → append」。Android 10+ 分支把「读旧内容 + 轮转 + 整份重写」
  交给原生（:160–176），两条日志并发时会读改写同一文件。
- 违反：第 22 条（并发假设必须写明并保护；此处隐含「同一时刻只有一条日志」的假设）。
- 后果：首页并发拉图时 `SQLITE_BUSY` 一次刷几十条错误日志（见 B-28），
  并发读改写会丢条目甚至互相覆盖；用户/开发者看到的日志残缺，排障结论被误导。

### B-23 `lib/core/utils/toast.dart`:24–27 同类提示 3 秒内静默丢弃
- 级别：P2
- 事实：
  ```dart
  final last = _lastShown[msg];
  if (last != null && now.difference(last) < _dedupeWindow) return;   // 无任何留痕
  ```
- 违反：第 9 条（静默丢弃反馈且不留痕）。
- 后果：连续两次触发同一错误（「登录已过期，请重新登录」「下载失败」）时，第二次
  **完全没有提示**；用户会认为「点了没反应」，尤其在只有一条 toast 的情况下。
  去重本身合理，但应对「关键级别消息」豁免或至少计数。

### B-24 `lib/core/utils/toast.dart`:29–33 去重表上限形同虚设
- 级别：P3
- 事实：
  ```dart
  if (_lastShown.length > 64) {
    _lastShown.removeWhere((_, t) => now.difference(t) >= _dedupeWindow);
  }
  ```
  若 64 条都在 3 秒窗口内，`removeWhere` 一条也删不掉，表继续增长。
- 违反：第 25 条（所有资源必须有上限；此处上限只在「恰有过期项」时生效）。
- 后果：批量失败场景（一次几十条不同文案）下 map 只增不减；单条字符串很小，
  实际泄漏有限，故 P3。

### B-25 `lib/core/utils/friendly_error.dart`:20 非 ApiException 一律退化为同一句文案
- 级别：P2
- 事实：
  ```dart
  if (api != null) { ... return switch (api.errorCode) { 1011 || 30791 || 401 => '登录已过期，请重新登录', _ => api.message }; }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
  ```
  `unwrapApi` 只解一层 `DioException.error`；`api.message` 直接取自上游
  `error_msg/errmsg/info`，可能是空串（`kugou_api_client.dart`:106 的默认值只在全缺省时生效）。
- 违反：第 8 条（异常契约必须单一且稳定——UI 只认一种包装形态，其它形态全部塌缩为同一文案）
  + 第 16 条（「失败原因未知」与「明确错误」被映射成同一展示）。
- 后果：超时、断网、签名失败、上游英文错误体都会显示「操作失败，请稍后重试」或英文原文；
  `api.message` 为空时 toast 变成空白气泡，用户看到「弹出一下就没了」。
  错误码不进任何埋点，客服无法据此判断是网络问题还是账号问题。

---

## 四、缓存（第 23 / 25 / 31 条）

### B-26 `lib/core/image/app_image_cache.dart`:68–72 声称串行化的 `getFileStream` 实际没有串行任何写入
- 级别：P2
- 事实：
  ```dart
  @override
  Stream<FileResponse> getFileStream(String url, {...}) async* {
    await _serial(() async {});
    yield* super.getFileStream(url, key: key, headers: headers, withProgress: withProgress);
  }
  ```
  入队的 action 是**空函数**，只能保证「多个调用轮流开始」；`super.getFileStream` 内部
  （`flutter_cache_manager` 的 `_getFileStream`）是在 **stream 被监听之后**才查询/写入 sqflite，
  这一步完全在队列之外，多个流可以同时在同一个 DB 上开事务。
  文件头注释（:6–22）明确宣称「把下载/写入操作串行化 —— 同一时刻只有一个 DB 事务，彻底消除 BUSY」。
- 违反：第 31 条（注释必须解释真实行为；此处注释描述了不存在的机制）
  + 第 1 条（`_serial` 只包住「开始」，未包住它声称要保护的副作用）。
- 后果：首页/歌单一次并发拉几十张封面时 `SQLITE_BUSY` 依旧出现（注释里引用的原始报错），
  被全局错误处理写进日志并刷屏（每次几十条，正好撞上 B-22 的并发写日志问题）；
  用户侧表现为封面加载慢、个别封面空白重试。作者以为已修复，后续不会再有人来查这条链路。

### B-27 `lib/core/image/app_image_cache.dart`:3–4 用 `package:file` 的 `File` 覆写 `dart:io` 的 `File`
- 级别：P2
- 事实：
  ```dart
  import 'package:file/file.dart';
  ...
  Future<File> getSingleFile(String url, {String? key, Map<String, String>? headers})
  ```
  父类 `CacheManager.getSingleFile` 返回 `Future<dart:io.File>`；
  `package:file` 的 `File` 是**另一个类型**（抽象接口），两者只有 `FileSystemEntity` 概念上的相似，
  不构成子类型关系。因此该 override 只有两种可能：
  或编译期 `invalid_override`（返回类型不兼容），或实际解析到的是 `dart:io` 的同名 `File`
  ——那这个 import 就是纯死导入（本文件其余代码未使用 `package:file` 的任何 API）。
- 违反：第 3 条（跨层契约必须先行：覆写签名与父类契约不一致）
  + 第 32 条（若解析到 dart:io，则此 import 为死代码）。
- 后果：两种情况都有代价——前者是**整包无法构建**；后者是误导后来者以为这里用
  `package:file` 抽象层（进而写出与 `CacheManager` 不兼容的代码）。图片缓存是首页首屏路径，
  任何构建问题都直接表现为「App 装不上/首屏无图」。

### B-28 `lib/core/image/app_image_cache.dart`:27–31 只有条目数上限，没有体积上限；清理绕开 CacheManager API
- 级别：P2
- 事实：
  ```dart
  AppImageCache._() : super(Config('tiernanImageCache',
      stalePeriod: const Duration(days: 30), maxNrOfCacheObjects: 600));
  ```
  - 600 条 × 30 天留存，**无字节上限**、无解码尺寸约束
    （`CachedNetworkImage` 的 `memCacheWidth` 由各调用方自行决定）；
  - 应用内唯一的「清除缓存」（`settings_page.dart`:124–154）清 `MemoryCache`、
    `LyricTranslationCache`、Hive 的 `api_cache/image_cache` 盒，然后
    **直接删除临时目录下除 `downloads_tmp` 外的所有实体**（`recursive: true`），
    其中就包含 `flutter_cache_manager` 的缓存目录与它的 sqflite 数据库；
    全程未调用 `AppImageCache.instance.emptyCache()` / `deleteFromCache()`。
- 违反：第 25 条（资源必须有上限，上限要有据可依）
  + 第 3 条（清理路径绕开组件公开契约，直接删其底层存储）。
- 后果：重度浏览用户（每天翻几十个歌单/歌手页）图片缓存可累积到数百 MB 且**永远不会被
  自身机制回收**（600 条只按条目数淘汰，单张原图可达数 MB）；而「清除缓存」是删除
  CacheManager 正在使用的数据库文件，组件持有的连接与磁盘状态脱节，
  表现为清缓存后个别封面反复加载失败/日志出现 sqflite 异常，通常要重启才恢复。
  低端设备上「存储不足」提示随之出现，用户在 App 内无法自助收敛体积。

### B-29 `lib/core/cache/cache_manager.dart`:81 翻译缓存键缺「翻译模型/服务版本」维度
- 级别：P2
- 事实：
  ```dart
  String _key(String lyricId, String targetLang) => '$lyricId:$targetLang';
  ```
  调用方把版本拼进 `targetLang`（lyric_repository.dart:196 `'$targetLanguage@$versionKey'`），
  但 `versionKey` 只是**歌词文本的哈希**（:222–232），与 `AppConfig.translateModel`、
  提示词、翻译服务无关。
- 违反：第 23 条（凡影响结果的输入都必须进缓存键）。
- 后果：项目升级翻译模型/改提示词后，所有老歌**永久返回旧译文**（没有 TTL，见 B-30），
  线上表现为「翻译质量没变、某些句子一直翻错」，且清缓存是唯一的修复手段。

### B-30 `lib/core/cache/cache_manager.dart`:71–110 翻译缓存无条数/体积上限、无过期
- 级别：P2
- 事实：`LyricTranslationCache` 直接 `Hive.openBox<String>('lyric_translations')`，
  `set()` 只 `put`，`clear()` 只有手动调用；无 LRU、无 TTL、无容量统计。
- 违反：第 25 条。
- 后果：按「歌词 id + 语言 + 版本」增长，长期使用后可积累上万条；Hive box 全量驻留内存，
  冷启动打开时间线性增长，低端机首屏变慢。用户侧无感知的慢性退化。

---

## 五、生命周期与资源释放（第 20 / 11 条）

### B-31 `lib/core/providers.dart`:7–25 与 `lib/core/direct/kg_providers.dart`:81–98 所有 Provider 均无 `ref.onDispose`
- 级别：P2
- 事实：
  - `kugouApiClientProvider` → `KgDirectApiClient` → 自身一个 `Dio`（`kugou_api_client.dart`:40–48，含 CookieManager 拦截器）；
  - `kgClientProvider` → `KgClient` → 另一个 `Dio`（`kg_client.dart`:139–150）；
  - `translateApiProvider` → 第三个 `Dio`；
  - 三者都没有对应 `ref.onDispose(...)` 调用 `dio.close(force: true)`。
  全文件（`providers.dart` 25 行、`kg_providers.dart` 98 行）无 `onDispose` 字样。
- 违反：第 20 条（申请了资源必须有对称释放点）。
- 后果：`ProviderScope` 重建（热重启、未来多窗口/多 isolate、测试）时旧 `Dio` 的
  连接池与 `CookieManager` 拦截器继续存活；用户侧表现为长时间使用后内存与 socket 数
  缓慢上升，偶发「请求莫名失败且只能重启 App 恢复」。

### B-32 `lib/core/router/app_router.dart`:22–25 `GoRouter` 未释放
- 级别：P2
- 事实：
  ```dart
  final appRouterProvider = Provider<GoRouter>((ref) {
    return GoRouter(initialLocation: '/home', routes: [...]);
  });
  ```
  `GoRouter` 是 `ChangeNotifier` + 持有 `routeInformationProvider`/`routerDelegate`，
  标准用法需要 `ref.onDispose(router.dispose)`。
- 违反：第 20 条。
- 后果：ProviderScope 重建后旧 router 仍监听平台路由信息；用户侧表现为
  「深链点两次才跳转」或跳转到已销毁的旧 Navigator（偶发白屏）。日常单实例路径无影响，故 P2。

### B-33 `lib/core/audio/audio_service_bootstrap.dart`:42 初始化失败被永久缓存，无恢复条件
- 级别：P2
- 事实：
  ```dart
  static Future<bool> _ensureStarted() => _future ??= _init();
  ...
  catch (e, st) { _error = e; _ready = false; return false; }
  ```
  `_future` 一旦完成（无论成功失败）就永不重置；`ensureReady()` 每次返回同一个已失败的 Future。
- 违反：第 11 条（降级必须有触发条件、次优行为与**退出/恢复条件**）。
- 后果：后台播放服务首次初始化失败（系统服务启动慢、通知权限异常）后，
  本次进程内**所有播放尝试都失败**，用户必须杀进程重启；界面提示「播放失败」但再点也没用。
  且没有任何重试入口。

### B-34 `lib/core/direct/kg_providers.dart`:19 / :42 `KgDeviceStore` 单例与 `save()` 从未被使用
- 级别：P3
- 事实：
  ```dart
  class KgDeviceStore {
    KgDeviceStore._();
    static final instance = KgDeviceStore._();   // 全仓零引用
    ...
    static Future<void> save(Box<String> box, KgDevice device) => ...;  // 全仓零引用
  }
  ```
  类的全部有效 API 都是 `static`，实例化路径纯属摆设。
- 违反：第 32 条（「仅供以后可能用」的抽象全部删除）。
- 后果：无用户可见后果；但 `instance` 的存在暗示「设备身份是单例对象」，
  与 B-10 里 dfid 多副本的现实相矛盾，会继续误导后来者把状态往这个单例上挂。

---

## 六、其它正确性与可维护性（第 6 / 9 / 12 / 13 / 14 / 16 / 32 条）

### B-35 `lib/core/api/translate_api.dart`:45 翻译失败时返回原文，调用方会把原文当译文永久缓存
- 级别：P1
- 事实：
  ```dart
  final content = res.data?['choices']?[0]?['message']?['content'] as String?;
  if (content == null) return lines;         // 返回的是**原文**
  ```
  调用方 `lyric_repository.dart`:200–215 只做「条数为 0 不写缓存」的判断，
  逐条 `if (value.isEmpty) continue;`；原文非空 → 被记为译文、并写入
  `LyricTranslationCache`（:222 `if (translations.isNotEmpty) ... set(...)`）。
- 违反：第 16 条（「失败」与「确实无译文」被映射成同一返回形态）
  + 第 9 条（静默降级不留痕）。
- 后果：一旦服务返回空 `choices`（限流/接口改版），当前歌的**所有行都以「原文=译文」写入持久缓存**；
  之后服务恢复也不会重试（缓存命中），用户看到双语歌词里两行一模一样，
  且即使清缓存也需要重新触发翻译。属于「长时间静默错误」，P1。

### B-36 `lib/core/api/translate_api.dart`:44 `choices[0]` 对空列表直接抛 RangeError
- 级别：P1
- 事实：
  ```dart
  res.data?['choices']?[0]?['message']?['content']
  ```
  `?[0]` 的 `?` 只保护「choices 为 null」；若上游返回 `"choices": []`（OpenAI 兼容服务
  在内容审核/额度耗尽时常见），`[]` 取 0 号元素抛 `RangeError`，不属于任何业务异常类型。
- 违反：第 14 条（边界数据必须校验：先判类型与长度再取下标）。
- 后果：`RangeError` 不会被 `on ApiException` / `on DioException` 捕获，沿调用链直冲到
  `ensureTranslation` 的调用方；若调用方未兜底即表现为**歌词页异常/红屏**，
  并被 `ErrorLogger` 记为 uncaught。上传/审核类空列表并非罕见，触发概率不低。

### B-37 `lib/core/api/translate_api.dart`:44 外部 JSON 裸类型强转
- 级别：P2
- 事实：`... ['content'] as String?`——若 `content` 是数组（多段内容）或对象
  （某些兼容实现返回 `{"text":...}`），`as String?` 抛 `TypeError`。
- 违反：第 13 条（外部数据禁止裸类型强转）。
- 后果：`TypeError` 属编程错误（`kg_direct_api_client` 对 TypeError 明确 rethrow），
  会被当作实现缺陷上抛，表现同 B-36：歌词加载中断。

### B-38 `lib/core/audio/preferred_quality.dart`:11–17 读设置吞掉所有异常，且两个失败分支落到相反档位
- 级别：P2
- 事实：
  ```dart
  try {
    if (Hive.isBoxOpen('settings')) {
      final v = Hive.box<dynamic>('settings').get('defaultQuality');
      if (v is String) return AudioQuality.fromString(v);
    }
  } catch (_) { /* box 未打开或读取异常 → 用默认 */ }
  return AudioQuality.q320;
  ```
  两处失败语义相反：box 未打开/异常 → `q320`（最高档）；
  而值存在但不是字符串、或字符串不被 `fromString` 识别 → `q128`
  （models.dart:32–49，未知值兜底 q128）。
- 违反：第 6 条（空体捕获）+ 第 9 条（同一设置的「读取失败」有两个方向相反的静默结果，且不留痕）。
- 后果：冷启动恢复播放队列时若 settings box 尚未打开，用户选过的 128k 会被按 **320k**
  请求 → 流量翻倍、弱网更容易卡；反之若设置值被写坏（旧版本别名未覆盖），
  用户花钱选的 Hi-Res 会**静默降到 128k**（听感忽然变糊），两种情况诊断页都查不到原因。

### B-39 `lib/core/router/app_router.dart`:76 榜单 id 解析失败静默变成 0
- 级别：P2
- 事实：
  ```dart
  rankId: int.tryParse(state.pathParameters['rankId'] ?? '') ?? 0,
  ```
- 违反：第 16 条（非法输入与「合法但为空」混为一谈）。
- 后果：深链/历史路由里出现非法 id 时，页面照常打开并请求 `rankId=0`，
  显示空白榜单且无错误提示（用户只看到「什么都没有」）。

### B-40 `lib/core/router/app_router.dart`:48 / :57 / :67 / :71 / :83 路由参数直接非空断言
- 级别：P3
- 事实：`id: state.pathParameters['id']!`、`hash: state.pathParameters['hash']!`。
  路径段理论上必存在，但这些值来自外部深链（第 14 条列出的边界之一）。
- 违反：第 12 条（跨边界的非空断言）。
- 后果：`/playlist/` 这类被外部 Intent 缩短的 URL 若命中匹配，会在 build 期抛
  `Null check operator used on a null value`，表现为打开 App 直接错误页。概率低，P3。

### B-41 `lib/core/utils/error_logger.dart`:207 `logApi()` 无任何调用方
- 级别：P2
- 事实：
  ```dart
  Future<void> logApi(Object error, {required String endpoint, int? code, Map<String, dynamic>? body})
  ```
  全仓检索 `logApi(` 只有该声明，没有调用点。
- 违反：第 32 条（死代码零容忍）。
- 后果：`ErrorLogger` 实际只有两个输入源——`FlutterError.onError` 与
  `runZonedGuarded`（main.dart:44、:169），即**只记「未捕获异常」**；
  所有被业务捕获并降级的 API 失败根本不入盘（只剩 `debugPrint` 与 B-19 那个无人读的内存表）。
  用户在设置页看到「已记录 N 条错误」时，N 里不会有任何一条「某接口一直失败」；
  开发者拿不到错误码与端点，排障只能靠猜。

### B-42 `lib/core/theme/app_theme.dart`:171 / :100 / :111 / :28–30 主题中的尺寸魔法值未纳入 token 体系
- 级别：P3
- 事实：文件顶部定义了 `radiusCard/radiusButton/radiusInput/radiusSmall` 与
  `motionShort/motionMedium/motionCurve`，但 `navigationBarTheme.height: 68`、
  `filledButton minimumSize: Size(0, 48)`、`outlinedButton: Size(0, 44)`、
  `segmentedButton: Size(0, 48)` 直接写字面量；`motion*` 常量在文件内也未被使用。
- 违反：第 2 条（魔法值必须有具名常量）+ 第 32 条（未使用的 token）。
- 后果：无功能后果；调整导航栏/按钮高度需要逐处改数字，易出现 48/44 混用导致
  同一行两个按钮不等高（视觉抖动）。

---

## 七、问题清单（按级别排序）

### P0（0 条）

本批未发现「已可触发」的崩溃、数据损坏或凭据外泄。原先判 P0 的 B-17 因
「当前唯一入口只喂未捕获异常、尚无调用点把响应体交给脱敏函数」而降为 P1（见该条「触发路径」）。

### P1（7 条）

| 编号 | 位置 | 问题 | 条款 | 用户可见后果 |
|---|---|---|---|---|
| B-17 | `core/utils/error_logger.dart:189` | 脱敏正则对 `"token":"…"` / `mobile=…` 可证明失效，而日志落公共 Documents/MediaStore；与 B-41 合并构成「该记的没记、记的可能带明文」 | 第 9 条（兼第 14 条） | 任一调用点把响应体交给日志，即把明文 token/手机号写进用户会转发给客服的文件 |
| B-10 | `core/storage/secure_storage.dart:16` + `core/direct/kg_providers.dart:54` | dfid 四份权威存储（SecureStorage / Hive device / KgClient 字段 / cookie）五个写入点，两条注册路径产出不同 dfid 且互相覆盖 | 第 5 条 | 设备标识每次冷启动来回跳变 → 被判新设备：播放降权/试听、反复触发人机验证 |
| B-11 | `core/storage/secure_storage.dart:58` | `clearCredentials` 不删 dfid、不删 `acct_token_*`；普通退出登录不调 `deleteAccountToken` | 第 5 条（兼第 20 条） | 「退出登录」后 token 仍在设备上，账号切换可无密码恢复该账号 |
| B-19 | `core/direct/kg_direct_api_client.dart:138` | `lastErrors` 只写不读（诊断页无实现），内容未脱敏 | 第 9 条（兼第 32 条） | 「网络诊断」看不到任何直连失败，排障零线索 |
| B-07 | `core/api/kugou_api_client.dart:144–147` | cookie 持久化与否取决于「谁先构造客户端」这一时序，晚设置即静默退化为内存 jar | 第 2 条（兼第 9 条） | 冷启动偶发掉登录，必须重新扫码/短信登录，且日志无痕 |
| B-35 | `core/api/translate_api.dart:45` | `content == null` 时返回原文，调用方把原文当译文写入持久缓存 | 第 16 条（兼第 9 条） | 翻译服务一出问题，该歌双语歌词永久显示「原文=译文」，服务恢复也不重试 |
| B-36 | `core/api/translate_api.dart:44` | `choices[0]` 对空列表抛 RangeError，不属任何业务异常 | 第 14 条 | 上游返回空 choices 时歌词页异常/崩溃，且被记为未捕获错误 |

### P2（29 条）

| 编号 | 位置 | 问题 | 条款 |
|---|---|---|---|
| B-01 | `core/providers.dart:3` | core 公共 provider 引 features/lyric（core↔features 双向依赖） | 第 4 条 |
| B-02 | `core/router/app_router.dart:5–19` | 路由层静态 import 16 个 features 页面 | 第 4 条 |
| B-03 | `core/audio/preferred_quality.dart:4` | core/audio 引 features/player 的 `AudioQuality` | 第 4 条 |
| B-04 | `core/utils/error_logger.dart:8` | 全局日志器依赖 features/download 的存储权限服务 | 第 4 条 |
| B-08 | `core/api/kugou_api_client.dart:40–45` | 基类默认 baseUrl 是 kapi 中转域，且 `AuthRepository(api: null)` 会自建该客户端 | 第 2 条（兼第 27 条） |
| B-09 | `core/providers.dart:11–12` | `TranslateApi` 无注入点，第三方域名/模型硬编码且无开关 | 第 2 条 |
| B-12 | `core/direct/kg_providers.dart:74–78` | 设备身份兜底 `KgDevice.generate()` 每次启动新建、无日志 | 第 5 条（兼第 9 条） |
| B-13 | `core/direct/kg_providers.dart:35` | 首次设备落盘 `box.put` 未 await | 第 9 条（兼第 5 条） |
| B-14 | `core/direct/kg_providers.dart:54–71` | `saveDfidSync` 失败（false）无人检查、无日志 | 第 6 条（兼第 9 条） |
| B-15 | `core/cache/cache_manager.dart:64` | 内存缓存键不含用户身份，跨账号正确性靠人工清缓存 | 第 23 条 |
| B-16 | `core/api/kugou_api_client.dart:185–204` | 凭证散落 CookieJar/实例字段/KgClient 字段/SecureStorage，清理路径须成对调用 | 第 5 条 |
| B-18 | `core/utils/error_logger.dart:189` | 脱敏键白名单无 mobile/phone/userid/dfid | 第 9 条 |
| B-20 | `core/utils/error_logger.dart:101` | 私有目录不可用时日志被丢弃，只剩 200 条内存副本 | 第 9 条 |
| B-21 | `core/utils/error_logger.dart:264` | API 级别兜底恒为 29；`_apiLevelFromOsVersion` 把 Android 9 映射成 9 | 第 6 条（兼第 15 条） |
| B-22 | `core/utils/error_logger.dart:66` | 并发写日志无串行/锁（含原生读改写） | 第 22 条 |
| B-23 | `core/utils/toast.dart:24–27` | 同类消息 3 秒内静默丢弃，不留痕 | 第 9 条 |
| B-25 | `core/utils/friendly_error.dart:20` | 非 ApiException 一律塌缩为「操作失败」，`api.message` 可能为空 | 第 8 条（兼第 16 条） |
| B-26 | `core/image/app_image_cache.dart:68–72` | `getFileStream` 只串行「开始」，并未串行 sqflite 写入；注释宣称已彻底消除 BUSY | 第 31 条（兼第 1 条） |
| B-27 | `core/image/app_image_cache.dart:3–4` | 用 `package:file` 的 `File` 覆写 `dart:io.File` 返回值（invalid_override 或死导入） | 第 3 条（兼第 32 条） |
| B-28 | `core/image/app_image_cache.dart:27–31` | 图片缓存仅 600 条上限、无字节上限、无清理入口（「清除缓存」不含它） | 第 25 条 |
| B-29 | `core/cache/cache_manager.dart:81` | 翻译缓存键缺模型/提示词/服务版本维度 | 第 23 条 |
| B-30 | `core/cache/cache_manager.dart:71–110` | 翻译缓存无条数/体积上限、无 TTL、无淘汰 | 第 25 条 |
| B-31 | `core/providers.dart:7–25`、`kg_providers.dart:81–98` | 三个 `Dio` 与客户端均无 `ref.onDispose` | 第 20 条 |
| B-32 | `core/router/app_router.dart:22` | `GoRouter` 未 dispose | 第 20 条 |
| B-33 | `core/audio/audio_service_bootstrap.dart:42` | 初始化失败被 `_future` 永久缓存，无重试/恢复条件 | 第 11 条 |
| B-37 | `core/api/translate_api.dart:44` | `['content'] as String?` 外部数据裸强转 | 第 13 条 |
| B-38 | `core/audio/preferred_quality.dart:11–17` | 读取失败两个分支落到相反档位（320 / 128），异常全吞 | 第 6 条（兼第 9 条） |
| B-39 | `core/router/app_router.dart:76` | 榜单 id 解析失败静默变 0，空白页无提示 | 第 16 条 |
| B-41 | `core/utils/error_logger.dart:207` | `logApi()` 无任何调用方 → 无结构化接口错误日志 | 第 32 条 |

### P3（6 条）

| 编号 | 位置 | 问题 | 条款 |
|---|---|---|---|
| B-05 | `core/utils/permission_gate.dart:8` | core 权限门卫依赖 features/download | 第 4 条 |
| B-06 | `core/utils/toast.dart:6` | Toast 兼做剪贴板复制并依赖 l10n 生成层 | 第 1 条 |
| B-24 | `core/utils/toast.dart:29–33` | 去重表上限只在「恰有过期项」时生效 | 第 25 条 |
| B-34 | `core/direct/kg_providers.dart:19`、`:42` | `KgDeviceStore.instance` / `save()` 全仓零引用 | 第 32 条 |
| B-40 | `core/router/app_router.dart:48/57/67/71/83` | 深链参数直接 `!` 非空断言 | 第 12 条 |
| B-42 | `core/theme/app_theme.dart:171/100/111/28–30` | 导航/按钮尺寸魔法值未入 token；`motion*` 常量未使用 | 第 2 条（兼第 32 条） |

---

## 八、统计

### 按级别

| 级别 | 数量 | 占比 | 编号 |
|---|---|---|---|
| P0 | 0 | 0% | —（本批无「已可触发的」崩溃/数据损坏/凭据外泄） |
| P1 | 7 | 16.7% | B-07、B-10、B-11、B-17、B-19、B-35、B-36 |
| P2 | 29 | 69.0% | B-01~04、B-08/09、B-12~16、B-18、B-20~23、B-25~33、B-37~39、B-41 |
| P3 | 6 | 14.3% | B-05、B-06、B-24、B-34、B-40、B-42 |
| **合计** | **42** | 100% | |

### 按条款（一条问题只计主条款）

| 条款 | 次数 | 涉及编号 |
|---|---|---|
| 第 1 条 单一职责 | 1 | B-06 |
| 第 2 条 显式优于隐式 | 4 | B-07、B-08、B-09、B-42 |
| 第 3 条 契约先行 | 1 | B-27 |
| 第 4 条 分层单向 | 5 | B-01、B-02、B-03、B-04、B-05 |
| 第 5 条 状态单一来源 | 4 | B-10、B-11、B-12、B-16 |
| 第 6 条 禁止吞异常 | 3 | B-14、B-21、B-38 |
| 第 8 条 异常契约稳定 | 1 | B-25 |
| 第 9 条 失败可观测 | 7 | B-17、B-18、B-19、B-20、B-23、B-13、B-35（B-07 兼） |
| 第 11 条 降级条件 | 1 | B-33 |
| 第 12 条 非空断言 | 1 | B-40 |
| 第 13 条 裸类型强转 | 1 | B-37 |
| 第 14 条 边界校验 | 1 | B-36 |
| 第 16 条 空集合/缺失分离 | 1 | B-39 |
| 第 20 条 生命周期对称 | 2 | B-31、B-32 |
| 第 22 条 并发假设 | 1 | B-22 |
| 第 23 条 缓存键维度 | 2 | B-15、B-29 |
| 第 25 条 资源上限 | 3 | B-24、B-28、B-30 |
| 第 31 条 注释解释为什么 | 1 | B-26 |
| 第 32 条 死代码 | 2 | B-34、B-41 |

> 口径：每条问题只按「主条款」计入上表，兼注条款（如 B-11 兼第 20 条、B-26 兼第 1 条）
> 不重复计数。上表合计 = 1+4+1+5+4+3+1+7+1+1+1+1+1+2+1+2+3+1+2 = **42**，与按级别的合计一致。
> 逐条核对：B-01~05、B-06、B-07~09、B-10~12、B-13~20、B-21~24、B-25~27、B-28~30、B-31~42 已全部落表。

### 条款覆盖（本轮明确检查但未发现问题的项）

| 条款 | 结论 |
|---|---|
| 第 7 条 精确捕获 | 除 B-21（`catch (_)`）外，`ErrorLogger` 其余捕获均按可处理类型分层；`KgDeviceStore` 的 `catch (_)` 已在 B-13/B-14 记录 |
| 第 10 条 编程错误不进降级 | `kg_direct_api_client` 对 `TypeError/NoSuchMethodError` 显式 rethrow，方向正确（B-37 的问题在于产生 TypeError 的源头） |
| 第 24 条 惰性构建 | `AppTheme._base` 只在 `dark()/light()` 调用时构建，非每帧；主题对象无 I/O，符合 |
| 第 26 条 热路径零分配 | 本轮 infra 文件均不在滚动/每帧路径（图片缓存、日志、路由、主题构建），无命中 |
| 第 30 条 命名即文档 | `_kDfid`/`_kAcctTokenPrefix`/`maxBytes`/`_dedupeWindow` 命名准确；`kg_providers` 的 `saveSync/saveDfidSync` 区分清晰 |

---

## 九、三条最严重

1. **B-10（P1）dfid 四源五写**：SecureStorage、Hive `device`、`KgClient.dfid`、cookie
   各持一份，两条注册路径（kapi `register/dev` 与原生 `r_register_dev`）产出不同值并互相覆盖
   → 设备标识每次冷启动跳变，直接造成播放降权、试听片段与反复人机验证。
   这是「状态单一来源」在基础设施层的核心破口。
2. **B-11（P1）登出不清账号 token**：普通退出登录只清 4 个键，`acct_token_<userid>`
   与 dfid 永久保留；「账号切换」无需密码即可恢复已登出账号 —— 共享/转手设备上等于账号仍在线。
3. **B-17 + B-41（P1 / P2）日志链路的两个反向缺口**：脱敏正则对 `"token":"…"` 与手机号
   可证明失效（已用等价实现逐条实测），而日志目标是**公共 Documents / MediaStore Downloads**
   （用户会把它发给客服）；同时唯一负责写接口错误的 `logApi()` 没有任何调用方。
   结果是「该记的失败没记，记下来的又可能带明文凭据」。

---

## 十、附：本次审查的判定边界（供复核）

- 直连层（`kg_client.dart` / `kg_endpoints_*.dart` / `kg_play_api.dart`）按任务书不重复评审；
  本报告引用它们仅为**证明 core 侧事实**（dfid 读取点、`lastErrors` 无读方、`setCredentials` 同步），
  未对其端点语义、签名、`fallbackToKapi` 语义另作结论。
- 「用户可见后果」均按调用链推导（`main()` → Provider → Repository → 页面），
  未实际运行 App；凡涉及运行时序（如 B-07 的「先构造后设置」）均已在条目内写明前提。
- 未给出修复代码与修改建议（按 REVIEW_SPEC 一、三节口径）。
