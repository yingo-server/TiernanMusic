import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/direct/kg_play_api.dart';
import '../../../core/direct/kg_providers.dart';
import '../../../core/storage/secure_storage.dart';
import 'models.dart';

/// 一次成功解析出的播放结果。
class PlayableResult {
  const PlayableResult({
    required this.url,
    required this.quality,
    this.isPreview = false,
  });
  final String url;
  final AudioQuality quality;
  final bool isPreview;
}

/// 播放器仓库：直连酷狗网关（不经 Node 中转），避免中转层的 20028 风控。
///
/// 内容接口仍走 kapi；只有受风控影响的播放/权益链路直连。
class PlayerRepository {
  PlayerRepository(this._api, [this._ref]);

  final KugouApiClient _api;
  final Ref? _ref;

  /// 动态获取直连播放接口（异步 provider，可能尚未就绪）
  KgPlayApi? get _directPlay => _ref?.read(kgPlayApiProvider);

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
      // 部署版的 data 是各音质权益条目列表，并非单首歌曲对象。
      if (data is List) {
        final entries = data.whereType<Map>();
        if (entries.isEmpty) return song;
        final matching = entries.where((entry) =>
            '${entry['hash']}'.toUpperCase() == song.hash.toUpperCase());
        final detail = matching.isNotEmpty ? matching.first : entries.first;
        final merged = Song.fromJson(Map<String, dynamic>.from(detail));
        return merged.copyWith(
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
          quality: song.quality,
        );
      }
      if (data is Map<String, dynamic>) {
        final merged = Song.fromJson(data);
        return merged.copyWith(
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
          quality: song.quality,
        );
      }
    } catch (_) {
      // 详情查询失败不阻塞播放
    }
    return song;
  }

  /// 读取用户设置的默认音质（Hive settings['defaultQuality']，缺省 320）
  AudioQuality _preferredFromSettings() {
    try {
      if (Hive.isBoxOpen('settings')) {
        final v = Hive.box<dynamic>('settings').get('defaultQuality');
        if (v is String) return AudioQuality.fromString(v);
      }
    } catch (_) {}
    return AudioQuality.q320;
  }

  /// 获取可播放 URL：直连优先，失败回退 kapi。
  Future<PlayableResult> resolveUrl(Song song,
      {AudioQuality? preferred}) async {
    preferred ??= _preferredFromSettings();
    if (_directPlay != null) {
      try {
        final direct =
            await _resolveViaDirect(song, preferred: preferred);
        if (direct != null) return direct;
      } on ApiException catch (e) {
        // 20028/权益错误直接上抛，不再回退（回退也会被同样拦截）
        if (e.errorCode == 20028) rethrow;
        // 其它错误回退 kapi 再试
      }
    }
    return _resolveViaKapi(song, preferred: preferred);
  }

  /// 直连解析：按音质降级，命中权益不足才抛错。
  Future<PlayableResult?> _resolveViaDirect(Song song,
      {AudioQuality? preferred}) async {
    final play = _directPlay!;
    final start = preferred ?? song.quality;
    final order = AudioQuality.fallbackOrder;
    var startIndex = order.indexOf(start);
    if (startIndex < 0) startIndex = order.length - 1;

    int? lastErrorCode;
    String lastMessage = '';
    for (var i = startIndex; i < order.length; i++) {
      final q = order[i];
      final result = await play.songUrl(
        hash: song.hash,
        albumId: int.tryParse(song.albumId) ?? 0,
        albumAudioId: int.tryParse(song.albumAudioId) ?? 0,
        quality: q.value,
      );
      if (result.hasUrl) {
        return PlayableResult(
          // 直连拿到的是 http://fsandroid... ，走代理转 https
          url: _proxyHttp(result.bestUrl!),
          quality: _qualityFromBitrate(result, q),
          isPreview: result.isPreview,
        );
      }
      lastErrorCode = result.errorCode;
      lastMessage = result.message.isNotEmpty ? result.message : lastMessage;
      // 20028（需验证）/ 权益不足（fail_process 非空，需购买/无版权）：
      // 不再继续降级（继续也没权限），直接退出后由调用方决定回退或上抛
      if (result.errorCode == 20028) break;
      if (result.failProcess.isNotEmpty) break;
    }
    if (lastErrorCode != null && lastErrorCode != 0) {
      throw ApiException(lastErrorCode, lastMessage.isEmpty ? '直连获取播放地址失败' : lastMessage);
    }
    return null;
  }

  static AudioQuality _qualityFromBitrate(PlayUrlResult r, AudioQuality requested) {
    // 服务端给了明确 extName/quality 时优先采信
    final q = AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality);
    if (q != AudioQuality.q128) return q;
    // 否则按码率推断；未知/0 一律按最低，避免把试听错标为高音质
    if (r.bitrate >= 2000) return AudioQuality.flac;
    if (r.bitrate >= 900) return AudioQuality.high;
    if (r.bitrate >= 300) return AudioQuality.q320;
    return AudioQuality.q128;
  }

  /// 获取可播放 URL。从期望音质起逐级降级（super→high→flac→320→128）。
  ///
  /// 这里是 kapi 回退路径。
  Future<PlayableResult> _resolveViaKapi(Song song,
      {AudioQuality? preferred}) async {
    await ensureDfid();
    final start = preferred ?? song.quality;
    final order = AudioQuality.fallbackOrder;
    var startIndex = order.indexOf(start);
    if (startIndex < 0) startIndex = order.length - 1;

    ApiException? lastError;
    for (var i = startIndex; i < order.length; i++) {
      final q = order[i];
      final res = await _api.get('/song/url', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
        'quality': q.value,
        // 不带 free_part：需要试听时由调用方显式传入（默认拿全曲）
      });
      final data = res['data'] is Map ? res['data'] as Map : res;
      final errorCode = _int(data['errcode'] ?? data['error_code']);
      final status = _int(data['status']);
      if (errorCode != 0 || (status != null && status != 1)) {
        throw ApiException(
          errorCode ?? -1,
          _songFailureMessage(data, q),
        );
      }

      // 优先 url[0]，仅当主地址缺失时才使用 backupUrl[0]。
      final url = _firstUrl(data['url']) ?? _firstUrl(data['backupUrl']);
      if (url != null) {
        return PlayableResult(
          url: _proxyHttp(url),
          quality: _actualQuality(data, q),
          isPreview: _int(data['priv_status']) == 0 ||
              data['hash_offset'] is Map,
        );
      }
      lastError = ApiException(-1, '音质 ${q.value} 无可用播放地址');
    }
    throw lastError ?? ApiException(-1, '没有可尝试的播放音质');
  }

  /// 将部署版 /privilege/lite 的真实权益字段转换为可播放性。
  /// privilege 的 8 位表示无版权；接口顶层 status=1 且非无版权时可播放。
  static bool canPlay(Map<dynamic, dynamic> privilege) {
    final status = _int(privilege['status']);
    if (status != null && status != 1) return false;
    final value = _int(privilege['privilege']) ?? 0;
    return value & 8 == 0;
  }

  static bool requiresVip(Map<dynamic, dynamic> privilege) {
    final payType = _int(privilege['pay_type']) ?? 0;
    return payType == 1 || payType == 3;
  }

  static String _songFailureMessage(Map data, AudioQuality quality) {
    if (_int(data['errcode'] ?? data['error_code']) == 20028) {
      return '本次请求需要验证';
    }
    if (data['privilege'] != null && !canPlay(data)) {
      return (_int(data['privilege']) ?? 0) & 8 != 0 ? '歌曲暂无版权' : '歌曲不可播放';
    }
    if (requiresVip(data) || data['fail_process'] != null) {
      return '音质 ${quality.value} 需要会员或单独购买';
    }
    return '${data['error'] ?? data['error_msg'] ?? data['errmsg'] ?? '音质 ${quality.value} 暂不可播放'}';
  }

  static int? _int(Object? value) =>
      value is int ? value : int.tryParse('$value');

  static String? _firstUrl(Object? value) {
    final first = value is List && value.isNotEmpty ? value.first : value;
    if (first == null) return null;
    final url = first.toString().trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return url;
  }

  static String _proxyHttp(String url) => url.startsWith('http://')
      ? 'https://proxy.344977.xyz/$url'
      : url;

  static AudioQuality _actualQuality(Map data, AudioQuality requested) {
    final bitrate = _int(data['bitRate']);
    if (bitrate != null && bitrate > 0) {
      if (bitrate <= 192000) return AudioQuality.q128;
      if (bitrate <= 500000) return AudioQuality.q320;
    }
    return AudioQuality.fromString('${data['extName'] ?? requested.value}');
  }
}
