import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/direct/kg_providers.dart';
import '../../../core/utils/toast.dart';
import '../../../l10n/l10n.dart';
import '../data/captcha_types.dart';
import '../data/verification_service.dart';

/// 人机验证页（全屏）
///
/// 流程（依据 KuGouMusicApi issue #206）：
/// 1. 业务请求返回 20028，从 body.ssaCode 或响应头 ssa-code 拿到事件 id
/// 2. `/get/verify/info?eventid=<ssaCode>` 拿 v_type 与 url（url 前缀决定验证码类型）
/// 3. 按类型产出 verifycode，连同 sid/edt 提交 `/verify/user/info`
/// 4. 成功后由调用方重试原请求
///
/// 返回 `true` 表示验证通过。
class CaptchaPage extends ConsumerStatefulWidget {
  const CaptchaPage({
    super.key,
    required this.ssaCode,
    required this.api,
    this.typeHint,
    this.onVerified,
  });

  /// 20028 返回的 ssaCode（即 eventid）
  final String ssaCode;
  final KugouApiClient api;

  /// 可选：调用方已从响应头拿到的 ssaCode 之外的类型提示
  final CaptchaType? typeHint;

  /// 验证成功后可在页内重试原请求；返回 true 表示重试成功可关闭
  final Future<bool> Function()? onVerified;

  @override
  ConsumerState<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends ConsumerState<CaptchaPage> {
  late final VerificationService _service =
      VerificationService(
          widget.api, ref.read(kgClientProvider));

  VerifySession? _session;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  /// 腾讯验证码 WebView 是否就绪
  bool _webViewReady = false;
  String? _txAppId;

  final _smsCodeCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _smsCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await _service.getVerifyInfo(widget.ssaCode);
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
        // 腾讯验证需要 txappid，从 verifyUrl 或 session
        _txAppId = _extractTxAppId(session);
      });
    } catch (e) {
      if (!mounted) return;
      // V37-01（QUALITY_STANDARD 第 9 条 + v34_review_2/A3/C2 报告）：'$e' 不直出给用户，
      // 完整异常留日志便于排查。
      debugPrint('[captcha] getVerifyInfo failed: $e');
      setState(() {
        _error = context.l10n.captchaLoadFailed;
        _loading = false;
      });
    }
  }

  String? _extractTxAppId(VerifySession s) {
    // url 形如 KGCodeTX|xxx 或包含 txappid 参数
    final url = s.verifyUrl ?? '';
    final m = RegExp(r'txappid=([0-9A-Za-z_-]+)').firstMatch(url);
    if (m != null) return m.group(1);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.captchaTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError(theme)
              : _buildByType(theme, _session!),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildByType(ThemeData theme, VerifySession s) {
    switch (s.type) {
      case CaptchaType.tencent:
        return _buildTencent(theme, s);
      case CaptchaType.sms:
        return _buildSms(theme, s);
      case CaptchaType.geetest:
      case CaptchaType.kugou:
      case CaptchaType.kugouRotate:
      case CaptchaType.shumei:
      case CaptchaType.yidun:
        return _buildExternal(theme, s);
      case CaptchaType.liveness:
      case CaptchaType.face:
        return _buildExternal(theme, s);
      case CaptchaType.unknown:
        return _buildUnknown(theme, s);
    }
  }

  // ---------------- 腾讯 TCaptcha ----------------

  Widget _buildTencent(ThemeData theme, VerifySession s) {
    final appId = _txAppId;
    if (appId == null) {
      // 没有 txappid 无法初始化，退化为未知类型提示
      return _buildUnknown(theme, s);
    }
    final html = _tencentHtml(appId, s.eventId);
    return Stack(
      children: [
        InAppWebView(
          initialData: InAppWebViewInitialData(
            data: html,
            mimeType: 'text/html',
            encoding: 'utf-8',
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            transparentBackground: true,
            mediaPlaybackRequiresUserGesture: false,
          ),
          onWebViewCreated: (controller) {
            controller.addJavaScriptHandler(
              handlerName: 'onCaptchaResult',
              callback: (args) {
                if (args.isEmpty) return null;
                final payload = args.first;
                if (payload is Map) {
                  final ticket = '${payload['ticket'] ?? ''}';
                  final randstr = '${payload['randstr'] ?? ''}';
                  if (ticket.isNotEmpty && randstr.isNotEmpty) {
                    final code = VerifyCode.tencent(
                      ticket: ticket,
                      randstr: randstr,
                      txappid: appId,
                    );
                    _submitWithCode(s, code);
                  }
                }
                return null;
              },
            );
          },
          onLoadStop: (_, __) => setState(() => _webViewReady = true),
        ),
        if (!_webViewReady || _submitting)
          Container(
            color: Colors.black54,
            child: const Center(child: CircularProgressIndicator()),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Text(
            context.l10n.captchaTencentHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }

  String _tencentHtml(String appId, String eventId) {
    final appIdJson = jsonEncode(appId);
    final eventJson = jsonEncode(eventId);
    return '''
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  html,body{margin:0;height:100%;background:transparent;
    font-family:system-ui,-apple-system,sans-serif;color:#eee}
  #box{display:flex;flex-direction:column;align-items:center;
    justify-content:center;height:100%;gap:16px}
  button{padding:12px 28px;border-radius:24px;border:none;
    background:#00D4FF;color:#003;font-size:16px;font-weight:600}
  p{opacity:.7;font-size:13px;margin:0 12px;text-align:center}
</style></head>
<body>
<div id="box">
  <button id="go">开始验证</button>
  <p>完成滑块后自动继续</p>
</div>
<script src="https://turing.captcha.qcloud.com/TCaptcha.js"></script>
<script>
  var appId = $appIdJson;
  var eventId = $eventJson;
  function done(ticket, randstr) {
    window.flutter_inappwebview.callHandler('onCaptchaResult',
      {ticket: ticket, randstr: randstr, eventid: eventId});
  }
  document.getElementById('go').onclick = function () {
    try {
      var cap = new TencentCaptcha(appId, function (res) {
        if (res && res.ret === 0) {
          done(res.ticket, res.randstr);
        }
      });
      cap.show();
    } catch (e) {
      done('', '');
    }
  };
  window.onload = function () {
    // 自动尝试弹出
    document.getElementById('go').click();
  };
</script>
</body></html>
''';
  }

  // ---------------- 手机短信验证码 ----------------

  Widget _buildSms(ThemeData theme, VerifySession s) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.sms_outlined,
              size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          // V37-01：硬编码中文 → arb 键
          Text(context.l10n.captchaSmsTitle, textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(context.l10n.captchaSmsHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              )),
          const SizedBox(height: 28),
          TextField(
            controller: _smsCodeCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.l10n.captchaSmsCodeLabel,
              hintText: context.l10n.captchaSmsCodeHint,
            ),
            maxLength: 8,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _submitting
                ? null
                : () {
                    final code = _smsCodeCtrl.text.trim();
                    if (code.isEmpty) return;
                    _submitWithCode(s, code);
                  },
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.captchaSubmit),
          ),
        ],
      ),
    );
  }

  // ---------------- 外部 / 不支持的验证 ----------------

  Widget _buildExternal(ThemeData theme, VerifySession s) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined,
              size: 64, color: theme.colorScheme.tertiary),
          const SizedBox(height: 20),
          Text(s.type.label, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            // V37-01：硬编码中文 → arb 键
            context.l10n.captchaExternalHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close),
            label: Text(context.l10n.captchaClose),
          ),
        ],
      ),
    );
  }

  Widget _buildUnknown(ThemeData theme, VerifySession s) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.help_outline,
              size: 56, color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          // V37-01：硬编码中文 → arb 键
          Text(context.l10n.captchaUnknownType('${s.vType}'),
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            s.verifyUrl ?? context.l10n.captchaNoVerifyUrl,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 20),
          if (s.vType >= 0)
            FilledButton.tonal(
              onPressed: _submitting ? null : () => _submitWithCode(s, null),
              child: Text(context.l10n.captchaTryFingerprint),
            ),
        ],
      ),
    );
  }

  // ---------------- 提交 ----------------

  Future<void> _submitWithCode(VerifySession s, String? verifycode) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final ok = await _service.submit(
        session: s,
        verifycode: verifycode,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() => _submitting = false);
        _snack(context.l10n.captchaNotPassed);
        return;
      }
      // 验证通过 → 尝试重试原请求
      if (widget.onVerified != null) {
        final retried = await widget.onVerified!();
        if (!mounted) return;
        if (retried) {
          Navigator.of(context).pop(true);
          return;
        }
        setState(() => _submitting = false);
        _snack(context.l10n.captchaPassedButRetry);
        Navigator.of(context).pop(true);
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // V34-UI-02：'$e' 直出改友好文案
      _snack(context.l10n.captchaSubmitFailed);
      debugPrint('[captcha] submit failed: $e');
    }
  }

  void _snack(String msg) {
    // V34-UI-02b（P3）：项目统一用 Toast（login_page _showError 注释明示），
    // 避免验证页提示样式与全 app 不一致。
    Toast.show(context, msg);
  }
}

