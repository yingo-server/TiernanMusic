### 12/14 `lib/features/player/data/audio_handler.dart`（701 行，✅通读，分 3 段完整读完 1-240/241-480/481-701）

跨文件契约抽查（计入 8 个抽查额度）：`prefetch_engine.dart`（`updateUpcoming` / `onPlaybackCompleted` 签名与 `_requested` 语义）。

#### 问题

### lib/features/player/data/audio_handler.dart:26-29 / 69-78 / 全类无 dispose：8 个 StreamController + 3 条 player 流订阅 + AudioPlayer 全部无释放点
- 级别：P1
- 违反：QUALITY_STANDARD 第 20 条（生命周期必须双向对称：申请了订阅/控制器必须在同一作用域有对称释放点）
- 依据：`ensureEngineReady` 中 `p.playbackEventStream.listen(_broadcastState)` 与 `p.processingStateStream.listen(...)` 的返回值未保存、未 `cancel()`；`_playerInstance = AudioPlayer()` 创建后全类 701 行无 `dispose()` 覆写、无 `p.dispose()`；`_currentSongController`、`_actualQualityController`、`_errorController`、`_engineReadyController`、`_previewController`、`_verificationController`、`_playedController`（7 个 `StreamController.broadcast()`）均无 `close()`。注释明确这是进程级后台 Handler，但没有任何「进程生命周期内不释放」的显式声明或释放入口。
- 影响：热重载/音频服务重启/`AudioService` 重建 Handler 时，旧实例的 player 仍在占用音频焦点与平台通道、旧广播流仍持有 UI 订阅，出现双份播放状态推送（进度条/播放键抖动、通知栏两套控制），且内存与音频资源随重建次数累积不释放。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:53-91 `ensureEngineReady` 并发可重入，无 in-flight 合并
- 级别：P1
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门必须成对且归属同一所有者）、第 22 条（并发假设必须写明）
- 依据：`if (_initialized) return true; final ok = await AudioServiceBootstrap.ensureReady(); ... if (_initialized) return true; _initialized = true; final p = _playerInstance = AudioPlayer();` — `_initialized` 在 `await` **之后**才置 true，且没有 `_initializing`/Future 去重；两个调用者（如 `playQueue` 与 `play()` / `skipToNext()` 同时进入）都可越过首个 `if`，各自创建 `AudioPlayer()`、各自注册两条流监听、各自 `_engineReadyController.add(p)`，后创建者覆盖 `_playerInstance`，先创建者永不 dispose。
- 影响：冷启动并发点播时生成两个音频引擎，UI 收到两次「引擎就绪」、进度/播放态由两个 player 交替广播；被覆盖的 player 泄漏且可能仍在缓冲，用户听到卡顿、进度回跳或无声。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:70-86 `_player` 与 `_broadcastState` 用 `!` 非空断言且 `processingState` 映射使用 `map[..]!`
- 级别：P2
- 违反：QUALITY_STANDARD 第 12 条（禁止无依据的非空断言）、第 10 条（编程错误不得进业务降级）
- 依据：`AudioPlayer get _player => _playerInstance!;`（:29）——这是跨越函数边界的非空断言，其成立依赖「所有调用点都先 await ensureEngineReady」这一未在本函数体内证明的前提；`_broadcastState` 的 `processingState: const {...}[p.processingState]!`（:215）同样用 `!`，若 just_audio 新增/返回未枚举的 `ProcessingState`，直接抛 TypeError。`_broadcastState` 被 `playbackEventStream` 高频回调（每帧/每缓冲事件），异常发生在流回调里不受 `_playAt` 的 try/catch 保护。
- 影响：引擎刚创建但尚未赋值完成的竞态窗口、或三方库新增枚举值时，播放态广播抛未捕获异常，进度条/通知栏停止更新，用户看到「歌在响但界面卡住」。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:168-172 `_configureSession()` 空 catch 且 fire-and-forget
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`Future<void> _configureSession() async { try { ... } catch (_) {} }`，catch 为空体；调用点 :91 `_configureSession();` 未 `await`、未接 `catchError`，返回的 Future 被丢弃。同文件 :58-67 对引擎失败却接了 `ErrorLogger.instance.log`，两套可观测性口径。
- 影响：AudioSession 配置失败（蓝牙/耳机/音频焦点策略异常）时，用户遇到「插耳机不断播」「被电话打断后不恢复」等行为，日志与 UI 均无记录，线上完全无法定位。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:493-505 `finally` 中无条件 `_loading = false`，与「关闸必须判断我是否仍是当前持有者」冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 19 条（关闸时必须判断持有者身份）
- 依据：`finally { _loading = false; final pending = _pendingIndex; ... }` 无 token 判断；虽注释解释「被作废的旧请求同样负责放行」，但**同一时刻可能有多个 `_playAt` 在飞**（见下条与 :370 的 `if (_loading)` 早退并非在所有路径生效：`playQueue` 直接 `await _playAt(index)` 且 `_loading` 仍为 true 时，新请求把 `_pendingIndex` 写入后返回，理论上只有一个在飞；但 `_applySource` 的 `setAudioSource` 不可取消，旧请求 finally 释放闸门后 microtask 里 `_playAt(pending)` 与新请求可能交错）。`finally` 的释放不校验 `token == _playToken`，即「无条件关闸」。
- 影响：世代已作废的旧请求退出时提前放行，新请求与排队请求可同时进入 `setAudioSource`，出现「点 A 歌听到 B 歌」或双份音源装载；此类竞态只在快速连续切歌时偶现。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:75-86 / 249-263 播放完成回调 `_lastPlayUrl` 无世代与曲目校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`p.processingStateStream.listen((state) { if (state == ProcessingState.completed) { if (_lastPlayUrl.startsWith('http') && !_lastIsPreview && _lastDeclaredBytes > 0) { PrefetchEngine.instance.onPlaybackCompleted(...); } skipToNext(); } })`；回调不接收也不校验 token/当前曲目，`_lastPlayUrl`/`_lastDeclaredBytes`/`_lastIsPreview` 是三个可变字段（虽 `_setLastSource` 声称原子写入），而 `stop()`（:590-596）与 `playQueue` 空队列分支（:279-286）会重置它们。`completed` 是异步到达的引擎事件，可能晚于切歌/停止。
- 影响：停止或切歌瞬间引擎上报 completed 时，仍按上一次（或已清空）的 URL 触发永久文件缓存与自动跳歌；用户按了停止却又自动播下一首，或把上一首的文件以错误字节数标识入库。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:77-84 完整播放完成后未校验「实际播完」，缓存 hook 由 completed 事件直接触发
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（数据边界：字节数/身份必须可判定）
- 依据：`onPlaybackCompleted(_lastPlayUrl, 'audio', declaredBytes: _lastDeclaredBytes)` 只以 `_lastDeclaredBytes > 0` 与 `!_lastIsPreview` 为条件，未核对播放器实际 `position`/`duration`（是否播到末尾）、未核对实际接收字节数；`_lastDeclaredBytes` 来自解析 JSON 的「声明值」，非实测值。
- 影响：上游把试听片段标为完整（isPreview=false）或声明字节数与实际不符时，片段被当作全曲入永久缓存；后续复用该缓存播放会出现「歌只播一半」且极难排查（B3 已复核通过的四道长度校验在 `ResourceCache` 侧，但此处的入参可信度未在本层建立）。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:446-450 / 470-489 失败分支用 `catch (e)` 捕获一切、把 `$e` 原文写进用户可见 error 文案
- 级别：P2
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理类型）、第 8 条（跨层异常统一包装）、第 9 条
- 依据：`catch (e)` 无 `on` 子句，覆盖 `RangeError`/`TypeError` 等编程错误；`_errorController.add('播放失败：$e')` 与 `errorMessage: '播放失败：$e'` 把原始异常对象字符串直接作为用户可见文案/媒体会话错误，未走 `friendly_error.dart` 转译（抽查见 `core/utils/friendly_error.dart` 存在该出口）。仅有 `_extractApiException` 对 20028 特殊处理，其余异常一律当作「播放失败」并自动 `skipToNext()`。
- 影响：索引越界/空调用等实现缺陷被当作业务失败静默跳歌，用户看到一串技术异常文本（可能含 URL/token），同时真实 bug 被隐藏；失败原因未走统一友好错误出口。
- 证据等级：静态推演

### lib/features/player/data/audio_handler.dart:573-578 `_pauseEngineOnly` 空 catch；:247 `_emitQueue` 每次队列变化同步构造全队列 MediaItem
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（空 catch）、第 26 条（热路径零分配）/第 25 条（资源上限）
- 依据：`try { await p.pause(); } catch (_) {}` 空体且无留痕；`_emitQueue()` 在 `playQueue`（:291）、`playSong`（:335）每次都 `_songs.map((s) => MediaItem(...)).toList()` 全量构造，`updateUpcoming` 也每次全量遍历；`_songs` 无长度上限，`PrefetchEngine` 的 60 首上限只在预热入队侧。
- 影响：pause 失败时错误吞掉，失败自动跳歌逻辑照常推进；超大队列（数千首）换队列时主线程一次性分配数千 MediaItem 造成明显卡顿，且通知栏队列体积无上限。
- 证据等级：静态推演

#### 复核通过（本文件）
- `playQueue`/`playSong` 把 `++_playToken` 放在 `await ensureEngineReady()` **之前**，并在 await 后校验 token，消除首次引擎初始化窗口内两次队列并发装载（第 18 条主路径成立）。
- `pause()`/`stop()`/`onNotificationDeleted()` 只作废世代、不清 `_loading`，闸门由在途 `_playAt` 自己的 `finally` 释放；`pending` 交接携带 `handoffToken` 并在 microtask 内校验（第 19 条释放归属设计到位）。
- 20028 分支用 `_pendingSongHash`（hash 而非下标），`retryPendingPlayback()` 按 hash 重定位并在找不到时 `debugPrint` 留痕（第 18/16 条）；catch 入口先校验 token 再判 20028，迟到验证不打断当前播放。
- 本地文件分支用 `local.startsWith('content://') || File(local).existsSync()` 判定可用性，`on Exception` 时才**同曲**回退在线并用 `clearLocalPath: true` 清除失效源，未误跳下一首（第 11 条降级触发/退出条件明确）。
- `_applySource` 在 `setAudioSource` 前后各校验一次 token，明确记载「setAudioSource 不可取消」的平台事实（第 18/31 条）。
- 失败连续计数 `_failureStreak < _songs.length` 防止无限自动跳歌（第 25 条重试上限）。
- `_setLastSource` 三字段同批写入，`stop()`/空队列分支显式清空快照，`completed` 侧有 `startsWith('http') && !_lastIsPreview && bytes>0` 三条件闸门（第 5 条状态单一来源局部成立）。

---

### 13/14 `lib/features/player/player_provider.dart`（227 行，✅通读）

#### 问题

### lib/features/player/player_provider.dart:88-143 六个 `StreamProvider` 用 `yield* p.xxxStream` 委托，切换播放器时不取消旧播放器订阅
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（订阅必须在同一作用域内对称释放）、第 18 条（异步结果必须校验世代）
- 依据：`positionProvider`/`bufferedPositionProvider`/`durationProvider`/`isPlayingProvider`/`shuffleProvider`/`repeatProvider` 均为 `await for (final p in ref.watch(audioPlayerProvider.stream)) { ... yield* p.positionStream; }`。Dart 的 `yield*` 只在**内层流结束**后才回到外层 `await for`；`just_audio` 的 `positionStream` 是永不会自然完成的广播流。因此一旦 `audioPlayerProvider` 因引擎重建（见 audio_handler `ensureEngineReady` 无去重，可能 emit 第二个 player）产出新 `AudioPlayer`，这六个 provider 仍把旧 player 的流一路 `yield*` 到底，新 player 永远接不上；且 Provider 被 dispose 时 `yield*` 的订阅才随 StreamProvider 取消，没有显式 `StreamSubscription` 保存与 `cancel()`。
- 影响：引擎重建/热重载后进度条、播放键、时长、随机、循环全部停在上一个引擎的旧值，用户看到「歌在放但进度不动、按钮点不动」；旧 player 的每条 tick 仍驱动重建，低端机持续额外开销。
- 证据等级：静态推演

### lib/features/player/player_provider.dart:158-171 `recentPlayRecorderProvider` 内 `RecentPlayStore.add(...).then(...)` 无错误处理、无防重
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（异常不得被丢弃）、第 9 条（失败必须可观测）、第 21 条（写操作幂等或防重）
- 依据：`onSongStarted.listen((song) { ... RecentPlayStore.add(...).then((_) => RecentPlayStore.notifyListeners()); })` — Future 无 `catchError`/`onError`、未 `await`、无留痕；`notifyListeners()` 只在成功路径调用；同一首歌因自动切歌/失败跳歌/验证重试重复触发 `onSongStarted` 时无去重键。唯一的对称释放是 `ref.onDispose(sub.cancel)`，只处理订阅不处理在途写。
- 影响：Hive/磁盘写失败时最近播放列表静默丢记录且无日志（未处理异步错误）；同一首歌被重复写入多条最近播放，用户看到列表里重复项。
- 证据等级：静态推演

### lib/features/player/player_provider.dart:33 / 40-43 `audioHandlerProvider` 与 `audioEngineReadyProvider` 的生命周期/状态口径不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 2 条（隐式依赖）
- 依据：`audioHandlerProvider` 是普通 `Provider`（Riverpod 缓存后常驻，注释「应用生命周期内常驻」），无 `onDispose`；而 `audioEngineReadyProvider = Provider<bool>((ref) => ref.watch(audioHandlerProvider).isEngineReady)` 是**同步快照**，Riverpod 只在依赖失效时重算，`isEngineReady` 由 audio_handler 内部可变 `_initialized` 驱动却没有任何通知/刷新机制。所有 `StreamProvider`（queue/position/...）都 `ref.watch(audioHandlerProvider)` 而非监听引擎就绪事件。
- 影响：`ensureEngineReady()` 成功后 `audioEngineReadyProvider` 不会自动变为 true（除非被显式 invalidate），依赖它的 UI 会长期停留在「音频服务未就绪」提示或反之；同一份「引擎是否可用」事实在 `_initialized`、`engineError`、`engineReady` 流、该 Provider 四处存在，且只有一处可写。
- 证据等级：静态推演

### lib/features/player/player_provider.dart:19-21 注释引用不存在的装配位置
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，不得指向不存在的上游）
- 依据：`/// 复用 [kugouApiClientProvider]（core/providers.dart）` — 该 Provider 实际定义在 `lib/app/di.dart`（本报告第 1 个文件已确认），`core/providers.dart` 在装配口径里不是它的定义处；`_apiClientProvider` 只是对 `kugouApiClientProvider` 的一层无意义转发（`Provider<KugouApiClient>((ref) => ref.watch(kugouApiClientProvider))`），增加一层间接却不注入任何东西。
- 影响：维护者按注释去 core 层找装配点会找不到，误判登录态共享链路；无直接用户可见后果。
- 证据等级：静态推演

#### 复核通过（本文件）
- `audioPlayerProvider` 用 `StreamProvider` 而非普通 Provider，先 `yield handler.player`（可为 null）再 `await for` 引擎就绪流，规避「首帧 null 被永久缓存」的历史 P0（注释给出原因，第 31 条）。
- `recentPlayRecorderProvider` 用 `ref.onDispose(sub.cancel)` 对称取消订阅（第 20 条局部成立），并统一从 `onSongStarted` 而非各播放入口写最近播放（第 5 条单一来源）。
- 六个 progress Provider 在 `p == null` 时给出稳定的 `Duration.zero`/`false`/`LoopMode.off` 空值，不让 UI 拿到未定义态（第 16 条）。
- `playerRepositoryProvider` 先 `ref.watch(kgClientProvider)` 预热直连设备身份；`_apiClientProvider` 复用全局 `kugouApiClientProvider`，共享同一 CookieJar（登录态口径到位）。
- `PlayerController` 只做转发，不自行构造 Repository、不触网（分层单向依赖）。

---

### 14/14 `lib/features/player/presentation/queue_sheet.dart`（184 行，✅通读）

跨文件契约抽查（计入 8 个抽查额度）：`error_retry.dart`（`ErrorRetry` 构造签名，确认 :63 调用参数合法）。

#### 问题

### lib/features/player/presentation/queue_sheet.dart:129-147 点击队列项用 `controller.playQueue(live, idx)` **整体替换队列**，与「点击当前队列某一首」的语义不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（跨层接口契约：操作语义必须明确）、第 5 条（状态单一来源）
- 依据：`_play` 调 `controller.playQueue(live, idx)` → `audio_handler.playQueue` 会 `_songs.clear()..addAll(songs)`、`++_playToken`、`_emitQueue()`、重新 `_playAt(index)`。而 `live = handler.songs` 是 `List.unmodifiable(_songs)` 的当前副本；把同一份队列重新灌回去，会作废当前正在播放/缓冲的请求、重置 `_failureStreak`、清空 `_pendingSongHash`（挂起的人机验证），并让 `PrefetchEngine.updateUpcoming` 重新入队。注释只讨论「快照 index 失效」，未讨论「重放整队」的副作用。
- 影响：用户点队列里正在播的那首歌也会**从头重播**并重新发起网络解析；若此时正处于 20028 人机验证挂起状态，挂起被清空导致验证完成后不再重试，用户必须手动重进；快速点击时还会出现连续重装载与进度回跳。
- 证据等级：静态推演（调用链已核对 audio_handler.playQueue）

### lib/features/player/presentation/queue_sheet.dart:136-141 `s.hash.isEmpty` 分支仍按可能被替换过的快照 index 播放
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果/快照必须校验世代）
- 依据：`if (s.hash.isEmpty) { _play(controller, live, snapshotIndex); return; }`；`live` 是**当前**队列，`snapshotIndex` 来自 `queueAsync` 快照。注释自己承认「按快照 index 播（快照一致时才有效）」，但未做任何一致性校验；`_play` 只查 `idx < live.length`，队列变短/顺序变化时 index 会指向另一首歌。
- 影响：无 hash 的本地歌曲在队列变化后点击，会播到别的歌，用户听到与点击项不符的内容且无提示。
- 证据等级：静态推演

### lib/features/player/presentation/queue_sheet.dart:145 `context.mounted` 检查放在 `Navigator.of(context).pop()` 之后
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（异步/导航后触及已销毁对象必须先确认存活）
- 依据：`_onTap` 第 136 行先 `Navigator.of(context).pop();`（同步发起路由弹出，随后 context 所在 Element 会被卸载），到 :145 才在 else 分支判 `context.mounted` 并 `ScaffoldMessenger.of(context).showSnackBar(...)`；`ScaffoldMessenger.of(context)` 在同一函数里跨过 pop 后仍依赖该 context。且 `pop()` 之前没有任何 `mounted` 检查。
- 影响：弹层正被系统收起/页面已 dispose 时用户触发点击，`pop()`/`ScaffoldMessenger.of` 在已卸载 context 上抛错；「队列已变更」的提示因为弹层已 pop 而可能根本不显示（提示挂在正在消失的 Scaffold 上），用户只看到点击后弹层关闭、什么都没发生。
- 证据等级：静态推演

### lib/features/player/presentation/queue_sheet.dart:48 / 63-66 队列数在 loading 态显示 0，`error` 分支未展示可复制技术详情之外的日志
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条（加载中/失败/空必须语义分离）
- 依据：`Text(context.l10n.songCountSuffix(queueAsync.valueOrNull?.length ?? 0))` 在 loading/error 时把「未知」显示成 0 首；`error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(queueProvider))`，`ref.invalidate` 无异常保护，重试失败无额外留痕（抽查 `ErrorRetry` 只做 UI 分类，不落日志）。
- 影响：队列流尚未发首值时用户先看到「0 首」再跳成真实数目，短暂误导；队列流错误且重试反复失败时线上无日志可查。
- 证据等级：静态推演

#### 复核通过（本文件）
- 三态分离：`loading → CircularProgressIndicator`、`error → ErrorRetry`、`data & isEmpty → EmptyState`，注释明确不与「流尚未发首值」合并（第 16 条主路径成立）。
- 点击时以 `handler.songs` 当前队列为准、按 hash 重定位，找不到时给 `queueChangedHint` 提示而非静默（第 9/18 条局部成立）。
- `isCurrent` 判定要求 `current.hash.isNotEmpty` 且双方相等，规避双空串误判（第 14 条）。
- `_play` 显式下标范围检查，无 `!` 非空断言（第 12 条）；列表用 `ListView.builder` 惰性构建，封面 `memCacheWidth` 限制解码尺寸（第 24/25 条）。
- `showQueueSheet` 用 `builder: (_)` 不捕获外部 context，`FractionallySizedBox` 高度固定 0.7 且 `isScrollControlled/useSafeArea` 齐备。

---

## 跨文件契约抽查汇总（本视角，共 6 个文件，≤8）

| # | 文件 | 抽查内容 | 结论 |
|---|---|---|---|
| 1 | `lib/features/lyric/presentation/lyric_view.dart` | `_onTranslationPatch` 按 `startIndex + j` 应用 patch；`initState` 绑定 `_boundLyric`/`_boundSongHash`；`dispose` 取消订阅 | 证实 `lyric_repository` 两条 P1 的补丁错位（非推测） |
| 2 | `lib/core/resource/lyric_translation_stream.dart` | `LyricTranslationPatch(lyricId, startIndex, values, {songHash})` 定义；`emit` 的 `isClosed` 早退；`dispose` 可重建 | 契约确认；补丁是「连续段」语义 |
| 3 | `lib/core/cache/cache_manager.dart` | `LyricTranslationCache.get/set` 的 `Map<int,String>` 序列化、键含 `translateModel` | 确认缓存维度；`get` 里 `int.parse` 无异常保护（见下） |
| 4 | `lib/features/player/presentation/full_player_page.dart` | `ensureTranslation(..., songHash: song.hash)` 调用点；await 后 `now.hash != songHash` 世代校验 | 确认上游只做一次最终世代校验 |
| 5 | `lib/core/prefetch/prefetch_engine.dart` | `updateUpcoming(queue, currentIndex, {window=15})`、`onPlaybackCompleted(url, kind, {declaredBytes})`、`_requested` 去重与 60 首上限 | 确认 audio_handler 快照字段的消费者 |
| 6 | `lib/core/widgets/error_retry.dart` | `ErrorRetry({message, onRetry, error})` 构造签名 | `queue_sheet` 调用参数合法 |

### 抽查中新增问题（不计入通读文件，单列）

### lib/core/cache/cache_manager.dart:155-162 `LyricTranslationCache.get` 的 `int.parse` 对损坏缓存体无保护
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（磁盘读取边界必须校验）、第 13 条
- 依据：`for (final line in raw.split('\n')) { final idx = line.indexOf('\t'); if (idx > 0) { map[int.parse(line.substring(0, idx))] = line.substring(idx + 1); } }` — `int.parse` 未用 `tryParse`、无 try/catch；`idx > 0` 只保证有制表符，不保证前缀是数字。同文件 `getWithStale`（:30-38）对损坏 JSON 则明确 `catch` + 删除坏条目，两套边界口径不一致。
- 影响：`lyric_translations` 盒被旧版本/外部写入脏数据（或人工改坏）时，`ensureTranslation` 在 `await LyricTranslationCache.instance.get(...)` 处抛 `FormatException`；该调用位于 `lyric_repository.ensureTranslation:164`，**不在任何 try/catch 内**（翻译批次的 try 只包住 `translateLines`），异常一路冒到 `currentLyricProvider`，用户看到整页歌词加载失败且无译文。
- 证据等级：静态推演（跨文件契约已核对调用链）

### lib/core/prefetch/prefetch_engine.dart:120-131 `updateUpcoming` 只入队「已在 `_requested` 中」的 hash，预热窗口语义反了
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约语义与命名不符）、第 30 条（命名即文档）
- 依据：`for (...) { if (song.hash.isEmpty) continue; if (!_requested.contains(song.hash)) continue; upcoming.add(song); }` — `enqueueSongs` 里同样的判断写的是 `if (!_requested.contains(song.hash)) continue; // 已命中缓存/已入队：跳过`，即 `_requested` 在此处的语义与注释相互矛盾；`updateUpcoming` 名为「未来 window 首补充」，实际只挑**已请求过**的歌再次入队（且 `_prefetchOne` 未再检查 `_requested`，造成重复请求）。
- 影响：播放队列变化后，真正「未来 15 首」中尚未预热的歌永远不会被预热，用户连续切歌时每首都冷启动解析（20-30s 超时风险）；已被预热的歌反而重复入队发请求，浪费流量。
- 证据等级：静态推演

---

## 追加问题（`dart analyze` 实锤，补齐两个通读文件）

### lib/features/lyric/data/lyric_repository.dart:2 未使用的 import（analyze 实锤）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍：未使用的导入）
- 依据：`dart analyze lib/features/lyric/data/lyric_repository.dart` 输出 `warning - lyric_repository.dart:2:8 - Unused import: '../../../core/net/music_api.dart'`；全文 281 行无 `MusicApi` 符号引用。
- 影响：无用户可见后果；真实 unused_import 警告被大批量三方包缺失噪音淹没，降低静态检查信噪比。
- 证据等级：实锤（analyze 输出，见文末）

### lib/features/mv/data/mv_repository.dart:3 未使用的 import（analyze 实锤）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：`dart analyze lib/features/mv/data/mv_repository.dart` 输出 `warning - mv_repository.dart:3:8 - Unused import: '../../../core/net/music_api.dart'`；该文件是 43 个文件中唯一 **0 error** 的文件（仅 1 warning + 1 info），故该告警不可能是三方包缺失的级联产物。
- 影响：同上。
- 证据等级：实锤（analyze 输出，见文末）

### lib/features/mv/data/mv_repository.dart:230 局部变量可 final（analyze 实锤）
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条（命名/声明应表达意图）
- 依据：`info - mv_repository.dart:230:5 - Local variables should be final. Try making the variable final. - prefer_final_locals`，对应 `MvInfo.fromJson` 内 `var thumb = MvRepository._mvThumb(...)`（其后无重新赋值）。
- 影响：无用户可见后果；声明与行为不符的轻度整洁度问题。
- 证据等级：实锤（analyze 输出）

### lib/core/widgets/gradient_chip.dart:1/5/6 三个未使用 import（源码实锤，analyze 因 Flutter 缺失未报 unused_import）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：`import 'dart:async';`（:1）、`import '../utils/toast.dart';`（:5）、`import '../../l10n/l10n.dart';`（:6）在全文 53 行无任何符号引用；`dart analyze` 只报了 1 条 `uri_does_not_exist`（Flutter 缺失）与 22 条级联 undefined，未产生 unused_import 警告（依赖缺失时分析器不判定 import 使用性）。
- 影响：无用户可见后果；死代码 + 文末孤立注释误导。
- 证据等级：静态推演（源码全文核对；analyze 未覆盖此项，如实标注）

---

## 逐文件 `dart analyze` 结果（43/43 全覆盖）

命令：`export PATH=$PATH:/opt/dart/bin && dart analyze <file>`（逐文件单独执行，共 43 次；`dart --version` = 3.13.7 stable）。完整输出留在 `/tmp/analyze_all.txt`（2278 行），下表为逐文件汇总；**下表每一行的诊断码集合即该文件 analyze 的过滤后结果**。

### 噪音过滤口径（必须先说明，否则数字会被误读）

本仓库**无 `.dart_tool/package_config.json`**（未 `pub get`，任务书禁止），因此分析器无法解析任何 `package:flutter/**`、`package:flutter_riverpod/**`、`package:just_audio/**` 等三方包 URI。由此产生两类**预期噪音**：
1. `uri_does_not_exist`（`package:...` 与 `dart:ui`）：88 条，其中 `package:` 86 条，`dart:ui` 2 条（`splash_handwriting.dart:2`、`mini_player.dart:1` — 纯 Dart VM 环境不提供 Flutter 的 dart:ui，非项目缺陷）。
2. 由 ① 级联出的 `undefined_class` / `undefined_identifier` / `undefined_method` / `extends_non_class` / `super_formal_parameter_without_associated_named` / `override_on_non_overriding_member` / `creation_with_non_type` / `mixin_of_non_class` / `undefined_super_member` / `non_type_as_type_argument` / `type_test_with_undefined_name` / `undefined_getter` / `undefined_function` / `extra_positional_arguments` / `const_initialized_with_non_constant_value` / `non_constant_map_key|value` / `non_constant_set_element` / `undefined_named_parameter` / `unchecked_use_of_nullable_value` / `invalid_constant` / `non_type_in_catch_clause`。这些码的**每一条都指向缺失包里的符号或其类型推断的连带结果**，已逐条核对（例：`settings_provider.dart:16:40 extra_positional_arguments` 是 `StateNotifier` 未解析导致 `super(...)` 被当成 0 参构造；`audio_handler.dart:206-210 non_constant_map_key/value` 是 `ProcessingState`/`AudioProcessingState` 未解析导致 `const` map 键非常量；`error_retry.dart:208 unchecked_use_of_nullable_value` 是 `DioException.type` 未解析；`splash_handwriting.dart:216 undefined_named_parameter 'repaint'` 是 `CustomPainter` 未解析）。

**项目自有类出错数：0**（43/43 合格）。**相对路径 import 目标缺失：0**（`uri_does_not_exist` 里没有一条是相对路径）。

**过滤后仍需主代理知悉的真实 lint（不属「项目自有类报错」，为整洁度项，已计入问题清单）：**
| 文件 | 诊断 | 判定 |
|---|---|---|
| `lib/features/lyric/data/lyric_repository.dart:2` | `warning unused_import` `core/net/music_api.dart` | 真·死代码（已记 P3） |
| `lib/features/mv/data/mv_repository.dart:3` | `warning unused_import` `core/net/music_api.dart` | 真·死代码（已记 P3；该文件 0 error，非级联） |
| `lib/features/mv/data/mv_repository.dart:230` | `info prefer_final_locals` | 真（已记 P3） |
| `lib/core/widgets/error_retry.dart:227` | `warning dead_code` | 疑真（在 `errorClassification` 的 `if (error is ApiException)` 链尾，属抽查文件，不在通读范围；未单列问题，交主代理核） |
| `lib/core/widgets/splash_handwriting.dart` / `lib/core/theme/app_theme.dart:41` / `error_logger.dart` 等 | `unused_local_variable` / `const_initialized_with_non_constant_value` | 与缺失包类型推断耦合，暂列噪音，未计入问题 |
| `lib/features/player/data/player_repository.dart:340`、`mv_collection_repository.dart:149`、`rank_repository.dart:112` | `unnecessary_null_comparison` / `unnecessary_cast` | 属抽查文件且受缺失类型影响，未在本视角单列 |

### 逐文件结果（格式：文件 | 原始诊断数（error/warning/info） | `package:` URI 缺失数 | 过滤后项目自有类错误数 | 该文件的诊断码集合）

```
lib/app/bootstrap.dart                              | 8   (8/0/0)   | 2 | 0 | uri_does_not_exist, undefined_identifier, undefined_function
lib/app/di.dart                                       | 5   (5/0/0)   | 1 | 0 | uri_does_not_exist, undefined_function
lib/app/router.dart                                   | 62  (61/1/0)  | 3 | 0 | uri_does_not_exist, undefined_function, non_type_as_type_argument, undefined_identifier, creation_with_non_type, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_method, override_on_non_overriding_member
lib/core/audio/audio_service_bootstrap.dart           | 4   (4/0/0)   | 2 | 0 | uri_does_not_exist, undefined_identifier, undefined_method
lib/core/audio/preferred_quality.dart                  | 3   (3/0/0)   | 1 | 0 | uri_does_not_exist, undefined_identifier
lib/core/image/app_image_cache.dart                   | 11  (9/2/0)   | 2 | 0 | uri_does_not_exist, extends_non_class, undefined_method, extra_positional_arguments, non_type_as_type_argument, undefined_super_member, override_on_non_overriding_member
lib/core/theme/app_theme.dart                         | 134 (133/1/0) | 2 | 0 | uri_does_not_exist, const_initialized_with_non_constant_value, undefined_method, undefined_class, undefined_identifier, creation_with_non_type, non_type_as_type_argument, unused_local_variable
lib/core/theme/settings_provider.dart                 | 47  (47/0/0)  | 3 | 0 | uri_does_not_exist, undefined_function, non_type_as_type_argument, undefined_identifier, extends_non_class, extra_positional_arguments, undefined_class, undefined_method
lib/core/utils/error_logger.dart                      | 20  (20/0/0)  | 3 | 0 | uri_does_not_exist, undefined_class, const_initialized_with_non_constant_value, undefined_method, undefined_identifier
lib/core/utils/friendly_error.dart                    | 4   (4/0/0)   | 1 | 0 | uri_does_not_exist, type_test_with_undefined_name, undefined_getter
lib/core/utils/permission_gate.dart                    | 11  (11/0/0)  | 3 | 0 | uri_does_not_exist, undefined_method, undefined_identifier, undefined_class
lib/core/utils/toast.dart                             | 43  (39/4/0)  | 2 | 0 | uri_does_not_exist, undefined_class, non_type_as_type_argument, undefined_method, undefined_identifier, extends_non_class, mixin_with_non_class_superclass, mixin_of_non_class, undefined_super_member, creation_with_non_type, override_on_non_overriding_member
lib/core/utils/update_checker.dart                    | 10  (10/0/0)  | 3 | 0 | uri_does_not_exist, undefined_class, undefined_method, undefined_identifier, non_type_in_catch_clause
lib/core/widgets/confirm_dialog.dart                  | 16  (16/0/0)  | 1 | 0 | uri_does_not_exist, undefined_class, undefined_identifier, undefined_function
lib/core/widgets/empty_state.dart                     | 24  (23/1/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/core/widgets/error_retry.dart                     | 89  (84/5/0)  | 2 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, creation_with_non_type, type_test_with_undefined_name, unchecked_use_of_nullable_value, invalid_constant, override_on_non_overriding_member, dead_code
lib/core/widgets/gradient_chip.dart                   | 23  (22/1/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/core/widgets/list_skeleton.dart                   | 16  (15/1/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/core/widgets/section_header.dart                  | 21  (20/1/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_identifier, undefined_class, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/core/widgets/shimmer.dart                         | 61  (53/8/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, mixin_with_non_class_superclass, mixin_of_non_class, undefined_method, undefined_super_member, undefined_identifier, override_on_non_overriding_member
lib/core/widgets/song_tile.dart                       | 55  (54/1/0)  | 2 | 0 | uri_does_not_exist, undefined_class, extends_non_class, super_formal_parameter_without_associated_named, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/core/widgets/splash_handwriting.dart              | 70  (64/6/0)  | 1 | 0 | uri_does_not_exist(dart:ui), extends_non_class, super_formal_parameter_without_associated_named, undefined_class, mixin_with_non_class_superclass, mixin_of_non_class, undefined_super_member, undefined_method, undefined_identifier, creation_with_non_type, const_initialized_with_non_constant_value, undefined_named_parameter, override_on_non_overriding_member
lib/core/widgets/splash_screen.dart                    | 9   (8/1/0)   | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, override_on_non_overriding_member
lib/features/home/data/home_repository.dart           | 8   (8/0/0)   | 3 | 0 | uri_does_not_exist, undefined_function, undefined_method
lib/features/home/data/models.dart                     | 0   (0/0/0)   | 0 | 0 | No issues found!
lib/features/home/presentation/home_page.dart          | 251 (239/12/0)| 4 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_method, creation_with_non_type, undefined_identifier, mixin_with_non_class_superclass, mixin_of_non_class, undefined_super_member, override_on_non_overriding_member
lib/features/lyric/data/krc_decoder.dart               | 2   (2/0/0)   | 1 | 0 | uri_does_not_exist, creation_with_non_type
lib/features/lyric/data/krc_parser.dart                | 2   (2/0/0)   | 1 | 0 | uri_does_not_exist, undefined_method
lib/features/lyric/data/lyric_repository.dart          | 8   (7/1/0)   | 1 | 0 | uri_does_not_exist, undefined_method, unused_import(真·死代码)
lib/features/lyric/presentation/lyric_view.dart        | 85  (78/7/0)  | 1 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_method, undefined_super_member, undefined_identifier, non_type_as_type_argument, type_test_with_undefined_name, creation_with_non_type, override_on_non_overriding_member, unused_element_parameter
lib/features/mv/data/mv_collection_repository.dart     | 5   (4/1/0)   | 2 | 0 | uri_does_not_exist, undefined_method, undefined_function, unnecessary_null_comparison
lib/features/mv/data/mv_repository.dart                | 2   (0/1/1)   | 0 | 0 | unused_import(真·死代码), prefer_final_locals
lib/features/mv/mv_provider.dart                       | 5   (5/0/0)   | 1 | 0 | uri_does_not_exist, undefined_function, undefined_identifier
lib/features/mv/presentation/mv_player_page.dart       | 251 (246/5/0)| 4 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_super_member, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
lib/features/player/data/audio_handler.dart             | 114 (104/10/0)| 5 | 0 | uri_does_not_exist, mixin_with_non_class_superclass, mixin_of_non_class, undefined_class, undefined_identifier, undefined_method, non_type_as_type_argument, non_constant_set_element, non_constant_map_key, non_constant_map_value, type_test_with_undefined_name, undefined_getter, undefined_super_member, override_on_non_overriding_member
lib/features/player/data/player_repository.dart        | 8   (7/1/0)   | 2 | 0 | uri_does_not_exist, undefined_class, undefined_method, unnecessary_null_comparison
lib/features/player/play_helper.dart                    | 3   (3/0/0)   | 1 | 0 | uri_does_not_exist, undefined_class, undefined_function
lib/features/player/player_provider.dart                | 33  (33/0/0)  | 3 | 0 | uri_does_not_exist, undefined_function, non_type_as_type_argument, undefined_identifier
lib/features/player/presentation/full_player_page.dart  | 329 (310/19/0)| 5 | 0 | uri_does_not_exist, undefined_identifier, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_method, creation_with_non_type, mixin_with_non_class_superclass, mixin_of_non_class, undefined_super_member, override_on_non_overriding_member
lib/features/player/presentation/mini_player.dart       | 78  (74/4/0)  | 4 | 0 | uri_does_not_exist(dart:ui), extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_identifier, undefined_method, non_type_as_type_argument, creation_with_non_type, override_on_non_overriding_member
lib/features/player/presentation/queue_sheet.dart       | 61  (59/2/0)  | 3 | 0 | uri_does_not_exist, undefined_class, undefined_function, creation_with_non_type, extends_non_class, super_formal_parameter_without_associated_named, undefined_identifier, undefined_method, override_on_non_overriding_member
lib/features/rank/data/rank_repository.dart             | 3   (2/1/0)   | 1 | 0 | uri_does_not_exist, undefined_function, unnecessary_cast
lib/features/rank/presentation/rank_detail_page.dart   | 71  (68/3/0)  | 4 | 0 | uri_does_not_exist, extends_non_class, super_formal_parameter_without_associated_named, undefined_class, undefined_super_member, undefined_identifier, undefined_method, creation_with_non_type, override_on_non_overriding_member
```

**analyze 结论**：43/43 文件均已单独执行；过滤 Flutter/三方包缺失噪音后，**项目自有类 0 错误**（合格）。相对路径 import 目标缺失 0；`home/data/models.dart` 是唯一 0 诊断文件，`mv/data/mv_repository.dart` 是唯一 0 error 文件。真实 lint 仅 2 条 `unused_import` + 1 条 `prefer_final_locals`（已入问题清单）+ 1 条 `dead_code`（抽查文件，交主代理复核）。

---

