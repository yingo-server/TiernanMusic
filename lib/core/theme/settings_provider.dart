import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';


final _settingsBoxProvider = Provider<Box<dynamic>?>(
  (ref) {
    try {
      if (Hive.isBoxOpen('settings')) return Hive.box<dynamic>('settings');
    } catch (_) {}
    return null; // 未打开时降级为内存态，绝不抛异常卡首屏
  },
);

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._box) : super(_load(_box));

  final Box<dynamic>? _box;
  static const _key = 'themeMode';

  static ThemeMode _load(Box<dynamic>? box) {
    final v = box?.get(_key, defaultValue: 'dark') as String? ?? 'dark';
    return switch (v) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _box?.put(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    });
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(ref.watch(_settingsBoxProvider)),
);

class LocaleNotifier extends StateNotifier<Locale?> {
  LocaleNotifier(this._box) : super(_load(_box));

  final Box<dynamic>? _box;
  static const _key = 'locale';

  /// null = 跟随系统
  static Locale? _load(Box<dynamic>? box) {
    final v = box?.get(_key) as String?;
    if (v == null || v == 'system') return null;
    final parts = v.split('_');
    return parts.length == 2
        ? Locale(parts[0], parts[1])
        : Locale(parts[0]);
  }

  Future<void> set(Locale? locale) async {
    state = locale;
    if (locale == null) {
      await _box?.put(_key, 'system');
    } else {
      final code = locale.countryCode != null
          ? '${locale.languageCode}_${locale.countryCode}'
          : locale.languageCode;
      await _box?.put(_key, code);
    }
  }
}

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale?>(
  (ref) => LocaleNotifier(ref.watch(_settingsBoxProvider)),
);

/// 歌词显示模式
enum LyricDisplayMode { original, bilingual, translation }

class LyricModeNotifier extends StateNotifier<LyricDisplayMode> {
  LyricModeNotifier(this._box) : super(_load(_box));
  final Box<dynamic>? _box;
  static const _key = 'lyricDisplayMode';

  static LyricDisplayMode _load(Box<dynamic>? box) {
    final v = box?.get(_key, defaultValue: 'bilingual') as String? ?? 'bilingual';
    return LyricDisplayMode.values.firstWhere(
      (e) => e.name == v,
      orElse: () => LyricDisplayMode.bilingual,
    );
  }

  Future<void> set(LyricDisplayMode mode) async {
    state = mode;
    await _box?.put(_key, mode.name);
  }
}

final lyricModeProvider =
    StateNotifierProvider<LyricModeNotifier, LyricDisplayMode>(
  (ref) => LyricModeNotifier(ref.watch(_settingsBoxProvider)),
);

// V37-LOG-01（v3.7 日志批）：verbose 日志开关。
//
// 采用与同文件 themeMode / locale / lyricMode 一致的 StateNotifier 模式
// （而非裸 StateProvider）：初值须从 Hive 读盘（第 5 条状态单一来源——
// Hive 与内存不可并存两份可写副本），setter 持久化写回。
class VerboseLoggingNotifier extends StateNotifier<bool> {
  VerboseLoggingNotifier(this._box) : super(_load(_box));

  final Box<dynamic>? _box;
  static const _key = 'verboseLogging';

  static bool _load(Box<dynamic>? box) =>
      box?.get(_key, defaultValue: false) as bool? ?? false;

  Future<void> set(bool value) async {
    state = value;
    await _box?.put(_key, value);
  }
}

final verboseLoggingProvider =
    StateNotifierProvider<VerboseLoggingNotifier, bool>(
  (ref) => VerboseLoggingNotifier(ref.watch(_settingsBoxProvider)),
);

Future<void> initSettingsBox() => Hive.openBox('settings');
