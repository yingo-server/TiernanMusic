import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/config/app_config.dart';

class MvRepository {
  MvRepository(this._api);
  final KugouApiClient _api;

  /// 歌曲关联 MV
  Future<List<MvInfo>> findBySong(String albumAudioId) async {
    final q = {
      'album_audio_id': albumAudioId,
      'fields': 'mkv,tags,h264,h265,authors',
    };
    final cacheKey = MemoryCache.keyOf('/kmr/audio/mv', q);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/kmr/audio/mv', query: q);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);

    final groups = data['data'] as List? ?? [];
    final result = <MvInfo>[];
    for (final group in groups) {
      if (group is List) {
        for (final item in group) {
          result.add(MvInfo.fromJson(item as Map<String, dynamic>));
        }
      } else if (group is Map) {
        result.add(MvInfo.fromJson(group as Map<String, dynamic>));
      }
    }
    return result;
  }

  /// 视频详情
  Future<MvDetail> fetchDetail(String videoId) async {
    final cacheKey = MemoryCache.keyOf('/video/detail', {'id': videoId});
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/video/detail', query: {'id': videoId});
    if (cached == null) MemoryCache.instance.set(cacheKey, data);
    return MvDetail.fromJson(data);
  }

  /// 解析播放地址（HTTP → 代理 HTTPS）
  Future<String> resolvePlayUrl(String videoHash) async {
    final data = await _api.get('/video/url', query: {'hash': videoHash});
    final d = data['data'] as Map<String, dynamic>?;
    if (d == null) throw ApiException(-1, 'MV 解析失败');
    final entry = d[videoHash.toLowerCase()] ??
        d[videoHash.toUpperCase()] ??
        (d.isEmpty ? null : d.values.first);
    if (entry is! Map<String, dynamic>) throw ApiException(-1, 'MV 解析失败');
    final backup = entry['backupdownurl'];
    final url = '${entry['downurl'] ??
        (backup is List && backup.isNotEmpty ? backup.first : '')}';
    if (url.isEmpty) throw ApiException(-1, 'MV 暂无播放地址');
    return AppConfig.proxyMvUrl(url);
  }
}

class MvInfo {
  MvInfo({
    required this.videoId,
    required this.name,
    required this.artist,
    required this.thumb,
    required this.duration,
    this.sdHash,
    this.hdHash,
    this.qhdHash,
    this.sqHash,
  });
  final String videoId;
  final String name;
  final String artist;
  final String thumb;
  final int duration;
  final String? sdHash;
  final String? hdHash;
  final String? qhdHash;
  final String? sqHash;

  String? get bestHash => [sqHash, qhdHash, hdHash, sdHash]
      .whereType<String>()
      .where((hash) => hash.isNotEmpty)
      .firstOrNull;

  factory MvInfo.fromJson(Map<String, dynamic> json) {
    final mkv = json['mkv'] as Map<String, dynamic>? ?? {};
    final authors = json['authors'] as List? ?? [];
    var thumb = '${json['thumb'] ?? json['imgurl'] ?? ''}';
    thumb = thumb.replaceAll('{size}', '480');
    return MvInfo(
      videoId: '${json['mv_hash'] ?? json['id'] ?? json['video_id'] ?? ''}',
      name: '${json['mv_name'] ?? json['songname'] ?? json['name'] ?? json['filename'] ?? ''}',
      artist: authors.isNotEmpty
          ? authors
              .whereType<Map>()
              .map((author) => '${author['author_name'] ?? ''}')
              .where((name) => name.isNotEmpty)
              .join('、')
          : '${json['singername'] ?? json['singer'] ?? json['user_name'] ?? ''}',
      thumb: thumb,
      duration: (json['duration'] ?? mkv['timelength'] ?? 0) is int
          ? (json['duration'] ?? mkv['timelength'] ?? 0)
          : int.tryParse('${json['duration'] ?? mkv['timelength']}') ?? 0,
      sdHash: mkv['sd_hash'] as String?,
      hdHash: mkv['hd_hash'] as String?,
      qhdHash: mkv['qhd_hash'] as String?,
      sqHash: mkv['sq_hash'] as String?,
    );
  }
}

class MvDetail {
  MvDetail({
    required this.videoId,
    required this.name,
    required this.artist,
    required this.cover,
    required this.duration,
    required this.hashes,
  });
  final String videoId;
  final String name;
  final String artist;
  final String cover;
  final int duration;
  final Map<String, String> hashes; // quality -> hash

  factory MvDetail.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    var cover = '${data['imgurl'] ?? data['thumb'] ?? ''}';
    cover = cover.replaceAll('{size}', '480');
    final hashes = <String, String>{};
    final mkv = data['mkv'] as Map<String, dynamic>? ?? data;
    for (final q in ['sd', 'hd', 'qhd', 'sq', 'fhd']) {
      final h = mkv['${q}_hash'] as String?;
      if (h != null && h.isNotEmpty) hashes[q] = h;
    }
    return MvDetail(
      videoId: '${data['id'] ?? data['video_id'] ?? ''}',
      name: '${data['songname'] ?? data['name'] ?? ''}',
      artist: '${data['singername'] ?? data['author_name'] ?? ''}',
      cover: cover,
      duration: (data['duration'] ?? data['timelength'] ?? 0) is int
          ? (data['duration'] ?? data['timelength'] ?? 0)
          : int.tryParse('${data['duration'] ?? data['timelength']}') ?? 0,
      hashes: hashes,
    );
  }
}
