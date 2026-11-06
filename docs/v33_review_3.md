# v3.3 第 3 批审查③：遗留债清点 + UI/存储合规

- 执行代理：review3 代理；基线 `defd4a4`（含 v33_fix1/2 修复，未提交状态）
- 判定基准：`docs/QUALITY_STANDARD.md`（33 条）
- 方法：读 `v3_review_b2_infra.md` / `v3_review_b2_presentation.md` / `batch2_review_3_download.md` 的问题清单段落 + PROGRESS.md 修复台账 → 逐条核对当前代码
- 逐文件完整阅读后实时追加，本文为清点表性质报告。

## 一、遗留债清点表

（逐项追加中）

### B-19 lastErrors 诊断页实现质量
- 位置：`lib/core/direct/kg_direct_api_client.dart:138-146`（写入）；全仓读取方：**0 处**（grep `lastErrors` 除本文件外无命中）；「诊断」字样全仓无任何 UI 实现
- 状态：**未修**（v33_fix1 报告自认「本次未新建 UI，留待下批」）
- 证据：`static final List<String> lastErrors`、`_logError` insert/截断；TASK_v33_fix1.md:62 要求「设置页『网络诊断』卡片读 lastErrors（先脱敏）」，落空
- 双重问题仍在：①只写不读（第 32 条死代码）；②`_logError` 直接 `'$where: $e'` 拼异常文本，**未经 `_redact` 脱敏**——异常文本里常带 URL query（token/dfid）；若将来直接接 UI 会把敏感串展示给用户（第 9/13 条）
- 本版建议：**修**。最小实现：设置页「网络诊断」卡片读 `lastErrors`，展示前过 `ErrorLogger` 同源脱敏（复用 `_redact` 需将其提为可访问）；或退一步先在写入点调用脱敏。改动小、可执行。

### B-28 图片缓存字节上限
- 位置：`lib/core/image/app_image_cache.dart:24-27`
- 状态：**已修**
- 证据：`maxCacheSizeBytes: 500 * 1024 * 1024` + 注释含编号、条款（第 25 条）与「为什么」
- 备注：①上限值 500MB 无外部依据注释（第 25 条「有据可依」弱满足，P3）；②「清除缓存」绕开 `emptyCache()` 直删底层目录的问题（B-28 原文后半段）需核对 settings_page——见存储合规一节。500MB 常量为内联表达式，未提具名常量（第 2 条，轻微）。
- 本版建议：**不修**（主体已修；具名常量属 P3 整洁度，留 v3.4 顺手提）。

### B-29 翻译缓存键缺模型版本
- 位置：`lib/core/cache/cache_manager.dart:81`；调用方 `lyric_repository.dart:163/211`
- 状态：**未修**
- 证据：键仍为 `'$lyricId:$targetLang'`，targetLang 实参为 `'$targetLanguage@$versionKey'`，versionKey 只覆盖歌词文本哈希；`AppConfig.translateModel`（`app_config.dart:19`，'Index-Translate-35B-A3B'）未入键
- 后果：换翻译模型/改提示词后所有旧译文永久命中旧缓存（无 TTL），用户表现为「翻译质量不更新且无法恢复」（第 23 条）
- 本版建议：**修**（成本极低）：`_key` 拼入 `AppConfig.translateModel`，或 `LyricTranslationCache` 构造时以 model 为 box key 前缀。一行改动消除一类永久脏数据。

### B-30 翻译缓存无上限
- 位置：`lib/core/cache/cache_manager.dart:71-110`
- 状态：**未修**
- 证据：`LyricTranslationCache` 仍是裸 Hive box：`set()` 只 put、无 LRU/条数/TTL；`clear()` 仅手动
- 后果：每条为「整首歌词译文」字符串，长期使用 box 全量驻留内存、冷启动 openBox 变慢（第 25 条）
- 本版建议：**留 v3.4**。加「条数上限 + 超限 FIFO/LRU 淘汰」需引入时间戳结构（box value 变更需迁移），改动面大于收益；配合 B-29 修后键可控，先记录。若做 B-29 时顺手实现最简条数上限（`length > N` 时 clear 过半）也可接受。

### B-31 Dio/Provider 无 onDispose
- 位置：`lib/core/providers.dart:7-25`、`lib/core/direct/kg_providers.dart:81-109`
- 状态：**未修**
- 证据：两文件全文无 `ref.onDispose`；`kgClientProvider`/`kgDirectApiProvider`/`translateApiProvider` 各持 Dio，均未 `dio.close()`
- 后果：ProviderScope 重建（测试/热重启）时旧连接池存活；单实例 App 运行期无用户可见后果（第 20 条）
- 本版建议：**留 v3.4**。单例 App 全生命周期持有是合理设计，dispose 只在 container 销毁时触发；修复价值仅在测试环境。加三行 `ref.onDispose(client.dispose)` 成本也低，可作为 v3.4 首项。

### B-32 GoRouter 未 dispose
- 位置：`lib/core/router/app_router.dart:22`（待复核文件确认）
- 状态：**未修**（providers/router 均无 onDispose 痕迹）
- 本版建议：**留 v3.4**。与 B-31 同批：`ref.onDispose(router.dispose)` 一行。

### B-33 audio bootstrap 失败缓存
- 位置：`lib/core/audio/audio_service_bootstrap.dart:39-58`
- 状态：**未修**
- 证据：`_future ??= _init()` 失败后 `_future` 不清空，`ensureReady()` 永远返回 false；无重试/恢复条件（第 11 条降级无退出条件）
- 后果：JustAudioBackground.init 一次失败（系统服务瞬时不可用）后，整个会话播放永久失效，只能杀进程——用户可见且不可恢复
- 本版建议：**修**。失败分支 `_future = null`（允许下次 `ensureReady` 重新 `_init`），并保留 `_error` 供 UI。改动约 3 行，收益直接。

### R-24 positionProvider 世代切换
- 位置：`lib/features/player/player_provider.dart:88-96`（positionProvider 及同族 6 个流）
- 状态：**未修**
- 证据：`await for (final p in ref.watch(audioPlayerProvider.stream)) { ... yield* p.positionStream; }` —— `yield*` 只有内层流关闭才回到外层取新 player；`audioPlayerProvider` 明确设计为多次 yield（engineReady 补发）
- 后果：引擎重建而旧 AudioPlayer 未 dispose 时，进度/时长/播放态永久停在上一个实例（第 18 条）；当前代码引擎只创建一次，触发条件罕见
- 本版建议：**留 v3.4**。正确写法需用 `StreamProvider` 的 `ref.listen`/subscription 手工转发或 `switchMap` 语义，6 个流同改；在「引擎单实例」现状下无实际触发路径，属防御性重构。

### R-25 queueProvider 可变 List 引用
- 位置：`lib/features/player/player_provider.dart:70-76`
- 状态：**未修**
- 证据：`yield handler.songs;` —— 事件载荷是同一可变 List 引用（若 handler.songs 原地增删）
- 后果：UI 拿到可变引用，某次原地修改不触发 stream 时弹层与实际队列不一致（第 5 条）。需核对 audio_handler.songs 是否原地改——见后。
- 本版建议：**不修**。核对 `audio_handler.dart:123`：`List<Song> get songs => List.unmodifiable(_songs);` —— 每次发射已是不可变快照，`yield handler.songs` 不会泄漏可变引用。原报告的担忧点已被现有实现化解，**该项实为已消解/误报**，无需改动。

### B-02 路由层 import 16 个 features 页面
- 位置：`lib/core/router/app_router.dart:4-18`
- 状态：**未修**
- 证据：16 个 `../../features/...` import 仍在；`appRouterProvider` 内直接构造各页面
- 违反第 4 条。维护成本问题，无运行期故障。
- 本版建议：**留 v3.4**。改法为路由表移到 features 各自注册（RouteRegistry 模式）或路由层上移出 core，牵动所有页面构造签名，是结构性重构，不宜夹带在本版小改里。

### B-03 preferred_quality 依赖 features 枚举
- 位置：`lib/core/audio/preferred_quality.dart:2`
- 状态：**未修**。仍 `import '../../features/player/data/models.dart'`。
- 本版建议：**留 v3.4**。修法（AudioQuality 下沉 core 或读原始字符串在 features 侧转换）需动多处调用方，单独成批做。

### B-04 error_logger 依赖 download 模块
- 位置：`lib/core/utils/error_logger.dart:7`
- 状态：**未修**。仍 `import '../../features/download/data/storage_permission_service.dart'`。
- 本版建议：**留 v3.4**（与 B-03/B-05 同一批「分层回流专项」，v33_fix1 只做了日志行为修复未动依赖方向）。

### 下载断点续传（Range）成本评估
- 现状：核对 `lib/features/download/data/public_media_store.dart` 与下载链路（详见存储一节）：下载以整文件写临时名（`dimKey` 含音质维度，D-01 已修），无 Range/`Range:` 头、无已下载字节记录。
- 成本评估（方案，不下结论）：
  1. HTTP 侧：resolveUrl 返回的 CDN 地址需实测是否支持 `Range: bytes=n-`（酷狗 audio CDN 通常支持，但**须原生直连实测留样**，第 28/29/33 条——kapi 返回不可作依据）；
  2. 本地侧：临时文件需从「整文件覆盖写」改为「append + 记录已写字节」（Hive 任务记录加 `receivedBytes` 字段，需数据迁移）；
  3. 一致性侧：断点恢复必须校验「同 hash+同音质+总长一致」，否则交错写坏文件（D-01 已修的 dimKey 维度恰好是前置条件）；服务端不支持 Range 时须整文件重下并清除临时文件，避免半文件残留。
  4. 预估改动面：download_repository 下载循环 + 任务模型 + public_media_store 写入方式 ≈ 200~400 行 + 实测脚本；**属独立特性批，建议 v3.4 单独立项**。
- 本版建议：**留 v3.4 立项**。v3.3 修复①刚完成存储外置与临时名维度，叠加 Range 改动回归面大。


## 二、存储合规终审（第 5/23/25 条）

### S-1 凭证是否只在内部（SecureStorage）
- 核对：
  - `kg_providers.dart`：dfid 权威源 Hive device box（**私有目录**，`Hive` 默认应用私有）+ SecureStorage 双写，合规；
  - CookieJar（B-07 已修）：sharedCookieJar 路径未就绪不落盘、降级内存留日志——需确认其落盘目录为私有。核对结论：token/t1/userid 只进 SecureStorage 与私有 Hive，未发现写外置路径的代码路径。
- 结论：**合规**（未见凭证外流代码路径）。

### S-2 外置目录是否含凭证数据
- 外置产物清单：①日志 `Documents/Tiernan Music/Logs/error_*.log`；②下载媒体 `Music|Pictures|Movies|Documents/Tiernan Music`；③图片缓存（CacheManager，私有 temp）。
- 日志：`log()` 落盘前统一 `_redact()`（C-02），V33-03 已补 `dfid/t1/userid/mobile` 键 + 双/单引号 JSON 形态 + Bearer/Basic，覆盖良好。**残留缺口**：
  - `_redact` 对 `mobile` 的通用分支 `(\\S+)` 只挡「key: 值」形态，裸 JSON 无引号数字 `"mobile":13812345678`（数字形态无引号）会被 `(\\S+)` 捕获吗——`\S+` 匹配数字串，会命中；但单独出现的 11 位号码（无 key 前缀，如异常文本里直接拼了号码）不脱敏。P3 边缘。
  - `context` 由调用方自由拼接（B-18 原问题）：`AuthRepository.sendSmsCode(mobile)` 若把号码放 context，会经 `_redact`——「上下文: 138...」无 key= 前缀，**不脱敏**。此为遗留 B-18 的一部分，属 P2 边缘残留。
- 图片缓存文件名：CacheManager 以 URL hash 命名，无凭证。**合规**。
- 下载文件名：歌曲/MV 名，无凭证。**合规**。
- 结论：**基本合规**；两条脱敏边缘缺口见 N-1/N-2。

### S-3 Android 10+ scoped storage 兼容
- `public_media_store.dart`：10+ 走 MediaStore insert/write/finalize（pending 语义正确，异常清孤儿条目）；≤9 直写公共目录 + 权限检查不弹窗；降级目录 `getExternalStorageDirectory()`（App 专属 external，无需权限）。合规。
- `error_logger.dart`：10+ 走 MediaStore `appendText`；≤9 需 WRITE_EXTERNAL_STORAGE 且**不主动弹窗**、未授权降级私有。合规。
- B-21 修复的 `apiLevel` 兜底（<21 归一到 29）逻辑自洽：宁可走 MediaStore 现代路径也不误碰旧分支。
- `queryExisting`/`delete`/`open` 均双轨（uri/path）。合规。
- 一处注意（N-3）：`_rewriteMediaStore` 的 `ok != null` 判定——原生 `appendText` 失败若返回空串而非抛异常，会被当成功返回 true，`_everPersisted=false` 但 `_publicDirPath` 不设置，行为尚可；但 `ok.isNotEmpty` 已赋值路径、`return ok != null` 空串时返回 true 且什么都没写——**公共写失败被当成功，日志静默丢失**（第 9 条）。P2。建议改为 `return ok != null && ok.isNotEmpty;`。

## 三、v33 新改动 UI 巡检（第 30/31/32 条）

### U-1 手写动画文案 i18n
- 位置：`lib/core/widgets/splash_handwriting.dart:25` `this.label = '汀澜音乐'`（硬编码中文默认值）；调用点 `splash_screen.dart:20` 用默认值，**未传 l10n**。
- 事实：l10n 已有 `appName` 键（10 语言 arb 齐全，`main.dart:292` 也在用 `ctx.l10n.appName`），splash 却直接用中文常量。
- 违反第 30 条配套 i18n 纪律；后果：非中文语言用户在启动屏看到中文品牌名（品牌名保留中文或有品牌考虑，但工程上应显式走 `appName` 键，各语言 arb 已把 appName 翻译/本地化）。
- 本版建议：**修**（小改）：`SplashScreen` 在 build 里取 `context.l10n.appName` 传入 label；或确认「品牌名不翻译」后把注释写明该决定（第 31 条），二选一。

### U-2 通知渠道名硬编码
- 位置：`lib/core/audio/audio_service_bootstrap.dart:48` `androidNotificationChannelName: '汀澜音乐播放'`（既有代码，非 v33 新增，但属同类）。系统通知渠道名支持本地化需走资源；当前各语言用户都看到中文。
- 本版建议：**留 v3.4**（改动需原生侧资源或 plist 配合，且属既有代码）。

### U-3 具名常量巡检（第 2 条）
- `splash_handwriting.dart`：时序全部具名（`HandwritingCycle.dotMs` 等），几何具名（`HandwritingGeometry`），优秀样本。
- `app_image_cache.dart:26`：`500 * 1024 * 1024` 内联表达式，未提具名常量（如 `maxCacheBytes`）——P3，顺手项。
- `error_logger.dart`：`maxBytes = 5MB`、`folderName`、`logsDirName` 均具名；`apiLevel` 兜底 `21`/`29` 为裸字面量（V33-20 引入），散在条件里——P3，建议提 `minSupportedApiLevel`/`fallbackApiLevel` 具名。
- `mv_repository.dart`：320/480 档以具名参数 `size:` 传入，注释给依据；合格。
- 本版建议：三处具名化 **留 v3.4 顺手提**，均无用户可见后果。

### U-4 注释「为什么」巡检（第 31 条）
- v33 新增注释抽查：`splash_handwriting.dart`（path 硬编码为什么、dot 半径来源、时序依据）、`error_logger.dart`（B-21/B-22/为什么不去等超时/为什么哨兵串）、`audio_handler`（playQueue 世代）、`mv_repository`（duration 毫秒口径 + 弃启发式的原因 + 出处文档）——**全部合格**，均解释「为什么/为什么不用别的方案」。
- 无「复述做了什么」式注释污染。

### U-5 死代码巡检（第 32 条，v33 改动引入）
- `animated_svg_logo.dart` 已删除，全仓无引用（grep 0 处）。合格。
- 残留死代码：`kg_direct_api_client.dart` `_directOrFallback` 的 kapi 回退分支——`fallbackToKapi = false` 且 `static const`，`!fallbackToKapi` 恒真 → 所有 `try { return await kapi(); }` 回退体**不可达**（第 32 条）。注释已声明「保留供对照」，但按死代码零容忍应删除或以 `if (fallbackToKapi)` 编译期消除。P2（维护误导：读者仍需理解一条永不执行的路径）。
- 本版建议：**留 v3.4**：删除回退体或保留 `kapi` 闭包仅作类型占位；删除后 `_directOrFallback` 可缩为 `_directOnly`。改动面中等（涉及全部调用点签名），不宜本版夹带。
- `SplashHandwriting.label` 参数：仅一处调用且用默认值，参数本身可保留（可配置性合理），不算死代码。

## 四、新增问题清单（本次复核发现的 v33 引入/相关缺陷）

### N-1 `_rewriteMediaStore` 空串成功误判
- 位置：`lib/core/utils/error_logger.dart:_rewriteMediaStore`（约 :233-247）
- 级别：P2
- 事实：`return ok != null;` —— 原生通道失败若返回空串（而非抛 PlatformException），本方法返回 true，日志**静默丢失**且上层认定「公共写入成功」。
- 违反：第 9 条（失败可观测）。同文件 `_appendPublic` 的其它分支均判空，唯此处不一致。
- 后果：用户以为日志在公共目录，实际无文件，排障时拿不到任何日志。
- 本版建议：**修**——`return ok != null && ok.isNotEmpty;` 一行。

### N-2 context 自由拼接绕过脱敏（B-18 残留）
- 位置：`error_logger.dart:log(context:)` 与调用方（如 `AuthRepository.sendSmsCode(mobile)`）
- 级别：P2（隐私面）
- 事实：`_redact` 只识别 `key=value/JSON` 形态；调用方把 11 位手机号直接拼进 context 文本时无 key 前缀，原样落公共日志。
- 违反：第 14 条（边界数据必须校验）/第 9 条配套隐私纪律。
- 后果：手机号在可分享的公共日志文件明文残留。
- 本版建议：**修**（本版或 v3.4）：在 `_redact` 末尾追加一条「独立 1 开头 11 位数字」兜底正则（前后非数字），约 3 行；同时排查 sendSmsCode 调用点是否把 mobile 传入 context。

### N-3 lastErrors 未脱敏（并入 B-19 修复一并处理）
- 见 B-19 条目。写入点 `_logError` 拼接原始异常文本，接 UI 前必须过 `_redact`。

## 五、清点表总汇

| 编号 | 位置 | 状态 | 证据 | 本版建议 |
|---|---|---|---|---|
| B-19 | kg_direct_api_client.dart:138 | 未修（UI 未建） | lastErrors 全仓 0 读取方；v33_fix1 自认留待下批 | **修**：设置页诊断卡片 + 脱敏 |
| B-28 | app_image_cache.dart:26 | 已修 | maxCacheSizeBytes 500MB | 不修（具名常量留 v3.4） |
| B-29 | cache_manager.dart:81 | 未修 | 键缺 translateModel 维度 | **修**：键拼 AppConfig.translateModel |
| B-30 | cache_manager.dart:71-110 | 未修 | 无上限/无 TTL | 留 v3.4 |
| B-31 | providers.dart / kg_providers.dart | 未修 | 无 onDispose | 留 v3.4 |
| B-32 | app_router.dart:22 | 未修 | GoRouter 未 dispose | 留 v3.4（与 B-31 同批） |
| B-33 | audio_service_bootstrap.dart:39 | 未修 | 失败 Future 永久缓存 | **修**：失败置 _future=null |
| R-24 | player_provider.dart:88-96 | 未修 | yield* 世代问题 | 留 v3.4（无实际触发路径） |
| R-25 | player_provider.dart:70 | 已消解 | handler.songs 返回 List.unmodifiable | 不修（误报） |
| B-02 | app_router.dart:4-18 | 未修 | 16 个 features import | 留 v3.4（结构重构） |
| B-03 | preferred_quality.dart:2 | 未修 | core→features 枚举 | 留 v3.4 |
| B-04 | error_logger.dart:7 | 未修 | core→download | 留 v3.4 |
| 断点续传 | download 链路 | 无实现 | 无 Range/字节记录 | v3.4 立项（成本 200~400 行 + 原生实测） |
| N-1 | error_logger.dart _rewriteMediaStore | 新发现 | 空串判成功 | **修**（一行） |
| N-2 | error_logger.dart _redact | 新发现（B-18 残留） | 无 key 前缀手机号不脱敏 | **修**（约 3 行） |
| U-1 | splash_handwriting.dart:25 | 新发现 | label 硬编码中文未走 l10n | **修**（传 appName 或注释决策） |

## 六、统计
- 清点遗留项：14 项 → 已修 1（B-28）、已消解/误报 1（R-25）、本版建议修 5（B-19、B-29、B-33 + N-1、N-2）、留 v3.4 7、不修 0（理由见各条）
- 新发现 UI/巡检项：U-1~U-5（2 项建议本版修：U-1、以及 kapi 死代码留 v3.4）
- 存储合规终审：凭证仅在 SecureStorage/私有 Hive——**通过**；外置目录无凭证数据——**基本通过**（N-2 脱敏兜底为唯一缺口）；Android 10+/≤9 双轨与降级路径——**通过**（N-1 为可观测性缺口）
- 本版最小修复集（按优先序）：N-1（1 行）→ B-33（3 行）→ B-29（1 行）→ N-2（3 行）→ U-1（1~2 行）→ B-19（诊断卡片 + 脱敏，半天）

## 七、dart analyze 结论
- `dart analyze`（/opt/dart）共 4887 条；过滤缺包噪音（uri_does_not_exist / extends_non_class（StatefulWidget 等未解析）/ const_initialized_with_non_constant_value / override_on_non_overriding_member 等）后**无真实 error/warning**。
- 遗留 info：`prefer_final_locals` 2 处（mv_repository.dart:184、playlist_repository.dart:92）——P3 整洁度，留 v3.4。
- test/screenshots_test.dart 有 2 处 dead_code warning（缺包导致 if 分支解析异常的衍生噪音，需装包后复核）。
