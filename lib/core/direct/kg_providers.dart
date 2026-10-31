import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'kg_client.dart';
import 'kg_direct_api_client.dart';
import 'kg_play_api.dart';

/// 设备身份持久化（Hive box 'device'，单条 key 'kg'）
///
/// 首次启动生成并固定，避免每次请求被判定为新设备。
class KgDeviceStore {
  KgDeviceStore._();
  static final instance = KgDeviceStore._();

  static const boxName = 'device';
  static const _key = 'kg';

  /// 同步加载（Hive 已 open 后可用），首次无记录则生成并保存
  static KgDevice loadSync(Box<String> box) {
    final raw = box.get(_key);
    if (raw != null) {
      try {
        return KgDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    final device = KgDevice.generate();
    box.put(_key, jsonEncode(device.toJson()));
    return device;
  }

  static Future<void> save(Box<String> box, KgDevice device) =>
      box.put(_key, jsonEncode(device.toJson()));
}

/// 设备（main() 中 override）
final kgDeviceProvider = Provider<KgDevice>((ref) {
  throw UnimplementedError('kgDeviceProvider 需在 main() 中 override');
});

/// 直连客户端（main() 中 override，或由设备派生）
final kgClientProvider = Provider<KgClient>((ref) {
  return KgClient(device: ref.watch(kgDeviceProvider));
});

/// 直连播放接口
final kgPlayApiProvider =
    Provider<KgPlayApi>((ref) => KgPlayApi(ref.watch(kgClientProvider)));

/// 直连内容客户端（替代 kapi 中转）
final kgDirectApiProvider = Provider<KgDirectApiClient>((ref) {
  return KgDirectApiClient(ref.watch(kgClientProvider));
});
