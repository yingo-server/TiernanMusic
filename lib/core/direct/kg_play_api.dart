/// 播放与权益相关接口（直连版）
///
/// 移植自：
///   module/song_url.js      → KgPlayApi.songUrl
///   module/privilege_lite.js→ KgPlayApi.privilege
///
/// 【重要】`/v5/url` 与 `/v2/get_res_privilege/lite` 的请求参数构造统一放在
/// [KgSharedParams] 里 —— `kg_direct_api_client.dart` 里的同名实现复用它，
/// 避免两份拷贝参数不一致（历史上就是因为两处各写一份导致匿名态行为不一致）。
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
    final params = KgSharedParams.songUrl(
      client: client,
      hash: hash,
      albumId: albumId,
      albumAudioId: albumAudioId,
      quality: quality,
      freePart: freePart,
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
    List<String> qualities = const [],
  }) async {
    final body = KgSharedParams.privilege(
      client: client,
      hashes: hashes,
      albumIds: albumIds,
      qualities: qualities,
    );

    final res = await client.requestWithVerify(
      '/v2/get_res_privilege/lite',
      method: 'POST',
      headers: {'x-router': 'media.store.kugou.com'},
      data: body,
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

/// 播放 / 权益接口的**共享**参数构造
///
/// `kg_direct_api_client.dart` 与 [KgPlayApi] 共用，保证两边行为一致。
class KgSharedParams {
  KgSharedParams._();

  /// 魔法音质（概念版）
  static const List<String> magicQualities = [
    'piano', 'acappella', 'subwoofer', 'ancient', 'dj', 'surnay',
  ];

  /// `/v5/url` 的完整查询参数
  ///
  /// 关键点（实测确认）：
  /// - `hash` 必须**小写**
  /// - `key` = `KgSignature.keyOf(hash小写, mid, userid, appid)`，
  ///   `userid` 用字符串（匿名态 `'0'`）—— 缺 key 服务端报风控错误
  /// - `signature` 必填（由 [KgClient.request] 用 android 签名自动补上）
  static Map<String, dynamic> songUrl({
    required KgClient client,
    required String hash,
    int albumId = 0,
    int albumAudioId = 0,
    String quality = '128',
    bool freePart = false,
  }) {
    final lowerHash = hash.toLowerCase();
    final q = magicQualities.contains(quality) ? 'magic_$quality' : quality;
    final lite = client.lite;

    return <String, dynamic>{
      'album_id': albumId,
      'area_code': 1,
      'hash': lowerHash,
      'ssa_flag': 'is_fromtrack',
      'version': 11430,
      'page_id': lite ? 967177915 : 151369488,
      'quality': q,
      'album_audio_id': albumAudioId,
      'behavior': 'play',
      'pid': lite ? 411 : 2,
      'cmd': 26,
      'pidversion': 3001,
      'IsFreePart': freePart ? 1 : 0,
      'ppage_id': lite
          ? '356753938,823673182,967485191'
          : '463467626,350369493,788954147',
      'cdnBackup': 1,
      'module': '',
      'clientver': 11430,
      // key：hash 必须小写；userid 匿名态为字符串 '0'
      'key': KgSignature.keyOf(
        hash: lowerHash,
        mid: client.device.mid,
        userid: client.userid.isEmpty ? '0' : client.userid,
        lite: lite,
      ),
    };
  }

  /// `/v2/get_res_privilege/lite` 的完整请求体
  ///
  /// 关键点（实测确认）：
  /// - `resource[].page_id` 必须是 **0**
  /// - `resource[].hash` 必须非空（空串 / 字符串 "null" 会让上游返回 20010）
  /// - `qualities` 必须是**数组**（`'128,320,flac,high'` 这类逗号串要拆开）
  ///
  /// [hashes] 与 [albumIds] 按下标一一对应；被过滤掉的空 hash 不会打乱
  /// 剩余条目的 album_id 对应关系。
  static Map<String, dynamic> privilege({
    required KgClient client,
    required List<String> hashes,
    List<String> albumIds = const [],
    List<String> qualities = const [],
  }) {
    final resource = <Map<String, dynamic>>[];
    for (var i = 0; i < hashes.length; i++) {
      final hash = hashes[i].trim().toLowerCase();
      // 过滤空 hash（避免把字符串 "null" 当成 hash 传给上游）
      if (hash.isEmpty || hash == 'null') continue;
      resource.add({
        'type': 'audio',
        'page_id': 0,
        'hash': hash,
        'album_id': i < albumIds.length ? albumIds[i] : '0',
      });
    }

    final useQualities = qualities.isEmpty
        ? const <String>[
            '128', '320', 'flac', 'high',
            'viper_atmos', 'viper_tape', 'viper_clear', 'super', 'multitrack',
          ]
        : qualities;

    return <String, dynamic>{
      'appid': client.lite ? KgConfig.liteAppid : KgConfig.appid,
      'area_code': 1,
      'behavior': 'play',
      'clientver': client.lite ? KgConfig.liteClientver : KgConfig.clientver,
      'need_hash_offset': 1,
      'relate': 1,
      'support_verify': 1,
      'resource': resource,
      'qualities': useQualities,
    };
  }

  /// 把逗号分隔的音质串拆成数组（`'128,320,flac,high'` → `['128','320',...]`）
  static List<String> parseQualities(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty && e != 'null')
          .toList();
    }
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty || s == 'null') return const <String>[];
    return s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != 'null')
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
    this.failProcess = const [],
    this.extName = '',
  });

  final List<String> urls;
  final List<String> backupUrls;
  final String quality;
  final int bitrate;
  final bool isPreview;
  final int errorCode;
  final String message;
  final String? ssaCode;

  /// 非空表示服务端明确拒绝（需购买/无版权等），降级无意义
  final List<String> failProcess;

  /// 服务端实际返回的音质扩展名（如 flac/320/128）
  final String extName;

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
      // 60s 试听：end_ms 约 60000 或路径含 /p_0_（flac 时 bitRate=0 不可作为依据）
      isPreview:
          (endMs > 0 && endMs <= 65000) || urls.any((u) => u.contains('/p_0_')),
      errorCode: res.errorCode,
      message: '${b['error'] ?? b['error_msg'] ?? b['errmsg'] ?? ''}',
      ssaCode: res.ssaCode,
      failProcess: toList(b['fail_process']),
      extName: '${b['extName'] ?? ''}',
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
    final info = j['info'] is Map
        ? Map<String, dynamic>.from(j['info'] as Map)
        : const <String, dynamic>{};
    // 真实权益在 data[].relate_goods[]（128 可能同时有 level=1 ogg 与 level=2 mp3）
    final goods = j['relate_goods'];
    final g = (goods is List && goods.isNotEmpty)
        ? Map<String, dynamic>.from(goods.first as Map)
        : <String, dynamic>{};
    final fp = g['fail_process'] ?? j['fail_process'];
    return PrivilegeItem(
      hash: '${j['hash'] ?? ''}',
      privilege: _int(g['privilege'] ?? j['privilege']),
      payType: _int(g['pay_type'] ?? j['pay_type']),
      status: _int(g['status'] ?? j['status']),
      failProcess: fp is List
          ? fp.map(_int).toList()
          : (_int(fp) > 0 ? [_int(fp)] : const <int>[]),
      quality: '${g['quality'] ?? j['quality'] ?? ''}',
      pkgPrice: _int(g['pkg_price'] ?? j['pkg_price']),
      durationMs: info['duration'] == null ? null : _int(info['duration']),
      cover: info['image']?.toString(),
    );
  }

  static int _int(dynamic v) =>
      v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
}
