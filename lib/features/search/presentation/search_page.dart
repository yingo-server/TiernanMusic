import 'dart:async';

import '../../../core/image/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../home/data/models.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart'
    show GradientChip, EmptyState, ErrorRetry, ListSkeleton, SectionHeader, SongTile, SongTileMenuItem;
import '../../player/data/models.dart';
import '../../player/play_helper.dart';
import '../../download/presentation/download_sheet.dart';
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
    try {
      // R-27（第6批②，P2）：历史写盘失败不应中断搜索提交（第 6/9 条）
      await ref.read(searchRepositoryProvider).addHistory(k);
    } catch (e) {
      debugPrint('[search] addHistory failed (non-fatal): $e');
    }
    // R-26（第6批②，P2）：await 后 setState 必须 mounted 检查（第 18 条）
    if (!mounted) return;
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
    // 能否返回：作为底部导航 Tab 时不能，作为二级页面 push 进来时可以。
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      // Material 3 规范：搜索用 SearchBar 控件（自带展开/收起行为、
      // 统一的焦点态），而不是在 AppBar 里塞裸 TextField。
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  if (canPop) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: context.l10n.back,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
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
                      // 主题里已统一 SearchBar 外观，这里只覆盖必要项。
                      elevation: const WidgetStatePropertyAll(0),
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: // R-28（第6批②，P2）：联想词优先级高于已提交结果——
                  // 输入框有新输入（_showSuggest）时展示联想，否则回落已提交
                  // 结果/落地页。此前 _submittedKeyword 优先使联想词在
                  // 「首次搜索后继续输入」这一最常见状态下永久不可达。
                  _showSuggest
                      ? _SuggestList(suggestions: _suggestions, onTap: _submit)
                      : _submittedKeyword != null
                          ? _SearchResults(
                              key: ValueKey(_submittedKeyword),
                              keyword: _submittedKeyword!,
                            )
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

  /// 当前选中的热搜榜（第一项为「全部」）。
  String? _board;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final list = await ref.read(searchRepositoryProvider).getHistory();
    if (mounted) setState(() => _history = list);
  }

  /// 清空历史属于破坏性操作：二次确认 Dialog（error 色强调）。
  Future<void> _confirmClearHistory() async {
    final ok = await showDestructiveConfirm(
      context,
      title: context.l10n.clearHistory,
      message: context.l10n.clearHistoryConfirm,
      confirmLabel: context.l10n.clear,
    );
    if (!ok) return;
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
          error: (_, __) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: EmptyState(
              icon: Icons.wifi_off_rounded,
              message: context.l10n.hotSearchLoadFailed,
              actionLabel: context.l10n.reload,
              onAction: () => ref.invalidate(_hotSearchProvider),
            ),
          ),
          data: (boards) {
            final visible = _board == null
                ? boards
                : boards.where((b) => b.name == _board).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // M3 规范：榜单切换属于「筛选/切换」语义 → FilterChip
                // （带选中态），而不是横向一排普通按钮。
                if (boards.length > 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: Text(context.l10n.all),
                          selected: _board == null,
                          onSelected: (_) => setState(() => _board = null),
                        ),
                        for (final board in boards)
                          FilterChip(
                            label: Text(board.name),
                            selected: _board == board.name,
                            onSelected: (sel) => setState(
                                () => _board = sel ? board.name : null),
                          ),
                      ],
                    ),
                  ),
                for (final board in visible) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(board.name,
                        style: theme.textTheme.titleSmall
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
            );
          },
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

  /// R-29（第6批②）：分页（加载更多）失败态——区别于首次加载失败
  ///（_error），footer 据此渲染「重试」而非转圈。
  Object? _pageError;

  @override
  bool get wantKeepAlive => true;

  bool get _hasMore => _total < 0 || _items.length < _total;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scroll.addListener(() {
      // 失败态不自动重试（避免每次微滚都发请求+Toast 刷屏），只走 footer「重试」按钮。
      // R-29（第6批②，P2）：只有「首次加载失败」（_error）才阻断；
      // 分页失败（_pageError）已由 footer 重试按钮接管，滚动不应再被阻断。
      if (_error != null) return;
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
        // F-5（第7批终审，P2）：成功后必须清分页失败态——
        // 否则 ErrorRetry 重试成功后 footer 仍渲染「重试」按钮
        // 而非正常转圈，滚动自动加载也被阻断。
        _pageError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _initialLoading = false;
        // F-5：分页失败不复用 _error（_error 会阻断滚动自动加载，
        // 且首屏 ErrorRetry 与分页 footer 是两个不同的失败面）。
        // 只在「首屏尚无内容」时才算首次失败。
        if (_items.isEmpty) {
          _error = e;
        } else {
          _pageError = e;
        }
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
                // R-29（第6批②，P2）：失败显示可点重试，成功后才转圈
                if (_pageError != null) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () {
                          if (!mounted) return;
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
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final s = _items[i];
              return SongTile(
                title: s.name,
                artist: s.singer,
                cover: s.cover,
                duration: s.duration,
                // M3 规范：列表项多个操作收进 PopupMenuButton。
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
                        hash: s.hash ?? s.id,
                        albumId: s.albumId ?? '',
                        albumAudioId: s.albumAudioId ?? '',
                        name: s.name,
                        artist: s.singer,
                        cover: s.cover,
                        duration: Duration(seconds: s.duration),
                      ),
                    );
                  }
                },
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
                        // V33-17（修复②）：空封面守卫（R-30 同类）。
                        child: p.cover.isNotEmpty
                            ? CachedNetworkImage(
                                cacheManager: AppImageCache.instance,
                                imageUrl: p.cover,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                // V33-11（修复②）：补解码上限。网格两列、padding 16、
                                // 间距 12，单卡宽 ≈ (屏宽-44)/2，乘 dpr（第 25 条）。
                                memCacheWidth: ((MediaQuery.sizeOf(context).width -
                                            44) /
                                        2 *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                                errorWidget: (_, __, ___) => Container(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  child: const Icon(Icons.queue_music),
                                ),
                              )
                            : Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.queue_music),
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
                // V33-19（修复②）：空封面守卫（R-30 同类）。
                child: s.cover.isNotEmpty
                    ? CachedNetworkImage(
                        cacheManager: AppImageCache.instance,
                        imageUrl: s.cover,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        memCacheWidth: (48 *
                                MediaQuery.devicePixelRatioOf(context))
                            .round(),
                        placeholder: (_, __) => Container(
                          width: 48,
                          height: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.album_outlined),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: const Icon(Icons.album_outlined),
                      ),
              ),
              title:
                  Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.singer,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                if (type == 'mv' && s.hash != null) {
                  context.push('/mv/${s.hash}');
                } else if (type == 'album' && s.id.isNotEmpty) {
                  // 专辑：albumid 数字 ID → /album/:id
                  context.push('/album/${s.id}');
                } else if (type == 'author' && s.id.isNotEmpty) {
                  // 歌手：AuthorId → /artist/:id
                  context.push('/artist/${s.id}');
                }
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

