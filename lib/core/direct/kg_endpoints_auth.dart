import 'dart:convert';

import 'package:qr_flutter/qr_flutter.dart';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';

/// 账号/登录/验证端点
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointAuth {
  KgEndpointAuth(this.kg);
  final KgClient kg;


  //
  // 全部按 KuGouMusicApi/module 下同名 js 逐行移植：
  // 请求的 url/baseURL/method/params/data/encryptType/headers 保持一致。
  // 登录成功（status==1 且含 secu_params）时解密并回写 kg.token / kg.userid。

  /// 二维码 appid/srcappid 常量（config.json）
  static const int _qrSrcappid = 2919;

  /// 掩码手机号（形如 13*****0），酷狗登录接口要求传掩码值
  String _maskMobile(String mobile) {
    if (mobile.length < 11) return mobile;
    return '${mobile.substring(0, 2)}*****${mobile.substring(10, 11)}';
  }

  /// 酷狗设备注册（对应 module/register_dev.js，复用 kg.registerDevice）
  Future<KgResponse> registerDev() async {
    final ok = await kg.registerDevice();
    if (ok && kg.device.dfid.isNotEmpty) {
      return KgResponse(
        status: 200,
        body: <String, dynamic>{
          'status': 1,
          'data': <String, dynamic>{'dfid': kg.device.dfid},
        },
      );
    }
    return KgResponse(
      status: 200,
      body: <String, dynamic>{'status': 0, 'error': '设备注册失败'},
    );
  }

  /// 发送短信验证码（对应 module/captcha_sent.js）
  Future<KgResponse> captchaSent(Map<String, dynamic> q) {
    return kg.request('/v7/send_mobile_code',
        baseUrl: 'http://login.user.kugou.com',
        method: 'POST',
        encryptType: 'android',
        data: {
          'businessid': 5,
          'mobile': '${q['mobile'] ?? ''}',
          'plat': 3,
        });
  }

  /// 手机验证码登录（对应 module/login_cellphone.js）
  Future<KgResponse> loginCellphone(Map<String, dynamic> q) async {
    final dateTime = DateTime.now().millisecondsSinceEpoch;
    final encrypt = KgCrypto.aesEncryptCbcAuto(jsonEncode({
      'mobile': '${q['mobile'] ?? ''}',
      'code': '${q['code'] ?? ''}',
    }));
    final mobile = _maskMobile('${q['mobile'] ?? ''}');
    final dfid = kg.device.dfid.isNotEmpty
        ? kg.device.dfid
        : KgCrypto.randomString(24);
    final lite = kg.lite;
    final t2 = KgCrypto.aesEncryptCbcHex(
      '${kg.device.guid}|0f607264fc6318a92b9e13c65db7cd3c|${kg.device.mac}|${kg.device.dev}|$dateTime',
      key: 'fd14b35e3f81af3817a20ae7adae7020',
      iv: '17a20ae7adae7020',
    );
    final t1 = KgCrypto.aesEncryptCbcHex('|$dateTime',
        key: '5e4ef500e9597fe004bd09a46d8add98', iv: '04bd09a46d8add98');

    final dataMap = <String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      't1': lite ? t1 : 0,
      't2': lite ? t2 : 0,
      'clienttime_ms': dateTime,
      'mobile': mobile,
      'key': KgSignature.paramsKey(dateTime, lite: lite),
      'pk': KgCrypto.rsaEncryptRawHex(
        jsonEncode({'clienttime_ms': dateTime, 'key': encrypt.key}),
        lite: lite,
      ).toUpperCase(),
      'params': encrypt.str,
    };
    final uid = '${q['userid'] ?? ''}';
    if (uid.isNotEmpty) dataMap['userid'] = uid;
    if (lite) {
      dataMap['dfid'] = dfid;
      dataMap['dev'] = kg.device.dev;
      dataMap['gitversion'] = '5f0b7c4';
    } else {
      dataMap['t3'] = 'MCwwLDAsMCwwLDAsMCwwLDA=';
    }

    final r = await kg.request('/v7/login_by_verifycode',
        baseUrl: 'https://loginserviceretry.kugou.com',
        method: 'POST',
        data: dataMap,
        encryptType: 'android',
        headers: {
          'support-calm': '1',
          'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
        });
    _afterLogin(r, encrypt.key);
    return r;
  }

  /// 用户名密码登录（对应 module/login.js）
  Future<KgResponse> login(
      Map<String, dynamic> q, Map<String, dynamic> d) async {
    final dateNow = DateTime.now().millisecondsSinceEpoch;
    final encrypt = KgCrypto.aesEncryptCbcAuto(jsonEncode({
      'pwd': '${d['password'] ?? ''}',
      'code': '${d['code'] ?? q['code'] ?? ''}',
      'clienttime_ms': dateNow,
    }));
    final dataMap = <String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      'clienttime_ms': dateNow,
      // t1/t2 为酷狗固定常量（与 Node 版一致）
      't1':
          '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d81341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599abeb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b3536380169995693e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac',
      't2':
          '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830cc3be4',
      't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
      'dev': kg.device.dev,
      'username': '${d['username'] ?? q['username'] ?? ''}',
      'params': encrypt.str,
      'pk': KgCrypto.rsaEncryptRawHex(
        jsonEncode({'clienttime_ms': dateNow, 'key': encrypt.key}),
        lite: kg.lite,
      ).toUpperCase(),
    };

    final r = await kg.request('/v9/login_by_pwd',
        method: 'POST',
        data: dataMap,
        encryptType: 'android',
        headers: {'x-router': 'login.user.kugou.com'});
    _afterLogin(r, encrypt.key);
    return r;
  }

  /// 刷新登录态（对应 module/login_token.js）
  Future<KgResponse> loginToken(Map<String, dynamic> q) async {
    final dateNow = DateTime.now().millisecondsSinceEpoch;
    final token = '${q['token'] ?? (kg.token.isNotEmpty ? kg.token : '')}';
    final userid = '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}';
    final lite = kg.lite;
    const key = '90b8382a1bb4ccdcf063102053fd75b8';
    const iv = 'f063102053fd75b8';
    const liteKey = 'c24f74ca2820225badc01946dba4fdf7';
    const liteIv = 'adc01946dba4fdf7';

    final encrypt = KgCrypto.aesEncryptCbcHex(
      jsonEncode({'clienttime': dateNow ~/ 1000, 'token': token}),
      key: lite ? liteKey : key,
      iv: lite ? liteIv : iv,
    );
    final encryptParams = KgCrypto.aesEncryptCbcAuto('{}');
    final pk = KgCrypto.rsaEncryptRawHex(
      jsonEncode({'clienttime_ms': dateNow, 'key': encryptParams.key}),
      lite: lite,
    );
    final t2 = KgCrypto.aesEncryptCbcHex(
      '${kg.device.guid}|0f607264fc6318a92b9e13c65db7cd3c|${kg.device.mac}|${kg.device.dev}|$dateNow',
      key: 'fd14b35e3f81af3817a20ae7adae7020',
      iv: '17a20ae7adae7020',
    );
    // 上游逻辑：cookie.t1 存在时为「t1|dateNow」，否则「|dateNow」
    final t1Plain = kg.t1.isNotEmpty ? '${kg.t1}|$dateNow' : '|$dateNow';
    final t1 = KgCrypto.aesEncryptCbcHex(t1Plain,
        key: '5e4ef500e9597fe004bd09a46d8add98', iv: '04bd09a46d8add98');

    final dataMap = <String, dynamic>{
      'dfid': kg.device.dfid.isNotEmpty ? kg.device.dfid : '-',
      'p3': encrypt,
      'plat': 1,
      't1': lite ? t1 : 0,
      't2': lite ? t2 : 0,
      't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
      'pk': pk,
      'params': encryptParams.str,
      'userid': userid,
      'clienttime_ms': dateNow,
    };
    if (lite) dataMap['dev'] = kg.device.dev;

    final r = await kg.request('/v5/login_by_token',
        baseUrl: 'http://login.user.kugou.com',
        method: 'POST',
        data: dataMap,
        encryptType: 'android');
    _afterLogin(r, encryptParams.key);
    return r;
  }

  /// 二维码 key 生成（对应 module/login_qr_key.js）
  Future<KgResponse> loginQrKey(Map<String, dynamic> q) {
    final type = '${q['type'] ?? ''}';
    return kg.request('/v2/qrcode',
        baseUrl: 'https://login-user.kugou.com',
        method: 'GET',
        encryptType: 'web',
        params: {
          'appid': type == 'web' ? 1014 : 1001,
          'type': 1,
          'plat': 4,
          'qrcode_txt':
              'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=${KgConfig.appid}&',
          'srcappid': _qrSrcappid,
        });
  }

  /// 二维码图片生成（对应 module/login_qr_create.js，本地生成 PNG base64）
  Future<KgResponse> loginQrCreate(Map<String, dynamic> q) async {
    final key = '${q['key'] ?? ''}';
    final url =
        'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=$key';
    final wantImg = '${q['qrimg'] ?? ''}' == '1' || q['qrimg'] == 1;
    final b64 = wantImg ? await _qrPngBase64(url) : '';
    return KgResponse(
      status: 200,
      body: <String, dynamic>{
        'code': 200,
        'status': 200,
        'data': <String, dynamic>{'url': url, 'base64': b64, 'key': key},
      },
    );
  }


  /// 二维码状态检测（对应 module/login_qr_check.js）
  Future<KgResponse> loginQrCheck(Map<String, dynamic> q) async {
    // 直连不像 kapi 会自动加时间戳，这里自行加入以绕过缓存
    final timestamp =
        q['timestamp'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final r = await kg.request('/v2/get_userinfo_qrcode',
        baseUrl: 'https://login-user.kugou.com',
        method: 'GET',
        encryptType: 'web',
        params: {
          'plat': 4,
          'appid': KgConfig.appid,
          'srcappid': _qrSrcappid,
          'qrcode': q['key'],
          'dev': kg.device.dev,
          'timestamp': timestamp,
          '_t': timestamp,
        });
    final data = r.body['data'];
    if (data is Map && '${data['status']}' == '4') {
      final token = '${data['token'] ?? ''}';
      final userid = '${data['userid'] ?? ''}';
      if (token.isNotEmpty) kg.token = token;
      if (userid.isNotEmpty && userid != '0') kg.userid = userid;
    }
    return r;
  }

  /// 用户信息（对应 module/user_detail.js）
  Future<KgResponse> userDetail(Map<String, dynamic> q) async {
    final token = '${q['token'] ?? (kg.token.isNotEmpty ? kg.token : '')}';
    final userid = int.tryParse(
            '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pk = KgCrypto.rsaEncryptRawHex(
      jsonEncode({'token': token, 'clienttime': clienttime}),
      lite: kg.lite,
    ).toUpperCase();
    final resp = await kg.request('/v3/get_my_info',
        method: 'POST',
        params: {'plat': 1},
        data: {
          'visit_time': clienttime,
          'usertype': 1,
          'p': pk,
          'userid': userid,
        },
        encryptType: 'android',
        headers: {'x-router': 'usercenter.kugou.com'});
    // 实测响应无 userid 字段，而上层 AuthRepository 读 data.userid → 回填
    final d = resp.body;
    final inner = d['data'];
    if (inner is Map<String, dynamic>) {
      inner['userid'] = userid.toString();
    }
    return resp;
  }

  /// 获取人机验证信息（对应 module/get_verify_info.js）
  Future<KgResponse> getVerifyInfo(Map<String, dynamic> q) {
    final userid = int.tryParse(
            '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    return kg.request('/verifyservice/v3/get_verify_info',
        method: 'POST',
        encryptType: 'android',
        data: {
          'eventid': q['eventid'],
          'userid': userid,
          'platid': q['platid'] ?? 2,
          'rtype': 1,
          'wasm': 1,
          'i': '',
          'sid': '',
          'edt': '',
        });
  }

  /// 提交人机验证结果（对应 module/verify_user_info.js）
  Future<KgResponse> verifyUserInfo(Map<String, dynamic> d) {
    final vType = int.tryParse('${d['v_type'] ?? 23}') ?? 23;
    final userid = int.tryParse(
            '${d['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    final sid = Uri.decodeComponent('${d['sid'] ?? ''}');
    final edt = Uri.decodeComponent('${d['edt'] ?? ''}');
    var dataMap = <String, dynamic>{
      'eventid': d['eventid'],
      'userid': userid,
      'platid': d['platid'] ?? 2,
      'v_type': vType,
      'wasm': 1,
      'i': '',
      'sid': sid,
      'edt': edt,
    };
    if (vType == 23) {
      final encrypt = KgCrypto.aesEncryptCbcAuto('{}');
      dataMap = {
        ...dataMap,
        'verifycode': Uri.decodeComponent('${d['verifycode'] ?? ''}'),
        'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'key': encrypt.key}),
            lite: kg.lite),
        'params': encrypt.str,
      };
    } else if (vType == 32) {
      final encrypt = KgCrypto.aesEncryptCbcAuto(
          jsonEncode({'code': '${d['verifycode'] ?? ''}'}));
      dataMap = {
        ...dataMap,
        'code': Uri.decodeComponent('${d['verifycode'] ?? ''}'),
        'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'key': encrypt.key}),
            lite: kg.lite),
        'params': encrypt.str,
      };
    }
    return kg.request('/v4/verify_user_info',
        baseUrl: 'https://verifyservice.kugou.com',
        method: 'POST',
        params: {'clientver': 11510},
        data: dataMap,
        encryptType: 'android');
  }

  /// 登录成功后：解密 secu_params 合并进 data，并回写 kg.token / kg.userid
  void _afterLogin(KgResponse r, String tempKey) {
    final body = r.body;
    if (body['status'] != 1) return;
    final data = body['data'];
    if (data is! Map) return;
    final sp = data['secu_params'];
    if (sp is String && sp.isNotEmpty) {
      try {
        final dec = KgCrypto.aesDecryptCbcHex(sp, tempKey);
        if (dec is Map) {
          dec.forEach((k, v) => data['$k'] = v);
        } else if (dec is String && dec.isNotEmpty) {
          data['token'] = dec;
        }
      } catch (e) {
        debugPrint('secu_params 解密', e);
      }
    }
    final token = '${data['token'] ?? ''}';
    final userid = '${data['userid'] ?? ''}';
    if (token.isNotEmpty) kg.token = token;
    if (userid.isNotEmpty && userid != '0') kg.userid = userid;
    final t1 = data['t1']?.toString();
    if (t1 != null && t1.isNotEmpty) kg.t1 = t1;
  }
  /// QR URL → PNG base64（qr_flutter 渲染）
  Future<String> qrPngBase64(String data) async {
    final painter = QrPainter(
      data: data,
      version: QrVersions.auto,
      gapless: true,
    );
    final picData = await painter.toImageData(480);
    return picData == null ? '' : base64Encode(picData.buffer.asUint8List());
  }

}
