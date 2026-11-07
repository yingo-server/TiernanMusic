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

  // ---- V37-LOG-07（v3.7 存储重构）：设备存储根目录 ----
  //
  // 用户确认口径：文件管理器根目录显示 `TierNanMusic`（用户拼写，保持原样，
  // 勿"修正"为 TiernanMusic——改名会让已有目录分裂成两个）。
  /// MANAGE_EXTERNAL_STORAGE 已授权时的根目录
  static const String rootDirName = 'TierNanMusic';

  /// 未授权时的降级根目录（Download 下，MediaStore 无需权限可达）
  static const String fallbackRootDirName = 'TiernanMusic';

  /// 设备存储根：已授权 → /storage/emulated/0/TierNanMusic
  static const String rootPath = '/storage/emulated/0/$rootDirName';

  /// 分域子目录（根目录与 Download 降级根下同名使用）
  static const String audioSubDir = 'audio';
  static const String mvSubDir = 'mv';
  static const String logsSubDir = 'logs';
  static const String coverSubDir = 'cover';
  static const String lyricsSubDir = 'lyrics';

  /// 下载类型 → 子目录（download_provider / public_media_store 统一走这里）
  static String subDirOf(String typeName) => switch (typeName) {
        'audio' => audioSubDir,
        'mv' => mvSubDir,
        'cover' => coverSubDir,
        'lyric' => lyricsSubDir,
        _ => audioSubDir,
      };

  /// verbose 日志在 MediaStore 里的 RELATIVE_PATH（未授权降级写入位置）。
  /// **必须以 `/` 结尾**：MediaStore RELATIVE_PATH 规范要求目录形式。
  static const String verboseRelativePath =
      'Download/$fallbackRootDirName/$logsSubDir/';

  /// 所有文件访问是否已授权（MANAGE_EXTERNAL_STORAGE）。
  ///
  /// Android 11+ 才有该权限；低版本返回 false（resolveRoot 会按
  /// API 级别走直写/MediaStore 分支，不受此影响）。
  Future<bool> isAllFilesAccessGranted() async {
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 申请所有文件访问权限（跳系统授权页）。
  ///
  /// permission_handler 在 Android 11+ 会直接跳转系统「所有文件访问」
  /// 设置页；返回值是**回到 App 后**的真实授权态（低版本恒 false）。
  Future<bool> requestAllFilesAccess() async {
    try {
      final result = await Permission.manageExternalStorage.request();
      return result.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// V37-LOG-07：当前生效的存储根目录。
  ///
  ///  - MANAGE_EXTERNAL_STORAGE 已授权 → `/storage/emulated/0/TierNanMusic`（直写）
  ///  - 未授权 → `Download/TiernanMusic`（API≥29 走 MediaStore Downloads 集合；
  ///    ≤28 需 WRITE_EXTERNAL_STORAGE，由调用方按 [currentStrategy] 决定降级）
  ///
  /// 三处根路径（download_provider / public_media_store / error_logger）
  /// 统一走本方法，禁止各自硬编码。
  Future<String> resolveRoot() async {
    if (await isAllFilesAccessGranted()) return rootPath;
    try {
      final base =
          await _channel.invokeMethod<String>('publicDir', {'type': 'downloads'});
      if (base != null && base.isNotEmpty) return '$base/$fallbackRootDirName';
    } catch (_) {}
    // 原生通道不可用时的保守兜底（标准 Android 路径）
    return '/storage/emulated/0/Download/$fallbackRootDirName';
  }

  /// 存储模式名（设置页展示用）：'root' = 根目录模式，'download' = Download 模式。
  Future<String> resolveRootMode() async =>
      (await isAllFilesAccessGranted()) ? 'root' : 'download';

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
    // V37-LOG-07：已授权所有文件访问 → 直写公共根（directPath）
    if (await isAllFilesAccessGranted()) return StorageStrategy.directPath;
    if (level >= 29) return StorageStrategy.mediaStore;
    final granted = await requestStoragePermission();
    return granted ? StorageStrategy.directPath : StorageStrategy.appFallback;
  }

  /// 当前策略（不申请权限）。
  Future<StorageStrategy> currentStrategy() async {
    // V37-LOG-07：已授权所有文件访问 → 直写公共根
    if (await isAllFilesAccessGranted()) return StorageStrategy.directPath;
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
