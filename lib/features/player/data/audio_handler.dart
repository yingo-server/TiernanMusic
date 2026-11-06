import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/audio/audio_service_bootstrap.dart';
import 'models.dart';
import 'player_repository.dart';

/// 汀澜音乐后台音频处理器。
///
/// 封装 just_audio [AudioPlayer]，向系统广播 mediaItem / playbackState，
/// 并维护歌曲队列与播放逻辑（含音质解析与失败自动降级）。
class TiernanAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  TiernanAudioHandler(this._repository);

  final PlayerRepository _repository;

  /// 延迟创建：启动期不实例化 AudioPlayer / AudioSession，
  /// 避免任何平台通道异常导致首屏卡死。
  ///
  /// 关键：**必须先等 just_audio_background 初始化完成**再创建 AudioPlayer，
  /// 否则会抛 LateInitializationError: _audioHandler（真机实测必现）。
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance!;

  bool _initialized = false;

  /// 音频引擎是否可用（just_audio_background 已就绪且 AudioPlayer 已创建）。
  bool get isEngineReady => _initialized;

  /// 引擎初始化失败的原因（供 UI 展示；null = 未失败）
  String? engineError;

  /// 等待音频后台服务就绪；失败返回 false（调用方给友好错误，不要播放）。
  Future<bool> ensureEngineReady() async {
    if (_initialized) return true;
    final ok = await AudioServiceBootstrap.ensureReady();
    if (!ok) {
      // 记录失败原因并同步播放态，避免 UI 停留在「播放中」假象
      engineError ??= '音频服务未就绪，请稍后重试';
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ));
      _errorController.add(engineError!);
      return false;
    }
    if (_initialized) return true;
    _initialized = true;
    final p = _playerInstance = AudioPlayer();
    // 通知 UI：引擎已就绪，播放态流可以接上了
    _engineReadyController.add(p);
    p.playbackEventStream.listen(_broadcastState);
    p.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) skipToNext();
    });
    _configureSession();
    return true;
  }

  /// 兼容旧调用点：仅在引擎已就绪时返回 player，否则 null。
  AudioPlayer? get _playerOrNull => _playerInstance;

  final List<Song> _songs = [];
  final _currentSongController = StreamController<Song?>.broadcast();
  final _actualQualityController =
      StreamController<AudioQuality?>.broadcast();

  /// 播放错误（引擎未就绪 / 权益不足 / 验证失败等），供 UI 展示
  final _errorController = StreamController<String>.broadcast();

  /// 播放错误事件流
  Stream<String> get errors => _errorController.stream;

  /// 引擎就绪事件流。
  ///
  /// 关键：AudioPlayer 是在首次播放时才创建的（惰性），
  /// 若 UI 只依赖一次性 getter 读取 player，会永久拿到缓存的 null，
  /// 导致进度条/播放键/时长/随机/循环全部不更新。
  /// 这里用广播流把「引擎何时可用」变成可观察事件。
  final _engineReadyController = StreamController<AudioPlayer?>.broadcast();

  /// 引擎就绪事件流（首次为 null，引擎就绪后推送真实 player）
  Stream<AudioPlayer?> get engineReady => _engineReadyController.stream;

  /// 是否 60 秒试听（VIP/付费曲走官方免费试听通道时置 true）
  final _previewController = StreamController<bool>.broadcast();
  Stream<bool> get previewStream => _previewController.stream;
  bool _isPreview = false;
  bool get isPreview => _isPreview;

  /// 人机验证事件（播放命中 20028 时发出）
  final _verificationController =
      StreamController<ApiException>.broadcast();

  Stream<ApiException> get verificationRequired => _verificationController.stream;

  /// 播放真正开始（setAudioSource 成功且 play() 已调用）时发出，
  /// 用于最近播放记录（自动切歌 / 手动上下一首同样覆盖）。
  final _playedController = StreamController<Song>.broadcast();
  Stream<Song> get onSongStarted => _playedController.stream;

  int _index = -1;
  bool _loading = false;
  int _playToken = 0;

  /// 对外暴露的 player：未就绪时返回 null（UI 需判空）。
  AudioPlayer? get player => _playerOrNull;

  /// 当前播放歌曲流。
  Stream<Song?> get currentSongStream => _currentSongController.stream;

  /// 实际播放音质流（可能因降级低于期望音质）。
  Stream<AudioQuality?> get actualQualityStream =>
      _actualQualityController.stream;

  List<Song> get songs => List.unmodifiable(_songs);
  int get currentIndex => _index;
  Song? get currentSong =>
      (_index >= 0 && _index < _songs.length) ? _songs[_index] : null;

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}
  }

  void _broadcastState(PlaybackEvent event) {
    final p = _playerOrNull;
    if (p == null) return;
    final playing = p.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[p.processingState]!,
      playing: playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
      queueIndex: _index,
      shuffleMode: p.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: switch (p.loopMode) {
        LoopMode.off => AudioServiceRepeatMode.none,
        LoopMode.all => AudioServiceRepeatMode.all,
        LoopMode.one => AudioServiceRepeatMode.one,
      },
    ));
  }

  void _emitMediaItem() {
    final song = currentSong;
    _currentSongController.add(song);
    if (song == null) {
      mediaItem.add(null);
      return;
    }
    mediaItem.add(MediaItem(
      id: song.hash,
      title: song.name,
      artist: song.artist,
      duration: song.duration > Duration.zero ? song.duration : null,
      artUri: song.cover.isNotEmpty ? Uri.tryParse(song.cover) : null,
      extras: {
        'albumId': song.albumId,
        'albumAudioId': song.albumAudioId,
      },
    ));
  }

  void _emitQueue() {
    queue.add(_songs
        .map((s) => MediaItem(
              id: s.hash,
              title: s.name,
              artist: s.artist,
              duration: s.duration > Duration.zero ? s.duration : null,
              artUri: s.cover.isNotEmpty ? Uri.tryParse(s.cover) : null,
            ))
        .toList());
  }

  /// 设置队列并从 [index] 开始播放。
  Future<void> playQueue(List<Song> songs, int index) async {
    if (!await ensureEngineReady()) return;
    // 新的播放请求会清掉 20028 挂起状态，避免验证后跳回旧歌
    _pendingSongIndex = null;
    // PLY-03（审查③）：队列被整体替换时**立即作废在途请求**——
    // 旧 _playAt 恢复后按旧 index 写 _songs 会污染新队列（越界或覆盖错歌）。
    // F4-14（审查②-B，P0）：队列替换时**不得**无条件 `_loading = false`。
    // 旧 _playAt 仍在飞行，提前开闸会让新请求与旧请求真正并发
    // （QUALITY_STANDARD 第 19 条：闸门必须由持有者成对开关）。
    // 这里只作废旧请求的世代标记并把新下标排队，闸门由旧请求的 finally 释放，
    // 释放后立即播放排队中的新下标。
    _playToken++;
    // V3-04（第5批复核②，P2）：换队列必须重置连续失败计数（第 18 条）——
    // 旧队列累积的 streak 若接近旧队列长度，新队列第一首失败就会触发「停止」。
    _failureStreak = 0;
    _pendingIndex = null;
    _songs
      ..clear()
      ..addAll(songs);
    _emitQueue();
    await _playAt(index);
  }

  /// 播放单曲（追加到队列或替换当前位置）。
  Future<void> playSong(Song song) async {
    if (!await ensureEngineReady()) return;
    // 新的播放请求会清掉 20028 挂起状态，避免验证后跳回旧歌
    _pendingSongIndex = null;
    final existing = _songs.indexOf(song);
    if (existing >= 0) {
      // PLY-17（审查③）：Song== 只比 hash。若传入歌带 localPath（下载页入口）
      // 而队列里是同 hash 的在线版本，用本地源覆盖队列项，否则离线播放失效。
      if ((song.localPath?.isNotEmpty ?? false) &&
          (_songs[existing].localPath?.isNotEmpty != true)) {
        _songs[existing] =
            _songs[existing].copyWith(localPath: song.localPath);
      }
      await _playAt(existing);
      return;
    }
    final insertAt = _index + 1;
    _songs.insert(insertAt > _songs.length ? _songs.length : insertAt, song);
    _emitQueue();
    await _playAt(_songs.indexOf(song));
  }

  /// 加载中又收到的新播放请求（排队，保证"点了就有声音"）
  int? _pendingIndex;
  int _failureStreak = 0;

  Future<void> _playAt(int index) async {
    if (!await ensureEngineReady()) {
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
        errorMessage: '音频服务启动失败，请重启应用',
      ));
      return;
    }
    if (index < 0 || index >= _songs.length) return;

    if (_loading) {
      // 不丢弃请求：记录待播下标，当前流程结束后立刻播它
      _pendingIndex = index;
      return;
    }

    _index = index;
    _emitMediaItem();
    final token = ++_playToken;
    final song = _songs[index];
    _loading = true;
    // F4-16（审查②-B，P2）：新歌一开始解析就重置试听标记，
    // 否则上一首的「60 秒试听」角标会挂到这首完整曲上（第 18 条：世代切换即重置派生状态）。
    if (_isPreview) {
      _isPreview = false;
      _previewController.add(false);
    }
    try {
      // 先广播缓冲状态
      _broadcastState(_player.playbackEvent);

      // PLY-06（审查③）：本地资源可用的歌**先走离线**，不做网络补全——
      // fetchDetail 要等 20-30s 超时，飞行模式下离线播放基本不可用。
      final local = song.localPath;
      final localUsable = local != null &&
          local.isNotEmpty &&
          (local.startsWith('content://') || File(local).existsSync());

      if (localUsable) {
        // ---- 离线分支 ----
        _isPreview = false;
        _previewController.add(false);
        try {
          final applied = await _applySource(
            token,
            AudioSource.uri(
              local.startsWith('content://')
                  ? Uri.parse(local)
                  : Uri.file(local),
              tag: mediaItem.value,
            ),
          );
          if (!applied) return;
        } on Exception {
          // PL-01（审查③）：本地文件失效（被删/迁移/URI 失效）→
          // **同曲回退在线解析**，而不是抛给外层 catch 跳下一首。
          final detailed = await _repository.fetchDetail(song);
          if (token != _playToken) return;
          _songs[index] = detailed;
          _emitMediaItem();
          final result = await _repository.resolveUrl(detailed);
          if (token != _playToken) return;
          _actualQualityController.add(result.quality);
          _isPreview = result.isPreview;
          _previewController.add(_isPreview);
          // 清掉失效的 localPath，防止下次再走坏源（PL-04 同源）
          // F4-15（审查②-B，P1）：`localPath: null` 在原 copyWith 中是空操作，
          // 必须走显式清除标记。
          _songs[index] = detailed.copyWith(
              quality: result.quality, clearLocalPath: true);
          final applied = await _applySource(
            token,
            AudioSource.uri(Uri.parse(result.url), tag: mediaItem.value),
          );
          if (!applied) return;
        }
      } else {
        // ---- 在线分支：补全详情 + 解析 URL ----
        final detailed = await _repository.fetchDetail(song);
        if (token != _playToken) return;
        _songs[index] = detailed;
        _emitMediaItem();

        final result = await _repository.resolveUrl(detailed);
        if (token != _playToken) return;
        _actualQualityController.add(result.quality);
        _isPreview = result.isPreview;
        _previewController.add(_isPreview);
        _songs[index] = detailed.copyWith(quality: result.quality);
        final applied = await _applySource(
          token,
          AudioSource.uri(Uri.parse(result.url), tag: mediaItem.value),
        );
        if (!applied) return;
      }
      if (token != _playToken) return;
      _failureStreak = 0;
      await _player.play();
      // V3-03（第5批复核②，P2）：play() 期间队列可能被整体替换，
      // 世代校验 + 越界双检（第 18/12 条）；否则 RangeError 会被下面的
      // catch 当成播放失败，用户看到假错误并触发跳歌。
      if (token != _playToken) return;
      if (index < _songs.length && _index == index) {
        _playedController.add(_songs[index]);
      }
    } catch (e) {
      // 命中 20028：需要人机验证，不跳歌，交由 UI 弹验证页后重试
      final api = _extractApiException(e);
      if (api != null && api.needsVerification) {
        _pendingSongIndex = index;
        _verificationController.add(api);
        // PLY-02（审查③）：用户必须知道发生了什么，否则停在静默 error 态
        _errorController.add('需要完成人机验证后重试');
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.error,
          errorMessage: '需要人机验证',
        ));
        return;
      }
      // 播放失败，尝试下一首（连续失败达到队列长度即停止，防止无限循环）
      // V35-B1-1（第 B 批，P2）：catch 入口必须先校验世代——resolveUrl
      // 在飞时用户按暂停（pause 作废世代）→ 旧请求随后网络失败抛异常，
      // 此前会 ①上报已作废请求的假错误（UI 弹「播放失败」）②暂停引擎
      // ——把新歌的装载一并暂停（新请求 play() 之前的窗口）。
      if (token != _playToken) return;
      _errorController.add('播放失败：$e');
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
        errorMessage: '播放失败：$e',
      ));
      // F-3（第7批终审，P1）：失败分支用 _pauseEngineOnly——
      // pause() 会 _playToken++，导致 canAdvance 恒 false，
      // 自动跳歌彻底失效（用户必须手动点下一首）。
      await _pauseEngineOnly();
      _failureStreak++;
      final canAdvance =
          token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;
      if (canAdvance) {
        await skipToNext();
      } else {
        _failureStreak = 0;
      }
    } finally {
      // F4-14（审查②-B，P0）：闸门只在本处释放（第 19 条）——
      // playQueue 不再直接置 `_loading = false`，因此「关闭中又开闸」不会发生，
      // 也就不会出现两个 _playAt 真正并发装载音源的情况。
      // 被作废的旧请求同样负责放行：它退出后队列里排着的 _pendingIndex
      // 必须由它交给下一轮 _playAt，否则新请求会被永久挂起。
      _loading = false;
      final pending = _pendingIndex;
      if (pending != null) {
        _pendingIndex = null;
        // 异步调度，避免在 finally 中递归调用自身
        Future.microtask(() => _playAt(pending));
      }
    }
  }

  /// 装载音源，并在装载前后各校验一次世代（第 18 条）。
  ///
  /// `_player.setAudioSource` 不可取消：旧请求的调用若在新请求之后完成，
  /// 会把**旧歌**的 URL 装进引擎，而 `_index`/`mediaItem` 已是新歌
  /// （用户看到新歌封面、听到上一首）。这里用返回值告诉调用方
  /// 「装载完成后我是否仍是当前有效请求」，不是就放弃后续 play()。
  Future<bool> _applySource(int token, AudioSource source) async {
    if (token != _playToken) return false;
    await _player.setAudioSource(source);
    return token == _playToken;
  }

  /// 待验证的歌曲下标（验证通过后重试）
  int? _pendingSongIndex;

  ApiException? _extractApiException(Object e) {
    if (e is ApiException) return e;
    if (e is DioException && e.error is ApiException) {
      return e.error as ApiException;
    }
    return null;
  }

  /// 验证完成后重试上次失败的播放
  Future<void> retryPendingPlayback() async {
    final idx = _pendingSongIndex;
    if (idx == null) return;
    _pendingSongIndex = null;
    await _playAt(idx);
  }

  @override
  Future<void> play() async {
    if (!await ensureEngineReady()) return;
    await _player.play();
  }

  /// 失败分支专用：只停引擎，**不**作废世代（F-3，第7批终审 P1）。
  /// 用户主动暂停用 [pause]（作废世代防缓冲中自动续播）；
  /// 失败路径的世代由 catch 里的 canAdvance 判定使用，作废即失效。
  Future<void> _pauseEngineOnly() async {
    final p = _playerOrNull;
    if (p == null) return;
    try {
      await p.pause();
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    final p = _playerOrNull;
    if (p == null) return;
    // V3-02（第5批复核②，P2）：暂停必须作废在途播放请求——
    // 否则缓冲中的 _playAt 恢复后会自动 play()，出现「按了暂停却开始播放」
    //（QUALITY_STANDARD 第 18 条）。
    // V3-13（复核②终审回归）：**只作废世代，不开闸**（第 19 条）——
    // 在途 _playAt 各 await 点的 `token != _playToken` 检查会放弃后续
    // play()，闸门仍由它自己的 finally 释放。这里若直接 `_loading=false`，
    // 旧请求 finally 之前就开闸，第二个请求与旧请求并发 setAudioSource。
    _playToken++;
    _pendingIndex = null;
    await p.pause();
  }

  @override
  Future<void> stop() async {
    // V3-01（第5批复核②，P1）：停止/划掉通知必须作废世代，
    // 在途 _playAt 恢复后不得再调用 play()（第 18 条）。
    // V3-13：同 pause()，不开闸——闸门由持有者 finally 释放（第 19 条）。
    _playToken++;
    _pendingIndex = null;
    _pendingSongIndex = null;
    final p = _playerOrNull;
    if (p == null) return;
    await p.stop();
    _currentSongController.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final p = _playerOrNull;
    if (p == null) return;
    await p.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (!await ensureEngineReady()) return;
    if (_songs.isEmpty) return;
    if (_player.shuffleModeEnabled) {
      final next = _randomIndex();
      await _playAt(next);
      return;
    }
    var next = _index + 1;
    if (next >= _songs.length) {
      if (_player.loopMode == LoopMode.all) {
        next = 0;
      } else {
        return;
      }
    }
    await _playAt(next);
  }

  @override
  Future<void> skipToPrevious() async {
    if (!await ensureEngineReady()) return;
    if (_songs.isEmpty) return;
    // 播放超过 3 秒回到开头
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    var prev = _index - 1;
    if (prev < 0) {
      prev = _player.loopMode == LoopMode.all ? _songs.length - 1 : 0;
    }
    await _playAt(prev);
  }

  int _randomIndex() {
    if (_songs.length <= 1) return _index;
    final candidates =
        List.generate(_songs.length, (i) => i)..remove(_index);
    candidates.shuffle();
    return candidates.first;
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (!await ensureEngineReady()) return;
    await _player.setShuffleModeEnabled(
        shuffleMode == AudioServiceShuffleMode.all);
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (!await ensureEngineReady()) return;
    await _player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.none => LoopMode.off,
      AudioServiceRepeatMode.all => LoopMode.all,
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.group => LoopMode.all,
    });
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> onTaskRemoved() async {
    final p = _playerOrNull;
    if (p == null) return;
    // 任务被移除时若未在播放则停止服务
    if (!p.playing) {
      await stop();
    }
  }

  @override
  Future<void> onNotificationDeleted() async {
    // V3-01（第5批复核②，P1）：与 stop() 对称，作废在途请求（第 18 条）。
    // V3-13：不开闸，闸门由持有者 finally 释放（第 19 条）。
    _playToken++;
    _pendingIndex = null;
    _pendingSongIndex = null;
    await _playerOrNull?.stop();
  }
}
