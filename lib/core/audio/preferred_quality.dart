import 'package:hive/hive.dart';

import '../domain/quality.dart';
import '../../features/player/data/models.dart';

/// 用户设置的默认音质（单一事实源）。
///
/// 播放与下载共用此读取器，避免「设置里选了 320，下载却是 128」的不一致。
AudioQuality preferredQuality() {
  try {
    if (Hive.isBoxOpen('settings')) {
      final v = Hive.box<dynamic>('settings').get('defaultQuality');
      if (v is String) return AudioQuality.fromString(v);
    }
  } catch (_) {
    // box 未打开或读取异常 → 用默认
  }
  return AudioQuality.q320;
}
