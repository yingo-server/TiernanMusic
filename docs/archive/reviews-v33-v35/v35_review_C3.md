# v3.5 C 批·审查③：main + router + l10n + 配置层（v35_review_C3）

基线 5d84c63（工作分支 HEAD，"docs: v3.5 C 批启动"）。定位：本档为 v3.5 C 批第③份，覆盖**此前从未单独成档**的 main.dart / app_router.dart / l10n 全量 / pubspec / CI / AndroidManifest / network_security_config / analysis_options / app_theme（isDark 复认）。

硬性规则遵守：全部文件完整逐行 file_read（main 382 / router 145 / build.yml 210 / Manifest 71 / nsc 24 / pubspec 73 / analysis_options 8 / app_theme 278 / app_localizations.dart 3772 生成物 + tool/gen_l10n_min.py 147）；未编译未装包；l10n 用 python 程序化校验（静态文本比对，不属编译/装包）；**噪音过滤只适用于 Flutter SDK 符号**；跨文件改动双向核对。dart analyze 未使用（本档以通读 + 程序化文本校验为准）。

---

## 一、lib/main.dart（382 行，全文读完）

### ✅ 核对通过项（V34-C-02/03 + V35-A3 世代号修复后全量复核）

- **启动编排**：runZonedGuarded 包裹全启动 → FlutterError.onError / ErrorWidget.builder 先行接管 → Hive.initFlutter + 7 个 box 逐个 openSafe（单个失败不阻断，:58-70）→ Cookie 目录就绪（:74-81）→ 设备身份三重兜底（box 加载 → KgDevice.generate → StateError 进 _startupError，:84-107）→ **无论如何 runApp**（不卡原生启动屏）。每个 catch 都有 debugPrint 留痕或进 _startupError（第 6/9 条 ✅）。
- **音频服务**：`AudioServiceBootstrap.start()` 只发起不等待，注释写明「原先 await+timeout(8s) 超时放弃但底层未就绪 → LateInitializationError」的历史原因（第 31 条 ✅）。播放前 ensureReady 等待——双向核对：bootstrap 与 handler 的衔接在 audio_handler 侧（B1 批已审）。
- **启动看门狗**：15s 首帧未渲染留日志；`_watchdog` 首帧 post-frame 内 cancel + 置 null，Timer 生命周期对称（第 20 条 ✅）。
- **V34-C-02 回归**：authState listen 回调不再套单一空 catch；`applyAuth()` 各步骤独立，异常走 200ms 延迟重试一次，重试仍失败 debugPrint 留痕（第 11 条降级有恢复条件 ✅）。
- **V35-A3 世代号回归**：`authEventGeneration` 每次 listen 回调 `++`，重试闭包捕获 `generation` 快照，200ms 后 `generation != authEventGeneration` 则跳过（第 18 条 ✅）。**注意**：generation 是 `build` 方法内的局部变量（:225 `var authEventGeneration = 0;`），随 `_TiernanMusicAppState` 每次 build 重建——但 `ref.listen` 在 riverpod 中注册回调本身是幂等的（同 provider 重复 listen 只保留一个），计数器随 build 重置不会产生跨 build 的代际错乱：build 重置后第一条新事件 generation=1，旧回调不会并存（WidgetRef.listen 在 build 中调用，旧 build 的 listen 随帧失效）。核对通过。
- **V34-C-03 回归**：切号/登出/登录均走 `MemoryCache.instance.clear()`（:259），缓存键缺用户维度（B-15）的串数据窗口被根修——双向核对：MemoryCache 唯一 clear 调用点补齐（main + didHaveMemoryPressure），✅。
- **t1 读取**：`readCredentials().then(...).catchError(...)` 异步路径有留痕 ✅；user==null 时直接清 t1，与 SecureStorage 异步读不竞态（登出分支同步先行，后续 then 只在 user!=null 分支）✅。
- **启动屏时序**：`_appReady`（首帧）+ `_splashMinElapsed`（HandwritingCycle.minVisible，:162 `writeEndMs+200`）双条件；`_splashTimer` dispose 对称取消（第 20 条 ✅）。
- **三条事件流接线**：① `recentPlayRecorderProvider` watch 激活（provider 内部 `ref.onDispose(sub.cancel)` 对称 ✅）；② `playerErrorProvider` listen → Toast（ctx.mounted 守卫 ✅）；③ `authStateProvider` listen（上述）。第四条 `verificationStreamProvider` 由 router 层 VerificationListener 承接（见 §二）✅ 无漏接。
- **didChangeAppLifecycleState / didHaveMemoryPressure** 转发正确 ✅。

### main.dart:52-55 ErrorWidget.builder 全局替换为 StartupErrorPage——构建期异常的可见性损失
- 级别：**P2**
- 事实：`ErrorWidget.builder` 被替换为 `StartupErrorPage(error: details.exception, compact: true)`，**全程生效**（不是只在启动阶段）。它把所有 build 期异常（包括已上线功能里的布局/类型异常）渲染成一个深蓝底、青色图标的页面，用户无法从错误页**返回或继续**（无手势返回目标时整页死锁）；且 `compact` 模式只显示异常文本，丢失堆栈。FlutterError.onError 已留痕，但 UI 层用户被卡死在错误页——对一个用户来说，「整页变成错误页且无法退出」比红屏更糟：红屏至少在 debug 下可复制信息，release 下红屏会灰屏崩溃退出（进程结束），而本实现**吞掉异常继续活着**，用户只能杀进程。
- 违反：第 10 条（编程错误绝不进入业务降级——build 异常属实现缺陷，被当成「可展示的业务错误页」兜底）；第 9 条反面（无退出路径的降级）。
- 后果：任何页面一旦出现构建异常（哪怕单个 tile），整页永久替换为错误页，用户无法返回上一页，只能杀进程重启。
- 修法：ErrorWidget.builder 内保留简短提示 + 一个「返回首页」按钮（Navigator.popUntil 到 '/home'），或仅对 _startupError != null 时使用该页。

### main.dart:110-124 runApp 失败后 runZonedGuarded 静默继续
- 级别：P3
- 事实：`runApp` 包 try/catch，失败仅 debugPrint（:120）。此路径下进程继续活着但没有任何 UI（原生启动屏也已被 Flutter 接管标志破坏），看门狗 15s 后会打一条日志。可接受（第 9 条有留痕），但此时进程是「僵尸态」，无恢复手段。记录不计正式问题（极端异常路径，runApp 失败通常意味着引擎层故障）。

### main.dart:38-40 顶层可变全局 `_startupError/_firstFrameRendered/_watchdog`
- 级别：P3
- 事实：三个顶层 `var`/`Timer?`。单 main 入口下安全（第 22 条隐含单线程假设未显式声明，但 Dart 单 isolate + 一次性调用，风险为零）。**命名即文档**角度，`_firstFrameRendered` 与 `_watchdog` 若被未来代码在别处触碰会产生跨入口污染。轻微，不构成正式问题（第 22 条：前提真实存在且入口唯一）。

---

## 二、lib/core/router/app_router.dart（145 行，全文读完）

### ✅ 核对通过项
- StatefulShellRoute.indexedStack 四分支 + `goBranch(i, initialLocation: i == shell.currentIndex)` 再点当前 tab 回到该分支初始页 ✅。
- `/rank/:rankId`：`int.tryParse` 失败或 ≤0 渲染错误 Scaffold（V33-03/B-39 修复在位，第 14 条 ✅）。错误文案「排行榜参数无效」硬编码中文——深链参数非法属极边缘路径，其余页面全走 l10n，此处不一致（P3，归入 i18n 遗留，见 §三 #8 汇总）。
- `/mv/:hash`、`/comments/:type/:id`、`/playlist/:id`：pathParameters 非空断言 `!` 依赖 GoRouter 路由模板保证（模板里有 `:id` 则必非空——同函数体内已被路由匹配证明，第 12 条允许范围 ✅）。
- `userListId: state.uri.queryParameters['user']` 可空传入，PlaylistDetailPage 内部处理（跨文件契约：playlist_detail_page 双数据源已审 ✅）。
- MainShell：VerificationListener 包裹 ✅（20028 链路双向核对：audio_handler 发 verificationRequired → listener `_handling` 防重 → CaptchaPage → retryPendingPlayback 消费 `_pendingSongIndex`，契约闭环）。
- MiniPlayer 常驻底栏 + NavigationBar 组合，mainAxisSize.min ✅。
- F4-31 底部导航文案走 l10n ✅（`context.l10n.home/search/library/settings` 四键在 arb 中存在，双向核对 ✅）。

### app_router.dart:37-41 全部 builder 使用 `(_, __)` 丢弃 context/state——无问题，但 `(_, __)` 中 `__` 触发 lint（avoid_underscore_prefixed? 否，Flutter lint 默认允许）。核对通过，无正式问题。

---

## 三、l10n 全量（11 个 arb + app_localizations.dart 生成物 + tool/gen_l10n_min.py 生成器）

### 校验方法（程序化，python3 静态文本比对）
1. 键集一致性：11 个 arb 两两比对键集。
2. dart 生成物 vs 每个 arb：键缺失 / 值漂移 / dart 独有键。
3. getter 覆盖：`String get X` / `String X(...)` vs 模板键集。
4. 占位符：arb 值中 `{name}` 使用 vs `@key.placeholders` 声明。
5. 死键：`l10n.<key>` 全仓引用 vs 模板键集。

### 结果 A：键集一致性（任务重点①）——通过，1 处已知例外
- zh_CN（模板）/ de / en / es / fr / ja / ko / pt / ru / zh_TW 全部 **328 键完全一致**。
- `app_zh.arb`（裸 zh）**329 键**，多出 `albumPageComingSoon`——该键在其它 10 语言（含 zh_CN 模板）中均不存在，且生成物 `_strings_zh` 里也没有它（生成器以 zh_CN 为模板取键，zh 独有键被静默丢弃）→ **zh 独有键为死数据**（第 32 条，P3，见问题 #3）。PROGRESS 记载 v34 已知此项「留 UI 批收尾」，至今未收尾。
- l10n.yaml：template=app_zh_CN.arb，output-dir=lib/l10n ✅ 与生成器一致。注意 `generate: true`（pubspec :73）与「离线生成器 + 固定 output-dir」并存——`generate: true` 会让 Flutter 在构建时尝试 synth 生成本地化到 `.dart_tool`，与本手写生成器**并行不冲突**（代码 import 的是 lib/l10n/app_localizations.dart），但这是双轨配置，pubspec 的 `generate: true` 实际无人消费其产物。P3 双轨（见 #5）。

### 结果 B：dart 生成物 vs arb（**本档最重要的发现**）——**P1：生成物落后于 arb，23 个键三处脱节**

对每个语言比对「arb 键 → dart `_strings_<lang>` 键 → getter 集合」，发现**同一批 23 个键在三个层面同时缺失**：

| 层面 | 缺失键（23 个，所有 11 语言一致） |
|---|---|
| dart `_strings_*` 无此键 | addedToPlaylist, playlistNameEmpty, captchaLoadFailed, captchaSmsTitle, captchaSmsHint, captchaSmsCodeLabel, captchaSmsCodeHint, captchaSubmit, captchaNotPassed, captchaPassedButRetry, captchaSubmitFailed, captchaTencentHint, captchaExternalHint, captchaClose, captchaUnknownType, captchaNoVerifyUrl, captchaTryFingerprint, lyricEmptyGuide, downloadEmptyGuide, reloginGuide, mvCollectGuide, mvUnavailable, downloadFolderFallback |
| getter 段无此 getter | 同上 23 个（getter 共 307 个 vs 模板 328 键） |
| 代码引用 | `addedToPlaylist`（add_to_playlist_sheet.dart:96）、`playlistNameEmpty`（:118）**两处在编译期就会报错** |

- **级别：P1**
- 事实：`add_to_playlist_sheet.dart:96` 调 `context.l10n.addedToPlaylist`、`:118` 调 `context.l10n.playlistNameEmpty`（C2 批 V35-C2-1/2 修复时新加的调用），而 `app_localizations.dart`（「GENERATED CODE - DO NOT MODIFY BY HAND」）的 getter 段只生成到 307 个——这两个 getter 不存在，`dart analyze` 必报 `undefined_getter`，`flutter build` **必然失败**。arb 侧 11 语言键都在（键集一致性校验通过），缺的是**生成步骤没有重新执行**：tool/gen_l10n_min.py 以 zh_CN 为模板取键，arb 键是齐的，说明有人往 arb 加了 23 个键后没有重跑生成器。
- 违反：第 3 条（契约：arb 是唯一文案源，生成物必须随 arb 同步）；CI 链完整性（见 §五：analyze-test job 会先于 build 挂掉）。
- 后果：**CI 全红**（flutter analyze 报 undefined_getter ×2 + flutter test 编译失败）→ tag 无法出包；本地任何构建同样失败。用户可见后果 = 新版本无法发布。
- 修法：重跑 `python3 tool/gen_l10n_min.py`（生成器本身正确：按模板键序生成、按名替换占位符）。这是纯生成步骤遗漏，不是生成器缺陷。
- 备注：另有 40 个「值漂移」的键（arb 已改、dart 是旧译文），典型：`captchaTitle`（en arb='Verification' vs dart='Human-Machine Verification'）、`loginRequiredTitle/Hint/Action`、`previewOnly`（arb 各语言均有译文，dart 8 个语言全是中文'试听'）、`licenseBody` 全语言、fr 的 40 处（多为转义形态差异 `\\'` vs `'`——其中 fr 值漂移实为转义表示差异，语义相同；但 captchaTitle/previewOnly/loginRequired* 是**真实语义漂移**：dart 侧 previewOnly 在 de/en/es/fr/ko/pt/ru 显示为简体中文'试听'）。
- 值漂移细分类（不重复计问题，统一归入 #1 的修复动作「重跑生成器」即可全部消除）：
  - 真实漂移（用户可见）：previewOnly ×7 语言中文、loginRequiredTitle/Hint/Action ×10、captchaTitle ×10（ru dart='Проверка человека' 语义错误「人的检查」）、部分 zh_TW（previewOnly dart=简体'试听'）。
  - 转义形态差异（语义等价）：fr 34 处 `\\'`、licenseBody 的 `\\n`（生成器 esc 把 `\n` 转成 `\\n` 字面量写入 dart 源码，dart 字符串里 `\\n` 解析回 `\n`，行为正确，仅比对工具视角差异）。

### 结果 C：@meta 占位符完整性（任务重点③）——通过
- 模板 40 个 @meta：每个带占位符的键都有 placeholders 声明；13 个 meta 缺 `description` 字段（gen_l10n_min.py 不消费 description，无功能影响——Flutter 官方 gen-l10n 也不强制）。
- 全部 328 键的「值中使用的 {占位符}」与「@meta 声明」**零失配**。
- 生成器 `sig()/call_expr()` 按 placeholders 声明生成参数（多参时参数顺序取 dict 迭代序 = JSON 写入序，与 `r()` 按名替换解耦，不会错位——生成器 :96-101 注释也写明了这个设计）✅。

### 结果 D：语义漂移抽查（任务重点②）
抽查 14 个高危键 × 10 语言（vipOnly/tryListen/noCopyright/qualityFlac/captchaTencentHint/downloadFallbackNotice/previewOnly/accountNeedRelogin/wifiAutoHighQualityDesc/networkErrorHint/playlistUnavailableSoon/mvQualitySelect/reloginGuide/mvCollectGuide），arb 层面**质量良好**：
- `tryListen`（ko '듣기 체험'）与 `previewOnly`（ko '미리듣기'）同义不同形——两键本就是「试听」一词的重复（P3 语义重复，#4）。
- `mvQualitySelect` zh='清晰度' en='Clarity' ja='解像度' de='Auflösung' pt='Resolução'——中英用「清晰度/Clarity」，日德葡用「分辨率/Resolução」，韩'화질'（画质），俄'Чёткость'（锐度）。语义族漂移但用户可理解，P3。
- `qualityFlac` ru='Потерь нет FLAC'——生硬直译（应为 «Без потерь FLAC»），P3 文案。
- `wifiAutoHighQualityDesc` 各语言均保留「（预留）」标注——与 settings_page 已删假开关呼应：**这两个键是死键**（见结果 E）。
- 其余键语义一致 ✅。

### 结果 E：死键全量（`l10n.<key>` 全仓引用比对）
328 键中 **77 个键无任何 `l10n.` 引用**（含方法形式）。但其中 61 个键实际在生成物里没有 getter（上面 23 个 + 若干），不构成「死代码」而是「脱节」。**真正的死键**（有 getter、无人调用）：
- `wifiAutoHighQuality / wifiAutoHighQualityDesc`（V34-UI-04 假开关已删，C2 #13 已记）——C2 消化记录说「待修」，至今仍在。
- `captchaHint`（captcha_page 现用其它键）。
- `tryListen` vs `previewOnly` 二选一（两者 getter 都在，`previewOnly` 被引用，`tryListen` 死）。
- 其余经查多数通过 `context.l10n.xxx` 之外的路径不适用——精确引用数为 251 个被引用键，77 未引用中需人工甄别 61 个是「getter 缺失」而不是死键。

### l10n 结论清单（问题按级别）
| # | 位置 | 级别 | 标题 |
|---|---|---|---|
| 1 | tool/gen_l10n_min.py 产物 lib/l10n/app_localizations.dart | **P1** | 生成物落后 arb 23 键 + 40 键值漂移；add_to_playlist_sheet 引用 addedToPlaylist/playlistNameEmpty 编译必败，CI 全红 |
| 2 | lib/l10n/app_zh.arb:429-430 | P3 | 裸 zh 独有键 albumPageComingSoon 三份遗留（arb / 生成器静默丢弃 / 无代码引用），第 32 条 |
| 3 | app_*.arb（各语言 previewOnly/tryListen） | P3 | 「试听」双键并存，tryListen 死键；ko 两键译法不一（듣기 체험/미리듣기） |
| 4 | app_*.arb mvQualitySelect / qualityFlac(ru) | P3 | 语义族漂移（清晰度 vs 分辨率 vs 画质）、ru 生硬直译 |
| 5 | pubspec.yaml:73 `generate: true` + 手写生成器双轨 | P3 | generate:true 产物无人消费；CI `flutter gen-l10n` 步骤（build.yml:46）实际生成到 .dart_tool，与 lib/l10n 生成物无关联——analyze/test 校验的是手写生成物，gen-l10n 步骤形同虚设（还可能因 arb 缺 description 告警） |

---

## 四、pubspec.yaml（73 行）/ pubspec.lock（不存在）/ analysis_options.yaml（8 行）

- **pubspec.lock 不存在**：应用程序仓库（非库）惯例应提交 lock 固定依赖；CI `flutter pub get` 每次解析最新兼容版本 → 依赖漂移可导致「昨天绿今天红」且不可复现。**P2**（第 3 条：构建契约不固定）。
- version 3.4.0+35；environment sdk >=3.4.0；`intl: ^0.20.3` 仅声明为直接依赖但**生成器刻意绕开 intl**（gen_l10n_min.py 用自写 `.r()`）——intl 实际是 flutter_localizations 的传递必需，声明无错。核对通过。
- 依赖与代码双向核对（抽样）：flutter_inappwebview（captcha_page ✅）、qr_flutter（设置页二维码登录 ✅）、package_info_plus（update_checker ✅）、permission_handler（download ✅）、crypto/pointycastle（kg_crypto ✅）、archive（KRC 解压 ✅）。无未使用依赖声明。
- **analysis_options.yaml**：flutter_lints 4 + 4 条启用规则。无 `analyzer.errors` 调优——CI `flutter analyze --no-fatal-infos --no-fatal-warnings`（build.yml:47）意味着 **warning 与 info 都不阻断**，只有 error 阻断。这与「analyze 报错即真错误」的批次纪律一致，可接受；但 `prefer_final_locals` 等规则产生的 info 全部放行，lint 形同虚设。P3（纪律口径问题，非缺陷）。

---

## 五、.github/workflows/build.yml（210 行）——keystore 移除后构建链完整性（任务重点③）

### ✅ 核对通过项
- 触发：push(main/master) + tag v* + PR + workflow_dispatch，tag 条件 `startsWith(github.ref, 'refs/tags/v')` 与 release job 一致 ✅。
- analyze-test job：pub get → `flutter gen-l10n` → analyze → test，三步顺序正确（analyze 前先生成本地化）✅。
- keystore 流程（P0 移除后）：`Restore keystore` step **仅在 `github.ref_type == 'tag'` 执行**，secret `ANDROID_KEYSTORE_B64` 未配置则 `::error::` + exit 1（tag 构建硬失败，不会静默出未签名包）✅；非 tag 构建（push/PR/dispatch）不解 keystore，走 debug 签名（debug APK 无条件构建上传）✅。android/app/build.gradle 侧：`tiernan.jks` 文件存在才挂 signingConfig，release 未签名时 Flutter 默认 debug 签名兜底——**release 构建在非 tag 分支也能跑通**（不出包不上传 release APK），链路自洽 ✅。
- keystore 密码：`System.getenv('KS_STORE_PASS') ?: 'tiernan123'`——**默认密码硬编码在 build.gradle**（配合已移除的 keystore.b64.txt 历史）。keystore 本体已移出仓库，且需用户轮换（PROGRESS 已记），此处默认密码属于「文件存在时才用」，风险依赖轮换动作。复认项，不升级（PROGRESS/keystore_setup.md 已通告）。
- `.github/workflows/keystore.b64.txt` 文件**仍存在于工作区**（5880 字节，11-02 时间戳）——git 索引已移除但文件残留本地；若该文件被再次 `git add -f` 或打包进 artifact 即复发。**P2 提醒**（非代码缺陷，工作区卫生）。
- Upload mapping / release APKs 仅 tag ✅；screenshots job continue-on-error（不阻断发布）✅。
- release job：版本号校验（pubspec version vs tag）→ 下载 artifacts → gh-release。needs: [build-apk, visual-review]，visual-review continue-on-error 不阻塞 ✅。

### ❌ 问题
### build.yml:46/108/… `flutter gen-l10n` 步骤与本项目的离线生成器双轨脱节
- 级别：P2（与 #1 P1 同根，但独立成立）
- 事实：l10n.yaml 存在（template zh_CN、output-dir lib/l10n），CI 三个 job 都跑 `flutter gen-l10n`。但 lib/l10n/app_localizations.dart 的头注释是「GENERATED CODE - DO NOT MODIFY BY HAND (offline gen-l10n equivalent) / See tool/gen_l10n_min.py」——**真实生成器是 python 脚本**。Flutter gen-l10n 会把 synth 包生成到 .dart_tool/flutter_gen，**不会**改写 lib/l10n/app_localizations.dart。于是 CI 的 gen-l10n 步骤对实际被 import 的文件零影响，arb→dart 的同步完全依赖开发者记得本地跑 python 脚本——没有 CI 步骤校验「生成物是否最新」（可加 `python3 tool/gen_l10n_min.py && git diff --exit-code lib/l10n/`）。#1 的 P1（23 键脱节）正是这条缺失守卫的直接后果。
- 违反：第 3 条（契约先行：arb↔dart 的同步契约无机器校验）。
- 修法：CI analyze-test 增加「重新生成 + git diff --exit-code」守卫；或废弃 python 生成器改用标准 gen-l10n（需补 @meta description 与 nullable-getter 语义核对，工程量大，不推荐现在做）。

### build.yml:41 `FLUTTER_VERSION: '3.47.9'` + android-36 / ndk 28.2.13676358
- 事实：SDK 版本写死；pubspec sdk 约束 >=3.4.0 与 3.47.9 兼容。核对通过（无法验证 3.47.9 是否真实存在的 Flutter 版本号——按第 29 条精神标注：**未验证**，若该版本号不存在 setup_flutter 会在 setup 阶段失败，属 CI 首跑即知的问题，不构成本档判定依据）。

---

## 六、AndroidManifest.xml（71 行）+ network_security_config.xml（24 行）——cleartext 域名表 vs 实际域名（任务重点④）

### cleartext 覆盖核对（程序化枚举 lib/ 全部 URL 字面量 vs nsc 白名单）
代码内全部域名（rg 枚举）：kugou.com 一级子域若干、**trackercdn.kugou.com / trackermv.kugou.com / openapi.kugou.com / complexsearch.kugou.com / verifyservice / userservice / login-user / loginserviceretry / gateway / ocean / msearch / lyrics / h5 / expendablekmr / musicadservice / m.comment.service**（全部 `*.kugou.com` 一级子域，被 nsc 首条 `kugou.com includeSubdomains=true` 覆盖 ✅）、二级子域 `service.mobile.kugou.com`（被 `mobile.kugou.com` 条目覆盖 ✅）、`kugouaudio.com`（nsc 有 ✅）、非酷狗域：`api.github.com`（update_checker，https）、`index-translate.bilibili.com`（https 翻译）、`proxy.344977.xyz`（https）、`kapi.344977.xyz`（https 仅 Cookie 占位不发请求）。**https 域无需 cleartext 白名单** ✅。
- B1 报告提过的 fsandroid/fsmobile：代码实测明文引用只有注释里的 `http://fsandroid.kugou.com/...`（kg_play_api.dart:21 注释）；**实际播放 URL 来自上游 downurl 字段**（http:// 形态），播放器直接以该 URL 出流——nsc 对 `fsandroid.kugou.com`、`fsmvpc.tx.kugou.com`、`fsandroid.tx.kugou.com`、`tx.kugou.com`、`kugouaudio.com` 均已放行 ✅。**fsmobile.kugou.com 未在 nsc 名单**（nsc 有 fsandroid/fsmvpc 无 fsmobile）：代码与注释均无 fsmobile 引用，B1 所述实测 CDN 域为 fsandroid 系——**判定：覆盖充分**，无缺口。
- `android:usesCleartextTraffic="false"` + nsc base-config false + domain-config 白名单——双层一致 ✅（manifest 属性与 nsc 并存时 nsc 优先，写 false 作冗余防御无害）。

### 权限 vs 实际使用（逐条核对）
| 权限 | 使用方 | 结论 |
|---|---|---|
| INTERNET | 全网络层 | ✅ |
| ACCESS_NETWORK_STATE | 音质自适应/下载判断（wifiAutoHighQuality 逻辑已删，剩下载前网络类型判断） | ✅ |
| WAKE_LOCK | audio_service 前台播放 | ✅ |
| FOREGROUND_SERVICE + FOREGROUND_SERVICE_MEDIA_PLAYBACK | manifest 内 AudioService foregroundServiceType="mediaPlayback" | ✅ 类型匹配 |
| WRITE_EXTERNAL_STORAGE(maxSdk 28) / READ_EXTERNAL_STORAGE(maxSdk 32) / READ_MEDIA_AUDIO | 下载/媒体扫描（B3 批已审） | ✅ 分版本声明规范 |
| POST_NOTIFICATIONS | 播放通知（audio_service） | ✅ |

### Manifest 其余核对通过项
- FileProvider exported=false + grantUriPermissions（下载分享链）✅；audio_service 组件名与 audio_service 0.18.x 包名一致 ✅；`android:label="汀澜音乐"` 硬编码中文（应用名不本地化——Play 生态常用资源化 `@string/app_name`，但桌面名走 onGenerateTitle 动态本地化，launcher 名固定中文是取舍。P3 不计问题，记录）。
- `singleTop` + configChanges 全量（含 locale|layoutDirection|fontScale）——语言切换不重建 Activity ✅（配合 in-app localeProvider 切语言，合理）。

---

## 七、app_theme.dart（278 行）——isDark 死代码复认（任务重点⑤）

### 复认结论：**确认死代码，P3 维持**
- `app_theme.dart:41` `final isDark = scheme.brightness == Brightness.dark;` 赋值后全文件（278 行）**零引用**（rg 计数=1，仅赋值处）。dart analyzer（unused_local_variable）会报 info，CI `--no-fatal-infos` 放行 → 永远不被发现。
- 违反：第 32 条（死代码零容忍）。
- 后果：无直接用户可见后果（A2 定 P3 正确）；lint 污染。
- 修法：删该行（一行删除，随批修）。

其余主题核对通过项：形状/动效 token 统一 ✅；chipTheme labelStyle 不带 color 的原因注释（第 31 条 ✅）；SearchBarThemeData textStyle 类型注释与实现一致 ✅；PageTransitionsTheme Android=FadeForwards / iOS=Cupertino ✅；无硬编码颜色绕过 scheme（StartupErrorPage 的 0xFF0B1622/0xFF00D4FF 是启动错误页特例——它在 MaterialApp 之外渲染，无 theme 可用，**合理豁免**）。

---

## 八、跨文件改动双向核对汇总（硬性条款）

| 改动点 | A 面 | B 面 | 结论 |
|---|---|---|---|
| V34-C-02/03 auth 同步拆 catch + 清缓存 | main.dart:230-289 applyAuth | kgClientProvider / MemoryCache（A2 已审）/ home/library provider invalidate | ✅ 双向在位 |
| V35-A3 世代号 | main.dart:229-247 generation | authStateProvider（AsyncNotifier）事件源 | ✅ |
| V35-C2-1/2（C2 批修复） | add_to_playlist_sheet:96/:118 新增 l10n 调用 | **app_localizations.dart getter 未生成** | ❌ 断裂（§三 #1，P1） |
| F4-31 底部导航 l10n | app_router.dart:117-127 四键 | arb home/search/library/settings 存在 | ✅ |
| V33-03 rankId 校验 | app_router.dart:82-90 | RankDetailPage 消费 int | ✅ |
| 20028 链 | audio_handler.verificationRequired | VerificationListener → CaptchaPage → retryPendingPlayback | ✅ 闭环 |
| pubspec generate:true | flutter gen-l10n（CI + 构建） | 手写 gen_l10n_min.py 产物 | ❌ 双轨无校验（§五 P2） |
| keystore 移除 | build.gradle 文件存在才签名 | CI tag 时从 secret 还原 | ✅（密码默认值残留，复认） |
| cleartext 白名单 | nsc 9 域 | 代码实际 http 出流域（fsandroid 系 downurl） | ✅ 无缺口 |
| 错误页兜底 | main.dart ErrorWidget.builder 全局替换 | 所有页面构建异常路由 | ❌ 无退出路径（§一 P2） |

---

## 九、问题清单（按级别）

| # | 位置 | 级别 | 标题 |
|---|---|---|---|
| 1 | lib/l10n/app_localizations.dart（生成物） | **P1** | 生成物落后 arb：23 键无 getter（addedToPlaylist/playlistNameEmpty 被 add_to_playlist_sheet:96/:118 引用 → 编译必败、CI 全红）+ 40 键值漂移（previewOnly 7 语言 dart 侧显示中文、captchaTitle ru 语义错误等）。修法：重跑 `python3 tool/gen_l10n_min.py` |
| 2 | lib/main.dart:52-55 | **P2** | ErrorWidget.builder 全局替换为不可退出的 StartupErrorPage：任何 build 异常 → 整页死锁只能杀进程（第 10 条：编程错误进入业务降级） |
| 3 | .github/workflows/build.yml + l10n.yaml + gen_l10n_min.py | P2 | gen-l10n 双轨无守卫：CI gen-l10n 产物无人消费，arb↔dart 同步全靠人肉跑 python，#1 即其后果 |
| 4 | pubspec.lock 缺失 | P2 | 应用仓库不锁依赖，CI 逐次解析最新版本，构建不可复现 |
| 5 | .github/workflows/keystore.b64.txt（工作区残留） | P2 | git 索引已移除但文件仍在磁盘，二次入库/误打包即复发（keystore 已泄露需轮换，PROGRESS 已通告） |
| 6 | lib/l10n/app_zh.arb:429 | P3 | 裸 zh 独有键 albumPageComingSoon 死数据（生成器静默丢弃） |
| 7 | lib/core/theme/app_theme.dart:41 | P3 | isDark 死代码（A2 复认维持） |
| 8 | app_*.arb：tryListen 死键 / mvQualitySelect 语义族漂移 / qualityFlac(ru) 直译生硬 | P3 | 文案收尾 |
| 9 | pubspec.yaml:73 generate:true 与手写生成器并存 | P3 | 双轨配置（与 #3 同根，代码侧表现） |
| 10 | analysis_options + CI --no-fatal-infos/warnings | P3 | lint info/warning 全放行，isDark 类问题永不被 CI 发现 |
| 11 | app_router.dart:85 「排行榜参数无效」硬编码中文 | P3 | 深链错误边缘路径，与全局 l10n 口径不一致 |

共 11 条：**P1×1、P2×4、P3×6**。

## 十、任务重点逐项结论
1. **main.dart 启动编排全量**：通过（V34-C-02/03、V35-A3、三条事件流接线全部回归到位；仅 ErrorWidget.builder 全局替换的退出路径问题 #2）。
2. **l10n 程序化校验**：键集一致性 ✅（328×10，zh 329 有孤立键）；**生成物层 P1**（23 键 getter 缺失 → 编译必败，arb 层却是齐的——问题在生成步骤未执行）；@meta 占位符零失配 ✅；语义漂移 arb 层良好、dart 层 40 键漂移（同 #1 修复即消）。
3. **CI keystore 链**：P0 移除后 tag 构建 hard-fail 设计正确、非 tag debug 构建不受影响；密码默认值残留为已知复认项；gen-l10n 步骤脱节为真实缺口（#3）。
4. **Manifest cleartext**：fsandroid/fsmvpc/tx/kugouaudio 全覆盖，fsmobile 代码零引用不构成缺口；权限表与使用逐条匹配 ✅。
5. **isDark 死代码**：确认（#7）。
