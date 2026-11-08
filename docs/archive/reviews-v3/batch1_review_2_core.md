# 第 1 批 · 审查②：core 基础设施（只读 · 只报问题）

> 范围：`lib/core/providers.dart`、`lib/core/cache/**`、`lib/core/image/**`、`lib/core/storage/**`、`lib/core/utils/**`、`lib/core/config/**`、`lib/core/theme/**`、`lib/core/widgets/**`，以及同属启动基础设施、未被①/③认领的 `lib/core/audio/**`、`lib/core/router/**`、`lib/main.dart`、`lib/core/api/kugou_api_client.dart`、`lib/core/api/translate_api.dart`。
> 方法：逐文件完整阅读（未使用正则推断逻辑）；未构建、未运行、未修改任何源码。涉及跨层证据时，附 Node 服务与调用方行号。
> 纪律：只写问题、位置、依据与影响，不写修法。
> 结论：**无编译阻塞项**；以下 22 项按 严重功能/安全 → 逻辑健壮性 → 一致性/质量 排序。

---

## P1 功能失效 / 安全

### C-01 图片缓存「串行化」实际未覆盖任何真实调用路径，SQLITE_BUSY 防护失效
- 位置：`lib/core/image/app_image_cache.dart:51-67`
- 问题：类注释声明「下载/写入串行化，同一时刻只有一个 DB 事务」，但只重写了 `getSingleFile`（内部走 `_serial`）；`getFileStream` 直接 `super.getFileStream(...)`，没有进入队列。
- 依据：`CachedNetworkImage` / `CachedNetworkImageProvider` 的加载链路走 `CacheManager.getFileStream`，不走 `getSingleFile`；全仓库 `getSingleFile` 调用点为 0（`rg 'getSingleFile|getFileStream' lib` 仅命中该类自身）。仓库内 19 处图片组件（16 处 `CachedNetworkImage` + 3 处 `CachedNetworkImageProvider`）全部显式传 `cacheManager: AppImageCache.instance`。
- 影响：并发拉封面时仍然并发开启 sqflite 写事务，注释中描述要消除的 `DatabaseException(database is locked (code 5 SQLITE_BUSY))` 依然会出现；`AppImageCache` 的存在只统一了实例，未统一事务。

### C-02 错误日志未脱敏即写入用户可见的公共 Documents 目录
- 位置：`lib/core/utils/error_logger.dart:66-112`（`log`）与 `187-202`（`_redact`）
- 问题：`log()` 直接把 `error`、`context`、`stack` 拼进 `text` 并 `_appendPublic` / 私有目录落盘，全程没有调用 `_redact`。`_redact` 只在 `logApi` 的响应体截断分支使用，而 `logApi` 在全仓库**无调用点**（`rg 'logApi\('` 仅定义处）。
- 依据：`log()` 内 74-84 行构造 `sb` 后 95 行直接 `_appendPublic(fileName, text)`；`_redact` 的注释（183-186 行）明确写着「日志落在公共 Documents 目录（文件管理器可见，且用户可能分享），响应体/header 中的凭据必须先脱敏再落盘」。`ErrorLogger.handleFlutterError` / `handleUncaught`（225-238 行）是全局错误入口，任何 `DioException` 的 `toString()`/`message` 都可能包含完整请求 URI（如 `/login/token?token=...&userid=...`）。
- 影响：登录 token / t1 / cookie 可经任何一次网络异常写入 `Documents/Tiernan Music/Logs/error_*.log`，并可能被用户分享或其它具备文件读取能力的应用读取；与类内声明的安全约束直接矛盾。

### C-03 切换账号时 t1/auth 旧值不清除，SecureStorage 与共享 CookieJar 同时残留
- 位置：`lib/core/storage/secure_storage.dart:24-30`；`lib/core/api/kugou_api_client.dart:189-199`；调用方 `lib/features/auth/data/auth_repository.dart:318-338`
- 问题：`saveCredentials` 对 `t1`/`auth` 使用 `if (t1 != null) write(...)`，参数为 null 时既不写也不删旧键；`KugouApiClient.setCredentials` 同样只在非 null 时 `Cookie(...)`，不清理旧 cookie。`_handleLoginSuccess` 的 `t1 = d['t1']?.toString()`、`auth = d['auth']?.toString()` 都可能为 null（扫码登录、token 刷新、部分短信登录响应不带这两个字段）。
- 依据：`secure_storage.dart:27-29` 条件写入；`kugou_api_client.dart:192-194` 条件 Cookie；`auth_repository.dart:318-320` 的 `t1`/`auth` 来源可为 null，随后 322-338 行原样传入两个保存方法。
- 影响：A 账号退出后登录 B 账号，若 B 的响应不含 t1/auth，磁盘与共享 jar 中仍是 A 的 t1/auth，而 token/userid 已是 B；后续 `/login/token` 签名、`/song/url` 鉴权、`/user/verify` 会带着 A 的 t1 与 B 的 token 组合请求，表现为播放鉴权失败、账号串号或随机掉登录。

### C-04 `main.dart` 登录态监听中的 t1 异步回填存在退出竞态
- 位置：`lib/main.dart:245-257`
- 问题：登出分支只同步清 `client.t1 = ''`；登录分支发起 `SecureStorage.instance.readCredentials().then(...)`，回调里只校验 `c.userId == user.userid`，没有校验「当前 authState 是否仍是这次登录」。若读取期间用户登出（或切到另一账号后切回同一 userid），回调仍会把旧 `t1` 写回 `client`。
- 依据：`readCredentials()` 是 5 次串行 `_storage.read`（`secure_storage.dart:33-44`），存在真实异步窗口；回调闭包捕获的是发起时的 `user`，不是 `next.value`。
- 影响：登出后 `KgClient.t1` 被异步重新填回，客户端继续以旧票据签名；与 C-03 叠加时更难排查。

### C-05 启动页 SVG「逐笔写出」动画实际不可见（裁剪尺寸不随进度变化）
- 位置：`lib/core/widgets/animated_svg_logo.dart:51-69`
- 问题：外层 `SizedBox(width: size)` + `ClipRect` 固定为 132×132；内部的 `Align(widthFactor: t)` 只改变自身盒子宽度，不裁剪子节点，`SvgPicture` 仍以 132 宽从左侧完整绘制。`ClipRect` 的裁剪矩形是 132 宽，因此没有任何一帧被裁掉。
- 依据：`Align`/`RenderPositionedBox` 的 `widthFactor` 只参与自身尺寸计算，子节点按 loose 约束布局并允许溢出绘制；真正决定可见区域的是祖先 `ClipRect` 的 132×132。`AnimatedBuilder` 每帧重建 `SvgPicture.asset`（59-66 行），布局开销存在，但视觉进度不会变化。
- 影响：启动页 LOGO 直接整幅出现（或仅盒子尺寸变化），1.4 秒动画形同虚设；同时每帧重建 SVG widget 造成无意义布局/绘制。

### C-06 kapi 响应判定把任意 `0 < error_code < 300` 当作「警告」放行，错误码 1/2 等会被吞掉
- 位置：`lib/core/api/kugou_api_client.dart:77-108`
- 问题：`okStatus = status == 1 || status == 200`；`isWarning = warningCodes.contains(errorCode) || (errorCode > 0 && errorCode < 300)`；最终拒绝条件为 `failedStatus || (hasErrorCode && errorCode != 0 && !(okStatus && isWarning))`。当 `status==1` 且 `error_code==1`（酷狗常见的参数/系统错误）时，`okStatus && isWarning` 为真，异常被放行，调用方拿到的是错误响应体并当作正常数据。
- 依据：77-85 行布尔式计算；`warningCodes` 只应包含 151/152/200/201（79-80 行注释），但 81-82 行又把 1-299 全部并入。
- 影响：参数错误、风控错误（非 20028）在 kapi 回退路径上表现为「请求成功但数据为空/字段缺失」，上层只能显示空态；同时 20028 之外的验证码类错误码也不会进入 `ApiException` 的验证分支。

### C-07 登录/设备注册类接口缺少 `timestamp`，命中 Node 侧 2 分钟全局 URL 缓存
- 位置：`lib/core/api/kugou_api_client.dart:148-156`（`_needsTimestamp` 白名单）；服务端依据 `KuGouMusicApi/server.js:318`、`KuGouMusicApi/util/apicache.js:892`
- 问题：kapi 对**所有** HTTP 200 响应按 `hostname + originalUrl` 做 2 分钟全局缓存；客户端只对 `/login/qr/check`、`/login/token`、`/playlist/*`、`/comment/` 等加时间戳。`/captcha/sent`、`/login/cellphone`、`/login`、`/login/qr/key`、`/login/qr/create`、`/register/dev`、`/get/verify/info`、`/verify/user/info`、`/sidedt` 都不在白名单。
- 依据：`server.js:312-318` 注释「相同 URL 在 2 分钟内只会向酷狗服务器发送一次请求」；`apicache.js:892` 的 key 为 `req.hostname + (req.originalUrl || req.url)`，不含请求头/body，因此不同用户共享同一 key。`auth_repository.dart:71,84,96,145,151,160` 与 `player_repository.dart:47` 均直接调用这些路径。
- 影响（仅在直连失败回退 kapi 时触发，但回退正是网络异常时）：2 分钟内第二个用户请求 `/login/qr/key` 会拿到**同一个二维码 key**，扫码登录串号；`/register/dev` 会拿到同一个 dfid，设备身份被复用；同一手机号 2 分钟内重发短信直接返回缓存成功而不再下发；同一 `eventid` 的 `/get/verify/info`（含派生 `/sidedt`）在 2 分钟内复用同一份验证会话信息。

---

## P2 逻辑与健壮性

### C-08 MemoryCache 无用户维度、key 不转义、值强转，三处可致错误数据/崩溃
- 位置：`lib/core/cache/cache_manager.dart:12-28, 56-61`
- 问题 1（跨账号）：缓存 key 只有 path+query，不含 userid/token；登出/换号时 `main.dart:241` 只 `ref.invalidate(homeDataProvider)`，没有 `MemoryCache.clear()`。`search_repository`、`playlist_repository`（`/playlist/detail`、`/playlist/track/all`）、`lyric_repository`、`mv_repository` 的条目在 90 秒 TTL 内继续命中上一账号的响应。
- 问题 2（key 碰撞）：`keyOf` 直接 `'$path?${e.key}=${e.value}'` 拼接，参数值未做 `Uri.encodeQueryComponent`，值中出现 `&`/`=`（搜索词是用户输入）时会与另一组参数生成完全相同的字符串。
- 问题 3（类型/别名）：`get<T>` 用 `e.value as T?`；若同一 key 先后以不同 T 读取会抛 `CastError`。`set` 保存的是调用方传入的 Map 引用，`get` 原样返回，调用方对返回 Map 的就地修改会污染缓存。
- 依据：`home_repository.dart:23-33`、`playlist_repository.dart:21-25,50-54`、`search_repository.dart:63-70` 均为「取缓存→直接返回/写入」；无任何深拷贝。
- 影响：换号后 90 秒内可看到上一账号的权益/个性化数据；搜索关键词含 `&` 时返回别的关键词结果；任一处规范化 Map 会污染后续同 key 请求。

### C-09 歌词翻译持久缓存无版本、无过期、无容量上限，反序列化无保护
- 位置：`lib/core/cache/cache_manager.dart:81-109`
- 问题：key 仅 `'$lyricId:$targetLang'`，不包含歌词内容版本/哈希，歌词更新后仍返回旧译文；写入永不删除，也没有 TTL 或条数上限（`clear()` 仅设置页手动触发）。`get` 的 `int.parse(line.substring(0, idx))` 无 try/catch，Hive 中任一条目损坏（或被旧版本写入不同格式）会抛 `FormatException` 到歌词页。`init()` 的 `_box ??= await Hive.openBox` 在并发首次调用时没有 future 去重，两个调用会同时进入 open。
- 依据：88-92 行无保护解析；100-103 行直接拼接 `key\tvalue`，译文若自身含 `\n`/`\t` 会被下一次 `split('\n')` 截断成错误行号；`_box` 判空发生在 await 之前。
- 影响：翻译串行、错位题；缓存无限增长；一次损坏导致整首歌翻译加载抛异常（上层若未捕获则整页错误）。

### C-10 设置 Provider：Hive 值强转可致整树崩溃、box 打开时机固定、失败后永久内存态
- 位置：`lib/core/theme/settings_provider.dart:6-13, 21-27, 52-58, 86-91, 105`
- 问题：三个 `_load` 都用 `box?.get(...) as String?`。Hive 若存有旧版本写入的非 String（如 ThemeMode 序号 int）时 `as String?` 抛 `CastError`；异常发生在 `StateNotifierProvider` 创建期，而 `main.dart:264-265` 在根 `build` 中 `ref.watch(themeModeProvider)`/`localeProvider`，异常会直接走 `ErrorWidget.builder` 全屏错误页，且每次启动复现。`_settingsBoxProvider` 只在首次被 watch 时读一次 `Hive.box('settings')`：若启动时 `openSafe('settings')` 失败（`main.dart:78` 只打印日志），返回 null 被永久缓存，之后即使 box 打开也不会恢复，主题/语言/歌词模式全部静默不落盘。`initSettingsBox()`（105 行）为死代码，无人调用。
- 依据：`main.dart:65-83` 的 `openSafe` 吞掉异常；`main.dart:78` 之后没有任何重试或 provider 失效逻辑。
- 影响：单条脏数据导致「应用启动异常」页且无法自愈；存储初始化失败时用户设置看似生效、重启即丢。

### C-11 Toast 双计时器导致淡出永远不可见，且去重发生在确认可显示之前
- 位置：`lib/core/utils/toast.dart:23-46, 80-87`
- 问题 1：`Toast.show` 设置 `_dismissTimer = Timer(2400ms, _hide)`，`_ToastViewState.initState` 又设置 `Timer(2400ms, _controller.reverse)`。两个计时器同时到点，`_hide` 立即 `remove()` entry，`reverse` 刚开始 180ms 就随 State dispose 被取消。
- 问题 2：`_lastShown[msg] = now` 在 `overlay == null` 判断（34-35 行）之前执行；没有 Overlay 的调用（启动早期/无根 Overlay）会把消息标记为已展示，3 秒内真正可显示时被静默抑制。
- 问题 3：`_current` 是静态字段，跨 Navigator/Overlay 共享；A Overlay 插入的 entry 若其宿主被销毁，静态引用仍指向旧 entry，直到下一次 show 或 2.4s 计时器。
- 依据：38-45 行与 85-87 行两个相同 2400ms 计时器；`_ToastView` 的 `FadeTransition`（105-106 行）使用同一个 controller。

### C-12 ErrorLogger 公共目录写入链路与注释/返回值不一致
- 位置：`lib/core/utils/error_logger.dart:31-32, 114-180, 262-268`
- 问题：119-121 行注释称「由 Dart 侧缓存当日内容，退出/超限时整份重写」，Dart 侧没有任何当日内容缓存，实际依赖原生 `appendText` 每次读旧+重写，注释与实现不符。`_rewriteMediaStore` 在 `ok` 为空字符串时 172 行不记录路径、175 行却 `return ok != null` 返回成功（空串被当作成功）。`apiLevel` 在原生通道不可用时无条件回退 29（267 行），在 Android ≤9 上会先走 MediaStore 分支失败再降级，且注释所说的版本名兜底并不存在。
- 依据：`_appendPublic` 的 29 分支与 ≤9 分支（117-140 行）；`apiLevel` 只 `try StoragePermissionService.apiLevel()` 后 `return 29`。
- 影响：日志路径展示可能为空（用户从诊断页拿不到路径）；旧设备日志永远落私有目录；注释误导后续维护者。

### C-13 两套错误文案映射并存且不一致，且均未本地化
- 位置：`lib/core/utils/friendly_error.dart:7-17`；`lib/core/widgets/error_retry.dart:204-247`
- 问题：`friendlyError` 对 `ApiException` 的 1011/20010/30791/401 输出「登录已过期，请重新登录」，其余直接返回 `e.message`；`errorClassification` 对**所有** `ApiException` 一律返回 `error.message`，不做上述映射。两者都把服务端原始 message（可能是英文、HTML、或含参数的回显）直接上屏，且全部是硬编码中文，10 语言界面下英文/日文用户仍看到中文。`ErrorRetry` 还会把 `error.toString()` 放入可展开的「技术详情」并支持一键复制（`_TechDetail` 135-153 行），DioException 的 toString 含完整 URL 查询参数。
- 依据：`friendly_error.dart:8-13` 与 `error_retry.dart:227-234` 的分支差异；`settings_page.dart:360`、`download_provider.dart:358` 使用前者，列表/详情页普遍使用后者。
- 影响：同类错误在不同页面文案不同；「登录过期」在错误页不提示；英文界面出现中文；技术详情可能暴露 token 查询参数。

### C-14 10 语言应用中，主导航、启动页、启动错误页文案硬编码中文
- 位置：`lib/core/router/app_router.dart:110-113`；`lib/core/widgets/splash_screen.dart:20-26`；`lib/main.dart:315-322`
- 问题：底部导航 `'首页' '搜索' '音乐库' '设置'` 直接写死；启动页 `'汀澜音乐'`；启动错误页 `'应用启动异常'`。`l10n` 中也不存在 navHome/navSearch 等 key（`rg` 在 `lib/l10n` 无命中）。
- 依据：`AppLocalizations.supportedLocales` 含 de/en/es/fr/ja/ko/pt/ru/zh/zh_CN/zh_TW（`app_localizations.dart:3417-3429`）；`app_en.arb` 已有 `appName: Tinglan Music` 但 splash 未使用。
- 影响：非中文用户全程看到中文导航；截图与视觉验收无法通过多语言检查。

### C-15 AudioServiceBootstrap 失败结果被永久缓存，`ensureReady` 无超时
- 位置：`lib/core/audio/audio_service_bootstrap.dart:25-42, 66-73`
- 问题：`_future ??= _init()` 一旦 `_init` 返回 false（`JustAudioBackground.init` 抛异常），`_future` 永久保存该已完成 false，后续 `ensureReady` 永远返回 false，整个进程生命周期内没有任何重试入口。`ensureReady` 对 `_future` 直接 `await`，没有超时；若原生初始化挂起，播放请求会无限等待（注释明确拒绝超时，但没有替代的失败路径）。
- 依据：`_error` 只写不读（33 行 getter 无人使用）；`features/player/data/audio_handler.dart:43` 只判断 bool，失败后直接 return。
- 影响：一次系统服务启动失败后，本次进程内所有播放都被判为「引擎未就绪」，用户只能杀进程重启；初始化卡死时 UI 停在加载态。

### C-16 `ErrorWidget.builder` 返回整屏 Scaffold，嵌套在任意布局中会二次报错
- 位置：`lib/main.dart:47-51, 295-335`
- 问题：任何 widget build 异常都被替换成 `StartupErrorPage`，其根是 `Scaffold`。当异常发生在 `Row`/`Column`/`ListView` 子项时，`Scaffold` 被塞进无界或窄约束，会触发新的布局异常（如 `BoxConstraints forces an infinite height`），错误页本身无法渲染。`compact` 参数（296 行）在 build 中从未使用；`'$error'`（325 行）原样展示异常文本。
- 依据：`ErrorWidget.builder` 的替换范围是**出错的单个 widget**，不是整个 App；MaterialApp 层已有启动错误分支（267-272 行）。
- 影响：局部渲染错误从「一个红框」升级为整页崩溃/白屏，且错误信息可能含路径与参数。

### C-17 更新检查的代理/ABI/版本比较均有边界缺口
- 位置：`lib/core/utils/update_checker.dart:96-104, 111-131, 134-147, 163-225`
- 问题 1：`apiUrl = 'https://proxy.344977.xyz/' + 'https://api.github.com/...'` 实际返回 308，Location 为 `https://proxy.344977.xyz/https:/api.github.com/...`（单斜杠）。当前实测可跟随到 200，但代码没有显式 `followRedirects`/最终 URL 校验，代理行为变化即整体失效。
- 问题 2：`_pickApkUrl` 只按文件名含 `arm64` 优先，否则取 assets 中第一个 `.apk`；当前 release 资产顺序为 arm64、armeabi-v7a、x86_64，fallback 会给出 32 位包，非 arm64 设备/模拟器可能装错 ABI；也未校验大小/哈希/包名。
- 问题 3：`_splitVersion` 对无 `-` 的 `1.0.0rc1` 会把 `0rc1` 清洗成 `01` 解析为 1，得到 `1.0.1`；`latestVersion: latest.isEmpty ? current : latest`（98 行）在 85-87 行已对空 tag 抛异常，分支不可达。
- 依据：实测 `curl -sI` 返回 308 与上述 Location；release 资产名通过 GitHub API 实测为 `app-arm64-v8a-release.apk`、`app-armeabi-v7a-release.apk`、`app-x86_64-release.apk`。
- 影响：非 arm64 设备可能下载到不兼容 APK；代理重定向策略改变时更新检查静默失败；非标准 tag 的版本比较可能误判有无更新。

### C-18 权限门卫的拒绝反馈与版本分支不完整
- 位置：`lib/core/utils/permission_gate.dart:42-61, 64-82`
- 问题：`requestWithPrompt` 在 `isPermanentlyDenied` 时直接 `openAppSettings()` 并 return false，不展示传入的 `reason`（78 行只在普通拒绝时 Toast），用户不知道为何被带到系统设置。`hasMediaReadAccess` 只检查 `Permission.audio`，不覆盖图片/视频，且 `level < 33` 直接返回 true，忽略了 Android 10-12 的 scoped storage 仍需 `READ_EXTERNAL_STORAGE` 才能读他人媒体。`ensureNotification` 直接委托 service，未处理 Android 13 以下无该权限概念时的返回值语义。
- 依据：`requestWithPrompt` 的 72-80 行分支；`hasMediaReadAccess` 52-56 行；`rg 'PermissionGate' lib` 只命中 `settings_page.dart:69,696,699` 三处，`ensureNotification` / `hasMediaReadAccess` 全仓库零调用；`StoragePermissionService.requestNotificationPermission`（`storage_permission_service.dart:88`）同样零调用。
- 影响：注释宣称的「发通知前调用」入口实际不存在，Android 13+ 若后续接入下载/播放通知不会触发授权；媒体读取检查也无法覆盖图片/视频。

### C-19 core 层反向依赖 features，破坏「依赖单向」
- 位置：`lib/core/providers.dart:3, 17-19`；`lib/core/utils/error_logger.dart:8`；`lib/core/utils/permission_gate.dart:7`；`lib/core/audio/preferred_quality.dart:3`；`lib/core/router/app_router.dart:5-19`
- 问题：core 直接 import `features/lyric/data/lyric_repository.dart`、`features/download/data/storage_permission_service.dart`、`features/player/data/models.dart` 以及 14 个 feature 页面。`lib/core` 已无法在不引入 features 的情况下单独编译/测试，feature 也无法独立替换。
- 依据：上述 import 行；项目既有原则「分层清晰、依赖单向」（`docs/PLAN_architecture.md`）。
- 影响：循环依赖风险、单测必须拉起整个 feature 树；`ErrorLogger`/`PermissionGate` 这类底层工具无法复用到其它壳工程。

---

## P3 一致性与代码质量

### C-20 死代码与声明不一致
- `lib/core/config/app_config.dart:6,9-13,16`：`appId`、`platform` 无任何引用（`rg 'AppConfig.appId|AppConfig.platform'` 空）；`platform=''` 与「固定标准版」注释无实现。
- `lib/core/theme/settings_provider.dart:105`：`initSettingsBox()` 无调用点。
- `lib/core/utils/error_logger.dart:205-219`：`logApi` 无调用点（同时导致 C-02 的脱敏路径成为死代码）。
- `lib/main.dart:217`：`_onPlayerError(String message, WidgetRef ref)` 的 `ref` 未使用；`StartupErrorPage.compact` 未使用。
- `lib/core/widgets/song_tile.dart:10-17,211-214`：重复的 export/尾随注释块；`toast.dart`、`dart:async` 等 import 在 `empty_state/gradient_chip/list_skeleton/section_header/song_tile` 中未使用（`rg` 逐文件核对符号无命中）。
- `lib/core/widgets/error_retry.dart:181-200` 自己定义了 `FriendlyError` 类，与 `core/utils/friendly_error.dart` 的同名概念（函数）分叉。

### C-21 声明的最低 SDK 低于实际使用的 API
- 位置：`pubspec.yaml:6-7` 声明 `sdk: '>=3.4.0 <4.0.0'`
- 问题：`CardThemeData` / `DialogThemeData` / `TabBarThemeData`（`app_theme.dart:54,63,232`）以及 `FadeForwardsPageTransitionsBuilder`（272 行）均晚于 Flutter 3.22/Dart 3.4 才提供；在当前声明的下限工具链上无法编译。CI 固定 `FLUTTER_VERSION: 3.47.9`（`.github/workflows/*.yml:12`），掩盖了下限不成立。
- 依据：`flutter analyze` 在当前 CI 版本通过，但 pubspec 的约束允许解析到 3.4 工具链。

### C-22 主题与组件的可访问性/一致性缺口
- `lib/core/widgets/gradient_chip.dart:41-44`：文字固定 `Colors.white`，底色由 `HSL(lightness 0.42)` 生成，浅色相（黄/青）对比度不足，且不随亮/暗主题调整。
- `lib/core/widgets/confirm_dialog.dart:18,22-23,33`：`scheme` 在 `await showDialog` 之前从外层 context 取，主题切换后对话框配色仍是旧值；`confirmLabel` 为空串时会显示空按钮。
- `lib/core/widgets/empty_state.dart:56-59`：`constraints.maxHeight.isFinite` 时用 `Center`，在 `Column` 的有限高度中会撑满父级（非「内容居中」而是「占满再居中」），与注释的「ListView 无界」两分法不完整（`maxHeight` 有限但 `maxWidth` 无界的 Row 场景未处理）。
- `lib/core/theme/app_theme.dart:270-275`：`pageTransitionsTheme` 只覆盖 Android/iOS，其余平台落回默认；`InkSparkle`（50 行）在非 Android 平台的渲染支持未在代码中做平台分支。

---

## 附：跨文件调用点核对结论（用于排除误报）

- 全仓库 19 处 `CachedNetworkImage(Provider)` 均显式传入 `cacheManager: AppImageCache.instance`（逐文件计数相等），因此问题不是「漏传实例」，而是 C-01 的 `getFileStream` 未串行。
- `MemoryCache` 的 12 个调用点全部以 `Map<String,dynamic>` 存取（`home/playlist/lyric/search/mv repository`），当前无实际类型冲突；C-08 的强转风险在后续新增调用方时成立。
- `settings` / `lyric_translations` 盒在 `main.dart:78,82` 先于 `runApp` 打开，正常路径下 C-10 的「打开时机」不触发；仅在 `openSafe` 失败时暴露。
- `_settingsBoxProvider` 在 `themeModeProvider` 首次被根 build watch 时创建，早于任何设置页写入；当前无「先写后读」竞态。
