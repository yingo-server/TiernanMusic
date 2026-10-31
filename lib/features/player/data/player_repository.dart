import '../../core/api/kugou_api_client.dart';
import '../../core/storage/secure_storage.dart';
import 'models.dart';

/// 一次成功解析出的播放结果。
class PlayableResult {
  const PlayableResult({required this.url, required this.quality});
  final String url;
  final AudioQuality quality;
}

/// 播放器仓库：封装 dfid 注册、歌曲详情查询与播放地址获取（含音质降级）。
class PlayerRepository {
  PlayerRepository(this._api);

  final KugouApiClient _api;

  bool _registering = false;

  /// 确保本地有 dfid，首次播放前自动注册设备。
  Future<String> ensureDfid() async {
    final cached = await SecureStorage.instance.readDfid();
    if (cached != null && cached.isNotEmpty) return cached;
    if (_registering) {
      // 简单防并发
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return ensureDfid();
    }
    _registering = true;
    try {
      final res = await _api.get('/register/dev');
      final data = res['data'];
      final dfid = data is Map ? '${data['dfid'] ?? ''}' : '';
      if (dfid.isEmpty) {
        throw ApiException(-1, '注册设备失败：未返回 dfid');
      }
      await SecureStorage.instance.saveDfid(dfid);
      return dfid;
    } finally {
      _registering = false;
    }
  }

  /// 查询歌曲详情（/privilege/lite），返回补全后的 Song。
  /// 失败时返回原 song。
  Future<Song> fetchDetail(Song song) async {
    try {
      final res = await _api.get('/privilege/lite', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'qualities': '128,320,flac,high',
      });
      final data = res['data'];
      if (data is Map<String, dynamic>) {
        var merged = Song.fromJson(data);
        // 保留原有非空字段
        merged = merged.copyWith(
          hash: song.hash,
          albumId: merged.albumId.isNotEmpty ? merged.albumId : song.albumId,
          albumAudioId: merged.albumAudioId.isNotEmpty
              ? merged.albumAudioId
              : song.albumAudioId,
          name: merged.name.isNotEmpty ? merged.name : song.name,
          artist: merged.artist.isNotEmpty ? merged.artist : song.artist,
          cover: merged.cover.isNotEmpty ? merged.cover : song.cover,
          duration:
              merged.duration > Duration.zero ? merged.duration : song.duration,
        );
        // 免费可得的最佳音质
        final vip = data['quality_vip'];
        if (vip is Map && vip['best_free_quality'] != null) {
          merged = merged.copyWith(
              quality: AudioQuality.fromString('${vip['best_free_quality']}'));
        }
        return merged;
      }
    } catch (_) {
      // 详情查询失败不阻塞播放
    }
    return song;
  }

  /// 获取可播放 URL。从期望音质起逐级降级（super→high→flac→320→128）。
  Future<PlayableResult> resolveUrl(Song song,
      {AudioQuality? preferred}) async {
    await ensureDfid();
    final start = preferred ?? song.quality;
    final order = AudioQuality.fallbackOrder;
    var startIndex = order.indexOf(start);
    if (startIndex < 0) startIndex = order.length - 1;

    Object? lastError;
    for (var i = startIndex; i < order.length; i++) {
      final q = order[i];
      try {
        final res = await _api.get('/song/url', query: {
          'hash': song.hash,
          'album_id': song.albumId,
          'album_audio_id': song.albumAudioId,
          'quality': q.value,
          'free_part': '1',
        });
        final data = res['data'];
        if (data is Map) {
          final urls = <dynamic>[
            if (data['url'] is List) ...(data['url'] as List) else data['url'],
            if (data['backupUrl'] is List)
              ...(data['backupUrl'] as List)
            else
              data['backupUrl'],
          ];
          for (final u in urls) {
            final url = '$u';
            if (url.isNotEmpty && url.startsWith('http') && url != 'null') {
              return PlayableResult(url: url, quality: q);
            }
          }
        }
        lastError = ApiException(-1, '音质 ${q.value} 无可用播放地址');
      } catch (e) {
        lastError = e;
      }
    }
    throw ApiException(-1, '获取播放地址失败：$lastError');
  }
}
