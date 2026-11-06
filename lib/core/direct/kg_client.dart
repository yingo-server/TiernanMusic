/// 酷狗网关直连客户端（移植自 KuGouMusicApi util/request.js 的 createRequest）
///
/// 与旧 KugouApiClient 的区别：不再经由自建 Node 服务中转，
/// 由 App 直接向 gateway.kugou.com 发请求，签名/设备标识全部本地生成。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../features/auth/data/edt_generator.dart';
import 'kg_crypto.dart';

/// 直连响应
class KgResponse {  const KgResponse({
    required this.status,
    required this.body,
    this.headers = const {},
    this.rawBytes,
  });

  /// HTTP 状态（200 成功 / 502 封装失败）
  final int status;

  /// 解析后的响应体（JSON Map）
  final Map<String, dynamic> body;

  /// 响应头（小写 key），含 ssa-code
  final Map<String, String> headers;

  /// 原始响应字节（非 JSON 响应，如 AES 加密的二进制体）。
  /// 需要自行用 seed 派生 key/iv 解密。
  final List<int>? rawBytes;

  /// HTTP 200 + 业务 status 成功。
  ///
  /// ⚠️ 业务成功语义不统一（docs/api_verified.md 实测）：
  /// - 多数业务接口：`body.status == 1`
  /// - 歌词类（lyrics.kugou.com）：HTTP 200 + `body.status == 200` + `errcode == 200`
  /// 故这里把 `status == 200` 也视为成功；细节判定仍由各端点的 `_wrap` 负责。
  ///
  /// V35-A1（第 A 批，P2）：⚠️ 本 getter 与 `_wrap` 的判定口径**不一致**
  ///（此处不看 err_code/error_code，_wrap 有五分支）——全仓零调用方
  ///（第 32 条死代码），保留会诱导调用方绕过 _wrap。已确认删除依据：
  /// `rg isOk` 仅此一处声明。若未来需要「HTTP 层快速判定」，请命名
  /// `isHttpOk` 并在注释中说明与 _wrap 的分工。

  /// 业务错误码
  ///
  /// 读取顺序：`error_code`（通用）→ `errcode`（网关）→ `err_code`
  /// （mcomment 系列业务码，实测 status=1 + err_code=60102 表示失败）。
  int get errorCode {
    final v = body['error_code'] ?? body['errcode'] ?? body['err_code'] ?? 0;
    return v is int ? v : int.tryParse('$v') ?? 0;
  }

  /// mcomment 专有业务码（与 [errorCode] 分开读，避免普通接口误判）
  int get businessErrorCode {
    final v = body['err_code'] ?? 0;
    return v is int ? v : int.tryParse('$v') ?? 0;
  }

  String? get ssaCode =>
      (body['ssaCode'] ?? body['ssa_code'] ?? headers['ssa-code'])?.toString();
}

/// 设备身份（对应 server.js 注入的 KUGOU_API_* cookie）
class KgDevice {
  KgDevice({
    required this.guid,
    required this.mid,
    this.dfid = '',
    this.dev = '',
    this.mac = '',
    this.webgl = '',
  });

  final String guid;
  final String mid;
  String dfid;
  final String dev;
  final String mac;
  final String webgl;

  /// 由 GUID 计算 MID（移植 calculateMid：MD5 转 BigInt 十进制）
  static String calculateMid(String guid) {
    final digest = KgCrypto.md5(guid);
    var value = BigInt.zero;
    final base = BigInt.from(16);
    for (var i = 0; i < digest.length; i++) {
      final charValue = BigInt.from(int.parse(digest[i], radix: 16));
      value = value + charValue * base.pow(digest.length - 1 - i);
    }
    return value.toString();
  }

  /// 生成默认设备（首次启动调用一次并持久化）
  factory KgDevice.generate() {
    final guid = KgCrypto.uuidV4();
    return KgDevice(
      guid: guid,
      mid: calculateMid(guid),
      dev: KgCrypto.randomString(10),
      mac: _randomMac(),
      webgl: '11664606328242161144',
    );
  }

  static String _randomMac() {
    final r = KgCrypto.randomString(12).toLowerCase();
    final hex = List.generate(
      12,
      (i) => '0123456789abcdef'[
          (r.codeUnitAt(i) * 7 + i * 13) % 16],
    ).join();
    return '${hex.substring(0, 2)}:${hex.substring(2, 4)}:'
        '${hex.substring(4, 6)}:${hex.substring(6, 8)}:'
        '${hex.substring(8, 10)}:${hex.substring(10, 12)}';
  }

  Map<String, dynamic> toJson() => {
        'guid': guid,
        'mid': mid,
        'dfid': dfid,
        'dev': dev,
        'mac': mac,
        'webgl': webgl,
      };

  factory KgDevice.fromJson(Map<String, dynamic> j) => KgDevice(
        guid: '${j['guid'] ?? ''}',
        mid: '${j['mid'] ?? ''}',
        dfid: '${j['dfid'] ?? ''}',
        dev: '${j['dev'] ?? ''}',
        mac: '${j['mac'] ?? ''}',
        webgl: '${j['webgl'] ?? ''}',
      );
}

/// 直连客户端
class KgClient {
  KgClient({required this.device, String? baseUrl})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 25),
          // 设备注册 / 云歌单 / 歌词下载等较慢接口，请求体发出也需要上限
          sendTimeout: const Duration(seconds: 30),
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ));

  final KgDevice device;
  final Dio _dio;

  String token = '';
  String userid = '0';
  String t1 = ''; // 登录态 t1 票据（login/token 刷新签名用）

  /// PLY-12：登录态 dfid（与 token/userid 同步，QUALITY_STANDARD 第 5 条
  /// 状态单一来源——直连层签名取 kg.device.dfid，登录刷新后需保持一致）。
  String dfid = '';

  /// F4-12（审查①-B，P1）：登录态会员信息（三态判定：匿名/非 VIP/VIP）。
  /// 由 KgEndpointAuth._afterLogin 从登录响应的 data.vip_type / vip_token 写入；
  /// 匿名/非 VIP 为 '0' / ''。此前全仓无该字段，banner 等处只能硬编码 0。
  String vipType = '0';
  String vipToken = '';

  bool lite = false;

  /// 通用请求（对应 createRequest）
  Future<KgResponse> request(
    String path, {
    String baseUrl = KgConfig.gateway,
    String method = 'GET',
    Map<String, dynamic>? params,
    dynamic data,
    String encryptType = 'android',
    Map<String, String>? headers,
    bool clearDefaultParams = false,
    bool notSignature = false,
  }) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final appid = lite ? KgConfig.liteAppid : KgConfig.appid;
    final clientver = lite ? KgConfig.liteClientver : KgConfig.clientver;

    final defaultParams = <String, dynamic>{
      'dfid': device.dfid.isEmpty ? '-' : device.dfid,
      'mid': device.mid,
      // uuid 实测保留 '-'：匿名态 A/B（/v5/url 免费曲，uuid='-' vs guid）
      // 两者均 status=1 返回 url、无差异；Node 版虽注入 uuid=guid，
      // 但改 guid 未见任何收益，维持既往实测结论（勿盲改）。
      'uuid': '-',
      'appid': appid,
      'clientver': clientver,
      'clienttime': clienttime,
      if (token.isNotEmpty) 'token': token,
      if (userid.isNotEmpty && userid != '0') 'userid': userid,
    };

    final allParams = <String, dynamic>{
      if (!clearDefaultParams) ...defaultParams,
      ...?params,
    };

    // 请求体序列化
    // V35-C1（第 C 批，P1）：支持二进制 body——Node mv_collect_del.js 发
    // `Buffer.from(aesEncrypt.str,'base64')`（原始字节），而 playlist_del.js
    // 发 `aesEncrypt.str`（Base64 文本）。KgClient 此前只有 String/jsonEncode
    // 两分支，List<int> 会被 jsonEncode 成整数数组文本——MV 收藏的
    // base64Decode 传参实际发的是「[21,34,...]」文本而非二进制（V34 修复
    // 的真实行为与 Node 不符）。加 Uint8List 分支直传字节。
    final String? bodyStr = data == null
        ? ''
        : data is Uint8List
            ? null // 二进制直传，不走字符串编码
            : (data is String ? data : jsonEncode(data));

    // 签名
    if (!allParams.containsKey('signature') && !notSignature) {
      allParams['signature'] = switch (encryptType) {
        'register' => KgSignature.register(allParams),
        'web' => KgSignature.web(allParams, data: bodyStr ?? ''),
        _ => KgSignature.android(allParams, data: bodyStr ?? '', lite: lite),
      };
    }

    final reqHeaders = <String, dynamic>{
      'dfid': device.dfid.isEmpty ? '-' : device.dfid,
      'clienttime': '$clienttime',
      'mid': device.mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
      ...?headers,
    };

    Response<List<int>> res;
    try {
      res = await _dio.request<List<int>>(
        '$baseUrl$path',
        queryParameters: allParams,
        // V35-C1：二进制 body（Uint8List）直传；字符串按原逻辑
        data: data is Uint8List
            ? data
            : (bodyStr == null || bodyStr.isEmpty ? null : bodyStr),
        options: Options(
          method: method,
          headers: reqHeaders,
          contentType: data is Uint8List
              ? 'application/octet-stream'
              : (bodyStr == null || bodyStr.isEmpty
                  ? null
                  : 'application/json;charset=utf-8'),
        ),
      );
    } on DioException catch (e) {
      return KgResponse(
        status: 502,
        body: {'status': 0, 'error': '${e.message}'},
      );
    }

    final raw = res.data == null ? '' : utf8.decode(res.data!, allowMalformed: true);
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(raw);
      body = decoded is Map<String, dynamic> ? decoded : {'data': decoded};
    } catch (_) {
      body = {'status': 0, 'error': '响应解析失败', 'raw': raw.substring(0, raw.length.clamp(0, 200))};
    }

    final headerMap = <String, String>{};
    res.headers.forEach((k, v) {
      headerMap[k.toLowerCase()] = v.join(',');
    });

    return KgResponse(
      status: res.statusCode ?? 0,
      body: body,
      headers: headerMap,
      rawBytes: res.data,
    );
  }

  /// 带验证自动处理的请求：命中 20028 时提交 sid/edt 后重试一次
  ///
  /// V3-10（第5批复核①，P1）：**写操作禁止使用本方法**（第 21 条）——
  /// 验证后重试会把同一请求原样重发；若首次请求服务端已执行
  /// （响应在风控校验环节才失败），重试即重复提交（重复评论/重复加歌）。
  /// 写端点必须直接调 [request]，把 20028 上抛交给 UI 验证流程处理。
  Future<KgResponse> requestWithVerify(
    String path, {
    String baseUrl = KgConfig.gateway,
    String method = 'GET',
    Map<String, dynamic>? params,
    dynamic data,
    String encryptType = 'android',
    Map<String, String>? headers,
    bool clearDefaultParams = false,
    bool notSignature = false,
    int retries = 1,
  }) async {
    final first = await request(
      path,
      baseUrl: baseUrl,
      method: method,
      params: params,
      data: data,
      encryptType: encryptType,
      headers: headers,
      clearDefaultParams: clearDefaultParams,
      notSignature: notSignature,
    );
    if (!_needsVerify(first) || retries <= 0) return first;

    final ssa = first.ssaCode;
    if (ssa == null || ssa.isEmpty) return first;

    final ok = await submitFingerprintVerification(ssa);
    if (!ok) return first;

    return request(
      path,
      baseUrl: baseUrl,
      method: method,
      params: params,
      data: data,
      encryptType: encryptType,
      headers: headers,
      clearDefaultParams: clearDefaultParams,
      notSignature: notSignature,
    );
  }

  /// 是否需要走人机验证。
  ///
  /// 对齐 Node request.js:234-246：任意失败响应（status==0 或 error_code!=0）
  /// 只要带 `ssa-code` 头/体，就应生成 sid/edt 提交验证后重试，
  /// 而非只认 20028。实测 20006（签名错风控）也会带 ssa-code。
  bool _needsVerify(KgResponse r) {
    if (r.status != 200) return false;
    final failed =
        r.body['status'] == 0 || r.errorCode != 0;
    return failed && (r.ssaCode?.isNotEmpty ?? false);
  }

  /// 生成 sid/edt 并提交 /verify/user/info
  Future<bool> submitFingerprintVerification(String ssaCode) async {
    final edt = EdtGenerator.generate(
      mid: device.mid,
      userid: userid,
      dfid: device.dfid.isEmpty ? '0' : device.dfid,
      webglHash: device.webgl.isEmpty ? '0' : device.webgl,
    );

    final r = await request(
      '/verifyservice/v3/get_verify_info',
      baseUrl: 'https://verifyservice.kugou.com',
      method: 'POST',
      params: {'clientver': lite ? KgConfig.liteClientver : KgConfig.clientver},
      data: {
        'eventid': ssaCode,
        'userid': int.tryParse(userid) ?? 0,
        'platid': 2,
        'rtype': 1,
        'wasm': 1,
        'i': '',
        'sid': edt.sid,
        'edt': edt.edt,
      },
      encryptType: 'android',
    );
    return r.body['status'] == 1;
  }

  /// 设备注册（移植 module/register_dev.js），成功后写入 device.dfid
  ///
  /// 【实测结论 / 24-24 成功率的完整步骤】
  /// ```
  /// POST https://userservice.kugou.com/risk/v3/r_register_dev
  /// query: part=1, platid=2, p=<RSA-PKCS1-v1_5 hex 小写>
  ///       + dfid, mid, uuid, appid=1005, clientver=20489, clienttime, signature
  /// body : playlistAesEncrypt(payload) 的 base64 串
  /// headers: Content-Type: application/x-www-form-urlencoded
  ///          dfid / clienttime / mid / kg-rc / kg-thash / kg-rec / kg-rf / User-Agent
  /// ```
  ///
  /// 踩过的坑（均经 A/B 实测确认，勿改）：
  /// - **platid 必须是 2**（platid=1 只有约 50% 成功率）
  /// - **`uid` 必须传字符串 `"0"`**（传数值 0 或已登录 uid → 响应 `data:[]`，
  ///   拿不到 dfid）
  /// - **`p` 用小写 hex**（对齐 Node `forge.util.bytesToHex`）
  /// - **signature 必须包含 body**：android 签名 =
  ///   `md5(salt + sorted("k=v") + bodyStr + salt)`
  /// - **响应是二进制不是 JSON**（content-type: application/octet-stream）：
  ///   `base64(bytes)` → 用 seed 派生 key/iv 解密 → JSON `{status, error_code, data:{dfid}}`
  /// - `data:[]` 表示没分配到 dfid（需要重试）
  ///
  /// 失败重试 3 次；成功后把 dfid 写回 [device.dfid] 并持久化到 Hive。
  Future<bool> registerDevice({int retries = 3}) async {
    for (var attempt = 0; attempt < retries; attempt++) {
      final ok = await _registerDeviceOnce();
      if (ok) {
        _persistDfid();
        return true;
      }
      // 退避后重试，避免连续打同一个接口被风控
      if (attempt < retries - 1) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
    return false;
  }

  /// 注册成功后回调（由 [kg_providers] 注入，用于把 dfid 落盘到 Hive）
  void Function(String dfid)? onDfidRegistered;

  void _persistDfid() {
    final dfid = device.dfid;
    if (dfid.isEmpty) return;
    try {
      onDfidRegistered?.call(dfid);
    } catch (_) {
      // 持久化失败不影响本次请求
    }
  }

  Future<bool> _registerDeviceOnce() async {
    final payload = _registerPayload();
    final aes = KgCrypto.aesEncryptHex(jsonEncode(payload));
    // uid 必须是字符串 "0"：传数值 0 或已登录 uid 都会返回 data:[]
    final p = KgCrypto.rsaEncryptPkcs1(
      jsonEncode({'aes': aes.key, 'uid': '0', 'token': ''}),
      lite: lite,
    );

    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final appid = lite ? KgConfig.liteAppid : KgConfig.appid;
    final clientver = lite ? KgConfig.liteClientver : KgConfig.clientver;

    final params = <String, dynamic>{
      'dfid': device.dfid.isEmpty ? '-' : device.dfid,
      'mid': device.mid,
      'uuid': '-',
      'appid': appid,
      'clientver': clientver,
      'clienttime': clienttime,
      'part': 1,
      // platid 必须是 2（1 只有 ~50% 成功率）
      'platid': 2,
      'p': p,
    };

    // 签名必须包含 body（bodyStr = AES base64 串）
    final bodyStr = aes.str;
    params['signature'] = KgSignature.android(params, data: bodyStr, lite: lite);

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'dfid': device.dfid.isEmpty ? '-' : device.dfid,
      'clienttime': '$clienttime',
      'mid': device.mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
    };

    Response<List<int>> res;
    try {
      res = await _dio.request<List<int>>(
        '${KgConfig.registerGateway}/risk/v3/r_register_dev',
        queryParameters: params,
        data: bodyStr,
        options: Options(
          method: 'POST',
          headers: headers,
          responseType: ResponseType.bytes,
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
    } on DioException catch (_) {
      return false;
    }

    final raw = res.data ?? const <int>[];
    if (raw.isEmpty) return false;

    // 响应是二进制（application/octet-stream）：
    // base64(bytes) → 用 seed 派生 key/iv 解密 → JSON
    Map<String, dynamic> body;
    try {
      body = KgCrypto.aesDecryptPlaylistB64(base64.encode(raw), aes.key);
    } catch (_) {
      // 少数情况下服务端直接返回明文 JSON
      try {
        final decoded = jsonDecode(utf8.decode(raw, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          body = decoded;
        } else {
          return false;
        }
      } catch (_) {
        return false;
      }
    }

    final data = body['data'];
    if (data is Map && data['dfid'] != null) {
      final dfid = '${data['dfid']}';
      if (dfid.isNotEmpty) {
        device.dfid = dfid;
        return true;
      }
    }
    // data:[] 表示没分配到 dfid → 交给上层重试
    return false;
  }

  /// 注册载荷（对齐 Node `module/register_dev.js` 的 dataMap）
  ///
  /// 注意：**不要**加 guid / mid / networktype / mac —— Dart 旧实现多出的
  /// 这几个字段会降低注册成功率。
  Map<String, dynamic> _registerPayload() => {
        'availableRamSize': 4983533568,
        'availableRomSize': 48114719,
        'availableSDSize': 48114717,
        'basebandVer': '',
        'batteryLevel': 100,
        'batteryStatus': 3,
        'brand': 'Redmi',
        'buildSerial': 'unknown',
        'device': 'marble',
        'imei': device.guid,
        'imsi': '',
        'manufacturer': 'Xiaomi',
        'uuid': device.guid,
        'accelerometer': false,
        'accelerometerValue': '',
        'gravity': false,
        'gravityValue': '',
        'gyroscope': false,
        'gyroscopeValue': '',
        'light': false,
        'lightValue': '',
        'magnetic': false,
        'magneticValue': '',
        'orientation': false,
        'orientationValue': '',
        'pressure': false,
        'pressureValue': '',
        'step_counter': false,
        'step_counterValue': '',
        'temperature': false,
        'temperatureValue': '',
      };
}

/// 字节工具
Uint8List toBytes(String s) => Uint8List.fromList(utf8.encode(s));
