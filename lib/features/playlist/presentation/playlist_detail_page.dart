import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
// V37-UI-06：收藏失败文案统一走 friendlyError 解包（不拼 '$e' 技术串）
import '../../../core/utils/friendly_error.dart';
import '../../../core/utils/toast.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../l10n/l10n.dart';
import '../../auth/presentation/login_guard.dart';
import '../../download/presentation/download_sheet.dart';
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../data/playlist_repository.dart';

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

/// 收藏操作飞行锁（V3-14 + F-4 终审修正）：**autoDispose**——
/// 进程级单例锁在 widget 销毁后 finally 复位失败时会永久卡死
/// （只能重启 App）；autoDispose 让锁与页面共存亡（F-4 终审：声明必须
/// 与注释一致——此前注释写 autoDispose 实际是全局单例，切页面后锁仍
/// 挂 20 秒。改为 autoDispose 后 provider 随页面销毁，finally 里的
/// 复位异常已被 try/catch 吞掉，行为正确）。
final _collectingProvider = StateProvider.autoDispose<bool>((ref) => false);

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
                    // UI-03（审查②）：数据源要与页面顶部一致——
                    // 用户歌单（?user=）走 userPlaylistTracksProvider
                    final tracksAsync = (userListId != null &&
                            userListId!.isNotEmpty)
                        ? ref.read(userPlaylistTracksProvider(userListId!))
                        : ref.read(playlistTracksProvider(id));
                    final tracks = tracksAsync.value;
                    if (tracks != null && tracks.songs.isNotEmpty) {
                      // R-39（v3.7 排查环节 2）：fire-and-forget 保持不变，
                      // 未捕获异常由 runZonedGuarded 落盘。V37-PLAY-04：
                      // 列表加载中/为空/失败时此前**静默无响应**（用户点
                      // 按钮没反应，第 9 条失败可感知），补 Toast 告知。
                      ref.read(playHelperProvider).playPlaylistQueue(
                          tracks.songs, 0, cover: detail.cover);
                    } else if (tracksAsync.isLoading) {
                      Toast.show(context, context.l10n.loading);
                    } else {
                      Toast.show(context, context.l10n.loadFailed);
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
                    // V3-06（复查）：重试必须指向当前数据源
                    onRetry: () => ref.invalidate(
                        (userListId != null && userListId!.isNotEmpty)
                            ? userPlaylistTracksProvider(userListId!)
                            : playlistTracksProvider(id)),
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
  ///
  /// V3-14（第5批复核②，P1）：收藏按钮防重（第 21 条）——飞行中拒绝
  /// 新提交，连点不再产生多条同名歌单。catch 区分 PlaylistWriteException
  /// 的 maybeSucceeded 语义（第 8/9 条），不把原始异常文本拼给用户。
  Future<void> _collectPlaylist(
      BuildContext context, WidgetRef ref, PlaylistDetail detail) async {
    if (!ensureLoggedIn(context, ref, action: context.l10n.favorite)) return;
    final lock = ref.read(_collectingProvider.notifier);
    if (ref.read(_collectingProvider)) return;
    lock.state = true;
    try {
      await ref.read(_playlistRepoProvider).collectPlaylist(
            name: detail.name,
            listCreateGid: detail.id, // global_collection_id
          );
      if (context.mounted) {
        Toast.show(context, context.l10n.collectSuccess);
      }
    } on PlaylistWriteException catch (e) {
      if (!context.mounted) return;
      // V37-UI-06：原「操作结果未知，请到「我的音乐」确认」为 l10n 包装内的
      // 硬编码中文（英文界面漏翻）；且失败分支拼原始异常 '$e' 直出技术串。
      // 统一改走 friendlyError 解包 + 明确下一步动作（第 9 条/微文案维度 A）。
      Toast.show(
          context,
          e.maybeSucceeded
              ? context.l10n.collectResultUnknown
              : context.l10n.operateFailed(e.message));
    } catch (e) {
      if (context.mounted) {
        Toast.show(context, context.l10n.operateFailed(friendlyError(e)));
      }
    } finally {
      // F-4（第7批终审，P1）：widget 可能已销毁（用户收藏后立刻返回），
      // 在已 dispose 的 element 上 ref.read 会抛 StateError → 锁永不
      // 复位 → 所有歌单页收藏永久无反应。用 notifier 快照复位；
      // 快照本身持有 controller，不受 widget 生命周期影响。
      try {
        lock.state = false;
      } catch (_) {}
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
