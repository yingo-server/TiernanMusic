import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/direct/kg_crypto.dart';
import '../../core/direct/kg_providers.dart';
import '../../core/providers.dart';
import '../../core/utils/friendly_error.dart';
import '../mv/data/mv_repository.dart';
import 'data/download_repository.dart';
import 'data/download_store.dart';
import 'data/download_task.dart';
import 'data/public_media_store.dart';
import 'data/storage_permission_service.dart';

/// 下载状态快照。
class DownloadState {
  const DownloadState({this.tasks = const []});

  final List<DownloadTask> tasks;

  /// 全部任务（按时间倒序）
  List<DownloadTask> get all => tasks;

  /// 音频任务
  List<DownloadTask> get audios =>
      tasks.where((t) => t.type == DownloadTaskType.audio).toList();

  /// 已完成的任务
  List<DownloadTask> get completed => tasks
      .where((t) => t.status == DownloadTaskStatus.completed)
      .toList();

  /// 进行中的任务
  List<DownloadTask> get active => tasks
      .where((t) =>
          t.status == DownloadTaskStatus.queued ||
          t.status == DownloadTaskStatus.running)
      .toList();

  DownloadState copyWith({List<DownloadTask>? tasks}) =>
      DownloadState(tasks: tasks ?? this.tasks);
}

/// 下载管理器：队列 + 并发（最多 2 个）+ 持久化。
class DownloadManager extends StateNotifier<DownloadState> {
  DownloadManager(this._repo) : super(const DownloadState()) {
    _restore();
  }

  final DownloadRepository _repo;

  /// 最大并发下载数
  static const int maxConcurrent = 2;

  final Map<String, CancelToken> _tokens = {};
  final Set<String> _running = {};

  /// 写入策略（首次下载时确定；App resume 时重置后重新解析）
  StorageStrategy _strategy = StorageStrategy.mediaStore;
  bool _strategyResolved = false;

  AppLifecycleState? _lastLifecycle;

  /// App 生命周期回调：resume 时重置策略缓存。
  ///
  /// Android ≤9 用户首次拒绝授权后策略会锁定为 appFallback，
  /// 从系统设置授权返回时必须重新 resolveStrategy()，否则本次进程内
  /// 所有下载仍落到 Android/data（需重启 App 才能恢复）。
  void onAppLifecycle(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed &&
        _lastLifecycle == AppLifecycleState.paused) {
      _strategyResolved = false;
    }
    _lastLifecycle = s;
  }

  /// 从 Hive 恢复任务记录（未完成的置为暂停）
  void _restore() {
    final saved = DownloadStore.readAll();
    if (saved.isEmpty) return;
    final restored = saved.map((t) {
      if (t.status == DownloadTaskStatus.running ||
          t.status == DownloadTaskStatus.queued) {
        return t.copyWith(
          status: DownloadTaskStatus.paused,
          clearError: true,
        );
      }
      return t;
    }).toList();
    state = state.copyWith(tasks: restored);
  }

  /// 当前写入策略
  StorageStrategy get strategy => _strategy;

  /// 添加任务（同一 id 覆盖），并启动调度。
  Future<void> add(DownloadTask task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final exists = state.tasks.any((t) => t.id == task.id);
    // DL-03（审查③）：同 id 重复下载必须**取消旧任务**——否则旧 _run
    // 完成后会把新任务改回 completed（写旧音质的文件信息）。
    if (exists && _running.contains(task.id)) {
      _tokens[task.id]?.cancel('re-added');
      _tokens.remove(task.id);
      _running.remove(task.id);
    }
    // DL-12（审查③）：createdAt 用 now（新建任务默认 0，持久化排序会错乱）
    final newTask = task.copyWith(
      status: DownloadTaskStatus.queued,
      clearError: true,
      createdAt: now,
      updatedAt: now,
    );
    _replace(newTask);
    await DownloadStore.save(newTask);
    unawaited(_schedule());
  }

  /// 批量添加（歌曲 + 封面 + 歌词）
  Future<void> addAll(List<DownloadTask> tasks) async {
    for (final t in tasks) {
      await add(t);
    }
  }

  /// 暂停任务（取消网络请求，保留已下载进度信息）
  Future<void> pause(String id) async {
    final task = _find(id);
    if (task == null) return;
    _tokens[id]?.cancel('paused');
    _tokens.remove(id);
    _running.remove(id);
    _update(task.copyWith(
      status: DownloadTaskStatus.paused,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    unawaited(_schedule());
  }

  /// 继续（重新排队）
  Future<void> resume(String id) async {
    final task = _find(id);
    if (task == null) return;
    // 守卫：对 running/queued 任务重复 resume 会把状态改回 queued，
    // 导致进度条冻结（实际还在下载但状态不匹配）。
    if (task.status == DownloadTaskStatus.completed ||
        task.status == DownloadTaskStatus.running ||
        task.status == DownloadTaskStatus.queued) {
      return;
    }
    _update(task.copyWith(
      status: DownloadTaskStatus.queued,
      clearError: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    unawaited(_schedule());
  }

  /// 重试（失败任务）
  Future<void> retry(String id) => resume(id);

  /// 删除任务（同时删除公共目录中的文件）
  Future<void> remove(String id) async {
    final task = _find(id);
    _tokens[id]?.cancel('removed');
    _tokens.remove(id);
    _running.remove(id);
    // V37-04（B3 P1-1，第 18/21 条）：防「remove 与 _run 完成回调竞态
    // 复活已删任务」——本方法在 token 取消后有多处 await（删公共文件/
    // 清临时文件），期间被取消的 _run 的 catch/finally 可能正好执行
    // _update（其内部 guard `cur != null` 在此刻仍可能为真，因为任务
    // 尚未从 state 移除），把任务写回 state 与 Hive。因此在最终删除
    // state/Hive 记录前**二次确认任务仍在**：若已被复活（重新 save），
    // 删除仍会执行，但为彻底封死窗口，这里先把 token 表钉死空值，
    // 使迟到的 _update guard `_tokens[task.id] == token` 恒假。
    _tokens[id] = CancelToken()..cancel('removed-final');
    if (task != null) {
      await PublicMediaStore.instance.delete(
        PublishedFile(
          uri: task.mediaUri.isEmpty ? null : task.mediaUri,
          path: task.filePath.isEmpty ? null : task.filePath,
        ),
      );
      // DL-05（审查③）：连临时文件一起清（下载中/失败的任务不会有已发布文件）
      // V34-05（v3.4 审查①，P1）：audio 真实扩展名由服务端 extName 决定
      //（可能 .flac/.m4a），此前恒用 .mp3 重建路径 → 磁盘泄漏。修复：
      // 优先用任务持久化的 realTempPath，无则按 dimKey+默认扩展名重建
      //（与 _run 的 tempPath 生成规则一致）。
      try {
        final tmpDir = await PublicMediaStore.tempDir();
        final raw = '${task.hash}_${task.type.name}_${task.quality ?? ''}'
            '_${task.albumAudioId ?? ''}';
        final h = KgCrypto.md5(raw).substring(0, 12);
        final dimKey = '${task.hash}_${task.type.name}_$h';
        final candidates = <String>[
          if (task.realTempPath.isNotEmpty) task.realTempPath,
          '${tmpDir.path}/$dimKey${task.type.fileExtension}',
        ];
        for (final path in candidates) {
          final f = File(path);
          // （删除失败静默：临时目录会由系统回收）
          if (f.existsSync()) f.deleteSync();
        }
      } catch (_) {}
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => t.id != id).toList(),
    );
    await DownloadStore.remove(id);
    // V37-04（B3 P1-1）：收尾移除钉死的哨兵 token；迟到的 _run 回调
    // （guard `_tokens[task.id] == token`）自此恒假，不会再写回任务。
    if (identical(_tokens[id]?.isCancelled, true)) _tokens.remove(id);
    unawaited(_schedule());
  }

  /// 清空所有任务与文件
  Future<void> clearAll() async {
    for (final t in state.tasks) {
      _tokens[t.id]?.cancel('cleared');
      await PublicMediaStore.instance.delete(
        PublishedFile(
          uri: t.mediaUri.isEmpty ? null : t.mediaUri,
          path: t.filePath.isEmpty ? null : t.filePath,
        ),
      );
    }
    _tokens.clear();
    _running.clear();
    state = const DownloadState();
    await DownloadStore.clear();
  }

  /// 某首歌是否已下载音频
  bool hasAudio(String hash) => state.tasks.any((t) =>
      t.hash == hash &&
      t.type == DownloadTaskType.audio &&
      t.status == DownloadTaskStatus.completed);

  /// 某首歌的音频任务
  DownloadTask? audioTaskOf(String hash) {
    for (final t in state.tasks) {
      if (t.hash == hash && t.type == DownloadTaskType.audio) return t;
    }
    return null;
  }

  // ---------- 内部 ----------

  DownloadTask? _find(String id) {
    for (final t in state.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _replace(DownloadTask task) {
    final list = [...state.tasks];
    final idx = list.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      list[idx] = task;
    } else {
      list.insert(0, task);
    }
    state = state.copyWith(tasks: list);
  }

  void _update(DownloadTask task) {
    _replace(task);
    unawaited(DownloadStore.save(task));
  }

  /// 调度队列：并发不超过 [maxConcurrent]。
  Future<void> _schedule() async {
    while (_running.length < maxConcurrent) {
      final next = state.tasks.where((t) =>
          t.status == DownloadTaskStatus.queued &&
          !_running.contains(t.id));
      if (next.isEmpty) return;
      final task = next.first;
      _running.add(task.id);
      unawaited(_run(task));
    }
  }

  Future<void> _run(DownloadTask task) async {
    final token = CancelToken();
    _tokens[task.id] = token;
    _update(task.copyWith(
      status: DownloadTaskStatus.running,
      received: 0,
      total: 0,
      clearError: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    try {
      // 首次下载时确定写入策略（可能触发权限申请）
      if (!_strategyResolved) {
        _strategy = await StoragePermissionService.instance.resolveStrategy();
        _strategyResolved = true;
      }

      final tempDir = await PublicMediaStore.tempDir();
      // D-01（第6批③，P1）：临时文件名必须包含**全部影响内容的维度**
      //（QUALITY_STANDARD 第 23 条）——此前只含 hash+type，同一首歌
      // 先下 128k 再下 320k（或换 MV 清晰度）时两个流写同一个文件，
      // 交错写坏 →「下载成功但中途爆音/截断」。quality/albumAudioId
      // 都会影响产物内容，必须进键；文件名超长时用短 hash。
      final dimKey = () {
        final raw = '${task.hash}_${task.type.name}_${task.quality ?? ''}'
            '_${task.albumAudioId ?? ''}';
        final h = KgCrypto.md5(raw).substring(0, 12);
        return '${task.hash}_${task.type.name}_$h';
      }();
      final tempPath = '${tempDir.path}/$dimKey${task.type.fileExtension}';

      void onProgress(int received, int total) {
        final cur = _find(task.id);
        if (cur == null) return;
        if (cur.status != DownloadTaskStatus.running) return;
        _update(cur.copyWith(
          received: received,
          total: total,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }

      // DL-02（审查③）：audio 任务的真实扩展名（服务端 extName 决定）
      var realTempPath = tempPath;
      switch (task.type) {
        case DownloadTaskType.audio:
          // V3-11（复查）：一次解析同时拿 url + 扩展名（原来调两次 songUrl，
          // 请求翻倍且两次结果可能不一致）
          final (url, ext) = await _repo.resolveAudioUrlWithExt(
            task.hash,
            albumId: task.albumId,
            albumAudioId: task.albumAudioId,
            quality: task.quality,
          );
          realTempPath = tempPath.replaceAll(RegExp(r'\.mp3$'), ext);
          // V34-05（v3.4 审查①，P1）：持久化真实路径，remove() 按它清理
          _update(_find(task.id)?.copyWith(realTempPath: realTempPath) ??
              task.copyWith(realTempPath: realTempPath));
          await _repo.downloadFile(url, realTempPath,
              onProgress: onProgress, cancelToken: token);
          break;
        case DownloadTaskType.cover:
          if (task.coverUrl.isEmpty) {
            throw StateError('缺少封面地址');
          }
          await _repo.downloadCover(task.coverUrl, tempPath,
              onProgress: onProgress, cancelToken: token);
          break;
        case DownloadTaskType.lyric:
          await _repo.downloadLyric(task, tempPath,
              onProgress: onProgress, cancelToken: token);
          break;
        case DownloadTaskType.mv:
          final url = await _repo.resolveMvUrl(task.albumAudioId, task.mvHash);
          await _repo.downloadFile(url, tempPath,
              onProgress: onProgress, cancelToken: token);
          break;
      }

      // 发布到公共目录（MediaStore / 公共路径）。
      // 先查同名文件：已存在则删旧文件再发布，避免 MediaStore 自动改名
      // 产生 "xxx (1).mp3" 副本（旧文件不受任务管理）。
      final displayName = DownloadRepository.displayNameOf(task);
      final exist = await PublicMediaStore.instance.queryExisting(
        type: task.type,
        displayName: displayName,
      );
      if (exist != null) {
        await PublicMediaStore.instance.delete(exist);
      }
      final published =
          await _repo.publish(task, realTempPath, strategy: _strategy);
      final size = await File(realTempPath).exists()
          ? await File(realTempPath).length()
          : 0;

      final cur = _find(task.id);
      if (cur != null) {
        // DL-05（审查③）：发布成功后删除临时文件（tempPath 只在本方法内使用）
        try {
          final f = File(realTempPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
        _update(cur.copyWith(
          status: DownloadTaskStatus.completed,
          // Android 10+ 走 MediaStore，只有 uri（content://）可用；
          // ≤9 / 降级目录才有绝对路径。两者都存，播放时按形态分别处理。
          filePath: published.path ?? published.uri ?? '',
          mediaUri: published.uri ?? '',
          displayName: DownloadRepository.displayNameOf(task),
          displayPath: published.displayPath,
          received: size,
          total: cur.total > 0 ? cur.total : size,
          clearError: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } on DioException catch (e) {
      // DL-04（审查③）：与通用 catch 一致——旧 _run 的 cancel 异常
      // 不得污染 resume 后的新任务状态。
      if (_tokens[task.id] != token) return;
      final cur = _find(task.id);
      if (cur != null) {
        final cancelled = e.type == DioExceptionType.cancel;
        _update(cur.copyWith(
          status:
              cancelled ? DownloadTaskStatus.paused : DownloadTaskStatus.failed,
          error: cancelled ? null : (e.message ?? '下载失败'),
          clearError: cancelled,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } catch (e) {
      if (_tokens[task.id] != token) return;
      final cur = _find(task.id);
      if (cur != null) {
        _update(cur.copyWith(
          status: DownloadTaskStatus.failed,
          error: friendlyError(e),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } finally {
      if (_tokens[task.id] == token) _tokens.remove(task.id);
      // V3-01（复查 P0）：槽位归属校验写反导致正常完成时 _running 永不释放
      // （token 已删 → _tokens[id] != token 恒真 → 走"新任务接管"空分支），
      // 两次下载后队列彻底停摆。正确逻辑：
      //   - 新 _run 已接管（_running 有且 token 已易主）→ 不动；
      //   - 否则（正常完成 / 旧请求被取消）→ 释放。
      final tokenChanged = _tokens[task.id] != null &&
          _tokens[task.id] != token;
      if (_running.contains(task.id) && tokenChanged) {
        // 新 _run 已接管该任务：不要动它的槽
      } else {
        _running.remove(task.id);
      }
      unawaited(_schedule());
    }
  }
}

/// 下载仓库（直连播放接口 + 歌词 + MV）
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  return DownloadRepository(
    playApi: ref.watch(kgPlayApiProvider),
    lyricRepository: ref.watch(lyricRepositoryProvider),
    mvRepository: MvRepository(ref.watch(kugouApiClientProvider)),
  );
});

/// 下载管理器
final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, DownloadState>((ref) {
  return DownloadManager(ref.watch(downloadRepositoryProvider));
});

/// 已下载（完成）音频列表
final downloadedAudioProvider = Provider<List<DownloadTask>>((ref) {
  return ref
      .watch(downloadManagerProvider)
      .audios
      .where((t) => t.status == DownloadTaskStatus.completed)
      .toList();
});
