import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// V33-01（修复②）：启动屏「手写笔迹」动画。
///
/// 品牌图标本身就是一条从左到右、像字迹一样起落的波形笔画，
/// 因此不再用整张图做淡入/滑动，而是把 SVG 的 path 数据抽出来，
/// 用 [PathMetric.extractPath] 按长度逐段描摹——效果等同「一笔写出来」，
/// 笔头实时跟随描摹位置，写完停顿后再整体渐隐、清空重写。
///
/// 为什么把 path 硬编码在这里（而不是运行时解析 SVG）：
/// - 图标是固定品牌资产，路径只有 11 段，展开成绝对坐标后与源文件一一对应，
///   可在纯 Dart 里验证（见下方 [HandwritingGeometry.strokePath] 注释）；
/// - 运行时零 IO、零解析，splash 每帧不需要任何资源读取；
/// - `flutter_svg` 不暴露按长度分段的 API，无法实现真正的路径描摹。
///
/// 所有位图/图形缩放都走等比：绘制前按内容包围盒计算一个统一 scale
/// （宽度与高度用同一个系数），不存在任何方向的拉伸。
class SplashHandwriting extends StatefulWidget {
  const SplashHandwriting({
    super.key,
    this.logoSize = 132,
    // U-1（第7批复核③）：默认用「汀澜音乐」，但外部可传——
    // 调用方（main.dart）传 l10n 后即为本地化文案。
    this.label = '汀澜音乐',
  });

  /// 图标绘制区边长（正方形）。等比缩放的输入，不允许变形。
  final double logoSize;
  final String label;

  @override
  State<SplashHandwriting> createState() => _SplashHandwritingState();
}

class _SplashHandwritingState extends State<SplashHandwriting>
    with SingleTickerProviderStateMixin {
  /// 单实例控制器，只在 splash 存续期运行；离开本页由 [dispose] 对称释放
  /// （第 20/26 条）。
  late final AnimationController _controller;
  late final Animation<double> _labelOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HandwritingCycle.duration,
    )..repeat();
    _labelOpacity = _buildLabelOpacity(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 文字透明度：书写期间保持 0，写完在 [HandwritingCycle] 的 hold 段淡入，
  /// 随整体渐隐一起退场。用 TweenSequence 驱动 [FadeTransition]，
  /// 这样每帧只重绘、不重建 Text（第 26 条）。
  Animation<double> _buildLabelOpacity(Animation<double> parent) {
    final fadeInStart = HandwritingCycle.writeEndMs - 30;
    final fadeInEnd = fadeInStart + 260;
    final fadeOutStart = HandwritingCycle.holdEndMs;
    // 权重直接用毫秒数，与 HandwritingCycle 的时序常量一一对应。
    return TweenSequence<double>([
      TweenSequenceItem(
        tween: ConstantTween<double>(0),
        weight: fadeInStart.toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: (fadeInEnd - fadeInStart).toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1),
        weight: (fadeOutStart - fadeInEnd).toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: HandwritingCycle.fadeMs.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(0),
        weight: (HandwritingCycle.totalMs - HandwritingCycle.fadeEndMs)
            .toDouble(),
      ),
    ]).animate(parent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 用主题主色（品牌 #00D4FF 派生），深浅色模式自动适配；
    // 不再固定 SVG 里的白蓝色值。
    final ink = theme.colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.logoSize,
          height: widget.logoSize,
          child: CustomPaint(
            painter: HandwritingLogoPainter(cycle: _controller, ink: ink),
            isComplex: true,
            willChange: true,
          ),
        ),
        const SizedBox(height: 22),
        FadeTransition(
          opacity: _labelOpacity,
          child: Text(
            widget.label,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 4,
            ),
          ),
        ),
      ],
    );
  }
}

/// 一轮动画的时序（毫秒）。
///
/// 总长 2600ms > 典型冷启动 ~2s，保证首页切走前至少看到完整一次书写；
/// [SplashScreen] 的最短展示时长也从这里取，避免动画被首帧立刻掐断。
abstract final class HandwritingCycle {
  /// 起笔的「点」先落笔（对应图标左侧那个小圆点）。
  static const int dotMs = 110;

  /// 主笔画由左到右写出。
  static const int strokeMs = 1560;

  /// 写完停顿。
  static const int holdMs = 620;

  /// 整体渐隐。
  static const int fadeMs = 290;

  /// 渐隐后留一点空白再重新起笔，避免首尾相接显得突兀。
  static const int tailMs = 20;

  static const int writeEndMs = dotMs + strokeMs;
  static const int holdEndMs = writeEndMs + holdMs;
  static const int fadeEndMs = holdEndMs + fadeMs;
  static const int totalMs = fadeEndMs + tailMs;

  static const Duration duration = Duration(milliseconds: totalMs);

  /// 启动屏最短可见时长：写完 + 停一拍。冷启动再快也要让用户看到这一笔。
  static const Duration minVisible = Duration(milliseconds: writeEndMs + 200);
}

/// 图标几何（坐标沿用 SVG 的 192×192 画布）。
abstract final class HandwritingGeometry {
  /// 描摹用笔画宽度（SVG 原值 12）。
  static const double strokeWidth = 12;

  /// 末端小圆点：SVG 是 r=3、stroke-width=6 的描边圆，
  /// 视觉上就是一个直径 12 的实心点；这里直接按实心圆绘制（半径 6），
  /// 省掉一次描边路径度量，且小尺寸下观感一致。
  static const Offset dotCenter = Offset(22, 96);
  static const double dotRadius = 6;

  /// 源：`assets/audiomack.svg` 的
  /// `M43 96 s11 5 19-8 l5 20 19-30 c0 12 8 38 8 38 l26-53 -1 82 34-98
  ///  -3 67 12-14 8-2`（V33-02）。
  ///
  /// 相对指令已在此逐段展开为绝对坐标（`s` 的第一控制点按 SVG 规范
  /// 「上一段无 C/S 则退化为当前点」处理），因此这里只有 moveTo/cubicTo/
  /// lineTo，逐条可人工核对。段序即书写顺序。
  static final Path strokePath = _buildStrokePath();

  static Path _buildStrokePath() {
    final p = Path();
    p.moveTo(43, 96);
    // s11 5 19-8：首段无前控制点 → c1=(43,96)
    p.cubicTo(43, 96, 54, 101, 62, 88);
    p.lineTo(67, 108);
    p.lineTo(86, 78);
    // c0 12 8 38 8 38：相对当前点 (86,78)
    p.cubicTo(86, 90, 94, 116, 94, 116);
    p.lineTo(120, 63);
    p.lineTo(119, 145);
    p.lineTo(153, 47);
    p.lineTo(150, 114);
    p.lineTo(162, 100);
    p.lineTo(170, 98);
    return p;
  }

  /// 笔画 + 圆点的内容包围盒（含描边半径），用于等比缩放居中。
  static final Rect contentBounds = strokePath
      .getBounds()
      .expandToInclude(Rect.fromCircle(center: dotCenter, radius: dotRadius))
      .inflate(strokeWidth / 2);
}

/// 笔迹描摹绘制器。
///
/// 动画进度直接取自 [cycle]（构造时作为 `repaint` 传入），因此每帧只有
/// paint 调用，没有 Widget 重建；Path/度量对象在首次绘制时缓存一次（第 26 条）。
class HandwritingLogoPainter extends CustomPainter {
  HandwritingLogoPainter({required this.cycle, required this.ink})
    : super(repaint: cycle);

  final Animation<double> cycle;
  final Color ink;

  /// 单笔画 → 只有一个 PathMetric；缓存避免每帧重新 `computeMetrics()`。
  ui.PathMetric? _metric;

  @override
  void paint(Canvas canvas, Size size) {
    final ms = cycle.value * HandwritingCycle.totalMs;
    if (ms >= HandwritingCycle.fadeEndMs) return; // 已完全渐隐，空画布

    final opacity = ms <= HandwritingCycle.holdEndMs
        ? 1.0
        : (1 - (ms - HandwritingCycle.holdEndMs) / HandwritingCycle.fadeMs)
              .clamp(0.0, 1.0);
    if (opacity <= 0 || size.isEmpty) return;

    // 等比适配：宽高共用同一 scale（取两者较小值），绝不拉伸。
    final bounds = HandwritingGeometry.contentBounds;
    final scale = math.min(
      size.width / bounds.width,
      size.height / bounds.height,
    );
    if (!scale.isFinite || scale <= 0) return;

    canvas.save();
    canvas.translate(
      (size.width - bounds.width * scale) / 2,
      (size.height - bounds.height * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = HandwritingGeometry.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ink.withValues(alpha: opacity);

    // 起笔的圆点：随进度从小长大，模拟笔尖落下。
    final dotT = Curves.easeOut.transform(
      (ms / HandwritingCycle.dotMs).clamp(0.0, 1.0),
    );
    if (dotT > 0) {
      canvas.drawCircle(
        HandwritingGeometry.dotCenter,
        HandwritingGeometry.dotRadius * dotT,
        Paint()..color = ink.withValues(alpha: opacity * dotT),
      );
    }

    final strokeT = Curves.easeInOutSine.transform(
      ((ms - HandwritingCycle.dotMs) / HandwritingCycle.strokeMs).clamp(
        0.0,
        1.0,
      ),
    );
    if (strokeT <= 0) {
      canvas.restore();
      return;
    }

    final metric = _metric ??= HandwritingGeometry.strokePath
        .computeMetrics()
        .first;
    final drawn = metric.extractPath(0, metric.length * strokeT);
    canvas.drawPath(drawn, paint);

    // 笔头：跟随描摹终点，收笔后淡出。让「在写」这件事有物理指向。
    if (strokeT < 1) {
      final tip = metric.getTangentForOffset(metric.length * strokeT)?.position;
      if (tip != null) {
        canvas.drawCircle(
          tip,
          HandwritingGeometry.strokeWidth * 0.62,
          Paint()..color = ink.withValues(alpha: opacity * 0.28),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(HandwritingLogoPainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.cycle != cycle;
}
