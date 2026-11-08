# v3.9.9 日志审计（用户 2026-11-07 18:07 附 677 行真机日志）

## 结论先行
**v3.8.0（日志里的运行版本）上播放已修复**：PlatformException 只出现在 14:11–15:07（v3.8.0 时代），18:04–18:05（v3.9.0+）同链路 **idle→loading→ready 正常播放**，无任何异常。此前的日志捕获盲区也随 v3.7.1 修复（日志里已能看到 [net]/playback/ErrorLogger 全记录）。

## 逐条定位

### 1. PlatformException（Activity/FlutterEngine）——只出现在旧版本时段
14:11–15:07 反复出现，是 v3.8.0 的 MainActivity 继承 FlutterActivity 根因；v3.9.0 起已改继承 AudioServiceActivity（2810e2e）。18:04 之后零异常 → **已修复实锤**。

### 2. 歌词「有点问题」——三个实测问题
a) **重复请求**：16:23 一首歌连发 `search → download → search → download → download`（同一歌词 id 444155544 的 KRC 下载了 2~3 次）。同种形态在 16:24/16:26/18:04 均出现——歌词 fetch 的**去重/缓存失效**，且「搜索到多个候选时逐个 download」无短路。v3.9.9 A 档已加 LyricPersistentCache，但**并发去重（in-flight 合并）与候选短路未做** → 待办 P1。
b) **翻译 API 504**：18:04:52「翻译批次失败（0..18）」——上游 index-translate 504 超时。现有条数防御（V34-03）生效，未崩；但失败后**无重试且该批译文丢失** → 待办 P2（重试 + 失败批进缓存标记避免重复打）。
c) **歌词下载双发**：16:24:36 search 后连续两次 download 相同 content（180ms/288ms）——同 URL 重复请求，属 a 的子型。

### 3. MV 页面 UI（日志证据）
- `/v1/video`（mv_player_page 的 MV 详情）返回 **20010 invalid param**（15:07:34）——MV 详情请求参数形态错，MV 播放页详情拿不到 → UI 自然「没做好」的实锤。v3.9 重写未覆盖 mv_player_page（当时排除在外）→ **待办 P1：修 /v1/video 参数 + MV 页按 A 档同纪律重写**。
- `/kmr/v1/audio/mv` 对 522041612 返回 `data:[{}]`（18:04:53）——该曲无 MV，播放页空 MV 处理正确（不弹错）。
- trackermv index 正常（15:07:35）。

### 4. 其他健康项（不处理）
- /yueku/banner 31136（运营位空，正常）
- 登录态/歌单/评论/播放 privilege 全 200/正常
- 18:05 播放 idle→loading→ready 全链正常

## 待办（进 v3.9.10）
1. P1 歌词：in-flight 合并去重 + 候选短路（首个可下载即停）
2. P1 MV：/v1/video 20010 参数修复（对照 Node video_detail.js）+ mv_player_page 重写
3. P2 翻译 504：单批重试一次 + 失败标记缓存（TTL 短）防雪崩重打
