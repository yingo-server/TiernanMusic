import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../utils/toast.dart';
import 'package:flutter/services.dart';

/// 全局轻提示（替代直接 showSnackBar）
///
/// - 同类消息 3 秒去重：请求并发失败时不会刷屏
/// - 同一时刻最多显示 1 条：新消息先移除旧条目再插入
class Toast {
  Toast._();

  static const _dedupeWindow = Duration(seconds: 3);
  static const _displayDuration = Duration(milliseconds: 2400);

  static final Map<String, DateTime> _lastShown = {};
  static OverlayEntry? _current;
  static Timer? _dismissTimer;

  /// 显示一条提示；[msg] 相同且在 3 秒内已展示过则静默忽略。
  static void show(BuildContext context, String msg) {
    final now = DateTime.now();
    final last = _lastShown[msg];
    if (last != null && now.difference(last) < _dedupeWindow) return;
    _lastShown[msg] = now;
    // 防止 map 无限增长
    if (_lastShown.length > 64) {
      _lastShown.removeWhere((_, t) =>
          now.difference(t) >= _dedupeWindow);
    }

    final overlay = context.findRootAncestorStateOfType<OverlayState>();
    if (overlay == null) return;

    // 队列长度恒为 1：清掉当前显示的
    _dismissTimer?.cancel();
    _current?.remove();
    _current = null;

    final entry = OverlayEntry(builder: (_) => _ToastView(msg));
    _current = entry;
    overlay.insert(entry);
    _dismissTimer = Timer(_displayDuration, _hide);
  }

  /// 复制文本到剪贴板并提示（报错文字点击时使用）
  static Future<void> copy(BuildContext context, String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      show(context, context.l10n.copiedToClipboard);
    }
  }

  static void _hide() {
    _current?.remove();
    _current = null;
    _dismissTimer?.cancel();
    _dismissTimer = null;
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView(this.msg);
  final String msg;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  Timer? _exitTimer;

  @override
  void initState() {
    super.initState();
    _exitTimer = Timer(
        const Duration(milliseconds: 2400), _controller.reverse);
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: media.padding.bottom + 96,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Text(
                  widget.msg,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

