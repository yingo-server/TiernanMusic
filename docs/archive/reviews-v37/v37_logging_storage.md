# v3.7 报告：日志系统完善 + 存储重构（V37-LOG 系列）

基线 `3e8d525`（任务书正文写 832761d，以沙箱实际 HEAD 为准）。进行中，实时更新。

## 改动清单

- V37-LOG-01 `lib/core/theme/settings_provider.dart`：新增 `verboseLoggingProvider`（StateNotifier<bool>，持久化 Hive settings box `verboseLogging` 键，默认 false）。采用与同文件 themeMode/locale/lyricMode 一致的 StateNotifier 模式而非裸 StateProvider，保证「读盘初值 + 持久化写入」单一来源（第 5 条）。
- V37-LOG-02 `lib/core/utils/error_logger.dart`：`verboseMode` 静态开关 + `setVerbose(bool)`（安装/卸载 debugPrint 全局包装，防递归：包装内不再走 debugPrint，直写落盘链）；新增 `verbose(msg, tag)` 与 `debug(msg)`——统一走现有 `_writeQueue` 串行链（链尾 catchError 兜底），每行过 `_redact`，verbose 关时零开销直接 return（行为与现状一致）；verbose 文件名 `verbose_YYYY-MM-DD.log`，2MB 轮转保留 5 份；已授权直写 `<根>/logs/`，未授权走 MediaStore `Download/TiernanMusic/logs/`。
- V37-LOG-03 `lib/main.dart`：App build 中 `ErrorLogger.setVerbose(ref.watch(verboseLoggingProvider))` 同步 provider 与静态开关（幂等，可重复执行）。
- V37-LOG-04 `lib/core/direct/kg_client.dart`：`request()` 每次请求/响应（method/url/status/耗时 ms/errorCode）verbose 落盘；请求体/响应体截断 4KB；DioException 也记录。脱敏由 ErrorLogger 入口统一执行。
- V37-LOG-05 `lib/features/player/data/audio_handler.dart`：`_broadcastState` 仅在 processingState/playing 组合变化时记一行（不逐帧）。
- V37-LOG-06 `lib/features/download/download_provider.dart`：`_update` 状态迁移记一行（与旧状态比较，仅变化时）。
- V37-LOG-07 `lib/features/download/data/storage_permission_service.dart`：新增根目录常量（`TierNanMusic` / fallback `TiernanMusic`）、子目录常量 `audio/mv/logs/cover/lyrics`、`resolveRoot()`、`isAllFilesAccessGranted()`、`requestAllFilesAccess()`；`resolveStrategy/currentStrategy` 已授权 MANAGE_EXTERNAL_STORAGE 时返回 directPath。
- V37-LOG-08 `lib/features/download/data/public_media_store.dart`：`relativePathOf`（MediaStore 回退路径）→ `Download/TiernanMusic/{audio,mv,cover,lyrics}`；`_publishDirect` 已授权 → `<根>/<子目录>` 直写，未授权 → `Download/TiernanMusic/<子目录>`（≤28 需写权限，否则 appFallback）；`queryExisting` 与发布路径同步。
- V37-LOG-09 `android/app/src/main/AndroidManifest.xml`：`MANAGE_EXTERNAL_STORAGE` 权限 + `requestLegacyExternalStorage=true`。
- V37-LOG-10 `lib/features/settings/presentation/settings_page.dart`：诊断区新增 verbose 开关、当前存储根路径（区分根目录模式/Download 模式）、「授权所有文件访问」按钮。
- V37-LOG-11 `lib/l10n/app_*.arb` + 重新生成 `app_localizations.dart`（用项目自带 `tool/gen_l10n_min.py`，离线脚本，非 flutter gen-l10n）。

## analyze 结果

（见文末逐文件报告）

## 验收自评

（收尾填写）

## 需真机验证

（收尾填写）

---

## analyze 结果（逐文件，dart analyze 3.13.7，过滤 Flutter/第三方符号噪音后）

| 文件 | 报告 | 项目自有错误 |
|---|---|---|
| lib/core/theme/settings_provider.dart | 47 issues | 0（全部 Widget/ThemeMode/Box/StateNotifier 等噪音；V37-LOG-01 新增段与同文件既有模式一致，无新错误行号落在新增区间） |
| lib/core/utils/error_logger.dart | 20 issues | 0（初版 1 条真错误 `instance_access_to_static_member: service.logsSubDir`（99 行）已修复为 `StoragePermissionService.logsSubDir`，复测归零；其余为 debugPrint/MethodChannel/getApplicationDocumentsDirectory/FlutterErrorDetails 噪音） |
| lib/main.dart | 103 issues | 0（Widget 系噪音；本次仅新增 2 行 setVerbose 同步，247-248 行无报错） |
| lib/core/direct/kg_client.dart | 12 issues | 0（全部 Dio/Response/Options 噪音） |
| lib/features/player/data/audio_handler.dart | ~30 issues | 0（audio_service/just_audio 噪音 + 3 条 `BaseAudioHandler` 未解析连带的 mixin 报错，属 Flutter 符号噪音，修改前同样存在） |
| lib/features/download/download_provider.dart | 41 issues | 0（riverpod/Dio 噪音；另有 197/328 行 dead_code warning 为存量代码，非本批触碰行） |
| lib/features/download/data/storage_permission_service.dart | 14 issues | 0（Permission/MethodChannel 噪音） |
| lib/features/download/data/public_media_store.dart | 8 issues | 0（MethodChannel/path_provider 噪音；顺带第 32 条清理：删除已无消费方的死常量 `folderName` 与死方法 `_subSuffix`，过滤噪音后项目自有错误为 0） |
| lib/features/settings/presentation/settings_page.dart | 498 issues | 0（Material 系噪音；新增 236-288 行区间无项目自有报错；新增 import `storage_permission_service.dart` 解析正常） |
| lib/l10n/app_localizations.dart | 62 issues | 0（`Locale`/`SynchronousFuture`/`_Msg.r` 均为 flutter 符号噪音，重新生成前后形态一致） |
| lib/l10n/l10n.dart | 2 issues | 0（未触碰，仅复核） |
| android/app/src/main/AndroidManifest.xml | 非 Dart，无 analyze | XML 结构经 grep 核对（权限声明在 `<manifest>` 直接子级，`requestLegacyExternalStorage` 在 `<application>` 属性上） |

## 跨文件双向核对（已静态验证）

- `verboseLoggingProvider`：定义 settings_provider.dart ↔ 消费 settings_page.dart（watch/read）、main.dart（watch → ErrorLogger.setVerbose）✅
- `ErrorLogger.setVerbose/verboseMode/verbose`：定义 error_logger.dart ↔ 消费 main.dart、kg_client.dart、audio_handler.dart、download_provider.dart ✅
- `resolveRoot/resolveRootMode/rootPath/fallbackRootDirName/subDirOf/logsSubDir/verboseRelativePath/requestAllFilesAccess`：定义 storage_permission_service.dart ↔ 消费 error_logger.dart、public_media_store.dart、settings_page.dart ✅
- `relativePathOf/publicDirNameOf`：仅 public_media_store.dart 内部消费，无外部调用点受签名变化影响 ✅
- l10n 新 key（6 个）11 个 ARB 全量补齐 → gen_l10n_min.py 重新生成，settings_page 消费点全部存在 ✅

## 验收标准逐条自评（静态可验证部分）

1. **verbose 开 + 已授权 → /storage/emulated/0/TiernanMusic/logs/**：✅ `_writeVerbose` 优先 `resolveRoot()`（已授权 = rootPath）+ `logsSubDir` 直写；kg_client `_logVerboseRequest` 在 verbose 开时对每次 request() 落盘（含 method/url/status/耗时/errorCode + 4KB 截断体），脱敏在 `_redact` 入口统一执行。
2. **verbose 开 + 未授权 → Download/TiernanMusic/logs/ + 设置页提示**：✅ 直写失败走 MediaStore `Download/TiernanMusic/logs/`（verboseRelativePath，API≥29）；设置页 FutureBuilder 显示 `storageModeDownload` 文案与实际路径。
3. **verbose 关 = 现状**：✅ `verbose()`/`debug()`/`_logVerboseRequest`/audio/download 记录点第一行均 `if (!verboseMode) return`；log() 既有路径未改写逻辑（仅串行链提取为共用 `_enqueue`，语义不变）；debugPrint 包装保留但内部受 verboseMode 门控。
4. **新下载落 audio/ 等子目录，历史文件不受影响**：✅ `relativePathOf`/`_publishDirect`/`queryExisting` 三处同步指向新分域子目录；download_store/mediaUri/filePath 持久化路径未动，迁移策略 = 不迁移（任务书四.4）。

## 需真机验证清单

1. MANAGE_EXTERNAL_STORAGE 授权流程：permission_handler 是否正确跳转系统「所有文件访问」页并在返回后 `request()` 返回 granted。
2. 已授权直写 /storage/emulated/0/TierNanMusic/{audio,mv,cover,lyrics,logs} 是否成功（部分厂商 ROM 对 MANAGE_EXTERNAL_STORAGE 直写有额外限制）。
3. MediaStore `appendText` 写 `Download/TiernanMusic/logs/verbose.log`（非 Downloads 集合而是 files 集合路径）在目标机型上的真实行为。
4. Android ≤9 直写 Download/TiernanMusic（需旧版写权限）分支。
5. debugPrint 全局包装在 release 模式下的行为与开销（AOT 下 debugPrint 仍存在，但建议真机确认无递归/无卡顿）。
6. verbose 开启长时间运行的日志体积（2MB × 5 轮转是否够用）。
7. 设置页「存储根路径」卡片两行文案在不同屏幕字号下不溢出。

## 遗留说明

- 任务书正文基线 `832761d` 与沙箱 HEAD `3e8d525` 不一致，以沙箱 HEAD 为基线执行（3e8d525 即上一批提交）。
- 根目录名严格按用户原话取 `TierNanMusic`（非 TiernanMusic），常量处已注释说明勿"修正"。
- 未改 pubspec.yaml；未安装任何 SDK/依赖；未执行 flutter 命令；未 git commit/push；仅用 file_edit/shell（离线脚本 gen_l10n_min.py 重新生成 l10n，属项目自带工具链）。
