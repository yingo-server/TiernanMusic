# API 三态样本索引

自动生成，勿手改。每行对应 `docs/api_samples/<name>/<state>.json`。

| 接口 | 方法 | 路径 | 关键参数 | 成功判定 | anon | nonvip | vip |
|---|---|---|---|---|---|---|---|
| search_song | GET | `/search` | `keywords=晴天, type=song, page=1` | status=1 + data.lists[] | ok | — | — |
| search_album | GET | `/search` | `keywords=晴天, type=album, page=1` | status=1 + data.lists[] | ok | — | — |
| search_special | GET | `/search` | `keywords=流行, type=special, page=1` | status=1 + data.lists[]（gid 字段） | ok | — | — |
| search_author | GET | `/search` | `keywords=周杰伦, type=author, page=1` | status=1 + data.lists[] | ok | — | — |
| search_mv | GET | `/search` | `keywords=晴天, type=mv, page=1` | status=1 + data.lists[]（MvHash 才是视频 hash） | ok | — | — |
| search_hot | GET | `/search/hot` | `` | status=1 + data.list[] | ok | — | — |
| search_suggest | GET | `/search/suggest` | `keywords=周杰` | data[].RecordDatas[].HintInfo | ok | — | — |
| search_lyric | GET | `/search/lyric` | `hash=B3A52A7A958BF0AED0EBFBA2E9A818B7, album_audio_id=32100650` | **status=200 + errcode=200（成功，不是错误）** + candidates[] | ok | — | — |
| lyric | GET | `/lyric` | `id=274944371` | status=1 + decodeContent / content(base64 加密 KRC) | ok | — | — |
| song_url | GET | `/song/url` | `hash=9839C10AB3BE538976A3D1157B3707DB, album_audio_id=979006105, quality=128` | status=1 + data.url[]（数组）；VIP 曲匿名 status=2 | needs_verification | — | — |
| song_url_vip | GET | `/song/url` | `hash=B3A52A7A958BF0AED0EBFBA2E9A818B7, album_audio_id=32100650, quality=128` | 匿名 status=2 fail_process=[pkg,buy]；加 free_part=1 得 60 秒试听 | needs_verification | — | — |
| privilege_lite | GET | `/privilege/lite` | `hash=9839C10AB3BE538976A3D1157B3707DB` | status=1 + data[]（relate_goods 内才是各档权益） | ok | — | — |
| kmr_audio_mv | GET | `/kmr/audio/mv` | `album_audio_id=32100650` | status=1 + data[0] 为数组 | ok | — | — |
| video_detail | GET | `/video/detail` | `id=117613` | status=1 + data[]（首项为视频对象，hash 平铺顶层） | ok | — | — |
| video_url | GET | `/video/url` | `hash=C95D2E0D2A3B4B7B0F2E5E9C1A2B3C4D` | status=1 + data[<hash小写>].downurl | http_error | — | — |
| playlist_detail | GET | `/playlist/detail` | `ids=collection_3_520033052_181_0` | status=1 + data[]（首项）；数字 id → data:{} | ok | — | — |
| playlist_track_all | GET | `/playlist/track/all` | `id=collection_3_520033052_181_0, page=1` | status=1 + data.songs[] + data.count | ok | — | — |
| top_playlist | GET | `/top/playlist` | `page=1` | status=1 + data.special_list[]（global_collection_id） | ok | — | — |
| top_song | GET | `/top/song` | `type=21608, page=1` | status=1 + data[]（新歌） | ok | — | — |
| rank_list | GET | `/rank/list` | `` | status=1 + data.info[] | ok | — | — |
| yueku | GET | `/yueku` | `` | status=1 + data.info.{song,recommend} | ok | — | — |
| yueku_banner | GET | `/yueku/banner` | `` | 实测 error_code=31136（上游无数据） | http_error | — | — |
| everyday_recommend | GET | `/everyday/recommend` | `platform=android` | 需登录；匿名 status=0 error_code=200103（缺 platform 参数时也是 200103） | ok | — | — |
| comment_music | GET | `/comment/music` | `mixsongid=32100650, page=1` | status=1 + 顶层 list[] | ok | — | — |
| comment_count | GET | `/comment/count` | `hash=B3A52A7A958BF0AED0EBFBA2E9A818B7` | 裸 Map {"<hash>": n}（无 status 包裹） | unknown | — | — |
| comment_floor | GET | `/comment/floor` | `mixsongid=32100650` | status=1 + 顶层 list[] | ok | — | — |
| comment_playlist | GET | `/comment/playlist` | `id=collection_3_520033052_181_0, page=1` | status=1 + 顶层 list[] | ok | — | — |
| register_dev | GET | `/register/dev` | `` | status=1 + data.dfid | ok | — | — |
| user_detail | GET | `/user/detail` | `` | 需登录：status=1 + nickname/pic（无 userid） | http_error | — | — |
| user_playlist | GET | `/user/playlist` | `page=1` | 需登录：status=1 + data.info[] | http_error | — | — |
| get_verify_info | GET | `/get/verify/info` | `` | 无效 eventid → 36001（仅验证连通） | http_error | — | — |
