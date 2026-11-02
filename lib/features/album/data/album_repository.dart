import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart' show kugouApiClientProvider;
import '../../home/data/models.dart' show kugouImageUrl;

/// 专辑信息（/album/detail 实测字段，data 为**数组**取首项）。
class AlbumInfo {
  const AlbumInfo({
    required this.id,
    required this.name,
    this.artist = '',
    this.cover = '',
    this.publishDate = '',
    this.intro = '',
    this.heat = 0,
    this.language = '',
  });

  final String id;
  final String name;
  final String artist;
  final String cover;
  final String publishDate;
  final String intro;
  final int heat;
  final String language;

  factory AlbumInfo.fromJson(Map<String, dynamic> j) {
    final raw = j['data'];
    final Map d = raw is List && raw.isNotEmpty && raw.first is Map
        ? raw.first as Map
        : (raw is Map ? raw : j);
    String s(Object? v) => v == null ? '' : '$v';
    int i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
    return AlbumInfo(
      id: s(d['album_id'] ?? d['id']),
      name: s(d['album_name'] ?? d['name']),
      artist: s(d['author_name'] ?? d['singername']),
      cover: kugouImageUrl(s(d['sizable_cover'] ?? d['cover']), size: 480),
      publishDate: s(d['publish_date']),
      intro: s(d['intro']),
      heat: i(d['heat']),
      language: s(d['language']),
    );
  }
}

/// 专辑单曲。
///
/// 注意：`/album/songs` 是**嵌套结构**（实测）：
///   base{hash? no—hash 在 audio_info} / audio_info{hash, duration(ms)}
///   album_info{album_name, cover} / authors[]{author_name} / mvdata[]{hash,id}
/// 与 `/artist/audios` 的扁平结构完全不同，不能共用解析。
class AlbumSong {
  const AlbumSong({
    required this.hash,
    required this.name,
    this.artist = '',
    this.albumId = '',
    this.albumAudioId = '',
    this.cover = '',
    this.duration = Duration.zero,
    this.mvHash = '',
  });

  final String hash;
  final String name;
  final String artist;
  final String albumId;
  final String albumAudioId;
  final String cover;
  final Duration duration;
  final String mvHash;

  factory AlbumSong.fromJson(Map<String, dynamic> e) {
    String s(Object? v) => v == null ? '' : '$v';
    int i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

    final base = e['base'] is Map ? e['base'] as Map : const {};
    final audio = e['audio_info'] is Map ? e['audio_info'] as Map : const {};
    final album = e['album_info'] is Map ? e['album_info'] as Map : const {};
    final authors = e['authors'];
    final mvdata = e['mvdata'];

    var artist = s(base['author_name']);
    if (artist.isEmpty && authors is List && authors.isNotEmpty) {
      final a = authors.first;
      if (a is Map) artist = s(a['author_name']);
    }

    var mvHash = '';
    if (mvdata is List && mvdata.isNotEmpty) {
      final m = mvdata.first;
      if (m is Map) mvHash = s(m['hash']);
    }

    final tp = e['trans_param'];
    final unionCover = tp is Map ? s(tp['union_cover']) : '';

    return AlbumSong(
      hash: s(audio['hash']),
      name: s(base['audio_name'] ?? base['filename']),
      artist: artist,
      albumId: s(base['album_id']),
      albumAudioId: s(base['album_audio_id']),
      cover: kugouImageUrl(
          unionCover.isNotEmpty ? unionCover : s(album['cover']),
          size: 240),
      // duration 单位毫秒
      duration: Duration(milliseconds: i(audio['duration'])),
      mvHash: mvHash,
    );
  }
}

class AlbumSongsPage {
  const AlbumSongsPage({required this.songs, required this.total});
  final List<AlbumSong> songs;
  final int total;
}

class AlbumRepository {
  AlbumRepository(this._api);

  final dynamic _api;

  Future<AlbumInfo> fetchDetail(String id) async {
    final res =
        await _api.get('/album/detail', query: {'id': id}) as Map<String, dynamic>;
    return AlbumInfo.fromJson(res);
  }

  Future<AlbumSongsPage> fetchSongs(String id, {int page = 1}) async {
    final res = await _api.get('/album/songs', query: {
      'id': id,
      'page': page,
      'pagesize': 50,
    }) as Map<String, dynamic>;
    final data = res['data'];
    final Map d = data is Map ? data : const {};
    final list = d['songs'] is List ? d['songs'] as List : const [];
    final songs = list
        .whereType<Map>()
        .map((e) => AlbumSong.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.hash.isNotEmpty)
        .toList();
    final total = d['total'] is int
        ? d['total'] as int
        : int.tryParse('${d['total'] ?? ''}') ?? songs.length;
    return AlbumSongsPage(songs: songs, total: total);
  }
}

final albumRepositoryProvider =
    Provider<AlbumRepository>((ref) => AlbumRepository(ref.watch(kugouApiClientProvider)));
