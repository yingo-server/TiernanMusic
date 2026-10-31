# 评论 / MV / 歌词接口核验与修复报告

核验时间：2026-10-31  
Base：`https://kapi.344977.xyz`  
凭证：非 VIP Cookie；测试歌曲 `mixsongid=32100650`，`hash=B3A52A7A958BF0AED0EBFBA2E9A818B7`。

## 1. 接口实测

### 评论

- `GET /comment/music?mixsongid=32100650&page=1&pagesize=5`
  - 成功，`count=710225`，返回 5 条顶层评论。
  - 顶层字段为 `list`，不是 `data.list`。
  - `like` 是对象：`{count, likenum, haslike, ...}`；旧模型按数字解析，导致点赞恒为 0。
  - 回复字段为 `reply_num`，`special_child_id` 示例为 `20505418`。
- `GET /comment/count?hash=B3A52A7A958BF0AED0EBFBA2E9A818B7`
  - 成功，直接返回 `{hash: 710225}`，没有统一 `status/data` 包装。
- `GET /comment/floor?special_id=20505418&mixsongid=32100650&tid=1723639894&page=1&pagesize=5`
  - 成功，返回 5 条；总数字段为 `comments_num=139`，不是 `count/total`。

### MV

- `GET /kmr/audio/mv?album_audio_id=32100650&fields=mkv,tags,h264,h265,authors`
  - 成功，`data` 为嵌套数组 `List<List<Mv>>`。
  - 标题字段为 `mv_name`；艺人在 `authors`，用户视频也可能只有 `singer/user_name`。
  - 第一条 `video_id=117613`，官方版；`h264.hd_hash=C95D0A0BEF765BB6413758E290F873D4`。
- `GET /video/url?hash=C95D0A0BEF765BB6413758E290F873D4`
  - 成功；`data` 的 key 是小写 hash。
  - `downurl` 与 `backupdownurl` 均返回 **HTTP** 地址，需要经过 `AppConfig.proxyMvUrl` 转成 HTTPS 代理。

### 歌词

- `GET /search/lyric?hash=...&duration=269`
  - 成功，一个候选：`id=274944371`，`accesskey=2A7B35884B3C20E9D3281686BA59A3F8`，`duration=269792` 毫秒。
- `GET /lyric?id=...&accesskey=...&fmt=krc&decode=true`
  - 成功，返回 `decodeContent`；同时保留加密的 `content`。
  - 实测客户端固定 key XOR + zlib 解码结果与 `decodeContent` 完全一致（8405 字符）。
- `GET /lyric?id=...&accesskey=...&fmt=lrc`
  - 成功；`contenttype=1`，`content` 是 **Base64 编码的明文 LRC**，不能走 KRC 解密器。

## 2. KRC parser 验证

真实 `decodeContent` 暂存于 `/tmp/qingtian.krc`，LRC 明文暂存于 `/tmp/qingtian.lrc`；模拟 Dart 正则的脚本为 `/tmp/verify_krc.py`。

真实样本统计：

| 指标 | KRC | LRC |
| --- | ---: | ---: |
| 原始物理行 | 68 | 68 |
| 有效歌词行 | 63 | 63 |
| 逐字标签 | 602 | 0 |
| 拼接正文字符 | 651 | 651 |
| 内嵌翻译块 | 0 | 0 |

修复及边界测试：

- `language` 不再空处理：支持 Base64(JSON) 翻译数组，并按行绑定；损坏块不影响原文。
- 支持方括号、特殊字符及完全没有 `<...>` 标签的正文；保留无标签尾部，不再静默丢字。
- 保留空行跳过、CRLF、元数据、`offset`；LRC 时间戳也复用同一模型。
- 逐字时间标签第三项兼容非 0 值。
- 测试夹具验证 `[A]B[C]`、无标签正文、翻译两行映射均通过。

## 3. 修改摘要

- `comment_repository.dart`
  - 修复 `like.count` 点赞解析。
  - 楼中楼兼容 `comments_num` 总数。
  - 新增按 hash 查询 `/comment/count`。
- `mv_repository.dart`
  - 修复 `mv_name`、多艺人及用户视频艺人回退。
  - 空数据安全解析，空 hash 不再被选作最佳播放 hash。
  - 保持 HTTP 播放地址代理处理。
- `krc_parser.dart`
  - 完成内嵌翻译、LRC、特殊字符/无标签正文解析。
- `krc_decoder.dart`
  - Base64 规范化，校验 `krc1` 文件头及空内容。
- `lyric_repository.dart`
  - 支持 `fmt=lrc` 及其 Base64 明文解码。
  - 翻译缓存按索引空值保护，避免稀疏缓存被覆盖为 null。

仅进行了 curl 与 Python 数据/正则验证，未运行 Flutter。
