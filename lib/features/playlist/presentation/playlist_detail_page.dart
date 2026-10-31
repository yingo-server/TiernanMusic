import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../core/widgets/song_tile.dart';
import '../../player/play_helper.dart';
import '../data/playlist_repository.dart';

final _playlistRepoProvider =
    Provider<PlaylistRepository>((ref) => throw UnimplementedError());

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
          message: '$e',
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
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
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
            if (detail.intro.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    detail.intro,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
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
                    message: '$e',
                    onRetry: () => ref.invalidate(playlistTracksProvider(id)),
                  ),
                ),
              ),
              data: (tracks) => SliverList(
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

  String _formatCount(int count) {
    if (count >= 100000000) return '${(count / 100000000).toStringAsFixed(1)}亿';
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
    return '$count';
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
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
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}
