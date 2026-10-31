import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api/kugou_api_client.dart';
import 'data/audio_handler.dart';
import 'data/models.dart';
import 'data/player_repository.dart';

/// API 客户端单例。
final _apiClientProvider = Provider<KugouApiClient>((ref) => KugouApiClient());

/// 播放器仓库。
final playerRepositoryProvider = Provider<PlayerRepository>(
    (ref) => PlayerRepository(ref.watch(_apiClientProvider)));

/// 全局音频处理器（应用生命周期内常驻）。
final audioHandlerProvider = Provider<TiernanAudioHandler>((ref) {
  return TiernanAudioHandler(ref.watch(playerRepositoryProvider));
});

/// 底层 just_audio 播放器。
final audioPlayerProvider =
    Provider<AudioPlayer>((ref) => ref.watch(audioHandlerProvider).player);

/// 当前播放歌曲。
final currentSongProvider = StreamProvider<Song?>((ref) =>
    ref.watch(audioHandlerProvider).currentSongStream);

/// 实际播放音质。
final actualQualityProvider = StreamProvider<AudioQuality?>(
    (ref) => ref.watch(audioHandlerProvider).actualQualityStream);

/// 播放队列。
final queueProvider = StreamProvider<List<Song>>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  yield handler.songs;
  await for (final _ in handler.queue.stream) {
    yield handler.songs;
  }
});

/// 播放进度。
final positionProvider = StreamProvider<Duration>((ref) =>
    ref.watch(audioPlayerProvider).positionStream);

/// 缓冲进度。
final bufferedPositionProvider = StreamProvider<Duration>((ref) =>
    ref.watch(audioPlayerProvider).bufferedPositionStream);

/// 总时长。
final durationProvider = StreamProvider<Duration?>((ref) =>
    ref.watch(audioPlayerProvider).durationStream);

/// 是否正在播放。
final isPlayingProvider = StreamProvider<bool>((ref) =>
    ref.watch(audioPlayerProvider).playingStream);

/// 随机播放开关。
final shuffleProvider = StreamProvider<bool>((ref) =>
    ref.watch(audioPlayerProvider).shuffleModeEnabledStream);

/// 循环模式。
final repeatProvider = StreamProvider<LoopMode>(
    (ref) => ref.watch(audioPlayerProvider).loopModeStream);

/// 播放控制器，供 UI 调用。
final playerControllerProvider = Provider<PlayerController>(
    (ref) => PlayerController(ref.watch(audioHandlerProvider)));

class PlayerController {
  PlayerController(this._handler);
  final TiernanAudioHandler _handler;

  /// 播放单曲。
  Future<void> playSong(Song song) => _handler.playSong(song);

  /// 播放队列。
  Future<void> playQueue(List<Song> songs, int index) =>
      _handler.playQueue(songs, index);

  /// 下一首。
  Future<void> next() => _handler.skipToNext();

  /// 上一首。
  Future<void> prev() => _handler.skipToPrevious();

  /// 播放 / 暂停切换。
  Future<void> togglePlay() {
    final player = _handler.player;
    return player.playing ? _handler.pause() : _handler.play();
  }

  /// 跳转进度。
  Future<void> seekTo(Duration position) => _handler.seek(position);

  /// 切换随机播放。
  Future<void> toggleShuffle() {
    final enabled = _handler.player.shuffleModeEnabled;
    return _handler.setShuffleMode(enabled
        ? AudioServiceShuffleMode.none
        : AudioServiceShuffleMode.all);
  }

  /// 循环模式轮转：列表循环 → 单曲循环 → 顺序播放。
  Future<void> cycleRepeatMode() {
    final mode = _handler.player.loopMode;
    return _handler.setRepeatMode(switch (mode) {
      LoopMode.all => AudioServiceRepeatMode.one,
      LoopMode.one => AudioServiceRepeatMode.none,
      LoopMode.off => AudioServiceRepeatMode.all,
    });
  }
}
