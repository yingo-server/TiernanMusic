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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  await initSettingsBox();

  // 设备身份（固定，持久化在 box 'device'）
  final deviceBox = await Hive.openBox<String>(KgDeviceStore.boxName);
  final device = KgDeviceStore.loadSync(deviceBox);

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.tiernan.music.channel.audio',
    androidNotificationChannelName: '汀澜音乐播放',
    androidNotificationOngoing: true,
  );

  runApp(ProviderScope(
    overrides: [kgDeviceProvider.overrideWithValue(device)],
    child: const TiernanMusicApp(),
  ));
}

class TiernanMusicApp extends ConsumerWidget {
  const TiernanMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 登录态变化时同步到直连客户端
    ref.listen(authStateProvider, (_, next) {
      final user = next.value;
      final client = ref.read(kgClientProvider);
      client.token = user?.token ?? '';
      client.userid = user?.userid ?? '0';
    });

    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

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
    );
  }
}
