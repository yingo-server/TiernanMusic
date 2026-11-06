import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/image/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../core/utils/friendly_error.dart';
import '../../../core/utils/toast.dart';
import '../../../core/widgets/song_tile.dart' show EmptyState;
import '../../../l10n/l10n.dart';
import '../../auth/data/auth_providers.dart';
import '../data/playlist_repository.dart';

/// V34-UI-01（修复②，P2）：「收藏到歌单」弹层。
///
/// 此前 `addToPlaylist` l10n 键与 PlaylistRepository.addTracks 均已就绪，
/// 却没有任何 UI 入口（死键）——「搜索一首歌 → 收藏到歌单」任务流必须
/// 退出播放页绕到库页才能完成。本弹层由播放页「更多」菜单与搜索结果
/// 歌曲菜单共用（易用性：任务流 1）。
///
/// 写操作全部走 PlaylistRepository（防重/失败语义/缓存失效在仓库层已统一，
/// 第 3/8/21 条），UI 层不自行触网（第 4 条分层单向依赖）。
Future<void> showAddToPlaylistSheet(BuildContext context, TrackRef track) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.7,
      child: AddToPlaylistSheet(track: track),
    ),
  );
}

class AddToPlaylistSheet extends ConsumerStatefulWidget {
  const AddToPlaylistSheet({super.key, required this.track});
  final TrackRef track;

  @override
  ConsumerState<AddToPlaylistSheet> createState() =>
      _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  Future<List<UserPlaylist>>? _playlistsFuture;
  bool _creating = false;
  bool _busy = false;
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    final user = ref.read(authStateProvider).valueOrNull;
    if (user == null) {
      setState(() => _playlistsFuture = null);
      return;
    }
    setState(() {
      _playlistsFuture = ref
          .read(playlistRepositoryProvider)
          .fetchUserPlaylists();
    });
  }

  /// 加歌写操作统一出口：失败文案区分「确定失败」与「可能已生效」
  /// （第 9 条可观测 / 第 21 条防重复提交）。
  ///
  /// V35-C2-1（第 C 批，P1）：[_createAndAdd] 在持有 `_busy` 期间调用
  /// 本方法，首行 `if (_busy) return` 会把加歌**静默吞掉**——新建歌单
  /// 成功但歌没进去。加 `bypassBusy` 供内部链式调用。
  Future<void> _addTo(UserPlaylist p, {bool bypassBusy = false}) async {
    if (_busy && !bypassBusy) return;
    if (p.listid.trim().isEmpty ||
        widget.track.hash.trim().isEmpty) {
      // 边界校验（第 14 条）：缺 hash 打上去只会得到无法解释的业务错误
      if (mounted) Toast.show(context, context.l10n.operationFailed);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(playlistRepositoryProvider)
          .addTracks(p.listid, [widget.track]);
      if (!mounted) return;
      Toast.show(context, context.l10n.addedToPlaylist);
      Navigator.of(context).pop();
    } on PlaylistWriteException catch (e) {
      // 仓库层的 message 是面向用户的整理文案（区分结果未知），直接展示
      if (mounted) Toast.show(context, e.message);
    } catch (e) {
      if (mounted) Toast.show(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 新建歌单并加歌。
  ///
  /// 实测契约说明：`/playlist/add`（type=0 新建）的返回体未建模、拿不到
  /// 新歌单 listid（第 29 条：未实测的返回结构不得当作依据）。因此创建后
  /// 重新拉取我的歌单、按名称精确匹配定位新歌单再加歌；匹配不到时只提示
  /// 创建成功，不静默丢歌（用户可在新歌单里手动再加）。
  Future<void> _createAndAdd(String name) async {
    if (_busy) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      Toast.show(context, context.l10n.playlistNameEmpty);
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(playlistRepositoryProvider);
    try {
      await repo.collectPlaylist(name: trimmed);
      final list = await repo.fetchUserPlaylists();
      final created = list.where((p) => p.name == trimmed).toList();
      if (!mounted) return;
      if (created.isEmpty) {
        Toast.show(context, context.l10n.collectSuccess);
        Navigator.of(context).pop();
        return;
      }
      await _addTo(created.first, bypassBusy: true);
    } on PlaylistWriteException catch (e) {
      if (mounted) Toast.show(context, e.message);
    } catch (e) {
      if (mounted) Toast.show(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = ref.watch(authStateProvider).valueOrNull;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                const Icon(Icons.playlist_add_rounded, size: 20),
                const SizedBox(width: 8),
                Text(l10n.addToPlaylist,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Divider(height: 1),
          if (user == null)
            Expanded(
              child: EmptyState(
                icon: Icons.lock_outline_rounded,
                message: l10n.loginRequiredHint,
                actionLabel: l10n.goLogin,
                onAction: () {
                  // V35-C2-2（第 C 批，P1）：「去登录」此前只 pop 不跳转——
                  // 注释声称走 /login 路由但实现缺失（第 3 条：注释与
                  // 行为必须一致）。pop 后跳登录页，登录成功后用户自然
                  // 重新打开收藏弹层。
                  Navigator.of(context).pop();
                  context.push('/login');
                },
              ),
            )
          else if (_creating)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameCtrl,
                    autofocus: true,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: l10n.playlistName,
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() => _creating = false),
                          child: Text(l10n.cancel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed:
                              _busy ? null : () => _createAndAdd(_nameCtrl.text),
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : Text(l10n.confirm),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            Expanded(
              child: FutureBuilder<List<UserPlaylist>>(
                future: _playlistsFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return EmptyState(
                      icon: Icons.error_outline_rounded,
                      message: l10n.playlistLoadFailed,
                      actionLabel: l10n.retry,
                      onAction: _reload,
                    );
                  }
                  final list = snap.data ?? const <UserPlaylist>[];
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add_circle_outline_rounded),
                        title: Text(l10n.createPlaylist),
                        onTap: _busy
                            ? null
                            : () => setState(() => _creating = true),
                      ),
                      const Divider(height: 1),
                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: EmptyState(
                            icon: Icons.queue_music_outlined,
                            message: l10n.noPlaylistsYet,
                          ),
                        )
                      else
                        for (final p in list)
                          ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: p.cover.isNotEmpty
                                    ? CachedNetworkImage(
                                        cacheManager: AppImageCache.instance,
                                        imageUrl: p.cover,
                                        fit: BoxFit.cover,
                                        memCacheWidth: (44 *
                                                MediaQuery.devicePixelRatioOf(
                                                    context))
                                            .round(),
                                        errorWidget: (_, __, ___) => Container(
                                          color: theme.colorScheme
                                              .surfaceContainerHighest,
                                          child: const Icon(
                                              Icons.queue_music_rounded,
                                              size: 20),
                                        ),
                                      )
                                    : Container(
                                        color: theme
                                            .colorScheme.surfaceContainerHighest,
                                        child: const Icon(
                                            Icons.queue_music_rounded,
                                            size: 20),
                                      ),
                              ),
                            ),
                            title: Text(p.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(l10n.songCountSuffix(p.count)),
                            onTap: _busy ? null : () => _addTo(p),
                          ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
