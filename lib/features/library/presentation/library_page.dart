import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/account_manager.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../../download/data/download_task.dart';
import '../../download/download_provider.dart';
import '../../download/presentation/download_sheet.dart';
import '../data/recent_play_store.dart';
import '../../../l10n/l10n.dart';

/// 音乐库页：账号卡片 + 我的歌单 + 最近播放 + 已下载 + 收藏 MV 占位。
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
    final downloaded = ref.watch(downloadedAudioProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.library,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---- 账号卡片 ----
          _AccountCard(account: account),
          const SizedBox(height: 8),

          // ---- 我的歌单 ----
          if (account != null) ...[
            SectionHeader(title: context.l10n.myPlaylists),
            playlistsAsync.when(
              loading: () => const _PlaylistRowSkeleton(),
              error: (e, _) => _PlaylistRowError(
                onRetry: () => ref.invalidate(
                    _userPlaylistsProvider(true)),
              ),
              data: (list) => _MyPlaylistRow(playlists: list),
            ),
          ] else ...[
            SectionHeader(title: context.l10n.myPlaylists),
            const _LoginGuideCard(),
          ],

          // ---- 最近播放 ----
          SectionHeader(
            title: context.l10n.recentlyPlayed,
            action: _recent.isEmpty
                ? null
                : TextButton.icon(
                    onPressed: _confirmClearRecent,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: Text(context.l10n.clear),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
          ),
          if (_recent.isEmpty)
            EmptyState(
              icon: Icons.history_rounded,
              message: context.l10n.noRecentlyPlayed,
            )
          else
            for (final r in _recent.take(20))
              SongTile(
                title: r.name,
                artist: r.artist,
                cover: r.cover,
                onTap: () => _playRecent(r),
                // 下载是次要但高频的操作，收进「更多」菜单避免与时长冲突
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
                        hash: r.hash,
                        albumAudioId: r.albumAudioId,
                        name: r.name,
                        artist: r.artist,
                        cover: r.cover,
                      ),
                    );
                  }
                },
              ),

          // ---- 已下载 ----
          SectionHeader(
            title: context.l10n.downloadedSongs,
            action: downloaded.isEmpty
                ? null
                : TextButton.icon(
                    onPressed: () => context.push<void>('/downloads'),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(context.l10n.downloadManagement),
                  ),
          ),
          if (downloaded.isEmpty)
            EmptyState(
              icon: Icons.download_for_offline_outlined,
              message: context.l10n.noDownloads,
              actionLabel: context.l10n.downloadManagement,
              onAction: () => context.push<void>('/downloads'),
            )
          else
            for (final task in downloaded.take(20))
              SongTile(
                title: task.title.isEmpty ? task.hash : task.title,
                artist: task.artist,
                cover: task.coverUrl,
                onTap: () => _playDownloaded(task),
                trailing: const Icon(Icons.offline_pin_outlined, size: 20),
              ),

          // ---- 我收藏的 MV ----
          SectionHeader(title: context.l10n.myFavoriteMvs),
          EmptyState(
            icon: Icons.movie_outlined,
            message: context.l10n.mvComingSoon,
          ),
        ],
      ),
    );
  }

  /// 从最近播放记录构造 Song 并跳转播放页。
  Future<void> _playRecent(RecentPlay r) async {
    final song = Song(
      hash: r.hash,
      albumId: '',
      albumAudioId: r.albumAudioId,
      name: r.name,
      artist: r.artist,
      cover: r.cover,
    );
    await ref.read(playHelperProvider).playSong(song);
    if (!mounted) return;
    context.push('/player');
  }

  /// 播放已下载音频（本地文件路径优先）。
  Future<void> _playDownloaded(DownloadTask task) async {
    final song = Song(
      hash: task.hash,
      albumAudioId: task.albumAudioId,
      name: task.title.isEmpty ? task.hash : task.title,
      artist: task.artist,
      cover: task.coverUrl,
    );
    await ref.read(playHelperProvider).playSong(song);
    if (!mounted) return;
    context.push('/player');
  }

  /// 清空最近播放（危险操作：红色强调 + 二次确认 Dialog）。
  Future<void> _confirmClearRecent() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.clearRecentlyPlayed),
        content: Text(context.l10n.clearRecentConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    );
    if (ok == true) {
      await RecentPlayStore.clear();
      _loadRecent();
    }
  }

  AccountRecord? _currentAccount() {    try {
      return AccountManager.instance.currentAccount;
    } catch (_) {
      return null;
    }
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
            colors: [
              scheme.primary.withValues(alpha: 0.25),
              scheme.surfaceContainerHigh
            ],
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
                    account == null ? context.l10n.notLoggedIn : account!.nickname,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    account == null
                        ? context.l10n.loginToSync
                        : context.l10n.userIdLabel('${account!.userid}'),
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
                child: Text(context.l10n.login),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              EmptyState(
                icon: Icons.playlist_add_rounded,
                message: context.l10n.loginToViewPlaylists,
                actionLabel: context.l10n.goLogin,
                onAction: () => context.push('/login'),
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
  final repo = PlaylistRepository(ref.watch(kugouApiClientProvider));
  return repo.fetchUserPlaylists();
});

class _MyPlaylistRow extends StatelessWidget {
  const _MyPlaylistRow({required this.playlists});
  final List<UserPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (playlists.isEmpty) {
      return EmptyState(
          icon: Icons.queue_music_outlined, message: context.l10n.noPlaylistsYet);
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
          return SizedBox(
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
                          color: theme.colorScheme.surfaceContainerHighest,
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
                        child: Text(context.l10n.songCountSuffix(p.count),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: Colors.white)),
                      ),
                    ),
                  ],
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
    return ErrorRetry(message: context.l10n.playlistLoadFailed, onRetry: onRetry);
  }
}
