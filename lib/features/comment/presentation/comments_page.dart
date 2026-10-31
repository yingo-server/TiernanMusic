import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/auth_providers.dart';
import '../data/comment_repository.dart';

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

  Future<void> loadMore() async {
    _page++;
    await load();
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
    super.dispose();
  }

  bool get _isLoggedIn =>
      ref.read(authStateProvider).value != null;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_commentsProvider(_args));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('评论')),
      body: Column(
        children: [
          Expanded(
            child: state.when(
              loading: () => const ListSkeleton(),
              error: (e, _) => ErrorRetry(
                message: '$e',
                onRetry: () => ref
                    .read(_commentsProvider(_args).notifier)
                    .load(refresh: true),
              ),
              data: (page) => page.comments.isEmpty
                  ? const EmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      message: '还没有评论，快来抢沙发',
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '回复 ${_replyTo!.userName}：${_replyTo!.content}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _replyTo = null),
                    child: const Icon(Icons.close, size: 18),
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
                    decoration: InputDecoration(
                      hintText: _isLoggedIn ? '说点什么…' : '登录后可评论',
                      isDense: true,
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
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
          .showSnackBar(const SnackBar(content: Text('请先登录')));
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
            .showSnackBar(const SnackBar(content: Text('评论成功')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('评论失败：$e')));
      }
    }
  }

  Future<void> _deleteComment(Comment comment) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('确定删除这条评论吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
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
            .showSnackBar(const SnackBar(content: Text('已删除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
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
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              fontSize: 11,
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
                  size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              const SizedBox(width: 4),
              Text('${comment.likeCount}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                  )),
              if (comment.replyCount > 0) ...[
                const SizedBox(width: 16),
                Text('${comment.replyCount} 条回复',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    )),
              ],
              const Spacer(),
              if (onReply != null)
                GestureDetector(
                  onTap: onReply,
                  child: Text('回复',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      )),
                ),
              if (onDelete != null) ...[
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onDelete,
                  child: Text('删除',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      )),
                ),
              ],
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
