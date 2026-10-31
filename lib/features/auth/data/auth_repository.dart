import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/storage/secure_storage.dart';
import 'account_manager.dart';

/// 登录用户
class AuthUser {
  const AuthUser({
    required this.userid,
    required this.token,
    this.nickname = '',
    this.avatar = '',
  });

  final String userid;
  final String token;
  final String nickname;
  final String avatar;
}

/// 触发人机验证异常（error_code = 20028）
class CaptchaRequiredException implements Exception {
  CaptchaRequiredException(this.ssaCode, this.message);
  final String ssaCode;
  final String message;
  @override
  String toString() => 'CaptchaRequiredException($ssaCode): $message';
}

/// 短信登录：一个手机号归属多个账号
class MultiAccountException implements Exception {
  MultiAccountException(this.users);
  final List<Map<String, dynamic>> users;
}

/// 人机验证信息
class VerifyInfo {
  const VerifyInfo({
    required this.vType,
    this.txappid = '',
    this.mobile = '',
    this.raw = const {},
  });

  final int vType; // 23 = 腾讯 TCaptcha，32 = 二次短信，38 = 其它类型
  final String txappid;
  final String mobile;
  final Map<String, dynamic> raw;
}

/// 二维码登录结果
class QrKeyResult {
  const QrKeyResult({required this.key, required this.qrImgBase64});
  final String key;
  final String qrImgBase64;
}

/// 二维码轮询状态：0过期 1待扫 2待确认 4成功
class QrCheckResult {
  const QrCheckResult({required this.status, this.token, this.userid, this.t1});
  final int status;
  final String? token;
  final String? userid;
  final String? t1;
}

class AuthRepository {
  AuthRepository({KugouApiClient? api, SecureStorage? storage})
      : _api = api ?? KugouApiClient(),
        _storage = storage ?? SecureStorage.instance;

  final KugouApiClient _api;
  final SecureStorage _storage;

  static const captchaErrorCode = 20028;

  /// 获取设备 dfid
  Future<String> getDfid() async {
    final existing = await _storage.readDfid();
    if (existing != null && existing.isNotEmpty) return existing;
    try {
      final res = await _api.get('/register/dev');
      final dfid = '${res['data']?['dfid'] ?? ''}';
      if (dfid.isNotEmpty) {
        await _storage.saveDfid(dfid);
        return dfid;
      }
    } catch (_) {}
    return '-';
  }

  /// 发送短信验证码
  Future<void> sendSmsCode(String mobile) async {
    await _api.get('/captcha/sent', query: {'mobile': mobile});
  }

  /// 短信验证码登录
  /// [userid] 多账号归属时指定要登录的账号
  Future<AuthUser> loginBySms({
    required String mobile,
    required String code,
    String? userid,
  }) async {
    Map<String, dynamic> res;
    try {
      res = await _api.get('/login/cellphone', query: {
        'mobile': mobile,
        'code': code,
        if (userid != null) 'userid': userid,
      });
    } on DioException catch (e) {
      final err = e.error;
      if (err is ApiException) {
        // 多账号归属，返回用户列表供选择
        if (err.errorCode == 20034 || err.message.contains('多个')) {
          final data = _errorResponseData(e);
          final list = data?['data']?['users'] ?? data?['users'];
          if (list is List) {
            throw MultiAccountException(
              list.whereType<Map<String, dynamic>>().toList(),
            );
          }
        }
        rethrow;
      }
      rethrow;
    }
    return _handleLoginSuccess(res);
  }

  /// 账号密码登录；error_code=20028 抛 [CaptchaRequiredException]
  Future<AuthUser> loginByPassword({
    required String username,
    required String password,
  }) async {
    try {
      final res = await _api.post('/login', {
        'username': username,
        'password': password,
      });
      return await _handleLoginSuccess(res);
    } on DioException catch (e) {
      final err = e.error;
      if (err is ApiException && err.errorCode == captchaErrorCode) {
        final data = _errorResponseData(e);
        final ssaCode = '${data?['ssaCode'] ?? data?['data']?['ssaCode'] ?? data?['ssa_code'] ?? ''}';
        throw CaptchaRequiredException(ssaCode, err.message);
      }
      rethrow;
    }
  }

  /// 获取人机验证信息
  Future<VerifyInfo> getVerifyInfo(String eventid) async {
    final res = await _api.get('/get/verify/info', query: {'eventid': eventid});
    final d = (res['data'] as Map<String, dynamic>?) ?? {};
    return VerifyInfo(
      vType: int.tryParse('${d['v_type'] ?? 0}') ?? 0,
      txappid: '${d['txappid'] ?? d['appid'] ?? ''}',
      mobile: '${d['mobile'] ?? ''}',
      raw: d,
    );
  }

  /// 提交人机验证结果；eventid 直接使用 20028 返回的 ssaCode。
  /// 部署版不提供 /sidedt，不额外请求 sid / edt。
  Future<void> submitVerify({
    required String eventid,
    required int vType,
    required String verifycode,
  }) async {
    if (vType != 23 && vType != 32) {
      throw ApiException(-1, '暂不支持的验证类型（v_type=$vType）');
    }
    await _api.post('/verify/user/info', {
      'eventid': eventid,
      'v_type': vType,
      'verifycode': verifycode,
    });
  }

  /// 生成 TCaptcha verifycode
  static String buildTencentVerifyCode({
    required String ticket,
    required String randstr,
    required String txappid,
  }) {
    final payload = jsonEncode({
      'ticket': ticket,
      'randstr': randstr,
      'txappid': txappid,
    });
    return Uri.encodeComponent('KGCodeTX|$payload');
  }

  /// 获取扫码登录 key 与二维码图
  Future<QrKeyResult> getQrKey() async {
    final res = await _api.get('/login/qr/key');
    final d = (res['data'] as Map<String, dynamic>?) ?? {};
    final key = '${d['qrcode'] ?? ''}';
    var img = '${d['qrcode_img'] ?? ''}';
    // 部分服务返回列表或其他字段
    if (key.isEmpty) {
      final res2 = await _api.get('/login/qr/create', query: {'qrimg': 1});
      final d2 = (res2['data'] as Map<String, dynamic>?) ?? {};
      return QrKeyResult(
        key: '${d2['key'] ?? d2['qrcode'] ?? ''}',
        qrImgBase64: '${d2['qrcode_img'] ?? d2['base64'] ?? ''}',
      );
    }
    if (img.isEmpty) {
      final res2 = await _api
          .get('/login/qr/create', query: {'key': key, 'qrimg': 1});
      final d2 = (res2['data'] as Map<String, dynamic>?) ?? {};
      img = '${d2['qrcode_img'] ?? d2['base64'] ?? ''}';
    }
    return QrKeyResult(key: key, qrImgBase64: img);
  }

  /// 轮询二维码状态
  Future<QrCheckResult> checkQr(String key) async {
    final res = await _api.get('/login/qr/check', query: {
      'key': key,
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    final d = (res['data'] as Map<String, dynamic>?) ?? res;
    final status = int.tryParse('${d['status'] ?? d['error_code'] ?? 1}') ?? 1;
    return QrCheckResult(
      status: status,
      token: d['token']?.toString(),
      userid: d['userid']?.toString(),
      t1: d['t1']?.toString(),
    );
  }

  /// 使用 token + userid 刷新登录态
  Future<AuthUser> loginByToken({
    required String token,
    required String userid,
  }) async {
    final res = await _api.get('/login/token', query: {
      'token': token,
      'userid': userid,
    });
    return _handleLoginSuccess(res, fallbackToken: token, fallbackUserid: userid);
  }

  /// 获取用户信息（验证登录有效性）
  Future<AuthUser> getUserDetail() async {
    final res = await _api.get('/user/detail');
    final d = (res['data'] as Map<String, dynamic>?) ?? {};
    return AuthUser(
      userid: '${d['userid'] ?? ''}',
      token: '',
      nickname: '${d['nickname'] ?? ''}',
      avatar: '${d['pic'] ?? d['avatar'] ?? ''}',
    );
  }

  /// 启动时恢复凭证并静默刷新
  Future<AuthUser?> restoreSession() async {
    final cred = await _storage.readCredentials();
    if (cred == null) return null;
    await _api.setCredentials(
      token: cred.token,
      userid: cred.userId,
      t1: cred.t1,
      auth: cred.auth,
      dfid: cred.dfid,
    );
    try {
      final user =
          await loginByToken(token: cred.token, userid: cred.userId);
      return user;
    } catch (_) {
      // 静默刷新失败，尝试用现有凭证请求用户信息确认是否仍有效
      try {
        final detail = await getUserDetail();
        return AuthUser(
          userid: cred.userId,
          token: cred.token,
          nickname: detail.nickname,
          avatar: detail.avatar,
        );
      } catch (_) {
        await logout();
        return null;
      }
    }
  }

  /// 退出当前账号（保留多账号记录可选）
  Future<void> logout({bool removeAccount = false}) async {
    final cred = await _storage.readCredentials();
    if (removeAccount && cred != null) {
      await AccountManager.instance.remove(cred.userId);
    }
    await _storage.clearCredentials();
    await _api.clearCredentials();
  }

  /// 解析登录成功响应并持久化
  Future<AuthUser> _handleLoginSuccess(
    Map<String, dynamic> res, {
    String? fallbackToken,
    String? fallbackUserid,
  }) async {
    final d = (res['data'] as Map<String, dynamic>?) ?? res;
    final token = '${d['token'] ?? fallbackToken ?? ''}';
    final userid = '${d['userid'] ?? fallbackUserid ?? ''}';
    final t1 = d['t1']?.toString();
    final nickname = '${d['nickname'] ?? ''}';
    final avatar = '${d['pic'] ?? d['avatar'] ?? ''}';
    if (token.isEmpty || userid.isEmpty) {
      throw ApiException(-1, '登录响应缺少 token 或 userid');
    }

    final dfid = await getDfid();
    await _storage.saveCredentials(
      token: token,
      userId: userid,
      t1: t1,
      dfid: dfid,
    );
    await _api.setCredentials(
      token: token,
      userid: userid,
      t1: t1,
      dfid: dfid,
    );

    // 写入多账号列表
    await AccountManager.instance.upsert(AccountRecord(
      userid: userid,
      token: token,
      nickname: nickname,
      avatar: avatar,
      t1: t1,
    ));

    // 写入设置盒（供设置页显示当前账号）
    try {
      final box = Hive.box('settings');
      await box.put('nickname', nickname);
      await box.put('avatar', avatar);
    } catch (_) {}

    return AuthUser(
      userid: userid,
      token: token,
      nickname: nickname,
      avatar: avatar,
    );
  }

  /// 从 DioException 中提取原始响应体
  Map<String, dynamic>? _errorResponseData(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  KugouApiClient get api => _api;
}
