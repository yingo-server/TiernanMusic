# v5.1 交叉审查 B4 批 · 视角 C（用户路径与一致性）

基线：v5.0.0（71b4d73）后当前磁盘主线；只读审查，当前磁盘状态。
范围：43 文件 / 9550 行。本代理通读 ✅ 标注的 12 个文件，其余只做 ≤8 文件跨文件契约抽查（签名 + 调用点）。
视角：真实用户操作序列（进入→操作→反馈）的断点、空/加载/失败三态、可观测性、i18n、生命周期、跨模块契约一致性、回归。
证据等级：本报告所有结论均为「静态推演」或「实锤」（静态可证的代码事实），**未实测**（无 SDK/构建/真机，任务书禁止）。
规范：QUALITY_STANDARD.md（第 1–33 条）+ REVIEW_SPEC.md；冲突以 QUALITY_STANDARD 为准。
去重索引已读：b1/b2/b3_merged、b3_b、b3_c 的条目标题；不重复报告已审条目。

---

## 逐文件记录（实时 append）

### F1 `lib/app/router.dart`（163 行，完整读）

### lib/app/router.dart:22-27 未配置 `errorBuilder` / `redirect`，未知深链无本地化错误页与脱出口
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（深链属于必须校验的数据边界）
- 依据：`GoRouter` 构造参数只有 `initialLocation` 与 `routes`，无 `errorBuilder`、无 `onException`、无顶层 redirect；而同文件 :63-95 对「/rank/:rankId 非法」这一同类深链边界专设了 `context.l10n.rankParamsInvalid` + `context.go('/home')` 的错误页。同一类用户输入（非法深链）在本文件内存在两种截然不同的处理口径。
- 影响：用户点开拼错或截断的分享链接（例如 `/playlist` 缺 `:id`、`/rank/abc` 之外的未知路径）时，落到 go_router 默认错误呈现（框架自带的英文/调试态信息），既不是应用语言也不提供「返回首页」按钮；若该链接是冷启动的 initialLocation，系统返回键直接退出应用而不是回首页。与 :63-95 已经做好的中文引导形成明显不一致。
- 证据等级：静态推演（默认错误页具体形态未实测，任务书禁止构建/真机）

### lib/app/router.dart:22 / 115-127 GoRouter 由无 `dispose` 的 `Provider` 持有，`MainShell` 内的 NavigationBar 依赖 `shell.currentIndex` 但路由对象无重建/失效约定
- 级别：P3
- 违反：QUALITY_STANDARD 第 20 条（生命周期双向对称）
- 依据：`appRouterProvider = Provider<GoRouter>((ref) => GoRouter(...))` 未指定 `dispose`；`GoRouter` 自身持有路由信息解析与刷新监听。`MainShell` 是 StatelessWidget，选中态完全由 `shell.currentIndex` 提供（:135-140）。
- 影响：热重载 / provider 被失效重建时旧路由对象未被释放，存在旧监听继续消费刷新事件的窗口；用户侧可能表现为一次深链打开旧页面。该路径在正常使用序列中不易触发，定 P3。
- 证据等级：静态推演（未实测热重载；`main.dart` 是否 invalidate 该 provider 不在本代理抽查范围）

### 复核通过（F1）
- :90-95、:141-156 底部导航四项标签与排行榜错误页文案全部走 `context.l10n`，路由层无硬编码用户可见中文；i18n 一致。
- :63-95 非法 rankId 直接给本地化错误页 + 「返回首页」出口，失败可观测且可脱出（第 9 条）。
- :23-36 `StatefulShellRoute.indexedStack` 四个分支各自保活，切换 tab 不重建页面，用户切走再回来不丢滚动位置与输入内容。

#### F1 `dart analyze lib/app/router.dart`
```
62 issues found（61 error + 1 warning）
噪音归类：uri_does_not_exist ×3（package:flutter/material.dart、flutter_riverpod、go_router 三方包缺失）
          undefined_function ×24 / undefined_identifier ×12 / creation_with_non_type ×9 /
          undefined_method ×7 / undefined_class ×3 / extends_non_class ×1 /
          non_type_as_type_argument ×1 / super_formal_parameter_without_associated_named ×1 /
          override_on_non_overriding_member ×1（均由上述 3 个包缺失导致 GoRouter/Widget/Icon/Icons/
          context.l10n 等符号无法解析的级联噪音）
项目自有类错误：0（import 的 16 个 lib/ 相对路径逐一核对，全部存在）→ 合格
```

### F2 `lib/core/image/app_image_cache.dart`（79 行，完整读）

### lib/core/image/app_image_cache.dart:57-67 / 69-79 `getFileStream` 的串行闸门只挡住「开始消费」，流本身并行下载，与文件头承诺的「同一时刻只有一个 DB 事务」不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明并保护）、第 31 条（注释须与行为一致）
- 依据：`_serial` 把每个排队的 `action` 链接到 `_queue`（:41-51），只有 `getSingleFile` 的 `action` 真的是「下载+写入」（:61-62）。`getFileStream` 传入的是空操作 `_serial(() async {})`（:74），await 后立即 `yield* super.getFileStream(...)`（:75-77）——此后不再持有任何闸门；而且 `_serial` 的 `_queue` 在空操作完成后即释放，下一个调用者的 `await _serial(() async {})` 立即通过。文件头 :7-21 声称 CachedNetworkImage 的 getFileStream 链路也「串行化」，:68-70 注释声称「不串行化则 sqflite 并发写事务 → SQLITE_BUSY」。统计核对：全库 15 个使用 `CachedNetworkImage` 的文件全部显式传 `cacheManager: AppImageCache.instance`，即主要链路确实走这个方法。
- 影响：首页/榜单首屏一次并发拉几十张封面时，多个 `getFileStream` 仍可同时进入 `super` 的下载/写库路径；文件头描述已被修掉的 `DatabaseException(database is locked)` 日志刷屏与 IO 拖慢会从这个入口重现，用户表现为首屏封面加载慢/偶发不显示。属「承诺的修复实际未覆盖主链路」的回归。
- 证据等级：静态推演（`flutter_cache_manager` 内部是否对下载再排队未实测；按注释自身陈述的「本身不做并发控制」推演）

### lib/core/image/app_image_cache.dart:35-45 `maxNrOfCacheObjects: 600` 与「500MB 字节上限」注释互相矛盾，清缓存入口对图片盒无独立可见性
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，不得与实现相反）
- 依据：注释 :32-34 写「加 500MB 上限」，紧接着 :34-38 又写「Config 无字节上限参数……条目上限 600 已由 maxNrOfCacheObjects 承担；字节维度由『清缓存』入口（settings_page emptyCache）+ 用户手动兜底」，但 `Config` 实参里只有 `stalePeriod: 30 days` 与 `maxNrOfCacheObjects: 600`（:29-31），没有任何 500MB 语义；「用户手动兜底」对 App 内图片缓存无对应操作。
- 影响：用户在设置页看到的清缓存说明与实际容量口径不一致；长期大量浏览封面时仍可能占用较大内部存储而没有任何字节维度提示。定 P3（该现象需长期运行才可见，未实测）。
- 证据等级：静态推演

### 复核通过（F2）
- :26 / :38 `AppImageCache._()` + `static final instance` 全局单例，且对全库 15 个 `CachedNetworkImage` 使用文件逐一核对：`cacheManager: AppImageCache.instance` 全部到位，无一处退回默认实例（与 :22-23 的强约束一致，用户切页不会因多实例产生重复下载）。
- :17 静态过期 30 天 + 条目上限 600，满足第 25 条「资源必须有常量上限」。
- :44-51 `_serial` 用 `Completer` 显式 completeError 传递异常与 stack，未吞异常（第 6/9 条）。

#### F2 `dart analyze lib/core/image/app_image_cache.dart`
```
11 issues found（9 error + 2 warning）
噪音归类：uri_does_not_exist ×2（package:file/file.dart、package:flutter_cache_manager/...，三方包缺失）
          extends_non_class ×1 / undefined_method ×1 / extra_positional_arguments ×1 /
          non_type_as_type_argument ×2 / undefined_super_member ×2 /
          override_on_non_overriding_member ×2（均为 CacheManager/Config/File/FileResponse
          无法解析的级联噪音）
项目自有类错误：0 → 合格
```

### F3 `lib/core/utils/toast.dart`（139 行，完整读）

### lib/core/utils/toast.dart:17-24 / 26-28 去重发生在 Overlay 查找之前，无 Overlay 时消息被记为「已展示」，真实提示永久丢失
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 18 条（异步/跨上下文结果须校验有效性）
- 依据：`show()` 先 `_lastShown[msg] = now` 记账（:22），再 `context.findRootAncestorStateOfType<OverlayState>()`，取不到就直接 `return`（:27-28）；返回前既不回滚 `_lastShown` 也不记日志。而 `_dedupeWindow = 3s`（:11），`_lastShown` 是进程级静态 Map（:17）。异步操作完成后常见序列是：请求 A 失败 → Toast.show 成功展示；3 秒内页面被 pop，`await` 后的请求 B 用已卸载 context 调 `Toast.show`（此时找不到 Overlay 或 context 已失效）→ 静默 return 且写入时间戳；紧接着用户重新进入页面、同一错误在 3 秒内再次发生 → :20-21 的 `_lastShown` 命中，`return` 不展示。
- 影响：失败/操作反馈在「转场瞬间 + 3 秒内复现」这一常见序列中完全不可见，用户既看不到错误也看不到重试提示；与 `copy()`（:46-50）显式检查 `context.mounted` 的处理口径不一致。
- 证据等级：静态推演（Overlay 缺失的具体时机未实测）

### lib/core/utils/toast.dart:35-42 / 59-65 `_current` 与 `_dismissTimer` 绑定到「创建时的根 Overlay」，页面重建/多 Navigator 时旧 OverlayEntry 无人移除
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（生命周期双向对称）
- 依据：`overlay.insert(entry)`（:40）把 entry 插入的是调用处的 `OverlayState`，但 `_current` 是静态字段（:18），`_hide()`（:60-65）只对 `_current` 调 `remove()`，没有保存 entry 所属的 OverlayState，也没有在 `OverlayState.dispose` 时清理的钩子。若两次 `show()` 分别来自不同根 Overlay（例如全屏 `/player` 页自带 Overlay、或路由重建后新的 Navigator Overlay），:34-36 的「清掉当前显示的」会调用旧 entry 的 `remove()`，而旧 Overlay 已不存在/已 dispose；同时 `_dismissTimer` 只有一个（:19、:41），旧计时器被无条件 `cancel()`，旧 entry 再无第二个移除时机。类注释 :8「同一时刻最多显示 1 条」在此路径不成立。
- 影响：全屏播放器/对话框切换期间可能出现两条提示叠加，或一条提示常驻不退（直到下一次 Toast.show 才被清），遮挡底部导航与迷你播放器。
- 证据等级：静态推演（多 Overlay 的具体路由结构未在本范围完整核对）

### lib/core/utils/toast.dart:24-28 / 46-50 `_lastShown` 以整个 `msg` 字符串作键，动态错误信息绕开去重，且长文本无截断
- 级别：P3
- 违反：QUALITY_STANDARD 第 25 条（资源必须有上限）
- 依据：去重键是原始 `msg`（:20、:22）；`_ToastView` 的 `Text(widget.msg)`（:115）无 `maxLines`/`overflow`。Map 上限只在 `length > 64` 时按时间清理（:24-27），单条 msg 的长度没有上限。上游 `friendly_error` 等处若把 URL/异常 toString 拼入提示文本，每次文本都不同 → 3 秒窗口形同虚设，且长文本会在 `bottom: media.padding.bottom + 96`（:98）的固定位置撑成多行胶囊。
- 影响：并发失败时连续弹多条不同文字的提示、互相顶掉；长错误串撑破屏幕底部布局。属轻微体验问题，定 P3。
- 证据等级：静态推演

### 复核通过（F3）
- :45-50 `copy()` 对空文本早退、await 后用 `context.mounted` 再展示，异步后校验了上下文有效性（第 18/20 条）。
- :85-96 `_ToastViewState` 的 `_exitTimer` 与 `AnimationController` 在 `dispose()` 成对取消/释放（第 20 条）。
- :107-116 提示文案取 `theme.colorScheme.inverseSurface/onInverseSurface`，深浅色主题下对比度随系统主题切换，无硬编码颜色。

#### F3 `dart analyze lib/core/utils/toast.dart`
```
43 issues found（39 error + 4 warning）
噪音归类：uri_does_not_exist ×2（package:flutter/material.dart、package:flutter/services.dart）
          undefined_method ×13 / undefined_identifier ×10 / undefined_class ×7 /
          override_on_non_overriding_member ×4 / undefined_super_member ×2 /
          non_type_as_type_argument ×1 / mixin_with_non_class_superclass ×1 /
          mixin_of_non_class ×1 / extends_non_class ×1 / creation_with_non_type ×1
          （全部源于 Flutter 包缺失：StatefulWidget/State/AnimationController/Positioned/
          OverlayEntry/Clipboard/Colors/Curves 等无法解析；`context.l10n` 亦因此不可解析）
项目自有类错误：0（l10n/l10n.dart 相对 import 路径存在）→ 合格
```

### F4 `lib/core/utils/error_logger.dart`（486 行，完整读 1-486）

### lib/core/utils/error_logger.dart:43-66 `setVerbose(false)` 不再恢复 `debugPrint`，且包装体不检查 `verboseMode`，关闭 verbose 后仍全量落盘
- 级别：P1
- 违反：QUALITY_STANDARD 第 30/31 条（命名/注释与行为一致）、第 25 条（资源上限与开关语义）
- 依据：`setVerbose` 中 `if (on && !_debugPrintHookInstalled)` 才安装包装；包装体（:47-59）唯一的短路条件是 `_inDebugPrintHook || message == null || message.isEmpty`，**没有 `verboseMode` 判断**，随即无条件 `instance._enqueueVerbose('debugPrint: $message')`。:63-65 的注释明确写「关闭时保留包装（包装体内部以 verboseMode 判断是否落盘）」，但包装体内不存在该判断；`_debugPrintHookInstalled` 一经置 true 也永不清 false，`original` 指针永不恢复。统计核对：`main.dart:265` 每次 `ref.watch(verboseLoggingProvider)` 变化都调用 `setVerbose`，即用户在设置页关闭详细日志后该包装仍在。
- 影响：用户把「详细日志」开关关掉后，App 仍把每一次 `debugPrint`（网络、播放、缓存等所有走 debugPrint 的信息）写进 `verbose.log` 并轮转 2MB×5 份；存储空间持续被写入、诊断页仍显示 verbose 条目，开关对用户完全失效，且用户无从得知自己关闭失败。属「设置项静默无效」的长时间静默错误。
- 证据等级：实锤（本文件内开关与包装体互斥条件可直接静态确证；`_enqueueVerbose` :80-86 自身只有 `_recent` 记账 + `unawaited(_enqueue(...))`，不再检查 verboseMode）

### lib/core/utils/error_logger.dart:47-59 / 80-86 / 103-149 verbose 包装把「原 debugPrint 输出」也重新入队，日志量随自身输出放大
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（资源必须有上限）、第 24 条（不得在热路径重复计算/无谓 IO）
- 依据：包装体内 `_inDebugPrintHook = true;` 保护的是「落盘动作内部再触发 debugPrint」，但 :58 `original(message, wrapWidth: wrapWidth)` 是在 `finally { _inDebugPrintHook = false; }`（:54-56）之后调用的，此时守卫已复位；`original` 若最终仍指向别的包装链，或 :134/:147/:291 等处 `debugPrint('[ErrorLogger] ...')` 在写入失败时产生的新消息，都会被再次当作新的 debugPrint 事件入队一条 `[verbose]`。每条 verbose 落盘都是一次 `resolveRoot()`（:106，含探测写根目录）+ 一次文件轮转检查 + 一次 flush 写盘（:110-112），全部串在同一条 `_writeQueue` 上，与 `log()`（:240-252）共用。
- 影响：打开详细日志后浏览首页/播放时，日志写盘队列被 verbose 条目占满，用户主动触发的「记录错误」与设置页「查看日志目录」排在长队后面，诊断页迟迟不刷新；同时外部存储的写放大与耗电明显。verbose 关闭失效（上一条）会让此影响在整个会话持续。
- 证据等级：静态推演（写入放大倍数取决于上游 debugPrint 频率，未实测）

### lib/core/utils/error_logger.dart:451-466 `currentDirPath()` 的「（日志仅进程内）」哨兵与 verbose 写入路径脱节
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 9 条（失败可观测）
- 依据：`_everPersisted`（:186）只在 `log()` 的成功分支写入（:228、:246）；`_writeVerbose()` 的三条成功路径（:113、:127、:141）只分别设置 `_publicDirPath` / `_fallbackWrittenPath`，**从不设置 `_everPersisted`**。而 `currentDirPath()` 先看 `_publicDirPath`，再看 `_fallbackWrittenPath`，只有两者都为空时才用 `!_everPersisted` 返回哨兵（:456-465）。`settings_page.dart:94` 与 :854/:864 都调用该方法向用户展示日志位置。
- 影响：用户打开详细日志、日志实际已成功写到 `logs/verbose.log` 且 `_publicDirPath` 已赋值时，诊断页显示的是真实路径——此路径下只有 verbose 文件；但从未调用过 `log()` 时 `_everPersisted=false` 并不影响它。反过来，若 verbose 的三条路径都失败（例如 `apiLevel < 29` 且公共直写与私有目录都不可写），`_everPersisted` 仍为 false，用户看到「（日志仅进程内）」，而真实失败原因（三个分支的 `catch (_) {}` 空体，:115、:132）既无日志也无 Toast。用户在设置页「导出/分享日志」时得到的是一个与事实不符的静态提示，无法自行定位。
- 证据等级：实锤（字段写入点可逐一静态确证）

### lib/core/utils/error_logger.dart:103-115 / 121-133 `_writeVerbose` 前两级失败完全静默，`catch (_) {}` 空体
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：公共根直写分支 :114-116 是 `catch (_) { // 直写失败（权限中途被收回等）→ 走 MediaStore }`，无任何日志/计数；MediaStore 分支 :129-132 是 `catch (_) {}`，同样空体；仅第三级私有目录失败才 `debugPrint('[ErrorLogger] verbose write failed: $e')`（:145）。对照同文件 `_appendPublic`/`_rewriteMediaStore`/`_hasStoragePermission`（:286-288、:329-332、:343-346）都会 `debugPrint` 留痕。
- 影响：用户开启详细日志后，日志被静默写到 App 私有目录（文件管理器里看不到），设置页虽显示私有路径但用户按注释 :8-9 的预期去「公共 Downloads/Documents」找文件会找不到；权限中途被收回这一具体原因在日志中毫无记录，客服/用户无法区分「没开开关」「写了但找不到」「完全没写」。
- 证据等级：实锤

### lib/core/utils/error_logger.dart:47-59 / 43-45 反复 `setVerbose(true)` 与 `verboseMode` 外部直改会让包装链叠加/失配
- 级别：P3
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门必须归属同一所有者）
- 依据：`verboseMode` 是 public static 可写字段（:26），`setVerbose` 的幂等条件 `if (verboseMode == on) return`（:44）依赖该字段；`_debugPrintHookInstalled` 是另一个独立布尔（:30）。若任一调用方直接写 `ErrorLogger.verboseMode = false`（字段公开），再调 `setVerbose(false)` 会因 `verboseMode == on` 直接 return，`_debugPrintHookInstalled` 与全局 `debugPrint` 指针状态再无同步点；`original` 闭包被保留但无从卸载。统计核对本范围外仅 `main.dart:265` 与 `kg_client.dart:172` 使用该字段，当前调用链未直接赋值。
- 影响：热重载或第三方代码改动开关后，全局 `debugPrint` 包装无法卸载，控制台输出与落盘行为不一致。当前已读调用链未触发，定 P3。
- 证据等级：静态推演

### 复核通过（F4）
- :250-269 `_enqueue` 用 `_writeQueue.then` + 链尾 `catchError` 兜底，任一事务抛错不破坏整条串行链，避免日志锁永久死锁（第 19/22 条）。
- :376-405 `_redact` 对 token/authorization/sign/cookie/dfid/t1/userid/mobile 四种键值形态 + 裸手机号 + Bearer/Basic 统一脱敏，且 `logApi`、`verbose`、`log` 三条入口都过 `_redact`（:197、:84、:222），公共目录日志不泄漏凭据（第 14 条）。
- :26-27 `verboseMaxBytes`/`verboseMaxBackups`、:21 `maxBytes`、:172-173 `_recent` 上限 200，均具名常量且轮转保留份数有上限（第 25 条）。
- :451-466 `currentDirPath()` 只返回「实际确认写入」的路径，不把计划路径当真实路径，且 :9/:20 注释明确「绝不因日志写入影响主流程」；`handleFlutterError`/`handleUncaught` 均 `unawaited`，不阻塞 UI。

#### F4 `dart analyze lib/core/utils/error_logger.dart`
```
20 issues found（20 error）
噪音归类：uri_does_not_exist ×3（package:flutter/foundation.dart、flutter/services.dart、path_provider）
          undefined_method ×12 / undefined_identifier ×2 / undefined_class ×2 /
          const_initialized_with_non_constant_value ×1（均源于上述三方包缺失：debugPrint、
          FlutterErrorDetails、MethodChannel、Directory? 等类型/符号级联不可解析）
项目自有类错误：0（../storage/storage_permission.dart 相对 import 存在）→ 合格
```

### F5 `lib/core/widgets/empty_state.dart`（68 行，完整读）

### lib/core/widgets/empty_state.dart:1-6 / 63-68 导入与尾部注释错位：文件尾是 `error_retry.dart` 的文档注释，且 3 个 import 完全未使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 31 条（注释解释「为什么」）
- 依据：`import 'dart:async';`、`import '../utils/toast.dart';`、`import '../../l10n/l10n.dart';`（:1-6）在本文件 68 行内无任何符号引用（`EmptyState` 只用 `IconData`/`Theme`/`LayoutBuilder`，全部来自 material.dart）。文件尾 :63-68 的注释「统一错误重试 / 绝不把原始异常……折叠在『技术详情』里」描述的是 `error_retry.dart`，而不是本文件的 `EmptyState`。对照 `list_skeleton.dart` 尾部 :44-46 的注释「统一空态（图标 + 文案 + 可选按钮）」恰好描述 `empty_state.dart`——两个文件的尾部注释互换了位置。
- 影响：维护者按注释在 `empty_state.dart` 找错误重试逻辑会扑空，改空态组件时容易误删/误改；用户不可见，定 P3。
- 证据等级：实锤

### lib/core/widgets/empty_state.dart:44-50 / 14-19 空态按钮文案由调用方传入，组件自身无 l10n 兜底，且 `actionLabel` 与 `onAction` 必须同时非空才渲染
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失语义分离）、第 9 条（失败可观测）
- 依据：`if (actionLabel != null && onAction != null)`（:44）是「与」条件；`FilledButton.tonalIcon` 的 `label: Text(actionLabel!)`（:49）直接渲染调用方字符串，本文件没有 `context.l10n` 兜底（虽然 import 了 l10n 却未用）。组件无 `icon`/`message` 的语义提示（例如「请求失败」与「确实为空」共用同一 `IconData` 参数），全部依赖调用方区分。
- 影响：调用方只给了操作回调忘了给文案（或只给文案忘了回调）时，空态/失败态既无说明外的动作也无重试入口，用户卡在空页面无法脱出；调用方传入硬编码中文时该处不走 l10n。属边界态一致性问题，当前 8 个 SongTile 调用方是否全部正确配对未在本代理通读范围，定 P3。
- 证据等级：静态推演

### 复核通过（F5）
- :25-31 `LayoutBuilder` 按 `constraints.maxHeight.isFinite` 分支：全屏占位用 `Center`、放进无界高度 ListView 时直接返回 content，避免无限高度断言（第 14 条：对外部布局约束做校验）。
- :33-42 图标与文案取 `theme.colorScheme.onSurfaceVariant`，深浅主题一致，无硬编码颜色。

#### F5 `dart analyze lib/core/widgets/empty_state.dart`
```
24 issues found（23 error + 1 warning）
噪音归类：uri_does_not_exist ×1（package:flutter/material.dart）
          undefined_method ×7 / undefined_identifier ×6 / undefined_class ×4 /
          creation_with_non_type ×3 / extends_non_class ×1 /
          super_formal_parameter_without_associated_named ×1 /
          override_on_non_overriding_member ×1（Flutter 缺失的级联噪音）
项目自有类错误：0（3 个 lib/ 相对 import 路径均存在）→ 合格
补充：本文件 3 个未使用 import 因 Flutter 包缺失未被 analyzer 报出（级联噪音覆盖），
      已由完整阅读确证，见 F5 第 1 条（第 32 条）。
```

### F6 `lib/core/widgets/list_skeleton.dart`（46 行，完整读）

### lib/core/widgets/list_skeleton.dart:1-6 / 44-46 3 个 import 完全未使用，尾部注释描述的是 `empty_state.dart`
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 31 条
- 依据：`import 'dart:async';`、`import '../utils/toast.dart';`、`import '../../l10n/l10n.dart';`（:2-6）在 46 行内零引用；只有 `shimmer.dart`（:1）与 material.dart（:3）被使用。文件尾 :44-46 的「统一空态（图标 + 文案 + 可选按钮）」描述 `EmptyState`，与本文件 `ListSkeleton` 无关（与 F5 的错位注释互换）。
- 影响：维护者按注释找空态组件会走错文件；用户不可见，定 P3。
- 证据等级：实锤

### lib/core/widgets/list_skeleton.dart:18-22 / 12-13 骨架屏用 `ListView.builder` 但无 `physics`/`shrinkWrap` 参数，嵌套在下拉刷新列表中会吃掉滚动手势
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（跨层契约：组件应声明自己适用的布局约束）、第 14 条
- 依据：`ListView.builder(itemCount: itemCount, ...)`（:18-20）默认 `physics` 为平台滚动物理、`shrinkWrap: false`，需要有限高度约束；本组件不接收任何布局参数（构造函数只有 `itemCount`，:13），也不像 `EmptyState` 那样用 `LayoutBuilder` 判约束。统计核对：加载态骨架在首页/搜索/榜单等列表页使用，这些页面通常外层还有 `RefreshIndicator`/`NestedScrollView`。
- 影响：把骨架放进无界高度或嵌套滚动容器时，用户下拉刷新手势被内层 ListView 抢走（或触发无限高度断言），首屏加载阶段出现「下拉没反应/白屏」；把加载态从「可交互」变成「卡住」。
- 证据等级：静态推演（具体页面是否嵌套未在本代理通读范围逐一核对）

### lib/core/widgets/list_skeleton.dart:12-13 `itemCount` 无上界、无最小值校验，调用方可传负数/超大值
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（边界校验）、第 25 条（资源上限）
- 依据：`final int itemCount;` 直接进 `ListView.builder(itemCount: itemCount)`（:19），构造时既无 `assert` 也无 clamp；默认 6。虽然 `builder` 是惰性的（第 24 条已满足），但 `itemCount` 完全由调用方控制。
- 影响：传入负数时 Flutter 抛断言、加载态直接崩溃；传入极大值时骨架项虽惰性构建但滚动条比例异常。属边界防御缺失，定 P3。
- 证据等级：静态推演

### 复核通过（F6）
- :16-39 `ListView.builder` 惰性构建（第 24 条），骨架行用 `SkeletonBox`/`SkeletonText` 且颜色取 `theme.colorScheme.surface`/`surfaceContainerHighest`，主题一致。
- :15-17 `Shimmer` 由父层统一驱动，单个骨架项不各自创建动画控制器（第 20/26 条）。

#### F6 `dart analyze lib/core/widgets/list_skeleton.dart`
```
16 issues found（15 error + 1 warning）
噪音归类：uri_does_not_exist ×1（package:flutter/material.dart）
          undefined_method ×4 / undefined_identifier ×4 / undefined_class ×2 /
          creation_with_non_type ×2 / extends_non_class ×1 /
          super_formal_parameter_without_associated_named ×1 /
          override_on_non_overriding_member ×1（Flutter 缺失级联噪音）
项目自有类错误：0（shimmer.dart / toast.dart / l10n.dart 相对 import 均存在）→ 合格
```

### F7 `lib/core/widgets/song_tile.dart`（221 行，完整读）

### lib/core/widgets/song_tile.dart:85-102 封面加载失败与「无封面」共用同一占位，`errorWidget` 不区分网络失败，用户无法看到加载/失败三态中的失败态
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失必须语义分离）、第 9 条（失败可观测）
- 依据：`placeholder: (_, __) => _placeholder(theme)` 与 `errorWidget: (_, __, ___) => _placeholder(theme)`（:99-100）指向**同一个** `_placeholder`（:185-195，一个音符图标）；`cover == null || cover!.isEmpty` 分支（:92）也返回同一个 `_placeholder`。三条完全不同的事实（加载中 / 图片 URL 404 或网络断开 / 该歌曲本来就没有封面）在 UI 上不可区分，且 `errorWidget` 未记录任何日志。
- 影响：网络异常时整屏歌曲列表看起来「都没有封面」，用户误以为数据源无封面而不会去检查网络或重试；加载慢时也没有任何进度反馈。与 B4 范围其它组件（如 `error_retry.dart` 的「技术详情」折叠错误）的三态口径不一致。
- 证据等级：实锤

### lib/core/widgets/song_tile.dart:131-161 `PopupMenuButton` 与 `onMenuSelected` 无配对校验，给了菜单但漏回调时菜单项点击后完全无反馈
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：回调可选却无失败语义）、第 9 条
- 依据：`_hasMenu` 只判断 `menuItems != null && menuItems!.isNotEmpty`（:78）；`onSelected: (v) => onMenuSelected?.call(v)`（:137）在 `onMenuSelected == null` 时静默丢弃选择。构造函数把 `menuItems` 与 `onMenuSelected` 都声明为可选（:63-67），无 assert、无 disabled 态、无日志。统计核对：全库 8 个 `SongTile(` 使用文件中，4 个文件出现 `menuItems:` 字面量，另 4 个（artist/album/rank_detail/library 之一）计数为 0，具体配对情况未逐一通读（本代理只抽查，不越界）。
- 影响：用户点「更多」→ 选「收藏/删除/添加到歌单」→ 弹窗关闭、界面毫无变化，也没有 Toast/日志；对「删除」这类写操作用户会反复点，可能产生重复提交疑虑（第 21 条）。属于「进入→操作→反馈」链路的操作后反馈断点。
- 证据等级：静态推演（具体调用方配对不全在通读范围）

### lib/core/widgets/song_tile.dart:215-217 `_fmt` 对时长 ≥60 分钟不做小时归一，且未处理负数或超大值
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）、第 17 条（数值精度）
- 依据：`duration` 注释为「秒」（:48/:57），`_fmt` 实现 `'${(sec ~/ 60)...}:${(sec % 60)...}'`（:216-217）：60 分钟显示为 `60:00`，超过 1 小时也不转 `h:mm:ss`；分钟用 `padLeft(1,'0')` 不补零（对比秒 `padLeft(2,'0')`），出现 `0:05` 与 `5:05` 宽度不一致。`sec` 为负时 `~/` 与 `%` 产生 `-1:59` 之类的非法显示。
- 影响：播客/长音频/MV 伴生条目在列表里显示 `60:00`、`125:00` 等非常规时长；单位仍是秒却没有在命名/类型上体现（只有一个行尾注释）。轻微体验问题，定 P3。
- 证据等级：静态推演

### lib/core/widgets/song_tile.dart:7-16 / 1-5 `export` 五个组件 + 3 个未使用 import，单一职责被破坏
- 级别：P3
- 违反：QUALITY_STANDARD 第 1 条（单一职责）、第 32 条（死代码）
- 依据：`song_tile.dart` 在 :7-11 `export 'section_header.dart'; 'gradient_chip.dart'; 'list_skeleton.dart'; 'empty_state.dart'; 'error_retry.dart';`——一个「歌曲列表项」文件同时充当 6 个组件的门面；`import 'dart:async';`（:2）、`import '../utils/toast.dart';`（:13）、`import '../../l10n/l10n.dart';`（:15）中 l10n 实际被 `context.l10n.moreActions/download` 使用（:136、:173），另两个在 221 行内零引用。`import 'empty_state.dart';` 与 `import 'error_retry.dart';`（:6-7）也无本文件内引用，仅为了配合 export。
- 影响：任何页面只想用 `EmptyState` 都必须连带编译 `SongTile` 及其 `cached_network_image` 依赖，改动任一被 export 的组件都会让所有使用方重新分析；维护时难以判断「统一组件」的权威入口在哪（与 `empty_state.dart`/`list_skeleton.dart` 尾部错位注释叠加）。用户不可见，定 P3。
- 证据等级：实锤

### 复核通过（F7）
- :88-90 全部封面走 `cacheManager: AppImageCache.instance` + `memCacheWidth` 按设备像素比计算，与 `app_image_cache.dart` 的全局单例契约一致，且不会按原图解码（第 23/25 条）。
- :165-177 单一高频下载按钮显式 `BoxConstraints(minWidth: 48, minHeight: 48)` 补足触控目标，并用 `context.l10n.download` 作 tooltip（可达性 + i18n）。
- :131-161 多操作统一收进 `PopupMenuButton`，`isDestructive` 项用 `theme.colorScheme.error` 强调，危险操作有一致视觉口径。
- :78 标题/副标题 `maxLines: 1` + `TextOverflow.ellipsis`，`isPlaying` 用 primary 色与半粗体，当前播放项在列表中可辨识。

#### F7 `dart analyze lib/core/widgets/song_tile.dart`
```
55 issues found（54 error + 1 warning）
噪音归类：uri_does_not_exist ×2（package:cached_network_image/...、package:flutter/material.dart）
          undefined_method ×18 / undefined_identifier ×15 / undefined_class ×12 /
          creation_with_non_type ×5 / extends_non_class ×1 /
          super_formal_parameter_without_associated_named ×1 /
          override_on_non_overriding_member ×1（三方包缺失级联噪音）
项目自有类错误：0（app_image_cache.dart / gradient_chip.dart / empty_state.dart /
          error_retry.dart / section_header.dart / list_skeleton.dart / toast.dart /
          l10n.dart 相对 import 路径均存在）→ 合格
```

### F8 `lib/features/home/data/home_repository.dart`（198 行，完整读）

### lib/features/home/data/home_repository.dart:157-188 五个区块全部失败时被折叠成一个通用异常，用户看不到「哪个区块失败/可重试」，且失败文案硬编码中文
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条（空集合与失败语义分离）、i18n 一致性
- 依据：`songsF/plF/rankF/bannerF/dailyF`（:159-175）每个都用 `catch (_) { return const []; }` 或 `return null` 把异常吞成空集合；`Future.wait` 后（:177-179）只判断 `songs/playlists/ranks/banners` 全空就 `throw Exception('首页数据加载失败，请检查网络后重试')`（:184-186），字符串为中文硬编码。统计核对：`home_page.dart:27-43` 用 `homeAsync` 的 error 态 + `onRetry` / `ref.refresh`，:71 的空态 `onAction` 也是 `ref.invalidate`；`main.dart:212` 还监听该 provider。
- 影响：用户断网打开首页时看到的是一条不区分原因的中文提示；若四个接口恰好返回「合法但空」的列表（限流、地区榜单为空、未登录），同样抛同一条「请检查网络」——用户按提示反复检查网络/重试也不会恢复。部分区块成功时（例如只有新歌成功）其余空区块会以空白占位出现，用户无法区分「加载中/确实没有/加载失败」，三态完全混同。与 `router.dart` 已全部走 `context.l10n` 的口径不一致（英文/其它语言用户看到中文）。
- 证据等级：实锤（异常与文案可直接静态确证；具体接口返回形态未实测）

### lib/features/home/data/home_repository.dart:58-68 `fetchTopPlaylists` 的 `catch (_)` 空体回落，降级无留痕、无触发/退出条件
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 11 条（降级须有触发与退出条件）、第 9 条
- 依据：`try { ... _cachedGet('/top/playlist', ...) ... } catch (_) { // 回落 yueku 歌单 }`（:59-67）注释只有一行，既不 debugPrint 也不记日志，更不区分异常类型；`raw.isNotEmpty` 为 false 时**不抛异常**也直接落到 `fetchYuekuPlaylists()`（:68），即「主路径业务返回空」与「主路径抛异常」共用同一降级；降级结果还会经 `_cachedGet` 写进缓存，下一次请求只要主路径再失败就继续用旧数据，没有「何时退出降级」的判定。对照同文件 `fetchBanners`（:103-105）、`fetchDailyRecommend`（:128-131）、`fetchNewSongs`（:147-150）三处回落都有 `debugPrint` 留痕并写明原因，唯独此路径没有。
- 影响：推荐歌单长期静默变成乐库歌单，用户看到的「推荐」内容悄悄改变却没有任何提示；线上无法从日志区分「/top/playlist 挂了」和「返回空」，客服无法定位，也不知何时恢复。
- 证据等级：实锤

### lib/features/home/data/home_repository.dart:1 / 3 `package:flutter/foundation.dart` 重复 import 两次
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）
- 依据：:1 与 :3 是逐字相同的两行 `import 'package:flutter/foundation.dart';`，中间夹着 `import '../../../core/net/music_api.dart';`（:2）。`music_api.dart` 这个 import 在 198 行内也未被任何符号使用（本文件只用 `KugouApiClient`、`CachedApiCall`、`kListTtl`、`kugouApiClientProvider`、`Provider`、`debugPrint`）。
- 影响：无用户可见后果；属整洁度与 import 一致性问题，定 P3。
- 证据等级：实锤

### lib/features/home/data/home_repository.dart:159-175 五个 `.timeout(12s)` 各自计时但 `Future.wait` 不校验世代，登录态切换后旧首页数据仍可写回
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`fetchHomeData()` 内 5 个 Future 各自 `.timeout(t)`，聚合用 `Future.wait<dynamic>`（:177-179）等待全部完成（最坏 12s）；返回的 `HomeData` 不含任何请求世代/用户标识。`main.dart:287` 在登录态变化时 `ref.invalidate(homeDataProvider)`，但本方法没有 `cancel`/`generation` 参数，被 invalidate 的旧 Future 仍会跑完并（经 `CachedApiCall`/`ResourceCache`）写缓存。`fetchDailyRecommend()`（:117）明确说明「登录态强相关，绝不能进 MemoryCache」，但聚合方法把它的结果与其它区块一起在旧世代里完成。
- 影响：用户登录/登出瞬间若旧首页请求仍在跑（最长 12 秒），新请求与旧请求的结果交错；每日推荐这一登录态强相关区块可能在登出后仍短暂显示、或登录后延迟不出现，用户看到与账号不符的推荐内容。
- 证据等级：静态推演（Riverpod invalidate 对未完成 Future 的具体行为未实测）

### 复核通过（F8）
- :103-105 / :128-131 / :147-150 三处回落都 `debugPrint` 写明端点与失败原因，符合「静默降级必须留痕」（第 9 条）。
- :117-120 每日推荐刻意绕开 `_cachedGet` 直接 `_api.get`，避免匿名态响应被缓存后登录仍不刷新（第 23 条：缓存键覆盖登录态维度）。
- :157-179 五个区块并发 + 单项 12s 超时 + `Future.wait`，任一失败不影响其它区块，首页不是「全有或全无」（第 11 条退化粒度合理）。

#### F8 `dart analyze lib/features/home/data/home_repository.dart`
```
8 issues found（8 error）
噪音归类：uri_does_not_exist ×3（package:flutter/foundation.dart 重复 ×2、flutter_riverpod）
          undefined_function ×2（Provider / FutureProvider）/ undefined_method ×3（debugPrint）
          均为三方包缺失级联噪音
项目自有类错误：0（core/net/music_api.dart、core/api/kugou_api_client.dart、
          core/resource/cached_api.dart、core/resource/resource_cache.dart、app/di.dart、
          models.dart 相对 import 均存在）→ 合格
补充：:1/:3 重复 import 与 :2 未使用 import 已由完整阅读确证（F8 第 3 条）。
```

### F9 `lib/features/lyric/data/krc_decoder.dart`（102 行，完整读）

### lib/features/lyric/data/krc_decoder.dart:97-101 兼容入口 `decode()` 把 4 类失败统一折叠成空串，仍可从任何调用方绕过结构化错误
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 32 条（死代码）、第 3 条（契约单一）
- 依据：`decodeDetailed()` 已定义 `KrcDecodeError{emptyInput, invalidBase64, notKrcContainer, corruptPayload}`（:11-16）与带 `error` 的 `KrcDecodeResult`（:18-28），但 :98-101 仍保留 `static String decode(...) => decodeDetailed(...).text;`，注释写「兼容旧调用点」；统计核对全库 `KrcDecoder` 调用点只有 `lyric_repository.dart:129` 一处且用的是 `decodeDetailed`，即"旧调用点"已不存在。文件头 :6-9 自述旧实现「统一返回 ''……损坏时被当成『无歌词』静默吞掉（第 9 条）」正是这个入口仍在提供的行为。
- 影响：后续任一新调用方误用 `decode()`（名字更短、更符合直觉）时，KRC 密文损坏会再次被当成「没有歌词」，歌词页静默空白且日志无任何线索；用户无法区分「这首歌没歌词」与「歌词解密失败」，与 `EmptyState` 的三态语义冲突。
- 证据等级：实锤

### lib/features/lyric/data/krc_decoder.dart:88-92 `utf8.decode(..., allowMalformed: true)` 把乱码静默替换成 U+FFFD，解密成功但歌词内容已损坏仍报 success
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败可观测）、第 13/14 条（外部数据边界校验）
- 依据：`_inflateUint8List` 只在 `text.trim().isEmpty` 时抛 `FormatException`（:90-92）；非法 UTF-8 字节因 `allowMalformed: true`（:89）被替换字符吸收，函数返回 `KrcDecodeResult.success(text)`（:68）。`decodeDetailed` 对解压后的内容不做任何 KRC 结构校验（不检查是否含 `[` 时间标签、不检查替换字符比例）。
- 影响：上游返回编码异常或 XOR key 错位但 zlib 恰巧解压出字节流时，用户看到整页歌词是「□□□/问号菱形」，而 UI 认为解密成功、不触发回落 LRC 明文、不记日志；用户既无正确歌词也无错误提示，且反复重试无改善。
- 证据等级：静态推演（上游返回是否会出现该形态未实测）

### lib/features/lyric/data/krc_decoder.dart:42-46 / 60-84 `base64.normalize` 对超长输入无上限，XOR + 两次 zlib 解压都在主线程同步执行
- 级别：P3
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 24 条（惰性/按需计算）
- 依据：`decodeDetailed` 接收任意 `String base64Content`，只判 `trim().isEmpty`（:42-44），随后 `base64.decode(base64.normalize(...))` 整串解码（:46）、`bytes.sublist(4)` 复制一份（:59）、`Uint8List(body.length)` 再分配一份（:62）、失败时 `_inflateUint8List` 最多再尝试一次带移位的完整拷贝（:72-77）。全过程无长度上限、无 isolate、无 `compute`。
- 影响：上游返回一个异常大的歌词字段时，切歌瞬间主线程同步做数次大内存拷贝与解压，歌词页/播放控制出现明显卡顿；极端情况下内存峰值翻倍。定 P3（正常歌词体量小，未实测卡顿）。
- 证据等级：静态推演

### 复核通过（F9）
- :41-57 四类失败（空串 / 非法 Base64 / 非 krc1 头 / 解压损坏）在入口逐一分支返回结构化 `KrcDecodeResult.failure`，不再统一返回 `''`（第 13/14/16 条）。
- :69-83 「krc1 头后还有 4 字节长度前缀」的形态只在首次解压失败时多试一次，不在成功路径增加开销，且失败仍落 `corruptPayload`（第 11 条：降级有明确触发与退出条件）。
- :36-39 固定 key 为具名常量 `_key`，避免魔法值散落（第 2 条）。

#### F9 `dart analyze lib/features/lyric/data/krc_decoder.dart`
```
2 issues found（2 error）
噪音归类：uri_does_not_exist ×1（package:archive/archive.dart）、creation_with_non_type ×1（ZLibDecoder）
项目自有类错误：0（仅 dart:convert / dart:typed_data / archive 三个 import）→ 合格
```

### F10 `lib/features/rank/data/rank_repository.dart`（133 行，完整读）

### lib/features/rank/data/rank_repository.dart:107-129 `fetchRankSongs` 把「响应形态异常/接口失败」静默解析成空列表，且 `total` 用 `songs.length` 兜底，榜单详情页会错误停止分页
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（请求失败与确实为空语义分离）、第 9 条（失败可观测）
- 依据：`_reads.post(...) as Map<String, dynamic>`（:112-116）之后，`data is Map ? ... : <String,dynamic>{}`（:117）、`map['songlist'] is List ? ... : const []`（:118）；响应体没有 `data`、没有 `songlist`、或 `songlist` 里所有条目 `hash` 都为空（:121 的 `.where((s) => s.hash.isNotEmpty)`）时，一律返回 `RankSongsPage(songs: [], total: ...)`；`total` 在解析失败时用 `songs.length`（:126-127）即 0。全过程无 throw、无日志、无错误标记。统计核对：`rank_detail_page.dart:41-42 / :63-64` 用该结果驱动 `_page` 与「加载更多」。
- 影响：用户点开排行榜，遇到上游返回结构变化、限流、需要登录等真实失败时看到的是「空榜单」而不是错误/重试提示；`total=0` 让分页逻辑认为已到末页，下拉「加载更多」不再触发，用户以为该榜单真的没有歌曲。失败态与空态混同，且刷新前不会自行恢复提示。
- 证据等级：静态推演（`RepositoryReads.post` 是否已把业务错误抛异常不在本代理通读范围；但「有响应、形态不符」这一分支在本文件内确定会静默成空）

### lib/features/rank/data/rank_repository.dart:112 `post` 用于读操作，且 body 为空 Map 与 `rankRepositoryProvider` 用 `ref.watch` 装配，榜单分页与账号切换的契约不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（请求方法契约）、第 32 条
- 依据：`_reads.post('/rank/audio', const <String, dynamic>{}, query: {...})`（:112）对只读的榜单歌曲查询使用 POST 且传空 body；`import '../../../core/api/kugou_api_client.dart';`（:3）与 `final KugouApiClient _api`（:105）在本文件只用于构造 `RepositoryReads`，`import '../../home/data/models.dart' show kugouImageUrl` 的 `show` 使用正确。`rankRepositoryProvider` 用 `ref.watch(kugouApiClientProvider)`（:132-133），而 `home_repository.dart:13` 用 `ref.read(...)`，同批两个仓库的装配口径不一致。
- 影响：用户切号时榜单仓库会随 provider 重建，首页仓库不会；同一账号切换操作在两个 Tab 上产生不同的刷新行为。属一致性/整洁度问题，定 P3。
- 证据等级：静态推演

### lib/features/rank/data/rank_repository.dart:77-89 时长只认 `duration_128/320/flac`，缺失时静默 `Duration.zero`，列表显示 `0:00`
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）、第 16 条
- 依据：`var ms = 0;`（:77）遍历三个键（:78-88），`v` 既非正 int 也非可解析的正数字符串时保持 0，最终 `duration: Duration(milliseconds: ms)`（:97）。文件头 :12 注释写明这三个字段单位是毫秒，但字段名本身不含单位，且代码无「字段缺失」与「时长确为 0」的区分。
- 影响：上游字段名变动或某音质无时长时，榜单里一批歌曲统一显示 `0:00`，用户误以为文件损坏而不敢点播；同时没有任何日志提示字段缺失。定 P3。
- 证据等级：静态推演

### 复核通过（F10）
- :50-53 对 `audio_info`/`album_info`/`trans_param`/`video_info` 四个嵌套对象逐一 `is Map` 分支校验后再 `Map.from`，未裸强转（第 13 条）。
- :55-59 歌手名优先 `author_name`，缺失时回落 `authors[].author_name` 且 `first is Map` 才取值（第 14 条）。
- :120-122 过滤 `hash.isEmpty` 的无效条目，避免用户点到无法播放的歌（第 14 条）。
- :65-68 封面统一走 `kugouImageUrl(..., size: 400)`，与首页/搜索的图片尺寸契约一致。

#### F10 `dart analyze lib/features/rank/data/rank_repository.dart`
```
3 issues found（2 error + 1 warning）
噪音归类：uri_does_not_exist ×1（package:flutter_riverpod/...）、undefined_function ×1（Provider）
          warning unnecessary_cast ×1（:112 `as Map<String, dynamic>`，非项目自有类错误）
项目自有类错误：0（core/net/repository_reads.dart、core/api/kugou_api_client.dart、
          app/di.dart、home/data/models.dart 相对 import 均存在）→ 合格
```

### F11 `lib/features/lyric/presentation/lyric_view.dart`（379 行，完整读）

### lib/features/lyric/presentation/lyric_view.dart:186-200 `lines.isEmpty` 用同一句 `lyricEmptyGuide` 覆盖「纯音乐 / 解密失败 / 加载中」三种事实
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失/失败语义分离）、第 9 条（失败可观测）
- 依据：`build()` 的唯一空态分支（:186-200）只渲染 `Text(context.l10n.lyricEmptyGuide)`，没有任何参数用于区分上游状态；`LyricView` 构造参数（:21-29）只有 `lyric/position/mode/onTapLine/lyricId/songHash`，没有 loading / error / retry 入口。对照 `krc_decoder.dart` 已把 KRC 失败细分为 4 类 `KrcDecodeError`，但本视图无从消费。注释 :186-188 自述旧实现「无法区分『纯音乐/解密失败/加载中』」，而当前实现只是把「一片空白」换成了一句引导文案，三种事实仍然共用同一 UI。
- 影响：网络失败/歌词解密损坏时用户看到「暂无歌词 + 引导」，会以为这首歌本来就没有歌词，不会去重试或检查网络；加载过程中也没有任何进度指示，切歌后长时间停在「暂无歌词」。用户路径「进入歌词页 → 等待 → 得到反馈」中的反馈是错的。
- 证据等级：实锤（构造参数与空态分支可直接静态确证）

### lib/features/lyric/presentation/lyric_view.dart:232-239 用户手动滚动的 `ScrollStartNotification` 判定带 `dragDetails != null`，程序化滚动也刷新暂停计时，且 `_lastUserScrollAt` 换歌后不重置
- 级别：P2
- 违反：QUALITY_STANDARD 第 30 条（命名与行为一致）、第 18 条（异步结果世代）
- 依据：`onNotification` 条件为 `n is ScrollStartNotification && n.dragDetails != null || n is UserScrollNotification`（:234-235），第二个分支对所有 `UserScrollNotification`（包括 `_scrollTo` 的 `animateTo` 触发的方向变化通知）都会 `_lastUserScrollAt = DateTime.now()`；`_scrollTo` 在 :216-217 用 300ms 动画，动画本身会产生滚动通知。而 :212 的 `paused` 判定用 `DateTime.now().difference(_lastUserScrollAt) < 5s`；`didUpdateWidget` 换歌词时（:142-149）只重置 `_currentIndex`/`_boundLyric`/`_boundSongHash`，**不重置 `_lastUserScrollAt`，也不重置 `_didInitialScroll`**。
- 影响：用户手动划一下歌词后 5 秒内切歌，新歌当前行的自动跟随仍处于「暂停」状态，且因 `_didInitialScroll` 已为 true 不再做首帧 `jumpTo`，用户看到的是上一首歌遗留的滚动位置、当前演唱行跑到屏幕外，需要再等 5 秒或手动回滚。这是「换歌 → 歌词跟随」这条高频路径的可见断点。
- 证据等级：静态推演（ScrollNotification 具体派发序列未实测）

### lib/features/lyric/presentation/lyric_view.dart:160-175 自动滚动用固定 64/76px 估算行高，长文本换行后偏差随行号线性累积
- 级别：P2
- 违反：QUALITY_STANDARD 第 17 条（数值与索引精度）、第 14 条
- 依据：`_estimateLineHeight` 只按「是否双语且有译文」在 `_itemExtentApprox = 64.0`（:58）与 `76`（:174-177）之间二选一；`_scrollTo` 用 `for (var i = 0; i < upper; i++) offset += _estimateLineHeight(lines[i])`（:165-168）线性累加。实际 `_LyricLineTile` 的 `Text` 没有 `maxLines`，长歌词行/超长译文在窄屏或大字体（系统无障碍字号放大）下会换成 2–3 行，实际行高远超 76；`ListView.builder` 未使用 `itemExtent`/`prototypeItem`，也没有真实布局测量。注释 :154-157 自述「偏差随行号线性累积」是旧实现的问题，但新实现仍用累加估算，只是把基线从「固定 64px」改成「按估算高度」。
- 影响：大字体模式或长译文歌曲，唱到后半段当前行逐渐偏出屏幕中心甚至跑出视口，用户看不到正在唱的字；`_scrollTo` 还把 target clamp 到 `maxScrollExtent`，末尾几行始终贴底无法居中。
- 证据等级：静态推演（未实测具体字号下的像素偏差）

### lib/features/lyric/presentation/lyric_view.dart:92-101 / 142-149 译文补丁订阅只在 `initState` 建立，`didUpdateWidget` 换歌词时不重绑，且 `songHash` 变化时 `_boundSongHash` 有条件不更新
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 23 条（匹配键覆盖全部维度）
- 依据：`_subscribePatches()` 只在 `initState`（:85-90）调用；`didUpdateWidget` 仅在 `oldWidget.lyric != widget.lyric` 时更新 `_boundLyric` 与 `_boundSongHash`（:144-148），订阅本身不重建。`_onTranslationPatch` 的歌曲代际校验是 `final wantHash = widget.songHash; if (wantHash != null && wantHash.isEmpty == false) {...}`（:105-109）——当 `songHash` 为 null 或空串时**跳过歌曲代际校验**，只靠 `lyricId` 比对（:110），而 `lyricId` 注释 :28-32 明确「为 null 时退化为只接受当前歌词代际内、下标范围合法」。注释 :47-50 又宣称「换歌后即使候选 id 恰好复用，旧歌词/旧译文也不得写入新歌视图」。
- 影响：全屏播放器/下载面板等未传 `songHash` 的调用方，切歌后如果新歌歌词对象复用了同一实例（或 `lyricId` 恰好相同），旧歌译文补丁会写进新歌的行里，用户看到与当前歌曲无关的译文；与 b3_c 已撤销的「跨歌串入」条目不同——那条针对 `lyric_view` 已实现的 hash 校验，本条是 hash 为 null/空时该校验被整体跳过的分支。
- 证据等级：静态推演（调用方是否传 songHash 未逐一通读；`full_player_page.dart` 在本批通读范围，见 F14 交叉核对）

### lib/features/lyric/presentation/lyric_view.dart:198-200 / 262-263 空态与行内文案未接入 `MediaQuery` 字号缩放限制，`fontSize: 12/16/17` 硬编码
- 级别：P3
- 违反：QUALITY_STANDARD 第 26 条（无障碍/一致性）
- 依据：`_LyricLineTile._buildOriginal` 用 `fontSize: isCurrent ? 17 : 16`（:351）、译文两处 `fontSize: 12`（:302、:315），都是硬编码逻辑像素；`theme.textTheme.titleMedium?.copyWith(...)` 的其它属性（字族/字重）保留但字号被覆盖，系统「大字体」无障碍设置对逐字歌词行无效。
- 影响：开启系统大字体/粗体的用户，歌词行仍以固定 12–17px 显示，与页面其它文字大小不一致，译文尤其难读。定 P3（可访问性缺陷）。
- 证据等级：静态推演

### 复核通过（F11）
- :103-135 `_onTranslationPatch` 有 `if (!mounted) return`、`_boundLyric == null` 早退、`songHash`/`lyricId` 双维度代际校验、`startIndex` 边界检查、「已有译文不覆盖」，且 `changed` 时才 `setState` 一次（第 18/20/24 条）。
- :137-140 `dispose()` 与 `initState` 的 `_patchSub` 订阅对称 `cancel()`，`_scroll.dispose()`（第 20 条）。
- :206-226 `build()` 不直接改状态，改用 `_pendingRebuild` + `addPostFrameCallback` 保证同一帧只排一次 `setState`（第 24 条：build 纯函数）。
- :364-373 `_findCurrentLine` 二分查找，不在每帧做线性扫描（第 26 条）。
- :198 空态文案走 `context.l10n.lyricEmptyGuide`，无硬编码中文。

#### F11 `dart analyze lib/features/lyric/presentation/lyric_view.dart`
```
85 issues found（84 error + 1 warning）
噪音归类：uri_does_not_exist ×1（package:flutter/material.dart）
          undefined_identifier ×35 / undefined_method ×17 / undefined_class ×11 /
          override_on_non_overriding_member ×6 / undefined_super_member ×3 /
          extends_non_class ×3 / type_test_with_undefined_name ×2 /
          super_formal_parameter_without_associated_named ×2 /
          non_type_as_type_argument ×2 / creation_with_non_type ×2
          （全部为 Flutter 缺失的级联噪音）
          warning unused_element_parameter ×1（:282 `_LyricLineTile.key` 从未传值，非自有类错误）
项目自有类错误：0（l10n/l10n.dart、core/resource/lyric_translation_stream.dart、
          core/theme/settings_provider.dart、../data/krc_parser.dart 均存在）→ 合格
```

### F12 `lib/features/mv/mv_provider.dart`（34 行，完整读）

### lib/features/mv/mv_provider.dart:27-33 `mvDetailProvider` 空 catch 把「MV 详情请求失败」折叠成 null，与注释「隐藏清晰度按钮」以外的失败不可区分
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 16 条
- 依据：`try { return await ref.watch(mvRepoProvider).fetchDetail(hash); } catch (_) { return null; }`（:29-33），异常对象被丢弃、无 debugPrint、无 ErrorLogger、无错误态；返回类型 `MvDetail?` 用 null 同时表示「该 MV 没有清晰度列表」与「请求失败/超时/解析异常」。统计核对：`mv_player_page.dart:280` 用 `ref.watch(mvDetailProvider(...))` 决定是否渲染清晰度入口。
- 影响：网络波动时用户打开 MV 播放页，清晰度选择按钮直接消失，既没有「加载中」也没有「重试」；用户会以为该 MV 只有一种清晰度，反复退出重进也不会得到错误提示，无法判断是网络问题还是内容本身。
- 证据等级：实锤

### lib/features/mv/mv_provider.dart:11-16 / 19-25 `mvExistsProvider` 与 `songMvProvider` 对同一 `albumAudioId` 各发一次 `findBySong`，无异常折叠口径不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 8 条（异常契约单一且稳定）
- 依据：两个 `FutureProvider.family.autoDispose` 分别对同一个 `albumAudioId` 调 `findBySong`（:14、:22），一个返回 `bool`（`list.isNotEmpty`），一个返回 `MvInfo?`（`list.first`），两者都没有 try/catch——异常直接以 FutureProvider 的 error 态向外传播；而同文件 :27-33 的 `mvDetailProvider` 却把异常吞成 null。三个 provider 对「同一仓库调用失败」给出三种不同形态（error / error / null）。统计核对：`full_player_page.dart:436`、`download_sheet.dart:37` 消费 `songMvProvider`；`mvExistsProvider` 在全库除本文件定义外无任何消费点（第 32 条嫌疑，见下条）。
- 影响：同一首歌在播放器与下载面板上，「MV 是否存在」这一事实需要两次独立网络请求且可能得到不同结果；某个页面展示 MV 入口而另一个不展示，用户看到不一致；失败时一个页面报错、另一个静默隐藏按钮，反馈口径混乱。
- 证据等级：静态推演（`findBySong` 内部是否有缓存合并不在本代理通读范围）

### lib/features/mv/mv_provider.dart:11-16 `mvExistsProvider` 全库零消费点
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）
- 依据：统计核对全库 `mvExistsProvider` 仅在本文件 :11 定义、:11-16 实现体内无自引用；`songMvProvider` 已在 :19-25 提供同一 `findBySong(...).isNotEmpty` 的等价信息且被两个页面消费。
- 影响：无用户可见后果；多一个可被误用的 state 入口，定 P3。
- 证据等级：实锤

### 复核通过（F12）
- :7-8 `mvRepoProvider` 用 `ref.watch(kugouApiClientProvider)` 装配（DI 注入，不 new 裸 client），播放页与全屏播放器共享同一仓库实例（第 2/5 条）。
- :11 / :19 / :27 三个 family 均 `autoDispose`，离开页面后释放缓存态，避免切歌累积（第 20/25 条）。
- :12-13 / :20-21 `albumAudioId.isEmpty` 早退，不发无意义的空 ID 请求（第 14 条）。

#### F12 `dart analyze lib/features/mv/mv_provider.dart`
```
5 issues found（5 error）
噪音归类：uri_does_not_exist ×1（package:flutter_riverpod/...）、undefined_function ×1（Provider）、
          undefined_identifier ×3（FutureProvider）
项目自有类错误：0（app/di.dart、data/mv_repository.dart 相对 import 均存在）→ 合格
```

