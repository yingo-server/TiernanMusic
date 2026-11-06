import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/providers.dart' show kugouApiClientProvider;
import '../../../core/utils/friendly_error.dart';
import '../../../core/utils/toast.dart';
import '../../../l10n/l10n.dart';
import '../data/auth_providers.dart';
import '../data/auth_repository.dart';
import 'captcha_page.dart';

/// 登录方式：短信 / 密码 / 二维码。
enum _LoginMode { sms, password, qr }

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late _LoginMode _mode = _LoginMode.sms;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // 切换登录方式时重建，让 QR Tab 通过 active 参数启停轮询
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onLoginSuccess() {
    // V34-UI-05（P3）：登录成功返回来源页——登录页总经 push 进入，
    // 直接 pop 回 push 来源（库页「去登录」→ 登录 → 回库页，任务流 3
    // 不再被强制甩到首页）；pop 失败（理论不可达）时回落 /home。
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else if (mounted) {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 登录是二级页面：左上角提供返回按钮（≥48dp 触控目标 + tooltip）
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: context.l10n.back,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            const SizedBox(height: 8),
            // Logo 区：圆角图标 + 标题 + 副标题
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, scheme.tertiary],
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.graphic_eq_rounded,
                  size: 44, color: Colors.white),
            ),
            const SizedBox(height: 16),
            // 大标题层级：M3 顶层页用 headlineMedium / displaySmall
            Text(context.l10n.appName,
                style: textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              context.l10n.unofficialClient,
              style:
                  textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            // 登录方式切换：M3 用 SegmentedButton（互斥模式），比 TabBar 更贴合
            // 「在少量选项间做单选」的语义。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_LoginMode>(
                  segments: [
                    ButtonSegment<_LoginMode>(
                      value: _LoginMode.sms,
                      label: Text(context.l10n.smsLogin),
                    ),
                    ButtonSegment<_LoginMode>(
                      value: _LoginMode.password,
                      label: Text(context.l10n.passwordLogin),
                    ),
                    ButtonSegment<_LoginMode>(
                      value: _LoginMode.qr,
                      label: Text(context.l10n.qrLogin),
                    ),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    final mode = selection.first;
                    if (mode == _mode) return;
                    setState(() => _mode = mode);
                    _tabController.animateTo(mode.index);
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _SmsLoginTab(onSuccess: _onLoginSuccess),
                  _PasswordLoginTab(onSuccess: _onLoginSuccess),
                  _QrLoginTab(
                    onSuccess: _onLoginSuccess,
                    active: _mode == _LoginMode.qr,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 显示错误提示（项目统一用 Toast，避免 Snackbar 刷屏）
void _showError(BuildContext context, Object e) {
  // A2-07（审查②）：直连层抛 DioException(error: ApiException)，
  // 必须经 unwrapApi 解包，否则落到 '$e' 显示技术文本。
  final api = unwrapApi(e);
  final msg = api?.message ??
      (e is CaptchaRequiredException ? e.message : friendlyError(e));
  Toast.show(context, msg.isEmpty ? context.l10n.operationFailed : msg);
}

// ---------------------------------------------------------------------------
// 短信登录
// ---------------------------------------------------------------------------
class _SmsLoginTab extends ConsumerStatefulWidget {
  const _SmsLoginTab({required this.onSuccess});
  final VoidCallback onSuccess;

  @override
  ConsumerState<_SmsLoginTab> createState() => _SmsLoginTabState();
}

class _SmsLoginTabState extends ConsumerState<_SmsLoginTab> {
  final _mobileCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _mobileCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  bool get _mobileValid =>
      RegExp(r'^1\d{10}$').hasMatch(_mobileCtrl.text.trim());

  Future<void> _sendCode() async {
    final mobile = _mobileCtrl.text.trim();
    if (!_mobileValid) {
      _showError(context, context.l10n.phoneInvalid);
      return;
    }
    try {
      await ref.read(authRepositoryProvider).sendSmsCode(mobile);
      if (!mounted) return;
      Toast.show(context, context.l10n.smsCodeSent);
      setState(() => _countdown = 60);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_countdown <= 1) {
          t.cancel();
          setState(() => _countdown = 0);
        } else {
          setState(() => _countdown--);
        }
      });
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  Future<void> _login({String? userid}) async {
    final mobile = _mobileCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (!_mobileValid) {
      _showError(context, context.l10n.phoneInvalid);
      return;
    }
    if (code.isEmpty) {
      _showError(context, context.l10n.codeInvalid);
      return;
    }
    setState(() => _loading = true);
    try {
      await ref
          .read(loginControllerProvider.notifier)
          .loginBySms(mobile: mobile, code: code, userid: userid);
      widget.onSuccess();
    } on MultiAccountException catch (e) {
      if (!mounted) return;
      final chosen = await _showAccountPicker(e.users);
      if (chosen != null && mounted) {
        await _login(userid: chosen);
      }
    } catch (e) {
      if (mounted) _showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 多账号归属选择
  Future<String?> _showAccountPicker(List<Map<String, dynamic>> users) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(context.l10n.selectAccount,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              // M3 规范：长列表必须 ListView.builder，不用 shrinkWrap。
              Expanded(
                child: ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (_, i) {
                    final u = users[i];
                    final userid = '${u['userid'] ?? u['user_id'] ?? ''}';
                    final nickname =
                        '${u['nickname'] ?? u['name'] ?? context.l10n.account + ' $userid'}';
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(nickname),
                      subtitle: Text('ID: $userid'),
                      onTap: () => Navigator.pop(ctx, userid),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _mobileCtrl,
          keyboardType: TextInputType.phone,
          maxLength: 11,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: InputDecoration(
            labelText: context.l10n.phoneNumber,
            hintText: context.l10n.phoneHintCn,
            prefixIcon: const Icon(Icons.phone_iphone),
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofillHints: const [AutofillHints.oneTimeCode],
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.l10n.verificationCode,
                  prefixIcon: const Icon(Icons.pin_outlined),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 次要操作：FilledButton.tonal（发送验证码是辅助动作）
            FilledButton.tonal(
              onPressed: _countdown > 0 ? null : _sendCode,
              child: Text(_countdown > 0 ? context.l10n.resendIn(_countdown) : context.l10n.sendSmsCode),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // 主操作：FilledButton + 内联 CircularProgressIndicator
        FilledButton(
          onPressed: _loading ? null : () => _login(),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.login),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 密码登录
// ---------------------------------------------------------------------------
class _PasswordLoginTab extends ConsumerStatefulWidget {
  const _PasswordLoginTab({required this.onSuccess});
  final VoidCallback onSuccess;

  @override
  ConsumerState<_PasswordLoginTab> createState() => _PasswordLoginTabState();
}

class _PasswordLoginTabState extends ConsumerState<_PasswordLoginTab> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      _showError(context, context.l10n.usernamePasswordRequired);
      return;
    }
    setState(() => _loading = true);
    try {
      await ref
          .read(loginControllerProvider.notifier)
          .loginByPassword(username: username, password: password);
      widget.onSuccess();
    } on CaptchaRequiredException catch (e) {
      if (!mounted) return;
      if (e.ssaCode.isEmpty) {
        _showError(context, e);
      } else {
        final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CaptchaPage(
            ssaCode: e.ssaCode,
            api: ref.read(kugouApiClientProvider),
          ),
        ));
        // 验证成功后重试原登录请求
        if (ok == true && mounted) {
          await _login();
          return;
        }
      }
    } catch (e) {
      if (mounted) _showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _usernameCtrl,
          decoration: InputDecoration(
            labelText: context.l10n.usernameLabel,
            prefixIcon: const Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: context.l10n.password,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                  _obscure ? Icons.visibility_off : Icons.visibility),
              tooltip: _obscure
                  ? context.l10n.showPassword
                  : context.l10n.hidePassword,
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) {
            if (!_loading) _login();
          },
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _loading ? null : _login,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.login),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 二维码登录
// ---------------------------------------------------------------------------
class _QrLoginTab extends ConsumerStatefulWidget {
  const _QrLoginTab({required this.onSuccess, this.active = true});
  final VoidCallback onSuccess;

  /// 当前 Tab 是否可见；false 时暂停二维码轮询
  final bool active;

  @override
  ConsumerState<_QrLoginTab> createState() => _QrLoginTabState();
}

class _QrLoginTabState extends ConsumerState<_QrLoginTab>
    with AutomaticKeepAliveClientMixin {
  String? _key;
  String? _qrBase64;
  int _status = 1; // 0过期 1待扫 2待确认 4成功
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadQr();
  }

  @override
  void didUpdateWidget(covariant _QrLoginTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active && _status != 0 && _status != 4) {
        _startPolling();
      } else {
        _pollTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadQr() async {
    _pollTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _status = 1;
    });
    try {
      final qr = await ref.read(authRepositoryProvider).getQrKey();
      if (!mounted) return;
      setState(() {
        _key = qr.key;
        _qrBase64 = qr.qrImgBase64;
        _loading = false;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      // P3 修复：与本页 _showError 口径统一——'$e' 技术串不得上屏（第 9 条）
      setState(() {
        _loading = false;
        _error = context.l10n.qrLoadFailed(friendlyError(e));
      });
    }
  }

  /// 自驱动轮询链：上次请求完成后再排下一次，避免慢网络下请求重叠
  void _startPolling() {
    _pollTimer?.cancel();
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(seconds: 3), _pollOnce);
  }

  Future<void> _pollOnce() async {
    if (!mounted || !widget.active) return;
    await _checkOnce();
    if (mounted && _status != 0 && _status != 4) {
      _scheduleNextPoll();
    }
  }

  Future<void> _checkOnce() async {
    final key = _key;
    if (key == null || !mounted) return;
    try {
      final res = await ref.read(authRepositoryProvider).checkQr(key);
      if (!mounted) return;
      setState(() => _status = res.status);
      if (res.status == 4) {
        _pollTimer?.cancel();
        // status==4 只表示扫码成功，token 换登录态仍可能失败，必须提示
        try {
          await ref.read(loginControllerProvider.notifier).loginByQrToken(
                token: res.token ?? '',
                userid: res.userid ?? '',
              );
          widget.onSuccess();
        } catch (e) {
          if (mounted) _showError(context, e);
        }
      } else if (res.status == 0) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // 轮询失败忽略，下次再试
    }
  }

  String get _statusText => switch (_status) {
        0 => context.l10n.qrExpired,
        2 => context.l10n.qrScanSuccess,
        4 => context.l10n.loginSuccess,
        _ => context.l10n.qrScanHint,
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.all(16),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: KeyedSubtree(
                key: ValueKey('qr-${_loading}-$_status-$_qrBase64?.length'),
                child: _buildQrContent(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // 状态提示：AnimatedSwitcher 平滑过渡
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_status == 2)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.check_circle,
                    color: scheme.primary, size: 20),
              ),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _error ?? _statusText,
                  key: ValueKey(_error ?? _statusText),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
          ],
        ),
        if (_status == 0 || _error != null) ...[
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _loadQr,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.refreshQr),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQrContent() {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }
    final b64 = _qrBase64;
    if (_error != null || b64 == null || b64.isEmpty) {
      // 错误态用图标 + 明确的刷新入口（error 色）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _loadQr,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(context.l10n.refreshQr),
            ),
          ],
        ),
      );
    }
    try {
      // 兼容 data:image/png;base64, 前缀
      final pure = b64.contains(',') ? b64.split(',').last : b64;
      final bytes = base64Decode(pure);
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bytes, fit: BoxFit.contain),
          if (_status == 0)
            Container(
              color: Colors.black87,
              alignment: Alignment.center,
              child: Text(context.l10n.qrExpiredShort,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white)),
            ),
        ],
      );
    } catch (_) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _loadQr,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(context.l10n.refreshQr),
            ),
          ],
        ),
      );
    }
  }
}
