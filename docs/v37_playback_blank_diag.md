# v3.7 专项排查——播放失败/空白+无日志（进行中）
基线 8a49345（HEAD 1d6b72e）。只读排查。

### 环节 1：播放入口链路（已读 play_helper.dart / player_provider.dart / audio_handler.dart）
- PlayHelper.playHomeQueue/playPlaylistQueue → PlayerController.playQueue → handler.playQueue，入口无 ensureLoggedIn 拦截，无早期 return（空列表除外）。
- handler.playQueue 首行 `if (!await ensureEngineReady()) return;` —— 引擎失败即静默 return（无 _errorController 上报、无 playbackState error）。**注意**：_playAt 内有上报，但 playQueue/playSong 入口的失败完全静默。
- 待查：home_page.dart R-39 fire-and-forget 是否 catch。

### 环节 2：R-39 fire-and-forget 与无日志（home_page.dart:246-250 / 509-513）
- 结论：成立（结构性缺口）
- 证据：`ref.read(playHelperProvider).playHomeQueue(songs, i); context.push('/player');` —— 未 await 未 catch。异常会进 runZonedGuarded → ErrorLogger.handleUncaught **会记录**（main.dart:31-37 与 zone handler 均接）。所以「异常被吞且无日志」不来自这里；但失败时用户不知情（仅 push 了播放页）。
- 证据等级：实测（代码原文）

### 环节 3：播放页「空白」形态
- 结论：song==null 时播放页**不是全空白**——有顶栏（收起按钮+「正在播放」+菜单）、进度条、控制按钮，中间显示「未在播放/未知艺术家」。若用户看到的是这状态 = playQueue 未成功写 _songs/_currentSong。若真的全空白 = build 抛异常 → ErrorWidget.builder（compact StartupErrorPage，深色页+「重启应用」按钮）——那也是「类似空白」。播放页 watch 的所有流都依赖 audioHandlerProvider（普通 Provider，惰性创建），无 null 崩溃点。
- 证据等级：静态推导

### 环节 4（关键）：ensureEngineReady 静默失败链
- audio_handler.playQueue / playSong 首行：`if (!await ensureEngineReady()) return;` —— **无错误上报、无 playbackState error、无 Toast**（对比 _playAt 内的失败有 _errorController.add）。ensureEngineReady 失败仅置 engineError + 加 _errorController —— 但 playQueue 的 return 不经过 _playAt，所以引擎失败时**整个播放请求静默丢弃**，且 main.dart 的 ref.listen(playerErrorProvider) 只在构建时注册，初次事件可能错过……实际上 listener 会收到。但核心：JustAudioBackground.init 在真机失败（通知渠道被禁/ServiceStartNotAllowedException/后台启动限制）→ init 永远 false → 每次播放静默 return → 无声音、播放页 song==null、无任何日志（init 失败只 debugPrint，release 下 debugPrint 在 kReleaseMode 默认被吞）。
- 证据等级：静态推导（代码路径实测，真机触发条件为推测）

### 环节 5：release 日志可见性
- ErrorLogger 只接 FlutterError.onError + runZonedGuarded + playerError 流（Toast）。**所有 debugPrint（含 AudioServiceBootstrap.init failed、[player] direct resolve failed、[auth-sync]）在 release 下不落盘**（debugPrint 在 release 仍输出到 logcat，但用户看的「ErrorLogger 文件」里没有）。
- 结论：无日志与「失败只走 debugPrint/Toast」完全自洽。
- 证据等级：静态推导

### 环节 6：manifest 核对
- AudioService service + MediaButtonReceiver 已声明；POST_NOTIFICATIONS、FOREGROUND_SERVICE_MEDIA_PLAYBACK 已声明。channelId 'com.tiernan.music.channel.audio' 与 init 参数一致。**缺**：无 permission handler 请求 POST_NOTIFICATIONS 运行时授权代码的检查（待查）；Android 12+ 前台服务启动限制不影响 init（init 在 app 前台调用）。
- 证据等级：实测

### 环节 7：歌单全部播放按钮（playlist_detail_page.dart:210-225）
- 结论：排除「按钮没调到」——onPressed 无 ensureLoggedIn 拦截；仅当 tracksAsync 尚在 loading/error 时 `tracks == null` **静默不播放且无 Toast**（失败可感知性缺口，但不是全量失败根因；列表数据正常渲染时 tracks 非空）。
- 证据等级：实测（代码）

### 环节 8：下载 vs 播放路径分叉（自洽性确认）
- 下载：`download_repository.resolveAudioUrl → KgPlayApi.songUrl`，**不创建 AudioPlayer、不经 JustAudioBackground/AudioService**。
- 播放：同一 `KgPlayApi.songUrl`（经 player_repository.resolveUrl），但前提是 `ensureEngineReady()` 成功创建 AudioPlayer。
- 结论：URL 获取链路对两条路径同一实现 →「下载成功」证明 songUrl/签名/dfid 链路在真机可用。播放失败的解释必须落在 songUrl **之后**（AudioPlayer 创建/加载）**或之前**（引擎初始化静默 return，连 songUrl 都没打）。
- 证据等级：静态推导（链路同一性实测）

### 环节 9：dart analyze
- 环境内无 dart SDK（dart: not found），无法执行；静态通读未发现项目自有类真错误。
- 证据等级：实测（环境限制）

### 环节 10：错误可见性盲区汇总（「无日志」解释）
ErrorLogger 只有三类输入：FlutterError.onError（build/框架异常）、runZonedGuarded（未捕获异步异常）、——**播放链路的全部失败都是「捕获后转 Toast/debugPrint」，从不调 ErrorLogger.log**。具体：
1. `ensureEngineReady()` false → playQueue/playSong 静默 return（连 Toast 都没有：ensureEngineReady 里 _errorController.add(engineError) 只在 Bootstrap 失败分支发；main.dart 的 ref.listen(playerErrorProvider) 会 Toast——但仅当 TiernanMusicApp build 已注册 listener，首次冷启动 init 失败发生在 build 前，事件丢失，之后每次播放 ensureEngineReady 重试失败……注意 B-33 修复后失败会重试 init，每次重试都会重新发事件，所以理应有 Toast——除非 init 失败的原因是永久性且 ensureReady 返回 false 前抛出异常被 ensureReady catch(_) 吞掉返回 false——此时 engineError 置位、_errorController.add 仍会发）。
2. 播放失败 catch：`_errorController.add('播放失败：$e')` → 仅 Toast，不落 ErrorLogger。
3. Bootstrap._init 失败：仅 debugPrint。
- 结论：「ErrorLogger 无任何记录」与「播放失败但 UI 至多有 Toast」完全自洽——**播放链路从未接入 ErrorLogger**，本就是盲区。
- 证据等级：实测

### 环节 11：v3.7 回归排查（8a49345..HEAD）
- lib/features/player/data/audio_handler.dart、lib/core/audio/**：**零改动**。mini_player.dart 仅布局降级（LayoutBuilder），不触碰播放逻辑。playlist_detail_page 播放全部无逻辑改动。
- 结论：v3.7 代码改动不构成播放回归；现象应自 v3.6 及之前即存在（或为真机环境因素）。世代守卫 V35-B1-1 复核：catch 首行 token 校验只会**少报**假错误，不会吞掉当次有效请求的真实错误（当次有效请求 token==_playToken 时 `_errorController.add` 正常执行）。
- 证据等级：实测（git diff）

## ———————— 汇总 ————————

## 根因假设排序

**H1（最可能）：音频引擎初始化在真机永久失败 → playQueue/playSong 入口静默 return**
- 机制：`JustAudioBackground.init` 失败（B-33 修复后每次播放都会重试 init，但若为永久性失败如系统限制/插件兼容，永远 false）→ `ensureEngineReady()` false → `audio_handler.playQueue`/`playSong` 首行静默 return（audio_handler.dart:157/192，无上报无 Toast 无 playbackState error）→ 队列未装载 → 播放页 currentSong==null →「未在播放」空态（用户感知为「失败/空白」）；反复进入永远一样（init 失败被 _error 缓存了吗？——_ready=false 不缓存失败 future，每次重试仍失败）→「类似空白的状态」。
- 同时解释四线索：✓下载正常（不走引擎）✓播放失败 ✓全部入口失败 ✓无日志（init 失败只 debugPrint）。
- **为什么无 Toast**：ensureEngineReady 的 Bootstrap 失败分支会发 _errorController.add —— 但 main.dart 的 `ref.listen(playerErrorProvider)` 只在 TiernanMusicApp.build 时注册；且 stream 是广播流，playQueue 静默 return 路径根本不 add 事件。**用户只看到页面没反应。**
- 验证方法（真机，一步定位）：`adb logcat -s flutter | grep -i "JustAudioBackground\|audio"`；或在设置页加临时诊断按钮读 `AudioServiceBootstrap.isReady/error` 与 `audioHandler.isEngineReady/engineError` 展示。

**H2：引擎初始化成功，但 AudioPlayer 创建/加载阶段失败且静默**（如 just_audio 平台通道异常）
- playQueue 会走到 _playAt → 失败进 catch → 有 `_errorController.add('播放失败')` → 应有 Toast。若无 Toast，则更偏 H1；若用户偶见「播放失败」Toast 则偏 H2。
- 验证：logcat 过滤 `flutter` 全量 + 确认用户是否见过任何 Toast。

**H3：fetchDetail/resolveUrl 在播放上下文失败但下载上下文成功**（如 cookie/token 差异、风控按 UA/来源区分）
- 与「同一首歌下载能成」矛盾较弱（songUrl 同一实现），且失败会有 Toast。可能性低。
- 验证：probe 脚本直打原生 /v5/url（三态 cookie，第 33 条）。

**H4：播放页渲染异常（ErrorWidget）→ 真空白**
- ErrorWidget.builder 会显示深色 StartupErrorPage(compact)，用户可能描述为空白；该异常走 FlutterError.onError → **会进 ErrorLogger**。与「无日志」矛盾，排除为主因。
- 验证：让用户描述播放页是否显示「应用启动异常/重启应用」字样。

## 真机诊断清单

1. **抓引擎状态（决定性）**：
   `adb logcat -s flutter | grep -iE "JustAudioBackground|audio|LateInitialization"`，复现一次点播放。
2. **确认 Toast**：点播放瞬间屏幕上是否弹过任何提示（哪怕一闪）？→ 有「播放失败」→ H2 方向；完全无 → H1。
3. **确认播放页形态**：是「有顶栏+进度条+播放按钮但显示未在播放」（H1/H2 空队列态），还是纯深色/纯白（H4/ErrorWidget 或 SplashScreen 未退出）？
4. **日志落盘侧信道**：`adb shell ls /sdcard/Documents/"Tiennan Music"/Logs/` 与 `run-as com.tiernan.music ls files/"Tiernan Music"/Logs`（私有降级目录）——确认是否真的零写入。
5. **通知权限**：系统设置里应用通知是否被禁（Android 13+ POST_NOTIFICATIONS 被拒不阻断 init，但需记录排除）。
6. **系统版本**：Android 版本号；是否厂商 ROM（MIUI/ColorOS 后台启动限制会掐 AudioService）。

## 建议修复（H1 成立时）
1. `playQueue`/`playSong` 入口 `ensureEngineReady()` 失败时：`_errorController.add(engineError!)` + `playbackState` error + **ErrorLogger.log**（第 9 条：失败必须可观测）。
2. `AudioServiceBootstrap._init` 失败改为 `ErrorLogger.instance.log(e, st, source:'audio_bootstrap')`——这是本次「无日志」的直接补口。
3. 播放链路 catch 统一接 ErrorLogger（至少 resolveUrl 失败、_applySource 失败落盘）。
