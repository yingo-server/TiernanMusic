import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../features/auth/data/auth_providers.dart';
import 'kg_client.dart';
import 'kg_play_api.dart';

/// 设备身份持久化（Hive box 'device'，单条 key 'kg'）
///
/// 首次启动生成并固定，避免每次请求被判定为新设备。
class KgDeviceStore {
  KgDeviceStore._();
  static final instance = KgDeviceStore._();

  static const _boxName = 'device';
  static const _key = 'kg';

  Box<String>? _box;

  Future<Box<String>> _open() async =>
      _box ??= await Hive.openBox<String>(_boxName);

  Future<KgDevice> load() async {
    final box = await _open();
    final raw = box.get(_key);
    if (raw != null) {
      try {
        return KgDevice.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    final device = KgDevice.generate();
    await save(device);
    return device;
  }

  Future<void> save(KgDevice device) async {
    final box = await _open();
    await box.put(_key, jsonEncode(device.toJson()));
  }
}

/// 全局设备
final kgDeviceProvider = FutureProvider<KgDevice>((ref) async {
  return KgDeviceStore.instance.load();
});

/// 全局直连客户端（登录态变化时同步 token/userid）
final kgClientProvider = FutureProvider<KgClient>((ref) async {
  final device = await ref.watch(kgDeviceProvider.future);
  final client = KgClient(device: device);
  final auth = ref.watch(authStateProvider);
  final user = auth.value;
  if (user != null) {
    client.token = user.token;
    client.userid = user.userid;
  }
  return client;
});

/// 直连播放接口
final kgPlayApiProvider = FutureProvider<KgPlayApi>((ref) async {
  final client = await ref.watch(kgClientProvider.future);
  return KgPlayApi(client);
});
