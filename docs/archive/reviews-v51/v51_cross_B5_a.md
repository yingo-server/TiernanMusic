# v5.1 交叉审查·第 B5 批·视角 A（功能正确性）

审查人：代理 A。范围：12 个通读文件（✅）+ 跨文件契约抽查（○，≤8 个）。
判定依据：`docs/QUALITY_STANDARD.md`（33 条）与 `docs/REVIEW_SPEC.md`。
基线：B3 修复后当前磁盘状态。实时逐文件 append。

---

## album_repository.dart（166 行，通读 ✅）

dart analyze：见文末汇总表。

### album_repository.dart:96-99 fetchDetail 与 fetchSongs 读取参数形态不一致（json:true）
- 级别：P2
- 违反：第 28 条（调用方式逐一实测、不得推测）+ 第 8 条（同一层契约单一稳定）
- 依据：`fetchDetail` 调 `_reads.get('/album/detail', query:…, json: true)`，而 `fetchSongs` 调 `_reads.get('/album/songs', query:…)` 不带 `json` 参数；同文件同 Repository 两个端点使用不同读取形态，且无注释说明 `/album/detail` 为何需要 `json:true`。
- 影响：若 `json:true` 对该端点是错误形态，直连请求参数与上游期望不一致，可能直连假失败并落入回退/空数据路径；若不是，则两处口径不一致使后续维护者无法判断哪个是基准形态。
- 证据等级：静态推演（需对照 `repository_reads.dart` 的 json 参数语义与实测留样复核）。

### album_repository.dart:36 AlbumInfo.fromJson 在 data 缺失时回退到整个响应体 j
- 级别：P2
- 违反：第 16 条（空集合与缺失语义分离）+ 第 11 条（降级需明确触发/退出条件）
- 依据：`final Map d = raw is List && … ? raw.first : (raw is Map ? raw : j);` —— 当 `data` 既非数组也非 Map（如上游返回错误体 `{status:0, error_code:…}`）时，直接把错误响应体当专辑信息解析，各字段静默为 ''/0。
- 影响：专辑详情接口失败时，页面呈现一个「名字为空、封面为空」的专辑而非错误态，用户看到空白详情页且无失败反馈。
- 证据等级：静态推演。

### album_repository.dart:14-33 模型解析对 `data` 为空数组时回退 j（同上分支）
- 级别：P3
- 违反：第 16 条
- 依据：`raw is List && raw.isNotEmpty` 为 false（空数组）时落入 `raw is Map ? raw : j`，即 data=[]（确实无专辑）与 data 缺失（请求失败）被同等对待，均回退解析响应体顶层。
- 影响：「确实为空」与「失败」未分离。
- 证据等级：静态推演。

复核通过项（本文件）：
- `AlbumSong.fromJson` 对嵌套结构（base/audio_info/album_info/authors/mvdata）全部做 `is Map`/`is List` 分支校验，无裸强转（第 13/14 条到位）。
- `duration` 毫秒单位在注释中显式声明（第 15 条）。
- Repository 注入 `kugouApiClientProvider`，未 new 裸客户端。
- 过滤 `hash.isEmpty` 条目，避免空 hash 歌曲进入下游。

## artist_page.dart（517 行，通读 ✅）

dart analyze：见文末汇总表。

### artist_page.dart:100-129 _loadSongs 失败后 `_page` 不回退且加载更多失败无「失败态」入口
- 级别：P2
- 违反：第 9 条（失败必须可观测）+ 第 16 条（失败与空态语义分离）
- 依据：catch 分支设 `_songsError = e`，但 `_buildSongs` 只在 `_songsError != null && _songs.isEmpty` 时显示重试。第 1 页成功、第 2 页失败时列表无任何失败提示。
- 影响：分页中途网络抖动时，用户看到列表「停止增长」且无任何错误提示，以为歌手只有这些歌。
- 证据等级：静态推演。

### artist_page.dart:185-186 `_infoName` 在 build 中被赋值（build 期间修改实例状态）
- 级别：P3
- 违反：第 22 条 + 第 24 条（build 应为纯函数，不含状态变更）
- 依据：`FutureBuilder` builder 内 `_infoName = info.name;` —— builder 可能一帧多次调用，属于在构建路径上写实例字段。
- 影响：无直接用户可见故障（waiting 态下无歌曲列表），属隐式跨帧通信；P3 整洁度。
- 证据等级：静态推演。

### artist_page.dart:131-141 _loadAlbums 失败时把错误吞成空态并永久标记 `_loadedAlbums = true`
- 级别：P2
- 违反：第 6/9 条（异常被吞、失败不可观测）+ 第 11 条（降级无退出条件）
- 依据：`catch (_) {}` 空 catch 且成功与失败分支都设 `_loadedAlbums = true`，触发条件 `if (i == 1 && !_loadedAlbums)` —— 专辑请求失败后之后切 tab 永远不会再尝试加载。
- 影响：专辑 tab 一次网络失败后永久显示「暂无专辑」空态，重进页面才有机会恢复；失败原因对用户与日志均不可见。
- 证据等级：静态推演。

### artist_page.dart:459 `_fans` 万位以下直接拼 `$n`
- 级别：P3
- 违反：第 30 条/17（格式化口径一致性）——轻微
- 依据：≥10000 显示 `x.xw`，<10000 显示原始数字，边界呈 1.0w / 9999 双口径，产品口径问题非缺陷。
- 影响：轻微显示口径不统一。
- 证据等级：静态推演。

复核通过项（本文件）：
- `_songsGen` 世代号校验在 await 后正确执行，排序切换/刷新作废在途请求（第 18 条到位，注释明确）。
- `dispose` 中 `_scroll.removeListener + dispose`、`_tab.dispose` 成对（第 20 条）。
- `_loadSongs` 分页防重：`_loadingMore || _loadingSongs` 双闸；`_total` 上限判断（第 25 条）。
- 三态分离清晰：loading / error / empty。
- 滚动路径无大对象分配（第 26 条）。

## auth_repository.dart（418 行，通读 ✅）

dart analyze：见文末汇总表。

### auth_repository.dart:53-54 `AuthRepository` 构造默认 `KugouApiClient()`（裸构造，REVIEW_SPEC 架构口径）
- 级别：P2
- 违反：REVIEW_SPEC 三.1「Repository 不得 new 裸 KugouApiClient()」+ 第 2 条（显式优于隐式）
- 依据：`_api = api ?? KugouApiClient()`。裸构造的客户端 baseUrl 为 kapi（B1 裁决注释已澄清：运行期经 Provider 注入直连子类）。契约抽查确认：`authRepositoryProvider` 已注入 `kugouApiClientProvider`（生产路径无违纪）；默认构造仅测试/误用可达。
- 影响：潜在 kapi 主路径违纪（生产装配已排除，实际风险限于误用）。
- 证据等级：静态推演。

### auth_repository.dart:86 sendSmsCode 无任何结果校验
- 级别：P2
- 违反：第 28/29 条
- 依据：`await _api.get('/captcha/sent', query: {'mobile': mobile});` 不检查返回体；裸 Map 无 status 字段时 evaluateResponse hasStatus 守卫按数据放行（B2 修复后行为），发送失败会被当成功。
- 影响：验证码发送失败（手机号格式错、频率限制）时 UI 显示「已发送」，用户等短信永不来。
- 证据等级：静态推演（需对照该端点实测留样确认成功判定口径）。

### auth_repository.dart:92-110 loginBySms 多账号判定 `err.message.contains('多个')` 依赖中文错误文案
- 级别：P2
- 违反：第 3 条（契约必须可枚举）+ 第 13 条
- 依据：`if (err.errorCode == 20034 || err.message.contains('多个'))` —— 用错误消息中文子串做分支条件，上游文案一变分支即失效。
- 影响：上游文案改动时，多账号归属用户的短信登录直接抛错而非进入账号选择页，登录功能失效。
- 证据等级：静态推演。

### auth_repository.dart:186-195 checkQr 状态码解析默认值 1（待扫）
- 级别：P2
- 违反：第 16 条
- 依据：`int.tryParse('${d['status'] ?? d['error_code'] ?? 1}') ?? 1` —— 响应缺 status/error_code 或非数值时默认「待扫」继续轮询；`d['data'] ?? res` 回退顶层与 status 从 `error_code` 回退两套字段名，无实测来源注释。
- 影响：响应形态漂移时扫码登录假死（一直转圈直至二维码过期），无错误反馈。
- 证据等级：静态推演。

### auth_repository.dart:39-49 getDfid 空 catch 吞掉网络异常且失败返回 ''
- 级别：P3
- 违反：第 6/9 条（空 catch 完全无留痕）
- 依据：`catch (_) {}` 无日志；注释解释了「不落盘」的理由，但 `loginByToken` 链路中 dfid='' 会被 saveCredentials 持久化（与 getDfid「失败不落盘」的意图相反）。
- 影响：断网登录时凭证文件 dfid=''，行为可自愈；但空 dfid 落盘与注释意图不一致，失败不可观测。P3。
- 证据等级：静态推演。

### auth_repository.dart:310-323 logout 中 `readCredentials` 失败将使登出整体抛出
- 级别：P2
- 违反：第 20 条（生命周期双向对称）
- 依据：`logout` 首行 `await _storage.readCredentials()` 无 try/catch（restoreSession 特意为 Keystore 故障机型包了防护，此处未包）。Keystore 故障机型上抛出 → 后续清理全部未执行，登出中断且无兜底。
- 影响：Keystore 故障机型（restoreSession 注释称「实测常见」）用户点退出登录可能一直失败，无法登出也无法切换账号。
- 证据等级：静态推演（与同文件 285-291 注释自相矛盾：同一故障源一处理由防护、一处裸调）。

复核通过项（本文件）：
- `restoreSession` 对 Keystore 读凭证失败防护 + 留痕（V35-A3），网络错误不清凭证走 `_degradedUser`（第 18/11 条到位）。
- `_isTokenInvalidCode` 显式排除参数性 20010，防止误清有效会话。
- 20028 → `CaptchaRequiredException` 的 ssaCode 提取三路兜底（A2-01 修复到位）。
- 登录落盘并行化注释解释「为什么」，主路径 await、副产物失败留痕不阻塞（第 9 条）。
- `logout` B-11 修复：普通登出删切换 token、dfid 写入/清除对称。
- `CaptchaRequiredException`/`MultiAccountException` 异常类型可枚举（第 8 条）。

## verification_service.dart（98 行，通读 ✅）

dart analyze：见文末汇总表。

### verification_service.dart:23-27 getVerifyInfo 不校验返回形态即进 VerifySession.fromJson
- 级别：P2
- 违反：第 13/14 条
- 依据：直接 `VerifySession.fromJson(ssaCode, data)`，未确认含有效 v_type/url。契约抽查确认 captcha_types.dart 的 fromJson 有兜底（vType 非数值降级 -1）；但 vType<=0 时 submit 用 `vType > 0 ? vType : 23` 猜默认验证类型提交。
- 影响：eventid 过期/接口变更时，用户走完验证流程提交的却是错误的 v_type（硬编码 23），验证静默失败并可能循环弹出。
- 证据等级：静态推演。

### verification_service.dart:80-89 submit 成功判定三路 or 口径过宽
- 级别：P2
- 违反：第 29 条
- 依据：`ok = status == 1 || status == '1' || (data.data.codeDesc 下缀 == 'success')`。第三路把「有 codeDesc=success 但 status 不是 1」判成功；混合判定无注释给出实测依据。
- 影响：若上游某失败分支也带 codeDesc 字符串（或字段名大小写漂移），提交失败被判成功，用户以为已通过验证但原请求仍 20028。
- 证据等级：静态推演（口径正确性需原生留样复核；kapi 包装结果不可作为依据，第 33 条）。

### verification_service.dart:91-95 DioException→false 与网络异常形态不一致
- 级别：P3
- 违反：第 8 条
- 依据：`if (e.error is ApiException) return false; rethrow;` —— ApiException（含参数错误）一律「未通过」，纯网络断连则 rethrow；无日志留痕区分。
- 影响：验证接口 20010（sid/edt 生成参数错误）与真实滑块错误对用户不可区分。
- 证据等级：静态推演。

复核通过项（本文件）：
- mid 权威来源切到 KgDevice、缺失降级 '0' 有注释说明理由。
- verify/user/info 参数双放 body+query 有 Node 源码行号引用（实测纪律到位）。
- edt 生成走 EdtGenerator 封装（第 1 条）。

## login_page.dart（740 行，通读 ✅）

dart analyze：见文末汇总表。

### login_page.dart:710-718 轮询失败完全静默（catch (_) 空处理）且无连续失败上限
- 级别：P2
- 违反：第 9 条 + 第 25 条
- 依据：`_checkOnce` catch (_) 「轮询失败忽略，下次再试」——网络断开时轮询每 3 秒持续打点、UI 恒显示「待扫」，无失败提示；无连续失败计数/降级策略。
- 影响：弱网用户拿着过期二维码等待，状态文案从不更新，也无「网络异常」提示；无限轮询打点。
- 证据等级：静态推演。

### login_page.dart:399-401 CaptchaRequiredException 重试为无条件递归 _login()
- 级别：P2
- 违反：第 21 条 + 第 11 条
- 依据：验证成功后 `if (ok == true && mounted) { await _login(); return; }` 无重试次数限制；若服务端再次返回 20028 将形成「验证→重试→再 20028」循环，每轮都弹验证页。
- 影响：极端情况下用户陷入验证循环；至少多弹一轮验证页，无收敛提示。
- 证据等级：静态推演。

### login_page.dart:207-239 _login 递归 userid 选择未重新校验验证码有效期
- 级别：P3
- 违反：第 22 条
- 依据：多账号选择后 `_login(userid: chosen)` 复用 `_codeCtrl` 中旧验证码；停留期间验证码可能已过期，重试得到验证码错误（有错误提示兜底）。
- 影响：轻微多一次失败往返。P3。
- 证据等级：静态推演。

### login_page.dart:52-58 _onLoginSuccess 仅 pop 一层
- 级别：P3
- 违反：无明确条款（轻微契约）
- 依据：注释自述「pop 失败（理论不可达）时回落 /home」；pop 后回到的页面若依赖登录态刷新，依赖各页面自身监听 authStateProvider（main.dart 全局监听已核实存在）。
- 影响：依赖全局监听正确性；本身无可见缺陷。
- 证据等级：静态推演。

复核通过项（本文件）：
- `_showError` 统一 unwrapApi 解包，技术串不上屏（A2-07 修复到位）。
- `_QrLoginTab` 轮询自驱动防请求重叠；`didUpdateWidget` 按 active 启停、dispose cancel，定时器生命周期对称（第 20/18 条）。
- `AutomaticKeepAliveClientMixin` + super.build(context) 正确。
- 扫码成功≠登录成功，token 换登录失败单独 catch 并提示（第 16 条语义分离到位）。
- base64 解码 try/catch + data: 前缀兼容 + 错误态刷新入口（第 14 条）。
- 控制器/计时器 dispose 成对。

## comment_repository.dart（279 行，通读 ✅）

dart analyze：见文末汇总表。

### comment_repository.dart:57-78 sendComment 预查 specialChildId 的额外往返与失败静默
- 级别：P2
- 违反：第 26 条（写路径多一跳网络）/ 第 9 条（catch (_) 静默）
- 依据：发歌评前先 `fetchComments(pageSize:1)` 取首条评论的 specialChildId；查询失败 `catch (_) {}` 无留痕。注释给出 Node 源码依据，但「取第一页第一条」与 Node「用 mixsongid 查 specialChildId」的语义是否一致未见留样引用。
- 影响：每次发歌评多一次网络往返（慢网发送延迟翻倍）；预查失败时 childrenId=id 兜底被静默走，发送结果取决于服务端兜底行为，失败不可归因。
- 证据等级：静态推演。

### comment_repository.dart:84-98 写操作（send/sendFloorReply/deleteComment）无本地提交锁
- 级别：P1
- 违反：第 21 条
- 依据：三个写方法直接 `_api.post(...)` 返回，无 in-flight 闸门；B2 merged 待核实项——本视角核实：**本文件内无任何防重**。契约抽查确认防重仅存在于 comments_page 的 `_sending` UI 闸门（单一入口）；数据层可被并发调用（其他入口/非 UI 路径），post 失败重试无幂等键。
- 影响：双击发送/自动重试/其他入口场景下重复发评论（真实重复提交，P1 口径）；UI 主路径有闸但数据层契约缺口。
- 证据等级：静态推演。

### comment_repository.dart:103-119 deleteComment 对非歌曲类型仅换 resource_type
- 级别：P2
- 违反：第 28 条
- 依据：path 固定 `/comment/music/del`，歌单/专辑删除仅靠 `resource_type` 区分 code；而发送端点是**三个不同路径**。删除路径复用歌曲删除端点是否为上游真实形态未注释来源。
- 影响：歌单/专辑下删除自己的评论可能静默失败（评论仍在），或服务端报错。
- 证据等级：静态推演（需原生实测留样）。

### comment_repository.dart:187-191 CommentPage total 的 fallback 口径
- 级别：P3
- 违反：第 16 条
- 依据：`_asInt(count ?? total ?? comments_num ?? str_count, fallback: comments.length)` —— 四字段名兜底链无来源注释；fallback 用本地页长度使「总数未知」折叠为「本页数量」。
- 影响：字段漂移时分页判断提前截停或次数错。
- 证据等级：静态推演。

复核通过项（本文件）：
- fetchFloor 强制传 resource_type 且注释说明 err_code=60102 后果（第 31 条到位）。
- 零评论歌曲 childrenId=mixsongid 兜底修复有完整因果注释（V34-04）。
- like 对象形态解析修正有实测注释；`{size}` 占位替换处理。
- isMine 双字段名兜底 + currentUserId 优先，语义明确。
- 枚举 switch 分发路径，无字符串魔法分支散落。

## download_repository.dart（302 行，通读 ✅）

dart analyze：见文末汇总表。

### download_repository.dart:63-124 resolveAudioDownloadSource 试听/高潮片段声明字节数直接比较（B2 遗留确认）
- 级别：P2
- 违反：第 29 条
- 依据：`climaxBytes = preview.offsetFileSize` 与 `trialBytes = preview.previewFileSize` 直接比较择长，两字段是否同语义（声明字节数 vs 区间字节数）决定选择正确性；代码无注释给出两者实测留样出处。
- 影响：若语义不同，非 VIP 下载的「高潮片段」可能实际比试听片段更短，用户拿到更小的音频文件而无感知。
- 证据等级：静态推演（需对照 v3.9.9 B4 实测留样）。

### download_repository.dart:126-138 _urlAndExt 扩展名推断失败默认 .mp3
- 级别：P3
- 违反：第 30/9 条（猜测无留痕）
- 依据：audioExts 匹配失败时用 URL 正则回推，仍失败则 `'.mp3'` 硬编码，无日志。
- 影响：扩展名猜错导致文件后缀与内容不符（播放器多数可容错），轻微。
- 证据等级：静态推演。

### download_repository.dart:141-167 downloadFile 重试间隙的半截文件
- 级别：P2
- 违反：第 21/14 条
- 依据：receiveTimeout 中途断后重试，Dio 重开写入文件本身最终一致；但重试间隙 savePath 上存在半截文件，且失败终止时残留（依赖 publish 链 .part 机制兜底——契约抽查确认发布走独立临时目录与 .part 原子替换，风险主要落在「失败任务后手动检查文件」场景）。
- 影响：任务失败/取消时临时文件残留半截内容，直到下次发布或 remove 清理。
- 证据等级：静态推演。

### download_repository.dart:222-235 downloadLyric 的 onProgress 语义伪造
- 级别：P3
- 违反：第 15/17 条
- 依据：`onProgress?.call(content.length, content.length)` —— 字符数冒充字节数、received=total（100%），与 downloadFile 的字节语义不同；翻译等待期间进度 0、瞬间跳 100%。
- 影响：UI 进度对歌词任务瞬间满格，轻微体验失真。
- 证据等级：静态推演。

### download_repository.dart:196-201 downloadCover 只是 downloadFile 别名
- 级别：P3
- 违反：第 32 条/第 1 条
- 依据：纯转发无附加逻辑。
- 影响：无功能影响，纯冗余封装。
- 证据等级：静态推演。

复核通过项（本文件）：
- Dio 超时双档有注释理由；4xx 不重试、5xx/网络错误指数退避（第 11/25 条）。
- cancelToken.isCancelled 先于重试判断（第 19 条）。
- 高潮片段解析失败留痕回落试听（第 9 条，V399-B4）。
- displayNameOf 非法字符/尾部点空格清洗 + realTempPath 扩展名覆盖（V35-B3 P1 修复到位）。
- 依赖注入可选 + StateError 显式消息（未初始化即暴露，第 10 条）。

## public_media_store.dart（324 行，通读 ✅）

dart analyze：见文末汇总表。

### public_media_store.dart:97-103 publish 的 MediaStore insert 调用本身无 try/catch
- 级别：P2
- 违反：第 6/8 条
- 依据：`_channel.invokeMethod<String>('insert', …)` 在 try 之外（try 从 write 步骤才开始）。PlatformException 直接抛给 DownloadRepository，而 insert 成功后的 write/finalize 失败才走降级。同一「MediaStore 不可用」事实在两条路径上一条降级、一条抛错。
- 影响：insert 阶段失败时下载任务报错而非退回直写路径，与其他降级行为不一致；部分机型下载必失败而其他机型正常。
- 证据等级：静态推演。

### public_media_store.dart:97-103 insert 返回 null/empty 走直写时未删已插条目
- 级别：P3
- 违反：第 20 条
- 依据：`uri == null || uri.isEmpty` 时直接 `_publishDirect`，Kotlin 层 insert 可能已产生 pending 条目却返回空串（未注释）；对照 finalize false 分支显式 delete，此分支未删。
- 影响：极小概率残留 pending 条目，7 天后系统自动清理；P3。
- 证据等级：静态推演（依赖原生 insert 返回语义）。

### public_media_store.dart:255-273 queryExisting Android 10+ 查询失败静默返回 null
- 级别：P2
- 违反：第 9/16 条
- 依据：`catch (_) {}` 后 `return null` —— 「已下载判定」在 channel 异常时恒 null，调用方把已下载歌曲判为未下载，触发重复下载与重复发布（第 21 条防重失败的现实入口）。无留痕。
- 影响：已下载文件在异常态被重复下载并再次发布，磁盘出现重复文件副本（与 download_provider:351 交叉印证）。
- 证据等级：静态推演。

### public_media_store.dart:287-296 delete 失败静默返回 false
- 级别：P3
- 违反：第 9 条
- 依据：catch (_) 直接 return false，无 debugPrint。
- 影响：删除失败用户无感知原因。
- 证据等级：静态推演。

复核通过项（本文件）：
- .part 原子替换写法正确（V37-04 修复说明准确），失败清 part 且旧文件不动（第 21/20 条到位）。
- write/finalize 每个失败分支都先 delete pending 再降级（注释给出 pending 7 天清理周期依据）。
- mimeOf 按真实扩展名映射（V35-B3 修复到位）；collectionOf lyrics 用 files collection 有依据注释。
- resolveRoot 统一根路径（V399-B2），注释解释原缺陷。
- queryExisting <29 路径与 _publishDirect 子目录推导同源。

## download_sheet.dart（215 行，通读 ✅）

dart analyze：见文末汇总表。

### download_sheet.dart:41-50 buildTask 音质判定 `song.quality != AudioQuality.q128` 的魔法基准
- 级别：P2
- 违反：第 2 条 / 第 3 条
- 依据：语义是「song.quality 为默认占位 q128 时用用户偏好」，把「未知/默认」编码成「等于 q128」。一首真实 128kbps 的歌同样触发该分支，被静默升级为用户偏好音质下载。
- 影响：128k 免费歌下载音质被偷换为偏好档；若偏好档为 VIP 音质，非 VIP 用户拿到的反而是试听片段而非完整 128k 全曲。
- 证据等级：静态推演（取决于 Song.quality 默认值语义是否与「未知」复用同一档位）。

### download_sheet.dart:60-65 audioTask 与其余三类用两条查询路径
- 级别：P3
- 违反：第 5 条（轻微）
- 依据：同一「按 hash+type 查任务」存在 manager 方法与本地线性扫描两条路径；`_taskOf` 在 build 中遍历 3 次（任务列表小，非热路径）。
- 影响：无功能缺陷，两套查询并存易漂移。
- 证据等级：静态推演。

### download_sheet.dart:113-121 downloadAll 后 addAll 异常时弹层不关闭
- 级别：P3
- 违反：轻微
- 依据：`await manager.addAll([...])` 无错误处理——若 addAll 抛出，pop 不执行，弹层卡住但任务可能已部分加入。
- 影响：轻微；依赖 download_provider.add 的契约（抽查确认 add 内部捕获任务级错误，风险低）。
- 证据等级：静态推演。

复核通过项（本文件）：
- MV 可得性预判 + 禁用原因说明（V37-UI-09，第 16 条三态分离到位）。
- 进度条仅 running/paused 态显示，状态视觉映射清晰。
- 48dp 触控区显式约束（V37-UI-05）。
- onDownload 统一走 manager.add/addAll，UI 不直接触达 Repository（第 4 条）。

## playlist_repository.dart（656 行，通读 ✅）

dart analyze：见文末汇总表。

### playlist_repository.dart:233-236 _fetchAllReversed 已知总页数分支：超大歌单 + 小 pageSize 时静默退化为仅首页
- 级别：P2
- 违反：第 17 条（索引/页号精确性）
- 依据：`totalPages = wantedPages`（clamp 到 maxPages=100），`startPage = ceil(trustedTotal/size) - totalPages + 1`。当真实总页数 > maxPages（如 total=30000、pageSize=100 → 300 页）时 startPage=201，循环 `for (p=201; p<301; p++)` 中 `p > maxPages` 全部 `continue` → **除首页外一首歌都抓不到**，结果静默只有首页几十/几百首。
- 影响：歌单超过 1 万首（或 total 大 + pageSize 小）时「全量」结果只剩首页，无任何提示。
- 证据等级：静态推演（构造 total>maxPages×pageSize 场景必然触发）。

### playlist_repository.dart:419-424 _toWriteException 对 badResponse 判 maybeSucceeded=true
- 级别：P2
- 违反：第 11 条
- 依据：badResponse 通常意味着拿到了响应但状态不符（明确拒绝），按类注释口径应为 maybeSucceeded=false。归为 true 使 UI 提示「可能已生效，请刷新确认」。CI 实测注释只针对 transformTimeout，badResponse 并入同行存疑。
- 影响：明确的失败被提示为「可能已生效」，用户误以为成功，刷新后发现没生效。
- 证据等级：静态推演。

### playlist_repository.dart:60-62 fetchUserPlaylists 不走缓存
- 级别：P3
- 违反：第 5 条（轻微）
- 依据：详情与曲目走 `_cached`（90s TTL），`fetchUserPlaylists` 直接 `_api.get`；写后失效对它无意义（反而新鲜），仅口径不统一。
- 影响：我的歌单每次进页都打网络；非缺陷，P3。
- 证据等级：静态推演。

### playlist_repository.dart:527-533 PlaylistSong.fromJson 歌名前缀剥离逻辑两处重叠
- 级别：P3
- 违反：第 30 条/第 1 条
- 依据：开头 `if (sep > 0)` 分支与末尾 artist 空回退各剥离一次前缀，条件重叠可达性靠推演确认，无注释。
- 影响：无直接缺陷，维护风险。
- 证据等级：静态推演。

### playlist_repository.dart:634 UserPlaylist.isMine 判定口径无实测留样
- 级别：P2
- 违反：第 28/29 条
- 依据：`isMine = list_create_type==0 || is_create=='1'` 决定「我的歌单」可否删除/编辑；注释只给字段清单不给判定分支的实测依据。
- 影响：若服务端自建歌单 list_create_type 非 0，我的自建歌单被判非 mine，删除入口消失（或相反他人歌单误判可删）。
- 证据等级：静态推演（需三态留样）。

复核通过项（本文件）：
- `PlaylistWriteException.maybeSucceeded` 契约文档化在类注释（第 3/8 条标杆级）。
- `_write` 防重锁请求发出前拒绝（V37-03 语义修正注释明确）；`finally` 释放配对（第 21/22 条到位）。
- 写操作不回退 kapi（write:true + get 分派），大注释解释为什么（第 27 条纪律标杆）。
- addTracks 分隔符协议边界校验（`|,` 全角替换、hash 缺失拒绝、批次内去重），注释给出字段右移后果（第 14 条到位）。
- 空 listid/空集校验 + 明确异常（第 14 条）。
- 单页失败留痕跳过不中断、探测失败连续 3 页上限、maxPages 上界（第 9/25 条）。
- PlaylistDetail 空 data 显式抛 ApiException（数字 specialid 场景）（第 16 条）。
- 写后 `_invalidatePlaylistCaches` ns 精确失效（第 5 条）。
- timelen 毫秒/秒换算显式注释（第 15 条）。

## search_repository.dart（327 行，通读 ✅）

dart analyze：见文末汇总表。

### search_repository.dart:230-242 fetchHotSearch / fetchSuggest 空 catch 吞掉所有失败返回空列表
- 级别：P2
- 违反：第 6/9/16 条
- 依据：`catch (_) { return const []; }` —— 网络断开/接口 500 与「热搜为空」都返回空列表；无任何 debugPrint。对比 playlist 同期实现的留痕纪律，此处倒退。
- 影响：断网时搜索页热搜/建议板块静默消失，线上问题无法定位。
- 证据等级：静态推演。

### search_repository.dart:297-300 getHistory/addHistory 的 clear+addAll 窗口
- 级别：P3
- 违反：第 22 条
- 依据：`addHistory` 读全部 → remove → insert(0) → clear → addAll，clear 与 addAll 之间并发写会丢条目。搜索历史并发概率低（UI 串行）。
- 影响：极小概率丢历史条目；P3。
- 证据等级：静态推演。

### search_repository.dart:163-170 _mvItem cover 硬编码 http:// 前缀
- 级别：P3
- 违反：第 28 条（需留样确认域名与明文）
- 依据：`'http://imge.kugou.com/mvthumb/{size}/$pic'` —— `{size}` 占位由 kugouImageUrl 下游替换（契约依赖），http 明文（Android 9+ 默认禁明文流量）。
- 影响：MV 封面可能加载失败或依赖重定向；P3。
- 证据等级：静态推演。

### search_repository.dart:88-92 _totalOf 返回 -1 表示「未知总数」
- 级别：P3
- 违反：第 3 条（-1 魔数语义无注释指向消费方）
- 依据：注释解释兜底意图，但 `-1` 作为 SearchResult.total 的语义需每个消费方理解；若消费方用 `items.length >= total` 判断停页则语义错位。
- 影响：取决于消费方处理（search_page 未逐行核对该分支），语义隐式。
- 证据等级：静态推演。

复核通过项（本文件）：
- V400-B-04 读接口统一 ResourceCache（kListTtl + in-flight + 失效回退），ns='search'。
- `_maps`/`_asList`/`_toInt`/`_toStr` 边界安全解析一致，无裸强转（第 13 条）。
- 各类型搜索字段差异逐一注释实测结论；MvHash 与 video_id 语义有明确警告（第 29 条纪律）。
- 历史上限 maxHistory=20 常量具名（第 25/2 条）。
- 三类搜索走同一 `_cachedGet`（第 5 条）。

## settings_providers.dart（38 行，通读 ✅）

dart analyze：见文末汇总表。

### settings_providers.dart:16-20 DefaultQualityNotifier.set 先改 state 再落盘，落盘失败无反馈
- 级别：P3
- 违反：第 9 条（轻微）
- 依据：`state = quality; await _box()?.put(...)` —— `_box()` 返回 null 时静默不落盘，状态仅内存生效；重启后回退旧值，无留痕。
- 影响：极端时序下（box 未就绪）设置的默认音质重启后丢失且无提示。
- 证据等级：静态推演。

复核通过项（本文件）：
- `_box()` 防护性读取，注释说明理由（null 返回即降级语义）。
- V34-UI-04 死代码删除有完整记录注释（假开关删除理由、遗留键不清理口径），第 32 条纪律到位。
- 音质名称指向 l10n 运行时获取（i18n 契约注释）。
- defaultQuality 值域与 AudioQuality.value 对齐有注释锚点。

---

# 跨文件契约抽查（○ 文件）

### auth_providers.dart（134 行，抽查）

### auth_providers.dart:73-88 switchAccount 成功后未同步 ResourceGateway 用户维度缓存
- **【更正：误报，撤销】**：主代理核对 `lib/main.dart:288-292` —— `authStateProvider` 全局 listen（switchAccount/login/logout 均经 authStateProvider 变更）在 applyAuth 内显式调用 `ResourceGateway.instance.onUserChanged()`（V34-C-03），注释明确「登录/登出/切号都走这里」。切号缓存失效链路完整。保留本条仅留痕，不计入问题清单。
- （撤销原因：仅读 auth_providers.dart 未核 main.dart 全局监听即下 P1，属跨层核实不足。）

### auth_providers.dart:56-66 logout 清 settings 盒 nickname/avatar 但 login 时同样写
- 级别：P3
- 违反：第 5 条（轻微）
- 依据：login 落盘链写 `nickname/avatar` 到 settings 盒，logout 删除；AccountManager 已存同字段。同一展示信息两处存储、两处修改，靠 login/logout 严格配对维持一致。
- 影响：任一侧改动遗漏即头像昵称不一致（switchAccount 经 loginByToken→upsert 可自愈）。
- 证据等级：静态推演。

其余抽查结论：`authRepositoryProvider` 正确注入 `kugouApiClientProvider`（回应上文裸构造疑点）。`loginControllerProvider` 三方法 loading/error 配对、rethrow 保留给 UI 层，异常契约一致（第 8 条通过）。

### captcha_types.dart（156 行，抽查）

### captcha_types.dart:44-47 supportedInApp 仅 tencent 与 sms
- 级别：P2
- 违反：第 3 条
- 依据：上游真实下发 geetest/数美/易盾/活体/人脸时 `supportedInApp=false`，captcha_page 无法呈现验证 UI；结合 verification_service「vType<=0 猜 23（腾讯）」——若实际类型是数美（KGCodeSM）而 url 识别失败，会以腾讯流程提交格式错误的 verifycode，验证必然失败。
- 影响：非腾讯滑块的验证场景用户反复验证失败、无法完成登录，且无「该验证类型暂不支持」的明确提示。
- 证据等级：静态推演。

其余抽查结论：VerifySession.fromJson 对 data 缺失/v_type 非数值降级 -1、typeList 过滤负值，边界处理合格（但 -1 → submit 猜 vType=23 的链路风险仍成立，见 verification_service 条目）。

### account_manager.dart（188 行，抽查）

### account_manager.dart:53-58 init 的「兼容清洗」每次启动重写 accounts 列表
- 级别：P3
- 违反：第 11 条（一次性迁移无退出条件）
- 依据：init 无条件 `await _saveList(accounts)`，注释说为洗掉历史明文 token（toJson 已不含 token）。每次启动都执行一次序列化重写，无「已清洗」标记，幂等无害但永久性冗余写。
- 影响：无用户可见后果，轻微性能/整洁度。
- 证据等级：静态推演。

其余抽查结论：`accounts`/`currentUserid` 未初始化降级空值有终审依据注释（第 6/10 条到位）；upsert/switchTo/clearCurrent/remove 均触发 `_notifyChanged` 广播，生命周期对称；token 不持久化到 Hive 的安全口径注释明确。`upsert` 无并发保护但调用方为登录主链路（串行），可接受（第 22 条假设未写明，P3 级别）。

### comments_page.dart（726 行，抽查）

### comments_page.dart:52-118 _CommentsController.load 非刷新追加时 total 取「新页的 total」
- 级别：P3
- 违反：第 5 条（轻微）
- 依据：追加分支 `total: result.total` —— 若上游字段漂移某页 total 异常（如 0），`_page*30 >= total` 立即截停后续分页；与 search 的 -1 未知总数口径相比无未知态处理。
- 影响：字段漂移时分页提前终止；正常路径无影响。
- 证据等级：静态推演。

### comments_page.dart:160-168 _onScroll 在 pageError 态下仍隐式触发 loadMore
- 级别：P3
- 违反：第 22 条（轻微）
- 依据：pageError 不阻断 loadMore（只查 `_loadingMore`+`_hasMore`），失败 footer 未被点重试前滚动会继续发请求并可能再次失败。
- 影响：隐式重试流，与「显式重试」设计意图不符；轻微。
- 证据等级：静态推演。

**重要核对结论（回应 comment_repository P1 疑点）**：UI 层确有防重——`_sending` 闸门（V39-AUX-04，发送按钮禁用 + finally 释放，第 19 条同栈成对）；但数据层 `sendComment`/`sendFloorReply` 本身无防重，删除入口无 _sending 闸（二次确认后单次调用，风险低）。**综合裁定：写防重只存在于单一 UI 入口，数据层无防重仍为缺陷，维持 comment_repository 的 P1，但 UI 主路径风险降低。**

其余抽查结论：`_generation` 代次防串页到位；V37-08 分页失败 footer 重试三态分离到位；`_send` 失败还原输入、20028 验证页 + 「禁止自动重试」红线注释（第 21 条纪律到位）；A2-07 unwrapApi 解包口径一致（第 8 条）；删除走二次确认 destructive dialog。

### download_provider.dart（492 行，抽查）

### download_provider.dart:351-357 发布前 queryExisting→delete 旧文件：queryExisting 异常返回 null 时旧文件不删
- 级别：P2
- 违反：第 21 条
- 依据：`queryExisting` 失败静默 null（见 public_media_store P2 条目）→ 跳过删除 → MediaStore 同名发布自动改名 "xxx (1).mp3" 副本，与代码注释意图相悖。
- 影响：异常态重复下载产生重复文件副本。
- 证据等级：静态推演。

### download_provider.dart:382-399 completed 分支 filePath 混存 uri/path 两种形态
- 级别：P3
- 违反：第 15 条（形态混用；注释已声明按形态分别处理）
- 依据：content:// 与绝对路径存同一字段，消费方靠前缀区分，属已知设计折衷。
- 影响：消费方误用隐患，靠纪律维持。
- 证据等级：静态推演。

其余抽查结论：
- DL-03 同 id 重下取消旧任务、DL-12 createdAt 修正、resume 守卫、remove 钉死哨兵 token（V37-04 P1 修复，注释详尽正确）、finally 槽位归属校验（V3-01 P0 修复）——第 18/19/20/21 条执行水平高。
- `_schedule` 只取 queued 且不在 _running，maxConcurrent=2 上界恒定（第 25 条）。
- onProgress 用 `_find`+status guard 防过期回调写状态（第 18 条）。
- clearAll 逐任务删公共文件，与 remove 语义一致。
- downloadRepositoryProvider 注入直连 playApi（架构口径通过）。

### playlist_detail_page.dart（389 行，抽查）

### playlist_detail_page.dart:32-52 playlistTracksProvider allPages:true 每次进页全量抓取
- 级别：P2
- 违反：第 24/25 条
- 依据：`fetchTracks(id, allPages:true)` 一次性拉全（_fetchAllReversed 串行抓页 + 未知总数探测）；FutureProvider 无流式更新，500 首歌单进页要串行 5 页请求后才渲染列表。
- 影响：大歌单详情页首屏等待显著（串行抓取 + 整体 await），弱网用户白屏 10s+。
- 证据等级：静态推演。

其余抽查结论：
- `_collectingProvider` autoDispose 防重锁 + F-4 终审 notifier 快照复位，第 21/20 条修复到位。
- 收藏失败按 maybeSucceeded 区分文案（第 8/9 条契约消费正确），V37-UI-06 技术串不直出。
- 详情/歌曲/重试三处 provider 数据源选择统一（userListId 分支一致，V3-06 注释）。
- UI-03 播放全部空态/加载态 Toast 反馈补齐（第 9 条）。

### settings_page.dart（1158 行，抽查头部 + 相关段）

抽查目的：核实上文 settings_providers 疑点消费侧与账号链路。
- `_qualityNames` key 与 AudioQuality.value 一致性有注释锚点（V399-B3 蝰蛇/魔法档）。
- V37-PERM-02/03 生命周期对称（addObserver/removeObserver）、误导性反馈修复注释到位。
- `_loadStorageRoot` 降级占位 ('-', 'download') 不打断 build（第 11 条）。
- 未发现与 auth 域交叉的新问题点。

### download_store.dart / download_task.dart（未通读说明）

任务书限抽查 ≤8 个文件（已用 8 个：auth_providers/captcha_types/account_manager/comments_page/download_provider/playlist_detail_page/settings_page + album_page 未用）；上文疑点已通过 download_provider + public_media_store 契约闭环（realTempPath/segment/filePath/mediaUri 写入侧均已核对），无遗留未决点。

---

# dart analyze 逐文件结果（/opt/dart/bin/dart，未 pub get——三方包 URI 缺失为预期噪音）

规则：过滤「三方包符号缺失/Flutter 框架符号未定义」噪音后，项目自有类 0 error 为合格。

| 文件 | 噪音后自有错误 | 自有警告 |
|---|---|---|
| album_repository.dart | 0（`Provider` undefined 为 riverpod 缺失噪音） | ⚠️ 138/149 `unnecessary_type_check` + `dead_code`（项目自有） |
| artist_page.dart | 0（全部为 Flutter/riverpod 符号缺失噪音） | 无 |
| auth_repository.dart | 0（dio/hive/flutter 符号缺失噪音） | 无 |
| verification_service.dart | 0（同上） | 无 |
| login_page.dart | 0（Flutter 符号缺失噪音） | 无 |
| comment_repository.dart | 0（同上） | 无 |
| download_repository.dart | 0（dio/flutter 符号缺失噪音） | 无 |
| public_media_store.dart | 0（flutter services/path_provider 缺失噪音） | 无 |
| download_sheet.dart | 0（Flutter/riverpod 缺失噪音，62 条全为符号缺失级联） | 无 |
| playlist_repository.dart | 0（dio/flutter/riverpod 缺失噪音；382 行 `dead_code_on_catch_subtype` 为 ApiException 解析失败级联，非真实死代码） | 无 |
| search_repository.dart | 0（riverpod/hive 缺失噪音） | ⚠️ 64 `unused_field _api`（项目自有） |
| settings_providers.dart | 0（riverpod/hive_flutter 缺失噪音） | 无 |

结论：12/12 过滤噪音后项目自有类 0 错误，合格。两条自有警告见下。

### album_repository.dart:138 / 149 analyze 警告：unnecessary_type_check + dead_code
- 级别：P3
- 违反：第 32 条
- 依据：`raw.first is Map` 在类型提升后被分析器认定恒真（dead code 同源）。非缺陷，整洁度。
- 影响：无直接用户可见后果。
- 证据等级：实锤（分析器输出）。

### search_repository.dart:64 analyze 警告：unused_field `_api`
- 级别：P3
- 违反：第 32 条（死代码）
- 依据：`SearchRepository._api` 已无使用点（全部读路径走 `_cached`/`CachedApiCall`），仅构造器赋值。
- 影响：无功能影响；误导维护者以为存在直连旁路。
- 证据等级：实锤（分析器输出）。

# 问题清单（按级别排序）

P0：无。

P1（1 条）：
1. comment_repository.dart:84-98 —— 写操作（发评论/回复/删评论）数据层无防重闸，防重仅存在于 comments_page 单一 UI 入口（第 21 条；B2 merged 待核实项，本视角已核实）。

P2（19 条）：
1. album_repository.dart:96-99 —— fetchDetail/fetchSongs 读取形态（json:true）不一致，无实测注释（第 28 条）。
2. album_repository.dart:36 —— data 非法形态时回退解析错误响应体，失败呈现为空白专辑（第 16/11 条）。
3. auth_repository.dart:53 —— 构造默认 new 裸 KugouApiClient（生产装配已确认注入直连，误用路径违纪）（第 2 条）。
4. auth_repository.dart:86 —— sendSmsCode 无返回校验，发送失败当成功（第 28/29 条）。
5. auth_repository.dart:92-110 —— 多账号判定依赖中文错误文案子串（第 3 条）。
6. auth_repository.dart:186-195 —— checkQr 状态解析默认「待扫」，形态漂移时扫码登录假死（第 16 条）。
7. auth_repository.dart:310-323 —— logout 裸 readCredentials，Keystore 故障机型登出中断（第 20 条）。
8. verification_service.dart:80-89 —— submit 成功判定三路 or 口径过宽，无实测依据（第 29 条）。
9. verification_service.dart:23-27 —— getVerifyInfo 不校验返回形态，vType<=0 猜 23 提交（第 13/14 条）。
10. comment_repository.dart:57-78 —— 发歌评预查多一跳网络且失败静默（第 26/9 条）。
11. comment_repository.dart:103-119 —— 歌单/专辑删除复用歌曲删除端点未证实（第 28 条）。
12. public_media_store.dart:97-103 —— MediaStore insert 无 try/catch，降级链不一致（第 6/8 条）。
13. public_media_store.dart:255-273 —— queryExisting 失败静默 null → 重复下载/重复发布副本（第 9/16/21 条；download_provider:351 交叉印证）。
14. download_repository.dart:63-124 —— 试听/高潮片段声明字节数直接比较择长，语义需留样裁决（B2 遗留确认）（第 29 条）。
15. download_repository.dart:141-167 —— downloadFile 重试间隙/失败终止的半截文件残留（第 21/14 条）。
16. playlist_repository.dart:233-236 —— 超大歌单全量抓取静默退化为仅首页（第 17/16 条）。
17. playlist_repository.dart:419-424 —— badResponse 归入 maybeSucceeded=true（第 11 条）。
18. playlist_repository.dart:634 —— UserPlaylist.isMine 判定口径无实测留样（第 29 条）。
19. captcha_types.dart:44-47 —— supportedInApp 仅 tencent/sms，非腾讯滑块验证闭环无明确不支持反馈（第 3 条）。
20. artist_page.dart:131-141 —— 专辑 tab 一次失败后永久空态（第 6/9/11 条）。
21. artist_page.dart:100-129 —— 歌曲分页失败静默无提示（第 9 条）。
22. login_page.dart:710-718 —— QR 轮询失败完全静默且无连续失败上限（第 9/25 条）。
23. login_page.dart:399-401 —— 20028 重试无次数上限，极端时验证循环（第 21/11 条）。
24. search_repository.dart:230-242 —— 热搜/建议失败吞成空列表，失败与空态不分且无留痕（第 6/9/16 条）。
25. playlist_detail_page.dart:32-52 —— 大歌单进页全量串行抓取，首屏等待（第 24/25 条）。
26. download_sheet.dart:41-50 —— `quality != q128` 把真实 128k 歌曲偷换为偏好音质（第 2/3 条）。

P3（15 条，摘要）：
1. auth_repository.dart:39-49 —— getDfid 空 catch 无留痕；'' 随 saveCredentials 落盘与注释意图不一致。
2. verification_service.dart:91-95 —— ApiException 一律「未通过」，异常形态不一致无日志。
3. login_page.dart:207-239 —— 多账号选择后复用旧验证码。
4. comment_repository.dart:187-191 —— total 四字段兜底链 fallback=本页长度。
5. download_repository.dart:126-138 —— 扩展名推断失败默认 .mp3 无留痕。
6. download_repository.dart:222-235 —— 歌词 onProgress 字符数伪造字节进度。
7. download_repository.dart:196-201 —— downloadCover 纯别名封装。
8. download_provider.dart:382-399 —— filePath 混存 uri/path 两形态（已知折衷）。
9. search_repository.dart:163-170 —— MV 封面硬编码 http://。
10. search_repository.dart:297-300 —— 历史写 clear+addAll 窗口。
11. playlist_repository.dart:60-62 —— fetchUserPlaylists 不走缓存。
12. playlist_repository.dart:527-533 —— 歌名前缀剥离两处重叠无注释。
13. account_manager.dart:53-58 —— init 兼容清洗每次启动重写。
14. auth_providers.dart:56-66 —— nickname/avatar 双存储依赖配对。
15. settings_providers.dart:16-20 —— 落盘失败静默。
16. comments_page.dart:52-118 / 160-168 —— total 透传漂移；pageError 态隐式 loadMore。
17. artist_page.dart:185-186 —— build 期间写 _infoName。
18. artist_page.dart:459 —— 万位计数双口径。
19. album_repository.dart:138/149、search_repository.dart:64 —— analyze 自有警告（第 32 条）。
20. album_repository.dart:14-33 —— data 空数组与缺失语义混同。

# 复核通过项（本范围确认到位的设计）

1. comment：`_generation` 防串页、V37-08 分页失败重试 footer 三态分离、`_sending` 防重闸（finally 同栈释放）、20028 验证页禁止自动重试红线、失败还原输入。
2. playlist：`PlaylistWriteException.maybeSucceeded` 契约文档化与 UI 消费；`_write` in-flight 防重 + finally 配对；写操作不回退 kapi（get 分派 + write:true 注释完整）；分隔符协议边界校验（全角替换/hash 缺失拒绝/批次去重）；maxPages 上界 + 单页失败留痕跳过；PlaylistDetail 空 data 显式报错；写后 ns 精确失效。
3. download：remove 钉死哨兵 token 封死迟到回调复活窗口（V37-04）；V3-01 槽位归属校验修复；DL-03 同 id 重下取消旧任务；dimKey 含全部内容维度；resume 守卫；publish .part 原子替换；MediaStore 每个失败分支先删 pending 再降级；mimeOf 按真实扩展名。
4. auth：restoreSession Keystore 防护 + 网络错误不清凭证 + _degradedUser 降级；_isTokenInvalidCode 排除参数性 20010；ssaCode 三路兜底；logout B-11 修复；main.dart authState listen 统一 onUserChanged 清缓存（切号缓存链完整）。
5. login：unwrapApi 统一错误出口；QR 轮询自驱动防重叠 + active 启停 + dispose 对称；扫码成功≠登录成功分态提示。
6. artist：_songsGen 世代号作废在途请求；三态分离清晰；滚动路径零重分配。
7. album/comment 模型解析全面 is-分支校验，无裸强转；duration 单位注释显式。
8. settings：假开关死代码删除有记录注释；音质名 l10n 契约；_box() 防护性读取。
9. 架构口径：所有通读文件 Provider 装配均注入直连实例，无运行期 kapi 主路径。
10. 12/12 文件 analyze 过滤噪音后项目自有类 0 错误。

# 未做项说明

- 未通读 album_page.dart / download_store.dart / download_task.dart（抽查配额优先用于疑点闭环；写入侧契约已经 download_provider/public_media_store 核对无遗留）。
- 未做 pub get / 构建 / 运行（硬性禁令）；analyze 三方包缺失噪音按规范过滤。
- 试听/高潮字节数语义、checkQr 状态值表、isMine 口径、删除端点形态等「需原生留样」项均标注静态推演，未以 kapi 结果为据（第 33 条）。
