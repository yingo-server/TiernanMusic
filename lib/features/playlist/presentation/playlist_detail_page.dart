import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
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

class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(playlistDetailProvider(id));
    final tracksAsync = ref.watch(playlistTracksProvider(id));
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
                  : SliverList(
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
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
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
