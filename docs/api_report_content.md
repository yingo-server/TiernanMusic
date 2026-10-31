# 首页 / 搜索 / 歌单接口核实与修复报告

## 范围与方法

- Base URL：`https://kapi.344977.xyz`
- 核实方式：`curl`，匿名 Cookie 与 VIP Cookie 两种状态；详情与歌曲接口使用真实响应中的 `rankid`、`global_collection_id` 和用户 `listid`。
- 本报告只记录接口结构和客户端解析，不保存账号凭证。
- 实测时所有已核实内容接口均返回业务成功。`/rank/song` 是例外：匿名和 VIP 都返回 HTML `Cannot GET /rank/song`，不是空歌曲 JSON。

## 接口实测摘要

| 接口 | 匿名 / VIP | 真实结构或结果 |
| --- | --- | --- |
| `/yueku` | 成功 / 成功 | `data.info.song` 为歌曲数组；推荐歌单在 `data.info.recommend`，歌单内容位于每项的 `extra`；全局 ID 为 `extra.global_specialid` |
| `/top/song` | 成功 / 成功 | `data` 直接是歌曲数组，不在 `data.info/list/songs`；时长 `timelength` 为毫秒；歌手为 `author_name` |
| `/top/playlist?category_id=0` | 成功 / 成功 | `data.special_list`；封面 `imgurl` / `flexible_cover`；全局 ID `global_collection_id` |
| `/rank/list` | 成功 / 成功 | `data.info`；榜单 ID `rankid`，封面可读 `banner_9`、`imgurl` 等 |
| `/rank/song?rankid=8888` | 失败 / 失败 | 返回 HTML `Cannot GET /rank/song`；没有可核实的歌曲 JSON 结构，不应显示为空榜单 |
| `/everyday/recommend` | 成功 / 成功 | 列表为 `data.song_list`；匿名本次返回 29 首，VIP 返回 30 首，因此不能仅凭匿名响应判定需登录 |
| `/search?keywords=周杰伦&type=song` | 成功 | `data.lists`，总数 `data.total`；单曲字段 `FileHash`、`OriSongName`、`SingerName`、`Duration`、`AlbumID` |
| `/search?keywords=周杰伦&type=special` | 成功 | `data.lists`；歌单封面字段是 `img`，全局 ID 是 `gid`，不是公共推荐接口的 `global_collection_id` |
| `/search?keywords=周杰伦&type=album` | 成功 | `data.lists`；专辑字段 `albumid`、`albumname`、`singer`、`img` 等 |
| `/search/hot` | 成功 / 成功 | `data.list[]`，每项包含 `name` 和 `keywords[]`；现解析结构匹配 |
| `/search/suggest?keywords=周杰伦` | 成功 / 成功 | `data` 是分组数组，关键词在 `data[].RecordDatas[].HintInfo`；原实现把分组对象当关键词，实际得不到建议 |
| `/playlist/detail?ids=<gid>` | VIP 成功 | `data` 为数组，首项使用 `name`、`pic`、`count`、`list_create_username`、`global_collection_id` |
| `/playlist/track/all?id=<gid>` | VIP 成功 | 公共歌单歌曲位于 `data.songs`，总数 `data.count` |
| `/playlist/track/all/new?listid=1` | VIP 成功 | 用户歌单歌曲位于 `data.info`，总数 `data.count`；`listid` 来自 `/user/playlist` 的 `data.info[].listid` |
| `/user/playlist` | VIP 成功 | 用户歌单位于 `data.info`，实测 14 项；首项 `listid=1`，同时含 `global_collection_id` |

## 歌曲字段差异

公共歌单和用户歌单歌曲均实测到：

- `hash`：播放 hash。
- `name`：通常为 `歌手 - 歌名`，需拆分且不能简单只取最后一段（歌名自身可能含分隔符）。
- `singerinfo[].name`：歌手列表，客户端合并为顿号分隔文本。
- `album_id`：专辑 ID。
- `mixsongid`：`album_audio_id` 的真实字段。
- `timelen`：毫秒，展示和播放器模型需要转换为秒。
- `fileid`：从用户歌单删除歌曲所需 ID。
- 封面位于 `trans_param.union_cover`（歌单歌曲也有直接 `cover` 字段）。

首页不同接口还存在以下差异：

- `/top/song`：`timelength` 毫秒、`album_sizable_cover`、`author_name`。
- `/everyday/recommend`：`time_length` 秒、`sizable_cover`、`album_audio_id`。
- 单曲搜索：`Duration` 秒、`Image`、`Audioid`。
- 乐库歌曲：`duration` 秒、`singername`，封面优先 `trans_param.union_cover`。

## 已修复

1. `lib/core/api/kugou_api_client.dart`
   - 将 `status=0`（包括 `error_code=0` 的失败响应）、`status=2`、非零 `error_code/errcode` 统一转成 `ApiException`。
   - `20028` 保留为可识别错误码，并给人机验证默认文案。
   - 防止仓库把鉴权、验证或失败响应当作空列表。
2. `lib/features/home/data/models.dart`
   - 歌曲封面支持并优先 `trans_param.union_cover`，补充新歌、每日推荐封面。
   - 补充 `author_name`、小写 `filename`、`album_id`。
   - 修正 hash 与 mixsongid 的用途；按接口处理秒/毫秒时长。
   - 搜索歌单支持 `img` 和 `gid`，乐库歌单支持 `global_specialid`。
3. `lib/features/home/data/home_repository.dart`
   - 修复排行榜解析引用未定义 `data` 变量的问题。
   - 新歌读取直接数组 `data`。
   - 每日推荐读取 `data.song_list`。
   - 乐库推荐读取 `data.info.recommend[].extra`。
4. `lib/features/search/data/search_repository.dart`
   - 展开 `data[].RecordDatas[]` 并读取 `HintInfo`，恢复搜索建议。
   - 歌单搜索继续返回统一 `HomePlaylist`，其 `img/gid` 已在模型中修正。
5. `lib/features/playlist/data/playlist_repository.dart`
   - 公共歌单歌曲读取 `data.songs`，用户歌单保留 `data.info`。
   - 修正 `singerinfo`、`timelen`、`mixsongid` 和歌名分隔解析。
   - 详情补充 `pic/count/list_create_username/global_collection_id`。
6. `lib/features/home/presentation/home_page.dart`
   - 所有模块无内容时显示“暂无推荐内容，请下拉重试”。
   - 首页错误状态区分登录/验证失败和普通加载失败。

## 错误处理约定

- HTTP 200 不代表业务成功；客户端现在检查业务 `status` 与 `error_code/errcode`。
- `status=0 + error_code`：失败；根据具体错误码由上层决定登录、验证或其他提示。
- `status=2 + errcode=20028`：需要人机验证，抛出 `ApiException(20028, ...)`。
- 业务成功且真实数组长度为 0 才表示无数据。
- `/rank/song` 当前为服务端路由不可用，HTTP/Dio 错误会进入错误 UI，而不是空列表。

## 后续注意

- 首页排行榜点击仍复用公共歌单详情路由；由于 `/rank/song` 当前不可用，本轮没有伪造榜单歌曲解析或修改路由。
- 本轮按要求未运行 Flutter。
