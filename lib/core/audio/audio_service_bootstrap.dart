import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_background/just_audio_background.dart';
import '../../features/player/data/audio_handler.dart';
import '../../features/player/data/player_repository.dart';
import '../api/kugou_api_client.dart';

import '../utils/error_logger.dart';

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
      // V37-PLAY-1（用户真机反馈「播放页全空白」根因）：JustAudioBackground
      // 的 init **必须传入 handler**——否则后台服务启动后没有任何
      // AudioHandler 挂载，AudioPlayer 创建的通知/媒体会话是「孤儿」，
      // 播放流程静默失败、播放页 song==null 全空白。此前缺 `handler:`
      // 与 `androidNotificationChannelDescription` 参数。
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.tiernan.music.channel.audio',
        androidNotificationChannelName: '汀澜音乐播放',
        androidNotificationChannelDescription: '后台播放控制与通知',
        androidNotificationOngoing: true,
        handler: TiernanAudioHandler(PlayerRepository(
          // V37-PLAY-1：init 阶段尚无 ProviderContainer 可读，直接构造。
          // handler 内部 _ref 可空（见 player_provider），repository 的
          // 网络调用发生在 resolveUrl（播放时），那时容器已就绪。
          KugouApiClient(),
        )),
      );
      _ready = true;
      return true;
    } catch (e, st) {
      _error = e;
      _ready = false;
      // V37-PERM-01：init 失败此前只 debugPrint（release 下用户不可见、
      // ErrorLogger 文件里也没有），是「播放失败且无日志」盲区的直接补口
      // （第 9 条：失败必须可观测）。必须 import dart:async 的 unawaited。
      unawaited(ErrorLogger.instance.log(
        e,
        st,
        source: 'audio_bootstrap',
        context: 'JustAudioBackground.init failed',
      ));
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
