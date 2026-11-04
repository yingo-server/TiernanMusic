import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/toast.dart';
import '../../l10n/l10n.dart';

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
