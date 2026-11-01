import 'package:flutter/material.dart';

/// 骨架屏微光动画（无第三方依赖）。
///
/// Material 3 规范：列表加载中用骨架屏（shimmer）代替转圈，
/// 避免内容出现时的布局跳动。
class Shimmer extends StatefulWidget {
  const Shimmer({
    super.key,
    required this.child,
    this.baseColor,
    this.highlightColor,
    this.enabled = true,
  });

  final Widget child;

  /// 静止态底色（默认 surface）。
  final Color? baseColor;

  /// 高光带颜色。
  final Color? highlightColor;

  /// 关闭动画时只渲染底色（用于 prefers-reduced-motion 场景）。
  final bool enabled;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = widget.baseColor ?? theme.colorScheme.surface;
    final highlight = widget.highlightColor ??
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
    if (!widget.enabled) {
      return ColoredBox(color: base, child: widget.child);
    }
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // 高光带从左侧 -1 推进到右侧 1，覆盖 child 后裁剪
        final dx = -1.2 + _controller.value * 2.4;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
            transform: GradientTranslation(dx * bounds.width),
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// 骨架占位块（圆角矩形）。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    required this.height,
    this.width,
    this.radius = 12,
  });

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 骨架文字条。
class SkeletonText extends StatelessWidget {
  const SkeletonText({super.key, required this.width, this.height = 16});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// Gradient 平移：把渐变整体在 x 方向偏移 [dx]
class GradientTranslation extends GradientTransform {
  const GradientTranslation(this.dx);
  final double dx;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}
