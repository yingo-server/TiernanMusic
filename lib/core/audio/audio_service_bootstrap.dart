import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_background/just_audio_background.dart';

/// 音频后台服务引导器。
///
/// 【为什么需要它】
/// `just_audio_background` 在 `AudioPlayer` 首次激活平台通道时会读取它自己的
/// `_audioHandler` late 字段。若 `JustAudioBackground.init()` 尚未完成（比如
/// 启动时被 timeout 放弃、或系统服务启动慢），创建/使用 AudioPlayer 就会抛出：
///
///   LateInitializationError: Field '_audioHandler@...' has not been initialized.
///
/// 表现为：点播放直接没声音/卡住，且每次播放都刷一条崩溃日志。
///
/// 【做法】
/// - 启动时只「发起」初始化，不阻塞首帧（[start]）；
/// - 真正播放前用 [ensureReady] 等待它完成；
/// - 初始化失败时明确返回 false，由调用方给出友好错误，**绝不**再去创建
///   AudioPlayer（那一定会崩）。
class AudioServiceBootstrap {
  AudioServiceBootstrap._();

  static Future<bool>? _future;
  static bool _ready = false;
  static Object? _error;

  /// 初始化是否已完成且成功。
  static bool get isReady => _ready;

  /// 初始化失败时的错误（未失败为 null）。
  static Object? get error => _error;

  /// 启动期调用：只发起，不等待（不阻塞首帧）。
  static void start() {
    _ensureStarted();
  }

  static Future<bool> _ensureStarted() {
    // B-33（第7批复核③）：init 失败的 Future 被 _future 永久缓存，
    // 本进程内所有后续播放都撞同一个失败——只能杀进程重启。
    // 改为失败时置 null 允许重试（第 11 条：降级须有恢复条件）。
    final f = _future ??= _init();
    return f.whenComplete(() {
      if (_ready == false) _future = null;
    });
  }

  static Future<bool> _init() async {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.tiernan.music.channel.audio',
        androidNotificationChannelName: '汀澜音乐播放',
        androidNotificationOngoing: true,
      );
      _ready = true;
      return true;
    } catch (e, st) {
      _error = e;
      _ready = false;
      debugPrint('[audio] JustAudioBackground.init failed: $e\n$st');
      return false;
    }
  }

  /// 播放前调用：等待初始化完成（成功返回 true）。
  ///
  /// 不做超时放弃——超时只是「不再等」，底层 future 仍在跑，之后创建
  /// AudioPlayer 依然会撞上未初始化的 `_audioHandler`。要么等到成功，
  /// 要么拿到明确的失败。
  static Future<bool> ensureReady() async {
    final f = _ensureStarted();
    try {
      return await f;
    } catch (_) {
      return false;
    }
  }
}
