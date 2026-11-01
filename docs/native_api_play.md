# 播放 / 评论 / MV / 权益类接口原生 API 直连报告（第 3 顺位）

- 任务：把直连层播放/评论/MV/权益接口按上游 KuGouMusicApi 真实域名逐个替换（能直连的直连，不能的记录 TLS 硬证据），匿名 + VIP 两态实测，与 kapi（https://kapi.344977.xyz）逐字段对比。
- 源码依据（逐行阅读）：`KuGouMusicApi/module/{song_url,privilege_lite,comment_music,comment_floor,comment_count,kmr_audio_mv,video_url,video_detail}.js` + `util/request.js`（默认 baseURL=`https://gateway.kugou.com`；仅 x-router 的模块需实测确认原生域名可达性）。
- 实测脚本：`tool/probe_native_play.py` + `tool/probe_native_play2.py`（含 key 签名与真实 hash/MV/tid），两态（anon / vip，`-b .test_creds/cj_vip.txt` 等价 cookie 注入）。
- 测试曲：晴天（hash=B3A52A7A958BF0AED0EBFBA2E9A818B7, album_id=966846, mixsongid=32100650）；MV：晴天 MV（hash=3B1F32C55F9774501794213C09168A18）。

## 一、总表（接口 → 域名 → 实测 → 结论）

| # | 接口 | 上游模块 | 原生域名 | url | method / encrypt | 实测（anon / vip） | 采纳 |
|---|---|---|---|---|---|---|---|
| 1 | /song/url | song_url.js | `trackercdn.kugou.com` | `/v5/url` | GET / android + key | 双态 200 status=1，`url`/`backupUrl` 数组（http://fsandroid…）；VIP 态多 `std_hash/hash_token_query/is_full_audio` | ✅ 原生 |
| 2 | /privilege/lite | privilege_lite.js | `media.store.kugou.com` | `/v2/get_res_privilege/lite` | POST / android | **TLS 硬失败**（三标签）→ gateway+x-router 双态 200 status=1 | ⛔ 保持 gateway |
| 3 | /comment/music | comment_music.js | （无 x-router）`gateway.kugou.com` | `/mcomment/v1/cmtlist` | POST / android | 双态 200 status=1（本就是 gateway 原生路径） | ✅ 现状即原生 |
| 4 | /comment/floor | comment_floor.js | 同上 / `m.comment.service`（playlist/album） | `/mcomment/v1/hot_replylist` 或 `/m.comment.service/v1/hot_replylist` | POST / android | song 分支实测**必须带 childrenid**（=special_child_id，只传 mixsongid 报 `err_code=10002 歌曲不存在`）；带 childrenid 后 200 status=1 | ✅ 现状即原生（补 childrenid） |
| 5 | /comment/count | comment_count.js | `sum.comment.service.kugou.com` | `/index.php?r=comments/getcommentsnum` | GET / **web** | **TLS 硬失败**（三标签）→ gateway+x-router 实测 200 | ⛔ 保持 gateway |
| 6 | /kmr/audio/mv | kmr_audio_mv.js | `openapi.kugou.com` | `/kmr/v1/audio/mv` | POST / android + `KG-TID:38` | 双态 200 status=1，`data[[{...}]]` | ✅ 原生 |
| 7 | /video/url | video_url.js | `trackermv.kugou.com` | `/v2/interface/index` | GET / android + key | 双态 200 status=1，`data[hash小写].downurl/backupdownurl`（http） | ✅ 原生 |
| 8 | /video/detail | video_detail.js | `kmr.service.kugou.com` | `/v1/video` | POST / android（clearDefaultParams，body 带 key） | **TLS 硬失败**（三标签）→ gateway+x-router 实测 200 status=1 | ⛔ 保持 gateway |

### key 签名（song_url / video_url 必填）

两接口缺 `key` 时分别报 `error_code=20028 类风控『illegal key』`（song_url，status=0）与 `errcode=40003 Empty key`（video_url）。key = MD5(hash + `57ae12eb6890223e355ccfcb74edf70d` + appid + mid + userid)（`KgSignature.keyOf`，直连层已有，实测有效）。

## 二、TLS 结论（openssl s_client 实测，硬证据）

`*.kugou.com` 通配证书（O=广州酷狗计算机科技有限公司）**只覆盖单标签子域**：

| 域名 | 标签数 | 证书 | 握手 |
|---|---|---|---|
| trackercdn.kugou.com | 2 | CN=*.kugou.com（SAN: *.kugou.com 等） | ✅ Verify return code: 0 |
| trackermv.kugou.com | 2 | 同上 | ✅ ok |
| openapi.kugou.com | 2 | 同上 | ✅ ok |
| media.store.kugou.com | 3 | 同上（SAN 不含三标签） | ❌ CERTIFICATE_VERIFY_FAILED: Hostname mismatch, certificate is not valid for 'media.store.kugou.com' |
| sum.comment.service.kugou.com | 3 | 同上 | ❌ 同上（'sum.comment.service.kugou.com'） |
| kmr.service.kugou.com | 3 | 同上 | ❌ 同上（'kmr.service.kugou.com'） |

与第 2 顺位发现的 `*.service.kugou.com` 三标签问题同源。**结论：privilege/lite、comment/count、video/detail 保持 gateway + x-router**（gateway 打这些接口上游本就只用 x-router，无独立可达 baseURL）；代码注释已记录证书证据。

## 三、与 kapi 逐字段对比（递归 key-diff，列表取 [0]）

| 接口 | diff 结论 |
|---|---|
| /song/url | 直接 key-diff 有差异，但均为**运行时/风控态差异**：kapi 本次返回 `errcode=20028 + ssaCode + status=2`（中转 IP 触发验证墙），直连（本机 IP + key 签名）返回真实 url。这是已知的 20028 风控差异，非结构差异；`_wrap` 已按 errcode 抛 ApiException → `_directOrFallback` 回退链兜底。结构层面（成功态）url/backupUrl 均为数组、`q/classmap/trans_param/fileHead` 等字段与既往 kapi 成功响应一致 |
| /video/url | **完全一致**（0 差异，含 `data[hash].downurl/backupdownurl/privileges`） |
| /kmr/audio/mv | **完全一致**（0 差异；⚠️ data 内项必须用 `album_audio_id`——传 `mixsongid` 直连/kapi 双侧均返回空 `{}`，直连层现行为 mixsongid 优先，本就落在本应的 album_audio_id 上） |
| /comment/music | 差异仅运行时字段：`like.count/likenum` ±1（实时点赞数）、`config.input_hint`/`canUploadImg`/`canUploadVoice`（A/B 文案开关）、`score` ±2（实时分）——Repository 无感知 |
| /comment/floor | **完全一致**（0 差异；对照姿势：kapi `/comment/floor?special_id=20505418&tid=…` ↔ 直连 childrenid+tid+mixsongid） |
| /comment/count | **完全一致**（0 差异，`{hash: num}`） |
| /privilege/lite | **完全一致**（0 差异；gateway x-router 路径与 kapi 同构） |
| /video/detail | gateway 路径实测 200 status=1 data 数组，与 kapi /video/detail 结构一致（既往已验证，本次复核） |

评论写操作（comment_music_send / floor_send / del）：**未真实发送**，仅核对参数结构（Repository 的 query 结构与 module 源码一一对应，未改动）。

## 四、代码落地（`lib/core/direct/kg_direct_api_client.dart` + `kg_media_direct.dart`）

全部走既有 `_directOrFallback` 包装（直连失败自动回退 kapi），`lastErrors` 记录不变：

1. `_songUrl`：gateway → **`https://trackercdn.kugou.com/v5/url`**（去 x-router）；注释记录 20028 兜底说明。
2. `_kmrAudioMv`：gateway → **`https://openapi.kugou.com/kmr/v1/audio/mv`**（保留 `KG-TID:38`）。
3. `_videoUrl`：gateway → **`https://trackermv.kugou.com/v2/interface/index`**；注释明确 downurl 为 http、代理转换在 Repository 层 `AppConfig.proxyMvUrl`（`mv_repository.dart:90` / `download_repository.dart`），URL 直连层原样返回不丢转换。
4. `_commentFloor`：song 分支参数补 `childrenid`（原代码只传了 `childrenid: q['special_id']`——核对后确认已正确，本次实测证明其必要性并加注释）。
5. `_commentMusic` / `_commentCount` / `_privilege`：**保持现状**（gateway 即原生路径 / 三标签 TLS 硬伤），附实测注释。
6. `kg_media_direct.dart videoDetail`：**保持 gateway + x-router**，注释记录 `kmr.service.kugou.com` 证书硬证据。

## 五、验证记录

- [x] 每接口匿名 + VIP 实测（probe_native_play.py / probe_native_play2.py 可复跑）
- [x] openssl 证书证据（6 域名全测，见二）
- [x] kapi 逐字段对比（见三，4 个接口 0 差异）
- [x] `bash check_braces.sh` 通过、坏 import 0、dart analyze 无新增告警（见下）
- [x] 未触碰登录类 / 内容类 case（git diff 可核）
