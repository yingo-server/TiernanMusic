# 第4批·修复②：功能链路（歌词/搜索/歌单/评论/首页/MV 数据层）

## 角色
你是**修复代理**。按报告逐条改代码，不要重新审查全部代码、不要扩大范围。

## 绝对禁止
- 禁止下载 Flutter/Dart SDK、禁止装包、禁止 git clone、禁止构建、禁止跑测试、禁止起 Node/kapi
- 禁止 git commit / git push（由主代理统一提交）
- 禁止修改 `lib/core/direct/**`（网络层由另一个修复代理负责，改了会冲突）
- 禁止改动与本任务无关的文件

## 工作目录
`/var/minis/workspace/TiernanMusic`

## 规范
`docs/REVIEW_SPEC.md` 第 1 条：所有接口必须优先走酷狗原生网关，禁止以 kapi 网关作为实现。

## 输入报告（先完整读）
1. `docs/batch4_review_2_function_b.md`（歌词/搜索/歌单/评论/首页/MV，含 3 项 P0）
2. `docs/batch4_review_2_function.md`（播放链路 18 项）

## 目标文件（只改这些）
- `lib/features/playlist/data/playlist_repository.dart`（P0 集中地）
- `lib/features/lyric/data/krc_parser.dart`
- `lib/features/lyric/data/krc_decoder.dart`
- `lib/features/lyric/data/lyric_repository.dart`
- `lib/features/lyric/presentation/lyric_view.dart`
- `lib/features/search/data/search_repository.dart`
- `lib/features/comment/data/comment_repository.dart`
- `lib/features/home/data/home_repository.dart`
- `lib/features/home/data/models.dart`
- `lib/features/mv/data/mv_repository.dart`
- `lib/features/player/data/audio_handler.dart`
- `lib/features/player/data/models.dart`
- `lib/features/player/player_provider.dart`

## 必修 P0（4 项）
1. `playlist_repository.dart` 的 `collectPlaylist` / `deletePlaylist` / `addTracks` / `removeTracks` 全是 `GET` 且经 `_directOrFallback` 可回退 → **重复提交**。
   - 直连层已加 `write: true` 参数（写操作不回退）。你要做的：把 Repository 层改成调 `post`（写操作不该用 GET 语义），并确保异常向上抛而不是吞。
2. 同上：写操作失败后 UI 必须能区分「可能已成功」与「确定失败」，不要静默。
3. `playlist_repository.dart:126-129` `名称|hash|album_id|album_audio_id` 用 `|` 和 `,` 拼接 → 歌名含分隔符必然错位。改成传 Map 列表或对分隔符做校验/转义。
4. `player/data/audio_handler.dart` 的 P1 竞态（`_loading` 无条件下调、旧请求 `setAudioSource` 覆盖新源）→ 每次 setAudioSource 前再校验一次 token，或在 finally 中用 token 比较决定是否清 `_loading`。

## 其余优先修（P1，从报告里挑）
- 歌词 KRC 逐字时间基准、LRC 多时间戳同行、翻译内嵌三种结构
- 搜索 v3 字段差异、分页 hasMore 竞态、空关键词
- 评论 `err_code==0` 判定与裸 Map 分支
- 首页 `special_recommend` 回退表现
- 模型毫秒/秒单位一致性、`as Map` 强转、`albumAudioId` 来源
- `recentPlayRecorderProvider` 副作用 Provider 无 watch 时不生效

## 修复要求
- 每处改动前先 `file_read` 完整读该文件
- 每处改动加注释编号：`// F4-11（审查②-B，P0）：<一句话>`
- 只用 `file_edit` 工具改代码，不要用 sed/python
- 改动必须能编译；不确定的宁可少改也不要写坏

## 报告
改完写 `docs/batch4_fix_2_function.md`：逐条列「编号 / 文件:行 / 改了什么 / 依据」。未修的写明原因。

完成后 5 行内汇报：修了几条 P0/P1/P2，哪些没修及原因。
