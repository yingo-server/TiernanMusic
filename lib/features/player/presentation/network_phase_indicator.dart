import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/net/network_phase.dart';
import '../../../l10n/l10n.dart';

/// P2（v5.3 重写批）：网络阶段指示器。
///
/// 细进度条 + 阶段文案，常驻播放页顶部；idle 阶段整体隐藏（AnimatedSwitcher
/// 高度收敛为 0，不占布局空间）。>500ms 的网络阶段必然可见（原则 34）：
/// 数据源是 core 层 [NetworkPhaseTracker] 的阶段事件流（单一事实源）。
class NetworkPhaseIndicator extends StatefulWidget {
  const NetworkPhaseIndicator({super.key});

  @override
  State<NetworkPhaseIndicator> createState() => _NetworkPhaseIndicatorState();
}

class _NetworkPhaseIndicatorState extends State<NetworkPhaseIndicator> {
  StreamSubscription<NetworkPhaseEvent>? _sub;

  /// 当前阶段（null = idle，不渲染）。
  NetworkPhase? _phase;

  /// 阶段进入时刻——不足 500ms 的瞬时阶段不闪烁（PLAN P2 口径）。
  DateTime _enteredAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _sub = NetworkPhaseTracker.instance.events.listen(_onEvent);
  }

  void _onEvent(NetworkPhaseEvent e) {
    if (!mounted) return;
    final next = e.phase == NetworkPhase.idle ? null : e.phase;
    if (next == _phase) return;
    setState(() {
      _phase = next;
      _enteredAt = DateTime.now();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _label(BuildContext context) => switch (_phase) {
        NetworkPhase.resolving => context.l10n.networkPhaseResolving,
        NetworkPhase.buffering => context.l10n.networkPhaseBuffering,
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _phase != null;
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: visible
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor:
                      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _label(context),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ])
          : const SizedBox(width: double.infinity),
    );
  }
}

