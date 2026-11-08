# 第 2 批审查③：下载与音乐库（只读）

- 审查基线：`73e72c0`（CI 全绿）
- 审查方式：完整读取源码（未运行、未构建、未修改源码）
- 审查范围：
  - `lib/features/download/**`（download_provider / download_repository / download_store / download_task / public_media_store / storage_permission_service / download_page / download_sheet）
  - `lib/features/library/**`（library_page / recent_play_store）
  - `lib/features/player/presentation/queue_sheet.dart`
  - 关联只读核对：`main.dart`、`audio_handler.dart`、`player_repository.dart`、`player_provider.dart`、`preferred_quality.dart`、`kg_play_api.dart`、`MainActivity.kt`、`AndroidManifest.xml`、`network_security_config.xml`、各下载入口页
- 说明：按要求未读取 `docs/batch1_*.md` 与 `docs/check_*.md`，避免锚定。

## 结论

- P0：0 项
- P1：8 项
- P2：51 项

---

## A. 下载内核（队列 / 任务 / 解析）

### DL-01（P1）下载不识别试听地址，30~60 秒试听片段会被当作完整歌曲落盘

- 位置：`lib/features/download/data/download_repository.dart:53-62`；`lib/core/direct/kg_play_api.dart:265-271`
- 现象：`resolveAudioUrl()` 只取 `result.bestUrl` 并返回，`PlayUrlResult.isPreview`、`failProcess`、`ssaCode` 全部未读取。下载任务随后直接进入 `completed`，文件名与完成状态都与完整歌曲一致。
- 依据：`kg_play_api.dart:265-267` 明确把 `end_ms <= 65000` 或 URL 含 `/p_0_` 标记为 `isPreview`；播放链路 `audio_handler.dart:305-306` 会消费该标记并在全屏页显示“试听”角标，而下载链路没有任何对应分支。
- 影响：无版权/未登录/非会员场景下，“已下载”的歌曲实际只有几十秒，离线播放时中途截断，且用户无法从下载列表分辨。

### DL-02（P1）音频扩展名与 MIME 硬编码为 mp3，无视服务端实际返回 flac/ogg 等格式

- 位置：`lib/features/download/data/download_task.dart:19-27`；`lib/features/download/data/public_media_store.dart:39-46`；`lib/features/download/data/download_repository.dart:53-62`
- 现象：`DownloadTaskTypeX.fileExtension` 对 `audio` 恒定返回 `.mp3`；`PublicMediaStore.mimeOf` 对音频恒定返回 `audio/mpeg`。`PlayUrlResult.extName`（服务端实际扩展名）从未被使用，URL 路径也未参与判断。
- 依据：`kg_play_api.dart:271` 已解析 `extName`；`download_provider.dart:267-268` 用固定 `fileExtension` 拼临时文件名；`public_media_store.dart:42` 固定 `audio/mpeg`；`MainActivity.guessMime` 反而能按 `.flac` 正确返回 `audio/flac`，说明类型判断只缺在下载侧。
- 影响：下载无损/Hi-Res 歌曲后，公共目录里是 `.mp3` 后缀 + `audio/mpeg` 元数据、内容却是 FLAC。MediaStore 索引类型错误，第三方播放器/车机/文件管理器可能拒绝播放或显示错误信息；应用内播放能靠解码器嗅探掩盖该问题。

### DL-03（P1）同 id 任务重复下载时不会取消旧任务，旧任务完成会改写新任务状态

- 位置：`lib/features/download/download_provider.dart:101-114`（add）、`236-246`（_schedule）、`321-338`（完成回写）
- 现象：`add()` 只把新任务写为 `queued` 并替换状态，不取消正在执行的 `_run`；`_schedule()` 看到该 id 仍在 `_running` 中会跳过，于是新任务永远不启动。旧 `_run` 完成后执行 `_find(task.id)` 拿到的是**新任务对象**，直接把新任务标记为 `completed` 并写入旧任务的文件信息。
- 依据：`add()` 内无 `_tokens[task.id]?.cancel()`；`_schedule()` 的筛选条件含 `!_running.contains(t.id)`；`_run()` 末尾用 `cur.copyWith(status: completed, ...)` 回写。`download_sheet.dart:108-114` 的“全部下载”按钮在任务 running 时仍可点击，是直接触发路径。
- 影响：用户改默认音质后对同一首歌再次点下载，界面短暂显示重新排队，随后被旧任务的结果覆盖，下载到的仍是旧音质；若新任务参数（目标语言、封面地址）不同，也会被旧结果覆盖。

### DL-04（P1）暂停/继续时旧请求的取消异常会污染新任务状态，并提前释放并发槽

- 位置：`lib/features/download/download_provider.dart:123-136`（pause）、`340-351`（DioException 分支）、`362-365`（finally）
- 现象：`pause()` 立即 `_running.remove(id)` 并取消 token；用户马上 `resume()` 会启动新的 `_run` 并写入新 token。旧请求随后抛 `DioExceptionType.cancel`，其 `on DioException` 分支只判断 `cur != null`，不校验 token 归属，会把**新任务**改成 `paused`。旧 `_run` 的 `finally` 又无条件 `_running.remove(task.id)`，把新任务占用的并发槽一并释放。
- 依据：通用 `catch (e)` 分支有 `if (_tokens[task.id] != token) return;`，而 `on DioException` 分支没有同样的归属校验；`finally` 中只有删除 token 做了比较，`_running.remove` 没有。
- 影响：快速“暂停→继续”后任务卡在暂停、进度不动，或调度器以为并发未满而多启动下载（实际并发超过 `maxConcurrent=2`），在弱网下进一步拖慢所有任务。

### DL-05（P1）发布成功后临时文件从不删除，失败/取消/删除也不清理，单曲下载长期占用双份空间

- 位置：`lib/features/download/download_provider.dart:266-268`、`321-322`、`362-366`；`lib/features/download/data/public_media_store.dart:58-64`
- 现象：`tempPath` 只在 `_run` 内创建和使用，整个工程没有任何 `File(tempPath).delete()` 调用；`remove()`/`clearAll()` 只删除已发布文件（`mediaUri`/`filePath`），不触碰临时目录。
- 依据：对 `lib/features/download` 全目录检索 `tempPath`，仅出现于 `download_provider.dart` 的创建、下载、发布、读取大小四处，无删除调用；临时目录固定为 `getTemporaryDirectory()/downloads_tmp`。
- 影响：每次成功下载后，私有缓存保留一份等大的副本；MV 与无损歌曲可达数十至数百 MB。下载越多占用越大，只能依赖系统清理缓存，且删除任务/清空列表都不会释放。

### DL-06（P1）每个进度回调都同步落 Hive 并重建整个下载状态

- 位置：`lib/features/download/download_provider.dart:272-280`（onProgress）、`230-234`（_update）、`219-228`（_replace）
- 现象：Dio 的 `onReceiveProgress` 每收到数据块就调用 `_update`，后者复制整个任务列表、替换状态，并 `unawaited(DownloadStore.save(task))` 写 Hive。两个并发任务时写盘频率与网络分块频率同量级。
- 依据：`onProgress` 无节流/去抖；`_update` 内 `DownloadStore.save(task)` 每次调用；`DownloadState` 无选择器，`downloadedAudioProvider`（`download_provider.dart:386-392`）依赖整个 `downloadManagerProvider`，任何进度变化都会重算并通知音乐库页重建。
- 影响：下载期间 UI 掉帧、Hive 频繁写盘与 box 压缩；音乐库页即使只展示“已下载”，也会随每个进度包整页重建，放大图片解码与布局开销。

### DL-07（P2）重下时会先删除旧文件，新文件发布失败则旧文件已丢失

- 位置：`lib/features/download/download_provider.dart:310-320`
- 现象：`queryExisting()` 命中后先 `delete(exist)`，再 `publish()`。若发布阶段插入/写入/权限失败，任务转为 `failed`，旧文件已经不存在。
- 依据：删除发生在 `publish` 之前，且 `publish` 抛错时没有恢复/保留旧文件的路径。
- 影响：弱网或存储异常时，用户为了换音质重下，结果既没有得到新文件，也失去了原本可离线播放的旧文件；任务记录只保留失败状态。

### DL-08（P2）删除/清空任务无法中断“发布中”阶段，会生成不受管理的孤儿文件

- 位置：`lib/features/download/download_provider.dart:159-178`（remove）、`180-198`（clearAll）、`309-338`（发布段）
- 现象：`remove()` 取消 token 并立刻删除任务记录，但 `_run` 在下载完成后进入 `queryExisting → publish` 期间不再检查 token。若删除发生在该窗口，文件仍会被写入公共目录，随后 `_find(task.id)` 为 null，任务不记录该文件。
- 依据：`_run` 的发布段没有 `_tokens[task.id] == token` 检查；`remove`/`clearAll` 删除的是任务当时的 `mediaUri`（下载中为空）。
- 影响：用户点删除后仍会多出一个公共目录文件，且下载列表里没有任何入口可再次删除它；`clearAll` 之后同样会残留。

### DL-09（P2）暂停保留的“进度”只是数字，继续时从 0 重下且进度条回跳

- 位置：`lib/features/download/download_provider.dart:124-131`（注释）、`248-258`（_run 重置）、`84-117`（downloadFile）
- 现象：`pause` 的注释称“保留已下载进度信息”，但继续时 `_run` 立即 `received: 0, total: 0`；Dio 默认 `deleteOnError: true` 会删除半成品；重试也是整文件重下。
- 依据：`_run` 起始的 `copyWith(received: 0, total: 0...)`；`downloadFile` 未使用 Range/断点续传参数。
- 影响：大文件（MV/无损）暂停后继续会从零开始，UI 已显示的进度瞬间归零，用户容易误以为下载失败而反复操作。

### DL-10（P2）任务 id 不含音质，重下覆盖同一记录，历史与文件不可区分

- 位置：`lib/features/download/data/download_task.dart:99-101`；`lib/features/download/data/download_repository.dart:187-196`
- 现象：`id = '${type.name}_$hash'`，`displayName` 也不含音质；不同音质下载落到同一任务 id、同一公共文件名。
- 依据：`DownloadTask.id` 与 `displayNameOf` 均未使用 `quality`；`DownloadManager.add` 以 id 覆盖。
- 影响：用户无法同时保留 128 与无损两份；换音质重下会覆盖并删除原文件；任务记录中只剩最后一次音质，无法回溯。

### DL-11（P2）同名不同曲会互相删除文件，旧任务仍显示“已完成”

- 位置：`lib/features/download/data/download_repository.dart:187-196`；`lib/features/download/download_provider.dart:310-318`
- 现象：文件名仅由 `artist - title + 扩展名` 构成。两首同名同歌手（Live/Remix/不同专辑）下载时，后一首的 `queryExisting` 会命中并删除前一首文件。
- 依据：`displayNameOf` 未拼接 hash/albumAudioId/quality 等区分项；`queryExisting` 按 displayName 精确匹配后直接删除。
- 影响：前一首任务仍为 `completed` 且 `mediaUri` 指向已被删除的条目，音乐库继续展示，点击播放失败（并触发 PL-01 的连锁问题）。

### DL-12（P2）`add()` 复用已有任务时把 `createdAt` 写成 0，持久化排序错乱

- 位置：`lib/features/download/download_provider.dart:101-112`
- 现象：`createdAt: exists ? task.createdAt : now` 使用的是**传入的新任务**的 `createdAt`，而新建 `DownloadTask` 默认 `createdAt = 0`；已有任务的时间戳被清零。
- 依据：`DownloadSheet.buildTask`（`download_sheet.dart:33-46`）构造任务时未设置 `createdAt`；`DownloadStore.readAll()`（`download_store.dart:34`）按 `createdAt` 倒序恢复。
- 影响：任何重复下载都会让该任务在下次启动后排到列表末尾；下载管理页顺序与用户操作时间不一致。

### DL-13（P2）恢复任务只改内存状态不回写，且不校验已完成文件是否仍存在

- 位置：`lib/features/download/download_provider.dart:81-99`；`lib/features/download/data/download_store.dart:21-37`
- 现象：`_restore()` 把 `running/queued` 转成 `paused` 后只赋给 `state`，没有 `DownloadStore.save`；Hive 中仍是 `running/queued`。同时对所有 `completed` 任务原样恢复，不检查 `mediaUri/filePath` 是否还存在。
- 依据：`_restore` 内无任何写库调用；`completed` 分支直接 `return t`；后续没有文件存在性校验。
- 影响：每次冷启动都会重复一次“运行中→暂停”的转换（若将来有逻辑依赖持久化状态会不一致）；外部清理/换机/迁移后，音乐库仍显示已下载并可点击，实际文件已不存在。

### DL-14（P2）`addAll` 串行写入且不跳过已完成任务，“全部下载”会重下并删除已有文件

- 位置：`lib/features/download/download_provider.dart:116-120`；`lib/features/download/presentation/download_sheet.dart:104-116`
- 现象：`addAll` 对每项 `await add()`，每次都落库并调度；“全部下载”无条件加入 audio/cover/lyric 三项，即使任务已完成。
- 依据：`addAll` 无状态判断；`DownloadSheet` 的按钮直接 `buildTask` 三项，未过滤 `completed`。
- 影响：已下载歌曲再次点“全部下载”会重新排队、删除旧文件并重下（叠加 DL-07），离线时会失败并把原本可用的下载项变成 failed。

### DL-15（P2）下载失败/重试路径忽略服务端明确拒绝原因

- 位置：`lib/features/download/data/download_repository.dart:55-62`；`lib/features/download/download_provider.dart:333-352`
- 现象：`resolveAudioUrl` 仅在无 URL 时用 `result.message`；`failProcess`（服务端明确拒绝原因）与 `ssaCode` 被丢弃。Dio 失败时 `error: e.message ?? '下载失败'`。
- 依据：`PlayUrlResult` 已解析 `failProcess`/`ssaCode`（`kg_play_api.dart:228-234`），下载侧未引用。
- 影响：需要购买/无版权/地区限制时，用户只看到“无可用播放地址”或 Dio 的英文 message，无法判断是版权问题还是网络问题。

### DL-16（P2）歌词下载不支持取消，暂停后仍会继续请求并写临时文件

- 位置：`lib/features/download/data/download_repository.dart:146-172`；`lib/features/download/download_provider.dart:298-300`
- 现象：`downloadLyric()` 签名接收 `cancelToken` 但从未使用；内部的 `findCandidate`、`fetchLyric`、`ensureTranslation` 全是不可取消的 Future。
- 依据：该方法参数 `cancelToken` 在方法体内无引用；`_run` 的 lyric 分支传入 token 也不产生效果。
- 影响：歌词任务暂停/删除后网络请求继续，结束后仍写临时文件；删除任务后无法阻止后续写入（与 DL-08 叠加）。

### DL-17（P2）接收超时 10 分钟且无心跳，CDN 挂起时任务长时间停在 running

- 位置：`lib/features/download/data/download_repository.dart:27-33`
- 现象：`receiveTimeout` 为 10 分钟，`connectTimeout` 15 秒；Dio 的 receiveTimeout 只约束两次数据到达之间的间隔，但 10 分钟对移动网络过长。
- 依据：`BaseOptions(... receiveTimeout: Duration(minutes: 10))`；`_run` 无额外的 watchdog。
- 影响：CDN 卡住时任务界面显示“下载中”最长 10 分钟不动，用户只能手动暂停；期间占用并发槽。

### DL-18（P2）存储权限兜底的 API 版本映射错误

- 位置：`lib/features/download/data/storage_permission_service.dart:58-67`
- 现象：`if (name <= 9) return name;` 把 Android 9 映射为 API 9（应为 28）；`return name + 19` 对 Android 13/14/15 分别得到 32/33/34（应为 33/34/35）。
- 依据：同函数注释写明“Android 9 == API 28”“逐版本递增”，与实际返回值矛盾；该函数仅在 MethodChannel 失败时启用。
- 影响：原生通道异常时，Android 13+ 的 `requestNotificationPermission` 会误判 `< 33` 直接返回 true；Android 9 虽仍走 `<29` 分支，但任何未来依赖精确 level 的逻辑都会出错。

### DL-19（P2）下载没有前台服务/通知，后台或锁屏时不可靠

- 位置：`android/app/src/main/AndroidManifest.xml:6-21`（仅音频播放服务）；`lib/features/download/data/storage_permission_service.dart:88-101`
- 现象：下载只运行在 Flutter 主 isolate 的普通异步任务中，没有 foreground service、WakeLock 或下载通知；`requestNotificationPermission()` 在全工程无调用点。
- 依据：Manifest 只有 `AudioService`（`foregroundServiceType="mediaPlayback"`），无下载服务；检索 `ensureNotification`/`requestNotificationPermission` 仅定义未使用。
- 影响：用户锁屏或切到后台后，系统可能冻结/杀死进程，下载中断且无通知提示；大文件下载体验不可控。

### DL-20（P2）`firstWhere` 状态解析把未知/损坏记录默认为 queued

- 位置：`lib/features/download/data/download_task.dart:213-226`
- 现象：`fromJson` 对未知 `type` 默认 `audio`、未知 `status` 默认 `queued`；结合 `_restore` 会把它们转成 paused 并显示为可继续任务。
- 依据：两处 `firstWhere(..., orElse: ...)`。
- 影响：Hive 记录损坏或版本升级后，错误类型/状态的任务会以错误标签出现在下载列表，甚至被当作音频展示。

### DL-21（P2）删除音频任务不会联动清理同曲的封面/歌词任务与文件

- 位置：`lib/features/download/download_provider.dart:159-178`（remove）、`116-120`（addAll）；`lib/features/download/presentation/download_sheet.dart:104-116`
- 现象：“全部下载”把 audio/cover/lyric 生成为三个独立 id 的任务；删除音频任务时 `remove(id)` 只按该 id 删除文件与记录，不处理同 hash 的封面/歌词。
- 依据：`remove` 仅有单一 `id` 参数；`DownloadManager` 没有按 `hash` 分组的删除逻辑；三个任务的 id 分别为 `audio_<hash>`/`cover_<hash>`/`lyric_<hash>`。
- 影响：用户在下载管理页删除歌曲后，封面图和歌词仍留在 Pictures/Documents 与任务列表里；`clearAll` 才能全清，逐条删除会越积越多。

---

## B. 公共目录发布（MediaStore / 降级）

### PB-01（P1）降级发布整文件读入内存，MV/无损可能 OOM

- 位置：`lib/features/download/data/public_media_store.dart:145-150`
- 现象：`_publishDirect` 使用 `await File(tempFilePath).readAsBytes()` 一次性读入完整文件再 `writeAsBytes`。
- 依据：该方法无流式复制；`_publishDirect` 在 MediaStore 插入返回 null、写入失败、finalize 异常以及 `appFallback`/`directPath` 策略下都会被调用。
- 影响：Android 9 或权限降级场景下载数百 MB 的 MV/无损时，峰值内存约等于文件大小，容易 OOM 崩溃；即便不崩也会造成明显卡顿。

### PB-02（P2）MediaStore `insert` 抛异常时没有降级，任务直接失败

- 位置：`lib/features/download/data/public_media_store.dart:81-90`
- 现象：只有 `insert` 返回 null/空串才走 `_publishDirect`；`invokeMethod` 抛 `PlatformException`（非法 RELATIVE_PATH、集合不支持、同名冲突等）时异常直接冒出 `publish`。
- 依据：`insert` 调用在 `try` 块之外，后续 `write/finalize` 才被 `try` 包裹。
- 影响：本应降级到直接路径的场景变成整个下载任务失败，且临时文件已下载完成，用户重试仍会重复失败。

### PB-03（P2）`finalize` 返回值被忽略，pending 条目可能永久不可见

- 位置：`lib/features/download/data/public_media_store.dart:99-103`；`android/.../MainActivity.kt:303-311`
- 现象：`invokeMethod<bool>('finalize')` 的结果未检查；原生 `finalize` 无论 `contentResolver.update` 是否命中行都 `return true`。若更新 0 行（条目已被删/uri 失效），Dart 侧仍返回成功。
- 依据：Dart 未接收返回值；Kotlin 直接 `return true`。
- 影响：任务显示“已完成”，但 MediaStore 中文件仍 `IS_PENDING=1`，文件管理器与其他应用看不到，直到系统清理。

### PB-04（P2）“在文件管理器中打开”把文件当目录，MediaStore 任务传入 content:// 必然失败

- 位置：`lib/features/download/data/public_media_store.dart:225-240`；`android/.../MainActivity.kt:154-177`；`lib/features/download/presentation/download_page.dart:220-234`
- 现象：`PublishedFile.path` 的语义是**文件**路径，不是所在目录；`viewFolder` 直接 `File(path)` 再对该文件发 `ACTION_VIEW` + `resource/folder`。Android 10+ 时 `DownloadManager` 把 `content://` 存进 `filePath`，`download_page` 又把它作为 `path` 传入，原生 `File("content://...")` 不存在，直接返回 false。
- 依据：`publish` 的 MediaStore 分支只构造 `uri` 和 `displayPath`（`public_media_store.dart:100-103`）；`DownloadManager` 写入 `filePath: published.path ?? published.uri`（`download_provider.dart:330`），即把 uri 塞进 path 语义字段；`_publishDirect` 返回 `path: target.path`（文件本身）。
- 影响：Android 10+ 上“打开所在目录”永远失败，随后 `download_page.dart:230-232` 把 `content://...` 复制到剪贴板，而不是用户需要的 `/sdcard/Music/...`；Android 9 上即使成功也是把文件当目录打开。

### PB-05（P2）MediaStore URI 打开时无法推断 MIME

- 位置：`android/.../MainActivity.kt:136-141`、`229-242`；`lib/features/download/presentation/download_page.dart:210-219`
- 现象：`openFile` 优先使用 `uri`，但 `guessMime(uri, path)` 只看字符串后缀；MediaStore URI 形如 `content://media/external/audio/media/123`，没有扩展名，且下载任务未单独保存扩展名/MIME。
- 依据：`guessMime` 的 when 分支全部是 `endsWith(".mp3")` 等；`PublishedFile` 无 mime 字段。
- 影响：点击“用其他应用打开”时以 `*/*` 发起 Intent，部分播放器/文件管理器不会出现在候选列表，或需要用户手动选择。

### PB-06（P2）`query` 的 RELATIVE_PATH 前缀匹配会命中同前缀兄弟目录

- 位置：`android/.../MainActivity.kt:330-335`
- 现象：`selection = "DISPLAY_NAME = ? AND RELATIVE_PATH LIKE ?"`，参数为 `"$relativePath%"`；`relativePath` 不带尾部 `/`（如 `Music/Tiernan Music`），会匹配 `Music/Tiernan Music2/`、`Music/Tiernan MusicBackup/` 等目录下的同名文件。
- 依据：`relativePathOf`（`public_media_store.dart:25-31`）返回值均无尾斜杠；SQL 使用 `%` 通配。
- 影响：`queryExisting` 可能返回别的目录里的同名文件，`DownloadManager` 随后 `delete` 它，误删非本应用管理的文件。

### PB-07（P2）文件名无长度限制，超长标题会让发布失败

- 位置：`lib/features/download/data/download_repository.dart:187-196`
- 现象：仅替换非法字符与尾部点/空格，没有截断；`artist - title + 扩展名` 直接作为 DISPLAY_NAME/文件名。
- 依据：`displayNameOf` 无 `length`/字节数限制；MediaStore 与 ext4 对文件名有 255 字节上限。
- 影响：超长歌名（尤其中文/emoji，多字节）触发 `IllegalArgumentException`/`ENAMETOOLONG`，下载在最后发布阶段失败，临时文件已完整下载。

### PB-08（P2）歌词产物是自定义时间戳文本而非 LRC，外部播放器不可用

- 位置：`lib/features/download/data/download_repository.dart:199-222`；`lib/features/download/data/download_task.dart:25`
- 现象：`_lyricToText` 输出 `[ti]`、`[ar]` 与 `[mm:ss.cc] 原文` / 同时间戳译文两行，扩展名为 `.txt`。
- 依据：文件后缀固定 `.txt`，行内没有 LRC 的 `[mm:ss.xx]` 之外的标准标签（如 `[by]`、`[offset]`），且译文与原文共用时间戳、无语言区分。
- 影响：用户从“下载歌词”得到的是仅供阅读的文本，无法被音乐播放器作为 LRC 外挂歌词加载；与功能命名预期不符。

### PB-09（P2）封面扩展名/MIME 固定 jpg，未按实际内容判断

- 位置：`lib/features/download/data/download_task.dart:23`；`lib/features/download/data/public_media_store.dart:43`
- 现象：`cover` 固定 `.jpg` + `image/jpeg`；`coverUrl` 可能是 png/webp（不同 CDN 返回）。
- 依据：`downloadCover` 直接按 URL 下载，未解析 Content-Type；`fileExtension`/`mimeOf` 均硬编码。
- 影响：少数封面在相册/图片查看器中类型不符，或部分解码器按错误 MIME 处理。

### PB-10（P2）MediaStore 失败后的“降级直写”在 Android 10+ 仍写公共目录，且不使用已有的可写检测

- 位置：`lib/features/download/data/public_media_store.dart:117-150`；`lib/features/download/data/storage_permission_service.dart:120-141`
- 现象：`_publishDirect` 无条件调用 `service.publicDir(...)`，只要返回值非空就创建 `Music/Tiernan Music` 等公共目录并写文件；`StoragePermissionService.isPublicDirWritable()`（原生 `publicDirWritable` 已实现）在全工程无调用点。
- 依据：`publish()` 在 `StorageStrategy.mediaStore` 写入失败时调用 `_publishDirect`（`public_media_store.dart:90/97/110`）；`_publishDirect` 只在 `publicBase == null/空` 时才使用 `fallbackDir`（`public_media_store.dart:123-129`），没有 API 级别判断；`isPublicDirWritable` 仅定义未使用。
- 影响：Android 10+ 上 MediaStore 插入/写入失败后，所谓“降级”会改为直写 scoped storage 禁止的公共路径，必然再次失败，任务最终报错；真正可写的 `Android/data` 降级目录在该分支永远走不到。

---

## C. 下载入口与展示

### DU-01（P2）歌单详情下载丢失 albumId 与时长

- 位置：`lib/features/playlist/presentation/playlist_detail_page.dart:268-276`
- 现象：从歌单点下载时构造的 `Song` 未传 `albumId`、`duration`，而 `PlaylistSong` 本身有这两个字段（`playlist_repository.dart:222-239`）。
- 依据：`showDownloadSheet` 的 `Song(...)` 只填 hash/albumAudioId/name/artist/cover；`DownloadSheet.buildTask` 用 `song.albumId`、`song.duration.inSeconds` 生成任务（`download_sheet.dart:38-43`）。
- 影响：`songUrl` 以 `album_id=0` 请求，部分歌曲解析失败或音质降级；`lyric` 任务 `durationSec=0`，KRC 候选匹配（`download_repository.dart:154-158`）更容易选错歌词。

### DU-02（P2）最近播放下载/播放缺少 albumId 与时长

- 位置：`lib/features/library/presentation/library_page.dart:203-212`、`128-148`；`lib/features/library/data/recent_play_store.dart:5-21`
- 现象：`RecentPlay` 未保存 `albumId`、`duration`、`quality`；`_playRecent` 构造 `Song` 时 `albumId: ''`、`duration` 为 0；从最近播放打开下载弹层同样带空 `albumId`。
- 依据：`RecentPlay` 字段仅 hash/name/artist/cover/ts/albumAudioId；`recentPlayRecorderProvider`（`player_provider.dart:155-166`）也未写入这些字段。
- 影响：播放时 `/privilege/lite` 首次请求带空 album_id（详情返回后才回填），下载任务固定 albumId=0、歌词时长 0；离线/接口异常时退化更明显。

### DU-03（P2）“全部下载”不含 MV，已完成项也没有删除/重下入口

- 位置：`lib/features/download/presentation/download_sheet.dart:104-116`、`155-170`
- 现象：按钮文案为“全部下载”，实际只添加 audio/cover/lyric，入口列表中的 MV 被排除；`_OptionTile` 在 `completed` 时只显示对勾图标，没有删除或重新下载入口。
- 依据：`manager.addAll([...])` 列表只有三项；`_OptionTile` 的 trailing 分支 completed → 对勾，running → 转圈，其余 → 下载 IconButton；completed 图标不可点击。
- 影响：用户对“全部”的理解与行为不一致；已完成的封面/歌词无法在弹层内撤销或换音质，只能去下载管理页逐条找；已完成音频也无法从弹层重下。

### DU-04（P2）下载列表不显示音质与实际大小，失败原因单行截断

- 位置：`lib/features/download/presentation/download_page.dart:132-188`
- 现象：副标题只有“类型 · 状态 · error”；已完成任务不展示 `quality`、`received`；错误信息 `maxLines: 1` 且与状态同行。
- 依据：`task.quality`/`task.received` 在页面中无引用；错误文本使用 `TextOverflow.ellipsis`。
- 影响：用户无法判断下载的是 128 还是无损、占用了多少空间；长错误原因（含 URL/异常栈）被截断。

### DU-05（P2）queued 任务没有队列位置/等待提示，paused 且 total=0 时显示不确定进度动画

- 位置：`lib/features/download/presentation/download_page.dart:162-169`
- 现象：进度条只在 `running || paused` 显示；`queued` 仅文字“排队中”。`paused` 时若 `total == 0`，`LinearProgressIndicator(value: null)` 显示持续动画，看起来仍在下载。
- 依据：`progress` 在 `total <= 0` 时返回 null（`download_task.dart:120-124`）。
- 影响：用户无法知道前面还有几个任务、为何不动；暂停状态视觉上仍“活跃”。

### DU-06（P2）下载管理页重复转发生命周期，策略缓存被重置两次

- 位置：`lib/main.dart:201-205`；`lib/features/download/presentation/download_page.dart:33-39`
- 现象：App 根 State 与下载页 State 都监听 `didChangeAppLifecycleState` 并调用 `DownloadManager.onAppLifecycle`。
- 依据：两处调用同一方法；`onAppLifecycle` 只看 `paused → resumed`，两次调用都会把 `_strategyResolved=false`。
- 影响：从设置返回时策略被重置两次（本身幂等），但下载页关闭后根仍持续转发，语义上职责重复；若后续在 `onAppLifecycle` 加入恢复队列等副作用，会被执行两次。

### DU-07（P2）下载任务与歌词/MV 的权限提示时机不一致

- 位置：`lib/features/download/download_provider.dart:259-264`；`lib/features/download/presentation/download_sheet.dart:71-102`
- 现象：点下载时立即把任务加入列表并显示“排队中”，权限申请发生在首个 `_run` 内；若用户在系统弹窗拒绝，任务才变为 failed/appFallback，界面无预期提示。
- 依据：`resolveStrategy()` 在 `_run` 中首次调用；`add()` 不检查权限。
- 影响：用户点击后看不到“需要存储权限”的上下文说明，只看到任务失败；Android 9 首次下载体验尤其明显。

### DU-08（P2）下载页“打开”与音乐库点击行为不一致

- 位置：`lib/features/download/presentation/download_page.dart:288-300`；`lib/features/library/presentation/library_page.dart:218-232`
- 现象：下载页点已完成条目调用 `PublicMediaStore.open` 交给外部应用；音乐库点已下载条目则进入应用内播放器。下载页没有“在应用内播放”入口。
- 依据：两处 `onTap` 实现不同。
- 影响：用户从下载管理点歌曲会跳出应用（可能被浏览器/文件管理器接管），与“已下载歌曲”预期不符。

---

## D. 音乐库与最近播放

### LB-01（P2）最近播放只展示前 20 条，剩余记录无入口

- 位置：`lib/features/library/presentation/library_page.dart:127`
- 现象：存储上限 50 条（`recent_play_store.dart:46`），页面固定 `_recent.take(20)`，没有“查看全部”或分页。
- 依据：`for (final r in _recent.take(20))`。
- 影响：第 21~50 条最近播放永远不可见，也无法从 UI 删除单条，只能“清空全部”。

### LB-02（P2）已下载列表固定前 20 条，条目无单曲操作

- 位置：`lib/features/library/presentation/library_page.dart:158-188`
- 现象：`downloaded.take(20)`；条目只有点击播放与离线角标，没有删除、查看位置、查看详情等菜单。
- 依据：`SongTile` 未设置 `menuItems`；section action 与空态按钮都能跳“下载管理”，但列表本身没有单曲操作。
- 影响：下载超过 20 首后，其余歌曲在音乐库不可见（需进下载管理页）；误下载/文件失效只能去另一页逐条处理。

### LB-03（P2）最近播放写入后重复通知，页面每次播放读两遍 Hive 并 setState 两次

- 位置：`lib/features/library/data/recent_play_store.dart:83-92`；`lib/features/player/player_provider.dart:155-166`；`lib/features/library/presentation/library_page.dart:48-50`
- 现象：`_addInner` 结尾已调用 `notifyListeners()`，`recentPlayRecorderProvider` 又在 `.then` 中调用一次，同一写入触发两次 `changes` 事件。
- 依据：`add()` 的 Future 完成回调再次 `RecentPlayStore.notifyListeners()`；`_recentSub` 每次事件都 `_loadRecent()`（读 Hive + setState）。
- 影响：每次切歌音乐库多做一次全量 Hive 读取与重建；快速连播时放大 IO 与布局开销。

### LB-04（P2）最近播放串行队列吞掉所有写入异常，且错误不可观测

- 位置：`lib/features/library/data/recent_play_store.dart:72-81`
- 现象：`_serial = next.catchError((Object e) { return; });` 把错误转为正常完成；`add()` 返回的 `next` 若调用方不 await，异常也无处上报。注释称“保留错误可观测性”，实际被完全吞掉。
- 依据：`catchError` 回调直接 `return;`，无日志/上报；全工程调用 `RecentPlayStore.add` 的 `recentPlayRecorderProvider` 只 `.then`，无 `catchError`。
- 影响：Hive 写入失败（磁盘满、box 关闭）时最近播放静默丢失，用户与开发都无感知。

### LB-05（P2）`clear()` 在 box 未打开时静默返回，且不清理内存态

- 位置：`lib/features/library/data/recent_play_store.dart:95-100`
- 现象：`if (!Hive.isBoxOpen(_boxName)) return;`，不删除、不通知；调用方仍执行 `_loadRecent()`。
- 依据：`clear` 与 `read`（会懒打开）行为不一致。
- 影响：极端启动失败场景下，点“清空”后列表仍在（若内存有旧值），或下次启动旧记录复活。

### LB-06（P2）`_loadRecent` 无异常处理，Hive 打开失败会成为未捕获异步异常

- 位置：`lib/features/library/presentation/library_page.dart:60-64`、`40`
- 现象：`initState` 直接调用 `_loadRecent()`，内部 `await RecentPlayStore.read()` 可能抛 `StateError`/Hive 异常，无 try/catch。
- 依据：`read()` 会 `Hive.openBox`，失败时异常向上抛；`_loadRecent` 未捕获，`initState` 的 Future 无人处理。
- 影响：进入音乐库时若 box 异常，页面停留在空列表，异常进入全局 zone（仅记录日志），无重试入口。

### LB-07（P2）最近播放/已下载列表没有单条删除，清空是唯一清理方式

- 位置：`lib/features/library/presentation/library_page.dart:115-124`、`127-188`
- 现象：最近播放只有“清空”按钮；已下载没有删除入口。
- 依据：列表项 `SongTile` 未提供 `menuItems`；清空调用 `RecentPlayStore.clear()` 全删。
- 影响：用户想移除一条误播/误下载记录只能全清或去下载管理页，最近播放尤其无法局部整理。

### LB-08（P2）`downloaded.take(20)` 的顺序是下载创建顺序，不是最近完成/最近播放

- 位置：`lib/features/download/download_provider.dart:386-392`；`download_store.dart:34`
- 现象：`downloadedAudioProvider` 保持 `state.tasks` 顺序（新增插到队首）；恢复时按 `createdAt` 排序，而重复下载会把 createdAt 清零（DL-12）。
- 依据：`_replace` 新任务 `insert(0)`；`readAll` 按 createdAt 排序。
- 影响：冷启动前后“已下载”顺序跳变，用户最近下载的歌曲不一定在最前。

---

## E. 播放队列面板

### Q-01（P2）队列不支持删除单曲、清空、拖动排序

- 位置：`lib/features/player/presentation/queue_sheet.dart:1-129`
- 现象：每个条目只有 `onTap` 播放；没有 Dismissible、ReorderableListView、清空按钮或长按菜单。
- 依据：整文件仅 `ListView.builder` + `ListTile.onTap`。
- 影响：用户无法从队列移除不想要的歌曲或调整顺序，只能整体替换队列；播放队列作为基础功能缺失。

### Q-02（P2）用 hash 判断当前项，重复歌曲会同时高亮

- 位置：`lib/features/player/presentation/queue_sheet.dart:64`
- 现象：`final isCurrent = current?.hash == s.hash;`；队列中同一首歌出现两次时两项都 `selected` 并显示均衡器图标。
- 依据：`Song ==` 也只比较 hash（`player/data/models.dart:215-217`），但此处直接比较 hash 字段。
- 影响：用户无法判断实际播放的是哪一项；点击任一项都 `if (isCurrent) return`（`queue_sheet.dart:107`），重复项中非当前实例无法通过点击切过去。

### Q-03（P2）队列加载中显示“队列为空”

- 位置：`lib/features/player/presentation/queue_sheet.dart:34`、`54-58`
- 现象：`ref.watch(queueProvider).valueOrNull ?? const []`，首次打开时 stream 尚无值，直接进入空态分支。
- 依据：`valueOrNull` 对 loading 返回 null。
- 影响：打开队列瞬间闪现“队列为空”，随后才出现列表；弱设备上可见闪烁。

### Q-04（P2）点击队列项先关闭弹层再播放，失败无就地反馈

- 位置：`lib/features/player/presentation/queue_sheet.dart:105-109`
- 现象：`Navigator.pop()` 后 `await controller.playQueue(...)`；异常由播放器内部吞掉并走全局 Toast/错误态。
- 依据：`PlayerController.playQueue` 直接转发 `_handler.playQueue`，无返回值；`_playAt` 内部 catch 后仅发流。
- 影响：若目标歌曲无版权/解析失败，弹层已关闭，用户只看到短暂 Toast 或播放页错误，无法在队列中重试该条目。

---

## F. 与播放链路的交界（下载结果的实际可用性）

### PL-01（P1）本地文件失效时离线分支直接抛错并跳下一首，不回退在线解析

- 位置：`lib/features/player/data/audio_handler.dart:276-298`、`335-352`
- 现象：`localUsable` 对 `content://` 只做前缀判断，不验证条目是否还存在；`setAudioSource` 失败后进入通用 catch，只发错误并 `skipToNext()`，不会用同一首歌的在线地址重试。
- 依据：`local.startsWith('content://')` 被无条件视为可用；catch 分支没有 `resolveUrl` 回退；失败后 `canAdvance` 为真则跳歌。
- 影响：用户删除公共目录文件、换存储/迁移、MediaStore 条目失效后，音乐库仍显示已下载；点击播放会直接跳到下一首（或停止），且无法在线播放当前歌。

### PL-02（P2）离线播放不更新音质状态，全屏页残留上一首的在线音质标签

- 位置：`lib/features/player/data/audio_handler.dart:284-298`、`304-306`；`lib/features/player/presentation/full_player_page.dart:55-56`
- 现象：在线分支会 `_actualQualityController.add(result.quality)`，离线分支只设置 `_isPreview=false`，不写 `_actualQualityController`。
- 依据：`actualQualityProvider` 监听该 controller，UI 直接展示其值；离线分支无写入。
- 影响：先在线播放 320，再播放本地 128 的已下载歌曲，全屏页仍显示 320/无损标签；用户误判本地文件音质，且状态跨歌曲泄漏。

### PL-03（P2）离线播放丢失时长，歌词匹配以 0 秒发起

- 位置：`lib/features/library/presentation/library_page.dart:218-232`；`lib/features/player/presentation/full_player_page.dart:18-29`；`lib/features/lyric/data/lyric_repository.dart:20-27`
- 现象：`_playDownloaded` 未传 `duration`（`Song.duration` 默认 `Duration.zero`）；离线分支（`audio_handler.dart:284-298`）又不执行 `fetchDetail` 补全，因此 `currentLyricProvider` 用 `song.duration.inSeconds == 0` 去调 `/search/lyric`。
- 依据：`DownloadTask.durationSec` 已保存（`download_task.dart:70`），但 `_playDownloaded` 没使用；`currentLyricProvider` 直接把 `song.duration.inSeconds` 作为 `durationSec` 传给 `findCandidate`，后者无条件写入 query 的 `duration` 参数。
- 影响：所有离线播放的已下载歌曲都以 `duration=0` 请求歌词，服务端可能返回不匹配的候选或直接无结果；同时 `MediaItem.duration` 为空，播放页总时长依赖解码器后置回报。

### PL-04（P2）暂停/删除下载任务不会影响已进入播放队列的本地引用

- 位置：`lib/features/download/download_provider.dart:159-178`；`lib/features/player/data/audio_handler.dart:230-237`
- 现象：`playSong` 只把 `localPath` 合并进已有队列项，从不清理；删除下载任务后，队列中该歌曲仍保留 `localPath`。
- 依据：`remove` 不触碰 `audioHandler` 的 `_songs`；队列项是独立拷贝。
- 影响：删除下载后，从队列切回该歌仍尝试本地播放并失败（触发 PL-01），需要用户重启应用/重建队列才恢复在线播放。

---

## G. 其他一致性问题

### OT-01（P2）`DownloadState.completed`/`hasAudio` 等派生 getter 未被使用，状态语义分散

- 位置：`lib/features/download/download_provider.dart:20-38`、`200-214`、`386-392`
- 现象：`completed`、`active`、`hasAudio`、`audioTaskOf` 各自用不同条件判断完成/音频；`downloadedAudioProvider` 又单独过滤一次。
- 依据：`hasAudio` 要求 `type == audio && completed`；`downloadedAudioProvider` 先 `audios` 再 `completed`；页面/弹层各自再遍历 `state.tasks`。
- 影响：后续新增任务类型或状态（如“已失效”）时容易出现判定不一致；当前“已下载”徽标、弹层状态、音乐库列表来自三套遍历逻辑。

### OT-02（P2）下载相关错误文案硬编码中文，未走 l10n

- 位置：`lib/features/download/data/download_repository.dart:60`、`159`、`161`；`download_provider.dart:294`、`347`
- 现象：`'无可用播放地址'`、`'暂无歌词'`、`'歌词解析失败'`、`'缺少封面地址'`、`'下载失败'` 等直接写死；下载页其它文案均走 `context.l10n`。
- 依据：上述字符串未使用 `AppLocalizations`；错误最终显示在 `download_page.dart:157` 的副标题。
- 影响：非中文界面下下载错误仍为中文，与其他页面本地化程度不一致。

### OT-03（P2）下载任务没有磁盘空间预检，失败信息多为底层异常

- 位置：`lib/features/download/download_provider.dart:266-306`；`download_repository.dart:84-117`
- 现象：开始下载前不检查可用空间；Dio 写入失败（ENOSPC）走通用 catch，`friendlyError(e)` 可能回退为原始异常文本。
- 依据：全流程无 `statvfs`/磁盘配额检查；`DownloadRepository` 无空间相关处理。
- 影响：存储将满时用户要等下载到一半才失败，且失败原因可能是英文 `FileSystemException`；临时文件可能留下（DL-05）。

### OT-04（P2）音乐库不展示正在下载任务/进度，“已下载”为空时仍显示“暂无下载”

- 位置：`lib/features/library/presentation/library_page.dart:158-188`；`lib/core/router/app_router.dart`（/downloads 路由）
- 现象：音乐库“已下载”只列 completed；有任务在下载但尚无完成项时，`downloaded.isEmpty` 为真，区块显示 `EmptyState(noDownloads)`，只在按钮里提供“下载管理”入口。
- 依据：`downloadedAudioProvider` 只含 completed（`download_provider.dart:386-392`）；音乐库未 watch `DownloadState.active`，也没有进度徽标或全局下载按钮。
- 影响：用户发起下载后回到音乐库，看到“暂无下载”，会误以为任务未开始或已丢失；无法就地感知进度/失败。

---

## 说明

- 以上仅记录问题与依据，未给出修改方案，未改动任何源码。
- 未运行构建/测试；涉及 MediaStore 行为（PB-02/03/06/10）与系统调度（DL-19）的结论基于代码路径与 Android 平台约束，未在真机复验。
