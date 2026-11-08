import 'dart:convert';
import '../../../core/foundation/errors.dart' show ApiException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    // 失败返回空串且不落盘：'-' 占位符会被服务端拒绝且永久缓存
    return '';
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
    // V35-A3（第 A 批，P2）：readCredentials 在 Keystore 故障机型
    // （EncryptedSharedPreferences 解密失败，实测常见）会直接抛——
    // 异常逃逸出 authStateProvider build → AsyncError → main 监听
    // 把有凭证用户当匿名清空（静默永久匿名，重启无法自愈）。
    // 边界读取必须防护（第 6/14 条）：失败按「无凭证」降级并留痕。
    final Credentials? cred;
    try {
      cred = await _storage.readCredentials();
    } catch (e, st) {
      debugPrint('[auth] readCredentials failed (keystore?): $e\n$st');
      return null;
    }
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
    } on DioException catch (e) {
      final err = e.error;
      // 网络异常（断网/超时）不得清凭证：返回降级用户，保留登录态
      final networkError = e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout;
      final confirmedInvalid = err is ApiException &&
          _isTokenInvalidCode(err.errorCode, err.message);
      if (!networkError && confirmedInvalid) {
        await logout();
        return null;
      }
      return _degradedUser(cred);
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
      } on DioException catch (e) {
        final err = e.error;
        final confirmedInvalid = err is ApiException &&
            _isTokenInvalidCode(err.errorCode, err.message);
        if (confirmedInvalid) {
          await logout();
          return null;
        }
        return _degradedUser(cred);
      } catch (_) {
        return _degradedUser(cred);
      }
    }
  }

  /// 已知「凭证失效」的 error_code（401 类/token 过期），网络错误绝不算
  bool _isTokenInvalidCode(int code, String message) {
    // A2-09（审查②）：20010 是网关通用「参数缺失/参数错误」码，不专指
    // token 失效——t1 空/dfid='-' 也会返回它。一次参数性失败就把有效会话
    // 清空，用户必须重登。移出名单，参数性失败走 _degradedUser 降级。
    const invalidCodes = {1011, 30791, 401};
    if (invalidCodes.contains(code)) return true;
    return code == -1 && message.contains('token');
  }

  /// 弱网降级：用缓存资料构造用户，凭证保持不动
  AuthUser _degradedUser(Credentials cred) {
    AccountRecord? record;
    try {
      record = AccountManager.instance.currentAccount;
    } catch (_) {}
    return AuthUser(
      userid: cred.userId,
      token: cred.token,
      nickname: record?.nickname ?? '',
      avatar: record?.avatar ?? '',
    );
  }

  /// 退出当前账号（保留多账号记录可选）
  Future<void> logout({bool removeAccount = false}) async {
    final cred = await _storage.readCredentials();
    if (removeAccount && cred != null) {
      await AccountManager.instance.remove(cred.userId);
      try {
        await _storage.deleteAccountToken(cred.userId);
      } catch (_) {}
    } else {
      // 保留账号列表，但清掉当前账号指针，避免「已退出」仍可静默切回旧账号
      await AccountManager.instance.clearCurrent();
    }
    // B-11（第6批①，P1）：普通登出也必须删除该账号的切换 token——
    // 此前只在 removeAccount 时删，共享设备上「退出登录」后仍可
    // 无密码切回旧账号（安全残留）。dfid 一并清除（写入/清除对称）。
    await _storage.clearCredentials(userid: cred?.userId);
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

    // V399-B1：登录成功后的落盘链并行化——dfid 获取（可能打一次网络）
    // 与多账号 token 写入、账号 upsert、设置盒写入相互独立，此前串行
    // await 使登录页停留时间叠加四段延迟（用户反馈「登录大延迟」）。
    // saveCredentials 必须先完成（api.setCredentials 依赖它的语义顺序，
    // 且登录态事实源），其余四项 Future.wait 并行。
    final dfidFuture = getDfid();
    final auth = d['auth']?.toString();
    // 多账号 token / 设置盒写入不依赖 dfid，立即并行发起
    final sideFutures = <Future<void>>[
      _storage.saveAccountToken(userid: userid, token: token),
      AccountManager.instance.upsert(AccountRecord(
        userid: userid,
        token: token,
        nickname: nickname,
        avatar: avatar,
        t1: t1,
      )),
      () async {
        try {
          final box = Hive.box('settings');
          await box.put('nickname', nickname);
          await box.put('avatar', avatar);
        } catch (_) {}
      }(),
    ];
    final dfid = await dfidFuture;
    await _storage.saveCredentials(
      token: token,
      userId: userid,
      t1: t1,
      auth: auth,
      dfid: dfid,
    );
    await _api.setCredentials(
      token: token,
      userid: userid,
      t1: t1,
      auth: auth,
      dfid: dfid,
    );
    // 副产物写入失败不阻塞登录成功（与原 catch (_) {} 语义一致），
    // 但必须留痕（第 9 条）。
    try {
      await Future.wait(sideFutures);
    } catch (e) {
      debugPrint('[auth] login side-effect write failed: $e');
    }

    return AuthUser(
      userid: userid,
      token: token,
      nickname: nickname,
      avatar: avatar,
    );
  }

  /// 从 DioException 中提取原始响应体
  ///
  /// A2-01（审查②）：直连层的 DioException 不带 response（只有 .error），
  /// 此处从包装的 ApiException 中兜底取 ssaCode/响应体，否则密码登录
  /// 命中 20028 时 ssaCode 恒为空，验证页永不弹出。
  Map<String, dynamic>? _errorResponseData(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    // 直连包装的异常：从 ApiException 兜底
    final err = e.error;
    if (err is ApiException) {
      if (err.ssaCode != null && err.ssaCode!.isNotEmpty) {
        return {'ssaCode': err.ssaCode};
      }
    }
    return null;
  }

  KugouApiClient get api => _api;

  /// 读取指定账号的 token（SecureStorage，按 userid）
  Future<String?> getAccountToken(String userid) =>
      _storage.readAccountToken(userid);
}
