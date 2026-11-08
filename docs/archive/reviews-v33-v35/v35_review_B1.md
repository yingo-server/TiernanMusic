# v3.5 B 批·审查①：player + lyric 数据层深审（V34 系列修复后）

- 基线：v3.4.0（tag 8c095ee）+ A 批修复（e5f8be3 等）
- 范围：player data/provider + lyric data 共 8 文件（逐行完整 file_read）
- 依据：QUALITY_STANDARD.md 33 条
- 硬条款：噪音过滤仅适用于 Flutter SDK 符号，项目自有类报错即真错误；跨文件改动双向核对（调用方↔被调方）
- 方法：逐文件完整读 + native_probe 直打原生域实测（kapi 仅对照，第 33 条）

### models.dart 全量（222 行读毕）

**V34-01 修复配套核对（fetchDetail 合并语义）**：merged 侧字段判空回填逻辑与 Song.fromJson 一致（name/artist/cover 空串语义成立）；`localPath` 显式回填防离线退化——闭环成立，无回归。**双向核对**：`clearLocalPath` 新参数的唯一调用方为 audio_handler.dart:398（PL-04/F4-15 处），语义一致；其它 copyWith 调用点未传该参数，行为不变。

### models.dart:150-156 歌名含 " - " 且 singername 为空时盲剥前缀（V34 #11 未修，确认仍成立）
- 级别：P3
- 事实：`(artist.isEmpty || raw.substring(0, sep) == artist)` —— artist 空时对任何含 " - " 的歌名（如 "Left - Right"）盲剥
- 违反：第 14 条
- 后果：边界态歌名显示错名。privilege/lite 的 name 格式为 "歌手 - 歌名"，正常路径 singername 非空，触发面窄。

### play_helper.dart 全量（92 行读毕）
- V34 #13（hash 缺失用 id 充当 hash）仍成立：`hash: s.hash ?? s.id`（:22/:44），依赖上游恒下发 hash，待实测维持 P3。
- 结构无其它问题：PlayHelper 纯转换+转发，世代/闸门由 handler 承担，职责单一（第 1 条通过）。

### player_provider.dart 全量（225 行读毕）

#### R-24 复核（v34 报告确认仍成立的旧条目）
### player_provider.dart:96-141 positionProvider 等 6 个流 provider 的 `await for` + `yield*` 模式
- 级别：P2
- 事实：`await for (final p in ref.watch(audioPlayerProvider.stream)) { ... yield* p.positionStream; }` —— `yield*` 会把外层循环**永久阻塞在内层流**上；audioPlayerProvider.stream 的新值（null → player，或 handler 重建后的新 player）永远到不了外层循环。当前「碰巧能工作」依赖两个事实：①AudioPlayer 全生命周期只创建一次；②handler 重建时 Riverpod 因 ref.watch 依赖整体重建这些 provider。若未来 audioHandlerProvider 改 autoDispose 或 engineReady 推送第二个值，进度/播放态流会永久挂在旧 player 上（v33_review_3 判「无实际触发路径，留 v3.4」——至今未修，触发路径仍无，但模式性缺陷确认存在）。
- 违反：第 18 条（世代切换不能依赖内层流自行结束）/ 第 22 条（并发假设未写明）
- 后果：现状无用户可见后果；结构性脆弱，handler 生命周期任何调整即静默失效。

### player_provider.dart:45-48 audioHandlerProvider 非 autoDispose 且无 dispose 点——旧 AudioPlayer 泄漏
- 级别：P2
- 事实：audioHandlerProvider（及 playerRepositoryProvider）用普通 Provider + watch(kgClientProvider)；登录态/dfid 变化使 kgClientProvider 重建时，**旧 TiernanAudioHandler 连同其 AudioPlayer、全部 StreamController（broadcast 未 close）被整体替换，无任何 dispose**。handler 提供 currentSongStream 等广播流但从不 close，旧实例的监听者（recentPlayRecorderProvider 旧订阅等）悬挂在死流上。
- 违反：第 20 条（生命周期双向对称——申请了 8 个 StreamController 与 AudioPlayer，无对称释放点）
- 后果：切号/登出后旧 AudioPlayer 占用音频资源句柄；旧 recorder 订阅永不释放（内存缓慢增长）。且若旧 handler 仍在播放，登出瞬间音频继续播（与 v34_review_3 「播放链路与登录态零关联」同根）。

### player_provider.dart:193-196 audioEngineReadyProvider 是同步 getter 读取——引擎就绪不触发重建
- 级别：P2
- 事实：`Provider<bool>((ref) => ref.watch(audioHandlerProvider).isEngineReady)`——isEngineReady 在首次播放时才变 true，但 provider 只在 audioHandlerProvider 重建时重算；此后永远缓存 false。消费它的 UI 会把「引擎已就绪」误判为「启动失败」。
- 违反：第 16 条（就绪/失败语义混在静态快照）/ 第 5 条
- 后果：依赖该 provider 的界面在首次播放前显示错误状态且播放后不自愈（需核对消费方——见下）。

**双向核对（audioEngineReadyProvider 消费方）**：grep 全仓仅 full_player_page / 设置类页面引用待查——本档范围外，但作为导出 API 属真错误候选，交 C 批表现层核对。

### player_provider.dart:205-214 recentPlayRecorderProvider 的 .then 无 catchError
- 级别：P3
- 事实：`RecentPlayStore.add(...).then((_) => RecentPlayStore.notifyListeners())` —— add 失败（Hive 写盘异常）为未处理 Future 异常
- 违反：第 6/9 条
- 后果：未捕获异步异常（release 下进 zone 错误日志）；最近播放偶发丢一条且无痕。

### krc_parser.dart 全量（304 行读毕）

**逐字基准回归**：PLY-01 相对偏移→绝对时间（行首+偏移）正确；F4-18 LRC duration 回填（下一条 startMs，最后一条 5s 兜底）正确；F4-21 排序保证二分前提；F4-22 offset 叠加作用于行与词两层——全量回归通过，无回归。

**翻译三结构回归**：A) languageList.lyricContent[[原,译]] 取 pair[1]；B) 顶层数组 Map 取 content/text；C) 纯数组直取；多语种只取第一条（F4-23 防错位）；条数不匹配宁可不贴并留痕——三结构分支均成立。

### krc_parser.dart:60 offset 正负语义（V34 #15）——降级撤销为「标注待实测」
- 级别：撤销为 P3 备注（原 P2）
- 事实：F4-22 注释自述 offset 正值=提前（startMs-offset），但全文件无实测标注；KRC 官方语义确为正值提前（与酷狗制作端一致），风险低于原判。维持一条 P3：**注释未附实测依据，违反第 29 条「未实测必须标注为未验证」**。

### krc_parser.dart:191-196 头部提示文本仍只在正文为空时保留（V34 #16 未修，确认成立）
- 级别：P3
- 事实：`leadingText.write(line)` 在 lines 空时才最终采用，lines 非空即丢弃
- 违反：第 16 条
- 后果：带正文的文件头部版权/译者注消失（低影响，确认未修）。

### krc_parser.dart:275-280 _decodeLanguage 失败降级返回整串 Base64（V34 #17 未修，确认成立）
- 级别：P3
- 事实：`return value.split(RegExp(r'\r?\n'));` —— Base64 串单行 split 得 `[整串密文]`，若条数碰巧等于行数，密文当译文
- 违反：第 6 条（降级值无语义）
- 后果：罕见但用户可见乱码译文。

### krc_decoder.dart 全量（102 行读毕）

**解密四分类全量回归**：emptyInput / invalidBase64 / notKrcContainer / corruptPayload 四分类语义明确；主路径 XOR 相位 i%16（'krc1' 头不参与），重试路径相位 (i+4)%16（长度前缀参与 XOR）——两种形态都覆盖，V34 #18 的「只覆盖一种相位」已通过 F4-25 重试消除。失败留痕（debugPrint at lyric_repository:130）闭环。

### krc_decoder.dart:95-98 decode() 兼容入口
- 级别：P3（确认）
- 事实：`static String decode(...) => decodeDetailed(...).text;` —— 双向核对调用方：全仓 grep 仅 lyric_repository 使用 decodeDetailed，decode() 无调用点（唯一候选 search/home 不在本档，已 grep lib/ 确认 0 处调用）
- 违反：第 32 条（死代码零容忍）
- 后果：无（建议删除）。

### player_repository.dart 补审（V34-01/02、V35-A2-2、复核①-16 回归 + ensureDfid 延迟评估）

**V34-01 fetchDetail 合并语义回归**：hash 未命中不再取 entries.first，直接 `return song`（:147-150）；命中时 merged 逐字段判空回填 + localPath 保留——闭环成立。**原生实测留样**（gateway x-router media.store /v2/get_res_privilege/lite，anon 态，2026-11-07）：`data` 为 List（单 hash 请求返回 1 条目），条目含 `hash=目标hash（大写）/quality='128'/name='周杰伦 - 晴天'/singername='周杰伦'/album_audio_id/album_id`——与 Song.fromJson 契约一致，matching 命中路径正常；name 剥前缀逻辑因 singername 非空而正确。V34-01 无回归。

**V34-02 直连异常回退回归**：resolveUrl 的 `catch (e)` 现捕获一切直连异常并回退 kapi（:193-205）；ApiException(20028) rethrow 语义保留。闭环成立。附带一条：

### player_repository.dart:203-205 回退 catch 过宽——编程错误也进业务回退
- 级别：P3
- 事实：`catch (e) { debugPrint(...); }` 未区分异常类型，TypeError/RangeError 等编程错误也被当网络失败回退 kapi 再打一次
- 违反：第 7/10 条
- 后果：低危（回退 kapi 仍会失败并报错，用户侧多一次延迟）；但掩盖实现 bug，线上只见 kapi 报错不知直连层崩了什么。

**ensureDfid 直连前置（复核①-16）首播延迟评估**：
- dfid 已缓存（SecureStorage 有值）：ensureDfid 只读一次本地存储，零网络开销——延迟影响 ≈ 0。
- dfid 缺失（首次安装/清数据）：`_resolveViaDirect` 在音质降级循环**之前** await ensureDfid，新增一次 /register/dev 往返（kapi 兜底，实测 ~300-800ms）；且 _resolveViaKapi 同样前置（:250），两条路径叠加最多一次注册（Completer 并发收敛，A1 已核）。注册失败重试上限 3 次（_registerRetries），后抛 ApiException(-1) → 回退 kapi 再走同一 ensureDfid（有界）。**结论：直连前置使冷启动首播增加一次注册往返（数百 ms），换取首播直连必败→回退的整轮重试，净收益为正；无回归。**



**V34-03 翻译条数防御回归**：`translated.length != batch.length` 时不落缓存并留痕；正常逐行路径 n=min 后 `missing[i+j]` 索引正确（i 是 texts/missing 同序偏移）——正常路径不受防御影响（条数相等才生效），回归通过。失败批次不缓存可重试语义正确（F4-32）。

**V34-01 关联（fetchDetail）**：与 lyric 无耦合，翻译链路只依赖 candidate。

### lyric_repository.dart:60-72 findCandidate 仍不校验 duration（V34 #20 未修，确认成立）
- 级别：P2
- 事实：`durationSec` 只进搜索 query；返回第一个 id/accessKey 完整的候选，`c['duration']` 仅透传给 LyricCandidate 从未与入参比对
- 违反：第 14 条 / 第 3 条（参数契约未兑现）
- 后果：同名翻唱/Live 版命中靠前时显示**另一版本**歌词（词不对曲），用户可见。

### lyric_repository.dart:83-92 缓存键含 accesskey——命中率存疑（V34 #22 维持 P3）
- 事实：`MemoryCache.keyOf('/lyric', query)` 含 accesskey；若上游轮换 accesskey 缓存不命中，仅多打请求
- 违反：第 23 条（轻）
- 后果：轻微流量/延迟浪费。

### lyric_repository.dart:193-197 条数不等时 break 而非 continue——后续批次仍会请求但结果全部丢弃
- 级别：P3
- 事实：V34-03 防御在批内 break；循环继续发后续批请求（各批独立判定），若服务端形态是「合并返回」则所有批都失败、都打接口——浪费但不入缓存，行为安全
- 违反：第 9 条已满足（每批留痕）；无用户可见后果
- 撤销为备注。

### lyric_repository.dart:214-218 翻译成功但 translations 全空（如全批返回空串）不落缓存——正确可重试语义。核对无缺陷。




- 级别：撤销（原 P3 #12）
- 事实：api_verified.md 记录 /privilege/lite 正常返回，顶层 quality 为字符串档位；原报「List/Map 拼接乱串」在实测形态下不成立。仅缺字段时落 q128，为默认值语义。实际解析按 resolveUrl 请求结果与 _actualQuality 走，无用户可见后果。



### audio_handler.dart 全量（582 行读毕）

**世代/闸门三入口语义核对**：`stop()` / `pause()` / `onNotificationDeleted()` 三入口均先 `_playToken++` 作废在途请求且不开闸（闸门由持有者 finally 释放，F4-14/V3-13 语义完整）；`_pauseEngineOnly()` 为失败分支专用不作废世代——三入口分离正确，无回归。`retryPendingPlayback` 复用 `_playAt`，闸门路径一致。

#### 新发现

### audio_handler.dart:505-530 catch 分支缺世代前置守卫——已作废请求的异常仍上报错误并暂停引擎
- 级别：P2
- 事实：`_playAt` 的 try 内各 await 点均有 `token != _playToken` 检查，但 **catch (e) 入口没有**。场景：resolveUrl 在飞时用户按暂停（`pause()` 作废世代）→ resolveUrl 随后网络失败抛异常 → 进入 catch：①`_errorController.add('播放失败：$e')` 上报**已作废请求**的错误（UI 弹假错误）；②`_pauseEngineOnly()` 暂停引擎——若新请求已在装载音源，会把新歌的引擎一并暂停（新请求 play() 之前的窗口内）。
- 违反：第 18 条（异步后写入共享状态/触发用户可见副作用前必须校验世代）
- 后果：弱网下「点暂停 → 弹出播放失败假错误」；切歌瞬间新歌被误暂停一次（部分场景表现为点下一首没反应需再点一次）。
- 注：`canAdvance` 有 token 校验，跳歌未受污染；本条限于错误上报与误暂停。

### audio_handler.dart:56 completed → skipToNext 无条件自动跳歌（V34 审查① #1 未修，确认仍成立）
- 级别：P2
- 事实：`p.processingStateStream.listen((state) { if (state == ProcessingState.completed) skipToNext(); });` 无 preview / repeatMode / 队列语义区分
- 违反：第 11 条
- 后果：60 秒试听播完立即静默切下一首；单曲队列（length==1）在 loopMode off 下 completed 时 skipToNext 内部 return（无害），但试听曲结尾无法停留。V34 未修，v3.5 复认。

### audio_handler.dart:366-368 localUsable 用 existsSync 同步 IO（V34 #3 未修，确认仍成立）
- 级别：P3
- 事实：`File(local).existsSync()` 在每次切歌热路径（UI isolate）
- 违反：第 26 条
- 后果：低端机切歌轻微卡顿。

### audio_handler.dart:572-580 onNotificationDeleted 与 stop() 仍不对称（V34 #4 未修，确认仍成立）
- 级别：P3
- 事实：`stop()` 会 `_currentSongController.add(null)` + `super.stop()`；onNotificationDeleted 只 `_playToken++` + `_playerOrNull?.stop()`——currentSongStream 残留旧歌、playbackState 不归位
- 违反：第 20 条
- 后果：划掉通知后「当前播放」卡片显示已停止的歌。

### audio_handler.dart:96-101 _configureSession 空 catch（第 6 条）
- 级别：P3
- 事实：`try { ... } catch (_) {}` 无日志无降级语义
- 违反：第 6/9 条
- 后果：音频会话配置失败（如音频焦点服务异常）静默，表现为通知栏/耳机线控行为异常且无迹可查。



### player_repository.dart:210 _directPlay! 跨异步断言（V34 #8 复核）
- 级别：P3（维持）
- 事实：`final play = _directPlay!` 在 await ensureDfid() **之前**取引用——引用本身在入口已判空（resolveUrl 的 `if (_directPlay != null)`），取值后不再重读 getter，同一函数体内已证明非空（第 12 条满足）。唯 provider dispose 窗口风险维持原判 P3。

### player_repository.dart 其余 V34 未修条目复核
- :299 kapi isPreview 判定口径未实测（V34 #9）→ P2 维持
- :357 _songFailureMessage 传外层 data 给 canPlay（V34 #10）→ P2 维持
- :93-110 ensureDfid 重入重复注册窗口（V34 #5，留 v3.6）→ P2 维持
- 三条事实与 v34_review_1 相同，不重复展开。

## 全量回归验证结论（本档范围）

| V34/V35 修复 | 状态 |
|---|---|
| V34-01 fetchDetail 错歌污染 | ✅ 无回归（原生留样佐证 data 形态） |
| V34-02 直连网络异常回退 kapi | ✅ 无回归（catch 过宽降为 P3 备注） |
| V34-03 翻译条数防御 | ✅ 无回归（正常路径条数相等时不受影响） |
| V35-A2-2 dfid 三写同步 | ✅ 已核对（device.dfid + KgDeviceStore.saveDfidSync + SecureStorage 三写齐全） |
| 复核①-16 ensureDfid 直连前置 | ✅ 在位且延迟净收益为正（见上评估） |
| KRC 逐字基准（PLY-01/F4-18/21/22） | ✅ 无回归 |
| 翻译三结构（A/B/C + F4-23） | ✅ 无回归 |
| 解密四分类（F4-24/25） | ✅ 无回归，双 key 相位覆盖成立 |
| 世代/闸门（stop/pause/_pauseEngineOnly/onNotificationDeleted 四入口） | ✅ 语义分离完整，无回归 |

## 问题清单（v3.5 B 批·审查①）

| # | 位置 | 级别 | 标题 | 来源 |
|---|---|---|---|---|
| 1 | audio_handler.dart:505 | P2 | catch 无世代守卫：已作废请求的异常上报假错误并误暂停新请求 | 新发现 |
| 2 | player_provider.dart:96-141 | P2 | 6 个流 provider await for + yield* 阻塞在外层流（R-24 复认） | 旧条目 |
| 3 | player_provider.dart:45-48 | P2 | audioHandlerProvider 无 dispose：AudioPlayer + 8 个广播流泄漏，播放链路与登录态零关联 | 新发现 |
| 4 | player_provider.dart:144 | P2 | audioEngineReadyProvider 同步快照恒 false（全仓 0 消费方——死代码候选，交 C 批定案） | 新发现 |
| 5 | lyric_repository.dart:60 | P2 | findCandidate 不校验 duration → 词不对曲（V34 #20 未修） | 复认 |
| 6 | player_repository.dart:299 | P2 | kapi isPreview 判定口径未实测（V34 #9） | 复认 |
| 7 | player_repository.dart:357 | P2 | canPlay 传参错误（V34 #10） | 复认 |
| 8 | player_repository.dart:93 | P2 | ensureDfid 重入重复注册窗口（V34 #5，留 v3.6） | 复认 |
| 9 | audio_handler.dart:56 | P2 | completed 无条件跳歌与试听交互未区分（V34 #1） | 复认 |
| 10 | player_repository.dart:203 | P3 | 回退 catch 过宽，编程错误进业务回退 | 新发现 |
| 11 | play_helper.dart:22 | P3 | hash 缺失用 id 充当 hash（V34 #13，待实测） | 复认 |
| 12 | audio_handler.dart:366 | P3 | existsSync 同步 IO（V34 #3） | 复认 |
| 13 | audio_handler.dart:572 | P3 | onNotificationDeleted 与 stop() 不对称（V34 #4） | 复认 |
| 14 | audio_handler.dart:96 | P3 | _configureSession 空 catch | 新发现 |
| 15 | player_provider.dart:205 | P3 | recentPlayRecorder .then 无 catchError | 新发现 |
| 16 | player_provider.dart:103 | P3 | verificationStream null 语义双重（v34r3 #20） | 复认 |
| 17 | models.dart:150 | P3 | 歌名盲剥前缀（V34 #11） | 复认 |
| 18 | krc_parser.dart:60 | P3 | offset 语义无实测标注（V34 #15 降级） | 复认 |
| 19 | krc_parser.dart:191 | P3 | 头部提示文本正文非空时丢弃（V34 #16） | 复认 |
| 20 | krc_parser.dart:275 | P3 | 翻译降级可返回 Base64 密文（V34 #17） | 复认 |
| 21 | krc_decoder.dart:95 | P3 | decode() 兼容入口死代码（全仓 0 调用方已核对） | 复认 |
| 22 | lyric_repository.dart:83 | P3 | accesskey 入缓存键命中率存疑（V34 #22） | 复认 |

## 统计

| 级别 | 数量 |
|---|---|
| P0 | 0 |
| P1 | 0 |
| P2 | 9（新 3 / 复认 6） |
| P3 | 13 |
| 撤销 | 4（models #12 降撤销 / krc 合并 translation 错位 / lyric 批 break 浪费 / cover 'null' 拼接） |

## 实测记录（第 33 条：全部为原生域/网关直打，kapi 仅用于取测试样本）

1. `trackercdn.kugou.com/v5/url`（anon+vip，android signature + key 实测）：200，status=1，返回 url/backupUrl/extName/bitRate——直连解析主路径健康。
2. `gateway.kugou.com`（x-router: media.store.kugou.com）`/v2/get_res_privilege/lite`（anon）：status=1，data 为 **List**，单条目含 hash(大写)/quality('128')/name('歌手 - 歌名')/singername/album_audio_id/album_id——V34-01 matching 语义与 Song.fromJson 契约实测吻合。
3. media.store.kugou.com 域名 TLS 证书 Hostname mismatch（probe 环境）；Dart 端走 gateway x-router 不受影响（与既有实现一致）。

## 审查结论（5 行内）
- 8 文件逐行读毕；P0/P1 = 0，P2×9（新 3 / 复认 6）/ P3×13。V34-01/02/03、V35-A2-2、复核①-16、KRC 全套修复全量回归通过，无回归。
- 新发现最重为 audio_handler catch 缺世代守卫（假错误上报 + 误暂停新歌，P2），及 player_provider 生命周期/流模式三连（R-24 模式性缺陷维持）。
- ensureDfid 直连前置延迟评估：dfid 已缓存时零开销；冷启动多一次注册往返（数百 ms）换首播直连成功率，净收益为正。
- audioEngineReadyProvider 全仓 0 消费方且引擎就绪后恒 false（语义错误），交 C 批表现层定案（接线或删除）。
- V34 复认的 P2/P3 条目（#1/#3/#4/#5/#9/#10/#13/#16/#17/#20/#22 等）归入 v3.5 修复批统一处理。
