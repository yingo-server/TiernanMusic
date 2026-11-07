import 'dart:io';

import 'package:flutter/foundation.dart';
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
    } catch (e) {
      // V399-B2：步骤失败留痕（第 9 条），禁止裸 catch 吞掉
      debugPrint('[perm] manageExternalStorage.status check failed: $e');
      lastProbeError = '授权态查询失败: $e';
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
      // V37-PERM-04：request() 内部异常/ROM 差异导致的失败不能静默
      //（第 9 条）——落 debugPrint，线上可由 verbose 日志捕获。
      debugPrint('[perm] manageExternalStorage.request → ${result.name}');
      if (!result.isGranted) {
        lastProbeError = '授权页返回 ${result.name}';
      }
      return result.isGranted;
    } catch (e) {
      debugPrint('[perm] manageExternalStorage.request failed: $e');
      lastProbeError = 'request() 抛异常: $e';
      return false;
    }
  }

  /// V399-B2：最近一次探测结果（设置页展示「探测到的实际可写路径」）。
  /// null = 尚未探测；每次 [resolveRoot] 实测后更新。
  static String? lastProbeError;

  /// V399-B2：对 [dir] 做真实写入能力探测（写探针文件 → 读回 → 删除）。
  ///
  /// 这是「给了权限说没给」的根治：MANAGE_EXTERNAL_STORAGE 授权态、
  /// ROM 分域挂载、SD 卡只读等任何一环不通过都判为不可写，不信缓存。
  ///
  /// ⚠️ 本方法**不得**经 ErrorLogger 留痕：ErrorLogger._writeVerbose 自身
  /// 调用 resolveRoot，形成「探测失败 → 写日志 → 又探测」递归链
  ///（第 22 条并发前提）。探测留痕用 debugPrint + [lastProbeError]。
  static Future<bool> _probeWritable(Directory dir) async {
    final probe = File('${dir.path}'
        '/.tm_probe_${DateTime.now().millisecondsSinceEpoch}.tmp');
    try {
      try {
        await dir.create(recursive: true);
      } catch (e) {
        lastProbeError = '目录创建失败: $e';
        debugPrint('[perm] probe dir create failed: $e');
        return false;
      }
      const payload = 'probe';
      await probe.writeAsString(payload, flush: true);
      final readBack = await probe.readAsString();
      if (readBack != payload) {
        lastProbeError = '探针读回不一致';
        debugPrint('[perm] probe read-back mismatch');
        return false;
      }
      await probe.delete();
      lastProbeError = null;
      return true;
    } catch (e) {
      lastProbeError = '写入探测失败: $e';
      debugPrint('[perm] probe write failed: $e');
      // 探针残留清理（失败不抛：下一个探针换名，不冲突）
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {}
      return false;
    }
  }

  /// V399-B2：当前生效的存储根目录（**每次调用重新实测写入能力**）。
  ///
  ///  - MANAGE_EXTERNAL_STORAGE 已授权 → 先对 `/storage/emulated/0/TierNanMusic`
  ///    实测写探针；通过才返回，否则按未授权继续降级（不再信授权态缓存）；
  ///  - 未授权 → `Download/TiernanMusic`（API≥29 走 MediaStore Downloads 集合；
  ///    ≤28 需 WRITE_EXTERNAL_STORAGE，由调用方按 [currentStrategy] 决定降级）。
  ///
  /// 三处根路径（download_provider / public_media_store / error_logger）
  /// 统一走本方法，禁止各自硬编码。
  Future<String> resolveRoot() async {
    if (await isAllFilesAccessGranted()) {
      final dir = Directory(rootPath);
      if (await _probeWritable(dir)) return rootPath;
      // V399-B2：授权态为真但实测不可写（ROM 怪癖/目录损坏）→
      // 降级到 Download 路径并留痕（第 9 条失败可观测）。
      debugPrint('[perm] rootPath granted but probe failed, '
          'fallback to download root: ${lastProbeError ?? '-'}');
    }
    try {
      final base =
          await _channel.invokeMethod<String>('publicDir', {'type': 'downloads'});
      if (base != null && base.isNotEmpty) {
        final candidate = '$base/$fallbackRootDirName';
        if (await _probeWritable(Directory(candidate))) return candidate;
        debugPrint('[perm] download root probe failed: ${lastProbeError ?? '-'}');
        return candidate; // 通道给了真实路径：即使探测失败也返回（调用方各有降级）
      }
    } catch (e) {
      // V399-B2：原生通道失败必须留痕，禁止裸 catch 吞掉（第 6/9 条）
      debugPrint('[perm] publicDir(downloads) channel failed: $e');
      lastProbeError = '原生通道 publicDir 失败: $e';
    }
    // 原生通道不可用时的保守兜底（标准 Android 路径）
    return '/storage/emulated/0/Download/$fallbackRootDirName';
  }

  /// 存储模式名（设置页展示用）：'root' = 根目录模式，'download' = Download 模式。
  ///
  /// V399-B2：与 resolveRoot 同口径——授权态但实测不可写时也报 'download'
  ///（声称的模式与实际生效路径一致，第 31 条不误导）。
  Future<String> resolveRootMode() async {
    if (await isAllFilesAccessGranted() &&
        await _probeWritable(Directory(rootPath))) {
      return 'root';
    }
    return 'download';
  }

  static const MethodChannel _channel =
      MethodChannel('com.tiernan.music/storage');

  int? _apiLevel;

  /// 设备 API 级别
  Future<int> apiLevel() async {
    if (_apiLevel != null) return _apiLevel!;
    var level = 0;
    try {
      level = await _channel.invokeMethod<int>('apiLevel') ?? 0;
    } catch (e) {
      // V399-B2：原生通道失败留痕后走版本名兜底（第 9 条）
      debugPrint('[perm] apiLevel channel failed: $e');
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

    final PermissionStatus status;
    try {
      status = await Permission.storage.status;
    } catch (e) {
      // V399-B2：状态查询失败留痕，按未授权降级（第 6/9 条）
      debugPrint('[perm] storage.status check failed: $e');
      lastProbeError = 'storage 状态查询失败: $e';
      return false;
    }
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      try {
        await openAppSettings();
      } catch (e) {
        // V399-B2：跳设置页失败也要留痕（第 9 条）
        debugPrint('[perm] openAppSettings failed: $e');
        lastProbeError = 'openAppSettings 失败: $e';
      }
      return false;
    }
    final result = await Permission.storage.request();
    if (!result.isGranted) {
      lastProbeError = 'storage.request 返回 ${result.name}';
    }
    return result.isGranted;
  }

  /// 申请通知权限（Android 13+ 后台下载通知）。
  Future<bool> requestNotificationPermission() async {
    final level = await apiLevel();
    if (level < 33) return true;
    final PermissionStatus status;
    try {
      status = await Permission.notification.status;
    } catch (e) {
      // V399-B2：状态查询失败留痕（第 6/9 条）
      debugPrint('[perm] notification.status check failed: $e');
      lastProbeError = 'notification 状态查询失败: $e';
      return false;
    }
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      try {
        await openAppSettings();
      } catch (e) {
        debugPrint('[perm] openAppSettings failed: $e');
        lastProbeError = 'openAppSettings 失败: $e';
      }
      return false;
    }
    final result = await Permission.notification.request();
    if (!result.isGranted) {
      lastProbeError = 'notification.request 返回 ${result.name}';
    }
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
    } catch (e) {
      // V399-B2：通道失败留痕（第 9 条）
      debugPrint('[perm] publicDir($type) channel failed: $e');
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
      if (ok != true) {
        // V399-B2：原生返回不可写也要留痕（第 9 条）
        debugPrint('[perm] publicDirWritable($type) → false');
        lastProbeError = 'publicDirWritable($type) 不可写';
      }
      return ok ?? false;
    } catch (e) {
      debugPrint('[perm] publicDirWritable($type) channel failed: $e');
      lastProbeError = 'publicDirWritable($type) 通道失败: $e';
      return false;
    }
  }
}
