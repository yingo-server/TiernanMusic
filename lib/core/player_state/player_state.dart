/// v5.3 P1：播放器状态机（唯一事实源）。
///
/// 定案：彻底弃用 `BaseAudioHandler` / `QueueHandler` / `SeekHandler` 双 Handler
/// 架构（审计 A-00），改为 `AudioSource` 序列 + `MediaItem` tag 单一链路：
/// 系统媒体会话仍由 `just_audio_background` 内部注册的 `_PlayerAudioHandler`
/// 承载，本文件是 App 侧唯一权威状态；`audio_handler.dart` 降级为
/// 纯 just_audio 适配器，只把平台事件翻译成本文件的事件。
///
/// 事实源只有一个：[PlayerSnapshot]（`state + queue + index + mode + generation`）。
/// 所有派生事实（当前歌曲/试听/音质/网络阶段/引擎错误/最近播放）都由
/// reducer 从该快照投射，UI 只 watch `playerStateProvider`。
library;

import 'dart:async';

import '../../domain/quality.dart';
import '../../domain/song.dart';
import '../../foundation/errors.dart';
import '../../net/network_phase.dart';

/// 用户可见的播放失败原因（错误态必须「发生了什么 + 下一步」）。
enum PlayerFailureReason {
  engineNotReady,
  emptyQueue,
  invalidSong,
  invalidIndex,
  resolveFailed,
  sourceFailed,
  seekRejected,
  queueChanged,
}

/// 暂停原因：用户主动 / 系统媒体会话 / 等待人机验证。
enum PlayerPauseReason { user, system, verification }

/// 循环模式（与 just_audio.LoopMode 解耦，状态机不依赖平台枚举）。
enum PlayerRepeatMode { off, all, one }

/// sealed 状态：互斥，任何时刻只有一个。
sealed class PlayerState {
  const PlayerState();
}

final class PlayerIdle extends PlayerState {
  const PlayerIdle();
}

/// 解析/装载中。[phase] 保证 >500ms 的阶段可见（原则 34）。
final class PlayerLoading extends PlayerState {
  const PlayerLoading(
    this.song, {
    required this.phase,
    required this.startedAt,
    required this.generation,
  });

  final Song song;
  final NetworkPhase phase;
  final DateTime startedAt;
  final int generation;
}

final class PlayerPlaying extends PlayerState {
  const PlayerPlaying(
    this.song, {
    required this.isPreview,
    required this.quality,
    required this.sourceId,
  });

  final Song song;
  final bool isPreview;
  final AudioQuality quality;
  final String sourceId;
}

final class PlayerPaused extends PlayerState {
  const PlayerPaused(this.song, this.reason);

  final Song song;
  final PlayerPauseReason reason;
}

/// 20028 是一等公民状态（审计 A-08）：保留 generation + songHash，
/// 验证通过/取消/队列替换三个退出事件都必须校验世代号。
final class PlayerSuspended extends PlayerState {
  const PlayerSuspended(this.song, this.api, this.generation);

  final Song song;
  final ApiException api;
  final int generation;
}

final class PlayerFailure extends PlayerState {
  const PlayerFailure(
    this.reason, {
    required this.whatHappened,
    required this.nextAction,
    this.song,
    this.retry,
  });

  final PlayerFailureReason reason;
  final String whatHappened;
  final String nextAction;

  /// 失败时若仍知道是哪首歌，UI 可保留封面/歌名而不是白屏。
  final Song? song;

  /// 重试动作由 controller 注入（捕获事件，不捕获可变状态）。
  final Future<void> Function()? retry;
}

/// 队列状态：唯一权威列表 + 当前下标 + 模式 + 随机历史。
final class QueueState {
  const QueueState({
    this.songs = const <Song>[],
    this.index = -1,
    this.shuffle = false,
    this.repeat = PlayerRepeatMode.off,
    this.history = const <String>{},
  });

  final List<Song> songs;
  final int index;
  final bool shuffle;
  final PlayerRepeatMode repeat;

  /// 随机模式已播 hash（显式边界：一轮内不重复；满队列后清空重开一轮）。
  final Set<String> history;

  bool get isEmpty => songs.isEmpty;
  int get length => songs.length;

  Song? get current =>
      (index >= 0 && index < songs.length) ? songs[index] : null;

  QueueState copyWith({
    List<Song>? songs,
    int? index,
    bool? shuffle,
    PlayerRepeatMode? repeat,
    Set<String>? history,
  }) {
    return QueueState(
      songs: songs ?? this.songs,
      index: index ?? this.index,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      history: history ?? this.history,
    );
  }
}

/// 对外唯一快照。equality 按 generation + state 类型 + index 判定，
/// 避免同一世代的重复 tick 触发整页重建（原则 26）。
final class PlayerSnapshot {
  const PlayerSnapshot({
    required this.state,
    required this.queue,
    required this.generation,
    required this.revision,
    this.engineError,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.duration,
    this.isPlaying = false,
  });

  final PlayerState state;
  final QueueState queue;
  final int generation;
  final int revision;
  final String? engineError;
  final Duration position;
  final Duration buffered;
  final Duration? duration;
  final bool isPlaying;

  Song? get currentSong => queue.current;

  PlayerSnapshot copyWith({
    PlayerState? state,
    QueueState? queue,
    int? generation,
    int? revision,
    String? engineError,
    bool clearEngineError = false,
    Duration? position,
    Duration? buffered,
    Duration? duration,
    bool clearDuration = false,
    bool? isPlaying,
  }) {
    return PlayerSnapshot(
      state: state ?? this.state,
      queue: queue ?? this.queue,
      generation: generation ?? this.generation,
      revision: revision ?? this.revision,
      engineError: clearEngineError ? null : (engineError ?? this.engineError),
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      duration: clearDuration ? null : (duration ?? this.duration),
      isPlaying: isPlaying ?? this.isPlaying,
    );
  }
}

/// 状态机事件（UI / adapter / 系统媒体会话都只投递事件，禁止直改字段）。
sealed class PlayerEvent {
  const PlayerEvent();
}

final class PlayQueueRequested extends PlayerEvent {
  const PlayQueueRequested(this.songs, this.startIndex, {this.source = 'ui'});
  final List<Song> songs;
  final int startIndex;
  final String source;
}

final class PlaySongRequested extends PlayerEvent {
  const PlaySongRequested(this.song, {this.policy = PlaySongPolicy.afterCurrent});
  final Song song;
  final PlaySongPolicy policy;
}

enum PlaySongPolicy { afterCurrent, append, replace }

final class NextRequested extends PlayerEvent {
  const NextRequested({this.manual = true});
  final bool manual;
}

final class PreviousRequested extends PlayerEvent {
  const PreviousRequested();
}

final class SkipToQueueItemRequested extends PlayerEvent {
  const SkipToQueueItemRequested(this.index, {this.fromSystem = false});
  final int index;
  final bool fromSystem;
}

final class SeekToRequested extends PlayerEvent {
  const SeekToRequested(this.positionMs);
  final int positionMs;
}

final class Completed extends PlayerEvent {
  const Completed(this.sourceId, this.generation);
  final String sourceId;
  final int generation;
}

final class Failed extends PlayerEvent {
  const Failed(this.generation, this.reason, this.error, {this.sourceId});
  final int generation;
  final PlayerFailureReason reason;
  final Object error;
  final String? sourceId;
}

final class VerificationSuspended extends PlayerEvent {
  const VerificationSuspended(this.generation, this.song, this.api);
  final int generation;
  final Song song;
  final ApiException api;
}

final class VerificationPassed extends PlayerEvent {
  const VerificationPassed(this.songHash, this.generation);
  final String songHash;
  final int generation;
}

final class VerificationCancelled extends PlayerEvent {
  const VerificationCancelled(this.generation);
  final int generation;
}

final class PauseRequested extends PlayerEvent {
  const PauseRequested({this.reason = PlayerPauseReason.user});
  final PlayerPauseReason reason;
}

final class ResumeRequested extends PlayerEvent {
  const ResumeRequested();
}

final class StopRequested extends PlayerEvent {
  const StopRequested({this.fromSystem = false});
  final bool fromSystem;
}

final class ShuffleModeChanged extends PlayerEvent {
  const ShuffleModeChanged(this.enabled);
  final bool enabled;
}

final class RepeatModeChanged extends PlayerEvent {
  const RepeatModeChanged(this.mode);
  final PlayerRepeatMode mode;
}

final class EngineReadyChanged extends PlayerEvent {
  const EngineReadyChanged(this.ready, {this.error});
  final bool ready;
  final String? error;
}

final class LoadingPhaseChanged extends PlayerEvent {
  const LoadingPhaseChanged(this.generation, this.phase);
  final int generation;
  final NetworkPhase phase;
}

/// adapter 装载成功且 play() 已调用：唯一 Loading→Playing 转移。
final class PlaybackStarted extends PlayerEvent {
  const PlaybackStarted(
    this.generation, {
    required this.song,
    required this.quality,
    required this.isPreview,
    required this.sourceId,
  });
  final int generation;
  final Song song;
  final AudioQuality quality;
  final bool isPreview;
  final String sourceId;
}

/// 失败态「重试」：重播当前队列项，不改变队列内容。
final class RetryRequested extends PlayerEvent {
  const RetryRequested();
}

final class PlaybackTick extends PlayerEvent {
  const PlaybackTick({
    required this.position,
    required this.buffered,
    this.duration,
    required this.isPlaying,
  });
  final Duration position;
  final Duration buffered;
  final Duration? duration;
  final bool isPlaying;
}

/// 状态机 reducer（纯函数 + 唯一可变字段 `_snapshot`）。
///
/// 并发纪律：所有事件串行投递（Dart 单 isolate 事件循环），每个异步边界
/// 携带 `generation`；迟到事件与当前世代不符直接丢弃（原则 18）。
class PlayerStateMachine {
  PlayerStateMachine();

  final _controller = StreamController<PlayerSnapshot>.broadcast();

  PlayerSnapshot _snapshot = const PlayerSnapshot(
    state: PlayerIdle(),
    queue: QueueState(),
    generation: 0,
    revision: 0,
  );

  PlayerSnapshot get snapshot => _snapshot;
  Stream<PlayerSnapshot> get stream => _controller.stream;

  /// 连续失败计数（有上限，原则 25）。
  static const int kMaxFailureStreak = 3;
  int _failureStreak = 0;

  /// 供 adapter 读取：当前世代 + 当前 sourceId（completed 回调必须双校验）。
  int get generation => _snapshot.generation;
  String? get currentSourceId {
    final s = _snapshot.state;
    return s is PlayerPlaying ? s.sourceId : null;
  }

  void _emit(PlayerSnapshot next) {
    _snapshot = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  PlayerSnapshot _reduce(PlayerSnapshot s, PlayerEvent event) {
    final gen = s.generation;
    final q = s.queue;
    switch (event) {
      case PlayQueueRequested():
        final items = List<Song>.unmodifiable(event.songs);
        if (items.isEmpty) {
          return _newGeneration(s, state: const PlayerIdle(), queue: const QueueState());
        }
        final index = _clampIndex(event.startIndex, items.length);
        final song = items[index];
        if (song.hash.isEmpty) {
          return _newGeneration(
            s,
            state: _failure(PlayerFailureReason.invalidSong, song: song),
            queue: QueueState(songs: items, index: index),
          );
        }
        return _newGeneration(
          s,
          state: _loading(song, NetworkPhase.resolving, gen + 1),
          queue: QueueState(songs: items, index: index),
        );

      case PlaySongRequested():
        final song = event.song;
        if (song.hash.isEmpty) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.invalidSong, song: song),
          );
        }
        final List<Song> items;
        final int index;
        switch (event.policy) {
          case PlaySongPolicy.replace:
            items = <Song>[song];
            index = 0;
          case PlaySongPolicy.append:
            items = <Song>[...q.songs, song];
            index = q.index < 0 ? 0 : q.index;
          case PlaySongPolicy.afterCurrent:
            final existing = _indexOfHash(q.songs, song.hash);
            if (existing >= 0) {
              // 同 hash 但带 localPath 时覆盖为可离线源（不整表替换）。
              items = List<Song>.of(q.songs);
              if ((song.localPath?.isNotEmpty ?? false) &&
                  (items[existing].localPath?.isNotEmpty != true)) {
                items[existing] = items[existing].copyWith(localPath: song.localPath);
              }
              index = existing;
            } else {
              items = List<Song>.of(q.songs);
              final insertAt = (q.index + 1).clamp(0, items.length);
              items.insert(insertAt, song);
              index = insertAt;
            }
        }
        return _newGeneration(
          s,
          state: _loading(items[index], NetworkPhase.resolving, gen + 1),
          queue: q.copyWith(songs: List<Song>.unmodifiable(items), index: index),
        );

      case NextRequested():
        if (q.isEmpty) return s;
        final cur = s.state;
        if (!event.manual &&
            q.repeat == PlayerRepeatMode.one &&
            cur is PlayerPlaying) {
          // 单曲循环：保持同一 generation/sourceId，由 adapter 重播当前 source。
          return s.copyWith(revision: s.revision + 1);
        }
        final next = _nextIndex(q, s.position, manual: event.manual);
        if (next == null) {
          return s.copyWith(
            revision: s.revision + 1,
            state: const PlayerIdle(),
            isPlaying: false,
          );
        }
        final history = <String>{...q.history};
        final currentHash = q.current?.hash ?? '';
        if (currentHash.isNotEmpty) history.add(currentHash);
        return _newGeneration(
          s,
          state: _loading(q.songs[next], NetworkPhase.resolving, gen + 1),
          queue: q.copyWith(index: next, history: history),
        );

      case PreviousRequested():
        if (q.isEmpty) return s;
        if (s.position > const Duration(seconds: 3)) {
          return s.copyWith(revision: s.revision + 1, position: Duration.zero);
        }
        var prev = q.index - 1;
        if (prev < 0) {
          if (q.repeat == PlayerRepeatMode.all) {
            prev = q.length - 1;
          } else {
            prev = 0;
          }
        }
        return _newGeneration(
          s,
          state: _loading(q.songs[prev], NetworkPhase.resolving, gen + 1),
          queue: q.copyWith(index: prev),
        );

      case SkipToQueueItemRequested():
        if (event.index < 0 || event.index >= q.length) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.invalidIndex, song: q.current),
          );
        }
        // 只改 index，不重建 items（审计 A-02 根因）。
        return _newGeneration(
          s,
          state: _loading(q.songs[event.index], NetworkPhase.resolving, gen + 1),
          queue: q.copyWith(index: event.index),
        );

      case SeekToRequested():
        final st = s.state;
        if (st is! PlayerPlaying && st is! PlayerPaused) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.seekRejected, song: q.current),
          );
        }
        final maxMs = s.duration?.inMilliseconds;
        if (event.positionMs < 0 || (maxMs != null && event.positionMs > maxMs)) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.seekRejected, song: q.current),
          );
        }
        return s.copyWith(revision: s.revision + 1); // adapter 收到事件后执行 seek

      case Completed():
        final st = s.state;
        if (event.generation != gen ||
            st is! PlayerPlaying ||
            event.sourceId != st.sourceId) {
          return s; // 迟到 completed：不缓存、不跳歌（A-04 P0）
        }
        return _reduce(s, const NextRequested(manual: false));

      case Failed():
        if (event.generation != gen) return s;
        _failureStreak++;
        if (_failureStreak < kMaxFailureStreak && q.length > 1) {
          return _reduce(s, const NextRequested(manual: false));
        }
        _failureStreak = 0;
        return s.copyWith(
          revision: s.revision + 1,
          isPlaying: false,
          state: _failure(event.reason, song: q.current, error: event.error),
        );

      case VerificationSuspended():
        if (event.generation != gen) return s;
        return s.copyWith(
          revision: s.revision + 1,
          isPlaying: false,
          state: PlayerSuspended(event.song, event.api, gen),
        );

      case VerificationPassed():
        final st = s.state;
        if (st is! PlayerSuspended || st.generation != gen ||
            st.song.hash != event.songHash) {
          return s; // 队列已换 / 验证已取消：不重播错歌
        }
        final idx = _indexOfHash(q.songs, event.songHash);
        if (idx < 0) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.queueChanged),
          );
        }
        return _newGeneration(
          s,
          state: _loading(q.songs[idx], NetworkPhase.resolving, gen + 1),
          queue: q.copyWith(index: idx),
        );

      case VerificationCancelled():
        final st = s.state;
        if (st is! PlayerSuspended || st.generation != gen) return s;
        return s.copyWith(
          revision: s.revision + 1,
          state: PlayerPaused(st.song, PlayerPauseReason.verification),
        );

      case PauseRequested():
        final cur = q.current;
        if (cur == null) return s;
        _failureStreak = 0;
        return _newGeneration(
          s,
          state: PlayerPaused(cur, event.reason),
          isPlaying: false,
        );

      case ResumeRequested():
        final st = s.state;
        if (st is! PlayerPaused) return s;
        return _newGeneration(
          s,
          state: _loading(st.song, NetworkPhase.buffering, gen + 1),
        );

      case StopRequested():
        _failureStreak = 0;
        return _newGeneration(
          s,
          state: const PlayerIdle(),
          queue: const QueueState(),
          isPlaying: false,
          position: Duration.zero,
          buffered: Duration.zero,
          clearDuration: true,
        );

      case ShuffleModeChanged():
        return s.copyWith(
          revision: s.revision + 1,
          queue: q.copyWith(
            shuffle: event.enabled,
            history: event.enabled ? const <String>{} : q.history,
          ),
        );

      case RepeatModeChanged():
        return s.copyWith(
          revision: s.revision + 1,
          queue: q.copyWith(repeat: event.mode),
        );

      case EngineReadyChanged():
        if (!event.ready && event.error != null) {
          return _newGeneration(
            s,
            state: _failure(PlayerFailureReason.engineNotReady, song: q.current),
            engineError: event.error,
            isPlaying: false,
          );
        }
        return s.copyWith(
          revision: s.revision + 1,
          clearEngineError: event.ready,
        );

      case LoadingPhaseChanged():
        final st = s.state;
        if (event.generation != gen || st is! PlayerLoading) return s;
        return s.copyWith(
          revision: s.revision + 1,
          state: PlayerLoading(
            st.song,
            phase: event.phase,
            startedAt: st.startedAt,
            generation: st.generation,
          ),
        );

      case PlaybackStarted():
        final st = s.state;
        if (event.generation != gen || st is! PlayerLoading) return s;
        _failureStreak = 0;
        return s.copyWith(
          revision: s.revision + 1,
          isPlaying: true,
          state: PlayerPlaying(
            event.song,
            isPreview: event.isPreview,
            quality: event.quality,
            sourceId: event.sourceId,
          ),
        );

      case RetryRequested():
        final cur = q.current;
        if (cur == null) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.emptyQueue),
          );
        }
        _failureStreak = 0;
        return _newGeneration(
          s,
          state: _loading(cur, NetworkPhase.resolving, gen + 1),
        );

      case PlaybackTick():
        return s.copyWith(
          revision: s.revision + 1,
          position: event.position,
          buffered: event.buffered,
          duration: event.duration,
          clearDuration: event.duration == null,
          isPlaying: event.isPlaying,
        );
    }
  }

  PlayerSnapshot _newGeneration(
    PlayerSnapshot s, {
    PlayerState? state,
    QueueState? queue,
    String? engineError,
    bool clearEngineError = false,
    Duration? position,
    Duration? buffered,
    Duration? duration,
    bool clearDuration = false,
    bool? isPlaying,
  }) {
    final nextGen = s.generation + 1;
    return s.copyWith(
      state: state ?? s.state,
      queue: queue ?? s.queue,
      generation: nextGen,
      revision: s.revision + 1,
      engineError: engineError,
      clearEngineError: clearEngineError,
      position: position,
      buffered: buffered,
      duration: duration,
      clearDuration: clearDuration,
      isPlaying: isPlaying,
    );
  }

  PlayerLoading _loading(Song song, NetworkPhase phase, int generation) =>
      PlayerLoading(
        song,
        phase: phase,
        startedAt: DateTime.now(),
        generation: generation,
      );

  PlayerFailure _failure(
    PlayerFailureReason reason, {
    Song? song,
    Object? error,
  }) {
    final what = switch (reason) {
      PlayerFailureReason.engineNotReady => '音频服务未就绪',
      PlayerFailureReason.emptyQueue => '播放队列是空的',
      PlayerFailureReason.invalidSong => '这首歌缺少可播放标识',
      PlayerFailureReason.invalidIndex => '队列位置已失效',
      PlayerFailureReason.resolveFailed => '播放地址解析失败',
      PlayerFailureReason.sourceFailed => '音频装载失败',
      PlayerFailureReason.seekRejected => '当前还不能拖动进度',
      PlayerFailureReason.queueChanged => '播放队列已变化',
    };
    final next = switch (reason) {
      PlayerFailureReason.engineNotReady => '请重启应用后重试',
      PlayerFailureReason.emptyQueue => '去首页选一首歌',
      PlayerFailureReason.invalidSong => '返回列表换一首歌',
      PlayerFailureReason.invalidIndex => '重新打开播放队列',
      PlayerFailureReason.resolveFailed => '点重试或换一首歌',
      PlayerFailureReason.sourceFailed => '点重试或切换音质',
      PlayerFailureReason.seekRejected => '等歌曲开始播放后再试',
      PlayerFailureReason.queueChanged => '返回列表重新选择',
    };
    return PlayerFailure(
      reason,
      whatHappened: error == null ? what : '$what（${error.runtimeType}）',
      nextAction: next,
      song: song,
      retry: null, // controller 注入，避免 core 层反向依赖 features（第 4 条）
    );
  }

  int? _nextIndex(QueueState q, Duration position, {required bool manual}) {
    if (q.isEmpty) return null;
    if (!manual && q.repeat == PlayerRepeatMode.one) return q.index;
    if (q.shuffle && q.length > 1) {
      final unplayed = <int>[
        for (var i = 0; i < q.length; i++)
          if (i != q.index && !q.history.contains(q.songs[i].hash)) i,
      ];
      if (unplayed.isEmpty) {
        // 一轮播完：清历史重新洗牌，但绝不立刻重复当前曲。
        final fresh = <int>[
          for (var i = 0; i < q.length; i++)
            if (i != q.index) i,
        ];
        fresh.shuffle();
        return fresh.first;
      }
      unplayed.shuffle();
      return unplayed.first;
    }
    final next = q.index + 1;
    if (next < q.length) return next;
    if (q.repeat == PlayerRepeatMode.all) return 0;
    return null;
  }

  /// 事件入口：返回 reducer 之后的快照（adapter 据此决定副作用）。
  PlayerSnapshot dispatch(PlayerEvent event) {
    final next = _reduce(_snapshot, event);
    if (!identical(next, _snapshot)) _emit(next);
    return next;
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  static int _clampIndex(int index, int length) {
    if (length == 0) return -1;
    return index < 0 ? 0 : (index >= length ? length - 1 : index);
  }

  static int _indexOfHash(List<Song> songs, String hash) {
    if (hash.isEmpty) return -1;
    for (var i = 0; i < songs.length; i++) {
      if (songs[i].hash == hash) return i;
    }
    return -1;
  }
}
