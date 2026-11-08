/// v5.0 M6：启动编排（从 main.dart 上移，REFACTOR_PLAN_V5 §八 M6）。
///
/// main() 只负责：binding / 全局错误钩子 / Hive 开箱 / 调 [bootstrap]。
/// 启动阶段的策略（看门狗、权限、音频引擎、预加载）全部在此声明。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/audio/audio_service_bootstrap.dart';
import '../core/utils/error_logger.dart';
import '../core/utils/permission_gate.dart';
import '../core/direct/kg_providers.dart' show KgDeviceStore;

/// 启动阶段致命错误（UI 直接展示，不白屏卡死）。
Object? startupError;

/// 首帧是否已渲染（启动看门狗判定）。
bool firstFrameRendered = false;

Timer? startupWatchdog;

Future<void> openHiveBoxes() async {
  Future<void> openSafe(String name, {bool stringValues = false}) async {
    try {
      if (Hive.isBoxOpen(name)) return;
      if (stringValues) {
        await Hive.openBox<String>(name);
      } else {
        await Hive.openBox(name);
      }
    } catch (e) {
      debugPrint('[bootstrap] openBox($name) failed: $e');
    }
  }

  await openSafe(KgDeviceStore.boxName, stringValues: true);
  await openSafe('settings');
  await openSafe('accounts');
  await openSafe('recent_plays');
  await openSafe('search_history', stringValues: true);
  await openSafe('lyric_translations', stringValues: true);
  await openSafe('lyric_cache', stringValues: true);
  await openSafe('resource_json', stringValues: true);
  await openSafe('downloads');
  await openSafe('api_cache', stringValues: true);
  await openSafe('image_cache', stringValues: true);
}

/// 首帧看门狗：15 秒未出首帧则留痕（不阻塞、不杀进程）。
void startWatchdog() {
  startupWatchdog = Timer(const Duration(seconds: 15), () {
    if (!firstFrameRendered) {
      ErrorLogger.instance.log('first frame timeout', StackTrace.current,
          source: 'bootstrap', context: 'watchdog');
    }
  });
}

void markFirstFrame() {
  firstFrameRendered = true;
  startupWatchdog?.cancel();
  startupWatchdog = null;
}

/// 启动期并行：通知权限 / 音频引擎 / 日志目录（互不依赖，失败各自留痕）。
Future<void> bootstrapServices() async {
  await Future.wait<Object?>(<Future<Object?>>[
    PermissionGate.instance.ensureNotification().catchError((Object e) {
      debugPrint('[bootstrap] notification permission: $e');
      return false;
    }),
    AudioServiceBootstrap.ensureReady().catchError((Object e) {
      debugPrint('[bootstrap] audio service: $e');
      return false;
    }),
  ]);
}
