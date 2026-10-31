import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart' show kugouApi;
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/account_manager.dart';
import '../../playlist/data/playlist_repository.dart';
import '../data/recent_play_store.dart';

/// 音乐库页：账号卡片 + 我的歌单 + 最近播放 + 收藏 MV 占位。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  List<RecentPlay> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  void _loadRecent() {
    setState(() => _recent = RecentPlayStore.read());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = _currentAccount();
    final playlistsAsync = ref.watch(_userPlaylistsProvider(account != null));

    return Scaffold(
      appBar: AppBar(title: Text('音乐库',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---- 账号卡片 ----
          _AccountCard(account: account),
          const SizedBox(height: 8),

          // ---- 我的歌单 ----
          if (account != null) ...[
            _sectionTitle(context, '我的歌单'),
            playlistsAsync.when(
              loading: () => const _PlaylistRowSkeleton(),
              error: (e, _) => _PlaylistRowError(
                onRetry: () => ref.invalidate(
                    _userPlaylistsProvider(true)),
              ),
              data: (list) => _MyPlaylistRow(playlists: list),
            ),
          ] else ...[
            _sectionTitle(context, '我的歌单'),
            const _LoginGuideCard(),
          ],

          // ---- 最近播放 ----
          _sectionTitle(context, '最近播放'),
          if (_recent.isEmpty)
            const EmptyState(
              icon: Icons.history_rounded,
              message: '还没有播放记录，去首页挑首歌吧',
            )
          else ...[
            for (final r in _recent.take(20))
              SongTile(
                title: r.name,
                artist: r.artist,
                cover: r.cover,
                // TODO(播放): 接入播放 API 后在此恢复播放
                onTap: () {},
              ),
          ],

          // ---- 我收藏的 MV ----
          _sectionTitle(context, '我收藏的 MV'),
          const EmptyState(
            icon: Icons.movie_outlined,
            message: 'MV 收藏功能即将上线，敬请期待',
          ),
        ],
      ),
    );
  }

  AccountRecord? _currentAccount() {
    try {
      return AccountManager.instance.currentAccount;
    } catch (_) {
      return null;
    }
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Text(title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}

// ---------- 账号卡片 ----------

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});
  final AccountRecord? account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.primary.withOpacity(0.25), scheme.surfaceContainerHigh],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: (account?.avatar ?? '').isNotEmpty
                  ? CachedNetworkImageProvider(account!.avatar)
                  : null,
              child: (account?.avatar ?? '').isEmpty
                  ? Icon(Icons.person_rounded, color: scheme.onPrimaryContainer)
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account == null ? '未登录' : account!.nickname,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    account == null ? '登录后同步你的歌单与收藏' : 'ID: ${account!.userid}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (account == null)
              FilledButton(
                onPressed: () => context.push('/login'),
                child: const Text('登录'),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- 未登录引导卡片 ----------

class _LoginGuideCard extends StatelessWidget {
  const _LoginGuideCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const EmptyState(
                icon: Icons.playlist_add_rounded,
                message: '登录后查看你的歌单',
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/login'),
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('去登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 我的歌单横排 ----------

final _userPlaylistsProvider = FutureProvider.autoDispose
    .family<List<UserPlaylist>, bool>((ref, loggedIn) async {
  if (!loggedIn) return const [];
  final repo = PlaylistRepository(kugouApi);
  return repo.fetchUserPlaylists();
});

class _MyPlaylistRow extends StatelessWidget {
  const _MyPlaylistRow({required this.playlists});
  final List<UserPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return const EmptyState(icon: Icons.queue_music_outlined, message: '暂无歌单');
    }
    return SizedBox(
      height: 170,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = playlists[i];
          // TODO(跳转): 用户歌单详情页待接入
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {},
            child: SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: p.cover,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 120,
                            height: 120,
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: const Icon(Icons.queue_music_rounded),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${p.count} 首',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white)),
                        ),
                      ),
                    ],
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

// ---------- 骨架 / 错误 ----------

class _PlaylistRowSkeleton extends StatelessWidget {
  const _PlaylistRowSkeleton();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return SizedBox(
      height: 170,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 5,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                    color: base, borderRadius: BorderRadius.circular(16))),
            const SizedBox(height: 6),
            Container(height: 12, width: 90, color: base),
          ],
        ),
      ),
    );
  }
}

class _PlaylistRowError extends StatelessWidget {
  const _PlaylistRowError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ErrorRetry(message: '歌单加载失败', onRetry: onRetry);
  }
}
