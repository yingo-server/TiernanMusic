import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di.dart';
import '../../../core/utils/toast.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart';
import '../../auth/data/auth_providers.dart';
import '../../auth/presentation/login_guard.dart';
import '../data/comment_repository.dart';
import '../../../l10n/l10n.dart';

/// 楼中楼（评论回复列表）页面。
///
/// 复用评论列表的视觉结构：fetchFloor 分页拉取回复，
/// 支持回复（sendFloorReply）与删除自己的回复（cid + special_id + tid）。
class CommentFloorPage extends ConsumerStatefulWidget {
  const CommentFloorPage({
    super.key,
    required this.args,
    required this.comment,
  });

  final CommentArgsShim args;
  final Comment comment;

  @override
  ConsumerState<CommentFloorPage> createState() => _CommentFloorPageState();
}

/// 与 comments_page 的 _CommentArgs 解耦的轻量参数
/// （避免两个页面互相依赖私有类型）。
class CommentArgsShim {
  CommentArgsShim(this.type, this.id, this.specialId, this.tid);
  final CommentResourceType type;
  final String id;
  final String specialId; // special_child_id
  final String tid; // 顶层评论 id
}

class _CommentFloorPageState extends ConsumerState<CommentFloorPage> {
  final _scroll = ScrollController();
  final _inputCtrl = TextEditingController();
  final List<Comment> _comments = [];
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  // V39-AUX-06（第 16 条）：分页失败与「没有更多」是不同事实；
  // 失败置 _pageError，footer 显示重试（对齐 comments_page V37-08 范式）。
  String? _pageError;
  // V39-AUX-04 同源：发送防重闸门（第 21 条）
  bool _sending = false;

  bool get _isLoggedIn => ref.read(authStateProvider).valueOrNull != null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  CommentRepository get _repo => ref.read(_floorRepoProvider);

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    setState(() {
      _error = null;
      _pageError = null;
      _page = 1;
      _hasMore = true;
    });
    try {
      final result = await _repo.fetchFloor(
        specialId: widget.args.specialId,
        tid: widget.args.tid,
        type: widget.args.type,
        mixsongid:
            widget.args.type == CommentResourceType.song ? widget.args.id : null,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(result.comments);
        _hasMore = result.comments.isNotEmpty && _comments.length < result.total;
      });
    } catch (e) {
      if (!mounted) return;
      // V39-AUX-07：不裸上 '$e'（第 6/9 条 + friendly_error 口径）
      setState(() => _error = friendlyError(e));
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    _loadingMore = true;
    final next = _page + 1;
    try {
      final result = await _repo.fetchFloor(
        specialId: widget.args.specialId,
        tid: widget.args.tid,
        type: widget.args.type,
        mixsongid:
            widget.args.type == CommentResourceType.song ? widget.args.id : null,
        page: next,
      );
      if (!mounted) return;
      setState(() {
        _comments.addAll(result.comments);
        _page = next;
        _hasMore = result.comments.isNotEmpty && _comments.length < result.total;
        _pageError = null;
      });
    } catch (e) {
      // V39-AUX-06：失败不推进页码、留重试入口（第 9 条失败可观测）。
      // 原空体 catch(_){} 使用户只看到 footer 永远转圈。
      if (mounted) setState(() => _pageError = friendlyError(e));
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    if (!_isLoggedIn) {
      ensureLoggedIn(context, ref, action: context.l10n.comment);
      return;
    }
    _inputCtrl.clear();
    // V39-AUX-04 同源：floor 回复同样是写操作，飞行期间防重
    if (_sending) return;
    _sending = true;
    setState(() {});
    try {
      await _repo.sendFloorReply(
        specialId: widget.args.specialId,
        tid: widget.args.tid,
        content: text,
        resourceType: widget.args.type,
      );
      if (!mounted) return;
      Toast.show(context, context.l10n.commentSuccess);
      await _load();
    } catch (e) {
      if (!mounted) return;
      // V39-AUX-07：失败还原输入 + friendlyError 解包（不裸上 '$e'）
      _inputCtrl.text = text;
      Toast.show(context, context.l10n.commentFailed(friendlyError(e)));
    } finally {
      _sending = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteComment(Comment c) async {
    final confirm = await showDestructiveConfirm(
      context,
      title: context.l10n.deleteComment,
      message: context.l10n.deleteCommentConfirm,
      confirmLabel: context.l10n.delete,
    );
    if (!confirm) return;
    // 楼层回复删除必须带 special_id + tid（= 顶层评论 id）
    try {
      await _repo.deleteComment(
        cid: c.id,
        mixsongid:
            widget.args.type == CommentResourceType.song ? widget.args.id : null,
        specialId: widget.args.specialId,
        tid: widget.args.tid,
        resourceType: widget.args.type,
      );
      if (!mounted) return;
      Toast.show(context, context.l10n.deleted);
      await _load();
    } catch (e) {
      if (mounted) {
        // V39-AUX-08：与 comments_page 同一 unwrap/friendly 口径（第 8 条）
        Toast.show(context, context.l10n.deleteFailed(friendlyError(e)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.repliesCount(widget.comment.replyCount))),
      body: Column(
        children: [
          // 顶层评论内容固定在顶部
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.comment.userName,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(widget.comment.content),
              ],
            ),
          ),
          Expanded(
            child: _error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : _comments.isEmpty && !_loading
                    ? EmptyState(
                        icon: Icons.chat_bubble_outline_rounded,
                        message: context.l10n.noComments,
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          controller: _scroll,
                          itemCount: _comments.length + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _comments.length) {
                              // V39-AUX-06：分页失败 → 重试按钮（第 16 条）
                              if (_pageError != null) {
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: TextButton.icon(
                                      onPressed: () {
                                        setState(() => _pageError = null);
                                        _loadMore();
                                      },
                                      icon: const Icon(Icons.refresh),
                                      label: Text(context.l10n.retry),
                                    ),
                                  ),
                                );
                              }
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child: CircularProgressIndicator()),
                              );
                            }
                            final c = _comments[index];
                            return ListTile(
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundImage: c.avatar.isNotEmpty
                                    ? CachedNetworkImageProvider(
        cacheManager: AppImageCache.instance,
        
                                        c.avatar,
                                        // 头像显示尺寸约 32px × dpr
                                        maxWidth: (32 *
                                                MediaQuery.devicePixelRatioOf(
                                                    context))
                                            .round(),
                                      )
                                    : null,
                                child: c.avatar.isEmpty
                                    ? const Icon(Icons.person, size: 16)
                                    : null,
                              ),
                              title: Text(c.userName,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              subtitle: Text(c.content),
                              trailing: (_isLoggedIn && c.isMine)
                                  ? IconButton(
                                      icon: Icon(Icons.delete_outline,
                                          size: 20,
                                          color: theme.colorScheme.error),
                                      tooltip: context.l10n.delete,
                                      // V37-UI-05：图标 20dp + 默认 padding 8 →
                                      // 触控目标 <48dp；补足 48dp 触控区
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(
                                          minWidth: 48, minHeight: 48),
                                      padding: EdgeInsets.zero,
                                      onPressed: () => _deleteComment(c),
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
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
                    // V37-UI-08（P2-8 死按钮）：原 `onPressed: _isLoggedIn
                    // ? _send : () {}` 未登录点击完全无反应。_send 首行已有
                    // ensureLoggedIn 登录引导（与 comments_page 同一口径），
                    // 直接统一委托给它即可。
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final _floorRepoProvider = Provider<CommentRepository>(
    (ref) => CommentRepository(ref.watch(kugouApiClientProvider)));
