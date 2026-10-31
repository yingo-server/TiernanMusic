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

Future<void> initSettingsBox() => Hive.openBox('settings');
