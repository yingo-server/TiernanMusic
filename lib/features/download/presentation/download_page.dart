import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/toast.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../l10n/l10n.dart';
import '../data/download_task.dart';
import '../data/public_media_store.dart';
import '../download_provider.dart';

/// 下载管理页：任务列表、进度条、暂停/继续/删除。
class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends ConsumerState<DownloadPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从系统设置授权返回时，重置写入策略缓存并重新检测
    ref.read(downloadManagerProvider.notifier).onAppLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
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
                // 危险操作：二次确认 + error 色强调
                final ok = await showDestructiveConfirm(
                  context,
                  title: context.l10n.downloadClearAll,
                  message: context.l10n.downloadDeleteConfirm,
                  confirmLabel: context.l10n.confirm,
                );
                if (ok) await manager.clearAll();
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

/// 统一的 PopupMenu 项：图标 + 文案（不用 ListTile 嵌套，避免多余内边距）。
PopupMenuItem<String> _menuItem({
  required IconData icon,
  required String label,
  required String value,
  bool destructive = false,
}) {
  return PopupMenuItem<String>(
    value: value,
    child: Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final color =
            destructive ? scheme.error : scheme.onSurfaceVariant;
        return Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              label,
              style: destructive ? TextStyle(color: scheme.error) : null,
            ),
          ],
        );
      },
    ),
  );
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
      DownloadTaskType.cover => context.l10n.downloadCoverLabel,
      DownloadTaskType.lyric => context.l10n.downloadLyricLabel,
      DownloadTaskType.mv => context.l10n.downloadMvLabel,
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
          // 降级路径（Android/data）：提示用户文件在应用私有目录
          if (task.status == DownloadTaskStatus.completed &&
              task.filePath.contains('/Android/data/'))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                context.l10n.downloadFallbackHint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
      // 多个操作（暂停/继续/重试/打开/删除）收进 PopupMenuButton
      trailing: PopupMenuButton<String>(
        tooltip: context.l10n.moreActions,
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
              final opened = await PublicMediaStore.instance.open(
                PublishedFile(
                  uri: task.mediaUri.isEmpty ? null : task.mediaUri,
                  path: task.filePath.isEmpty ? null : task.filePath,
                ),
              );
              if (!opened && context.mounted) {
                Toast.show(context, context.l10n.downloadOpenFileFailed);
              }
              break;
            case 'folder':
              final ok = await PublicMediaStore.instance.viewFolder(
                PublishedFile(
                  uri: task.mediaUri.isEmpty ? null : task.mediaUri,
                  path: task.filePath.isEmpty ? null : task.filePath,
                ),
              );
              if (!ok && context.mounted) {
                // 多数文件管理器不支持以 FileProvider uri 打开目录，
                // 失败时复制路径到剪贴板作为兜底
                final path = task.filePath.isNotEmpty
                    ? task.filePath
                    : task.displayPath;
                await Toast.copy(context, path);
              }
              break;
            case 'delete':
              // 危险操作：error 色 + 二次确认 Dialog
              final ok = await showDestructiveConfirm(
                context,
                title: context.l10n.delete,
                message: context.l10n.downloadDeleteConfirm,
                confirmLabel: context.l10n.delete,
              );
              if (ok) await manager.remove(task.id);
              break;
          }
        },
        itemBuilder: (context) => [
          if (task.status == DownloadTaskStatus.running ||
              task.status == DownloadTaskStatus.queued)
            _menuItem(
              icon: Icons.pause_rounded,
              label: context.l10n.downloadPause,
              value: 'pause',
            ),
          if (task.status == DownloadTaskStatus.paused)
            _menuItem(
              icon: Icons.play_arrow_rounded,
              label: context.l10n.downloadResume,
              value: 'resume',
            ),
          if (task.status == DownloadTaskStatus.failed)
            _menuItem(
              icon: Icons.refresh_rounded,
              label: context.l10n.downloadRetry,
              value: 'retry',
            ),
          if (task.status == DownloadTaskStatus.completed) ...[
            _menuItem(
              icon: Icons.open_in_new_rounded,
              label: context.l10n.openWithOtherApp,
              value: 'open',
            ),
            if (task.filePath.isNotEmpty)
              _menuItem(
                icon: Icons.folder_open_outlined,
                label: context.l10n.openInFileManager,
                value: 'folder',
              ),
          ],
          // 删除是危险操作：error 色
          _menuItem(
            icon: Icons.delete_outline,
            label: context.l10n.delete,
            value: 'delete',
            destructive: true,
          ),
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
