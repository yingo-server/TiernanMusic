import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// 统一的「危险操作二次确认」对话框。
///
/// Material 3 规范：删除/清空这类破坏性操作必须
/// 1) 用 error 色强调；2) 用 Dialog（需要用户做决策），而不是 Snackbar；
/// 3) 提供明确的取消 / 确认两个动作。
///
/// [title] / [message] 由调用方传入本地化文案。
Future<bool> showDestructiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel ?? context.l10n.confirm),
        ),
      ],
    ),
  );
  return ok == true;
}
