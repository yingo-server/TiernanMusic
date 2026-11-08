# v4.0.2 复核①：播放列表/队列深查（只读）

基线：当前工作区（含主代理 V402-P1/P3 修复）。方法：逐行通读五个目标文件 + verification_listener.dart（retryPendingPlayback 唯一调用点）+ QUALITY_STANDARD.md（33 条）+ docs/v400_order.md。未 grep 筛源码、未改代码、未装依赖。

## 1. V402-P1（`_pendingSongHash` 挂起→重试）是否闭环 —— **通过（附 2 条边界瑕疵）**

机制（audio_handler.dart）：
- `_playAt` catch 命中 `needsVerification`：`_pendingSongHash = _songs[index].hash`（越界置 `''`），发 `_verificationController` + `_errorController`，置 error 态，**return 不跳歌** ✓（不触发失败连跳，正确）。
- `retryPendingPlayback()`：先取走并清空 hash；空/null 直接 return；按 hash 在**当前队列** `indexWhere` 重定位；找不到则 debugPrint 留痕丢弃，不按下标盲播（第 14/16 条）✓。
- 清理点核对：`stop()`、`onNotificationDeleted()`、`playQueue()`、`playSong()` 均清 `_pendingSongHash` ✓。`pause()` 不清——验证弹窗期间用户暂停，验证通过后仍能重试，语义合理。

三种边界：
- **hash 为空**：越界置 `''` 或歌曲本身 hash 为空 → retry 显式丢弃 ✓。
- **队列含重复 hash**：`indexWhere` 取第一个命中。因 `Song.==` 只比 hash（models.dart），重复项内容等同，播第一个与用户点击目标一致 → 通过。注：playQueue 不去重，queue_sheet 的 isCurrent 也会把同 hash 多行同时标亮（V39-AUX-09 只防了空 hash 误判，未防重复行全亮）——记录为观察项。
- **队列被整体替换**：playQueue 前置清空 pendingHash；若验证弹窗仍开着（listener 在 await Navigator），成功后 retry 拿到 null 直接 return，新队列已在播 → 无错播 ✓。残余场景见问题 P2-5。

## 2. V402-P3（世代前置）是否引入新竞态 —— **通过（闸门成对性保持，见 P2-2 残留）**

- playQueue/playSong 把 `++_playToken` 前置到 `ensureEngineReady()` 之前，await 后 `token != _playToken` 即退出 → 首次引擎初始化窗口内第二次请求能正确作废第一次 ✓。
- `_loading` 闸门：只有 `_playAt` 持有者置 true，且**只在其 finally** 置 false（playQueue 不再无条件开闸，F4-14 保留）→ 第 19 条成对性成立 ✓。
- `_pendingIndex` 交接：旧 `_playAt` finally 取走 pending 并 `Future.microtask` 交给下一轮，被作废请求同样负责放行 ✓。pause/stop/onNotificationDeleted/playQueue 均清 `_pendingIndex` ✓。
- 残留：finally 里调度出的 `Future.microtask(() => _playAt(pending))` **不带世代标记**，见问题 P2-2。

## 3. catch 世代守卫 / canAdvance / 失败跳过 / completed 语义

- canAdvance = `token == _playToken && _songs.length > 1 && _failureStreak < _songs.length`：三条件齐备，单曲队列不跳、连续失败有界（第 25 条）✓；成功后 `_failureStreak = 0`，不可推进也复位 ✓。
- 失败分支 `_pauseEngineOnly()` 不作废世代（F-3），catch 内先查 `token != _playToken` 再报错跳歌 ✓ —— **但 20028 分支在世代检查之前**，见 P2-1。
- completed → `onPlaybackCompleted(_lastPlayUrl)` 永久缓存 + `skipToNext()`：`_lastPlayUrl` 在各分支均于 token 校验之后写入 ✓；LoopMode.one 由 just_audio 内部循环、completed 不触发，语义正确 ✓。**试听 URL 也满足 startsWith('http') 被永久缓存**（P3-4）；60s 试听完整播完即自动切下一首（语义记录：试听曲会逐首 60 秒快进整队列，是否符合预期属产品裁定）。

## 4. retryPendingPlayback 重复重试 —— **通过**

唯一调用点 `verification_listener.dart:54`；`_handling` 布尔在入队/finally 双向防护，broadcast 流多事件不会并发弹两个验证页；retry 内先清 `_pendingSongHash`，天然幂等。无重复重试路径。

## 5. 循环/随机/单曲/空队列/shuffle 一致性

- skipToNext：shuffle 走 `_randomIndex()`（length≤1 返回当前 index；否则排除自身）✓；末尾 LoopMode.all 回 0、off 停止 ✓。
- skipToPrevious：>3s 回开头；index 0 且 <3s 时 `_playAt(0)` 整首重载（重新 setAudioSource，非 seek(0)）——多一次网络装载，轻微（不列级）。
- 空队列：skipToNext/Previous 均 isEmpty 早退 ✓；但 `playQueue(空列表)` 见 P2-3。

## 6. 订阅/Controller/Timer 对称释放 —— **通过**

handler 内 7 个 broadcast StreamController 与 2 个 player 流订阅均为应用生命周期单例（audioHandlerProvider 常驻），无中途创建/销毁错配；无 Timer。recentPlayRecorderProvider 用 `ref.onDispose(sub.cancel)` 对称 ✓。

---

## 问题清单（P0/P1/P2）

### P2-1 catch 的 20028 分支缺世代守卫（audio_handler.dart `_playAt` catch）
- 事实：`if (api != null && api.needsVerification)` 分支位于 `if (token != _playToken) return;` **之前**，且不校验 token 即写 `_pendingSongHash` 并发 `_verificationController`。
- 违反：第 18 条（异步结果必须校验世代）。
- 用户可见后果：装载中用户暂停/换歌作废世代后，旧请求的 20028 迟到返回 → 验证页突然弹出、且把已作废歌曲记为待重试，验证通过后跳播旧歌打断当前播放。
- 建议修法：20028 分支入口先 `if (token != _playToken) return;` 再挂 pendingHash/发事件。
- 证据等级：实锤。

### P2-2 finally 交接的 microtask `_playAt(pending)` 不带世代（audio_handler.dart `_playAt` finally）
- 事实：`Future.microtask(() => _playAt(pending))` 无 token 参数；若旧请求 finally 先于 playQueue 执行（pending 已捕获），随后队列整体替换，该 microtask 在新队列上按旧下标 `_playAt` 并 `++_playToken` 作废新请求。
- 违反：第 18/19 条（交接的请求同样需要世代归属）。
- 用户可见后果：换队列后可能自动多播/错播一首旧排队歌曲，且瞬间打断刚点的队列装载（时序依赖，概率低但存在）。
- 建议修法：microtask 闭包捕获发出时的 `_playToken`，`_playAt` 内先比对不一致即丢弃 pending。
- 证据等级：实锤（代码路径可完整推演，未真机复现）。

### P2-3 `playQueue(空列表)` 不发 currentSong/mediaItem 空事件（audio_handler.dart `playQueue`）
- 事实：清空 `_songs` 后只 `_emitQueue()`；越界时 `_playAt` 静默 return，`_index` 未重置、`_emitMediaItem()` 未调用 → `currentSongStream`/`mediaItem` 残留上一首。
- 违反：第 16 条（空与缺失语义分离）、第 5 条（状态单一来源）。
- 用户可见后果：播空队列后通知栏/迷你播放器仍显示上一首歌，点播放无反应且无提示。
- 建议修法：playQueue 清空后若 `songs.isEmpty` 则 `_index = -1; _emitMediaItem();` 并置 idle 态。
- 证据等级：实锤。

### P3-4 试听 URL 也被永久缓存（audio_handler.dart completed 回调）
- 事实：`_lastPlayUrl` 在 preview 分支同样写入 result.url，completed 时 `onPlaybackCompleted` 不区分 isPreview。
- 后果：60 秒试听片段被当作完整资源永久缓存，磁盘缓存混入无效整曲替身。
- 建议修法：仅 `_isPreview == false` 时写 `_lastPlayUrl`。
- 证据等级：实锤。

### P3-5 验证挂起期间手动 skipToNext 不清 `_pendingSongHash`
- 事实：skipToNext 不触碰 pendingHash；验证通过后 retry 会把用户拉回验证前的旧歌。
- 后果：用户已手动切歌听新歌，验证完成瞬间被打断跳回旧歌。
- 建议修法：skipToNext/skipToPrevious 入口清 `_pendingSongHash`（视作放弃待重试）。
- 证据等级：实锤（路径确定，属语义取舍，定 P3）。

### 观察项（不计级）
- completed→skipToNext 使试听曲 60 秒即自动切下一首，整队列逐首试听快进（产品语义，需用户裁定）。
- 队列允许重复 hash：queue_sheet 中重复行会同时标亮 isCurrent。
- skipToPrevious 在 index 0 且 <3s 时整首重载而非 seek(0)。

## 统计
- 实锤 4（P2-1/P2-2/P2-3/P3-4）+ 实锤语义取舍 1（P3-5）；P0：0；P1：0。
- 通过项：V402-P1 主体闭环、V402-P3 世代前置无新竞态（闸门成对）、retryPendingPlayback 无重复重试、订阅/Controller 释放对称、循环/随机/单曲边界、completed 缓存的 token 守卫 —— 6 项。
- 最重一条：P2-1（20028 分支缺世代守卫 → 假验证弹窗 + 打断当前播放）。
