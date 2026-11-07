import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/preferred_quality.dart';
import '../../../l10n/l10n.dart';
import '../../player/data/models.dart';
import '../data/download_task.dart';
import '../download_provider.dart';

/// 打开单曲下载弹层。
Future<void> showDownloadSheet(BuildContext context, Song song) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DownloadSheet(song: song),
  );
}

/// 单曲下载弹层：音频 / 封面 / 歌词 / MV。
class DownloadSheet extends ConsumerWidget {
  const DownloadSheet({super.key, required this.song});
  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);
    final theme = Theme.of(context);

    final audioTask = manager.audioTaskOf(song.hash);

    DownloadTask buildTask(DownloadTaskType type) => DownloadTask(
          hash: song.hash,
          type: type,
          title: song.name,
          artist: song.artist,
          coverUrl: song.cover,
          albumId: song.albumId,
          albumAudioId: song.albumAudioId,
          // 音质：歌曲自带 > 用户默认设置（与播放链路同一事实源）
          quality: (song.quality != AudioQuality.q128
                  ? song.quality
                  : preferredQuality())
              .value,
          durationSec: song.duration.inSeconds,
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              song.name.isEmpty ? context.l10n.download : song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _OptionTile(
              icon: Icons.music_note,
              title: context.l10n.downloadAudio,
              task: audioTask,
              onDownload: () async {
                await manager.add(buildTask(DownloadTaskType.audio));
              },
            ),
            _OptionTile(
              icon: Icons.album_outlined,
              title: context.l10n.downloadCover,
              task: _taskOf(state.tasks, DownloadTaskType.cover),
              onDownload: () async {
                await manager.add(buildTask(DownloadTaskType.cover));
              },
            ),
            _OptionTile(
              icon: Icons.lyrics_outlined,
              title: context.l10n.downloadLyric,
              task: _taskOf(state.tasks, DownloadTaskType.lyric),
              onDownload: () async {
                await manager.add(buildTask(DownloadTaskType.lyric));
              },
            ),
            _OptionTile(
              icon: Icons.movie_outlined,
              title: context.l10n.downloadMv,
              task: _taskOf(state.tasks, DownloadTaskType.mv),
              onDownload: () async {
                await manager.add(buildTask(DownloadTaskType.mv));
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(context.l10n.downloadAll),
                onPressed: () async {
                  await manager.addAll([
                    buildTask(DownloadTaskType.audio),
                    buildTask(DownloadTaskType.cover),
                    buildTask(DownloadTaskType.lyric),
                  ]);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  DownloadTask? _taskOf(List<DownloadTask> tasks, DownloadTaskType type) {
    for (final t in tasks) {
      if (t.hash == song.hash && t.type == type) return t;
    }
    return null;
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.onDownload,
    this.task,
  });

  final IconData icon;
  final String title;
  final DownloadTask? task;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = task?.progress;
    final status = task?.status;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: progress != null &&
              (status == DownloadTaskStatus.running ||
                  status == DownloadTaskStatus.paused)
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: progress),
            )
          : null,
      trailing: status == DownloadTaskStatus.completed
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : status == DownloadTaskStatus.running
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.download_outlined),
                  // V37-UI-05：弹层行内下载按钮显式保证 48dp 触控区
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  onPressed: () => onDownload(),
                ),
    );
  }
}
