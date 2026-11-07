# v3.7 专项——权限请求网关修复 + 播放功能全面实测级检查

基线 `bb24c9c`（8de30b4 已含可疑 V37-PLAY-1 提交，见 PLAY-01）。逐项静态走查 + 立即修复，
改动标 `V37-PERM-xx` / `V37-PLAY-xx`。dart analyze 结果逐文件附后（环境无 Flutter SDK 与
多数三方包源码，包符号报错按噪音过滤，见文末「analyze 噪音说明」）。

---

## 任务一：权限请求网关

### 1. manifest 声明核对 —— ✅ 无缺陷
- `MANAGE_EXTERNAL_STORAGE` 已声明（无 maxSdkVersion，正确——11+ 才生效）。
- `requestLegacyExternalStorage="true"` 在 `<application>` 上（V37-LOG-09），Android 10 生效。
- `WRITE_EXTERNAL_STORAGE maxSdkVersion=28`、`READ_EXTERNAL_STORAGE maxSdkVersion=32` 正确。
- `READ_MEDIA_AUDIO`、`POST_NOTIFICATIONS` 已声明。

### 2. 请求链路 —— ❌ 缺陷已修
- 现状：`settings_page._requestAllFilesAccess` → `requestAllFilesAccess()` →
  `Permission.manageExternalStorage.request()`。MANAGE_EXTERNAL_STORAGE 的 request()
  **没有系统弹窗**，靠跳转「所有文件访问」设置页；部分 ROM 上跳转静默失败 → request
  立即返回当前态（未授权 false），用户点按钮毫无反应。
- **V37-PERM-02a**：`_requestAllFilesAccess` 在返回未授权时兜底
  `openAppSettings()`，保证用户总能到达可授权的系统界面。
- 请求异常/ROM 差异此前被 `catch (_) {}` 静默吞掉（违反第 6/9 条）。
  **V37-PERM-04**：`storage_permission_service.requestAllFilesAccess` 失败与返回值
  均 debugPrint 留痕（verbose 日志开启时落盘）。

### 3. 授权后刷新 —— ❌ 缺陷已修（用户反馈的直接根因）
- 现状：状态只在 initState / 按钮回调里查询，**无 `AppLifecycleState.resumed` 监听**。
  用户从系统设置页授权返回后 UI 永远显示「未授权」，且「授权所有文件访问」按钮
  （按 `resolveRootMode()=='root'` 条件隐藏）也不会消失——即「网关没做好」的表象。
- **V37-PERM-02b**：`_SettingsPageState` 挂 `WidgetsBindingObserver`，resumed 时重查
  `_storageGranted` 与 `_storageRoot`；initState addObserver / dispose removeObserver
  对称（第 20 条）。
- **V37-PERM-03**：原按钮回调把 request() 返回值当「用户授权结果」弹
  「已授权/未授权」Toast——但系统页跳转**无结果回调**，request 立即返回跳转前状态，
  用户授权回来反而看到「未授权」误导提示（第 31 条）。已移除该 Toast，真实状态由
  resumed 刷新回填。

### 4. 降级链 —— ✅ 三处均已生效
逐处核对 `resolveRoot()` / `isAllFilesAccessGranted()` 实际调用：
- **error_logger._writeVerbose**：先 `resolveRoot()` 直写 `<root>/logs/`，失败 →
  MediaStore `Download/TiernanMusic/logs/`（verboseRelativePath），再失败 → App 私有
  目录。三层降级完整。
- **public_media_store._publishDirect**：`isAllFilesAccessGranted()` → rootPath 直写；
  未授权 → 原生 publicDir 探测的 Download 根 + 同名子目录；再失败 fallbackDir。
- **download_provider._run**：`resolveStrategy()`（内部先查 isAllFilesAccessGranted →
  directPath；≥29 → mediaStore；≤28 走 storage 运行时权限）。App 生命周期 resumed 时
  `onAppLifecycle` 重置 `_strategyResolved`（download_provider:74-76），权限中途授权/
  收回能恢复——已有机制，无需改。

### 5. 权限状态展示 —— ✅ 一致（经 V37-PERM-02b 修复后）
「当前模式」与「存储权限」两个入口都基于同一权威 `StoragePermissionService`
（`resolveRootMode()`/`hasStorageWriteAccess()`），无第二状态源。resumed 刷新后
显示与实际写入路径一致。

---

## 任务二：播放功能 10 子项

### 子项 1：AndroidManifest 声明 —— ✅ 无缺陷
service（`mediaPlayback` 类型 + MediaBrowserService intent-filter）、
MediaButtonReceiver、WAKE_LOCK、FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK
全部齐全。真机验证：`adb shell dumpsys package com.tiernan.music | grep -A2 "service"`。

### 子项 2：JustAudioBackground.init 参数 —— ❌ 严重缺陷，已修
- **发现**：HEAD 工作区已有一个提交 8de30b4「V37-PLAY-1 init 补 handler 参数」，向
  `JustAudioBackground.init` 传 `handler: TiernanAudioHandler(...)`。**包源码核实
  （just_audio_background.dart:34-51）：init 没有 handler 参数**——该提交是编译级
  真错误（还诱导启动期裸构造 PlayerRepository 绕过 Provider 生命周期）。若真按此
  构建必然失败 → 引擎永远初始化失败 → H1 成立 →「播放全空白」。
- **V37-PLAY-01**：移除伪造 handler 参数；保留 channelDescription；
  显式 `androidStopForegroundOnPause: false`（暂停不降前台服务，规避 Android 12+
  暂停后恢复需重启 service 受后台启动限制失败——部分 ROM「暂停后无法续播」根因）。
- channelId `com.tiernan.music.channel.audio` / 名称「汀澜音乐播放」与 manifest 一致
  （渠道由插件按 init 参数动态创建，manifest 无需静态声明渠道）。

### 子项 3：AudioService.init 调用 —— ✅ 无缺陷（设计如此）
just_audio_background 0.0.1-beta.13 内部完成 audio_service 的 handler 配置
（`_JustAudioBackgroundPlugin.setup` → 平台侧 configure），**不需要**再显式
`AudioService.init`。项目无第二个 AudioService.init 调用点（grep 确认仅
player_provider 注释提及）。handler 单例由 `audioHandlerProvider`（普通 Provider，
应用生命周期常驻）保证。

### 子项 4：通知渠道/POST_NOTIFICATIONS 运行时权限 —— ❌ 缺陷已修
- manifest 已声明 POST_NOTIFICATIONS，但**全项目无任何运行时申请代码**
  （grep `ensureNotification|Permission.notification` 仅定义无调用）→ Android 13+
  默认拒绝 → 媒体通知不显示、锁屏控制不可见，且部分 ROM 上前台服务通知缺失会
  在 app 退后台时把音频服务一并掐掉（后台播放失效）。
- **V37-PLAY-02**：main.dart 首帧 post-frame 回调非阻塞申请
  `PermissionGate.ensureNotification()`（内部对 permanentlyDenied 会引导系统设置页）。
- 真机验证：Android 13+ 首次启动应弹通知权限框；`adb shell dumpsys notification
  --noredact | grep -A3 tiernan` 播放时应有 MediaStyle 通知。

### 子项 5：引擎初始化失败路径 —— ⚠️ 半缺陷，已补
- ensureEngineReady 失败已有 `_errorController.add` → Toast（main.dart:259 监听）
  + ErrorLogger 落盘 + playbackState error（v3.6/v3.7 已修部分）。
- **缺口**：Bootstrap._init 失败只 debugPrint，从未落 ErrorLogger——release 下
  「播放失败且无日志」盲区的源头（排查报告环节 10 结论）。
  **V37-PERM-01**：`_init` catch 内 `ErrorLogger.instance.log(source:'audio_bootstrap')`。
- **V37-PLAY-03**：全屏播放页顶部新增引擎错误 banner（读 `handler.engineError`），
  Toast（3 秒即逝）之外常驻可见，用户进播放页就知道「音频服务未就绪」而非空白。

### 子项 6：播放页空态 —— ✅ 无缺陷（现状澄清）
songProvider null 时播放页**不是全空白**：有顶栏、MV 入口区、封面占位、「未在播放/
未知艺术家」、进度条、全部控制键。用户描述的「空白」若为真全白/全黑，则命中的是
H1（队列从未装载）或 ErrorWidget（V35-C3 已有重启按钮）。本轮修复（PLAY-01/02/03）
后 H1 链路闭合。真机验证：见文末诊断清单。

### 子项 7：playQueue 入口 —— ⚠️ 半缺陷，已补
- 链路完整：按钮 → playHelper.playPlaylistQueue → PlayerController.playQueue →
  handler.playQueue（R-39 fire-and-forget，异常走 runZonedGuarded 落盘，成立）。
- **缺口**：playlist_detail_page「播放全部」在 tracks loading/error 时**静默不播**
  （排查报告环节 7）。**V37-PLAY-04**：loading 分支 Toast「加载中」，其余失败分支
  Toast「加载失败」（用既有 l10n key，无新文案）。

### 子项 8：20028 验证闭环 —— ✅ 无缺陷
触发 → `_extractApiException` 识别 → `_pendingSongIndex` 记录 + `_verificationController`
→ VerificationListener（挂在 MainShell 外层，app_router.dart:128）→ CaptchaPage →
pop(true)（captcha_page 3 处成功出口均 pop(true)）→ `retryPendingPlayback()` →
`_playAt(_pendingSongIndex)`。世代守卫完整。真机验证：`adb logcat -s flutter | grep 20028`，
触发后应自动弹验证页，完成后自动续播原歌。

### 子项 9：音频焦点 —— ✅ 无缺陷
`_configureSession()`：`AudioSessionConfiguration.music()`（打断其他应用；被通话/
导航打断由 just_audio 默认 duck+pause 处理）。try-catch 包裹，失败不阻断播放
（第 11 条）。真机验证：播放中来电 → 应自动暂停，挂断后不自动恢复（music 配置
默认行为）；`adb logcat -s AudioTrack AudioFlinger | grep -i focus`。

### 子项 10：后台播放 —— ⚠️ 已由 PLAY-01/02 间接修复
- manifest：service `foregroundServiceType="mediaPlayback"` + 权限齐全 ✅。
- 缺口在运行时：①`androidStopForegroundOnPause` 包默认 true，暂停即降前台 →
  部分 ROM 恢复播放需重启 service 撞后台启动限制（PLAY-01 已显式 false）；
  ②Android 13+ 通知权限被拒时前台服务通知不可见，部分 ROM 直接不认前台服务
  （PLAY-02 已补申请）。
- 真机验证：播放中锁屏 10 分钟应继续出声；`adb shell dumpsys activity services
  com.tiernan.music` 应见 foreground service；后台被杀时
  `adb logcat | grep -i "background start"`。

---

## dart analyze 逐文件结果

环境：Dart SDK 3.13.7（/opt/dart/bin），**无 Flutter SDK、无 pub-cache**
（仅 /tmp 下散落的 audio_service/just_audio/dio 等部分包源码，已尽力构造
package_config，Flutter/riverpod/go_router/hive/permission_handler 等仍不可解析）。
按任务书规则，**Flutter SDK 与三方包符号报错属噪音**；项目自有类报错即真错误。
逐文件（过滤 uri_does_not_exist 及未解析包符号后的结果）：

| 文件 | 结果 |
|---|---|
| lib/core/audio/audio_service_bootstrap.dart | ✅ 无项目自有类错误（残留 4 条均为 JustAudioBackground/debugPrint 包符号噪音） |
| lib/core/utils/error_logger.dart | ✅ 无自有类错误（MethodChannel/debugPrint 包符号噪音；error_logger 未改动，属触碰核对文件） |
| lib/features/settings/presentation/settings_page.dart | ✅ 无自有类错误（ConsumerState/mounted/setState/AppLifecycleState 等框架符号噪音；override 警告同源） |
| lib/features/download/data/storage_permission_service.dart | ✅ 无自有类错误（Permission/openAppSettings/MethodChannel 包符号噪音） |
| lib/features/download/data/public_media_store.dart | ✅ 无自有类错误（未改动，核对文件） |
| lib/features/download/download_provider.dart | ✅ 未改动、无自有类错误（dead_code 警告为既有代码，非本次触碰范围，`state`/AppLifecycleState 噪音） |
| lib/main.dart | ✅ 无自有类错误（Hive/debugPrint/Widget 框架符号噪音） |
| lib/features/player/data/audio_handler.dart | ✅ 仅 3 条：audio_session 包未解析噪音（AudioSession/AudioSessionConfiguration），无自有类错误（未改动，核对文件） |
| lib/features/player/presentation/full_player_page.dart | ✅ 无自有类错误（Widget/BuildContext/Scaffold 框架符号噪音） |
| lib/features/playlist/presentation/playlist_detail_page.dart | ✅ 无自有类错误（框架符号噪音） |
| lib/features/player/player_provider.dart | ✅ 无错误（核对文件，未改动） |
| lib/features/player/play_helper.dart | ✅ 无错误（核对文件，未改动） |
| lib/features/auth/presentation/verification_listener.dart | ✅ 无自有类错误（核对文件，未改动） |

## 改动清单

| 标记 | 文件 | 内容 |
|---|---|---|
| V37-PERM-01 | audio_service_bootstrap.dart | init 失败落 ErrorLogger（audio_bootstrap 源） |
| V37-PERM-02a/b | settings_page.dart | openAppSettings 兜底 + resumed 重查 + observer 对称 |
| V37-PERM-03 | settings_page.dart | 移除误导性「未授权」Toast |
| V37-PERM-04 | storage_permission_service.dart | request 失败/结果留痕 |
| V37-PLAY-01 | audio_service_bootstrap.dart | 移除非法 handler 参数 + 显式 stopForegroundOnPause:false |
| V37-PLAY-02 | main.dart | Android 13+ POST_NOTIFICATIONS 运行时申请 |
| V37-PLAY-03 | full_player_page.dart | 引擎错误常驻 banner |
| V37-PLAY-04 | playlist_detail_page.dart | 播放全部静默分支补 Toast |

改动均未 commit（遵守禁止提交）。l10n 未新增 key（PLAY-04 用既有 loading/loadFailed）。

---

## 8 行内汇报

1. **权限网关修 4 处**（PERM-01..04）：跳系统页失败兜底 openAppSettings、resumed 重查授权态（用户反馈根因）、移除误导 Toast、request 留痕。
2. **10 子项结论**：①manifest✅ ②init 参数❌已修（**发现并清除 8de30b4 伪造 handler: 参数——该参数在 just_audio_background 0.0.1-beta.13 中不存在，是真编译错误，正是 H1 根因**）③AudioService.init✅ ④POST_NOTIFICATIONS 运行时申请❌已修 ⑤引擎失败反馈⚠️已补（落盘+播放页 banner）⑥播放页空态✅（非全空白，空队列态）⑦playQueue 入口⚠️已补 Toast ⑧20028 闭环✅ ⑨音频焦点✅ ⑩后台播放⚠️由①④修复覆盖。
3. **立即修复 8 处**：V37-PERM-01/02/03/04 + V37-PLAY-01/02/03/04（10 文件触碰、逐文件 analyze 通过）。
4. **需真机验证**：Android 13+ 通知权限弹窗与媒体通知显示；init 是否成功（`adb logcat -s flutter | grep -iE "JustAudioBackground|audio"`）；锁屏/后台持续播放；20028 验证闭环；授权返回后设置页状态刷新。
