import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/providers.dart';
import '../../home/data/models.dart';

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(ref.read(kugouApiClientProvider));
});

/// 搜索结果（带总数，供分页）
class SearchResult {
  const SearchResult({required this.items, required this.total});
  final List<HomeSong> items;
  final int total;
}

/// 歌单搜索结果
class SearchPlaylistResult {
  const SearchPlaylistResult({required this.items, required this.total});
  final List<HomePlaylist> items;
  final int total;
}

/// 热搜榜
class HotSearchBoard {
  const HotSearchBoard({required this.name, required this.keywords});
  final String name;
  final List<HotSearchKeyword> keywords;

  factory HotSearchBoard.fromJson(Map<String, dynamic> json) {
    final kws = (json['keywords'] is List ? json['keywords'] as List : [])
        .map((e) => HotSearchKeyword.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return HotSearchBoard(
      name: json['name']?.toString() ?? '热搜榜',
      keywords: kws,
    );
  }
}

class HotSearchKeyword {
  const HotSearchKeyword({required this.keyword, this.reason});
  final String keyword;
  final String? reason;

  factory HotSearchKeyword.fromJson(Map<String, dynamic> json) {
    final reason = json['reason']?.toString();
    return HotSearchKeyword(
      keyword: json['keyword']?.toString() ?? '',
      reason: (reason == null || reason.isEmpty) ? null : reason,
    );
  }
}

/// 搜索仓库：搜索 / 热搜 / 建议 / 历史（Hive）
class SearchRepository {
  SearchRepository(this._api);

  final KugouApiClient _api;
  final _cache = MemoryCache.instance;

  static const String historyBoxName = 'search_history';
  static const int maxHistory = 20;

  Future<Map<String, dynamic>> _cachedGet(String path,
      {Map<String, dynamic>? query}) async {
    final key = MemoryCache.keyOf(path, query);
    final cached = _cache.get<Map<String, dynamic>>(key);
    if (cached != null) return cached;
    final data = await _api.get(path, query: query);
    _cache.set(key, data);
    return data;
  }

  List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 搜索单曲
  Future<SearchResult> searchSongs(String keywords,
      {int page = 1, int pageSize = 30}) async {
    final query = {
      'keywords': keywords,
      'type': 'song',
      'page': '$page',
      'pagesize': '$pageSize',
    };
    final json = await _cachedGet('/search', query: query);
    final data = json['data'];
    final raw = _asList(data is Map ? (data['lists'] ?? data['info']) : data);
    final items = raw
        .map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final total = _toInt(data is Map ? data['total'] : null);
    return SearchResult(items: items, total: total);
  }

  /// 搜索歌单
  Future<SearchPlaylistResult> searchPlaylists(String keywords,
      {int page = 1, int pageSize = 30}) async {
    final query = {
      'keywords': keywords,
      'type': 'special',
      'page': '$page',
      'pagesize': '$pageSize',
    };
    final json = await _cachedGet('/search', query: query);
    final data = json['data'];
    final raw = _asList(data is Map ? (data['lists'] ?? data['info']) : data);
    final items = raw
        .map((e) => HomePlaylist.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final total = _toInt(data is Map ? data['total'] : null);
    return SearchPlaylistResult(items: items, total: total);
  }

  /// 通用搜索（专辑/歌手/MV/歌词），返回原始列表
  Future<SearchResult> searchByType(String keywords, String type,
      {int page = 1, int pageSize = 30}) async {
    if (type == 'song') return searchSongs(keywords, page: page, pageSize: pageSize);
    final query = {
      'keywords': keywords,
      'type': type,
      'page': '$page',
      'pagesize': '$pageSize',
    };
    final json = await _cachedGet('/search', query: query);
    final data = json['data'];
    final raw = _asList(data is Map ? (data['lists'] ?? data['info']) : data);
    final items = raw
        .map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final total = _toInt(data is Map ? data['total'] : null);
    return SearchResult(items: items, total: total);
  }

  /// 热搜
  Future<List<HotSearchBoard>> fetchHotSearch() async {
    try {
      final json = await _cachedGet('/search/hot');
      final raw = _asList(json['data']?['list']);
      return raw
          .map((e) =>
              HotSearchBoard.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((b) => b.keywords.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 搜索建议
  Future<List<String>> fetchSuggest(String keywords) async {
    if (keywords.trim().isEmpty) return const [];
    try {
      final json =
          await _cachedGet('/search/suggest', query: {'keywords': keywords});
      final data = json['data'];
      final raw = _asList(data is Map
          ? (data['list'] ?? data['info'] ?? data['suggest'])
          : data);
      return raw
          .map((e) {
            if (e is Map) {
              return (e['keyword'] ?? e['KeywordName'] ?? e['name'] ?? e['suggest'])
                      ?.toString() ??
                  '';
            }
            return e.toString();
          })
          .where((s) => s.isNotEmpty)
          .take(10)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ---------- 搜索历史（Hive） ----------

  Future<Box<String>> _historyBox() async {
    if (Hive.isBoxOpen(historyBoxName)) return Hive.box<String>(historyBoxName);
    return Hive.openBox<String>(historyBoxName);
  }

  Future<List<String>> getHistory() async {
    try {
      final box = await _historyBox();
      return box.values.toList();
    } catch (_) {
      return const [];
    }
  }

  /// 添加历史（去重置顶，最多 20 条）
  Future<void> addHistory(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final box = await _historyBox();
    final list = box.values.toList()..remove(k);
    list.insert(0, k);
    if (list.length > maxHistory) list.removeRange(maxHistory, list.length);
    await box.clear();
    await box.addAll(list);
  }

  Future<void> removeHistory(String keyword) async {
    final box = await _historyBox();
    final list = box.values.toList()..remove(keyword);
    await box.clear();
    await box.addAll(list);
  }

  Future<void> clearHistory() async {
    final box = await _historyBox();
    await box.clear();
  }
}
