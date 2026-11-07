import 'dart:ui';

import '../../../core/image/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/l10n.dart';
import '../player_provider.dart';
import 'queue_sheet.dart';

/// 底部迷你播放器（高 64）。无播放内容时不显示。
///
/// 性能：播放进度每秒 tick 若干次，若整棵子树都跟着重建会浪费。
/// 这里把进度条拆成独立组件，只让它监听 position；
/// 其余部分仅在歌曲/播放状态变化时重建。
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  @override
  Widget build(BuildContext context) {
    final song = ref.watch(currentSongProvider).valueOrNull;
    if (song == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final controller = ref.read(playerControllerProvider);
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/player'),
        onLongPress: () => showQueueSheet(context),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55),
                border: Border(
                  top: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // 进度条独立：只有它随 position 重建
                  const _MiniProgressBar(),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      // V37-UI-07（P2-2）：小屏/大字号下 44 封面 + 3×48 按钮 +
                      // 文本会溢出 Row。用 LayoutBuilder 在窄宽度下降级为
                      // 紧凑布局（隐藏「队列」次操作，主/下一保留），不再硬溢出。
                      child: LayoutBuilder(builder: (context, constraints) {
                        final compact = constraints.maxWidth < 360;
                        final row = <Widget>[
                          Hero(
                            tag: 'album-art',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: song.cover.isNotEmpty
                                    ? CachedNetworkImage(
                                        cacheManager: AppImageCache.instance,
                                        imageUrl: song.cover,
                                        fit: BoxFit.cover,
                                        fadeInDuration:
                                            const Duration(milliseconds: 180),
                                        memCacheWidth: 132,
                                        errorWidget: (_, __, ___) =>
                                            const _MiniPlaceholder(),
                                      )
                                    : const _MiniPlaceholder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  song.artist.isEmpty
                                      ? context.l10n.unknownArtist
                                      : song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // 播放/暂停是主操作，用 filled 风格强调
                          IconButton.filled(
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            tooltip: isPlaying
                                ? context.l10n.pause
                                : context.l10n.play,
                            onPressed: controller.togglePlay,
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next_rounded),
                            tooltip: context.l10n.next,
                            onPressed: controller.next,
                          ),
                        ];
                        if (!compact) {
                          // 播放队列：显式入口（不只靠长按这一隐藏手势）；
                          // 窄宽度降级时仅保留长按手势入口
                          row.add(IconButton(
                            icon: const Icon(Icons.queue_music_rounded),
                            tooltip: context.l10n.playQueue,
                            onPressed: () => showQueueSheet(context),
                          ));
                        }
                        return Row(children: row);
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 迷你播放器顶部进度条：单独监听 position，避免整棵子树重建。
class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final total = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 2,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

class _MiniPlaceholder extends StatelessWidget {
  const _MiniPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.music_note_rounded, color: Colors.grey),
    );
  }
}
