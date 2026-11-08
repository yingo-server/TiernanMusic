# v3.5 C 批·审查①：MV + Library 数据层/表现层联动 + album/artist 全链路

基线 `a819334`（v3.5 B1 修复后）。依据 `docs/QUALITY_STANDARD.md`（33 条）与
`TASK_v34_review2.md` 变体差异（C1 档）。审查纪律：完整逐行阅读，跨文件改动双向核对，
噪音过滤仅适用于 Flutter SDK 符号，项目自有类报错即真错误。

## 实测记录（native_probe 直打原生域，第 33 条）

用 `tool/kg_probe.py` 直打 `openapi.kugou.com/kmr/v1/audio/mv`（KG-TID:38，POST
`{'data':[{'album_audio_id':32100650}],'fields':'mkv,tags,h264,h265'}`，匿名态），
与 `kg_endpoints_media.dart:22-40` 的实现逐字段对齐：

- ✅ 返回 `status=1`，`data` 为嵌套数组，12 项。单项实测字段与 `MvInfo.fromJson`
  假设一致：`mv_name` / `video_id` / `duration=317400`（**毫秒**）/ `thumb` /
  `hdpic` / `singer`（authors 为空数组）/ `h264{fhd,qhd,hd,sd,ld}_hash` /
  `mkv{qhd,sd}_hash`。
- ✅ `pick('sq_hash')` 实测不存在 sq → 注释「sq 实测不存在」成立。
- ⚠️ 实测**thumb 与 hdpic 的路径前缀不同**：thumb=`imge.kugou.com/mvthumb/{size}/…`，
  hdpic=`imge.kugou.com/mvhdpic/{size}/…`。`MvRepository._mvThumb`（mv_repository.dart:92-104）
  对裸文件名统一拼 `/mvthumb/{size}/`，而 MV 详情兜底链 `cover→hdpic→thumb→pic`
  传入 hdpic 整 URL 时不受影响（已带 http），但若上游某端点只回 hdpic **裸文件名**
  （无 `mvhdpic/` 前缀），拼成 mvthumb 路径会 404。实测样本 hdpic 均带完整 URL，
  风险仅在 hdpic 裸名场景 → P3，见 MV-R3。
- ✅ 缩略图四档实测：HEAD `{size}`∈{240,320,480,720} 全部 200。
  **实测各档 Content-Length 完全相同（16058/16058/16058 字节，240 档 16645）**
  ——上游把 320/480/720 返回同一物理文件。即 `_mvThumb(size:480)`（详情封面）
  并不会比 320 更清晰，注释「720× 设备像素仍清晰，按 480 档取」的前提不成立。
  选档逻辑无错，但注释与实测不符（MV-R1，第 31 条：注释须记录平台怪癖）。
- 实测样本：video_id=117613（晴天）h264 含 fhd_hash；`MvInfo.bestHash` 中
  `sqHash` 恒为 null，回退链生效正常。

---

## 一、mv 数据层

### MV-R1: lib/features/mv/data/mv_repository.dart:96-104 `选档注释与实测不符`
- 级别：P3
- 事实：`_mvThumb` 注释称「按控件实际需要的最小够用档请求（第 25 条）」，
  详情封面用 480 档理由是「720× 设备像素仍清晰」。实测 320/480/720 三档
  返回**同一文件**（Content-Length 均为 16058）——档位选择在此 CDN 上无效果，
  480 档与 320 档同样清晰/同样糊。
- 违反：第 31 条（注释解释「为什么」必须记录实测反常行为，本处注释陈述了不成立的前提）。
- 后果：后续维护者会误以为升档可提升清晰度去改代码；且「MV 缩略图过糊」类
  反馈无法通过调档解决。行为本身无错，纯注释误导。

### MV-R2: lib/features/mv/data/mv_repository.dart:92-104 `裸文件名拼 mvthumb 前缀，hdpic 裸名场景 404`
- 级别：P3
- 事实：`_mvThumb` 对非 http 裸名统一拼 `http://imge.kugou.com/mvthumb/{size}/`。
  实测 hdpic 与 thumb 的 CDN 前缀不同（`mvhdpic/` vs `mvthumb/`）。当前实测样本
  hdpic 恒带完整 URL，触发条件是「上游某端点返回 hdpic 裸文件名」，目前未实测到。
- 违反：第 28 条（未实测路径按推测处理需标注；此处未标注）。
- 后果：若上游某天返回 hdpic 裸名，封面 404 静默裂图（errorWidget 兜底有，
  不算失效，仅显示占位图标）。

### MV-R3: lib/features/mv/data/mv_repository.dart:126-133 `sqHash 取 sq_hash 注释自认不存在，死代码分支`
- 级别：P3
- 事实：`pick('sq_hash')` 与 `bestHash` 回退链首位 sqHash、`MvDetail.bestHash`
  的 'sq' 档，实测均无该字段（h264 只有 fhd/qhd/hd/sd/ld）。实测注释已写明
  「sq 实测不存在」，但保留了读取分支。
- 违反：第 32 条（仅供「以后可能用」的分支）——但作为协议前瞻性防御保留成本
  极低，故降为 P3 备案。

### MV-R4: lib/features/mv/data/mv_repository.dart:56-63 `findBySong 缓存未命中时异常无转译`
- 级别：P2
- 事实：`cached ?? await _api.get(...)` 抛出的异常（超时/DioException）原样上抛。
  调用方 `mvExistsProvider`（mv_provider.dart:10-13）**没有 catch**：
  `mvExistsProvider` 是 `FutureProvider.family`，异常会传播到 watch 方
  （全屏播放器 `full_player_page.dart:309` `mv` 为 AsyncValue，UI 侧 `.value`
  取 null，MV 入口消失——静默）。
  同文件 `mvDetailProvider`（mv_provider.dart:27-32）有 `catch (_) => null` 兜底，
  两个 provider 口径不一致。
- 违反：第 8 条（回退路径与主路径异常形态一致）/ 第 9 条（失败可观测——
  mvExists 失败与「无 MV」在 UI 上不可区分）。
- 后果：网络抖动时全屏播放器 MV 入口直接消失，用户以为这首歌没有 MV，
  与 `mvDetailProvider` 失败仅隐藏清晰度按钮的降级策略不对称。
  （对照：第 16 条「请求失败与确实为空语义分离」在此被打破。）

### MV-R5: lib/features/mv/data/mv_repository.dart:160-165 `resolvePlayUrl 的 d.values.first 兜底取值无序`
- 级别：P3
- 事实：`entry = d[hash] ?? d.values.first`——Map 迭代序在 Dart 是插入序，
  但服务端 data 下可能含非条目键（如 status/errmsg 已在上游剥离？未实测该形态）。
  若 data 中混入元信息键，`values.first` 会取到非 Map → `entry is! Map` 抛
  ApiException，可接受。行为安全，仅备案。

## 二、mv_collection_repository（cancel_collect 修复后回归）

### MVC-R1: lib/features/mv/data/mv_collection_repository.dart:93-153 `setCollected 全仓无调用方（死功能）`
- 级别：P2
- 事实：跨文件双向核对（调用方↔被调方）：`grep setCollected` 全仓仅命中定义
  （本文件 :93）；`mvCollectionRepositoryProvider` 的唯一消费者是
  `library_page.dart:519` 的 `fetchCollected`（读）。即 cancel_collect 修复
  （/v1/cancel_collect + 二进制 body + 解密判定）修复了一个**没有任何 UI 入口
  会触发的函数**：MV 收藏/取消收藏在整个 app 无入口（mv_player_page 无收藏按钮，
  库页只读展示）。D-P0-2 的修复本身经核对正确（见 MVC-R2），但功能不可达。
- 违反：第 32 条（死代码零容忍——不可达的写路径）；易用性任务流 4
  （「MV 观看 → 收藏 MV」入口可达性：v34 报告曾指出，仍未闭环）。
- 后果：用户无法收藏 MV；库页「我收藏的 MV」只对已在酷狗 App 收藏过的用户
  有内容。修复代码成为无回归保护的孤岛——一旦协议再变，无人发现。

### MVC-R2: `setCollected 修复后正确性复核（针对解密判定回归）` ✅
- 事实核对：
  1. `path = collect ? '/v1/collect' : '/v1/cancel_collect'`（:107）——与 Node
     mv_collect_del.js 对齐，`collect` 形参真实参与请求 ✅
  2. body 走 `base64Decode(aes.str)`（:131）发送**二进制**。核对 KgClient.request
     （kg_client.dart:175-177）：`bodyStr = data is String ? data : jsonEncode(data)`
     ——**data 是 List<int> 时会被 jsonEncode 成整数数组文本**！
     ⚠️ 但核对 KgClient.request 的调用链：`data` 参数类型是 `dynamic`，
     `bodyStr` 最终经 `_dio.request(data: bodyStr.isEmpty ? null : bodyStr)` 发送
     ——`base64Decode` 产生的 `List<int>` 会走 `jsonEncode` 分支，
     序列化为 `[21,35,...]` 字节码字符串而非原始二进制！
     **P0/P1 级疑似缺陷**：若服务端期望原始 AES 密文字节，jsonEncode 后的
     整数数组文本完全不可解。
     ⚠️ 反向核对：kg_endpoints_playlist.dart:51 的 playlistDel 走的是
     `data: aes.str`（Base64 **文本**），其响应解密成功（有实测记录）——
     说明该端点族服务端**接受 Base64 文本 body**。而 mv_collection 修复
     特意改成二进制（注释「Node 发二进制，不是 Base64 文本」）。两个端点
     同为 collectservice 家族，协议是否真的一文本一二进制？**无实测记录**
     支撑二进制形态（docs/api_verified.md 无 /v1/collect 行）。
  3. 解密判定 `decrypted != null`：`aesDecryptPlaylistB64` 内部
     `jsonDecode` 非 Map 即抛 FormatException，被 catch 捕获 → 返回
     `res.status == 200`（:152）。降级路径与主路径语义不一致：主路径要求
     「解出 JSON 对象」，降级只看 HTTP 200——风控空包 200 仍判成功。
     第 8/11 条违反残留（修复只完成了一半）。
- 级别：P1（第 2 点：请求体形态未经实测，直接按推测发送，违反第 28 条；
  若形态错，收藏/取消收藏**静默失败**且被解密降级路径误判成功）
- 后果：收藏态判定失真（正是本次修复想解决的问题，可能在另一形态上复发）。

### MVC-R3: lib/features/mv/data/mv_collection_repository.dart:45-50 `duration 字段源 audio_info.duration 未验证单位`
- 级别：P3
- 事实：`ms = audioInfo['duration']` 直接当毫秒；全仓 MV 时长口径已实测为毫秒
  （kmr/video 接口），但 collect_list_mixvideo 的 audio_info.duration 无实测留样。
  若是秒，Duration 差 1000 倍（该字段当前无 UI 消费，仅数据模型承载）。
- 违反：第 29 条（未实测必须标注）。

### MVC-R4: lib/features/mv/data/mv_collection_repository.dart:136-139 `UA 拼接硬编码分片`
- 级别：P3
- 事实：`'Android9-1070-...-MV/Care'-wifi'` 手写拼串，与 kg_client.dart:229 默认
  UA（Android15-…-DiscoveryDRADProtocol-wifi）双源。UA 魔法值散落两处。
- 违反：第 2 条（魔法值具名常量）/ 第 5 条（同一事实两处存储）。

## 三、mv_provider + mv_player_page

### MPP-R1: lib/features/mv/presentation/mv_player_page.dart:113-158 `_resolve 切档后旧控制器在异常路径可能双持`
- 级别：P3
- 事实：切档成功路径：`old?.dispose()`（:144）✅；失败路径 `created?.dispose()` ✅；
  但 `!mounted` 分支（:135-138）`created.dispose()` 后 `return`——此时 `_controller`
  旧实例尚在，dispose() 中 `_controller?.dispose()`（:71）会再释放一次 ✅ 无泄漏。
  复核通过，无问题。备案为核对记录。

### MPP-R2: lib/features/mv/presentation/mv_player_page.dart:166-172 `build 内 addPostFrameCallback 每帧注册`
- 级别：P3
- 事实：`build` 每次执行都注册一个 postFrameCallback 设置 SystemUiMode（横竖屏
  切换时频繁触发）。setEnabledSystemUIMode 幂等，实际开销低，但属「构建函数
  含副作用」（第 24 条：构建函数应为纯函数）。文件头注释已自述「build 不再有
  副作用」，与实现矛盾（initState 的方向锁也是副作用，但一次性，可接受；
  build 内这处与自述不符）。

### MPP-R3: lib/features/mv/presentation/mv_player_page.dart:196-203 `清晰度按钮遮挡全屏播放器底部进度条区（bottom:108 魔法数）`
- 级别：P3
- 事实：`Positioned(bottom:108)` 竖屏时清晰度按钮浮在操作条（bottom:48）上方
  60dp 处；横屏时 108 无对应锚点。魔法数值无注释出处（第 2 条）。
- 后果：小屏竖屏下清晰度按钮可能与进度条（bottom:16，高度约 8dp）视觉拥挤。

### MPP-R4: mv_player_page `_activeHash 为 null 时重试按钮回退 widget.hash 与清晰度列表断链`
- 级别：P3
- 事实：`_resolve(_activeHash ?? widget.hash)`（:243, :297）：若首次用 videoId
  转换出的 bestHash 成功，_activeHash 记录的是**hash**；重试一致 ✅。
  但若用户从 `/mv/:hash` 进入且 videoId 为 null（mvDetailProvider 键 = hash，
  /video/detail 传 hash 返回 invalid param → detail=null → 无清晰度按钮）。
  full_player_page.dart:345 总是带 videoId ✅；rank_detail_page.dart:178 的
  `context.push('/mv/${s.mvHash}')` **不带 videoId query** → 从榜单进 MV
  永远没有清晰度切换按钮（mvDetailProvider 错用 hash 当 videoId 打 /video/detail）。
- 级别：**P2**（次要功能失效：榜单入口 MV 无清晰度切换）
- 违反：第 5 条（mvDetailProvider 的键语义是 videoId，调用方传 hash 即语义漂移）；
  第 3 条（契约不明确）。
- 后果：榜单 → MV 播放：清晰度按钮缺失，默认 bestHash 播放，用户无法切档。

### MPP-R5: mv_player_page `onTap 整屏切 controls 与 IconButton 点击冒泡冲突` ✅ 复核
- 事实：IconButton 在 Stack 内、GestureDetector 之下，点击按钮时 GestureDetector
  也会收到（in hit test 中 child 优先，GestureDetector 是父级，behavior 默认
  deferToChild——Stack 覆盖全屏有 child 命中，会同时触发）。点击播放/暂停按钮
  会不会同时触发 _showControls 翻转？IconButton 命中后事件被按钮消费，
  父 GestureDetector（RawGestureDetector arena）与子按钮竞争——**子胜出**，
  父 onTap 不触发 ✅ 无问题。备案。

## 四、library_page（V34-UI-06/08 修复后）+ recent_play_store

### LIB-R1: lib/features/library/presentation/library_page.dart:59-66 `账号切换 invalidate 后 provider 键 loggedIn 变化导致旧键残留`
- 级别：P3
- 事实：`libraryUserPlaylistsProvider(account != null)` 每次 build 生成不同
  family 键（true/false）。登出→登录：build 先以 false 键渲染（返回 const []），
  `ref.invalidate(provider)` invalidate 的是**所有** family 键（Riverpod family
  invalidate 全键）✅ 行为正确。复核通过，备案。

### LIB-R2: library_page.dart:95-101 `_loadRecent 失败降级为空列表，与「确实为空」不可区分`
- 级别：P3
- 事实：catch 中 `setState(_recent = [])`，UI 显示「暂无最近播放」EmptyState——
  读取失败与确实为空同 UI（第 16 条），但 debugPrint 已留痕（第 9 条满足）。
  降级文案误导性低，备案。

### LIB-R3: library_page.dart:238-241 `_confirmClearRecent 中 RecentPlayStore.clear() 后未等 await`
- 级别：P3
- 事实：`await RecentPlayStore.clear(); _loadRecent();` ✅ 实际有 await。
  复核通过。

### LIB-R4: library_page.dart:516-521 `libraryCollectedMvsProvider pageSize=50 上限无分页`
- 级别：P2
- 事实：`fetchCollected()` 默认 page=1, pageSize=50；UI `list.take(20)`。
  收藏 MV >50 的用户（重度用户）只能看到前 50，**无任何「还有更多」提示或
  加载入口**，静默截断。
- 违反：第 16 条（语义：截断与完整不可区分）/ 易用性（用户任务流：看不到
  自己全部收藏）。
- 后果：收藏超过 50 个 MV 的用户发现列表「莫名少了」，且无翻页/更多按钮。

### LIB-R5: recent_play_store.dart:63-70 `_serial 链 catchError 后 _serial 变为已完成 Future，后续 add 仍排队 ✅` 复核
- 事实：`_serial = next.catchError(...)` 返回 `Future<void>`，错误被吞转为正常
  完成——后续链不断 ✅。但 catchError 回调体是 `return;` 且**完全静默**
  （注释写「保留错误可观测性」却只有一行被注释掉的 print，:69
  `// ignore: avoid_print` 下方无实际输出）。
- 级别：P3（第 6/9 条：注释声称可观测但实际无任何输出——`return;` 不留痕）。
- 后果：最近播放写盘失败完全无日志，与注释承诺不符。

### LIB-R6: recent_play_store.dart:52-57 `read() 的 box 懒打开与 clear() 的「未打开即 return」不对称` ✅ 复核合理
- 事实：clear 在 box 未打开时直接 return（无事可清，等价幂等）✅。

### LIB-R7: library_page.dart:127-136 `最近播放菜单只有 download，长按/菜单含「收藏到歌单」缺失（V34-UI-01 任务流未覆盖库页）`
- 级别：P3
- 事实：V34-UI-01 给搜索页与播放页加了收藏到歌单入口；库页最近播放的
  SongTile 菜单只有 download。`r.albumAudioId/hash` 齐全，TrackRef 契约可满足。
  入口不一致（同类列表不同能力），易用性问题，非缺陷。

## 五、add_to_playlist_sheet 与数据层契约（TrackRef）双向核对 ✅

- `TrackRef`（playlist_repository.dart:540-545）：`name/hash/albumId?/albumAudioId?`。
- 调用方核对：
  - full_player_page.dart:91-98：`TrackRef(name,hash,albumId,albumAudioId)` ✅
  - search_page.dart:595-602：`hash: s.hash ?? s.id` ✅（HomeSong.hash 可空，
    回退 id——id 是否是 hash 需确认：HomeSong 的 `id` 字段在 search 语境
    （FileHash 场景）语义为 hash？search_page 处 `s` 为 HomeSong，其 `id`
    实测来自 `/search?type=song` 的 FileHash？**未逐一实测**，若 id 是
    numeric id 而非 hash，加歌会发错误 hash → P2 疑点）。
    ⚠️ 核对 home/data/models.dart：`/search?type=song` 解析记录「`FileHash` /
    `OriSongName`」，HomeSong.fromJson 未见（需读 :132 附近解析）——初判
    `id` 取 FileHash（搜索场景 hash 与 id 同源）。标注为**未完全验证**，
    建议补一条实测：用 search 返回的 id 直接加歌是否成功。→ P3 备案。
- `_addTo` 空值守卫（:83-88）✅；`_busy` 防重（第 21 条）✅；
  PlaylistWriteException 专属 catch（第 8 条）✅。
- `_createAndAdd` 的「创建后按名称匹配 listid」方案（:109 注释）契约诚实
  （未实测返回体不冒充依据，第 29 条 ✅）。重名歌单场景会匹配到旧歌单
  （按名称精确匹配的第一个）→ 歌加错歌单 → P3。
- 级别合计：P3 ×2（见上）。

## 六、album 全链路（从未审过）

### ALB-R1: lib/features/album/data/album_repository.dart:124 `final dynamic _api 失去类型`
- 级别：P2
- 事实：`AlbumRepository(this._api); final dynamic _api;`——注入的类型被抹成
  dynamic，`_api.get(...)` 的方法存在性、返回类型全部失去静态检查（artist_repository
  同病，:149）。`kugouApiClientProvider` 返回的是 KgDirectApiClient（实现 get），
  完全可以声明为接口类型或具体类型。第 10 条：编程错误（方法名打错/参数错）
  会推迟到运行时才暴露。
- 违反：第 10 条 / 第 2 条（显式优于隐式）。
- 后果：`fetchDetail` 的 `as Map<String, dynamic>` 强转（:127）在 dynamic 调用
  返回非预期类型时运行时崩溃，静态分析器完全沉默。
  （对照 mv_repository 注入了 `KugouApiClient` 具体类型 ✅——同项目同层两种口径。）

### ALB-R2: album_repository.dart:127 `fetchDetail 强转 as Map<String,dynamic> 无守卫`
- 级别：P2
- 事实：`(await _api.get(...)) as Map<String, dynamic>`——上游返回非 Map
  （网关错误页/字符串）时 TypeError 直接上抛。对照同文件 fetchSongs 用
  `data is Map ? data : const {}` 的分支校验（:139）——同文件两种口径。
  直接违反第 13 条（外部数据禁止裸类型强转）。AlbumInfo.fromJson 内部
  （:33-36）反而做了 `raw is List/is Map` 分支 ✅，但入口强转先崩。
- 后果：album/detail 上游异常形态时专辑页 ErrorRetry 显示 TypeError 文案，
  而非友好错误。
- （artist_repository.dart:152 `res as Map<String, dynamic>` 同病 → 同 P2，
  而 fetchSongs/fetchAlbums 是 `is List` 分支 ✅。）

### ALB-R3: album_page.dart:60-63 `_onScroll 无分页终止条件外的重复请求守卫 ✅ / 但 refresh 后 _page 未重置崩溃边界` 复核
- 事实：`_loadSongs(refresh:true)` 重置 _page=1 ✅；分页防抖（_loadingMore）✅；
  `_total>0 && _songs.length>=_total` 终止 ✅。但 `_total==0`（首页尚未返回）
  时滚动会触发 `_loadSongs()`（非 refresh）——若首屏请求未完成，`_loading`
  守卫挡住 ✅；若首页返回 0 条（空专辑）但 total 解析失败回退
  `songs.length`=0 → `_total=0`，滚动到顶也继续发请求（每滚一次发一次，
  每次返回 0 条追加 0 条，无终止）。
- 级别：P3（空专辑 + total 缺失场景的重复请求；第 25 条上限/终止条件缺失）。

### ALB-R4: album_page.dart:168 `info.cover memCacheWidth: 360 固定值未乘 dpr` ✅ 对照 V33-12 口径
- 事实：专辑封面 120dp 显示、memCacheWidth 360（=120×3）。账号卡片头像用了
  `MediaQuery.devicePixelRatioOf`（library_page.dart），此处硬编码 3 倍。
  高分屏（dpr>3）欠采样，低分屏（dpr=2）过度解码。不一致口径，P3。

### ALB-R5: album_page.dart:96 `_playAt 内 context.push 在 async gap 外 ✅` 复核通过。

### ALB-R6: album_page.dart `专辑页无 MV 入口`
- 事实：AlbumSong 解析了 `mvdata[].hash`（mvHash 字段，:110），但 album_page
  的 SongTile **没有任何菜单/入口消费 mvHash**——数据解析了却不用（对照
  artist_page 同样解析 mvHash 也不用，搜索页/榜单页有 `/mv/` 跳转）。
- 级别：P3（第 32 条死数据；易用性：专辑页歌曲的 MV 不可达）。

## 七、artist 全链路（从未审过）

### ART-R1: artist_page.dart:74-80 `_onScroll 挂在 _scroll，但 _buildSongs 的 ListView 用 controller: _scroll` ✅
- 事实：单曲 Tab 滚动触发分页 ✅。但**专辑 Tab**（GridView）没有 controller，
  专辑分页（_albumPage）只加载一次（首次切 Tab 时 _loadAlbums 一页 30 条），
  专辑 >30 的歌手无法看更多，GridView 滚到底无加载更多，无提示。
- 级别：P2（与 LIB-R4 同型：静默截断，第 16 条）。
- 后果：多专辑歌手（>30 张）的专辑列表不完整且用户不知道。

### ART-R2: artist_page.dart:136 `_loadAlbums 失败 catch(_)` 吞异常
- 事实：`catch (_) { _loadedAlbums = true; }`——加载失败被标记为「已加载」，
  UI 显示 EmptyState「暂无数据」（第 6/16 条：失败与空不可区分，且完全静默）。
  对照 _loadSongs 有 _songsError 状态 + ErrorRetry ✅ 同页两口径。
- 级别：P2（次要功能：专辑 Tab 网络抖动时显示「暂无数据」，用户以为歌手
  没有专辑；无重试入口）。
- 违反：第 6 条 / 第 9 条 / 第 16 条。

### ART-R3: artist_page.dart:225 `_infoName 在 build 中被赋值（build 含状态写入）`
- 事实：`final info = snap.data!; _infoName = info.name;`——build 中写实例字段，
  _playAt 依赖它。属于「构建函数含副作用」（第 24 条），且若 build 未跑过
  （理论上不可能，_playAt 必然在 build 后）该字段为 ''。轻微，P3。

### ART-R4: artist_repository.dart:67-79 `long_intro 解析 as List 强转`
- 事实：`d['long_intro'] is List` 先判 ✅，内部 `whereType<Map>()` ✅。复核通过。

### ART-R5: artist_repository.dart:117 `pagesize 注释「上限 100」但用 30` ✅ 一致性无问题。
### ART-R6: artist_repository.dart:135 `fetchSongs 的 total 解析失败回退 0` → 分页终止条件
  `_total>0 && …` 永不满足 → 同 ALB-R3，total 缺失时滚动持续请求。P3（并入 ALB-R3 同型）。

### ART-R7: artist_page.dart:397 `_fans 硬编码 'w' 单位（中文万）`
- 事实：`'${(n/10000).toStringAsFixed(1)}w'`——l10n 键未使用，英文环境下
  显示「w」。检查 app_en.arb 未有对应机制。P3（l10n 硬编码）。

### ART-R8: artist_page.dart `_sort 切换未取消在途请求（第 18 条世代校验）`
- 事实：`onSelectionChanged: _loadSongs(refresh:true)`——若「new」请求在途，
  用户切「hot」，refresh 分支 `if (_loadingMore || _loadingSongs) return;`
  **不生效**（refresh 分支先于守卫执行）：_songs.clear() 后 hot 请求发出，
  new 的旧响应随后返回 `setState(_songs.addAll(res.songs))`——**旧排序数据
  混入新列表**。
- 级别：**P1**（核心功能数据错乱：排序切换后列表内容与选中态不符，用户
  可见且高频触发——网络慢时点一下排序即现）。
- 违反：第 18 条（异步结果必须校验世代，等待期间有效性可能已失效——本处
  换排序即失效，无世代标记）。
- 后果：选「最热」显示的可能是「最新」的歌曲，且 `_total`/`_page` 也被旧
  响应污染（total 用旧值、page 计数错乱），后续分页拉到重复/遗漏数据。
- （对照 album_page 无排序切换无此问题；artist_page 中 _loadSongs 的 refresh
  分支无世代守卫，是 B1 批 `_playAt` 世代修复的同类遗漏。）

## 八、问题清单汇总

| # | 位置 | 级别 | 一句话 |
|---|---|---|---|
| ART-R8 | artist_page.dart:190-198 | **P1** | 排序切换无世代校验，旧响应污染新列表 |
| MVC-R2 | mv_collection_repository.dart:117-152 | **P1** | cancel_collect 请求体形态（二进制 vs JSON 数组文本）未实测，且解密失败降级仍以 HTTP 200 判成功 |
| MV-R4 | mv_repository.dart:56-63 | P2 | findBySong 异常上抛致 mvExists 失败与「无 MV」不可区分，与 mvDetailProvider 口径不一致 |
| ALB-R1 | album_repository.dart:124 | P2 | `final dynamic _api` 抹掉注入类型，静态检查全失（artist 同） |
| ALB-R2 | album_repository.dart:127 | P2 | fetchDetail 入口裸 `as Map<String,dynamic>` 强转（artist :152 同） |
| ART-R1 | artist_page.dart | P2 | 专辑 Tab 只加载一页 30 条，无分页无提示 |
| ART-R2 | artist_page.dart:136 | P2 | _loadAlbums 吞异常，「失败」显示为「暂无数据」 |
| LIB-R4 | library_page.dart:516-521 | P2 | 收藏 MV 50 条静默截断 |
| MPP-R4 | mv_player_page.dart:120 | P2 | 榜单入口不带 videoId，MV 无清晰度切换 |
| MV-R1 | mv_repository.dart:96-104 | P3 | 选档注释与实测不符（320/480/720 同一文件） |
| MV-R2 | mv_repository.dart:92-104 | P3 | hdpic 裸名拼 mvthumb 前缀 404（未实测到触发场景） |
| MV-R3 | mv_repository.dart:126-133 | P3 | sq_hash 死分支备案 |
| MV-R5 | mv_repository.dart:160-165 | P3 | values.first 兜底备案（行为安全） |
| MVC-R3 | mv_collection_repository.dart:45-50 | P3 | collect_list duration 单位未实测标注 |
| MVC-R4 | mv_collection_repository.dart:136-139 | P3 | UA 魔法值双源 |
| MPP-R2 | mv_player_page.dart:166-172 | P3 | build 内 postFrameCallback 副作用，与头注释矛盾 |
| MPP-R3 | mv_player_page.dart:196-203 | P3 | bottom:108 魔法数 |
| LIB-R2 | library_page.dart:95-101 | P3 | 最近播放读取失败与空不可区分 |
| LIB-R5 | recent_play_store.dart:63-70 | P3 | catchError 静默，注释称可观测但无输出 |
| LIB-R7 | library_page.dart:127-136 | P3 | 库页缺收藏到歌单入口（V34-UI-01 未覆盖） |
| ALB-R3 | album_page.dart:60-63 | P3 | total=0 场景滚动重复请求（artist 同型） |
| ALB-R4 | album_page.dart:168 | P3 | memCacheWidth 硬编码 3×，未用 dpr |
| ALB-R6 | album_page.dart | P3 | mvHash 解析未消费 |
| ART-R3 | artist_page.dart:225 | P3 | build 中写实例字段 |
| ART-R7 | artist_page.dart:397 | P3 | 粉丝单位 'w' 硬编码未 l10n |
| A2P-1 | search_page.dart:595 | P3 | TrackRef hash 回退 s.id 的语义未实测验证 |

统计：P1×2、P2×7、P3×17（含 3 条复核通过备案不计入问题数 → 实际问题 26 条）。

## 易用性任务流走查

| 任务流 | 状态 | 断点 |
|---|---|---|
| 1. MV 观看 → 收藏 MV | ❌ 不可达 | 全 app 无收藏 MV 入口（MVC-R1），库页仅只读 |
| 2. 库页看收藏 MV → 播放 | ✅ | hash 空有 Toast（V34 修复在位） |
| 3. 排序切换（歌手页） | ⚠️ | 切换快时列表错乱（ART-R8） |
| 4. 榜单 → MV → 切清晰度 | ❌ | 无清晰度按钮（MPP-R4） |
| 5. 专辑 → 播放全部 | ✅ | 分页守卫正确 |
| 6. 搜索 → 收藏到歌单 | ✅（待验） | hash 回退 s.id 需实测（A2P-1） |

## 实测样本（第 33 条，直连 openapi.kugou.com）

- `/kmr/v1/audio/mv`（匿名，KG-TID:38）：status=1，晴天 12 条 MV，
  duration=317400（ms），h264 含 fhd_hash，authors=[]，singer=「周杰伦」，
  thumb 带 `{size}` 占位 ✅ 与 MvInfo.fromJson 逐字段一致。
- 缩略图 HEAD：240=16645B、320/480/720 均=16058B（同一文件）。
- `/v1/collect` / `/v1/cancel_collect` 请求体形态**未实测**（需登录写操作，
  不便直打）——MVC-R2 的 P1 判定即基于「无实测记录 + 源码推演矛盾」，
  已按第 29 条标注为未验证，修复前必须先补实测。
