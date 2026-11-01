import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

import 'core/api/kugou_api_client.dart';
import 'core/direct/kg_client.dart';
import 'core/direct/kg_providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/settings_provider.dart';
import 'core/utils/error_logger.dart';
import 'features/auth/data/auth_providers.dart';
import 'l10n/l10n.dart';

/// 启动阶段致命错误（用于在 UI 上直接展示，而不是白屏卡死）
Object? _startupError;

/// 首帧是否已渲染（用于启动看门狗）
bool _firstFrameRendered = false;

Future<void> main() async {
  // 任何未捕获异常都记录下来，保证仍能 runApp 显示错误页
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      ErrorLogger.instance.handleFlutterError(details);
    };

    // 任何构建异常都显示可读错误页，而不是红屏/白屏
    ErrorWidget.builder = (details) => StartupErrorPage(
      error: details.exception,
      compact: true,
    );

    KgDevice? device;

    // 整个「启动准备」阶段都包在 try 里：任何未预期异常都不得阻止 runApp，
    // 否则原生启动屏（LaunchTheme）永远不会被 Flutter 首帧替换 —— 表现为「卡在第一屏」。
    try {
      try {
        await Hive.initFlutter();
      } catch (e, st) {
        debugPrint('[startup] Hive.initFlutter failed: $e\n$st');
      }

      // 逐个 box 打开，单个失败不影响启动
      Future<void> openSafe(String name, {bool stringValues = false}) async {
        try {
          if (stringValues) {
            await Hive.openBox<String>(name);
          } else {
            await Hive.openBox<dynamic>(name);
          }
        } catch (e) {
          debugPrint('[startup] openBox($name) failed: $e');
        }
      }

      await openSafe(KgDeviceStore.boxName, stringValues: true);
      await openSafe('settings');
      await openSafe('accounts');
      await openSafe('recent_plays');
      await openSafe('search_history', stringValues: true);
      await openSafe('lyric_translations', stringValues: true);
      await openSafe('downloads');

      // Cookie 持久化目录（应用私有存储，三层存储规范第 2 层）。
      // 必须是可写目录，否则 PersistCookieJar 会报「Read-only file system」。
      try {
        final docs = await getApplicationDocumentsDirectory();
        final cookieDir = Directory('${docs.path}/cookies');
        if (!await cookieDir.exists()) await cookieDir.create(recursive: true);
        KugouApiClient.cookieStoragePath = cookieDir.path;
      } catch (e) {
        debugPrint('[startup] cookie dir init failed: $e');
      }

      // 设备身份（box 未开时用内存默认值兜底，绝不阻塞启动）
      try {
        final box = Hive.isBoxOpen(KgDeviceStore.boxName)
            ? Hive.box<String>(KgDeviceStore.boxName)
            : null;
        device = box != null
            ? KgDeviceStore.loadSync(box)
            : KgDevice.generate();
      } catch (e) {
        debugPrint('[startup] device init failed: $e');
        device = KgDevice.generate();
      }

      // 音频后台服务：失败不阻塞（否则整机白屏）
      try {
        await JustAudioBackground.init(
          androidNotificationChannelId: 'com.tiernan.music.channel.audio',
          androidNotificationChannelName: '汀澜音乐播放',
          androidNotificationOngoing: true,
        ).timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('[startup] JustAudioBackground.init failed: $e');
      }
    } catch (e, st) {
      // 兜底：准备阶段出现任何未预期异常，记录并继续 runApp（不让启动屏卡死）
      _startupError = e;
      debugPrint('[startup] preparation failed: $e\n$st');
    }

    // 设备身份最终兜底：device 为 null 时（极端情况）再尝试一次
    if (device == null) {
      try {
        device = KgDevice.generate();
      } catch (e) {
        _startupError ??= e;
        debugPrint('[startup] device fallback failed: $e');
      }
    }
    if (device == null) {
      // 仍失败：写入 startupError 让 UI 显示错误页，而不是让 override 崩溃
      _startupError ??= StateError('设备身份初始化失败');
    }

    // 无论如何都要 runApp —— 保证首帧渲染，原生启动屏才会消失
    final dev = device;
    final overrides = <Override>[
      if (dev != null) kgDeviceProvider.overrideWithValue(dev),
    ];

    try {
      runApp(
        ProviderScope(
          overrides: overrides,
          child: const TiernanMusicApp(),
        ),
      );
    } catch (e, st) {
      debugPrint('[startup] runApp failed: $e\n$st');
    }

    // 启动看门狗：15 秒内首帧未渲染则记录日志（不阻塞 UI）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _firstFrameRendered = true;
      debugPrint('[startup] first frame rendered');
    });
    Timer(const Duration(seconds: 15), () {
      if (!_firstFrameRendered) {
        debugPrint(
          '[startup][watchdog] 15 秒内未渲染首帧，疑似卡在启动屏。'
          'startupError=$_startupError',
        );
      }
    });
  }, (error, stack) {
    // runZonedGuarded 捕获的异步异常：落盘记录，不崩溃
    ErrorLogger.instance.handleUncaught(error, stack);
  });
}

class TiernanMusicApp extends ConsumerWidget {
  const TiernanMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 登录态变化时同步到直连客户端（仅在有值时创建 client，避免启动期强依赖）
    ref.listen(authStateProvider, (_, next) {
      // loading 期间不做任何事（避免把已登录态误清空）
      if (next.isLoading) return;
      try {
        final client = ref.read(kgClientProvider);
        final user = next.value;
        // 退出登录时必须清空，否则会继续以旧账号身份请求
        client.token = user?.token ?? '';
        client.userid = user?.userid ?? '0';
        // AuthUser 不携带 t1：登录/恢复时由 loginByToken → cookie 刷新；
        // 退出（user == null）时必须清空，否则残留旧 t1。
        if (user == null) client.t1 = '';
      } catch (e) {
        debugPrint('[auth-sync] $e');
      }
    });

    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

    if (_startupError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: StartupErrorPage(error: _startupError!),
      );
    }

    return MaterialApp.router(
      title: '汀澜音乐',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) => child ?? const SizedBox.shrink(),
    );
  }
}

/// 启动/构建异常兜底页
class StartupErrorPage extends StatelessWidget {
  const StartupErrorPage({super.key, required this.error, this.compact = false});

  final Object error;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1622),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 56, color: Color(0xFF00D4FF)),
                const SizedBox(height: 16),
                const Text(
                  '应用启动异常',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
