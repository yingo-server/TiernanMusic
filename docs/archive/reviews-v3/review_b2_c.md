# 审查报告：下载 / 存储 / 权限模块（批2检3，纯读）

审查基线：commit `bcfd024`。只读审查，未修改任何代码、未运行任何测试。
按严重度排序：编译阻塞 > 功能失效 > 体验瑕疵 > 代码质量。通过项附后。

---

## 一、功能失效

### F1. 歌词下载在 Android 10+ 必然失败：Downloads collection 不接受 `Documents/` RELATIVE_PATH
- **位置**：`lib/features/download/data/public_media_store.dart:47-52`（`collectionOf`）+ `android/.../MainActivity.kt:246-253`（`collectionUri`）
- **问题**：`collectionOf(lyric)` 返回 `'downloads'`，映射到 `MediaStore.Downloads.EXTERNAL_CONTENT_URI`；而 `relativePathOf(lyric)` 返回 `'Documents/Tiernan Music/Lyrics'`。`MediaStore.Downloads` 要求 RELATIVE_PATH 必须位于 `Download/` 之下，传入 `Documents/...` 时 `contentResolver.insert()` 会抛 `IllegalArgumentException`（部分 OEM 直接拒绝）。异常被 `publish()` 的 `catch (_)` 吞掉后走 `_publishDirect`，而 Android 10+ scoped storage 下 `Directory.create()` 同样失败 → 任务报失败。同文件内 `MainActivity.kt` 的 `appendText` 注释已明确说明该语义（"用 Downloads collection 会落到 /sdcard/Download"），说明作者知道坑但在下载路径没用对。
- **修法**：
```dart
// public_media_store.dart
static String collectionOf(DownloadTaskType type) => switch (type) {
      DownloadTaskType.audio => 'audio',
      DownloadTaskType.cover => 'images',
      DownloadTaskType.lyric => 'files', // MediaStore.Files，支持 Documents/ 下任意路径
      DownloadTaskType.mv => 'video',
    };
```
```kotlin
// MainActivity.kt collectionUri() 增加：
"files" -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
```
（注意：当前 `collectionUri` 未知集合会落到 `else -> Audio`，属静默错插，建议改为抛错。）

### F2. publish 写流抛异常时遗留 IS_PENDING=1 的孤儿条目
- **位置**：`lib/features/download/data/public_media_store.dart:92-118`（`publish`）
- **问题**：`write` 返回 `false`（ok != true）时会 `delete` pending 条目再降级，处理正确；但 `write`/`finalize` **抛异常**时走 `catch (_) { return _publishDirect(...) }`，pending 条目没有删除，会残留约 7 天（MediaStore 对 pending 条目的清理周期）或在部分机型永久残留。
- **修法**：
```dart
} catch (_) {
  try {
    await _channel.invokeMethod<bool>('delete', {'uri': uri});
  } catch (_) {}
  return _publishDirect(type, tempFilePath, displayName);
}
```
同时建议检查 `finalize` 返回值：`if (await _channel.invokeMethod<bool>('finalize', ...) != true) { /* 记录但不降级，文件实际已写完 */ }`。

### F3. 暂停/继续竞态：可对同一任务并发跑两个 `_run`，状态显示错乱
- **位置**：`lib/features/download/download_provider.dart:135-146`（`pause`）、`148-158`（`resume`）、`227-320`（`_run`）
- **问题**：时序——① `pause()`：cancel token、`_running.remove(id)`、状态置 paused；② 用户立刻 `resume()`：状态置 queued，`_schedule()` 发现该 id 不在 `_running` → 启动第 2 个 `_run`（新 token，状态 running）；③ 第 1 个 `_run` 的 `DioException(cancel)` 分支随后执行，把状态改回 **paused**——但真正在下载的是第 2 个 `_run`。后果：进度回调里 `cur.status != running → return` 使进度条冻结；UI 显示"已暂停"但实际在下载；极端时序下第 1 个任务的 `finally` 里 `_schedule()` 还可能与第 2 个并存写同一 tempPath（`{hash}_{type}.mp3` 同名），文件损坏。
- **修法**：`_run` 的异常处理里校验 token 归属，非当前 token 的回调一律忽略：
```dart
Future<void> _run(DownloadTask task) async {
  final token = CancelToken();
  _tokens[task.id] = token;
  ...
  } on DioException catch (e) {
    if (_tokens[task.id] != token) return; // 已被新的 _run 接管
    ...
  } finally {
    if (_tokens[task.id] == token) _tokens.remove(task.id);
    _running.remove(task.id);
    unawaited(_schedule());
  }
```
另外 `resume()` 应加守卫：`if (task.isActive) return;`（对 running/queued 任务重复 resume 会把状态改回 queued，同样冻结进度）。

### F4. downloadFile 对所有错误一视同仁重试，且无超时
- **位置**：`lib/features/download/data/download_repository.dart:82-110`（`downloadFile`）
- **问题**：
  1. `catch (e)` 不区分错误类型：404/403/签名过期等 4xx 重试纯属浪费（且 2 次重试放大请求量）；只有网络层错误（连接失败、超时、5xx）值得重试。
  2. `Dio()` 未配置 `connectTimeout/receiveTimeout`，CDN 挂起时任务永远停在 running。
  3. 重试无退避延迟，连续 3 发打同一 CDN。
  4. 无 Range 断点续传（注释已坦白"每次重试从头开始"），大 MV 重试代价高——至少应在重试时改用 `Range: bytes=已收-` + `openOutputStream(uri, "wa")`。
- **修法**（最小改动）：
```dart
} on DioException catch (e) {
  if (cancelToken != null && cancelToken.isCancelled) rethrow;
  final status = e.response?.statusCode ?? 0;
  final retryable = e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      (status >= 500 && status < 600);
  if (!retryable || attempt > retries) rethrow;
  await Future<void>.delayed(Duration(seconds: attempt)); // 线性退避
}
```
并在构造时：
```dart
_dio = dio ?? Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(minutes: 10),
));
```

### F5. Android 10+ 上权限拒绝后从设置返回，策略缓存永不刷新
- **位置**：`lib/features/download/download_provider.dart:67-69`（`_strategyResolved`）+ `lib/features/download/data/storage_permission_service.dart:96-105`（`resolveStrategy`）
- **问题**：`_strategyResolved` 首次置 true 后终身复用。Android ≤9 用户首次拒绝 → 策略锁定为 `appFallback`，即使随后去系统设置授权，本次进程内所有下载仍落到 `Android/data/...`（需重启 App）。且 `requestStoragePermission` 在 `isPermanentlyDenied` 时直接静默 `openAppSettings()`（`storage_permission_service.dart:79-82`），用户从设置页返回后没有任何"重新检测"逻辑。
- **修法**：监听生命周期，resume 时若权限状态变化则重置缓存：
```dart
// DownloadManager 构造器中
AppLifecycleState? _last;
void onAppLifecycle(AppLifecycleState s) {
  if (s == AppLifecycleState.resumed && _last == AppLifecycleState.paused) {
    _strategyResolved = false; // 下次下载重新 resolveStrategy()
  }
  _last = s;
}
```
（同时建议 `isPermanentlyDenied` 时的 `openAppSettings` 移到 UI 层并配文案，见 X3。）

---

## 二、体验瑕疵

### X1. 重新下载已完成歌曲会产生 MediaStore 副本文件（"xxx (1).mp3"）
- **位置**：`lib/features/download/download_provider.dart:106-121`（`add`）+ `public_media_store.dart:92`（`publish` 未先 `queryExisting`）
- **问题**：对已 completed 任务再次 `add()`（下载弹层对 paused/failed/queued 状态都显示下载按钮，点了就重新入队）会再次 insert，MediaStore 对同名 DISPLAY_NAME 自动追加 `" (1)"`，产生重复文件且旧文件不受任务管理（`remove` 只删最新 uri）。`queryExisting` 已实现却未在 publish 前调用（在所读 13 个文件内未见任何调用点，疑似死代码）。
- **修法**：`_run` 在 `publish` 前：
```dart
final exist = await PublicMediaStore.instance.queryExisting(
    type: task.type, displayName: DownloadRepository.displayNameOf(task));
final published = exist ?? await _repo.publish(task, tempPath, strategy: _strategy);
```
另注意：`queryExisting` 的「已下载」判定只匹配精确 displayName，MediaStore 自动改名过的 `(1)` 副本查不到；且只查了本 App 记录外的公共库，若用户手动删了文件但 Hive 记录还在，`hasAudio` 仍返回 true（应以存在性为准或打开时校验）。

### X2. displayName 清洗不含控制字符与 Windows 保留尾巴
- **位置**：`lib/features/download/data/download_repository.dart:126-133`（`displayNameOf`）
- **问题**：`RegExp(r'[\\/:*?"<>|]')` 已覆盖非法字符（好），但没处理：① 结尾的 `.` 和空格（Windows 同步到 NTFS/exFAT 时 `dir.create` / 某些 PC 文件管理器报错，Android 本身允许）；② `\x00-\x1f` 控制字符（Windows 硬错）；③ Windows 保留名 `CON/PRN/AUX/NUL/COM1..9/LPT1..9`（概率极低，可不做）。
- **修法**：
```dart
final safe = (base.isEmpty ? task.hash : base)
    .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
    .replaceAll(RegExp(r'[.\s]+$'), ''); // 去尾部点/空格（Windows）
if (safe.isEmpty) safe 版回退 task.hash;
```

### X3. 「用其它应用打开」/「在文件管理器查看」失败零反馈
- **位置**：`lib/features/download/presentation/download_page.dart:174-190`（`open`/`folder` 分支）、`247-252`（onTap）
- **问题**：`PublicMediaStore.open/viewFolder` 返回 bool，但 UI 完全忽略返回值。`viewFolder` 用 `ACTION_VIEW + resource/folder` + FileProvider uri——绝大多数文件管理器**不支持**以 FileProvider uri 打开目录；降级分支用 `Uri.fromFile`（`MainActivity.kt:136-141`），在无文件管理器或 API 24+ 上抛 `FileUriExposedException` 被 catch 返回 false → 用户点了没任何反应。
- **修法**：
```dart
case 'folder':
  final ok = await PublicMediaStore.instance.viewFolder(...);
  if (!ok && context.mounted) {
    Toast.show(context, context.l10n.openInFileManagerFailed); // 需新增文案
  }
  break;
```
更稳的原生方案：`DocumentsUI` intent——`Intent("android.provider.action.VIEW").setDataAndTypeDocumentsUri(...)`，或干脆展示 `displayPath` 文案 + 提供"复制路径"。

### X4. Android ≤9 权限被拒后降级路径用户找不到（提示缺失）
- **位置**：`lib/features/download/data/public_media_store.dart:120-126`（`fallbackDir`）+ 下载页无任何提示
- **问题**：降级到 `Android/data/<pkg>/files/Music/Tiernan Music`，多数文件管理器在 Android 11+ 看不到该目录（Android/data 被限制访问）——虽然此分支只在 ≤9 或拒绝后出现，≤9 上 `Android/data` 通常可见，但完成后的 `displayPath` 显示的是绝对路径长串，没有"该目录在文件管理器中的位置"的友好说明，也没有"去授权以存到公共音乐目录"的引导。
- **修法**：任务 completed 且 `strategy == appFallback` 时，subtitle 追加一句引导文案（如「已存到应用专属目录，授予存储权限后可存到公共音乐库」+ 跳设置按钮）。

### X5. 进度回调每 chunk 写一次 Hive
- **位置**：`lib/features/download/download_provider.dart:246-257`（`onProgress` → `_update` → `DownloadStore.save`）
- **问题**：`onReceiveProgress` 每个 TCP chunk 触发，一次 5MB 歌曲可触发数百次 `box.put`（Hive 每次都落盘），大 MV 更是放大 IO 与耗电。
- **修法**：节流——
```dart
var lastFlush = 0;
void onProgress(int received, int total) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastFlush < 500 && received < total) return; // 500ms 节流
  lastFlush = now;
  ...原逻辑...
}
```

### X6. 下载弹层对 paused/queued/failed 状态显示与"未下载"相同的下载图标
- **位置**：`lib/features/download/presentation/download_sheet.dart:150-172`（`_OptionTile`）
- **问题**：trailing 只有三种形态：completed 打勾 / running 转圈 / 其余一律下载按钮。queued 任务点击会 `add()` 重排（幂等但把位置提到队首）；failed 显示下载而非"重试"图标，用户不知道已失败（错误信息只在下载页可见）。另外「全部下载」不含 MV（若为有意设计建议注释说明）。
- **修法**：`status == failed` 时显示 `Icons.error_outline`（红色）+ 点击走 `manager.retry`；queued 显示 `Icons.hourglass_empty` 灰色；paused 显示 `Icons.pause_circle_outline` + 点击 resume。

### X7. 进度条 0% / 未知大小时的表现
- **位置**：`lib/features/download/presentation/download_page.dart:116-120`
- **问题**：`LinearProgressIndicator(value: progress)`，`progress` 为 null（total 未知）时是来回滚动的 indeterminate 条——可接受；但 `received=0, total 已知` 时是 0 宽度的空条，用户分不清"没开始"和"进行中"。建议 running 且 value==null 时叠加文字「正在连接…」。

---

## 三、代码质量 / 低风险

### Q1. 日志轮转行为不一致（≥29 丢弃 vs ≤28 改名 .1）
- **位置**：`lib/core/utils/error_logger.dart:126-131`（Dart ≤28 分支，`error_logger.dart` 的 `_appendPublic`）与 `MainActivity.kt:197-205`（≥29 在 `appendText` 内 `old = ""`）
- **问题**：≤28 分支轮转成 `error_x.log.1`（保留旧日志）；≥29 分支直接丢旧内容。行为不一致但**可接受**：MediaStore 下做 rename 轮转需 insert 新条目 + copy 流，复杂度高、收益低。建议在 `appendText` 注释中明示"等价轮转（丢弃）"，避免后人当 bug 修。
- **注意**：Dart 侧 `_appendPublic` 的 ≤28 轮转代码（`error_logger.dart` 约 121-127 行）与原生 `appendText` 的 ≤28 分支（`MainActivity.kt:211-218`，同样有 `.1` rename）**重复实现**，且 Dart 侧先 rename 再 appendText，原生又会 rename 一次——双份轮转逻辑应收敛到一处（建议只留 Dart 侧，原生 ≤28 分支删掉 rename）。

### Q2. MediaStore 日志读旧+整份重写的 O(n²) 写放大
- **位置**：`MainActivity.kt:169-193`（`appendText` ≥29 已存在分支：`readBytes()` 全量读 → `openOutputStream(uri, "rwt")` 全量写）
- **问题**：每条日志都全量读+全量写当日文件；错误风暴时 5MB 文件每条日志触发 10MB IO，耗电明显。**建议**：Dart 侧内存 buffer 聚合（如 5 秒 / 8KB 批量 flush 一次），不改原生。当前实现是正确性优先的合理简化，非必改项。

### Q3. 日志可能包含敏感信息
- **位置**：`lib/core/utils/error_logger.dart:203-215`（`logApi` 把响应 body 截 800 字符写入日志）
- **问题**：响应体可能含 token/签名/手机号等；日志又落在公共 `Documents/Tiernan Music/Logs/`（文件管理器可见，且用户可能上传分享）。Dio 的 `header` 没有直接落盘（好），但建议 `logApi` 写入前做脱敏：正则剔除 `(token|sign|key|cookie)\s*[=:]\s*\S+`。

### Q4. `PermissionGate.requestWithPrompt` 在所读范围内无调用点（疑似死代码）
- **位置**：`lib/core/utils/permission_gate.dart:66-83`
- **问题**：13 个文件内未发现调用。职责划分本身清晰（`PermissionGate`=UI 提示层，`StoragePermissionService`=判定权威，无重复申请逻辑——除了 `PermissionGate.ensureStorageWrite` 与 service 直接调用并存两套入口，建议统一走 PermissionGate）。若全仓确认无调用应删除，或让下载入口改用它（能解决 Q5 的"静默弹设置页"问题）。

### Q5. `openAppSettings` 藏在 Service 层，静默跳转
- **位置**：`lib/features/download/data/storage_permission_service.dart:79-82, 88-91`
- **问题**：`requestStoragePermission` / `requestNotificationPermission` 在 permanentlyDenied 时直接拉起系统设置，用户不知道为什么被带过去，回来也没有引导文案。这是 UI 决策，应上移到 `PermissionGate`（有 context 可弹 Toast/Dialog）。

### Q6. 删除他人文件时静默失败且仍删除任务记录
- **位置**：`lib/features/download/download_provider.dart:160-177`（`remove`）
- **问题**：`PublicMediaStore.delete` 对非本 App 创建的 MediaStore 条目（Android 10+ 上 `contentResolver.delete` 抛 `RecoverableSecurityException` → catch 返回 false）会 false，但 `remove` 不管结果照删 Hive 记录 → 文件成"游离文件"。本 App 自己 insert 的条目必然可删，风险低；建议 false 时保留记录或 Toast 提示「文件删除失败，请手动清理」。

### Q7. `ErrorLogger._rewriteMediaStore` 返回值语义
- **位置**：`lib/core/utils/error_logger.dart:158-172`
- **问题**：`return ok != null` —— 原生失败返回 null 时正确返回 false；但原生**回退到 Downloads collection** 时返回的路径仍是 `/sdcard/Documents/...`（`MainActivity.kt:193` 固定拼 relativePath），`_publicDirPath` 会把错误路径展示给用户。修法：原生按实际落点返回（Files 命中→Documents 路径；Downloads 回退→`/sdcard/Download/...`）。
- `currentDirPath()` 只回传实际写入过的路径、`_publicDirPath` 仅成功后赋值——审查点 11 的要求满足 ✓。

### Q8. `hasAudio` / 已下载判定只看 Hive
- **位置**：`download_provider.dart:186-189`（`hasAudio`）
- **问题**：用户在系统文件管理器手动删文件后，App 仍认为已下载（点开播放才失败）。建议 completed 任务打开时做存在性校验（uri 查询 / File.exists），失败则把任务转回 failed。

---

## 四、通过项（确认无问题）

1. **并发上限 2 与槽位释放**：`_schedule` 的 while 循环 + `_running` 集合逻辑正确；`pause/remove/clearAll/_run finally` 都会释放槽位并重新调度，无饥饿死锁（除 F3 竞态外）。`_running.add` 与 `_run` 启动顺序正确（同步添加后再 unawaited），不会超卖并发。
2. **崩溃恢复**：`_restore()` 把 running/queued 置为 paused 正确；temp 文件虽残留（`downloads_tmp/`）但下次下载同名覆盖，无功能性影响（建议启动时顺手清理：`tempDir().then((d) => d.deleteRecursively())` —— 列入改进而非缺陷）。
3. **displayName 非法字符**：`[\\/:*?"<>|]` 清洗已实现（X2 是补强项）。
4. **MediaStore pending 流程主干**：insert(pending=1) → write("w") → finalize(pending=0) 完整；write 返回 false 时会 delete pending 条目并降级（F2 只针对异常路径）。
5. **日志三层分流**：≥29 走原生 MediaStore Files（RELATIVE_PATH 以 `/` 结尾、`Documents/Tiernan Music/Logs/` 语义正确，与 ≤28 分支 `removePrefix("Documents/")` 拼接一致）；≤28 检查权限但不弹窗（合理：日志是隐式路径）；失败降级私有目录且 `init()` 不缓存失败状态 ✓。
6. **`_apiLevelFromOsVersion` 兜底**：版本名→API 映射正确（Android N→N+19；≤9 直接返回，9→9 与 `needsLegacyWritePermission` 的 `<29` 配合正确），认不出时取 29 走 MediaStore 是安全侧 ✓。
7. **Manifest 权限**：`WRITE_EXTERNAL_STORAGE` 限 `maxSdkVersion="28"` ✓；`READ_MEDIA_*` 声明了但本 App 只读自己写的文件，属冗余但无害（上架审核可能被问，建议移除或加 `tools:node` 说明）；FileProvider `grantUriPermissions="true"`、`exported="false"` ✓；`openFile` 带 `FLAG_GRANT_READ_URI_PERMISSION` ✓。
8. **`file_paths.xml`**：`external-path path="."` 覆盖 `/sdcard` 全部 → 公共目录文件与 `Android/data` 降级目录都能被 FileProvider 分享（偏宽但功能正确）。
9. **删除双路径**：uri（MediaStore）与 path（File.delete）都处理 ✓。
10. **UI 基础**：暂停菜单只在 running/queued 显示 ✓；失败有重试入口 ✓；completed 显示路径 ✓；清空/删除均有二次确认且危险操作用 error 色 ✓；空状态 ✓。
11. **下载弹层四类型独立状态**：音频/封面/歌词/MV 各自按 hash+type 匹配任务、独立进度与打勾 ✓。
12. **`viewFolder` 仅在 `filePath` 非空时展示菜单项**（download_page.dart:208）——MediaStore-only 任务不会点到必然失败的入口，处理得当 ✓。

---

## 五、修复优先级建议

1. **F1**（歌词在 10+ 必挂）→ 2. **F3**（并发竞态）→ 3. **F4**（重试/超时）→ 4. **F2**（pending 孤儿）→ 5. **F5/X1/X3**（体验）→ 其余按需。
