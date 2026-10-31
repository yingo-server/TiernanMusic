/// 首页聚合模块数据模型（容错解析）
library;

/// 替换图片 URL 中的 {size} 占位符
String kugouImageUrl(String? url, {int size = 240}) {
  if (url == null || url.isEmpty) return '';
  var u = url.replaceAll('{size}', '$size');
  if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
  return u;
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

String _toStr(dynamic v) => v?.toString() ?? '';

/// 单曲
class HomeSong {
  const HomeSong({
    required this.id,
    required this.name,
    required this.singer,
    required this.cover,
    required this.duration,
    this.hash,
    this.albumId,
  });

  final String id;
  final String name;
  final String singer;
  final String cover;
  final int duration; // 秒
  final String? hash;
  final String? albumId;

  String get durationText {
    if (duration <= 0) return '--:--';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  factory HomeSong.fromJson(Map<String, dynamic> json) {
    final transParam = json['trans_param'] is Map
        ? json['trans_param'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final hash = _toStr(json['hash'] ?? json['FileHash']);
    final name = _toStr(json['songname'] ?? json['OriSongName'] ?? json['name']);
    final singer = _toStr(json['singername'] ??
        json['SingerName'] ??
        json['author_name'] ??
        json['singer']);
    final fileName = _toStr(json['FileName'] ?? json['filename']);
    var displayName = name;
    var displaySinger = singer;
    if (displayName.isEmpty && fileName.contains('-')) {
      final parts = fileName.split('-');
      displaySinger = displaySinger.isEmpty ? parts.first.trim() : displaySinger;
      displayName = parts.sublist(1).join('-').trim();
    }
    if (displayName.isEmpty) displayName = fileName;
    final duration = json.containsKey('duration') || json.containsKey('Duration')
        ? _toInt(json['duration'] ?? json['Duration'])
        : json.containsKey('time_length')
            ? _toInt(json['time_length'])
            : _toInt(json['timelength']) ~/ 1000;
    final albumId = _toStr(json['albumid'] ?? json['album_id'] ?? json['AlbumID']);
    return HomeSong(
      id: hash.isNotEmpty
          ? hash
          : _toStr(json['mixsongid'] ?? json['audio_id'] ?? json['id']),
      name: displayName.isEmpty ? '未知歌曲' : displayName,
      singer: displaySinger.isEmpty ? '未知歌手' : displaySinger,
      cover: kugouImageUrl(_toStr(transParam['union_cover'] ??
          json['imgurl'] ??
          json['Image'] ??
          json['album_sizable_cover'] ??
          json['sizable_cover'] ??
          json['album_img'])),
      duration: duration,
      hash: hash.isEmpty ? null : hash,
      albumId: albumId.isEmpty ? null : albumId,
    );
  }
}

/// 歌单
class HomePlaylist {
  const HomePlaylist({
    required this.id,
    required this.globalCollectionId,
    required this.name,
    required this.cover,
    required this.playCount,
    this.intro,
  });

  final String id;
  final String globalCollectionId;
  final String name;
  final String cover;
  final int playCount;
  final String? intro;

  String get playCountText {
    if (playCount >= 10000) {
      return '${(playCount / 10000).toStringAsFixed(1)}万';
    }
    return '$playCount';
  }

  factory HomePlaylist.fromJson(Map<String, dynamic> json) {
    final globalId = _toStr(json['global_collection_id'] ??
        json['global_specialid'] ??
        json['gid']);
    return HomePlaylist(
      id: _toStr(json['specialid'] ?? json['id']),
      globalCollectionId: globalId.isNotEmpty
          ? globalId
          : _toStr(json['specialid'] ?? json['id']),
      name: _toStr(json['specialname'] ?? json['name'] ?? json['title'])
          .isEmpty
          ? '未知歌单'
          : _toStr(json['specialname'] ?? json['name'] ?? json['title']),
      cover: kugouImageUrl(_toStr(
          json['imgurl'] ?? json['img'] ?? json['flexible_cover'] ?? json['cover'])),
      playCount: _toInt(json['playcount'] ?? json['play_count']),
      intro: _toStr(json['intro']).isEmpty ? null : _toStr(json['intro']),
    );
  }
}

/// 排行榜
class HomeRank {
  const HomeRank({
    required this.id,
    required this.name,
    required this.cover,
  });

  final String id;
  final String name;
  final String cover;

  factory HomeRank.fromJson(Map<String, dynamic> json) {
    return HomeRank(
      id: _toStr(json['rankid'] ?? json['id']),
      name: _toStr(json['rankname'] ?? json['name']).isEmpty
          ? '未知榜单'
          : _toStr(json['rankname'] ?? json['name']),
      cover: kugouImageUrl(
          _toStr(json['banner_9'] ?? json['imgurl'] ?? json['banner'])),
    );
  }
}

/// 轮播 Banner
class HomeBanner {
  const HomeBanner({required this.imageUrl, this.extra});

  final String imageUrl;
  final String? extra;

  factory HomeBanner.fromJson(Map<String, dynamic> json) {
    return HomeBanner(
      imageUrl: kugouImageUrl(
          _toStr(json['imgurl'] ?? json['image_url'] ?? json['bannerurl']),
          size: 480),
      extra: _toStr(json['extra'] ?? json['title']).isEmpty
          ? null
          : _toStr(json['extra'] ?? json['title']),
    );
  }
}

/// 首页聚合数据
class HomeData {
  const HomeData({
    this.banners = const [],
    this.songs = const [],
    this.playlists = const [],
    this.ranks = const [],
    this.dailyRecommend = const [],
  });

  final List<HomeBanner> banners;
  final List<HomeSong> songs;
  final List<HomePlaylist> playlists;
  final List<HomeRank> ranks;

  /// 每日推荐（未登录为 null，区分于空列表）
  final List<HomeSong>? dailyRecommend;
}
