import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/kugou_api_client.dart';
import '../../l10n/l10n.dart';

/// 统一歌曲列表项
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.title,
    required this.artist,
    this.cover,
    this.duration,
    this.trailing,
    this.onTap,
    this.onDownload,
    this.isPlaying = false,
  });

  final String title;
  final String artist;
  final String? cover;
  final int? duration; // 秒
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: cover != null && cover!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: cover!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                placeholder: (_, __) => _placeholder(theme),
                errorWidget: (_, __, ___) => _placeholder(theme),
              )
            : _placeholder(theme),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: isPlaying ? theme.colorScheme.primary : null,
          fontWeight: isPlaying ? FontWeight.w600 : null,
        ),
      ),
      subtitle: Text(
        artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withOpacity(0.6),
        ),
      ),
      trailing: trailing ??
          (onDownload != null
              ? IconButton(
                  icon: const Icon(Icons.download_outlined, size: 20),
                  tooltip: context.l10n.download,
                  onPressed: onDownload,
                )
              : (duration != null
                  ? Text(
                      _fmt(duration!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    )
                  : null)),
    );
  }

  Widget _placeholder(ThemeData theme) => Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note,
            color: theme.colorScheme.onSurface.withOpacity(0.3)),
      );

  String _fmt(int sec) =>
      '${(sec ~/ 60).toString().padLeft(1, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
}

/// 统一加载骨架
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.itemCount = 6});
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: itemCount,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 12,
                    width: 120,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
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

/// 统一空态（图标 + 文案 + 可选按钮）
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.onSurface.withOpacity(0.35)),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
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
  }
}

/// 渐变色 Chip（色相随 index 变化），用于热门搜索等场景
class GradientChip extends StatelessWidget {
  const GradientChip({
    super.key,
    required this.label,
    required this.index,
    this.onTap,
  });

  final String label;
  final int index;
  final VoidCallback? onTap;

  static HSLColor _hue(int i) =>
      HSLColor.fromAHSL(1, (i * 47.0) % 360, 0.65, 0.5);

  @override
  Widget build(BuildContext context) {
    final a = _hue(index).toColor();
    final b = _hue(index + 1).toColor();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [a, b]),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一错误重试
///
/// 绝不把原始异常（如 `DioException [connection error]...`）直接展示给用户：
/// 通过 [errorClassification] 分类后给出友好文案，原始错误折叠在「技术详情」里。
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
                color: theme.colorScheme.errorContainer.withOpacity(0.5),
              ),
              child: Icon(
                c.icon,
                size: 44,
                color: theme.colorScheme.onErrorContainer.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              friendly,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              c.hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.55),
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
                  color: theme.colorScheme.onSurface.withOpacity(0.45),
                ),
                const SizedBox(width: 4),
                Text(
                  context.l10n.techDetail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.45),
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
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              widget.raw,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ),
      ],
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
  final raw = error?.toString() ?? '';
  if (error is DioException) {
    final t = error.type;
    if (error is DioException &&
        (t == DioExceptionType.connectionTimeout ||
            t == DioExceptionType.receiveTimeout ||
            t == DioExceptionType.sendTimeout ||
            t == DioExceptionType.connectionError)) {
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
