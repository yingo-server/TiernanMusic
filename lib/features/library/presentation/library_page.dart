import 'dart:async';

import '../../../core/image/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

// F4-32（审查③-B，P2）：删除未使用的 kugouApiClientProvider 导入——
// UI 层不得持有网络客户端（QUALITY_STANDARD 第 4 条分层单向依赖 / 第 32 条死代码）。
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/utils/toast.dart';
import '../../../core/widgets/shimmer.dart';
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/account_manager.dart';
import '../../auth/data/auth_providers.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../../download/data/download_task.dart';
import '../../download/download_provider.dart';
import '../../mv/data/mv_collection_repository.dart';
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
  StreamSubscription<AccountRecord?>? _authSub;
  StreamSubscription<void>? _recentSub;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    // 登录/登出后刷新账号卡片与「我的歌单」（StatefulShellRoute 保活，build 不依赖 auth）。
    _authSub = AccountManager.instance.onCurrentAccountChanged.listen((_) {
      if (!mounted) return;
      setState(() {});
      ref.invalidate(_userPlaylistsProvider);
      // F4-34（审查③-B，P3）：账号切换后「我收藏的 MV」也属于该账号的私有数据，
      // 必须一并失效，否则 A→B 切换后仍展示 A 的收藏（第 5 条状态单一来源 / 第 18 条世代）。
      ref.invalidate(_collectedMvsProvider);
    });
    // 播放记录写入后刷新最近播放。
    _recentSub = RecentPlayStore.changes.listen((_) {
      if (mounted) _loadRecent();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _recentSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    // F4-33（审查③-B，P3）：本地记录读取失败必须留痕并降级为空列表——
    // 原实现无 catch，异常会让「最近播放」区块永远停在上一次状态（第 6/9 条）。
    try {
      final list = await RecentPlayStore.read();
      if (!mounted) return;
      setState(() => _recent = list);
    } catch (e) {
      debugPrint('[library] 读取最近播放失败: $e');
      if (!mounted) return;
      setState(() => _recent = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = _currentAccount();
    final playlistsAsync = ref.watch(_userPlaylistsProvider(account != null));
    final downloaded = ref.watch(downloadedAudioProvider);

    return Scaffold(
      // M3 规范：顶层页面用大标题（SliverAppBar.large）。
      // 长内容用 CustomScrollView + SliverToBoxAdapter，避免嵌套 shrinkWrap ListView。
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(context.l10n.library),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                // 已下载状态用图标徽标（次要信息），不是操作按钮。
                trailing: Icon(
                  Icons.offline_pin_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),

          // ---- 我收藏的 MV ----
          SectionHeader(title: context.l10n.myFavoriteMvs),
          _buildCollectedMvs(context, account != null),
                ],
              ),
            ),
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

  /// 播放已下载音频（本地文件路径优先，断网/VIP 离线可播）。
  Future<void> _playDownloaded(DownloadTask task) async {
    final song = Song(
      hash: task.hash,
      albumId: task.albumId,
      albumAudioId: task.albumAudioId,
      name: task.title.isEmpty ? task.hash : task.title,
      artist: task.artist,
      cover: task.coverUrl,
      // 本地文件路径交给 audio_handler 优先离线播放
      localPath: task.filePath.isNotEmpty ? task.filePath : null,
    );
    await ref.read(playHelperProvider).playSong(song);
    if (!mounted) return;
    context.push('/player');
  }

  /// 清空最近播放（危险操作：error 色强调 + 二次确认 Dialog）。
  Future<void> _confirmClearRecent() async {
    final ok = await showDestructiveConfirm(
      context,
      title: context.l10n.clearRecentlyPlayed,
      message: context.l10n.clearRecentConfirm,
      confirmLabel: context.l10n.clear,
    );
    if (ok) {
      await RecentPlayStore.clear();
      _loadRecent();
    }
  }

  /// 我收藏的 MV 区块
  Widget _buildCollectedMvs(BuildContext context, bool loggedIn) {
    if (!loggedIn) {
      return EmptyState(
        icon: Icons.movie_outlined,
        message: context.l10n.loginToViewFavorites,
      );
    }
    final async = ref.watch(_collectedMvsProvider(true));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ErrorRetry(error: e, onRetry: () {
        ref.invalidate(_collectedMvsProvider(true));
      }),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.movie_outlined,
            message: context.l10n.noData,
          );
        }
        return Column(
          children: [
            // F4-35（审查③-B，P2）：MV 收藏同样必须具备上限——
            // 与其他区块一致的 20 条口径，避免上百条 ListTile 一次性构建（第 24/25 条）。
            for (final mv in list.take(20))
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: mv.cover.isEmpty
                        ? Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          )
                        : CachedNetworkImage(
                            imageUrl: mv.cover,
                            cacheManager: AppImageCache.instance,
                            fit: BoxFit.cover,
                            memCacheWidth: 144,
                          ),
                  ),
                ),
                title: Text(
                  mv.title.isEmpty ? context.l10n.mv : mv.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  mv.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  if (mv.hash.isNotEmpty) {
                    context.push('/mv/${mv.hash}');
                  }
                },
              ),
          ],
        );
      },
    );
  }

  AccountRecord? _currentAccount() {    try {
      return AccountManager.instance.currentAccount;
    } catch (_) {
      return null;
    }
  }
}

// ---------- 账号卡片 ----------

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});
  final AccountRecord? account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  ? CachedNetworkImageProvider(
        cacheManager: AppImageCache.instance,
        account!.avatar)
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
              )
            else
              // F4-36（审查③-B，P2）：已登录后账号卡片此前无任何可点区域，
              // 用户在本页找不到切换账号/退出入口（第 16 条语义分离之外的可达性缺口）。
              PopupMenuButton<String>(
                tooltip: context.l10n.moreActions,
                onSelected: (v) async {
                  if (v == 'manage') {
                    await context.push<void>('/settings');
                    return;
                  }
                  if (v == 'logout') {
                    final ok = await showDestructiveConfirm(
                      context,
                      title: context.l10n.logout,
                      message: context.l10n.logoutConfirm,
                      confirmLabel: context.l10n.logout,
                    );
                    if (!ok || !context.mounted) return;
                    try {
                      await ref.read(authStateProvider.notifier).logout();
                    } catch (e) {
                      if (context.mounted) {
                        Toast.show(context, context.l10n.logoutFailed(''));
                      }
                      debugPrint('[library] 退出登录失败: $e');
                    }
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'manage',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.manage_accounts_outlined),
                      title: Text(context.l10n.accountManage),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'logout',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.logout,
                          color: scheme.error),
                      title: Text(context.l10n.logout,
                          style: TextStyle(color: scheme.error)),
                    ),
                  ),
                ],
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
  final repo = ref.watch(playlistRepositoryProvider);
  return repo.fetchUserPlaylists();
});

/// 我收藏的 MV（需登录）
final _collectedMvsProvider = FutureProvider.autoDispose
    .family<List<CollectedMv>, bool>((ref, loggedIn) async {
  if (!loggedIn) return const [];
  final repo = ref.watch(mvCollectionRepositoryProvider);
  return repo.fetchCollected();
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
          // 跳转到「我的歌单」详情：
          // 详情页用 gid（公共歌单同款接口），歌曲用数字 listid。
          final gid = p.globalCollectionId;
          return SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: GestureDetector(
                        onTap: () {
                          if (gid.isEmpty && p.listid.isEmpty) return;
                          final detailId = Uri.encodeComponent(
                              gid.isEmpty ? p.listid : gid);
                          final user = p.listid.isEmpty
                              ? ''
                              : '?user=${Uri.encodeComponent(p.listid)}';
                          context.push('/playlist/$detailId$user');
                        },
                        child: CachedNetworkImage(
                    cacheManager: AppImageCache.instance,
                        imageUrl: p.cover,
                        width: 120,
                        height: 120,
                        fit: BoxFit.cover,
                        memCacheWidth:
                            (120 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        placeholder: (_, __) => Container(
                          width: 120,
                          height: 120,
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 120,
                          height: 120,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.queue_music_rounded),
                        ),
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
                // F4-37（审查③-B，P3）：标题改用 Flexible 吸收剩余高度，
                // 系统字体放大到 1.3x 以上时不再把 170dp 的列顶出黄黑溢出条（第 24 条惰性/布局健壮性）。
                Flexible(
                  child: Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall),
                ),
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
    final theme = Theme.of(context);
    return SizedBox(
      height: 170,
      child: Shimmer(
        baseColor: theme.colorScheme.surface,
        highlightColor:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 5,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, __) => const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: 120, height: 120, radius: 16),
              SizedBox(height: 6),
              SkeletonText(width: 90, height: 12),
            ],
          ),
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
