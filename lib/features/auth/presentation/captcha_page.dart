import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/auth_repository.dart';

/// 人机验证页（全屏弹窗）
///
/// 使用方式：
/// ```dart
/// final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
///   fullscreenDialog: true,
///   builder: (_) => CaptchaPage(ssaCode: code, repository: repo),
/// ));
/// ```
/// 返回 true 表示验证成功，调用方应重试原请求。
class CaptchaPage extends StatefulWidget {
  const CaptchaPage({
    super.key,
    required this.ssaCode,
    required this.repository,
  });

  final String ssaCode;
  final AuthRepository repository;

  @override
  State<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends State<CaptchaPage> {
  VerifyInfo? _info;
  String? _sid;
  String? _edt;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

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
      final info = await widget.repository.getVerifyInfo(widget.ssaCode);
      final se = await widget.repository.getSidEdt();
      if (!mounted) return;
      setState(() {
        _info = info;
        _sid = se.sid;
        _edt = se.edt;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载验证信息失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _submit(String verifycode) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.repository.submitVerify(
        eventid: widget.ssaCode,
        vType: _info!.vType,
        verifycode: verifycode,
        sid: _sid ?? '',
        edt: _edt ?? '',
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '验证失败，请重试：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安全验证'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final info = _info;
    if (info == null) {
      return _ErrorView(message: _error ?? '未知错误', onRetry: _load);
    }
    if (info.vType == 32) {
      return _buildSmsVerify(info);
    }
    if (info.vType == 23) {
      return _buildTencentCaptcha(info);
    }
    return _ErrorView(
      message: '暂不支持的验证类型（v_type=${info.vType}）',
      onRetry: _load,
    );
  }

  /// 二次短信验证
  Widget _buildSmsVerify(VerifyInfo info) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '需要短信二次验证${info.mobile.isNotEmpty ? '\n验证码已发送至 ${info.mobile}' : ''}',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _smsCodeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: '短信验证码',
              prefixIcon: Icon(Icons.sms_outlined),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting
                ? null
                : () => _submit(_smsCodeCtrl.text.trim()),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('提交验证'),
          ),
        ],
      ),
    );
  }

  /// 腾讯 TCaptcha WebView
  Widget _buildTencentCaptcha(VerifyInfo info) {
    final txappid = info.txappid;
    final html = '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>html,body{margin:0;padding:0;background:#121212;display:flex;align-items:center;justify-content:center;height:100vh;color:#fff;font-family:sans-serif;}</style>
<script src="https://turing.captcha.qcloud.com/TCaptcha.js"></script>
</head>
<body>
<div id="loading">正在加载验证组件…</div>
<script>
function onCaptchaResult(res) {
  if (res && res.ticket) {
    window.flutter_inappwebview.callHandler('tencentCaptcha', res.ticket, res.randstr);
  } else {
    window.flutter_inappwebview.callHandler('tencentCaptchaCancel');
  }
}
try {
  var captcha = new TencentCaptcha('$txappid', onCaptchaResult, {});
  captcha.show();
  document.getElementById('loading').style.display = 'none';
} catch (e) {
  document.getElementById('loading').innerText = '验证组件加载失败: ' + e;
}
</script>
</body>
</html>
''';
    return Column(
      children: [
        if (_error != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        Expanded(
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              transparentBackground: true,
            ),
            initialData: InAppWebViewInitialData(
              data: html,
              baseUrl: WebUri('https://turing.captcha.qcloud.com/'),
            ),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: 'tencentCaptcha',
                callback: (args) {
                  if (args.length >= 2) {
                    final ticket = '${args[0]}';
                    final randstr = '${args[1]}';
                    final code = AuthRepository.buildTencentVerifyCode(
                      ticket: ticket,
                      randstr: randstr,
                      txappid: txappid,
                    );
                    _submit(code);
                  }
                },
              );
              controller.addJavaScriptHandler(
                handlerName: 'tencentCaptchaCancel',
                callback: (args) {
                  if (mounted) {
                    setState(() => _error = '验证已取消，请重新尝试');
                  }
                },
              );
            },
            onReceivedError: (controller, request, error) {
              if (mounted) {
                setState(() => _error = '页面加载失败：${error.description}');
              }
            },
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
