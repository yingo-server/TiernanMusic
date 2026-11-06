# v3.5 A 批·审查②：core 基础设施终验报告

基线 tag v3.3.0（ac188b2）后的 v3.3/v3.4 改动之上，对 core 基础设施 10 个文件逐行完整审读。
方法：完整 file_read + 用法侧 grep 巡检（列出 grep 命令与匹配）+ `dart analyze lib/core`
（Flutter/Dio/Hive 等第三方包在分析环境不可解析，其符号报错一律按噪音过滤；
**项目自有类报错即真错误**——本档核心文件未出现项目自有符号的 analyzer 报错，
仅 app_theme.dart:41 `isDark` 未使用一条 warning，见 P3-2）。

---

## 逐文件结论

### lib/core/api/translate_api.dart（B-36 防护后）
完整读毕（69 行）。B-36 防护（choices 判空 → 退回原文）实现正确：
`res.data?['choices']` 先 `is! List || isEmpty` 再取 `[0]`，无 RangeError 路径；
`content` 空串/null 均退回原文；行数对齐用 `List.generate` 不足补原文，无越界。
**遗留 P2-1**：解析链 `choices[0]?['message']?['content'] as String?` 中
`choices[0]` 与 `['message']` 是动态取值后直接成员访问，若上游返回
`choices: [123]`（元素非 Map）会抛 NoSuchMethodError 而非退回原文——
外部数据边界未逐一分支验证类型（第 13 条）。属低概率但真实存在的崩溃路径。
另：`translateText` 的 `lines.first` 在 translateLines 恒返回等长列表的前提下安全。

### lib/core/cache/cache_manager.dart（B-29 键变更后）
完整读毕（113 行）。

- MemoryCache：容量上限 200 有据、过期先清再 FIFO，正确。
- **B-29 残留评估（任务重点①）**：`LyricTranslationCache._key` 现为
  `'$lyricId:$targetLang@$versionKey@${AppConfig.translateModel}'`（版本键由
  lyric_repository.dart:167 拼入 targetLang 参数）。键变更后旧格式条目
  （无 model/无 version 段）永不命中、永不清理，Hive `lyric_translations` 盒单调增长。
- **清理路径巡检**：唯一清理入口是 settings_page.dart:135 的
  `LyricTranslationCache.instance.clear()`（清缓存按钮），能整盒清空，故旧条目
  **不会误用**、且有用户可达的清理手段——不构成数据错误。但按第 25 条（所有资源
  必须有上限），该盒**无条目数/字节上限、无自动淘汰**，每次换翻译模型或歌词改版
  都新增一批死键。定为 **P3-1**（仅占空间，无错误行为）。建议（非本次修复范围）：
  init 时按 `@` 段过滤 model 不符的键删除，或设置盒条目上限。

### lib/core/image/app_image_cache.dart（maxCacheSizeBytes 撤销后）
完整读毕（79 行）。撤销字节上限后，条目上限 `maxNrOfCacheObjects: 600` 承担容量
约束，注释如实记录了 flutter_cache_manager 4.x 无字节参数的事实与 v3.4 计划，
符合第 25/31 条。串行链 `_serial` 实现正确：completer 在 action 抛错时
completeError 转发，**不会**让 `_queue` 进入 error 态（每环内层 try/catch）。
getFileStream 用 `await _serial(() async {})` 占位排队后转发流，语义正确（排队点
在流开始前，流本身的消费不被串行链阻塞——这是合理的取舍，避免长下载占住队列）。
用法巡检：全项目 21 处 CachedNetworkImage 均显式传 `cacheManager: AppImageCache.instance`，
无遗漏退回默认实例。无问题。

### lib/core/utils/error_logger.dart（B-17/N-1/N-2/串行链兜底后）
完整读毕（337 行）。

- **串行链尾 catchError 正确性（任务重点②）**：`_writeQueue = _writeQueue.then(...)` 后
  紧接 `_writeQueue = _writeQueue.catchError(...)`。分析：catchError 的回调返回
  `Future<void>`（`debugPrint` 返回 void，箭头函数体为语句，回调返回 void——
  catchError 要求回调返回 FutureOr<void>，void 兼容 void 链）。语义正确：
  每轮 log 都重新赋值 `_writeQueue`，链尾兜底在**每次追加时都重建**，任何一环
  逃逸异常都被当轮的 catchError 吸收，不会污染下一环。`completer` 在 finally 中
  complete，等待者不会悬挂。**结论：兜底实现正确。**
  一个次要点：内层私有目录写入的 try/catch 只捕获写文件异常，而
  `_appendPublic` 自身已整体 try/catch 返回 false，逃逸面实际为空——兜底是
  纵深防御，非必需但无害（不报）。
- **脱敏正则误伤面（任务重点②）**：
  - 键值正则对 `t1|userid|mobile|dfid` 等键做脱敏，仅在键名后跟 `=`/`:` 时触发，
    误伤面限于同名键，合理。
  - **N-2 裸手机号正则 `(?<!\d)(1[3-9]\d{9})(?!\d)`**：任务书点名的时间戳/ID
    误伤，逐一核查：
    - ISO 时间戳 `2026-11-06T08:31:45.123` — 无 11 位连续数字段（含毫秒 3 位 +
      秒 2 位被 `:` 分隔），不命中。
    - Unix 毫秒时间戳（13 位，如 `1770000000000`）：lookbehind/ahead 只排除**相邻
      数字**，13 位数字中**任意中间 11 位窗口**满足 `1[3-9]` 开头的都可能命中——
      13 位数字串在正则引擎匹配时会先尝试最左起点：若第 1 位是 1 且第 2 位是
      3–9，则命中前 11 位（剩余 2 位数字使 `(?!\d)` 失败，回退）；起点不满足时
      引擎右移，**中间窗口前面有数字 → lookbehind 失败**。结论：连续 13 位
      数字串内**无法**命中（任何 11 位窗口要么尾随数字要么前导数字）。
      但 **11 位纯数字 ID**（如订单号、歌曲合作方 ID 恰为 139xxxxxxxx 形态）
      会被误脱敏为 `139****xxx`——影响是日志可读性，非正确性，属可接受代价
      （第 13/14 条下宁可多脱敏不可泄露）。**不构成问题**，记录为已核查。
    - `(?!\d)` 也排除了手机号后紧跟分机/更多数字的形态。核查通过。
  - Bearer/Basic 正则范围合理。**脱敏面整体通过，无误伤缺陷。**
- N-1（空串返回值判失败）、B-22（串行写）、B-20/B-21 兜底实现与注释一致。
- apiLevel 兜底到 29 的策略有注释依据。无问题。

### lib/core/storage/secure_storage.dart（B-11/F-2 登出语义后）
完整读毕（114 行）。

- saveCredentials 的 null-删除语义（C-03）正确，四键 + dfid 均对称写/删。
- clearCredentials：保留 dfid（F-1 设备语义）、删 token/userid/t1/auth +
  `acct_token_<userid>`。与 B-10 dfid 单源化的一致性（任务重点④）巡检：
  - dfid 权威源 = Hive `device` box（kg_providers.dart B-10 注释）；
    注册成功回调 `onDfidRegistered` **双写** Hive（saveDfidSync）+ SecureStorage
    （saveDfid，fire-and-forget）。SecureStorage 侧是**镜像**不是源。
  - 登出保留 dfid 后，SecureStorage 镜像仍在，下次登录
    auth_repository.getDfid()（:67）优先读它——与 Hive 值一致（双写保证），
    不产生设备身份跳变。**一致，无冲突。**
  - 但发现一个真实缺陷：**player_repository.dart:46 `ensureDfid()` 只读
    SecureStorage**，读不到就走 `/register/dev` 注册并 `saveDfid`（:75）写回
    SecureStorage——**绕过了 Hive 单源**。kg_client.dart:499 直连注册成功写
    `device.dfid` + Hive；player_repository 的注册路径（经 KugouApiClient.get
    '/register/dev'）若直连成功会触发 kg_client 的 onDfidRegistered 吗？
    ——巡检 kg_direct_api_client.dart:284：direct 分支 `_registerDev()` 走
    `_epAuth.registerDev()` → kg_client.registerDevice → 触发 onDfidRegistered
    双写，此路径一致；**kapi 兜底分支**返回 kapi 包装结果时不触发回调，此时
    player_repository:75 把 kapi 发的 dfid 只写 SecureStorage，Hive/内存
    device.dfid 未更新 → **直连签名仍用旧/空 dfid，SecureStorage 镜像与权威源
    永久分叉**，且该 dfid 是「kapi 包装结果」（第 33 条：不可作为原生依据）。
    定 **P2-2**：恢复条件缺失（第 11 条），后果是签名维度与设备注册态漂移、
    可能触发风控。auth_repository.getDfid 的同款 kapi 路径（:70-77）同样只写
    SecureStorage——同一根因，一并计入。
  - 次要（P3-3）：`clearCredentials` 不接受「登出但保留设备」以外的场景说明，
    无量问题；`Credentials` 类无 toString 覆写——若上层误把 cred 打进日志会泄露
    token（error_logger 的键值正则会拦 `token=`，`Credentials(...)` 的
    Dart toString 形如 `Credentials#12345` 不含字段值，实际安全）。不报。

### lib/core/audio/audio_service_bootstrap.dart（B-33 重试后）
完整读毕（80 行）。

- B-33 修复本身正确：`_future ??= _init()` + `whenComplete` 中失败置 null 允许重试。
- **重试风暴评估（任务重点③）**：`ensureReady()` 无调用间隔控制、无退避、无
  尝试次数上限。若调用方在「播放按钮点击 → ensureReady 失败 → 提示」的用户
  循环里，风暴受用户手速限制（人肉节流），风险低。但需核查是否有**自动重试
  调用方**：巡检 lib 内 `ensureReady` 调用点。

（巡检：`grep -rn "ensureReady\|AudioServiceBootstrap" lib`）
巡检结果：仅 player 播放路径与 main.dart:105 启动期各一处调用，无自动循环重试。
JustAudioBackground.init 失败多为平台服务不可用，重试即再打一次平台通道，
无网络放大效应。**结论：当前调用形态下无风暴风险（P3 观察项）：若未来加入
自动重连/队列自动播放逻辑，需先在此处加退避与次数上限（第 25 条）。**
另：`_error` 记录后无读取方（除 error getter 暴露）——检查是否有 UI 展示，
巡检无。error getter 无人消费，属轻微死代码（第 32 条），P3。

### lib/core/audio/preferred_quality.dart
完整读毕（18 行）。isBoxOpen 守卫 + try/catch + 默认 q320，正确。
`catch (_) {}` 空 catch 违反第 6 条字面，但属「读不到就用默认值」的有语义降级
（注释写明），且此路径下无用户可见功能损失——**降级值语义明确，通过**（第 6 条
允许「返回有明确语义的降级值」）。无问题。

### lib/core/theme/settings_provider.dart + app_theme.dart
完整读毕（105 + 278 行）。

- settings_provider：三处 Notifier 均为「box 不可用 → 内存态降级」，降级语义
  （重启丢失设置）与注释一致；`_load` 对非法值有 orElse/switch 兜底。
  Locale 解析 `split('_')` 对 `zh_Hans_CN` 三段式 locale 会截成
  `Locale('zh', 'Hans')`——countryCode 语义错位，但本项目 l10n 仅 zh/en，
  实际写入只有 languageCode 或 languageCode_country 两类，不触发。不报。
- **P3-2**：app_theme.dart:41 `final isDark = ...` 声明后从未使用（dart analyze
  warning，项目自有代码真死代码，第 32 条）。
- app_theme 其余：chipTheme labelStyle 不带色、SearchBar textStyle 类型、
  CupertinoPageTransitionsBuilder 的 show 导入均有正确注释；形状/动效 token
  集中定义，无硬编码颜色绕过 scheme（Colors.transparent 除外，属语义色）。

### lib/core/providers.dart
完整读毕（25 行）。kugouApiClientProvider → kgDirectApiProvider 链清晰；
translateApi 每次 Provider 重建新建 Dio 实例（Provider 默认常驻，实际单例），无泄漏。
关于不建第二个顶层 Container 的注释属实（防止 UnimplementedError）。无问题。

---

## 问题清单（按级别）

| 编号 | 位置 | 级别 | 摘要 |
|---|---|---|---|
| P2-1 | translate_api.dart:51 | P2 | choices[0] 非 Map 时 NoSuchMethodError 而非退回原文（第 13 条） |
| P2-2 | player_repository.dart:46,75 + auth_repository.dart:70-77 | P2 | kapi 兜底注册的 dfid 只写 SecureStorage 镜像，绕过 Hive 单源且属 kapi 包装结果（第 5/11/33 条） |
| P3-1 | cache_manager.dart LyricTranslationCache | P3 | B-29 键变更后旧条目永久残留、盒无上限；清理仅靠用户手动清缓存（第 25 条） |
| P3-2 | app_theme.dart:41 | P3 | isDark 未使用死代码（第 32 条） |
| P3-3 | audio_service_bootstrap.dart:24 `_error` | P3 | error getter 无消费方（第 32 条）；重试风暴：当前调用形态安全，未来自动重试前需加退避 |

## 重点核查结论（无问题，记录备查）

1. **B-29 旧缓存残留**：不会误用（键不命中），清理路径存在（清缓存按钮整盒清），
   仅为空间占用 → P3-1。
2. **error_logger 串行链尾 catchError**：逐轮重建、吸收逃逸异常、completer
   finally 兜底，实现正确。**裸手机号正则对 13 位毫秒时间戳不命中**（数字边界
   lookaround 使中间窗口必邻数字）；11 位纯数字 ID 存在理论误脱敏，影响仅日志
   可读性，可接受。
3. **bootstrap 重试风暴**：失败置 null 重试 + 当前仅用户手势/启动两处调用、
   无自动循环 → 当前无风暴；已留 P3 观察项。
4. **SecureStorage 登出保留 dfid 与 B-10 一致性**：双写机制下一致；但发现
   kapi 兜底注册路径绕过单源 → P2-2（本档最重要发现）。
