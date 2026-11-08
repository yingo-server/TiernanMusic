import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di.dart';
import '../../player/player_provider.dart';
import 'captcha_page.dart';

/// 全局人机验证监听器
///
/// 播放链路命中 20028 时自动弹出验证页；验证通过后重试原播放。
/// 包在 MainShell 外层，任何页面播放被拦截都能弹窗。
class VerificationListener extends ConsumerStatefulWidget {
  const VerificationListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VerificationListener> createState() =>
      _VerificationListenerState();
}

class _VerificationListenerState extends ConsumerState<VerificationListener> {
  bool _handling = false;

  @override
  Widget build(BuildContext context) {
    // 首次进入订阅一次播放器的验证事件流
    ref.listen(verificationStreamProvider, (previous, next) {
      final api = next.valueOrNull;
      if (api == null || _handling) return;
      final ssaCode = api.ssaCode;
      if (ssaCode == null || ssaCode.isEmpty) return;
      _handle(ssaCode);
    });

    return widget.child;
  }

  Future<void> _handle(String ssaCode) async {
    if (_handling || !mounted) return;
    _handling = true;
    try {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CaptchaPage(
            ssaCode: ssaCode,
            api: ref.read(kugouApiClientProvider),
          ),
        ),
      );
      if (ok == true && mounted) {
        // 验证通过，重试刚才被拦截的播放
        await ref.read(audioHandlerProvider).retryPendingPlayback();
      }
    } finally {
      _handling = false;
    }
  }
}
