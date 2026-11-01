import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
import '../../../core/utils/toast.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../l10n/l10n.dart';
import '../../download/presentation/download_sheet.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../data/playlist_repository.dart';

/// 歌单仓库（用全局直连/回退客户端构造，之前是 throw 导致歌单页必然失败）
final playlistRepositoryProvider = Provider<PlaylistRepository>(
    (ref) => PlaylistRepository(ref.watch(kugouApiClientProvider)));

final _playlistRepoProvider = playlistRepositoryProvider;

final playlistDetailProvider = FutureProvider.family
    .autoDispose<PlaylistDetail, String>((ref, id) {
  return ref.watch(_playlistRepoProvider).fetchDetail(id);
});

final playlistTracksProvider = FutureProvider.family
    .autoDispose<PlaylistTracks, String>((ref, id) {
  return ref.watch(_playlistRepoProvider).fetchTracks(id);
});

/// 歌单歌曲追加页（>100 首的公共歌单分页加载）
final _playlistMoreTracksProvider =
    FutureProvider.family.autoDispose<PlaylistTracks, _MoreTracksArgs>(
        (ref, args) {
  return ref
      .watch(_playlistRepoProvider)
      .fetchTracks(args.id, page: args.page);
});

class _MoreTracksArgs {
  _MoreTracksArgs(this.id, this.page);
  final String id;
  final int page;
}

/// 加载更多后手动触发 UI 重建的计数器
final _tracksReloadProvider = StateProvider<int>((ref) => 0);

class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(playlistDetailProvider(id));
    final tracksAsync = ref.watch(playlistTracksProvider(id));
    // 加载更多后 bump 触发本页重建（ songs 列表是本地可变对象，直接展示）
    ref.watch(_tracksReloadProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(
          error: e,
          onRetry: () => ref.invalidate(playlistDetailProvider(id)),
        ),
        data: (detail) => CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              actions: [
                // 评论入口（detail.id 来自 global_collection_id）
                IconButton(
                  icon: const Icon(Icons.comment_outlined),
                  tooltip: context.l10n.comments,
                  onPressed: () => context.push(
                      '/comments/playlist/${Uri.encodeComponent(detail.id)}'),
                ),
                // 收藏 / 取消收藏（之前仓库方法是死代码，无任何入口）
                IconButton(
                  icon: const Icon(Icons.favorite_border),
                  tooltip: context.l10n.favorite,
                  onPressed: () => _collectPlaylist(context, ref, detail),
                ),
                const SizedBox(width: 4),
              ],
              flexibleSpace: FlexibleSpaceBar(
                title: Text(
                  detail.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                ),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (detail.cover.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: detail.cover,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            Container(color: theme.colorScheme.surfaceContainerHighest),
                      )
                    else
                      Container(color: theme.colorScheme.surfaceContainerHighest),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      bottom: 56,
                      right: 16,
                      child: Row(
                        children: [
                          _InfoChip(Icons.play_arrow,
                              context.l10n.playCountSuffix(detail.playCount)),
                          const SizedBox(width: 12),
                          _InfoChip(Icons.music_note,
                              context.l10n.trackCountSuffix(detail.trackCount)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 简介：M3 规范「可展开内容」用 ExpansionTile，
            // 而不是自定义的「展开/收起」按钮。
            if (detail.intro.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(
                      context.l10n.playlistIntro,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                    subtitle: Text(
                      detail.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          detail.intro,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                theme.colorScheme.onSurface.withValues(alpha: 0.75),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                // 主操作：FilledButton（播放全部）
                child: FilledButton.icon(
                  onPressed: () {
                    final tracks = ref.read(playlistTracksProvider(id)).value;
                    if (tracks != null && tracks.songs.isNotEmpty) {
                      ref.read(playHelperProvider).playPlaylistQueue(
                          tracks.songs, 0, cover: detail.cover);
                    }
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: Text(context.l10n.playAll),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            tracksAsync.when(
              loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 200, child: ListSkeleton())),
              error: (e, _) => SliverToBoxAdapter(
                child: SizedBox(
                  height: 200,
                  child: ErrorRetry(
                    error: e,
                    onRetry: () => ref.invalidate(playlistTracksProvider(id)),
                  ),
                ),
              ),
              data: (tracks) => tracks.songs.isEmpty
                  ? SliverToBoxAdapter(
                      child: SizedBox(
                        height: 200,
                        child: EmptyState(
                          icon: Icons.queue_music_outlined,
                          message: context.l10n.noSongsInPlaylist,
                        ),
                      ),
                    )
                  : _buildTracksSlivers(context, ref, detail, tracks, theme),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  /// 歌曲列表 + 截断提示/加载更多（>100 首的公共歌单不再静默截断）
  Widget _buildTracksSlivers(BuildContext context, WidgetRef ref,
      PlaylistDetail detail, PlaylistTracks tracks, ThemeData theme) {
    final truncated = tracks.total > tracks.songs.length;
    return SliverMainAxisGroup(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final song = tracks.songs[index];
              return SongTile(
                title: song.name,
                artist: song.artist,
                duration: song.duration,
                onTap: () {
                  ref.read(playHelperProvider).playPlaylistQueue(
                      tracks.songs, index, cover: detail.cover);
                },
                // 多个次要操作收进「更多」菜单
                menuItems: [
                  SongTileMenuItem(
                    value: 'download',
                    label: context.l10n.download,
                    icon: Icons.download_outlined,
                  ),
                ],
                onMenuSelected: (v) {
                  if (v == 'download') {
                    showDownloadSheet(
                      context,
                      Song(
                        hash: song.hash,
                        albumAudioId: song.albumAudioId,
                        name: song.name,
                        artist: song.artist,
                        cover: song.cover,
                      ),
                    );
                  }
                },
              );
            },
            childCount: tracks.songs.length,
          ),
        ),
        // 截断提示 + 加载更多（直接 fetchTracks 第 2 页追加，简单实现）
        if (truncated)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                children: [
                  Text(
                    context.l10n
                        .onlyShowsFirstN(tracks.songs.length, tracks.total),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final nextPage =
                          (tracks.songs.length / 100).floor() + 1;
                      final args =
                          _MoreTracksArgs(detail.id, nextPage);
                      try {
                        final more =
                            await ref.read(_playlistMoreTracksProvider(args).future);
                        // 去重后追加（翻页间可能重复）
                        final seen =
                            tracks.songs.map((s) => s.hash).toSet();
                        final fresh = more.songs
                            .where((s) => seen.add(s.hash))
                            .toList();
                        tracks.songs.addAll(fresh);
                        if (context.mounted) {
                          // 追加成功，触发本页重建展示新歌曲
                          ref.read(_tracksReloadProvider.notifier).state++;
                        }
                      } catch (e) {
                        if (context.mounted) {
                          Toast.show(
                              context, context.l10n.operateFailed('$e'));
                        }
                      }
                    },
                    icon: const Icon(Icons.expand_more, size: 18),
                    label: Text(context.l10n.loadMore),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 收藏歌单（简单实现：仅收藏公共歌单，成功后 toast）
  Future<void> _collectPlaylist(
      BuildContext context, WidgetRef ref, PlaylistDetail detail) async {
    final confirm = await showDestructiveConfirm(
      context,
      title: context.l10n.favorite,
      message: context.l10n.collectPlaylistConfirm,
      confirmLabel: context.l10n.confirm,
    );
    if (!confirm) return;
    try {
      await ref.read(_playlistRepoProvider).collectPlaylist(
            name: detail.name,
            listCreateGid: detail.id, // global_collection_id
          );
      if (context.mounted) {
        Toast.show(context, context.l10n.collectSuccess);
      }
    } catch (e) {
      if (context.mounted) {
        Toast.show(context, context.l10n.operateFailed('$e'));
      }
    }
  }
}

/// 歌单信息角标（播放量 / 曲目数）。
class _InfoChip extends StatelessWidget {
  const _InfoChip(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.white)),
        ],
      ),
    );
  }
}
