import 'dart:async';

import 'package:flutter/material.dart';

import '../image/app_image_cache.dart';
import 'gradient_chip.dart';
import 'empty_state.dart';
import 'error_retry.dart';
export 'section_header.dart';
export 'gradient_chip.dart';
export 'list_skeleton.dart';
export 'empty_state.dart';
export 'error_retry.dart';

import '../utils/toast.dart';
import '../../l10n/l10n.dart';

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
