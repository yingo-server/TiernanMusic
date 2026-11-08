# v5.1 交叉审查 B4 · 视角 B（鲁棒与代码质量）

- 任务书：`docs/TASK_v51_B4_b.md`（第 4 批，视角 B）；通用规范 `docs/TASK_v51_cross_common.md`；判据 `docs/QUALITY_STANDARD.md`（33 条，冲突时优先）；`docs/REVIEW_SPEC.md` 为补充。
- 范围：43 个 .dart 文件 / 9550 行（按任务书清单）。本代理**通读**标注 ✅ 的 14 个文件；其余 29 个文件仅做「跨文件契约抽查」（≤8 个，读定义签名与调用点），不逐行审。
- 视角：异常契约、资源申请/释放对称、并发与世代、边界值、缓存维度、死代码（重点第 1/6/9/11/14/18/19/20/21/23/25/28/29 条）。
- 工作方式：逐文件 `file_read` 从头读到尾 → **读完一个文件立即 append**；只读源码，未改任何代码文件；未装 SDK / 未 pub get / 未构建 / 未跑测试 / 未起服务。
- 证据等级：除特别标注外均为「静态推演」（无真机/无实测环境）；不把推测写成实测。
- 去重复：已读 `docs/v51_cross_b1_merged.md`、`b2_merged.md`、`b3_merged.md` 与 `b3_b.md`、`b3_c.md` 的**问题清单索引**，仅用于避免重复报告；未据此改代码、未照抄其结论。
- 逐文件 `dart analyze` 结果在文末统一贴（每文件单独执行）；Flutter/三方包符号缺失为预期噪音，项目自有类 0 错误为通过。

---

## 逐文件审查（实时 append）

### 1/14 `lib/app/di.dart`（40 行，✅通读）

#### 问题

### lib/app/di.dart:30-39 在 Provider 创建回调里做全局静态副作用注册
- 级别：P2
- 违反：QUALITY_STANDARD 第 2 条（显式优于隐式：副作用必须在签名或名称上体现）
- 依据：`musicApiProvider` 的 create 回调除返回 `MusicApi` 外，还执行 `MusicApi.attachInvalidator(ResourceGateway.instance.invalidateNs)` 与 `QualityDiagnostics.onUnknownValue ??= ...` 两次**进程级静态状态写入**；Provider 是惰性创建，注册时机完全取决于「谁先读这个 Provider」，签名与命名（`Provider<MusicApi>`）均不体现这两个副作用。
- 影响：在读该 Provider 之前发生的任何 `MusicApi` 写操作/音质解析，缓存失效器与未知值日志钩子尚未注册；写后旧缓存不被失效（用户看到旧歌单/旧列表），未知音质降级不留痕。此类问题只在冷启动时序变化时偶现，且无日志可定位。
- 证据等级：静态推演

### lib/app/di.dart:34-37 未知音质降级仅 `print`，不进入可检索日志
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测：日志须可检索）
- 依据：注入的 `QualityDiagnostics.onUnknownValue` 实现体为 `print('[quality] unknown value fallback to q128: $raw')`（源码显式 `// ignore: avoid_print`），未走项目 `ErrorLogger`；且用 `??=` 表示「已被别处赋值则本处静默不生效」，无注册失败留痕。
- 影响：线上用户遇到上游返回未知音质而被静默降到 q128 时，只有开发态 stdout 一行，导出日志里查不到，无法统计与定位「为什么音质变差」。
- 证据等级：静态推演

### lib/app/di.dart:12-17 `TranslateApi()` / `LyricRepository` 无装配期契约校验
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约先行：跨层接口的失败语义必须明确）
- 依据：`translateApiProvider` 用无参构造 `TranslateApi()` 创建；`kugouApiClientProvider` 声明返回 `KugouApiClient` 而实际返回 `ref.watch(kgDirectApiProvider)`（子类实例），本文件未对两者之间的依赖是否完成初始化做任何断言或注释说明。
- 影响：装配层对「直连客户端是否已就绪」无校验；若上游 Provider 抛错，错误形态由被依赖方决定，调用方无法按统一异常契约处理，表现为歌词页进入即失败且原因不明。
- 证据等级：静态推演

#### 复核通过（本文件）
- `kugouApiClientProvider` 恒注入 `kgDirectApiProvider`，未出现 `new KugouApiClient()` 的 kapi 裸构造（符合 REVIEW_SPEC 装配口径）。
- 未再创建第二个 `ProviderContainer`；注释给出「为什么不能建」的原因（第 31 条）。
- 本文件无定时器/订阅/控制器，无资源释放对称性问题；无匿名闭包捕获 `ref` 造成的跨生命周期写入。

---

### 2/14 `lib/core/audio/preferred_quality.dart`（19 行，✅通读）

#### 问题

### lib/core/audio/preferred_quality.dart:12-16 `catch (_) {}` 空捕获且不留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：整个 `try` 体（含 `Hive.isBoxOpen`、`Hive.box<dynamic>('settings').get('defaultQuality')`、`AudioQuality.fromString(v)`）被一个**空体** `catch (_) {}` 包住，catch 内既不转译、也不记日志、也不返回带语义的降级值，只有注释「box 未打开或读取异常 → 用默认」；随后统一 `return AudioQuality.q320`。
- 影响：设置箱损坏/读取抛错时，用户为省流量选的「流畅/标准」音质被静默换成 320kbps 播放与下载，用户不可见、日志里无任何记录；同一异常也会掩盖 `fromString` 的编程错误（第 10 条）。
- 证据等级：静态推演

### lib/core/audio/preferred_quality.dart:12 捕获一切对象，把编程错误折成业务默认值
- 级别：P2
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理类型）、第 10 条（编程错误绝不进入业务降级）
- 依据：`catch (_)` 无 `on` 子句，覆盖 `TypeError`/`HiveError`/任意 `Error`；而 try 体内存在 `Hive.box<dynamic>(...)` 的泛型强转与 `AudioQuality.fromString(v)` 的解析，类型错误会与「箱未打开」走同一条静默 q320 分支。
- 影响：一次本地存储类型变更或解析实现缺陷会永久表现为「音质设置无效」，而不是崩溃/报错，缺陷被长期隐藏。
- 证据等级：静态推演

### lib/core/audio/preferred_quality.dart:11-14 磁盘读取边界未做类型校验，未登录/未设置/损坏三态被合并
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 16 条（空集合与缺失必须语义分离）
- 依据：`get('defaultQuality')` 的返回值只在 `v is String` 时使用；`null`（从未设置）、非 String（旧版本写入的 int/枚举 index）、读取异常三种事实全部折叠为同一个 `AudioQuality.q320`，既无留痕也无区分。
- 影响：老版本升级后用户此前保存的音质设置被无声重置为 q320（可能触发高额移动流量），且调用方无法区分「用户没设置」与「设置读不出来」，不能给出任何引导。
- 证据等级：静态推演

#### 复核通过（本文件）
- 播放与下载共用同一读取器，符合「音质单一事实源」意图（第 5 条）。
- 无异步等待后写共享状态，无世代问题；无资源申请，无泄漏。

---

### 3/14 `lib/core/theme/settings_provider.dart`（130 行，✅通读）

#### 问题

### lib/core/theme/settings_provider.dart:6-11 设置箱降级为 null 后永久内存态，无退出条件
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确的触发条件与退出条件）、第 9 条（失败必须可观测）
- 依据：`_settingsBoxProvider` 的 create 回调 `try { if (Hive.isBoxOpen('settings')) return ... } catch (_) {}`，失败或未打开时 `return null`（注释「未打开时降级为内存态，绝不抛异常卡首屏」）。`_settingsBoxProvider` 是无 `ref.onDispose`/`ref.watch` 依赖的普通 `Provider`，Riverpod 会缓存其首次结果，**此后 `initSettingsBox()` 成功开箱也不会令其重新求值**；四个 Notifier 拿到的 `_box` 恒为 null。且 `catch (_) {}` 为空体，不留任何日志。
- 影响：开箱稍慢于 Provider 首次读取（冷启动竞态）或开箱抛错时，用户本次会话里改主题/语言/歌词模式/日志开关全部只改内存，杀进程重启后设置全部丢失；用户看不到任何异常提示，日志也无记录。这是静默的用户设置丢失。
- 证据等级：静态推演

### lib/core/theme/settings_provider.dart:29-33 / 61-71 / 92-95 / 117-120 四个 `set()` 先改 state 后写盘，写失败无回滚、无留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常 / 失败须转译或留痕）、第 9 条（失败必须可观测）
- 依据：`ThemeModeNotifier.set`、`LocaleNotifier.set`、`LyricModeNotifier.set`、`VerboseLoggingNotifier.set` 均为 `state = ...; await _box?.put(...)`；无 try/catch、不 `await` 结果给调用方之外任何处理，异常直接向上抛到 UI；`_box == null` 时 `?.put` 静默 no-op 却仍返回成功 Future。
- 影响：Hive 写盘失败（磁盘满/箱被关）时界面立刻切换但重启后回退旧值，用户以为已保存；若 UI 未捕获，`Future` 异常成为未处理异步错误。写失败与「保存成功」在界面上完全同形。
- 证据等级：静态推演

### lib/core/theme/settings_provider.dart:22-23 / 50-51 / 85-86 / 114-115 四处磁盘值裸 `as String?` / `as bool?` 强转
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（数据边界必须校验）
- 依据：`box?.get(_key, defaultValue: 'dark') as String?`、`box?.get(_key) as String?`、`box?.get(key, defaultValue:'bilingual') as String?`、`box?.get(_key, defaultValue: false) as bool?` 均把 Hive（磁盘/持久化边界）返回值用 `as` 直接强转；旧版本写入 int、或跨版本字段名复用写入其它类型时，`as` 抛 `TypeError`（且发生在 `StateNotifier` 构造的 `super(_load(_box))` 内，即 Provider 首次求值处）。`_load` 均无 try/catch。
- 影响：老版本升级后设置箱里残留非 String/bool 值时，Provider 创建抛错 → 依赖它的页面（主题/语言/歌词设置）进入即崩或整棵子树失效，且没有降级路径。
- 证据等级：静态推演

### lib/core/theme/settings_provider.dart:52-57 locale 字符串未做合法性校验，空串/多段被构造为非法 Locale
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界校验）、第 3 条（输入取值范围契约）
- 依据：`_load` 对 `v.split('_')` 只判 `parts.length == 2 ? Locale(parts[0], parts[1]) : Locale(parts[0])`；`v` 为 `''` 时 `parts == ['']` → `Locale('')`；`v` 为 `'zh_Hant_TW'` 时 `parts.length == 3` → `Locale('zh')`（静默丢弃地区/脚本）。无任何长度、字符集、`supportedLocales` 校验。
- 影响：损坏或被外部写入的 locale 值会让 App 落到一个不受支持的语言，`Locale('')` 下 MaterialApp 取不到字体/本地化资源，界面文案异常或空白；用户无法从界面判断原因。
- 证据等级：静态推演

### lib/core/theme/settings_provider.dart:130 `initSettingsBox()` 无异常契约、无开箱失败留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 3 条（可抛异常集合应明确）
- 依据：`Future<void> initSettingsBox() => Hive.openBox('settings');` 一行直接返回 Hive 的 Future，未捕获、未包装、未记录；与 `_settingsBoxProvider` 的空 catch 形成「一处吞、一处裸抛」的两套异常形态。
- 影响：启动阶段开箱失败时错误形态由 Hive 决定，调用方无法按统一契约处理；同时上面第 1 条的内存态降级已生效，形成「报错了但其实全程用内存态」的不可观测状态。
- 证据等级：静态推演

#### 复核通过（本文件）
- 四个设置项均用 `StateNotifier` 且持久化写回，注释明确「Hive 与内存不并存两份可写副本」的意图（第 5 条）。
- `LyricModeNotifier._load` 用 `firstWhere(orElse:)` 对未知枚举名给了明确降级，未用 `as` 之外的裸索引。
- 无定时器/订阅/控制器，无资源释放对称问题；无异步等待后写共享状态，`set()` 内 `state` 赋值在 `await` 之前，无世代错写。

---

### 4/14 `lib/core/utils/permission_gate.dart`（92 行，✅通读）

#### 问题

### lib/core/utils/permission_gate.dart:51-54 `apiLevel()` 调用无异常保护，与同文件其它通道查询的异常处理不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一且稳定）、第 9 条（失败必须可观测）
- 依据：`hasMediaReadAccess()` 中 `final level = await _service.apiLevel();` 位于 `try` 之前且无 catch；同文件 `hasStorageWriteAccess`（:28-34）、`hasMediaReadAccess` 的 `Permission.audio.status` 部分（:55-60）、`openSettings`（:85-89）都做了 `try/catch + debugPrint`。同一类「平台通道查询」在本类里出现「有保护 / 无保护」两种异常形态。
- 影响：平台通道抛错（Android 服务异常、MethodChannel 未注册）时，`hasMediaReadAccess` 直接向调用方抛未包装异常，UI 的只读状态展示变成未处理异步错误；而同样的故障在其它入口只是显示「无权限」，行为不一致且无日志。
- 证据等级：静态推演

### lib/core/utils/permission_gate.dart:62-79 `requestWithPrompt` 全链路无异常保护、且 `BuildContext` 跨两次异步等待后使用
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（异步回调触及已销毁对象必须先确认存活）、第 8 条
- 依据：`permission.status`、`permission.request()`、`openAppSettings()` 三处均为裸 await 无 try/catch；`Toast.show(context, reason)` 在两次异步等待之后使用传入的 `BuildContext`，未检查 `context.mounted`，也未在申请前/返回后做任何世代或存活校验。
- 影响：用户在权限弹窗期间退出页面（或旋转/重建）后再拒绝授权，`Toast.show` 会持有已卸载的 context，触发 Flutter 的 "Do not use BuildContexts across async gaps" 类错误/断言；权限申请被系统拒绝时的平台异常也无任何留痕，界面表现为按钮点了没反应。
- 证据等级：静态推演

### lib/core/utils/permission_gate.dart:74-76 永久拒绝分支 `openAppSettings()` 异常被裸抛且返回值语义混淆
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（失败时返回语义明确）、第 9 条
- 依据：`if (status.isPermanentlyDenied) { await openAppSettings(); return false; }` 中 `openAppSettings()` 无 try/catch（同类方法 `openSettings()` 却有），且「成功打开设置页」与「打开失败」都返回 `false`，调用方无法区分。
- 影响：某些 ROM 上 `openAppSettings` 抛错时用户看到的是一次静默失败（无提示、无日志）；同时 UI 无法据此给出「请手动到设置里开启」的引导，权限永久拒绝后功能一直不可用。
- 证据等级：静态推演

#### 复核通过（本文件）
- 判定逻辑统一委托 `StoragePermissionService.instance`，本类不自行判断权限态（第 5 条状态单一来源）。
- `hasStorageWriteAccess`、`hasMediaReadAccess` 的查询接口明确「不申请、不弹窗」，与写前申请接口分离（第 2 条）。
- 非 Android 平台统一 `return true`，无平台分支遗漏；无定时器/订阅，无资源申请释放问题。

---

### 5/14 `lib/core/widgets/confirm_dialog.dart`（42 行，✅通读）

#### 问题

### lib/core/widgets/confirm_dialog.dart:23-40 `builder` 内混用外部 `context` 与 `ctx`，对话框生命周期内的 context 归属不统一
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（异步回调触及已销毁对象必须先确认对象仍存活）
- 依据：`builder: (ctx) => AlertDialog(...)` 中，取消/确认按钮的 `Navigator.pop` 用的是 `ctx`，但两个按钮的文案却用外部 `context.l10n.cancel` / `context.l10n.confirm`，图标色用函数入口缓存的 `scheme`（`Theme.of(context)` 在 `showDialog` 之前求值）。若对话框打开期间外部 `context` 所在子树被卸载或主题/语言切换，弹窗内按钮仍持有旧 context/旧配色。
- 影响：语言切换或页面被替换后，弹窗按钮文案停在旧语言、危险色与当前主题不一致；在外部 context 已 dispose 时读 `context.l10n` 可抛异常，破坏性操作的确认框反而成为崩溃点。
- 证据等级：静态推演

#### 复核通过（本文件）
- `showDialog<bool>` 的 `ok == true` 把「返回 null（点遮罩/返回键取消）」正确折叠为「不执行破坏操作」，默认安全（第 14/21 条边界处理到位）。
- 文案由调用方传入并走 `l10n`，本文件无硬编码 UI 文案（i18n 到位）。
- 无资源申请、无异步写共享状态，无世代问题；`showDialog` 由调用方 await 结果，无未等待 Future。

---

### 6/14 `lib/core/widgets/gradient_chip.dart`（53 行，✅通读）

#### 问题

### lib/core/widgets/gradient_chip.dart:1-6 三个 import 全部未被使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍：未使用的导入）
- 依据：文件首行 `import 'dart:async';`，第 5 行 `import '../utils/toast.dart';`，第 6 行 `import '../../l10n/l10n.dart';`；全文 53 行内除 `GradientChip` 与 `_hue` 外无任何符号引用 `Future`/`Stream`/`Timer`、`Toast`、`l10n` 扩展。文末第 53 行还残留孤立注释 `/// 统一加载骨架（带微光动画）`，本文件并无对应实现（实现在同目录 `shimmer.dart`）。
- 影响：无用户可见功能后果，但 `dart analyze` 会产生 3 条 unused_import 警告并掩盖真实告警；孤立注释误导维护者以为骨架实现在此文件。
- 证据等级：静态推演（analyze 见文末，实锤 unused_import 警告）

### lib/core/widgets/gradient_chip.dart:20-22 / 33-38 未校验 `index` 边界与 `label` 空串；chip 无语义标签
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（数据边界必须校验）
- 依据：`_hue(int i)` 直接 `(i * 47.0) % 360`，对负数 index 得负色相（`HSLColor.fromAHSL` 的 hue 参数按契约应为 [0,360)）；`Text(label)` 无 `maxLines`/`overflow`，`InkWell` 无 `Semantics`/tooltip。
- 影响：传入负 index 或超长标签时颜色异常、文字溢出容器；屏幕阅读器只读到无上下文的裸文本。属边界/可访问性缺陷。
- 证据等级：静态推演

#### 复核通过（本文件）
- `build` 为纯函数，无 I/O、无状态变更（第 24 条）；`_hue` 是静态纯计算。
- 无控制器/订阅/定时器，不存在释放对称问题；`onTap` 为可空回调，未强制点击。

---

### 7/14 `lib/core/widgets/shimmer.dart`（151 行，✅通读）

#### 问题

### lib/core/widgets/shimmer.dart:36-51 `enabled` 从 false→true 且 controller 已完成时动画不会重启
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条（降级/恢复必须有明确的退出条件）、第 20 条（生命周期状态与资源状态一致）
- 依据：`didUpdateWidget` 只在 `widget.enabled && !_controller.isAnimating` 时 `_controller.repeat()`；`initState` 中 `enabled=false` 时**不调用 repeat**，此时 controller 处于 `dismissed`（`isAnimating=false`），后续切 true 会走 repeat 分支，此路径正常。但一旦 `enabled` 由 true→false 调用 `_controller.stop()` 后再切回 true，`isAnimating` 为 false 会 repeat（`repeat()` 从当前值重启到 1 后循环），此路径也正常。**真正的不对称**在：`_controller.repeat()` 从不因 `enabled=false` 而 `reset()`，且 `build` 在 `!enabled` 分支仍保留 controller 活跃于内存中（未 dispose），只是不渲染；同时 `initState` 只在构造时读一次 `widget.enabled`，若 widget 首次以 `enabled=true` 创建、随后父级在同一帧内改 false，`stop()` 之后 controller 停在任意 `value`（非 0），再启用时高光带从中间开始，出现一次可见跳变。
- 影响：系统「减少动态效果」开关切换/骨架屏反复进出时，微光带从随机位置突然出现或停在中途，视觉闪烁；controller 在长时间停留的骨架列表里持续占用 ticker 资源（虽被 stop，但 TickerProvider 未释放直到 dispose），在低端机上与列表滚动争帧。
- 证据等级：静态推演

### lib/core/widgets/shimmer.dart:70-82 每帧 `shaderCallback` 内新建 `LinearGradient` 与 `Matrix4`
- 级别：P2
- 违反：QUALITY_STANDARD 第 26 条（热路径零分配）、第 24 条（构建函数不得在每帧路径上做可避免的解析/分配）
- 依据：`AnimatedBuilder` 的 `builder` 每帧执行，`shaderCallback` 每次重绘都 `LinearGradient(colors:[base, highlight, base], stops: const [...], transform: GradientTranslation(dx * bounds.width))` 新建对象，并在 `GradientTranslation.transform` 里 `Matrix4.translationValues(dx,0,0)` 新建矩阵；`bounds` 宽度每帧参与乘法。一个屏幕里若同时有 N 个 `Shimmer`（列表骨架通常 6–10 个），每帧新建 2N 个对象。
- 影响：骨架屏常出现于首屏/弱网等待阶段，低端机上每帧 GC 压力与栅格化开销叠加导致骨架动画掉帧、页面切换卡顿；这是典型「高端机不可见、低端机明显」的性能退化。
- 证据等级：静态推演

### lib/core/widgets/shimmer.dart:42-47 / 56-57 颜色无兜底校验，`withValues(alpha:0.4)` 与 `ShaderMask` 的 srcATop 组合在透明 child 上无可见骨架
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（边界值）
- 依据：`base`/`highlight` 完全由 `Theme.of(context).colorScheme` 与调用方可空参数决定，未校验 `base == highlight` 或 alpha 无效；`ShaderMask(blendMode: BlendMode.srcATop)` 要求 child 有不透明像素才能显示高光，而 `SkeletonBox`/`SkeletonText` 本身只是半透明色块，多个 `Shimmer` 嵌套或 child 全透明时高光完全不可见。
- 影响：极端主题（自定义纯色）下骨架屏看起来是静止色块，用户无法区分「加载中」和「内容为空」。
- 证据等级：静态推演

#### 复核通过（本文件）
- `_controller.dispose()` 在 `dispose()` 中对称调用，且 `SingleTickerProviderStateMixin` 与之配对（第 20 条主路径成立）。
- `enabled=false` 走 `ColoredBox` 静态分支，不创建 `AnimatedBuilder`（第 11 条 reduced-motion 降级有明确触发条件）。
- `AnimatedBuilder` 用 `child:` 缓存子树，`builder` 内不重建 child（第 24/26 条局部成立）。

---

### 8/14 `lib/core/widgets/splash_screen.dart`（29 行，✅通读）

#### 问题

### lib/core/widgets/splash_screen.dart:18-28 启动页无超时/无失败兜底，完全依赖外部替换
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确的触发条件与退出条件）
- 依据：`SplashScreen` 自身是纯 `StatelessWidget`，`build` 只装配 `SplashHandwriting(label: ...)`，无 Timer、无超时、无「首帧未就绪」的判断或退出条件；注释声称「显示直到首帧就绪」，但退出逻辑完全不在本文件，也不接受任何「就绪」信号参数。
- 影响：若调用方的初始化流程异常或首帧看门狗未触发替换，启动页会无限循环播放手写动画，用户永久停留在启动页且无错误提示；本组件无法自检也无法留痕。
- 证据等级：静态推演

#### 复核通过（本文件）
- 职责单一：动画逻辑全部委托 `SplashHandwriting`，本文件只装配（第 1 条）。
- App 名走 `context.l10n.appName`，无硬编码中文（i18n 到位）。
- `build` 为纯函数，无 I/O、无状态变更；无资源申请，无泄漏。

---

### 9/14 `lib/features/home/presentation/home_page.dart`（657 行，✅通读，分 3 段完整读完 1-230/231-460/461-657）

#### 问题

### lib/features/home/presentation/home_page.dart:35-40 `onRefresh` 无异常保护，刷新失败时指示器照常收起且旧数据被当作新数据
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 6 条（禁止吞掉/未处置异常）
- 依据：`onRefresh: () async { await ResourceGateway.instance.invalidateNs('home'); return ref.refresh(homeDataProvider.future); }`，`invalidateNs` 与 `refresh` 均无 try/catch、无日志、无 Toast；`RefreshIndicator` 只等待 Future 完成（含 error 完成）就收起指示器。注释「refresh.future 保留旧数据等待新结果（不闪回骨架屏）」说明失败时**旧数据仍留在屏幕上**。同时 `homeAsync.when` 只在 `loading/error` 分支展示错误，而 `ref.refresh(...future)` 的错误不会写回正在展示的 `AsyncData`。
- 影响：下拉刷新遇到网络失败/缓存清理异常时，用户看到指示器转完、列表一动不动、全是旧推荐，既无错误提示也无日志，误以为「刷新成功但没新内容」。这是长时间静默错误。
- 证据等级：静态推演

### lib/features/home/presentation/home_page.dart:177 / 444 Banner 与榜单封面未做空 URL 守卫，与同文件两处守卫不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界必须校验）
- 依据：`_BannerCarousel` 的 `CachedNetworkImage(imageUrl: widget.banners[i].imageUrl)`（:177）与 `_RankRow` 的 `CachedNetworkImage(imageUrl: r.cover)`（:444）直接把网络数据字段交给图片组件；而同文件 `_DailyRecommend`（:251，注释「V33-14 修复② 空封面守卫」）与 `_PlaylistRow`（:344，注释「V33-15 修复② 空封面守卫」）都显式判 `isNotEmpty` 后降级。同一页面四种数据源两套边界口径。
- 影响：上游返回空字符串封面时，Banner 轮播/榜单卡片触发无效 URL 请求异常，占位 `errorWidget` 虽能兜住但最终表现为灰块/空白卡；日志里没有可检索的上游字段异常记录，无法定位是哪条数据脏。
- 证据等级：静态推演

### lib/features/home/presentation/home_page.dart:133-148 `_index` 在 banners 变短后越界，且 `didUpdateWidget` 未重置翻页状态
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步/刷新后共享状态须校验世代）、第 14 条（边界值）
- 依据：`_BannerCarouselState` 声明 `int _index = 0`，`onPageChanged` 由用户手势写入；`didUpdateWidget` 未覆写，`_startAutoPlay()` 只在 `initState` 调用。下拉刷新让 `widget.banners` 从 5 条变 2 条后，`_index` 仍可能是 4：指示点循环 `i == _index`（:194）永远为 false（无高亮点），`PageController` 仍指向旧页，下一次 Timer 的 `animateToPage((4+1)%2=1)` 会直接跳到末页。
- 影响：刷新后轮播指示点全部熄灭、自动翻页从错误位置跳变，用户看到 Banner「自己乱跳」；StatefulShellRoute 保活下这个状态会一直残留到页面重建。
- 证据等级：静态推演

### lib/features/home/presentation/home_page.dart:124-132 `_visible` 只写字段不触发重建，且切后台不取消进行中的翻页动画
- 级别：P3
- 违反：QUALITY_STANDARD 第 20 条（生命周期状态与资源/动画状态一致）
- 依据：`didChangeAppLifecycleState` 仅 ` _visible = state == AppLifecycleState.resumed;` 未 `setState`，也未对已启动的 `_controller.animateToPage` 做任何处理；`Timer.periodic` 在 paused 期间仍持续回调（靠 `_visible` 早退）。`_visible` 初值 `true`，若 App 以非 resumed 状态创建该 State（如从后台恢复的路由重建），第一次 4s Tick 之前没有同步过真实生命周期。
- 影响：切后台再回前台时，可能有一帧停留在中途的半透明 Banner 过渡；注释宣称的「非当前 Tab 不后台翻页」只覆盖 Tab 切换，未覆盖 App 生命周期切换时的在途动画。
- 证据等级：静态推演

### lib/features/home/presentation/home_page.dart:525-534 下载菜单用 `song.hash ?? song.id` 构造 Song，无空值/有效性校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界校验）、第 17 条（标识符精度/形态）
- 依据：`Song(hash: song.hash ?? song.id, albumId: song.albumId ?? '', albumAudioId: song.albumAudioId ?? '', ...)`；`HomeSong.hash` 与 `id` 均为可空字段，`?? song.id` 在两者皆为 null 时仍可能得到 null（若 `id` 可空），且 `albumId`/`albumAudioId` 缺失时统一降级为空串而非「不可下载」，`duration: Duration(seconds: song.duration)` 未校验负值/异常大值。此处无任何失败提示或日志。
- 影响：上游缺 hash 时下载单被提交一个无效标识，下载流程随后失败但用户只看到「下载没反应」，且无法区分「歌曲不支持下载」与「数据脏」；异常 duration 会写入错误的元数据。
- 证据等级：静态推演

### lib/features/home/presentation/home_page.dart:1-19 import 顺序混乱且 `dart:async` 与多个 core 包混排
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码/整洁度）、第 30 条（命名即文档）
- 依据：文件前 19 行里 `dart:async`、相对路径 `core/cache/resource_gateway.dart`、`package:` 导入、`../../player/play_helper.dart`、l10n 交替出现 4 组；`cache_manager.dart` 导入后全文未见 `CacheManager`/`getWithStale` 等符号引用（需 analyze 确认是否 unused_import）。
- 影响：无用户可见后果；但混乱导入与潜在未使用导入会淹没真实 analyze 告警，增加维护成本。
- 证据等级：静态推演（analyze 见文末核对是否 unused_import）

#### 复核通过（本文件）
- `_BannerCarouselState.dispose()` 同时 `cancel` Timer、`removeObserver`、`dispose` PageController，且 `WidgetsBinding.instance.addObserver` 在 `initState` 成对（第 20 条主路径成立）。
- Timer 回调入口有 `!mounted` 与 `ModalRoute.of(context)?.isCurrent` 双闸门，避免后台 Tab 堆积 setState（第 18/20 条局部成立）。
- 三态齐备：`loading → _HomeSkeleton`、`error → ErrorRetry(onRetry: ref.invalidate)`、`data` 且五个集合全空 → `EmptyState(reload)`（第 16 条空/失败分离）。
- 列表用 `SliverList.separated`/`ListView.separated` 惰性构建（第 24 条）；所有 `CachedNetworkImage` 均传 `memCacheWidth` 限制解码尺寸，并注入统一 `AppImageCache.instance`（第 25 条局部成立）。
- `_HomeSkeleton` 用与内容页相同的 Sliver 结构与固定高度，切换不跳动；骨架内 `ListView.separated` 避免 360dp 屏溢出。

---

### 10/14 `lib/features/lyric/data/lyric_repository.dart`（281 行，✅通读，分 2 段完整读完 1-160/161-281）

跨文件契约抽查（本文件相关，计入 8 个抽查额度）：`lyric_view.dart`（补丁应用与 `_boundLyric` 绑定）、`lyric_translation_stream.dart`（`LyricTranslationPatch` 定义）、`cache_manager.dart`（`LyricTranslationCache.get/set`）、`full_player_page.dart`（`ensureTranslation` 调用点与世代键）。

#### 问题

### lib/features/lyric/data/lyric_repository.dart:164-183 缓存命中时按「非连续 missing 下标」构造补丁，values 与 startIndex 语义不成立
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（跨层接口契约：输入取值范围与语义必须明确）、第 17 条（索引必须精确）
- 依据：`missing` 是**不保证连续**的行号列表（:150-153 逐行筛 `translation` 为空）；`LyricTranslationPatch(lyricId, missing.first, [for (final i in missing) ...])` 把 `missing.first` 当 `startIndex`，把全部缺译行的译文按 missing 顺序当连续 `values`。消费方 `lyric_view.dart:106-120` 明确按 `i = p.startIndex + j` 逐行写入（`values[j]` 落到 `lines[startIndex+j]`）。当歌词第 3 行已有内嵌译文、缺译行为 0,1,2,4,5 时，`startIndex=0`，`values` 长度为 5，原本第 5 行的译文会写到第 4 行、第 4 行译文写到第 3 行，末行译文丢失。
- 影响：双语歌词在部分行自带译文（KRC 常见）或缓存命中「仅成功部分」译文时，译文整体错位到错误歌词行；用户看到唱 A 句却显示 B 句译文，且 `lyric_view` 的「已有译文不覆盖」策略会让错误译文长期驻留直到切歌。
- 证据等级：静态推演（跨文件契约已核对，非推测消费方行为）

### lib/features/lyric/data/lyric_repository.dart:216-227 翻译成功批次同样用 `missing[i]` 作 startIndex，多批时行号映射错误
- 级别：P1
- 违反：QUALITY_STANDARD 第 17 条（索引精确性）、第 3 条
- 依据：外层 `for (var i = 0; i < texts.length; i += batchSize)` 的 `i` 是 **texts 的下标**（即 `missing` 的下标），却被当作 `missing[i]` 的**行号**用于 `startIndex`（`LyricTranslationPatch(lyricId, missing[i], ...)`，:222），以及 `translations[missing[i + j]] = value`（:213）。同一处 `i` 在 :202 的 `sublist(i, i+batchSize)` 里是 texts 偏移，在 :213/:222 里被复用为 missing 下标——这两者恰好一致时正确，但 :222 传给 `startIndex` 的是**行号**而非「连续段起点」，而 `values` 是连续批译文；一旦 `missing` 非连续（:150 允许），`startIndex + j` 与 `missing[i+j]` 不再相等，广播补丁与写回 `translations` 落到两套不同行。
- 影响：同一批译文在 UI 实时补丁与最终持久缓存里出现两种不同对齐，用户先看到错行译文、切歌再回来看到另一种错行译文，前后不一致且无法自愈。
- 证据等级：静态推演

### lib/features/lyric/data/lyric_repository.dart:14-17 `_api` 恒等字段被显式标注为未使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍：无人写入/使用的状态）
- 依据：`// ignore: unused_field — 恒等字段：构造契约保留 _api 引用（调用方可直查 userid 等状态）`；全文 281 行中 `_api` 除构造函数初始化列表 `CachedApiCall(_api, ns: 'lyric')` 外无任何读取，注释所称「调用方可直查」在本类无对应 getter 或方法。
- 影响：无用户可见后果；但以 `ignore` 抑制告警掩盖了真正的死字段，且注释描述的行为在本文件不存在（第 31 条）。
- 证据等级：静态推演

### lib/features/lyric/data/lyric_repository.dart:116-120 LRC Base64 解码失败 `catch (_) {}` 空体且不留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞异常）、第 9 条（失败必须可观测）
- 依据：`try { krcText = utf8.decode(base64.decode(base64.normalize(raw.trim())), allowMalformed: true); } catch (_) { // 歌词是可选内容，任何解码异常都不应影响播放 return null; }`；catch 为空体（仅注释），既不记录也不区分「Base64 非法」与「内容为空」；随后 `fetchLyric` 会再试一次 LRC/KRC 降级，最终统一返回 null。同文件 KRC 分支（:124-128）却对失败做了 `debugPrint`，两套失败可观测性口径不一致。
- 影响：上游返回损坏的 LRC 内容时，用户只看到「暂无歌词」，日志里查不到任何线索；运维无法区分「版权方没给词」与「解码实现有缺陷」。
- 证据等级：静态推演

### lib/features/lyric/data/lyric_repository.dart:39-41 / 102-105 `_cached.get` 异常无世代校验与缓存维度校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`findCandidate` 以 `query` 里的 `hash/keywords/album_audio_id/duration` 走 `_cached.get('/search/lyric', ...)`，`fetchLyric` 的 `_fetchLyricByFormat` 走 `_cached.get('/lyric', ...)`；两处只把 `ns: 'lyric'` 与 `ttl: 168h` 交给 `CachedApiCall`，**未把 `format`（krc/lrc）之外的 `decode=true` 语义差异、用户身份、歌词版本纳入本层可见的键**，也未对 `await` 之后的结果做任何「当前歌曲是否仍是发起时那首」的校验（世代校验只在上游 `full_player_page.dart:74-77` 的 `ensureTranslation` 之后做一次，`findCandidate`/`fetchLyric` 自身的两次 await 无校验）。
- 影响：快速切歌时，旧歌的候选/歌词请求仍在 `CachedApiCall` 的 in-flight 里被复用，旧歌歌词可能被写进当前代际（上游虽有最终 hash 校验，但仍白跑两轮网络并占用共享缓存槽）；若上游某个调用点不做校验，即出现「唱 A 歌显示 B 歌词」。
- 证据等级：静态推演

### lib/features/lyric/data/lyric_repository.dart:269-278 版本哈希用 31 进制短哈希且只在 `text` 上累加，无长度/溢出语义说明
- 级别：P3
- 违反：QUALITY_STANDARD 第 23 条（缓存键维度）、第 17 条（精度可追溯）
- 依据：`_lyricVersionKey` 只累加 `line.text.codeUnits`（不含 `translation`、`startMs`/`wordStartMs` 时间轴、offset），返回 `'${lyric.lines.length}-$hash'`，`hash` 用 `& 0x7fffffff` 截断到 31 位。注释称「行数与内容同时纳入即可覆盖官方改词/KRC 版本变化」。
- 影响：官方只改时间轴（修正歌词不同步）或只改译文时版本键不变，仍命中旧译文缓存；极长歌词下 31 位哈希碰撞概率虽低但无冲突处理，一旦碰撞即全篇译文错行。用户表现为「歌词改版后译文还是旧的」。
- 证据等级：静态推演

#### 复核通过（本文件）
- `findCandidate` 对 `candidates` 先判 `is List`、逐条 `raw is! Map` 跳过、`id`/`accesskey` 缺失与字符串 `"null"` 均跳过，避免 `id=null&accesskey=null` 非法请求（第 13/14 条到位）。
- `fetchLyric` 对 `format` 做 `ArgumentError` 显式校验；KRC 解不出时降级 LRC 并 `debugPrint` 留痕，触发/退出条件明确（第 11 条）。
- 翻译批次 `translated.length != batch.length` 时不落缓存、只记日志（:204-208），避免条数不符时整批错行被持久化；单批异常 `catch` 有 `debugPrint` 且不写缓存（:228-233，第 6/9 条主路径成立）。
- 译文缓存键含 `lyricId + targetLanguage@versionKey`，`LyricTranslationCache._key` 再并入 `AppConfig.translateModel`（第 23 条局部成立）。
- `LyricTranslationStream.emit` 在 `c.isClosed` 时早退，`dispose()` 后 `_ctl` 可重建（第 20 条局部成立）；`ensureTranslation` 的 `songHash` 透传至 patch，`lyric_view` 按 (songHash, lyricId) 双键校验（第 18 条局部成立）。

---

### 11/14 `lib/features/mv/data/mv_repository.dart`（399 行，✅通读，分 2 段完整读完 1-210/211-399）

#### 问题

### lib/features/mv/data/mv_repository.dart:41 / 80-104 静态 `Map<String,String> _hashToVideoId` 无并发合并、无用户维度、超限整体 clear
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 25 条（所有资源必须有上限）、第 22 条（并发假设必须写明）
- 依据：`static final Map<String, String> _hashToVideoId = {};` 为进程级全局静态，`fetchDetail` 用 `_hashToVideoId[videoId] ?? await _resolveVideoIdByHash(videoId)`，**未命中时多个并发调用各自发起 `/search`（无 in-flight 合并）**；写入处只有 `if (_hashToVideoId.length > 128) _hashToVideoId.clear();`（:96），即第 129 个条目会清空全部 128 条；键里只有 hash，不含登录态/userid/ns。注释称「会话级缓存（有上限）」，但无任何并发访问前提声明。
- 影响：切账号后仍复用上一个账号的反查结果（MV 可见性/地区差异可能被串）、并发打开多个 MV 时重复发同一批搜索请求；缓存长到 129 条时全部失效，接下来一批 MV 进页都重新打搜索，出现周期性卡顿。
- 证据等级：静态推演

### lib/features/mv/data/mv_repository.dart:61-66 `fetchDetail` 未对 `videoIdOrHash` 做形态校验、未校验 `data` 结构即交 `fromJson`
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 3 条（输入取值范围契约）
- 依据：`videoId = videoIdOrHash` 后，只有 `_looksLikeHash` 为真时走反查；**非 hash 形态的字符串（空串、非数字、超长 ID）直接作为 `{'id': videoId}` 发出**，没有任何数字校验（对比 `_resolveVideoIdByHash` 里对反查结果明确 `int.tryParse(id) != null` 才收，:94）。`_cached.get` 返回的 `data` 未做 `status`/`data` 字段存在性判断即 `MvDetail.fromJson(data)`；`fromJson` 在 `raw` 既非 List 也非 Map 时 `data = json`（:301），把整个响应体当详情对象，随后所有字段取空串。
- 影响：调用方传入空/脏 id 时发出无效请求，接口返回错误包被解析成「空详情」（`hashes` 全空、`bestHash == null`），用户在 MV 页只看到「MV 暂无播放地址」而无从得知是数据问题；错误被静默降级（第 9/11 条）。
- 证据等级：静态推演

### lib/features/mv/data/mv_repository.dart:120-135 `resolvePlayUrl` 用 `d.values.first` 兜底取任意清晰度 URL，键大小写不匹配时静默播错视频
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发条件与次优行为）、第 9 条（失败必须可观测）
- 依据：`d[hash.toLowerCase()] ?? d[hash.toUpperCase()] ?? (d.isEmpty ? null : d.values.first)`；当响应 `data` Map 存在但**不含本 hash 对应键**（上游按其它 hash/画质分组返回，或请求 hash 与返回键大小写混杂）时，无条件取 `values.first` 当作目标视频的播放地址；此分支无 `debugPrint`/`ErrorLogger` 留痕，且 `entry is! Map` 时才抛错。注释把「优先直连原始 HTTP 地址」作为降级理由，与本处「取任意条目」的降级无关（第 31 条）。
- 影响：点开 A 的 MV 实际播放 B 的 MV（或错误清晰度/错误片段），用户看到画面与歌名不符且无任何提示；这类错误在测试环境（单条返回）不可见。
- 证据等级：静态推演

### lib/features/mv/data/mv_repository.dart:124-133 `backupdownurl` 首项强转为字符串后未校验 URL 形态
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（网络响应边界校验）、第 13 条（外部数据禁止裸强转）
- 依据：`else if (backup is List && backup.isNotEmpty) { url = '${backup.first}'; }`，`backup.first` 可能是 Map/嵌套 List/null，`'${...}'` 会把任意对象字符串化为 `"{...}"` / `"null"`；`url` 仅判 `isNotEmpty` 即返回，无 scheme/域名/长度校验。同分支 `down`/`backup` 为 String 时也未校验。
- 影响：上游把 backup 数组元素改为对象时，播放器拿到非 URL 字符串作为源，MV 播放立即失败且错误来自播放器底层（用户看到「播放失败」，无法定位到解析层）；若字符串恰为 `null` 还会触发一次无效网络请求。
- 证据等级：静态推演

### lib/features/mv/data/mv_repository.dart:347-353 `duration` 的毫秒→秒换算对异常大值无上限、负值统一吞为 0
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（边界值）、第 15 条（单位必须显式）
- 依据：`durationMs = durRaw.round()`（num 可为 double/负数/极大值），`duration = durationMs <= 0 ? 0 : durationMs ~/ 1000`；`MvInfo.fromJson:231-237` 同口径但注释称「实测恒为毫秒」，而两处字段名不同（`duration`/`timelength`）却共用同一单位假设，无具名常量或类型区分。上游若返回秒（字段变更）则时长被压成 0。
- 影响：脏数据下 MV 时长显示 0:00 或异常巨大值，进度条/耗时展示错误；单位假设一旦上游变更，全模块无自检。
- 证据等级：静态推演

#### 复核通过（本文件）
- `_looksLikeHash` 用 32 位十六进制严格判定，避免把纯数字 video_id 误当 hash（第 14 条局部成立）。
- `_resolveVideoIdByHash` 查不到时显式抛 `ApiException` 而非静默降级为空详情，且对 `MvID` 做 `int.tryParse` 脏数据过滤（第 9/14 条）。
- `resolvePlayUrl` 的三种 URL 来源（downurl / backup List / backup String）均判空，最终 `url.isEmpty` 抛 `ApiException`，不让空地址流入播放器（第 16 条）。
- `MvInfo.fromJson` / `MvDetail.fromJson` 对 `mkv`/`h264`/`h265`/`data` 均先 `is Map`/`is List` 再 `Map<String,dynamic>.from`，无裸 `as Map<String,dynamic>`（第 13 条主路径成立）。
- `_mvThumb` 对空串早退、`{size}` 占位替换、裸文件名拼 URL、http→https 升级三处边界均有处理，尺寸档按控件需求传 320/480（第 25 条局部成立）。

---

