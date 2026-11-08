/// v5.3 P1 重写：just_audio ↔ [PlayerStateMachine] 适配器。
///
/// ## 职责边界（PLAN §二）
/// 本类是**唯一**注册到系统媒体会话的 `AudioHandler`（由
/// `AudioServiceBootstrap.attach` 挂到 `SwitchAudioHandler.inner`，A-00 定案），
/// 同时只做三件事：
/// 1. 系统媒体会话指令 → 状态机事件；
/// 2. 状态机快照 → mediaItem / queue / playbackState 单向投射；
/// 3. just_audio 平台事件（completed / processingState）→ 状态机事件 + 世代校验。
///
/// 不再持有 `_songs / _index / _loading / _playToken / _pendingIndex /
/// _pendingSongHash / _failureStreak / _isPreview / _last*` 等状态字段：
/// 全部收进 `PlayerStateMachine`（单一事实源，原则 5）。
///
/// 不再 `with QueueHandler, SeekHandler`：所有队列方法显式 override，
/// 避免 mixin 默认空实现吞掉系统指令（A-01）。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/audio/audio_service_bootstrap.dart';
import '../../../core/domain/quality.dart';
import '../../../core/domain/song.dart';
import '../../../core/net/network_phase.dart';
import '../../../core/player_state/player_state.dart';
import '../../../core/prefetch/prefetch_engine.dart';
import '../../../core/utils/error_logger.dart';
import '../../../core/utils/friendly_error.dart' show unwrapApi;
import 'player_repository.dart';

/// 单次装载成功的资源快照（绑定 sourceId，不再散落三个全局字段）。
final class _ResolvedSource {
  const _ResolvedSource({
    required this.source,
    required this.url,
    required this.declaredBytes,
    required this.isPreview,
    required this.quality,
  });

  final AudioSource source;
  final String url;
  final int declaredBytes;
  final bool isPreview;
  final AudioQuality quality;
}

/// 汀澜音乐后台音频处理器（唯一注册实例）。
class TiernanAudioHandler extends BaseAudioHandler {
  TiernanAudioHandler(this._repository, this._machine);

  final PlayerRepository _repository;
  final PlayerStateMachine _machine;

  // ── 生命周期 ───────────────────────────────────────────────────────────
  bool _disposed = false;
  bool _initialized = false;
  Future<bool>? _engineInitFuture;

  AudioPlayer? _playerInstance;
  AudioPlayer? get player => _playerInstance;
  bool get isEngineReady => _initialized;
  String? get engineError => _machine.snapshot.engineError;

  /// 引擎就绪事件（保留旧契约：audioPlayerProvider 靠它拿到惰性 AudioPlayer）。
  final _engineReadyController = StreamController<AudioPlayer?>.broadcast();
  Stream<AudioPlayer?> get engineReady => _engineReadyController.stream;

  /// 播放真正开始（play() 已调用）→ 最近播放记录。
  final _playedController = StreamController<Song>.broadcast();
  Stream<Song> get onSongStarted => _playedController.stream;

  StreamSubscription<PlayerSnapshot>? _stateSub;
  StreamSubscription<PlaybackEvent>? _eventSub;
  StreamSubscription<ProcessingState>? _processingSub;

  /// 当前已装载资源（只由 [generation] 对应的装载写入，completed 回调双校验）。
  _ResolvedSource? _loadedSource;
  int _loadedGeneration = -1;

  /// 快照变化订阅：系统媒体会话与业务状态同源投射。
  void _bindStateStream() {
    _stateSub ??= _machine.snapshots.listen(_project);
  }

  PlayerSnapshot get snapshot => _machine.snapshot;
  int get generation => _machine.generation;

  // ── 引擎初始化 ─────────────────────────────────────────────────────────
  /// 等待音频后台服务就绪；失败返回 false（状态机转 Failure，不创建 Player）。
  Future<bool> ensureEngineReady() async {
    if (_initialized) return true;
    if (_engineInitFuture != null) return _engineInitFuture!;
    final fut = AudioServiceBootstrap.ensureReady();
    _engineInitFuture = fut;
    final ok = await fut;
    if (_disposed) return false;
    if (!ok) {
      _engineInitFuture = null; // 允许重试（原则 11）
      final reason = friendlyEngineError(AudioServiceBootstrap.error);
      _machine.dispatch(EngineReadyChanged(false, error: reason));
      unawaited(ErrorLogger.instance.log(
        AudioServiceBootstrap.error ?? reason,
        StackTrace.current,
        source: 'audio_handler',
        context: 'ensureEngineReady failed',
      ));
      return false;
    }
    if (_initialized) return true;
    _initialized = true;
    final p = _playerInstance = AudioPlayer();
    _engineReadyController.add(p);
    _eventSub = p.playbackEventStream.listen(_broadcastPlaybackEvent);
    // A-04：completed 必须携带 generation + sourceId 双校验。
    _processingSub = p.processingStateStream.listen((state) {
      if (_disposed || state != ProcessingState.completed) return;
      final loaded = _loadedSource;
      final gen = _machine.generation;
      if (loaded == null || gen != _loadedGeneration) return;
      final playing = _machine.snapshot.state;
      if (playing is! PlayerPlaying) return;
      _onCompleted(loaded, playing.sourceId, gen);
    });
    unawaited(_configureSession());
    _bindStateStream();
    _machine.dispatch(const EngineReadyChanged(true));
    return true;
  }

  String friendlyEngineError(Object? error) =>
      '音频服务未就绪，请重启应用后重试';

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      // 第 6/9 条：音频会话配置失败不吞——留痕但不阻塞播放。
      debugPrint('[audio] AudioSession.configure failed: $e');
      unawaited(ErrorLogger.instance.log(
        e,
        StackTrace.current,
        source: 'audio_handler',
        context: 'AudioSession.configure',
      ));
    }
  }

  void _onCompleted(_ResolvedSource loaded, String sourceId, int gen) {
    // 完整播放 + 非试听 + 声明字节数>0 才永久缓存（V402 口径）。
    if (loaded.url.startsWith('http') &&
        !loaded.isPreview &&
        loaded.declaredBytes > 0) {
      PrefetchEngine.instance.onPlaybackCompleted(
        loaded.url,
        'audio',
        declaredBytes: loaded.declaredBytes,
      );
    }
    // 只投一次 Completed；reducer 负责 repeat/next，绝不在此直接跳歌。
    _machine.dispatch(Completed(sourceId, gen));
  }

  // ── 媒体会话投射（单向：state → mediaItem / queue / playbackState） ──────
  MediaItem _mediaItemOf(Song song) => MediaItem(
        id: song.hash,
        title: song.name,
        artist: song.artist,
        duration: song.duration > Duration.zero ? song.duration : null,
        artUri: song.cover.isNotEmpty ? Uri.tryParse(song.cover) : null,
        extras: {
          'albumId': song.albumId,
          'albumAudioId': song.albumAudioId,
        },
      );

  void _project(PlayerSnapshot s) {
    if (_disposed) return;
    final q = s.queue;
    queue.add([for (final song in q.songs) _mediaItemOf(song)]);
    final cur = q.current;
    mediaItem.add(cur == null ? null : _mediaItemOf(cur));
    final st = s.state;
    final processing = switch (st) {
      PlayerIdle() => AudioProcessingState.idle,
      PlayerLoading() => st.phase == NetworkPhase.buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.loading,
      PlayerPlaying() => AudioProcessingState.ready,
      PlayerPaused() => AudioProcessingState.ready,
      PlayerSuspended() => AudioProcessingState.error,
      PlayerFailure() => AudioProcessingState.error,
    };
    final playing = st is PlayerPlaying;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToQueueItem,
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
      },
      processingState: processing,
      playing: playing,
      updatePosition: _playerInstance?.position ?? Duration.zero,
      bufferedPosition: _playerInstance?.bufferedPosition ?? Duration.zero,
      speed: _playerInstance?.speed ?? 1.0,
      queueIndex: q.index < 0 ? null : q.index,
      repeatMode: switch (q.repeat) {
        PlayerRepeatMode.off => AudioServiceRepeatMode.none,
        PlayerRepeatMode.one => AudioServiceRepeatMode.one,
        PlayerRepeatMode.all => AudioServiceRepeatMode.all,
      },
      shuffleMode: q.shuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      errorMessage: st is PlayerFailure ? st.whatHappened : null,
    ));
    // PrefetchEngine 只认「队列/下标」；用新下标投递，修 A-03 预取错窗口。
    if (q.songs.isNotEmpty) {
      PrefetchEngine.instance.updateUpcoming(q.songs, q.index);
    }
    // 快照变化驱动装载/暂停/停止（generation 决定是否需要重新解析）。
    unawaited(_applySnapshotSideEffect(s));
  }

  /// 快照 → 引擎副作用。只有「本世代尚未装载」才走解析链。
  Future<void> _applySnapshotSideEffect(PlayerSnapshot s) async {
    final st = s.state;
    if (st is PlayerLoading && st.generation == s.generation) {
      await _loadGeneration(s.generation, st.song);
      return;
    }
    final p = _playerInstance;
    if (p == null) return;
    if (st is PlayerPlaying) {
      // 单曲循环/恢复：世代未变且 source 已装好，只调 play()。
      if (_loadedGeneration == s.generation && _loadedSource != null) {
        await p.play();
      } else {
        await _loadGeneration(s.generation, st.song);
      }
      return;
    }
    if (st is PlayerPaused || st is PlayerSuspended || st is PlayerFailure) {
      if (p.playing) await p.pause();
      return;
    }
    if (st is PlayerIdle) {
      await p.stop();
      _loadedSource = null;
      _loadedGeneration = -1;
    }
  }

  // ── 装载链（唯一异步写入点，全程世代校验） ─────────────────────────────
  Future<void> _loadGeneration(int gen, Song song) async {
    if (_disposed) return;
    // 保证引擎与本 Handler 的双向订阅已建立。
    if (!_initialized) {
      final ok = await ensureEngineReady();
      if (!ok || _disposed) return;
    }
    if (gen != _machine.generation || _disposed) return;
    final p = _playerInstance;
    if (p == null) return;

    // 同一世代重复投射（LoadingPhaseChanged/PlaybackTick）不重复解析。
    if (_loadedGeneration == gen && _loadedSource != null) return;

    NetworkPhaseTracker.instance.begin(NetworkPhase.resolving,
        detail: 'gen:$gen:${song.hash}');
    try {
      final resolved = await _resolveSource(gen, song);
      if (resolved == null || gen != _machine.generation || _disposed) return;
      _machine.dispatch(LoadingPhaseChanged(gen, NetworkPhase.buffering));
      NetworkPhaseTracker.instance.begin(NetworkPhase.buffering,
          detail: 'setSource:$gen');
      try {
        await p.setAudioSource(resolved.source, preload: true);
      } finally {
        NetworkPhaseTracker.instance.end(NetworkPhase.buffering);
      }
      if (gen != _machine.generation || _disposed) return;
      _loadedSource = resolved;
      _loadedGeneration = gen;
      await p.play();
      if (gen != _machine.generation || _disposed) return;
      final sourceId = '$gen:${song.hash}';
      _machine.dispatch(PlaybackStarted(
        gen,
        song: song,
        quality: resolved.quality,
        isPreview: resolved.isPreview,
        sourceId: sourceId,
      ));
      _playedController.add(song);
    } catch (e) {
      if (gen != _machine.generation || _disposed) return; // 迟到异常丢弃
      final api = unwrapApi(e);
      if (api != null && api.needsVerification) {
        _machine.dispatch(VerificationSuspended(gen, song, api));
        return;
      }
      unawaited(ErrorLogger.instance.log(
        e,
        StackTrace.current,
        source: 'audio_handler',
        context: 'loadGeneration($gen)',
      ));
      _machine.dispatch(Failed(
        gen,
        PlayerFailureReason.resolveFailed,
        e,
      ));
    } finally {
      NetworkPhaseTracker.instance.end(NetworkPhase.resolving);
    }
  }

  /// 解析本世代可播放源：离线优先，失败同曲回退在线（A-24 留痕）。
  Future<_ResolvedSource?> _resolveSource(int gen, Song song) async {
    final local = song.localPath;
    final localUsable = local != null &&
        local.isNotEmpty &&
        (local.startsWith('content://') || File(local).existsSync());
    if (localUsable) {
      try {
        return _ResolvedSource(
          source: AudioSource.uri(
            local.startsWith('content://')
                ? Uri.parse(local)
                : Uri.file(local),
            tag: _mediaItemOf(song),
          ),
          url: '',
          declaredBytes: 0,
          isPreview: false,
          quality: song.quality,
        );
      } catch (e) {
        debugPrint('[audio] local source unusable, fallback online: $e');
      }
    }
    final detailed = await _repository.fetchDetail(song);
    if (gen != _machine.generation) return null;
    final result = await _repository.resolveUrl(detailed);
    if (gen != _machine.generation) return null;
    final effective = detailed.copyWith(
      quality: result.quality,
      clearLocalPath: localUsable && local != null,
    );
    return _ResolvedSource(
      source: AudioSource.uri(
        Uri.parse(result.url),
        tag: _mediaItemOf(effective),
      ),
      url: result.url,
      declaredBytes: result.expectedBytes,
      isPreview: result.isPreview,
      quality: result.quality,
    );
  }

  // ── UI 事件入口（controller 只调这些） ──────────────────────────────────
  Future<void> enqueueQueue(List<Song> songs, int index) async {
    _bindStateStream();
    if (!await ensureEngineReady()) return;
    _machine.dispatch(PlayQueueRequested(songs, index));
  }

  Future<void> enqueueSong(Song song) async {
    _bindStateStream();
    if (!await ensureEngineReady()) return;
    _machine.dispatch(PlaySongRequested(song));
  }

  Future<void> skipToIndex(int index) async {
    _machine.dispatch(SkipToQueueItemRequested(index));
  }

  Future<void> nextFromUi() async {
    _machine.dispatch(const NextRequested(manual: true));
  }

  Future<void> previousFromUi() async {
    final p = _playerInstance;
    if (p != null && p.position > const Duration(seconds: 3)) {
      await p.seek(Duration.zero);
      return;
    }
    _machine.dispatch(const PreviousRequested());
  }

  Future<void> togglePlayFromUi() async {
    if (!await ensureEngineReady()) return;
    final st = _machine.snapshot.state;
    if (st is PlayerPlaying) {
      _machine.dispatch(const PauseRequested());
    } else if (st is PlayerPaused) {
      _machine.dispatch(const ResumeRequested());
    } else {
      _machine.dispatch(const RetryRequested());
    }
  }

  Future<void> seekFromUi(Duration position) async {
    if (!await ensureEngineReady()) return;
    final before = _machine.generation;
    final snap = _machine.dispatch(SeekToRequested(position.inMilliseconds));
    // reducer 拒绝（Loading/Idle/Failure）时 state 变成 Failure，不执行 seek。
    if (snap.state is PlayerFailure) return;
    final p = _playerInstance;
    if (p == null || before != _machine.generation) return;
    final maxMs = p.duration?.inMilliseconds;
    if (position.inMilliseconds < 0 ||
        (maxMs != null && position.inMilliseconds > maxMs)) {
      return;
    }
    try {
      await p.seek(position);
    } catch (e) {
      _machine.dispatch(Failed(
        _machine.generation,
        PlayerFailureReason.sourceFailed,
        e,
      ));
    }
  }

  Future<void> toggleShuffleFromUi() async {
    if (!await ensureEngineReady()) return;
    final q = _machine.snapshot.queue;
    _machine.dispatch(ShuffleModeChanged(!q.shuffle));
  }

  Future<void> cycleRepeatFromUi() async {
    if (!await ensureEngineReady()) return;
    final q = _machine.snapshot.queue;
    final next = switch (q.repeat) {
      PlayerRepeatMode.all => PlayerRepeatMode.one,
      PlayerRepeatMode.one => PlayerRepeatMode.off,
      PlayerRepeatMode.off => PlayerRepeatMode.all,
    };
    _machine.dispatch(RepeatModeChanged(next));
  }

  Future<void> retryFromUi() async {
    if (!await ensureEngineReady()) return;
    _machine.dispatch(const RetryRequested());
  }

  /// 验证页返回：只按「当前 Suspended 的 hash + generation」重放（A-08）。
  Future<void> verificationPassedFromUi() async {
    final st = _machine.snapshot.state;
    if (st is! PlayerSuspended) return;
    _machine.dispatch(VerificationPassed(st.song.hash, st.generation));
  }

  // ── 系统媒体会话指令（A-00：全部经同一个注册 Handler 到达） ─────────────
  @override
  Future<void> play() async {
    if (!await ensureEngineReady()) return;
    _machine.dispatch(const SystemPlayRequested());
  }

  @override
  Future<void> pause() async {
    _machine.dispatch(const SystemPauseRequested());
  }

  @override
  Future<void> stop() async {
    _machine.dispatch(const StopRequested(fromSystem: true));
  }

  @override
  Future<void> seek(Duration position) => seekFromUi(position);

  @override
  Future<void> skipToNext() async {
    _machine.dispatch(const SystemSkipToNextRequested());
  }

  @override
  Future<void> skipToPrevious() =>
      previousFromUi(); // >3s 回开头语义与 UI 一致

  @override
  Future<void> skipToQueueItem(int index) async {
    _machine.dispatch(SystemSkipToQueueItemRequested(index));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _machine.dispatch(SystemSetShuffleModeRequested(
        shuffleMode != AudioServiceShuffleMode.none));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    // group 未实现（audio_service 官方注释）：显式归一为 all 并留痕（A-07）。
    if (repeatMode == AudioServiceRepeatMode.group) {
      debugPrint('[audio] repeatMode.group unimplemented → all');
    }
    final mode = switch (repeatMode) {
      AudioServiceRepeatMode.none => PlayerRepeatMode.off,
      AudioServiceRepeatMode.one => PlayerRepeatMode.one,
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group =>
        PlayerRepeatMode.all,
    };
    _machine.dispatch(SystemSetRepeatModeRequested(mode));
  }

  @override
  Future<void> onTaskRemoved() async {
    final p = _playerInstance;
    if (p == null || !p.playing) await stop();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // 划掉通知必须清队列/挂起/资源快照（A-10）。
    await stop();
  }

  void _broadcastPlaybackEvent(PlaybackEvent event) {
    if (_disposed) return;
    final p = _playerInstance;
    if (p == null) return;
    // 只更新连续遥测字段，不改离散 state（避免与 reducer 抢事实源）。
    playbackState.add(playbackState.value.copyWith(
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
    ));
  }

  /// 对称释放（原则 20）：3 条订阅 + 3 个 controller + AudioPlayer。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateSub?.cancel();
    await _eventSub?.cancel();
    await _processingSub?.cancel();
    await _playerInstance?.dispose();
    await _engineReadyController.close();
    await _playedController.close();
    await super.stop();
  }
}
