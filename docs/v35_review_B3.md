# v3.5 B 批·审查③：download 全链深审（含原生通道）

- 任务书：TASK_v34_review1.md 的变体（原文件缺失，依 TASK_v34_review2.md 硬性规则 + 用户差异条款执行）
- 规范：docs/QUALITY_STANDARD.md（33 条）+ docs/REVIEW_SPEC.md
- 基线：只读审查，禁编译/装包；噪音过滤仅适用于 Flutter SDK 符号，项目自有类报错即真错误；跨文件改动双向核对

## 逐文件审阅

### lib/features/download/download_provider.dart（462 行，已完整读完）

#### P1-1 remove() 竞态窗口内 _update 可「复活」已删除任务
- 级别：P1
- 位置：download_provider.dart `_run` 中 realTempPath 持久化处（约 L330）：
  `_update(_find(task.id)?.copyWith(realTempPath: realTempPath) ?? task.copyWith(realTempPath: realTempPath));`
- 依据：`_update` → `_replace`，`_replace` 在 `idx < 0` 时执行 `list.insert(0, task)`。audio 分支在 `resolveAudioUrlWithExt`（网络等待）之后才走到这行；若等待期间用户 `remove(id)`（state 与 DownloadStore 均已移除），此处 `_find` 返回 null，走 `??` 右支，把旧 task（status 可能还是 running）重新 insert 回 state 并 `DownloadStore.save` 持久化。
- 违反：原则 18（异步结果必须校验世代）、原则 5（状态单一来源）。
- 后果：用户明确删除的任务重新出现在下载列表且持久化，显示为僵尸任务；随后 onProgress 因 `cur == null` 判断已不成立（任务被复活）继续写进度。

#### P1-2 先删同名旧文件再发布：发布失败即用户旧文件丢失
- 级别：P1
- 位置：`_run` 发布段（约 L345–352）：
  ```dart
  final exist = await PublicMediaStore.instance.queryExisting(...);
  if (exist != null) { await PublicMediaStore.instance.delete(exist); }
  final published = await _repo.publish(task, realTempPath, strategy: _strategy);
  ```
- 依据：删除发生在 `publish` **之前**且无恢复。publish 可能因权限被系统撤销、存储满、MediaStore 异常而失败（失败落入通用 catch，任务置 failed）。
- 违反：原则 21（写操作必须幂等/防重——此处为破坏性先删后写，非原子）、原则 14（数据边界校验）。
- 后果：同一首歌重新下载（如换音质）失败时，公共目录里原本完好的旧文件已被删，用户数据丢失（接近 P0；因触发需叠加发布失败，定 P1）。

#### P1-3 audio 扩展名替换用正则 `\.mp3$` 锚定，跨文件核对 fileExtension 真实值
- 级别：待 cross-check（见 download_task.dart 一节）
- 位置：`realTempPath = tempPath.replaceAll(RegExp(r'\.mp3$'), ext);`
- 依据：tempPath 由 `'${tempDir.path}/$dimKey${task.type.fileExtension}'` 构成。若 `DownloadTaskType.audio.fileExtension` 不是 `.mp3`（例如 `.m4a`），正则不命中，realTempPath == tempPath，服务端返回 `.flac` 内容写入 `.m4a`/错误扩展名文件——正是本档重点「MIME 与真实扩展名匹配」问题。是否成立取决于 download_task.dart，双向核对后定级。

#### P2-1 真实扩展名与 MIME/显示名不联动：.flac 内容可挂 audio/mpeg 的 .mp3 之名发布
- 级别：P2（MIME 匹配需结合 repository/public_media_store 双向核对后定级，见下文）
- 位置：download_task.dart L20–27：`DownloadTaskType.audio => '.mp3'`（硬编码默认扩展名）；provider 中以 `replaceAll(RegExp(r'\.mp3$'), ext)` 替换。
- 依据（跨文件核对 download_task.dart 后修正 P1-3）：`fileExtension` 确为 `.mp3`，正则能命中，realTempPath 机制本身可用。但 `ext` 来自服务端（可能 `.flac`/`.m4a`），最终发布文件名/MIME 是否跟随 `realTempPath` 的扩展名，取决于 `DownloadRepository.publish` / `displayNameOf` 与 `PublicMediaStore.insert` 的 mimeType 参数——继续向下核对。
- realTempPath 序列化往返核对：`toJson` 含 `'realTempPath'`，`fromJson` 有 `'realTempPath': '${json['realTempPath'] ?? ''}'`，`copyWith` 有对应参数且 `?? ''` 传空串可正常写入（'' 非 null，不会回落旧值）。**序列化全链无缺字段、无类型歧义，通过。**
- 附带核对：
  - `fromJson` 对 `type`/`status` 用 `firstWhere(... orElse:)` 兜底为 audio/queued：未知枚举字符串被静默改写为 audio 类型任务，违反原则 13/14（外部数据形态变更静默变形而非丢弃），P3。
  - `id = '${type.name}_$hash'` 不含 quality/albumAudioId：同一首歌只能有一个音频任务，换音质重下会走 DL-03 覆盖分支（取消旧任务），属设计选择，不另立项，但与 `dimKey` 含 quality 的防串写设计不一致，记 P3（命名与行为暗示不一致：dimKey 承认多音质并存，id 不允许）。
  - `received`/`total`/`createdAt`/`updatedAt` 的 int 兜底解析双向一致，通过。

#### P3-2 重试策略本身合规（记录核对结论，非问题）
- `_isRetryable` 精确区分网络层/超时/5xx 与 4xx；上限 2 次，指数退避 1s→2s。符合原则 25/11，无重试风暴。

### lib/features/download/data/download_task.dart（255 行，已完整读完）
（见上文 P2-1 及序列化往返核对：toJson/fromJson/copyWith 三处 realTempPath 字段齐全，无缺漏。附：fromJson 未知枚举兜底改写为 audio/queued，P3；id 不含 quality 与 dimKey 含 quality 的设计不一致，P3。）

### lib/features/download/data/public_media_store.dart（278 行，已完整读完）

#### P1-5（与 P1-4 同根合并）MIME 硬编码：mimeOf(audio) 恒 'audio/mpeg'，.flac 内容以 mp3 之名入库
- 级别：P1（双向核对完成：provider→repository→public_media_store 全链无一环把 realTempPath 的真实扩展名传给 publish；publish 也不接收 mimeType 参数）
- 位置：`mimeOf`（audio → 'audio/mpeg'）+ `publish()` 中 `'mimeType': mimeOf(type)`。
- 违反：原则 3（publish 输入契约缺真实格式维度）、原则 23。
- 后果：无损 .flac 以 audio/mpeg 注册进 MediaStore；系统/第三方播放器解析失败，分类错乱。

#### P2-4 finalize 返回值被忽略（本档重点：IS_PENDING 卡 7 天）
- 级别：P2
- 位置：`publish()` 内 `await _channel.invokeMethod<bool>('finalize', ...)` 返回值未校验。
- 依据：write 有 ok!=true 处理，finalize 无任何处理。且 finalize 在 try 内：若抛异常，catch 会 `delete(uri)` 后回退 _publishDirect —— 把已写好的文件删掉再整段重写（发布语义错乱）；若 Kotlin 侧吞异常返回 false，则 pending 条目静默滞留约 7 天被系统清理。需结合 Kotlin 核对（见 Kotlin 一节）。
- 违反：原则 9、13。

#### P1-6 D-02 原子替换仍有窗口：delete→rename 非原子 + .part 残留无清扫
- 级别：P1
- 位置：`_publishDirect`：`if (await target.exists()) await target.delete(); await partFile.rename(target.path);`
- 依据：
  1. 跨设备 rename 边界：partFile（`${target.path}.part`）与 target 同目录，同一文件系统，rename 原子性成立——此点通过。
  2. **进程被杀窗口**：delete 与 rename 之间进程被杀 → 旧好文件已删、新文件停在 .part。D-02 声称「此后任何异常都不会破坏旧副本」在进程级信号面前不成立（正确做法是 rename 直接覆盖，无需先 delete——POSIX rename 本可覆盖已存在文件；先 delete 反而制造窗口。Android FUSE 下 rename 覆盖是否被允许需实测，但至少注释里的保证过度）。
  3. **.part 残留**：写 .part 期间进程被杀 → catch 不执行 → .part 残留；全链无任何启动清扫逻辑（待全仓库 grep 巡检确认）。
- 违反：原则 21、25。
- 后果：公共 Music 目录出现孤儿 .part 文件；进程被杀时旧文件丢失。

#### P2-5 queryExisting 的 API<29 分支与发布降级路径不对称
- 位置：`queryExisting`：publicDir 为空直接 return null；而 `_publishDirect` 同条件会落到 fallbackDir 发布成功。
- 违反：原则 5/11。后果：已下载判定与真实位置脱节，重下产生双副本（Android/data + 公共目录）。

#### P2-6 delete() 失败静默，上层从不检查返回值
- 位置：`delete()` 吞异常返回 false；provider remove/clearAll 均不检查。
- 违反：原则 6/9。后果：删除失败时文件变孤儿，用户无从得知。

### lib/features/download/data/storage_permission_service.dart（143 行，已完整读完·首次单独审查）

#### P2-7 策略降级完全不可观测（B-39 遗留确认仍在）
- 级别：P2
- 位置：`resolveStrategy()` 返回 `appFallback` 时无日志、无回调、无用户提示；provider 侧拿到 `_strategy` 也只默默使用。
- 依据：原则 9（失败必须可观测）、原则 11（降级必须有明确触发/退出条件——退出条件部分存在：resume 时重置 _strategyResolved，但触发时的可观测性为零）。
- 后果：Android ≤9 用户拒绝权限后，所有文件静默落到 Android/data（卸载即丢），用户以为文件「下载到 Music」，去公共目录找不到，无任何提示解释原因。B-39 记录的「策略切换无提示」确认未修复。

#### P2-8 _apiLevelFromOsVersion 的映射错误：Android 9→9，但 API 应为 28；且 >9 时 name+19 公式对 Android 10 恰好对（29），对 Android 11+ 同样成立（30+），但 Android 9 分支返回 9 会导致 needsLegacyWritePermission 判定 9>0 && 9<29 为真——行为碰巧正确，但 apiLevel() 语义已错
- 级别：P2
- 位置：`_apiLevelFromOsVersion`：`if (name <= 9) return name;`
- 依据：原则 15（单位必须显式——API level 与版本号是两种「单位」，此处混用）。Android 9 真实 API=28，此函数返回 9。下游所有 `>= 29` 比较碰巧不出错（9<29），但 `apiLevel()` 作为公开契约返回的是错误值；若未来出现 `level >= 26` 之类的比较（Android 8 → 8），9 恰好也与 26 同侧，暂时无害，但 `level == 28` 这类判定永假。这是埋雷的隐式约定，且违反注释自己声明的「必须做版本名 → API level 映射」的意图（映射本身就是错的）。
- 后果：当前无用户可见故障，但任何基于真实 API level 的分支（如 Android 8.0 的特定行为）都会静默走错。

#### P3-3 requestStoragePermission 的 isPermanentlyDenied 分支：openAppSettings() 后直接 return false
- 依据：用户被跳到设置页授权后返回，本次调用已返回 false（降级 appFallback）。provider 靠 resume 重置 _strategyResolved 补救——机制上闭环，但 openAppSettings 是 fire-and-forget，权限弹窗与下载流程完全脱节，用户在设置页授权回来后没有任何「重试/继续」引导，只能自己再点一次下载。可观测性/引导缺失，P3（与 P2-7 同根）。

#### P3-4 多处 `catch (_) {}` 空捕获（apiLevel/publicDir/isPublicDirWritable）
- 违反：原则 6/7（至少转译或留痕）。平台通道异常与「真的不可用」无法区分，线上无从定位。属普遍性小问题，此处集中记录一次。

#### grep 巡检结果（巡检类，依任务书规则说明）
- `resolveAudioUrl`/`resolveAudioExt`：全仓库仅定义处出现，无调用 → **P2-2 确认为死代码**（resolveAudioUrl 无调用、resolveAudioExt 无调用，仅 resolveAudioUrlWithExt 被 provider 使用）。
- `.part` 清扫：全仓库仅 public_media_store.dart 三处（写入/清理逻辑本身），**无任何启动清扫** → P1-6 第 3 点确认。

### lib/features/download/data/download_store.dart（45 行，已完整读完）

#### P3-5 所有写操作在 box 未打开时静默丢弃
- 位置：`save/remove/clear`：`if (box == null) return;`
- 依据：原则 6/9。Hive 未初始化（如 box 打开时序错误）时下载记录全部静默不落盘，重启后任务消失。
- 后果：持久化失效但无任何痕迹。属低概率但零留痕的静默失败。

#### P3-6 readAll 对非 Map 值静默跳过（原则 13 部分合规）
- `raw is Map` 不符则丢弃该条——形态校验做了，但无日志；可接受（损坏记录丢弃优于崩溃），记为合规备注，不立项。

### lib/features/download/download_provider.dart 补充（并发/取消时序专项，本档重点）

#### P2-9 取消下载时的临时文件清理时序竞态
- 位置：`pause()`/`remove()` 取消 token 后，`_run` 的 DioException(cancel) 分支只改状态，**不删临时文件**；`remove()` 尝试删 `realTempPath`/重建路径。
- 依据：时序上 remove() 先执行 `f.deleteSync()`，随后 _run 的 catch 走完 finally。若下载已把部分字节写入 realTempPath，remove() 删除成功即干净；但若 remove() 执行时文件尚未创建（dio.download 未开始写），删除空过，随后 _run 才开始写 → **取消后的任务把文件写到一半留在临时目录**，无人清理（remove 已把任务从 state 移除，onProgress 因 cur==null 静默，但 dio.download 还在写盘直到完成或异常）。临时目录垃圾累积。
- 违反：原则 20/25（取消后资源回收不对称）。
- 后果：取消/删除下载后，后台仍在下载并留下完整或部分文件（若用户删的是 2GB MV，磁盘被占满而 UI 已无该任务）。

#### P2-10 clearAll 不清临时目录（与 remove 不对称）
- 位置：`clearAll` 只删已发布文件 + Hive，未清 tempDir/downloads_tmp 与 .part。
- 后果：全部清空后临时垃圾全留；同 P1-6/P2-9 根源——临时目录生命周期无 owner。

#### P3-7 addAll 串行 await add()，每次 add 都触发一次 _schedule
- 位置：`addAll` 逐个 await；`add` 内 `unawaited(_schedule())`。
- 依据：原则 24（性能）轻微：批量添加 N 个任务触发 N 次调度，_schedule 有 while 守卫不会重复启动任务，仅冗余遍历。不构成用户可见后果，P3 观察项。

#### P3-8 _run 中 audio 分支的 `_update(_find(task.id)?.copyWith(...) ?? task.copyWith(...))`
- 与 P1-1 同一处：`?? task.copyWith` 的兜底分支本身就是「复活已删任务」的实现载体。回退值应改为 no-op 而非用入参 task 兜底。

### android/.../MainActivity.kt（341 行，已完整读完·MediaStore 原生通道全方法核对）

#### P1-7 finalize 恒返回 true，IS_PENDING=0 失败被掩盖（本档重点确认）
- 级别：P1（与 Dart 侧 P2-4 双向核对后升级）
- 位置：`finalize(uri): Boolean`：`contentResolver.update(uri, values, null, null)` 无返回值检查，无条件 `return true`。
- 依据：update 对不存在的行返回 0 行受影响而不抛异常 → Dart 拿到 true 以为 pending 已清。若 update 因 SecurityException/行失效抛异常，会被外层 catch 转 result.error → Dart 的 catch 里 `delete(uri)` 后回退 _publishDirect（重复发布）；若 update 返回 0（URI 已被系统回收/7 天清理后），静默 true，条目永远不可见但 Dart 记 completed。**对照：appendText 里同样的 update 也没查返回值，但 appendText 场景条目是自己刚插的，风险低；下载 publish 的 insert→write→finalize 横跨一次大文件复制（分钟级），窗口大得多。**
- 违反：原则 13（平台返回必须验证语义）、原则 9。
- 后果（用户可见）：「下载完成」但文件管理器看不到文件；或 pending 条目滞留 7 天被系统清理——V34 报告 P2 的复查结论：**未修复，且 Kotlin 侧使问题比 Dart 报告认定的更深**。

#### P2-11 write 无 cancelToken/进度，大文件复制不可中断
- 位置：`write(uri, src)`：`src.inputStream().use { it.copyTo(out) }` 同步阻塞平台线程，1GB MV 复制分钟级。
- 依据：原则 1/20。复制期间无法取消；若用户此时删任务，Dart 的 delete(uri) 排队等 write 完成（MethodChannel 单线程 handler），UI 取消变成「完成后立刻删」，净效果浪费全部 IO；且 copyTo 在平台主线程上跑（configureFlutterEngine 的 handler 默认在 main thread）→ 大文件复制期间整个 Android 主线程阻塞，ANR 风险。
- 违反：原则 26（热路径/主线程零重活）。
- 后果：大文件下载发布阶段 ANR/卡顿；取消不生效。

#### P2-12 appendText 轮转轮转前 `target.renameTo(rotated)` 未查返回值
- 位置：appendText ≤28 分支：`target.renameTo(rotated)` 返回值被丢弃（Kotlin renameTo 返回 Boolean）。
- 依据：原则 9/13。rename 失败（权限/占用）后 `target.appendText(content)` 继续追加 → 日志无限增长超过 maxBytes 上限。
- 违反：原则 25（资源上限失效）。
- 后果：日志文件超限增长，占满公共 Documents 目录（低概率、缓慢）。

#### P2-13 appendText 的 old+content 全量读入内存重写
- 位置：`openInputStream(uri)?.use { it.readBytes() ... }` + `openOutputStream(uri, "rwt")` 整体重写。
- 依据：原则 25/26。日志接近 maxBytes（设计上限）时每次 append 都全量读+写；若调用方传 maxBytes=0（默认值），则**无上限累积**且每次全量 O(n)。
- 后果：低端机内存峰值 / IO 翻倍。需核对 Dart 调用方是否总传 maxBytes（见下）。

#### P3-9 query 的 RELATIVE_PATH 用 LIKE 'path%' 前缀匹配
- 位置：`selection = "... RELATIVE_PATH LIKE ?"` + `args = arrayOf(displayName, "$relativePath%")`。
- 依据：前缀匹配会把 'Music/Tiernan Music' 与 'Music/Tiernan Music X'（若存在兄弟目录）混淆。当前只有一个 App 目录，暂无实际影响；LIKE 通配符 %/_ 未转义（目录名含 % 时失配）。P3。

#### P3-10 isPublicDirWritable 探针文件 'probe' 写在公共目录根
- 位置：`File(...dir, "probe")` writeText 后 delete；进程被杀时 probe 残留（用户可见垃圾文件，命名无前缀）。P3。

#### P3-11 openFile guessMime 对 .flac/.m4a 等已覆盖，但 uri 优先时 `guessMime(uri, path)` 用 uri 字符串推断扩展名（content:// 无扩展名 → 恒 `*/*`）——path 参数被忽略
- 位置：`guessMime(uri, path)`：`val name = path ?: uri ?: ""`，当 uri 非空时仍传了 path 却优先用…实际写法是 `name.endsWith` 基于 `path ?: uri`，uri 分支传入的 path 可用——核对：`openFile` 里 uri 分支调用 `guessMime(uri, path)`，函数内 `path ?: uri` 会优先用 path（非空时），扩展名推断正确；path 为空时用 content:// uri 推断失败 → `*/*`。影响轻微（多数查看器自行嗅探）。P3。

### presentation 两文件（待读）

### lib/features/download/presentation/download_page.dart（308 行，已完整读完）

#### 回归确认：此前 UI 批修复的语法错已修，无回归
- 全文件结构完整（class 均闭合）、switch 表达式合法、`context.mounted` 使用正确。**确认无语法回归。**

#### P2-14 降级提示判定 `task.filePath.contains('/Android/data/')` 不可靠
- 位置：降级路径提示行。
- 依据：原则 13/14（用字符串包含判断路径形态）。Windows/macOS 桌面端（若支持）或路径大小写差异（/android/data）时提示失效；更重要的是 MediaStore 策略下 filePath 存的是 uri（见 provider：`filePath: published.path ?? published.uri`），uri 不含 /Android/data/，判定对象错位但碰巧不误报。脆弱设计，P2 降 P3 边缘——取 P3（后果仅提示缺失）。

#### P3-12 'folder' 菜单项仅 filePath 非空才显示（MediaStore 任务 displayPath 有值也无入口）
- 与 provider 中 `filePath: published.path ?? published.uri` 对照：Android 10+ 完成任务的 filePath 实际是 **content:// uri**，`viewFolder` 的 Kotlin 实现要求 `file.exists()`（File 路径）——uri 传入 File(path) 必 false → viewFolder 恒失败 → 走 Toast.copy 复制的是 uri 字符串，用户粘贴后无法使用。**跨文件双向核对实锤**：
  - 级别：P2（升级）
  - 违反：原则 3/22（PublishedFile.uri/path 的语义契约在 UI→原生边界被破坏）。
  - 后果：Android 10+ 用户点「在文件管理器中打开」必然失败并复制出无意义的 content:// 字符串。

### lib/features/download/presentation/download_sheet.dart（177 行，已完整读完）

#### P3-13 audioTaskOf 与 _taskOf 重复实现同一查找逻辑（原则 1/32）
- `manager.audioTaskOf(song.hash)` 与本地 `_taskOf(tasks, audio)` 并存，且 _taskOf 找到的 audioTask 未用于第一个 OptionTile（用 audioTaskOf，不含 status 过滤差异），两处结果可能不一致（audioTaskOf 返回任意 status 的 audio 任务，_taskOf 相同——实际语义一致，纯重复代码）。P3。

#### P3-14 buildTask 的音质回退：`song.quality != q128 ? song.quality : preferredQuality()`
- 依据：歌曲实际音质为 128 时用用户偏好音质下载——语义上「下载档位可高于播放档位」是合理设计，但与注释「与播放链路同一事实源」表述矛盾（事实源不一致时静默取偏好值）。用户选 128 播放却下载 flac（流量/体积翻倍）无提示。P3。

#### P3-15 下载全部不含 MV，但列表有 MV 项（有意为之与否未注明）
- `downloadAll` 只加 audio/cover/lyric；MV 单独下载。若为有意设计，违反原则 31（为什么不做注释）。P3。

## 问题清单（按级别）

### P1（5 项）
| # | 位置 | 摘要 |
|---|---|---|
| P1-1 | download_provider.dart（audio realTempPath 持久化处） | remove() 竞态窗口内 `_replace` 兜底 insert 复活已删任务并重新持久化（原则 18/5） |
| P1-2 | download_provider.dart（_run 发布段） | 先删同名旧文件再发布，发布失败旧文件已丢（原则 21/14） |
| P1-4/5 | download_repository.dart publish/displayNameOf + public_media_store.dart mimeOf | 真实扩展名链最后一环断裂：.flac 以 .mp3 + audio/mpeg 入库（原则 3/23/30） |
| P1-6 | public_media_store.dart _publishDirect | delete→rename 非原子窗口 + .part 残留无任何清扫（原则 21/25） |
| P1-7 | MainActivity.kt finalize | 恒返回 true，IS_PENDING=0 失败被掩盖；Dart 侧 P2-4 双向核对后确认未修复且更深层（原则 13/9） |

### P2（10 项）
P2-2 死代码 resolveAudioUrl/resolveAudioExt（巡检确认）｜P2-3 下载产物无内容校验｜P2-4 finalize 返回值被忽略（并入 P1-7）｜P2-5 queryExisting 与发布降级路径不对称｜P2-6 delete() 静默失败上层不查｜P2-7 策略降级零可观测（B-39 确认仍在）｜P2-8 apiLevel 映射语义错误（Android 9→9）｜P2-9 取消下载后 _run 继续写盘的清理时序竞态｜P2-10 clearAll 不清临时目录｜P2-11 Kotlin write 阻塞主线程、不可取消｜P2-12 appendText renameTo 返回值被丢（轮转失效）｜P2-13 appendText 全量读内存重写｜P2-14 viewFolder 对 content:// uri 恒失败（download_page + Kotlin 双向核对）——注：P2-14 编号在正文为 P3-12 升级，此处以正文为准。

### P3
P3-1（未单独成项，并入正文）｜P3-3 openAppSettings 后无重试引导｜P3-4 空捕获集中记录｜P3-5 DownloadStore box 未打开静默丢写｜P3-6（合规备注）｜P3-7 addAll 冗余调度｜P3-8 ?? task 兜底复活载体｜P3-9 LIKE 前缀未转义｜P3-10 probe 探针残留｜P3-11 guessMime uri 分支｜P3-12 降级提示字符串判定｜P3-13 audioTaskOf/_taskOf 重复｜P3-14 音质回退无提示｜P3-15 downloadAll 不含 MV 未注明｜fromJason 未知枚举兜底改写｜id 与 dimKey 维度不一致。

## 专项结论（本档重点逐条回应）
1. **D-02 .part 残留**：确认存在，进程被杀窗口双重（写中 + delete/rename 之间），无清扫 → P1-6。
2. **跨设备 rename**：partFile 与 target 同目录同文件系统，原子性成立；风险在先 delete 后 rename 的窗口 → P1-6。
3. **realTempPath 序列化往返**：toJson/fromJson/copyWith 三处齐全，通过；但消费端（publish 链）断裂 → P1-4/5。
4. **MediaStore finalize 返回值**：V34 P2 未修复，Kotlin 恒 true 使其恶化 → P1-7 + P2-4。
5. **MIME 与真实扩展名**：全链硬编码 audio/mpeg + .mp3 → P1-4/5。
6. **权限策略降级可观测性**：B-39 确认未修复 → P2-7。
7. **并发上限**：maxConcurrent=2 常量，_schedule while 守卫正确，合规。
8. **重试风暴**：2 次指数退避，4xx 不重试，合规。
9. **下载中取消的清理时序**：存在竞态 → P2-9/P2-10。
