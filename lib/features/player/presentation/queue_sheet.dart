import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/song_tile.dart';
../../../l10n/l10n.dart
import '../player_provider.dart';

/// 播放队列底部弹层（迷你播放器长按 / 全屏播放页队列按钮共用）。
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.7,
      child: QueueSheet(),
    ),
  );
}

class QueueSheet extends ConsumerWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final queue = ref.watch(queueProvider).value ?? const [];
    final current = ref.watch(currentSongProvider).value;
    final controller = ref.read(playerControllerProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.queue_music_rounded, size: 20),
              const SizedBox(width: 8),
              Text(context.l10n.nowPlaying,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(context.l10n.songCountSuffix(queue.length),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: queue.isEmpty
              ? EmptyState(
                  icon: Icons.queue_music_outlined,
                  message: context.l10n.queueEmpty,
                )
              : ListView.builder(
                  itemCount: queue.length,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemBuilder: (context, i) {
                    final s = queue[i];
                    final isCurrent = current?.hash == s.hash;
                    return ListTile(
                      selected: isCurrent,
                      selectedColor: theme.colorScheme.primary,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: s.cover.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: s.cover,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) =>
                                      const _QueuePlaceholder(),
                                )
                              : const _QueuePlaceholder(),
                        ),
                      ),
                      title: Text(s.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        s.artist.isEmpty ? context.l10n.unknownArtist : s.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isCurrent
                                ? null
                                : theme.colorScheme.onSurfaceVariant),
                      ),
                      trailing: isCurrent
                          ? Icon(Icons.graphic_eq_rounded,
                              size: 18, color: theme.colorScheme.primary)
                          : null,
                      onTap: () async {
                        Navigator.of(context).pop();
                        if (isCurrent) return;
                        await controller.playQueue(queue, i);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _QueuePlaceholder extends StatelessWidget {
  const _QueuePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.music_note_rounded, size: 20, color: Colors.grey),
    );
  }
}
