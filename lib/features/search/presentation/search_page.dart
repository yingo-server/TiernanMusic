import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../home/data/models.dart';
import '../../../core/widgets/song_tile.dart'
    show GradientChip, EmptyState, ErrorRetry, ListSkeleton, SectionHeader;
import '../../player/play_helper.dart';
import '../../../core/utils/toast.dart';
import '../data/search_repository.dart';
import '../../../l10n/l10n.dart';


final _hotSearchProvider = FutureProvider<List<HotSearchBoard>>(
    (ref) => ref.read(searchRepositoryProvider).fetchHotSearch());

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<String> _suggestions = [];
  bool _showSuggest = false;
  String? _submittedKeyword;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// SearchBar 的清除按钮依赖文本变化，需要主动刷新 trailing。
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggest = false;
        _submittedKeyword = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final list =
          await ref.read(searchRepositoryProvider).fetchSuggest(text.trim());
      if (!mounted || _controller.text.trim() != text.trim()) return;
      setState(() {
        _suggestions = list;
        _showSuggest = list.isNotEmpty;
      });
    });
  }

  Future<void> _submit(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    _debounce?.cancel();
    _focusNode.unfocus();
    await ref.read(searchRepositoryProvider).addHistory(k);
    setState(() {
      _controller.text = k;
      _showSuggest = false;
      _suggestions = [];
      _submittedKeyword = k;
    });
  }

  void _clear() {
    _controller.clear();
    _onChanged('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // Material 3 规范：搜索用 SearchBar 控件（自带展开/收起行为、
      // 统一的焦点态），而不是在 AppBar 里塞裸 TextField。
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SearchBar(
                controller: _controller,
                focusNode: _focusNode,
                hintText: context.l10n.searchSongsHint,
                leading: const Icon(Icons.search),
                trailing: [
                  if (_controller.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: context.l10n.clear,
                      onPressed: _clear,
                    ),
                ],
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: _submit,
                elevation: const WidgetStatePropertyAll(0),
                backgroundColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHigh,
                ),
                side: WidgetStatePropertyAll(
                  BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ),
            Expanded(
              child: _submittedKeyword != null
                  ? _SearchResults(
                      key: ValueKey(_submittedKeyword),
                      keyword: _submittedKeyword!,
                    )
                  : _showSuggest
                      ? _SuggestList(suggestions: _suggestions, onTap: _submit)
                      : _SearchLanding(onTapKeyword: _submit),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 建议下拉 ----------

class _SuggestList extends StatelessWidget {
  const _SuggestList({required this.suggestions, required this.onTap});
  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.search, size: 20),
        title: Text(suggestions[i]),
        onTap: () => onTap(suggestions[i]),
      ),
    );
  }
}

// ---------- 未输入：历史 + 热搜 ----------

class _SearchLanding extends ConsumerStatefulWidget {
  const _SearchLanding({required this.onTapKeyword});
  final ValueChanged<String> onTapKeyword;

  @override
  ConsumerState<_SearchLanding> createState() => _SearchLandingState();
}

class _SearchLandingState extends ConsumerState<_SearchLanding> {
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final list = await ref.read(searchRepositoryProvider).getHistory();
    if (mounted) setState(() => _history = list);
  }

  /// 清空历史属于破坏性操作：二次确认 Dialog。
  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.clearHistory),
        content: Text(context.l10n.clearHistoryConfirm),
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
    if (ok != true) return;
    await ref.read(searchRepositoryProvider).clearHistory();
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final hotAsync = ref.watch(_hotSearchProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        if (_history.isNotEmpty) ...[
          SectionHeader(
            title: context.l10n.searchHistory,
            action: TextButton.icon(
              onPressed: _confirmClearHistory,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(context.l10n.clear),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final h in _history)
                  InputChip(
                    label: Text(h),
                    onPressed: () => widget.onTapKeyword(h),
                    onDeleted: () async {
                      await ref
                          .read(searchRepositoryProvider)
                          .removeHistory(h);
                      _loadHistory();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        SectionHeader(
          title: context.l10n.hotSearch,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        ),
        hotAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => const SizedBox.shrink(),
          data: (boards) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final board in boards) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(board.name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < board.keywords.length; i++)
                        Badge(
                          isLabelVisible: board.keywords[i].reason != null,
                          label: Text(board.keywords[i].reason ?? ''),
                          offset: const Offset(8, -4),
                          child: GradientChip(
                            label: board.keywords[i].keyword,
                            index: i,
                            onTap: () =>
                                widget.onTapKeyword(board.keywords[i].keyword),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------- 搜索结果 ----------

class _SearchResults extends StatelessWidget {
  const _SearchResults({super.key, required this.keyword});
  final String keyword;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: context.l10n.tabSongs),
              Tab(text: context.l10n.playlist),
              Tab(text: context.l10n.albums),
              Tab(text: context.l10n.artists),
              Tab(text: context.l10n.mv),
            ],
          ),
          Expanded(
            child: TabBarView(
              // 结果 Tab 切换带 PageTransition 滑动过渡
              physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
              children: [
                _SongResultTab(keyword: keyword),
                _PlaylistResultTab(keyword: keyword),
                _GenericResultTab(keyword: keyword, type: 'album'),
                _GenericResultTab(keyword: keyword, type: 'author'),
                _GenericResultTab(keyword: keyword, type: 'mv'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 单曲结果（分页） ----------

class _SongResultTab extends ConsumerStatefulWidget {
  const _SongResultTab({required this.keyword});
  final String keyword;

  @override
  ConsumerState<_SongResultTab> createState() => _SongResultTabState();
}

class _SongResultTabState extends ConsumerState<_SongResultTab>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final List<HomeSong> _items = [];
  int _page = 1;
  int _total = -1;
  bool _loading = false;
  bool _initialLoading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  bool get _hasMore => _total < 0 || _items.length < _total;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scroll.addListener(() {
      if (_scroll.position.pixels >=
              _scroll.position.maxScrollExtent - 200 &&
          !_loading &&
          _hasMore) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final result = await ref
          .read(searchRepositoryProvider)
          .searchSongs(widget.keyword, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _total = result.total;
        _page++;
        _initialLoading = false;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _initialLoading = false;
        _error = e;
      });
      // 列表已有内容时静默降级：仅弹一条去重 Toast，不打断浏览
      if (_items.isNotEmpty) {
        Toast.show(context, context.l10n.genericErrorTitle);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_initialLoading) {
      // 列表加载用骨架屏而非转圈，视觉更稳定
      return const ListSkeleton(itemCount: 8);
    }
    if (_error != null && _items.isEmpty) {
      return ErrorRetry(error: _error, onRetry: () {
        setState(() {
          _error = null;
          _initialLoading = true;
          _page = 1;
        });
        _loadMore();
      });
    }
    if (_items.isEmpty) {
      return EmptyState(
          icon: Icons.search_off_rounded, message: context.l10n.noSearchResults);
    }
    return Column(
      children: [
        if (_total > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(context.l10n.totalSongs(_total),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        Expanded(
          child: ListView.separated(
            controller: _scroll,
            itemCount: _items.length + (_hasMore ? 1 : 0),
            separatorBuilder: (_, __) =>
                const Divider(height: 1, indent: 88),
            itemBuilder: (context, i) {
              if (i >= _items.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final s = _items[i];
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: s.cover,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      width: 48,
                      height: 48,
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: const Icon(Icons.music_note),
                    ),
                  ),
                ),
                title:
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.singer,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                // trailing 只承载次要信息（时长）
                trailing: Text(s.durationText,
                    style: Theme.of(context).textTheme.bodySmall),
                onTap: () {
                  ref.read(playHelperProvider).playHomeQueue(_items, i);
                  context.push('/player');
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------- 歌单结果（网格） ----------

class _PlaylistResultTab extends ConsumerWidget {
  const _PlaylistResultTab({required this.keyword});
  final String keyword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_playlistSearchProvider(keyword));
    return result.when(
      loading: () => const ListSkeleton(itemCount: 6),
      error: (e, _) => ErrorRetry(
          error: e,
          onRetry: () => ref.invalidate(_playlistSearchProvider(keyword))),
      data: (r) {
        if (r.items.isEmpty) {
          return EmptyState(
              icon: Icons.playlist_play_rounded, message: context.l10n.noRelatedPlaylists);
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          itemCount: r.items.length,
          itemBuilder: (context, i) {
            final p = r.items[i];
            final theme = Theme.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () =>
                            context.push('/playlist/${p.globalCollectionId}'),
                        child: CachedNetworkImage(
                          imageUrl: p.cover,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.queue_music),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
            );
          },
        );
      },
    );
  }
}

final _playlistSearchProvider =
    FutureProvider.family<SearchPlaylistResult, String>(
        (ref, keyword) =>
            ref.read(searchRepositoryProvider).searchPlaylists(keyword));

// ---------- 专辑/歌手/MV 通用结果 ----------

class _GenericResultTab extends ConsumerWidget {
  const _GenericResultTab({required this.keyword, required this.type});
  final String keyword;
  final String type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_genericSearchProvider((keyword, type)));
    return result.when(
      loading: () => const ListSkeleton(itemCount: 6),
      error: (e, _) => ErrorRetry(
          error: e,
          onRetry: () =>
              ref.invalidate(_genericSearchProvider((keyword, type)))),
      data: (r) {
        if (r.items.isEmpty) {
          return EmptyState(
            icon: type == 'mv' ? Icons.movie_outlined : Icons.album_outlined,
            message: context.l10n.noRelatedContent,
          );
        }
        return ListView.separated(
          itemCount: r.items.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
          itemBuilder: (context, i) {
            final s = r.items[i];
            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: s.cover,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    width: 48,
                    height: 48,
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: const Icon(Icons.album_outlined),
                  ),
                ),
              ),
              title:
                  Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.singer,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                if (type == 'mv' && s.hash != null) {
                  context.push('/mv/${s.hash}');
                } else if (type == 'album' && s.albumId != null) {
                  context.push('/playlist/${s.albumId}');
                }
                // TODO(播放模块): 歌手页跳接待补充
              },
            );
          },
        );
      },
    );
  }
}

final _genericSearchProvider =
    FutureProvider.family<SearchResult, (String, String)>(
        (ref, arg) => ref
            .read(searchRepositoryProvider)
            .searchByType(arg.$1, arg.$2));
