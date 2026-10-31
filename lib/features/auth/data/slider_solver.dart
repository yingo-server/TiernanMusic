import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 滑块验证码求解器
///
/// 两步：
/// 1. [GapDetector] 识别缺口水平偏移（背景图 vs 拼图块模板匹配）
/// 2. [TrajectoryGenerator] 生成类人拖动轨迹（缓动 + 抖动 + 回弹）
///
/// 适用于酷狗自研/旋转滑块与可拿到背景+拼图图片的滑块；
/// 腾讯 TCaptcha 在跨域 iframe 内，无法注入事件，只能人工拖动。
class SliderSolver {
  const SliderSolver._();

  /// 识别缺口偏移（返回需要拖动的像素距离）
  ///
  /// [background] 背景图（含缺口）
  /// [piece] 拼图块图（通常带透明边）
  /// [scale] 显示缩放比（截图宽度 / 原始宽度），用于换算拖拽距离
  static int? detectOffset(
    Uint8List background,
    Uint8List piece, {
    double scale = 1.0,
  }) {
    final bg = img.decodeImage(background);
    final pc = img.decodeImage(piece);
    if (bg == null || pc == null) return null;

    // 拼图块去除透明边，取有效区域
    final pieceBox = _alphaBounds(pc);
    if (pieceBox == null) return null;
    final (px, py, pw, ph) = pieceBox;

    // 拼图块通常有约 10px 透明外扩，缺口实际宽度取有效宽度
    final searchTop = math.max(0, py);
    // 缺口区域纵向以拼图块顶部为起点

    var bestScore = double.infinity;
    var bestX = -1;

    // 缺口一定在拼图右侧，从拼图右边缘开始搜索
    final startX = math.max(0, px + pw);
    for (var x = startX; x <= bg.width - pw; x++) {
      final score = _matchScore(bg, pc, x, searchTop, pw, ph, px, py);
      if (score < bestScore) {
        bestScore = score;
        bestX = x;
      }
    }

    if (bestX < 0) return null;
    // 拖动距离 = 缺口左边 - 拼图左边
    final offset = (bestX - px) * scale;
    return offset.round();
  }

  /// 用边缘/亮度差做模板匹配（不依赖颜色，抗缺口阴影）
  static double _matchScore(
    img.Image bg,
    img.Image piece,
    int bx,
    int by,
    int w,
    int h,
    int px,
    int py,
  ) {
    var sum = 0.0;
    var count = 0;
    // 采样步长：大图降采样加速
    final step = math.max(1, math.min(w, h) ~/ 30);
    for (var y = 0; y < h; y += step) {
      for (var x = 0; x < w; x += step) {
        final sx = px + x;
        final sy = py + y;
        final tx = bx + x;
        final ty = by + y;
        if (tx < 0 || ty < 0 || tx >= bg.width || ty >= bg.height) continue;
        if (sx < 0 || sy < 0 || sx >= piece.width || sy >= piece.height) {
          continue;
        }
        // 只匹配拼图块不透明的区域
        if (piece.getPixel(sx, sy).a < 128) continue;
        final pv = _luma(piece.getPixel(sx, sy));
        final bv = _luma(bg.getPixel(tx, ty));
        sum += (pv - bv).abs();
        count++;
      }
    }
    if (count == 0) return double.infinity;
    // 缺口区域通常比周围暗，给暗区一点偏好
    final center = _luma(bg.getPixel(bx + w ~/ 2, by + h ~/ 2));
    return sum / count + (center > 200 ? 8 : 0);
  }

  static int _luma(img.Pixel p) =>
      (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();

  /// 求拼图块非透明像素包围盒
  static (int, int, int, int)? _alphaBounds(img.Image pc) {
    var minX = pc.width, minY = pc.height, maxX = -1, maxY = -1;
    for (var y = 0; y < pc.height; y++) {
      for (var x = 0; x < pc.width; x++) {
        if (pc.getPixel(x, y).a < 128) continue;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0) return null;
    return (minX, minY, maxX - minX + 1, maxY - minY + 1);
  }
}

/// 拖动轨迹中的一个采样点
class DragPoint {
  const DragPoint({required this.x, required this.y, required this.timeMs});

  /// 相对起点水平位移
  final double x;

  /// 相对起点垂直位移（轻微上下抖动）
  final double y;

  /// 从按下起的毫秒数
  final int timeMs;
}

/// 类人拖动轨迹生成
///
/// 特征：先快后慢、末端回弹微调、轻微纵向抖动、随机停留
class TrajectoryGenerator {
  const TrajectoryGenerator._();

  static final _rand = math.Random();

  /// 生成拖动到 [distance] 的轨迹
  ///
  /// [totalMs] 总耗时，真人一般 400~1200ms
  static List<DragPoint> generate(
    double distance, {
    int? totalMs,
    bool simulateOvershoot = true,
  }) {
    final total = totalMs ?? (400 + _rand.nextInt(600));
    final points = <DragPoint>[];

    // 超出量：先多滑一点再回退（真人常见）
    final overshoot = simulateOvershoot ? 3 + _rand.nextDouble() * 8 : 0.0;
    final peak = distance + overshoot;

    // 三段：加速 → 减速 → 回弹
    final decelEnd = (total * 0.85).round();

    var lastX = 0.0;
    for (var t = 0; t <= decelEnd; t += 16) {
      final progress = t / decelEnd;
      // easeOutCubic 前段快后段慢
      final eased = 1 - math.pow(1 - progress, 3).toDouble();
      var x = peak * eased;
      // 抖动：低速时更明显
      final jitterAmp = progress < 0.5 ? 0.8 : 1.6;
      x += (_rand.nextDouble() - 0.5) * jitterAmp;
      // 保证单调不减（除最后一次修正）
      if (x < lastX) x = lastX + 0.1;
      lastX = x;
      final y = math.sin(progress * math.pi * 2) * 1.2 +
          (_rand.nextDouble() - 0.5) * 1.5;
      points.add(DragPoint(x: x, y: y, timeMs: t));
    }

    // 回弹到目标
    if (overshoot > 0) {
      final steps = 3 + _rand.nextInt(4);
      for (var i = 1; i <= steps; i++) {
        final p = i / steps;
        final x = peak - (peak - distance) * p;
        points.add(DragPoint(
          x: x,
          y: (_rand.nextDouble() - 0.5) * 0.8,
          timeMs: decelEnd + i * (20 + _rand.nextInt(30)),
        ));
      }
    }

    // 末端停留
    points.add(DragPoint(
      x: distance,
      y: 0,
      timeMs: points.last.timeMs + 60 + _rand.nextInt(120),
    ));

    return points;
  }

  /// 生成酷狗旋转验证的旋转角度轨迹（旋转码通常 0~360）
  static List<DragPoint> generateRotation(double angle) {
    final total = 500 + _rand.nextInt(500);
    final points = <DragPoint>[];
    var last = 0.0;
    for (var t = 0; t <= total; t += 16) {
      final p = t / total;
      final eased = 1 - math.pow(1 - p, 2.5).toDouble();
      var a = angle * eased;
      a += (_rand.nextDouble() - 0.5) * 1.2;
      if (a < last) a = last;
      last = a;
      points.add(DragPoint(x: a, y: 0, timeMs: t));
    }
    return points;
  }
}
