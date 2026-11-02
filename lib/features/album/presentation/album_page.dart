import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/image/app_image_cache.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../l10n/l10n.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../data/album_repository.dart';

/// 专辑页：详情 + 歌曲列表。
///
/// `/album/detail` 的 `data` 是**数组**；
/// `/album/songs` 的歌曲是**嵌套结构**（base/audio_info/album_info/authors/mvdata），
/// 见 `album_repository.dart` 的说明。
class AlbumPage extends ConsumerStatefulWidget {
  const AlbumPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  late Future<AlbumInfo> _info;
  final List<AlbumSong> _songs = [];
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _info = _fetchInfo();
    _loadSongs(refresh: true);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) _loadSongs();
  }

  Future<AlbumInfo> _fetchInfo() =>
      ref.read(albumRepositoryProvider).fetchDetail(widget.id);

  Future<void> _loadSongs({bool refresh = false}) async {
    if (refresh) {
      _page = 1;
      _total = 0;
      _error = null;
      setState(() {
        _songs.clear();
        _loading = true;
      });
    } else {
      if (_loadingMore || _loading) return;
      if (_total > 0 && _songs.length >= _total) return;
      setState(() => _loadingMore = true);
    }
    try {
      final res =
          await ref.read(albumRepositoryProvider).fetchSongs(widget.id, page: _page);
      if (!mounted) return;
      setState(() {
        _songs.addAll(res.songs);
        _total = res.total;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e;
      });
    }
  }

  void _playAt(int index) {
    final songs = _songs
        .map((s) => Song(
              hash: s.hash,
              albumId: s.albumId,
              albumAudioId: s.albumAudioId,
              name: s.name,
              artist: s.artist,
              cover: s.cover,
              duration: s.duration,
            ))
        .toList();
    ref.read(playHelperProvider).playQueue(songs, index);
    context.push('/player');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: FutureBuilder<AlbumInfo>(
        future: _info,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Scaffold(
              appBar: AppBar(),
              body: ErrorRetry(
                error: snap.error,
                onRetry: () => setState(() => _info = _fetchInfo()),
              ),
            );
          }
          final info = snap.data!;

          return CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: Text(info.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: [
                  IconButton(
                    tooltip: context.l10n.comments,
                    icon: const Icon(Icons.comment_outlined),
                    onPressed: () => context
                        .push('/comments/album/${Uri.encodeComponent(info.id)}'),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 120,
                          height: 120,
                          child: info.cover.isEmpty
                              ? Container(
                                  color: theme.colorScheme.surfaceContainerHighest)
                              : CachedNetworkImage(
                                  imageUrl: info.cover,
                                  cacheManager: AppImageCache.instance,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 360,
                                  placeholder: (_, __) => Container(
                                    color:
                                        theme.colorScheme.surfaceContainerHighest,
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    color:
                                        theme.colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.album_outlined),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              info.name,
                              style: theme.textTheme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              info.artist,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.primary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (info.publishDate.isNotEmpty) info.publishDate,
                                if (info.language.isNotEmpty) info.language,
                                '${_total} ${context.l10n.tabSongs}',
                              ].join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 10),
                            FilledButton.tonalIcon(
                              onPressed: _songs.isEmpty ? null : () => _playAt(0),
                              icon: const Icon(Icons.play_arrow),
                              label: Text(context.l10n.playAll),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading && _songs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && _songs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetry(
                    error: _error,
                    onRetry: () => _loadSongs(refresh: true),
                  ),
                )
              else if (_songs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.music_note_outlined,
                    title: context.l10n.noData,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: _songs.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _songs.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final s = _songs[i];
                    return SongTile(
                      title: s.name,
                      artist: s.artist,
                      cover: s.cover,
                      duration: s.duration,
                      subtitleTrailing: i == 0 ? null : null,
                      onTap: () => _playAt(i),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
