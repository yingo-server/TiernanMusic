import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 启动页：SVG 图标「从左到右逐笔绘出」的动画。
///
/// flutter_svg 的 [SvgPicture.asset] 不支持按 path 分段绘制，
/// 因此用 ClipRect + 横向推进的遮罩模拟「从左到右写出来」的效果。
class AnimatedSvgLogo extends StatefulWidget {
  const AnimatedSvgLogo({
    super.key,
    this.svgAsset = 'assets/audiomack.svg',
    this.size = 120,
    this.duration = const Duration(milliseconds: 1400),
    this.color,
  });

  final String svgAsset;
  final double size;
  final Duration duration;
  final Color? color;

  @override
  State<AnimatedSvgLogo> createState() => _AnimatedSvgLogoState();
}

class _AnimatedSvgLogoState extends State<AnimatedSvgLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _curve.value.clamp(0.0, 1.0);
        return SvgPicture.asset(
          widget.svgAsset,
          width: widget.size,
          height: widget.size,
          colorFilter: widget.color == null
              ? null
              : ColorFilter.mode(widget.color!, BlendMode.srcIn),
          builder: (context, child) => child == null
              ? const SizedBox.shrink()
              : ClipRect(
                  alignment: Alignment.centerLeft,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: t,
                    child: child,
                  ),
                ),
        );
      },
    );
  }
}
