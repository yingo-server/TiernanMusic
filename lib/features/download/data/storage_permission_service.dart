import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 公共目录写入策略。
enum StorageStrategy {
  /// Android 10+：MediaStore + IS_PENDING（无需存储权限）
  mediaStore,

  /// Android 9 及以下：直接写公共目录路径（需要 WRITE_EXTERNAL_STORAGE）
  directPath,

  /// 权限被拒：降级到 App 私有外部目录（Android/data/...）
  appFallback,
}

/// 存储权限服务：判断 API 级别、申请运行时权限、决定写入策略。
///
/// 这是**唯一权威**的存储权限来源；`lib/core/utils/permission_gate.dart`
/// 只负责 UI 层提示，两者共享同一套判定逻辑。
class StoragePermissionService {
  StoragePermissionService._();
  static final instance = StoragePermissionService._();

  static const MethodChannel _channel =
      MethodChannel('com.tiernan.music/storage');

  int? _apiLevel;

  /// 设备 API 级别
  Future<int> apiLevel() async {
    if (_apiLevel != null) return _apiLevel!;
    var level = 0;
    try {
      level = await _channel.invokeMethod<int>('apiLevel') ?? 0;
    } catch (_) {
      level = 0;
    }
    // 原生通道失败时用 operatingSystemVersion 兜底。
    // 注意：Platform.operatingSystemVersion 返回的是**版本名**（如 "Android 13"），
    // 不是 API level，必须做版本名 → API level 映射，否则会把 Android 10(API 29)
    // 误判成 API 10，从而走错存储分支。
    if (level <= 0) {
      level = _apiLevelFromOsVersion(Platform.operatingSystemVersion);
    }
    _apiLevel = level;
    return level;
  }

  /// Android 版本名 → API level 映射（仅作为原生通道不可用时的兜底）。
  static int _apiLevelFromOsVersion(String osVersion) {
    final match = RegExp(r'Android\s+(\d+)').firstMatch(osVersion);
    final name = int.tryParse(match?.group(1) ?? '');
    if (name == null) return 29; // 认不出来时按 Android 10+ 处理（最安全的分支）
    if (name <= 9) return name; // Android 9 == API 28
    // Android 10 → API 29，逐版本递增
    return name + 19;
  }

  /// Android 10 及以上
  Future<bool> isAndroid10Plus() async => (await apiLevel()) >= 29;

  /// Android 9 及以下（需要写权限）
  Future<bool> needsLegacyWritePermission() async {
    final level = await apiLevel();
    return level > 0 && level < 29;
  }

  /// 申请存储权限（仅 Android 9 及以下需要）。
  ///
  /// 返回是否具备公共目录写入能力。
  Future<bool> requestStoragePermission() async {
    final level = await apiLevel();
    if (level >= 29) return true; // MediaStore 免权限

    final status = await Permission.storage.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }
    final result = await Permission.storage.request();
    return result.isGranted;
  }

  /// 申请通知权限（Android 13+ 后台下载通知）。
  Future<bool> requestNotificationPermission() async {
    final level = await apiLevel();
    if (level < 33) return true;
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// 计算当前可用的写入策略（会触发权限申请）。
  Future<StorageStrategy> resolveStrategy() async {
    final level = await apiLevel();
    if (level >= 29) return StorageStrategy.mediaStore;
    final granted = await requestStoragePermission();
    return granted ? StorageStrategy.directPath : StorageStrategy.appFallback;
  }

  /// 当前策略（不申请权限）。
  Future<StorageStrategy> currentStrategy() async {
    final level = await apiLevel();
    if (level >= 29) return StorageStrategy.mediaStore;
    final status = await Permission.storage.status;
    return status.isGranted
        ? StorageStrategy.directPath
        : StorageStrategy.appFallback;
  }

  /// 公共目录绝对路径（仅 API <= 28 有效）。
  Future<String?> publicDir(String type) async {
    try {
      return await _channel.invokeMethod<String>('publicDir', {'type': type});
    } catch (_) {
      return null;
    }
  }

  /// 该公共目录在当前系统版本下是否可直接写文件。
  ///
  /// Android 10+ 的 scoped storage 下，直写公共路径会被拒绝，
  /// 必须走 MediaStore；此方法用于判断是否需要降级。
  Future<bool> isPublicDirWritable(String type) async {
    final level = await apiLevel();
    if (level >= 29) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
          'publicDirWritable', {'type': type});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
