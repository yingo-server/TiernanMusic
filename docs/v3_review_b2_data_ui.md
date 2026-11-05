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

### download_provider.dart 进度回调中整表复制 + 每次进度写盘
- 级别：P2
- 事实：`onProgress` 每收到一次进度就 `_update(cur.copyWith(...))`；`_update` → `_replace` 把 `[...state.tasks]` 整表复制并 `state = ...`，再 `unawaited(DownloadStore.save(task))` 逐条落 Hive。Dio 的 `onReceiveProgress` 在局域网/5G 下每秒可触发数十次，即每秒数十次 O(n) 列表复制 + 数十次 Hive 写盘（每次含整个任务 JSON 序列化），且没有任何节流/合并。
- 违反：第 25 条（资源必须有上限：此处写盘频率无上限、无节流）、第 26 条（热路径分配：进度回调每帧级路径上整表复制）
- 后果：下载多任务时界面明显掉帧；低端机下载期间整机卡顿、耗电与闪存写入放大（TLC 寿命）；任务数越多越卡（O(n) 随任务数线性放大）。

### download_provider.dart 临时文件名只由 hash+type 决定，新旧任务共用同一路径
- 级别：P1
- 事实：`_run` 里 `tempPath = '${tempDir.path}/${task.hash}_${task.type.name}${task.type.fileExtension}'`，`DownloadTask.id` 也是 `'${type.name}_$hash'`（`download_task.dart`），**都不包含音质（quality）、albumAudioId、targetLanguage**。`add()` 对同 id 已存在的任务只是 `_tokens[id]?.cancel('re-added')` 后立刻 `_replace` + `_schedule()`——旧 `_run` 可能正处在 `await _repo.publish(...)` 或 `downloadFile` 的写文件阶段，取消只对 Dio 请求生效，文件流/发布阶段不会被中断；此时新任务已经用**同一个** tempPath 开始写入。更糟的是 `_dio.download()` 的 `deleteOnError` 默认为 true：旧任务被取消时 Dio 会**删除这个路径上的文件**，而该文件此刻正被新任务写入——新任务写入的字节落到已删除的 inode 上，最终 `File(realTempPath).length()` 读到 0 字节或残缺文件。
- 违反：第 21 条（写操作幂等/防重：同一目标被两次写）、第 23 条（标识键必须覆盖全部影响结果的维度：音质缺失）、第 18 条（异步结果未校验世代：旧 `_run` 的 publish 结果仍会落到新任务条目上，仅靠 token 比对兜底，publish 阶段前无校验）
- 后果：① 同一首歌先下 128k、再下 320k 时，两个流同时写同一个临时文件，且旧任务的取消清理会删掉新任务正在写的文件 → 最终保存出一个「状态已完成、实际 0 字节/中途截断」的音频；② 已完成的 128k 任务被新任务覆盖为 completed，但文件内容是哪个音质取决于竞争结果；③ 用户看到「下载成功」却播放失败，重试仍可能复现同一竞态。

### download_provider.dart / download_repository.dart 无断点续传，却对外宣称「暂停保留进度」
- 级别：P2
- 事实：`pause()` 的注释写「取消网络请求，保留已下载进度信息」，`resume()` 只是把状态改回 queued；`_run` 一开始就 `received: 0, total: 0`，`downloadFile` 调用 `_dio.download(url, savePath, ...)` 既不带 `Range` 头，也没有 `options.headers['Range']` 或 `FileMode.append`，Dio 默认 `deleteOnError: true` 会删掉半成品。重试（`retries=2`）同样是从 0 重新下载整个文件。
- 违反：第 21 条（断点续传的幂等性：重试/恢复语义与状态不一致）、第 5 条（同一事实两处来源：`received/total` 声称的进度 vs 实际文件内容）、第 15 条（进度语义未显式定义：是「已落盘字节」还是「本次会话已收字节」）
- 后果：用户在大文件（无损/MV）下到 90% 点暂停或网络抖动自动重试，回来进度条从 0 重来，流量成倍消耗；弱网用户永远下不完一首 FLAC。持久化的 `received` 在重启后仍显示旧百分比，点继续瞬间跳回 0，视觉上像「进度丢失」。

### download_provider.dart `_strategy` 全局共享，与具体任务写入路径无绑定
- 级别：P2
- 事实：`_strategy` 是 manager 级单值，`onAppLifecycle` 在 `resumed` 时把 `_strategyResolved` 置 false，**下一次** `_run` 重新 resolve；而 `_strategyResolved` 只在 `!_strategyResolved` 时才置 true，也就是说两次下载之间用户改了权限，前一次已开始的任务仍用旧策略，后一次用新策略，`remove()`/`clearAll()` 删除文件时按任务里存的 `mediaUri`/`filePath` 判断，二者混存（MediaStore uri 与绝对路径）没有问题，但**策略切换本身没有日志、没有提示**：同一批「下载全部」的三个子任务可能一个进 MediaStore、两个进 Android/data。
- 违反：第 11 条（降级必须有触发/退出条件，且必须可观测：何时降级、为何降级无记录）、第 9 条（静默降级必须留痕）
- 后果：用户点「全部下载」后，歌曲在「音乐」App 可见，封面/歌词却在 `Android/data` 里且文件管理器看不到，用户以为下载丢了；不同机型上表现不一致，客服无法复现。

### download_provider.dart remove() / :405 完成清理 空捕获
- 级别：P2
- 事实：`remove()` 里 `try { ... f.deleteSync(); } catch (_) {}`，注释写「删除失败静默」；`_run` 完成分支同样 `try { f.deleteSync(); } catch (_) {}`；`public_media_store.dart` `delete()` 整体 `catch (_) {}` 返回 false（调用方 `remove()` 不检查返回值）、`queryExisting` 的 `catch (_) {}`、`open/viewFolder` 的 `catch (_) { return false; }`。
- 违反：第 6 条（禁止吞掉异常：既未转译、未记录、也无明确降级语义）、第 7 条（`catch (_)` 捕获一切对象）
- 后果：临时文件删不掉时无人知晓，`downloads_tmp` 目录在 SD 卡/内部存储里持续膨胀（用户清理缓存也清不到，因为该目录属 App 私有）；删除已发布文件失败时任务已从列表消失，MediaStore 里留下孤儿条目，用户「删了还在」。

### download_provider.dart downloadRepositoryProvider 内部 new MvRepository
- 级别：P3
- 事实：`MvRepository(ref.watch(kugouApiClientProvider))` 在 provider 体内构造协作者；`DownloadRepository` 构造函数额外接受 `MvRepository?`，但这里是唯一装配点，未复用 MV 域自己的 provider（若存在）。`DownloadRepository` 构造函数还 `dio ?? Dio(BaseOptions(...))` 自行构造 Dio。
- 违反：第 2 条（依赖必须由注入传入，不得内部自行构造；魔法超时值应具名）
- 后果：下载 MV 用的 client 与 MV 页面用的 client 不是同一实例（cookie/userid 靠静态共享 jar 兜底），一旦共享 jar 路径变化就串号；单元测试无法替换 Dio。

### download_repository.dart resolveAudioExt() 与 :63 resolveAudioUrl() 已被 :134 取代
- 级别：P3
- 事实：`resolveAudioExt`、`resolveAudioUrl` 两份实现与 `resolveAudioUrlWithExt`（V3-11 引入）是同一段逻辑的三份拷贝；`_run` 只调用 `resolveAudioUrlWithExt`。`resolveAudioExt` 在 `api == null` 时还静默返回 `'.mp3'`（不抛错），与 `resolveAudioUrl` 的 `throw StateError` 语义相反。
- 违反：第 32 条（死代码零容忍）、第 1 条（同一职责三处实现）、第 8 条（回退路径与主路径的异常形态不一致）
- 后果：任何后续调用者（新增下载入口/测试）若用 `resolveAudioExt`，在播放接口未初始化时会得到 `.mp3` 的假成功，把一个直接路径的 FLAC 存成 mp3 后缀——播放器按后缀解码失败。

### download_repository.dart downloadFile 重试只覆盖 DioException，且退避无上限说明
- 级别：P3
- 事实：`on DioException catch (e)`，`_isRetryable` 按 type/status 判断，退避 `1 << (attempt-1)` 秒；`retries` 是调用参数（`_run` 不传，默认 2）。但 `downloadFile` 没有校验 `savePath` 所在分区剩余空间，也没有 `total` 与磁盘可用空间比较。
- 违反：第 25 条（资源必须有上限/前置校验）、第 3 条（契约未写明：磁盘不足属何种异常）
- 后果：存储将满时先写满分区再抛 `FileSystemException`，被 `_run` 通用 `catch (e)` 记为「下载失败」；临时文件占满后连歌词/封面都下不了，需手动清缓存。用户看到的是「下载失败」而非「存储空间不足」。

### download_task.dart 任务 id 与 hasAudio 判定忽略音质
- 级别：P2
- 事实：`String get id => '${type.name}_$hash';`；`download_provider.dart` `hasAudio(hash)` 只看 hash+type+completed。`DownloadSheet` 的音质取自 `song.quality`/`preferredQuality()`（`download_sheet.dart`），与 id 无关。
- 违反：第 23 条（缓存/标识键缺维度）、第 16 条（「已下载」与「已下载该音质」语义未分离）
- 后果：用户在设置里把默认音质改成 FLAC，打开某首已下 128k 的歌，弹层直接显示「已下载 ✅」，无法再下无损；或反之，改了音质后重复下载覆盖旧文件，用户以为两版都在。

### public_media_store.dart MIME 固定，与真实扩展名不符
- 级别：P2
- 事实：`mimeOf` 对 audio 恒返回 `'audio/mpeg'`，mv 恒 `'video/mp4'`，cover 恒 `'image/jpeg'`；而 `download_repository.dart` 已按服务端 `extName`/URL 解析出 `.flac/.m4a/.ogg`（`resolveAudioUrlWithExt`），`_run` 用 `realTempPath` 写入、`displayNameOf` 用 `task.type.fileExtension`（恒 `.mp3`）——即**扩展名与 MIME 都在撒谎**，且与实际容器格式可能三者不一致。
- 违反：第 23 条（同一文件的描述维度不一致）、第 1 条（format 判定分散在两处）、第 15 条（单位/类型必须显式：容器格式必须单一权威）
- 后果：下载的无损曲在系统「音乐」库里被标记为 MP3，部分车机/第三方播放器按 MIME 选解码器直接报「格式不支持」；分享到微信时文件名 `xxx.mp3` 而内容是 FLAC，接收方无法播放。

### public_media_store.dart `finalize` 返回值未校验
- 级别：P2
- 事实：`await _channel.invokeMethod<bool>('finalize', {'uri': uri});` 返回值被丢弃，紧接着返回 `PublishedFile(uri: uri, ...)`；`publish` 调用方随后把任务置 completed。
- 违反：第 9 条（失败必须可观测）、第 14 条（边界返回值必须校验）、第 29 条（成功判定口径必须逐一确认，不能假设）
- 后果：原生侧 finalize 返回 false 时（磁盘满、MediaStore 事务失败），条目仍是 `IS_PENDING=1`：App 内显示「已完成」并可播放（走 uri 读流），但系统相册/音乐 App 完全看不到文件，约 7 天后被系统清理——用户过一周发现下载的歌全没了，且无法解释。

### public_media_store.dart 发布前先删旧文件
- 级别：P1
- 事实：`_run` 在 publish 前 `queryExisting(...)` 查到同名文件就直接 `delete(exist)`，然后才 `publish`。`_publishDirect` 里 `target.openWrite(mode: FileMode.write)` 直接覆盖写，中间任何异常（空间不足、SELinux、文件被占用）都会让目标文件变成残缺文件；`_publishDirect` 没有先写 `.part` 再 rename 的原子性保证。
- 违反：第 21 条（写操作必须幂等或有防重/原子提交）、第 5 条（旧文件是唯一副本，删除与写入不是同一事务）
- 后果：用户对一首已下好的歌「重新下载」以修复爆音，结果中途失败/断网，旧的好文件已被删、新的半截文件留在音乐库——净结果是「越修越坏，且原文件不可恢复」。

### public_media_store.dart queryExisting / :249 delete / :262 open 空捕获
- 级别：P2
- 事实：`queryExisting` 的 `try { ... } catch (_) {}` 后 `return null`；`delete` 的 `catch (_) {}` 后 `return false`（调用方 `remove()`、`clearAll()` 均不看返回值）；`open()` `catch (_) { return false; }` 无日志。
- 违反：第 6 条、第 7 条、第 9 条（失败静默）
- 后果：MediaStore 查询通道异常时「已存在同名文件」判定恒为 false，重复下载不断产生 `xxx (1).mp3`、`xxx (2).mp3`；平台通道版本不匹配（升级后原生侧改名）时，表现为「下载成功但打开失败」，日志里什么也没有。

### public_media_store.dart 临时目录无启动清理
- 级别：P2
- 事实：`tempDir()` 每次 `create(recursive: true)`，全仓唯一的清理点是单个任务完成/删除时按 `hash_type.ext` 精确删自己的文件。任务被 kill、App 进程被杀、publish 抛异常后 `realTempPath`（带真实扩展名，如 `.flac`）与 remove() 里拼的 `.mp3` 路径**不一致**，因此 `remove()` 的临时文件清理对 audio 任务几乎总是找不到文件。
- 违反：第 25 条（磁盘缓存必须有上限与回收点）、第 1 条（临时文件名规则两处各自拼接，必然漂移）
- 后果：异常中断的下载在 `downloads_tmp` 留下整首 FLAC/MV，永不回收；长期使用后占用数百 MB 到数 GB，用户在系统设置里「清除缓存」也未必覆盖（`getTemporaryDirectory` 在部分 ROM 上不参与「清除缓存」），最终表现为「App 占用空间莫名很大」。

### download_page.dart 删除/打开用 `task.filePath` 混合 uri 与路径
- 级别：P3
- 事实：多处重复构造 `PublishedFile(uri: task.mediaUri.isEmpty ? null : task.mediaUri, path: task.filePath.isEmpty ? null : task.filePath)`，`PublishedFile` 的构造在三处（`download_page.dart` 3 次 + provider 2 次）重复展开；`filePath` 在 completed 时被赋成 `published.path ?? published.uri ?? ''`，即可能是 `content://` 字符串，此时 `path` 字段承载的是 uri。
- 违反：第 15 条（类型语义必须显式：path 字段装 uri）、第 1 条（同一映射逻辑复制 5 份）
- 后果：目录跳转 `viewFolder(path: 'content://...')` 必然失败（代码已用「复制路径到剪贴板」兜底，但复制给用户的是 `content://media/...` 串，用户粘贴到任何地方都打不开）。

### download_sheet.dart 音质取值三元表达式
- 级别：P3
- 事实：`quality: (song.quality != AudioQuality.q128 ? song.quality : preferredQuality()).value` —— 用「不等于 128」来推断「歌曲自带音质有效」，而 `q128` 同时也是合法用户选择；若歌曲对象默认就是 q128，则永远取全局默认，二者无法区分。
- 违反：第 16 条（「未设置」与「设置为 128」语义未分离）、第 2 条（隐式约定）
- 后果：用户在详情页明确选了 128k 下载，实际会按全局默认（如 320k/FLAC）下载，流量与体积超出预期；反之亦然。

### download_sheet.dart 下载按钮无已存在任务的禁用/覆盖提示
- 级别：P3
- 事实：`_OptionTile` 只对 `completed` 显示对勾，对 `failed/paused` 仍显示可点的下载图标，点击走 `manager.add` → 静默重排队；`下载全部` 只下发 audio/cover/lyric（不含 mv），与上方四个按钮的语义不一致但无任何说明。
- 违反：第 16 条（状态语义）、第 2 条（隐式行为）
- 后果：用户以为点一下是「补下失败的封面」，实际把已完成/暂停的任务全部重置重下，已下好的文件被删除重写（叠加前文「先删后写」问题）。

---

# 二、认证域

> 线路核对（先于结论）：`kugouApiClientProvider` = `kgDirectApiProvider`（`core/providers.dart`），
> `KgDirectApiClient.fallbackToKapi = false`，未移植路径抛 `ApiException(-404)` 而不是走 kapi。
> 因此本域「是否走原生网关」在**装配层成立**；下面问题集中在调用形态与状态机。

### auth_repository.dart `AuthRepository()` 默认构造裸 KugouApiClient（kapi baseUrl）
- 级别：P3（结构性隐患，当前装配已注入）
- 事实：构造签名为 `AuthRepository({KugouApiClient? api, ...}) : _api = api ?? KugouApiClient()`；`KugouApiClient` 的 `baseUrl ?? AppConfig.kugouApiBase`，而 `AppConfig.kugouApiBase = 'https://kapi.344977.xyz'`。`authRepositoryProvider` 目前注入了直连客户端，但默认值把「忘记注入」的路径直接指向第三方中转，且 `KugouApiClient` 的 `setCredentials` 也把 token/userid cookie 写到 kapi 域名。
- 违反：第 2 条（依赖必须注入，不得内部构造）、第 27 条（中转网关不得作为实现路径，哪怕只是默认值）
- 后果：任何新调用点（后台 isolate、测试、工具脚本、以后新增的 provider）一旦漏注入，登录密码、短信验证码、token 会整包发往第三方 kapi；届时是「静默」的，没有任何日志能区分走了哪条链路。

### auth_repository.dart `getDfid()` 全空捕获后返回空串
- 级别：P2
- 事实：`try { ... } catch (_) {}`，失败时 `return ''`；注释只解释了「不落盘 '-'」，没有记录失败、没有返回值语义（空串 = 失败还是「设备无需 dfid」）。
- 违反：第 6 条（禁止吞异常）、第 9 条（失败必须可观测）、第 16 条（失败与「无此概念」未分离）
- 后果：设备注册接口被风控/断网时，登录请求带空 dfid，上游按新设备处理 → 频繁触发 20028 人机验证或直接 `status=2`；用户看到「登录失败」，日志里查不到任何 dfid 相关记录。

### auth_repository.dart 外部数据裸强转 `(res['data'] as Map<String, dynamic>?)`
- 级别：P2
- 事实：`getQrKey`、`checkQr`、`getUserDetail`、`loginBySms`（`_errorResponseData`）、`_handleLoginSuccess`、`captcha_types.dart VerifySession.fromJson` 全部使用 `as Map<String, dynamic>?` 直接断言。同仓库已有反例：`comment_repository.dart` 用 `whereType<Map>()` 逐一校验，`mv_repository.dart` 用 `raw is List / raw is Map` 分支——说明上游确实存在 `data` 为 List 的端点（`/video/detail`、`/playlist/detail` 已实测）。
- 违反：第 13 条（外部数据禁止裸类型强转）、第 10 条（类型错误必须暴露，不能被当成业务失败兜底）
- 后果：上游一旦把 `login/qr/check` 的 `data` 换成数组或字符串，抛的是 `TypeError` 而不是 `ApiException`：登录页 `catch (e)` 只显示一句 `friendlyError`，二维码页停在「待扫码」；`restoreSession` 的外层 `catch (_)` 把它吞掉后返回降级用户 → 用户表现为「明明登录过，重启后变成未登录且昵称空白」。

### auth_repository.dart `restoreSession()` 三层嵌套 catch + 失败再发请求
- 级别：P2
- 事实：`try { loginByToken } on DioException { 判断 invalid → logout / 降级 } catch (_) { try { getUserDetail } on DioException {...} catch (_) { return _degradedUser } }`。三段降级彼此独立：第一段按错误码判失效，第二段按 `getUserDetail` 判失效，第三段无条件降级；`catch (_)` 同时吞掉 `TypeError`/`StateError`。
- 违反：第 8 条（异常契约必须单一且可穷尽）、第 7 条（捕获一切对象）、第 11 条（降级的触发/退出条件未定义）、第 10 条（编程错误进入业务降级）
- 后果：凭证真的失效但错误码不在白名单时，用户被永久停留在「已登录」状态：收藏/评论/下载全部 401 失败，而界面没有任何「重新登录」入口（因为 UI 认为已登录）；反过来，代码 bug 造成的 TypeError 会被包装成「弱网降级」，永远不上报。

### auth_repository.dart `_isTokenInvalidCode()` 用错误文案判断凭证失效
- 级别：P2
- 事实：`const invalidCodes = {1011, 30791, 401};` 之后 `return code == -1 && message.contains('token');`——把自然语言文案当作协议字段。
- 违反：第 8 条（契约必须稳定可枚举）、第 2 条（隐式约定：文案即协议）
- 后果：上游把提示改成中文「登录已过期」或换字段后，失效凭证不再被清理，用户卡在假登录；反过来任何含 "token" 字样的参数错误（例如「token 参数缺失」）会被误判为凭证失效并执行 `logout()`，用户被无故踢下线、本地账号列表被清指针。

### auth_repository.dart `_handleLoginSuccess()` t1 的删除策略与内存不一致
- 级别：P2
- 事实：`final t1 = d['t1']?.toString();` → `saveCredentials(..., t1: t1)`，而 `SecureStorage.saveCredentials` 在 `t1 == null` 时 **delete** 旧键；同时 `KgDirectApiClient.setCredentials` 在 `t1 == null` 时**保留** `kg.t1` 原值（`if (t1 != null) kg.t1 = t1;`）。即内存里有 t1、磁盘上已删除。`auth_providers.dart` 的注释明确写着「直连 /login/token 的签名用 kg.t1，若此刻为空则刷新必然失败」。更关键的是 `main.dart` 的 `ref.listen(authStateProvider, ...)`：登录/恢复后它用 `SecureStorage.readCredentials()` 回填 `client.t1`，且 `client.t1 = (c != null && c.userId == user.userid) ? (c.t1 ?? '') : '';`——**无条件覆盖**，即使 `_afterLogin` 刚在内存里写入过有效 t1，只要磁盘上没有 t1 就会被清成空串。
- 违反：第 5 条（同一状态两处来源，且写入规则相反）、第 20 条（凭证生命周期不对称：写入与清除不在同一语义内）
- 后果：QR 登录/重新登录的响应若不带 t1（`login/qr/check` 的直连实现只回写 token/userid，见 `kg_endpoints_auth.dart`），本次会话能正常用，**下次冷启动** `login/token` 因 t1 为空而失败 → 用户每次重开 App 都要重新扫码/输验证码。

### auth_repository.dart / account_manager.dart 昵称与头像存在三份可写副本
- 级别：P2
- 事实：`authStateProvider` 的 `AuthUser` 带 nickname/avatar；`AccountManager.upsert(AccountRecord(nickname, avatar))` 写 Hive 'accounts'；`_handleLoginSuccess` 又 `Hive.box('settings').put('nickname'), put('avatar')`。第三处写入整体包在 `try { ... } catch (_) {}` 中，失败被完全吞掉，而前两处成功；`authStateProvider.logout()` 只删 settings 两键，accounts 里的记录与 `AuthUser` 各自独立变化。
- 违反：第 5 条（状态单一来源；同一事实三处存储且写入点/失败策略不同）、第 6 条（settings 写入失败被空捕获）
- 后果：settings 盒写入失败（升级后 box 未打开、磁盘满）时，音乐库卡片/账号菜单（读 accounts）显示新昵称，而设置页（读 settings 盒）永远显示旧昵称或空——同一个用户在两处看到两个身份；这在「刚换过头像/昵称」时最容易被用户当成「资料没保存」。也正因为有三份，任何一处漏更新都不会报错。

### auth_repository.dart `loginByPassword` 的 ssaCode 取值链对 dynamic 做下标
- 级别：P2
- 事实：`final ssaCode = '${data?['ssaCode'] ?? data?['data']?['ssaCode'] ?? data?['ssa_code'] ?? ''}';`。若 `data['data']` 是 String/List（20028 响应体形态未实测留样），`?['ssaCode']` 在 dynamic 上会抛 `NoSuchMethodError`。
- 违反：第 13 条（外部数据不得假设形态）、第 3 条（20028 契约的字段集合未固定）
- 后果：命中风控时抛 `NoSuchMethodError`，被登录页通用 `catch` 显示成 `friendlyError` 的兜底文案，验证码页永不弹出——用户被要求「重试」，但每次都被风控拦截，密码登录彻底不可用。

### login_page.dart `_sendCode()` 无请求中互斥
- 级别：P2
- 事实：按钮只在 `_countdown > 0` 时禁用，而 `_countdown` 在 `await sendSmsCode` **成功之后**才置 60；期间 `_loading` 标记不存在，`_sendCode` 自身也没有 `if (_sending) return`。
- 违反：第 21 条（写操作必须防重）、第 19 条（闸门必须成对且归属同一所有者）
- 后果：弱网下用户连点两次「发送验证码」，服务端收到两条短信请求 → 两条验证码，先到的那条作废；频繁触发会升级为 20028 人机验证，甚至按条计费。

### login_page.dart `_QrLoginTab._checkOnce()` 轮询失败全静默 + 后台不停轮询
- 级别：P2
- 事实：`catch (_) { // 轮询失败忽略，下次再试 }`；`_scheduleNextPoll` 固定 3 秒、无退避、无最大失败次数；`_QrLoginTab` 没有 `WidgetsBindingObserver`，App 退到后台后 Timer 继续触发网络请求（`dispose` 才 cancel）。
- 违反：第 6 条（空捕获）、第 9 条（失败不可观测）、第 25 条（重试频率/次数无上限）、第 20 条（生命周期未随前后台切换）
- 后果：断网时用户盯着「请扫码」永远不动，不知道是网络问题；弱网/后台挂 10 分钟就是 200 次无效请求，耗电耗流量并可能被风控降级，下一次真扫码时提示「二维码已失效」。

### login_page.dart `_loadQr()` 未校验 key 为空即开始轮询
- 级别：P2
- 事实：`_key = qr.key;` 后无条件 `_startPolling()`；`AuthRepository.getQrKey()` 在两条路径都取不到时返回 `key: ''`（`'${d['qrcode'] ?? ''}'`）。`_checkOnce` 只判 `key == null`，空串会照发。
- 违反：第 14 条（边界必须校验）、第 16 条（「无 key」与「key 已失效」未区分）、第 3 条（空值语义未定义）
- 后果：key 获取失败的机型上，页面永久显示「待扫码」，每 3 秒发一次 `qrcode=` 的空请求，服务端返回错误被吞掉；用户既扫不了码也不知道要刷新（刷新按钮只在 `_status == 0 || _error != null` 时出现，而这里两者都不成立）。

### verification_service.dart `submit()` 成功判定为推测，且未留样
- 级别：P2
- 事实：`final ok = status == 1 || status == '1' || (data['data'] is Map && codeDesc.toLowerCase() == 'success');`。`docs/api_verified.md` 只有 `get/verify/info` 的**错误**样本（假 eventid → st=0 ec=36001），`verify/user/info` 的成功返回**没有任何留样**。
- 违反：第 29 条（返回结构与成功判定必须实测留样；未实测不得作为依据）、第 3 条（契约先行：成功语义未定义）
- 后果：验证实际通过而上游用的是第三种口径（例如 `status=200`，与歌词接口一致）时，页面判定「验证未通过，请重试」，用户反复验证直到被风控锁定，最终无法登录/评论。

### verification_service.dart `submit()` 把一切 ApiException 当作「验证未通过」
- 级别：P2
- 事实：`on DioException catch (e) { if (e.error is ApiException) return false; rethrow; }`。而直连层把「未移植路径 -404」「空响应体 -1」「参数错误 20010」全部包装成 `ApiException` 塞进 `DioException.error`。
- 违反：第 8 条（异常契约必须可区分）、第 9 条（失败必须可观测且有正确语义）
- 后果：验证接口本身不可用（未移植/被网关拦截）时，用户看到的是「验证未通过，请重试」——一个永远不可能成功的动作，既无法上报也无法自查。

### captcha_page.dart `typeHint` 字段从未使用
- 级别：P3
- 事实：`final CaptchaType? typeHint;` 只在构造里赋值，`build`/`_buildByType` 完全不读；类型完全由 `VerifySession.type` 决定。
- 违反：第 32 条（死代码零容忍）
- 后果：调用方以为可以「带提示修正识别错误的验证类型」，实际被静默忽略；类型识别错误时只能退到「未知类型」页。

### captcha_page.dart 验证码状态机无过期/重载路径
- 级别：P2
- 事实：`_load()` 只用构造传入的 `widget.ssaCode` 请求一次；`_error` 时「重试」按钮调 `_load()` 复用**同一个**已过期的 eventid；`_submitWithCode` 失败后只把 `_submitting` 置 false，不重新取事件（`/get/verify/info` 的返回里本就有 `sessionid`/`type_list`，未被使用）。
- 违反：第 11 条（降级必须有触发条件与恢复条件）、第 3 条（eventid 有效期契约未定义）
- 后果：用户在两分钟内没完成滑块，之后无论点多少次「重试」都失败（同一个过期 eventid），只能杀掉页面回到登录重新触发 20028——而多数用户在验证页内看不到「关闭再重来」的指引。

### captcha_page.dart 短信验证类型无「发送/重发验证码」入口
- 级别：P2
- 事实：`_buildSms` 只有 `TextField` + 「提交验证」按钮；全页没有任何调用 `/captcha/sent` 或 `sendSmsCode` 的按钮，也没有倒计时。该分支假定「进入页面时上游已自动下发短信」。
- 违反：第 3 条（交互契约未定义：短信由谁触发）、第 11 条（无恢复路径）
- 后果：若上游并不自动下发（v_type=32 的实现未实测留样），用户收不到验证码、页面又没有发送按钮 → 验证流程死锁，账号被风控后彻底无法登录。

### captcha_page.dart 腾讯验证 WebView 失败无任何反馈
- 级别：P2
- 事实：内嵌 HTML 的 `catch (e) { done('', ''); }` 会以空 ticket/randstr 回调；Dart 侧 `if (ticket.isNotEmpty && randstr.isNotEmpty)` 才提交，否则**什么都不做**；`TCaptcha.js` 加载失败、`txappid` 解析不到（退化为 `_buildUnknown`）也没有错误提示。
- 违反：第 9 条（失败必须可观测）、第 6 条（隐含吞掉 WebView 侧异常）
- 后果：用户点了「开始验证」后页面没有任何反应（既没弹窗也没报错），以为按钮坏了；弱网下尤其常见。

### captcha_page.dart 全页硬编码中文
- 级别：P2
- 事实：`'人机验证'`、`'重试'`、`'短信验证'`、`'请输入接收到的验证码完成验证'`、`'验证码'`、`'提交验证'`、`'该验证类型需要在酷狗官方 App 内完成。'`、`'验证未通过，请重试'`、`'提交失败：$e'`、`'如验证码未自动弹出…'` 全部为字面量；同目录 `login_page.dart` 全量使用 `context.l10n.*`。
- 违反：第 30 条（项目口径：用户可见文案必须走 l10n）、第 1 条（同一流程两条文案来源）
- 后果：英文/日文/韩文界面用户在人机验证页突然看到整页中文，无法继续操作；翻译团队也无法覆盖（.arb 里没有这些键）。

### captcha_page.dart 短信输入 maxLength 与提示不一致
- 级别：P3
- 事实：`maxLength: 8`，`labelText: '验证码'`、`hintText: '6 位数字'`；提交时只判非空。
- 违反：第 3 条（输入取值范围未定）
- 后果：用户输入 7–8 位后提交，上游必然报错，错误又被归为「验证未通过」，白跑一轮。

### kg_endpoints_auth.dart `captchaSent()` 走明文 HTTP 且未记录原因
- 级别：P1（隐私/安全）
- 事实：`kg.request('/v7/send_mobile_code', baseUrl: 'http://login.user.kugou.com', ...)`，body 为 `{businessid:5, mobile: 完整手机号, plat:3}`。同文件其它端点均为 `https://`（`loginserviceretry`、`login-user`、`verifyservice`、`login.user` 的 login 走 https），只有这一处是 http；代码没有任何注释说明「上游只接受 http」或「为何可以接受明文」。
- 违反：第 31 条（平台怪癖/反常行为必须写明原因，否则下个人无法判断是 bug 还是约束）
- 后果：手机号（可直接关联到账号的真实 PII）在公共 Wi-Fi、运营商侧、恶意热点下可被明文嗅探；由于这是短信登录的第一步，泄露面覆盖所有用短信登录的用户。当前实现无法证明这是上游硬约束，因此必须按「可能的安全缺陷」处理。

---

# 三、评论域

### kg_direct_api_client.dart `post()` 缺少评论写操作分支 → 发评论/回复/删除全部失效
- 级别：P1
- 事实：`KgEndpointComment` 已实现 `commentSend`（POST `/index.php?r=commentsv3/add`）、`commentFloorSend`（POST `commentsv2/reply`）、`commentDel`（GET `commentsv2/delcomment`），并在 `KgDirectApiClient` 的 **get** switch 中被路由（`case 'comment/music/send' ... write: true`、`case 'comment/floor/send'`、`case 'comment/music/del'`）。但 `CommentRepository` 的三个写方法都用 `_api.post(...)`，而 **post switch 里没有这三个 case**（只有 `comment/music`、`comment/floor`、`comment/playlist`、`comment/album` 的读）。post 落到末尾统一的「未移植」分支：`throw _asDioException('/$n', ApiException(-404, '接口 /$n 尚未移植到原生网关…'))`。
- 违反：第 28 条（调用方式必须逐一实测：方法/路径形态与实现不一致，属「参数形态错误导致静默失败」的同族）、第 3 条（跨层契约先行：Repository 与 Client 对 method 的约定从未对齐）、第 27 条（原生网关已实现却不可达，等于功能不存在）
- 后果：任何用户点「发送评论」「回复」「删除」都会弹出技术文案「接口 /comment/music/send 尚未移植到原生网关（kapi 仅作参考，运行期不调用）」。评论功能变成纯只读；用户反复重试无效，且看到的是内部实现细节。这是本批最严重的功能性缺陷。

### comment_repository.dart `sendComment()` 为取 childrenId 先拉一页评论
- 级别：P3
- 事实：发送前 `fetchComments(type: song, id: id, page: 1, pageSize: 1)`，只为拿 `specialChildId`；失败时 `catch (_) {}` 静默继续，`childrenid` 交给直连层兜底（`_childName` 只处理名字，`childrenid` 取 `q['special_id'] ?? q['id']`，此时 `id` 是 mixsongid —— 与 special_child_id 语义不同）。
- 违反：第 1 条（发送职责里夹带一次读请求）、第 6 条（空捕获）、第 3 条（childrenid 语义未对齐）
- 后果：每条评论多一次网络往返（弱网下发送延迟翻倍）；取不到时用 mixsongid 冒充 childrenid，上游按「不存在的楼层」处理 → 评论发送成功但楼中楼挂错位置/不进楼层。

### comments_page.dart `_send()` 无提交锁，先清空输入再发请求
- 级别：P2
- 事实：`_inputCtrl.clear();` 在 `await` 之前；`_send()` 无 `_sending` 标记，回车（`onSubmitted`）与发送按钮可各触发一次；失败分支只 Toast，不回填文本。
- 违反：第 21 条（写操作必须防重）、第 9 条（失败后可恢复性）
- 后果：连按两次回车会产生两条一模一样的评论（服务端不去重，用户只能逐条删——而删除同样失效，见上）；网络失败时用户刚打的几十个字被清空且不可恢复，重打等于重写。

### comments_page.dart `_commentsProvider` 为非 autoDispose family
- 级别：P2
- 事实：`StateNotifierProvider.family<_CommentsController, AsyncValue<CommentPage>, _CommentArgs>`，`_CommentArgs` 无 `==`/`hashCode`（按 identity 建键），页面 `dispose` 后 ProviderContainer 仍持有 controller 与整页评论列表，永不释放。对比同仓 `_userPlaylistsProvider`、`mvDetailProvider` 均为 `autoDispose`。
- 违反：第 25 条（内存条目无上限）、第 20 条（生命周期不对称：创建无对应销毁）
- 后果：用户连续打开 30 首歌的评论区（每页 30 条评论 + 头像 URL），进程内常驻约 900 条评论对象与字符串，且不再被使用；低端机上表现为「越用越卡、切回首页要重载」。

### comments_page.dart 刷新失败与加载更多失败均静默
- 级别：P2
- 事实：`load()` 的 catch 只有 `if (state.value == null) state = AsyncValue.error(...)`——已有数据时刷新失败什么都不做（不 Toast、不日志、`RefreshIndicator` 正常收起）；`loadMore()` 的 `catch (_) { // 失败不推进页码 }` 完全空体。
- 违反：第 6 条（空捕获）、第 9 条（失败必须可观测）
- 后果：下拉刷新失败时用户以为已是最新（其实是旧数据）；上拉失败时列表底部永远显示「没有更多了」，用户无法区分「真的到底」与「请求失败」，只能退出重进。

### comments_page.dart / comment_floor_page.dart 登录态用 `ref.read` 读在 build 里
- 级别：P2
- 事实：两页都写 `bool get _isLoggedIn => ref.read(authStateProvider).valueOrNull != null;`，`build` 中调用；登录/切号/退出后不会重建（只有 `_authSub` 在 library 页监听，评论页无监听）。
- 违反：第 5 条（状态读取必须订阅单一来源）、第 18 条（异步结果未校验世代：页面存活期间登录态可能已变）
- 后果：从评论页点「登录」→ 登录成功回到首页再进来才恢复；若在设置页切号后返回评论页，输入框仍显示「登录后评论」、发送按钮仍跳登录页，用户以为登录失败。

### comment_repository.dart `total` 缺失时回落为当前页条数
- 级别：P3
- 事实：`_asInt(data['count'] ?? ... , fallback: comments.length)`；`fetchCount` 缺字段直接返回 0。
- 违反：第 16 条（「未知」与「空/零」必须分离）
- 后果：上游不下发 count 时，一页 30 条就显示「共 30 条评论」，翻页逻辑（`_page * 30 >= total`）立即判定到底，用户看不到第 2 页；歌曲卡片上的评论数显示 0 而实际有评论。

### comment_floor_page.dart `_load()` 与 `_loadMore()` 无世代校验
- 级别：P2
- 事实：`_load()` 把 `_page = 1` 并 `_comments.clear()`；`_loadMore()` 在 await 之后直接 `_comments.addAll(result.comments)` 并 `_page = next`，没有任何 generation/token 比对（对比 `comments_page._CommentsController` 有 `_generation`）。
- 违反：第 18 条（异步结果必须校验世代）、第 5 条（分页游标与列表内容可能不一致）
- 后果：下拉刷新与上拉加载同时发生时，旧的第 3 页数据被追加到刚清空的新列表上 → 楼层重复出现/顺序错乱，回复数对不上；用户会看到同一条回复出现两次。

### comment_floor_page.dart 无 20028 验证分支，且直接展示 `$e`
- 级别：P2
- 事实：`_send()` 的 catch 只有 `Toast.show(context, context.l10n.commentFailed('$e'))`；`comments_page._send()` 则有完整的 `unwrapApi → needsVerification → CaptchaPage` 分支。`_load()` 失败时 `_error = '$e'` 直接交给 `ErrorRetry` 显示。
- 违反：第 8 条（同一层异常契约/回退路径必须一致）、第 9 条（用户可见反馈必须是可理解的语义）
- 后果：楼层回复被风控时用户只看到 `DioException [unknown]: null` 之类技术串，且没有验证入口 → 楼中楼回复功能对该用户永久不可用（顶层评论还能通过验证恢复）。

### comment_floor_page.dart `_load()` 的 finally 不触发重建
- 级别：P3
- 事实：`finally { _loading = false; }` 无 `setState`；而 build 里用 `_comments.isEmpty && !_loading` 决定空态，`_loading` 变化不会引起重建（依赖其它 setState 顺带刷新）。
- 违反：第 5 条（状态变更未通知订阅者）
- 后果：首屏加载失败/成功时偶发停在旧画面（例如先显示「暂无回复」再突然出现列表），或下拉刷新后 loading 指示不消失。

---

# 四、榜单与 MV 域

### rank_repository.dart `as Map<String, dynamic>` 冗余强转
- 级别：P3
- 事实：`await _api.post(...) as Map<String, dynamic>`——`KugouApiClient.post` 的返回类型本就是 `Future<Map<String, dynamic>>`。
- 违反：第 32 条（死代码/无效断言）
- 后果：无功能影响，但会让读者误以为 post 可能返回其它类型，掩盖了「返回值其实已被契约保证」这一事实。

### rank_repository.dart `total` 缺失时回落 `songs.length`
- 级别：P3
- 事实：`int.tryParse('${map['total'] ?? ''}') ?? songs.length`。
- 违反：第 16 条（未知与已读完混同）
- 后果：上游不下发 total 时，第一页就判定「已到末尾」，榜单只能看 30 首；用户滑动到底看到「没有更多」而不是「加载失败/未知」。

### mv_provider.dart `mvDetailProvider` 失败返回 null，吞掉全部异常
- 级别：P2
- 事实：`try { return await fetchDetail(hash); } catch (_) { return null; }`，UI 只拿到 `null`，无法区分「该视频只有一个清晰度」「hash 不是 video_id」「网络失败」三种情况。
- 违反：第 6 条（空捕获）、第 9 条（失败静默）、第 16 条（三种语义压成同一种）
- 后果：清晰度按钮凭空消失，用户不知道是不能切还是加载失败；只有 hash（无 videoId）进入播放页时 `fetchDetail(hash)` 按仓库注释必然 `invalid param` → 所有从「收藏 MV」进入的播放页都拿不到清晰度列表。

### mv_repository.dart `resolvePlayUrl()` 的两处无原则兜底
- 级别：P3
- 事实：① `d[hash.toLowerCase()] ?? d[hash.toUpperCase()] ?? (d.isEmpty ? null : d.values.first)`——大小写都不匹配时取「随便第一个」，可能取到别的清晰度；② `backup is List && backup.isNotEmpty → url = '${backup.first}'`——元素若是 Map，字符串化后是 `{...}`，被当成 URL 返回。
- 违反：第 11 条（降级必须有明确触发条件与次优行为）、第 13 条（外部数据未校验形态）
- 后果：用户选了「高清」却播放成「流畅」（或反之）；备份地址是对象形态时播放器报 `Unsupported URL`，错误文案是 `_error` 里的原始异常，用户无法理解。

### mv_player_page.dart 切清晰度被 `_resolving` 静默丢弃
- 级别：P2
- 事实：`_resolve()` 开头 `if (_resolving) return;`，没有任何 loading 提示或排队；切档时 `_resolving` 会保持 true 直到旧请求 + `initialize()` 全部完成（弱网下数秒）。
- 违反：第 22 条（并发假设必须显式声明并保护）、第 9 条（被拒绝的操作无反馈）
- 后果：弱网下用户点「高清」没反应，再点「超清」还是没反应，以为按钮坏了；实际只有第一次点击排队，最终播出的档位与最后一次点击不一致。

### mv_player_page.dart 在 build 中注册 post-frame 回调修改系统 UI
- 级别：P3
- 事实：`build` 内直接 `WidgetsBinding.instance.addPostFrameCallback((_) { SystemChrome.setEnabledSystemUIMode(...); });`，每次 setState（切控件、播放/暂停、错误态）都会排一次平台调用。
- 违反：第 24 条（build 必须是纯函数，不含副作用）、第 26 条（高频路径上的平台通道调用）
- 后果：每次点屏幕都在主线程排队一次 SystemChrome 调用，低端机上控制条显隐有可感知延迟；横竖屏切换瞬间可能与系统栏动画打架（闪一下状态栏）。

### mv_player_page.dart 播放器无 listener，播放/暂停图标与进度不刷新
- 级别：P3
- 事实：`VideoPlayerController` 创建后从未 `addListener`；`_buildPlayer` 用 `controller.value.isPlaying` 决定图标，只在 `onPressed` 里手动 `setState`。播放结束、缓冲、被系统暂停都不会重建。
- 违反：第 5 条（状态变化未驱动 UI）
- 后果：视频播完后按钮仍显示「暂停」，用户点一下才开始重播；缓冲时没有任何指示，看起来像卡死。

### mv_player_page.dart 错误态直接展示异常原文
- 级别：P3
- 事实：`setState(() => _error = '$e');` 后 `Text(_error!)` 直接渲染。
- 违反：第 9 条（用户可见反馈必须是有语义的领域信息）
- 后果：用户看到 `PlatformException(VideoError, ...)`/`SocketException` 原文，既看不懂也不知道该重试还是该换网络。

---

# 五、音乐库域

### library_page.dart 三个区块用 for 循环一次性构建
- 级别：P2
- 事实：`CustomScrollView` 里只有一个 `SliverToBoxAdapter(Column(...))`，内部 `for (final r in _recent.take(20)) SongTile(...)`、`for (final task in downloaded.take(20)) SongTile(...)`、`for (final mv in list.take(20)) ListTile(...)`。全部 60 个条目在首帧同步 build（含 `CachedNetworkImageProvider`、`MediaQuery` 解析）。
- 违反：第 24 条（长列表必须惰性构建）、第 26 条（首帧热路径分配）
- 后果：音乐库首帧明显慢于其它 Tab（低端机 100ms+），进入页面有可见白屏/掉帧；滚动时整块 Sliver 无法按需构建。

### library_page.dart 登录态以 AccountManager（Hive）为准，评论/其它页以 authStateProvider 为准
- 级别：P2
- 事实：`_currentAccount()` 读 `AccountManager.instance.currentAccount`，`account != null` 决定「我的歌单/收藏 MV」是否展示；而 `comments_page`、`comment_floor_page`、`download_sheet` 用 `authStateProvider`。两者来源不同：`restoreSession()` 成功时写 SecureStorage + `AccountManager`（经 `_handleLoginSuccess`），但**降级路径**（`_degradedUser`）不写 AccountManager；反之 `AccountManager.clear()` 或 Hive 损坏时 accounts 为空而 SecureStorage 仍有凭证。
- 违反：第 5 条（同一事实两处权威来源）、第 16 条（「已登录但资料缺失」与「未登录」未分离）
- 后果：出现过「音乐库卡片显示未登录、但评论区能直接发评论」或相反的组合；用户会认为账号状态错乱，重登也未必恢复（因为卡片的判据是 Hive 记录，不是凭证）。

### library_page.dart `_currentAccount()` 空捕获
- 级别：P3
- 事实：`try { return AccountManager.instance.currentAccount; } catch (_) { return null; }` 无日志。
- 违反：第 6 条、第 9 条
- 后果：AccountManager 未初始化（启动异常路径）时界面静默显示「未登录」，用户会去重新登录，而真实原因是 Hive box 打不开——日志里没有任何线索。

### library_page.dart 账号变化时全页 setState + 双 invalidate
- 级别：P3
- 事实：`_authSub` 回调 `setState(() {})`（重建 60 个 tile）+ `ref.invalidate(_userPlaylistsProvider)` + `ref.invalidate(_collectedMvsProvider)`。
- 违反：第 26 条（高频/全局重建）、第 1 条（一个事件触发三处副作用）
- 后果：切号瞬间音乐库整体重建并同时发两个网络请求，低端机可见卡顿；微信式「切号后立刻返回」场景下会闪一次骨架屏。

### library_page.dart `_loadRecent()` 随每次播放重新读全量记录
- 级别：P3
- 事实：`RecentPlayStore.changes.listen((_) { if (mounted) _loadRecent(); })`，`_loadRecent` 每次 `RecentPlayStore.read()` 全量读盘并 `setState`，无防抖/去重；`initState` 也直接调用一次。
- 违反：第 24 条（按需计算）、第 25 条（无节流）
- 后果：连续切歌/连播时，每首歌都触发一次 Hive 读 + 整页重建，播放中滑动音乐库会周期性卡顿。

---

# 六、未验证观察（不计入统计，供后续实测）

1. **榜单只保留一个 hash**：`RankSong.hash` 取 `hash_128 ?? hash_320 ?? hash_flac`，下载/播放时另传 `quality`。若 `trackercdn /v5/url` 按 hash 的档位返回（而不是按 quality 参数），榜单来源的歌曲选「无损」只会得到 128k。`docs/api_verified.md` 未覆盖「hash 与 quality 的组合语义」，故不作为结论。
2. **QR 登录后 t1 的来源**：`login/qr/check` 的直连实现只回写 token/userid；若上游 `data` 不含 t1，则冷启动 `login/token` 会失败（见认证域 t1 结论）。缺 `login/qr/check` 成功样本。
3. **`/login/cellphone` 多账号（20034）返回体**：`loginBySms` 从 `data['data']['users'] ?? data['users']` 取列表，无实测留样；形态不符时多账号选择器永远不弹，用户看到「登录失败」。
4. **`verify/user/info` 成功响应**：无留样（见上）。
5. **`captcha/sent` 是否必须 http**：无 Node 源码对照结论，无法判定是上游硬约束还是实现失误。
6. **`/comment/music/send` 等写接口的成功语义**：`_wrap` 对 `err_code` 有统一处理，但写接口返回体（是否只回 `err_code:0`、是否带 `data`）无留样；一旦写通（修掉路由后）仍需逐端点确认。
7. **`library_page._playRecent` 传 `albumId: ''`**：`KgPlayApi.songUrl` 是否需要 album_id 才能取 VIP/付费曲地址未实测；若需要，「最近播放」点播付费曲会失败而下载入口正常。

---

# 七、问题清单

## P1（4）

| # | 位置 | 问题 | 条款 | 用户后果 |
|---|---|---|---|---|
| 1 | `kg_direct_api_client.post()` | 评论 send/reply/del 三个 case 只在 get switch 中，Repository 用 post → 全部 -404 | 28 / 3 / 27 | 发评论、回复、删评论全部弹出「接口尚未移植」，评论功能只剩只读 |
| 2 | `download_provider._run()` + `download_task.id` | tempPath 与任务 id 均不含音质，同曲重下共用临时文件 | 21 / 23 / 18 | 同曲换音质重下时文件被并发交错写坏，显示成功但播放爆音/截断 |
| 3 | `download_provider._run()` + `public_media_store._publishDirect` | 发布前先删旧文件，且直接覆盖写无原子性 | 21 / 5 | 重新下载失败后旧的好文件已被删，音乐库里只剩半截文件 |
| 4 | `kg_endpoints_auth.captchaSent` | 手机号经 `http://` 明文提交，且无原因记录 | 31（安全类） | 公共 Wi-Fi 下手机号可被嗅探，短信登录用户 PII 泄露 |

## P2（34）

| # | 位置 | 问题 | 条款 |
|---|---|---|---|
| 1 | `download_provider.onProgress` | 每次进度整表复制 + Hive 写盘，无节流 | 25 / 26 |
| 2 | `download_repository.downloadFile` | 无 Range/续传，重试从 0 开始 | 21 / 5 |
| 3 | `download_provider._strategy` | 策略切换无日志无提示，同批任务落两处 | 11 / 9 |
| 4 | `download_provider.remove` / 完成清理 | `catch (_) {}` 空捕获 | 6 / 7 |
| 5 | `public_media_store.publish` | `finalize` 返回值不校验 | 9 / 14 / 29 |
| 6 | `public_media_store.mimeOf` | MIME 恒 audio/mpeg，与真实扩展名不符 | 23 / 1 / 15 |
| 7 | `public_media_store.tempDir` / `remove` | 临时目录无启动回收，且删除路径规则与写入不一致 | 25 / 1 |
| 8 | `download_task.id` / `hasAudio` | 已下载判定忽略音质 | 23 / 16 |
| 9 | `auth_repository.getDfid` | 空捕获返回 '' | 6 / 9 / 16 |
| 10 | `auth_repository` 多处 | `as Map<String,dynamic>?` 裸强转外部 data | 13 / 10 |
| 11 | `auth_repository.restoreSession` | 三层 catch、降级触发条件不明 | 8 / 7 / 11 / 10 |
| 12 | `auth_repository._isTokenInvalidCode` | 用错误文案 contains('token') 判失效 | 8 / 2 |
| 13 | `auth_repository._handleLoginSuccess` | t1 内存保留/磁盘删除，冷启动刷新失败 | 5 / 20 |
| 14 | `auth_repository._handleLoginSuccess` | 昵称/头像三处副本，写入点不一致 | 5 |
| 15 | `auth_repository.loginByPassword` | `data?['data']?['ssaCode']` 对 dynamic 下标 | 13 / 3 |
| 16 | `login_page._sendCode` | 无请求中互斥，可并发发码 | 21 / 19 |
| 17 | `login_page._QrLoginTab` | 轮询空捕获、固定 3s、后台不停 | 6 / 9 / 25 / 20 |
| 18 | `login_page._loadQr` | key 为空仍轮询 | 14 / 16 / 3 |
| 19 | `verification_service.submit` | 成功判定未实测留样 | 29 / 3 |
| 20 | `verification_service.submit` | 一切 ApiException 记作「验证未通过」 | 8 / 9 |
| 21 | `captcha_page._load` | 无过期/重载，重试复用同一 eventid | 11 / 3 |
| 22 | `captcha_page._buildSms` | 无发送/重发验证码入口 | 3 / 11 |
| 23 | `captcha_page._buildTencent` | WebView 失败无反馈（空 ticket 静默） | 9 / 6 |
| 24 | `captcha_page` 全页 | 硬编码中文未走 l10n | 30 / 1 |
| 25 | `comments_page._send` | 无提交锁 + 先清空输入，可重复评论/丢内容 | 21 / 9 |
| 26 | `comments_page._commentsProvider` | 非 autoDispose family，评论列表常驻 | 25 / 20 |
| 27 | `comments_page.load/loadMore` | 刷新与加载更多失败静默 | 6 / 9 |
| 28 | `comments_page` / `comment_floor_page` | `ref.read(authStateProvider)` 在 build 中判登录 | 5 / 18 |
| 29 | `comment_floor_page._load/_loadMore` | 无世代校验，刷新与翻页并发串数据 | 18 / 5 |
| 30 | `comment_floor_page._send` | 无 20028 分支，直接展示 `$e` | 8 / 9 |
| 31 | `mv_provider.mvDetailProvider` | 失败返回 null，三种语义合并 | 6 / 9 / 16 |
| 32 | `mv_player_page._resolve` | `_resolving` 静默丢弃切档点击 | 22 / 9 |
| 33 | `library_page` 三区块 | 60 个条目一次性构建（非惰性） | 24 / 26 |
| 34 | `library_page._currentAccount` | 登录态与其它页来源不同（Hive vs authState） | 5 / 16 |

## P3（16）

| # | 位置 | 问题 | 条款 |
|---|---|---|---|
| 1 | `download_provider.downloadRepositoryProvider` | provider 内 new MvRepository/Dio，超时魔法值 | 2 |
| 2 | `download_repository.resolveAudioExt/resolveAudioUrl` | 三份重复实现 + 一处静默返回 '.mp3' | 32 / 1 / 8 |
| 3 | `download_repository.downloadFile` | 无磁盘空间前置校验 | 25 / 3 |
| 4 | `download_page` / `download_provider` | `PublishedFile(...)` 5 处重复展开，path 字段装 uri | 15 / 1 |
| 5 | `download_sheet.buildTask` | 用 `!= q128` 推断「歌曲自带音质」 | 16 / 2 |
| 6 | `download_sheet._OptionTile` | failed/paused 仍显示下载按钮；「全部下载」不含 MV | 16 / 2 |
| 7 | `auth_repository` 默认构造 | 裸 `KugouApiClient()` 指向 kapi | 2 / 27 |
| 8 | `secure_storage` / `account_manager.clear` | `acct_token_*` 永不清理 | 20 / 25 |
| 9 | `captcha_page.typeHint` | 从未使用的字段 | 32 |
| 10 | `captcha_page._buildSms` | maxLength 8 vs 文案 6 位 | 3 |
| 11 | `rank_repository.fetchRankSongs` | 冗余 `as Map<String,dynamic>` | 32 |
| 12 | `rank_repository.fetchRankSongs` | total 回落 songs.length | 16 |
| 13 | `mv_repository.resolvePlayUrl` | `d.values.first` 兜底 + backup 非 String 造非法 URL | 11 / 13 |
| 14 | `mv_player_page.build` | build 内 addPostFrameCallback 改系统 UI | 24 / 26 |
| 15 | `mv_player_page` | 无 controller listener，播放态不刷新；错误原文直出 | 5 / 9 |
| 16 | `library_page` | `_currentAccount` 空捕获；账号变化全页重建；最近播放重复 IO | 6 / 26 / 24 |

---

# 八、统计

| 级别 | 数量 | 主要分布 |
|---|---|---|
| P0 | 0 | — |
| P1 | 4 | 评论写接口路由缺失 1、下载同名并发与先删后写 2、手机号明文传输 1 |
| P2 | 34 | 下载 8、认证 16、评论 6、MV 2、音乐库 2 |
| P3 | 16 | 下载 6、认证 4、榜单 2、MV 3、音乐库 1 |
| 合计 | 54 | 覆盖 14 个源文件（+6 个为验证条款补读的上下文文件） |

按条款分布（同一问题多条款时重复计数，共 114 次引用）：

| 条款 | 次数 | 条款 | 次数 |
|---|---|---|---|
| 第 9 条 失败可观测 | 12 | 第 5 条 状态单一来源 | 8 |
| 第 3 条 契约先行 | 8 | 第 16 条 空集合语义分离 | 8 |
| 第 6 条 禁止吞异常 | 7 | 第 2 条 显式优于隐式 | 5 |
| 第 25 条 资源上限 | 6 | 第 1 条 单一职责 | 5 |
| 第 8 条 异常契约 | 5 | 第 11 条 降级条件 | 5 |
| 第 21 条 写操作防重 | 5 | 第 20 条 生命周期对称 | 4 |
| 第 26 条 热路径 | 4 | 第 13 条 裸强转 | 3 |
| 第 18 条 世代校验 | 3 | 第 23 条 键覆盖维度 | 3 |
| 第 24 条 惰性构建 | 3 | 第 32 条 死代码 | 3 |
| 第 27 条 原生网关 | 2 | 第 29 条 实测留样 | 2 |
| 第 7 条 精确捕获 | 2 | 第 10 条 编程错误不降级 | 2 |
| 第 14 条 边界校验 | 2 | 第 15 条 单位/语义显式 | 2 |
| 第 22 条 并发假设 | 1 | 第 19 条 互斥闸门 | 1 |
| 第 28 条 调用方式实测 | 1 | 第 30 条 命名/文案 | 1 |
| 第 31 条 注释解释为什么 | 1 | | |

> 未引用条款：第 4/12/17 条（本批范围内未发现符合该三条判定的事实，不强行凑数）；
> 第 12 条（无依据非空断言）在 `download_task.fromJson` 的 `is int` 分支内已同函数体证明，不计问题。

## 结论

- 下载域的问题集中在**并发标识维度**与**发布原子性**：同一首歌换音质会共用临时文件（P1），重新下载会先删掉旧文件（P1），断点续传只停留在字段层面，磁盘缓存没有全局回收点。
- 数据层与直连层的**方法契约断裂**是本批唯一「功能整块消失」的缺陷：评论写入的三个 case 只挂在 get 分支，Repository 全部走 post，用户侧看到的是「接口尚未移植」。
- 认证域的主要风险不是加密（密码已 AES+RSA，token 存 SecureStorage 合规），而是**降级与状态同步**：t1 内存/磁盘不一致会让 QR 用户每次冷启动掉登录；短信验证码走明文 HTTP 是当前唯一的 P1 安全项。
- 音乐库与 MV 属于**产品完整度**问题：MV 清晰度在只有 hash 的入口恒不可用，音乐库首帧一次性构建 60 条。
