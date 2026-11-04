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
    await Future.wait([
      _storage.write(key: _kToken, value: token),
      _storage.write(key: _kUserId, value: userId),
      // C-03（审查②）：null 必须**删除**旧键——切号时新响应常不带 t1/auth，
      // 保留旧值会造成 A 账号票据配 B 账号 token 的串号。
      if (t1 != null) { await _storage.write(key: _kT1, value: t1); } else { await _storage.delete(key: _kT1); }
      if (auth != null) { await _storage.write(key: _kAuth, value: auth); } else { await _storage.delete(key: _kAuth); }
      if (dfid != null) { await _storage.write(key: _kDfid, value: dfid); } else { await _storage.delete(key: _kDfid); }
    ]);
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

  Future<void> clearCredentials() async {
    await Future.wait([
      _storage.delete(key: _kToken),
      _storage.delete(key: _kUserId),
      _storage.delete(key: _kT1),
      _storage.delete(key: _kAuth),
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
