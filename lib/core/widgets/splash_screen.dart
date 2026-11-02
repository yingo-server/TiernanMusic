import 'package:flutter/material.dart';

import 'animated_svg_logo.dart';

/// 启动页（App 冷启动时显示，直到首帧就绪）
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AnimatedSvgLogo(size: 132),
            const SizedBox(height: 22),
            Text(
              '汀澜音乐',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
