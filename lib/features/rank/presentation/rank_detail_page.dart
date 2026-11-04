import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/settings_provider.dart';
import '../../../l10n/l10n.dart';
import '../../../core/widgets/song_tile.dart';
import '../../player/data/models.dart' show Song;
import '../../player/play_helper.dart';
import '../data/rank_repository.dart';

/// 榜单详情（TOP500 / 国潮音乐榜 …）
class RankDetailPage extends ConsumerStatefulWidget {
  const RankDetailPage({super.key, required this.rankId, required this.name});

  final int rankId;
  final String name;

  @override
  ConsumerState<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends ConsumerState<RankDetailPage> {
  int _page = 1;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error; // UI-02（审查②）
  final List<RankSong> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ref
          .read(rankRepositoryProvider)
          .fetchRankSongs(widget.rankId, page: _page);
      if (!mounted) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(r.songs);
        _hasMore = _songs.length < r.total;
      });
    } catch (e) {
      if (!mounted) return;
      // UI-02（审查②）：记录错误态，渲染重试入口而非永久转圈
      setState(() => _error = e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(rankRepositoryProvider)
          .fetchRankSongs(widget.rankId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _songs.addAll(r.songs);
        _page++;
        _hasMore = _songs.length < r.total;
      });
    } catch (_) {
      // 静默：保留已有列表
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _play(int index) {
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
    if (songs.isEmpty) return;
    ref.read(playHelperProvider).playQueue(songs, index);
    context.push('/player');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          if (_songs.isNotEmpty)
            IconButton(
              tooltip: context.l10n.playAll,
              icon: const Icon(Icons.play_arrow),
              onPressed: () => _play(0),
            ),
        ],
      ),
      body: _songs.isEmpty
          ? (_error != null
              // UI-02（审查②）：错误态给重试入口，不再永久转圈
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.l10n.loadFailed),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _load();
                        },
                        child: Text(context.l10n.reload),
                      ),
                    ],
                  ),
                )
              : const Center(child: CircularProgressIndicator()))
          : ListView.builder(
              itemCount: _songs.length + 1,
              itemBuilder: (context, i) {
                if (i == _songs.length) {
                  if (_loadingMore) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (_hasMore) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: OutlinedButton.icon(
                          onPressed: _loadMore,
                          icon: const Icon(Icons.expand_more, size: 18),
                          label: Text(context.l10n.loadMore),
                        ),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        context.l10n.noMore,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }
                final s = _songs[i];
                return SongTile(
                  title: s.name,
                  artist: s.artist,
                  cover: s.cover,
                  duration: s.duration.inSeconds,
                  onTap: () => _play(i),
                  trailing: s.mvHash.isEmpty
                      ? null
                      : IconButton(
                          tooltip: context.l10n.mv,
                          icon: const Icon(Icons.movie_outlined),
                          onPressed: () => context.push('/mv/${s.mvHash}'),
                        ),
                );
              },
            ),
    );
  }
}
