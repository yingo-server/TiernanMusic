/// v5.3 P1（A-00 定案）：音频后台服务引导器。
///
/// ## 为什么不再用 just_audio_background
/// 旧实现 `JustAudioBackground.init()` 内部自己调一次 `AudioService.init`
/// 并注册 `_PlayerAudioHandler`；App 侧又 `new TiernanAudioHandler(...)`，
/// 两套媒体会话互不相通（通知栏「下一首」静默无效、划掉通知不回传）。
/// `audio_service` 的 `AudioService.init` 有 `assert(_cacheManager == null)`
/// 且 `_handler` 是进程内单例，**不能调用两次**。
///
/// 定案：本文件成为全仓唯一一处 `AudioService.init`，builder 返回一个
/// [SwitchAudioHandler] 作为桥。这样：
/// - main() 早期即可注册系统媒体会话（冷启动媒体按钮可唤醒 App）；
/// - Riverpod 就绪后 [attach] 把唯一的 `TiernanAudioHandler` 设为 inner，
///   系统指令与 App 状态共用同一 Handler（单一事实源）；
/// - attach 之前系统指令落到临时 [BaseAudioHandler]（no-op），不会崩。
///
/// 所有配置参数沿用旧 `JustAudioBackground.init` 的定值，避免通知渠道 ID
/// 变更导致用户设备上出现两个渠道。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../utils/error_logger.dart';

/// [attach] 的显式约束：core 层只认 AudioHandler 能力，
/// 不得反向依赖 features/player（原则 4 / CI 架构断言）。
typedef AudioHandlerFactory = AudioHandler Function();

class AudioServiceBootstrap {
  AudioServiceBootstrap._();

  static Future<bool>? _future;
  static bool _ready = false;
  static Object? _error;

  /// 注册阶段创建的桥（进程内唯一）。
  static SwitchAudioHandler? _switcher;

  /// Riverpod 先于 init 完成时暂存 Handler，init 成功后自动挂上，
  /// 避免「attach 早于 init」被永久丢弃（原则 18/20）。
  static AudioHandler? _pendingHandler;

  /// init 完成且成功。
  static bool get isReady => _ready;

  /// init 失败原因（成功后清空）。
  static Object? get error => _error;

  /// 把真正的业务 Handler 挂到媒体会话桥上。
  ///
  /// 幂等：同一实例重复 attach 无副作用；重建 Handler 时重新订阅由
  /// SwitchAudioHandler.inner setter 对称完成（原则 20）。
  static void attach(AudioHandler handler) {
    _pendingHandler = handler;
    final s = _switcher;
    if (s == null) {
      // 启动期只发起 init，不阻塞首帧；这里等它完成后自动 attach。
      unawaited(_ensureStarted().then((ok) {
        if (ok) _applyPending();
      }));
      return;
    }
    _applyPending();
  }

  static void _applyPending() {
    final s = _switcher;
    final h = _pendingHandler;
    if (s == null || h == null || identical(s.inner, h)) return;
    s.inner = h;
  }

  /// 启动期调用：只发起，不等待（不阻塞首帧）。
  static void start() {
    unawaited(_ensureStarted());
  }

  static Future<bool> _ensureStarted() {
    final f = _future ??= _init();
    return f.whenComplete(() {
      if (!_ready) _future = null; // 失败允许重试（原则 11 恢复条件）
    });
  }

  static Future<bool> _init() async {
    try {
      // 与旧 JustAudioBackground.init 逐项对齐的通知配置。
      final switcher = await AudioService.init<SwitchAudioHandler>(
        builder: () => SwitchAudioHandler(BaseAudioHandler()),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.tiernan.music.channel.audio',
          androidNotificationChannelName: '汀澜音乐播放',
          androidNotificationChannelDescription: '后台播放控制与通知',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        ),
      );
      _switcher = switcher;
      _error = null;
      _ready = true;
      _applyPending();
      return true;
    } catch (e, st) {
      _error = e;
      _ready = false;
      unawaited(ErrorLogger.instance.log(
        e,
        st,
        source: 'audio_bootstrap',
        context: 'AudioService.init failed',
      ));
      debugPrint('[audio] AudioService.init failed: $e\n$st');
      return false;
    }
  }

  /// 播放前调用：等待 init 完成（成功 true / 失败 false）。
  ///
  /// 不做「超时后放弃但仍创建 AudioPlayer」——那正是旧版
  /// LateInitializationError 的根因。要么等到成功，要么拿到明确失败。
  static Future<bool> ensureReady() async {
    try {
      return await _ensureStarted();
    } catch (_) {
      return false;
    }
  }
}
