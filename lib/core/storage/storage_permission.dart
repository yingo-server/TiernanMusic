import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

/// 公共目录写入策略。
enum StorageStrategy {
  /// Android 10+：MediaStore + IS_PENDING（无需存储权限）
  mediaStore,

  /// Android 9 及以下：直接写公共目录路径（需要 WRITE_EXTERNAL_STORAGE）
  directPath,

  /// 权限被拒：降级到 App 私有外部目录（Android/data/...）
  appFallback,
}

/// V5.2-A：resolveRoot 单对象结果——路径 + 生效级别 + 全链探测历史。
///
/// 消除「resolveRootMode 与 resolveRoot 各自独立探测（两次探针）」的
/// 不一致：mode 由 level 推导（L1 = root，其余 = download），单次探测
/// 全局同口径。
class StorageResolution {
  const StorageResolution({
    required this.path,
    required this.level,
    required this.probeLog,
  });

  /// 实际生效的根目录路径
  final String path;

  /// 生效级别（1-5，见 [StoragePermissionService.resolveRoot] 回退链）
  final int level;

  /// 全链探测历史（逐级一行：级别 + 结果/失败原因）
  final List<String> probeLog;

  /// 模式名（设置页展示用）：L1 = 'root'，其余 = 'download'。
  String get mode => level == 1 ? 'root' : 'download';

  /// 全链历史合并为可展示文本
  String get probeLogText => probeLog.join('\n');

  @override
  String toString() => 'L$level: $path';
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
    final probe = File(
      '${dir.path}'
      '/.tm_probe_${DateTime.now().millisecondsSinceEpoch}.tmp',
    );
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

  // ---- V5.2-A：四重检测矩阵 ----
  //
  // 每次 resolveRoot 全跑，任何一环失败即降级并留痕：
  //  1. permission_handler manageExternalStorage.isGranted
  //  2. 原生通道 canWrite('/storage/emulated/0')（java.io.File.canWrite()，
  //     排除 permission_handler 的 ROM 怪癖）
  //  3. 目录实际写探针（写→读回→删，_probeWritable）
  //  4. Environment.isExternalStorageManager() 原生复验（API 30+，反射调用，
  //     防 permission_handler 框架偏差）

  /// 检测 2：原生通道 canWrite（java.io.File.canWrite()）。
  /// 通道失败/异常一律视为未通过（宁可降级，不可误判可写）。
  Future<bool> _nativeCanWriteRoot() async {
    try {
      final ok = await _channel.invokeMethod<bool>('canWrite', {
        'path': '/storage/emulated/0',
      });
      if (ok != true) {
        debugPrint('[perm] native canWrite(/storage/emulated/0) → $ok');
        lastProbeError = '原生 canWrite = $ok';
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[perm] native canWrite channel failed: $e');
      lastProbeError = '原生 canWrite 通道失败: $e';
      return false;
    }
  }

  /// 检测 4：原生复验 isExternalStorageManager（API 30+，反射调用）。
  /// API < 30 无此概念（MANAGE_EXTERNAL_STORAGE 尚不存在），直接通过。
  Future<bool> _nativeIsExternalStorageManager() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isExternalStorageManager');
      if (ok == null) {
        // API < 30：反射结果为 null = 该权限不存在，视为通过
        debugPrint('[perm] isExternalStorageManager: n/a (API < 30)');
        return true;
      }
      if (!ok) {
        debugPrint('[perm] native isExternalStorageManager → false');
        lastProbeError = '原生 isExternalStorageManager = false';
      }
      return ok;
    } catch (e) {
      debugPrint('[perm] isExternalStorageManager channel failed: $e');
      lastProbeError = 'isExternalStorageManager 通道失败: $e';
      return false;
    }
  }

  /// V5.2-A：四重检测矩阵全跑（逐项留痕，任一失败即整体不通过）。
  ///
  /// 返回是否四项全部通过；失败原因写入 [lastProbeError]（最后一项的）。
  Future<bool> _quadrupleCheck() async {
    // ① permission_handler 授权态
    final granted = await isAllFilesAccessGranted();
    if (!granted) return false;
    // ② 原生 canWrite
    if (!await _nativeCanWriteRoot()) return false;
    // ③ 写探针在回退链各级路径上单独做（此处对根目录先验）
    // ④ 原生 isExternalStorageManager 复验（含 API < 30 直接通过）
    if (!await _nativeIsExternalStorageManager()) return false;
    return true;
  }

  /// V5.2-A：最近一次 resolveRoot 结果缓存（mode 推导用，避免双探针）。
  StorageResolution? _lastResolution;

  /// V5.2-A：当前生效的存储根目录（**每次调用跑完整四重检测 + 五级回退**）。
  ///
  /// 五级回退链（顺序不可变，逐级留痕原因）：
  ///  - L1 `/storage/emulated/0/TierNanMusic`（四重全过 + 写探针通过才用）
  ///  - L2 `/storage/emulated/0/Download/TierNanMusic`（MediaStore 免权限）
  ///  - L3 `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)/TierNanMusic`
  ///    （原生直取，防 channel 路径差异）
  ///  - L4 `context.getExternalFilesDir(null)/TierNanMusic`（App 外部私有，免权限必可写）
  ///  - L5 `getApplicationSupportDirectory()`（内部私有，最后兜底）
  ///
  /// 每级结果与失败原因写入 [lastProbeError] + debugPrint；结果含全链
  /// probeLog，设置页显示「生效级别 + 全链探测历史」。
  ///
  /// 三处根路径（download_provider / public_media_store / error_logger）
  /// 统一走本方法，禁止各自硬编码。

  /// 进行中的 resolveRoot Future（并行调用共享同一次探测）。
  Future<StorageResolution>? _inFlight;

  Future<StorageResolution> resolveRoot() async {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _resolveRootImpl();
    _inFlight = future;
    try {
      return await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<StorageResolution> _resolveRootImpl() async {
    final log = <String>[];
    void trace(String line) {
      log.add(line);
      debugPrint('[perm] $line');
    }

    // ---- L1 根目录：四重检测矩阵 + 写探针全过才用 ----
    if (await _quadrupleCheck()) {
      final dir = Directory(rootPath);
      if (await _probeWritable(dir)) {
        trace('L1 通过（四重检测+写探针）：$rootPath');
        lastProbeError = null;
        return _lastResolution = StorageResolution(
          path: rootPath,
          level: 1,
          probeLog: log,
        );
      }
      trace('L1 写探针失败：${lastProbeError ?? '-'}');
    } else {
      trace('L1 四重检测未过：${lastProbeError ?? '-'}');
    }

    // ---- L2
    final l2Path = '/storage/emulated/0/Download/$fallbackRootDirName';
    if (await _probeWritable(Directory(l2Path))) {
      trace('L2 通过：$l2Path');
      lastProbeError = 'L1 降级，生效 L2';
      return _lastResolution = StorageResolution(
        path: l2Path,
        level: 2,
        probeLog: log,
      );
    }
    trace('L2 写探针失败：${lastProbeError ?? '-'}');

    // ---- L3
    String? l3Path;
    try {
      final base = await _channel.invokeMethod<String>('publicDir', {
        'type': 'downloads',
      });
      if (base != null && base.isNotEmpty) {
        l3Path = '$base/$fallbackRootDirName';
        if (l3Path != l2Path && await _probeWritable(Directory(l3Path))) {
          trace('L3 通过：$l3Path');
          lastProbeError = 'L1/L2 降级，生效 L3';
          return _lastResolution = StorageResolution(
            path: l3Path,
            level: 3,
            probeLog: log,
          );
        }
        trace('L3 探测失败：${lastProbeError ?? '-'}');
      } else {
        trace('L3 原生 publicDir 返回空');
        lastProbeError = '原生 publicDir(downloads) 返回空';
      }
    } catch (e) {
      // V399-B2：原生通道失败必须留痕，禁止裸 catch 吞掉（第 6/9 条）
      trace('L3 原生通道 publicDir 失败: $e');
      lastProbeError = '原生通道 publicDir 失败: $e';
    }

    // ---- L4
    String l4Path;
    try {
      final ext = await _channel.invokeMethod<String>('externalFilesDir');
      l4Path = (ext != null && ext.isNotEmpty)
          ? '$ext/$fallbackRootDirName'
          : '${(await getExternalStorageDirectory())?.path ?? ''}/$fallbackRootDirName';
    } catch (e) {
      trace('L4 原生 externalFilesDir 失败: $e，走 path_provider 兜底');
      final extDir = await getExternalStorageDirectory();
      if (extDir == null) {
        trace('L4 path_provider 外部目录为 null');
        l4Path = '';
      } else {
        l4Path = '${extDir.path}/$fallbackRootDirName';
      }
    }
    if (l4Path.isNotEmpty && await _probeWritable(Directory(l4Path))) {
      trace('L4 通过：$l4Path');
      lastProbeError = 'L1-L3 降级，生效 L4（App 外部私有目录）';
      return _lastResolution = StorageResolution(
        path: l4Path,
        level: 4,
        probeLog: log,
      );
    }
    trace('L4 探测失败：${l4Path.isEmpty ? "路径不可得" : (lastProbeError ?? "-")}');

    // ---- L5
    final l5Path = '${(await _appSupportDir()).path}/$fallbackRootDirName';
    trace('L5 兜底：$l5Path');
    lastProbeError = '公共目录均不可写，已降级到应用私有目录（L5）';
    return StorageResolution(path: l5Path, level: 5, probeLog: log);
  }

  /// 应用私有支持目录（拿不到时退回临时目录——必定可写）。
  Future<Directory> _appSupportDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (!dir.existsSync()) await dir.create(recursive: true);
      return dir;
    } catch (e) {
      debugPrint('[perm] getApplicationSupportDirectory failed: $e');
      return Directory.systemTemp;
    }
  }

  /// 存储模式名：'root' / 'download'。
  ///
  /// V5.2-A：**不再独立探测**（消除与 resolveRoot 的双探针不一致）——
  /// 直接复用最近一次 resolveRoot 的级别推导。若尚未探测过，先跑一次。
  Future<String> resolveRootMode() async {
    final cached = _lastResolution;
    if (cached != null) return cached.mode;
    final res = await resolveRoot();
    return res.mode;
  }

  static final MethodChannel _channel = MethodChannel(
    'com.tiernan.music/storage',
  );

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
    // Android 10 → API 29，逐版本递增。
    // V5.2-A 修正：旧公式 name+19 对 Android 13 算出 32（实际 33）、
    // Android 14 算出 33（实际 34）——差 1。改为 name+20（10→30 基准）。
    return name + 20;
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
      final ok = await _channel.invokeMethod<bool>('publicDirWritable', {
        'type': type,
      });
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
