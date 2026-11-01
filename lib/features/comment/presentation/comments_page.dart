import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
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
  void dispose() {
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
                        itemCount: page.comments.length + 1,
                        itemBuilder: (context, index) {
                          if (index == page.comments.length) {
                            if (page.comments.length < page.total) {
                              ref
                                  .read(_commentsProvider(_args).notifier)
                                  .loadMore();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.pleaseLoginFirst)));
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.commentSuccess)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.commentFailed('$e'))));
      }
    }
  }

  Future<void> _deleteComment(Comment comment) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.deleteComment),
        content: Text(context.l10n.deleteCommentConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.l10n.cancel)),
          // 危险操作：红色强调
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.delete)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(_commentsProvider(_args).notifier).deleteComment(
          comment.id,
          specialId: comment.specialChildId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.deleted)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.deleteFailed('$e'))));
      }
    }
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, this.onReply, this.onDelete});
  final Comment comment;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

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
              // 次要操作用 TextButton（而非裸 GestureDetector 文本）：
              // 有涟漪反馈、有 48dp 触控目标、有语义。
              if (onReply != null)
                TextButton(
                  onPressed: onReply,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(context.l10n.reply,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
              if (onDelete != null)
                TextButton(
                  onPressed: onDelete,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: Text(context.l10n.delete,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error)),
                ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
