import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/image/app_image_cache.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../l10n/l10n.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../data/artist_repository.dart';

/// 歌手页：详情 + 单曲（可切最新/最热）+ 专辑。
///
/// 数据来源见 docs/api_samples：`/artist/detail`、`/artist/audios`、`/artist/albums`。
/// 注意 `/artist/audios` 的歌曲是**扁平结构**，名字字段是 `audio_name`。
class ArtistPage extends ConsumerStatefulWidget {
  const ArtistPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late Future<ArtistInfo> _info;

  /// 单曲列表（自己管理分页，`/artist/audios` 每页上限 100）。
  final List<ArtistSong> _songs = [];
  int _page = 1;
  int _total = 0;
  String _sort = 'new';
  bool _loadingSongs = false;

  /// ART-R8（第 C 批，P1）：歌曲列表世代号——排序切换/refresh 会作废
  /// 在途请求，await 返回后必须校验，否则旧排序数据混入新列表并污染
  /// 分页计数（第 18 条）。
  int _songsGen = 0;
  bool _loadingMore = false;
  Object? _songsError;

  /// 专辑列表
  final List<ArtistAlbum> _albums = [];
  int _albumPage = 1;
  bool _loadedAlbums = false;
  bool _loadingAlbums = false;

  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _info = _fetchInfo();
    _loadSongs(refresh: true);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) _loadSongs();
  }

  Future<ArtistInfo> _fetchInfo() =>
      ref.read(artistRepositoryProvider).fetchDetail(widget.id);

  Future<void> _loadSongs({bool refresh = false}) async {
    if (refresh) {
      _songsGen++;
      _page = 1;
      _total = 0;
      _songsError = null;
      setState(() {
        _songs.clear();
        _loadingSongs = true;
      });
    } else {
      if (_loadingMore || _loadingSongs) return;
      if (_total > 0 && _songs.length >= _total) return;
      setState(() => _loadingMore = true);
    }
    final gen = _songsGen;
    try {
      final res = await ref
          .read(artistRepositoryProvider)
          .fetchSongs(widget.id, page: _page, sort: _sort);
      if (!mounted) return;
      if (gen != _songsGen) return; // 已被新排序/新 refresh 作废
      setState(() {
        _songs.addAll(res.songs);
        _total = res.total;
        _page += 1;
        _loadingSongs = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSongs = false;
        _loadingMore = false;
        _songsError = e;
      });
    }
  }

  Future<void> _loadAlbums() async {
    if (_loadingAlbums) return;
    setState(() => _loadingAlbums = true);
    try {
      final list = await ref
          .read(artistRepositoryProvider)
          .fetchAlbums(widget.id, page: _albumPage);
      if (!mounted) return;
      setState(() {
        _albums.addAll(list);
        _albumPage += 1;
        _loadingAlbums = false;
        _loadedAlbums = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingAlbums = false;
        _loadedAlbums = true;
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
              artist: s.artist.isEmpty ? _infoName : s.artist,
              cover: s.cover,
              duration: s.duration,
            ))
        .toList();
    ref.read(playHelperProvider).playQueue(songs, index);
    context.push('/player');
  }

  String _infoName = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: FutureBuilder<ArtistInfo>(
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
          _infoName = info.name;

          return NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverAppBar.large(
                pinned: true,
                title: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                flexibleSpace: FlexibleSpaceBar(
                  background: _Header(info: info),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarDelegate(
                  TabBar(
                    controller: _tab,
                    tabs: [
                      Tab(text: context.l10n.tabSongs),
                      Tab(text: context.l10n.albums),
                    ],
                    onTap: (i) {
                      if (i == 1 && !_loadedAlbums) _loadAlbums();
                    },
                  ),
                  theme.scaffoldBackgroundColor,
                ),
              ),
            ],
            body: TabBarView(
              controller: _tab,
              children: [
                _buildSongs(context),
                _buildAlbums(context),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSongs(BuildContext context) {
    if (_loadingSongs && _songs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_songsError != null && _songs.isEmpty) {
      return ErrorRetry(
        error: _songsError,
        onRetry: () => _loadSongs(refresh: true),
      );
    }
    if (_songs.isEmpty) {
      return EmptyState(
        icon: Icons.music_note_outlined,
        message: context.l10n.noData,
      );
    }

    return ListView.builder(
      controller: _scroll,
      itemCount: _songs.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _playAt(0),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(context.l10n.playAll),
                ),
                const Spacer(),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'new', label: Text(context.l10n.sortNew)),
                    ButtonSegment(value: 'hot', label: Text(context.l10n.sortHot)),
                  ],
                  selected: {_sort},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) {
                    setState(() => _sort = v.first);
                    _loadSongs(refresh: true);
                  },
                ),
              ],
            ),
          );
        }
        final s = _songs[i - 1];
        return SongTile(
          title: s.name,
          artist: s.artist,
          cover: s.cover,
          duration: s.duration.inSeconds,
          onTap: () => _playAt(i - 1),
        );
      },
    );
  }

  Widget _buildAlbums(BuildContext context) {
    if (_loadingAlbums && _albums.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_albums.isEmpty) {
      return EmptyState(
        icon: Icons.album_outlined,
        message: context.l10n.noData,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: _albums.length,
      itemBuilder: (context, i) {
        final a = _albums[i];
        return _AlbumCard(
          album: a,
          onTap: () => context.push('/album/${a.id}'),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info});

  final ArtistInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = artistImage(info.avatar, size: 480);

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 88,
                height: 88,
                child: avatar.isEmpty
                    ? Container(color: theme.colorScheme.surfaceContainerHighest)
                    : CachedNetworkImage(
                        imageUrl: avatar,
                        cacheManager: AppImageCache.instance,
                        fit: BoxFit.cover,
                        memCacheWidth: 264,
                        errorWidget: (_, __, ___) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.person_outline),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    info.name,
                    style: theme.textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${info.songCount} ${context.l10n.tabSongs} · '
                    '${info.albumCount} ${context.l10n.albums} · '
                    '${_fans(info.fans)} ${context.l10n.fansLabel}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 简介：实测 `intro` 是简述，`long_intro[]` 是详细分段
                  if (_introText(info).isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _IntroBlock(text: _introText(info)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 组合简介：优先详细分段（long_intro），否则用简述（intro）
  static String _introText(ArtistInfo info) {
    if (info.longIntro.isNotEmpty) return info.longIntro.join('\n\n');
    return info.intro;
  }

  static String _fans(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    return '$n';
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final ArtistAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = artistImage(album.cover, size: 480);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: cover.isEmpty
                  ? Container(color: theme.colorScheme.surfaceContainerHighest)
                  : CachedNetworkImage(
                      imageUrl: cover,
                      cacheManager: AppImageCache.instance,
                      fit: BoxFit.cover,
                      memCacheWidth: 400,
                      placeholder: (_, __) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.album_outlined),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            album.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          if (album.publishDate.isNotEmpty)
            Text(
              album.publishDate,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar, this.background);

  final TabBar tabBar;
  final Color background;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(color: background, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarDelegate old) =>
      old.tabBar != tabBar || old.background != background;
}

/// 歌手简介（可展开/收起）
class _IntroBlock extends StatefulWidget {
  const _IntroBlock({required this.text});
  final String text;

  @override
  State<_IntroBlock> createState() => _IntroBlockState();
}

class _IntroBlockState extends State<_IntroBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: _expanded ? null : 3,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (widget.text.length > 80)
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _expanded ? context.l10n.collapse : context.l10n.expand,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
