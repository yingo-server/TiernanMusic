import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/song_tile.dart';
import '../../../l10n/l10n.dart';
import '../data/download_task.dart';
import '../data/public_media_store.dart';
import '../download_provider.dart';

/// 下载管理页：任务列表、进度条、暂停/继续/删除。
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.downloadManagement),
        actions: [
          if (state.tasks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: context.l10n.downloadClearAll,
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(context.l10n.downloadClearAll),
                    content: Text(context.l10n.downloadDeleteConfirm),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(context.l10n.cancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(context.l10n.confirm),
                      ),
                    ],
                  ),
                );
                if (ok == true) await manager.clearAll();
              },
            ),
        ],
      ),
      body: state.tasks.isEmpty
          ? EmptyState(
              icon: Icons.download_for_offline_outlined,
              message: context.l10n.noDownloads,
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: state.tasks.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final task = state.tasks[index];
                return _DownloadTile(task: task);
              },
            ),
    );
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final manager = ref.read(downloadManagerProvider.notifier);
    final progress = task.progress;

    final typeLabel = switch (task.type) {
      DownloadTaskType.audio => context.l10n.downloadAudio,
      DownloadTaskType.cover => context.l10n.downloadCover,
      DownloadTaskType.lyric => context.l10n.downloadLyric,
      DownloadTaskType.mv => context.l10n.downloadMv,
    };

    final statusLabel = switch (task.status) {
      DownloadTaskStatus.queued => context.l10n.downloadQueued,
      DownloadTaskStatus.running => context.l10n.downloading,
      DownloadTaskStatus.paused => context.l10n.downloadPaused,
      DownloadTaskStatus.completed => context.l10n.downloadCompleted,
      DownloadTaskStatus.failed => context.l10n.downloadFailed,
    };

    return ListTile(
      leading: Icon(
        switch (task.type) {
          DownloadTaskType.audio => Icons.music_note,
          DownloadTaskType.cover => Icons.album_outlined,
          DownloadTaskType.lyric => Icons.lyrics_outlined,
          DownloadTaskType.mv => Icons.movie_outlined,
        },
        color: theme.colorScheme.primary,
      ),
      title: Text(
        task.title.isEmpty ? task.hash : task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$typeLabel · $statusLabel'
            '${task.error != null ? ' · ${task.error}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (task.status == DownloadTaskStatus.running ||
              task.status == DownloadTaskStatus.paused)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: progress),
            ),
          if (task.status == DownloadTaskStatus.completed &&
              task.displayPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                task.displayPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'pause':
              await manager.pause(task.id);
              break;
            case 'resume':
              await manager.resume(task.id);
              break;
            case 'retry':
              await manager.retry(task.id);
              break;
            case 'open':
              await PublicMediaStore.instance.open(
                PublishedFile(
                  uri: task.mediaUri.isEmpty ? null : task.mediaUri,
                  path: task.filePath.isEmpty ? null : task.filePath,
                ),
              );
              break;
            case 'folder':
              await PublicMediaStore.instance.viewFolder(
                PublishedFile(
                  uri: task.mediaUri.isEmpty ? null : task.mediaUri,
                  path: task.filePath.isEmpty ? null : task.filePath,
                ),
              );
              break;
            case 'delete':
              await manager.remove(task.id);
              break;
          }
        },
        itemBuilder: (context) => [
          if (task.status == DownloadTaskStatus.running ||
              task.status == DownloadTaskStatus.queued)
            PopupMenuItem(value: 'pause', child: Text(context.l10n.downloadPause)),
          if (task.status == DownloadTaskStatus.paused)
            PopupMenuItem(value: 'resume', child: Text(context.l10n.downloadResume)),
          if (task.status == DownloadTaskStatus.failed)
            PopupMenuItem(value: 'retry', child: Text(context.l10n.downloadRetry)),
          if (task.status == DownloadTaskStatus.completed) ...[
            PopupMenuItem(
                value: 'open', child: Text(context.l10n.openWithOtherApp)),
            if (task.filePath.isNotEmpty)
              PopupMenuItem(
                  value: 'folder', child: Text(context.l10n.openInFileManager)),
          ],
          PopupMenuItem(value: 'delete', child: Text(context.l10n.delete)),
        ],
      ),
      onTap: () {
        if (task.status == DownloadTaskStatus.completed) {
          PublicMediaStore.instance.open(
            PublishedFile(
              uri: task.mediaUri.isEmpty ? null : task.mediaUri,
              path: task.filePath.isEmpty ? null : task.filePath,
            ),
          );
        }
      },
    );
  }
}
