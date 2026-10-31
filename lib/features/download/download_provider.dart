import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/direct/kg_providers.dart';
import '../../core/providers.dart';
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

  /// 写入策略（首次下载时确定，之后复用）
  StorageStrategy _strategy = StorageStrategy.mediaStore;
  bool _strategyResolved = false;

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
    final newTask = task.copyWith(
      status: DownloadTaskStatus.queued,
      clearError: true,
      createdAt: exists ? task.createdAt : now,
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
    if (task.status == DownloadTaskStatus.completed) return;
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
    if (task != null) {
      await PublicMediaStore.instance.delete(
        PublicMediaStore.PublishedFile(
          uri: task.mediaUri.isEmpty ? null : task.mediaUri,
          path: task.filePath.isEmpty ? null : task.filePath,
        ),
      );
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => t.id != id).toList(),
    );
    await DownloadStore.remove(id);
    unawaited(_schedule());
  }

  /// 清空所有任务与文件
  Future<void> clearAll() async {
    for (final t in state.tasks) {
      _tokens[t.id]?.cancel('cleared');
      await PublicMediaStore.instance.delete(
        PublicMediaStore.PublishedFile(
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
      final tempPath = '${tempDir.path}/${task.hash}_${task.type.name}'
          '${task.type.fileExtension}';

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

      switch (task.type) {
        case DownloadTaskType.audio:
          final url = await _repo.resolveAudioUrl(
            task.hash,
            albumId: task.albumId,
            albumAudioId: task.albumAudioId,
            quality: task.quality,
          );
          await _repo.downloadFile(url, tempPath,
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

      // 发布到公共目录（MediaStore / 公共路径）
      final published = await _repo.publish(task, tempPath, strategy: _strategy);
      final size = await File(tempPath).exists() ? await File(tempPath).length() : 0;

      final cur = _find(task.id);
      if (cur != null) {
        _update(cur.copyWith(
          status: DownloadTaskStatus.completed,
          filePath: published.path ?? '',
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
      final cur = _find(task.id);
      if (cur != null) {
        _update(cur.copyWith(
          status: DownloadTaskStatus.failed,
          error: '$e',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } finally {
      _tokens.remove(task.id);
      _running.remove(task.id);
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
