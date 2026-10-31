import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../home/data/models.dart';
import '../../../core/widgets/song_tile.dart' show GradientChip, EmptyState;
import '../../player/play_helper.dart';
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
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: _submit,
            decoration: InputDecoration(
              hintText: context.l10n.searchSongsHint,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                    )
                  : null,
              isDense: true,
              filled: true,
              fillColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ),
      body: _submittedKeyword != null
          ? _SearchResults(
              key: ValueKey(_submittedKeyword),
              keyword: _submittedKeyword!,
            )
          : _showSuggest
              ? _SuggestList(suggestions: _suggestions, onTap: _submit)
              : _SearchLanding(onTapKeyword: _submit),
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

  @override
  Widget build(BuildContext context) {
    final hotAsync = ref.watch(_hotSearchProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(context.l10n.searchHistory,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: context.l10n.clearHistory,
                onPressed: () async {
                  await ref
                      .read(searchRepositoryProvider)
                      .clearHistory();
                  _loadHistory();
                },
              ),
            ],
          ),
          Wrap(
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
          const SizedBox(height: 24),
        ],
        Text(context.l10n.hotSearch,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
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
                Text(board.name,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(
                            color:
                                Theme.of(context).colorScheme.primary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < board.keywords.length; i++)
                      Badge(
                        isLabelVisible: board.keywords[i].reason != null,
                        label: Text(board.keywords[i].reason ?? '',
                            style: const TextStyle(fontSize: 9)),
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
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return _ErrorRetry(onRetry: () {
        setState(() {
          _error = null;
          _initialLoading = true;
          _page = 1;
        });
        _loadMore();
      });
    }
    if (_items.isEmpty) {
      return EmptyState(icon: Icons.search_off_rounded, message: context.l10n.noSearchResults);
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _ErrorRetry(
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
            return InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () =>
                  context.push('/playlist/${p.globalCollectionId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CachedNetworkImage(
                        imageUrl: p.cover,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.queue_music),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _ErrorRetry(
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

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 56),
          const SizedBox(height: 12),
          Text(context.l10n.loadFailedNetwork),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.retry),
          ),
        ],
      ),
    );
  }
}
