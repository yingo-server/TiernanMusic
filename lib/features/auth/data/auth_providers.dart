import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/providers.dart';
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
  @override
  Future<AuthUser?> build() async {
    await AccountManager.instance.init();
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
