import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/toast.dart';
import '../../l10n/l10n.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 既要能作为全屏占位（垂直居中），也要能直接放进 ListView（高度无界）；
    // 后者用 Center 会触发无限高度断言，所以按约束是否有限分支处理。
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: onAction,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        );
        if (constraints.maxHeight.isFinite) {
          return Center(child: content);
        }
        return content;
      },
    );
  }
}

/// 统一错误重试
///
/// 绝不把原始异常（如 `DioException [connection error]...`）直接展示给用户：
/// 通过 [errorClassification] 分类后给出友好文案，原始错误折叠在「技术详情」里。
