import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'core/cache/cache_manager.dart';
import 'features/library/presentation/library_page.dart'
    show libraryUserPlaylistsProvider, libraryCollectedMvsProvider;
import 'core/api/kugou_api_client.dart';
import 'core/direct/kg_client.dart';
import 'core/direct/kg_providers.dart';
import 'core/audio/audio_service_bootstrap.dart';
import 'core/router/app_router.dart';
import 'features/home/data/home_repository.dart' show homeDataProvider;
import 'core/theme/app_theme.dart';
import 'core/theme/settings_provider.dart';
import 'core/widgets/splash_handwriting.dart' show HandwritingCycle;
import 'core/widgets/splash_screen.dart';
import 'core/utils/toast.dart';
import 'core/utils/error_logger.dart';
import 'core/utils/permission_gate.dart';
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
    // V35-C3（第 C 批，P2）：加「重启应用」按钮——此前 ErrorWidget.builder
    // 全局替换后任何 build 异常都落在不可交互的静态页，整页死锁只能杀
    // 进程（第 9 条：失败必须给出下一步动作）。
    ErrorWidget.builder = (details) => StartupErrorPage(
      error: details.exception,
      compact: true,
      onRestart: () => main(),
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
  /// 启动准备是否完成（完成后才从 SplashScreen 切到主界面）
  bool _appReady = false;

  /// V33-04（修复②）：启动屏最短展示是否已到。
  ///
  /// 原先 _appReady 在首帧的 post-frame 回调里立刻置 true，SplashScreen
  /// 实际只活一帧——手写动画连起笔都看不到。这里加一个「下限」：
  /// 只有 HandwritingCycle.minVisible（写完 + 停一拍）之后才允许切走。
  /// 该计时发生在首帧渲染之后，不阻塞 main()、不阻塞首帧（第 20 条：
  /// Timer 在本 State 的 dispose 内对称取消）。
  bool _splashMinElapsed = false;
  Timer? _splashTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧后再标记就绪，确保 SplashScreen 至少绘制一帧（可见动画）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _appReady = true);
      // V37-PLAY-02：Android 13+ 通知运行时权限（POST_NOTIFICATIONS）——
      // manifest 里声明了权限但没有运行时申请，Android 13+ 上默认拒绝，
      // 媒体通知不显示（锁屏/通知栏控制全部失效，后台播放状态不可见）。
      // 首帧后非阻塞申请一次（fire-and-forget；系统只在合适时机弹一次，
      // 永久拒绝时 StoragePermissionService 会引导系统设置页）。
      unawaited(PermissionGate.instance.ensureNotification());
    });
    _splashTimer = Timer(HandwritingCycle.minVisible, () {
      if (mounted) setState(() => _splashMinElapsed = true);
    });
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
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
    // V37-LOG-03（v3.7 日志批）：verbose 日志开关同步到 ErrorLogger
    // 静态总开关（setVerbose 幂等，verbose 关时为无操作）。
    ErrorLogger.setVerbose(ref.watch(verboseLoggingProvider));
    // 激活最近播放记录器（F2：监听 onSongStarted 写最近播放，全局一次即可）
    ref.watch(recentPlayRecorderProvider);
    // 播放错误统一 Toast 提示（引擎未就绪 / 权益不足 / 播放失败）
    ref.listen(playerErrorProvider, (_, next) {
      final msg = next.value;
      if (msg != null && msg.isNotEmpty) _onPlayerError(msg, ref);
    });
    // 登录态世代号（V35-A3：重试闭包捕获旧 next 的问题在这里根治）——
    // 每次 listen 回调递增，重试前校验自己是否仍是最新事件（第 18 条）。
    var authEventGeneration = 0;
    ref.listen(authStateProvider, (_, next) {
      // loading 期间不做任何事（避免把已登录态误清空）
      if (next.isLoading) return;
      final generation = ++authEventGeneration;
      // V34-C-02（v3.4 审查③，P1）：整个同步体不再套单一空 catch——
      // 此前 `ref.read(kgClientProvider)` 在冷启动恢复期 provider 未就绪
      // 会抛异常，**连同后面的 invalidate 一起被跳过** → token 丢失且
      // 首页/库页不刷新，无补偿。改为各步骤独立防护 + 失败重试一次。
      void applyAuth() {
        final client = ref.read(kgClientProvider);
        final user = next.valueOrNull;
        ref.invalidate(homeDataProvider);
        ref.invalidate(libraryUserPlaylistsProvider);
        ref.invalidate(libraryCollectedMvsProvider);
        client.token = user?.token ?? '';
        client.userid = user?.userid ?? '0';
        // V34-C-03（v3.4 审查③，P1）：切号/登出必须清 MemoryCache——
        // 缓存键不含用户身份维度（B-15 同根），不清则 90 秒内跨账号串
        // 数据（A 的歌单/每日推荐显示给 B）。登录/登出/切号都走这里。
        MemoryCache.instance.clear();
        if (user == null) {
          client.t1 = '';
        } else {
          SecureStorage.instance.readCredentials().then((c) {
            client.t1 =
                (c != null && c.userId == user.userid) ? (c.t1 ?? '') : '';
          }).catchError((e) {
            debugPrint('[auth-sync] readCredentials failed: $e');
          });
        }
      }

      try {
        applyAuth();
      } catch (e) {
        // 冷启动竞态（provider 未就绪）：延迟一帧重试一次（第 11 条：
        // 降级须有恢复条件），仍失败才留痕放弃。
        debugPrint('[auth-sync] deferred retry after: $e');
        Future.delayed(const Duration(milliseconds: 200), () {
          // V35-A3（第 A 批，P2）：重试前必须校验世代——200ms 窗口内
          // 若来了新 auth 事件（restoreSession 落定/用户登出），旧事件
          // 的重试会把新 token 回滚为旧值（违反第 18 条：异步结果
          // 未校验世代；恰好发生在登录成功瞬间最拥挤的时序）。
          if (generation != authEventGeneration) {
            debugPrint('[auth-sync] retry skipped (stale generation $generation)');
            return;
          }
          try {
            applyAuth();
          } catch (e2) {
            debugPrint('[auth-sync] retry failed: $e2');
          }
        });
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
      builder: (context, child) {
        // V33-04：就绪 + 最短展示时长都满足才退出启动屏。
        if (!_appReady || !_splashMinElapsed) return const SplashScreen();
        return child ?? const SizedBox.shrink();
      },
    );
  }
}

/// 启动/构建异常兜底页
class StartupErrorPage extends StatelessWidget {
  const StartupErrorPage(
      {super.key, required this.error, this.compact = false, this.onRestart});

  final Object error;
  final bool compact;

  /// V35-C3（第 C 批，P2）：ErrorWidget.builder 场景传入重启入口，
  /// 避免 build 异常后整页死锁只能杀进程。
  final VoidCallback? onRestart;

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
                if (onRestart != null) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onRestart,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重启应用'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
