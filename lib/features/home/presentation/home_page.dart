import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../l10n/l10n.dart';

import '../../player/play_helper.dart';
import '../../player/data/models.dart';
import '../../download/presentation/download_sheet.dart';
import '../../../core/widgets/shimmer.dart';
import '../../../core/widgets/song_tile.dart';
import '../data/home_repository.dart';
import '../data/models.dart';


class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeAsync = ref.watch(homeDataProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: homeAsync.when(
          loading: () => const _HomeSkeleton(),
          error: (e, _) => _HomeError(
            error: e,
            onRetry: () => ref.invalidate(homeDataProvider),
          ),
          data: (data) => RefreshIndicator(
            // refresh.future 保留旧数据等待新结果（不闪回骨架屏），指示器跟随真实完成。
            onRefresh: () {
              // 清掉首页相关接口的 MemoryCache，避免 90s TTL 内"刷新无效果"。
              MemoryCache.instance
                  .removeWhere((k) => k.startsWith('/yueku') || k.startsWith('/top/playlist') || k.startsWith('/rank/list'));
              return ref.refresh(homeDataProvider.future);
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 大标题层级：M3 顶层页面用 SliverAppBar.large（headlineMedium），
                // 滚动后自动折叠为小标题栏。
                SliverAppBar.large(
                  title: Text(context.l10n.home),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: context.l10n.search,
                      onPressed: () => context.push('/search'),
                    ),
                  ],
                ),
                if (data.banners.isEmpty &&
                    data.dailyRecommend == null &&
                    data.playlists.isEmpty &&
                    data.ranks.isEmpty &&
                    data.songs.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.explore_outlined,
                      message: context.l10n.noRecommend,
                      actionLabel: context.l10n.reload,
                      onAction: () => ref.invalidate(homeDataProvider),
                    ),
                  ),
                if (data.banners.isNotEmpty)
                  SliverToBoxAdapter(child: _BannerCarousel(data.banners)),
                if (data.dailyRecommend != null &&
                    data.dailyRecommend!.isNotEmpty)
                  SliverToBoxAdapter(
                      child: _DailyRecommend(data.dailyRecommend!)),
                if (data.playlists.isNotEmpty) ...[
                  _sectionTitle(context, context.l10n.recommendedPlaylists),
                  SliverToBoxAdapter(child: _PlaylistRow(data.playlists)),
                ],
                if (data.ranks.isNotEmpty) ...[
                  _sectionTitle(context, context.l10n.topCharts),
                  SliverToBoxAdapter(child: _RankRow(data.ranks)),
                ],
                if (data.songs.isNotEmpty) ...[
                  _sectionTitle(context, context.l10n.newSongsRecommend),
                  SliverList.separated(
                    itemCount: data.songs.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 88),
                    itemBuilder: (context, i) =>
                        _SongTile(song: data.songs[i], queue: data.songs, index: i),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: SectionHeader(title: title),
    );
  }
}

// ---------- Banner ----------

class _BannerCarousel extends StatefulWidget {
  const _BannerCarousel(this.banners);
  final List<HomeBanner> banners;

  @override
  State<_BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<_BannerCarousel> {
  final _controller = PageController();
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  void _startAutoPlay() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || widget.banners.length < 2) return;
      // StatefulShellRoute 用 IndexedStack 保活：非当前 Tab 时不要后台翻页（省电、避免 setState 堆积）。
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      final next = (_index + 1) % widget.banners.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 150,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.banners.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                  imageUrl: widget.banners[i].imageUrl,
                  fit: BoxFit.cover,
                  memCacheWidth:
                      (400 * MediaQuery.devicePixelRatioOf(context)).round(),
                  placeholder: (_, __) => Container(
                      color: theme.colorScheme.surfaceContainerHighest),
                  errorWidget: (_, __, ___) =>
                      Container(color: theme.colorScheme.surfaceContainerHighest),
                ),
              ),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.banners.length; i++)
              Container(
                width: i == _index ? 16 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: i == _index
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------- 每日推荐 ----------

class _DailyRecommend extends ConsumerWidget {
  const _DailyRecommend(this.songs);
  final List<HomeSong> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.dailyRecommend),
        SizedBox(
          height: 110,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: songs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final s = songs[i];
              return SizedBox(
                width: 220,
                child: Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      ref.read(playHelperProvider).playHomeQueue(songs, i);
                      context.push('/player');
                    },
                    child: Row(
                      children: [
                        SizedBox(
                          width: 78,
                          height: 78,
                          child: CachedNetworkImage(
                            imageUrl: s.cover,
                            fit: BoxFit.cover,
                            memCacheWidth:
                                (78 * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            placeholder: (_, __) => Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest),
                            errorWidget: (_, __, ___) => const SizedBox(
                                width: 78,
                                height: 78,
                                child: Icon(Icons.music_note)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(s.singer,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------- 推荐歌单 ----------

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow(this.playlists);
  final List<HomePlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = playlists[i];
          return SizedBox(
            width: 130,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () =>
                          context.push('/playlist/${p.globalCollectionId}'),
                      child: CachedNetworkImage(
                        imageUrl: p.cover,
                        width: 130,
                        height: 130,
                        fit: BoxFit.cover,
                        memCacheWidth:
                            (130 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        placeholder: (_, __) => Container(
                          width: 130,
                          height: 130,
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 130,
                          height: 130,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.queue_music),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------- 排行榜 ----------

class _RankRow extends StatelessWidget {
  const _RankRow(this.ranks);
  final List<HomeRank> ranks;

  static Color _hue(int i) =>
      HSLColor.fromAHSL(1, (i * 67.0) % 360, 0.65, 0.42).toColor();

  static Color _hue2(int i) =>
      HSLColor.fromAHSL(1, ((i + 1) * 67.0) % 360, 0.7, 0.28).toColor();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: ranks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final r = ranks[i];
          final c = _hue(i);
          return SizedBox(
            width: 200,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => context.push('/playlist/${r.id}'),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 渐变主题色背景（每张不同色相）
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [c, _hue2(i)],
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: 0.5,
                        child: CachedNetworkImage(
                          imageUrl: r.cover,
                          fit: BoxFit.cover,
                          colorBlendMode: BlendMode.luminosity,
                          memCacheWidth:
                              (200 * MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          placeholder: (_, __) => const SizedBox.shrink(),
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                          child: Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------- 歌曲 ----------

class _SongTile extends ConsumerWidget {
  const _SongTile({required this.song, this.queue, this.index = 0});
  final HomeSong song;
  final List<HomeSong>? queue;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SongTile(
      title: song.name,
      artist: song.singer,
      cover: song.cover,
      duration: song.duration,
      onTap: () {
        final helper = ref.read(playHelperProvider);
        if (queue != null) {
          helper.playHomeQueue(queue!, index);
        } else {
          helper.playHomeSong(song);
        }
        context.push('/player');
      },
      // M3 规范：列表项多个操作收进 PopupMenuButton，trailing 只留时长。
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
              hash: song.hash ?? song.id,
              albumId: song.albumId ?? '',
              albumAudioId: song.albumAudioId ?? '',
              name: song.name,
              artist: song.singer,
              cover: song.cover,
              duration: Duration(seconds: song.duration),
            ),
          );
        }
      },
    );
  }
}

// ---------- 骨架屏 & 错误 ----------

/// 骨架屏：与内容页同为 CustomScrollView + SliverAppBar.large 结构，
/// 各区块尺寸对齐（歌单 180、SectionHeader padding 20/8），切换时不跳动。
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget header(String width) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SkeletonText(width: width),
        );
    return Shimmer(
      baseColor: scheme.surface,
      highlightColor:
          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: CustomScrollView(
        physics: const NeverScrollableScrollPhysics(),
        slivers: [
          const SliverAppBar.large(title: SizedBox.shrink()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Banner
                  const SkeletonBox(height: 150, radius: 16),
                  // 每日推荐
                  header('110'),
                  SizedBox(
                    height: 110,
                    child: Row(children: [
                      for (var i = 0; i < 2; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        const SkeletonBox(width: 220, height: 110, radius: 12),
                      ],
                    ]),
                  ),
                  // 推荐歌单：130x130 圆角卡横排（高 180 与实际一致）
                  header('140'),
                  SizedBox(
                    height: 180,
                    child: Row(children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBox(width: 130, height: 130, radius: 16),
                            SizedBox(height: 6),
                            SkeletonText(width: 100),
                          ],
                        ),
                      ],
                    ]),
                  ),
                  // 排行榜横排卡
                  header('90'),
                  SizedBox(
                    height: 150,
                    child: Row(children: [
                      for (var i = 0; i < 2; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        const SkeletonBox(width: 200, height: 150, radius: 16),
                      ],
                    ]),
                  ),
                  // 新歌列表行（56 封面 + 两行文字）
                  header('120'),
                  for (var i = 0; i < 5; i++)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Row(children: [
                        SkeletonBox(width: 56, height: 56, radius: 8),
                        SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SkeletonText(width: double.infinity, height: 14),
                                  SizedBox(height: 8),
                                  SkeletonText(width: 120, height: 12),
                                ])),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ErrorRetry(error: error, onRetry: onRetry);
  }
}
