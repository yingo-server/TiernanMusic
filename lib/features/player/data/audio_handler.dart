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

  /// 等待音频后台服务就绪；失败返回 false（调用方给友好错误，不要播放）。
  Future<bool> ensureEngineReady() async {
    if (_initialized) return true;
    final ok = await AudioServiceBootstrap.ensureReady();
    if (!ok) return false;
    if (_initialized) return true;
    _initialized = true;
    final p = _playerInstance = AudioPlayer();
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
    try {
      // 先广播缓冲状态
      _broadcastState(_player.playbackEvent);
      // 补全详情（专辑信息等），不阻塞失败
      final detailed = await _repository.fetchDetail(song);
      if (token != _playToken) return;
      _songs[index] = detailed;
      _emitMediaItem();

      // 已下载歌曲：本地文件存在时直接离线播放，跳过网络解析（F4）
      final local = song.localPath;
      if (local != null && local.isNotEmpty && File(local).existsSync()) {
        _isPreview = false;
        _previewController.add(false);
        await _player.setAudioSource(
          AudioSource.uri(Uri.file(local), tag: mediaItem.value),
        );
      } else {
        final result = await _repository.resolveUrl(detailed);
        if (token != _playToken) return;
        _actualQualityController.add(result.quality);
        _isPreview = result.isPreview;
        _previewController.add(_isPreview);
        _songs[index] = detailed.copyWith(quality: result.quality);
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(result.url),
            tag: mediaItem.value,
          ),
        );
      }
      if (token != _playToken) return;
      _failureStreak = 0;
      await _player.play();
      // 播放真正开始后再写最近播放（F2：自动切歌 / 上下一首同样覆盖）
      _playedController.add(_songs[index]);
    } catch (e) {
      // 命中 20028：需要人机验证，不跳歌，交由 UI 弹验证页后重试
      final api = _extractApiException(e);
      if (api != null && api.needsVerification) {
        _pendingSongIndex = index;
        _verificationController.add(api);
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.error,
          errorMessage: '需要人机验证',
        ));
        return;
      }
      // 播放失败，尝试下一首（连续失败达到队列长度即停止，防止无限循环）
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
        errorMessage: '播放失败：$e',
      ));
      // 失败后必须真正停住引擎，否则 player.playing 仍为 true，
      // UI 的播放按钮会卡在"暂停"态（真机反馈：播放态滞留）
      try {
        await _playerOrNull?.pause();
      } catch (_) {}
      _failureStreak++;
      final canAdvance =
          token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;
      if (canAdvance) {
        await skipToNext();
      } else {
        _failureStreak = 0;
      }
    } finally {
      _loading = false;
      final pending = _pendingIndex;
      if (pending != null) {
        _pendingIndex = null;
        // 异步调度，避免在 finally 中递归调用自身
        Future.microtask(() => _playAt(pending));
      }
    }
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

  @override
  Future<void> pause() async {
    final p = _playerOrNull;
    if (p == null) return;
    await p.pause();
  }

  @override
  Future<void> stop() async {
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
    await _playerOrNull?.stop();
  }
}
