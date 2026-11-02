## 直连端点实测（匿名态，2026-11-03）

| 端点 | 结果 | 关键发现 |
|---|---|---|
| search/song | ✅ st=1 data=dict(19) | complexsearch.kugou.com/v3 |
| search/hot | ✅ st=1 | msearch.kugou.com |
| rank/list | ✅ st=1 info 56 项 | ocean.kugou.com/v6 |
| rank/audio | ✅ st=1 {total,songlist[]} | kg-tid 369；签名用 defaultParams+body |
| playlist/detail | ✅ st=1 data=list[1] | pubsongs/v3，载荷 data[].global_collection_id |
| playlist/track/all | ✅ st=1 | pubsongs/v2/get_other_list_file_nofilt |
| artist/detail | ✅ st=1 data=dict(14) | gateway/kmr/v3/author |
| artist/audios | ✅ st=1 data=list(3) | **签名需 defaultParams+body 合并**（clearDefaultParams 会 20006） |
| artist/albums | ✅ st=1 data=list[3] | kmr/v1/author/albums |
| album/detail | ✅ st=1 data=list[1] | kmr/v2/albums |
| album/songs | ✅ st=1 {songs,total} | v1/album_audio/lite |
| kmr/audio/mv | ✅ st=1 data=list[1] | openapi + KG-TID:38，body album_audio_id |
| comment/music | ✅ st=1 顶层 list | **参数走 query 不是 body** |
| comment/floor | ✅ st=1 | mcomment/v1/hot_replylist |
| comment/count | ✅ {"hash":710442} | web 签名 + sum.comment.service x-router |
| privilege/lite | ✅ st=1 relate_goods 7 项 | resource[{type:audio,page_id:0}]，qualities 数组 |
| song/url | ✅ st=1 | 需 key（signKey）；直连无 20028 |
| video/detail | ✅ st=1 清晰度 hash 齐全 | kmr.service x-router |
| video/url | ✅ st=1 downurl | trackermv.kugou.com/v2/interface/index |
| lyric/search | ✅ st=200 errcode=200 | **成功语义是 status=200** |
| yueku | ✅ st=1 {timestamp,info} | v1/yueku/recommend_v2 |
| everyday/recommend | ✅ st=1 | platform 必须是 query 参数 |
| login/qr/key | ✅ st=1 qrcode | web 签名 + login-user.kugou.com |
| get/verify/info | ✅ st=0 ec=36001 | 假 eventid 正确报错（接口通） |
| top/song | ✅ | musicadservice.kugou.com |
| top/playlist | ⚠️ ec=200101 | 直连不可用，保留 kapi 回退 |

## 签名要点（实测）

### 三种签名模式，勿混用
1. **android**（默认）：`md5(salt + sorted("k=v") + bodyStr + salt)`，salt=`OIlwieks28dk2k092lksi2UIkp`
   - 签名输入 = **defaultParams + 自定义 params**（body 单独传，不进签名，除非也在 params 里）
2. **web**：`md5(WEB_SALT + sorted("k=v") + bodyStr + WEB_SALT)`，salt=`NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`
   - 用于 comment/count、login/qr/*
3. **register**：`md5("1014" + sorted(values) + "1014")`

### key（signParamsKey）
`md5(appid + salt + clientver + data)`，data 通常是 clienttime（**秒级**）

### key（signKey，播放用）
`md5(hash + "57ae12eb6890223e355ccfcb74edf70d" + appid + mid + userid)`，hash **必须小写**

## 已知端点行为
- `top/playlist`（special_recommend）直连恒 `ec=200101` → 保留 kapi 回退
- 歌词接口成功语义是 `status=200` + `errcode=200`（不是 status=1）
- 评论接口参数必须走 **query**，不能放 body
- 试听（`IsFreePart=1`）只提供固定 60 秒，**上游无分段续传接口**，无法拼接完整歌曲
- 匿名可播免费曲全音质；VIP 曲匿名恒 `status=2` + `fail_process=["pkg","buy"]`
