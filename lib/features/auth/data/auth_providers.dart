import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/direct/kg_providers.dart';
import '../../../app/di.dart';
import '../../../core/storage/secure_storage.dart';
import 'auth_repository.dart';
import 'account_manager.dart';

/// 认证仓库
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(api: ref.watch(kugouApiClientProvider));
});

/// 当前登录用户状态
final authStateProvider =
    AsyncNotifierProvider<AuthStateNotifier, AuthUser?>(
  AuthStateNotifier.new,
);

class AuthStateNotifier extends AsyncNotifier<AuthUser?> {
  /// v5.4：乐观恢复的后台刷新必须检查 notifier 存活（第 18/20 条）。
  bool _disposed = false;

  @override
  Future<AuthUser?> build() async {
    _disposed = false;
    await AccountManager.instance.init();
    // ⚠️ 必须**先补 t1** 再 restoreSession：
    // 直连 /login/token 的签名用 kg.t1，若此刻为空则刷新必然失败
    // （原本要等 authState 变化后才补，而那已经晚于这次请求了）。
    Credentials? cred;
    try {
      cred = await SecureStorage.instance.readCredentials();
      if (cred?.t1 != null && cred!.t1!.isNotEmpty) {
        ref.read(kgClientProvider).t1 = cred.t1!;
      }
    } catch (_) {
      // 读不到凭证就按无 t1 继续，后续有降级路径
    }
    // v5.4 乐观恢复：本地凭证立即渲染，loginByToken 网络刷新转后台。
    if (cred != null && cred.token.isNotEmpty && cred.userId.isNotEmpty) {
      unawaited(Future<void>(() async {
        try {
          final fresh =
              await ref.read(authRepositoryProvider).restoreSession();
          if (fresh != null && !_disposed) setUser(fresh);
        } catch (_) {
          // 网络失败保留乐观登录态（第 11 条：降级有退出条件）
        }
      }));
      return AuthUser(userid: cred.userId, token: cred.token);
    }
    return ref.read(authRepositoryProvider).restoreSession();
  }

  void setUser(AuthUser? user) => state = AsyncData(user);

  Future<void> logout({bool removeAccount = false}) async {
    await ref.read(authRepositoryProvider).logout(removeAccount: removeAccount);
    try {
      final box = Hive.box('settings');
      await box.delete('nickname');
      await box.delete('avatar');
    } catch (_) {}
    state = const AsyncData(null);
  }

  /// 切换到另一个账号（token 从 SecureStorage 按 userid 读取）。
  ///
  /// 顺序：peek（只查）→ 取 token → 登录（可能失败）→ 成功后才 switchTo。
  /// 避免中途失败时 AccountManager 指针已切而登录态仍是旧账号（F3）。
  Future<void> switchAccount(String userid) async {
    final record = AccountManager.instance.peek(userid);
    if (record == null) return;
    final token = await ref.read(authRepositoryProvider).getAccountToken(userid);
    if (token == null || token.isEmpty) {
      // 该账号无可用 token（未登录过或已被清理），需要重新登录
      throw StateError('该账号需要重新登录');
    }
    final repo = ref.read(authRepositoryProvider);
    final user = await repo.loginByToken(token: token, userid: userid);
    // 登录成功后才切指针+广播（loginByToken → _handleLoginSuccess → upsert
    // 内部已会设 current，switchTo 保留显式切换语义）
    await AccountManager.instance.switchTo(userid);
    state = AsyncData(user);
  }
}

/// 登录操作控制器（处理 loading / error 状态）
final loginControllerProvider =
    AsyncNotifierProvider<LoginController, void>(LoginController.new);

class LoginController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  void _finish(AuthUser user) {
    ref.read(authStateProvider.notifier).setUser(user);
    state = const AsyncData(null);
  }

  Future<AuthUser> loginBySms({
    required String mobile,
    required String code,
    String? userid,
  }) async {
    state = const AsyncLoading();
    try {
      final user =
          await _repo.loginBySms(mobile: mobile, code: code, userid: userid);
      _finish(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser> loginByPassword({
    required String username,
    required String password,
  }) async {
    state = const AsyncLoading();
    try {
      final user =
          await _repo.loginByPassword(username: username, password: password);
      _finish(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser> loginByQrToken({
    required String token,
    required String userid,
  }) async {
    state = const AsyncLoading();
    try {
      final user = await _repo.loginByToken(token: token, userid: userid);
      _finish(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }
}
