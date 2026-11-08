import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/net/repository_reads.dart';

import '../../../core/api/kugou_api_client.dart' show KugouApiClient;
import '../../../app/di.dart' show kugouApiClientProvider;
import '../../home/data/models.dart' show kugouImageUrl;

/// 歌手信息（/artist/detail 实测字段）。
class ArtistInfo {
  const ArtistInfo({
    required this.id,
    required this.name,
    this.avatar = '',
    this.songCount = 0,
    this.albumCount = 0,
    this.mvCount = 0,
    this.fans = 0,
    this.intro = '',
    this.longIntro = const <String>[],
  });

  final String id;
  final String name;
  final String avatar;
  final int songCount;
  final int albumCount;
  final int mvCount;
  final int fans;
  final String intro;

  /// 详细简介分段（实测 `long_intro[]` = `{title, content}`）
  final List<String> longIntro;

  static int _i(Object? v) =>
      v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

  static String _s(Object? v) => v == null ? '' : '$v';

  factory ArtistInfo.fromJson(Map<String, dynamic> j) {
    final d = j['data'] is Map ? j['data'] as Map : j;
    return ArtistInfo(
      id: _s(d['author_id'] ?? d['id']),
      name: _s(d['author_name'] ?? d['name']),
      // sizable_avatar 含 {size} 占位符，交给 kugouImageUrl 替换
      avatar: _s(d['sizable_avatar'] ?? d['avatar']),
      songCount: _i(d['song_count']),
      albumCount: _i(d['album_count']),
      mvCount: _i(d['mv_count']),
      fans: _i(d['fansnums'] ?? d['fans']),
      intro: _s(d['intro']),
      // long_intro 是 [{title, content}]，拼接成分段文本
      longIntro: (d['long_intro'] is List)
          ? (d['long_intro'] as List)
              .whereType<Map>()
              .map((e) {
                final m = Map<String, dynamic>.from(e);
                final title = _s(m['title']);
                final content = _s(m['content']);
                if (title.isEmpty) return content;
                if (content.isEmpty) return title;
                return '$title\n$content';
              })
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[],
    );
  }
}

/// 歌手专辑（/artist/albums 实测字段）。
class ArtistAlbum {
  const ArtistAlbum({
    required this.id,
    required this.name,
    this.cover = '',
    this.publishDate = '',
    this.heat = 0,
  });

  final String id;
  final String name;
  final String cover;
  final String publishDate;
  final int heat;

  factory ArtistAlbum.fromJson(Map<String, dynamic> e) {
    String s(Object? v) => v == null ? '' : '$v';
    int i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
    return ArtistAlbum(
      id: s(e['album_id'] ?? e['id']),
      name: s(e['album_name'] ?? e['name']),
      cover: s(e['sizable_cover'] ?? e['cover']),
      publishDate: s(e['publish_date']),
      heat: i(e['heat']),
    );
  }
}

/// 歌手页分页结果。
class ArtistSongsPage {
  const ArtistSongsPage({required this.songs, required this.total});

  final List<ArtistSong> songs;
  final int total;
}

/// 歌手单曲。
///
/// 注意：`/artist/audios` 返回的是**扁平结构**（audio_name / timelength 毫秒），
/// 与 `/album/songs` 的嵌套结构不同，两者不能共用解析（实测确认）。
class ArtistSong {
  const ArtistSong({
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

  /// 有 MV 时非空（`video_hash`），用于显示 MV 入口。
  final String mvHash;

  factory ArtistSong.fromJson(Map<String, dynamic> e) {
    String s(Object? v) => v == null ? '' : '$v';
    int i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
    final tp = e['trans_param'];
    final cover = tp is Map ? s(tp['union_cover']) : '';
    return ArtistSong(
      hash: s(e['hash']),
      name: s(e['audio_name'] ?? e['songname'] ?? e['filename']),
      artist: s(e['author_name'] ?? e['singername']),
      albumId: s(e['album_id']),
      albumAudioId: s(e['album_audio_id'] ?? e['mixsongid']),
      albumName: s(e['album_name']),
      cover: cover,
      // timelength 单位是毫秒（实测 285000 = 285 秒）
      duration: Duration(milliseconds: i(e['timelength'])),
      mvHash: s(e['video_hash']),
    );
  }
}

class ArtistRepository {
  // V37-06（C1 ALB-R2，第 13/2 条）：同 album_repository——dynamic 改具体类型。
  ArtistRepository(this._api);

  final KugouApiClient _api;
  final RepositoryReads _reads = RepositoryReads(_api, 'artist');

  Future<ArtistInfo> fetchDetail(String id) async {
    // V37-06（C1 ART 同病，第 13 条）：裸强转改 is Map 分支校验——
    // 上游异常形态（网关错误页/字符串）时给空数据而非 TypeError 上抛。
    final res = await _reads.get('/artist/detail', query: {'id': id}, json: true);
    return ArtistInfo.fromJson(res is Map<String, dynamic> ? res : const {});
  }

  Future<ArtistSongsPage> fetchSongs(String id,
      {int page = 1, String sort = 'new'}) async {
    // V37-06（C1 ART 同病，第 13 条）：入口强转改 is 校验。
    final raw = await _reads.get('/artist/audios', query: {
      'id': id,
      'page': page,
      // 实测 pagesize 上限 100，超限 error_code=20010
      'pagesize': 30,
      'sort': sort,
    });
    final res = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    final list = res['data'] is List ? res['data'] as List : const [];
    final songs = list
        .whereType<Map>()
        .map((e) => ArtistSong.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.hash.isNotEmpty)
        .toList();
    final total = res['total'] is int
        ? res['total'] as int
        : int.tryParse('${res['total'] ?? ''}') ?? 0;
    return ArtistSongsPage(songs: songs, total: total);
  }

  Future<List<ArtistAlbum>> fetchAlbums(String id, {int page = 1}) async {
    // V37-06（C1 ART 同病，第 13 条）：入口强转改 is 校验。
    final raw = await _reads.get('/artist/albums', query: {
      'id': id,
      'page': page,
      'pagesize': 30,
    });
    final res = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    final list = res['data'] is List ? res['data'] as List : const [];
    return list
        .whereType<Map>()
        .map((e) => ArtistAlbum.fromJson(Map<String, dynamic>.from(e)))
        .where((a) => a.id.isNotEmpty)
        .toList();
  }
}

final artistRepositoryProvider = Provider<ArtistRepository>(
    (ref) => ArtistRepository(ref.watch(kugouApiClientProvider)));

/// 封面统一补全 {size} 并升级 https（复用首页的 kugouImageUrl）。
String artistImage(String raw, {int size = 480}) =>
    kugouImageUrl(raw, size: size);
