import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../home/data/models.dart' show kugouImageUrl;

/// 排行榜歌曲列表项
///
/// 【实测结构】`/openapi/kmr/v2/rank/audio` → `data.songlist[]`：
/// - `songname` 歌名
/// - `author_name` / `authors[].author_name` 歌手
/// - `audio_id` / `album_audio_id` 混音id（**album_audio_id 才是 MixSongID**）
/// - `audio_info.hash_128 / hash_320 / hash_flac` 各音质 hash
/// - `audio_info.duration_128` 等时长（毫秒）
/// - `album_info.sizable_cover` / `album_info.album_name` 专辑
/// - `trans_param.union_cover` 封面
/// - `video_info.video_hash` MV hash（无 MV 时为空）
class RankSong {
  const RankSong({
    required this.hash,
    required this.name,
    this.artist = '',
    this.albumId = '',
    this.albumAudioId = '',
    this.albumName = '',
    this.cover = '',
    this.duration = Duration.zero,
    this.mvHash = '',
  });

  final String hash;
  final String name;
  final String artist;
  final String albumId;
  final String albumAudioId;
  final String albumName;
  final String cover;
  final Duration duration;
  final String mvHash;

  factory RankSong.fromJson(Map<String, dynamic> e) {
    String s(Object? v) => v == null ? '' : '$v';
    final ai = e['audio_info'];
    final audioInfo = ai is Map ? Map<String, dynamic>.from(ai) : <String, dynamic>{};
    final alb = e['album_info'];
    final albumInfo = alb is Map ? Map<String, dynamic>.from(alb) : <String, dynamic>{};
    final tp = e['trans_param'];
    final transParam = tp is Map ? Map<String, dynamic>.from(tp) : <String, dynamic>{};
    final vi = e['video_info'];
    final videoInfo = vi is Map ? Map<String, dynamic>.from(vi) : <String, dynamic>{};

    final authors = e['authors'];
    var artist = s(e['author_name']);
    if (artist.isEmpty && authors is List && authors.isNotEmpty) {
      final first = authors.first;
      if (first is Map) artist = s(first['author_name']);
    }

    final cover = kugouImageUrl(
      '${transParam['union_cover'] ?? albumInfo['sizable_cover'] ?? ''}',
      size: 400,
    );

    // 时长：优先 128（各音质时长一致），否则任意可用值
    var ms = 0;
    for (final k in ['duration_128', 'duration_320', 'duration_flac']) {
      final v = audioInfo[k];
      if (v is int && v > 0) {
        ms = v;
        break;
      }
      if (v is String && int.tryParse(v) != null && int.parse(v) > 0) {
        ms = int.parse(v);
        break;
      }
    }

    return RankSong(
      hash: s(audioInfo['hash_128'] ?? audioInfo['hash_320'] ?? audioInfo['hash_flac']),
      name: s(e['songname']),
      artist: artist,
      albumId: s(albumInfo['album_id'] ?? e['album_id']),
      albumAudioId: s(e['album_audio_id']),
      albumName: s(albumInfo['album_name']),
      cover: cover,
      duration: Duration(milliseconds: ms),
      mvHash: s(videoInfo['video_hash']),
    );
  }
}

class RankSongsPage {
  const RankSongsPage({required this.songs, required this.total});
  final List<RankSong> songs;
  final int total;
}

class RankRepository {
  RankRepository(this._api);
  final KugouApiClient _api;

  /// 榜单歌曲（分页）
  Future<RankSongsPage> fetchRankSongs(
    int rankId, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final res = await _api.post('/rank/audio', const <String, dynamic>{}, query: {
      'rankid': rankId,
      'page': page,
      'pagesize': pageSize,
    }) as Map<String, dynamic>;
    final data = res['data'];
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final list = map['songlist'] is List ? map['songlist'] as List : const [];
    final songs = list
        .whereType<Map>()
        .map((e) => RankSong.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.hash.isNotEmpty)
        .toList();
    final total = map['total'] is int
        ? map['total'] as int
        : int.tryParse('${map['total'] ?? ''}') ?? songs.length;
    return RankSongsPage(songs: songs, total: total);
  }
}

final rankRepositoryProvider = Provider<RankRepository>(
    (ref) => RankRepository(ref.watch(kugouApiClientProvider)));
