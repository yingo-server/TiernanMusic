# 批1·审查③ 播放与歌词链路（只读审查报告）

- 仓库：`/var/minis/workspace/TiernanMusic` HEAD `33fbb68`
- 方式：静态阅读 + `rg` 调用点交叉核对 + 对照 `test/lyric_test.dart` 的真实 KRC 样本与 `docs/api_verified.md`；**未构建、未跑测试、未联网**。
- 范围（共 17 个文件 / 3053 行）：`features/player/**`（player_provider、audio_handler、player_repository、models、play_helper、full_player_page、mini_player、queue_sheet）、`features/lyric/**`（krc_decoder、krc_parser、lyric_repository、lyric_view）、`core/audio/**`、`core/cache/cache_manager.dart`、`features/download/data/download_repository.dart` 的歌词导出段、`features/auth/presentation/verification_listener.dart`（20028 回链）。
- 结论：**未发现确定性的编译阻塞**（未运行 `flutter analyze`，仅静态判读）；功能/数据级问题 **P0 4 项、P1 15 项、P2 13 项**，另附 1 组不单独定级的静态观察。
- 按要求：以下**只写问题、位置、依据与影响，不含任何修复建议**。未覆盖 MV 播放页与下载音频本体（仅涉及歌词导出）。

---

## P0（播放/歌词主链路直接失效）

### PLY-01 ⛔ KRC 逐字时间基准错误：相对时间戳被当成绝对播放时间

- 位置：
  - `lib/features/lyric/data/krc_parser.dart:90-97`（`KrcWord.startMs` 直接取 `<start,dur,0>` 的 start，未加行首 `line.startMs`）
  - `lib/features/lyric/presentation/lyric_view.dart:66`（`_posMs = position + offsetMs`，只加全曲 offset）
  - `lib/features/lyric/presentation/lyric_view.dart:221-223`（用绝对 `posMs` 与 `w.startMs` 比较）
- 问题：KRC 的逐字时间是**相对本行开始**的偏移，解析器原样保存，视图却拿整首歌的播放位置去比较。只有 `startMs == 0` 的第一行能正确逐字；其它行一进入该行所有字立即被判为 `isPast`，整行瞬间全亮（或整行未唱时全暗）。
- 依据：`test/lyric_test.dart:31-36` 的真实 KRC 样本第二行是 `[2048,1281]<0,256,0>词<256,256,0>：…`，words 从 0 开始；而 line 从 2048ms 开始。`krc_parser.dart:92-94` 未做 `+ lineStart`。此前 `docs/review_b4_a.md:132` 的“逐字高亮实现正确”只核对了 `Text.rich + TextSpan` 的形态，没有核对时间基准。
- 影响：逐字歌词对除第一行外的所有行失效；非当前行的“已唱/未唱”颜色也按绝对时间误判，长歌词几乎整篇处于全亮。

### PLY-02 ⛔ 20028 人机验证链断裂：ssaCode 在播放链路丢失，验证页永不弹出且无提示

- 位置：
  - `lib/features/player/data/player_repository.dart:193-195`（直连失败后重新 `throw ApiException(lastErrorCode, lastMessage)`，未带 `ssaCode`）
  - `lib/features/player/data/audio_handler.dart:318-330`（`api.needsVerification` 分支只把异常丢给 `_verificationController`，不写 `_errorController`，也不 pause）
  - `lib/features/auth/presentation/verification_listener.dart:28-33`（`ssaCode` 为空直接 `return`）
  - `lib/core/direct/kg_play_api.dart:262-269`（`PlayUrlResult.ssaCode` 已从响应解析，但全仓库无任何读取点）
- 依据：`rg` 全仓库只有 `PlayUrlResult` 定义 `ssaCode`，没有 `result.ssaCode` 的消费；`ApiException.needsVerification` 只判断 `errorCode == 20028`，而 `verification_listener` 还要求 `ssaCode` 非空。
- 影响：命中风控 20028 时——不弹 `CaptchaPage`、不重试、不 Toast（`main.dart` 只监听 `playerErrorProvider`），界面停在“需要人机验证”的 error 状态；上一首歌若还在响，`_playAt` 的 20028 分支连 `pause()` 都没有（通用失败分支在 340-342 才 pause），会出现“通知/歌名已切到新歌、声音还是旧歌”。`_pendingSongIndex` 会一直保留到下一次播放请求。

### PLY-03 ⛔ 播放请求并发竞态：loading 期间换队列，旧请求会写坏新队列并可能越界

- 位置：`lib/features/player/data/audio_handler.dart:207-215`（`playQueue` 无条件 `_songs.clear()..addAll()`）、`238-267`（`_playAt` 在 await 前捕获 index/song，之后 `_songs[index] = detailed`）、`294/305/317`（后续还有 `_songs[index]` 写入与 `_playOn` 记录）
- 问题：`_playToken` 只在新请求**真正开始** `_playAt` 时自增（257 行）。当前请求还在 `_loading` 时，新请求只会写入 `_pendingIndex` 并返回（249-252），不会作废旧 token。若新请求来自 `playQueue`（队列面板、播放全部、专辑/歌手页），`_songs` 已被整体替换，旧请求恢复后仍按旧 index 写入新列表：
  - 下标小于新列表长度 → 把旧歌详情覆盖到**新队列的另一首歌**上；
  - 下标越界 → `RangeError` 被 318 行 catch 吞成“播放失败”，随后 `skipToNext` 在错误的 `_index` 上跳歌；
  - 旧请求仍会 `play()`（313-315），出现“点了 B，先响一下 A”的错歌 blip。
- 依据：`_songs[index]` 的所有写入点都在网络 await 之后；`playQueue` 替换列表时既不递增 token，也不取消在途请求。
- 影响：弱网/慢解析时，从任意页面开始新队列可导致队列内容被污染、当前歌被顶掉、播放失败跳歌；错误信息会把 `RangeError` 文本弹给用户。

### PLY-04 ⛔ 所谓“kapi 回退路径”在第一个音质失败就抛错，降级与 60 秒试听兜底是死代码

- 位置：`lib/features/player/data/player_repository.dart:213-239`（循环内 `throw ApiException`）、`240-252`、`253-277`（试听兜底循环）
- 问题：`_resolveViaKapi` 在任意一档 `errorCode != 0 || status != 1` 时立即抛错（234-239），`for` 不会继续到下一档；后面 253-277 的 `free_part=1` 兜底循环只有在前面的循环**正常跑完且没有抛错**时才可能执行——只要服务端对任一档返回非 0 错误码或 status≠1，该兜底即不可达（只有全部档位“无 URL 且 errcode=0”时才可能进入）。且 `_api` 是 `KgDirectApiClient`，`_api.get('/song/url')` 会先路由到 `kg_direct_api_client.dart:166-167 → kg_endpoints_media.dart:71-90` 的直连实现，只有直连失败才落到 `super.get`（kapi）。所以注释所说“这里是 kapi 回退路径”实际是“再打一遍直连，失败才 kapi”。
- 依据：控制流直接可见；`kg_direct_api_client.dart:118-134` 的 `_directOrFallback` 先 direct 后 kapi。
- 影响：默认音质 flac/high/super 而该档无权益时，320/128 的可播地址不会尝试；VIP 曲的免费试听兜底永远不执行；一次播放对同一首歌可能发出 5 次（`_resolveViaDirect` 逐档）+ 1 次（本函数 direct）+ 1 次（kapi fallback）请求。

---

## P1（高概率功能/数据错误）

### PLY-05 歌词翻译串行阻塞显示；切歌后仍显示上一首歌词；loading/error 无 UI

- 位置：`lib/features/player/presentation/full_player_page.dart:20-40`（先 search → download → `ensureTranslation` 全部 await 后才返回）、`372-388`（只判 `lyricAsync.value?.lyric != null`）
- 依据：
  - `ensureTranslation` 每 40 行一批**串行**请求（`lyric_repository.dart:111-127`），`TranslateApi` 超时 `connect 20s / receive 60s`（`translate_api.dart:8-13`）。
  - Riverpod 2 的 `AsyncValue` 在依赖变化重建时保留 previous value（`copyWithPrevious`），`currentLyricProvider` watch 了 `currentSongProvider`；新歌加载期间 `.value?.lyric` 仍是上一首的歌词。
  - provider 返回的 `error` 字段（“暂无歌词”/“歌词解析失败”）在 `_CoverOrLyric` 中没有任何读取点。
- 影响：切歌后歌词区显示**旧歌歌词**，数秒到数分钟（长歌词/翻译服务慢）后才换；无歌词、解析失败、翻译中都没有任何提示，用户只看到封面，只能反复点歌词按钮。

### PLY-06 已下载歌曲仍先等网络 `fetchDetail`，离线点歌要等 20–30 秒才响

- 位置：`lib/features/player/data/audio_handler.dart:264-286`
- 问题：`_playAt` 无条件先 `await _repository.fetchDetail(song)`（`/privilege/lite` 网络请求），之后（274 行起）才判断 `localPath` 走本地文件。`fetchDetail` 内部 catch 掉异常，但 Dio 的 `connectTimeout 20s / receiveTimeout 30s` 仍然要等完。
- 依据：`player_repository.dart:46-118` 的 fetchDetail 只 try/catch，不设短超时；本地分支在 274 行之后。
- 影响：飞行模式/弱网下播放已下载歌曲，本地文件要等 20–30 秒；播放失败自动跳下一首时每首都要先等一次网络超时，离线连续播放基本不可用。

### PLY-07 音质码率单位混用：bps 数据按 kbps 阈值推断，128/320 会被标成“无损”

- 位置：`lib/features/player/data/player_repository.dart:199-208`（阈值 2000/900/300）对照同文件 `296-308`（`_actualQuality` 用 192000/500000 判 bps）
- 依据：`lib/core/direct/kg_play_api.dart:250-258` 原样读取 `bitRate`（服务端为 320000/128000 这类 bps 值）；`_qualityFromBitrate` 的 2000/900/300 明显是 kbps 阈值。当 `extName` 不是 `128/320/flac/high/super` 的标准值（例如 `mp3`、`m4a`、空串）时 `AudioQuality.fromString` 落到 `q128`，随后 `bitrate >= 2000` 恒真 → 返回 `flac`。
- 影响：实际 128k/320k 的曲目在播放页显示“无损”，`_songs[index].quality` 同样被写成错误值，与下载/设置页显示不一致；`high`/`super` 档位判断也因此不可信。

### PLY-08 `fail_process` 即 break：放弃同一首歌更低音质的可播地址

- 位置：`lib/features/player/data/player_repository.dart:175-190`
- 问题：当前档位只要 `fail_process` 非空，就先请求该档位的 `freePart`，失败后直接 `break`，不再向更低档尝试。`fail_process` 只表示该 quality 被拒（常见：flac 需会员、320 免费可播），不是整首歌不可播。试听兜底也只针对当前档位请求一次。
- 依据：`kg_play_api.dart:228-233` 将 `fail_process` 定义为“服务端明确拒绝（需购买/无版权等），降级无意义”，但实际场景中拒绝是按 quality 粒度返回的。
- 影响：默认音质为 flac 的用户，本来可播的 320/128 直接变成“需要会员/播放失败”，并触发自动跳歌。

### PLY-09 翻译缓存“部分命中即返回”，失败批次永久不再重试

- 位置：`lib/features/lyric/data/lyric_repository.dart:89-104`（`cached != null` 就应用并 `return`）、`129-140`（只写成功批次）
- 问题：写入端只把成功批次放进缓存；读取端只要缓存 map 非空就不再检查缺行、也不再请求翻译。第一次部分批次失败后，该歌词永久只有部分行有译文，直到用户手动清“歌词翻译缓存”。
- 依据：`cached != null` 分支没有“缓存行数 < 歌词行数”的判断；注释 108 行“失败批次不入缓存，下次还能重试”在读取端不成立。
- 影响：长歌词（>40 行）一次网络抖动即造成整首永久缺译；且 `hasEmbedded` 只看 `translation != null`，后续也不会重新触发。

### PLY-10 翻译缓存的序列化/反序列化不健壮，可让整条歌词链抛异常

- 位置：`lib/core/cache/cache_manager.dart:83-103`
- 问题：
  - `set` 用 `\t` 与 `\n` 分隔且不转义；LLM 译文含换行/制表符时记录被拆坏。
  - `get` 中 `int.parse(line.substring(0, idx))` 没有 try/catch；任意一条损坏记录都会抛 `FormatException`。
- 依据：`ensureTranslation`（lyric_repository.dart:94-95）未捕获该异常，`currentLyricProvider` 会进入 error 分支，而 UI 又不显示 error（见 PLY-05）。
- 影响：一旦缓存被写坏，该歌词（或该语言）持续无法显示，且现象是“突然没有歌词”，难以定位。

### PLY-11 KRC `language` 解码失败时把原始 Base64 当译文显示；多语言直接扁平化导致错位

- 位置：`lib/features/lyric/data/krc_parser.dart:203-206`（catch 后 `return value.split(...)`）与 `140-146`（按行号赋值 translation）
- 问题：注释写“解不开时降级为按行分割的纯文本”，实际返回的是未解码的 `value`（Base64 原文）。`test/lyric_test.dart:105-111` 只断言了原文不丢，没有断言 `translation`，所以测试全绿但 UI 会在每行下方显示一长串 Base64。另外 `languageList` 里若含多个语言，`_decodeLanguage` 把各语言的 `lyricContent` 依次 `out.add` 到同一数组，再按行号赋给原文 → 第 2 种语言会覆盖/串到后面的行。
- 依据：`krc_parser.dart:158-201` 的扁平化逻辑；`140-145` 的 `lines[i].translation = embeddedTranslations[i]`。
- 影响：损坏/非 JSON 的 language 块直接显示 Base64 噪声；多语言 KRC 译文错行。

### PLY-12 LRC 多时间戳行只解析第一个，第二个时间戳进入歌词正文

- 位置：`lib/features/lyric/data/krc_parser.dart:54`（`^\[(\d+):(\d+(?:\.\d+)?)\](.*)$`）、`110-124`
- 问题：LRC 常见“一句多个时间标签”`[00:12.00][00:15.00]歌词`；正则只吃掉第一个，`group(3)` 仍是 `[00:15.00]歌词`，被原样写入 `KrcLine.text`，且只生成 12s 一行。
- 依据：正则与 LRC 规范（一行可挂多个时间戳）不一致；`_lrcLineRe` 没有循环匹配。
- 影响：歌词正文里出现 `[00:15.00]`；重复句在 15s 处不会高亮。

### PLY-13 KRC 失败时没有 LRC 兜底（有实现但全仓库从不调用）

- 位置：`lib/features/lyric/data/lyric_repository.dart:44-80`；调用点 `full_player_page.dart:31`、`download_repository.dart:160`
- 问题：`fetchLyric` 支持 `format = 'lrc'`，也能正确 Base64 解 LRC；但两个调用点都用默认 `'krc'`。KRC 请求失败、`content` 为空、`KrcDecoder` 返回空串、`decodeContent` 缺失时直接 `return null`，上层记为“歌词解析失败”，不会用同一个 `candidate` 再取 LRC。
- 依据：`rg "fetchLyric"` 全仓库仅两处调用，均未传 `format`；`krc_decoder.dart` 对任何非 `krc1`/zlib 失败都返回 `''`。
- 影响：KRC 缺失/格式变更/解密失败时整首歌词不可用，即使 lyrics.kugou.com 同一 `id+accesskey` 通常还能给 LRC。

### PLY-14 歌词候选盲取 `candidates.first`，不做时长/版本匹配

- 位置：`lib/features/lyric/data/lyric_repository.dart:33-40`
- 问题：搜索请求带了 `duration`，但结果直接取第一条，不比较候选 `duration` 与歌曲时长、不比较 hash/歌名；`LyricCandidate.duration` 字段定义了却无任何消费点。
- 依据：`rg "candidate.duration"` 无结果；`findCandidate` 只读 `id/accesskey`。
- 影响：同名的现场版/伴奏/remix/翻唱候选排在前时，拿到错误歌词，整首时间轴对不上（且 UI 无“歌词版本错误”反馈）。

### PLY-15 音频引擎初始化失败被永久缓存，进程内无法恢复

- 位置：`lib/core/audio/audio_service_bootstrap.dart:40-42`（`_future ??= _init()`）、`53-58`（失败只置 `_ready=false`）
- 问题：`_init()` 失败后 `_future` 保存的是已完成的 `false` Future；后续每次 `ensureReady()` 都 await 同一个失败结果，不会重试；`_error` 也没有清除路径。
- 依据：`ensureEngineReady`（audio_handler.dart:40-49）只依赖 `ensureReady()` 的返回值；失败提示写“请稍后重试”，但重试路径不存在。
- 影响：启动期一次 `JustAudioBackground.init` 失败（系统服务慢、后台被杀）后，本次进程内所有播放都失败，只能杀进程重启。

### PLY-16 `setAudioSource`/`play` 无超时与取消，`_loading` 闩锁可永久卡死；排队期间旧请求仍会出声

- 位置：`lib/features/player/data/audio_handler.dart:249-259`、`281-315`
- 问题：`_loading = true` 之后 `resolveUrl`→`setAudioSource`→`play` 全链没有超时；`just_audio` 的 HTTP 连接不受 Dio 超时约束，CDN 卡住时 `await _player.setAudioSource` 可以长期不返回，`finally` 永不执行。期间所有新播放请求只写 `_pendingIndex`（249-252），用户无法切歌，也没有 loading 指示。另：`_playToken` 只在真正开始播放时自增（257），排队等待期间旧请求不会作废，仍会执行 `play()`（315），出现“点 B 先响 A”。
- 依据：`setAudioSource` 前后没有任何 `.timeout(...)`；`_pendingIndex` 是单值，连续点击只保留最后一次。
- 影响：弱网/死链时播放器假死，只能重启；正常网络下快速切歌有错歌 blip。

### PLY-17 队列里已有同 hash 的在线版本时，播放已下载歌曲会忽略 `localPath`

- 位置：`lib/features/player/data/audio_handler.dart:219-227`；`lib/features/player/data/models.dart:217-222`（`Song ==` 只比 hash）
- 问题：`playSong` 用 `_songs.indexOf(song)` 判重，命中就 `_playAt(existing)`；下载页构造的 `Song` 带 `localPath`，但队列里的同 hash 项通常是不带 `localPath` 的在线版本，结果仍走网络解析。
- 依据：`Song.operator ==` 仅 `hash` 相等；`_playAt` 的本地分支读的是队列项 `song.localPath`（274 行）。
- 影响：从下载页/最近播放点已下载歌曲，离线时仍会失败并自动跳歌；用户视角是“下载了却不能离线播”。

### PLY-18 音质/试听状态串台：切歌后沿用上一首的 `actualQuality` / `isPreview`

- 位置：`lib/features/player/data/audio_handler.dart:274-285`（本地文件分支不写 `_actualQualityController`）、`300-305`；`lib/features/player/player_provider.dart:75-82`
- 问题：`_actualQualityController` 只在网络解析成功时 emit；本地播放、解析失败、20028 都不 emit。`_isPreview` 是普通成员变量，只有本地分支显式置 `false`。两个 provider 都是 `StreamProvider`，会保留上一次的值。
- 依据：本地分支 278-286 没有 `_actualQualityController.add(...)`；`_actualQualityController` 没有任何清零/重置点。
- 影响：切到本地歌曲后仍显示上一首的“无损/Hi-Res”标签；解析失败的新歌会沿用上一首的“仅试听”角标。

### PLY-19 kapi 分支把任意 `hash_offset` 都当 60 秒试听，判定标准与直连分支不一致

- 位置：`lib/features/player/data/player_repository.dart:247-248`；对照 `lib/core/direct/kg_play_api.dart:262-267`
- 问题：kapi 分支 `isPreview = priv_status == 0 || data['hash_offset'] is Map`；直连分支要求 `hash_offset.end_ms` 在 `(0, 65000]` 或 URL 含 `/p_0_`。`hash_offset` 也用于“从副歌开始”等整曲信息，只要服务端返回 Map 就会被标成试听。
- 依据：两处判定条件直接对比；`PlayUrlResult.fromResponse` 的注释明确说 `end_ms` 才是依据。
- 影响：完整歌曲可能被标“仅试听”，并影响用户对权益状态的判断；两条解析路径行为不一致。

---

## P2（体验/一致性/可维护性）

### PLY-20 队列面板点歌会清空并重建整个队列

- 位置：`lib/features/player/presentation/queue_sheet.dart:100-108`
- 问题：`controller.playQueue(queue, i)` 把同一个队列 `clear + addAll` 后重新从 i 开始，触发重新 `fetchDetail` + 重新解析 URL + 歌词 provider 重建；若此时正在 `_loading`，还会触发 PLY-03 的竞态。
- 依据：`playQueue`（audio_handler.dart:207-215）的实现；队列项本来就来自 `handler.songs`。
- 影响：切歌多一次缓冲/网络请求；弱网下表现为“点了队列没反应/停顿”。

### PLY-21 进度条拖动时每一帧都 seek，拖动位置被播放位置流反复覆盖；`_fmt` 超 1 小时显示错误

- 位置：`lib/features/player/presentation/full_player_page.dart:490-495`、`42-45`
- 问题：`Slider.onChanged` 直接 `controller.seekTo(...)`，没有 `onChangeStart` 的本地拖拽值；`positionProvider` 的 tick 会在拖动过程中把 value 拉回旧位置，导致 thumb 抖动/回跳。`_fmt` 用 `inMinutes.remainder(60)`，75 分钟显示为 `15:00`。
- 依据：Slider 使用流式 `posMs` 作为 value；`_fmt` 无小时位。
- 影响：拖动进度条手感差；长有声书/现场曲时长显示错误。

### PLY-22 歌词滚动按固定 64px 行高估算，双语/换行时累计偏移；且 `LyricView` 每个 position tick 都被整体重建

- 位置：`lib/features/lyric/presentation/lyric_view.dart:68-79`（`index * 64`）、`109-119`；`lib/features/player/presentation/full_player_page.dart:359`（父级 watch `positionProvider`）
- 问题：行高随译文、字号、换行变化，64px 只是近似，越往后偏移越大；`padding.vertical = 120` 也未计入，当前行不会居中。父级每秒多次 watch position，`LyricView.build` 与可见 `_LyricLineTile` 每 tick 重跑，注释宣称的“只让当前行随位置变化”实际做不到。
- 依据：`_itemExtentApprox` 常量与 `ListView.builder`；`build` 中 `posMs` 直接传给每一行。
- 影响：长歌词自动滚动逐渐跑偏；逐字计算与重建带来掉帧风险（此前 `review_b4_a.md:78-95` 已记录父级重建问题，代码尚未改动）。

### PLY-23 翻译目标语言直接传 locale 代码，中文歌也翻译；`original` 模式仍执行翻译

- 位置：`lib/features/player/presentation/full_player_page.dart:33-38`（`targetLang = 'zh_CN'` 等）
- 问题：`ensureTranslation` 在返回歌词前无条件执行，不看 `lyricModeProvider`；目标语言是 `zh_CN/zh_TW/en/...` 代码而非语言名，且没有“源语言 == 目标语言则跳过”的判断（`LyricCandidate` 也没有 language 字段）。
- 依据：`translate_api.dart:33-35` 直接把 `$targetLanguage` 拼进 prompt；provider 未 watch `lyricModeProvider`。
- 影响：中文界面听中文歌也会把整首歌词发给翻译服务（延迟/配额浪费）；只看原文的用户同样被阻塞（叠加 PLY-05）。

### PLY-24 播放页的音质标签与播放错误文案硬编码中文，10 语言 UI 不一致

- 位置：`lib/features/player/data/models.dart:5-9`（`标准/高品/无损/Hi-Res/臻品母带`）、`full_player_page.dart:171`（`quality.label`）、`player_repository.dart:300-320`（`歌曲暂无版权/需要会员...`）
- 问题：设置页音质名称走 l10n（`settings_page.dart:40-47`），播放页 chip 用 enum 的中文字面量；错误经 Toast 直接展示中文异常文本。
- 依据：`AudioQuality.label` 为 `const` 中文；`_songFailureMessage` 全部中文。
- 影响：英/日/韩等界面出现中文；同一音质在设置页与播放页名称不一致。

### PLY-25 设置页的“WiFi 自动高品质 / 流量降低音质”开关没有任何消费点

- 位置：`lib/features/settings/presentation/settings_providers.dart:31-61`
- 问题：`wifiAutoHighQuality`（默认 true）与 `cellularLowerQuality` 只被设置页读写，播放链路（`player_repository` / `audio_handler`）从未读取，也没有网络类型判断。
- 依据：`rg "wifiQualityProvider|cellularQualityProvider|wifiAutoHighQuality|cellularLowerQuality"` 在 `features/settings/presentation/settings_providers.dart` 与 `settings_page.dart` 之外无命中。
- 影响：UI 承诺的策略不生效，用户以为已按网络切换音质。

### PLY-26 下载歌词导出格式不规范：`[ti]` / `[ar]` 缺冒号，译文与原文同时间戳重复写

- 位置：`lib/features/download/data/download_repository.dart:199-215`
- 问题：标准 LRC 元数据是 `[ti:标题]`、`[ar:歌手]`，这里写成 `[ti]标题`、`[ar]歌手`；每行原文后若带译文，再以同一时间戳写一遍译文（双语播放器会同一时刻显示两行/重复句）；行序未排序、未写 `[offset:]`。
- 依据：`_lyricToText` 实现；LRC 元数据语法。
- 影响：导出的 `.txt` 在第三方播放器中元数据不识别，双语行重复。

### PLY-27 点击歌词行 seek 到 `line.startMs`，未补偿 `offsetMs`

- 位置：`full_player_page.dart:382-384`（`seekTo(ms)`）、`lyric_view.dart:66`（显示位置加了 `offsetMs`）
- 问题：显示用 `position + offset` 对齐，点击却 seek 到原始 `startMs`；有 `[offset:]` 的歌词点行会跳到偏移量之外。
- 依据：`onTapLine` 传 `line.startMs`，未做 `- lyric.offsetMs`。
- 影响：带 offset 的歌词点击定位不准。

### PLY-28 `stop()` / 通知删除只停引擎，不清队列、媒体项、试听与音质状态

- 位置：`lib/features/player/data/audio_handler.dart:395-401`、`484-487`（`onNotificationDeleted`）
- 问题：`stop()` 只 `_player.stop()` + 清 `currentSong`；`_index`、`_songs`、`mediaItem`、`_isPreview`、`_actualQuality` 全部保留。`onNotificationDeleted` 也只 `stop()`。
- 依据：实现直接可见；`_emitMediaItem` 没有在 stop 时调用。
- 影响：停止后系统媒体库/蓝牙端仍可能显示旧媒体项；再次播放会从旧 `_index` 继续，UI 的音质/试听标签保留停止前的值。

### PLY-29 首页无 hash 的歌曲把 `id`（mixsongid/audio_id）当 hash 用；`fetchDetail` 的 `entries.first` 兜底可能合并错歌

- 位置：`lib/features/player/play_helper.dart:22、37`；`lib/features/player/data/player_repository.dart:60-70`
- 问题：`HomeSong.fromJson` 在无 hash 时把 `mixsongid/audio_id/id` 塞进 `id`，播放入口 `hash: s.hash ?? s.id` 直接把它当播放 hash；`/v5/url` 以 audio_id 当 hash 请求必然失败。`fetchDetail` 在 `matching` 为空时用 `entries.first`（第一档权益条目）与当前歌合并，若响应不是当前 hash 的条目，会把别的歌的专辑/时长/封面合并进来。
- 依据：`models.dart:121-124`（id 兜底逻辑）；`player_repository.dart:60-70`。
- 影响：首页某些区块（yueku/推荐）点播失败；详情补全可能展示错专辑信息。

### PLY-30 换歌后 `LyricView` 不再首帧跳转；点击歌词空白处会切回封面

- 位置：`lib/features/lyric/presentation/lyric_view.dart:52-58`（`didUpdateWidget` 未重置 `_didInitialScroll`）、`93-97`；`full_player_page.dart:362-366`（整块 GestureDetector 的 onTap 切换封面）
- 问题：`_didInitialScroll` 只在首次 build 后置 true，换歌后新歌词不做 `jumpTo`，而是从上一首的滚动位置 `animateTo`，会看到明显滑动。歌词区的父级 GestureDetector 与行内 GestureDetector 竞争，点击行间空白会触发“切回封面”，与“点歌词行 seek”语义冲突。
- 依据：实现直接可见；`ListView` 的 `padding` 与行内 `GestureDetector` 均未阻止父级点击（仅行内命中时子级获胜）。
- 影响：切歌时歌词列表先滚一下；误触歌词空白会退出歌词视图。

### PLY-31 `KrcParser` 不排序，`_findCurrentLine` 却用二分查找假设时间有序

- 位置：`lib/features/lyric/data/krc_parser.dart:56-138`（按文件顺序 append，无 sort）；`lyric_view.dart:137-149`
- 问题：KRC/LRC 若存在乱序行（对唱、拼接、重复时间戳），二分查找会返回错误行；同一时间戳的多行只命中最后一个。
- 依据：`_findCurrentLine` 的标准 lower-bound 二分；parser 未排序。
- 影响：个别歌词高亮跳到错误行或整段不高亮。

### PLY-32 错误提示直接把异常 `toString()` 弹给用户

- 位置：`lib/features/player/data/audio_handler.dart:332-337`（`'播放失败：$e'` → `playerErrorProvider`）；`lib/main.dart:215-230`（Toast）
- 问题：Dio/just_audio/`RangeError` 的英文堆栈式文本直接展示，未本地化、未脱敏；`$e` 可能包含 URL、响应体片段。
- 依据：`_errorController.add('播放失败：$e')`；`_onPlayerError` 原样 `Toast.show`。
- 影响：中英混杂、暴露内部信息，用户无法据此行动。

### PLY-33 其他静态观察（不单独定级）

- `lib/features/player/data/player_repository.dart:163、185、245、268`：`_proxyHttp` 是恒等函数，但注释仍写“走代理转 https”，与实际行为矛盾，容易误导后续维护。
- `player_repository.dart:199`：`_qualityFromBitrate(..., AudioQuality requested)` 的 `requested` 参数从未使用。
- `player_provider.dart:143-145`：`audioEngineReadyProvider` 是普通 `Provider` 读取瞬时 `isEngineReady`，不会随引擎就绪刷新，且全仓库无消费者。
- `audio_handler.dart:446-452`：`_randomIndex` 每次随机挑一个非当前下标，没有“最近播放”去重，随机模式可能连续重复同一首。
- `lyric_view.dart:206`：`Widget _buildOriginal(ThemeData theme, Color primary) {    if (...)` 格式化异常（语法合法）。
- `download_repository.dart:216-224`：`_fmtMs` 的分钟不做 60 取模，超过 1 小时输出 `[75:00.00]`，部分 LRC 解析器不接受。
- `audio_handler.dart:395-401`：`stop()` 已清 `currentSong`，但 `queueProvider` 仍返回旧队列，迷你播放器隐藏后队列面板仍可打开显示旧曲。
- `lyric_repository.dart:28-31`：歌词搜索/下载只做 90 秒内存缓存（`MemoryCache`），同一首歌重复进播放页会重复请求。
- `models.dart:213-215`：`Song.hashCode` 对空 hash 全部相同，`indexOf` 对多个空 hash 歌曲会命中第一首（与 PLY-17 同源）。
- `full_player_page.dart:20-40`：歌词 provider 声明在页面文件内，属于 presentation 层发起数据请求，与 `PLAN_architecture.md` 的分层铁律（UI 不直接构造/发起 repository 请求）不一致（`currentLyricProvider` 直接 `findCandidate/fetchLyric`）。

---

## 附：判定依据清单（便于复核）

| 问题 | 关键证据 |
|---|---|
| PLY-01 | `test/lyric_test.dart:31-36` 第二行 `[2048,1281]<0,256,0>…`；`krc_parser.dart:92-94`；`lyric_view.dart:221-223` |
| PLY-02 | `player_repository.dart:193-195`；`audio_handler.dart:321-329`；`verification_listener.dart:31-32`；`PlayUrlResult.ssaCode` 无消费 |
| PLY-03 | `audio_handler.dart:211-213`、`257`、`266/294/305/317` |
| PLY-04 | `player_repository.dart:234-239`、`253-277`；`kg_direct_api_client.dart:166-167` |
| PLY-05 | `full_player_page.dart:20-40`、`372-388`；`lyric_repository.dart:111-127` |
| PLY-06 | `audio_handler.dart:264-286`；`player_repository.dart:46-118` |
| PLY-07 | `player_repository.dart:199-208` vs `296-308`；`kg_play_api.dart:250-258` |
| PLY-08 | `player_repository.dart:175-190`；`kg_play_api.dart:228-233` |
| PLY-09 | `lyric_repository.dart:89-104`、`129-140` |
| PLY-10 | `cache_manager.dart:88-103` |
| PLY-11 | `krc_parser.dart:140-146`、`203-206`；`lyric_test.dart:105-111` |
| PLY-12 | `krc_parser.dart:54`、`110-124` |
| PLY-13 | `lyric_repository.dart:44-80`；调用点 `full_player_page.dart:31`、`download_repository.dart:160` |
| PLY-14 | `lyric_repository.dart:33-40`；`LyricCandidate.duration` 无消费 |
| PLY-15 | `audio_service_bootstrap.dart:40-42`、`53-58` |
| PLY-16 | `audio_handler.dart:249-259`、`281-315` |
| PLY-17 | `audio_handler.dart:223-226`；`models.dart:217-222` |
| PLY-18 | `audio_handler.dart:274-285`、`300-305`；`player_provider.dart:75-82` |
| PLY-19 | `player_repository.dart:247-248` vs `kg_play_api.dart:262-267` |
| PLY-20 | `queue_sheet.dart:100-108`；`audio_handler.dart:207-215` |
| PLY-21 | `full_player_page.dart:490-495`、`42-45` |
| PLY-22 | `lyric_view.dart:68-79`、`109-119`；`full_player_page.dart:359` |
| PLY-23 | `full_player_page.dart:33-38`；`translate_api.dart:33-35` |
| PLY-24 | `models.dart:5-9`；`settings_page.dart:40-47`；`player_repository.dart:300-320` |
| PLY-25 | `settings_providers.dart:31-61`；全仓库无播放侧读取 |
| PLY-26 | `download_repository.dart:199-224` |
| PLY-27 | `full_player_page.dart:382-384`；`lyric_view.dart:66` |
| PLY-28 | `audio_handler.dart:395-401`、`484-487` |
| PLY-29 | `play_helper.dart:22、37`；`player_repository.dart:60-70` |
| PLY-30 | `lyric_view.dart:52-58`、`93-97`；`full_player_page.dart:362-366` |
| PLY-31 | `krc_parser.dart:56-138`；`lyric_view.dart:137-149` |
| PLY-32 | `audio_handler.dart:332-337`；`main.dart:215-230` |

> 备注：本次为只读审查，未修改源码、未执行构建/测试/联网；P0/P1/P2 的划分基于“对播放出声/歌词正确显示的影响程度”，不涉及修复方案。
