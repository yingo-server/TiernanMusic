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
    _apiLevel = level;
    return level;
  }

  /// Android 10 及以上
  Future<bool> isAndroid10Plus() async => (await apiLevel()) >= 29;

  /// Android 9 及以下（需要写权限）
  Future<bool> needsLegacyWritePermission() async =>
      (await apiLevel()) > 0 && (await apiLevel()) < 29;

  /// 申请存储权限（仅 Android 9 及以下需要）。
  ///
  /// 返回是否具备公共目录写入能力。
  Future<bool> requestStoragePermission() async {
    final level = await apiLevel();
    if (level <= 0) return false;
    if (level >= 29) return true; // MediaStore 免权限
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  /// 申请通知权限（Android 13+ 后台下载通知）。
  Future<bool> requestNotificationPermission() async {
    final level = await apiLevel();
    if (level <= 0) return false;
    if (level < 33) return true;
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  /// 计算当前可用的写入策略（会触发权限申请）。
  Future<StorageStrategy> resolveStrategy() async {
    final level = await apiLevel();
    if (level <= 0) return StorageStrategy.appFallback;
    if (level >= 29) return StorageStrategy.mediaStore;
    final granted = await requestStoragePermission();
    return granted ? StorageStrategy.directPath : StorageStrategy.appFallback;
  }

  /// 当前策略（不申请权限）。
  Future<StorageStrategy> currentStrategy() async {
    final level = await apiLevel();
    if (level <= 0) return StorageStrategy.appFallback;
    if (level >= 29) return StorageStrategy.mediaStore;
    final granted = await Permission.storage.status;
    return granted.isGranted
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
}
