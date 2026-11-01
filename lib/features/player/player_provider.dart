import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api/kugou_api_client.dart';
import '../../core/direct/kg_providers.dart';
import '../../core/providers.dart' show kugouApiClientProvider;
import '../library/data/recent_play_store.dart';
import 'data/audio_handler.dart';
import 'data/models.dart';
import 'data/player_repository.dart';

/// API 客户端单例。
///
/// 复用 [kugouApiClientProvider]（core/providers.dart），
/// 保证与认证模块**共享同一个 CookieJar** —— 否则登录态不会带到播放/评论请求里。
final _apiClientProvider = Provider<KugouApiClient>(
    (ref) => ref.watch(kugouApiClientProvider));

/// 播放器仓库（直连播放 + kapi 内容接口）。
final playerRepositoryProvider = Provider<PlayerRepository>((ref) {
  // 预热直连客户端，确保首次播放前设备身份已就绪
  ref.watch(kgClientProvider);
  return PlayerRepository(ref.watch(_apiClientProvider), ref);
});


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

/// 需要人机验证的事件流。
final verificationStreamProvider = StreamProvider<ApiException?>((ref) async* {
  yield null;
  await for (final e in ref.watch(audioHandlerProvider).verificationRequired) {
    yield e;
  }
});

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

/// 最近播放记录器：监听 onSongStarted（播放真正出声后）写最近播放。
///
/// 覆盖所有播放入口：自动切歌 / 手动上下一首 / 播放失败自动跳歌，
/// 原 PlayHelper._record（发起播放即写）已由本流取代（F2）。
final recentPlayRecorderProvider = Provider<void>((ref) {
  final sub = ref.watch(audioHandlerProvider).onSongStarted.listen((song) {
    if (song.hash.isEmpty) return;
    RecentPlayStore.add(RecentPlay(
      hash: song.hash,
      name: song.name,
      artist: song.artist,
      cover: song.cover,
      albumAudioId: song.albumAudioId,
      ts: DateTime.now().millisecondsSinceEpoch,
    )).then((_) => RecentPlayStore.notifyListeners());
  });
  ref.onDispose(sub.cancel);
});

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
