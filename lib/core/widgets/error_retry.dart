import 'dart:async';
import '../foundation/errors.dart' show ApiException;
import '../utils/friendly_error.dart' show unwrapApi;

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';

import '../utils/toast.dart';
import '../../l10n/l10n.dart';

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, this.message, this.onRetry, this.error});

  /// 兼容旧用法：显式友好文案（调用方需保证不含原始异常）。
  /// 若同时提供 [error]，优先使用 [error] 的分类文案。
  final String? message;

  /// 原始错误对象，用于自动分类 + 折叠的技术详情。
  final Object? error;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = errorClassification(context, error);
    final friendly = message ?? c.friendly;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
              ),
              child: Icon(
                c.icon,
                size: 44,
                color: theme.colorScheme.onErrorContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            // 报错文字点击即可复制到剪贴板
            _CopyableText(
              text: friendly,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _CopyableText(
              text: c.hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              ),
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.reload),
            ),
            if (c.raw != null && c.raw!.isNotEmpty) ...[
              const SizedBox(height: 24),
              _TechDetail(raw: c.raw!),
            ],
          ],
        ),
      ),
    );
  }
}

class _TechDetail extends StatefulWidget {
  const _TechDetail({required this.raw});
  final String raw;

  @override
  State<_TechDetail> createState() => _TechDetailState();
}

class _TechDetailState extends State<_TechDetail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  context.l10n.techDetail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:
                  theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              widget.raw,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_expanded)
          const SizedBox(height: 8),
        if (_expanded)
          OutlinedButton.icon(
            onPressed: () => Toast.copy(context, widget.raw),
            icon: const Icon(Icons.copy_all_outlined, size: 16),
            label: Text(context.l10n.copyDetails),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    );
  }
}

/// 可点击复制的文本（点击后写入剪贴板并提示）
class _CopyableText extends StatelessWidget {
  const _CopyableText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Toast.copy(context, text),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: style,
      ),
    );
  }
}


class FriendlyError {
  const FriendlyError({
    required this.friendly,
    required this.hint,
    required this.icon,
    this.raw,
  });

  /// 用户可见主文案
  final String friendly;

  /// 用户可见副文案
  final String hint;

  /// 大图标
  final IconData icon;

  /// 原始错误串（仅技术详情用）
  final String? raw;
}

/// 错误分类映射：DioException.connectionError/timeout → 网络文案；
/// ApiException → 其 message；其它 → 通用文案。
FriendlyError errorClassification(BuildContext context, Object? error) {
  final l = context.l10n;
  // v5.1 B4-A P2-1：先解包 DioException 内层 ApiException——直连层包装的
  // 登录过期/人机验证错误此前全部显示为通用文案（第 8 条）。
  final api = error == null ? null : unwrapApi(error);
  if (api != null) {
    return FriendlyError(
      friendly: api.message,
      hint: api.needsVerification ? l.genericErrorHint : null,
      icon: api.needsVerification
          ? Icons.verified_user_outlined
          : Icons.error_outline_rounded,
      raw: error?.toString() ?? '',
    );
  }
  final raw = error?.toString() ?? '';
  if (error is DioException) {
    final t = error.type;
    if (t == DioExceptionType.connectionTimeout ||
        t == DioExceptionType.receiveTimeout ||
        t == DioExceptionType.sendTimeout ||
        t == DioExceptionType.connectionError) {
      return FriendlyError(
        friendly: l.networkErrorTitle,
        hint: l.networkErrorHint,
        icon: Icons.wifi_off_rounded,
        raw: raw,
      );
    }
    return FriendlyError(
      friendly: l.genericErrorTitle,
      hint: l.genericErrorHint,
      icon: Icons.error_outline_rounded,
      raw: raw,
    );
  }
  if (error is ApiException) {
    return FriendlyError(
      friendly: error.message,
      hint: l.genericErrorHint,
      icon: Icons.error_outline_rounded,
      raw: raw,
    );
  }
  if (error != null) {
    return FriendlyError(
      friendly: l.genericErrorTitle,
      hint: l.genericErrorHint,
      icon: Icons.error_outline_rounded,
      raw: raw,
    );
  }
  return const FriendlyError(
    friendly: '',
    hint: '',
    icon: Icons.error_outline_rounded,
  );
}
