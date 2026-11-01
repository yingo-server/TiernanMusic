import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'kg_client.dart';
import 'kg_direct_api_client.dart';
import 'kg_play_api.dart';

/// 设备身份持久化（Hive box 'device'，单条 key 'kg'）
///
/// 首次启动生成并固定，避免每次请求被判定为新设备。
///
/// 【新增】提供同步的 [loadSync] / [saveSync]：设备注册成功拿到 dfid 后，
/// 需要**立刻**把新的 dfid 落盘（异步 put 不保证在进程被杀前完成），
/// 下次启动才不会丢 dfid。
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

  /// 同步保存（注册成功拿到 dfid 后调用）
  static void saveSync(Box<String> box, KgDevice device) {
    box.put(_key, jsonEncode(device.toJson()));
  }

  static Future<void> save(Box<String> box, KgDevice device) =>
      box.put(_key, jsonEncode(device.toJson()));

  /// 取出已 open 的 device box；未打开返回 null
  static Box<String>? openBox() {
    try {
      if (Hive.isBoxOpen(boxName)) return Hive.box<String>(boxName);
    } catch (_) {}
    return null;
  }

  /// 持久化单个 dfid（不覆盖其它设备字段）
  static bool saveDfidSync(String dfid) {
    if (dfid.isEmpty) return false;
    final box = openBox();
    if (box == null) return false;
    try {
      final raw = box.get(_key);
      Map<String, dynamic> json = <String, dynamic>{};
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) json = decoded;
      }
      json['dfid'] = dfid;
      box.put(_key, jsonEncode(json));
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 设备（main() 中 override）
final kgDeviceProvider = Provider<KgDevice>((ref) {
  // 兜底：main() 正常时永远会被 override；此处仅为防崩
  // （内存临时设备，不持久化，避免单点故障拖垮整条客户端链路）
  return KgDevice.generate();
});

/// 直连客户端（main() 中 override，或由设备派生）
final kgClientProvider = Provider<KgClient>((ref) {
  final client = KgClient(device: ref.watch(kgDeviceProvider));
  // 注册成功后把 dfid 落盘到 Hive 'device' box
  client.onDfidRegistered = (dfid) {
    KgDeviceStore.saveDfidSync(dfid);
  };
  return client;
});

/// 直连播放接口
final kgPlayApiProvider =
    Provider<KgPlayApi>((ref) => KgPlayApi(ref.watch(kgClientProvider)));

/// 直连内容客户端（替代 kapi 中转）
final kgDirectApiProvider = Provider<KgDirectApiClient>((ref) {
  return KgDirectApiClient(ref.watch(kgClientProvider));
});
