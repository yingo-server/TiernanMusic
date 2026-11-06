import 'package:flutter/material.dart';

import 'splash_handwriting.dart';

/// 启动页（App 冷启动时显示，直到首帧就绪）。
///
/// V33-03（修复②）：本文件只做装配。手写笔迹动画（描摹 → 停顿 → 渐隐 →
/// 循环）全部在 [SplashHandwriting] 内，避免启动页这个「被复用得最多、
/// 改动最少」的入口承担动画逻辑。
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: const Center(
        // 图标 + 文字的动画整体居中；文字由动画在书写完成后淡入。
        child: SplashHandwriting(),
      ),
    );
  }
}
