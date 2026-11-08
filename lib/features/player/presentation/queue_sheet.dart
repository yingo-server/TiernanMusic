import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/song_tile.dart';
import '../data/audio_handler.dart';
import '../../../core/domain/song.dart';
import '../player_provider.dart';
import '../../../l10n/l10n.dart';

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
    final controller = ref.read(playerControllerProvider);
    final current = ref.watch(currentSongProvider).valueOrNull;

    // V39-AUX-10（第 16 条）：加载中 / 失败 / 空队列是三个不同事实，
    // 不得把「流尚未发首值」和「确为空」合并成同一个空态。
    final queueAsync = ref.watch(queueProvider);

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
              Text(context.l10n.songCountSuffix(queueAsync.valueOrNull?.length ?? 0),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: queueAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorRetry(
              error: e,
              onRetry: () => ref.invalidate(queueProvider),
            ),
            data: (queue) => queue.isEmpty
                ? EmptyState(
                    icon: Icons.queue_music_outlined,
                    message: context.l10n.queueEmpty,
                  )
                : ListView.builder(
                    itemCount: queue.length,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemBuilder: (context, i) {
                      final s = queue[i];
                      // V39-AUX-09：isCurrent 必须双方 hash 均非空——
                      // Song.== 已保证空 hash 不相等，但字符串比较两边
                      // 都为 '' 时会误判，显式收口（第 3 条契约显式）。
                      final isCurrent = current != null &&
                          current.hash.isNotEmpty &&
                          current.hash == s.hash;
                      return ListTile(
                        selected: isCurrent,
                        selectedColor: theme.colorScheme.primary,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 2),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: s.cover.isNotEmpty
                                ? CachedNetworkImage(
                                    cacheManager: AppImageCache.instance,
                                    imageUrl: s.cover,
                                    fit: BoxFit.cover,
                                    // 44px 显示尺寸 × dpr，限制解码分辨率
                                    memCacheWidth: (44 *
                                            MediaQuery.devicePixelRatioOf(
                                                context))
                                        .round(),
                                    errorWidget: (_, __, ___) =>
                                        const _QueuePlaceholder(),
                                  )
                                : const _QueuePlaceholder(),
                          ),
                        ),
                        title: Text(s.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          s.artist.isEmpty
                              ? context.l10n.unknownArtist
                              : s.artist,
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
                        onTap: () => _onTap(context, ref, controller, s, i),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// V39-AUX-09（第 18 条世代校验）：弹层里 watch 到的列表只是快照，
  /// 停留期间队列可能被新的播放请求整体替换（audio_handler.playQueue
  /// 清空重灌 `_songs`）。旧快照 index 直接播放会指向错歌——
  /// `_playAt` 对越界只静默 return，用户表现为「点了没反应」。
  /// 点击时以 handler **当前**队列为准：与快照一致才按 index 播，
  /// 不一致则按 hash 在当前队列定位，定位不到给用户反馈。
  void _onTap(BuildContext context, WidgetRef ref,
      PlayerController controller, Song s, int snapshotIndex) {
    final handler = ref.read(audioHandlerProvider);
    final live = handler.songs;
    Navigator.of(context).pop();
    if (s.hash.isEmpty) {
      // 无 hash 的歌无法跨快照定位，按快照 index 播（快照一致时才有效）
      _play(controller, live, snapshotIndex);
      return;
    }
    var idx = -1;
    for (var i = 0; i < live.length; i++) {
      if (live[i].hash == s.hash) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      _play(controller, live, idx);
    } else if (context.mounted) {
      // 队列已变更且该歌不在新队列：可感知降级（第 9 条），不再静默
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.queueChangedHint)),
      );
    }
  }

  /// 越界防御（第 12 条）：显式范围检查，不做非空断言。
  void _play(PlayerController controller, List<Song> live, int idx) {
    if (idx < 0 || idx >= live.length) return;
    controller.playQueue(live, idx);
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
