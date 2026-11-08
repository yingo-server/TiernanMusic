/// P2（v5.3 重写批）：网络阶段播报——「>500ms 的网络阶段必须可见」（原则 34）。
///
/// 设计：
/// - core 层纯 Dart，零 UI 依赖（分层单向，第 4 条）；UI 侧
///   `presentation/network_phase_indicator.dart` 订阅本单例渲染指示器；
/// - 单例 + broadcast 流 = 阶段事实**单一来源**（第 5 条）；
/// - 深度计数支持并发嵌套（fetchDetail 与 resolveUrl 同属 resolving
///   且可能先后重叠；多请求并发时最后一个 end 才回落 idle，第 22 条）；
/// - 阶段枚举对应 PLAN_v53 P2 定义的粒度：resolving（解析播放地址/
///   详情）、buffering（引擎装载与首帧缓冲）。streaming 由 just_audio
///   自身的 buffering 流覆盖，不在此重复上报。
library;

import 'dart:async';

/// 网络阶段。
enum NetworkPhase {
  /// 无活动网络阶段（UI 不渲染指示器）。
  idle,

  /// 解析阶段：详情补全 / 设备注册 / 播放地址解析（直连+kapi 全链）。
  resolving,

  /// 缓冲阶段：URL 已就绪，音频引擎装载音源到可播放（首帧）。
  buffering,
}

/// 一次阶段切换事件。
class NetworkPhaseEvent {
  NetworkPhaseEvent(this.phase, {this.detail = ''}) : at = DateTime.now();

  final NetworkPhase phase;

  /// 附加上下文（歌曲 hash 等），仅供日志诊断，UI 不得直接展示。
  final String detail;

  /// 事件时刻（本地时钟，仅诊断用）。
  final DateTime at;
}

/// 全局阶段播报器。
///
/// begin/end 必须由**同一段代码**配对调用（第 19 条）；推荐
/// `try { begin(); ... } finally { end(); }`。深度计数保证并发安全：
/// 每个阶段独立计数，depth 0→1 发出 begin 事件，1→0 发出 end 事件。
class NetworkPhaseTracker {
  NetworkPhaseTracker._();
  static final NetworkPhaseTracker instance = NetworkPhaseTracker._();

  StreamController<NetworkPhaseEvent> _controller =
      StreamController<NetworkPhaseEvent>.broadcast();

  /// 阶段事件流（broadcast：多组件订阅互不影响）。
  Stream<NetworkPhaseEvent> get events => _controller.stream;

  NetworkPhase get current => _current;
  NetworkPhase _current = NetworkPhase.idle;

  int _resolvingDepth = 0;
  int _bufferingDepth = 0;

  /// 进入某阶段（重复 begin 同阶段安全，计数递增）。
  void begin(NetworkPhase phase, {String detail = ''}) {
    if (phase == NetworkPhase.idle) return;
    _bump(phase, 1);
    _push(phase, detail);
  }

  /// 离开某阶段（与 begin 配对；计数归零才回落 idle）。
  void end(NetworkPhase phase) {
    if (phase == NetworkPhase.idle) return;
    _bump(phase, -1);
    _push(_current, '');
  }

  void _bump(NetworkPhase phase, int delta) {
    switch (phase) {
      case NetworkPhase.resolving:
        _resolvingDepth = (_resolvingDepth + delta).clamp(0, 1 << 30);
      case NetworkPhase.buffering:
        _bufferingDepth = (_bufferingDepth + delta).clamp(0, 1 << 30);
      case NetworkPhase.idle:
        break;
    }
    // 阶段优先级：resolving（还在拿地址）优先于 buffering 表达给用户——
    // 两者并发时（理论上不应发生）仍以更早的阶段为准。
    if (_resolvingDepth > 0) {
      _current = NetworkPhase.resolving;
    } else if (_bufferingDepth > 0) {
      _current = NetworkPhase.buffering;
    } else {
      _current = NetworkPhase.idle;
    }
  }

  void _push(NetworkPhase phase, String detail) {
    final c = _controller;
    if (c.isClosed) return;
    c.add(NetworkPhaseEvent(phase, detail: detail));
  }

  /// 对称释放（第 20 条）；仅测试场景调用，随后可重新使用。
  Future<void> dispose() async {
    final c = _controller;
    _controller = StreamController<NetworkPhaseEvent>.broadcast();
    _resolvingDepth = 0;
    _bufferingDepth = 0;
    _current = NetworkPhase.idle;
    await c.close();
  }
}
