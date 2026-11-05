# 第6批·审查③：数据仓库与下载/音乐库（v3.0 终审 C 视角·变体 B2）

- 仓库：`/var/minis/workspace/TiernanMusic`，基线 commit `8c6a084`
- 判定依据：`docs/QUALITY_STANDARD.md`（32 条）+ `docs/REVIEW_SPEC.md` 既定口径 + `docs/api_verified.md` 实测记录
- 审查方式：全部源码 `file_read` 首行→末行完整阅读；未 grep、未编译、未跑测试、未改动代码
- 独立审查声明：未阅读 `docs/batch1~4_*`、`docs/check_*`、`docs/v3_review_b1_*` 及同批其它报告

## 范围核对（先 ls 确认文件名）

| 任务书路径 | 实际情况 |
|---|---|
| `download/data/download_repository.dart` | 存在（302 行） |
| `download/presentation/download_page.dart` | 存在（302 行） |
| `download/presentation/download_sheet.dart` | 存在（177 行） |
| `library/presentation/library_page.dart` | 存在（653 行） |
| `auth/data/auth_repository.dart` | 存在（390 行） |
| `auth/data/verification_service.dart` | 存在（97 行） |
| `auth/presentation/login_page.dart` | 存在（731 行） |
| `auth/presentation/captcha_page.dart` | 存在（439 行） |
| `comment/data/comment_repository.dart` | 存在（264 行） |
| `comment/presentation/comments_page.dart` | 存在（656 行） |
| `comment/presentation/comment_floor_page.dart` | 存在（310 行） |
| `rank/data/rank_repository.dart` | 存在（129 行） |
| `mv/data/mv_repository.dart` | 存在（304 行） |
| `mv/presentation/mv_page.dart` | **不存在**；实际为 `mv/presentation/mv_player_page.dart`（386 行），按此审查 |

上下文补读（为验证第 27/28/29 条所需的最小事实源，非本批报告文件）：
`download/download_provider.dart`、`download/data/download_task.dart`、`download/data/download_store.dart`、
`download/data/public_media_store.dart`、`download/data/storage_permission_service.dart`、
`auth/data/auth_providers.dart`、`auth/data/account_manager.dart`、`core/providers.dart`、
`core/api/kugou_api_client.dart`、`core/direct/kg_direct_api_client.dart`。

---

# 一、下载域

### download_provider.dart:327 进度回调中整表复制 + 每次进度写盘
- 级别：P2
- 事实：`onProgress` 每收到一次进度就 `_update(cur.copyWith(...))`；`_update` → `_replace` 把 `[...state.tasks]` 整表复制并 `state = ...`，再 `unawaited(DownloadStore.save(task))` 逐条落 Hive。Dio 的 `onReceiveProgress` 在局域网/5G 下每秒可触发数十次，即每秒数十次 O(n) 列表复制 + 数十次 Hive 写盘（每次含整个任务 JSON 序列化），且没有任何节流/合并。
- 违反：第 25 条（资源必须有上限：此处写盘频率无上限、无节流）、第 26 条（热路径分配：进度回调每帧级路径上整表复制）
- 后果：下载多任务时界面明显掉帧；低端机下载期间整机卡顿、耗电与闪存写入放大（TLC 寿命）；任务数越多越卡（O(n) 随任务数线性放大）。

### download_provider.dart:399 临时文件名只由 hash+type 决定，新旧任务共用同一路径
- 级别：P1
- 事实：`_run` 里 `tempPath = '${tempDir.path}/${task.hash}_${task.type.name}${task.type.fileExtension}'`，`DownloadTask.id` 也是 `'${type.name}_$hash'`（`download_task.dart:96`），**都不包含音质（quality）、albumAudioId、targetLanguage**。`add()` 对同 id 已存在的任务只是 `_tokens[id]?.cancel('re-added')` 后立刻 `_replace` + `_schedule()`——旧 `_run` 可能正处在 `await _repo.publish(...)` 或 `downloadFile` 的写文件阶段，取消只对 Dio 请求生效，文件流/发布阶段不会被中断；此时新任务已经用**同一个** tempPath 开始写入。
- 违反：第 21 条（写操作幂等/防重：同一目标被两次写）、第 23 条（标识键必须覆盖全部影响结果的维度：音质缺失）、第 18 条（异步结果未校验世代：旧 `_run` 的 publish 结果仍会落到新任务条目上，仅靠 token 比对兜底，publish 阶段前无校验）
- 后果：① 同一首歌先下 128k、再下 320k 时，两个流同时写同一个临时文件 → 文件被交错写坏，最终保存出一个「时长正确但中途爆音/截断」的音频；② 已完成的 128k 任务被新任务覆盖为 completed，但文件内容取决于竞争结果；③ 用户看到「下载成功」却播放失败。

### download_provider.dart:378 / download_repository.dart:200 无断点续传，却对外宣称「暂停保留进度」
- 级别：P2
- 事实：`pause()` 的注释写「取消网络请求，保留已下载进度信息」，`resume()` 只是把状态改回 queued；`_run` 一开始就 `received: 0, total: 0`，`downloadFile` 调用 `_dio.download(url, savePath, ...)` 既不带 `Range` 头，也没有 `options.headers['Range']` 或 `FileMode.append`，Dio 默认 `deleteOnError: true` 会删掉半成品。重试（`retries=2`）同样是从 0 重新下载整个文件。
- 违反：第 21 条（断点续传的幂等性：重试/恢复语义与状态不一致）、第 5 条（同一事实两处来源：`received/total` 声称的进度 vs 实际文件内容）、第 15 条（进度语义未显式定义：是「已落盘字节」还是「本次会话已收字节」）
- 后果：用户在大文件（无损/MV）下到 90% 点暂停或网络抖动自动重试，回来进度条从 0 重来，流量成倍消耗；弱网用户永远下不完一首 FLAC。持久化的 `received` 在重启后仍显示旧百分比，点继续瞬间跳回 0，视觉上像「进度丢失」。

### download_provider.dart:391 `_strategy` 全局共享，与具体任务写入路径无绑定
- 级别：P2
- 事实：`_strategy` 是 manager 级单值，`onAppLifecycle` 在 `resumed` 时把 `_strategyResolved` 置 false，**下一次** `_run` 重新 resolve；而 `_strategyResolved` 只在 `!_strategyResolved` 时才置 true，也就是说两次下载之间用户改了权限，前一次已开始的任务仍用旧策略，后一次用新策略，`remove()`/`clearAll()` 删除文件时按任务里存的 `mediaUri`/`filePath` 判断，二者混存（MediaStore uri 与绝对路径）没有问题，但**策略切换本身没有日志、没有提示**：同一批「下载全部」的三个子任务可能一个进 MediaStore、两个进 Android/data。
- 违反：第 11 条（降级必须有触发/退出条件，且必须可观测：何时降级、为何降级无记录）、第 9 条（静默降级必须留痕）
- 后果：用户点「全部下载」后，歌曲在「音乐」App 可见，封面/歌词却在 `Android/data` 里且文件管理器看不到，用户以为下载丢了；不同机型上表现不一致，客服无法复现。

### download_provider.dart:145 remove() / :405 完成清理 空捕获
- 级别：P2
- 事实：`remove()` 里 `try { ... f.deleteSync(); } catch (_) {}`，注释写「删除失败静默」；`_run` 完成分支同样 `try { f.deleteSync(); } catch (_) {}`；`public_media_store.dart:251` `delete()` 整体 `catch (_) {}` 返回 false（调用方 `remove()` 不检查返回值）、`queryExisting` 的 `catch (_) {}`、`open/viewFolder` 的 `catch (_) { return false; }`。
- 违反：第 6 条（禁止吞掉异常：既未转译、未记录、也无明确降级语义）、第 7 条（`catch (_)` 捕获一切对象）
- 后果：临时文件删不掉时无人知晓，`downloads_tmp` 目录在 SD 卡/内部存储里持续膨胀（用户清理缓存也清不到，因为该目录属 App 私有）；删除已发布文件失败时任务已从列表消失，MediaStore 里留下孤儿条目，用户「删了还在」。

### download_provider.dart:432 downloadRepositoryProvider 内部 new MvRepository
- 级别：P3
- 事实：`MvRepository(ref.watch(kugouApiClientProvider))` 在 provider 体内构造协作者；`DownloadRepository` 构造函数额外接受 `MvRepository?`，但这里是唯一装配点，未复用 MV 域自己的 provider（若存在）。`DownloadRepository` 构造函数还 `dio ?? Dio(BaseOptions(...))` 自行构造 Dio。
- 违反：第 2 条（依赖必须由注入传入，不得内部自行构造；魔法超时值应具名）
- 后果：下载 MV 用的 client 与 MV 页面用的 client 不是同一实例（cookie/userid 靠静态共享 jar 兜底），一旦共享 jar 路径变化就串号；单元测试无法替换 Dio。

### download_repository.dart:120 resolveAudioExt() 与 :63 resolveAudioUrl() 已被 :134 取代
- 级别：P3
- 事实：`resolveAudioExt`、`resolveAudioUrl` 两份实现与 `resolveAudioUrlWithExt`（V3-11 引入）是同一段逻辑的三份拷贝；`_run` 只调用 `resolveAudioUrlWithExt`。`resolveAudioExt` 在 `api == null` 时还静默返回 `'.mp3'`（不抛错），与 `resolveAudioUrl` 的 `throw StateError` 语义相反。
- 违反：第 32 条（死代码零容忍）、第 1 条（同一职责三处实现）、第 8 条（回退路径与主路径的异常形态不一致）
- 后果：任何后续调用者（新增下载入口/测试）若用 `resolveAudioExt`，在播放接口未初始化时会得到 `.mp3` 的假成功，把一个直接路径的 FLAC 存成 mp3 后缀——播放器按后缀解码失败。

### download_repository.dart:243 downloadFile 重试只覆盖 DioException，且退避无上限说明
- 级别：P3
- 事实：`on DioException catch (e)`，`_isRetryable` 按 type/status 判断，退避 `1 << (attempt-1)` 秒；`retries` 是调用参数（`_run` 不传，默认 2）。但 `downloadFile` 没有校验 `savePath` 所在分区剩余空间，也没有 `total` 与磁盘可用空间比较。
- 违反：第 25 条（资源必须有上限/前置校验）、第 3 条（契约未写明：磁盘不足属何种异常）
- 后果：存储将满时先写满分区再抛 `FileSystemException`，被 `_run` 通用 `catch (e)` 记为「下载失败」；临时文件占满后连歌词/封面都下不了，需手动清缓存。用户看到的是「下载失败」而非「存储空间不足」。

### download_task.dart:96 任务 id 与 hasAudio 判定忽略音质
- 级别：P2
- 事实：`String get id => '${type.name}_$hash';`；`download_provider.dart:214` `hasAudio(hash)` 只看 hash+type+completed。`DownloadSheet` 的音质取自 `song.quality`/`preferredQuality()`（`download_sheet.dart:43`），与 id 无关。
- 违反：第 23 条（缓存/标识键缺维度）、第 16 条（「已下载」与「已下载该音质」语义未分离）
- 后果：用户在设置里把默认音质改成 FLAC，打开某首已下 128k 的歌，弹层直接显示「已下载 ✅」，无法再下无损；或反之，改了音质后重复下载覆盖旧文件，用户以为两版都在。

### public_media_store.dart:120 MIME 固定，与真实扩展名不符
- 级别：P2
- 事实：`mimeOf` 对 audio 恒返回 `'audio/mpeg'`，mv 恒 `'video/mp4'`，cover 恒 `'image/jpeg'`；而 `download_repository.dart` 已按服务端 `extName`/URL 解析出 `.flac/.m4a/.ogg`（`resolveAudioUrlWithExt`），`_run` 用 `realTempPath` 写入、`displayNameOf` 用 `task.type.fileExtension`（恒 `.mp3`）——即**扩展名与 MIME 都在撒谎**，且与实际容器格式可能三者不一致。
- 违反：第 23 条（同一文件的描述维度不一致）、第 1 条（format 判定分散在两处）、第 15 条（单位/类型必须显式：容器格式必须单一权威）
- 后果：下载的无损曲在系统「音乐」库里被标记为 MP3，部分车机/第三方播放器按 MIME 选解码器直接报「格式不支持」；分享到微信时文件名 `xxx.mp3` 而内容是 FLAC，接收方无法播放。

### public_media_store.dart:137 `finalize` 返回值未校验
- 级别：P2
- 事实：`await _channel.invokeMethod<bool>('finalize', {'uri': uri});` 返回值被丢弃，紧接着返回 `PublishedFile(uri: uri, ...)`；`publish` 调用方随后把任务置 completed。
- 违反：第 9 条（失败必须可观测）、第 14 条（边界返回值必须校验）、第 29 条（成功判定口径必须逐一确认，不能假设）
- 后果：原生侧 finalize 返回 false 时（磁盘满、MediaStore 事务失败），条目仍是 `IS_PENDING=1`：App 内显示「已完成」并可播放（走 uri 读流），但系统相册/音乐 App 完全看不到文件，约 7 天后被系统清理——用户过一周发现下载的歌全没了，且无法解释。

### public_media_store.dart:150 发布前先删旧文件
- 级别：P1
- 事实：`_run` 在 publish 前 `queryExisting(...)` 查到同名文件就直接 `delete(exist)`，然后才 `publish`。`_publishDirect` 里 `target.openWrite(mode: FileMode.write)` 直接覆盖写，中间任何异常（空间不足、SELinux、文件被占用）都会让目标文件变成残缺文件；`_publishDirect` 没有先写 `.part` 再 rename 的原子性保证。
- 违反：第 21 条（写操作必须幂等或有防重/原子提交）、第 5 条（旧文件是唯一副本，删除与写入不是同一事务）
- 后果：用户对一首已下好的歌「重新下载」以修复爆音，结果中途失败/断网，旧的好文件已被删、新的半截文件留在音乐库——净结果是「越修越坏，且原文件不可恢复」。

### public_media_store.dart:216 queryExisting / :249 delete / :262 open 空捕获
- 级别：P2
- 事实：`queryExisting` 的 `try { ... } catch (_) {}` 后 `return null`；`delete` 的 `catch (_) {}` 后 `return false`（调用方 `remove()`、`clearAll()` 均不看返回值）；`open()` `catch (_) { return false; }` 无日志。
- 违反：第 6 条、第 7 条、第 9 条（失败静默）
- 后果：MediaStore 查询通道异常时「已存在同名文件」判定恒为 false，重复下载不断产生 `xxx (1).mp3`、`xxx (2).mp3`；平台通道版本不匹配（升级后原生侧改名）时，表现为「下载成功但打开失败」，日志里什么也没有。

### public_media_store.dart:74 临时目录无启动清理
- 级别：P2
- 事实：`tempDir()` 每次 `create(recursive: true)`，全仓唯一的清理点是单个任务完成/删除时按 `hash_type.ext` 精确删自己的文件。任务被 kill、App 进程被杀、publish 抛异常后 `realTempPath`（带真实扩展名，如 `.flac`）与 remove() 里拼的 `.mp3` 路径**不一致**，因此 `remove()` 的临时文件清理对 audio 任务几乎总是找不到文件。
- 违反：第 25 条（磁盘缓存必须有上限与回收点）、第 1 条（临时文件名规则两处各自拼接，必然漂移）
- 后果：异常中断的下载在 `downloads_tmp` 留下整首 FLAC/MV，永不回收；长期使用后占用数百 MB 到数 GB，用户在系统设置里「清除缓存」也未必覆盖（`getTemporaryDirectory` 在部分 ROM 上不参与「清除缓存」），最终表现为「App 占用空间莫名很大」。

### download_page.dart:39 生命周期监听只在下载页可见时生效
- 级别：P2
- 事实：`DownloadManager.onAppLifecycle` 的唯一调用点是 `_DownloadPageState.didChangeAppLifecycleState`，而 observer 在 `initState` 注册、`dispose` 注销。`download_provider.dart:69` 的注释宣称「App resume 时重置策略缓存」，实际只有用户停留在下载页时才会执行。
- 违反：第 5 条（状态刷新依赖某一页面存活，事实与注释不符）、第 2 条（隐式前提未声明：需页面挂载）
- 后果：Android 9 用户第一次拒绝存储权限 → 下载落到 `Android/data` → 用户去系统设置授权 → 回到 App（此时在首页/播放页）→ 之后所有下载仍落 `Android/data`，必须重启 App 才恢复。这正是注释里说要修的 bug，但修在了错误的作用域。

### download_page.dart:210 删除/打开用 `task.filePath` 混合 uri 与路径
- 级别：P3
- 事实：多处重复构造 `PublishedFile(uri: task.mediaUri.isEmpty ? null : task.mediaUri, path: task.filePath.isEmpty ? null : task.filePath)`，`PublishedFile` 的构造在三处（`download_page.dart` 3 次 + provider 2 次）重复展开；`filePath` 在 completed 时被赋成 `published.path ?? published.uri ?? ''`，即可能是 `content://` 字符串，此时 `path` 字段承载的是 uri。
- 违反：第 15 条（类型语义必须显式：path 字段装 uri）、第 1 条（同一映射逻辑复制 5 份）
- 后果：目录跳转 `viewFolder(path: 'content://...')` 必然失败（代码已用「复制路径到剪贴板」兜底，但复制给用户的是 `content://media/...` 串，用户粘贴到任何地方都打不开）。

### download_sheet.dart:43 音质取值三元表达式
- 级别：P3
- 事实：`quality: (song.quality != AudioQuality.q128 ? song.quality : preferredQuality()).value` —— 用「不等于 128」来推断「歌曲自带音质有效」，而 `q128` 同时也是合法用户选择；若歌曲对象默认就是 q128，则永远取全局默认，二者无法区分。
- 违反：第 16 条（「未设置」与「设置为 128」语义未分离）、第 2 条（隐式约定）
- 后果：用户在详情页明确选了 128k 下载，实际会按全局默认（如 320k/FLAC）下载，流量与体积超出预期；反之亦然。

### download_sheet.dart:99 下载按钮无已存在任务的禁用/覆盖提示
- 级别：P3
- 事实：`_OptionTile` 只对 `completed` 显示对勾，对 `failed/paused` 仍显示可点的下载图标，点击走 `manager.add` → 静默重排队；`下载全部` 只下发 audio/cover/lyric（不含 mv），与上方四个按钮的语义不一致但无任何说明。
- 违反：第 16 条（状态语义）、第 2 条（隐式行为）
- 后果：用户以为点一下是「补下失败的封面」，实际把已完成/暂停的任务全部重置重下，已下好的文件被删除重写（叠加前文「先删后写」问题）。
