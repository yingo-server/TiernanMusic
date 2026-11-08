# 第4批·审查①-B：端点域文件与播放地址（只读审查报告）

- 基线：`6e46611`
- 范围：`lib/core/direct/kg_endpoints_*.dart`（7 个）+ `lib/core/direct/kg_play_api.dart`
- 判定口径：`docs/REVIEW_SPEC.md` / `docs/TASK_b4_r1b.md`（原生域名优先，kapi 仅兜底）

---

### lib/core/direct/kg_endpoints_search.dart:58 歌曲搜索走 /v3 但参数集与 Node v2 不完全对齐
- 级别：P2
- 依据：`return kg.request('/v3/search/song', baseUrl: 'https://complexsearch.kugou.com', params: {..., 'platform': 'AndroidFilter', 'iscorrection': q['iscorrection'] ?? 1, 'privilegefilter': q['privilegefilter'] ?? 0, 'area_code': q['area_code'] ?? 1, 'dopicfull': 1, if (kg.lite) 'clientver': 201})`；Node `module/search.js` 的 song 分支为 `/v2/search/song` + `headers: {'x-router': 'complexsearch.kugou.com'}`，参数 `page/pagesize(30)/platform/iscorrection/privilegefilter/area_code/dopicfull`。域名与签名方式本身合规（baseUrl 直连 `complexsearch.kugou.com`），但 v3 未复刻 Node 的 `x-router` 语义仅靠 baseUrl，且 v3 与 v2 的返回结构差异（HQ/SQ/Res.Hash 是否存在）完全依赖注释声称「0 差异」，代码未做兼容分支。
- 影响：若 v3 结构与下游 `KgSong` 解析假设不一致，搜索结果可能出现音质标签/Hash 缺失；搜索域虽有直连实现，一旦 v3 形态变化无降级通路。

### lib/core/direct/kg_endpoints_search.dart:80 专辑搜索缺少 `searchsong`/`sorttype` 之外的 Node 默认项与 pagesize 一致性
- 级别：P2
- 依据：代码 `pagesize: q['pagesize'] ?? 20`，`category: q['category'] ?? '1'`，`sorttype: '${q['sorttype']}' == '1' ? 1 : 0`；Node 同为 pagesize 20、category '1'、`Number(params?.sorttype) === 1 ? 1 : 0`。字段一致，但代码用字符串比较 `'${q['sorttype']}' == '1'`，当上游传数值 `1` 时成立，传 `true`/`'01'` 等则退化为 0，与 Node `Number()` 语义不同。
- 影响：专辑排序参数在非标准传参下静默失效（「最新」排序不生效），用户看到顺序错误。

### lib/core/direct/kg_endpoints_search.dart:100 通用搜索（special/author/mv/lyric）参数集与 Node 不一致，分页默认值不同
- 级别：P1
- 依据：代码 `kg.request('/v1/search/$type', baseUrl: 'https://complexsearch.kugou.com', params: {'keyword', 'page', 'pagesize': q['pagesize'] ?? 20, 'platform': 'AndroidFilter', if tag, if lite clientver})`；Node `module/search.js` 该分支 `dataMap = {albumhide: 0, iscorrection: 1, keyword, nocollect: 0, page, pagesize: params?.pagesize || 30, platform: 'AndroidFilter'}`，并带 `headers: {'x-router': 'complexsearch.kugou.com'}`。Flutter 缺 `albumhide`/`nocollect`/`iscorrection` 三个字段，且 pagesize 默认 20 vs 30。
- 影响：歌手/MV/歌单搜索结果条数与服务端默认分页不一致，`hasMore` 计算（依赖 pagesize 与返回条数比较）会偏差；缺 `nocollect=0` 时服务端可能返回收藏态差异字段。

### lib/core/direct/kg_endpoints_search.dart:112 歌词搜索走无版本 `/search` 且 notSignature，违反既定口径与 Node 路径
- 级别：P1
- 依据：`kg.request('/search', baseUrl: 'https://lyrics.kugou.com', method: 'GET', clearDefaultParams: true, notSignature: true, params: {'appid', 'clientver', 'keyword', 'lrctxt': 1, 'man': ..., if durationSec>0 'duration': q['duration_ms'] ?? durationSec*1000, if hash, if album_audio_id})`。任务口径明确「`lyrics.kugou.com` `/v1/search` 必须带 signature」；Node `module/search_lyric.js` 为 `url: '/v1/search'`，`clearDefaultParams: true, notSign: true`。本实现把路径改成 `/search`（无版本前缀）并主动 `notSignature`，与口径要求的签名/版本均不符。另外 Node 固定下发 `album_audio_id: 0`、`duration: 0`、`hash: ''`，Flutter 在值为空时整条省略。
- 影响：直连歌词搜索若因缺 signature / 版本路径被服务端拒绝（空响应体 + `x-kg-errcode`），只能整段回退 kapi，属「直连恒失败只能靠 kapi」的隐性依赖；歌词候选拿不到时用户看到无歌词。

### lib/core/direct/kg_endpoints_search.dart:136 歌词下载 `ver` 传数值 1、`client` 默认 android，与 Node 一致但 fmt 非法值无校验
- 级别：P2
- 依据：代码 params `{'ver': 1, 'client': q['client'] ?? 'android', 'id': q['id'], 'accesskey': q['accesskey'], 'fmt': fmt, 'charset': 'utf8'}`，`fmt = q['fmt'] ?? 'krc'`；Node `lyric.js` 同字段同默认，`charset: 'utf8'` 一致，URL `/download`、baseURL `lyrics.kugou.com` 一致。差异在于 `id`/`accesskey` 直接透传，`q['id']` 为 null 时仍会拼出 `id=null`（Dio query 序列化为 "null"），Node 亦如此，但 Flutter 无任何空值拦截。
- 影响：缺 id/accesskey 时向服务端发 `id=null&accesskey=null`，得到无意义错误体，用户侧表现为「歌词加载失败」而非参数错误提示。

### lib/core/direct/kg_endpoints_search.dart:139 decode 分支仅处理 content 为 String 的情况，且未校验 contenttype 类型
- 级别：P2
- 依据：`if (content is String && content.isNotEmpty) { final contenttype = body['contenttype']; if (fmt == 'lrc' || contenttype != 0) { body['decodeContent'] = utf8.decode(base64.decode(content), allowMalformed: true); } }`。Node 为 `params?.fmt == 'lrc' || Number(res.body?.contenttype) !== 0`。Flutter 用 `contenttype != 0` 直接与动态类型比较：当服务端返回字符串 `"0"` 时 `"0" != 0` 为 true，会误判为「非 KRC」而按 base64 解码 KRC 内容；且 `decode=true` 只对 lrc/base64 生效，KRC 走 `decodeLyrics` 的分支完全缺失（Node 有 `decodeLyrics(content)`）。
- 影响：KRC 格式歌词在 `decode=true` 时不会解密（无 decodeContent），或字符串型 contenttype 导致把 KRC 当 base64 解出乱码，卡拉OK 逐字歌词无法显示。

---
### lib/core/direct/kg_endpoints_playlist.dart:26 取消收藏歌单 `p` 大小写/`key` 签名与 Node 一致，但解密失败静默回落原始密文
- 级别：P2
- 依据：`final p = KgCrypto.rsaEncryptPkcs1(jsonEncode({'aes': aes.key, 'uid': userid, 'token': kg.token})).toUpperCase();`，`'key': KgSignature.paramsKey('$clienttime')` —— 与 Node `playlist_del.js:20,24`（`rsaEncrypt2({...}).toUpperCase()`、`signParamsKey(clienttime.toString())`）一致。但解密段 `if (decoded.containsKey('status')) return ...; } catch (_) {} return res;`：解密成功却没有 `status` 键、或解密抛错时，直接返回 `res`（`body` 是 kg_client 里 `{'status':0,'error':'响应解析失败',...}` 的占位体）。
- 影响：取消收藏实际已在服务端生效，UI 却拿到 `status=0` 判为失败，用户看到「操作失败」并可能重复点击（写操作语义错报）。

### lib/core/direct/kg_endpoints_playlist.dart:78 playlistAdd 硬编码 `source: 1` 且 `is_pri` 无条件下发，忽略入参
- 级别：P2
- 依据：`data: {..., 'type': type, 'source': 1, 'is_pri': 0, ...}`；Node `playlist_add.js:13,21-23`：`source: params.source === 0 ? 0 : params.source || 1`，且 `if (params.type === 0) dataMap['is_pri'] = params.is_pri || 0`。Flutter 既不读 `q['source']` 也不读 `q['is_pri']`。
- 影响：调用方想建「私密歌单」或指定 source 时参数被丢弃，新建歌单始终公开、来源固定，用户设置不生效。

### lib/core/direct/kg_endpoints_playlist.dart:118 加歌资源对象缺 `number/size/sort/timelen/bitrate` 五个字段
- 级别：P1
- 依据：`_parseTracksResource` 返回 `{'name','hash','album_id','mixsongid'}`；Node `playlist_tracks_add.js:8-21` 返回 `{number: 1, name, hash, size: 0, sort: 0, timelen: 0, bitrate: 0, album_id, mixsongid}`。文件内注释自称「Node 把串解析成对象数组再发送」，但对象形状并未对齐。
- 影响：`/cloudlist.service/v6/add_song` 对 data 元素字段完整性敏感，缺 `number`/`timelen` 时可能整条被丢弃或写入时长 0 的条目——用户「加歌成功」提示后歌单里看不到歌（或显示 00:00）。

### lib/core/direct/kg_endpoints_playlist.dart:150 删歌同时使用路径前缀 `cloudlist.service/` 与 `x-router` 头，且 body 多出 Node 没有的字段
- 级别：P1
- 依据：`kg.request('/cloudlist.service/v4/delete_songs', method: 'POST', headers: {'x-router': 'cloudlist.service.kugou.com'}, data: {..., 'area_code': 1, 'allplatform': 1})`；Node `playlist_tracks_del.js:19-24` 为 `url: '/v4/delete_songs'` + `headers: {'x-router': 'cloudlist.service.kugou.com'}`，body 只有 `listid/userid/data/type/token/list_ver`。其余同类方法（`userPlaylist` 用 `/v7/get_all_list`、`userPlaylistTracks` 用 `/v4/get_list_all_file_v3`）都是「裸路径 + x-router」，唯此方法路径带服务前缀。
- 影响：路径前缀与 `x-router` 叠加可能导致网关 404/路由错乱，删歌恒失败并回退 kapi（写操作回退还有重复提交风险）；`area_code`/`allplatform` 不属于该端点契约，可能触发参数校验错误。

### lib/core/direct/kg_endpoints_playlist.dart:180 userPlaylist 的 query `userid` 传字符串，Node 传 Number
- 级别：P2
- 依据：`params: {'plat': 1, 'userid': userid, 'token': kg.token}`，`userid` 来自 `kg.userid`（String）；Node `user_playlist.js:21` 为 `params: { plat: 1, userid: Number(userid), token }`。
- 影响：`userid` 为 `'0'`（匿名）时签名串与 Node 一致，但已登录时若 `kg.userid` 含非数字字符（如空串兜底后残留），服务端解析为 0，返回空歌单列表。

### lib/core/direct/kg_endpoints_playlist.dart:210 playlistDetail 请求体缺 `userid`/`token`，且超 10 个 id 静默截断
- 级别：P1
- 依据：`return kg.request('/v3/get_list_info', method: 'POST', baseUrl: 'https://pubsongs.kugou.com', data: {'data': [for (final id in ids.take(10)) {'global_collection_id': id}]})`；Node `playlist_detail.js:6-10` 的 `dataMap = { data, userid: params?.userid || params?.cookie?.userid || 0, token: params?.token || params?.cookie?.token || '' }`。域名本身合规（`pubsongs.kugou.com` 原生域，Node 用 `x-router: pubsongs.kugou.com` 等价）。
- 影响：缺 `userid`/`token` 时，自己创建的私密歌单、VIP 歌单详情拿不到（或返回游客态字段），用户点进「我的歌单」详情为空/信息不全；一次传 >10 个 gid 时后续 id 被静默丢弃，批量场景少数据。

### lib/core/direct/kg_endpoints_playlist.dart:220 playlistDetail 空 ids 不做前置校验，直接发 `data: []`
- 级别：P2
- 依据：`ids` 由 `'${q['ids'] ?? q['global_collection_id'] ?? ''}'.split(',')...where(isNotEmpty)` 得到，为空时 `data: []` 照发；文件自身注释已写明「`data` 必须 1..10 项」，v2 会返回 `data len need in [1, 10]`。
- 影响：上游参数缺失时打一次必失败请求，回退 kapi 后仍失败，用户侧只看到通用错误。

### lib/core/direct/kg_endpoints_playlist.dart:236 playlistTrackAll 对纯数字 id 改发 `specialid`，与 Node 单键 `global_collection_id` 不一致
- 级别：P2
- 依据：`final isCollection = rawId.startsWith('collection_'); ... if (isCollection) 'global_collection_id': rawId else 'specialid': rawId`；Node `playlist_track_all.js:15` 恒发 `global_collection_id: params?.id`，url 为 `/pubsongs/v2/get_other_list_file_nofilt`（Flutter 改走 `https://pubsongs.kugou.com/v2/get_other_list_file_nofilt`，域名等价合规）。`specialid` 分支是 Node 不存在的自创参数键。
- 影响：`specialid` 形态未经 Node 侧验证，若服务端忽略该键则返回空列表；用户从「数字歌单 id」入口进入时歌单显示为空，且 `begin_idx`/`pagesize` 分页也随之失效。

---
### lib/core/direct/kg_endpoints_comment.dart:24 歌曲评论走 gateway 根路径 `/mcomment/v1/cmtlist`，未走 `x-router: m.comment.service.kugou.com`
- 级别：P1
- 依据：`kg.request('/mcomment/v1/cmtlist', method: 'POST', params: {...})`，无 `headers` 参数；Node `comment_music.js:16-22` 同样无 x-router/baseURL（默认 gateway）。但本项目口径写明「评论走 `x-router: m.comment.service.kugou.com`」，且同文件其它方法（commentSend/commentFloorSend/commentDel/commentCount）都显式带 x-router。此处依赖 gateway 根路径下挂 mcomment 服务的隐式路由。
- 影响：与口径不一致；一旦 gateway 根路径不再代理 mcomment 服务（或路由前缀调整），歌曲评论列表恒失败只能回退 kapi，用户看到评论为空。

### lib/core/direct/kg_endpoints_comment.dart:49 commentCount 的 `hash`/`childrenid` 互斥判定与 Node 一致，但 `special_id` 为 0/空串时仍下发
- 级别：P2
- 依据：`if (q['hash'] != null) 'hash': q['hash'], if (q['hash'] == null && q['special_id'] != null) 'childrenid': q['special_id']`；Node `comment_count.js:9-13` 为 `if (params.hash) ... else if (params.special_id) ...`（真值判定）。Flutter 只判 `!= null`，`hash=''` 时会发空 hash 且不发 childrenid。
- 影响：传入空串 hash 时请求退化为「既无 hash 也无 childrenid」，评论数返回 0 或错误，UI 显示 0 条评论。

### lib/core/direct/kg_endpoints_comment.dart:73 发评论请求体缺 `extdata`（content_extdata），`source` 也未透传
- 级别：P2
- 依据：`final contentData = {'content': ..., if (q['mixsongid'] != null) 'album_audio_id': ..., if (q['title'] != null) 'title': ..., 'images': const <String>[]}`；Node `_comment.js:106-113` 为 `compact({content, album_audio_id: firstValue(mixsongid, album_audio_id), title, extdata: params.content_extdata, images: ...})`，query 另有 `source: params.source`。
- 影响：带扩展上下文（如「正在听第几句歌词」、来源标识）的评论会丢失这些字段，服务端可能判为不完整请求；评论列表里展示的来源标签缺失。

### lib/core/direct/kg_endpoints_comment.dart:88 发评论 query 缺 `source`，且 `childrenname` 只认 `q['name']`
- 级别：P2
- 依据：query 中 `if (q['name'] != null) 'childrenname': '${q['name']}'`；Node `_comment.js:121` 为 `firstValue(params.name, params.song_name, params.album_name, params.playlist_name, params.childrenname)`。
- 影响：调用方只传 `song_name`/`album_name` 时 childrenname 缺失，服务端可能返回「资源不存在」类错误，发评论失败。

### lib/core/direct/kg_endpoints_comment.dart:126 楼中楼回复缺 `is_t`（顶层回复标记）与 `pid` 默认 0，且未做 `//@` 拼接
- 级别：P1
- 依据：`params: {..., 'content': content, 'tid': '${q['tid'] ?? ''}', if (q['pid'] != null) 'pid': '${q['pid']}'}`；Node `_comment.js:141-176`：`const pid = firstValue(params.pid, 0); const isTopLevelReply = firstValue(params.is_t, params.isT, `${pid}` === '0' ? 1 : 0);`，query 固定带 `is_t: isTopLevelReply, pid`，并按 `reply_user_name`/`reply_content` 拼 `content + '//@user:reply'`，另有 `extdata`。
- 影响：缺 `is_t` 时服务端无法区分「楼中楼回复」与「主楼回复」，回复可能被丢弃或挂错层级；缺 `//@` 前缀时被回复者收不到提醒，用户看到「回复成功」但对方无感知。

### lib/core/direct/kg_endpoints_comment.dart:161 删除评论用 POST，Node 为 GET（且无 body）
- 级别：P1
- 依据：`kg.request('/index.php', method: 'POST', clearDefaultParams: true, notSignature: true, headers: {'x-router': 'm.comment.service.kugou.com'}, params: {...'r': 'commentsv2/delcomment'...})`；Node `_comment.js:57-69` 的 `commentRequestConfig(params, query, method = 'GET', data)`，`buildCommentDelConfig` 未传 method → **GET**，注释亦写明「GET 无 body」。
- 影响：method 与 Node 不一致，服务端可能返回参数错误；删除评论失败但 UI 已从列表移除（或反之），用户看到评论「删了又回来」。

### lib/core/direct/kg_endpoints_comment.dart:170 删除评论缺 `cid` 强校验，`cid` 为空仍下发 `cid=`
- 级别：P2
- 依据：`'cid': '${q['cid'] ?? ''}'` 无条件下发；Node `_comment.js:197` 为 `cid: firstValue(params.cid, params.comment_id)`，经 `compact()` 过滤空串后不下发。Flutter 无 `comment_id` 别名，也无空值拦截。
- 影响：调用方用 `comment_id` 命名时 cid 变成空串，服务端删除失败；且请求已发出，属无效写请求。

### lib/core/direct/kg_endpoints_comment.dart:198 commentPlaylist / commentAlbum 用路径前缀 `/m.comment.service/v1/cmtlist` 而非 x-router
- 级别：P2
- 依据：`kg.request('/m.comment.service/v1/cmtlist', method: 'POST', params: {...})` 无 headers；Node `comment_playlist.js:16-22`、`comment_album.js:14-20` 同样用 `url: '/m.comment.service/v1/cmtlist'` 无 x-router。与 Node 一致，但与本项目「评论走 x-router」口径不符，且与 commentFloor 中「playlist/album → 带前缀路径」的自述注释混用两种路由方式。
- 影响：同一评论域存在两套路由约定（前缀路径 vs x-router），后续维护易错；服务端若统一要求 x-router，歌单/专辑评论会静默失败。

### lib/core/direct/kg_endpoints_comment.dart:228 commentFloor 的 `code` 忽略调用方显式传入值，路由判定也不看 code
- 级别：P2
- 依据：`'code': switch (resourceType) {'playlist' => ..., 'album' => ..., _ => songCode}`，且 `isPlaylistOrAlbum` 只看 `resource_type`；Node `comment_floor.js:14-26` 先取 `params.code`（isNonEmpty），再 `useServiceEndpoint = resourceType==='playlist' || 'album' || code===playlistCode || code===albumCode`。
- 影响：调用方传 `code`（如自定义评论池）时被覆盖，且当 resource_type 缺省但 code 是歌单码时走错端点，楼中楼列表恒空。

### lib/core/direct/kg_endpoints_comment.dart:241 commentFloor 的 `tid` 无条件以字符串下发、`childrenid` 仅取 `special_id`
- 级别：P2
- 依据：`'childrenid': q['special_id'], ... 'tid': q['tid']`；Node 为 `childrenid: params.special_id, tid: params.tid`（经 compact 过滤空值）。Flutter 在 `special_id` 为 null 时仍会带 `childrenid=null` 语义（Dio 会跳过 null，但 `''` 不会）。
- 影响：`special_id=''` 时向服务端发空 childrenid，返回 err_code≠0，楼层展开空白。

---
### lib/core/direct/kg_endpoints_media.dart:22 kmrAudioMv 域名与 KG-TID 合规，但 `album_audio_id` 全空时不做前置校验
- 级别：P2
- 依据：`baseUrl: 'https://openapi.kugou.com'` + `headers: {'KG-TID': '38'}` + `data: {'data': ids.map(...), 'fields': q['fields'] ?? ''}` —— 与 Node `kmr_audio_mv.js:12-19`（`x-router: openapi.kugou.com`、`KG-TID: 38`、`data/fields`）逐字段等价，域名原生合规。但 `ids` 为空时仍发 `data: []`；Node 侧同样会发空数组，差异在于 Flutter 无任何拦截。
- 影响：`album_audio_id` 缺失时打一次必失败请求，`_directOrFallback` 再回退 kapi 又失败，MV 入口报通用网络错误而非「无 MV」。

### lib/core/direct/kg_endpoints_media.dart:44 videoUrl 缺 `encryptKey` 对应的 key 语义校验，hash 未小写
- 级别：P2
- 依据：`'key': KgSignature.keyOf(hash: hash, mid: kg.device.mid, userid: kg.userid, lite: kg.lite)` 中 `hash` 直接取 `'${q['hash'] ?? ''}'` 原值；Node `util/request.js:135` 的 `params['key'] = signKey(params['hash'], ...)` 也用原值，但同项目 `/v5/url`（`KgSharedParams.songUrl`）明确要求小写 hash。同一 App 内两处 hash 大小写策略不一致。
- 影响：上游返回大写 hash 时（部分接口回传大写），MV `key` 校验串与资源 hash 不匹配，视频地址取不到，用户点 MV 无反应。

### lib/core/direct/kg_endpoints_media.dart:96 songUrl 由 `kg.request` 自动补 `signature`，而 Node 该端点是 `notSign: true`（不签名）
- 级别：P1
- 依据：`return kg.request('/v5/url', method: 'GET', baseUrl: 'https://trackercdn.kugou.com', params: params);` —— `kg.request` 在 `notSignature` 为 false 时无条件写入 `allParams['signature'] = KgSignature.android(...)`（`kg_client.dart:216-224`）；Node `song_url.js:42-51` 为 `headers: {'x-router': 'trackercdn.kugou.com'}, encryptKey: true, notSign: true`，即**只带 key、不带 signature**。
- 影响：请求参数形态与 Node 不一致（多出 signature），上游可能按「签名与 encryptKey 端点不匹配」返回 20006/20028；一旦被判风控，`_directOrFallback` 静默回退 kapi，播放地址依赖 kapi 中转——属「参数写错导致直连假失败」。

### lib/core/direct/kg_endpoints_media.dart:99 songUrl 的 `free_part` 判定与 Node 真值语义不同
- 级别：P2
- 依据：`freePart: '${q['free_part']}' == '1' || '${q['free_part']}' == 'true'`；Node `song_url.js:35` 为 `IsFreePart: params?.free_part ? 1 : 0`（任意真值，含 `'yes'`/`1`/`true` 乃至非空串）。
- 影响：调用方传 `free_part=yes` 或数值以外的真值时试听部分不生效，试听片段拿不到，UI 变成「无版权/无法播放」。

### lib/core/direct/kg_endpoints_media.dart:110 privilege 未校验空 hash 列表，空 resource 直接上行
- 级别：P1
- 依据：`final hashes = '${q['hash'] ?? ''}'.split(',');` 交给 `KgSharedParams.privilege`，其内部 `continue` 掉空项后可能得到 `resource: []`，请求照发；Node `privilege_lite.js:135-141` 有显式前置拦截：`if (!hashList.length) return Promise.reject({status: 502, body: {status: 0, error_code: -1, error: '缺少歌曲 hash'}})`。
- 影响：hash 缺失时上游返回 20010，被 `_wrap` 判失败后静默回退 kapi（同样失败），用户点开歌曲详情时音质/VIP 标签全部空白，且错误信息被替换成通用文案。

### lib/core/direct/kg_endpoints_media.dart:113 privilege 的 `resource[].album_id` 缺失时填字符串 `'0'`，Node 填数值 0
- 级别：P2
- 依据：`KgSharedParams.privilege` 中 `'album_id': i < albumIds.length ? albumIds[i] : '0'`，且 `albumIds` 来自 `'${q['album_id'] ?? ''}'.split(',')`（空串时得到 `['']`）；Node `privilege_lite.js:147-152` 为 `album_id: albumIdList[index] || 0`（空串回落数值 0）。
- 影响：album_id 为空串时上行 `album_id: ''`，上游可能按字符串解析失败返回 20010，权益查询降级为空，VIP/付费标记缺失。

### lib/core/direct/kg_endpoints_media.dart:118 privilege 的 `x-router` 合规但 `Content-Type` 与 Node 完全一致，无问题；另注 `media.store.kugou.com` 三标签证书限制属实
- 级别：P2（既知约束，需登记）
- 依据：`headers: {'x-router': 'media.store.kugou.com', 'Content-Type': 'application/json'}`，与 Node `privilege_lite.js:186` 一致；走 `gateway.kugou.com`（原生域）+ x-router 属合规路径，但本端点**无法**改成 `https://media.store.kugou.com` 直连——三标签域名不在 `*.kugou.com` 证书 SAN 内。
- 影响：该端点永久依赖 gateway 路由层；若 gateway 变更路由，权益接口整体失效且只能回退 kapi。

---
### lib/core/direct/kg_endpoints_artist_album.dart:24 artistDetail 走 gateway + x-router（未用 openapi 原生域名），与口径对照表不一致
- 级别：P2
- 依据：`kg.request('/kmr/v3/author', method: 'POST', data: {'author_id': ...}, headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'})`，baseUrl 取默认 `gateway.kugou.com`；Node `artist_detail.js:3-10` 同样无 baseURL、仅 x-router（所以行为一致）。但项目对照表要求 `/kmr/v3/author` 打 `openapi.kugou.com`，且同文件 `artistAudios` 的 Node 版本**有** `baseURL: 'https://openapi.kugou.com'`。
- 影响：依赖 gateway 的服务路由层而非原生域；若 gateway 前缀路由调整，歌手详情全线失败并回退 kapi（kapi 又依赖同一 Node 实现，属闭环依赖）。

### lib/core/direct/kg_endpoints_artist_album.dart:36 artistAudios 丢掉了 Node 的 `baseURL: openapi.kugou.com`，退化到 gateway + x-router
- 级别：P1
- 依据：Flutter 为 `kg.request('/kmr/v1/audio_group/author', method: 'POST', data: {...}, headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'})`，无 `baseUrl`；Node `artist_audios.js:20-28` 明确 `baseURL: 'https://openapi.kugou.com'` **且有** x-router。任务口径亦写明「歌手单曲 `/kmr/v1/audio_group/author` 必须 v1、openapi.kugou.com」。
- 影响：本端点本是「可用原生域名直连」的路径，却被改成经 gateway 转路由；一旦 gateway 侧 kmr 路由变更/限流，歌手全部歌曲列表恒失败只能回退 kapi，违背「禁止以 kapi 作为实现」的硬口径。

### lib/core/direct/kg_endpoints_artist_album.dart:40 artistAudios 的 `clienttime` 以**字符串**进 body，Node 为数值
- 级别：P2
- 依据：`final clienttime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';` → body `'clienttime': clienttime`（String）；Node `artist_audios.js:5,11`：`const clienttime = Math.floor(...)`（Number）。`key = KgSignature.paramsKey(clienttime)` 两者字符串化后一致，但 body JSON 里类型不同（`"clienttime":"1730..."` vs `"clienttime":1730...`）。
- 影响：若上游对 body 字段做类型校验，可能返回 20010/20006，列表为空；直连假失败后静默回退 kapi。

### lib/core/direct/kg_endpoints_artist_album.dart:42 artistAudios 把 pagesize 静默截断到 100，Node 原样下发
- 级别：P2
- 依据：`var ps = int.tryParse('${q['pagesize'] ?? 30}') ?? 30; if (ps > 100) ps = 100;`；Node `artist_audios.js:14` 为 `pagesize: params?.pagesize || 30`（无上限）。注释自称「超过 error_code=20010」是实测结论，但这对上层是不可见的行为改变。
- 影响：上层按请求的 pagesize 计算 `hasMore`/总页数时与实际返回条数不符，歌手歌曲翻页出现重复或漏歌。

### lib/core/direct/kg_endpoints_artist_album.dart:112 rankAudio 的 `rank_id` 缺省填 0，Node 不下发该键
- 级别：P2
- 依据：`'rank_id': int.tryParse('${q['rankid'] ?? q['rank_id'] ?? 0}') ?? 0`；Node `rank_audio.js:12` 为 `rank_id: params.rankid`（undefined 时 JSON.stringify 丢弃该键）。域名/路径（gateway `/openapi/kmr/v2/rank/audio`）+ `kg-tid: '369'` 与 Node 一致，合规。
- 影响：调用方漏传 rankid 时上行 `rank_id=0`，上游可能回落到某个默认榜或直接报参数错误，榜单页显示错误歌曲。

### lib/core/direct/kg_endpoints_artist_album.dart:118 rankAudio 的 `type`/`area_code` 硬编码与 Node 一致，无问题；但 `page`/`pagesize` 强转后非法值静默变 1/30
- 级别：P2
- 依据：`'pagesize': int.tryParse('${q['pagesize'] ?? 30}') ?? 30, 'page': int.tryParse('${q['page'] ?? 1}') ?? 1`；Node 直接透传字符串（`params.pagesize || 30`），非法值由上游报错。
- 影响：上游传 `page='2abc'` 类脏值时被吞成 1，用户翻页后跳回第一页且无任何提示。

### lib/core/direct/kg_endpoints_artist_album.dart:140 albumSongs 的 `is_buy` 用 `?? ''`，Node 用 `|| ''`（0/false 处理不同）
- 级别：P2
- 依据：`'is_buy': q['is_buy'] ?? ''`；Node `album_songs.js:5` 为 `is_buy: params?.is_buy || ''`。传 `is_buy: 0` 时 Flutter 上行 `0`、Node 上行 `''`。
- 影响：付费专辑场景下 is_buy=0 可能被上游判为「非购买态」而过滤曲目，专辑页少歌。

---
### lib/core/direct/kg_endpoints_home.dart:18 yueku 走 gateway + x-router，原生 `service.mobile.kugou.com` 未使用（证书限制声明需核实）
- 级别：P2
- 依据：`kg.request('/v1/yueku/recommend_v2', method: 'GET', headers: {'x-router': 'service.mobile.kugou.com'}, params: {...})`，无 baseUrl；Node `yueku.js:3-11` 同样仅 x-router → 行为与 Node 一致，且属「gateway 原生域 + x-router」合规路径。但注释以「网宿 CDN 证书 CN=default.chinanetcenter.com」为由放弃原生域，该说法未在代码内留下验证证据。
- 影响：若该理由不成立（CDN 已换证书），本可直连的端点多绕一层 gateway；一旦 gateway 路由变更即全线失效并回退 kapi。

### lib/core/direct/kg_endpoints_home.dart:33 rankList 改了 Node 的路径前缀写法（`/ocean/v6/rank/list` → 原生域 `/v6/rank/list`），符合口径但无 x-router 兜底
- 级别：P2
- 依据：`baseUrl: 'https://ocean.kugou.com'` + `/v6/rank/list`；Node `rank_list.js:11` 为 `url: '/ocean/v6/rank/list'`（gateway 前缀路由）。域名对照表要求 `ocean.kugou.com` 用于榜单列表，Flutter 实现符合口径。但一旦 `ocean.kugou.com` 直连不可达，本端点没有第二原生域名通路。
- 影响：榜单页在 ocean 域名被墙/限流时整体空白，且回退 kapi 仍走同一上游。

### lib/core/direct/kg_endpoints_home.dart:47 topSong 的 `userid` 缺省回落 `kg.userid`，Node 回落 0
- 级别：P2
- 依据：`'userid': q['userid'] ?? kg.userid`；Node `top_song.js:7` 为 `params?.userid || params?.cookie?.userid || 0`。匿名态 `kg.userid == '0'` 时等价；但 `kg.userid` 为 `''` 时会下发空串（Node 会落到 0）。
- 影响：userid 空串上行可能触发参数校验失败，新歌速递列表为空。

### lib/core/direct/kg_endpoints_home.dart:64 everydayRecommend 只发 query 无 body，Node 同形；但 `platform` 白名单未校验
- 级别：P2
- 依据：`params: {'platform': '${q['platform'] ?? 'ios'}'}`；Node `everyday_recommend.js:6` 为 `platform: params.platform || 'ios'`。字段一致。
- 影响：调用方传非法 platform 时直连返回空/报错，日推页无内容且无降级（平台参数不在本地校验范围）。

### lib/core/direct/kg_endpoints_home.dart:74 topPlaylist 已确认「直连恒 200101、依赖 kapi」——登记为既知约束但仍属硬口径违背
- 级别：P1（既知约束，需显式登记）
- 依据：`kg.request('/v2/special_recommend', method: 'POST', headers: {'x-router': 'specialrec.service.kugou.com'}, data: {...})`，注释自述「special_recommend 直连恒 ec=200101（匿名/VIP、多组参数均复现）」→ `_directOrFallback` 每次必落 kapi `/top/playlist`。另与 Node `top_playlist.js:8-17` 对比，`special_recommend` 内层缺 `sort: 1`、`ugc: 1`、`is_selected: 0`、`withrecommend: 1`、`area_code: 1` 五个字段（Flutter 只有 `withtag/withsong/categoryid/tagids`，且多了 Node 没有的 `tagids`）。
- 影响：推荐歌单页 100% 依赖 kapi 中转，违反「禁止以 kapi 作为实现」；且内层字段缺失本身可能就是 200101 的成因之一（未排除参数写错导致直连假失败）。

### lib/core/direct/kg_endpoints_home.dart:82 topPlaylist 的 `userid` 以字符串下发，Node 用 `|| 0` 兜底
- 级别：P2
- 依据：`'userid': kg.userid`（可能为空串）；Node `top_playlist.js:25` 为 `params?.userid || params?.cookie?.userid || 0`。
- 影响：空串 userid 进入 body 与 `key` 无关（key 只含 clienttime），但会导致上游个性化参数无效，即使修好 200101 也拿不到登录态推荐。

### lib/core/direct/kg_endpoints_home.dart:98 searchHot 原生域名合规，但 `navid`/`plat` 默认值与 Node 的硬编码语义不同
- 级别：P2
- 依据：`params: {'navid': q['navid'] ?? 1, 'plat': q['plat'] ?? 2}` + `baseUrl: 'https://msearch.kugou.com'`；Node `search_hot.js:3-6` 为硬编码 `navid: 1, plat: 2`（不接受入参覆盖）。域名对照（`msearch.kugou.com` 两标签，证书覆盖）成立。
- 影响：调用方传 navid/plat 时行为偏离 Node 基线，热搜分栏可能与官方客户端不一致（取到错误分组）。

### lib/core/direct/kg_endpoints_home.dart:117 yuekuBanner 已知匿名恒 31136，且 `vip_type` 硬编码 0
- 级别：P1
- 依据：`data: {..., 'vip_type': 0, ...}`；Node `yueku_banner.js:10` 同样硬编码 `vip_type: 0`，故与 Node 一致。但注释自述「匿名态恒 error_code=31136 → 回退 kapi（同样 31136）→ fetchBanners 容错置空」：每次进入乐库都发两次必失败请求（直连 + kapi）。
- 影响：Banner 位永久空白；每次进首页浪费一个直连 + 一个 kapi 请求，弱网下加重首屏延迟；且 `vip_type: 0` 使 VIP 账号也拿不到会员专属 banner（三态兼容缺失）。

### lib/core/direct/kg_endpoints_home.dart:157 videoDetail 的 `uuid` 由 md5(dfid+mid) 计算，与全局 `uuid: '-'` 口径不一致
- 级别：P2
- 依据：`'uuid': KgCrypto.md5('$dfid${kg.device.mid}')`；Node `video_detail.js:6` 为 `cryptoMd5(`${dfid}${mid}`)`（一致）。但 `kg_client.dart` 的默认参数恒用 `uuid: '-'`（注释明确「维持既往实测结论」），同一 App 内两种 uuid 策略并存。
- 影响：服务端若按 uuid 做设备一致性校验（dfid/mid/uuid 三元组），视频详情请求会被判为异常设备，返回风控错误并回退 kapi。

### lib/core/direct/kg_endpoints_home.dart:170 videoDetail 的 `data` 数组对空 id 静默跳过，Node 保留空项导致 body 结构不同
- 级别：P2
- 依据：`for (final id in '${q['id'] ?? q['ids'] ?? ''}'.split(',')) if (id.trim().isNotEmpty) {'video_id': id.trim()}`；Node `video_detail.js:10` 为 `(params.id || '').split(',').map((s) => ({video_id: s}))`（空串时得到 `[{video_id: ''}]`）。`clearDefaultParams: true` 的使用此处与 Node 一致且属允许的 5 处之一。
- 影响：id 为空时 Flutter 发 `data: []`，上游返回空数组或 20010；与 Node 的 `[{video_id:''}]` 行为不同，错误码也不同，UI 提示文案可能失真。

---
### lib/core/direct/kg_endpoints_auth.dart:56 验证码发送走 **明文 http** `http://login.user.kugou.com`
- 级别：P1
- 依据：`kg.request('/v7/send_mobile_code', baseUrl: 'http://login.user.kugou.com', method: 'POST', data: {'businessid': 5, 'mobile': '${q['mobile']}', 'plat': 3})`。Node `captcha_sent.js:10` 亦为 `http://`，但同文件其它登录接口全用 `https://loginserviceretry.kugou.com` / `https://login-user.kugou.com`。
- 影响：手机号以明文经 HTTP 传输（可被中间人读取/篡改），且 Android 9+ 默认禁明文流量，若 manifest 未开 `usesCleartextTraffic` 则请求直接失败、验证码永远收不到。

### lib/core/direct/kg_endpoints_auth.dart:70 登录请求未保存 `vip_type` / `vip_token`，三态兼容断裂
- 级别：P1
- 依据：`_afterLogin` 只回写 `kg.token` / `kg.userid` / `kg.t1`（`kg_client.dart` 的 `KgClient` 也只有这三个可变字段，全仓 `vip_type|vip_token` 仅命中 `kg_endpoints_home.dart:144` 的硬编码 0）。Node 在 `login_cellphone.js:66-70`、`login.js:40-42`、`login_token.js:69-73` 均把 `vip_type`、`vip_token` 写入 cookie，供后续 `song_url_new.js:12,40` 的 `viptoken`/`vip` 字段使用。
- 影响：VIP 用户登录后 App 无法感知会员态，音质选择、权益标记、蝰蛇音质入口全部按非 VIP 处理；三态（匿名/非 VIP/VIP）实际退化为两态，VIP 用户被降级。

### lib/core/direct/kg_endpoints_auth.dart:73 `pk` 用裸 RSA 且 **toUpperCase**，与 Node 一致；但 `params`（AES 密文）的 key 派生依赖随机 tempKey，失败时无回滚
- 级别：P2
- 依据：`'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'clienttime_ms': dateTime, 'key': encrypt.key}), lite: lite).toUpperCase()`，`encrypt = KgCrypto.aesEncryptCbcAuto(...)`；Node `login_cellphone.js:27` 同为 `cryptoRSAEncrypt({...}).toUpperCase()`，`encrypt.key` 为随机 tempKey。
- 影响：与 Node 一致，无独立缺陷；但 `_afterLogin(r, encrypt.key)` 一旦 `aesDecryptCbcHex` 因 padding 异常抛错（`catch` 仅打日志），登录返回 `status=1` 却拿不到 token，用户看到「登录成功」但仍为匿名态。

### lib/core/direct/kg_endpoints_auth.dart:88 `mobile` 掩码函数对长度 <11 的号码原样返回，Node 返回空
- 级别：P2
- 依据：`String _maskMobile(String mobile) { if (mobile.length < 11) return mobile; return '${mobile.substring(0, 2)}*****${mobile.substring(10, 11)}'; }`；Node `login_cellphone.js:12` 为 `params?.mobile && \`${mobile.substring(0,2)}*****${mobile.substring(10,11)}\``（短号时 substring 越界得到异常/空，且空手机号整体为 false）。
- 影响：手机号格式非法（10 位、含空格）时，Flutter 会把原始号码明文发给登录接口，Node 则会发空/异常值。用户输错位数时看到「密码错误/验证码错误」而非「手机号格式不正确」。

### lib/core/direct/kg_endpoints_auth.dart:129 密码登录缺 Node 的 `cookie` 透传（t1/t2 常量与 dev 一致，但 `t3` 固定）
- 级别：P2
- 依据：`data: {..., 't3': 'MCwwLDAsMCwwLDAsMCwwLDA=', 'dev': kg.device.dev, 'username': ..., 'params': ..., 'pk': ...}`，`headers: {'x-router': 'login.user.kugou.com'}`；Node `login.js:12-16` 字段相同，`cookie: params?.cookie` 被 Flutter 丢弃（Node 会把 `dfid/mid/...` cookie 一并透传）。
- 影响：Node 侧通过 cookie 携带的 dfid/mid 在 Flutter 只由默认 query 参数补，两者不一致时（dfid 为 '-'）风控可能判定为新设备，登录触发验证码/20034。

### lib/core/direct/kg_endpoints_auth.dart:161 loginToken 的 `t1` 取自 `kg.t1`，但 `kg.t1` 只在 `_afterLogin` 里由 `data['t1']` 赋值
- 级别：P2
- 依据：`final t1Plain = kg.t1.isNotEmpty ? '${kg.t1}|$dateNow' : '|$dateNow';`；Node `login_token.js:27` 为 `params.cookie?.t1 ? ...`。Flutter 的 t1 来源依赖上一次登录响应，`_afterLogin` 中 `final t1 = data['t1']?.toString(); if (t1 != null && t1.isNotEmpty) kg.t1 = t1;` —— 若登录响应不含 t1（部分登录方式），刷新时恒用 `|dateNow`。
- 影响：token 刷新时设备绑定串与上次登录不一致，服务端可能判定 token 与设备不匹配 → 刷新失败 → 用户被强制登出。

### lib/core/direct/kg_endpoints_auth.dart:186 loginToken 的 `pk` 未 toUpperCase，与 Node 一致；但 `t2`/`t1` 仅在 lite 下发，非 lite 传 0
- 级别：P2
- 依据：`'t1': lite ? t1 : 0, 't2': lite ? t2 : 0, 't3': 'MCwwLDAsMCwwLDAsMCwwLDA='`，与 Node `login_token.js:33-35` 相同；但 Flutter 在非 lite 时**仍然计算**了 `t1`/`t2`（AES 加密两次）并丢弃。
- 影响：无功能问题，但每次刷新多两次 AES 计算；更重要的是 `t3` 在 lite 分支也没替换（Node 同样硬编码），概念版登录可能因 t3 缺失设备信息而失败。

### lib/core/direct/kg_endpoints_auth.dart:203 loginQrKey 的 `appid` 与 `qrcode_txt` 内 appid 混用两套值
- 级别：P2
- 依据：`'appid': type == 'web' ? 1014 : 1001`，但 `qrcode_txt: 'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=${KgConfig.appid}&'`（即 1005）；Node `login_qr_key.js:10-14` 与 config 的 `appid` 同源，`type==='web'` 时也是 1014 与 `appid`（1005）混用 —— 行为与 Node 一致，但 `srcappid: 2919` 与 `appid: 1001` 一起出现时上游可能返回不同扫码落地页。
- 影响：Web 扫码的二维码内容指向 1005 的落地页而 key 用 1014 申请，扫码后可能落到错误登录页，用户扫码无反应。

### lib/core/direct/kg_endpoints_auth.dart:225 loginQrCheck 额外下发 `timestamp`/`_t`，Node 无此参数
- 级别：P2
- 依据：`params: {'plat': 4, 'appid': KgConfig.appid, 'srcappid': _qrSrcappid, 'qrcode': q['key'], 'dev': kg.device.dev, 'timestamp': timestamp, '_t': timestamp}`；Node `login_qr_check.js:11-17` 只有 `plat/appid/srcappid/qrcode/dev`。且 Flutter 用 `encryptType: 'web'`，web 签名会把这两个额外参数算进 md5，与 Node 的签名串不同。
- 影响：扫码状态轮询若被上游按签名校验，会返回签名错误（而非 0/1/2/4），二维码扫了也不跳转；即便不校验签名，也属参数形态偏离 Node 基线。

### lib/core/direct/kg_endpoints_auth.dart:225 loginQrCheck 未处理 `data.status==0`（过期）与 2（待确认）的区分，仅透传
- 级别：P2
- 依据：`final data = r.body['data']; if (data is Map && '${data['status']}' == '4') {...}`，其余状态（0 过期 / 1 待扫 / 2 待确认）原样返回；`_wrap` 对 `status==200` 放行（web 二维码接口响应体无 `status` 字段，走兜底 return body）。
- 影响：二维码过期时上层拿不到明确错误（响应无 status 字段，`_wrap` 不抛异常），UI 可能继续显示「等待扫码」直到超时，用户以为网络卡住。

### lib/core/direct/kg_endpoints_auth.dart:264 userDetail 手动回填 `data['userid']`，掩盖上游契约
- 级别：P2
- 依据：`final inner = d['data']; if (inner is Map<String, dynamic>) { inner['userid'] = userid.toString(); }`，注释自述「实测响应无 userid 字段，而上层 AuthRepository 读 data.userid → 回填」。请求参数与 Node `user_detail.js:8-19` 一致（`visit_time/usertype/p/userid` + `plat=1` + x-router usercenter）。
- 影响：userid 来自本地缓存/入参，若 token 已切换到另一账号而 userid 未同步，会把 A 账号的 userid 写进 B 账号的响应，账号信息串号。

### lib/core/direct/kg_endpoints_auth.dart:310 getVerifyInfo 走 gateway 根路径（无 baseUrl），与 Node 一致，但同项目另有一份 `verifyservice.kugou.com` 直连实现
- 级别：P2
- 依据：`kg.request('/verifyservice/v3/get_verify_info', method: 'POST', ...)`（默认 baseUrl `gateway.kugou.com`）；Node `get_verify_info.js:15-21` 同样走默认 gateway。但 `kg_client.dart:submitFingerprintVerification` 用的是 `baseUrl: 'https://verifyservice.kugou.com'` + `/verifyservice/v3/get_verify_info`（路径重复带前缀）。同一逻辑两处形态不同。
- 影响：人机验证链路的 sid/edt 提交与查询走不同域名/路径组合，其中一处（直连域 + 带前缀路径）大概率 404，20028 风控无法通过，表现为「验证码一直失败」。

### lib/core/direct/kg_endpoints_auth.dart:327 verifyUserInfo 的 `pk` 未 toUpperCase，Node 同样未大写（一致）；`v_type=23` 分支缺 `clienttime`
- 级别：P2
- 依据：`if (vType == 23) { ... 'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'key': encrypt.key}), lite: kg.lite), ...}`；Node `verify_user_info.js:24` 为 `cryptoRSAEncrypt({ key: encrypt.key })`（同样无 clienttime）。`verify_user_info.js:4` 声明了 `const clienttime = Date.now();` 却未使用。
- 影响：与 Node 一致，属上游契约遗留；但 `pk` 明文只有 key，服务端若升级要求 clienttime 绑定会直接失败，且无降级。

### lib/core/direct/kg_endpoints_auth.dart:363 registerDev 把 `kg.registerDevice()` 的成功包成 `status: 200` 的 **HTTP 状态**语义
- 级别：P2
- 依据：成功分支 `return KgResponse(status: 200, body: {'status': 1, 'data': {'dfid': ...}})`；失败 `KgResponse(status: 200, body: {'status': 0, 'error': '设备注册失败'})`。`KgResponse.status` 的文档定义为「HTTP 状态（200 成功 / 502 封装失败）」。
- 影响：把业务状态塞进 HTTP 状态字段，`isOk`/`_wrap` 判定链路混用两套语义；失败时 `status=0` 会被 `_wrap` 抛 ApiException，但 `errorCode` 为 0，上层只能看到「请求失败」通用文案。

### lib/core/direct/kg_endpoints_auth.dart:11 core 层 import UI 渲染包 `qr_flutter`
- 级别：P2
- 依据：文件顶部 `import 'package:qr_flutter/qr_flutter.dart';`，并在 `qrPngBase64` 中用 `QrPainter.toImageData(480)` 生成 PNG。`core/` 层直接依赖 Flutter 渲染插件与 `package:flutter/foundation.dart`。
- 影响：core 层被钉死在 UI 插件上，单元测试/无 UI 环境（后台任务、isolate）调用登录链路会因渲染上下文缺失而崩；架构分层（core 不依赖 features/UI）被打破。

---
### lib/core/direct/kg_play_api.dart:44 songUrl 走 gateway + x-router（未用 trackercdn 原生域），同仓另有一份直连 trackercdn 的实现
- 级别：P1
- 依据：`client.requestWithVerify('/v5/url', method: 'GET', params: params, encryptType: 'android', headers: {'x-router': 'trackercdn.kugou.com'})` —— 无 `baseUrl`，落在默认 `gateway.kugou.com`；而 `kg_endpoints_media.dart:96` 的 `songUrl` 用 `baseUrl: 'https://trackercdn.kugou.com'`。项目对照表要求「`trackercdn.kugou.com`（`/v5/url`）」为原生域实现。
- 影响：播放主路径（`KgPlayApi.songUrl` 被 `PlayerRepository._resolveViaDirect` 直接调用）并未落在原生域名上，只有 media 端点那条备用路径走原生域；一旦 gateway 路由变动，播放地址取不到 → 只能回退 kapi，违背后续「禁止以 kapi 作为实现」的硬口径。

### lib/core/direct/kg_play_api.dart:46 songUrl 由 `requestWithVerify` 自动补 `signature`，Node 该端点是 `notSign: true`
- 级别：P1
- 依据：`requestWithVerify` → `request` → `if (!allParams.containsKey('signature') && !notSignature) { allParams['signature'] = ... }`（`kg_client.dart`）；Node `song_url.js:42-51` 明确 `encryptKey: true, notSign: true`，即 `<b>只带 key、不带 signature</b>`。
- 影响：请求多出 signature 参数，服务端若将其纳入校验会返回 20006/20028；直连失败后 `_directOrFallback` 静默回退 kapi，播放依赖中转——属「参数形态错误导致直连假失败」。

### lib/core/direct/kg_play_api.dart:46 songUrl 未带 `dfid` 随机值，Node 为每次请求注入 `randomString(24)`
- 级别：P2
- 依据：Node `song_url.js:50` 为 `cookie: Object.assign({}, {dfid: randomString(24)}, params?.cookie)`，即**优先**使用 24 位随机 dfid；Flutter 的默认参数取 `device.dfid.isEmpty ? '-' : device.dfid`（固定设备 dfid）。
- 影响：上游按 dfid 做频控/试听额度时行为不同；匿名态 dfid 恒为 '-' 的账号更易触发风控 20028，播放失败率高于 Node 基线。

### lib/core/direct/kg_play_api.dart:96 privilege 把调用方 `qualities` 直接作为上游 `qualities` 下发，Node 恒发完整音质表
- 级别：P1
- 依据：`KgSharedParams.privilege` 中 `'qualities': useQualities`（`qualities` 非空时直接用入参）；Node `privilege_lite.js:24-26,176`：`UPSTREAM_QUALITIES = ['128','320','flac','high','viper_atmos','viper_tape','viper_clear','super','multitrack']`，注释明确「上游一次请求的音质列表：完整请求才能拿到 128 的 ogg 条目，输出时再按 qualities 参数过滤」，dataMap 里恒为 `qualities: UPSTREAM_QUALITIES`。
- 影响：调用方只查 `['128']` 时上游只返回 128 的 relate_goods，`vip_qualities`/`missing_qualities`/`best_free_quality` 全部失真；音质选择弹窗出现「该音质不存在」误判，VIP 用户看不到可用的更高音质。

### lib/core/direct/kg_play_api.dart:100 privilege 默认音质表顺序与 Node 默认输出表不同
- 级别：P2
- 依据：Flutter 默认 `['128','320','flac','high','viper_atmos','viper_tape','viper_clear','super','multitrack']`；Node 默认输出 `'128,320,flac,high,viper_tape,viper_clear,viper_atmos'`（`privilege_lite.js:162`）。
- 影响：`qualities` 数组顺序决定上层列表渲染顺序，蝰蛇三档顺序错位会让「最高可用音质」文案与实际不符。

### lib/core/direct/kg_play_api.dart:148 PrivilegeItem 只取 `relate_goods.first`，Node 按 level 挑选确切条目
- 级别：P1
- 依据：`final g = (goods is List && goods.isNotEmpty) ? Map<String, dynamic>.from(goods.first as Map) : <String, dynamic>{};`；Node `privilege_lite.js:41-47,63-98`：`pickRelate` 按 `QUALITY_LEVEL`（128 优先 level=1 的 ogg，其次 level=2 的 mp3）逐档挑选，并为每个 quality 生成一条记录。
- 影响：128 音质会取到错误条目（ogg vs mp3 的 hash/size 不同），`privilege`/`pay_type`/`status`/`quality` 全部来自第一条 relate_goods，导致「免费却显示需会员」或反之；VIP 判定失真，三态兼容失效。

### lib/core/direct/kg_play_api.dart:148 PrivilegeItem 无 `free_song` / `best_free_quality` / `super_vip_qualities` 聚合字段
- 级别：P2
- 依据：模型只有 `hash/privilege/payType/status/failProcess/quality/pkgPrice/durationMs/cover`；Node `privilege_lite.js:115-131` 返回 `free_song`、`free_listen`、`free_qualities`、`vip_qualities`、`super_vip_qualities`、`blocked_qualities`、`missing_qualities`、`best_free_quality` 等聚合结果。
- 影响：上层无法区分「歌曲本身免费」与「个别音质免费」，音质选择页只能逐条判断，容易出现免费用户看到全部音质可选但点击后失败。

### lib/core/direct/kg_play_api.dart:150 `isFree` 只判 `privilege == 0`，忽略 `status` 与 `pay_type`
- 级别：P2
- 依据：`bool get isFree => privilege == 0;`、`bool get needsPurchase => payType != 0 || privilege != 0;`；Node 的 obtainable 判定为 `freeListen || (exists && !neesuvip && relateItem.status !== 0)`（`privilege_lite.js:72`）。
- 影响：`privilege=0` 但 `status=0`（服务端不可播）的条目被判为「免费可播」，用户点击后播放失败，且不会走试听降级。

### lib/core/direct/kg_play_api.dart:196 songUrl 未下发 `IsFreePart` 以外的试听参数（`ssa_flag`/`cdnBackup` 有），但与 Node 的 `free_part` 真值语义不一致
- 级别：P2
- 依据：`'IsFreePart': freePart ? 1 : 0`，`freePart` 为 Dart bool，只能由 bool 入参决定；Node `song_url.js:35` 为 `params?.free_part ? 1 : 0`，接受 `'1'`/`true`/任意真值。`kg_endpoints_media.dart:99` 又单独实现了字符串判定 `'${q['free_part']}' == '1'`。
- 影响：同一语义在两条路径下对 `'true'`/`'yes'` 的判定不同，试听请求在一条路径上不生效，用户点「试听」拿到的是无版权错误。

### lib/core/direct/kg_play_api.dart:255 PlayUrlResult 只读 `hash_offset.end_ms`，`start_ms` 与 `clip_hash` 完全未处理
- 级别：P1
- 依据：`final endMs = (b['hash_offset'] is Map) ? int.tryParse('${(b['hash_offset'] as Map)['end_ms'] ?? ''}') ?? 0 : 0;`；其余字段（`start_ms`、`clip_hash`、`hash_offset.begin_ms`）从未被读取，`urls` 直接用 `b['url']`。`/v5/url` 在 `IsFreePart=1` 时返回的试听片段以 `hash_offset` 描述区间，Node 侧由 kapi 透传该对象。
- 影响：试听片段只播到 `end_ms` 之后的整段文件（或整段不可播）；`clip_hash` 对应的裁剪地址未被使用，试听体验错位（从 0 秒开始播整首歌而 UI 标「试听」）。

### lib/core/direct/kg_play_api.dart:257 试听判定依赖 URL 含 `/p_0_` 与 `end_ms<=65000` 两个启发式
- 级别：P2
- 依据：`isPreview: (endMs > 0 && endMs <= 65000) || urls.any((u) => u.contains('/p_0_'))`；注释自述「60s 试听：end_ms 约 60000 或路径含 /p_0_（flac 时 bitRate=0 不可作为依据）」。
- 影响：短歌曲（<65s，如童谣/间奏）会被误判为试听并打出「试听」标记；若试听时长调整为 30s/90s，判定直接失效。

### lib/core/direct/kg_play_api.dart:262 PlayUrlResult 无 URL 过期时间解析与重试机制
- 级别：P2
- 依据：模型字段只有 `urls/backupUrls/quality/bitrate/isPreview/errorCode/message/ssaCode/failProcess/extName`，`extName` 直接取 `b['extName']`；`/v5/url` 返回体中的 `url` 带时效签名，代码未保留任何过期时间（如 `b['expire']`/`b['time']`）或时间戳。
- 影响：长时间播放/切后台回来后再用同一 URL 会 403，播放器无「过期→重新解析」通路，用户看到卡住或无声。

### lib/core/direct/kg_play_api.dart:270 PlayUrlResult 的 `quality` 取 `b['quality']`，`_qualityFromBitrate` 又优先采信 `extName`
- 级别：P2
- 依据：`quality: '${b['quality'] ?? ''}'`、`extName: '${b['extName'] ?? ''}'`；`PlayerRepository._qualityFromBitrate` 用 `AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality)`。`/v5/url` 的 `extName` 是容器扩展名（mp3/ogg/flac），并非音质档位。
- 影响：返回 `extName='mp3'` 时 `AudioQuality.fromString('mp3')` 无法映射，回落 128 判定；128 与 320 同为 mp3 时显示档位错误，用户以为听的是无损。

---
## 问题清单（按级别排序）

统计：共 **74** 项 —— P0 **0** / P1 **20** / P2 **54**。

### P0（0 项）
无。本次范围内未发现「必然崩溃 / 明文泄露 / 数据损坏」级别缺陷；最严重的问题集中在「直连参数形态偏离 Node 导致假失败 → 静默回退 kapi」与「VIP 三态缺失」，已按 P1 记录。

### P1（20 项）

1. `kg_endpoints_search.dart:100` 通用搜索（special/author/mv）缺 `albumhide`/`nocollect`/`iscorrection`，pagesize 默认 20（Node 30）。
2. `kg_endpoints_search.dart:112` 歌词搜索打无版本 `/search` + `notSignature`，与口径「`/v1/search` 必须带 signature」及 Node `search_lyric.js` 均不符。
3. `kg_endpoints_playlist.dart:118` 加歌 data 元素缺 `number/size/sort/timelen/bitrate`（Node 必有 5 字段）。
4. `kg_endpoints_playlist.dart:150` 删歌 `'/cloudlist.service/v4/delete_songs'` + `x-router` 双前缀，body 多 `area_code`/`allplatform`。
5. `kg_endpoints_playlist.dart:210` playlistDetail 缺 `userid`/`token`（Node dataMap 必带）、>10 个 id 静默截断。
6. `kg_endpoints_comment.dart:24` 歌曲评论走 gateway 根路径 `/mcomment/v1/cmtlist`，未走 `x-router: m.comment.service.kugou.com`。
7. `kg_endpoints_comment.dart:126` 楼中楼回复缺 `is_t`、`pid` 默认 0、`//@` 拼接与 `extdata`。
8. `kg_endpoints_comment.dart:161` 删除评论用 POST，Node `buildCommentDelConfig` 为 GET。
9. `kg_endpoints_media.dart:96` `/v5/url` 由 `kg.request` 自动补 `signature`，Node 该端点 `notSign: true`（只带 key）。
10. `kg_endpoints_media.dart:110` privilege 空 hash 不拦截，空 `resource` 直接上行（Node 前置 reject 502）。
11. `kg_endpoints_artist_album.dart:36` artistAudios 丢掉 Node 的 `baseURL: openapi.kugou.com`，退化为 gateway + x-router。
12. `kg_endpoints_home.dart:74` topPlaylist 直连恒 200101 全程依赖 kapi；且 `special_recommend` 内层缺 `sort/ugc/is_selected/withrecommend/area_code` 五字段（未排除参数写错导致假失败）。
13. `kg_endpoints_home.dart:117` yuekuBanner 匿名恒 31136（直连 + kapi 双失败），`vip_type` 硬编码 0 致 VIP 无专属 banner。
14. `kg_endpoints_auth.dart:56` 验证码接口用明文 `http://login.user.kugou.com`。
15. `kg_endpoints_auth.dart:70` 登录不保存 `vip_type`/`vip_token`，全仓无 VIP 态字段 → 三态兼容断裂。
16. `kg_play_api.dart:44` 播放主路径 `/v5/url` 走 gateway + x-router，未落 `trackercdn.kugou.com` 原生域（同仓 media 版才走原生域）。
17. `kg_play_api.dart:46` 同上端点被 `requestWithVerify` 补 `signature`，Node `notSign: true`。
18. `kg_play_api.dart:96` privilege 把入参 qualities 直接下发，Node 恒发 `UPSTREAM_QUALITIES` 全表（否则 128 ogg 缺失、权益判定失真）。
19. `kg_play_api.dart:148` PrivilegeItem 只取 `relate_goods.first`，Node 按 `QUALITY_LEVEL` 逐档挑选。
20. `kg_play_api.dart:255` `hash_offset` 只读 `end_ms`，`start_ms`/`clip_hash` 完全未处理。

### P2（54 项）

**kg_endpoints_search.dart（4）**
- :58 歌曲搜索 /v3 与 Node v2 参数/结构差异未做兼容分支。
- :80 `sorttype` 用字符串比较，弱于 Node `Number()` 语义。
- :136 歌词下载 `id`/`accesskey` 空值不拦截，会发 `id=null`。
- :139 `contenttype != 0` 与动态类型比较，字符串 "0" 误判；KRC 无 `decodeLyrics` 分支。

**kg_endpoints_playlist.dart（5）**
- :26 取消收藏解密失败/无 status 时静默返回原始密文（写操作误报失败）。
- :78 playlistAdd 硬编码 `source:1`、`is_pri:0`，忽略入参。
- :180 userPlaylist query `userid` 传字符串，Node 用 `Number(userid)`。
- :220 playlistDetail 空 ids 不前置校验，直接发 `data: []`。
- :236 playlistTrackAll 数字 id 改发自创 `specialid` 键，Node 恒用 `global_collection_id`。

**kg_endpoints_comment.dart（7）**
- :49 commentCount 只判 `!= null`，空串 hash 致既无 hash 也无 childrenid。
- :73 发评论 body 缺 `extdata`（content_extdata）。
- :88 发评论 query 缺 `source`，`childrenname` 只认 `q['name']`。
- :170 删除评论 `cid` 空值不拦截、无 `comment_id` 别名。
- :198 commentPlaylist/commentAlbum 用路径前缀而非 x-router（与 Node 一致但背离口径）。
- :228 commentFloor 忽略调用方 `code`，路由判定不看 code。
- :241 commentFloor `childrenid` 仅取 `special_id`，空串仍下发。

**kg_endpoints_media.dart（5）**
- :22 kmrAudioMv 空 ids 不校验，直接发 `data: []`。
- :44 videoUrl hash 未小写，与 /v5/url 的小写策略不一致。
- :99 `free_part` 只认 `'1'`/`'true'`，Node 为真值判定。
- :113 privilege 缺 album_id 时填字符串 `'0'`，Node 填数值 0。
- :118 `media.store.kugou.com` 三标签证书限制 → 该端点永久依赖 gateway（既知约束登记）。

**kg_endpoints_artist_album.dart（7）**
- :24 artistDetail 走 gateway + x-router，未用 openapi 原生域。
- :40 artistAudios `clienttime` 以字符串进 body，Node 为数值。
- :42 artistAudios 静默把 pagesize 截断到 100，Node 原样下发。
- :112 rankAudio 缺省下发 `rank_id=0`，Node 丢弃该键。
- :118 rankAudio `page/pagesize` 脏值静默变 1/30。
- :140 albumSongs `is_buy` 用 `?? ''`，Node 用 `|| ''`（0 处理不同）。
- （:24 与 :36 同一文件的分层不一致，:36 已列 P1）

**kg_endpoints_home.dart（7）**
- :18 yueku 走 gateway + x-router，放弃原生域的「证书」理由缺证据。
- :33 rankList 无第二原生域名兜底。
- :47 topSong `userid` 回落 `kg.userid`（可能空串），Node 回落 0。
- :82 topPlaylist `userid` 以字符串下发，无 `|| 0` 兜底。
- :98 searchHot `navid`/`plat` 可被入参覆盖，Node 硬编码。
- :157 videoDetail `uuid=md5(dfid+mid)` 与全局 `uuid:'-'` 口径并存。
- :170 videoDetail 空 id 跳过，body 与 Node 的 `[{video_id:''}]` 不同。

**kg_endpoints_auth.dart（11）**
- :73 login 失败仅打日志，`status=1` 但无 token 时仍算成功。
- :88 `_maskMobile` 短号原样返回，Node 返回空。
- :129 密码登录丢 Node 的 `cookie` 透传。
- :161 `kg.t1` 依赖上次登录响应，缺失时刷新恒用 `|dateNow`。
- :186 非 lite 仍计算 t1/t2 后丢弃；lite 的 t3 仍硬编码设备串。
- :203 loginQrKey 的 `appid`(1001/1014) 与 `qrcode_txt` 内 appid(1005) 混用。
- :225 loginQrCheck 额外下发 `timestamp`/`_t`，web 签名串与 Node 不同。
- :225 loginQrCheck 未区分状态 0（过期）/2（待确认），过期无错误。
- :264 userDetail 手动回填 `data['userid']`，可能串号。
- :310 getVerifyInfo 走 gateway 根路径，与 `kg_client` 的 `verifyservice.kugou.com` + 前缀路径两份实现不一致。
- :327 verifyUserInfo `pk` 无 `clienttime`（与 Node 同），契约脆弱无降级。
- :363 registerDev 把业务 status 塞进 HTTP status 字段。
- :11 core 层 import `qr_flutter`（依赖 UI 渲染）。

**kg_play_api.dart（8）**
- :46 songUrl 未注入随机 dfid（Node `randomString(24)`）。
- :100 privilege 默认音质表顺序与 Node 默认输出表不同。
- :148 PrivilegeItem 无 `free_song`/`best_free_quality`/`super_vip_qualities` 等聚合字段。
- :150 `isFree` 只判 `privilege==0`，忽略 `status`/`pay_type`。
- :196 `free_part` 语义在 play_api（bool）与 media（字符串）两条路径下不一致。
- :257 试听判定启发式（`/p_0_` + `end_ms<=65000`）会误判 <65s 短歌。
- :262 无 URL 过期时间解析与「过期→重解析」重试通路。
- :270 `extName` 被当作音质档位喂给 `AudioQuality.fromString`（mp3/ogg 非档位）。

---

## 域名合规小结

| 端点 | 实际 baseUrl | 是否原生域 | 备注 |
|---|---|---|---|
| `/v3/search/song`、`/v1/search/*` | `complexsearch.kugou.com` | ✅ | 通用搜索参数与 Node 有差异（P1/P2） |
| 歌词 `/search`、`/download` | `lyrics.kugou.com` | ✅ 域 / ❌ 路径 | 路径用 `/search` 而非 `/v1/search`，且 notSignature（P1） |
| `/v3/get_list_info`、`/v2/get_other_list_file_nofilt` | `pubsongs.kugou.com` | ✅ | detail 缺 userid/token（P1） |
| `/v5/url`（media 版） | `trackercdn.kugou.com` | ✅ | 但多 signature（P1） |
| `/v5/url`（play_api 主路径） | `gateway.kugou.com` + x-router | ⚠️ 网关 | 未落原生域（P1） |
| `/kmr/v1/audio/mv` | `openapi.kugou.com` | ✅ | 正常 |
| `/kmr/v3/author`、`/kmr/v1/audio_group/author`、`/kmr/v1/author/albums`、`/kmr/v2/albums`、`/v1/album_audio/lite` | `gateway.kugou.com` + x-router | ⚠️ 网关 | artistAudios 的 Node 侧本有 openapi baseURL（P1） |
| `/openapi/kmr/v2/rank/audio` | gateway + `kg-tid:369` | ⚠️ 网关 | 与 Node 一致，kg-tid 正确 |
| `/v1/video`、`/v1/video_detail` 相关 | gateway + `kmr.service` | ⚠️ 网关 | 三标签证书限制，既知约束 |
| `/v6/rank/list` | `ocean.kugou.com` | ✅ | 正常 |
| `/container/v1/newsong_publish` | `musicadservice.kugou.com` | ✅ | 正常 |
| `/api/v3/search/hot_tab` | `msearch.kugou.com` | ✅ | 正常 |
| `/v2/special_recommend` | gateway + `specialrec.service` | ❌ 恒 200101 | **每次都回退 kapi，违反硬口径**（P1，既知约束） |
| `/v2/get_res_privilege/lite` | gateway + `media.store` | ⚠️ 网关 | 三标签证书限制，既知约束 |
| `/mcomment/v1/cmtlist`、`/mcomment/v1/hot_replylist` | gateway 根路径 | ⚠️ 网关 | 未带 `x-router: m.comment.service`（P1） |
| `/index.php`（计数/写评论/删评论） | gateway + `m.comment.service`/`sum.comment.service` | ✅ 网关 + x-router | 删评论 method 错（P1） |
| 登录/验证码/二维码 | `login.user.kugou.com`（http）、`loginserviceretry.kugou.com`、`login-user.kugou.com`、`userservice.kugou.com`、`verifyservice.kugou.com` | ✅ 域 | 验证码走明文 http（P1） |

**未发现任何 case 的 baseUrl 直接指向 `kapi.344977.xyz`**：kapi 仅作为 `KgDirectApiClient` 父类的兜底通道（`app_config.dart:9`）。但「直连参数形态错误 → 静默回退」的隐性依赖共发现 3 处确证（`top/playlist`、`/v5/url` 的 notSign 偏离、`artistAudios` 弃用 openapi baseURL），均已在 P1 列出。
