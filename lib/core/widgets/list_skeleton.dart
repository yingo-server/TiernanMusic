import 'shimmer.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/toast.dart';
import '../../l10n/l10n.dart';

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
