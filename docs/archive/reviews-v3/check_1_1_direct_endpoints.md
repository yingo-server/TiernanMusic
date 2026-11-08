# 第1批审查①：直连层 7 端点文件（只读）

- 基线：`33fbb68`（main，R1/R2 收敛后）
- 审查范围：`lib/core/direct/kg_endpoints_{search,playlist,comment,media,artist_album,home,auth}.dart` 共 7 个端点文件；交叉核对 `kg_direct_api_client.dart`、`kg_client.dart`、`kg_play_api.dart`、`lib/core/api/kugou_api_client.dart`、相关 Repository 调用点；协议基准 `KuGouMusicApi/module/*.js` 与 `docs/api_verified.md`。
- 方式：逐文件完整 `file_read`；未修改任何代码；未运行 `flutter analyze` / 测试 / 构建；未发起网络请求。
- 说明：派发到本代理的任务书正文被系统截断（仅保留“工作目录 /var/m…”之前的内容），报告按“7 端点文件 + 直连层集成”执行；落盘文件名沿用 `docs/check_*.md` 约定，取 `docs/check_1_1_direct_endpoints.md`。
- 严重度：🔴 功能失效/数据错误 > 🟠 行为偏差/兜底掩盖 > 🟡 质量与维护风险。

---

## 🔴 P0-1 直连层抛裸 `ApiException`，上层只按 `DioException` 捕获，登录验证/多账号/失效凭证分支全部失效

**位置**
- `lib/core/direct/kg_direct_api_client.dart:59-64`、`:68-73`、`:82-87`（`_wrap` 直接 `throw ApiException(...)`）
- `lib/core/direct/kg_direct_api_client.dart:122-132`（`_directOrFallback` 原样 `rethrow`，不包装成 `DioException`）
- `lib/features/auth/data/auth_repository.dart:101`（`on DioException catch`）、`:132`、`:222`、`:246`
- `lib/features/auth/presentation/verification_guard.dart:28`（同样只 `on DioException`）

**依据/影响**
- 直连 `/login` 返回 `error_code=20028` 时，`_wrap` 抛 `ApiException(20028)`；`AuthRepository.loginByPassword` 的 `on DioException` 不会命中，`CaptchaRequiredException` 永远不会抛出，`login_page.dart:395` 的验证码分支不可达。
- 直连 `/login/cellphone` 返回多账号 `20034` 时同理，`MultiAccountException` 永远不会抛出（`auth_repository.dart:105-112` 不可达）。
- `restoreSession()` 的“确认 token 失效才 logout”判断（`:222-234`、`:246-253`）只存在于 `on DioException`；直连的 `ApiException` 会落到 `:236` 的泛 catch，走 `getUserDetail` 降级，不会清理失效凭证。
- `_directOrFallback` 在 `:126` 对 `needsVerification` 直接 `rethrow`，其设计前提是“上层按 ApiException 处理”，但 `verification_guard.dart` 按 `DioException.error` 取；两套异常契约不一致。
- 对比 kapi 路径：`KugouApiClient` 的拦截器用 `DioException(error: ApiException(...))` 包装（`kugou_api_client.dart:110-124`），所以上层按 `DioException` 写是成立的；直连覆写 `get/post` 后没有保持这个契约。

---

## 🔴 P0-2 写操作失败自动回退 kapi，服务端已执行但响应丢失时会重复副作用

**位置**
- `lib/core/direct/kg_direct_api_client.dart:115-133`（`try { _wrap(await direct()) } catch (e) { ... return await kapi(); }`）
- 写端点调用：`kg_direct_api_client.dart:186-192`（`playlist/del`、`playlist/add`、`playlist/tracks/add`）、`:175-185`（评论 send/del/floor send）
- 对应写实现：`kg_endpoints_playlist.dart:19-56`（`playlistDel`）、`:65-98`（`playlistAdd`）、`:103-124`（`playlistTracksAdd`）、`:129-142`（`playlistTracksDel`）；`kg_endpoints_comment.dart:65-99`、`:105-131`、`:136-159`

**依据/影响**
- `_directOrFallback` 捕获的是 `Object`，不区分“请求未发出”“请求已发出但响应丢失”“业务失败”“解析失败”。写操作只要直连响应在返回途中断流/超时/解密失败，就会再次调用 kapi 的同一写接口。
- 歌单加歌、收藏歌单、发评论等非幂等操作会产生重复记录；删歌/删歌单会重复提交。当前评论写因 P0-7 路由错位实际只走 kapi，但 `playlistAdd`/`playlistTracksAdd` 已经走该路径。
- 同一 `catch (e)` 还会吞掉 `TypeError`/`NoSuchMethodError` 等编程错误并静默回退，使直连层 bug 在日志里只留下一条 `lastErrors`，不暴露为失败。

---

## 🔴 P0-3 `setCredentials` 只写 `KugouApiClient`，不同步 `KgClient`；冷启动 `login/token` 首次请求缺 token/userid

**位置**
- `lib/core/api/kugou_api_client.dart:161-164`（`userid`/`dfid` 字段）、`:180-198`（`setCredentials` 只写本类和 CookieJar）
- `lib/core/direct/kg_direct_api_client.dart:24-27`（`KgDirectApiClient extends KugouApiClient`，另持有独立 `KgClient kg`；无 `setCredentials` 覆写）
- `lib/features/auth/data/auth_repository.dart:211-220`（`setCredentials(...)` 后立刻 `loginByToken(...)`）
- `lib/features/auth/data/auth_providers.dart:21-33`（冷启动只补 `ref.read(kgClientProvider).t1`，未补 token/userid）
- `lib/core/direct/kg_client.dart:152-154`（`token=''`、`userid='0'`）、`:184-185`（默认参数只在 `kg.token`/`kg.userid` 非空时注入）
- `lib/core/direct/kg_endpoints_auth.dart:165-166`（只把入参 token/userid 放进 body）、`:207-211`（`kg.request` 的默认参数仍取 `kg.token`/`kg.userid`）
- `lib/main.dart:237-252`（`authStateProvider` 监听器才把 token/userid/t1 写回 `KgClient`，晚于 `restoreSession`）

**依据/影响**
- 冷启动 `AuthStateNotifier.build` 只设置 `kg.t1`；`restoreSession` 调 `setCredentials` 只更新父类的 `userid` 与 CookieJar，`kg.token` 仍为空、`kg.userid` 仍为 `'0'`。紧接着的 `loginToken` 用 `kg.request` 组装默认参数，请求 query/签名中缺 `token`、`userid`。
- Node 参考 `request.js:100-145` 从 cookie 注入 token/userid 并参与签名；Dart 直连没有 CookieJar 注入，只能依赖 `KgClient` 字段。首次刷新与 Node 的请求参数不一致，存在 20006/登录态刷新失败风险；失败后按 P0-1 又不会走正确的失效处理。
- 同一窗口内其它直连内容接口（评论 `kugouid`/`clienttoken`、歌单 `userid`/`token`）也会以空登录态发出。

---

## 🔴 P0-4 取消收藏歌单的 RSA 用了“无填充”算法，Node 用的是 PKCS1-v1_5

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:28-30`：`KgCrypto.rsaEncryptRawHex(jsonEncode({'aes':..., 'uid':..., 'token':...})).toUpperCase()`
- `lib/core/direct/kg_crypto.dart:171-190`：注释明确 `rsaEncrypt2 → rsaEncryptPkcs1`，`:191-213` 才是无 PKCS1 填充的 `rsaEncryptRawHex`
- Node `KuGouMusicApi/module/playlist_del.js:20`：`const p = rsaEncrypt2({ aes: aesEncrypt.key, uid: userid, token }).toUpperCase();`
- Node `KuGouMusicApi/util/crypto.js:264-270`：`rsaEncrypt2` 使用 `key.encrypt(..., 'RSAES-PKCS1-V1_5')`

**依据/影响**
- Node 侧 `p` 为 PKCS1-v1_5 填充结果；当前用裸 RSA（右补零 + modPow）生成，服务端无法按 PKCS1 解出 `{aes,uid,token}`，`/v2/delete_list` 直连失败并回退 kapi。
- `rsaEncryptRawHex` 未传 `lite:`，概念版下使用标准版公钥；Node `rsaEncrypt2` 内按 `isLite` 选 `publicLiteRasKey`（`crypto.js:265-267`），两者公钥来源不同。
- 交叉证据：`docs/PROGRESS.md` 的 S1.1 第 9 项自述“playlistDel/TracksDel 用 playlistAesEncrypt+rsaEncryptPkcs1”，与当前代码不一致，说明该端点此前的“✅”结论未覆盖实际实现。

---

## 🔴 P0-5 歌单加歌把 `data` 原样字符串发给 `/v6/add_song`，Node 发送的是对象数组

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:106`（`final raw = q['data'] ?? q['songs'] ?? '';`）、`:123`（`'data': raw`）
- Node `KuGouMusicApi/module/playlist_tracks_add.js:8-21`：把 `params.data.split(',').map(...)` 转成 `{number,name,hash,size,sort,timelen,bitrate,album_id,mixsongid}` 数组
- Node 同文件 `:31`：`data: resource`
- 调用方 `lib/features/playlist/data/playlist_repository.dart:125-130` 传的是 `名称|hash|album_id|album_audio_id` 逗号串

**依据/影响**
- 当前请求体是 `{"data":"名称|hash|album_id|album_audio_id,..."}`，Node 参考是 `{"data":[{...},{...}]}`；服务端解析 `data` 为数组，字符串形态会导致空列表/参数错误。
- 请求体（`data`）同时进入 android 签名（`kg_client.dart:193-200`），结构不同也会使签名输入与 Node 不一致。

---

## 🔴 P0-6 歌单删歌把 `fileids` 字符串发出，缺 `data:[{fileid}]` 与 `list_ver`

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:134-142`：请求体只有 `userid/token/listid/type/fileids/area_code/allplatform`
- Node `KuGouMusicApi/module/playlist_tracks_del.js:7`：`const resource = (params.fileids || '').split(',').map((s) => ({ fileid: Number(s) }));`
- Node 同文件 `:9-15`：`data: resource`、`list_ver: 0`
- 调用方 `playlist_repository.dart:133-136` 传 `fileids` 逗号串

**依据/影响**
- 服务端期望 `data` 为 `[{fileid: number}]`，当前发的是 `fileids: "..."`，没有 `data` 字段也没有 `list_ver`；直连 `/v4/delete_songs` 无法按 Node 协议执行。
- 这是写操作，配合 P0-2 的自动回退，还会出现直连失败后 kapi 再删一次的双请求。

---

## 🔴 P0-7 评论写接口只在 `get` 分支注册，Repository 全部走 `post`，直连实现永不命中

**位置**
- `lib/core/direct/kg_direct_api_client.dart:175-185`：`get` 分支包含 `comment/floor/send`、`comment/music/del`、`comment/music/send`、`comment/playlist/send`、`comment/album/send`
- `lib/core/direct/kg_direct_api_client.dart:264-298`：`post` 分支只有 `rank/audio`、`comment/music`、`kmr/audio/mv`、`everyday/recommend`、`top/playlist`、`privilege/lite`、`search`、`comment/floor`、`playlist/detail`、`login`、`verify/user/info`、artist/album；**没有任何 comment 写接口**
- `lib/features/comment/data/comment_repository.dart:89`、`:101`、`:119`：分别用 `_api.post` 调 `/comment/*/send`、`/comment/floor/send`、`/comment/music/del`

**依据/影响**
- `KgEndpointComment.commentSend`、`commentFloorSend`、`commentDel` 三个方法及 `KgDirectApiClient` 中对应委托全部是死代码；实际所有评论写操作都走 `super.post`（kapi）。
- 路由即使命中，下列语义问题也存在：
  - `kg_endpoints_comment.dart:85` 的 `childrenid` 取 `special_id/childrenid/id`；`CommentRepository.sendComment` 的歌曲分支只传 `mixsongid`（`comment_repository.dart:75-80`），结果为 `childrenid=''`。Node `comment_music_send.js:10-23` 会用 `mixsongid` 先查 `commentMusic` 解析 `specialChildId`，并在缺失时返回 400。
  - `kg_endpoints_comment.dart:146` 的删除评论同样只从 `special_id/childrenid/id` 取；`CommentRepository.deleteComment` 的歌曲分支只传 `mixsongid`（`:119-125`），Node `comment_music_del.js:17-27` 有同样的 `commentMusic` 解析兜底。
  - `kg_endpoints_comment.dart:86` 的 `childrenname` 只在调用方显式传 `name` 时发送；Repository 的 `name` 是可选参数（`comment_repository.dart:67`），Node `_comment.js:121` 会从 `song_name/album_name/playlist_name/childrenname` 多字段取值并在缺失时查询。
- 结果是：歌曲评论“发不出去/删不掉”时，日志里看到的是 kapi 的错误，直连层实现完全没有参与。

---

## 🟠 P1-1 楼中楼回复缺 `is_t`/默认 `pid`/`extdata`/`source`

**位置**
- `lib/core/direct/kg_endpoints_comment.dart:105-131`：只发 `pid`（且仅在非 null 时）、`content`、`tid`
- Node `KuGouMusicApi/module/_comment.js:141-172`：`pid = firstValue(params.pid, 0)`，`isTopLevelReply = firstValue(params.is_t, params.isT, String(pid)==='0' ? 1 : 0)`，并发送 `is_t`、`pid`、`extdata`、`source`
- 调用方 `comment_repository.dart:101-108`：`pid` 可选

**依据/影响**
- 顶层楼中楼回复（`pid` 为空）在 Node 中会明确 `pid=0, is_t=1`；当前请求两个字段都不发。服务端若按 `is_t` 区分“回复楼层/回复评论”，顶层回复会被归到错误层级或拒绝。
- `extdata`/`source` 缺失同样与 Node 请求体不一致。

---

## 🟠 P1-2 删除评论用 POST，Node 用 GET 且无 body

**位置**
- `lib/core/direct/kg_endpoints_comment.dart:136-159`：`method: 'POST'`，无 `data`
- Node `KuGouMusicApi/module/_comment.js:57-69`（`commentRequestConfig` 默认 `method='GET'`）；`buildCommentDelConfig` 在 `:188-209` 未覆盖 method
- Node `KuGouMusicApi/module/comment_music_del.js:29-38` 直接 `useAxios(buildCommentDelConfig(...))`

**依据/影响**
- 当前直连即使被路由到，也会把删除请求发成 POST；Node 参考是 GET + query。方法不同可能被服务端 404/405 或按不同 handler 处理。
- 结合 P0-7 的 `childrenid` 缺失，删除评论存在两处协议偏差。

---

## 🟠 P1-3 歌单详情请求体缺 `userid`/`token`

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:200-208`：body 只有 `data:[{global_collection_id}]`
- Node `KuGouMusicApi/module/playlist_detail.js:4-10`：`dataMap` 同时含 `userid` 与 `token`
- 调用方 `playlist_repository.dart:21-23` 用 `ids` 调 `/playlist/detail`

**依据/影响**
- 公共歌单匿名可读，但“我的歌单/私密歌单”的详情需要登录态；当前直连 body 不带 `userid/token`，与 Node 不一致，私密歌单可能返回空/无权限，触发 kapi 回退。

---

## 🟠 P1-4 `top/playlist` 的 `special_recommend` 缺 5 个 Node 字段

**位置**
- `lib/core/direct/kg_endpoints_home.dart:104-109`：只有 `withtag/withsong/categoryid/tagids`
- Node `KuGouMusicApi/module/top_playlist.js:8-17`：`withtag, withsong, sort, ugc, is_selected, withrecommend, area_code, categoryid`
- 调用方 `home_repository.dart:77-79` 传 `category_id`、`withsong`

**依据/影响**
- 当前请求体缺 `sort/ugc/is_selected/withrecommend/area_code`，且多出 Node 没有的 `tagids`；这与该端点“直连恒 ec=200101”的既有现象叠加，无法判断是上游收紧还是请求体本身不完整。
- 请求体进入 android 签名（`kg_client.dart:193-200`），字段集合与 Node 不同也会改变签名输入。

---

## 🟠 P1-5 权益请求在 `album_id=''` 时向 resource 传空串，Node 传 0

**位置**
- `lib/core/direct/kg_endpoints_media.dart:98-104`：`final albums = '${q['album_id'] ?? ''}'.split(',');` 空串得到 `['']`
- `lib/core/direct/kg_play_api.dart:156-165`：`'album_id': i < albumIds.length ? albumIds[i] : '0'`，取到 `''`
- Node `KuGouMusicApi/module/privilege_lite.js:143`：`String(params?.album_id || '').split(',')`；`:151`：`album_id: albumIdList[index] || 0`
- 调用方 `player_repository.dart:64-69` 传 `song.albumId`（部分歌曲可能为空）

**依据/影响**
- 空字符串经 `|| 0` 在 Node 变成 `0`，当前 Dart 保留 `''`；`/v2/get_res_privilege/lite` 的 resource 里 `album_id` 类型/取值与 Node 不一致，可能导致该曲权益条目缺失或 20010，进而使 `fetchDetail` 静默返回原 song。

---

## 🟠 P1-6 验证提交绕过直连层且发 GET，Node 是 POST

**位置**
- `lib/features/auth/data/verification_service.dart:66-70`：`_api.dio.get<Map<String, dynamic>>('/verify/user/info', queryParameters: query)`
- `lib/core/api/kugou_api_client.dart:158`：`dio` 是父类原始 Dio
- `lib/core/direct/kg_direct_api_client.dart:286-288`：直连 `post` 分支本来有 `verify/user/info`
- `lib/core/direct/kg_endpoints_auth.dart:323-370`：直连实现是 POST，并构造 `sid/edt/pk/params`
- Node `KuGouMusicApi/module/verify_user_info.js:40-48`：`method: 'POST'`

**依据/影响**
- `verification_service` 用 `_api.dio` 直接发请求，既不经过 `KgDirectApiClient.get/post`（直连实现永远不命中），又用 GET 调一个 Node 定义为 POST 的接口；验证码提交链路与 kapi/Node 都可能不兼容。
- 该路径是 20028 验证闭环的最后一步；即使 P0-1 修好，提交仍可能失败。

---

## 🟠 P1-7 `search` 的 special/author/mv 分支缺 Node 的 `albumhide/iscorrection/nocollect`，默认 pagesize 也不同

**位置**
- `lib/core/direct/kg_endpoints_search.dart:64-76`：仅 `keyword/page/pagesize/platform/tag/clientver`
- Node `KuGouMusicApi/module/search.js:64-73`：`albumhide:0, iscorrection:1, nocollect:0, page, pagesize(默认30), platform`
- 调用方 `search_repository.dart:184-196` 用 `type='special'` 并传 `pagesize`

**依据/影响**
- special 搜索结果会受 `albumhide/nocollect/iscorrection` 影响（专辑隐藏、纠错、是否聚合）；代码没有注释说明为何可以省略，也没有 `docs/api_verified.md` 对 special 分支的字段级记录。
- 默认 `pagesize` 为 20 而 Node 为 30；当前 App 调用显式传 pagesize，但其他调用方（或未来分页）会拿到不同页大小。

---

## 🟡 P2-1 `_wrap` 对 `status`/`err_code` 只做 int 比较，且 `status==200` 无条件放行

**位置**
- `lib/core/direct/kg_direct_api_client.dart:45-49`：`status` 原样取出，`rawCode` 只读 `error_code/errcode` 并 `int.tryParse`
- `:57-58`：`err_code` 只有 `is int` 才判错
- `:79`：`if (status == 200) return body;` 直接返回，不检查 `err_code/error_code`

**依据/影响**
- 如果服务端把 `status` 或 `err_code` 返回为字符串（JSON 数字通常是 int，但网关/上游存在混用），`status == 1`/`errCode is int` 都会失效；`status == 200` 分支会把带 `err_code=60102` 的歌词响应也当成功。
- 该方法是所有直连端点的唯一成功判定入口，类型宽松问题会放大到全部端点；当前没有 `status` 类型断言或统一 `asInt`。

---

## 🟡 P2-2 `lyric` 的 `contenttype` 未数值化，字符串 `'0'` 会被当成“非 0”

**位置**
- `lib/core/direct/kg_endpoints_search.dart:128-133`：`final contenttype = body['contenttype']; if (fmt == 'lrc' || contenttype != 0) { base64.decode(...) }`
- Node `KuGouMusicApi/module/lyric.js:32-36`：`Number(res.body?.contenttype) !== 0`

**依据/影响**
- 若上游把 `contenttype` 序列化为字符串 `'0'`，Dart 的 `contenttype != 0` 为 true，会把 KRC 密文当 Base64 解，`utf8.decode` 得到乱码或被 catch 吞掉；Node 会走 `decodeLyrics`。当前仓库随后还有 `KrcDecoder.decode(content)` 兜底，但 `decodeContent` 已被写坏时优先使用它。

---

## 🟡 P2-3 评论资源 code 选择未统一小写

**位置**
- `lib/core/direct/kg_endpoints_comment.dart:84`、`:115`、`:145` 调用 `_commentCodeOf('${q['resource_type'] ?? 'song'}')`
- `:163-167` 的 switch 只匹配 `'playlist'/'album'`
- Node `KuGouMusicApi/module/_comment.js:178-190` 的 `resolveCommentCode` 先 `toLowerCase()`

**依据/影响**
- 当前 `CommentRepository` 传 `type.name`（小写），所以现状可用；任何传入 `'Playlist'`/`'Album'` 的调用都会落到歌曲 code，评论池选错。这是跨端点复用的边界问题，不是当前 UI 的即时故障。

---

## 🟡 P2-4 `playlistAdd` 把 `source` 固定为 1，忽略调用方 `source=0`

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:89`：`'source': 1`
- Node `KuGouMusicApi/module/playlist_add.js:19`：`source: params.source === 0 ? 0 : params.source || 1`
- 调用方 `playlist_repository.dart:104-114` 未传 `source`

**依据/影响**
- 当前 App 不传 `source`，行为与 Node 默认一致；但端点签名宣称支持 `source`（Node 显式区分 0），Dart 实现无法表达 `source=0`，属于实现与注释/Node 能力不一致。

---

## 🟡 P2-5 `commentSend` 忽略 `images/content_extdata/source` 等 Node 可选字段

**位置**
- `lib/core/direct/kg_endpoints_comment.dart:67-72`：`images` 固定 `const []`，contentData 无 `extdata`
- `:82-98`：无 `source`
- Node `KuGouMusicApi/module/_comment.js:104-133`：`extdata: params.content_extdata`、`images: Array.isArray(params.images) ? params.images : []`、`source: params.source`

**依据/影响**
- 当前 UI 不发图/不带来源，短期不影响文本评论；但端点接口承诺的字段被静默丢弃，调用方传图会得到“无图评论”，且请求体与 Node 不一致。

---

## 🟡 P2-6 `videoDetail` 三份实现并存，`kg_endpoints_home.dart` 的副本是死代码

**位置**
- `lib/core/direct/kg_direct_api_client.dart:468-490`：主类内联 `_videoDetail`（实际被 `:241` 调用）
- `lib/core/direct/kg_endpoints_home.dart:158-180`：同名 `videoDetail`，无人调用
- `lib/core/direct/kg_media_direct.dart:58-88`：`KgMediaDirect.videoDetail` 第三份
- `lib/core/direct/kg_direct_api_client.dart:241`：`_directOrFallback(() => _videoDetail(q), ...)` 只走主类副本

**依据/影响**
- 三份请求体字段/构造方式几乎相同但独立维护；未来只改 `kg_endpoints_home.dart` 或 `kg_media_direct.dart` 不会影响实际 `/video/detail` 行为，容易出现“改了没生效”的排查成本。R1 拆分后主类副本与端点副本已经重复。

---

## 🟡 P2-7 主类遗留 R1 拆分前的私有成员与导入，均为死代码

**位置**
- `lib/core/direct/kg_direct_api_client.dart:348-352`：`_commentCodeOf`（实际使用 `kg_endpoints_comment.dart:163-167` 的私有副本）
- `:521`：`_qrSrcappid`
- `:524-527`：`_maskMobile`
- `:551`：`_qrPngBase64`
- `:566-590`：`_afterLogin`
- `:7`：`import 'dart:convert';` 未被使用
- `:10`：`import 'package:qr_flutter/qr_flutter.dart';` 未被使用

**依据/影响**
- R1 把逻辑搬到端点文件后，主类保留了旧 helper；`_afterLogin` 与 `kg_endpoints_auth.dart:376-401` 重复，`_commentCodeOf` 与 comment 端点重复。任何一处修改都不会同步到另一处；同时会产生 `unused_element`/`unused_import` 类分析告警（若 CI 将 warning 视为失败，会阻塞）。

---

## 🟡 P2-8 7 个端点文件都 import 主类但从不引用，形成循环依赖；artist/media/home 还 import 未使用的 `dart:convert`

**位置**
- `kg_endpoints_search.dart:6`、`kg_endpoints_playlist.dart:6`、`kg_endpoints_comment.dart:6`、`kg_endpoints_media.dart:6`、`kg_endpoints_artist_album.dart:6`、`kg_endpoints_home.dart:6`、`kg_endpoints_auth.dart:6` 均为 `import 'kg_direct_api_client.dart';`
- 这些文件只在文档注释里出现 `KgDirectApiClient`，代码中没有类型引用（例如 `kg_endpoints_artist_album.dart:14`、`media.dart:15`、`home.dart:14` 都是注释）
- `kg_endpoints_artist_album.dart:1`、`kg_endpoints_media.dart:1`、`kg_endpoints_home.dart:1` 的 `dart:convert` 在文件内无 `jsonEncode/base64/utf8` 使用

**依据/影响**
- 主类 import 端点、端点 import 主类，形成 7 条循环 import；Dart 允许循环，但初始化顺序、分析器告警和维护阅读都会被污染。当前没有运行时症状，属于 R1 拆分残留。

---

## 🟡 P2-9 拆分残留/损坏的注释

**位置**
- `lib/core/direct/kg_direct_api_client.dart:354-356`：`/// 协议：body = playlistAesEncrypt(...) 的 Base64， => _epComment.commentCodeOf(q);`——“=>”被拼进文档注释，且 `commentCodeOf` 在 comment 端点里是私有 `_commentCodeOf`，该描述不成立
- `lib/core/direct/kg_endpoints_playlist.dart:184-186`：一段“歌单评论（module/comment_playlist.js）”注释孤零零挂在 `playlistDetail` 上方；该实现实际在 `kg_endpoints_comment.dart:174-188`
- `lib/core/direct/kg_endpoints_comment.dart:169-172`：一段“删除/取消收藏歌单（playlist_del.js）”注释挂在 `commentPlaylist` 上方；`playlistDel` 在 playlist 文件且没有对应文档
- `lib/core/direct/kg_endpoints_playlist.dart:19`：`playlistDel` 上方没有自己的协议注释（被移到主类/别处）

**依据/影响**
- 不改变运行行为，但直接违反“一文件一职责、注释跟随实现”的重构目标；后续维护者按注释找实现会找错文件。`kg_direct_api_client.dart:354` 的 `=>` 是明显的脚本迁移误伤痕迹。

---

## 🟡 P2-10 `playlistDel` 对非数字 `listid` 静默变成 0

**位置**
- `lib/core/direct/kg_endpoints_playlist.dart:23-27`：`'listid': int.tryParse('${q['listid'] ?? 0}') ?? 0`
- Node `KuGouMusicApi/module/playlist_del.js:12-16`：`Number(params.listid)`（`NaN` 会序列化为 `null`，不会变 0）

**依据/影响**
- 若调用方传 `global_collection_id`（`collection_...`），Dart 的 `int.tryParse` 返回 null 后取 0，向服务端发 `listid: 0`；Node `Number('collection_...')` 为 `NaN`，序列化为 `null`。两者都不是有效 id，但当前实现会把解析失败伪装成合法的 0，日志里看不出入参类型错误。当前 Repository 只传数值 `listid`，属于防御性缺口。

---

## 🟡 P2-11 `qualities` 直连只发调用方请求的子集，Node 始终发全量上游音质

**位置**
- `lib/core/direct/kg_endpoints_media.dart:104`：`qualities: KgSharedParams.parseQualities(q['qualities'])`
- `lib/core/direct/kg_play_api.dart:168-173`：空时默认 9 档，非空时直接用子集
- Node `KuGouMusicApi/module/privilege_lite.js:139-141`：`UPSTREAM_QUALITIES` 固定 9 档；`:184` 请求始终 `qualities: UPSTREAM_QUALITIES`，再在响应里按用户请求过滤

**依据/影响**
- 当前播放器 `fetchDetail` 只请求 `128,320,flac,high`（`player_repository.dart:64-69`），直连响应不会包含 `viper_*` 条目；Node 会返回全量后由上层筛选。对现有 `Song.fromJson` 可能无感，但任何依赖 `relate_goods` 全量音质的调用会拿到不完整数据。

---

## 🟡 P2-12 `loginQrCheck` 比 Node 多传 `timestamp`/`_t`，且不写 `kg.t1`

**位置**
- `lib/core/direct/kg_endpoints_auth.dart:252-275`：`params` 含 `'timestamp': timestamp, '_t': timestamp`
- Node `KuGouMusicApi/module/login_qr_check.js:9-17`：无这两个参数
- `:273-274` 只更新 `kg.token/kg.userid`，未更新 `kg.t1`
- Node 同样只 push token/userid，但 Node 的后续 `login_token` 从 cookie 取 t1；Dart 的 `kg.t1` 是独立字段

**依据/影响**
- 多出的参数会进入 web 签名；若服务端按“收到的参数集合”重算签名通常无碍，但多参数属于无依据偏离，且轮询请求无法从 `docs/api_verified.md` 找到字段级验证记录。
- 二维码登录后若 `login/token` 刷新需要 t1，Dart 没有从 QR 响应回填（响应里有 t1 时也未取），与短信/密码登录的 `_afterLogin` 行为不一致。当前 `login_page.dart:577` 直接 `loginByQrToken`，依赖刷新接口返回新 t1；若刷新失败则无兜底。

---

## 汇总

| 级别 | 数量 | 条目 |
|---|---|---|
| 🔴 P0 | 7 | P0-1 异常契约 / P0-2 写请求重复回退 / P0-3 登录态未同步 / P0-4 歌单删除 RSA / P0-5 歌单加歌 data / P0-6 歌单删歌 data / P0-7 评论写路由 |
| 🟠 P1 | 7 | 楼中楼 is_t / 删除评论方法 / 歌单详情登录态 / top playlist 字段 / 权益 album_id / 验证提交 GET+绕层 / search special 参数 |
| 🟡 P2 | 12 | _wrap 类型 / lyric contenttype / 评论 code 大小写 / playlist source / comment 可选字段 / videoDetail 三副本 / 主类死代码 / 循环 import 与未用 import / 注释残骸 / playlistDel listid / qualities 子集 / qr check 参数与 t1 |

**总体判断**
- 7 个端点文件“方法能编译、大部分读接口与 Node 字段对齐”，但 R1 拆分后仍存在 **7 个 P0 级协议/集成问题**，集中在：异常契约、登录态同步、写请求回退、歌单写协议、评论写路由。
- 读接口中 `playlistDetail`、`top/playlist`、`privilege`、`search(special)` 存在字段级偏差；其中 `top/playlist` 的偏差与既有 `ec=200101` 叠加，不能再用“上游收紧”单独解释。
- 报告只列问题与依据，不含修复方案；未修改任何源码、未运行测试/构建/网络请求。
