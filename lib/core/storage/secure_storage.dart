import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  SecureStorage._();
  static final instance = SecureStorage._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kToken = 'token';
  static const _kUserId = 'userid';
  static const _kT1 = 't1';
  static const _kAuth = 'auth';
  static const _kDfid = 'dfid';

  Future<void> saveCredentials({
    required String token,
    required String userId,
    String? t1,
    String? auth,
    String? dfid,
  }) async {
    // C-03（审查②）：null 必须**删除**旧键——切号时新响应常不带 t1/auth，
    // 保留旧值会造成 A 账号票据配 B 账号 token 的串号。
    final ops = <Future<void>>[
      _storage.write(key: _kToken, value: token),
      _storage.write(key: _kUserId, value: userId),
      if (t1 != null)
        _storage.write(key: _kT1, value: t1)
      else
        _storage.delete(key: _kT1),
      if (auth != null)
        _storage.write(key: _kAuth, value: auth)
      else
        _storage.delete(key: _kAuth),
      if (dfid != null)
        _storage.write(key: _kDfid, value: dfid)
      else
        _storage.delete(key: _kDfid),
    ];
    await Future.wait(ops);
  }

  Future<Credentials?> readCredentials() async {
    final token = await _storage.read(key: _kToken);
    final userId = await _storage.read(key: _kUserId);
    if (token == null || userId == null) return null;
    return Credentials(
      token: token,
      userId: userId,
      t1: await _storage.read(key: _kT1),
      auth: await _storage.read(key: _kAuth),
      dfid: await _storage.read(key: _kDfid),
    );
  }

  /// B-11（第6批①，P1）：登出必须清干净当前会话凭证 + dfid + 账号 token
  ///（第 5 条对称性；第 20 条写入/清除对称）。
  /// 此前只删 4 个键：dfid 残留（下次登录签名维度错乱）、
  /// acct_token_<userid> 残留（退出后仍可无密码切回该账号，
  /// 共享设备/转手设备场景等于账号仍处于登录态）。
  /// [userid] 提供时同时删除该账号的切换 token。
  Future<void> clearCredentials({String? userid}) async {
    await Future.wait([
      _storage.delete(key: _kToken),
      _storage.delete(key: _kUserId),
      _storage.delete(key: _kT1),
      _storage.delete(key: _kAuth),
      _storage.delete(key: _kDfid),
      if (userid != null && userid.isNotEmpty)
        _storage.delete(key: '$_kAcctTokenPrefix$userid'),
    ]);
  }

  Future<void> saveDfid(String dfid) =>
      _storage.write(key: _kDfid, value: dfid);

  Future<String?> readDfid() => _storage.read(key: _kDfid);

  // ----- 多账号 token（按 userid 存取，替代 Hive accounts 盒明文存储）-----

  static const _kAcctTokenPrefix = 'acct_token_';

  Future<void> saveAccountToken({
    required String userid,
    required String token,
  }) =>
      _storage.write(key: '$_kAcctTokenPrefix$userid', value: token);

  Future<String?> readAccountToken(String userid) =>
      _storage.read(key: '$_kAcctTokenPrefix$userid');

  Future<void> deleteAccountToken(String userid) =>
      _storage.delete(key: '$_kAcctTokenPrefix$userid');
}

class Credentials {
  Credentials({
    required this.token,
    required this.userId,
    this.t1,
    this.auth,
    this.dfid,
  });
  final String token;
  final String userId;
  final String? t1;
  final String? auth;
  final String? dfid;
}
