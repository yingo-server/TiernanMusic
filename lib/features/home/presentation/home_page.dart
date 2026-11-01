import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../l10n/l10n.dart';

import '../../player/play_helper.dart';
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
            onRefresh: () async => ref.invalidate(homeDataProvider),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 大标题层级：M3 顶层页面使用 headline 样式的标题栏
                SliverAppBar(
                  floating: true,
                  title: Text(context.l10n.home,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
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
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: song.cover,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            width: 56,
            height: 56,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.music_note),
          ),
        ),
      ),
      title: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.singer,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      // trailing 只放次要信息（时长），操作收进 PopupMenu
      trailing: Text(song.durationText,
          style: Theme.of(context).textTheme.bodySmall),
      onTap: () {
        final helper = ref.read(playHelperProvider);
        if (queue != null) {
          helper.playHomeQueue(queue!, index);
        } else {
          helper.playHomeSong(song);
        }
        context.push('/player');
      },
    );
  }
}

// ---------- 骨架屏 & 错误 ----------

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Shimmer(
      baseColor: scheme.surface,
      highlightColor:
          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // Banner
          _SkBox(height: 150, radius: 16),
          const SizedBox(height: 24),
          // 推荐歌单：130x130 圆角卡横排
          _SkText(width: 120),
          const SizedBox(height: 12),
          SizedBox(
            height: 176,
            child: Row(children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkBox(width: 130, height: 130, radius: 16),
                    SizedBox(height: 8),
                    _SkText(width: 100),
                  ],
                ),
              ],
            ]),
          ),
          const SizedBox(height: 24),
          // 排行榜横排卡
          _SkText(width: 100),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: Row(children: [
              for (var i = 0; i < 2; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                const _SkBox(width: 200, height: 150, radius: 16),
              ],
            ]),
          ),
          const SizedBox(height: 24),
          // 新歌列表行（56 封面 + 两行文字）
          _SkText(width: 110),
          const SizedBox(height: 12),
          for (var i = 0; i < 5; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Row(children: [
                _SkBox(width: 56, height: 56, radius: 8),
                SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SkText(width: double.infinity, height: 14),
                          SizedBox(height: 8),
                          _SkText(width: 120, height: 12),
                        ])),
              ]),
            ),
        ],
      ),
    );
  }
}

/// 骨架占位块
class _SkBox extends StatelessWidget {
  const _SkBox(
      {required this.height, this.width, this.radius = 12});
  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 骨架文字条
class _SkText extends StatelessWidget {
  const _SkText({required this.width, this.height = 16});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// 微光扫过动画（3s 循环，无第三方依赖）
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child, this.baseColor, this.highlightColor});
  final Widget child;
  final Color? baseColor;
  final Color? highlightColor;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final theme = Theme.of(context);
        final base =
            widget.baseColor ?? theme.colorScheme.surface;
        final highlight = widget.highlightColor ??
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
        // 高光带从左侧 -1 推进到右侧 1，覆盖 child 后裁剪
        final dx = -1.2 + _controller.value * 2.4;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
            transform: GradientTranslation(dx * bounds.width),
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// Gradient 平移：把渐变整体在 x 方向偏移 [dx]
class GradientTranslation extends GradientTransform {
  const GradientTranslation(this.dx);
  final double dx;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
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
