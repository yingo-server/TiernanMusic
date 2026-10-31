# 直连内容接口三态实测报告

- 复刻脚本：`tool/kg_probe.py`（Dart 直连逻辑的 urllib 复刻）+ `probe_content.py` / `probe_lyric.py` / `probe_rest.py` / `probe_get_routes.py`
- 三态：匿名（无 cookie）/ 非VIP（userid=2461028533）/ VIP（userid=1666835066）
- 被测样本：`晴天` hash=`B3A52A7A958BF0AED0EBFBA2E9A818B7` mixsongid=32100650 album_audio_id=32100650
- 实测结论：**本次所有内容接口在三态下差异极小**（匿名即可拿到全部内容；VIP 不带来额外字段）。

## 一、三态总表

| 接口（Dart 路径） | 直连端点 | anon | nonvip | vip | 关键字段 |
| --- | --- | --- | --- | --- | --- |
| search(song) | GET `/v2/search/song` | ✅ | ✅ | ✅ | `data.lists[]`、`data.total=480`，项含 `FileHash/SongName/SingerName/Duration/AlbumID/MixSongID/Image/trans_param` |
| search(special) | GET `/v1/search/special` | ✅ | ✅ | ✅ | `data.lists[]`，`specialid`/`gid`/`img`/`specialname`/`song_count`/`play_count` |
| search(album) | GET `/v1/search/album` | ✅ | ✅ | ✅ | `data.lists[]`，`albumid/albumname/singer/img/songcount` |
| search(mv) | GET `/v1/search/mv` | ✅ | ✅ | ✅ | `data.lists[]`，`MvID/AudioID/MvHash/MvName/FileHash/Duration/MixSongID/Pic` |
| search(author) | GET `/v1/search/author` | ✅ | ✅ | ✅ | `data.lists[]`，`AuthorId/AuthorName/Avatar/AlbumCount` |
| search/lyric | GET `lyrics.kugou.com/search` | ✅ | ✅ | ✅ | `candidates[].id/accesskey/duration/song/singer`（**原 `/v1/search` 恒空**） |
| lyric | GET `lyrics.kugou.com/download` | ✅ | ✅ | ✅ | `status=200 error_code=0 content/contenttype/fmt/id`；krc 长 5592、lrc 长 3488 |
| comment/music | POST `/mcomment/v1/cmtlist` | ✅ | ✅ | ✅ | **顶层 `list`**（无 data 层）；`count=710223`；`like` 是对象 |
| comment/count | GET `/index.php` (web 签名) | ✅ | ✅ | ✅ | **整个响应就是 `{hash: 数字}`**，无 status/data 包裹 |
| comment/floor | POST `/mcomment/v1/hot_replylist` | ✅ | ✅ | ✅ | 顶层 `list[]`，含 `ori_cmt_id/pid/tid/content/like` |
| yueku | GET `/v1/yueku/recommend_v2` | ✅ | ✅ | ✅ | `data.info.{song,topic,video,rank,album,recommend,...}` |
| rank/list | GET `/ocean/v6/rank/list` | ✅ | ✅ | ✅ | `data.info[]` 56 项，`rankid/rankname/banner_9/children/songinfo` |
| everyday/recommend | `/everyday_song_recommend` | ✅ | ✅ | ✅ | `data.song_list[]` 29/30/30，`hash/songname/author_name/album_id` |
| top/playlist | POST `/v2/special_recommend` | ✅ | ✅ | ✅ | `data.special_list[]` 30 项，`specialid/specialname/songcount/flexible_cover`；**GET 一律 200101** |
| playlist/detail | POST `/v3/get_list_info` | ✅ | ✅ | ✅ | `data[0]`，`name/pic/intro/count/global_collection_id/list_create_username` |
| playlist/track/all | GET `/pubsongs/v2/get_other_list_file_nofilt` | ✅ | ✅ | ✅ | `data.songs[]` 30 + `data.count`，`hash/name/audio_id/album_id` |
| kmr/audio/mv | POST `/kmr/v1/audio/mv` | ✅ | ✅ | ✅ | `data` 嵌套 `[[{...}]]`；**必须传 mixsongid(32100650)，传 audio_id(20505418) 返回 `[{}]`** |
| video/url | GET `/v2/interface/index` | ✅ | ✅ | ✅ | `data["<hash小写>"].{downurl,backupdownurl,filesize}`，downurl 是 http |

## 二、歌词接口排查结论（重点）

**现象**：`https://lyrics.kugou.com/v1/search?...` 返回 HTTP 200、响应体**长度为 0**、响应头 `x-kg-errcode: 20010`。

**排查**：排除法测了 10 种组合，全部同样空：
参数（去 lrctxt / 去 man / 去 hash / 去 duration / duration=秒|毫秒|0 / appid=3116-lite / clientver=1000|11451|20489）、
请求头（User-Agent=KugouMusic、Referer、Accept+Accept-Encoding:identity）、
协议（http 明文）、加 `x-router: lyrics.kugou.com`、经 gateway 转发、加完整默认参数与 signature。
→ **与 Accept-Encoding/Referer/参数顺序/签名全部无关**。

**根因**：`/v1/search` 这个路径在 lyrics.kugou.com 上**不存在**。
- `/v1/search` → `x-kg-errcode: 20010`，空体
- `/v2/search` → `20006` + `{"status":0,"errcode":400,"errmsg":"auth fail, invalid clienttime"}`
- **`/search`（无版本前缀）→ `x-kg-errcode: 200`，正常返回 candidates**

**修复**：路径 `/v1/search` → `/search`；duration 改传毫秒（搜索结果 Duration=269 秒，候选 duration=269792 毫秒）；不签名。

实测返回：`status=200 errcode=200`，`proposal=274944371`，`candidates[0]` =
`id=274944371 accesskey=2A7B35884B3C20E9D3281686BA59A3F8 duration=269792 song=晴天 singer=周杰伦`。
下载 `lyrics.kugou.com/download?ver=1&client=android&id=274944371&accesskey=2A7B35884B3C20E9D3281686BA59A3F8&fmt=krc&charset=utf8`
三态均拿到 content（krc 5592 字符 / lrc 3488 字符，`contenttype` krc=0、lrc=1），与已知候选一致。

## 三、失败案例原始响应

1. `/v1/search`（歌词搜索，旧路径）
```
HTTP/2 200
content-type: application/json;charset=utf-8
x-kg-errcode: 20010
content-length: 0
（响应体为空）
```
2. playlist/detail 旧载荷 `{"listid":[...],"area_code":1,...}`（v1/v2/v3 全部）
```
{"status": 0, "error_code": 20010}
# v2 版本多给一条提示：
{"error_code": 20010, "errmsg": "data len need in [1, 10]", "data": {}, "status": 0}
```
3. top/playlist 用 GET 调用 `/v2/special_recommend`（三态一致）
```
{"data": "", "status": 0, "error_code": 200101}
```
4. kmr/audio/mv 传错 id（audio_id=20505418 而非 mixsongid=32100650）
```
{"status": 1, "error_code": 0, "errmsg": "", "data": [{}]}
```
5. GET `/kmr/v1/audio/mv` → HTTP 502 `<html>...502 Bad Gateway...openresty`（该端点只接受 POST）
6. 不带 x-router 的 `/v3/get_list_info` → HTTP 502 Bad Gateway（必须 `x-router: pubsongs.kugou.com`）
7. get_list_info 传 `userid` 为字符串时（服务端类型提示，证明 body 被正确解析）：
```
{"error_code": 20010, "errmsg": "Body err: json: cannot unmarshal string into Go struct field Request.userid of type int64", "data": {}, "status": 0}
```

## 四、已修复（lib/core/direct/kg_direct_api_client.dart）

1. `_searchLyric`：路径 `/v1/search` → **`/search`**；恢复 `notSignature: true`；duration 秒转毫秒；hash/album_audio_id 仅非空时传。
2. `_playlistDetail`：载荷 `{"listid":[...]}` → **{"data": [{"global_collection_id": "<gid>"}]}`**（限 10 项）；支持 `global_collection_id` 入参。

## 五、待办（已定位，本次未改）

1. **路由-方法不匹配**：仓库里 `playlist/detail`、`kmr/audio/mv`、`comment/music`、`comment/floor` 全用 `_api.get()` 调用，但直连覆写只在 `post()` 分支里处理 → GET 会漏到 kapi 回退。需在 `get()` 的 switch 中补 `'playlist/detail'`、`'kmr/audio/mv'`、`'comment/music'`、`'comment/floor'`。
2. `top/playlist`（`/v2/special_recommend`）**必须 POST + 完整 body**（GET 恒 200101）；仓库用 GET 调用，同样需要把该 case 移到 `get()` 分支并强制 POST。
3. `kmr/audio/mv` 需要 **mixsongid**（`32100650`），MV 仓库传的是 `album_audio_id`；实测传 `20505418` 返回 `[{}]`。
4. `_commentCount` 返回体是 `{hash: n}` 无 status 包裹，`_wrap` 会因 `status==null` 误判；仓库 `fetchCount` 已按 `data[hash]` 取值，需放开该接口的 status 校验。
5. `comment/music` / `comment/floor` 实测 GET/POST 均可返回数据，可统一走 GET。
