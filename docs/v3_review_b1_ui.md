# 第5批·审查③ UI/状态/发布合规复核报告（v3.0 终审 C 视角）

- 基线：`bc4a521`（tag v3.0.0）
- 审查方式：完整 file_read 逐文件通读；`dart analyze` 仅作补充（过滤缺 Flutter 包噪音）
- 判定依据：`docs/QUALITY_STANDARD.md` 32 条
- 级别：P0 崩溃/数据损坏/安全 / P1 核心功能失效或长时间静默错误 / P2 次要异常·边界·性能·可访问性 / P3 整洁度

---

## 0. 前置：清单与环境

```
lib/core/widgets/ 共 10 个文件：
animated_svg_logo.dart  confirm_dialog.dart  empty_state.dart  error_retry.dart
gradient_chip.dart  list_skeleton.dart  section_header.dart  shimmer.dart
song_tile.dart  splash_screen.dart
lib/l10n/：app_de/en/es/fr/ja/ko/pt/ru/zh/zh_CN/zh_TW.arb + app_localizations.dart + l10n.dart（共 11 个 arb）
```

---
## 1. `pubspec.yaml`（发布合规）

**读取结论：版本号合规。** `version: 3.0.0+30`，与 tag `v3.0.0` / versionName 3.0.0 / versionCode 30 一致。
`environment.sdk: '>=3.4.0 <4.0.0'` 与 `intl ^0.20.3`、`go_router ^14.2.0`、`flutter_lints ^4.0.0` 相互自洽（intl 0.20 需要较新 Flutter，SDK 下限 3.4 可接受）。

**依赖声明完整性**：本文件所直接声明的包覆盖了本次审查读到的所有第三方 import
（dio / dio_cookie_manager / hive / hive_flutter / path_provider / flutter_riverpod / go_router /
just_audio / audio_service / video_player / flutter_inappwebview / cached_network_image / flutter_svg /
crypto / archive / image / pointycastle / permission_handler / url_launcher / package_info_plus / uuid /
file / flutter_cache_manager / flutter_secure_storage / qr_flutter）。未发现「import 了但 pubspec 未声明」的包。

### 【P3】依赖体积与声明冗余：`audio_session`、`qr_flutter`、`image`、`archive`、`pointycastle` 等高权重包无条件进入 release
- 事实：`dependencies` 全部为直接依赖，无 `dependency_overrides`，也未用 `deferred`/条件导入；`archive`+`image`+`pointycastle` 三者叠加是安装包体积的主要来源（合计数 MB）。
- 违反：第 25 条（资源必须有上限/可解释）在工程维度的延伸——「凡是无上限的，迟早在低端设备上耗尽」；此处表现为包体积与启动期符号解析成本无预算约束。
- 后果：低端机安装包偏大、首启 dex/so 加载偏慢；非功能性，定 P3。

### 【P3】`assets: - assets/` 整目录声明
- 事实：以目录方式声明 `assets/`，目录内任何文件（含设计源文件/临时图）都会被打包，且新增文件不需要评审即可进入产物。
- 违反：第 2 条（魔法/隐式优于显式）——资源清单不显式。
- 后果：包体随目录内容漂移，无法从 pubspec 判断产物内容。P3。

### 观察（不计问题）
- `publish_to: 'none'` + `generate: true` 与 `l10n.yaml` 配合正确，l10n 生成会在 build 时执行；因此 **.arb 键缺失会直接导致构建失败**（见 §17 实测）。

---

## 2. `lib/main.dart`（336 行，通读）

整体结构评价：启动路径的「任何异常都不得阻塞 runApp」策略正确，`runZonedGuarded` + `ErrorWidget.builder` + 看门狗三件套齐备，注释解释了「为什么」（原生启动屏不会被首帧替换），符合第 31 条。

### 【P2】`client.t1` 的异步回填跨越了登录态世代，退出登录后可能把旧账号 t1 写回
```dart
SecureStorage.instance.readCredentials().then((c) {
  client.t1 = (c != null && c.userId == user.userid) ? (c.t1 ?? '') : '';
})...
```
- 事实：`ref.listen(authStateProvider)` 回调里发起异步读盘，回调返回时**没有再次校验当前登录态**。`user` 是闭包捕获的旧值；若用户在读盘期间退出登录（此时同回调已把 `client.t1 = ''` 清空），随后到达的 `.then` 仍会以「旧 user」通过 `userId` 校验并把旧 t1 写回 client。
- 违反：**第 18 条**（异步结果必须校验世代：「任何在等待之后写入共享状态的代码，必须先确认自己仍是当前有效的那一次」）；连带第 5 条（t1 的事实源同时是 SecureStorage 与 client 字段，两处可写）。
- 后果：退出登录后仍以旧账号 t1 发起请求 → 服务端可能返回旧账号的个性化/权益数据；用户看到「已退出但仍显示我的歌单」。属静默错误，定 P2（未直接造成数据泄露，但身份串扰）。

### 【P2】`_startupError` 为顶层可变全局，且 `StartupErrorPage` 分支缺少 localizationsDelegates
- 事实一：`Object? _startupError` 是文件级可变全局，在 `main()` 内被多次 `??=`/赋值，`build()` 直接读它。它不是 Provider，也不触发重建（依赖首帧前赋值才有意义），属于「同一事实两处存」（全局 + build 快照）。
- 事实二：`if (_startupError != null) return MaterialApp(home: StartupErrorPage(...))`——该 MaterialApp **未传** `localizationsDelegates` / `supportedLocales` / `theme`，而下方正常分支传了。
- 违反：第 5 条（状态单一来源）；第 8 条（回退路径与主路径的契约/形态必须一致——两条分支的 App 装配不一致）。
- 后果：错误页在非中文系统下仍是英文/中文混排的默认 Material 文案；且一旦后续有人在 StartupErrorPage 内使用 `context.l10n`，会直接抛 `No AppLocalizations found`（异常页再抛异常）。P2。

### 【P3】`StartupErrorPage` 内用户可见文案硬编码中文
- 事实：`'应用启动异常'`，以及 `main()` 里 `StateError('设备身份初始化失败')` 会经 `'$error'` 直接显示给用户。
- 违反：**第 30 条**（用户可见文案必须走 l10n）。此处有客观限制（ErrorWidget.builder 与早退分支都在 MaterialApp 之外，拿不到 l10n），代码注释已说明，故不升 P2。
- 后果：海外用户在崩溃页看到中文/中文异常串，无法自助判断。P3。

### 【P3】看门狗的「注册顺序」存在理论竞态，且 `_firstFrameRendered` 亦为全局
- 事实：`addPostFrameCallback` 先注册、`_watchdog = Timer(...)` 后赋值；回调执行时 `_watchdog` 才被 cancel。当前顺序（runApp 同步返回后才调度帧）下安全，但依赖「帧一定晚于本函数返回」这一隐式前提，代码未声明。
- 违反：**第 22 条**（并发/时序假设必须写明并在能保护处保护）。
- 后果：若将来有人在 runApp 后插入 `await`，可能出现「定时器已触发但回调里 cancel 的是 null」→ 误报「15 秒未渲染首帧」。日志噪音，P3。

### 【P3】`didChangeAppLifecycleState` 无 `mounted` 保护
- 事实：`ref.read(downloadManagerProvider.notifier).onAppLifecycle(state);` 直接调用，未判 `mounted`。
- 违反：第 20 条（异步/回调触及对象前须确认存活）。
- 后果：观察者在 `dispose` 中已移除，当前不会崩；但依赖「removeObserver 一定先于回调」的平台时序。P3（防御性）。

### 【P3】`_onPlayerError(String message, WidgetRef ref)` 参数命名遮蔽
- 事实：方法体只用到 `ref.context`；参数名 `ref` 与全局惯用名冲突，签名把「上下文」藏在 ref 里（应从调用处传 `BuildContext`）。
- 违反：第 30 条（命名即文档）；第 2 条（依赖显式）。
- 后果：阅读成本；无功能影响。P3。

### 【P3】`runApp` 被 try/catch 包裹
- 事实：`try { runApp(...) } catch (e) {...}`——`runApp` 本身几乎不抛（异常发生在后续 build 阶段，已由 ErrorWidget.builder 接管），此 catch 属于「捕获自己不知如何处置的异常」（第 7 条）。
- 违反：第 7 条（捕获必须精确到可处理的类型）。
- 后果：真正属于编程错误的参数非法会被吞成一行 debugPrint，无法在 release 观测。P3。

---

## 3. `lib/core/router/app_router.dart`（134 行，通读）

结构：`StatefulShellRoute.indexedStack` 四分支（home/search/library/settings）+ 9 条顶层路由；底部导航文案已走 `context.l10n`（历史问题已修，本次复核确认无残留硬编码）。

### 【P2】无 `errorBuilder`：任意无效深链/未知路径落到 go_router 默认英文错误页
- 事实：`GoRouter(...)` 未提供 `errorBuilder`。`initialLocation: '/home'` 只决定启动位置，不影响外部深链（`tiernanmusic://xxx`、误拼 `/libary`、旧版本已删除路由）。
- 违反：**第 14 条**（深链参数属数据边界，必须校验并有兜底）；**第 30 条**（默认错误页为英文 "Page Not Found"，用户可见文案未本地化）。
- 后果：用户从外部链接进入错误路径时看到英文调试页，且无「返回首页」出口，需杀进程。P2。

### 【P2】`/rank/:rankId` 用 `int.tryParse(...) ?? 0` 静默降级
- 事实：
```dart
rankId: int.tryParse(state.pathParameters['rankId'] ?? '') ?? 0,
name: state.uri.queryParameters['name'] ?? '',
```
非法 `rankId`（如 `/rank/abc`、`/rank/`）被替换成 `0` 后继续渲染页面，`name` 缺失与「空名字」合并成 `''`。
- 违反：**第 11 条**（降级必须有明确触发条件与退出条件——此处无触发日志、无用户提示、无恢复路径）；**第 16 条**（「缺失」与「空」必须语义分离）；**第 14 条**（边界校验）。
- 后果：`rankId=0` 会向服务端发出无效榜单请求，页面呈现「空榜单/一直转圈」，用户与日志都无法分辨「链接错了」还是「榜单确实为空」。P2。

### 【P3】路径参数一律用 `!` 强解
- 事实：`state.pathParameters['id']!`、`['type']!`、`['hash']!`。go_router 只在匹配成功时才调用 builder，故**当前**由框架契约保证非空，不构成第 12 条违规；但依赖未在代码中声明的框架契约。
- 违反：第 22 条（依赖前提必须写明）。
- 后果：go_router 升级或改用 `redirect` 阶段取值时会退化为空断言崩溃。P3。

### 【P3】`/comments/:type/:id` 的 `type` 未做枚举校验
- 事实：`resourceType: state.pathParameters['type']!` 直接透传字符串，由 CommentsPage 内部决定行为（见 §18）。
- 违反：第 14 条（边界校验）；第 3 条（契约先行：取值范围未在入口处约束）。
- 后果：`/comments/unknown/123` 会把非法类型带进评论接口，返回 4xx/空，页面表现为空列表。P3（若 CommentsPage 内部兜底则仅噪音）。

### 【P3】`appRouterProvider` 内 `ref` 未使用，且 GoRouter 无 dispose
- 事实：`Provider<GoRouter>((ref) { return GoRouter(...); })` —— `ref` 在体内零引用；未注册 `ref.onDispose(router.dispose)`。
- 违反：**第 32 条**（未使用的东西零容忍——至少是误导性参数）；**第 20 条**（申请的资源需对称释放；GoRouter 内部持有 ValueNotifier/RouteInformationProvider）。
- 后果：进程级 provider 不销毁，实践上泄漏为零；主要危害是阅读噪音与「看起来有人管生命周期」的错觉。P3。

### 观察（不计问题）
- `MainShell` 把 `MiniPlayer` 与 `NavigationBar` 放进 `bottomNavigationBar` 的 `Column(mainAxisSize: min)`，Scaffold 会据此计算 body 内边距，未发现溢出；`NavigationBar` 自带 48dp+ 触控区。

---

## 4. `lib/core/providers.dart`（25 行，通读）

### 【P2】核心层反向依赖业务模块（分层回流）
- 事实：`import '../features/lyric/data/lyric_repository.dart';`，并在 `core/` 内定义 `lyricRepositoryProvider`。`core` 是底层，`features/lyric` 是业务层。
- 违反：**第 4 条**（「底层不得知道上层……发现回流即为架构级缺陷」）。
- 后果：`core` 无法独立于业务编译/测试；`features/lyric` 的构造签名一变，`core/providers.dart` 全部依赖方（包括非歌词模块）都被迫重新编译。功能上不直接可见 → 按分级纪律定 P2（架构级，非用户可见）。

### 【P3】`translateApiProvider` / `lyricRepositoryProvider` 未注册 dispose
- 事实：`Provider<TranslateApi>((ref) => TranslateApi())`——`TranslateApi` 内部若持有 `Dio`（其 `close()` 需显式调用），provider 销毁后连接池不释放。
- 违反：**第 20 条**（生命周期双向对称）。
- 后果：这两个 provider 是全局长生命，实际泄漏为零；但若将来被 `autoDispose` 化或加入 `ref.watch` 动态依赖，会出现未关闭 HttpClient 的连接堆积。P3。

### 【P3】`lyricRepositoryProvider` 用 `ref.watch(kugouApiClientProvider)`，客户端一变即重建仓库
- 事实：`watch` 而非 `read`。`kugouApiClientProvider` 上游是 `kgDirectApiProvider`，任何触发其重建的动作（登录/设备切换）都会重建 `LyricRepository`，仓库内的内存缓存与在途状态一并丢弃。
- 违反：第 5 条（状态单一来源被「重建即清空」破坏）；第 23 条（缓存维度未显式化——身份变化本应作为缓存键，而不是销毁缓存）。
- 后果：登录后歌词需重新解析/重新翻译，弱网下用户看到歌词闪空。P3。

### 观察（不计问题）
- 注释明确解释「不要建第二个顶层 ProviderContainer」及其原因（第 31 条范例）。

---

## 5. `lib/core/config/app_config.dart`（42 行，通读）

### 【P1】第三方中转域名被固化为 **默认** API 基址，且无原因说明、无清理计划
- 事实：
```dart
static const String kugouApiBase  = 'https://kapi.344977.xyz';
static const String proxyBase     = 'https://proxy.344977.xyz';
```
两个都不属于服务提供方原生域名。`core/providers.dart` 的注释称「默认直连酷狗网关，未移植路径自动回退 kapi」，但**配置文件里 kapi 就是 `kugouApiBase`**，全仓任何 `AppConfig.kugouApiBase` 的调用点拿到的都是中转域名；此外没有任何注释写明「哪些路径尚未移植」「何时清理」。
- 违反：**第 27 条**（「任何第三方中转网关不得作为实现，仅可作为尚未移植路径的显式兜底，且必须在代码中写明原因与清理计划。中转网关一旦成为主路径，项目就失去了对协议的控制权与可测试性」）；**第 31 条**（反常用法必须记录原因）；**第 2 条**（魔法域名应源自单一可切换配置而非散落常量）。
- 后果：用户播放/登录/下载的全部流量默认经第三方主机，隐私与可用性完全受制于该主机；主机下线即全功能失效，且客户端无法切换到直连（域名写死、无远程开关）。核心功能级风险 → **P1**。

### 【P2】`supportedLocales` 与 `AppLocalizations.supportedLocales` 双源，且顺序/集合不一致
- 事实：本文件硬编码 10 项 `['zh_CN','zh_TW','en','ja','ko','es','fr','de','pt','ru']`；`MaterialApp.router` 实际使用的是 `AppLocalizations.supportedLocales`（由 `l10n.yaml` 生成的 arb 列表得出）。同时 `lib/l10n/` 下存在 **11** 个 arb（多一个裸 `app_zh.arb`）。
- 违反：**第 5 条**（同一事实只能有一处权威存储；两处必然最终不一致——现在就已经不一致：10 vs 11）；**第 23 条**（语言作为影响结果的维度未收敛）。
- 后果：设置页语言列表（若读 `AppConfig.supportedLocales`）与系统实际可解析语言集合不一致：多出的 `app_zh.arb` 对应的语言在 UI 中不可选却在产物中，裸 `zh` 与 `zh_CN` 同时存在时「简体」的匹配结果依赖于解析顺序。用户可能选到某语言后界面部分回落中文/英文。P2。

### 【P3】`platform = ''` 空字符串魔法值
- 事实：`static const String platform = '';` 注释只说「kugou 标准版」，空串的真实含义（不发送该参数？发送空值？）无法从代码读出。
- 违反：第 2 条（魔法值必须有具名常量/显式语义）；第 15 条（单位/取值域必须显式）。
- 后果：任何「以为空串=默认」的调用点都可能与实测行为相反，参数形态错误在本项目属静默失败（第 28 条）。P3。

### 【P3】`appName` / `appNameCn` 与 l10n 的 `appName` 三处重复
- 事实：`AppConfig.appName='Tiernan Music'`、`appNameCn='汀澜音乐'`，而 arb 内亦有 `appName` 且 `onGenerateTitle` 取的是 l10n 版本。`appNameCn` 在本次审查范围内未见被引用。
- 违反：第 5 条（双源）；第 32 条（疑似死代码）。
- 后果：改名时三处需同步，漏改即出现「启动器名与任务栏名不一致」。P3。

---

## 6. `lib/core/widgets/`（10 个文件，逐个通读）

### 6.1 共性问题（跨文件）

**【P3】6 个文件存在未使用 import（死代码）**
| 文件 | 未使用 | 说明 |
|---|---|---|
| `empty_state.dart` | `dart:async`、`../utils/toast.dart` | 文件内无 Timer/Future/Toast |
| `gradient_chip.dart` | `dart:async`、`../utils/toast.dart`、`../../l10n/l10n.dart` | 文件内无 l10n 调用、无 Toast |
| `list_skeleton.dart` | `dart:async`、`../utils/toast.dart`、`../../l10n/l10n.dart` | 同上 |
| `section_header.dart` | `dart:async`、`../utils/toast.dart`、`../../l10n/l10n.dart` | 同上 |
| `song_tile.dart` | `dart:async`、`../utils/toast.dart`、`gradient_chip.dart`、`empty_state.dart`、`error_retry.dart` | 后三者只出现在 `export` 指令里，import 本身未使用 |
| `error_retry.dart` | `dart:async` | 无异步原语 |
- 违反：**第 32 条**（未使用的导入零容忍）。
- 后果：读者误以为这些 widget 依赖 Toast/l10n（实际文案由调用方注入），修改 Toast 签名时不敢动；IDE 每次打开都报灰。P3。

**【P3】4 个文件尾部残留「下一个类」的孤立文档注释（复制粘贴残留）**
- 事实：`empty_state.dart` 末行 `/// 统一错误重试 …`；`gradient_chip.dart` 末行 `/// 统一加载骨架（带微光动画）`；`list_skeleton.dart` 末行 `/// 统一空态（图标 + 文案 + 可选按钮）`；`song_tile.dart` 末行 `/// 统一的分区标题（设置页 / 音乐库 / 首页共用）…`；`shimmer.dart` 中无此问题但 `song_tile.dart` 结尾注释里还提到 `[PopupMenuButton]` 之外的实现细节。
- 违反：**第 32 条**（注释掉的实现/遗留半成品）；**第 31 条**（注释与实际代码不符——注释描述的类不在本文件）。
- 后果：dartdoc 生成时这些悬空注释会挂到相邻符号上，产生错误文档；读者会去找一个不存在的类。P3。

**【P3】import 顺序混乱（相对导入置于 `dart:` 之前）**
- 事实：`list_skeleton.dart` 首两行 `import 'shimmer.dart';` 后才是 `import 'dart:async';`；`song_tile.dart` 首行是 `cached_network_image` 再 `dart:async`。
- 违反：第 30 条（工程一致性属命名/组织可读性）；`flutter_lints` 的 `directives_ordering` 未启用。
- 后果：合并冲突与人工扫描成本。P3。

### 6.2 `song_tile.dart`（214 行）

**【P2】`SongTile` 文件承担 4 类职责，并伪装成 barrel 出口**
- 事实：文件内同时存在 ①`SongTileMenuItem` ②`SongTile` ③一长串 `export 'section_header.dart'; export 'gradient_chip.dart'; export 'list_skeleton.dart'; export 'empty_state.dart'; export 'error_retry.dart';` ④尾部另一组件的文档注释。`export` 夹在 import 之间。
- 违反：**第 1 条**（一个文件应有且只有一个改变的理由）；**第 2 条**（依赖应显式：调用方 `import 'core/widgets/song_tile.dart'` 却意外获得 5 个组件的符号，属于隐式依赖）；**第 32 条**（export 出去的 5 个文件里有 3 个在本文件完全未使用）。
- 后果：任何改动 `empty_state.dart` 的导出名都会「经由 song_tile.dart」把编译错误散布到无关页面；重构时无法判断真实依赖方向。P2（架构/维护，非用户可见）。

**【P3】时长格式化：分钟位 `padLeft(1,'0')` 等于不补零，且 ≥1 小时时无小时段**
- 事实：`'${(sec ~/ 60).toString().padLeft(1, '0')}:${(sec % 60).toString().padLeft(2, '0')}'` → 5 分 3 秒显示 `5:03`（不是 `05:03`），3725 秒显示 `62:05`（不是 `1:02:05`）。
- 违反：**第 15 条**（单位与表示必须显式且全程一致）；**第 17 条**（时长精度表示必须选定一种并保持）。
- 后果：播客/有声书/MV 类长音频列表里出现 `62:05` 这类非标准时码，用户误读为 62 分钟歌曲。P3（列表项次要信息）。

**【P3】菜单项文本未做溢出保护**
- 事实：`PopupMenuItem` 的 `Row(children:[Icon, SizedBox, Text(item.label)])` 中 `Text` 未包 `Flexible`/未设 `overflow`。
- 违反：第 X 条布局稳定性 —— 具体为**第 24 条**（构建函数应是纯的、可预期的；此处依赖「文案一定短」的隐式假设）；更直接对应任务书 D 项「Row 溢出」。
- 后果：德语/俄语长菜单项（如「Zur Wiedergabeliste hinzufügen」）在窄屏或大字号下抛 `A RenderFlex overflowed by N pixels` 黄黑条。P3（PopupMenuItem 宽度受屏幕约束，实测多数情况会换行到裁剪）。

**【P3】`isPlaying` 仅用颜色区分，无可访问性语义**
- 事实：`color: isPlaying ? primary : null`，无 `Semantics(label: '正在播放')`、无图标。
- 违反：第 X 条 → **可访问性**（任务书 G 项），对第 30 条「名称/状态须可表达」的延伸；色弱用户无法识别。
- 后果：TalkBack 用户听到的条目与其它条目完全一致，无法判断当前播放曲。P3。

### 6.3 `shimmer.dart`（151 行）

**【P2】无限循环动画不响应系统「减弱动态效果」**
- 事实：`enabled` 参数注释写明「用于 prefers-reduced-motion 场景」，但**全仓没有任何调用方传入它**，也没有读取 `MediaQuery.disableAnimations` / `accessibleNavigation`；`_controller.repeat()` 无条件启动（3 秒一轮）。
- 违反：**第 11 条**（降级路径必须由明确触发条件驱动——此处通道存在但从不触发，等于没有）；**第 32 条**（无写入者的开关即死配置）。
- 后果：开启系统「移除动画」的用户在前庭功能障碍场景下仍被强制播放全屏扫光动画（骨架屏常占满列表区）。属可访问性缺陷 → P2。

**【P3】每帧创建 `ShaderMask` + `LinearGradient`**
- 事实：`AnimatedBuilder` 的 builder 内每帧 `LinearGradient(...).createShader(bounds)`。
- 违反：**第 26 条**（热路径零分配）。
- 后果：骨架屏期间每帧 new 一个 Shader 对象；中低端机滚动加载时掉帧。仅在加载态出现，P3。

### 6.4 `error_retry.dart`（248 行）

**【P2】`error == null && message == null` 时渲染空白卡片**
- 事实：`errorClassification` 在 `error == null` 分支返回 `FriendlyError(friendly: '', hint: '', ...)`；`ErrorRetry` 的 `friendly = message ?? c.friendly` → 空串。此时页面只剩一个感叹号图标 + 「重新加载」按钮，主副文案都是空 `Text`。
- 违反：**第 16 条**（「没有错误」与「错误但没有文案」被压成同一空值）；**第 9 条**（失败必须有可观测反馈）。
- 后果：调用方忘记传 `message`/`error` 时，用户看到无任何说明的报错页，无法判断是否网络问题。P2（提供 `errorClassification` 公共 API，误用概率不低）。

**【P3】`ApiException.message` 直接作为用户可见主文案，与文件头「绝不展示原始异常」的约定冲突**
- 事实：`if (error is ApiException) return FriendlyError(friendly: error.message, ...)`。该 message 来自服务端错误串（多为中文/英文原文），未经 l10n。
- 违反：**第 8 条**（同一层对外失败形态必须统一：Dio 分支给本地化文案，Api 分支给原始串）；**第 30 条**（用户可见文案未本地化）。
- 后果：俄语/日语界面下弹出一句中文服务端错误。P3。

**【P3】`_CopyableText` 的点击区无 48dp 保证、无语义**
- 事实：`GestureDetector(behavior: opaque, onTap: copy, child: Text(...))`，`bodySmall` 单行高度约 16–18dp；未加 `Semantics(button: true, label: ...)`。
- 违反：任务书 G 项（48dp 触控目标）→ **第 30 条**（意图须可被辅助技术表达）。
- 后果：用户难以点中复制，TalkBack 不会播报「可复制」。P3。

### 6.5 `gradient_chip.dart` / `section_header.dart` / `list_skeleton.dart` / `empty_state.dart` / `confirm_dialog.dart` / `animated_svg_logo.dart` / `splash_screen.dart`

**【P3】`GradientChip` 高度约 36dp，低于 48dp 触控标准；标签无 ellipsis**
- 事实：`EdgeInsets.symmetric(horizontal: 14, vertical: 8)` + `bodyMedium` 文本 ≈ 36dp 高；`Text(label)` 无 `maxLines`/`overflow`，`Ink` 内宽度随内容增长。
- 违反：任务书 G 项 48dp（可访问性，P2 上限，但热门搜索常用横向滚动条，误触成本低）；第 X 条布局 → 长标签在 `Wrap` 外单独使用时会撑破父约束。
- 后果：手指难以精确点中相邻 chip；德语长标签在窄屏 `Row` 中溢出。P3。

**【P3】`GradientChip` 渐变底色为 `HSL(l=0.42)` 全覆盖白字，部分色相（黄/青绿）对比度不足 4.5:1**
- 事实：饱和度固定 0.65、亮度固定 0.42，白字 `Colors.white`。色相 60–90（黄绿）在白字下亮度差最小。
- 违反：任务书 G 项（对比度）；第 2 条（颜色本应由主题 token 派生，此处为魔法值）。
- 后果：强光下热门搜索标签读不清。P3。

**【P3】`AnimatedSvgLogo` 对 `widget.duration` 的后续变更无响应**
- 事实：`AnimationController(duration: widget.duration)` 只在 `initState` 建一次；无 `didUpdateWidget`。且 `_curve` 是 `CurvedAnimation`，未在 dispose 中单独 dispose（`CurvedAnimation` 需 `dispose` 才会释放对 parent 的监听）。
- 违反：**第 20 条**（申请的资源须对称释放：`CurvedAnimation` 持有 parent listener）。
- 后果：当前 parent 与 curve 同生命周期，无实际泄漏；若将来复用该 widget 并热切换 duration，动画时长不更新。P3。

**【P3】`AnimatedSvgLogo` 默认资源名 `assets/audiomack.svg`**
- 事实：默认值指向第三方品牌名文件；本应用品牌为 Tiernan。
- 违反：**第 30 条**（命名即文档：资源名与产品不符）；**第 31 条**（未记录该资源来源/许可）。
- 后果：品牌与法务层面存在误用风险（若该 SVG 确为第三方标识）；同时读者无法判断该默认值是否仍在使用。P3（需人工确认资产来源，见待确认事项）。

**【P3】`SplashScreen` 硬编码 `'汀澜音乐'`**
- 事实：启动页标题写死中文，未用 `context.l10n.appName`。
- 违反：**第 30 条**（用户可见文案必须走 l10n）。此处为品牌名，可辩解；但同仓 `AppConfig.appName` 与 arb `appName` 已有三个来源（见 §5）。
- 后果：非中文用户在启动页看到中文字样，与随后切换的界面语言不一致。P3。

**【P3】`EmptyState` 把「加载中/失败/空」压给调用方，自身无默认文案**
- 事实：`message` 必填、`actionLabel` 与 `onAction` 必须同时非空才渲染按钮，否则按钮静默消失（无断言、无日志）。
- 违反：**第 16 条**（缺失与空不分离）；**第 11 条**（降级无提示）。
- 后果：调用方只传 `actionLabel` 忘记传 `onAction` 时，用户看不到任何行动入口且无人知晓。P3。

**【观察/合规】`confirm_dialog.dart`**：`showDialog<bool>` + `pop(false)/pop(true)` + `ok == true` 处理 barrier dismiss，生命周期与返回值语义正确；危险操作使用 error 色与 `FilledButton` 符合 M3。**未发现问题**。

**【观察】`section_header.dart` / `list_skeleton.dart`**：`Expanded` + `Column` 包裹标题，长标题换行不溢出；`ListSkeleton` 的 `Row` 中 `Expanded` 保护到位。除未使用 import 与尾部悬空注释外无布局问题。

---

