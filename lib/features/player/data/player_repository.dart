import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/audio/preferred_quality.dart';
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
          // ⚠️ 必须回填 localPath：否则离线歌曲播过一次后，
          // 队列里的对象被详情覆盖，切回来就退化成在线播放（终审 P1-5）。
          localPath: song.localPath,
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
          // ⚠️ 必须回填 localPath：否则离线歌曲播过一次后，
          // 队列里的对象被详情覆盖，切回来就退化成在线播放（终审 P1-5）。
          localPath: song.localPath,
        );
      }
    } catch (e) {
      // V3-05（第5批复核②，P1）：详情补全失败必须可观测且区分错误类型
      //（第 6/7/9/10 条）。TypeError/FormatException 属上游契约变化，
      // 不得与网络失败同等静默吞掉——否则用户永远拿到「未补全的 song」
      // （无时长/无封面）且线上无日志可查。
      if (e is TypeError || e is NoSuchMethodError || e is FormatException) {
        debugPrint('[player] fetchDetail 解析失败（上游契约变化？）: $e');
      } else {
        debugPrint('[player] fetchDetail 网络失败: $e');
      }
      // 详情查询失败不阻塞播放
    }
    return song;
  }

  /// 读取用户设置的默认音质（事实源：core/audio/preferred_quality.dart）
  AudioQuality _preferredFromSettings() => preferredQuality();

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
    // PLY-02（审查③）：20028 的 ssaCode 必须传给上层，否则验证页拿不到 eventid
    String lastSsaCode = '';
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
          url: result.bestUrl!,
          quality: _qualityFromBitrate(result, q),
          isPreview: result.isPreview,
        );
      }
      lastErrorCode = result.errorCode;
      lastMessage = result.message.isNotEmpty ? result.message : lastMessage;
      if (result.ssaCode != null && result.ssaCode!.isNotEmpty) {
        lastSsaCode = result.ssaCode!;
      }
      // 20028（需验证）直接退出
      if (result.errorCode == 20028) break;
      // 权益不足（需购买/无版权）：先尝试官方 60 秒试听通道（IsFreePart=1），
      // 拿到就按试听播放；拿不到再退出（不再为同一首歌打 5 次无效请求）。
      if (result.failProcess.isNotEmpty) {
        final preview = await play.songUrl(
          hash: song.hash,
          albumId: int.tryParse(song.albumId) ?? 0,
          albumAudioId: int.tryParse(song.albumAudioId) ?? 0,
          quality: q.value,
          freePart: true,
        );
        if (preview.hasUrl) {
          return PlayableResult(
            url: preview.bestUrl!,
            quality: _qualityFromBitrate(preview, q),
            isPreview: true,
          );
        }
        // PLY-08（审查③）：该档 fail_process 只代表**本档**被拒（flac 需会员
        // 但 320 可能免费可播），continue 尝试更低音质而非放弃整首。
        continue;
      }
    }
    if (lastErrorCode != null && lastErrorCode != 0) {
      throw ApiException(
        lastErrorCode,
        lastMessage.isEmpty ? '直连获取播放地址失败' : lastMessage,
        ssaCode: lastSsaCode.isNotEmpty ? lastSsaCode : null,
      );
    }
    return null;
  }

  static AudioQuality _qualityFromBitrate(PlayUrlResult r, AudioQuality requested) {
    // 服务端给了明确 extName/quality 时优先采信
    final q = AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality);
    if (q != AudioQuality.q128) return q;
    // 否则按码率推断；未知/0 一律按最低，避免把试听错标为高音质
    // PLY-07（审查③）：服务端 bitRate 是 **bps**（320000/128000），
    // 此前按 kbps 阈值（2000/900/300）推断，128/320 恒被判成 flac。
    if (r.bitrate != null && r.bitrate > 0) {
      // V3-06 修正（复核②终审）：阈值对齐 AudioQuality 序位
      //（128 < 320 < flac < Hi-Res < super），192000 边界归 q320 侧：
      // <192000→q128；<500000→q320；≥500000→flac。
      final b = r.bitrate;
      if (b >= 500000) return AudioQuality.flac;
      if (b >= 192000) return AudioQuality.q320;
      return AudioQuality.q128;
    }
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
        // PLY-04（审查③）：单档失败应**继续尝试更低音质**（fail 常按 quality
        // 粒度返回：flac 需会员但 320 免费可播），throw 会让降级循环与
        // 下方 free_part 试听兜底全部变成死代码。
        lastError = ApiException(
          errorCode ?? -1,
          _songFailureMessage(data, q),
        );
        continue;
      }

      // 优先 url[0]，仅当主地址缺失时才使用 backupUrl[0]。
      final url = _firstUrl(data['url']) ?? _firstUrl(data['backupUrl']);
      if (url != null) {
        return PlayableResult(
          url: url,
          quality: _actualQuality(data, q),
          isPreview: _int(data['priv_status']) == 0 ||
              data['hash_offset'] is Map,
        );
      }
      lastError = ApiException(-1, '音质 ${q.value} 无可用播放地址');
    }
    // 全部音质都拿不到：再试一次官方 60 秒试听（VIP/付费曲的兜底）
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
        final data = res['data'] is Map ? res['data'] as Map : res;
        final url = _firstUrl(data['url']) ?? _firstUrl(data['backupUrl']);
        if (url != null) {
          return PlayableResult(
            url: url,
            quality: _actualQuality(data, q),
            isPreview: true,
          );
        }
      } catch (_) {
        // 继续尝试下一档
      }
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

  /// 播放地址**不再**走前缀代理。
  ///
  /// 原因（真机实测）：
  /// - Android 的 network_security_config 已对 kugou.com（含子域）放行 cleartext；
  /// - 酷狗 CDN 支持 Range 请求，直连才能边下边播、seek、断点续传；
  /// - 走前缀代理时不转发 Range，表现为「只能播开头 / 卡住 / 播放态滞留」，
  ///   且多一跳中转明显更慢。
  /// 播放地址直连（CDN 支持 Range，直连才能边下边播/seek/断点续传）。
  /// 历史上的前缀代理方案已废弃：代理不转发 Range →「只能播开头」，
  /// 且多一跳更慢（V3-07：删除恒等包装 _proxyHttp，第 32 条死代码）。

  static AudioQuality _actualQuality(Map data, AudioQuality requested) {
    // V3-06（第5批复核②，P2）：与 _qualityFromBitrate 共用同一套阈值
    //（第 5 条：同一判断必须单一来源）。
    // V3-06 修正（复核②终审）：对齐 AudioQuality 序位，192000 归 q320 侧，
    // 消除「128k 显示高品 320、320k 显示 Hi-Res」的错档。
    final bitrate = _int(data['bitRate']);
    if (bitrate != null && bitrate > 0) {
      if (bitrate >= 500000) return AudioQuality.flac;
      if (bitrate >= 192000) return AudioQuality.q320;
      return AudioQuality.q128;
    }
    return AudioQuality.fromString('${data['extName'] ?? requested.value}');
  }
}
