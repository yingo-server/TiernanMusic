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
///
/// 实测各来源字段差异（均为真实响应）：
/// - `/top/song`：`hash` / `songname` / `author_name` / `timelength`（**毫秒**）
///   / `album_sizable_cover` / `album_id` / `album_audio_id` / `trans_param.union_cover`
/// - `/yueku`：`hash` / `songname` / `singername` / `duration`（**秒**）/ `trans_param.union_cover`
/// - `/everyday/recommend`：`hash` / `songname` / `author_name` / `time_length`（**秒**）
///   / `sizable_cover` / `album_id` / `album_audio_id` / `singerinfo[]`
/// - `/search?type=song`：`FileHash` / `OriSongName` / `SingerName` / `Duration`（**秒**）
///   / `Image` / `AlbumID` / `MixSongID`
/// - 歌单歌曲：`hash` / `name`（"歌手 - 歌名"）/ `singerinfo[]` / `timelen`（**毫秒**）
class HomeSong {
  const HomeSong({
    required this.id,
    required this.name,
    required this.singer,
    required this.cover,
    required this.duration,
    this.hash,
    this.albumId,
    this.albumAudioId,
  });

  final String id;
  final String name;
  final String singer;
  final String cover;
  final int duration; // 秒
  final String? hash;
  final String? albumId;

  /// album_audio_id（= mixsongid），MV/歌词接口需要。
  final String? albumAudioId;

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
    final name = _toStr(json['songname'] ??
        json['OriSongName'] ??
        json['name'] ??
        json['song_name']);

    // 歌手：优先显式字段，其次 singerinfo[]（歌单/每日推荐）。
    var singer = _toStr(json['singername'] ??
        json['SingerName'] ??
        json['author_name'] ??
        json['singer_name']);
    if (singer.isEmpty) {
      final singerInfo = json['singerinfo'];
      if (singerInfo is List) {
        singer = singerInfo
            .whereType<Map>()
            .map((e) => _toStr(e['name']))
            .where((s) => s.isNotEmpty)
            .join('、');
      } else if (singerInfo is Map) {
        // Map 形态的 singerinfo（取 name）；其余未知类型一律置空，
        // 避免 _toStr 把对象 toString 成 '{name: xxx}' 这类脏值。
        singer = _toStr(singerInfo['name']);
      }
    }
    if (singer.isEmpty) singer = _toStr(json['singer']);

    final fileName = _toStr(json['FileName'] ?? json['filename']);
    var displayName = name;
    var displaySinger = singer;
    if (displayName.isEmpty && fileName.contains('-')) {
      final parts = fileName.split('-');
      displaySinger = displaySinger.isEmpty ? parts.first.trim() : displaySinger;
      displayName = parts.sublist(1).join('-').trim();
    }
    if (displayName.isEmpty) displayName = fileName;

    // 时长：按字段名区分单位，秒与毫秒不可混用。
    // - duration / Duration / time_length → 秒
    // - timelength / timelen → 毫秒
    var duration = 0;
    for (final key in ['duration', 'Duration', 'time_length']) {
      if (json.containsKey(key) && json[key] != null) {
        duration = _toInt(json[key]);
        break;
      }
    }
    if (duration <= 0) {
      for (final key in ['timelength', 'timelen', 'timeLength']) {
        if (json.containsKey(key) && json[key] != null) {
          duration = _toInt(json[key]) ~/ 1000;
          break;
        }
      }
    }

    final albumId = _toStr(json['albumid'] ?? json['album_id'] ?? json['AlbumID']);
    final albumAudioId = _toStr(json['album_audio_id'] ??
        json['MixSongID'] ??
        json['mixsongid'] ??
        json['albumAudioId']);
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
          json['album_img'] ??
          json['cover'])),
      duration: duration,
      hash: hash.isEmpty ? null : hash,
      albumId: albumId.isEmpty ? null : albumId,
      albumAudioId: albumAudioId.isEmpty ? null : albumAudioId,
    );
  }
}

/// 歌单
///
/// 实测全局 ID 字段名按接口不同：
/// - `/top/playlist`：`global_collection_id`（如 `collection_1_355034155_571395_0`）
/// - `/yueku` 的 `info.recommend[].extra`：`global_specialid`（同名格式）
/// - `/search?type=special`：`gid`（同名格式）
/// 三者都是 `collection_<...>` 形式，必须原样作为歌单路由参数。
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
    // 全局 ID 优先级：global_collection_id > global_specialid > gid。
    // 数字 specialid 不是全局 ID，不能当路由参数用。
    final globalId = _toStr(json['global_collection_id'] ??
        json['global_specialid'] ??
        json['gid']);
    final numericId = _toStr(json['specialid'] ?? json['id']);
    final name = _toStr(json['specialname'] ?? json['name'] ?? json['title']);
    return HomePlaylist(
      id: numericId.isNotEmpty ? numericId : globalId,
      globalCollectionId: globalId.isNotEmpty ? globalId : numericId,
      name: name.isEmpty ? '未知歌单' : name,
      cover: kugouImageUrl(_toStr(
          json['imgurl'] ??
              json['img'] ??
              json['flexible_cover'] ??
              json['pic'] ??
              json['cover'])),
      // play_count / playcount 都是实测字段；collect_count 是收藏数不是播放数。
      playCount: _toInt(json['play_count'] ?? json['playcount']),
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
