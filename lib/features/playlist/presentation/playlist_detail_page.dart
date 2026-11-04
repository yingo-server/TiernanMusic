import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
import '../../../core/utils/toast.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../l10n/l10n.dart';
import '../../auth/presentation/login_guard.dart';
import '../../download/presentation/download_sheet.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../data/playlist_repository.dart';

/// 歌单仓库（用全局直连/回退客户端构造，之前是 throw 导致歌单页必然失败）
final playlistRepositoryProvider = Provider<PlaylistRepository>(
    (ref) => PlaylistRepository(ref.watch(kugouApiClientProvider)));

final _playlistRepoProvider = playlistRepositoryProvider;

final playlistDetailProvider = FutureProvider.family
    .autoDispose<PlaylistDetail, String>((ref, id) {
  return ref.watch(_playlistRepoProvider).fetchDetail(id);
});

/// 歌单歌曲（一次性拉完，按「整体从新到旧」排序）
///
/// 上游分页方向：page=1 最新、页越大越旧，页内也是从新到旧。
/// 仓库在 Repository 层倒序取页并反序拼接，保证列表整体从新到旧。
final playlistTracksProvider = FutureProvider.family
    .autoDispose<PlaylistTracks, String>((ref, id) {
  return ref
      .watch(_playlistRepoProvider)
      .fetchTracks(id, newestFirst: true, allPages: true);
});

/// 用户（我的）歌单歌曲：按 `listid` 走 `/playlist/track/all/new`。
///
/// 与公共歌单的 gid 不同，用户歌单只有数字 `listid`。
final userPlaylistTracksProvider = FutureProvider.family
    .autoDispose<PlaylistTracks, String>((ref, listId) {
  return ref.watch(_playlistRepoProvider).fetchUserTracks(listId);
});

/// 加载更多后手动触发 UI 重建的计数器
final _tracksReloadProvider = StateProvider<int>((ref) => 0);

class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.id, this.userListId});
  final String id;

  /// 用户（我的）歌单的 listid。
  ///
  /// 非空时按「我的歌单」渲染：详情用 gid 取、歌曲用 listid 取
  /// （用户歌单的歌曲接口 `/playlist/track/all/new` 只认数字 listid）。
  final String? userListId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(playlistDetailProvider(id));
    // 我的歌单：歌曲走 listid；公共歌单：歌曲走 gid
    final tracksAsync = (userListId != null && userListId!.isNotEmpty)
        ? ref.watch(userPlaylistTracksProvider(userListId!))
        : ref.watch(playlistTracksProvider(id));
    // 加载更多后 bump 触发本页重建（ songs 列表是本地可变对象，直接展示）
    ref.watch(_tracksReloadProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(
          error: e,
          onRetry: () => ref.invalidate(playlistDetailProvider(id)),
        ),
        data: (detail) => CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              actions: [
                // 评论入口（detail.id 来自 global_collection_id）
                IconButton(
                  icon: const Icon(Icons.comment_outlined),
                  tooltip: context.l10n.comments,
                  onPressed: () => context.push(
                      '/comments/playlist/${Uri.encodeComponent(detail.id)}'),
                ),
                // 收藏 / 取消收藏（之前仓库方法是死代码，无任何入口）
                IconButton(
                  icon: const Icon(Icons.favorite_border),
                  tooltip: context.l10n.favorite,
                  onPressed: () => _collectPlaylist(context, ref, detail),
                ),
                const SizedBox(width: 4),
              ],
              flexibleSpace: FlexibleSpaceBar(
                title: Text(
                  detail.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                ),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (detail.cover.isNotEmpty)
                      CachedNetworkImage(
                    cacheManager: AppImageCache.instance,
                        imageUrl: detail.cover,
                        fit: BoxFit.cover,
                        // 头图按屏宽 × dpr 限制解码分辨率
                        memCacheWidth: (MediaQuery.sizeOf(context).width *
                                MediaQuery.devicePixelRatioOf(context))
                            .round(),
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
            // 简介：M3 规范「可展开内容」用 ExpansionTile，
            // 而不是自定义的「展开/收起」按钮。
            if (detail.intro.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(
                      context.l10n.playlistIntro,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                    subtitle: Text(
                      detail.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          detail.intro,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                // 主操作：FilledButton（播放全部）
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
                    error: e,
                    onRetry: () => ref.invalidate(playlistTracksProvider(id)),
                  ),
                ),
              ),
              data: (tracks) => tracks.songs.isEmpty
                  ? SliverToBoxAdapter(
                      child: SizedBox(
                        height: 200,
                        child: EmptyState(
                          icon: Icons.queue_music_outlined,
                          message: context.l10n.noSongsInPlaylist,
                        ),
                      ),
                    )
                  : _buildTracksSlivers(context, ref, detail, tracks, theme),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  /// 歌曲列表 + 截断提示/加载更多（>100 首的公共歌单不再静默截断）
  Widget _buildTracksSlivers(BuildContext context, WidgetRef ref,
      PlaylistDetail detail, PlaylistTracks tracks, ThemeData theme) {
    return SliverMainAxisGroup(
      slivers: [
        SliverList(
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
                // 多个次要操作收进「更多」菜单
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
                        hash: song.hash,
                        albumAudioId: song.albumAudioId,
                        name: song.name,
                        artist: song.artist,
                        cover: song.cover,
                      ),
                    );
                  }
                },
              );
            },
            childCount: tracks.songs.length,
          ),
        ),

      ],
    );
  }

  /// 收藏歌单（非破坏性操作，无需确认：直接执行，成功后 toast）
  Future<void> _collectPlaylist(
      BuildContext context, WidgetRef ref, PlaylistDetail detail) async {
    // 匿名态直接拦截，不发请求（否则服务端拒绝，用户只看到原始错误）
    if (!ensureLoggedIn(context, ref, action: context.l10n.favorite)) return;
    try {
      await ref.read(_playlistRepoProvider).collectPlaylist(
            name: detail.name,
            listCreateGid: detail.id, // global_collection_id
          );
      if (context.mounted) {
        Toast.show(context, context.l10n.collectSuccess);
      }
    } catch (e) {
      if (context.mounted) {
        Toast.show(context, context.l10n.operateFailed('$e'));
      }
    }
  }
}

/// 歌单信息角标（播放量 / 曲目数）。
class _InfoChip extends StatelessWidget {
  const _InfoChip(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.white)),
        ],
      ),
    );
  }
}
