# 审查报告：设置 / i18n / 更新检查（批3检1，纯读）

- 仓库：`/var/minis/workspace/TiernanMusic`，commit `db7bafc`
- 审查范围：settings_page.dart、settings_providers.dart、update_checker.dart、error_logger.dart、permission_gate.dart、toast.dart、app_config.dart、verification_listener.dart、l10n 全套（含 app_localizations.dart 与 tool/gen_l10n_min.py）、app_zh_CN.arb
- 未运行 flutter/test（遵守只读铁律）；行号以当前工作区文件为准。

---

## 一、发现的问题（按严重度排序）

### 严重度：功能失效

**F1. i18n：`all` / `showPassword` / `hidePassword` 在全部 10 个语言里都是中文**
- 文件：`lib/l10n/app_zh_TW.arb`（及其余 en/de/es/fr/ja/ko/pt/ru.arb）→ 生成物 `lib/l10n/app_localizations.dart` 中 `'all': '全部'`、`'showPassword': '显示密码'`、`'hidePassword': '隐藏密码'` 出现在每个语言 map 里（共 11 处 locale × 3 key）。
- 问题：这三个 key 后期补进 zh_CN，但 `tool/translate_arb.py` 再生成时没有把这三个 key 翻译进其他语言；英文/日文用户界面会突然出现中文按钮。
- 修法：在 `app_en.arb` 等 9 个 ARB 中补齐这三条英文等翻译，然后重跑 `python3 tool/gen_l10n_min.py`。示例（app_en.arb）：
  ```json
  "all": "All",
  "showPassword": "Show password",
  "hidePassword": "Hide password",
  ```
  也可直接改 `tool/translate_arb.py` 的种子表后全量重生成。

**F2. i18n：`qualityNames` 硬编码中文，设置页音质名不随语言切换**
- 文件：`lib/features/settings/presentation/settings_providers.dart:31-37`
  ```dart
  const Map<String, String> qualityNames = {
    '128': '标准音质 128K',
    '320': '高品质 320K',
    'flac': '无损音质 FLAC',
    'hires': 'Hi-Res 高解析',
  };
  ```
- 问题：设置页「默认音质」弹层、subtitle 全部直接用 `qualityNames[quality]`（settings_page.dart `_showQualityDialog` 与 `_buildPlaybackSection`），切到英文后仍是中文；且 ARB 里已有对应 key（`quality128/320/Flac/High`）却没用上。
- 修法：改为运行时按 BuildContext 取 l10n。settings_page.dart 中：
  ```dart
  Map<String, String> _qualityNames(BuildContext c) => {
    '128': c.l10n.quality128,
    '320': c.l10n.quality320,
    'flac': c.l10n.qualityFlac,
    'hires': c.l10n.qualityHigh,
  };
  ```
  并把 `_buildPlaybackSection` / `_showQualityDialog` 里的 `qualityNames[...]` 替换为 `_qualityNames(context)[...]`（provider 文件里删掉该常量；若其它文件引用，一并替换）。

**F3. 缓存清理与缓存统计不对称：清不掉大头，「缓存占用」越清越大**
- 文件：`lib/features/settings/presentation/settings_page.dart`
  - `_loadCacheSize()`（约 91-112 行）统计的是 `getApplicationDocumentsDirectory()` + `getApplicationSupportDirectory()` + `getTemporaryDirectory()` 三个目录的**全部文件**。
  - `_clearCache()`（约 128-158 行）只清了：内存缓存、歌词翻译缓存、3 个 Hive box、**仅 `getTemporaryDirectory()` 顶层**。
- 问题：
  1. Documents 下包含下载的音乐/MV 与 `Tiernan Music/Logs` 错误日志 —— 全被算进「缓存占用」，但 `_clearCache` 完全不碰它们（这本身是**正确的**，日志与下载不能误删），结果就是用户点了「清除缓存」之后显示的占用几乎不变，形成体验/认知 bug。
  2. ApplicationSupport（Hive box 的磁盘文件）清 box 后文件并不缩小，也造成「清了没变小」。
- 修法：统计口径与清理口径必须一致。最小改法是统计时排除不可清理内容：
  ```dart
  final dirs = [
    await getApplicationSupportDirectory(),
    await getTemporaryDirectory(),
  ]; // 去掉 Documents（里面是下载与日志，不是缓存）
  ```
  并在 `clearCacheConfirm` 文案中已说明只清三类缓存（当前文案正确），保持统计只覆盖这三类即可。

### 严重度：体验瑕疵

**E1. API 地址编辑：无任何输入校验，可保存非法值并污染所有请求**
- 文件：`lib/features/settings/presentation/settings_page.dart` `_showApiEditDialog`（保存分支，约 700-710 行）
  ```dart
  final v = controller.text.trim();
  if (v.isNotEmpty) await onSave(v);
  ```
- 问题：只判空。可保存 `'abc'`、`'ftp://x'`、带路径尾斜杠/查询串的值，之后酷狗/翻译 API 全部请求失败，用户只能靠「重置为默认」自救（且翻译 API 没有 reset 按钮 —— `translateApiUrl` ListTile 的 trailing 只是 chevron，而酷狗的有 restart_alt 按钮）。
- 修法：保存前校验：
  ```dart
  onPressed: () async {
    final v = controller.text.trim();
    final uri = Uri.tryParse(v);
    final ok = uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
    if (!ok) {
      setDialogState(() => testResult = context.l10n.apiConnectionFailed('invalid url'));
      return;
    }
    await onSave(v);
    if (ctx.mounted) Navigator.pop(ctx);
  },
  ```

**E2. 「测试连通性」没有 receiveTimeout，且 GET 根路径 404 分支语义混乱**
- 文件：`settings_page.dart` `_testConnectivity`（约 540-555 行）
- 问题：`Dio(BaseOptions(connectTimeout: 8s))` 未设 `receiveTimeout` —— 服务器接受连接后不回包时挂 15 秒（Dio 默认无 receive 超时）才报错。另外 `apiServerReachable(404)` 把 404 文案化为「服务器可达（HTTP 404）」算有意设计，可接受，但 receiveTimeout 必须补。
- 修法：
  ```dart
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));
  ```

**E3. Toast：dedupe map 只在超过 64 条时清理，且 `_current` 移除后 OverlayEntry 未置空时机有竞态**
- 文件：`lib/core/utils/toast.dart:31-56`
- 问题 1：`_lastShown` 只有 `length > 64` 时才清理，且清理只删过期项 —— 若 3 秒内涌入 65 条**不同**消息，过期项一个也删不掉（全都未过期），map 继续增长；极端刷屏场景下缓慢泄漏。低危但修法简单。
- 问题 2：`_hide()` 与下一次 `show()` 都调用 `_current?.remove()`；`show()` 先 `_dismissTimer?.cancel()` 再 remove，顺序正确。`OverlayEntry` 移除后 `_ToastView` 的 `_controller` 在其 State.dispose 里释放，正确。
- 问题 3：`context.findRootAncestorStateOfType<OverlayState>()` —— 在 `showDialog` 的 builder 里的 context（如 `_showUpdateDialog` 的下载按钮失败分支 `Toast.show(context, ...)`) 能否找到 Overlay？能：Dialog 是插入 root Navigator（其内部即 root Overlay）的路由，向上 `findRootAncestorStateOfType` 会命中 root Overlay，可用。**通过**。
- 修法（问题 1）：
  ```dart
  if (_lastShown.length > 64) {
    final cutoff = now.subtract(_dedupeWindow);
    _lastShown.removeWhere((_, t) => t.isBefore(cutoff));
    if (_lastShown.length > 64) _lastShown.clear();
  }
  ```

**E4. 更新弹窗 release notes 为纯文本直出，Markdown 符号原样显示**
- 文件：`settings_page.dart` `_showUpdateDialog`（约 900-916 行）：`Text(info.releaseNotes!, ...)`。
- 问题：GitHub release body 是 Markdown（`-` 列表、`**粗体**`、`#` 标题），纯 Text 渲染后满屏 `**` 和 `-`，观感差；超长已由 `_extractNotes` 截断到 1200 字符 + `SingleChildScrollView` 可滚动，**无溢出风险（通过项）**。
- 修法（轻量，不引入 markdown 依赖）：
  ```dart
  Text(
    info.releaseNotes!
        .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^[-*]\s?', multiLine: true), '· '),
    style: Theme.of(ctx).textTheme.bodySmall,
  )
  ```

**E5. main.dart：MaterialApp `title` 硬编码中文「汀澜音乐」，任务栏/最近任务标题不随语言切换**
- 文件：`lib/main.dart:199`：`title: '汀澜音乐'`。
- 问题：应使用 `onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appName`（注意 `title` 参数无法拿到 localization context，必须用 onGenerateTitle；而 StartupErrorPage 早退分支没有 delegates，只能保留硬编码）。
- 修法：
  ```dart
  return MaterialApp.router(
    onGenerateTitle: (ctx) => ctx.l10n.appName,
    ...
  ```

**E6. 错误日志文件内部字段（「来源/上下文/错误/堆栈」「接口/错误码/响应」）为硬编码中文**
- 文件：`lib/core/utils/error_logger.dart:74-82、211-216`
- 评估：日志文件是给开发者/排障看的机器产物，且 ErrorLogger 位于 core/utils 不持有 BuildContext，做 l10n 需要传参，成本高于收益。**判为可接受的设计选择，不建议改**；但 captcha_page.dart 属于用户可见 UI，见 F4 之外的补充抽查结论（下一节）。

### 严重度：代码质量（低）

**Q1. `_Msg.r()` 按占位符在文本中出现的**顺序**替换，与声明顺序可能错位**
- 文件：`lib/l10n/app_localizations.dart:3230-3245`（生成器 `tool/gen_l10n_min.py:78-90`）
- 问题：`r(p0, p1)` 把第 1 个**在文本中遇到**的 `{xxx}` 换成 p0。当前 ARB（`onlyShowsFirstN` = `{loaded}…{total}`、`replyPrefix` = `{name}…{content}`）声明顺序恰好等于出现顺序，所以现在是对的；但翻译（如日语把 `{total}` 放前面）会让值错位。flutter gen-l10n 按**名字**替换，这里按**位置**替换，是与官方 API 的形状差异。
- 修法：生成器改为按名字建参映射。把 getter 生成为 `.r({'loaded': loaded, 'total': total})`，`_Msg.r` 改为：
  ```dart
  String r(Map<String, Object?> args) => text.replaceAllMapped(
      RegExp(r'\{(\w+)\}'), (m) => args[m.group(1)]?.toString() ?? m.group(0)!);
  ```
  注意当前 `apiConnectionOk(int code)` 的占位符类型声明为 `int` 而 `recentErrorsCount` 声明为 `String`（调用处传 `xxx.toString()`）——不一致但都能跑，统一成 `int` + `String` 按需即可。

**Q2. `settings_providers.dart` 各 Notifier 在构造时读 Hive，若 settings box 在 provider 首次实例化时还没打开，默认值兜底存在但「已保存值」被静默丢弃**
- 文件：`lib/features/settings/presentation/settings_providers.dart:6-12`
- 评估：`_box()` 用 try/isBoxOpen 双保险，未打开时返回 null → 构造器 fallback 到硬编码默认值，**不会崩（通过项）**。残余风险：若 `openHiveBoxes()` 晚于 provider 首次访问，用户上次存的偏好会显示为默认值；用户再动一下开关就会被覆盖写回。建议确认 main.dart 中 Hive 打开先于 `ProviderScope` 首次消费（main.dart 里启动顺序已先行打开 box，则无实际问题）。

**Q3. `UpdateChecker._dio` User-Agent 版本写死 `TiernanMusic/1.0.0`**
- 文件：`lib/core/utils/update_checker.dart:47`
- 修法：`headers` 改为在 `check()` 里动态设置，或干脆移除版本号只留 `TiernanMusic/Android`。

---

## 二、审查点逐项结论

### A. 设置页
1. **FutureBuilder 提字段** — ✅ 通过。`_logDirPath`、`_storageGranted` 均为 `late final`（initState 初始化），注释里写明了无限重建的原因；`build` 内的 FutureBuilder 引用字段，不重建。`recentErrorsCount` 直接读同步静态 `ErrorLogger.recent`，无 Future，安全。
2. **_checkingUpdate loading 态** — ✅ 通过。`setState(_checkingUpdate=true)` → `try/catch/finally`，finally 内 `if (mounted)` 复位；`check()` 内部 await 后所有分支都有 `if (!mounted) return;`。防重入 `if (_checkingUpdate) return;` 也有。
3. **provider 读写 Hive 未打开** — ✅ 通过（见 Q2 残余风险说明）。所有 getter 均有 `defaultValue` + `?? 硬编码默认值` 双兜底。
4. **缓存清理范围** — ⚠️ 见 F3。清的是内存缓存/歌词翻译缓存/3 个缓存 Hive box/tmp 顶层；**不会误删下载文件**（Documents 未动，下载安全），但统计口径含 Documents 导致「清了不变小」。
5. **API 地址编辑** — ⚠️ 见 E1、E2。
6. **版本号显示** — ✅ 通过。`_loadVersion` 显示 `'${info.version} (${info.buildNumber})'`，version 与 buildNumber 都有。

### B. i18n
7. **离线生成器 API 形状** — ✅ 基本一致：`SynchronousFuture` delegate（app_localizations.dart:3589）、`static const localizationsDelegates`、`supportedLocales` 与 `flutter gen-l10n` 相同的调用形状（`context.l10n.versionLabel('1.0.1')`）。差异点：a) 占位符按位置而非按名字替换（见 Q1）；b) `localizationsDelegates` 是单个 `_Delegate` 而非官方的 `DefaultLocalizationsDelegate + AppLocalizationsDelegate` 列表（main.dart 只挂了这一个 delegate，够用；但没有 GlobalMaterialLocalizations，Material 组件自身的文案如日期选择器仍是英文 —— 本 App 未用这些组件，可接受）；c) 回退链 `full → lang → template(zh_CN) → key` 比官方多了 template 兜底，合理。`isSupported` 返回 true（官方是 locale 列表判断），配合 `_maps[full] ?? _maps[lang] ?? template` 不崩，可接受。
8. **ARB @key 元数据** — ✅ 抽查通过：`@versionLabel`、`@recentErrorsCount`、`@onlyShowsFirstN`、`@apiConnectionOk`、`@apiServerReachable` 等都有完整 placeholders 声明，生成出的方法签名（`versionLabel(String version)`、`apiConnectionOk(int code)`、`onlyShowsFirstN(int loaded, int total)`）与调用点匹配。小瑕疵：`recentErrorsCount` 占位符声明为 `String` 而其他 count 类是 `int`，风格不一致（Q1 尾注）。
9. **硬编码中文漏网** — ⚠️ 漏网清单：
   - `captcha_page.dart`：约 17 处（86/105/136/220/293/296/306/326/347-348/358/374/378/388/408/420/428 行），验证页面向用户展示，切英文后全是中文，**应修**（ARB 中已有 `captchaTitle/captchaHint/close` 等 key 可复用，缺的需补 key）。
   - `main.dart`：102（通知渠道名）、125、199（title）、235（StartupErrorPage）。
   - `error_logger.dart`：日志字段中文（可接受，见 E6）。
   - `settings_providers.dart:32-35` qualityNames（见 F2）。
   - `app_localizations.dart` 全部 10 语言 map 中 all/showPassword/hidePassword 为中文（见 F1）。
10. **语言切换后不立即刷新的 UI** — `locale` 由 `main.dart` 的 `ref.watch(localeProvider)` 直接喂给 MaterialApp，locale 变化会整体重建路由树，页面级 UI 会刷新。不会刷新的：a) 已有 State 缓存的文案（如 `qualityNames` 常量 —— 本来就是中文，见 F2）；b) **Toast 显示中的那条**（OverlayEntry builder 闭包持有旧字符串，2.4 秒后消失，无感知问题）；c) 系统层 `title`（见 E5）；d) `AlertDialog` 若在其打开期间切语言 —— `_showApiEditDialog` 等用外层 `context.l10n` 求值后传入 title，不会刷新，但切语言入口与弹窗互斥，实际无感。整体：**无需要重启的硬伤**。
11. 无对应审查点（属于 C 组，见下）。

### C. 更新检查
11. **_compareVersion 预发布处理** — ✅ 通过，且正确对齐 semver：`1.0.0-rc1 < 1.0.0`（`if (pa.isEmpty) return 1;`）；`1.0.0-alpha < 1.0.0-alpha.1`（`if (i >= pa.length) return -1;` 标识更少者更旧 ✓）；数字段按数值比、标识段按 ASCII 比 ✓；`+build` 剔除 ✓；`v` 前缀剔除 ✓。轻微偏差：semver 规定数字标识 < ASCII 标识（`1.0.0-1 < 1.0.0-alpha`），当前实现只要一个是数字就按数值比、否则 ASCII，`1.0.0-alpha vs 1.0.0-1` 会走 ASCII 分支得出 alpha > 1 ✓ 碰巧一致；`1.0.0-2 vs 1.0.0-rc` 会数值比较返回 -1（2 < rc）——semver 亦判定 2 < rc ✓。实际无害。
12. **代理前缀拼接** — 格式 `https://proxy.344977.xyz/https://api.github.com/...` 与 `.../https://github.com/.../releases/download/...` 是自建代理约定的「全 URL 作为路径」格式，与 `AppConfig.proxyMvUrl` 的用法一致，对 API 和下载直链**均适用**（通过）。风险提示：该代理是单一故障点且写死在两个文件（update_checker.dart:44 与 app_config.dart:14），建议 update_checker 引用 `AppConfig.proxyBase` 而非重复字面量（代码质量小项）。
13. **arm64 优先 / fallback** — ✅ 通过：`_pickApkUrl` 遍历 assets，`.apk` 结尾 + `name.contains('arm64')` 直接返回；否则记第一个 APK 作 fallback；两者皆无时回退 `release['html_url']`（网页，浏览器打开后用户可手选）——三级 fallback 合理。小瑕疵：fallback 会命中 `universal.apk` 或 arm32（若在前），可加 `name.contains('armeabi')||name.contains('universal')` 排序优先级，非必须。
14. **release notes** — 纯文本 + 1200 字符截断 + SingleChildScrollView（见 E4，无溢出风险，仅 Markdown 符号观感问题）。
15. **Toast dedupe / Overlay context** — 见 E3；showDialog 内可用（通过项）。
16. **PermissionGate 与 StoragePermissionService 职责** — ✅ 通过。职责切分清晰且有注释明确「唯一权威」：判定与申请逻辑全在 StoragePermissionService，PermissionGate 只做 UI 层门面（ensureStorageWrite → request；hasStorageWriteAccess → 只查不弹，注释还特意说明诊断页只读展示不能弹窗）。error_logger.dart 的 `_hasStoragePermission` 也复用 Service 的 `currentStrategy()`，无重复申请路径。
17. **分组顺序** — ✅ 通过。实际顺序：账号 → 外观 → 播放 → 下载 → 缓存 → API → 诊断 → 关于，与题目给出的 Material 3 建议顺序完全一致；且组件选型符合 M3（SliverAppBar.large 大标题、SegmentedButton 单选、SwitchListTile 开关、底部弹层代替居中 Dialog、危险操作 error 色 + 二次确认），注释中均有 M3 依据说明。

### 附加抽查
- **verification_listener.dart** — ✅ 通过。`_handling` 防重入、`mounted` 检查、`ref.listen` 在 build 中使用（Riverpod 2.x 正确用法）、验证通过后 `retryPendingPlayback()` 重试链路完整。
- **app_config.dart** — ✅ 通过。proxyMvUrl 对 https 直通；10 语言 supportedLocales 与 localeNames 一一对应，与 l10n 生成物的 locale 列表一致（zh/zh_CN/zh_TW + 8 语言）。

---

## 三、通过项汇总（无需改动）
- FutureBuilder 两个均提为 State 字段，无无限重建（settings_page.dart）
- _checkingUpdate 的 try/finally + mounted 复位 + 防重入
- Hive 未打开时 provider 全部有默认值兜底，不崩
- 缓存清理不会误删下载文件与错误日志
- 版本号 version + buildNumber 均显示
- _compareVersion 语义化版本（含预发布、build number、v 前缀）处理正确
- arm64 → 任意 APK → release 网页 三级下载 fallback
- release notes 1200 字符截断 + 可滚动，无溢出
- Toast 在 showDialog context 下可用；Toast.copy 带 mounted 检查
- PermissionGate/StoragePermissionService 职责单一，无重复申请
- 设置页分组顺序与 M3 组件选型符合规范
- 离线 l10n 生成器输出形状与 flutter gen-l10n 兼容（SynchronousFuture、回退链）
- ARB 占位符元数据完整，生成签名与调用点匹配

## 四、修复优先级建议
1. F1（10 语言中文漏翻，用户直接可见）
2. F2（音质名硬编码中文）
3. captcha_page.dart 17 处硬编码中文
4. F3（缓存统计口径）
5. E1/E2（API 编辑校验与超时）
6. E4/E5/Q1-Q3（观感与代码质量）
