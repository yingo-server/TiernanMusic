/// v5.3 P1：单一 `PlayerState` → Riverpod 投射层。
///
/// 旧文件有 16 个各自独立的 StreamProvider（currentSong / queue / error /
/// preview / quality / verification / isPlaying / shuffle / repeat ...），
/// 状态互不原子。本版只保留：
/// - [playerStateProvider]：唯一离散状态流（UI 三态渲染的唯一输入）；
/// - [playerStateMachineProvider]：状态机实例（adapter 与 controller 共用）；
/// - [audioHandlerProvider]：唯一注册的媒体会话 Handler（just_audio 适配器）；
/// - [audioPlayerProvider]：高频遥测（position / duration / buffered /
///   playing / shuffle / repeat）的独立流，避免进度 tick 重建整页；
/// - 兼容派生 provider：消费 playerStateProvider 的同一次快照，
///   保证 mini_player / full_player_page / queue_sheet 同源。
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../app/di.dart' show kugouApiClientProvider;
import '../../core/audio/audio_service_bootstrap.dart';
import '../../core/direct/kg_providers.dart' show kgClientProvider;
import '../../core/domain/quality.dart';
import '../../core/domain/song.dart';
import '../../core/foundation/errors.dart' show ApiException;
import '../../core/player_state/player_state.dart';
import '../library/data/recent_play_store.dart';
import 'data/audio_handler.dart';
import 'data/player_repository.dart';

/// API 客户端单例：复用全局 Provider，保证与认证模块共享 CookieJar。
final _apiClientProvider = Provider<KugouApiClient>(
    (ref) => ref.watch(kugouApiClientProvider));

/// 播放器仓库（直连播放 + kapi 内容接口）。
final playerRepositoryProvider = Provider<PlayerRepository>((ref) {
  // 预热直连客户端，确保首次播放前设备身份已就绪。
  ref.watch(kgClientProvider);
  return PlayerRepository(ref.watch(_apiClientProvider), ref);
});

/// 状态机实例（进程内唯一）。
final playerStateMachineProvider = Provider<PlayerStateMachine>((ref) {
  final machine = PlayerStateMachine();
  ref.onDispose(machine.dispose);
  return machine;
});

/// 全局音频处理器：**唯一**注册到系统媒体会话的 Handler。
final audioHandlerProvider = Provider<TiernanAudioHandler>((ref) {
  final handler = TiernanAudioHandler(
    ref.watch(playerRepositoryProvider),
    ref.watch(playerStateMachineProvider),
  );
  // A-00 定案：把同一个 Handler 挂到 AudioService.init 创建的桥上。
  AudioServiceBootstrap.attach(handler);
  ref.onDispose(handler.dispose);
  return handler;
});

/// 唯一离散状态流（PLAN §二「UI 只 watch 一个 playerStateProvider」）。
final playerStateProvider = StreamProvider<PlayerSnapshot>(
    (ref) => ref.watch(playerStateMachineProvider).snapshots);

/// 底层 just_audio 播放器（引擎未就绪时为 null）。
///
/// 必须是 StreamProvider：AudioPlayer 惰性创建，普通 Provider 会把首帧
/// null 永久缓存，导致进度条/播放键/时长全部不更新。
final audioPlayerProvider = StreamProvider<AudioPlayer?>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  yield handler.player;
  await for (final p in handler.engineReady) {
    yield p;
  }
});

// ── 派生 provider：全部从同一个 PlayerSnapshot 取，不再各自维护流 ──

final currentSongProvider = StreamProvider<Song?>((ref) async* {
  await for (final s in ref.watch(playerStateProvider.stream)) {
    yield s.currentSong;
  }
});

final queueProvider = StreamProvider<List<Song>>((ref) async* {
  await for (final s in ref.watch(playerStateProvider.stream)) {
    yield s.queue.songs;
  }
});

final actualQualityProvider = StreamProvider<AudioQuality?>((ref) async* {
  await for (final s in ref.watch(playerStateProvider.stream)) {
    final st = s.state;
    yield st is PlayerPlaying ? st.quality : null;
  }
});

final previewProvider = StreamProvider<bool>((ref) async* {
  await for (final s in ref.watch(playerStateProvider.stream)) {
    final st = s.state;
    yield st is PlayerPlaying ? st.isPreview : false;
  }
});

/// 播放错误（「发生了什么 + 下一步」），main.dart 统一 Toast。
final playerErrorProvider = StreamProvider<String>((ref) async* {
  await for (final s in ref.watch(playerStateProvider.stream)) {
    final st = s.state;
    if (st is PlayerFailure) {
      yield '${st.whatHappened}，${st.nextAction}';
    } else if (st is PlayerSuspended) {
      yield '需要完成人机验证后重试';
    }
  }
});

/// 20028 验证事件：单次消费（Suspended 态进入时发一次，退出不再重发）。
final verificationStreamProvider = StreamProvider<ApiException?>((ref) async* {
  yield null;
  ApiException? last;
  await for (final s in ref.watch(playerStateProvider.stream)) {
    final st = s.state;
    if (st is PlayerSuspended) {
      if (!identical(st.api, last)) {
        last = st.api;
        yield st.api;
      }
    } else {
      last = null;
      yield null;
    }
  }
});

/// 音频引擎是否可用（保留旧 API 名，语义已与状态机同源）。
final audioEngineReadyProvider = Provider<bool>((ref) {
  final s = ref.watch(playerStateProvider).valueOrNull;
  return s?.engineError == null;
});

/// 播放真正开始（setAudioSource 成功且 play() 已调用）→ 最近播放记录。
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

/// 高频遥测：独立流，避免进度 tick 触发 playerStateProvider 重建整页。
final positionProvider = StreamProvider<Duration>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield Duration.zero;
      continue;
    }
    yield* p.positionStream;
  }
});

final bufferedPositionProvider = StreamProvider<Duration>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield Duration.zero;
      continue;
    }
    yield* p.bufferedPositionStream;
  }
});

final durationProvider = StreamProvider<Duration?>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield null;
      continue;
    }
    yield* p.durationStream;
  }
});

final isPlayingProvider = StreamProvider<bool>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield false;
      continue;
    }
    yield* p.playingStream;
  }
});

final shuffleProvider = StreamProvider<bool>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield false;
      continue;
    }
    yield* p.shuffleModeEnabledStream;
  }
});

final repeatProvider = StreamProvider<LoopMode>((ref) async* {
  await for (final p in ref.watch(audioPlayerProvider.stream)) {
    if (p == null) {
      yield LoopMode.off;
      continue;
    }
    yield* p.loopModeStream;
  }
});

/// 播放控制器：UI 只投递事件，禁止直改状态字段（PLAN §二）。
final playerControllerProvider = Provider<PlayerController>(
    (ref) => PlayerController(ref.watch(audioHandlerProvider)));

class PlayerController {
  PlayerController(this._handler);
  final TiernanAudioHandler _handler;

  Future<void> playSong(Song song) => _handler.enqueueSong(song);

  Future<void> playQueue(List<Song> songs, int index) =>
      _handler.enqueueQueue(songs, index);

  /// 队列弹层「跳到第 N 首」：只投递 SkipToQueueItem 事件，不整表替换。
  Future<void> skipToIndex(int index) => _handler.skipToIndex(index);

  Future<void> next() => _handler.nextFromUi();
  Future<void> prev() => _handler.previousFromUi();

  Future<void> togglePlay() => _handler.togglePlayFromUi();

  Future<void> seekTo(Duration position) =>
      _handler.seekFromUi(position);

  Future<void> toggleShuffle() => _handler.toggleShuffleFromUi();

  Future<void> cycleRepeatMode() => _handler.cycleRepeatFromUi();

  /// 失败态重试 / 空态拉起引擎。
  Future<void> retry() => _handler.retryFromUi();

  /// 人机验证完成后由 VerificationListener 调用。
  Future<void> retryPendingPlayback() =>
      _handler.verificationPassedFromUi();
}
