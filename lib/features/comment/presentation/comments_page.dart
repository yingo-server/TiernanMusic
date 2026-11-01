import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/utils/toast.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/auth_providers.dart';
import '../data/comment_repository.dart';
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

  Future<void> load({bool refresh = false}) async {
    if (refresh) _page = 1;
    try {
      final result = await _repo.fetchComments(
          type: _args.type, id: _args.id, page: _page);
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
    } catch (e, st) {
      if (state.value == null) state = AsyncValue.error(e, st);
    }
  }

  bool _loadingMore = false;
  bool _hasMore = true;

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final next = _page + 1;
    try {
      final result = await _repo.fetchComments(
          type: _args.type, id: _args.id, page: next);
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
      ref.read(authStateProvider).value != null;

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
                            if (page.comments.length < page.total) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child: CircularProgressIndicator()),
                              );
                            }
                            return const SizedBox(height: 80);
                          }
                          final comment = page.comments[index];
                          return _CommentTile(
                            comment: comment,
                            onReply: _isLoggedIn
                                ? () => setState(() => _replyTo = comment)
                                : null,
                            onDelete: _isLoggedIn
                                ? () => _deleteComment(comment)
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
                  onPressed: _send,
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
      Toast.show(context, context.l10n.pleaseLoginFirst);
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
      } else {
        await ref
            .read(_commentsProvider(_args).notifier)
            .sendComment(text);
      }
      if (mounted) {
        Toast.show(context, context.l10n.commentSuccess);
      }
    } catch (e) {
      if (mounted) {
        Toast.show(context, context.l10n.commentFailed('$e'));
      }
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
  const _CommentTile({required this.comment, this.onReply, this.onDelete});
  final Comment comment;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  bool get _hasActions => onReply != null || onDelete != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundImage: comment.avatar.isNotEmpty
            ? NetworkImage(comment.avatar)
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
