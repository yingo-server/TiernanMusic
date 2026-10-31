/// 播放与权益相关接口（直连版）
///
/// 移植自：
///   module/song_url.js      → KgPlayApi.songUrl
///   module/privilege_lite.js→ KgPlayApi.privilege
library;

import 'kg_client.dart';
import 'kg_crypto.dart';

class KgPlayApi {
  KgPlayApi(this.client);
  final KgClient client;

  /// 获取播放地址（GET /v5/url，x-router: trackercdn）
  ///
  /// 返回真实 URL 列表（http://fsandroid.kugou.com/...），
  /// [quality] 支持 128/320/flac/high/super 及魔法音质
  Future<PlayUrlResult> songUrl({
    required String hash,
    int albumId = 0,
    int albumAudioId = 0,
    String quality = '128',
    bool freePart = false,
  }) async {
    const magic = [
      'piano', 'acappella', 'subwoofer', 'ancient', 'dj', 'surnay',
    ];
    final q = magic.contains(quality) ? 'magic_$quality' : quality;

    final params = <String, dynamic>{
      'album_id': albumId,
      'area_code': 1,
      'hash': hash.toLowerCase(),
      'ssa_flag': 'is_fromtrack',
      'version': 11430,
      'page_id': client.lite ? 967177915 : 151369488,
      'quality': q,
      'album_audio_id': albumAudioId,
      'behavior': 'play',
      'pid': client.lite ? 411 : 2,
      'cmd': 26,
      'pidversion': 3001,
      'IsFreePart': freePart ? 1 : 0,
      'ppage_id': client.lite
          ? '356753938,823673182,967485191'
          : '463467626,350369493,788954147',
      'cdnBackup': 1,
      'module': '',
      'clientver': 11430,
    };

    // encryptKey：注入 key=signKey(hash, mid, userid, appid)
    params['key'] = KgSignature.keyOf(
      hash: hash.toLowerCase(),
      mid: client.device.mid,
      userid: client.userid,
      lite: client.lite,
    );

    final res = await client.requestWithVerify(
      '/v5/url',
      method: 'GET',
      params: params,
      encryptType: 'android',
      headers: {'x-router': 'trackercdn.kugou.com'},
    );

    return PlayUrlResult.fromResponse(res);
  }

  /// 获取音乐权益与音质（POST /v2/get_res_privilege/lite）
  Future<List<PrivilegeItem>> privilege({
    required List<String> hashes,
    List<String> albumIds = const [],
  }) async {
    final resource = <Map<String, dynamic>>[];
    for (var i = 0; i < hashes.length; i++) {
      resource.add({
        'type': 'audio',
        'page_id': 1,
        'hash': hashes[i].toLowerCase(),
        'album_id': i < albumIds.length ? albumIds[i] : '0',
      });
    }

    final res = await client.requestWithVerify(
      '/v2/get_res_privilege/lite',
      method: 'POST',
      data: {
        'appid': client.lite ? KgConfig.liteAppid : KgConfig.appid,
        'area_code': 1,
        'behavior': 'play',
        'clientver':
            client.lite ? KgConfig.liteClientver : KgConfig.clientver,
        'need_hash_offset': 1,
        'relate': 1,
        'support_verify': 1,
        'resource': resource,
        'qualities': const [
          '128', '320', 'flac', 'high',
          'viper_atmos', 'viper_tape', 'viper_clear', 'super', 'multitrack',
        ],
      },
      encryptType: 'android',
    );

    final data = res.body['data'];
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((e) => PrivilegeItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// 播放地址结果
class PlayUrlResult {
  const PlayUrlResult({
    required this.urls,
    required this.backupUrls,
    required this.quality,
    required this.bitrate,
    required this.isPreview,
    required this.errorCode,
    required this.message,
    required this.ssaCode,
  });

  final List<String> urls;
  final List<String> backupUrls;
  final String quality;
  final int bitrate;
  final bool isPreview;
  final int errorCode;
  final String message;
  final String? ssaCode;

  String? get bestUrl => urls.isNotEmpty
      ? urls.first
      : (backupUrls.isNotEmpty ? backupUrls.first : null);

  bool get hasUrl => bestUrl != null && bestUrl!.isNotEmpty;

  factory PlayUrlResult.fromResponse(KgResponse res) {
    final b = res.body;
    List<String> toList(dynamic v) {
      if (v is List) return v.map((e) => '$e').where((s) => s.isNotEmpty).toList();
      if (v is String && v.isNotEmpty) return [v];
      return const [];
    }

    final urls = toList(b['url']);
    final backups = toList(b['backupUrl']);
    final bitrate = b['bitRate'] is int
        ? b['bitRate'] as int
        : int.tryParse('${b['bitRate'] ?? ''}') ?? 0;
    final endMs = (b['hash_offset'] is Map)
        ? int.tryParse('${(b['hash_offset'] as Map)['end_ms'] ?? ''}') ?? 0
        : 0;

    return PlayUrlResult(
      urls: urls,
      backupUrls: backups,
      quality: '${b['quality'] ?? ''}',
      bitrate: bitrate,
      // 60s 试听：end_ms 约 60000 且路径含 p_0_
      isPreview: endMs > 0 &&
          endMs <= 65000 &&
          (urls.isNotEmpty ? urls.first.contains('/p_0_') : false),
      errorCode: res.errorCode,
      message: '${b['error'] ?? b['error_msg'] ?? b['errmsg'] ?? ''}',
      ssaCode: res.ssaCode,
    );
  }
}

/// 权益条目
class PrivilegeItem {
  const PrivilegeItem({
    required this.hash,
    required this.privilege,
    required this.payType,
    required this.status,
    required this.failProcess,
    required this.quality,
    required this.pkgPrice,
    this.durationMs,
    this.cover,
  });

  final String hash;
  final int privilege;
  final int payType;
  final int status;
  final List<int> failProcess;
  final String quality;
  final int pkgPrice;
  final int? durationMs;
  final String? cover;

  /// 是否免费可播（privilege=0）
  bool get isFree => privilege == 0;

  /// 是否需要付费/会员
  bool get needsPurchase => payType != 0 || privilege != 0;

  factory PrivilegeItem.fromJson(Map<String, dynamic> j) {
    final info = j['info'] is Map ? Map<String, dynamic>.from(j['info'] as Map) : const <String, dynamic>{};
    final fp = j['fail_process'];
    return PrivilegeItem(
      hash: '${j['hash'] ?? ''}',
      privilege: _int(j['privilege']),
      payType: _int(j['pay_type']),
      status: _int(j['status']),
      failProcess: fp is List
          ? fp.map(_int).toList()
          : (_int(fp) > 0 ? [_int(fp)] : const <int>[]),
      quality: '${j['quality'] ?? ''}',
      pkgPrice: _int(j['pkg_price']),
      durationMs: info['duration'] == null ? null : _int(info['duration']),
      cover: info['image']?.toString(),
    );
  }

  static int _int(dynamic v) =>
      v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
}
