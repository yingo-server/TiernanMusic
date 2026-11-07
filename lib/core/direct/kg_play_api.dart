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
      // F4-02（审查①-B，P1）：播放主路径落原生域 trackercdn.kugou.com，
      // 不再用 gateway + x-router（口径「trackercdn.kugou.com 用于 /v5/url」）。
      baseUrl: 'https://trackercdn.kugou.com',
      params: params,
      encryptType: 'android',
      // F4-01（审查①-B，P1→驳回）：报告要求按 Node `notSign: true` 撤掉 signature，
      // 但实测（curl 直打 trackercdn.kugou.com/v5/url）无 signature 时服务端返回
      // {"errcode":"20006","status":0,"errmsg":"err signature"}，带 android signature
      // 才返回 priv_status/hash_offset；且 Node util/request.js 只认 `notSignature`，
      // `notSign` 拼写根本不生效（该端点实际是**签名**发的）。故保留自动签名，
      // 见 docs/batch4_fix_1_network.md「F4-01 实测驳回」。
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
    // F4-08（审查①-B，P1）：Node privilege_lite.js 对每个 hash 按需要的音质
    // **逐档**在 relate_goods 里挑条目（pickRelate），不是只取 first ——
    // 128 有 level=1(ogg)/level=2(mp3) 两条，取 first 会把 320/flac 的权益
    // 当成 128 的，VIP 判定整档失真。
    final wanted =
        qualities.isEmpty ? KgSharedParams.defaultQualities : qualities;
    return [
      for (final e in list.whereType<Map>())
        for (final q in wanted)
          PrivilegeItem.fromJson(Map<String, dynamic>.from(e), quality: q),
    ];
  }
}

/// 播放 / 权益接口的**共享**参数构造
///
/// `kg_direct_api_client.dart` 与 [KgPlayApi] 共用，保证两边行为一致。
class KgSharedParams {
  KgSharedParams._();

  /// 魔法音效（概念版）。V399-B3：与 AudioQuality.magicOrder 对齐——
  /// 这里是**wire 名**（/v5/url 的 quality 参数用 `magic_` 前缀），
  /// 兼容带前缀与不带前缀两种写法（枚举 value 是带前缀形态）。
  static const List<String> magicQualities = [
    'piano', 'acappella', 'subwoofer', 'ancient', 'dj', 'surnay',
    'magic_piano', 'magic_acappella', 'magic_subwoofer',
    'magic_ancient', 'magic_dj', 'magic_surnay',
  ];

  /// V399-B3：蝰蛇三档 wire 名（VIP 态 /v5/url 实测真实返回 URL）。
  /// quality 参数原样传（无前缀），与 AudioQuality.viperOrder 对齐。
  static const List<String> viperQualities = [
    'viper_tape', 'viper_clear', 'viper_atmos',
  ];

  /// F4-07（审查①-B，P1）：上游一次请求的**完整**音质表
  /// （Node privilege_lite.js `UPSTREAM_QUALITIES`）。实测（curl
  /// gateway/v2/get_res_privilege/lite）只有整表下发才会返回 128 的 ogg 条目
  /// 与 vip/missing 各档；只传调用方要的那一档时其余档全缺，权益判定失真。
  /// 输出再按调用方 `qualities` 过滤（Node 同样如此）。
  static const List<String> upstreamQualities = [
    '128', '320', 'flac', 'high',
    'viper_atmos', 'viper_tape', 'viper_clear', 'super', 'multitrack',
  ];

  /// Node privilege_lite.js 的默认**输出**音质表（与上游表顺序不同：蝰蛇三档在后）
  static const List<String> defaultQualities = [
    '128', '320', 'flac', 'high', 'viper_tape', 'viper_clear', 'viper_atmos',
  ];

  /// F4-08（审查①-B，P1）：音质 → relate_goods.level 的取用顺序
  /// （Node `QUALITY_LEVEL`）。实测 relate_goods：128→level2、320→4、flac→5、
  /// high→6 各一条，蝰蛇/多轨 level=0；128 在概念版下可能额外有 level=1 的 ogg。
  static const Map<String, List<int>> qualityLevels = {
    '128': [1, 2],
    '320': [4],
    'flac': [5],
    'high': [6],
    'super': [7],
  };

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
    // V399-B3：魔法档统一补 magic_ 前缀（已是 magic_* 形态的不再重复补）；
    // 蝰蛇档原样传（wire 名即 viper_*，无前缀规则）。
    var q = quality;
    if (!q.startsWith('magic_') && magicQualities.contains(q)) q = 'magic_$q';
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
  ///
  /// F4-07（审查①-B，P1）：上游 `qualities` **恒下发完整表**，不随调用方入参收窄。
  /// [qualities] 仅作为调用方的**输出**过滤需求保留（由 [KgPlayApi.privilege] 使用）。
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
      // F4-10（审查①-B，P2）：album_id 缺失时下发**数值** 0（Node `|| 0`），
      // 而不是字符串 '0' —— 上游按字符串解析会返回 20010。
      final albumId = int.tryParse(
              i < albumIds.length ? albumIds[i].trim() : '') ??
          0;
      resource.add({
        'type': 'audio',
        'page_id': 0,
        'hash': hash,
        'album_id': albumId,
      });
    }

    return <String, dynamic>{
      'appid': client.lite ? KgConfig.liteAppid : KgConfig.appid,
      'area_code': 1,
      'behavior': 'play',
      'clientver': client.lite ? KgConfig.liteClientver : KgConfig.clientver,
      'need_hash_offset': 1,
      'relate': 1,
      'support_verify': 1,
      'resource': resource,
      'qualities': upstreamQualities,
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
    this.startMs = 0,
    this.endMs = 0,
    this.clipHash = '',
    this.offsetHash = '',
    // V399-B4：试听/高潮片段的 API 声明字节数（不下载即可比较长短）
    this.previewFileSize = 0,
    this.offsetFileSize = 0,
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

  /// F4-09（审查①-B，P1）：`hash_offset` 描述的试听片段区间（毫秒）。
  /// 实测 /v5/url（IsFreePart=1）返回
  /// `hash_offset{clip_hash,start_byte,end_byte,start_ms,end_ms,offset_hash,file_type}`：
  /// 只有 `end_ms` 时无法知道从第几秒开始播，短片段会整段错位。
  final int startMs;
  final int endMs;

  /// 试听片段对应的裁剪资源 hash（与整曲 hash 不同，播放/下载应优先用它）
  final String clipHash;

  /// `hash_offset` 的 offset_hash（服务端区间标识）
  final String offsetHash;

  /// V399-B4：试听片段声明的字节数（响应体 filesize；0=未声明）
  final int previewFileSize;

  /// V399-B4：高潮片段（offset_hash）声明的字节数
  ///（hash_offset.start_byte/end_byte 之差；0=未声明）
  final int offsetFileSize;

  /// V399-B4：试听片段时长（毫秒）；无区间信息时为 0
  int get clipDurationMs => endMs > startMs ? endMs - startMs : endMs;

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
    // F4-09（审查①-B，P1）：hash_offset 全字段读取。
    // 实测结构：{clip_hash, start_byte, end_byte, start_ms, end_ms, offset_hash, file_type}
    final offset = b['hash_offset'] is Map
        ? Map<String, dynamic>.from(b['hash_offset'] as Map)
        : const <String, dynamic>{};
    int ms(String key) => int.tryParse('${offset[key] ?? ''}') ?? 0;
    final startMs = ms('start_ms');
    final endMs = ms('end_ms');
    final clipHash = '${offset['clip_hash'] ?? ''}';
    // V399-B4：API 声明的字节数（试听片段 vs 高潮片段），供下载侧择优
    // 比较——禁止真的下载两个文件比对（第 24 条按需计算 / 任务书 B4）。
    final previewSize =
        b['filesize'] is int ? b['filesize'] as int : int.tryParse('${b['filesize'] ?? ''}') ?? 0;
    final offsetStartByte = ms('start_byte');
    final offsetEndByte = ms('end_byte');
    final offsetSize = offsetEndByte > offsetStartByte
        ? offsetEndByte - offsetStartByte
        : (offsetEndByte > 0 ? offsetEndByte : 0);

    return PlayUrlResult(
      urls: urls,
      backupUrls: backups,
      quality: '${b['quality'] ?? ''}',
      bitrate: bitrate,
      // 试听判定：区间时长（end_ms-start_ms）≤65s，或路径含 /p_0_（试听前缀）。
      // 此前只看 end_ms≤65000，短歌整曲（end_ms=全长）会被误判 / 从 120s 起的
      // 60s 片段（end_ms=180000）反而漏判。
      isPreview: (endMs > 0 &&
              (endMs - startMs > 0 ? endMs - startMs : endMs) <= 65000) ||
          urls.any((u) => u.contains('/p_0_')),
      errorCode: res.errorCode,
      message: '${b['error'] ?? b['error_msg'] ?? b['errmsg'] ?? ''}',
      ssaCode: res.ssaCode,
      failProcess: toList(b['fail_process']),
      extName: '${b['extName'] ?? ''}',
      startMs: startMs,
      endMs: endMs,
      clipHash: clipHash,
      offsetHash: '${offset['offset_hash'] ?? ''}',
      previewFileSize: previewSize,
      offsetFileSize: offsetSize,
    );
  }
}

/// 权益条目
///
/// F4-08（审查①-B，P1）：一条记录对应「一个 hash × 一个音质档」，
/// 与 Node privilege_lite.js 的 `qualities[]` 输出逐条对齐 —— 不再把所有
/// 档位的权益都算到 relate_goods 的第一条上。
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
    this.level = 0,
    this.exists = false,
    this.bitrate = 0,
    this.extName = '',
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

  /// relate_goods.level（2=128、4=320、5=flac、6=Hi-Res、7=DSD，其它为 0）
  final int level;

  /// 上游是否为该音质提供了权益条目（缺档 = 该音质不存在）
  final bool exists;

  final int bitrate;
  final String extName;

  /// 是否免费可播：存在该档权益 + privilege=0 + status≠0
  /// （Node obtainable = exists && !neesuvip && relateItem.status !== 0；
  /// 只判 privilege 会把 status=0 的不可播条目当成免费）
  bool get isFree => exists && privilege == 0 && status != 0;

  /// 是否需要付费/会员
  bool get needsPurchase => payType != 0 || privilege != 0;

  factory PrivilegeItem.fromJson(Map<String, dynamic> j,
      {String quality = '128'}) {
    final info = j['info'] is Map
        ? Map<String, dynamic>.from(j['info'] as Map)
        : const <String, dynamic>{};
    // 真实权益在 data[].relate_goods[]（每档一条：quality + level）
    final goods = j['relate_goods'];
    final list = goods is List
        ? goods
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];
    final g = _pickRelate(list, quality);
    final gInfo = g['info'] is Map
        ? Map<String, dynamic>.from(g['info'] as Map)
        : const <String, dynamic>{};
    final fp = g['fail_process'] ?? j['fail_process'];
    return PrivilegeItem(
      hash: '${j['hash'] ?? ''}',
      privilege: _int(g['privilege'] ?? j['privilege']),
      payType: _int(g['pay_type'] ?? j['pay_type']),
      status: _int(g['status'] ?? j['status']),
      failProcess: fp is List
          ? fp.map(_int).toList()
          : (_int(fp) > 0 ? [_int(fp)] : const <int>[]),
      // 音质以**请求档位**为准：关系表缺该档时不能退化成别的档位名
      quality: quality,
      pkgPrice: _int(g['pkg_price'] ?? j['pkg_price']),
      durationMs: info['duration'] == null ? null : _int(info['duration']),
      cover: info['image']?.toString(),
      level: _int(g['level']),
      exists: g.isNotEmpty,
      bitrate: _int(gInfo['bitrate']),
      extName: '${gInfo['extname'] ?? ''}',
    );
  }

  /// 按 [KgSharedParams.qualityLevels] 的 level 顺序逐档挑选该音质的条目
  /// （128 优先 level=1 的概念版 ogg，其次 level=2 的 mp3）。
  static Map<String, dynamic> _pickRelate(
      List<Map<String, dynamic>> goods, String quality) {
    final q = quality.toLowerCase();
    for (final level in KgSharedParams.qualityLevels[q] ?? const <int>[]) {
      for (final g in goods) {
        if (_int(g['level']) == level &&
            '${g['quality'] ?? ''}'.toLowerCase() == q) {
          return g;
        }
      }
    }
    for (final g in goods) {
      if ('${g['quality'] ?? ''}'.toLowerCase() == q) return g;
    }
    // 该音质在 relate_goods 里不存在：返回空表（exists=false），不得借用别档
    return const <String, dynamic>{};
  }

  static int _int(dynamic v) =>
      v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
}
