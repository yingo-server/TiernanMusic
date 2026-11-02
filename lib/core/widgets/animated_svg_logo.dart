import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 启动页：SVG 图标「从左到右逐笔绘出」的动画。
///
/// flutter_svg 的 [SvgPicture.asset] 不支持按 path 分段绘制，
/// 这里用外层固定尺寸 + 内部按进度裁剪的布局模拟「从左到右写出来」。
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
        return SizedBox(
          width: widget.size,
          height: widget.size,
          // 外层裁剪：只露出左侧 t 比例的区域，形成「逐渐写出」的效果
          child: ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: t,
              child: SvgPicture.asset(
                widget.svgAsset,
                width: widget.size,
                height: widget.size,
                colorFilter: widget.color == null
                    ? null
                    : ColorFilter.mode(widget.color!, BlendMode.srcIn),
              ),
            ),
          ),
        );
      },
    );
  }
}
