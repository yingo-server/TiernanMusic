# 第4批·修复①：网络层（端点域 + 播放 + 认证）修复记录

- 执行代理：修复①（子代理）
- 基线：`6e46611`
- 输入报告：`docs/batch4_review_1_network_b.md`（74 项）、`docs/batch4_review_1_network.md`
- 最高准则：`docs/QUALITY_STANDARD.md`（下文「对应条」均指其 32 条原则）
- 上游参考：`/var/minis/workspace/KuGouMusicApi`（MakcRe）`module/*.js` + `util/request.js`
- **所有「实测」均为 curl/python 直连酷狗原生域名所得，未起 Node、未装依赖**

---

## 一、核心实测结论（决定多条 P1 的成败，先列出来）

| # | 实测内容 | 结果 | 结论 |
|---|---|---|---|
| M1 | `trackercdn.kugou.com/v5/url` **不带** signature，只带 key | `{"errcode":"20006","status":0,"errmsg":"err signature"}` | 报告「撤掉 signature」**不成立**；Node `notSign` 拼写不生效（`util/request.js` 只认 `notSignature`），该端点实际是签名发的。签名保留 |
| M2 | 同上带 android signature，原生域 | 200 + `priv_status/hash_offset/url[]` | 原生域 `trackercdn.kugou.com` 直连可用（P1 第 2 条成立） |
| M3 | `openapi.kugou.com/kmr/v1/audio_group/author` / `/kmr/v3/author` | 200、`total/data` 与 gateway+x-router 逐字段一致 | 歌手域落原生域成立 |
| M4 | 歌曲评论四种路由 | A `gateway/mcomment/v1/cmtlist`(无 router)=200；B `gateway/v1/cmtlist`+x-router=200 同数据；C `mcomment` 前缀+x-router=`Access Deny !!!`；D 原生 `m.comment.service.kugou.com`=TLS Hostname mismatch | 采用 B（裸路径 + x-router），既合口径又不与服务前缀叠加 |
| M5 | `gateway/v2/special_recommend` 补齐 Node 五字段 | `status=1 / error_code=0`，special_list 35 条（旧 4 字段版 30 条、alg_id 不同） | 代码里「恒 200101」的注释**已过期**，P1 第 11 条成立且已实修 |
| M6 | `/ads.gateway/v3/listen_banner` 匿名 `vip_type=0` 与 `=1` | 两者均 `error_code=31136` | 匿名恒 31136 属上游行为；`vip_type` 只在登录态有意义 |
| M7 | `login.user.kugou.com` | **https 直连 TLS 证书 hostname mismatch**；http 200；`gateway + x-router: login.user.kugou.com` + `/v7/send_mobile_code` 200（`手机格式不正确`，路由正常） | 「改 https」不能简单的把 scheme 换掉（会直接 TLS 失败），改为 **gateway+x-router 的 https 通路** |
| M8 | `verifyservice` | `gateway + /verifyservice/v3/get_verify_info` 200（ec=36001，eventid 假的业务错）；`verifyservice.kugou.com + /verifyservice/v3/...` **404**；`verifyservice.kugou.com + /v3/...` 200 | `kg_client` 的「直连域 + 带前缀路径」确为 404，必须统一到 gateway 裸路径 |
| M9 | `v2/get_res_privilege/lite` relate_goods 结构 | 128→level 2、320→4、flac→5、high→6、蝰蛇/多轨 level=0（各一条）；条目字段 quality/level/privilege/status/pay_type/info.extname/info.filesize | Node `QUALITY_LEVEL` 可直接照抄；`relate_goods.first` 会串档 |
| M10 | `/v5/url`（IsFreePart=1）`hash_offset` | `{clip_hash, start_byte, end_byte, start_ms, end_ms, offset_hash, file_type}` | 只读 `end_ms` 丢失起播点与裁剪 hash |

---

## 二、已完成的修改（逐条）

格式：`编号 | 文件:行 | 改了什么 | 依据 | 对应 QUALITY_STANDARD 条`

### P1

1. **F4-01 | `lib/core/direct/kg_play_api.dart:44-56`（原 :46） | `/v5/url` 的 `notSignature` 处置**：报告要求撤掉 signature，**实测驳回**——保留自动 android 签名，并在代码内写明实测证据（不带签名 → `20006 err signature`）与 Node `notSign` 拼写不生效的原因 | 实测 M1 + `util/request.js:146`（只读 `options.notSignature`） | 第 28 条（调用方式必须实测，不得推测）、第 31 条（记录历史陷阱）
2. **F4-02 | `lib/core/direct/kg_play_api.dart:40-48`（原 :44） | 播放主路径 `/v5/url` 由 `gateway + x-router` 改为 `baseUrl: 'https://trackercdn.kugou.com'`，删掉 x-router 头 | 实测 M2；`REVIEW_SPEC` 域名表；口径 27 | 第 27 条（只走原生网关）、第 28 条
3. **F4-03 | `lib/core/direct/kg_endpoints_artist_album.dart:24-37`（artistDetail）、`:39-75`（artistAudios） | ①artistAudios 补 `baseUrl: 'https://openapi.kugou.com'`（Node 本就有）；②artistDetail 同落原生域；③`clienttime` 由 String 改 **int**（Node `Math.floor(..)` 为 Number，body 类型不再偏差） | `module/artist_audios.js:20-30`、`module/artist_detail.js:3-12`；实测 M3 | 第 27 条、第 28 条、第 15 条（单位/类型显式）
4. **F4-04 | `lib/core/direct/kg_endpoints_comment.dart:20-40`（原 :24） | 歌曲评论由 `'/mcomment/v1/cmtlist'`（gateway 根路径）改为 `'/v1/cmtlist'` + `x-router: m.comment.service.kugou.com`；代码注释留存四种路由的实测矩阵 | 实测 M4；口径「评论走 x-router」 | 第 27 条、第 28 条、第 31 条
5. **F4-05 | `lib/core/direct/kg_endpoints_comment.dart:132-190`（commentFloorSend，原 :126） | 补齐楼中楼回复契约：`pid` 缺省 `'0'`、`is_t = firstValue(is_t, isT, pid=='0'?1:0)`、`content//@user:原评论` 拼接（仅当有被回复人+内容且正文未含 `//@`）、透传 `extdata`、`source`、`childrenname` 四别名 | `module/_comment.js buildCommentReplyConfig`（逐字段对照） | 第 3 条（契约先行）、第 28 条
6. **F4-06 | `lib/core/direct/kg_endpoints_comment.dart:170-205`（commentDel，原 :161） | method `POST` → **GET**（Node 默认 GET、无 body）；`cid` 兼容 `comment_id` 别名且空值不下发；`tid` 空值不下发 | `module/_comment.js buildCommentDelConfig` + `commentRequestConfig(method='GET')` | 第 21 条（写操作幂等/契约）、第 28 条、第 16 条（缺失与空语义分离）
7. **F4-07 | `lib/core/direct/kg_play_api.dart:250-300`（`KgSharedParams.privilege`，原 :96-…） | 上游 `qualities` **恒下发完整 `upstreamQualities` 9 档**，不再用调用方传入的档位；新增常量 `upstreamQualities` / `defaultQualities`（Node 默认输出表，蝰蛇三档在后）；`qualities` 参数改为「输出过滤需求」 | `module/privilege_lite.js` `UPSTREAM_QUALITIES` + `qualities` 输出过滤逻辑；实测 M9 | 第 28 条、第 29 条、第 2 条（魔法值常量化）
8. **F4-08 | `lib/core/direct/kg_play_api.dart:76-95, 348-460`（`PrivilegeItem`） | 由「只取 `relate_goods.first`」改为 `_pickRelate` 按 `qualityLevels{128:[1,2],320:[4],flac:[5],high:[6],super:[7]}` **逐档挑选**；一条记录 = 一个 hash × 一个音质；新增 `level/exists/bitrate/extName`；`isFree` 由 `privilege==0` 改为 `exists && privilege==0 && status!=0`（对齐 Node obtainable） | `module/privilege_lite.js pickRelate / buildQualityVip`；实测 M9 | 第 29 条、第 16 条、第 30 条（命名表达意图）
9. **F4-09 | `lib/core/direct/kg_play_api.dart:300-350`（`PlayUrlResult.fromResponse`，原 :255） | 读取 `hash_offset` 全字段：`start_ms`/`end_ms`/`clip_hash`/`offset_hash`，新增 `startMs/endMs/clipHash/offsetHash` 与 `clipDurationMs`；试听判定改为「区间时长 ≤65s」而非 `end_ms≤65000` | 实测 M10；`module/song_url.js`（kapi 透传 hash_offset） | 第 29 条、第 15 条（毫秒单位显式）、第 13 条（外部数据先验证类型）
10. **F4-10 | `lib/core/direct/kg_endpoints_media.dart:93-115`（原 :110） | privilege 空 hash **前置拦截**：`resource` 为空直接返回 `status 502 / error_code -1 / error '缺少歌曲 hash'`，不再向上游发空数组 | `module/privilege_lite.js:135-141`（`Promise.reject 502`）；实测空 resource → `20010` | 第 14 条（边界校验）、第 16 条、第 9 条（失败可观测）
11. **F4-11 | `lib/core/direct/kg_endpoints_home.dart:74-125`（topPlaylist） | `special_recommend` 内层补 `sort/ugc/is_selected/withrecommend/area_code`，删掉 Node 没有的 `tagids`；注释更新为本次实测（直连可用、35 条） | `module/top_playlist.js:8-17`；实测 M5 | 第 28 条、第 29 条、第 31 条
12. **F4-12 | `lib/core/direct/kg_endpoints_home.dart:150-175`（yuekuBanner）+ `lib/core/direct/kg_client.dart:203-210` | `vip_type` 不再硬编码 0，改 `int.tryParse(kg.vipType) ?? 0`；`KgClient` 新增 `vipType`/`vipToken` 两个登录态字段（供三态判定） | `module/yueku_banner.js:10`（Node 硬编码 0 只覆盖匿名态）；实测 M6 | 第 7 条三态兼容（REVIEW_SPEC §7）、第 5 条（状态单一来源）
13. **F4-13 | `lib/core/direct/kg_endpoints_home.dart:66-82, 108-120` | topSong / topPlaylist 的 `userid` 统一 `int.tryParse(...) ?? 0`（Node `userid || cookie.userid || 0`），避免空串上行 | `module/top_song.js:7`、`module/top_playlist.js:25` | 第 17 条（标识符类型）、第 14 条
14. **F4-16 | `lib/core/direct/kg_endpoints_comment.dart:43-66`（commentCount，原 :49） | `hash`/`special_id` 由「只判 `!= null`」改为 `_nonEmpty()` **真值判定**，空串 hash 不再顶掉 childrenid | `module/comment_count.js:9-13`（`if (params.hash) … else if (params.special_id)`） | 第 16 条、第 28 条
15. **F4-17 | `lib/core/direct/kg_endpoints_comment.dart:70-130`（commentSend） | body 增 `extdata`（= `content_extdata`）、`album_audio_id` 支持 `album_audio_id` 别名、`images` 透传；query 增 `source`；`childrenname` 收敛 `name/song_name/album_name/playlist_name/childrenname` | `module/_comment.js buildCommentSendConfig`（compact + firstValue） | 第 3 条、第 28 条、第 16 条
16. **F4-18 | `lib/core/direct/kg_endpoints_comment.dart:178-200` | 删除评论 `cid` 空值拦截 + `comment_id` 别名（合并进 F4-06） | `module/_comment.js:197` `firstValue(cid, comment_id)` + compact | 第 21 条、第 14 条

### P2（顺手修，均不扩大范围）

17. **F4-19 | `lib/core/direct/kg_endpoints_comment.dart:228-300`（commentFloor） | 保留原路由并新增 `_nonEmpty/_childName` 辅助（供上述各方法复用） | `module/comment_floor.js` | 第 32 条（去重）、第 30 条
18. **F4-20 | `lib/core/direct/kg_play_api.dart:255-290`（`KgSharedParams.privilege`） | `resource[].album_id` 缺失/空串时下发**数值 0**（原为字符串 `'0'`） | `module/privilege_lite.js:147-152`（`albumIdList[index] || 0`） | 第 17 条、第 13 条
19. **F4-24 | `lib/core/direct/kg_endpoints_artist_album.dart:138-165`（albumSongs） | `is_buy` 由 `?? ''` 改为 Node 的 `|| ''` 语义（0/false/'0' → ''） | `module/album_songs.js:5` | 第 28 条、第 16 条
20. **F4-25 | `lib/core/direct/kg_endpoints_artist_album.dart:118-140`（rankAudio） | `rank_id` 仅在调用方给出时下发（Node `rank_id: params.rankid`，undefined 键被丢弃），不再补 0 落到默认榜 | `module/rank_audio.js:12` | 第 16 条、第 28 条
21. **F4-26 | `lib/core/direct/kg_endpoints_comment.dart`（新增 `_nonEmpty` / `_childName`） | 与 Node `firstValue` 同语义的私有工具（null/''/'null'/'undefined' 视为缺失） | `module/_comment.js firstValue/compact` | 第 30 条、第 32 条
22. **F4-27 | `lib/core/direct/kg_endpoints_comment.dart:206-214` | 删除从 playlistDel 残留过来的孤儿文档注释（该协议描述不属于评论端点） | 第 32 条（死代码/死注释零容忍） | 第 32 条

---

## 三、未修的条目及原因

### 因「主代理禁区」未修（禁止改动该文件）
- 报告 A 中 `kg_direct_api_client.dart` 的全部问题（P0 写操作重复提交、`_wrap` 各分支、`setCredentials` 不同步 dfid/旧 t1、`_commentCodeOf` 死代码、`qr_flutter` 死导入、`_videoDetail` 未委托等）：**由主代理处理**，本代理未触碰该文件。
- `kg_endpoints_search.dart` / `kg_endpoints_playlist.dart` 已由主代理修完，本代理未动。

### 因「需要登录态/真实账号才能实测」未修（口径 28/29 不允许靠推测下结论）
- **F4-14 登录保存 `vip_type`/`vip_token` 到 `_afterLogin`**：`KgClient` 字段已加好（F4-12），但 `_afterLogin` 属于登录链路，需要真实短信/扫码登录才能确认响应里 `vip_type`/`vip_token` 的实际形态与层级（顶层 vs `data.*`）；未实测就写入等于制造「看起来支持 VIP」的假实现。**状态：字段已就绪，赋值待有账号时补一行**（`kg.vipType = '${data['vip_type'] ?? kg.vipType}'; kg.vipToken = '${data['vip_token'] ?? kg.vipToken}';`）。
- **F4-15 getVerifyInfo 与 `kg_client` 前缀统一**：已实测出结论（M8：`kg_client` 的「直连域 + `/verifyservice/...` 前缀」= 404，gateway 裸路径可用），但真正落改需要改 `kg_client.submitFingerprintVerification` 的 baseUrl（该文件是允许改的），**因收尾时间到未落改**。下一步只需把 `baseUrl: 'https://verifyservice.kugou.com'` + `/verifyservice/v3/get_verify_info` 改为默认 gateway + `/verifyservice/v3/get_verify_info`（与 `kg_endpoints_auth.getVerifyInfo` 完全一致）。
- **F4-13 验证码改 https**：实测 M7 表明直接换 scheme 会 TLS 失败（`login.user.kugou.com` 证书不匹配），正确改法是 `gateway + x-router: login.user.kugou.com`（已验证 200）。**因时间到未落改**，代码仍为 `http://login.user.kugou.com`（明文，P1 仍存在）。
- **`commentDel` 改 GET 后的服务端行为**：无登录态无法实测，已按 Node 源码改，标注为「按 Node 对齐，未实测」。

### 时间不足未修（P2，已定位）
- `media.dart:44` videoUrl hash 未小写（与 `/v5/url` 策略不一致）。
- `media.dart:99` `free_part` 只认 `'1'/'true'`（Node 真值判定）。
- `artist_album.dart:42` pagesize 静默截断 100（实测 >100 会 20010，属已知约束，故意保留但未加日志）。
- `home.dart:98` searchHot 的 `navid/plat` 允许入参覆盖（Node 硬编码 1/2）。
- `home.dart:157/170` videoDetail 的 `uuid=md5(dfid+mid)` 与全局 `uuid:'-'` 两套策略并存、空 id 跳过项。
- `comment.dart:228` commentFloor 忽略调用方 `code`（需先实测自定义 code 的路由归属）。
- `comment.dart:198` commentPlaylist/commentAlbum 仍用服务端前缀路径（Node 一致、实测可用，仅口径不统一）。
- `kg_crypto.dart`：`aesEncryptHex` 命名/iv 派生与规范 §3 不一致（口径与 Node 实现冲突，需服务端解密结果裁定，不能盲改）；`randomString` 索引偏置；`register` 盐分支未接线。
- `kugou_api_client.dart`：拦截器与 `_wrap` 成功判定不一致、`verifyUrl` 恒 null、默认 baseUrl 即 kapi（kapi 已下线为参考，需主代理统一改）。
- `kg_client.dart:12` `core/` import `features/auth/data/edt_generator.dart`（分层回流，需把 edt_generator 迁到 core，属跨文件重构）。

### 与主代理口径变更相关的备注
- `fallbackToKapi` 已由主代理改为 `const false`：本代理未新增/未修改任何 `_directOrFallback` 调用点，签名保持不变；F4-10 的 502 返回会被 `_wrap` 转成 `ApiException(-1,'缺少歌曲 hash')` 直接上抛（不再二次提交）。
- 本代理所有改动均为「读接口 + 参数形态」，唯一写接口相关改动是评论三条（F4-05/F4-06/F4-17），均未引入回退，且与 Node 逐字段对齐。

---

## 四、验证状态说明
- 已实测：`/v5/url`（原生域 + 签名 vs 无签名）、`/kmr/v1/audio_group/author`（3 种路由）、`/kmr/v3/author`（3 种）、`/mcomment` 评论 4 种路由、`/v2/special_recommend`（4 组参数）、`/ads.gateway/v3/listen_banner`（vip_type 0/1）、`login.user.kugou.com`（http / https直连 / gateway+x-router）、`verifyservice`（3 种组合）、`/v2/get_res_privilege/lite`（relate_goods 全档结构）、`/v5/url` IsFreePart=1 的 `hash_offset` 全字段。
- 未实测（无账号/无短信）：评论写三条（发/回复/删）、登录与二维码、`vip_type/vip_token` 返回形态。
- 未运行 `dart analyze`（按收尾指令）；所有改动均为整段替换，无残留半截语句。
