import 'package:cached_network_image/cached_network_image.dart';
import '../image/app_image_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/kugou_api_client.dart';
import '../utils/toast.dart';
import 'shimmer.dart';
import '../../l10n/l10n.dart';

/// 列表项二级操作（收进 PopupMenuButton 的菜单项）。
class SongTileMenuItem {
  const SongTileMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.isDestructive = false,
  });

  final String value;
  final String label;
  final IconData? icon;

  /// 危险操作（删除等）用 error 色强调。
  final bool isDestructive;
}

/// 统一歌曲列表项
///
/// Material 3 约定：
/// - trailing 默认只承载「时长」这类次要信息；
/// - 多个操作收进 [PopupMenuButton]，而不是排一排 IconButton；
/// - 单一高频操作（下载）可直接作为 trailing 图标按钮，并带 tooltip。
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.title,
    required this.artist,
    this.cover,
    this.duration, // 秒
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.onDownload,
    this.menuItems,
    this.onMenuSelected,
    this.isPlaying = false,
    this.selected = false,
  });

  final String title;
  final String artist;
  final String? cover;
  final int? duration; // 秒
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 长按：M3 列表项的次级入口（等价于桌面端右键菜单）。
  final VoidCallback? onLongPress;
  final VoidCallback? onDownload;

  /// 需要收进「更多」菜单的操作。
  final List<SongTileMenuItem>? menuItems;
  final void Function(String value)? onMenuSelected;

  final bool isPlaying;
  final bool selected;

  bool get _hasMenu => menuItems != null && menuItems!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: cover != null && cover!.isNotEmpty
            ? CachedNetworkImage(
                    cacheManager: AppImageCache.instance,
                imageUrl: cover!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                memCacheWidth: (52 * MediaQuery.devicePixelRatioOf(context)).round(),
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
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: trailing ?? _buildTrailing(context, theme),
    );
  }

  Widget? _buildTrailing(BuildContext context, ThemeData theme) {
    // M3 规范：trailing 只承载「次要信息 + 单一入口」。
    // 时长是次要信息（文本），多个操作收进 PopupMenuButton —— 不排一排 IconButton。
    final durationLabel = duration != null
        ? Text(
            _fmt(duration!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        : null;

    if (_hasMenu) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (durationLabel != null) ...[
            durationLabel,
            const SizedBox(width: 8),
          ],
          PopupMenuButton<String>(
            tooltip: context.l10n.moreActions,
            onSelected: (v) => onMenuSelected?.call(v),
            itemBuilder: (context) => [
              for (final item in menuItems!)
                PopupMenuItem<String>(
                  value: item.value,
                  child: Row(
                    children: [
                      if (item.icon != null) ...[
                        Icon(
                          item.icon,
                          size: 20,
                          color: item.isDestructive
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        item.label,
                        style: item.isDestructive
                            ? TextStyle(color: theme.colorScheme.error)
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      );
    }
    if (onDownload != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (durationLabel != null) ...[
            durationLabel,
            const SizedBox(width: 8),
          ],
          IconButton(
            icon: const Icon(Icons.download_outlined, size: 20),
            tooltip: context.l10n.download,
            onPressed: onDownload,
          ),
        ],
      );
    }
    return durationLabel;
  }

  Widget _placeholder(ThemeData theme) => Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note,
            color: theme.colorScheme.onSurfaceVariant),
      );

  String _fmt(int sec) =>
      '${(sec ~/ 60).toString().padLeft(1, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
}

/// 统一的分区标题（设置页 / 音乐库 / 首页共用）。
///
/// Material 3 建议分区标题使用 titleMedium/labelLarge 这类层级 token，
/// 而不是硬编码字号；右侧可放一个次要操作按钮。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 8),
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) action!,
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
      HSLColor.fromAHSL(1, (i * 47.0) % 360, 0.65, 0.42);

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
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一加载骨架（带微光动画）
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.itemCount = 6});
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Shimmer(
      baseColor: theme.colorScheme.surface,
      highlightColor:
          theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: ListView.builder(
        itemCount: itemCount,
        itemBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SkeletonBox(height: 52, width: 52, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SkeletonText(width: double.infinity, height: 14),
                    const SizedBox(height: 8),
                    SkeletonText(width: 120, height: 12),
                  ],
                ),
              ),
            ],
          ),
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
