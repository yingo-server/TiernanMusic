import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/providers.dart';
import '../../../core/utils/toast.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart';
import '../../auth/presentation/login_guard.dart';
import '../../auth/data/auth_providers.dart';
import '../../auth/presentation/captcha_page.dart';
import '../data/comment_repository.dart';
import 'comment_floor_page.dart';
import '../../../l10n/l10n.dart';

final _commentRepoProvider = Provider<CommentRepository>(
    (ref) => CommentRepository(ref.watch(kugouApiClientProvider)));

final _commentsProvider = StateNotifierProvider.family<_CommentsController,
    AsyncValue<CommentPage>, _CommentArgs>((ref, args) {
  return _CommentsController(ref.watch(_commentRepoProvider), args);
});

class _CommentArgs {
  _CommentArgs(this.type, this.id);
  final CommentResourceType type;
  final String id;
}

class _CommentsController extends StateNotifier<AsyncValue<CommentPage>> {
  _CommentsController(this._repo, this._args)
      : super(const AsyncValue.loading()) {
    load();
  }

  final CommentRepository _repo;
  final _CommentArgs _args;
  int _page = 1;
  // 代次计数：刷新与加载更多并发时，旧请求的返回直接丢弃，防止串页。
  int _generation = 0;

  bool _loadingMore = false;
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  Future<void> load({bool refresh = false}) async {
    if (refresh) {
      _page = 1;
      _hasMore = true;
    }
    final gen = ++_generation;
    try {
      final result = await _repo.fetchComments(
          type: _args.type, id: _args.id, page: _page);
      // 已被更新的请求取代（刷新/翻页竞态），丢弃旧结果
      if (gen != _generation) return;
      if (refresh || state.value == null) {
        state = AsyncValue.data(result);
      } else {
        final prev = state.value!;
        state = AsyncValue.data(CommentPage(
          comments: [...prev.comments, ...result.comments],
          total: result.total,
          classifies: result.classifies,
          hotWords: result.hotWords,
        ));
      }
      if (result.comments.isEmpty || _page * 30 >= result.total) {
        _hasMore = false;
      }
    } catch (e, st) {
      if (state.value == null) state = AsyncValue.error(e, st);
    }
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final gen = _generation; // 刷新会把 _generation 推进，旧 loadMore 作废
    final next = _page + 1;
    try {
      final result = await _repo.fetchComments(
          type: _args.type, id: _args.id, page: next);
      if (gen != _generation) return; // 期间发生过刷新，丢弃
      final prev = state.value;
      if (prev == null) {
        state = AsyncValue.data(result);
      } else {
        state = AsyncValue.data(CommentPage(
          comments: [...prev.comments, ...result.comments],
          total: result.total,
          classifies: result.classifies,
          hotWords: result.hotWords,
        ));
      }
      _page = next;
      if (result.comments.isEmpty || _page * 30 >= result.total) {
        _hasMore = false;
      }
    } catch (_) {
      // 失败不推进页码，保留重试机会
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> sendComment(String content, {String? name}) async {
    await _repo.sendComment(
        type: _args.type, id: _args.id, content: content, name: name);
    await load(refresh: true);
  }

  Future<void> deleteComment(String cid,
      {String? specialId, String? tid}) async {
    await _repo.deleteComment(
        cid: cid,
        mixsongid: _args.type == CommentResourceType.song ? _args.id : null,
        specialId: specialId,
        tid: tid);
    await load(refresh: true);
  }
}

class CommentsPage extends ConsumerStatefulWidget {
  const CommentsPage({
    super.key,
    required this.resourceType,
    required this.resourceId,
  });
  final String resourceType;
  final String resourceId;

  @override
  ConsumerState<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends ConsumerState<CommentsPage> {
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  Comment? _replyTo;

  late final _args = _CommentArgs(
    switch (widget.resourceType) {
      'playlist' => CommentResourceType.playlist,
      'album' => CommentResourceType.album,
      _ => CommentResourceType.song,
    },
    widget.resourceId,
  );

  @override
  void initState() {
    super.initState();
    // 滚动到底时加载下一页（而不是在 itemBuilder 里触发 ——
    // 后者每次重建都会调用，导致重复请求与状态抖动）
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      ref.read(_commentsProvider(_args).notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  bool get _isLoggedIn =>
      ref.read(authStateProvider).valueOrNull != null;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_commentsProvider(_args));
    final theme = Theme.of(context);

    return Scaffold(
      // M3 规范：二级页面用标准 AppBar；标题区保持层级。
      appBar: AppBar(title: Text(context.l10n.comments)),
      body: Column(
        children: [
          Expanded(
            child: state.when(
              loading: () => const ListSkeleton(),
              error: (e, _) => ErrorRetry(
                error: e,
                onRetry: () => ref
                    .read(_commentsProvider(_args).notifier)
                    .load(refresh: true),
              ),
              data: (page) => page.comments.isEmpty
                  ? EmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      message: context.l10n.noComments,
                    )
                  : RefreshIndicator(
                      onRefresh: () => ref
                          .read(_commentsProvider(_args).notifier)
                          .load(refresh: true),
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: page.comments.length + 1,
                        itemBuilder: (context, index) {
                          if (index == page.comments.length) {
                            if (ref
                                .read(_commentsProvider(_args).notifier)
                                .hasMore) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child: CircularProgressIndicator()),
                              );
                            }
                            // 到底提示（之前永远转圈）
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: Text(
                                  context.l10n.noMore,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                            );
                          }
                          final comment = page.comments[index];
                          return _CommentTile(
                            comment: comment,
                            onReply: _isLoggedIn
                                ? () => setState(() => _replyTo = comment)
                                : null,
                            // 只能删自己的评论
                            onDelete: _isLoggedIn && comment.isMine
                                ? () => _deleteComment(comment)
                                : null,
                            // 楼中楼入口：点回复数进入
                            onOpenFloor: comment.replyCount > 0 &&
                                    comment.specialChildId != null
                                ? () => _openFloor(comment)
                                : null,
                          );
                        },
                      ),
                    ),
            ),
          ),
          _buildInput(theme),
        ],
      ),
    );
  }

  Widget _buildInput(ThemeData theme) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.replyPrefix(_replyTo!.userName, _replyTo!.content),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: context.l10n.cancel,
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    focusNode: _inputFocus,
                    decoration: InputDecoration(
                      hintText: _isLoggedIn
                          ? context.l10n.commentHint
                          : context.l10n.loginToComment,
                      isDense: true,
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: context.l10n.send,
                  // 未登录：点发送直接引导去登录页（之前只 toast）
                  onPressed: _isLoggedIn ? _send : () => context.push('/login'),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    if (!_isLoggedIn) {
      // 匿名态：给出明确的登录入口，而不是只提示「请先登录」
      ensureLoggedIn(context, ref, action: context.l10n.comment);
      return;
    }
    _inputCtrl.clear();
    final replyTo = _replyTo;
    setState(() => _replyTo = null);

    try {
      if (replyTo != null && replyTo.specialChildId != null) {
        // 回复楼中楼
        await ref.read(_commentRepoProvider).sendFloorReply(
              specialId: replyTo.specialChildId!,
              tid: replyTo.id,
              content: text,
              resourceType: _args.type,
            );
        // 与顶层评论路径保持一致：成功后刷新列表（replyCount 更新）
        await ref
            .read(_commentsProvider(_args).notifier)
            .load(refresh: true);
      } else {
        await ref
            .read(_commentsProvider(_args).notifier)
            .sendComment(text);
      }
      if (mounted) {
        Toast.show(context, context.l10n.commentSuccess);
      }
    } on ApiException catch (e) {
      // 20028 风控：弹人机验证页（复用 CaptchaPage）。
      // 验证通过后**不自动重试**（红线：禁止自动重试），提示用户手动再点发送。
      if (mounted &&
          e.needsVerification &&
          (e.ssaCode?.isNotEmpty ?? false)) {
        final ok = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CaptchaPage(
              ssaCode: e.ssaCode!,
              api: ref.read(kugouApiClientProvider),
            ),
          ),
        );
        if (mounted) {
          Toast.show(
              context,
              ok == true
                  ? context.l10n.commentVerifiedRetryHint
                  : context.l10n.commentFailed('$e'));
        }
        return;
      }
      if (mounted) {
        Toast.show(context, context.l10n.commentFailed('$e'));
      }
    } catch (e) {
      if (mounted) {
        Toast.show(context, context.l10n.commentFailed('$e'));
      }
    }
  }

  /// 进入楼中楼页面（fetchFloor 已有但从未被调用）
  Future<void> _openFloor(Comment comment) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: false,
        builder: (_) => CommentFloorPage(
          args: CommentArgsShim(
            _args.type,
            _args.id,
            comment.specialChildId!,
            comment.id,
          ),
          comment: comment,
        ),
      ),
    );
    // 返回后刷新（回复数/内容保持最新）
    if (mounted) {
      ref.read(_commentsProvider(_args).notifier).load(refresh: true);
    }
  }

  Future<void> _deleteComment(Comment comment) async {
    // 危险操作：error 色强调 + 二次确认 Dialog
    final confirm = await showDestructiveConfirm(
      context,
      title: context.l10n.deleteComment,
      message: context.l10n.deleteCommentConfirm,
      confirmLabel: context.l10n.delete,
    );
    if (!confirm) return;
    try {
      // 顶层评论删除：cid（+ mixsongid）。楼层回复的删除在 CommentFloorPage
      // 内处理（需额外带 special_id + tid）。
      await ref.read(_commentsProvider(_args).notifier).deleteComment(
          comment.id,
          specialId: comment.specialChildId);
      if (mounted) {
        Toast.show(context, context.l10n.deleted);
      }
    } catch (e) {
      if (mounted) {
        Toast.show(context, context.l10n.deleteFailed('$e'));
      }
    }
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    this.onReply,
    this.onDelete,
    this.onOpenFloor,
  });
  final Comment comment;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;
  final VoidCallback? onOpenFloor;

  bool get _hasActions => onReply != null || onDelete != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundImage: comment.avatar.isNotEmpty
            ? CachedNetworkImageProvider(
        cacheManager: AppImageCache.instance,
        
                comment.avatar,
                // 头像显示尺寸约 40px × dpr，限制解码尺寸
                maxWidth: (40 * MediaQuery.devicePixelRatioOf(context)).round(),
              )
            : null,
        child: comment.avatar.isEmpty
            ? const Icon(Icons.person, size: 20)
            : null,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              comment.userName,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            comment.createTime,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(comment.content),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.thumb_up_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
              const SizedBox(width: 4),
              Text('${comment.likeCount}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  )),
              if (comment.replyCount > 0) ...[
                const SizedBox(width: 16),
                // 楼中楼入口：可点击进入回复列表
                if (onOpenFloor != null)
                  InkWell(
                    onTap: onOpenFloor,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        context.l10n.repliesCount(comment.replyCount),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                else
                  Text(context.l10n.repliesCount(comment.replyCount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      )),
              ],
              const Spacer(),
              // M3 规范：列表项的多个操作收进 PopupMenuButton，
              // 而不是在行末排一排图标/文本按钮。
              if (_hasActions)
                PopupMenuButton<String>(
                  tooltip: context.l10n.moreActions,
                  onSelected: (v) {
                    if (v == 'reply') onReply?.call();
                    if (v == 'delete') onDelete?.call();
                  },
                  itemBuilder: (context) => [
                    if (onReply != null)
                      PopupMenuItem<String>(
                        value: 'reply',
                        child: Row(
                          children: [
                            Icon(Icons.reply,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 12),
                            Text(context.l10n.reply),
                          ],
                        ),
                      ),
                    if (onDelete != null)
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 20, color: theme.colorScheme.error),
                            const SizedBox(width: 12),
                            Text(context.l10n.delete,
                                style: TextStyle(
                                    color: theme.colorScheme.error)),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
