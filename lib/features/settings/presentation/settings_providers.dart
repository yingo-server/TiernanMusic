import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/domain/quality.dart';

/// 安全获取 settings box：未打开时返回 null，绝不抛异常（否则会拖垮首帧/设置页 build）。
Box<dynamic>? _box() {
  try {
    if (Hive.isBoxOpen('settings')) return Hive.box<dynamic>('settings');
  } catch (_) {}
  return null;
}

/// 默认音质：128 / 320 / flac / high / super（与 AudioQuality.value 一致）
class DefaultQualityNotifier extends StateNotifier<String> {
  DefaultQualityNotifier()
      : super((_box()?.get('defaultQuality', defaultValue: '320') as String?) ??
            '320');

  Future<void> set(String quality) async {
    state = quality;
    // v5.1 B5-C 实锤：盒未打开时 `?.` 使落盘成为 no-op——当前会话生效但
    // 重启回退，用户无感知。改为：重试一次，仍失败 debugPrint 留痕（第 9 条）。
    final box = _box() ?? await _reopen();
    if (box != null) {
      await box.put('defaultQuality', quality);
      return;
    }
    debugPrint('[settings] defaultQuality save skipped: settings box unavailable');
  }

  /// 设置页清缓存后可能关闭 settings 盒——尝试重开一次。
  Future<Box<dynamic>?> _reopen() async {
    try {
      return await Hive.openBox('settings');
    } catch (e) {
      debugPrint('[settings] reopen settings box failed: $e');
      return null;
    }
  }
}

final defaultQualityProvider =
    StateNotifierProvider<DefaultQualityNotifier, String>(
        (ref) => DefaultQualityNotifier());

/// 音质档位名称：运行时从 l10n 取（不得硬编码中文），
/// 见 settings_page.dart 的 `_qualityNames(BuildContext)`。

// V34-UI-04（修复②，P2）：删除 wifiQualityProvider / cellularQualityProvider
// （「Wi-Fi 自动最高音质 / 流量省流」预留假开关）。全项目无消费方，用户切换后
// 行为不变，属第 32 条死代码；设置页入口已同步移除。
// Hive 中遗留的 'wifiAutoHighQuality' / 'cellularLowerQuality' 键不再读取，
// 与其它已弃用设置项同口径（留在盒中不清理，避免额外迁移代码）。


