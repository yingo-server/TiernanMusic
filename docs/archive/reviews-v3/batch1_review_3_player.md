# 批1·审查③ 播放与歌词链路（只读审查）

HEAD 33fbb68 · P0×4 / P1×15 / P2×13 · 完整报告见子代理回调（已核对行号与证据链）

## P0（主链路失效）
- PLY-01 KRC逐字时间基准错误：相对时间戳未加行首 line.startMs（krc_parser.dart:90-97），视图用绝对播放位置比较（lyric_view.dart:221-223）→ 除第一行外逐字全亮
- PLY-02 20028验证链断裂：player_repository.dart:193-195 重抛时丢 ssaCode；PlayUrlResult.ssaCode 全仓库无消费；audio_handler 20028 分支不 pause → 验证页永不弹出且旧歌继续响
- PLY-03 播放并发竞态：playQueue 无条件替换 _songs（207-215），_playToken 只在 _playAt 开始时自增（257），旧请求恢复后按旧 index 写新列表 → 队列污染/RangeError/错歌 blip
- PLY-04 kapi回退死代码：_resolveViaKapi 任一档失败即 throw（234-239），音质降级循环与 free_part 试听兜底不可达；_api 实为直连客户端先打直连

## P1（15项，摘要）
- PLY-05 翻译串行阻塞+切歌显示旧歌词（copyWithPrevious）+error无UI
- PLY-06 已下载歌曲仍先等 fetchDetail 网络超时（20-30s）才走本地
- PLY-07 码率单位混用：bps 按 kbps 阈值（2000/900/300）→ 128/320 标成"无损"
- PLY-08 fail_process 即 break 放弃更低音质可播地址
- PLY-09 翻译缓存部分命中即返回，失败批次永久不重试
- PLY-10 翻译缓存序列化不健壮（\t\n 不转义、int.parse 无保护）
- PLY-11 language 解码失败显示 Base64 原文；多语言扁平化错位
- PLY-12 LRC 多时间戳只解析第一个
- PLY-13 KRC 失败无 LRC 兜底（fetchLyric format 参数从未使用）
- PLY-14 候选盲取 first，不匹配时长
- PLY-15 引擎初始化失败永久缓存 _future，无重试
- PLY-16 setAudioSource/play 无超时，_loading 闩锁可永久卡死
- PLY-17 队列同 hash 在线版本覆盖下载版的 localPath（Song==只比 hash）
- PLY-18 actualQuality/isPreview 切歌串台（本地/失败分支不 emit）
- PLY-19 kapi 分支任意 hash_offset 都算试听，与直连判定不一致

## P2（13项）
- PLY-20 队列面板点歌重建整队列 · PLY-21 拖动进度被流覆盖+_fmt超1小时错
- PLY-22 64px 行高估算偏移+每tick重建 · PLY-23 中文歌也翻译+locale代码直传
- PLY-24 音质label/错误文案硬编码中文 · PLY-25 WiFi/流量音质开关零消费
- PLY-26 导出LRC [ti]缺冒号+双语重复 · PLY-27 点行seek未补偿offsetMs
- PLY-28 stop()不清队列/mediaItem · PLY-29 无hash歌曲把id当hash用+entries.first合并错歌
- PLY-30 换歌不首帧跳转+点空白切回封面 · PLY-31 parser不排序但二分查找
- PLY-32 异常toString直接弹用户 · PLY-33 静态观察组（_proxyHttp注释矛盾等10项）

判定依据逐条见子代理回调（PLY-01~33 证据表）。
