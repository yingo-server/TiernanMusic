import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/providers.dart';
import 'models.dart';

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository(ref.read(kugouApiClientProvider));
});

/// 首页聚合数据 Provider
final homeDataProvider = FutureProvider<HomeData>((ref) {
  return ref.read(homeRepositoryProvider).fetchHomeData();
});

/// 首页数据仓库：聚合 /yueku + /top/playlist + /rank/list，
/// banner 与每日推荐独立容错（失败置 null / 空）。
class HomeRepository {
  HomeRepository(this._api);

  final KugouApiClient _api;
  final _cache = MemoryCache.instance;

  List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  /// 带缓存的 GET，返回 Map 中指定路径下的原始 JSON
  Future<Map<String, dynamic>> _cachedGet(String path,
      {Map<String, dynamic>? query}) async {
    final key = MemoryCache.keyOf(path, query);
    final cached = _cache.get<Map<String, dynamic>>(key);
    if (cached != null) return cached;
    final data = await _api.get(path, query: query);
    _cache.set(key, data);
    return data;
  }

  Future<List<HomeSong>> fetchYuekuSongs() async {
    final json = await _cachedGet('/yueku');
    final info = (json['data']?['info'] as Map?) ?? {};
    final songs = _asList(info['song'])
        .whereType<Map>()
        .map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return songs;
  }

  Future<List<HomePlaylist>> fetchYuekuPlaylists() async {
    final json = await _cachedGet('/yueku');
    final info = (json['data']?['info'] as Map?) ?? {};
    final raw = _asList(info['special'] ?? info['playlist'] ?? info['recommend']);
    return raw.whereType<Map>().map((e) {
      final item = Map<String, dynamic>.from(e);
      // 乐库推荐歌单的实际内容包在 extra 中。
      return HomePlaylist.fromJson(item['extra'] is Map
          ? Map<String, dynamic>.from(item['extra'] as Map)
          : item);
    }).toList();
  }

  /// 推荐歌单（优先 /top/playlist，失败回落 /yueku）
  Future<List<HomePlaylist>> fetchTopPlaylists({int categoryId = 0}) async {
    try {
      final query = {'category_id': '$categoryId', 'withsong': '1'};
      final json = await _cachedGet('/top/playlist', query: query);
      final raw = _asList(json['data']?['special_list'] ?? json['data']?['info']);
      if (raw.isNotEmpty) {
        return raw
            .whereType<Map>()
            .map((e) => HomePlaylist.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {
      // 回落 yueku 歌单
    }
    return fetchYuekuPlaylists();
  }

  /// 排行榜列表
  Future<List<HomeRank>> fetchRankList() async {
    final json = await _cachedGet('/rank/list', query: {'withsong': '1'});
    final data = json['data'];
    final raw = data is Map ? _asList(data['info']) : _asList(data);
    return raw
        .whereType<Map>()
        .map((e) => HomeRank.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 轮播 Banner（可能 502，容错返回空列表）
  Future<List<HomeBanner>> fetchBanners() async {
    try {
      final json = await _cachedGet('/yueku/banner');
      final data = json['data'];
      final raw = _asList(
          data is Map ? (data['banner'] ?? data['list'] ?? data['info']) : data);
      return raw
          .whereType<Map>()
          .map((e) => HomeBanner.fromJson(Map<String, dynamic>.from(e)))
          .where((b) => b.imageUrl.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 每日推荐（需登录，未登录等错误返回 null 以隐藏入口）
  Future<List<HomeSong>?> fetchDailyRecommend() async {
    try {
      final json = await _cachedGet('/everyday/recommend');
      final data = json['data'];
      final raw = _asList(
          data is Map
              ? (data['song_list'] ?? data['list'] ?? data['songs'] ?? data['info'])
              : data);
      if (raw.isEmpty) return null;
      return raw
          .whereType<Map>()
          .map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 新歌（/top/song 不可用则用 /yueku 的 song）
  Future<List<HomeSong>> fetchNewSongs() async {
    try {
      final json = await _cachedGet('/top/song');
      final data = json['data'];
      final raw = _asList(
          data is Map ? (data['info'] ?? data['list'] ?? data['songs']) : data);
      if (raw.isNotEmpty) {
        return raw
            .whereType<Map>()
            .map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {
      // 回落
    }
    return fetchYuekuSongs();
  }

  /// 首页聚合：全部并发，单项超时 12s，任一失败不影响其它区块。
  Future<HomeData> fetchHomeData() async {
    const t = Duration(seconds: 12);

    Future<List<HomeSong>> songsF() async {
      try { return await fetchNewSongs().timeout(t); } catch (_) { return const []; }
    }
    Future<List<HomePlaylist>> plF() async {
      try { return await fetchTopPlaylists().timeout(t); } catch (_) { return const []; }
    }
    Future<List<HomeRank>> rankF() async {
      try { return await fetchRankList().timeout(t); } catch (_) { return const []; }
    }
    Future<List<HomeBanner>> bannerF() async {
      try { return await fetchBanners().timeout(t); } catch (_) { return const []; }
    }
    Future<List<HomeSong>?> dailyF() async {
      try { return await fetchDailyRecommend().timeout(t); } catch (_) { return null; }
    }

    final results = await Future.wait<dynamic>([
      songsF(), plF(), rankF(), bannerF(), dailyF(),
    ]);

    final songs = results[0] as List<HomeSong>;
    final playlists = results[1] as List<HomePlaylist>;
    final ranks = results[2] as List<HomeRank>;
    final banners = results[3] as List<HomeBanner>;
    final daily = results[4] as List<HomeSong>?;

    if (songs.isEmpty && playlists.isEmpty && ranks.isEmpty && banners.isEmpty) {
      throw Exception('首页数据加载失败，请检查网络后重试');
    }

    return HomeData(
      banners: banners,
      songs: songs,
      playlists: playlists,
      ranks: ranks,
      dailyRecommend: daily,
    );
  }
}
