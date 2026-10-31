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
  static const _kAccounts = 'accounts'; // JSON list of {userid, token, nickname, avatar}

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
      if (t1 != null) _storage.write(key: _kT1, value: t1),
      if (auth != null) _storage.write(key: _kAuth, value: auth),
      if (dfid != null) _storage.write(key: _kDfid, value: dfid),
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
