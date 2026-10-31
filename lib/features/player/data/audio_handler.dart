import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/api/kugou_api_client.dart';
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
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= AudioPlayer();

  bool _initialized = false;

  /// 首次播放前调用；重复调用安全。
  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    final p = _player; // 触发创建
    p.playbackEventStream.listen(_broadcastState);
    p.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) skipToNext();
    });
    _configureSession();
  }

  final List<Song> _songs = [];
  final _currentSongController = StreamController<Song?>.broadcast();
  final _actualQualityController =
      StreamController<AudioQuality?>.broadcast();

  /// 人机验证事件（播放命中 20028 时发出）
  final _verificationController =
      StreamController<ApiException>.broadcast();

  Stream<ApiException> get verificationRequired => _verificationController.stream;

  int _index = -1;
  bool _loading = false;
  int _playToken = 0;

  AudioPlayer get player {
    ensureInitialized();
    return _player;
  }

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
    final playing = _player.playing;
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
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _index,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: switch (_player.loopMode) {
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
    ensureInitialized();
    _songs
      ..clear()
      ..addAll(songs);
    _emitQueue();
    await _playAt(index);
  }

  /// 播放单曲（追加到队列或替换当前位置）。
  Future<void> playSong(Song song) async {
    ensureInitialized();
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

  Future<void> _playAt(int index) async {
    ensureInitialized();
    if (index < 0 || index >= _songs.length) return;
    _index = index;
    _emitMediaItem();
    final token = ++_playToken;
    final song = _songs[index];

    if (_loading) return;
    _loading = true;
    try {
      // 先广播缓冲状态
      _broadcastState(_player.playbackEvent);
      // 补全详情（专辑信息等），不阻塞失败
      final detailed = await _repository.fetchDetail(song);
      if (token != _playToken) return;
      _songs[index] = detailed;
      _emitMediaItem();

      final result = await _repository.resolveUrl(detailed);
      if (token != _playToken) return;
      _actualQualityController.add(result.quality);
      _songs[index] = detailed.copyWith(quality: result.quality);

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(result.url),
          tag: mediaItem.value,
        ),
      );
      if (token != _playToken) return;
      await _player.play();
    } catch (e) {
      // 命中 20028：需要人机验证，不跳歌，交由 UI 弹验证页后重试
      final api = _extractApiException(e);
      if (api != null && api.needsVerification) {
        _pendingSongIndex = index;
        _verificationController.add(api);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: '需要人机验证',
        ));
        return;
      }
      // 播放失败，尝试下一首
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: '播放失败：$e',
      ));
      if (token == _playToken && _songs.length > 1) {
        await skipToNext();
      }
    } finally {
      _loading = false;
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
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _currentSongController.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
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
    await _player.setShuffleModeEnabled(
        shuffleMode == AudioServiceShuffleMode.all);
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
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
    // 任务被移除时若未在播放则停止服务
    if (!_player.playing) {
      await stop();
    }
  }

  @override
  Future<void> onNotificationDeleted() async {
    await _player.stop();
  }
}
