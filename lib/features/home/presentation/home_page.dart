import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logger/logger.dart';

import '../../player/play_helper.dart';
import '../data/home_repository.dart';
import '../data/models.dart';

final _log = Logger();

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
                SliverAppBar(
                  floating: true,
                  title: Text('汀澜音乐',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () => context.push('/search'),
                    ),
                  ],
                ),
                if (data.banners.isEmpty &&
                    data.dailyRecommend == null &&
                    data.playlists.isEmpty &&
                    data.ranks.isEmpty &&
                    data.songs.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('暂无推荐内容，请下拉重试')),
                  ),
                if (data.banners.isNotEmpty)
                  SliverToBoxAdapter(child: _BannerCarousel(data.banners)),
                if (data.dailyRecommend != null &&
                    data.dailyRecommend!.isNotEmpty)
                  SliverToBoxAdapter(
                      child: _DailyRecommend(data.dailyRecommend!)),
                if (data.playlists.isNotEmpty) ...[
                  _sectionTitle(context, '推荐歌单'),
                  SliverToBoxAdapter(child: _PlaylistRow(data.playlists)),
                ],
                if (data.ranks.isNotEmpty) ...[
                  _sectionTitle(context, '排行榜'),
                  SliverToBoxAdapter(child: _RankRow(data.ranks)),
                ],
                if (data.songs.isNotEmpty) ...[
                  _sectionTitle(context, '新歌推荐'),
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      ),
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
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                      Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
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
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text('每日推荐',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        SizedBox(
          height: 110,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: songs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final s = songs[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  ref.read(playHelperProvider).playHomeQueue(songs, i);
                  context.push('/player');
                },
                child: SizedBox(
                  width: 220,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(12)),
                          child: CachedNetworkImage(
                            imageUrl: s.cover,
                            width: 78,
                            height: 78,
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
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = playlists[i];
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () =>
                context.push('/playlist/${p.globalCollectionId}'),
            child: SizedBox(
              width: 130,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CachedNetworkImage(
                      imageUrl: p.cover,
                      width: 130,
                      height: 130,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 130,
                        height: 130,
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: const Icon(Icons.queue_music),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
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
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push('/playlist/${r.id}'),
            child: SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: r.cover,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest),
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
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget box(double h, {double? w, double r = 12}) => Container(
          height: h,
          width: w,
          decoration: BoxDecoration(
              color: base, borderRadius: BorderRadius.circular(r)),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        box(150, r: 16),
        const SizedBox(height: 24),
        box(20, w: 120),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: Row(children: [
            box(130, w: 130, r: 16),
            const SizedBox(width: 12),
            box(130, w: 130, r: 16),
            const SizedBox(width: 12),
            box(130, w: 130, r: 16),
          ]),
        ),
        const SizedBox(height: 24),
        box(20, w: 100),
        const SizedBox(height: 12),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              box(56, w: 56, r: 8),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    box(14),
                    const SizedBox(height: 8),
                    box(12, w: 120),
                  ])),
            ]),
          ),
      ],
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = '$error';
    final isAuthError = message.contains('20028') ||
        message.contains('登录') ||
        message.contains('验证');
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 56),
          const SizedBox(height: 12),
          Text(isAuthError ? '需要登录或完成验证后重试' : '加载失败，请检查网络'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
