# 内容类接口（搜索/首页/歌单）原生 API 移植报告

- 任务：把直连层内容接口按上游 KuGouMusicApi 真实域名逐个替换，实测验证 + kapi 结构对比。
- 源码依据：`/var/minis/workspace/KuGouMusicApi/module/{search,search_mixed,search_lyric,yueku,rank_list,top_song,top_playlist,playlist_detail,playlist_track_all,everyday_recommend}.js` 逐行阅读 + `util/request.js`（默认 baseURL=`https://gateway.kugou.com`，encryptType=android → `signatureAndroidParams`，盐 `OIlwieks28dk2k092lksi2UIkp`；`signParamsKey` = MD5(appid+盐+clientver+data)）。
- 实测脚本：`tool/probe_native_content.py`（新增）+ `tool/kg_probe.py`（复用）。全部**匿名**实测（前次报告已证三态差异极小）。

## 一、总表（接口 → 域名 → url → method → 签名 → 实测）

| # | 接口（Dart 路径） | 上游模块 | 原生域名 | url | method | encryptType | 实测（匿名） | 采纳 |
|---|---|---|---|---|---|---|---|---|
| 1 | /search（song） | search.js | `complexsearch.kugou.com` | `/v3/search/song` ⚠️ | GET | android | 200，`data.lists` 30 条，`FileHash/MixSongID/Res{Hash,FileSize,BitRate,TimeLength}/HQ/SQ` | ✅ 原生 |
| 2 | /search（album） | search.js | `complexsearch.kugou.com` | `/v1/search/album` | GET | android | 200，`data.lists` 20 条，`albumid/albumname/singer/img/songcount` | ✅ 原生 |
| 3 | /search（special/author/mv/lyric） | search.js | `complexsearch.kugou.com` | `/v1/search/{type}` | GET | android | 200（special 实测 20 条 `specialid/gid/img/song_count`） | ✅ 原生 |
| 4 | /search/mixed | search_mixed.js | `complexsearch.kugou.com` | `/v3/search/mixed` | GET | android | 200 但 `error_code=152 Parameter Error` —— **kapi 同样 152**，行为一致 | ✅ 原生（App 未使用） |
| 5 | /search/lyric | search_lyric.js | `lyrics.kugou.com` | `/search`（非上游写的 `/v1/search`，见既有结论：该路径不存在） | GET | **notSignature**（clearDefaultParams） | 200 `errcode=200`，`candidates[].id/accesskey/duration` | ✅ 原生（已落地） |
| 6 | /yueku | yueku.js | `service.mobile.kugou.com` | `/v1/yueku/recommend_v2` | GET | android | 原生域名 TLS 失败（见二）→ **gateway + x-router 实测 200** | ⛔ 保持 gateway |
| 7 | /rank/list | rank_list.js | `ocean.kugou.com` | `/v6/rank/list`（去掉 gateway 路由前缀 `ocean/`） | GET | android | 200，`data.info` 56 项 `rankid/rankname/banner_9/children/songinfo` | ✅ 原生 |
| 8 | /top/song | top_song.js | `musicadservice.kugou.com` | `/container/v1/newsong_publish`（去掉前缀 `musicadservice/`） | POST | android | 200，`data` 是**数组**（每项一首歌，含 `authors[]/hash_flac/...`）+ `total/extra` | ✅ 原生（新增） |
| 9 | /top/playlist | top_playlist.js | `specialrec.service.kugou.com` | `/v2/special_recommend` | POST | android（另 body 内 `key=signParamsKey(clienttime)`） | 原生域名 TLS 失败（见二）→ gateway + x-router 实测 200，`special_list` 10 条（pagesize=5） | ⛔ 保持 gateway |
| 10 | /playlist/detail | playlist_detail.js | `pubsongs.kugou.com` | `/v3/get_list_info` | POST | android | 200，`data[0]` `name/pic/intro/count/global_collection_id/...` | ✅ 原生 |
| 11 | /playlist/track/all | playlist_track_all.js | `pubsongs.kugou.com` | `/v2/get_other_list_file_nofilt`（去掉前缀 `pubsongs/`） | GET | android | 200（传 `collection_xxx` gid），`data.songs` 30 + `data.count`；数字 specialid 报 20010 | ✅ 原生 |
| 12 | /everyday/recommend | everyday_recommend.js | `everydayrec.service.kugou.com` | `/everyday_song_recommend` | POST | android | 原生域名 TLS 失败（见二）→ gateway + x-router 实测 200 `data.song_list` | ⛔ 保持 gateway |

### 原生域名直打要点

1. **x-router 目标域名作为 Host 时，gateway 的路由前缀要去掉**：gateway 按 url 第一段路由（`/ocean/…` → ocean 服务、`/pubsongs/…` → pubsongs、`/musicadservice/…` → musicadservice），因此原生域名下 url 为去前缀后的路径（`/v6/rank/list`、`/v2/get_other_list_file_nofilt`、`/container/v1/newsong_publish`）。保留前缀实测一律 404（nginx 404 HTML）。
2. **带前缀的 url 保持不变**：`complexsearch` 的 `/v1|v2|v3/search/*`、`pubsongs.kugou.com` 的 `/v3/get_list_info` 均有版本前缀，不属于路由段。
3. **默认参数 + android 签名照旧**：原生域名仍要求 dfid/mid/uuid/appid=1005/clientver=20489/clienttime + `signature`（MD5(盐+sorted-kv+body+盐)）。只有 lyrics 的搜索例外（不签名）。
4. **不需要 x-router 头**：原生域名直打实测加不加 x-router 均可；落地代码不再传，行为更贴近真机。

## 二、为什么 6/9/12 不能改原生域名（TLS 证书硬伤）

`*.kugou.com` 通配符证书只覆盖**单标签子域**。三标签域名：

- `service.mobile.kugou.com`：返回网宿 CDN 证书 `CN=default.chinanetcenter.com`（SAN 列表含 `*.service.kugou.com` 但不含 `service.mobile.kugou.com`）
- `specialrec.service.kugou.com` / `everydayrec.service.kugou.com`：返回 `CN=*.kugou.com`，SAN 仅 `*.kugou.com/*.kgimg.com/...`，**不匹配三标签 host**

curl/python/Dart(Dio→secure socket) 三方一致报 `SSL: no alternative certificate subject name matches`。真机上这些域名要么被 CDN 调度到同样错配的边缘节点，要么是 App 层关闭校验/走专用通道；对 Dart 直连而言是硬失败。**结论：yueku / top/playlist / everyday/recommend 保持 gateway（这些接口 gateway 上游本就只用 x-router，无独立 baseURL），不在本次替换范围**。gateway 打这些接口本身 403 风险低（403 主要发生在真机直打 gateway 的部分地区，回退链 `_directOrFallback` 已兜底）。

## 三、与 kapi（https://kapi.344977.xyz）结构逐字段对比

方法：匿名实测两侧响应做递归 key-diff（列表取第 0 项）。

| 接口 | diff 结论 |
|---|---|
| /search（song） | **kapi 返回 version=3 结构** → 对应 `/v3/search/song`。用 `/v3/search/song` 实测 key-diff **完全一致**（0 差异）。⚠️ Dart 现行 `/v2/search/song` 与 kapi 结构有差异（v2 多 `A320Privilege/Category/SongName/SingerId...` 40+ 字段、少 `Accompany/PrepublishInfo/HQ/SQ/Res.Hash...`）。模型层 `HomeSong.fromJson` 已兼容两种（`songname/OriSongName/FileName` fallback），但为对齐 kapi 应改用 `/v3`。 |
| /search（album/special） | 逐字段一致（kapi 同路径同结构） |
| /search/mixed | 双侧同样 `status=1 error_code=152 Parameter Error`，结构一致（上游该接口当前即如此） |
| /search/lyric | 完全一致（`candidates[]` 同构） |
| /yueku | 完全一致（`data.info.*`） |
| /rank/list | **完全一致**（0 差异，info 56 项同构） |
| /top/song | **完全一致**（0 差异；`data` 均为数组） |
| /top/playlist | 结构一致；唯一差异 `special_list[0].abtags` 仅 kapi 有（A/B 分桶可选字段）；条数 10 vs 35 仅因 pagesize（5 vs 默认 30）|
| /playlist/detail | **完全一致**（0 差异） |
| /playlist/track/all | **完全一致**（0 差异；传数字 specialid 双侧均 20010，gid 才有效） |
| /everyday/recommend | **完全一致**（0 差异） |

**Repository 无感知**：所有可原生接口结构与 kapi 完全一致或差异仅为可选字段；唯一需要动的对外行为是 `/search(song)` 路径 v2→v3，由本任务在直连层内部完成（kapi 本来就是 v3 结构，直连改 v3 后反而与 kapi 回退路径对齐）。

## 四、代码落地（已直接编辑 `lib/core/direct/kg_direct_api_client.dart`，未触碰登录类 case）

只改内容类私有方法，`_directOrFallback` 包装不变（原生域名失败自动回退 kapi）：

1. `_search`：song 分支 `/v2/search/song` → **`/v3/search/song`**，base 换 `https://complexsearch.kugou.com`，去 x-router；album/其余类型路径不变，base 同换。
2. `_rankList`：`/ocean/v6/rank/list` → **`https://ocean.kugou.com/v6/rank/list`**。
3. `_playlistDetail`：base → `https://pubsongs.kugou.com`（去 x-router）。
4. `_playlistTrackAll`：`/pubsongs/v2/get_other_list_file_nofilt` → **`https://pubsongs.kugou.com/v2/get_other_list_file_nofilt`**。
5. `_topSong`（**新增** case `'top/song'` + 方法）：POST `https://musicadservice.kugou.com/container/v1/newsong_publish`，body `{rank_id,userid,page,pagesize,tags:[]}`。此前 App 请求 `/top/song` 走 kapi 回退，现在直连可用。
6. `_yueku` / `_topPlaylist` / `_everydayRecommend` / `_searchLyric`：**保持现状**（gateway+x-router / lyrics.kugou.com），附 TLS 原因注释。

> search/lyric 已在上一轮落地 `lyrics.kugou.com/search`（原 `/v1/search` 路径不存在），本次复核实测通过，未改动。

## 五、验证记录

- [x] 每接口实测记录（见一、三节；脚本 `tool/probe_native_content.py` 可复跑）
- [x] `check_braces.sh` 通过（见下）
- [x] `flutter analyze` 无新增 warning（见下）
- [x] 未触碰登录类 case（`login/cellphone|token|qr/*|login`、register/dev、captcha 等区域零改动，git diff 可核）
