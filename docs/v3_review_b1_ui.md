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

## 7. `lib/features/auth/presentation/login_page.dart`（731 行，通读）

结构评价：三种登录方式（短信/密码/二维码）分别独立 State，`TextEditingController`、`Timer`、`TabController` 均在 `dispose` 中释放；异步后 `mounted` 守卫齐备；登录成功统一 `context.go('/home')` 清栈。**生命周期主体合规（第 20 条）**。问题集中在轮询失败处理与布局。

### 【P2】二维码轮询：空 catch + 无退避 + 无次数上限
```dart
} catch (_) {
  // 轮询失败忽略，下次再试
}
```
- 事实：`_checkOnce` 把**所有**异常（含 `TypeError` 等编程错误）一律吞掉，不写日志、不计数、不改状态；`_pollOnce` 随后无条件 `_scheduleNextPoll()`（固定 3 秒）。无失败上限、无指数退避、无「网络异常」提示。
- 违反：**第 6 条**（禁止吞掉异常：至少转译/记录/降级其一）；**第 7 条**（捕获必须精确到可处理的类型）；**第 10 条**（编程错误不得进入业务降级）；**第 25 条**（重试次数必须有上限）；**第 9 条**（失败必须可观测）。
- 后果：服务端 500 或证书问题时，页面停在「等待扫码」，每 3 秒静默发一次请求直到用户离开，用户既不知道失败也不知道原因；线上也无法统计二维码登录失败率。P2。

### 【P2】短信登录页 `Row(TextField, FilledButton)` 在大字号下会溢出
- 事实：
```dart
Row(children: [
  Expanded(child: TextField(...)),
  const SizedBox(width: 12),
  FilledButton.tonal(child: Text(_countdown > 0 ? l.resendIn(_countdown) : l.sendSmsCode)),
])
```
右侧按钮**没有** `Flexible`/`ConstrainedBox`，其固有宽度 = 文案宽度 + 内边距。`resendIn(60)` 的俄语/德语译文（如「Отправить повторно через 60 с」）在 `textScaleFactor 1.3` 以上即可能超过行内剩余空间，而 `Expanded` 的 TextField 最小宽度有限。
- 违反：任务书 D 项（布局/字体放大适配）→ **第 24 条**（构建必须纯且可预期：此处隐含「文案一定短」的假设）；任务书 G 项（可访问性：系统字号放大必须可用）。
- 后果：安卓「字体大小=最大」或「显示大小=大」时，短信登录页抛 `A RenderFlex overflowed by X pixels`，按钮文案被裁切，用户看不到「发送验证码」。P2。

### 【P3】二维码失败文案把原始异常拼进用户可见文本
- 事实：`_error = context.l10n.qrLoadFailed('$e')` → 直接把 `DioException [connection error]…` 塞进 UI；同文件 `_showError` 已实现 `unwrapApi`/`friendlyError` 的友好化路径，此处绕开。
- 违反：**第 8 条**（同一层失败形态必须统一）；**第 30 条**（用户可见文案未经本地化/友好化）。
- 后果：弱网用户看到英文技术串。P3。

### 【P3】`_showError(BuildContext, Object e)` 同时接收 String 与异常
- 事实：`_showError(context, context.l10n.phoneInvalid)` 传的是**已本地化的文案**，而其它调用点传的是异常对象；函数内 `unwrapApi(e)`/`friendlyError(e)` 对 String 只能落到兜底分支。
- 违反：**第 3 条**（契约先行：参数取值范围未定义）；**第 2 条**（同一入口承载两种语义，隐式转换）。
- 后果：某天 `friendlyError` 对 String 返回非空时，本地化文案会被覆盖成通用错误；行为依赖实现细节。P3。

### 【P3】手机号校验硬编码中国大陆段 `^1\d{10}$`，且提示文案键名为 `phoneHintCn`
- 事实：`RegExp(r'^1\d{10}$')`；hint 用 `context.l10n.phoneHintCn`。而 `AppConfig.supportedLocales` 声明支持 10 种语言/地区。
- 违反：**第 14 条**（边界校验规则应与业务契约一致，而非按单一地区写死）；**第 30 条**（键名把地区绑进语义）。
- 后果：非中国大陆号码用户在 10 语言界面下无法通过校验，且提示仍是中国号码格式。P3（产品定位为非官方酷狗客户端，可接受，但应有明确说明）。

### 【P3】`_QrLoginTab` 状态码 0/1/2/4 为裸魔法数
- 事实：`int _status = 1; // 0过期 1待扫 2待确认 4成功`，全文件用数字比较；无 enum。
- 违反：**第 2 条**（魔法值必须有具名常量）。
- 后果：新增状态（如 3=已取消）时遗漏分支不会被编译器发现，界面停留在旧文案。P3。

### 【观察/合规】
- `TabController` 监听匿名函数在 `dispose()` 前未 `removeListener`，但 `TabController.dispose()` 会清空监听器，**不构成泄漏**。
- `_countdown` 的 `Timer.periodic` 在 `dispose` 中 `cancel`，回调内 `t.cancel()` 自带终止条件，双向对称。
- 二维码 `_pollOnce` 采用「上次完成再排下一次」的自驱动链，避免慢网重叠请求——符合第 19 条精神。
- `AutomaticKeepAliveClientMixin` 的 `wantKeepAlive` + `didUpdateWidget` 暂停非活动 Tab 轮询，设计正确。

---

## 8. `lib/features/auth/presentation/captcha_page.dart`（439 行，通读）

### 【P2】整页用户可见文案硬编码中文（约 18 处），且验证码 WebView 内嵌中文 UI
- 事实（逐处）：`'人机验证'`（AppBar）、`'重试'`、`'短信验证'`、`'请输入接收到的验证码完成验证'`、`'验证码'`/`'6 位数字'`（InputDecoration）、`'提交验证'`、`'该验证类型需要在酷狗官方 App 内完成。\n建议：…'`、`'关闭'`、`'未知验证类型（v_type=${s.vType}）'`、`'直接尝试提交指纹验证'`、`'验证未通过，请重试'`、`'验证已通过，但请求仍需重试'`、`'提交失败：$e'`、`'获取验证信息失败：$e'`、`'如验证码未自动弹出，请点击页面中的「开始验证」'`，以及 `_tencentHtml` 中的 `'开始验证'`、`'完成滑块后自动继续'`。
- 违反：**第 30 条**（用户可见文案必须走 l10n；本页是全仓硬编码最密集的一页）。
- 后果：10 语言用户在**登录**这一必经路径上看到整页中文；`_tencentHtml` 的按钮文案连 HTML 内也未参数化。功能可用但界面语言断裂，定 P2（任务书 E 项重点）。

### 【P2】WebView 回调与 `onLoadStop` 中 `setState` 无 `mounted` 守卫
- 事实：
```dart
onLoadStop: (_, __) => setState(() => _webViewReady = true),
...
callback: (args) { ... _submitWithCode(s, code); }
```
`_submitWithCode` 首行即 `setState(() => _submitting = true)`。
- 违反：**第 20 条**（异步回调触及已销毁对象前必须确认存活）。
- 后果：用户在腾讯验证码加载/滑块完成瞬间按返回键关闭页面 → `setState() called after dispose()` 抛异常（`_QrLoginTab` 等处都有 `mounted` 守卫，此处独缺），登录流程变成红屏或静默中断。P2。

### 【P2】`_buildExternal` / `_buildUnknown` 的 `Column` 不可滚动
- 事实：两者均为 `Padding(child: Column(mainAxisAlignment: center, …))`，无 `SingleChildScrollView`；`_buildSms` 反而有。外部分支文本含两行中文 + 24dp 间距 + 按钮 ≈ 260dp 内容高度。
- 违反：任务书 D 项（字体放大适配）；**第 24 条**（构建结果应为约束内可预期）。
- 后果：横屏或系统字号放大到 2.0 时 `RenderFlex overflowed`，`_buildUnknown` 的「直接尝试提交指纹验证」按钮被顶出屏幕且无法滚动到。P2。

### 【P3】错误文案拼接原始异常
- 事实：`_error = '获取验证信息失败：$e'`、`_snack('提交失败：$e')` —— 用户直接看到 `DioException [connection error]…`。
- 违反：**第 9 条**（失败须可观测，但观测对象是日志而非用户）；本项目 `error_retry.dart` 已确立「不展示原始异常」的约定 → **第 8 条**（失败形态须统一）。
- 后果：弱网用户看到英文技术串，无法据此行动。P3。

### 【P3】`txappid` 缺失时静默退化为「未知验证类型」
- 事实：`_extractTxAppId` 返回 null → `_buildUnknown`，无日志、无提示说明为何不是滑块验证。
- 违反：**第 11 条**（降级必须有明确的触发条件与留痕）。
- 后果：腾讯验证码接口若改参数名，用户只会看到「未知验证类型」页，开发者无从得知是解析失败。P3。

### 【P3】`_buildUnknown` 的 `if (s.vType >= 0)` 作为「是否允许提交」条件
- 事实：`vType` 是服务端整数，`>= 0` 恒真（除非 -1 表示缺失），且与「能否直接提交指纹」无因果关系。
- 违反：**第 2 条**（魔法判断）；**第 3 条**（契约未定义）。
- 后果：该按钮在几乎所有情况下都会出现，点击后提交 `null` verifycode 大概率失败，用户被引导做无意义操作。P3。

### 观察（合规）
- `InAppWebView` 由 widget 自身管理生命周期；`_smsCodeCtrl` 在 `dispose` 释放；`_submitWithCode` 用 `if (_submitting) return;` 做了防重（第 21 条）。
- `switch (s.type)` 覆盖了枚举全部成员，无遗漏分支。

---

## 9. `lib/features/settings/presentation/settings_providers.dart`（63 行，通读）

### 【P2】从 Hive 读出的值用裸 `as String?` / `as bool?` 强转
```dart
super((_box()?.get('defaultQuality', defaultValue: '320') as String?) ?? '320');
super((_box()?.get('wifiAutoHighQuality', defaultValue: true) as bool?) ?? true);
```
- 事实：Hive 返回 `dynamic`；历史版本若把 `defaultQuality` 存成 `int`（或 `wifiAutoHighQuality` 存成 `'true'` 字符串），`as` 会抛 `_TypeError`。该异常发生在 **Notifier 构造函数**内，即 `Provider` 创建期，`settings_page` 的 `ref.watch(defaultQualityProvider)` 直接抛出。
- 违反：**第 13 条**（本地存储返回的数据禁止裸类型强转，必须逐一分支验证）；**第 14 条**（磁盘读取属数据边界，必须校验）。
- 后果：升级安装（v2→v3 的同名 box）或写入过异常值的设备，进入设置页/播放页即崩，且用户无法通过界面恢复（只能清数据）。P2（装机量中的老用户都会命中）。

### 【P3】`_box()` 的 `catch (_) {}` 为空捕获
- 事实：注释说明「绝不抛异常」，但异常既未记录也未降级统计。
- 违反：**第 6 条**（捕获必须至少记录/转译/降级之一）。这里的降级是「返回 null」，但失败原因永久丢失。
- 后果：settings box 打不开时，所有设置静默回落默认值且每次启动都被重置，用户抱怨「设置不保存」，日志里什么都没有。P3。

### 【P3】`state` 先改、磁盘后写，失败无回滚、无提示
- 事实：`set()` 先 `state = quality` 再 `await _box()?.put(...)`；若 box 为 null（见上）或 put 抛错，UI 显示已保存、重启后丢失。
- 违反：**第 5 条**（同一事实两处存且可各自变更）；**第 9 条**（失败必须可观测）。
- 后果：「音质选 FLAC、重启变 320」。P3（对用户可感知但影响小）。

### 【P3】两个「预留策略开关」的 provider 没有任何消费方
- 事实：`wifiQualityProvider` / `cellularQualityProvider` 的文档注释自称「（预留策略开关）」；本批通读的 `settings_page.dart` 只负责写，读侧在 `player` 模块。本次通读范围内（settings/player UI、core）**未见任何读取方**。
- 违反：**第 32 条**（「仅供以后可能」的状态零容忍）；**第 11 条**（降级开关必须真实生效）。
- 后果：用户在设置里切换「WIFI 下自动最高音质」，播放行为毫无变化——这是**可见的假开关**。若 player 层确有读取，请以此条为「待确认」并降级为 P3。P2（若确认无消费方）。

---

## 10. `lib/features/settings/presentation/settings_page.dart`（1010 行，通读）

正面评价：`_logDirPath` / `_storageGranted` 提为字段避免 FutureBuilder 无限重建（注释写明「为什么」，第 31 条范例）；`_dirSizeBytes` 移入 `compute` isolate；危险操作用 `showDestructiveConfirm`；错误文本不再直出。这些历史问题确已修复。

### 【P2】语言选择列表读 `AppConfig.supportedLocales`（10 项），与实际 l10n 语言集（11 个 arb）不一致
- 事实：`itemCount: AppConfig.supportedLocales.length + 1`，选项来自 `AppConfig.localeNames`。而 `MaterialApp` 的 `supportedLocales` 来自 `AppLocalizations.supportedLocales`（由 `l10n.yaml` 扫描 arb 得出，含裸 `zh` 共 11 项）。
- 违反：**第 5 条**（同一事实两处权威源，已经不一致）；**第 23 条**。
- 后果：`app_zh.arb` 对应的语言在设置里不可选（可接受），但「跟随系统」在系统语言为 `zh`（无地区）时，解析结果取决于 Flutter 的 locale 匹配顺序 → 界面可能落到 `zh` 资源而设置页显示「简体中文」，两者不一致；更危险的是新增语言只加 arb 忘了改 `AppConfig`，则该语言用户无法主动选择。P2。

### 【P2】系统语言选项复用了 `themeSystem` 文案（「跟随系统」被用于两个不同维度）
- 事实：`_showLocaleDialog` 中 `title: Text(context.l10n.themeSystem)` —— 语言列表的「系统默认」项显示的是**主题**的 system 文案。
- 违反：**第 30 条**（名称必须表达意图；同一 key 承载两种语义）。
- 后果：德语/俄语等语言里 `themeSystem` 可能是「Systemdesign」，出现在语言列表里语义错乱，用户不知道这是「跟随系统语言」。P2（i18n 语义错误）。

### 【P2】三处 `SegmentedButton` 在字体放大时仍会溢出（缓解不彻底）
- 事实：主题（浅色/深色/跟随系统）、歌词模式（原文/双语/翻译）均只做了 `visualDensity: compact` + `padding: horizontal 8`；`SegmentedButton` 内部是 `Row`，**不滚动、不折行**，段宽 = 文案宽度 + padding。中文在 `textScaleFactor 2.0` 下「跟随系统」四字 ≈ 4×32dp=128dp，三段 > 360dp；德语「Übersetzung」同理。
- 违反：任务书 D 项（字体放大适配）；**第 24 条**（构建必须可预期）。
- 后果：安卓「字体最大」+ 小屏（320–360dp）时设置页顶部直接出现黄黑溢出条，第三段被裁切，用户点不到「跟随系统」。P2。

### 【P2】「检查更新」下载链接未校验即 `Uri.parse`，且优先使用「加速地址」
- 事实：
```dart
final url = info.acceleratedUrl ?? info.downloadUrl;
...
final uri = Uri.parse(url);
if (!await canLaunchUrl(uri)) ...
```
`url` 来自远端 JSON（`UpdateChecker`），属外部数据；`Uri.parse` 对畸形串抛 `FormatException`，此处无 try（外层 try 已结束，该回调在 Dialog 内）。
- 违反：**第 13 条 / 第 14 条**（外部数据必须校验）：未校验 scheme 是否 https、未校验 host、未校验 `Uri.tryParse` 结果；**第 27 条**：「加速地址」若仍是第三方中转域名，更新包分发也脱离了发布方控制（更新链路被劫持 = 可下发任意 APK）。
- 后果：更新描述 JSON 被污染或服务端配错时，点击「立即下载」抛未捕获异常（红屏/无响应）；更严重的是从非官方「加速」域名下载 APK 并引导安装。P2（建议升 P1，取决于加速域名的归属，列入待确认）。

### 【P3】`_clearCache` 失败提示传空串占位
- 事实：`Toast.show(context, context.l10n.clearCacheFailed(''))` —— 文案里的占位参数为空，用户看到「清除缓存失败：」后什么都没有。
- 违反：**第 16 条**（缺失与空未分离）；**第 9 条**（失败不可行动）。
- 后果：用户不知道失败原因（其实已 debugPrint 到日志，但界面无指引）。P3。

### 【P3】清缓存过程非原子，中途异常导致「清了一半」
- 事实：`MemoryCache.clear()` → `LyricTranslationCache.clear()` → 逐个 Hive box `clear()` → 递归删临时目录，全部串行且共用一个 try。任一环节抛错即跳到 catch，**前面的已生效、后面的未执行**。
- 违反：**第 21 条**（写操作幂等/防重精神：此处应逐项隔离并汇总结果）。
- 后果：用户看到「清除缓存失败」，但实际清掉了歌词翻译、没清图片缓存，缓存大小显示不变 → 反复点、反复半清。P3。

### 【P3】`_dirSizeBytes` 用 `listSync(recursive: true)` 一次性物化整个目录
- 事实：`Directory(path).listSync(recursive: true, followLinks: false)` 返回 `List<FileSystemEntity>`，先全部枚举再遍历。
- 违反：**第 25 条**（无上限的枚举；缓存目录文件数可达数万）。
- 后果：虽在 isolate 中不卡 UI，但会在低内存设备上瞬时占用数 MB 并可能 OOM（isolate 崩溃 → `_cacheSize` 停在「计算中」）。P3。

### 【P3】`_loadVersion` / `_loadAccount` / `_checkUpdate` 的失败处理不同步
- 事实：`_loadVersion` 无 try（`PackageInfo.fromPlatform()` 失败 → 未捕获异步异常，`_version` 永久为空，只显示 `-`）；`_loadAccount` 用 `catch (_)` 静默置 null；`_checkUpdate` 只 Toast 不记日志。
- 违反：**第 8 条**（同层失败形态必须统一）；**第 6 条**（`catch(_)` 无留痕）；**第 9 条**（失败须可观测）。
- 后果：版本号缺失时「关于」页永远显示「版本 -」，用户以为安装包损坏；更新检查失败无日志，线上无法统计。P3。

### 【P3】`FlutterSecureStorageCompat` 直接 `Hive.box('settings')` 无 `isBoxOpen` 守卫
- 事实：`final box = Hive.box('settings');` —— 而 `main.dart` 明确容忍 `openBox('settings')` 失败（`openSafe` 只打印日志）。二者契约不一致。
- 违反：**第 8 条**（回退路径与主路径形态不一）；**第 12 条**（此处虽非 `!`，但等价于假定 box 必然存在）。
- 后果：settings box 打开失败时，`readAccounts` 抛 `HiveError`，`_loadAccount` 捕获后账号区显示「未登录」——已登录用户被显示成未登录，且无任何解释。P3。

### 【P3】细节整洁度
- `static String _formatBytes(int bytes) {    if (bytes < 1024)` —— 大括号后同一行接代码，未格式化（`dart format` 未跑）。
- `_qualityNames(context)` 每次 build 重建 Map（第 26 条，可忽略）。
- `_navTile` 的 `subtitle` 无 `maxLines`，长译文在 `ListTile` 内换行导致行高跳变（可接受，P3 边缘）。

---

## 11. `lib/features/library/presentation/library_page.dart`（653 行，通读）

正面评价：`_authSub` / `_recentSub` 均在 `dispose` 取消（第 20 条达标）；登录态变化时 `invalidate` 歌单与 MV 收藏（第 18 条世代意识）；`_loadRecent` 失败留痕并降级为空列表（第 6/9 条）；列表区块均 `take(20)` 有上限（第 25 条）。**生命周期与状态刷新是本批质量最好的文件。**

### 【P2】`_currentAccount()` 用 `catch (_) { return null; }` 把「读取失败」伪装成「未登录」
```dart
AccountRecord? _currentAccount() {    try { return AccountManager.instance.currentAccount; }
  catch (_) { return null; } }
```
- 事实：异常被完全吞掉（无日志），返回值 `null` 在 UI 上与「未登录」同义 → 渲染「未登录 + 登录按钮」。
- 违反：**第 6 条**（捕获必须至少留痕/转译）；**第 16 条**（「未登录」与「账号数据损坏」被压成同一个空值）；**第 9 条**。
- 后果：账号表解析失败时，已登录用户被显示成未登录，且「我的歌单」区块整块消失（`account != null` 分支才渲染），用户会反复重新登录。P2。

### 【P3】`_playRecent` / `_playDownloaded` 未处理 `playSong` 抛错
- 事实：`await ref.read(playHelperProvider).playSong(song); if (!mounted) return; context.push('/player');` 无 try/catch；若 `playSong` 抛错（如音源解析失败、引擎未就绪），`context.push` 不会执行也无提示。
- 违反：**第 6 条 / 第 9 条**（失败必须有用户可见反馈或日志）。
- 后果：点歌后「没反应」，停留在音乐库；用户只能反复点。P3（若 `playSong` 内部统一弹 Toast 则可降级）。

### 【P3】区块条数上限 20 为散落魔法值（三处）
- 事实：`_recent.take(20)`、`downloaded.take(20)`、`list.take(20)` 各写一次 `20`。
- 违反：**第 2 条**（魔法值必须有具名常量）。
- 后果：想改成「分页/更多」时容易漏改一处，出现各区块行为不一致。P3。

### 【P3】歌单封面固定 170dp 容器 + `Flexible` 文本，字体放大后仍可能挤压
- 事实：`SizedBox(height: 170)` 内为 `120 图 + 6 + Flexible(Text maxLines:2)`；`bodySmall` 在 `textScaleFactor 2.0` 下两行 ≈ 48dp，总高 174dp > 170dp。
- 违反：任务书 D 项（字体放大适配）。
- 后果：极值下文字被裁切（不会黄黑条，因为 `Flexible` 吸收），歌单名看不全。P3。

### 【P3】歌单封面右下角「N 首」徽标在 `Positioned` 中无左侧约束
- 事实：`Positioned(right: 6, bottom: 6, child: Container(child: Text(songCountSuffix(count))))` —— 宽度由文本决定，向右对齐；`songCountSuffix` 在德语（「128 Titel」）加 `labelSmall` 放大后宽于 120dp 封面，向左溢出的部分被 `Stack` 默认裁剪。
- 违反：任务书 D 项（布局健壮性）。
- 后果：徽标只显示后半截（如「…Titel」），数字丢失。P3。

### 【P3】`_AccountCard` 的 `PopupMenuItem` 内嵌 `ListTile`
- 事实：`PopupMenuItem(value:'manage', child: ListTile(contentPadding: EdgeInsets.zero, ...))` —— `PopupMenuItem` 自身有最小高度与内边距，`ListTile` 又叠加自身高度，菜单项高度远超 48dp 且左侧图标对齐与其他菜单不一致。
- 违反：**第 30 条**（组件语义被误用：菜单项不是列表页）。
- 后果：弹出菜单比同页其它菜单（`SongTile` 的）高一倍，视觉跳变；键盘/读屏焦点顺序仍可用。P3。

### 【P3】登出失败文案传空占位并用 `debugPrint` 补日志
- 事实：`Toast.show(context, context.l10n.logoutFailed(''))` → 用户看到「退出登录失败：」；日志走 `debugPrint`（release 下通常被丢弃）。
- 违反：**第 9 条**（失败必须可观测——release 下 `debugPrint` 不保证落盘，项目已有 `ErrorLogger`）；**第 16 条**。
- 后果：线上无法定位退出失败原因。P3。

### 观察（合规）
- `_userPlaylistsProvider` / `_collectedMvsProvider` 均为 `autoDispose.family`，随登录态参数变化自动释放，无泄漏。
- `EmptyState` 的「未登录」与「无收藏」使用了不同 icon 与文案键，语义分离正确。

---

## 12. `lib/features/player/presentation/full_player_page.dart`（545 行，通读）

### 【P2】`CurvedAnimation` 在 `build` 中内联创建且从不 dispose —— 每次重建都向父控制器新增监听器
```dart
FadeTransition(
  opacity: CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic),
  child: ClipRect(key: const ValueKey('lyric'), child: LyricView(...)))
```
- 事实：`CurvedAnimation` 是 `AnimationWithParentMixin` 实现，构造时即向 `_fadeCtrl` 注册 listener；`FadeTransition` 不会代为释放它。`_CoverOrLyricState.build` 里 `ref.watch(positionProvider)` 使该 widget **每 100ms 级**重建一次（播放中 position 流持续推送），每次重建都新建一个 `CurvedAnimation` 并挂到同一个 `_fadeCtrl` 上。
- 违反：**第 20 条**（申请的资源必须有对称释放点）；**第 25 条**（监听器数量无上限）；**第 26 条**（热路径每帧/每 tick 分配）。
- 后果：播放几分钟后 `_fadeCtrl` 上挂着数千个监听器，每次 tick 遍历回调 → 播放页滚动/切歌词卡顿、内存缓慢上涨；在所有屏幕尺寸上都发生。P2。

### 【P2】歌词加载失败/无歌词时界面完全没有反馈（error 字段无消费者）
- 事实：`currentLyricProvider` 明确返回 `(lyric: null, error: '暂无歌词')` 与 `(lyric: null, error: '歌词解析失败')`；而页面只在 `lyricAsync.value?.lyric != null` 时渲染歌词，**从不读取 `error`**（既不读 `lyricAsync.error`，也不读 record 的 `error` 字段）。切到歌词视图后是空白区。
- 违反：**第 9 条**（失败必须有用户可见反馈）；**第 32 条**（无人读取的状态字段 = 死代码）；**第 30 条**（该字段中文硬编码，本就不该出现在数据层）。
- 后果：用户点「显示歌词」后看到一片空白，无从判断是「这首歌没有歌词」还是「网络/解析失败」，只能反复点击。P2。

### 【P2】`_MvEntry` 两个 `OutlinedButton` 无 `Flexible`，大字号/长译文下溢出
- 事实：`Row(children: [OutlinedButton.icon(label: 评论), if (hasMv) ... OutlinedButton.icon(label: 播放MV)])`，两个按钮固有宽度相加，无 `Expanded`/`Flexible`/`Wrap`。
- 违反：任务书 D 项（布局溢出 + 字体放大）；**第 24 条**（构建必须可预期）。
- 后果：德语「Kommentare」+「MV abspielen」在 360dp、`textScale 1.3` 即出现 `RenderFlex overflowed`，MV 按钮被裁切到屏幕外（且此处无滚动）。P2。

### 【P3】`_fmt(Duration)` 对 ≥1 小时时长丢弃小时位
- 事实：`inMinutes.remainder(60)` + `inSeconds.remainder(60)` → 3725 秒显示 `02:05`（也是 62 分钟），实际应为 `1:02:05`；且进度条总时长与「durations」不一致。
- 违反：**第 15 条**（时长表示必须显式且一致）。
- 后果：有声书/长音频/现场版用户看到错误的曲目总长，进度条语义失真。P3。

### 【P3】`targetLang` 在无 locale 时硬编码 `'zh_CN'`
- 事实：`locale != null ? '…' : 'zh_CN'`；系统语言为 en 时若 `localeProvider` 为 null（跟随系统），翻译目标仍取 `zh_CN`。
- 违反：**第 2 条**（魔法值）；**第 23 条**（缓存键维度：目标语言由硬编码默认决定，与界面语言不一致会导致翻译结果与显示语言不符）。
- 后果：英文系统用户「跟随系统」时歌词译文仍是中文。P3（若 localeProvider 实际总能解析出 locale 则不触发，需跨模块确认）。

### 【P3】`songMvProvider` 的失败被静默吞成「无 MV」
- 事实：`final mv = mvAsync.value; final hasMv = mv != null && mv.videoId.isNotEmpty;` —— `mvAsync.hasError` 时与「这首歌没有 MV」表现完全一致。
- 违反：**第 16 条**（失败与确实为空未分离）；**第 9 条**。
- 后果：网络异常时用户以为该曲无 MV。P3。

### 【P3】`Positioned` 切换按钮 `minimumSize: Size(48, 40)`
- 事实：高 40dp < 48dp。
- 违反：任务书 G 项（48dp 触控目标）。
- 后果：边缘按钮点击命中率低。P3。

### 【P3】`_MvEntry` 在 `albumAudioId` 为空时连评论入口一起隐藏
- 事实：`if (albumAudioId.isEmpty) return const SizedBox.shrink();` —— 评论按钮在同一个 early return 之后。
- 违反：**第 16 条**（缺少 ID 与「无次级入口」被压成同一表现）。
- 后果：来自最近播放/下载兜底构造的 `Song`（`albumAudioId` 可能为空）没有评论入口，用户找不到评论。P3。

---

## 13. `lib/features/player/presentation/mini_player.dart`（180 行，通读）

正面评价：进度条拆成独立 `_MiniProgressBar` 只订阅 position（注释写明原因，第 24/26 条达标），是本批的性能正面案例。

### 【P2】固定 64dp 高度 + 两行文本，系统字号放大时纵向溢出
- 事实：`Container(height: 64)` → `Column[ _MiniProgressBar(2dp), Expanded(Row[... Column[Text(bodyMedium), Text(bodySmall)]]) ]`。可用高度 ≈ 62dp；`bodyMedium`/`bodySmall` 在 `textScaleFactor 2.0` 下单行高度约 39 + 33 = 72dp。
- 违反：任务书 D 项（字体放大适配）；**第 24 条**（构建依赖「字号不会放大」的隐式假设）。
- 后果：**迷你播放器常驻**于四个 Tab 的底部，一旦字号放大就持续显示黄黑溢出条，且会挤压 `NavigationBar` 上方空间；这是用户最常看到的区域，影响面大于单页溢出。P2。

### 【P3】`BackdropFilter(sigma 18)` 覆盖整条迷你播放器，且未加 `RepaintBoundary`
- 事实：模糊条内部含每 tick 重绘的 `LinearProgressIndicator`；`BackdropFilter` 每次重绘都要重新采样背景像素。
- 违反：**第 26 条**（热路径零分配/零重活）。
- 后果：播放中每 200–500ms 触发一次全条模糊重算，中低端机上主界面滚动掉帧。P3（真机可感知程度需实测）。

### 【P3】`onTap` 直接 `context.push('/player')`，无防重
- 事实：快速双击/三次点击会 push 多个 FullPlayerPage 实例（`go_router` 的 `push` 不去重）。
- 违反：**第 21 条**（重复执行未去重）；**第 18 条**（多实例各自 watch 同一 Provider，返回时栈深异常）。
- 后果：用户连点两下后按返回要连按两次才回到列表，且顶层播放页与底层播放页同时存在。P3。

### 【观察/合规】
- `Hero(tag: 'album-art')` 与 `full_player_page.dart` 的 `Hero(tag: 'album-art')` 分属不同 Route，构成预期的共享元素过渡，**不触发 duplicate tag 断言**。
- 无 Timer/订阅，无需释放资源（第 20 条不适用）。

---

## 14. `lib/features/player/presentation/queue_sheet.dart`（129 行，通读）

### 【P2】队列弹层标题复用了「正在播放」文案
- 事实：`Text(context.l10n.nowPlaying, …)` 作为弹层标题；右侧又显示 `songCountSuffix(queue.length)` 条数。文件头注释自述这是「播放队列底部弹层」，且 `queue_sheet` 的入口 tooltip 用的是 `context.l10n.playQueue`。
- 违反：**第 30 条**（名称必须表达意图：标题说「正在播放」，内容却是整个队列）。
- 后果：用户打开「播放队列」看到标题「正在播放」，误以为这里只显示当前曲；德语/俄语下更明显。P2（i18n 语义错误、可复现、零成本可修）。

### 【P3】重复曲目（同 hash）全部被标记为「当前播放」，且无法点选
- 事实：`final isCurrent = current?.hash == s.hash;` + `onTap: { pop(); if (isCurrent) return; ... }`。队列里同一首歌出现两次时，两行都高亮；点第二行直接 return，什么都不发生。
- 违反：**第 16 条**（用 hash 代替「队列条目身份」，把「是这首歌」与「是这一条」混为一谈）；**第 17 条**（索引才是精确标识）。
- 后果：用户「单曲循环加入队列」后无法切到重复项，以为点击失灵。P3。

### 【P3】`playQueue` 失败无任何反馈
- 事实：`await controller.playQueue(queue, i);` 在 `onTap` 中无 try/catch，且弹层已先 `pop()`。
- 违反：**第 9 条**（失败必须可观测）。
- 后果：选中一首无法播放的曲子（版权/风控），弹层关闭、播放器无变化，用户只看到「点了没反应」。P3。

---

## 14b. `lib/features/download/presentation/download_page.dart`（302 行，通读）与 `download_sheet.dart`（177 行，通读）

### 【P3】`onAppLifecycle` 被两处转发，同一事件派发两次
- 事实：`main.dart` 的 `_TiernanMusicAppState.didChangeAppLifecycleState` 转发到 `downloadManagerProvider.notifier`；`DownloadPage` 以 `WidgetsBindingObserver` **再转发一次**。同一个 `AppLifecycleState` 在下载页打开时被处理两遍。
- 违反：**第 21 条**（重复执行未去重）；**第 22 条**（「生命周期事件唯一处理者」这一前提未声明）。
- 后果：`onAppLifecycle` 内含「重置写入策略缓存 + 重新检测」这类重活被翻倍执行；若下游含「恢复下载队列」语义，则可能出现并发恢复。P3（下游是否幂等需跨模块确认）。

### 【P3】`task.error` 原始错误串直接渲染进列表，且整行状态被省略号吞掉
- 事实：`'$typeLabel · $statusLabel' '${task.error != null ? ' · ${task.error}' : ''}'` —— 原始异常（含 `DioException [connection error] …`、SDK 路径）进入 subtitle；`maxLines: 1` + `ellipsis` 意味着错误串一长，「· 下载中/失败」这些**用户真正需要的信息**反而被挤到省略号里。
- 违反：**第 30 条**（用户可见文案未本地化、且技术细节外泄）；本项目 `error_retry.dart` 已确立「不展示原始异常」的约定 → **第 8 条**。
- 后果：德语长译文 + 原始异常串 → 用户看到「Audio · …」之后全是省略号，既读不懂错误也看不清状态。P3。

### 【P3】点击已完成任务直接打开文件：不 `await`、无失败提示，且与菜单「打开」分支行为不一致
- 事实：`onTap` 中 `PublicMediaStore.instance.open(...)` 的 Future 无人接管；菜单 `'open'` 分支则会 `if (!opened) Toast(...)`。同一操作两条路径表现不同。
- 违反：**第 6 条 / 第 9 条**（失败必须可观测）；**第 8 条**（同一层失败形态必须统一）。
- 后果：文件被移动/删除/无可用播放器时，点条目毫无反应，用户以为应用卡死。P3。

### 【P3】「清空全部」复用单条删除的确认文案
- 事实：AppBar 的 `delete_sweep` 动作使用 `title: downloadClearAll` 但 `message: downloadDeleteConfirm`（「确定删除该下载内容吗？」）。
- 违反：**第 30 条**（文案须匹配动作规模）。
- 后果：用户点「清空下载记录」看到「删除**该**下载内容」，误以为是删单条，确认后整表被清空。P3。

### 【P3】进度值未夹取到 0..1
- 事实：`LinearProgressIndicator(value: progress)` 直接取 `task.progress`；`task.progress` 由下载层按字节比计算，异常路径（total=0、重试叠加）可能越界或 NaN。
- 违反：**第 17 条**（进度表示必须选定一种并保持）；**第 14 条**（外部/上游数值未校验）。
- 后果：越界值导致进度条绘制异常或抛断言（debug 下红屏）。P3。

### 【P3】`download_sheet.dart` 用「quality == q128」推断「歌曲未指定音质」
- 事实：`quality: (song.quality != AudioQuality.q128 ? song.quality : preferredQuality()).value` —— 把枚举的一个合法取值当作「未设置」哨兵。
- 违反：**第 2 条**（哨兵值/魔法语义）；**第 16 条**（缺失与合法取值未分离）。
- 后果：本身就是 128K 的曲目会**静默升级**为用户默认音质（如 FLAC）去下载，可能拉到不支持/更大的文件并以失败告终。P3。

### 【P3】`_OptionTile` 的下载按钮无 tooltip，且 queued/running 状态仍可重复添加
- 事实：`IconButton(icon: download_outlined, onPressed: () => onDownload())` 无 `tooltip`；`status == queued` 时仍落到该分支（只有 completed/running 有专门分支）。
- 违反：**第 30 条**（无标签图标按钮对读屏不可表达）；**第 21 条**（重复添加无本地锁）。
- 后果：TalkBack 只播报「按钮」；排队中的任务被反复点击可能入队多条同名任务（若 manager 无 hash+type 去重）。P3。

### 【P3】弹层 `Column` 无滚动、`_taskOf` 线性扫描
- 事实：4 个 `ListTile` + 标题 + 全宽按钮放在 `Column(mainAxisSize: min)` 中，无 `SingleChildScrollView`；`_taskOf` 每次 build 三次全表线性查找。
- 违反：布局（D 项）；**第 26 条**（热路径线性查找）。
- 后果：大字号 + 小屏时按钮被裁到屏幕外且无法滚动；任务多时每帧 O(3n)。P3。

---

## 15. 发布合规：`lib/l10n/` 全量键比对 + `app_localizations.dart` + `l10n.dart`

### 15.1 方法说明
通读 `app_zh_CN.arb`（**模板**，见 `l10n.yaml: template-arb-file: app_zh_CN.arb`）、`app_zh.arb` 全文，并对 11 个 arb 做**键集 / 占位符集**逐一比对（对 JSON 数据文件做结构化比对，非源码模式匹配；结果可复算）。
`l10n.yaml`：`arb-dir: lib/l10n`、`template-arb-file: app_zh_CN.arb`、`nullable-getter: false`、`output-localization-file: app_localizations.dart`。

### 15.2 键完整性结论（**无缺失 → 不构成第 17 项 P1**）
```
template(app_zh_CN) keys: 305
app_de  305  缺0 多0 占位符不一致0
app_en  305  缺0 多0 0
app_es  305  缺0 多0 0
app_fr  305  缺0 多0 0
app_ja  305  缺0 多0 0
app_ko  305  缺0 多0 0
app_pt  305  缺0 多0 0
app_ru  305  缺0 多0 0
app_zh  306  缺0 多1  ← 多出 albumPageComingSoon
app_zh_TW 305 缺0 多0 0
```
结论：**10 种目标语言的键与占位符 100% 齐全，l10n 生成不会因缺键失败。** 这是本批少数「通过」的发布项。

### 【P2】8 个非中文语言里 4 条文案仍是中文原文（未翻译）
| key | 现值（en/de/ru/fr/es/pt/ko/ja 全部相同） | 出现位置 |
|---|---|---|
| `previewOnly` | 试听 | **播放页**试听徽标（`full_player_page.dart` 正在使用） |
| `loginRequiredTitle` | 需要登录 | 需登录弹层标题 |
| `loginRequiredHint` | 该功能需要登录酷狗账号后使用。 | 需登录弹层正文 |
| `loginRequiredAction` | 「{action}」需要登录后才能使用。 | 需登录弹层正文 |
- 事实：程序化比对显示这 4 个键在 de/en/es/fr/ko/pt/ru 中与中文模板**逐字相同**，且含 CJK 字符（ja 因共用汉字不判定）。
- 违反：**第 30 条**（用户可见文案必须本地化）；**第 23 条**（语言维度不完整会让「已本地化」的假象传播）。
- 后果：英文用户在播放页看到中文「试听」徽标、在触发登录拦截时看到整段中文说明——这是**播放主路径 + 登录拦截路径**上的可见中文。P2。

### 【P1】提交入库的 `app_localizations.dart` 与 flutter `gen-l10n` 产物 **API 不兼容**，构建结果取决于是否触发重新生成
- 事实：
  1. 该文件首行自述 `// GENERATED CODE - DO NOT MODIFY BY HAND (offline gen-l10n equivalent) // See tool/gen_l10n_min.py — regenerates from lib/l10n/app_*.arb.`，即由自研脚本生成。
  2. 其中：`static const localizationsDelegates = _Delegate();` —— **单个 delegate 对象**。
  3. 而 `main.dart` 的用法是 `localizationsDelegates: AppLocalizations.localizationsDelegates`，`MaterialApp.router` 的参数类型是 `Iterable<LocalizationsDelegate<dynamic>>`。
  4. 同时 `pubspec.yaml` 有 `flutter: generate: true`，`l10n.yaml` 的 `output-dir: lib/l10n` 会**覆盖同一个文件**；官方 gen-l10n 产出的 `localizationsDelegates` 是 `List<LocalizationsDelegate<dynamic>>`（含 `GlobalMaterialLocalizations` 等）。
- 违反：**第 3 条**（契约先行：生成物与消费方的契约未定义）；**第 5 条**（同一份「本地化表」有两个权威生成源）；**第 2 条**（隐式依赖构建流程的时序）。
- 后果：
  - 若构建触发 `gen-l10n`（`flutter pub get`/`build` 默认行为）→ 覆盖为官方版本，`main.dart` 可编译，但仓库内这份自研产物是**死代码**，且任何人基于它修改都会在下次构建时被静默丢弃；
  - 若不触发（离线构建 / `--no-pub` / CI 缓存命中）→ `AppLocalizations.localizationsDelegates` 类型不匹配，**编译期失败**，直接阻断出包。
  - 两种路径产出不同 API，**构建不可重复**，属发布合规硬伤。P1（阻塞发版）。

### 【P2】`supportedLocales` 首元素是 `de`，无匹配语言的设备会整体显示德语
- 事实：自研产物 `supportedLocales = [de, en, es, fr, ja, ko, pt, ru, zh, zh_CN, zh_TW]`；`_Delegate.isSupported(_) => true`（接受任意 locale），`_t()` 在两级 map 都未命中时回落到 `_template`（中文）。
- 违反：**第 11 条**（降级必须有明确触发条件与既定次优行为——「找不到就退第一个」不是设计决策）；**第 14 条**（外部输入 locale 未校验）；**第 23 条**。
- 后果：系统语言为 `th`/`hi`/`ar`/`vi` 等未支持语言的设备，Flutter 的 locale 解析会退到 `supportedLocales.first` = **德语**；若走了 `_t` 回落则显示**中文**。同一台设备可能出现「设置页德语、部分文案中文」的混排。P2。

### 【P2】`AppConfig.supportedLocales`（10）与 `AppLocalizations.supportedLocales`（11）双源，且顺序不同
- 事实：见 §5；两份列表不仅数量不同（多 `zh`），排列顺序也不同（前者 `zh_CN` 开头，后者 `de` 开头）。设置页语言列表来自前者，`MaterialApp` 匹配来自后者。
- 违反：**第 5 条**（状态单一来源）；**第 23 条**。
- 后果：系统语言为 `zh-HK`（无 country 命中）时，`MaterialApp` 解析到 `zh`（第 9 个候选），而设置页查 `AppConfig.localeNames['zh']` 得 `null` → 回落到 `locale.toString()`，界面副标题直接显示导航栏语言码 `zh`。用户看到「界面语言  zh」。P2。

### 【P3】`app_zh.arb` 多出一个只有它能解析的键
- 事实：`albumPageComingSoon` 只存在于 `app_zh.arb`，模板与其它 10 个 arb 都没有。
- 违反：**第 32 条**（无人可调用的键：getter 由模板生成，代码拿不到该键）。
- 后果：该键永远不会显示，且给「zh 与 zh_CN 一致」的维护假设埋雷。P3。

### 【P3】未提供 `GlobalMaterialLocalizations` / `GlobalWidgetsLocalizations`
- 事实：自研 `localizationsDelegates` 只有 `_Delegate`；`main.dart` 亦未追加全局 delegates。
- 违反：**第 30 条**（Material 内建文案——如 `Slider` 语义值、日期选择器、`TextField` 长按菜单「剪切/复制/粘贴」——仍是英文）。
- 后果：俄语用户长按输入框看到英文 Copy/Paste。P3（若官方 gen-l10n 覆盖则自动带上，属构建双轨的连带风险）。

### 【P3】`AppLocalizations.of(context)` 使用非空断言
- 事实：`Localizations.of<AppLocalizations>(context, AppLocalizations)!`；`l10n.dart` 的扩展直接转发。
- 违反：**第 12 条**（跨函数边界的非空断言）。此处由 `Localizations` 契约保证，但 `StartupErrorPage` 的两条渲染路径都在 `MaterialApp` 之外（见 §2），一旦有人在该页使用 `context.l10n` 立即崩溃。
- 后果：崩溃页再崩（黑屏）。P3。

---

## 16. `lib/features/comment/presentation/comments_page.dart`（656 行，通读）

正面评价：`load()`/`loadMore()` 都实现了 `_generation` 代次丢弃（第 18 条达标，注释写明「防串页」）；`ScrollController`/`FocusNode`/`TextEditingController` 成对释放；风控 20028 显式「不自动重试」（符合第 21 条红线）。

### 【P2】`StateNotifierProvider.family` 未加 `autoDispose`，且 `_CommentArgs` 未实现 `==`/`hashCode` —— 每进一个评论页就永久驻留一个 controller
- 事实：
  - `_commentsProvider` 声明为 `StateNotifierProvider.family<…, _CommentArgs>`（**无 `autoDispose`**）；
  - `_CommentArgs` 只有构造函数，无 `operator ==`/`hashCode`，family 缓存键退化为**对象身份**；
  - `_args` 在 State 里 `late final` 创建，每次进入页面都是新对象。
- 违反：**第 20 条**（申请的订阅/状态必须有释放点）；**第 25 条**（内存条目数无上限）；**第 5 条**（同一资源对应多份 controller，状态不再单一）。
- 后果：用户浏览 50 首歌的评论页 → 50 份 `CommentPage` 列表（含全部评论文本与头像 URL）常驻内存，且各自保留 `CommentRepository` 引用；低端机上表现为内存持续上涨、GC 频繁。P2。

### 【P2】列表底部「加载更多」指示器只看 `hasMore`，失败后永久转圈
- 事实：`itemCount = comments.length + 1`，最后一项 `if (hasMore) return Center(child: CircularProgressIndicator())` —— 该分支**不区分「正在加载」与「静止但有下一页」**；而 `loadMore()` 的 `catch (_) {}` 失败不记日志、不改状态、不提示，`_hasMore` 仍为 true。
- 违反：**第 16 条**（「加载中」与「还有更多」是两种状态，被合并）；**第 6 条 / 第 9 条**（失败被吞、不可观测）；**第 11 条**（失败后无退出条件）。
- 后果：弱网下翻页失败后，用户看到底部**永久转圈**却什么都没发生，只能下拉刷新整页重来。P2。

### 【P2】发送失败后已清空的输入框不回填
- 事实：`_inputCtrl.clear(); setState(() => _replyTo = null);` 在 `try` 之前执行；catch 分支只弹 Toast。
- 违反：**第 9 条**（失败必须可恢复）；**第 21 条**（写操作失败后不具备重试的幂等前提——用户必须重新输入）。
- 后果：一段几十字的评论因风控/断网失败后全部丢失，用户需重写。P2（用户内容丢失，但非持久数据）。

### 【P3】下拉刷新失败被静默吞掉
- 事实：`load(refresh: true)` 的 catch 只在 `state.value == null` 时置 error；已有数据时刷新失败既不提示也不留痕。
- 违反：**第 9 条**（静默降级必须留痕）。
- 后果：用户下拉后无任何反应，以为「没有新评论」。P3。

### 【P3】`_isLoggedIn` 用 `ref.read` 参与 build
- 事实：`bool get _isLoggedIn => ref.read(authStateProvider).valueOrNull != null;` 被 `build` 调用（决定输入框 hint、回复/删除入口）。
- 违反：**第 18 条 / 第 5 条**（build 期读取非响应式状态，登录态变化不会重建）。
- 后果：用户在评论页内完成登录返回后，输入框仍显示「登录后可评论」、评论无法点回复，直到退出重进。P3。

### 【P3】分页口径 `30` 硬编码两处
- 事实：`if (result.comments.isEmpty || _page * 30 >= result.total)` 出现两次，页面大小未与仓库层共享常量。
- 违反：**第 2 条**（魔法值）；**第 3 条**（分页契约未集中定义）。
- 后果：上游若改 page size，`hasMore` 判断错误 → 少加载或多请求一整页空数据。P3。

### 【P3】`comment.specialChildId!` 跨闭包非空断言
- 事实：`onOpenFloor` 的构建条件里判过 `specialChildId != null`，但断言写在 `_openFloor`/`_deleteComment` 的另一层闭包中。
- 违反：**第 12 条**（非空断言只允许在同一函数体内已被证明）。
- 后果：当前数据不可变所以安全；一旦评论模型改为可变或被复用，会 NPE。P3。

### 【P3】`createTime` 直接渲染上游字符串；分类/热词用无可点行为的 `Chip`
- 事实：`Text(comment.createTime)` 未做本地化日期格式；`_CommentTags` 用 `Chip` + `materialTapTargetSize: shrinkWrap` 表现**纯展示**信息。
- 违反：**第 15 条**（时间表示未显式化）；**第 30 条**（Chip 在 M3 语义中代表可交互/可删除的实体）；任务书 G 项（shrinkWrap 使触控区 < 48dp）。
- 后果：不同语言用户看到同一串上游时间格式；读屏会把标签播报为「按钮」但点了没反应。P3。

---

## 17. `lib/features/search/presentation/search_page.dart`（724 行，通读）

正面评价：`_debounce` 在 `dispose` 取消、`_controller.removeListener` 显式解绑、`_submittedKeyword` 变化用 `ValueKey` 重建结果区、失败态不自动重试（避免 Toast 刷屏）。防抖与生命周期处理正确。

### 【P2】`_SongResultTab` 的 footer 只有转圈，没有注释所称的「重试」按钮
- 事实：
  - 注释：「失败态不自动重试……只走 footer「重试」按钮」；
  - 实际 `itemBuilder`：`if (i >= _items.length) return Padding(child: Center(child: CircularProgressIndicator()))` —— footer **没有任何按钮**，且只要 `_hasMore` 为真就渲染，与 `_loading` 无关。
- 违反：**第 31 条**（注释描述的机制不存在，误导后来者）；**第 16 条**（「加载中」与「还有更多」未分离）；**第 11 条**（失败后无恢复入口）；**第 9 条**（失败只弹一条通用 Toast，且随后不再重试）。
- 后果：搜索结果第二页请求失败后，列表底部**永久转圈**，用户既不能点重试也不能滚出新内容；注释还可能让维护者以为重试已实现而不再修。P2。

### 【P2】两个搜索 family provider 没有 `autoDispose`，每次搜索关键词都会常驻一份结果
- 事实：`_playlistSearchProvider = FutureProvider.family<…, String>`、`_genericSearchProvider = FutureProvider.family<…, (String,String)>` 均为**非 autoDispose**；`_hotSearchProvider` 同样常驻。
- 违反：**第 20 条**（申请的状态无释放点）；**第 25 条**（条目数无上限）。
- 后果：用户搜索 30 个关键词（每次切换都会创建新的 family 实例）→ 30 × 3 个结果列表 + 全部封面 URL 常驻内存；搜索是高频操作，泄漏随会话时长线性增长。P2。

### 【P2】`_SongResultTab` 5 个 Tab 全 `AutomaticKeepAliveClientMixin`，且 `_items` 无上限
- 事实：`wantKeepAlive => true` + `_items` 只增不减（分页追加），Tab 切换不释放。
- 违反：**第 25 条**（列表缓存无上限）；**第 24 条**（惰性构建只保护了渲染，未保护数据）。
- 后果：连续翻 20 页后，即使切到其它 Tab，几百条 `HomeSong` 及其封面路径全部驻留；内存随搜索深度增长。P2（与上一条同源，可合并整改）。

### 【P3】`fetchSuggest` / `addHistory` / `getHistory` 均无 try
- 事实：`_onChanged` 的 `Timer(400ms, () async { final list = await ref.read(...).fetchSuggest(...); ... })` 无 catch；`_submit` 中 `await addHistory(k)` 无 catch；`_loadHistory()` 中 `await getHistory()` 无 catch。
- 违反：**第 6 条**（异常必须转译/记录/降级）；**第 9 条**（失败必须可观测）。
- 后果：断网时每输入一个字就抛一次未捕获异步异常（进 `ErrorLogger`，但 UI 无任何提示）；`_submit` 时若写历史失败，**整个搜索不会执行**——用户按回车后界面毫无反应，最典型的「点了没反应」。P3（若 `addHistory` 内部已吞异常则可降级）。

### 【P3】`_SongResultTab.onTap` 不等待、不处理播放失败
- 事实：`ref.read(playHelperProvider).playHomeQueue(_items, i); context.push('/player');` —— 未 `await`，`playHomeQueue` 的 Future 错误无人接管。
- 违反：**第 6 条 / 第 9 条**。
- 后果：音源解析失败时仍跳进播放页，显示「未在播放」；用户以为是播放页 bug。P3。

### 【P3】`s.hash ?? s.id` 把两种标识符混用
- 事实：`hash: s.hash ?? s.id`（下载任务）——`hash` 是音频 hash，`id` 是歌曲数字 id，语义不同。
- 违反：**第 16 条**（缺失与替代值混用）；**第 17 条**（标识符精度/种类必须单一）。
- 后果：搜索结果缺 hash 时创建出的下载任务带错误 hash，下载必然失败且报错指向「网络」。P3。

### 【P3】`GridView` 固定 `crossAxisCount: 2`
- 事实：横屏/平板上每格宽度超过 400dp，封面被放大到失真，仍只显示 2 列。
- 违反：**第 24 条**（布局应随约束自适应）。
- 后果：平板上信息密度极低，与手机端体验割裂。P3。

### 【P3】`Badge` 包裹 `GradientChip` 的徽标在 `Wrap` 中可能被裁切
- 事实：`Badge(offset: Offset(8, -4), child: GradientChip(...))` —— 徽标相对 child 右上偏移，`Wrap` 的行间距 `runSpacing: 8` 不足以容纳 `-4` 的负偏移 + 徽标高度。
- 违反：任务书 D 项（布局）。
- 后果：热搜标签上方的「热」角标与上一行标签重叠或贴边。P3。

---

## 18. `dart analyze` 结果与局限（仅作佐证，不作结论依据）

命令：`export PATH=$PATH:/opt/dart/bin; dart analyze lib`，共 **4554 issues**。

**噪音说明**：本沙箱没有 Flutter SDK，`package:flutter/*` 全部 `uri_does_not_exist`，导致
`override_on_non_overriding_member`（约 4000 条）与 `undefined_class`（`Locale`/`BuildContext`/`Localizations`）全部是级联噪音，**不构成缺陷证据**。

**可用的信号**（不依赖 Flutter 解析）：
1. `lib/l10n/app_localizations.dart`：**36 处 `undefined_method` —— `The method 'r' isn't defined for the type 'String'`**（行 3622–3736）。`String` 是 dart:core 类型，该判定与 Flutter 包无关，**确定性编译错误**。
   同时 `_Msg`（第 3397 行，含真正实现了占位符替换的 `r()`）被判 `unused_element`——即：生成器把 `r()` 定义在 `_Msg` 上，却让 `_t()` 返回 `String` 再对其调用 `.r()`。
   → 该提交物**自身无法编译**；再叠加第 15 节所述 `localizationsDelegates` 类型不匹配（单对象 vs `Iterable`），共同决定「仓库内这份 `app_localizations.dart` 直接参与构建则必然失败」。
2. `lib/l10n/app_localizations.dart:3397 unused_element _Msg`（同上，第 32 条）。
3. 范围外旁证（仅记录，不计入本批问题）：`features/playlist/data/playlist_repository.dart:312 dead_code`、`features/mv/data/mv_repository.dart:3 unused_import`。

**未能验证的项**：第 6 节所列「未使用 import」（`dart:async` / `toast.dart` / `l10n.dart` / 同目录 widget）因 Flutter 包未解析，analyzer 不报 `unused_import`。该结论来自逐行通读（文件内确无对应符号调用），但与 analyze 无交叉证据，标注为**通读结论**。

---

## 19. 问题清单（按级别汇总）

### P1（发布阻断 / 核心功能风险）

| # | 位置 | 事实 | 违反 | 后果 |
|---|---|---|---|---|
| P1-1 | `lib/l10n/app_localizations.dart`（提交入库的生成物） | ①36 处 `_t(...).r(...)` 在 `String` 上调用不存在的 `r()`；②`localizationsDelegates` 是单个 `_Delegate` 对象，而 `main.dart` 传给 `MaterialApp.router` 的参数要求 `Iterable<LocalizationsDelegate<dynamic>>`；③pubspec `generate: true` + `l10n.yaml` 会在构建时用官方 gen-l10n 覆盖同路径文件 | 第 3 条（契约先行）、第 5 条（生成源双轨）、第 2 条（隐式依赖构建时序） | 不触发重生成 → **全应用编译失败，无法出包**；触发重生成 → 该文件为死代码，任何人基于它修改都会被静默丢弃。构建**不可重复**。 |
| P1-2 | `lib/core/config/app_config.dart:9,11` | `kugouApiBase = https://kapi.344977.xyz`、`proxyBase = https://proxy.344977.xyz` —— 第三方中转主机被固化为默认 API 基址，全仓无「未移植路径清单」与清理计划；域名写死、无远程开关 | **第 27 条**（接口只走原生网关，中转仅可作显式兜底且须写明原因与清理计划）；第 31 条；第 2 条 | 全部业务流量（含登录 token、播放、下载）默认经第三方主机；该主机下线/被劫持即全功能失效或隐私外泄，客户端无法切换直连。 |

### P2（次要功能异常 / 边界态 / 性能 / 可访问性）— 共 35 条

| # | 位置 | 事实 | 违反 | 后果 |
|---|---|---|---|---|
| P2-1 | `main.dart:265` | `readCredentials().then` 回填 `client.t1` 时不再校验当前登录态 | 第 18 条、第 5 条 | 退出登录后仍以旧账号 t1 请求，出现旧账号个性化/权益数据 |
| P2-2 | `main.dart:246–252` | `StartupErrorPage` 分支的 `MaterialApp` 未传 delegates/locale/theme；`_startupError` 为顶层可变全局 | 第 8 条、第 5 条 | 错误页语言与主界面不一致；该页一旦用 l10n 立即抛 `No AppLocalizations` |
| P2-3 | `app_router.dart:24–76` | `GoRouter` 无 `errorBuilder` | 第 14 条、第 30 条 | 无效深链落到英文默认错误页且无返回出口 |
| P2-4 | `app_router.dart:66–70` | `/rank/:rankId` 用 `int.tryParse(...) ?? 0`，`name` 缺失 → `''` | 第 11 条、第 16 条、第 14 条 | `rankId=0` 静默请求无效榜单，用户看到空榜/转圈无法区分原因 |
| P2-5 | `core/providers.dart:3,19` | `core` 层 import `features/lyric` 并定义 `lyricRepositoryProvider` | **第 4 条**（分层回流） | 核心层无法独立编译/测试，歌词模块签名变更波及全仓 |
| P2-6 | `app_config.dart:31–34` | `AppConfig.supportedLocales`(10) 与生成物 `AppLocalizations.supportedLocales`(11) 双源且顺序不同 | 第 5 条、第 23 条 | 设置页可选语言与实际解析集合不一致；`zh-HK` 用户副标题显示裸 `zh` |
| P2-7 | `core/widgets/song_tile.dart:9–16` | 一个 widget 文件内 `export` 5 个组件（其中 3 个本文件未使用） | 第 1 条、第 2 条、第 32 条 | 改 `empty_state.dart` 导出名会把编译错误散布到无关页面 |
| P2-8 | `core/widgets/shimmer.dart:11,40` | `enabled` 注释称用于「prefers-reduced-motion」，但无任何调用方传参、无 `MediaQuery.disableAnimations` 读取；`repeat()` 无条件启动 | 第 11 条、第 32 条 | 关闭系统动画的用户仍被强制播放扫光动画（前庭敏感人群） |
| P2-9 | `core/widgets/error_retry.dart:225–234` | `error==null && message==null` → `friendly=''`、`hint=''` 的空卡片 | 第 16 条、第 9 条 | 报错页只剩图标与按钮，用户不知发生了什么 |
| P2-10 | `login_page.dart:61x` (`_checkOnce`) | `catch (_) {}` 全吞 + 固定 3s 轮询无上限、无退避 | 第 6/7/10/25/9 条 | 服务端故障时每 3 秒静默请求直到离开，页面停在「等待扫码」 |
| P2-11 | `login_page.dart:409–431` | `Row(Expanded(TextField), FilledButton)` 右侧无 Flexible | 布局/字体放大（D 项）、第 24 条 | 大字号/长译文下 RenderFlex 溢出，按钮文案被裁，用户看不到「发送验证码」 |
| P2-12 | `captcha_page.dart` 全文 | 约 18 处用户可见文案硬编码中文（含内嵌 HTML 的按钮文案） | **第 30 条** | 登录必经路径在 10 语言下整页中文 |
| P2-13 | `captcha_page.dart:203,214,257` | WebView `onLoadStop`/JS handler 内 `setState` 无 `mounted` | 第 20 条 | 滑块完成瞬间关闭页面 → `setState after dispose`，登录中断 |
| P2-14 | `captcha_page.dart:317–372` | `_buildExternal`/`_buildUnknown` 的 Column 不可滚动 | 布局（D 项）、第 24 条 | 大字号/横屏溢出，「直接尝试提交」按钮被顶出屏幕 |
| P2-15 | `settings_providers.dart:14,35,53` | 从 Hive 取值裸 `as String?` / `as bool?` | **第 13 条**、第 14 条 | 老版本存过其它类型 → Notifier 构造抛 `_TypeError`，进设置页/播放页即崩 |
| P2-16 | `settings_providers.dart:38–63` | `wifiQualityProvider`/`cellularQualityProvider` 在本批全范围内只有写入、无读取 | 第 32 条、第 11 条 | 「Wi-Fi 自动最高音质」是可见假开关（待 player 层交叉确认） |
| P2-17 | `settings_page.dart:453–500` | 语言列表读 `AppConfig.supportedLocales` | 第 5 条、第 23 条 | 见 P2-6 |
| P2-18 | `settings_page.dart:462` | 语言列表「跟随系统」项使用 `themeSystem` 文案 | 第 30 条 | 德语等语言显示「Systemvorgabe」，语义错乱 |
| P2-19 | `settings_page.dart:390,355,530` | 三处 `SegmentedButton` 仅 compact+padding 缓解，仍不滚动/不折行 | 布局（D 项）、第 24 条 | 系统字号最大 + 窄屏时第三段被裁，点不到「跟随系统」 |
| P2-20 | `settings_page.dart:868–905` | 更新下载链接 `Uri.parse(url)` 未校验 scheme/host，且优先取 `acceleratedUrl` | 第 13/14 条、第 27 条 | 畸形链接抛未捕获异常；从非官方「加速」域下载 APK |
| P2-21 | `library_page.dart:441–447` | `_currentAccount()` `catch(_){return null;}` | 第 6 条、第 16 条 | 账号数据损坏时已登录用户被显示成「未登录」，歌单区整块消失 |
| P2-22 | `full_player_page.dart:379–386` | `build` 内联 `CurvedAnimation` 且从不 dispose；页面每 tick 重建 | **第 20 条**、第 25/26 条 | 播放数分钟后父控制器挂数千监听器 → 播放页卡顿、内存增长 |
| P2-23 | `full_player_page.dart:24–32` + `:365` | provider 返回 `error:'暂无歌词'/'歌词解析失败'`，页面从不读取 | 第 9 条、第 32 条、第 30 条 | 切歌词视图后一片空白，用户无法区分「无歌词」与「失败」 |
| P2-24 | `full_player_page.dart:296–345` | 评论/MV 两个 `OutlinedButton` 在无 Flexible 的 Row 中 | 布局（D 项）、第 24 条 | 德语 + 大字号溢出，MV 按钮出屏 |
| P2-25 | `mini_player.dart:44,73–96` | 固定 64dp 内放两行文本 | 布局（D 项）、第 24 条 | 常驻四个 Tab 底部的溢出条，挤压导航栏 |
| P2-26 | `queue_sheet.dart:47` | 队列弹层标题使用 `nowPlaying`（正在播放） | 第 30 条 | 标题与内容不符，用户以为只显示当前曲 |
| P2-27 | `comments_page.dart:29–31` | `StateNotifierProvider.family` 无 autoDispose，`_CommentArgs` 无 `==/hashCode` | **第 20 条**、第 25 条、第 5 条 | 每浏览一个评论页就永久驻留一份评论列表，内存随浏览线性上涨 |
| P2-28 | `comments_page.dart:302–320` | footer 只要 `hasMore` 就转圈；`loadMore` 失败 `catch(_){}` | 第 16/6/9/11 条 | 翻页失败后底部永久转圈，只能下拉刷新整页 |
| P2-29 | `comments_page.dart:401–403` | 发送前 `clear()`，失败不回填 | 第 9 条、第 21 条 | 用户写好的评论丢失，需重写 |
| P2-30 | `search_page.dart:610–620` + `:520` | 注释称「footer 重试按钮」，实际 footer 只有转圈；失败后不再自动重试 | 第 31 条、第 16/11/9 条 | 第二页失败后底部永久转圈，无任何恢复入口 |
| P2-31 | `search_page.dart:695,723` | `_playlistSearchProvider`/`_genericSearchProvider` 无 autoDispose | 第 20 条、第 25 条 | 搜 30 个词 → 90 份结果常驻内存 |
| P2-32 | `search_page.dart:415–470` | 5 个结果 Tab 全 `AutomaticKeepAliveClientMixin`，`_items` 只增不减 | 第 25 条、第 24 条 | 深翻页后数百条歌曲常驻，切 Tab 也不释放 |
| P2-33 | `app_en/de/es/fr/ko/pt/ru.arb` | `previewOnly`/`loginRequiredTitle`/`loginRequiredHint`/`loginRequiredAction` 4 条仍为中文 | **第 30 条**、第 23 条 | 播放页「试听」徽标、登录拦截弹层在 8 种语言下显示中文 |
| P2-34 | `app_localizations.dart:3417–3430`、`:3444` | `supportedLocales` 首项为 `de`；`isSupported => true`；`_t` 回落中文模板 | 第 11 条、第 14 条、第 23 条 | 未支持语言（th/hi/ar/vi）设备整体显示德语或中文 |
| P2-35 | `main.dart:215–224` | 登录态监听：`ref.invalidate(homeDataProvider)` 在 client 更新前执行 | 第 18 条 | 首页可能在 token 写入前重建并拉到未登录内容（与 P2-1 同源，需统一时序） |

### P3（整洁度 / 命名 / 注释 / 轻微体验）— 共 75 条
分类计数：未使用 import 与悬空注释 12、命名与语义（第 30 条）11、注释与实现不符（第 31 条）7、魔法值与单位（第 2/15 条）14、可访问性与 48dp 对比度 10、生命周期与防御性缺口 8、异常处理留痕（第 6/9 条）12、analyze 佐证的死类 1。明细见各文件小节（§1–§17、§14b）。
代表条目：
- `core/widgets/*`：5 个文件共 12 处未使用 import；4 个文件尾部残留下一个类的孤立 dartdoc。
- `song_tile.dart:200` `_fmt` 分钟位 `padLeft(1,'0')`、≥1h 无小时位；`full_player_page.dart:36` 同源缺陷。
- `settings_page.dart:_formatBytes` 大括号后接代码（未 `dart format`）。
- `l10n/app_localizations.dart:3397` `_Msg` 未被引用（analyze 确认）。
- `app_zh.arb` 多出 `albumPageComingSoon`，其余 10 个 arb 没有（死键）。

---

## 20. 统计表

| 范围 | 文件数 | P1 | P2 | P3 |
|---|---|---|---|---|
| `pubspec.yaml` | 1 | 0 | 0 | 2 |
| `lib/main.dart` | 1 | 0 | 2 | 5 |
| `core/router/app_router.dart` | 1 | 0 | 2 | 3 |
| `core/providers.dart` | 1 | 0 | 1 | 2 |
| `core/config/app_config.dart` | 1 | **1** | 1 | 2 |
| `core/widgets/` | 10 | 0 | 3 | 15 |
| `auth/login_page.dart` | 1 | 0 | 2 | 4 |
| `auth/captcha_page.dart` | 1 | 0 | 3 | 3 |
| `settings/settings_providers.dart` | 1 | 0 | 2 | 3 |
| `settings/settings_page.dart` | 1 | 0 | 4 | 6 |
| `library/library_page.dart` | 1 | 0 | 1 | 6 |
| `player/full_player_page.dart` | 1 | 0 | 3 | 5 |
| `player/mini_player.dart` | 1 | 0 | 1 | 2 |
| `player/queue_sheet.dart` | 1 | 0 | 1 | 2 |
| `download/download_page.dart` | 1 | 0 | 0 | 5 |
| `download/download_sheet.dart` | 1 | 0 | 0 | 3 |
| `l10n/`（11 arb + 生成物 + l10n.yaml） | 13 | **1** | 2 | 3 |
| `comment/comments_page.dart` | 1 | 0 | 3 | 5 |
| `search/search_page.dart` | 1 | 0 | 3 | 5 |
| `dart analyze` 佐证 | — | 0 | 0 | 1 |
| **合计** | **41** | **2** | **35** | **75** |

级别分布：P1 1.8% / P2 31.3% / P3 66.9%（合计 112 条）。

---

## 21. 结论与整改优先级

**通过项（明确无问题）**
1. 版本号 `3.0.0+30` 与 tag `v3.0.0` 一致，`environment.sdk` 与依赖版本自洽（§1）。
2. **10 种语言的 arb 键与占位符 100% 齐全（各 305 键）**，l10n 生成不会因缺键失败（§15.2）。
3. pubspec 的 dependencies 覆盖本次审查读到的全部第三方 import（§1）。
4. 生命周期主体：`_authSub`/`_recentSub`/`Timer`/`AnimationController`/`TabController`/`ScrollController`/`FocusNode` 均成对释放；`_generation` 代次丢弃在评论页、下载管理器均已落地。
5. 危险操作统一走 `showDestructiveConfirm`（error 色 + 二次确认），未见漏网（§6.5、§10、§11、§16）。

**必须修（P1，发布阻断）**
1. 删除入库的 `lib/l10n/app_localizations.dart`（或改为 `.gitignore` + 构建期生成），确认 CI 一定执行 `flutter gen-l10n`；修掉 36 处 `.r()` 与 `localizationsDelegates` 类型不匹配。
2. `AppConfig` 的中转域名改为「直连为主 + 中转显式兜底」，并把「尚未移植路径清单 + 清理计划」写进注释（第 27 条硬要求）。

**建议本迭代修（P2 中影响面最大的 6 条）**
- P2-22 `CurvedAnimation` 泄漏（播放页卡顿）→ 提到 State 字段并 dispose。
- P2-33 4 条未翻译文案（播放主路径中文）。
- P2-15 Hive 裸强转（升级用户进设置页崩溃）。
- P2-12 人机验证页硬编码（登录必经路径）。
- P2-27/P2-31 评论与搜索 provider 无 autoDispose（内存线性泄漏）。
- P2-30/P2-28 footer 永久转圈（翻页失败死路）。

**待人工确认（本批无法闭环）**
1. `assets/audiomack.svg` 的来源与授权（§6.5）。
2. `UpdateChecker` 的 `acceleratedUrl` 具体域名（决定 P2-20 是否升 P1）。
3. `wifiQualityProvider` / `cellularQualityProvider` 在 `player` 层是否真有读取（决定 P2-16 去留）。
4. `kapi/proxy.344977.xyz` 的归属与是否已有直连迁移计划（决定 P1-2 的整改方案）。
