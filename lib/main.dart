import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/direct/kg_client.dart';
import 'core/direct/kg_providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/settings_provider.dart';
import 'features/auth/data/auth_providers.dart';
import 'l10n/l10n.dart';

/// 启动阶段致命错误（用于在 UI 上直接展示，而不是白屏卡死）
Object? _startupError;

Future<void> main() async {
  // 任何未捕获异常都记录下来，保证仍能 runApp 显示错误页
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('[startup] FlutterError: ${details.exception}');
    };

    // 任何构建异常都显示可读错误页，而不是红屏/白屏
    ErrorWidget.builder = (details) => StartupErrorPage(
      error: details.exception,
      compact: true,
    );

    KgDevice? device;
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

    runApp(
      ProviderScope(
        overrides: [kgDeviceProvider.overrideWithValue(device!)],
        child: const TiernanMusicApp(),
      ),
    );
  }, (error, stack) {
    // runZonedGuarded 捕获的异步异常：记录，不崩溃
    debugPrint('[runtime] uncaught: $error\n$stack');
  });
}

class TiernanMusicApp extends ConsumerWidget {
  const TiernanMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 登录态变化时同步到直连客户端（仅在有值时创建 client，避免启动期强依赖）
    ref.listen(authStateProvider, (_, next) {
      final user = next.value;
      if (user == null) return;
      try {
        final client = ref.read(kgClientProvider);
        client.token = user.token;
        client.userid = user.userid;
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
