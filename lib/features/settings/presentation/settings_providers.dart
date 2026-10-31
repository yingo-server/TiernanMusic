import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/config/app_config.dart';

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

/// 音质档位名称
const Map<String, String> qualityNames = {
  '128': '标准音质 128K',
  '320': '高品质 320K',
  'flac': '无损音质 FLAC',
  'hires': 'Hi-Res 高解析',
};

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

/// 酷狗 API 地址
class KugouApiNotifier extends StateNotifier<String> {
  KugouApiNotifier()
      : super((_box()?.get('kugouApiBase',
                    defaultValue: AppConfig.kugouApiBase) as String?) ??
            AppConfig.kugouApiBase);

  Future<void> set(String url) async {
    state = url;
    await _box()?.put('kugouApiBase', url);
  }

  Future<void> reset() => set(AppConfig.kugouApiBase);
}

final kugouApiProvider = StateNotifierProvider<KugouApiNotifier, String>(
    (ref) => KugouApiNotifier());

/// 翻译 API 地址
class TranslateApiNotifier extends StateNotifier<String> {
  TranslateApiNotifier()
      : super((_box()?.get('translateApiBase',
                    defaultValue: AppConfig.translateApiBase) as String?) ??
            AppConfig.translateApiBase);

  Future<void> set(String url) async {
    state = url;
    await _box()?.put('translateApiBase', url);
  }

  Future<void> reset() => set(AppConfig.translateApiBase);
}

final translateApiProvider =
    StateNotifierProvider<TranslateApiNotifier, String>(
        (ref) => TranslateApiNotifier());
