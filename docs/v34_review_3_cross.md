# v3.4 审查③：跨模块一致性 / 状态流 / 配置层

基线 ac188b2（tag v3.3.0）。依据 QUALITY_STANDARD.md（33 条）。禁编译；dart analyze 仅作辅助（过滤缺包噪音）。

---

### lib/main.dart:267-277 登录态同步被 try/catch 吞掉，client 未就绪时 token 永不同步
- 级别：P1
- 事实：`ref.listen(authStateProvider, ...)` 内部：
```dart
try {
  final client = ref.read(kgClientProvider);
  ...
} catch (e) {
  debugPrint('[auth-sync] $e');
}
```
对整个同步体（invalidate home/library、token/userid/t1 写入）套一层 catch。若 `kgClientProvider` 此刻尚未构建（启动早期登录态恢复先触发 listen），`read` 抛出后**本次同步整体丢失**，且无重试——注释自称「仅在有值时创建 client，避免启动期强依赖」，但结果是丢失的那次不会被补发。
- 违反：第 6 条（catch 必须至少完成转译/日志/降级之一——此处仅 debugPrint 且吞掉业务写入）；第 19 条精神（状态同步无补偿机制）
- 后果：冷启动恢复登录态时若直连 client 构建失败/延后，所有直连请求以未登录身份发出——会员歌曲播不了、个性化内容缺失，且无任何用户可见提示，重启才能恢复。

### lib/main.dart:231-237 App 生命周期事件只有下载管理器一个订阅者
- 级别：P2
- 事实：`didChangeAppLifecycleState` 仅转发 `downloadManagerProvider.onAppLifecycle(state)`；player、home、auth 均未收到 resume/pause 事件。
- 违反：第 5 条（状态单一来源——生命周期事件由 App State 手工逐个转发，属隐式扇出，新增订阅者靠人记）
- 后果：切后台再回来的场景（token 过期检测、每日推荐刷新、播放状态校正）无人处理；尤其 resume 时不会校验登录态是否已在服务端失效，用户带着过期 cookie 继续操作，直到某次请求 401 才发现。

### lib/main.dart:241-242 didHaveMemoryPressure 只清 MemoryCache
- 级别：P3
- 事实：`MemoryCache.instance.clear();` 是全局唯一清理点，翻译缓存（Hive lyric_translations）、图片缓存不在范围——符合分层，但 MemoryCache 清空后无任何调用方感知。
- 违反：第 9 条（降级无留痕）
- 后果：轻微——用户在弱内存设备上遇到一次全量缓存冷启动（列表重新拉取、重复请求），无日志说明原因。

### lib/main.dart:254 vs lib/core/direct/kg_providers.dart:74-88 双渠道 listen/read 交叉，登录态同步与 kgClientProvider 创建顺序脆弱
- 级别：P2
- 事实：main.dart 中 `ref.read(kgClientProvider)`（watch 语义上应 read，因为 client 是稳定单例——这一点成立），但 login 的同步逻辑全部写在 **UI 层 ConsumerState 的 listen 回调**里，而 `kgClientProvider` 的 token/userid 属于第 5 条要求的「单一来源」外部状态。登录态→client 的同步没有任何 provider 依赖关系保障，完全靠 Widget build 时一次 listen 生效。
- 违反：第 5 条（单一来源靠 UI 层手工同步，而非依赖图）；第 2 条（隐式耦合：谁负责同步 token 没有显式契约）
- 后果：任何不经过 `_TiernanMusicAppState.build` 的路径（未来多窗口、后台 isolate 恢复）都不会同步 token；测试或重构中把 MaterialApp 换壳即静默失联。

### lib/core/router/app_router.dart:34 `/login` 路由登录成功后无 redirect 闭环
- 级别：P3
- 事实：GoRouter 未配置 `redirect`，登录态与路由解耦；登录页自身负责返回。
- 违反：第 3 条（契约模糊——「已登录访问 /login」行为由页面内部隐式决定，路由层无契约）
- 后果：深链进入 /login 且已登录时行为依赖 LoginPage 内部实现；若页面未处理则已登录用户看到登录页（见 auth 文件核实后定级）。

### lib/core/router/app_router.dart:131（占位撤销说明）
- 初稿曾列 MiniPlayer 可见性占位问题；player_provider.dart 复核后其流式 provider 体系齐备，占位不成立，撤销，不计入问题清单。




### lib/core/theme/settings_provider.dart:9-17 settings box 未打开时静默降级为内存态
- 级别：P2
- 事实：`_settingsBoxProvider` 在 box 未 open 时返回 null，三个 Notifier 全部退化为纯内存态；而 main.dart 的 `openSafe('settings')` 失败只 debugPrint。
- 违反：第 9 条（静默降级无留痕）；第 16 条（「打开失败」与「未设置过」语义混同）
- 后果：Hive 损坏的设备上，主题/语言/歌词模式每次冷启动重置为默认（dark/系统/bilingual），且没有任何日志可供定位——用户以为设置功能坏了。

### lib/core/theme/settings_provider.dart:17-22 `_load` 强转 `as String?` 会在脏数据下抛异常
- 级别：P2
- 事实：`box?.get(_key, defaultValue: 'dark') as String? ?? 'dark'`——box 内若被外部写入非 String（settings box 是 `Box<dynamic>`，全 app 任何代码都能往里写任意类型，auth_providers.dart:39-43 就往同一个 box 写 nickname/avatar），`as String?` 直接抛 TypeError，ThemeModeNotifier 构造失败 → ProviderScope 建树崩 → 错误页。
- 违反：第 13 条（外部数据裸强转）；第 14 条（数据边界校验——Hive 读取是边界）
- 后果：一个历史/异常写入的字段能把整个 App 打进 StartupErrorPage，且文案只显示 TypeError 不指明原因。

### lib/features/auth/data/auth_providers.dart:47-53 logout 不清直连客户端 t1/token 的时序竞态
- 级别：P2
- 事实：`logout()` 里 `state = AsyncData(null)` 触发 main.dart 的 authState listen → 清 client.token/userid/t1。但 listen 是在下一帧微任务里执行；logout 与 state 赋值之间若有在途请求（用旧 token），以及 main listen 里 `SecureStorage.readCredentials().then(...)` 是异步补 t1——登出后立刻登录另一账号时，前者 then 可能**晚于**新登录的 t1 写入返回，把新 t1 覆盖为旧账号值或 ''（世代未校验，违反第 18 条：`.then` 里没比对「仍是当前登录的 userid」——对比：同一文件 build 里的补 t1 也没校验，但 main listen 里做了 `c.userId == user.userid` 校验，说明作者知道该问题，logout→login 快速切换路径上 main 的捕获闭包捕获的 `user` 是旧值，最终写入的是基于旧 user 的结果）。
- 违反：第 18 条（异步结果未校验世代）
- 后果：退出后立即换号登录，新会话的 t1 可能被旧账号的空/旧值覆盖 → token 刷新签名失败 → 静默掉登录态，需重新登录。

### lib/features/auth/data/auth_providers.dart:70-77 switchAccount 失败时 loading 状态残留无 finally
- 级别：P3
- 事实：`switchAccount` 抛 StateError 时 authStateProvider 保持之前状态（正确），但无 catch 转 UI 反馈的统一出口；LoginController 有 AsyncError 状态，switchAccount 没有。
- 违反：第 8 条（同一层异常形态不一致：LoginController 走 AsyncError，switchAccount 裸抛）
- 后果：账号列表页对 switchAccount 的错误处理方式与登录页不同，容易一处提示一处不提示（需看调用方，此处按契约不一致记录 P3）。

### lib/features/auth/data/auth_repository.dart:33-38 AuthRepository 可在 provider 体系外自行 new，凭空产生第二个客户端
- 级别：P2
- 事实：`AuthRepository({KugouApiClient? api, ...}) : _api = api ?? KugouApiClient()`。auth_providers.dart 用 `ref.watch(kugouApiClientProvider)` 注入（正确），但构造契约允许裸 new——裸 new 出来的实例没有 device 注入与 cookie 目录配置（KugouApiClient 默认构造），与主链路行为不同。
- 违反：第 2 条（隐式依赖：默认构造隐藏了 device/cookie 的配置前提）
- 后果：任何新代码路径（测试/新 feature）`AuthRepository()` 后得到的 client 无设备身份 → 登录请求带内存临时 dfid → 服务端风控拒绝或生成新设备，表现为「登录成功但秒掉」，难排查。

### lib/features/auth/data/auth_repository.dart:56-57 `catch (_) {}` 在 getDfid 中空吞注册失败
- 级别：P2
- 事实：`try { ... /register/dev ... } catch (_) {}`，随后 `return ''`。空体捕获。
- 违反：第 6 条（空捕获）；第 9 条（失败不可观测）
- 后果：设备注册接口挂掉时用户登录流程静默以 dfid='' 继续，登录可能被服务端拒（或降级到无 dfid 签名），失败原因零留痕。

### lib/features/auth/data/auth_repository.dart:164-226 restoreSession 的降级路径异常形态不一致 + catch(_) 双层嵌套
- 级别：P2
- 事实：非 DioException 的异常走 `catch (_) { try getUserDetail ... } catch (_) { return _degradedUser(cred); }`。两级空捕获；且 `getUserDetail` 成功时构造的 AuthUser token 来自 cred（OK），但若 `getUserDetail` 抛的也是网络错，返回 `_degradedUser`——「网络失败降级」与「逻辑错误降级」（第 10 条）未区分：类型错误/空引用也被当弱网处理。
- 违反：第 6 条（空捕获）；第 10 条（编程错误进入业务降级）
- 后果：restoreSession 内部的编程错误（如 SecureStorage 数据形态变化引发 TypeError）被伪装成「弱网降级」，用户登录态看似恢复但后续请求行为异常，线上无从定位。

### lib/features/auth/data/auth_repository.dart:354-359 _handleLoginSuccess 往 settings box 写 nickname/avatar——跨模块同一 box 双写者
- 级别：P2
- 事实：auth_repository 与 auth_providers 的 logout、settings_provider（themeMode/locale/lyricDisplayMode）共用 `Hive.box('settings')` 且均为 `Box<dynamic>`。登录态数据（nickname/avatar）混入设置盒。
- 违反：第 5 条（登录资料已在 AccountManager + SecureStorage 有权威源，settings 是第三处副本）；第 1 条（box 职责不清）
- 后果：登出时 auth_providers 删 'nickname'/'avatar' 两个 key，但 AccountManager.upsert 的其它写入（t1 等）与 settings 内容可能不一致——设置页显示的「当前账号」来自副本，登出失败半途时页面仍显示旧昵称（见 logout 的 try/catch(_) 包裹 box.delete，第 6 条又一次空捕获）。

### lib/core/cache/cache_manager.dart:14-22 MemoryCache 键不含登录身份维度（第 23 条硬伤）
- 级别：P1
- 事实：`keyOf(path, query)` 只拼 path+query；登录态变化后 main.dart 只 invalidate 了 Riverpod provider（homeDataProvider/library*），但 **MemoryCache 本身没有任何 removeWhere(登录相关前缀) 调用**——凡直接走 MemoryCache 的请求层（键如 '/yueku...'）在切号/登出后 90 秒内仍返回旧账号身份的数据。
- 违反：第 23 条（用户身份是影响结果的第一维度，未进缓存键）
- 后果：切换账号后最多 90 秒内，「每日推荐/排行榜歌单/收藏」等命中内存缓存的页面显示前一个账号的内容——正是任务书点名的跨模块串数据，测试环境难以复现。
- 佐证：全文件无任何「登出时清 MemoryCache」的钩子；MemoryCache.clear 只挂在 didHaveMemoryPressure。

### lib/core/cache/cache_manager.dart:77-89 翻译缓存键变更后旧键永久残留
- 级别：P3
- 事实：B-29 修复把键改为 `'id:lang@model'`，但 `clear()` 无人调用（全项目检索见下），旧格式的 `'id:lang'` 键永久留在 lyric_translations box，无迁移/清理逻辑。
- 违反：第 32 条精神（废弃数据留存）；第 25 条（box 无体积上限与过期机制）
- 后果：磁盘上死数据持续累积；若用户历史上缓存过大量歌词，box 体积只增不减。（P3 因功能不受影响，属整洁度+存储泄漏。）

### lib/core/cache/cache_manager.dart:96-103 get 解析行 `int.parse` 无防护
- 级别：P2
- 事实：`map[int.parse(line.substring(0, idx))]`——box 内容若损坏（异常字符行），int.parse 抛 FormatException，get 直接炸，调用方（歌词渲染路径）无兜底。
- 违反：第 13/14 条（磁盘读取是边界，未逐行验证）
- 后果：一行损坏缓存数据可让歌词翻译功能在特定歌曲上每次抛异常（按调用方 catch 情况表现为译文不显示或红屏片段）。

### lib/core/storage/secure_storage.dart:65-75 logout/登出后 dfid 双源不一致风险（与 kg_providers B-10 相关）
- 级别：P3
- 事实：dfid 权威源在 Hive device box，SecureStorage 里的 dfid 仅在 login 时写入（saveCredentials），**登出时不再同步**——但 clearCredentials 注释明确决定保留 dfid（F-1），行为自洽；但 `_handleLoginSuccess` 里 `dfid = await getDfid()`（auth_repository.dart:342）优先读 SecureStorage，而直连链路注册新 dfid 时只更新 Hive + SecureStorage（onDfidRegistered）——两条写路径并发时（登录中触发设备注册）无锁。
- 违反：第 22 条（并发假设未写明：登录与设备注册可同时写 dfid 双存储）
- 后果：极端时序下登录写入的 dfid 被注册回调覆盖，下次请求签名 dfid 与 cookie 不匹配 → 服务端风控，表现为登录成功后部分接口 401/参数错误。

### lib/core/storage/secure_storage.dart:76-78 saveDfid fire-and-forget 无失败重试
- 级别：P3
- 事实：kg_providers.dart:83-87 `SecureStorage.instance.saveDfid(dfid).catchError(...debugPrint...)`。SecureStorage 写失败（磁盘满/ Keystore 异常）后 Hive 是新 dfid、SecureStorage 是旧 dfid，下次 getDfid/auth 流程读到旧值。
- 违反：第 9 条（失败仅 debugPrint，release 模式不可见）；第 5 条（双源，无一致性校验）
- 后果：与上一条同源——设备标识双存储漂移，触发风控类「莫名验证」。
- 佐证（grep）：MemoryCache 清理点仅 3 处（memory pressure / 设置页手动清缓存 / playlist_repository 前缀清除），**登出与切号路径均不清**，上一条 P1 成立。LyricTranslationCache.clear 仅设置页手动触发，B-29 旧键残留成立。

### lib/features/player/player_provider.dart:41-48 playerRepositoryProvider 副作用隐藏在 Provider 构建中
- 级别：P2
- 事实：`ref.watch(kgClientProvider);` 的注释说「预热直连客户端，确保首次播放前设备身份已就绪」——实际上 `watch` 一个惰性 Provider 只是**构建** KgClient 对象，并不会注册设备（注册在 KgClient 内部首次请求时触发，需核实）。注释宣称的效果与代码实际行为不符。
- 违反：第 31 条（注释误导：声称「预热」实际只是实例化）；第 2 条（副作用隐藏）
- 后果：若未来有人删掉这行「看似无用」的 watch，行为不变但没人能判断影响；更糟的是开发者以为播放前设备已注册，实际首次播放仍要走注册流程（首播延迟 1-3s 或弱网下首播失败）。

### lib/features/player/player_provider.dart:128-133 播放器全链路与登录态零关联
- 级别：P1
- 事实：全部 player provider 依赖图只到 audioHandlerProvider→playerRepositoryProvider→kgClientProvider。**没有任何 provider watch authStateProvider**；播放链路依赖 main.dart 里 listen 回调给 client 灌 token（见前述 P1）。也就是说「播放权限（VIP 试听判定）」的输入 token 是隐式的、经 UI 层旁路注入的。
- 违反：第 5 条（登录态→播放权限的传播不经依赖图，是隐式旁路）；第 2 条
- 后果：登出后已加载的 playerRepository/audioHandler 不重建，内存中的播放队列仍以旧账号身份续播/自动切歌——登出后下一首仍能播 VIP 曲目（服务端校验前）或反之正式曲被当试听；切号后音质档位判定沿用旧账号权益。

### lib/features/player/player_provider.dart:101-106 verificationStreamProvider 首个 yield null 值有语义冲突
- 级别：P3
- 事实：`yield null;` 后再 yield 事件——null 表示「无验证」，但监听方（router 的 VerificationListener）若以 `!= null` 判定弹窗，首次 null 无害；若以 AsyncValue 变化判定，则难以区分「初始」与「重置」。
- 违反：第 3 条（null 语义双重：初始 vs 清除，契约未写明）
- 后果：验证弹窗关闭后再触发同类验证时可能不弹（事件值相同被视为无变化），用户卡在播放失败无提示。

### lib/l10n/app_zh.arb:507 + app_en.arb:496-503 「previewOnly / loginRequiredTitle / loginRequiredHint / loginRequiredAction」英文键为中文原文（语义漂移/缺失翻译）
- 级别：P2
- 事实：app_en.arb 中：
```json
"previewOnly": "试听",
"loginRequiredTitle": "需要登录",
"loginRequiredHint": "该功能需要登录酷狗账号后使用。",
"loginRequiredAction": "「{action}」需要登录后才能使用。",
```
英文界面直接显示中文文案。同理 `@logoutConfirm` / `@hotSearchLoadFailed` 等元数据 description 仍是中文（元数据不影响运行时，仅列作整洁度）。
- 违反：第 30 条（键名与值语义错位）；第 1 条（本地化交付物职责——en 文件混入源语言内容）
- 后果：英文用户在收藏/评论/VIP 等场景弹出「需要登录」「试听」等中文提示，界面中英混排，观感等同功能 bug。

### lib/l10n/app_zh.arb:494-499 vs app_zh_CN.arb 同键语义漂移（双 zh 源不同步）
- 级别：P2
- 事实：l10n.yaml 模板是 **app_zh_CN.arb**，但 app_zh.arb 里 `downloadOpenFileFailed`（zh_CN「打开失败，未找到可用的应用」/ zh「打开文件失败」——zh 丢失「未找到可用应用」关键信息）、`downloadFallbackHint` 同样两版文案不同；且 `albumPageComingSoon` 只存在于 app_zh.arb、**不在模板 zh_CN 中**。
- 违反：第 5 条（zh 与 zh_CN 两份事实源漂移，无单一来源）；第 14 条（非模板语言键集不受 gen 校验，缺失静默回退）
- 后果： Album 页占位键实际生效的是 zh_CN 的模板值；zh 用户下载失败提示与 zh_CN 用户不一致；albumPageComingSoon 若被引用且 gen 未纳入，编译期取决于 gen-l10n 的容错行为（未编译验证，标为未验证）。

### lib/l10n 键集对照结论（脚本核实）
- 级别：P3
- 事实：zh 独有键 `albumPageComingSoon`（en 缺失，英文回退到模板值或报缺——nullable-getter:false 下 gen-l10n 对模板含而 en 缺的键会回退模板文案）；en 独有键无；占位符集合两语言完全一致。
- 违反：第 3 条（en 的交付契约不完整）
- 后果：英文界面专辑搜索结果占位文案回退中文（同上第一条后果）。

### lib/l10n/l10n.yaml:3 vs lib/core/config/app_config.dart:43 模板文件声明自相矛盾
- 级别：P2
- 事实：l10n.yaml：`template-arb-file: app_zh_CN.arb`；而 AppConfig 注释宣称「app_zh.arb（裸 zh）是 l10n 工具的模板文件」。两处对「谁是模板」的说法相反，实际生效的是 l10n.yaml（zh_CN）。
- 违反：第 30 条（注释/文档与事实不符）；第 5 条（单一来源认知混乱）
- 后果：后续开发者按 AppConfig 注释往 app_zh.arb 加新键（如 albumPageComingSoon 就是这么漏的），gen-l10n 不校验，键不进 AppLocalizations 抽象——引用处编译报错或运行期缺失，英文/其它语言永远拿不到译文。

### .github/workflows/keystore.b64.txt 签名 keystore 以 base64 明文提交进仓库
- 级别：P0
- 事实：`.github/workflows/keystore.b64.txt` 内容即 PKCS#12 keystore 的 base64（文件头 `MIIRNgIBAzCCEOAGCSqGSIb3DQEHAaCC...`），而 CI 正确路径是从 `secrets.ANDROID_KEYSTORE_B64` 读取——仓库里这份是配置期残留副本。
- 违反：第 14 条边界之外的密钥管理纪律（QUALITY_STANDARD 无专条，按 P0 级定义「安全泄露」判定）
- 后果：任何拿到仓库的人可以伪造带正式签名的 APK 冒充本应用发更新（升级劫持）；keystore 泄露不可撤销，只能换签名+全量重装。必须立即从仓库历史移除并更换 keystore。

### pubspec.yaml:5 / .github/workflows/build.yml:138 build-number 双源：GITHUB_RUN_NUMBER 覆盖 pubspec +34
- 级别：P3
- 事实：`version: 3.3.0+34`，但 release 构建 `--build-number="$GITHUB_RUN_NUMBER"`——Android versionCode 实际是 CI run number，与 pubspec build 号无关。版本一致性检查只比对 version 部分。
- 违反：第 5 条（build 号两个来源，pubspec 的 +34 形同虚设）；第 30 条
- 后果：应用内「版本」显示 3.3.0+34，而系统设置里 versionCode 是另一个数；升级比较逻辑若用 versionCode 会与本地认知错位（run number 可能小于历史 +34）。轻微，故 P3。

### .github/workflows/build.yml:8-10 触发条件：PR 只跑 analyze-test，PR 不产出可安装产物（合理）；push 非分支事件即 build-apk（含无 tag push 重复构建 debug）——记录为观察
- 级别：P3
- 事实：`if: startsWith(github.ref, 'refs/tags/') || github.event_name == 'push' || workflow_dispatch`——任何 push 都会构建 debug APK 三套 split，tags 时又额外 release。资源消耗型问题，无用户可见后果，按纪律降为观察项。
- 违反：无直接条款（第 26 条精神：无谓开销）。
- 后果：CI 时长翻倍，与用户无关。

### 版本一致性核查结论
- pubspec 3.3.0+34 ↔ tag v3.3.0：release job 有强制校验（build.yml:145-153），一致 ✅
- 代码内无硬编码版本常量（设置页走 package_info_plus），无双源 ✅
- AppConfig 无 version 字段，l10n 双源问题见上 ✅/❌

---

## 全局监听与事件流订阅者清点（三条流）

### 流 1：authStateProvider（Riverpod AsyncNotifier）
| 订阅者 | 方式 | 生效条件 | 问题 |
|---|---|---|---|
| main.dart `_TiernanMusicAppState.build` | ref.listen | 仅当 MaterialApp 处于树上 | 同步体被 try/catch 吞（P1）；闭包世代竞态（P2） |
| main.dart → homeDataProvider | invalidate | 同上 | ✅ |
| main.dart → libraryUserPlaylists/CollectedMvs | invalidate | 同上 | ✅（v3.3 修复） |
| 播放链路 | **无** | — | 不刷新，token 靠 main 旁路灌入（P1） |
| 设置页当前账号显示 | Hive settings 副本 | 登录/登出显式写删 | 副本可能不同步（P2） |

### 流 2：AccountManager.onCurrentAccountChanged（Stream 广播）
| 订阅者 | 问题 |
|---|---|
| library_page.dart:45 | 唯一订阅者。首页/搜索/歌单详情/播放页均**不监听**——切号后这些页面靠 main 的 invalidate 兜底，但 invalidate 只清 Riverpod provider，**不清 MemoryCache（90s TTL 内旧账号数据照旧命中）**（P1 根因） |

### 流 3：onAppLifecycle（WidgetsBindingObserver）
| 订阅者 | 问题 |
|---|---|
| downloadManagerProvider | 唯一订阅者。resume 时无人校验 token 有效性/刷新每日推荐（P2） |

## 登录态传播路径图（文字版）

```
SecureStorage(credentials)          Hive('device')          Hive('accounts'→AccountManager)
        │  restoreSession()              │                       │
        ▼                                │                       ▼
authStateProvider (AsyncNotifier<AuthUser?>) ◄── setUser/switchAccount/logout
        │
        ├─[ref.listen @ main.dart UI 层]──► invalidate home/library providers
        │                                 └► KgClient.token/userid/t1  ◄── 隐式旁路(P1)
        │                                     │
        │                                     ▼
        │                    player/home/playlist repository（间接、无世代校验）
        │                                     │
        │                                     ▼
        │                    MemoryCache(90s)  ← 键无 uid 维度，登出/切号不清 → 串数据(P1)
        │
        └─[无监听]──► playerProvider 全家 / settings 副本 / CI 版本链
```

## 问题清单（按级别）

**P0（1）**
1. keystore.b64.txt 明文提交仓库——签名泄露（.github/workflows/）

**P1（3）**
2. main.dart:267 登录态同步体被空 catch 吞，冷启动恢复期 token 丢失无补偿
3. cache_manager.dart:14 MemoryCache 键不含用户身份维度 + 登出/切号不清缓存 → 90s 串数据
4. player_provider.dart:128 播放链路与登录态零依赖关联，登出后旧身份续播

**P2（10）**
5. main.dart:231 生命周期事件仅下载管理器订阅，resume 不校验登录态
6. main.dart:254 登录态→client 同步写在 UI 层，无 provider 依赖保障
7. settings_provider.dart:9 settings box 降级静默、设置每次重置
8. settings_provider.dart:17 Box<dynamic> 脏数据 as 强转崩启动
9. auth_providers.dart:47 登出→登录竞态，t1 世代未校验
10. auth_repository.dart:33 AuthRepository 裸 new 产生无配置客户端
11. auth_repository.dart:56 getDfid 空捕获，注册失败零留痕
12. auth_repository.dart:164 restoreSession 编程错误进业务降级
13. auth_repository.dart:354 nickname/avatar 第三副本混入 settings box
14. l10n app_en.arb 四键中文原文（previewOnly/loginRequired*）+ albumPageComingSoon 键集缺失 + zh/zh_CN 漂移 + 模板声明矛盾（合并计 1 条，4 个文件证据）

**P3（7）**
15. main.dart:241 memory pressure 清缓存无留痕
16. cache_manager.dart:77 B-29 旧翻译键永久残留
17. cache_manager.dart:96 翻译缓存解析 int.parse 无防护
18. secure_storage.dart:65 dfid 双存储并发写无锁 / saveDfid fire-and-forget
19. player_provider.dart:41 「预热」注释误导
20. player_provider.dart:101 verificationStream null 语义双重
21. pubspec/CI build-number 双源（GITHUB_RUN_NUMBER）

## 统计
- 总计 21 条：P0×1、P1×3、P2×10（其中 l10n 合并 4 处证据计 1 条）、P3×7
- 最高优先 3 条：keystore 泄露（P0）＞登录态同步空 catch（P1）＞MemoryCache 无身份维度（P1）
- dart analyze：4642 条告警，绝大多数为 Flutter 缺包噪音（override_on_non_overriding_member 等均因 SDK 未解析），本档范围内无新增 Flutter 符号未核对 import 的情况；l10n 生成文件有未用元素警告（生成物，不计）













