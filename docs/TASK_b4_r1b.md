# 第4批·审查①-B：端点域文件与播放地址（只读）

先完整读 `/var/minis/workspace/TiernanMusic/docs/REVIEW_SPEC.md`，其「绝对禁止」「工作方式」「本项目既定口径」全部适用，违反任一条即任务失败。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 commit `6e46611`
Node 源码参考：`/var/minis/workspace/KuGouMusicApi/module/*.js`（只读，可对照关键端点）

## 报告文件
**`docs/batch4_review_1_network_b.md`**（每读完一个文件立刻 append；禁止读完全部再统一写）

## 范围（逐个 file_read 完整读，禁止 grep）
1. `lib/core/direct/kg_endpoints_search.dart`
2. `lib/core/direct/kg_endpoints_playlist.dart`
3. `lib/core/direct/kg_endpoints_comment.dart`
4. `lib/core/direct/kg_endpoints_media.dart`
5. `lib/core/direct/kg_endpoints_artist_album.dart`
6. `lib/core/direct/kg_endpoints_home.dart`
7. `lib/core/direct/kg_endpoints_auth.dart`
8. `lib/core/direct/kg_play_api.dart`

## 核对重点
A. **原生域名合规（本项目硬性口径）**：每个 case 的 baseUrl 必须是酷狗原生域名，禁止以 kapi 网关作为实现。
   - 对照表：`complexsearch.kugou.com`（搜索 v3）、`pubsongs.kugou.com`（歌单详情）、`trackercdn.kugou.com`（`/v5/url`）、`openapi.kugou.com`（`/kmr/v3/author`、`/kmr/v1/audio_group/author` 必须 v1 返回 List、`/v2/rank/audio` 带 `kg-tid:369`）、`login-user.kugou.com`、`userservice.kugou.com`（`/risk/v3/r_register_dev`）、`lyrics.kugou.com`（`/v1/search` 必须带 signature、`/download` 需 `ver:1&charset=utf8`）、`gateway.kugou.com`（评论走 `x-router: m.comment.service.kugou.com`）、`ocean.kugou.com`、`musicadservice.kugou.com`
   - 只走 kapi 或直连恒失败 → 记为问题并指明位置与原因。已知例外 `top/playlist`（`/v2/special_recommend` 恒 200101）需指出「依赖 kapi」这一事实。
B. 与 Node 源码逐字段对照：baseUrl / method / params / headers（尤其 `x-router`、`kg-tid`、`dfid`、`mid`、`appid`、`clientver`）
C. 成功判定：`status==1` / `status==200`（歌词、搜索）/ `err_code==0`（mcomment）/ 裸 Map（comment、comment/count），逐端点核对
D. 播放地址：音质降级顺序、`IsFreePart` 试听判定、`hash_offset`/`clip_hash` 处理、URL 过期与重试
E. 响应解析：`as Map` 强转、null 断言、`data` 与 `data.data` 双层结构、List vs Map 差异（如 `audio_group/author` v1/v2）
F. 分页参数与 hasMore 计算、空列表返回
G. 登录/注册：加密字段、设备信息（dfid/mid/uuid）一致性、错误码映射

## 落盘格式
```
### <文件>:<行号> 简述
- 级别：P0/P1/P2
- 依据：<代码片段或 Node 对照结论>
- 影响：<用户可见后果>
```
末尾追加「问题清单」按 P0/P1/P2 排序。不改代码、不跑构建。完成后 3 行内汇报问题数。
