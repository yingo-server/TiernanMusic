# v3.9.9 B 档修复报告（V399-B1~B4）

基线 755dcea。实时落盘中。

## V399-B1 个人信息页登录大延迟（进行中）
- 已读：library_page.dart / auth_providers.dart / auth_repository.dart / secure_storage.dart / account_manager.dart / settings_page.dart 账号区
- 事实：library_page build 串行 watch 两个独立 FutureProvider（歌单+收藏MV），恢复会话 restoreSession 内 loginByToken 成功前不返回 → 下方库页等用户信息请求完成后才可见；设置页 _loadStorageRoot 串行两次 await。

## V399-B1 个人信息页登录大延迟（完成）
改动：
- `auth_repository.dart` `_handleLoginSuccess`：落盘链并行化（V399-B1）。修复前序列：
  `getDfid()(可能网络) → saveCredentials → setCredentials → saveAccountToken → AccountManager.upsert → Hive settings` 六段串行；
  修复后：dfid 获取与 saveAccountToken/upsert/settings 盒写入**并行**发起，saveCredentials+setCredentials 保持顺序语义，副作用写失败留痕不再吞（第 9 条）。
- `secure_storage.dart` `readCredentials`：五键读取由 5 次 await 串行 → `Future.wait` 并行（Keystore 慢机型每次读凭证延迟 ×5 → ×1）。
- `settings_page.dart` `_loadStorageRoot`：resolveRoot/resolveRootMode 并行（后者内含写探针，串行翻倍延迟）。
- `library_page.dart`：歌单/收藏 MV 两区块 `skipLoadingOnReload: true`（stale-while-revalidate）——重取时先渲染上一次数据，骨架只在首次无缓存出现；两 provider 本就独立并行 watch，无串行网络链。
- 恢复链 restoreSession 仍需先确认凭证有效（loginByToken），属登录语义必需，无法砍掉；已把其内部子步骤全部并行化。
- 修复后序列：`[dfid ‖ saveAccountToken ‖ upsert ‖ settings盒] → saveCredentials → setCredentials`（等待=max(并行段) 而非 Σ）。

## V399-B2 权限网关（完成）
改动 `storage_permission_service.dart` / `public_media_store.dart` / `settings_page.dart`：
- a) `resolveRoot()` 每次调用重新实测：写探针文件→读回→删除（`_probeWritable`）。授权态为真但实测失败（ROM 怪癖/目录只读）→ 降级 Download 根并留痕。Download 根也实测；原生 publicDir 通道失败留痕。探测结果存 `lastProbeError` 供 UI 展示。
- b) 每步骤失败留痕对照（修复前→后）：
  | 步骤 | 修复前 | 修复后 |
  |---|---|---|
  | isAllFilesAccessGranted | `catch (_) {}` 吞 | debugPrint + lastProbeError |
  | requestAllFilesAccess | 失败只 debugPrint | 同左 + 未授权写 lastProbeError |
  | apiLevel 通道失败 | `catch (_) {}` 吞 | debugPrint |
  | storage.request/status 异常 | 无捕获（崩溃） | try/catch + 留痕 + 按未授权降级 |
  | notification.request/status | 同上 | 同上 |
  | openAppSettings | 无捕获 | try/catch + 留痕 |
  | publicDir/publicDirWritable 通道 | `catch (_) {}` 吞 | debugPrint + lastProbeError |
  | resolveRoot 探测/降级 | 无留痕 | debugPrint + lastProbeError |
  - 探测留痕**刻意不走 ErrorLogger**：ErrorLogger._writeVerbose 自身调 resolveRoot，会形成探测失败→写日志→再探测递归（第 22 条）。用 debugPrint + lastProbeError。
- c) 依赖方刷新：设置页 resumed 重查已有（V37-PERM-02）；DownloadManager.onAppLifecycle resume 重置策略缓存已有；`public_media_store._publishDirect` 修复前自判 `isAllFilesAccessGranted()+rootPath` 拼路径（信声称态），修复后统一走实测 `resolveRoot()`——授权被系统收回后立即落 Download 根。
- d) 设置页「存储根目录」subtitle 展示 resolveRoot 实测返回路径 + 探测失败原因（`storageProbeFailed` l10n 键），不再把声称路径当实际可写。

## V399-B3 音质音效补齐（完成）
- `models.dart` AudioQuality 扩蝰蛇三档（viper_tape/clear/atmos）+ 魔法六档（magic_piano/acappella/dj/surnay/subwoofer/ancient）；`viperOrder`/`magicOrder`/`isSpecial`；魔法档不进 `fallbackOrder` 通用降级链（注释明示）；fromString 兼容无 magic_ 前缀写法。
- `kg_play_api.dart`：`magicQualities` 补齐带前缀 wire 名（与枚举 value 对齐）；`songUrl` 前缀映射修正为「已是 magic_* 不重复补，其余魔法名补 magic_，蝰蛇原样传」；新增 `viperQualities`。
- `player_repository.dart`：直连降级按族分链（魔法在 magicOrder 内、蝰蛇在 viperOrder 内、普通在 fallbackOrder）；**特殊档不享有 freePart 试听兜底**（试听返回普通音源片段，冒充特殊音效属数据失真）；特殊档直连失败/kapi 一律不回退，抛 ApiException 明确报因；`_qualityFromBitrate` 对特殊档不做码率推断。
- UI：设置页 `_qualityNames` 暴露九个新档（10 键 × 11 语言 ARB 全补 + `gen_l10n_min.py` 重跑：356 keys, 11 locales）。魔法档匿名可用——选档不设 VIP 门槛，失败按 API 报因明示。

## V399-B4 非 VIP 下载择优（完成）
- `kg_play_api.dart` PlayUrlResult 新增 `previewFileSize`（响应体 filesize）与 `offsetFileSize`（hash_offset.start_byte/end_byte 之差），fromResponse 解析。
- `download_repository.dart`：新增唯一解析入口 `resolveAudioDownloadSource`——全曲可下走 'full'；否则请求试听通道（IsFreePart=1），比较 API **声明的字节数**（trialBytes vs climaxBytes）择长；高潮更长时用 offset_hash 再发一次元数据请求拿 URL（'climax'），解析失败留痕回落试听（'trial'）。**未做任何下载比对**。旧 resolveAudioUrl/resolveAudioExt/resolveAudioUrlWithExt 已无调用方，删除（第 32 条）。
- `download_task.dart`：新增 `segment` 字段（'full'/'trial'/'climax'），toJson/fromJson/copyWith 全链路；`download_provider.dart` _run 切换到新入口并记录 segment；下载页 UI 未变。

## dart analyze 逐文件报告（只允许 dart analyze，Flutter/三方符号缺失为预期噪音；基线同口径噪音经 git stash 对照确认）
| 文件 | 结果 |
|---|---|
| models.dart | 0 自有错误（enum 扩展后全仓无穷尽 switch 依赖，核实无 exhaustive switch） |
| player_repository.dart | 0 自有错误；1 warning(unnecessary_null_comparison :314) 基线已有 |
| kg_play_api.dart | 0 自有错误（KgClient/KgConfig/KgSignature 均为项目类，无报错） |
| download_repository.dart | 0 自有错误；其余为 Dio 符号缺失噪音 |
| download_task.dart | 0 错误（纯 Dart） |
| download_provider.dart | 0 自有错误；StateNotifier/Crypto 符号噪音（基线同） |
| storage_permission_service.dart | 0 自有错误；Permission/MethodChannel 符号噪音 |
| public_media_store.dart | 0 自有错误；MethodChannel/path_provider 噪音 |
| settings_page.dart | 0 自有错误；Flutter framework 噪音（基线 712 issues 同口径） |
| library_page.dart | 0 自有错误；同上 |
| auth_repository.dart | 0 自有错误；2 dead_code warning 基线已有（rethrow 可达性误报） |
| secure_storage.dart | 0 自有错误；flutter_secure_storage 符号噪音 |

## l10n
- 新键 10 个 × 11 语言（zh/zh_CN/zh_TW/en/ja/ko/de/fr/es/pt/ru）全补；
- `python3 tool/gen_l10n_min.py` 输出：`wrote lib/l10n/app_localizations.dart: 356 keys, 11 locales`。

## 未做项
- 播放页（full_player_page）音质即时切换菜单：A/C 档代理同期改动该文件（V399-A1/A3），避免跨代理冲突；音质经设置页默认档生效，播放页已有 _QualityBadge 展示实际档。
- pubspec.yaml 未动一字；未装 SDK/flutter/dart pub get；仅 dart analyze。
