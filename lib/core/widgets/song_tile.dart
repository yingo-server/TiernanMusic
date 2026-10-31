import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
../../l10n/l10n.dart

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
    this.isPlaying = false,
  });

  final String title;
  final String artist;
  final String? cover;
  final int? duration; // 秒
  final Widget? trailing;
  final VoidCallback? onTap;
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
          (duration != null
              ? Text(
                  _fmt(duration!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                )
              : null),
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
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, this.message, this.onRetry});
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 56, color: theme.colorScheme.onSurface.withOpacity(0.4)),
          const SizedBox(height: 16),
          Text(
            message ?? context.l10n.loadFailed,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retry),
            ),
          ],
        ],
      ),
    );
  }
}
