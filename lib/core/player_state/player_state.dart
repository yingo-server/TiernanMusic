/// v5.3 P1：播放器状态机（唯一事实源）。
///
/// ## A-00 二选一定案
/// 审计 A-00 实锤：旧架构同时存在「未注册的 `TiernanAudioHandler`」与
/// `just_audio_background` 内部注册的 `_PlayerAudioHandler`，两套媒体会话
/// 互不相通，通知栏/锁屏/蓝牙指令永远到不了 App 队列。
///
/// 定案（选择「把同一个 Handler 注册进 AudioService.init」分支）：
/// - 弃用 `just_audio_background`；`AudioServiceBootstrap` 直接调用
///   `AudioService.init(builder: () => SwitchAudioHandler(...))`；
/// - 引擎就绪后 `AudioServiceBootstrap.attach(handler)` 把**唯一**的
///   `TiernanAudioHandler` 挂到该 SwitchAudioHandler.inner；
/// - 系统指令 → SwitchAudioHandler → 本 Handler → 状态机事件；
///   App 状态 → 本 Handler 的 queue/mediaItem/playbackState → 同一媒体会话。
/// - 用 `SwitchAudioHandler` 作桥是为了保留「Riverpod 就绪后才惰性构造
///   Handler」：AudioService.init 在 main() 早期调用，但那时没有 ref，
///   无法构造 PlayerRepository（这与插件原 LateInitialization 陷阱等价）。
///
/// `QueueHandler` mixin 弃用：`skipToQueueItem/skipToNext/skipToPrevious`
/// 全部显式 override 为状态机事件（A-01）；手写队列收进 [QueueState]。
///
/// 事实源只有一个：[PlayerSnapshot]（state + queue + generation）。
/// 高频遥测（position/duration/buffered/isPlaying）不进快照——它们由
/// `audioPlayerProvider` 的独立流承载，避免整页每 200ms 重建（原则 26）。
library;

import 'dart:async';

import '../domain/quality.dart';
import '../domain/song.dart';
import '../foundation/errors.dart';
import '../net/network_phase.dart';

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

/// 循环模式（与 just_audio.LoopMode 解耦，core 层不依赖平台枚举）。
enum PlayerRepeatMode { off, all, one }

/// sealed 状态：互斥，任何时刻只有一个（PLAN §二）。
sealed class PlayerState {
  const PlayerState();
}

final class PlayerIdle extends PlayerState {
  const PlayerIdle();
}

/// 解析/装载中。[phase] 让 >500ms 的阶段可见（原则 34）。
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

/// 20028 是一等公民（A-08）：保留 generation + song，
/// 验证通过 / 取消 / 队列替换三个退出事件都必须校验世代号。
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
  });

  final PlayerFailureReason reason;

  /// 「发生了什么」+「下一步动作」（原则 34 / PLAN 质量要求 4）。
  final String whatHappened;
  final String nextAction;

  /// 失败时若仍知道是哪首歌，UI 可保留封面/歌名而不是白屏。
  final Song? song;
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

  /// 随机模式已播 hash（显式边界：一轮内不重复；满一轮后重开）。
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

/// 对外唯一快照。仅包含**离散**事实；每次状态/队列/世代变化发一次。
final class PlayerSnapshot {
  const PlayerSnapshot({
    required this.state,
    required this.queue,
    required this.generation,
    required this.revision,
    this.engineError,
  });

  final PlayerState state;
  final QueueState queue;

  /// 世代号：所有异步边界携带它，迟到结果直接丢弃（原则 18）。
  final int generation;

  /// 同世代内的变更序号（供调试/日志，不参与语义）。
  final int revision;

  /// 引擎初始化失败原因；成功后必须清除（A-09）。
  final String? engineError;

  Song? get currentSong => queue.current;

  PlayerSnapshot copyWith({
    PlayerState? state,
    QueueState? queue,
    int? generation,
    int? revision,
    String? engineError,
    bool clearEngineError = false,
  }) {
    return PlayerSnapshot(
      state: state ?? this.state,
      queue: queue ?? this.queue,
      generation: generation ?? this.generation,
      revision: revision ?? this.revision,
      engineError: clearEngineError ? null : (engineError ?? this.engineError),
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

enum PlaySongPolicy { afterCurrent, append, replace }

final class PlaySongRequested extends PlayerEvent {
  const PlaySongRequested(this.song,
      {this.policy = PlaySongPolicy.afterCurrent});
  final Song song;
  final PlaySongPolicy policy;
}

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

/// 进度跳转：不改变 PlayerState，仅做三态前置校验（A-23）。
/// 真实 seek 由 adapter 在校验通过后执行 `AudioPlayer.seek`。
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

/// 系统媒体会话的播放/暂停/停止/跳转指令（A-00 定案后的唯一入口）。
final class SystemPlayRequested extends PlayerEvent {
  const SystemPlayRequested();
}

final class SystemPauseRequested extends PlayerEvent {
  const SystemPauseRequested();
}

final class SystemStopRequested extends PlayerEvent {
  const SystemStopRequested();
}

final class SystemSkipToNextRequested extends PlayerEvent {
  const SystemSkipToNextRequested();
}

final class SystemSkipToPreviousRequested extends PlayerEvent {
  const SystemSkipToPreviousRequested();
}

final class SystemSkipToQueueItemRequested extends PlayerEvent {
  const SystemSkipToQueueItemRequested(this.index);
  final int index;
}

final class SystemSeekRequested extends PlayerEvent {
  const SystemSeekRequested(this.positionMs);
  final int positionMs;
}

final class SystemSetShuffleModeRequested extends PlayerEvent {
  const SystemSetShuffleModeRequested(this.enabled);
  final bool enabled;
}

final class SystemSetRepeatModeRequested extends PlayerEvent {
  const SystemSetRepeatModeRequested(this.mode);
  final PlayerRepeatMode mode;
}

/// 状态机 reducer（纯函数 + 唯一可变字段 `_snapshot`）。
///
/// 并发纪律：事件在 Dart 单 isolate 事件循环里串行投递；每个异步边界
/// 携带 `generation`，迟到事件与当前世代不符直接丢弃（原则 18/22）。
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

  /// 单一状态流（每个订阅者先收到当前快照，再收后续变更）。
  ///
  /// 用 `Stream.multi` 而非裸 broadcast：broadcast 流在「读取当前值」
  /// 与「建立订阅」之间会丢事件，正是旧 `_pendingIndex` 挂起竞态的
  /// 同类陷阱（原则 18/20）。所有派生 provider 都从这条流投射。
  Stream<PlayerSnapshot> get snapshots =>
      Stream<PlayerSnapshot>.multi((controller) {
        controller.add(_snapshot);
        final sub = _controller.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = () {
          unawaited(controller.close());
          return sub.cancel();
        };
      });

  @Deprecated('使用 snapshots；broadcast 流仅供内部 emit')
  Stream<PlayerSnapshot> get stream => _controller.stream;

  /// 连续失败计数（有上限，原则 25）。
  static const int kMaxFailureStreak = 3;
  int _failureStreak = 0;

  /// 供 adapter 读取：completed 回调必须同时校验 generation + sourceId。
  int get generation => _snapshot.generation;
  String? get currentSourceId {
    final s = _snapshot.state;
    return s is PlayerPlaying ? s.sourceId : null;
  }

  void _emit(PlayerSnapshot next) {
    _snapshot = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  PlayerSnapshot dispatch(PlayerEvent event) {
    final next = _reduce(_snapshot, event);
    if (!identical(next, _snapshot)) _emit(next);
    return next;
  }

  PlayerSnapshot _reduce(PlayerSnapshot s, PlayerEvent event) {
    final gen = s.generation;
    final q = s.queue;
    switch (event) {
      case PlayQueueRequested():
        final items = List<Song>.unmodifiable(event.songs);
        if (items.isEmpty) {
          return _newGeneration(s,
              state: const PlayerIdle(), queue: const QueueState());
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
        _failureStreak = 0;
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
                items[existing] =
                    items[existing].copyWith(localPath: song.localPath);
              }
              index = existing;
            } else {
              items = List<Song>.of(q.songs);
              final insertAt = (q.index + 1).clamp(0, items.length);
              items.insert(insertAt, song);
              index = insertAt;
            }
        }
        _failureStreak = 0;
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
        final next = _nextIndex(q, manual: event.manual);
        if (next == null) {
          // 到尾且非列表循环：明确 Idle + 可见提示由 UI 投射（A-06）。
          return s.copyWith(revision: s.revision + 1, state: const PlayerIdle());
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
        var prev = q.index - 1;
        if (prev < 0) {
          prev = q.repeat == PlayerRepeatMode.all ? q.length - 1 : 0;
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
        // 只改 index，不重建 items（A-02 根因）。
        _failureStreak = 0;
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
        return s.copyWith(revision: s.revision + 1);

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
          state: _failure(event.reason, song: q.current, error: event.error),
        );

      case VerificationSuspended():
        if (event.generation != gen) return s;
        // 单次消费：已挂起时第二次 20028 不覆盖（A-08）。
        if (s.state is PlayerSuspended) return s;
        return s.copyWith(
          revision: s.revision + 1,
          state: PlayerSuspended(event.song, event.api, gen),
        );

      case VerificationPassed():
        final st = s.state;
        if (st is! PlayerSuspended ||
            st.generation != gen ||
            st.song.hash != event.songHash) {
          return s; // 队列已换 / 挂起已取消：不重播错歌
        }
        final idx = _indexOfHash(q.songs, event.songHash);
        if (idx < 0) {
          return s.copyWith(
            revision: s.revision + 1,
            state: _failure(PlayerFailureReason.queueChanged),
          );
        }
        _failureStreak = 0;
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
        return _newGeneration(s, state: PlayerPaused(cur, event.reason));

      case ResumeRequested():
        final st = s.state;
        if (st is! PlayerPaused) return s;
        // 不换 generation：adapter 据「世代未变 + Playing」只调 play()。
        return s.copyWith(
          revision: s.revision + 1,
          state: _playing(st.song, gen),
        );

      case StopRequested():
        _failureStreak = 0;
        return _newGeneration(
          s,
          state: const PlayerIdle(),
          queue: const QueueState(),
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

      case SystemPlayRequested():
        final st = s.state;
        if (st is PlayerPlaying) return s;
        if (st is PlayerPaused) return _reduce(s, const ResumeRequested());
        final cur = q.current;
        if (cur == null) return s;
        return _newGeneration(
          s,
          state: _loading(cur, NetworkPhase.resolving, gen + 1),
        );

      case SystemPauseRequested():
        return _reduce(s, const PauseRequested(reason: PlayerPauseReason.system));

      case SystemStopRequested():
        return _reduce(s, const StopRequested(fromSystem: true));

      case SystemSkipToNextRequested():
        return _reduce(s, const NextRequested(manual: true));

      case SystemSkipToPreviousRequested():
        return _reduce(s, const PreviousRequested());

      case SystemSkipToQueueItemRequested():
        return _reduce(
            s, SkipToQueueItemRequested(event.index, fromSystem: true));

      case SystemSeekRequested():
        return _reduce(s, SeekToRequested(event.positionMs));

      case SystemSetShuffleModeRequested():
        return _reduce(s, ShuffleModeChanged(event.enabled));

      case SystemSetRepeatModeRequested():
        return _reduce(s, RepeatModeChanged(event.mode));
    }
  }

  PlayerSnapshot _newGeneration(
    PlayerSnapshot s, {
    PlayerState? state,
    QueueState? queue,
    String? engineError,
    bool clearEngineError = false,
  }) {
    return s.copyWith(
      state: state ?? s.state,
      queue: queue ?? s.queue,
      generation: s.generation + 1,
      revision: s.revision + 1,
      engineError: engineError,
      clearEngineError: clearEngineError,
    );
  }

  PlayerPlaying _playing(Song song, int generation) => PlayerPlaying(
        song,
        isPreview: false,
        quality: song.quality,
        sourceId: '$generation:${song.hash}',
      );

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
    );
  }

  int? _nextIndex(QueueState q, {required bool manual}) {
    if (q.isEmpty) return null;
    if (!manual && q.repeat == PlayerRepeatMode.one) return q.index;
    if (q.shuffle && q.length > 1) {
      final unplayed = <int>[
        for (var i = 0; i < q.length; i++)
          if (i != q.index && !q.history.contains(q.songs[i].hash)) i,
      ];
      if (unplayed.isEmpty) {
        // 一轮播完：清历史重开一轮，但绝不立刻重复当前曲。
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
