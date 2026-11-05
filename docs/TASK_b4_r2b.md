# 第4批·审查②-续：歌词/搜索/歌单/评论/首页/MV（只读）

先完整读 `/var/minis/workspace/TiernanMusic/docs/REVIEW_SPEC.md`，其「绝对禁止」「工作方式」「本项目既定口径」全部适用，违反任一条即任务失败。

## 背景
上一轮代理已审完**播放链路**（audio_handler / player_repository / models / player_provider / play_helper），成果在 `docs/batch4_review_2_function.md`。**不要重写那个文件，也不要重审播放链路。** 本轮只审下列剩余文件，写入新文件。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `6e46611`

## 报告文件
**`docs/batch4_review_2_function_b.md`**（每读完一个文件立刻 append；禁止读完全部再统一写）

## 范围（逐个 file_read 完整读，禁止 grep）
1. `lib/features/lyric/data/krc_parser.dart`
2. `lib/features/lyric/data/krc_decoder.dart`
3. `lib/features/lyric/data/lyric_repository.dart`
4. `lib/features/lyric/presentation/lyric_view.dart`
5. `lib/features/search/data/search_repository.dart`
6. `lib/features/playlist/data/playlist_repository.dart`
7. `lib/features/comment/data/comment_repository.dart`
8. `lib/features/home/data/home_repository.dart`
9. `lib/features/home/data/models.dart`
10. `lib/features/mv/data/mv_repository.dart`

## 核对重点
**最高优先级口径：所有接口必须优先使用酷狗原生网关，禁止以 kapi 中转（kapi.344977.xyz）作为实现。** 发现「只能靠 kapi」或「参数写错导致直连假失败」的路径要单独指出。

A. 歌词：KRC 逐字时间基准（相对行首还是绝对）、LRC 多时间戳同行、翻译/音译内嵌结构（`languageList[].lyricContent` / 顶层 List / Map 三种）、二分查找与排序、空歌词态
B. 歌词接口：`lyrics.kugou.com/v1/search` **必须带 signature**（Node 源码 `notSign:true` 是 bug）；`/download` 需 `ver:1&charset=utf8`
C. 搜索：v3 `/v3/search/song` 字段差异、分页 page/hasMore/total 状态机、刷新与加载更多竞态、空关键词
D. 歌单：详情分页、收藏/取消收藏写操作（AES body + RSA），是否有重复提交风险
E. 评论：`err_code==0` 判定、裸 Map（comment / comment/count）、楼层分页、点赞/回复
F. 首页：`/v2/special_recommend` 恒 200101 时的回退表现、榜单、新歌
G. 模型：毫秒/秒单位、字段名与真实响应一致性、`as Map` 强转、null 断言、`albumAudioId` 来源
H. 缓存：MemoryCache key 是否含用户维度、TTL、是否返回共享可变对象

## 落盘格式
```
### <文件>:<行号> 简述
- 级别：P0/P1/P2
- 依据：<代码片段>
- 影响：<用户可见后果>
```
末尾追加「问题清单」按 P0/P1/P2 排序。不改代码、不跑构建。完成后 3 行内汇报问题数。
