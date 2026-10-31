# 启动卡死排查报告（audit_startup.md）

> 目标：根治「App 卡在第一屏」（系统启动屏不消失 / 首页骨架屏一直转）。
> 约束：仅改 `lib/`、`android/app/src/main/res/`、`AndroidManifest.xml`；未触碰 `.github/`、`pubspec.yaml`。

---

## 0. 结论速览

| # | 检查项 | 结论 | 是否改动 |
|---|--------|------|----------|
| 1 | 主代理 4 处修复 | 语法/逻辑基本正确；音频惰性化后所有 `_player` 使用点补了 `ensureInitialized()`（**原 setRepeatMode 等 4 个 override 缺**） | 补 8 处 |
| 2a | `app_router.dart` 同步 IO | 无。`initialLocation='/home'`，全 `builder` 纯同步、无网络/IO | 否 |
| 2b | Provider 同步构造 | **发现 `globalContainer = ProviderContainer()`（顶层第二容器）**，读取即抛 `UnimplementedError`（kgDeviceProvider 未 override） | 是（删除 + 调用点改 ref） |
| 2c | `settings_providers.dart` 同步 `Hive.box` | **`_box()` 同步读取，box 未开则抛异常**（设置页/首帧 build 崩溃） | 是（改安全可空） |
| 2d | 首屏触发的 FutureProvider | `homeDataProvider`（12s 兜底）、`_userPlaylistsProvider`；均保证 resolve | 是（library 修复） |
| 3 | 无限 loading | 首页骨架屏 `homeDataProvider` 有 12s 超时 + 全空抛错，**保证 resolve**；其余 loading 页无死等 | 否（已保障） |
| 4 | Android 启动屏配置 | styles.xml / Manifest 均**正确**，无引用不存在资源 | 否 |
| 5 | audio_service 双重初始化 | **不存在 `AudioService.init` 死锁**（全仓只有 `JustAudioBackground.init` 一次）；但自定义 `BaseAudioHandler` 与 just_audio_background 架构冗余，建议重构（见 §5） | 否 |
| 6 | `kgDeviceProvider.overrideWithValue(device!)` | **`device!` 有 null 崩溃风险**（兜底 generate 也可能抛） | 是（改为可空 + 最终兜底 + 错误页） |
| 7 | 启动 watchdog | **原本没有**，已新增（15s 未首帧则打日志） | 是 |

**最可能造成「卡在系统启动屏」的根因**：`main()` 里准备阶段一旦有未预期异常，`runZonedGuarded` 的 onError 只打日志，**导致 `runApp` 永不执行 → 原生 LaunchTheme 永不被替换**。本次已把 `runApp` 改为「无论准备阶段是否异常都必定执行」。

---

## 1. 验证主代理 4 处修改

### 1.1 `lib/main.dart`（已重写，见 §6）
- `runZonedGuarded` + `ErrorWidget.builder` + 逐 box `openSafe` + 8s 超时：**正确**。
- 但原实现存在两个缺陷，已修：
  - **缺陷 A（致命）**：准备阶段异常时 onError 只 `debugPrint`，`runApp` 不执行 → 卡系统启动屏。已用外层 `try/catch` 包住全部准备逻辑，异常只记 `_startupError`，**必定 `runApp`**。
  - **缺陷 B**：`_startupError` 声明后从未被赋值（`TiernanMusicApp` 里的错误页是死代码）。已在准备失败/设备兜底失败时赋值，真正生效。

### 1.2 `lib/features/home/data/home_repository.dart`
- `fetchHomeData()`（第 144-）、`safe()` 单项 `Duration(seconds: 12)`（第 145 行）、`Future.wait` 全并发（第 154 行）、全空抛错（第 170 行）：**正确**。最坏 ~12s 必 resolve，**不会无限骨架屏**。

### 1.3 `lib/features/player/data/audio_handler.dart`（已加固）
- `_playerInstance` 惰性 + `_player` getter `??= AudioPlayer()`（第 24-25 行）：**正确**。
- `ensureInitialized()`（第 30 行）：**正确**，幂等。
- **发现遗漏**：`play()/pause()/stop()/seek()/skipToNext()/skipToPrevious()/setShuffleMode()/setRepeatMode()/onTaskRemoved()/onNotificationDeleted()` 这些 `@override` 直接用 `_player`，**未先 `ensureInitialized()`**。虽然 `_player` getter 会创建实例，但不会挂 `playbackEventStream` 监听、也不配置 AudioSession。
  - 已在这 8 个方法入口统一补 `ensureInitialized();`（setRepeatMode 最初漏改，已二次修正）。
- **全仓搜 `AudioPlayer(` / `new AudioPlayer`**：仅 `audio_handler.dart:25` 一处。**无其它直接 new AudioPlayer**。

### 1.4 `lib/core/theme/settings_provider.dart`
- `_settingsBoxProvider` 用 `Hive.isBoxOpen` 判空、失败返回 `null`（第 6-13 行），所有 notifier 走 `box?.`：**正确**。

---

## 2. 阻塞首帧的同步操作排查

### 2.1 `lib/core/router/app_router.dart`
- `initialLocation: '/home'`；`StatefulShellRoute.indexedStack` + 各 `GoRoute.builder` 全部返回 `const` Widget，**无同步 IO/网络/await**。`MainShell` 仅组 `Scaffold` + `MiniPlayer` + `NavigationBar`。**结论：无阻塞项，未改动。**

### 2.2 Provider 同步构造（重点发现）
- **`lib/core/providers.dart:22`（旧）`final globalContainer = ProviderContainer();` + `kugouApi` getter**：
  - 这是一个**没有 `ProviderScope` override 的第二容器**。`kugouApi` → `kugouApiClientProvider` → `kgDirectApiProvider` → `kgClientProvider` → `kgDeviceProvider`，而 `kgDeviceProvider`（`kg_providers.dart`）默认 **`throw UnimplementedError`**。任何读取 `kugouApi` 都会抛。
  - 调用点：`library_page.dart` 的 `_userPlaylistsProvider` 用 `PlaylistRepository(kugouApi)`（旧第 328 行）→ 该 FutureProvider 直接报 `UnimplementedError`，「我的歌单」永远出错。
  - **修复**：删除 `globalContainer` 与 `kugouApi` getter；`library_page.dart:6` 改 `show kugouApiClientProvider`，`library_page.dart:328` 改 `PlaylistRepository(ref.watch(kugouApiClientProvider))`。
- **`lib/features/settings/presentation/settings_providers.dart`**：`_box() => Hive.box('settings')` 同步读取，box 未打开会 `throw StateError`。设置页 build 时首次 watch 即触发。
  - **修复**：`_box()` 改为可空安全返回（`isBoxOpen` 判断，失败 `null`），各 notifier 用 `_box()?.get(...) ?? 默认值` 与 `_box()?.put(...)`，box 缺失时降级内存态，绝不抛。
- 其余 `Provider((ref)=>...)`（`playerRepositoryProvider`、`audioHandlerProvider`、`downloadRepositoryProvider`、`lyricRepositoryProvider` 等）构造均为轻量对象（Dio/Client 构造），**无同步网络/IO**。

### 2.3 首屏实际触发的 FutureProvider
- **首页**：`homeDataProvider`。保证 resolve（§1.2）。
- **IndexedStack 各分支**（LibraryPage / SettingsPage 会被 `StatefulShellRoute.indexedStack` 预构建）：`downloadedAudioProvider`（同步读 Hive，box 已在 main 打开，安全）、`_userPlaylistsProvider`（已修复）。这些异步/轻量，不阻塞首帧，但其中同步 `Hive.box` 已按 §2.2 加固。

---

## 3. 无限 loading 排查

- 首页 `_HomeSkeleton`：`homeDataProvider` = `FutureProvider(fetchHomeData)`，内部每项 12s 超时 + `Future.wait` + 全空抛错 → 状态必从 `loading` 转 `data`/`error`。**不会无限转**。
- `library` `playlistsAsync.when(loading: 骨架)`：`_userPlaylistsProvider` 在 `!loggedIn` 时直接返回 `[]`，否则网络请求（修复后走真实 client），会 resolve 或 error。
- `authStateProvider` 的 loading 不作为任何骨架屏显示（仅在 `TiernanMusicApp` 里 `ref.listen` 同步 token）。
- 结论：**无保证不了 resolve 的骨架屏**。

---

## 4. Android 启动屏配置

- `android/app/src/main/res/values/styles.xml`
  - 第 2 行 `LaunchTheme` 父主题 `@android:style/Theme.Black.NoTitleBar` —— **标准合法主题**，不会导致启动屏不消失。
  - 第 8-9 行 `NormalTheme` 父主题同样合法，`android:windowBackground = ?android:colorBackground` 为**系统内置属性**，非不存在资源。
  - `LaunchTheme` 未自定义 `windowBackground`（沿用父主题黑色底），无悬空引用。
- `android/app/src/main/AndroidManifest.xml`
  - 第 32 行 Activity `android:theme="@style/LaunchTheme"`。
  - 第 37-38 行 `io.flutter.embedding.android.NormalTheme` meta-data → `@style/NormalTheme`，**正确指向**。
- **结论：启动屏配置正确，无需改动。** 真正「卡启动屏」来自 §6 的 `runApp` 未执行。

---

## 5. audio_service 启动冲突（重点结论）

**结论：不存在「`AudioService.init` 永不返回」的双重初始化死锁。**

- 全仓 grep `AudioService.init`：**0 处**；仅有 `main.dart` 的 `JustAudioBackground.init`（1 次）。`just_audio_background` 内部会自己调用 `AudioService.init` 并安装其内部 handler，只初始化一次。
- 自定义 `TiernanAudioHandler extends BaseAudioHandler` 目前是**独立对象**，从未注册进 AudioService；它的 `playbackState` / `mediaItem` 流实际上**没有消费者**（系统通知由 just_audio_background 监听真实 `AudioPlayer` 驱动）。因此它**不会**与内部 handler 冲突、也不会阻塞 init。
- 顺序安全：`main()` 中 `JustAudioBackground.init`（8s 超时）在 `runApp` 之前完成；`AudioPlayer` 惰性创建发生在其后（首帧 MiniPlayer 触发），满足「init 先于首个 AudioPlayer」。

**架构建议（可选重构，本次不实施）**：当前是「just_audio_background + 自有 BaseAudioHandler」混合体，`TiernanAudioHandler` 的 `BaseAudioHandler` 部分基本是冗余壳。两条干净路线二选一：
- **方案 A（推荐，改动最小）**：保留 `just_audio_background`，把 `TiernanAudioHandler` 降级为纯业务控制器（**去掉 `extends BaseAudioHandler`**，只持有 `AudioPlayer` + 队列 + 验证重试逻辑），`mediaItem` 用 `MediaItem(tag:)` 交给 just_audio_background。UI 已全部监听真实 `AudioPlayer` 流，几乎零改动。
- **方案 B**：放弃 `just_audio_background`，改用 `AudioService.init(builder: () => TiernanAudioHandler(...))` 注册自定义 handler，通知/媒体按钮由 `BaseAudioHandler` 的 `playbackState`/`mediaItem` 驱动（需补全 `playbackState` 完整字段，当前 `_broadcastState` 已较完整）。

> 无论 A/B，都**不影响本次「卡首屏」修复**；当前架构能正常播放，问题在启动路径。

---

## 6. `ProviderScope` override 与 main 加固（已改）

`lib/main.dart` 变更点（行号为当前文件）：
- L25 `runZonedGuarded` 内，**把全部准备逻辑包进外层 `try { ... } catch`**（L28-L99），异常只记 `_startupError`，不再中断流程。
- L103-L111 设备身份**最终兜底**：`device == null` 时再 `KgDevice.generate()`；仍失败则 `_startupError ??= StateError(...)`，避免下文 `device!` 崩溃。
- L114-L124 **必定 runApp**：`overrides` 用可空条件 `if (dev != null) kgDeviceProvider.overrideWithValue(dev)`（`dev` 为 final 非空局部变量，Dart 类型提升安全），彻底消除 `device!` 的 null 崩溃与「未 runApp」两种卡死。
- L172-L176 `_startupError` 生效：有值则显示 `StartupErrorPage`，白屏/卡屏变可读错误页。

---

## 7. 启动看门狗（已新增）

`lib/main.dart`：
- L132-L135 `WidgetsBinding.instance.addPostFrameCallback` 首帧渲染后置 `_firstFrameRendered = true` 并打日志。
- L136-L143 `Timer(Duration(seconds: 15))`：若 15s 内未渲染首帧，打印 `[startup][watchdog] 15 秒内未渲染首帧…startupError=…`。
- 顶部 `bool _firstFrameRendered = false;`（L21）。

---

## 8. 改动文件清单

| 文件 | 改动 |
|------|------|
| `lib/main.dart` | 准备逻辑全包 try/catch、必 runApp、device 兜底、_startupError 生效、15s watchdog |
| `lib/core/providers.dart` | 删除危险 `globalContainer` + `kugouApi` 全局 getter，改为注释说明 |
| `lib/features/library/presentation/library_page.dart` | 改用 `ref.watch(kugouApiClientProvider)`（L6、L328） |
| `lib/features/settings/presentation/settings_providers.dart` | `_box()` 安全可空，所有 notifier 降级内存态 |
| `lib/features/player/data/audio_handler.dart` | 8 个公开 override 补 `ensureInitialized()` |

## 9. 校验

- `bash check_braces.sh`：**通过**（`brace check done`，无 UNBALANCED/UNCLOSED）。
- 无 Flutter/Dart SDK 环境，未跑 `flutter analyze`；已逐文件人工核对语法与类型（`Override` 列表、可空提升、`_player` 使用点）。

## 10. 建议后续（非阻塞）

1. 若要在真机复现定位，抓 `logcat | grep startup` 看 watchdog 是否触发，以及 `[startup] preparation failed` 的具体异常。
2. 按 §5 方案 A 收敛音频架构，去掉 `TiernanAudioHandler` 的 `BaseAudioHandler` 冗余继承。
3. 可把 `JustAudioBackground.init` 的 8s 超时下调到 ~4s，缩短极端情况下的启动屏停留。
