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
class KgResponse {
  const KgResponse({
    required this.status,
    required this.body,
    this.headers = const {},
  });

  /// HTTP 状态（200 成功 / 502 封装失败）
  final int status;

  /// 解析后的响应体（JSON Map）
  final Map<String, dynamic> body;

  /// 响应头（小写 key），含 ssa-code
  final Map<String, String> headers;

  bool get isOk => status == 200 && body['status'] == 1;

  /// 业务错误码
  int get errorCode {
    final v = body['error_code'] ?? body['errcode'] ?? 0;
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
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ));

  final KgDevice device;
  final Dio _dio;

  String token = '';
  String userid = '0';

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
    final bodyStr = data == null
        ? ''
        : (data is String ? data : jsonEncode(data));

    // 签名
    if (!allParams.containsKey('signature') && !notSignature) {
      allParams['signature'] = switch (encryptType) {
        'register' => KgSignature.register(allParams),
        'web' => KgSignature.web(allParams, data: bodyStr),
        _ => KgSignature.android(allParams, data: bodyStr, lite: lite),
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
        data: bodyStr.isEmpty ? null : bodyStr,
        options: Options(
          method: method,
          headers: reqHeaders,
          contentType:
              bodyStr.isEmpty ? null : 'application/json;charset=utf-8',
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
    );
  }

  /// 带验证自动处理的请求：命中 20028 时提交 sid/edt 后重试一次
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

  bool _needsVerify(KgResponse r) => r.errorCode == 20028;

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
  Future<bool> registerDevice() async {
    const aesKeySeed = 'abcdef';
    final aes = KgCrypto.aesEncryptHex(
      jsonEncode(_registerPayload()),
      key: null,
    );
    final p = KgCrypto.rsaEncryptPkcs1(
      jsonEncode({'aes': aes.key, 'uid': userid, 'token': token}),
      lite: lite,
    );

    final r = await request(
      '/risk/v3/r_register_dev',
      baseUrl: KgConfig.registerGateway,
      method: 'POST',
      params: {'part': 1, 'platid': 1, 'p': p},
      data: aes.str,
      encryptType: 'android',
      clearDefaultParams: false,
    );

    // 尝试从 body.data.dfid 或 set-cookie 拿 dfid
    final data = r.body['data'];
    if (data is Map && data['dfid'] != null) {
      device.dfid = '${data['dfid']}';
      return true;
    }
    final cookie = r.headers['set-cookie'] ?? '';
    final m = RegExp(r'dfid=([^;,\s]+)').firstMatch(cookie);
    if (m != null) {
      device.dfid = m.group(1)!;
      return true;
    }
    // aesKeySeed 占位避免未使用告警
    assert(aesKeySeed.isNotEmpty);
    return false;
  }

  Map<String, dynamic> _registerPayload() => {
        'uuid': device.guid,
        'guid': device.guid,
        'imei': device.guid,
        'mid': device.mid,
        'availableRamSize': 4983533568,
        'availableRomSize': 48114719,
        'availableSDSize': 48114717,
        'basebandVer': '',
        'batteryLevel': 100,
        'batteryStatus': 3,
        'brand': 'Redmi',
        'buildSerial': 'unknown',
        'device': 'marble',
        'imsi': '',
        'manufacturer': 'Xiaomi',
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
        'networktype': 1,
        'mac': device.mac,
      };
}

/// 字节工具
Uint8List toBytes(String s) => Uint8List.fromList(utf8.encode(s));
