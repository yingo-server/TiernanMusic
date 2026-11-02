import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'core/cache/cache_manager.dart';
import 'core/api/kugou_api_client.dart';
import 'core/direct/kg_client.dart';
import 'core/direct/kg_providers.dart';
import 'core/audio/audio_service_bootstrap.dart';
import 'core/router/app_router.dart';
import 'features/home/data/home_repository.dart' show homeDataProvider;
import 'core/theme/app_theme.dart';
import 'core/theme/settings_provider.dart';
import 'core/utils/toast.dart';
import 'core/utils/error_logger.dart';
import 'core/storage/secure_storage.dart';
import 'features/auth/data/auth_providers.dart';
import 'features/download/download_provider.dart';
import 'features/player/player_provider.dart'
    show playerErrorProvider, recentPlayRecorderProvider;
import 'l10n/l10n.dart';

/// 启动阶段致命错误（用于在 UI 上直接展示，而不是白屏卡死）
Object? _startupError;

/// 首帧是否已渲染（用于启动看门狗）
bool _firstFrameRendered = false;

/// 启动看门狗 Timer（首帧渲染后取消，避免无谓持有）
Timer? _watchdog;

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

      // 音频后台服务：这里只「发起」初始化，不阻塞首帧。
      // 播放前由 AudioServiceBootstrap.ensureReady() 等待完成。
      // （原先 await + timeout(8s) 会在超时后放弃等待，但底层仍未就绪，
      //   之后创建 AudioPlayer 必抛 LateInitializationError: _audioHandler）
      AudioServiceBootstrap.start();
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
      // 首帧已渲染，看门狗使命完成：取消以免无谓持有（W4）
      _watchdog?.cancel();
      _watchdog = null;
    });
    _watchdog = Timer(const Duration(seconds: 15), () {
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

class TiernanMusicApp extends ConsumerStatefulWidget {
  const TiernanMusicApp({super.key});

  @override
  ConsumerState<TiernanMusicApp> createState() => _TiernanMusicAppState();
}

class _TiernanMusicAppState extends ConsumerState<TiernanMusicApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 转发给下载管理器（resume 时重置写入策略缓存，见 W1/批2 下载页逻辑）
    ref.read(downloadManagerProvider.notifier).onAppLifecycle(state);
  }

  @override
  void didHaveMemoryPressure() {
    // 系统内存告警：清空进程内内存缓存
    MemoryCache.instance.clear();
  }

  /// 播放错误提示（引擎未就绪 / 权益不足 / 播放失败）
  ///
  /// 之前引擎初始化失败会静默 return，UI 停留在「播放中」假象；
  /// 现在统一通过 Toast 告知用户真实原因。
  void _onPlayerError(String message, WidgetRef ref) {
    final ctx = ref.context;
    if (!ctx.mounted) return;
    Toast.show(ctx, message);
  }

  @override
  Widget build(BuildContext context) {
    // 激活最近播放记录器（F2：监听 onSongStarted 写最近播放，全局一次即可）
    ref.watch(recentPlayRecorderProvider);
    // 播放错误统一 Toast 提示（引擎未就绪 / 权益不足 / 播放失败）
    ref.listen(playerErrorProvider, (_, next) {
      final msg = next.value;
      if (msg != null && msg.isNotEmpty) _onPlayerError(msg, ref);
    });
    // 登录态变化时同步到直连客户端（仅在有值时创建 client，避免启动期强依赖）
    ref.listen(authStateProvider, (_, next) {
      // loading 期间不做任何事（避免把已登录态误清空）
      if (next.isLoading) return;
      try {
        final client = ref.read(kgClientProvider);
        final user = next.valueOrNull;
        // 登录态变化后，首页个性化区块（每日推荐）与"我的歌单"必须重新拉取，
        // 否则登录成功返回首页仍是登录前的内容（真机反馈：登录不刷新）。
        ref.invalidate(homeDataProvider);
        // 退出登录时必须清空，否则会继续以旧账号身份请求
        client.token = user?.token ?? '';
        client.userid = user?.userid ?? '0';
        if (user == null) {
          // 退出时必须清空，否则残留旧 t1。
          client.t1 = '';
        } else {
          // W3：登录/恢复时异步补 t1（AuthUser 不携带 t1，
          // 从 SecureStorage credentials 读取），失败不阻塞。
          SecureStorage.instance.readCredentials().then((c) {
            client.t1 =
                (c != null && c.userId == user.userid) ? (c.t1 ?? '') : '';
          }).catchError((e) {
            debugPrint('[auth-sync] readCredentials failed: $e');
          });
        }
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
      // E5：用 onGenerateTitle 拿到 localization context，任务栏标题随语言切换；
      // StartupErrorPage 早退分支没有 delegates，保留硬编码。
      onGenerateTitle: (ctx) => ctx.l10n.appName,
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
