import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';

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
  Future<List<UserPlaylist>> fetchUserPlaylists(
      {int page = 1, int pageSize = 30}) async {
    final data = await _api.get('/user/playlist',
        query: {'page': page, 'pagesize': pageSize});
    final list = data['data']?['info'] as List? ?? [];
    return list
        .map((e) => UserPlaylist.fromJson(e as Map<String, dynamic>))
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
    final data = tracks
        .map((t) => [t.name, t.hash, t.albumId, t.albumAudioId]
            .where((e) => e != null && e.isNotEmpty)
            .join('|'))
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

  factory PlaylistDetail.fromJson(Map<String, dynamic> json, String id) {
    final data = json['data'] is List && (json['data'] as List).isNotEmpty
        ? (json['data'] as List).first as Map<String, dynamic>
        : (json['data'] as Map<String, dynamic>?) ?? {};
    String cover = '${data['imgurl'] ?? data['flexible_cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '480');
    return PlaylistDetail(
      id: id,
      name: '${data['specialname'] ?? data['name'] ?? ''}',
      cover: cover,
      intro: '${data['intro'] ?? ''}',
      playCount: (data['playcount'] ?? 0) is int
          ? data['playcount'] ?? 0
          : int.tryParse('${data['playcount']}') ?? 0,
      trackCount: (data['songcount'] ?? 0) is int
          ? data['songcount'] ?? 0
          : int.tryParse('${data['songcount']}') ?? 0,
      creatorName: '${data['nickname'] ?? data['username'] ?? ''}',
    );
  }
}

class PlaylistTracks {
  PlaylistTracks({required this.songs, required this.total});
  final List<PlaylistSong> songs;
  final int total;

  factory PlaylistTracks.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final info = data['info'] as List? ?? data['songs'] as List? ?? [];
    final songs = info
        .map((e) => PlaylistSong.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = (data['count'] ?? data['total'] ?? songs.length) is int
        ? (data['count'] ?? data['total'] ?? songs.length)
        : int.tryParse('${data['count'] ?? data['total']}') ?? songs.length;
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
  });
  final String hash;
  final String name;
  final String artist;
  final String albumId;
  final String albumAudioId;
  final int duration;
  final String fileId;

  factory PlaylistSong.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? json['filename'] ?? json['OriSongName'] ?? ''}';
    final singer = '${json['singername'] ?? json['SingerName'] ?? json['author_name'] ?? ''}';
    return PlaylistSong(
      hash: '${json['hash'] ?? json['FileHash'] ?? ''}',
      name: name.contains(' - ') ? name.split(' - ').last : name,
      artist: singer.isNotEmpty ? singer : (name.contains(' - ') ? name.split(' - ').first : ''),
      albumId: '${json['album_id'] ?? json['AlbumID'] ?? ''}',
      albumAudioId: '${json['album_audio_id'] ?? json['MixSongID'] ?? json['audio_id'] ?? ''}',
      duration: (json['duration'] ?? json['Duration'] ?? 0) is int
          ? (json['duration'] ?? json['Duration'] ?? 0)
          : int.tryParse('${json['duration'] ?? json['Duration']}') ?? 0,
      fileId: '${json['fileid'] ?? json['FileID'] ?? ''}',
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

  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    var cover = '${json['pic'] ?? json['imgurl'] ?? ''}';
    cover = cover.replaceAll('{size}', '240');
    return UserPlaylist(
      listid: '${json['listid'] ?? json['list_id'] ?? ''}',
      name: '${json['name'] ?? json['specialname'] ?? ''}',
      cover: cover,
      count: (json['count'] ?? json['songcount'] ?? 0) is int
          ? (json['count'] ?? json['songcount'] ?? 0)
          : int.tryParse('${json['count'] ?? json['songcount']}') ?? 0,
      isMine: (json['list_create_type'] ?? 0) == 0 ||
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
