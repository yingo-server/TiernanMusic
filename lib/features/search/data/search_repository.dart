import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/net/music_api.dart';
import 'package:hive/hive.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/resource/cached_api.dart';
import '../../../core/resource/resource_cache.dart';
import '../../../app/di.dart';
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
  SearchRepository(this._api) : _cached = CachedApiCall(_api, ns: 'search');

  final KugouApiClient _api;
  final CachedApiCall _cached;

  static const String historyBoxName = 'search_history';
  static const int maxHistory = 20;

  /// V400-B-04：读接口统一走 ResourceCache（搜索列表 90 秒语义 +
  /// in-flight 合并 + 失效回退）。
  Future<Map<String, dynamic>> _cachedGet(String path,
      {Map<String, dynamic>? query}) {
    return _cached.get(path, query: query, ttl: kListTtl);
  }

  List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  String _toStr(dynamic v) => v?.toString() ?? '';

  /// 安全地把列表项转成 Map；非 Map 项跳过而不是抛异常。
  List<Map<String, dynamic>> _maps(List<dynamic> raw) => raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  /// 从响应中取 `data.lists`（实测各类型搜索都是这个结构）。
  List<Map<String, dynamic>> _listsOf(Map<String, dynamic> json) {
    final data = json['data'];
    final raw = _asList(data is Map ? (data['lists'] ?? data['info']) : data);
    return _maps(raw);
  }

  /// 解析 total；接口未返回 total（<=0）但本页已返回满页数据时兜底 -1，
  /// 表示「总数未知、可能还有更多」，避免分页被截断为一页。
  int _totalOf(Map<String, dynamic> json, {int returned = 0, int pageSize = 30}) {
    final data = json['data'];
    final total = _toInt(data is Map ? data['total'] : null);
    if (total <= 0 && returned >= pageSize) return -1;
    return total;
  }

  /// 专辑搜索项。
  /// 实测字段：`albumid` / `albumname` / `singer` / `img` / `songcount`。
  Map<String, dynamic> _albumItem(Map<String, dynamic> e) {
    final albumId = _toStr(e['albumid'] ?? e['album_id'] ?? e['id']);
    final name = _toStr(e['albumname'] ?? e['name'] ?? e['title']);
    final singer = _toStr(e['singer'] ?? e['singername']);
    final img = _toStr(e['img'] ?? e['imgurl'] ?? e['cover']);
    return {
      'id': albumId,
      'name': name,
      'singer': singer,
      'cover': img,
      'albumid': albumId,
      // 专辑没有单曲 hash/时长；用 songcount 表示条目数，避免被当成可播放单曲。
      'songcount': _toInt(e['songcount'] ?? e['song_count']),
    };
  }

  /// 歌手搜索项。
  /// 实测字段：`AuthorId` / `AuthorName` / `Avatar` / `AlbumCount` / `AudioCount`。
  Map<String, dynamic> _authorItem(Map<String, dynamic> e) {
    final name = _toStr(e['AuthorName'] ?? e['authorname'] ?? e['name']);
    final albumCount = _toInt(e['AlbumCount']);
    final audioCount = _toInt(e['AudioCount']);
    final stats = <String>[];
    if (albumCount > 0) stats.add('$albumCount 专辑');
    if (audioCount > 0) stats.add('$audioCount 歌曲');
    return {
      'id': _toStr(e['AuthorId'] ?? e['authorid'] ?? e['id']),
      'name': name,
      // 歌手没有歌曲时长；副标题展示统计信息。
      'singer': stats.join(' · '),
      'cover': _toStr(e['Avatar'] ?? e['avatar'] ?? e['img']),
    };
  }

  /// MV 搜索项。
  /// 实测字段：`MvID` / `MvName` / `MvHash` / `SingerName` / `Duration`（秒）
  /// / `Pic`（**裸文件名**，不是 URL）/ `FileHash`（音频 hash）。
  Map<String, dynamic> _mvItem(Map<String, dynamic> e) {
    final mvHash = _toStr(e['MvHash'] ?? e['mv_hash']);
    final pic = _toStr(e['Pic'] ?? e['pic'] ?? e['ErectPic']);
    var cover = '';
    if (pic.isNotEmpty) {
      cover = pic.startsWith('http')
          ? pic
          : 'http://imge.kugou.com/mvthumb/{size}/$pic';
    }
    return {
      // MV 播放用的是 MvHash（/video/url 只认视频 hash，video_id 会 Not found）。
      'hash': mvHash,
      'id': _toStr(e['MvID'] ?? e['id']),
      'name': _toStr(e['MvName'] ?? e['mv_name'] ?? e['name']),
      'singer': _toStr(e['SingerName'] ?? e['singername']),
      'cover': cover,
      'duration': _toInt(e['Duration'] ?? e['duration']),
      'fileHash': _toStr(e['FileHash'] ?? e['hash']),
      'albumid': _toStr(e['AlbumID'] ?? e['album_id']),
    };
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
    final items = _listsOf(json)
        .map((e) => HomeSong.fromJson(e))
        .toList();
    return SearchResult(items: items, total: _totalOf(json, returned: items.length, pageSize: pageSize));
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
    final items = _listsOf(json)
        .map((e) => HomePlaylist.fromJson(e))
        .toList();
    return SearchPlaylistResult(items: items, total: _totalOf(json, returned: items.length, pageSize: pageSize));
  }

  /// 通用搜索（专辑/歌手/MV），返回归一化后的单曲列表。
  ///
  /// 实测各类型字段完全不同：
  /// - album：`albumid` / `albumname` / `singer` / `img`
  /// - author：`AuthorId` / `AuthorName` / `Avatar` / `AlbumCount` / `AudioCount`
  /// - mv：`MvID` / `MvName` / `MvHash` / `SingerName` / `Duration` / `Pic`
  /// 统一映射为 HomeSong，album/author 没有可播放 hash 与时长。
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
    final raw = _listsOf(json);
    final items = raw.map((e) {
      switch (type) {
        case 'album':
          return HomeSong.fromJson(_albumItem(e));
        case 'author':
          return HomeSong.fromJson(_authorItem(e));
        case 'mv':
          return HomeSong.fromJson(_mvItem(e));
        default:
          return HomeSong.fromJson(e);
      }
    }).toList();
    return SearchResult(
        items: items, total: _totalOf(json, returned: items.length, pageSize: pageSize));
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
      final groups = _asList(data is Map
          ? (data['list'] ?? data['info'] ?? data['suggest'])
          : data);
      // 搜索建议按 RecordDatas 分组返回，而不是字符串列表。
      final raw = groups
          .expand((e) => e is Map && e['RecordDatas'] is List
              ? e['RecordDatas'] as List
              : [e])
          .toList();
      return raw
          .map((e) {
            if (e is Map) {
              return (e['HintInfo'] ??
                      e['keyword'] ??
                      e['KeywordName'] ??
                      e['name'] ??
                      e['suggest'])
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
