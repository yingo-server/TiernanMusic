import 'package:flutter/foundation.dart';

/// 音质等级枚举（v5.0 M1：上移 core/domain，依据 REFACTOR_PLAN §1.1——
/// 音质属领域概念，core/audio 不应依赖 features/player）。
/// 排序：super > high > flac > 320 > 128。

enum AudioQuality {
  q128('128', '标准'),
  q320('320', '高品'),
  flac('flac', '无损'),
  high('high', 'Hi-Res'),
  superQuality('super', '臻品母带'),
  // V399-B3：蝰蛇三档（/v5/url 的 quality 参数即本 wire 名）
  viperTape('viper_tape', '蝰蛇磁带'),
  viperClear('viper_clear', '蝰蛇清澈'),
  viperAtmos('viper_atmos', '蝰蛇全景'),
  // V399-B3：魔法音效六档（概念版特殊音源，匿名可用；/v5/url 需 magic_ 前缀，
  // 由 KgSharedParams.songUrl 统一补前缀）
  magicPiano('magic_piano', '魔法钢琴'),
  magicAcappella('magic_acappella', '魔法清唱'),
  magicDj('magic_dj', '魔法DJ'),
  magicSurnay('magic_surnay', '魔法Surround'),
  magicSubwoofer('magic_subwoofer', '魔法低音'),
  magicAncient('magic_ancient', '魔法复古');

  const AudioQuality(this.value, this.label);
  final String value;
  final String label;

  /// 从高到低的降级顺序。
  ///
  /// ⚠️ V399-B3：蝰蛇/魔法档是特殊音源，**不进通用降级链**
  ///（普通音质不可降为魔法/蝰蛇，魔法失败也不得落到普通档——
  /// 见任务书 B3 与 fallback 纪律）。
  static const List<AudioQuality> fallbackOrder = [
    superQuality,
    high,
    flac,
    q320,
    q128,
  ];

  /// V399-B3：蝰蛇族降级顺序（只在族内降， VIP 态实测真实返回 URL）。
  static const List<AudioQuality> viperOrder = [
    viperAtmos,
    viperClear,
    viperTape,
  ];

  /// V399-B3：魔法族展示顺序（匿名可用；不自动降级到普通档）。
  static const List<AudioQuality> magicOrder = [
    magicPiano,
    magicAcappella,
    magicDj,
    magicSurnay,
    magicSubwoofer,
    magicAncient,
  ];

  /// 是否蝰蛇档
  bool get isViper => viperOrder.contains(this);

  /// 是否魔法档
  bool get isMagic => magicOrder.contains(this);

  /// 是否特殊音源档（蝰蛇/魔法，均不进通用 fallback）
  bool get isSpecial => isViper || isMagic;

  /// 从字符串解析音质。
  ///
  /// 兼容历史/别名写法（设置页旧版本写入过 'hires'）：
  /// - 'hires' / 'Hi-Res' → high
  /// - 'master' / '母带'   → superQuality
  ///
  /// ⚠️ 若别名缺失，用户在设置页选了「Hi-Res」而实际只请求 128k
  /// （设置页显示已生效但音质没变），属于数据一致性红线。
  static AudioQuality fromString(String? s) {
    if (s == null) return q128;
    final v = s.trim().toLowerCase();
    for (final q in values) {
      if (q.value == v) return q;
    }
    switch (v) {
      case 'hires':
      case 'hi-res':
      case 'hiresample':
        return high;
      case 'master':
      case '母带':
      case '臻品':
        return superQuality;
      // V399-B3：蝰蛇/魔法档显式解析。魔法档 wire 名带 magic_ 前缀
      //（/v5/url 参数用），枚举 value 同名，直接按 value 命中即可；
      // 兼容无前缀写法（旧设置残留）。
    }
    // V399-B3：魔法档无前缀兼容（'piano' → magic_piano）
    for (final q in magicOrder) {
      if (q.value == 'magic_$v') return q;
    }
    return q128;
  }
}
