import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';

/// 宽松地转 int：数字直接取整，字符串解析，失败返回 fallback。
int _toInt(dynamic v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return fallback;
  return int.tryParse('$v') ?? fallback;
}

class PlaylistRepository {
  PlaylistRepository(this._api);
  final KugouApiClient _api;

  /// 公共歌单详情
  Future<PlaylistDetail> fetchDetail(String globalCollectionId) async {
    final cacheKey = MemoryCache.keyOf('/playlist/detail', {'ids': globalCollectionId});
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/playlist/detail', query: {'ids': globalCollectionId});
    if (cached == null) MemoryCache.instance.set(cacheKey, data);
    return PlaylistDetail.fromJson(data, globalCollectionId);
  }

  /// 公共歌单歌曲（分页）
  Future<PlaylistTracks> fetchTracks(String globalCollectionId,
      {int page = 1, int pageSize = 100}) async {
    final q = {'id': globalCollectionId, 'page': page, 'pagesize': pageSize};
    final cacheKey = MemoryCache.keyOf('/playlist/track/all', q);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/playlist/track/all', query: q);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);
    return PlaylistTracks.fromJson(data);
  }

  /// 我的歌单（需登录）
  ///
  /// 实测 `/user/playlist`：歌单位于 `data.info[]`，首项 `listid=1`，
  /// 同时含 `global_collection_id`。
  Future<List<UserPlaylist>> fetchUserPlaylists(
      {int page = 1, int pageSize = 30}) async {
    final data = await _api.get('/user/playlist',
        query: {'page': page, 'pagesize': pageSize});
    final raw = data['data'];
    final list = raw is Map && raw['info'] is List
        ? raw['info'] as List
        : (raw is List ? raw : const []);
    return list
        .whereType<Map>()
        .map((e) => UserPlaylist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 用户歌单歌曲
  Future<PlaylistTracks> fetchUserTracks(String listid,
      {int page = 1, int pageSize = 300}) async {
    final data = await _api.get('/playlist/track/all/new',
        query: {'listid': listid, 'page': page, 'pagesize': pageSize, 'type': 0});
    return PlaylistTracks.fromJson(data);
  }

  /// 收藏歌单（type=1 收藏公共歌单，type=0 新建）
  Future<void> collectPlaylist({
    required String name,
    String? listCreateUserid,
    String? listCreateListid,
    String? listCreateGid,
  }) async {
    await _api.get('/playlist/add', query: {
      'type': listCreateUserid != null ? 1 : 0,
      'name': name,
      if (listCreateUserid != null) 'list_create_userid': listCreateUserid,
      if (listCreateListid != null) 'list_create_listid': listCreateListid,
      if (listCreateGid != null) 'list_create_gid': listCreateGid,
    });
  }

  /// 删除/取消收藏歌单
  Future<void> deletePlaylist(String listid) =>
      _api.get('/playlist/del', query: {'listid': listid}).then((_) {});

  /// 添加歌曲到歌单
  Future<void> addTracks(String listid, List<TrackRef> tracks) async {
    // 位置参数 data：名称|hash|album_id|album_audio_id，
    // 空字段必须占位（不能 skip，否则后字段前移导致服务端解析错位）
    final data = tracks
        .map((t) =>
            [t.name, t.hash, t.albumId ?? '', t.albumAudioId ?? ''].join('|'))
        .join(',');
    await _api.get('/playlist/tracks/add', query: {'listid': listid, 'data': data});
  }

  /// 从歌单删除歌曲
  Future<void> removeTracks(String listid, List<String> fileids) =>
      _api.get('/playlist/tracks/del',
          query: {'listid': listid, 'fileids': fileids.join(',')}).then((_) {});
}

class PlaylistDetail {
  PlaylistDetail({
    required this.id,
    required this.name,
    required this.cover,
    required this.intro,
    required this.playCount,
    required this.trackCount,
    required this.creatorName,
  });
  final String id;
  final String name;
  final String cover;
  final String intro;
  final int playCount;
  final int trackCount;
  final String creatorName;

  /// 实测 `/playlist/detail`：
  /// - `data` 是**数组**，首项为歌单对象
  /// - 名称 `name`；封面 `pic`（带 `{size}` 占位）；简介 `intro`
  /// - 曲目数 `count`；创建者 `list_create_username`
  /// - 全局 ID `global_collection_id`
  /// （`playcount` / `play_count` 实测都不存在，播放数只有 `heat`）
  factory PlaylistDetail.fromJson(Map<String, dynamic> json, String id) {
    final raw = json['data'];
    Map<String, dynamic> data;
    if (raw is List) {
      data = raw.isNotEmpty && raw.first is Map
          ? Map<String, dynamic>.from(raw.first as Map)
          : <String, dynamic>{};
    } else if (raw is Map) {
      data = Map<String, dynamic>.from(raw);
    } else {
      data = <String, dynamic>{};
    }
    var cover = '${data['pic'] ?? data['imgurl'] ?? data['flexible_cover'] ?? data['cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '480');
    return PlaylistDetail(
      id: '${data['global_collection_id'] ?? id}',
      name: '${data['name'] ?? data['specialname'] ?? ''}',
      cover: cover,
      intro: '${data['intro'] ?? ''}',
      playCount: _toInt(data['playcount'] ?? data['play_count'] ?? data['heat']),
      trackCount: _toInt(data['count'] ?? data['songcount']),
      creatorName:
          '${data['list_create_username'] ?? data['nickname'] ?? data['username'] ?? ''}',
    );
  }
}

class PlaylistTracks {
  PlaylistTracks({required this.songs, required this.total});
  final List<PlaylistSong> songs;
  final int total;

  /// 实测两种歌单结构不同：
  /// - 公共歌单 `/playlist/track/all` → `data.songs[]`，总数 `data.count`
  /// - 用户歌单 `/playlist/track/all/new` → `data.info[]`，总数 `data.count`
  factory PlaylistTracks.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    // 用户歌单优先取 info，公共歌单取 songs；两者都兼容。
    final rawList = data['info'] is List
        ? data['info'] as List
        : (data['songs'] is List ? data['songs'] as List : const []);
    final songs = rawList
        .whereType<Map>()
        .map((e) => PlaylistSong.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final total = _toInt(data['count'] ?? data['total'], fallback: songs.length);
    return PlaylistTracks(songs: songs, total: total);
  }
}

class PlaylistSong {
  PlaylistSong({
    required this.hash,
    required this.name,
    required this.artist,
    required this.albumId,
    required this.albumAudioId,
    required this.duration,
    required this.fileId,
    this.cover = '',
  });
  final String hash;
  final String name;
  final String artist;
  final String albumId;
  final String albumAudioId;
  final int duration; // 秒
  final String fileId;

  /// 歌曲封面（歌单歌曲有直接 `cover` 字段）。
  final String cover;

  /// 实测公共/用户歌单歌曲字段：
  /// `hash` / `name`（"歌手 - 歌名"）/ `singerinfo[].name` / `album_id` /
  /// `mixsongid`（= album_audio_id）/ `timelen`（**毫秒**）/ `fileid` /
  /// `cover` / `trans_param.union_cover`
  factory PlaylistSong.fromJson(Map<String, dynamic> json) {
    final rawName = '${json['name'] ?? json['filename'] ?? json['OriSongName'] ?? ''}';

    // 歌手：singerinfo[] 优先（实测歌单歌曲都有），其次显式字段。
    final singerInfo = json['singerinfo'];
    var singers = '';
    if (singerInfo is List) {
      singers = singerInfo
          .whereType<Map>()
          .map((e) => '${e['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .join('、');
    }
    final explicitSinger =
        '${json['singername'] ?? json['SingerName'] ?? json['author_name'] ?? ''}';

    // 歌名："歌手 - 歌名"。只剥一次前缀，歌名自身可能含分隔符。
    var name = rawName;
    var artist = explicitSinger.isNotEmpty ? explicitSinger : singers;
    final sep = rawName.indexOf(' - ');
    if (sep > 0) {
      final prefix = rawName.substring(0, sep).trim();
      name = rawName.substring(sep + 3).trim();
      if (explicitSinger.isEmpty && singers.isEmpty) artist = prefix;
      if (explicitSinger.isNotEmpty && prefix != explicitSinger) {
        // 前缀与显式歌手不同：保留完整名，避免误删歌名。
        name = rawName;
      }
    }

    // 时长：timelen 是**毫秒**；duration / Duration 是**秒**。
    var duration = 0;
    if (json['timelen'] != null) {
      duration = _toInt(json['timelen']) ~/ 1000;
    } else if (json['timelength'] != null) {
      duration = _toInt(json['timelength']) ~/ 1000;
    } else {
      duration = _toInt(json['duration'] ?? json['Duration']);
    }

    final transParam = json['trans_param'] is Map
        ? Map<String, dynamic>.from(json['trans_param'] as Map)
        : <String, dynamic>{};
    var cover = '${json['cover'] ?? transParam['union_cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '300');

    return PlaylistSong(
      hash: '${json['hash'] ?? json['FileHash'] ?? ''}',
      name: name,
      artist: artist.isEmpty
          ? (name.isNotEmpty && rawName.contains(' - ')
              ? rawName.substring(0, rawName.indexOf(' - ')).trim()
              : '')
          : artist,
      albumId: '${json['album_id'] ?? json['AlbumID'] ?? ''}',
      // mixsongid 才是 album_audio_id；audio_id 是另一套 id。
      albumAudioId:
          '${json['mixsongid'] ?? json['MixSongID'] ?? json['album_audio_id'] ?? ''}',
      duration: duration,
      fileId: '${json['fileid'] ?? json['FileID'] ?? ''}',
      cover: cover,
    );
  }
}

class UserPlaylist {
  UserPlaylist({
    required this.listid,
    required this.name,
    required this.cover,
    required this.count,
    required this.isMine,
  });
  final String listid;
  final String name;
  final String cover;
  final int count;
  final bool isMine;

  /// 实测用户歌单项：`listid` / `name` / `pic` / `count` /
  /// `list_create_type` / `global_collection_id`。
  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    var cover = '${json['pic'] ?? json['imgurl'] ?? json['cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '240');
    return UserPlaylist(
      listid: '${json['listid'] ?? json['list_id'] ?? ''}',
      name: '${json['name'] ?? json['specialname'] ?? ''}',
      cover: cover,
      count: _toInt(json['count'] ?? json['songcount']),
      isMine: _toInt(json['list_create_type'], fallback: 1) == 0 ||
          '${json['is_create'] ?? ''}' == '1',
    );
  }
}

class TrackRef {
  TrackRef({required this.name, required this.hash, this.albumId, this.albumAudioId});
  final String name;
  final String hash;
  final String? albumId;
  final String? albumAudioId;
}
