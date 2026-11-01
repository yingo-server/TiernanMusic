import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// 安全获取 settings box：未打开时返回 null，绝不抛异常（否则会拖垮首帧/设置页 build）。
Box<dynamic>? _box() {
  try {
    if (Hive.isBoxOpen('settings')) return Hive.box<dynamic>('settings');
  } catch (_) {}
  return null;
}

/// 默认音质：128 / 320 / flac / hires
class DefaultQualityNotifier extends StateNotifier<String> {
  DefaultQualityNotifier()
      : super((_box()?.get('defaultQuality', defaultValue: '320') as String?) ??
            '320');

  Future<void> set(String quality) async {
    state = quality;
    await _box()?.put('defaultQuality', quality);
  }
}

final defaultQualityProvider =
    StateNotifierProvider<DefaultQualityNotifier, String>(
        (ref) => DefaultQualityNotifier());

/// 音质档位名称：运行时从 l10n 取（不得硬编码中文），
/// 见 settings_page.dart 的 `_qualityNames(BuildContext)`。

/// WIFI 下自动使用最高音质（预留策略开关）
class WifiQualityNotifier extends StateNotifier<bool> {
  WifiQualityNotifier()
      : super((_box()?.get('wifiAutoHighQuality', defaultValue: true) as bool?) ??
            true);

  Future<void> set(bool value) async {
    state = value;
    await _box()?.put('wifiAutoHighQuality', value);
  }
}

final wifiQualityProvider = StateNotifierProvider<WifiQualityNotifier, bool>(
    (ref) => WifiQualityNotifier());

/// 流量下降低音质（预留策略开关）
class CellularQualityNotifier extends StateNotifier<bool> {
  CellularQualityNotifier()
      : super((_box()?.get('cellularLowerQuality', defaultValue: false)
                as bool?) ??
            false);

  Future<void> set(bool value) async {
    state = value;
    await _box()?.put('cellularLowerQuality', value);
  }
}

final cellularQualityProvider =
    StateNotifierProvider<CellularQualityNotifier, bool>(
        (ref) => CellularQualityNotifier());


