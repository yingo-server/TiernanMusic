# 第4批·审查②：功能链路回归（播放/歌词/搜索/歌单/评论）

- 基线：`6e46611`
- 范围：播放器（audio_handler / player_repository / models / provider / play_helper）、歌词（krc_parser / krc_decoder / lyric_repository / lyric_view）、搜索、歌单、评论、首页、MV
- 性质：只读审查。不含修复建议，只记录 问题 + 位置 + 依据 + 影响。

---

## 一、播放链路

### lib/features/player/data/audio_handler.dart:206-221 队列替换时 `_loading` 被无条件下调，旧请求仍在飞行
- 级别：P1
- 依据：
  ```dart
  Future<void> playQueue(List<Song> songs, int index) async {
    ...
    _playToken++;          // 作废旧请求
    _loading = false;      // ← 直接把闸门打开
    _pendingIndex = null;
    _songs..clear()..addAll(songs);
    await _playAt(index);
  }
  ```
  旧 `_playAt` 的 `finally`（373-380 行）**无条件**执行 `_loading = false`，且会取走 `_pendingIndex`。
- 影响：`playQueue` 把 `_loading` 置 false 后，新的 `_playAt` 立即通过 261 行闸门并置 true；随后旧请求的 `finally` 再把它置 false。此后 UI 再次点歌时闸门是开的，于是两个 `_playAt` 真正并发跑（各自 `_player.setAudioSource` / `_player.play()`）。表现为：连点两首歌后停顿几百毫秒才出声、或先播 A 再被 B 打断、或播放键态与真实音频不一致。`_playToken` 只保证「不写 _songs」，**不保证音频引擎不被旧请求改写**。

### lib/features/player/data/audio_handler.dart:322-334 token 检查在 await 之前，`setAudioSource` 仍可能后完成并覆盖新源
- 级别：P1
- 依据：
  ```dart
  final result = await _repository.resolveUrl(detailed);
  if (token != _playToken) return;
  ...
  await _player.setAudioSource(AudioSource.uri(Uri.parse(result.url), tag: mediaItem.value));
  }
  if (token != _playToken) return;
  await _player.play();
  ```
- 影响：`setAudioSource` 是不可取消的异步调用。旧请求在第 328 行进入后，用户点新歌 → 新 `_playAt` 也调用 `setAudioSource`；若旧调用后完成，**最终装载的是旧歌的 URL**，而 `_index` / `mediaItem` 已是新歌。用户看到封面/歌名是新歌、听到的是上一首（或直接无声）。同一问题存在于离线分支 311-313 行。

### lib/features/player/data/audio_handler.dart:309-310 `copyWith(localPath: null)` 无法清除 localPath（与注释意图相反）
- 级别：P1
- 依据：
  ```dart
  // 清掉失效的 localPath，防止下次再走坏源（PL-04 同源）
  _songs[index] = detailed.copyWith(quality: result.quality, localPath: null);
  ```
  `Song.copyWith`（models.dart:84-106）实现为 `localPath: localPath ?? this.localPath`。
- 影响：失效的本地路径**永远清不掉**。每次播放这首歌都会重新 `File(local).existsSync()` 失败 → 先 `setAudioSource(file://)` 抛异常 → 再走在线解析，多一次失败开销与一次错误态闪烁；若文件是被「移动」而非删除且系统仍返回旧 URI，会反复进入该分支。注释声称的语义与实际行为完全相反。

### lib/features/player/data/audio_handler.dart:337-371 失败跳歌的 `_failureStreak` 与队列长度比较混乱，且会被成功播放重置为 0
- 级别：P2
- 依据：
  ```dart
  _failureStreak++;
  final canAdvance = token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;
  if (canAdvance) { await skipToNext(); } else { _failureStreak = 0; }
  ```
  `skipToNext()` 内部又走 `_playAt` → 成功时 333 行 `_failureStreak = 0`。
- 影响：只要偶尔有一首解析成功，计数就被清零，「整队全挂」时可绕环重试远多于 `_songs.length` 次；反之若队列首尾相接（LoopMode.all），也只有在连续失败恰好 N 次后才停。极端场景（整队离线失效）会连续发起 5 次网络解析 × 5 档音质请求，用户看到长时间转圈。

### lib/features/player/data/audio_handler.dart:341-350 `_pendingSongIndex` 只在 playQueue/playSong 里清，队列被 `skipToNext` 改变后仍指向旧下标
- 级别：P2
- 依据：`playQueue`（210）与 `playSong`（227）清 `_pendingSongIndex`，`skipToNext`/`skipToPrevious` 不清；`retryPendingPlayback()`（395-400）直接用旧 `idx` 调 `_playAt(idx)`。
- 影响：命中 20028 → 弹验证页 → 用户先点「下一首」听别的 → 验证完成后自动跳回旧歌（或队列已被替换时下标越界/指向另一首歌）。属于「验证后跳错歌」，与 PLY-03 想解决的同类问题只覆盖了队列替换一条路径。

### lib/features/player/data/audio_handler.dart:315-331 新歌开始解析到 resolve 返回之间，试听标记仍沿用上一首
- 级别：P2
- 依据：在线分支只在 324-326 行 resolve 成功后写 `_isPreview`；`_playAt` 开头没有重置。离线分支在 285-286 行显式置 false。
- 影响：上一首是 VIP 试听曲、这一首是完整曲时，从点歌到解析完成（首次可达数秒）期间 UI 一直显示「60 秒试听」角标/进度提示；反之从完整曲切到试听曲时角标延迟出现。

### lib/features/player/data/audio_handler.dart:60-62 `completed` 时无条件 skipToNext，末曲顺序播放时进入空转
- 级别：P2
- 依据：
  ```dart
  p.processingStateStream.listen((state) {
    if (state == ProcessingState.completed) skipToNext();
  });
  ```
  `skipToNext`（440-447）在最后一首且非 LoopMode.all 时 `return;`。
- 影响：顺序播放到最后一首结束 → `skipToNext` 直接返回，`processingState` 保持 completed、`playing` 可能仍为 true，UI 停在高亮但无声的「播放中」态，需用户手动点暂停；同时 `_playedController` 不再触发，最近播放停在上一首。

### lib/features/player/data/audio_handler.dart:353 `_errorController.add('播放失败：$e')` 直接暴露底层异常串
- 级别：P2
- 依据：`_errorController.add('播放失败：$e');`，该流由 `playerErrorProvider` 直连 UI（player_provider.dart:51-52）。
- 影响：用户可能看到 `PlayerException(...)`, `DioException [bad response] ... uri=https://...&accesskey=...` 之类内部信息（含带签名的 URL / accesskey），既是体验问题也是信息泄露面。

### lib/features/player/data/audio_handler.dart:279-281 每首歌都在调用线程做同步文件存在性检查
- 级别：P2
- 依据：
  ```dart
  final localUsable = local != null && local.isNotEmpty &&
      (local.startsWith('content://') || File(local).existsSync());
  ```
- 影响：`existsSync` 在主 isolate 上执行；SD 卡/外置存储失效时 stat 可能阻塞几十到数百毫秒，切歌瞬间掉帧。`content://` 分支则完全不做可用性探测，直接进离线分支靠异常兜底。

### lib/features/player/data/audio_handler.dart:470 `_randomIndex` 每次现算，无历史，短队列会立刻重复
- 级别：P2
- 依据：`List.generate(_songs.length, (i) => i)..remove(_index); candidates.shuffle(); return candidates.first;`
- 影响：随机播放只排除「当前曲」，2 首歌的队列会永远 A↔B 交替（无法体现随机）；且 `skipToPrevious` 在随机模式下走的是 `_index - 1` 的线性下标，前进/后退不对称，用户按「上一首」听到的不是刚才那首。

### lib/features/player/data/player_repository.dart:210-220 `_qualityFromBitrate` 高位机读不出 super/high，且 `fromString` 的默认值 q128 与「未知」不可区分
- 级别：P2
- 依据：
  ```dart
  final q = AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality);
  if (q != AudioQuality.q128) return q;
  if (r.bitrate >= 500000) return AudioQuality.flac;
  if (r.bitrate >= 192000) return AudioQuality.high;
  if (r.bitrate >= 96000) return AudioQuality.q320;
  return AudioQuality.q128;
  ```
  `fromString`（models.dart:32-49）对 `''` / 未知一律返回 `q128`。
- 影响：`extName` 缺失且服务端返回 128 时无法与「字段缺失」区分，只能靠 bitrate 兜底；而 bitrate ≥ 500000 一律判 flac，臻品母带/Hi-Res（常见 900k~2M+ bps）会被显示成「无损」。实际音质流（`actualQualityProvider`）因此长期偏低/失真，用户会认为「设置里选了 Hi-Res 但显示无损」。

### lib/features/player/data/player_repository.dart:230-268 `_resolveViaKapi` 的降级从 `preferred` 起「只降不升」，且 `album_id`/`album_audio_id` 以字符串原样传空值
- 级别：P2
- 依据：
  ```dart
  final start = preferred ?? song.quality;
  var startIndex = order.indexOf(start);
  if (startIndex < 0) startIndex = order.length - 1;
  ```
  且 `'album_id': song.albumId, 'album_audio_id': song.albumAudioId` 未做空值剔除。
- 影响：1) 当 `preferred` 是 super 而歌曲只有 128 时，要连打 4 次失败请求才拿到 128，首次播放明显变慢（每档都是一次完整 HTTP + dfid 前置）。2) 从搜索/首页来的 Song 若 `albumId` 为空串，kapi 收到 `album_id=` 而不是省略该参数，接口可能返回 errcode 而非按 hash 兜底，直接落进「没有可尝试的播放音质」。

### lib/features/player/data/player_repository.dart:5-9, 275-277 `isPreview` 双重判定口径不一致（直连看 `result.isPreview`，kapi 看 `priv_status==0 || hash_offset is Map`）
- 级别：P2
- 依据：`_resolveViaKapi` 中
  ```dart
  isPreview: _int(data['priv_status']) == 0 || data['hash_offset'] is Map,
  ```
- 影响：`priv_status` 的 0 值语义未在仓库任何地方校验（其余权益判定统一走 `privilege & 8` / `pay_type`），若 0 表示「免费可播」而非「试听」，会把完整曲标成 60 秒试听，播放页出现误导性的试听进度与升级引导。同时直连路径的 `result.isPreview` 与 kapi 路径口径不同，同曲换路径会得到不同提示。

### lib/features/player/data/player_repository.dart:36-56 `ensureDfid` 用「延时 300ms + 递归」做互斥
- 级别：P2
- 依据：
  ```dart
  if (_registering) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return ensureDfid();
  }
  ```
- 影响：不是真正的等待者队列，只是一次轮询重试；注册接口慢于 300ms 时会叠加多次递归与多次 `/register/dev` 之外的重复读盘，且递归没有上限保护。首播阶段若同时有播放与下载两条链路调用，可能注册多次、覆盖 dfid。

### lib/features/player/data/models.dart:84-106 `copyWith` 无法把 nullable 字段置 null
- 级别：P1
- 依据：`localPath: localPath ?? this.localPath`（其余字段同理，均为非空参数）。
- 影响：这是 audio_handler.dart:310 那条「清理失效本地源」失效的根因；任何「撤销/清除」语义的调用点（清 localPath、清 cover）都会静默变成 no-op，且编译器不报错。后续下载删除、重新下载等链路只要用 copyWith 清除标记，都会留下幽灵状态。

### lib/features/player/data/models.dart:116-210 `Song.fromJson` 的时长单位靠字段白名单硬编码，且 `Duration(seconds: raw.round())` 会四舍五入丢失小数秒
- 级别：P2
- 依据：
  ```dart
  for (final key in ['duration', 'Duration', 'time_length']) { ... millis: false }
  for (final key in ['timelength', 'timelen', 'timeLength']) { ... millis: true }
  if (info['duration'] != null) setDuration(info['duration'], millis: true);
  ```
- 影响：`/privilege/lite` 的 `duration` 若是毫秒（部署版字段口径变动），会被当成秒 → 时长变成 1000 倍（进度条与 MediaItem.duration 全错，通知栏时长异常）。另外 `raw.round()` 对 3.5 秒这类值会偏移前后 1 秒，歌词首页定位与进度显示有可见误差。字段口径只在本文件注释里「实测」声明，没有任何运行时校验或交叉校验（如与 `time_length` 比对）。

### lib/features/player/play_helper.dart:28,43,58,75 所有入口都用 `Duration(seconds: ...)`，未校验上游单位
- 级别：P2
- 依据：`duration: Duration(seconds: s.duration)`（HomeSong / PlaylistSong 均为 int）。
- 影响：一旦 `HomeSong.duration` / `PlaylistSong.duration` 取自毫秒字段（见 home/models.dart 与 playlist 的解析），队列里所有歌时长会放大 1000 倍；`_emitQueue` 把这些错误时长写进 `MediaItem.duration`，系统媒体通知与锁屏进度条同步出错。

### lib/features/player/player_provider.dart:155-168 `recentPlayRecorderProvider` 是副作用型 Provider，且写盘不 await
- 级别：P2
- 依据：
  ```dart
  final recentPlayRecorderProvider = Provider<void>((ref) {
    final sub = ref.watch(audioHandlerProvider).onSongStarted.listen((song) {
      ...
      RecentPlayStore.add(...).then((_) => RecentPlayStore.notifyListeners());
    });
  ```
- 影响：无人 `watch` 时该 Provider 不会建立订阅，「最近播放」静默失效；`add` 失败（配额/IO）没有任何 catch，异常进 zone 变成未捕获错误。同一首歌自动重试会重复写入同一 hash 的多条记录（去重依赖 RecentPlayStore 内部，本文件未体现）。

