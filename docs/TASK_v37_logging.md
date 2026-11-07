# v3.7 任务书：日志系统完善 + 存储重构（修复代理）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）。

## 用户需求（原话拆解）
1. **日志捕获和「一坨屎一样」**：要求**设置中加开关**，打开后**无条件捕获所有日志**（全量：debugPrint/网络请求响应/播放状态/下载/错误全部落盘；关闭时保持现状）
2. **应用内部存储不变**（凭证/Hive 等不动）
3. **设备存储改为**：文件管理器根目录 `/storage/emulated/0/TierNanMusic/` 下分域子目录：`audio` / `mv` / `logs` ……
4. 用户已确认方案：**MANAGE_EXTERNAL_STORAGE（所有文件访问）+ 自动降级**——授权成功写根目录 TierNanMusic；未授权自动退回 `Download/TiernanMusic`；两个位置的路径都要在设置页展示并支持一键跳转授权页

## ⚠️ 硬性规则（最高优先级，违反即任务失败）
- **绝对禁止安装 Flutter SDK / flutter build / flutter test / flutter gen-l10n / dart pub get**——本沙箱是 ARM64 无 Flutter 环境，装了也无法构建（上一个代理试图删 pubspec 的 flutter 依赖来绕过，直接污染了仓库，已回滚）。**任何对 pubspec.yaml 的修改都是失败**。允许且只允许：`dart analyze`（Dart SDK 3.13.7 在 /opt/dart/bin）。
- analyze 出现的 Flutter/第三方包符号报错（Widget/State/BuildContext/riverpod 等）是**预期噪音**，过滤规则见下；但 **pubspec.yaml 一行都不许动**。
- 允许 dart analyze；**触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**（v3.4 试错 4 轮教训）
- 跨文件改动双向核对；项目自有类报错即真错误
- 禁 git commit/push；只用 file_edit；改动标 `V37-LOG-xx`
- 实时落盘

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `832761d`

## 报告
`docs/v37_logging_storage.md`

## 任务分解

### 一、全局日志开关 + 全量捕获（核心）
1. **设置开关**：`settings_provider.dart` 加 `verboseLoggingProvider`（StateProvider<bool>，持久化到 Hive settings box，默认 false）
2. **ErrorLogger 扩展**（`error_logger.dart`）：
   - 加 `verboseMode` 静态开关（与 provider 联动，main.dart 监听时同步）
   - verbose 关：保持现状（只记 FlutterError/runZonedGuarded/显式 log 调用）
   - verbose 开：**无条件落盘一切**——
     a) 拦截 `debugPrint`：全局包一层（参考 Flutter 的 debugPrint 覆盖机制：`debugPrint = (msg, {wrapWidth}) { ErrorLogger.instance.debug(msg); debugPrint(msg, wrapWidth: wrapWidth); }` 在 verbose 开启时安装）——注意防递归
     b) 网络层：KgClient `request()` 的每次请求/响应（method/url/status/耗时/errorCode）经 ErrorLogger 记录（verbose 开时；请求体响应体过大截断至 4KB，且脱敏规则必须先跑——B-17/N-2 已修的脱敏在 log 入口统一执行）
     c) 播放状态：audio_handler 的 playbackState 变化（仅状态枚举变化时记，不逐帧）
     d) 下载状态迁移：download_provider 的 `_update` 每次状态变更记一行
   - 所有写入走**现有串行链**（_writeQueue + 链尾 catchError），不得并发写
   - 脱敏不可绕过：verbose 落盘的每一行都过 `_redact`
3. **写盘路径**：verbose 日志写 `<存储根>/TierNanMusic/logs/`（见二），单文件 2MB 上限轮转保留 5 份

### 二、存储根目录重构（外置 TierNanMusic/）
1. **StoragePermissionService 扩展**（`storage_permission_service.dart`）：
   - 新增 `resolveRoot()`: MANAGE_EXTERNAL_STORAGE 已授权（`Permission.manageExternalStorage.isGranted`）→ 返回 `/storage/emulated/0/TierNanMusic`；未授权 → 返回 `/storage/emulated/0/Download/TiernanMusic`（MediaStore 或直写，API≥29 走 MediaStore Download）
   - 需要子目录常量：`audio/`、`mv/`、`logs/`、`cover/`、`lyrics/`（下载链路的 fallbackDir/publicDirNameOf 全部改指向）
2. **AndroidManifest**：加 `MANAGE_EXTERNAL_STORAGE` 权限声明 + `requestLegacyExternalStorage`（Android 10 兼容）
3. **设置页**：「存储与日志」区新增——
   - 日志详细模式开关（verboseLoggingProvider）
   - 当前存储根路径展示（实际生效路径，区分「根目录模式/Download 模式」）
   - 「授权所有文件访问」按钮（`Permission.manageExternalStorage.request()` → 跳系统授权页），授权状态实时刷新
4. **迁移**：不迁移旧文件（Download/TiernanMusic 里的历史下载保持可播放——download_store 的 mediaUri/filePath 已持久化，不动）；新下载写入新路径
5. **download_provider/public_media_store/error_logger 三处根路径统一**走 `resolveRoot()`，禁止各自硬编码

### 三、播放失败诊断（排查 H1 的配套）
- 上轮已修 ensureEngineReady → ErrorLogger；本批确认 verbose 开启时该条也能落盘即可

## 验收标准
- verbose 开 + 已授权：文件管理器 `/storage/emulated/0/TiernanMusic/logs/` 能看到日志文件且包含网络请求记录
- verbose 开 + 未授权：日志写 Download/TiernanMusic/logs/，设置页明确提示当前模式
- verbose 关：行为与现状完全一致
- 下载的新文件落在新目录 audio/，历史文件不受影响

## 完成后
追加报告 `docs/v37_logging_storage.md`：逐条 V37-LOG-xx、**每个触碰文件 analyze 结果**、验收标准逐条自评（能静态验证的）、需要真机验证的列清单。
8 行内汇报。
