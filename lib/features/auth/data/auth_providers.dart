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

  /// 切换到另一个账号
  Future<void> switchAccount(String userid) async {
    final record = await AccountManager.instance.switchTo(userid);
    if (record == null) return;
    final repo = ref.read(authRepositoryProvider);
    final user = await repo.loginByToken(
      token: record.token,
      userid: record.userid,
    );
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
