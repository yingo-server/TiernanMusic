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

/// 底层 just_audio 播放器（音频引擎未就绪时为 null）。
final audioPlayerProvider =
    Provider<AudioPlayer?>((ref) => ref.watch(audioHandlerProvider).player);

/// 当前播放歌曲。
final currentSongProvider = StreamProvider<Song?>((ref) =>
    ref.watch(audioHandlerProvider).currentSongStream);

/// 实际播放音质。
final actualQualityProvider = StreamProvider<AudioQuality?>(
    (ref) => ref.watch(audioHandlerProvider).actualQualityStream);

/// 当前是否为 60 秒试听（VIP/付费曲的官方免费试听）。
final previewProvider = StreamProvider<bool>(
    (ref) => ref.watch(audioHandlerProvider).previewStream);

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

/// 播放进度 / 缓冲 / 时长 / 播放态 / 随机 / 循环。
///
/// 引擎未就绪（just_audio_background 启动失败）时返回稳定的空值流，
/// 避免直接用 null 播放器导致空指针。
final positionProvider = StreamProvider<Duration>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<Duration>.value(Duration.zero);
  return p.positionStream;
});

final bufferedPositionProvider = StreamProvider<Duration>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<Duration>.value(Duration.zero);
  return p.bufferedPositionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<Duration?>.value(null);
  return p.durationStream;
});

final isPlayingProvider = StreamProvider<bool>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<bool>.value(false);
  return p.playingStream;
});

final shuffleProvider = StreamProvider<bool>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<bool>.value(false);
  return p.shuffleModeEnabledStream;
});

final repeatProvider = StreamProvider<LoopMode>((ref) {
  final p = ref.watch(audioPlayerProvider);
  if (p == null) return Stream<LoopMode>.value(LoopMode.off);
  return p.loopModeStream;
});

/// 音频引擎是否可用（false 时可提示"音频服务启动失败"）。
final audioEngineReadyProvider = Provider<bool>(
    (ref) => ref.watch(audioHandlerProvider).isEngineReady);

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
  Future<void> togglePlay() async {
    final p = _handler.player;
    if (p == null) {
      // 引擎未就绪：尝试拉起（首次点播放时初始化可能尚未完成）
      if (!await _handler.ensureEngineReady()) return;
      await _handler.play();
      return;
    }
    if (p.playing) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
  }

  /// 跳转进度。
  Future<void> seekTo(Duration position) => _handler.seek(position);

  /// 切换随机播放。
  Future<void> toggleShuffle() async {
    final p = _handler.player;
    if (p == null) return;
    await _handler.setShuffleMode(p.shuffleModeEnabled
        ? AudioServiceShuffleMode.none
        : AudioServiceShuffleMode.all);
  }

  /// 循环模式轮转：列表循环 → 单曲循环 → 顺序播放。
  Future<void> cycleRepeatMode() async {
    final p = _handler.player;
    if (p == null) return;
    await _handler.setRepeatMode(switch (p.loopMode) {
      LoopMode.all => AudioServiceRepeatMode.one,
      LoopMode.one => AudioServiceRepeatMode.none,
      LoopMode.off => AudioServiceRepeatMode.all,
    });
  }
}
