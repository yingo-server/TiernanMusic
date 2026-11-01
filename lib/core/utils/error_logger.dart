import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/download/data/storage_permission_service.dart';

/// 全局错误日志落盘。
///
/// 存储层级：**公共内部存储**（文件管理器可见）
///  - Android 10+：走 MediaStore Downloads 集合（无需任何权限，scoped storage 安全）
///  - Android ≤ 9：直接写公共 Documents 目录（需 WRITE_EXTERNAL_STORAGE 运行时权限）
/// 写入失败时静默降级到 App 私有目录，绝不因日志写入影响主流程。
class ErrorLogger {
  ErrorLogger._();
  static final instance = ErrorLogger._();

  static const MethodChannel _channel =
      MethodChannel('com.tiernan.music/storage');

  /// 公共目录下的子目录名
  static const String folderName = 'Tiernan Music';
  static const String logsDirName = 'Logs';

  /// 公共相对路径（Android 10+ 用 RELATIVE_PATH，≤9 用路径拼接）
  static String get _relativePath => 'Documents/$folderName/$logsDirName';

  /// 单个日志文件上限，超过后轮转
  static const int maxBytes = 5 * 1024 * 1024;

  /// 内存中的最近日志（供「诊断」页展示）
  static final List<String> _recent = <String>[];
  static List<String> get recent => List.unmodifiable(_recent);

  bool _initialized = false;
  Directory? _fallbackDir;

  /// 初始化日志目录（应用私有降级目录）
  ///
  /// 失败时**不置 _initialized**，保证下次调用会重试——
  /// 否则一次失败会让日志永久丢失。
  Future<void> init() async {
    if (_fallbackDir != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$folderName/$logsDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _fallbackDir = dir;
      _initialized = true;
    } catch (e) {
      debugPrint('[ErrorLogger] fallback dir failed: $e');
      _initialized = false;
    }
  }

  /// 记录一条错误
  Future<void> log(
    Object error,
    StackTrace? stack, {
    String source = 'app',
    String? context,
  }) async {
    final now = DateTime.now();
    final ts = now.toIso8601String();
    final sb = StringBuffer()
      ..writeln('──── [$ts] ────')
      ..writeln('来源: $source');
    if (context != null && context.isNotEmpty) {
      sb.writeln('上下文: $context');
    }
    sb.writeln('错误: $error');
    if (stack != null) {
      sb.writeln('堆栈:\n$stack');
    }
    final text = sb.toString();

    _recent.insert(0, text);
    if (_recent.length > 200) _recent.removeLast();

    debugPrint('[ErrorLogger] $source: $error');

    await init();
    final fileName = 'error_${_dateTag(now)}.log';

    // 优先写公共目录（文件管理器可见）
    if (await _appendPublic(fileName, text)) return;

    // 降级：应用私有目录
    final dir = _fallbackDir;
    if (dir == null) return;
    try {
      final file = File('${dir.path}/$fileName');
      if (await file.exists() && await file.length() > maxBytes) {
        final rotated = File('${file.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
      }
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('[ErrorLogger] write failed: $e');
    }
  }

  /// 写入公共目录：Android 10+ 用原生 MediaStore；≤9 直写公共 Documents。
  Future<bool> _appendPublic(String fileName, String text) async {
    try {
      final apiLevel = _apiLevel;
      if (apiLevel >= 29) {
        // MediaStore 每次插入都是新文件，无法追加 —— 所以按天聚合，
        // 由 Dart 侧缓存当日内容，退出/超限时整份重写。
        return await _rewriteMediaStore(fileName, text);
      }
      // ≤9：写公共 Documents 需要 WRITE_EXTERNAL_STORAGE，先申请
      if (!await _ensureStoragePermission()) return false;
      final base = await _channel.invokeMethod<String>(
          'publicDir', {'type': 'documents'});
      if (base == null || base.isEmpty) return false;
      final dir = Directory('$base/$folderName/$logsDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/$fileName');
      if (await file.exists() && await file.length() > maxBytes) {
        final rotated = File('${file.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
      }
      await file.writeAsString(text, mode: FileMode.append, flush: true);
      return true;
    } catch (e) {
      debugPrint('[ErrorLogger] public write failed: $e');
      return false;
    }
  }

  /// 申请存储权限（仅 Android 9 及以下需要；≥29 MediaStore 免权限）
  Future<bool> _ensureStoragePermission() async {
    try {
      final service = StoragePermissionService.instance;
      return await service.requestStoragePermission();
    } catch (e) {
      debugPrint('[ErrorLogger] permission request failed: $e');
      return false;
    }
  }

  /// Android 10+：MediaStore Downloads 写入。
  /// 原生层先查询同名文件并整份重写（真追加），这里无需缓存内容。
  Future<bool> _rewriteMediaStore(String fileName, String text) async {
    try {
      final ok = await _channel.invokeMethod<bool>('appendText', {
        'displayName': fileName,
        'relativePath': _relativePath,
        'content': text,
      });
      return ok == true;
    } catch (e) {
      debugPrint('[ErrorLogger] media store write failed: $e');
      return false;
    }
  }

  /// 记录 API 错误（含错误码与请求路径）
  Future<void> logApi(
    Object error, {
    required String endpoint,
    int? code,
    Map<String, dynamic>? body,
  }) async {
    final sb = StringBuffer()
      ..writeln('接口: $endpoint')
      ..writeln('错误码: ${code ?? '-'}');
    if (body != null && body.isNotEmpty) {
      final s = body.toString();
      sb.writeln('响应: ${s.length > 800 ? '${s.substring(0, 800)}…' : s}');
    }
    await log(error, null, source: 'api', context: sb.toString());
  }

  /// 全局未捕获异常（FlutterError.onError）
  void handleFlutterError(FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(log(
      details.exception,
      details.stack,
      source: 'flutter',
      context: details.context?.toDescription(),
    ));
  }

  /// 全局未捕获异步异常（runZonedGuarded）
  void handleUncaught(Object error, StackTrace stack) {
    debugPrint('[uncaught] $error\n$stack');
    unawaited(log(error, stack, source: 'uncaught'));
  }

  /// 当前日志目录（展示给用户）
  Future<String?> currentDirPath() async {
    await init();
    final apiLevel = _apiLevel;
    if (apiLevel >= 29) {
      return '/sdcard/Documents/$folderName/$logsDirName';
    }
    return _fallbackDir?.path;
  }

  /// Android API 级别
  static int get _apiLevel {
    final match =
        RegExp(r'Android\s+(\d+)').firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '') ?? 29;
  }

  static String _dateTag(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
