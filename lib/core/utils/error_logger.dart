import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 全局错误日志落盘。
///
/// 存储层级：**公共内部存储**（文件管理器可见）
/// 路径：Android 10+ 走 MediaStore 的 Documents/；≤28 直接写公共 Documents 目录。
/// 失败时静默降级到 App 私有目录，绝不因日志写入而影响主流程。
class ErrorLogger {
  ErrorLogger._();
  static final instance = ErrorLogger._();

  static const MethodChannel _channel =
      MethodChannel('com.tiernan.music/storage');

  /// 公共目录下的子目录名
  static const String folderName = 'Tiernan Music';
  static const String logsDirName = 'Logs';

  /// 单个日志文件上限，超过后轮转
  static const int maxBytes = 5 * 1024 * 1024;

  /// 内存中的最近日志（供「诊断」页展示）
  static final List<String> _recent = <String>[];
  static List<String> get recent => List.unmodifiable(_recent);

  bool _initialized = false;
  Directory? _fallbackDir;

  /// 初始化日志目录（启动时调用一次）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final base = await _publicDocumentsBase();
      if (base != null && base.isNotEmpty) {
        final dir = Directory('$base/$folderName/$logsDirName');
        if (!await dir.exists()) await dir.create(recursive: true);
        _fallbackDir = dir;
        return;
      }
    } catch (e) {
      debugPrint('[ErrorLogger] public dir failed: $e');
    }
    // 降级：应用私有目录
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$folderName/$logsDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _fallbackDir = dir;
    } catch (e) {
      debugPrint('[ErrorLogger] fallback dir failed: $e');
    }
  }

  /// Android 10+：MediaStore 只能插入文件，不能直接建目录拿路径。
  /// 因此这里对 Android 10+ 也退回公共 Documents 的传统路径（通过原生层解析）。
  Future<String?> _publicDocumentsBase() async {
    try {
      return await _channel.invokeMethod<String>('publicDir', {'type': 'documents'});
    } catch (_) {
      return null;
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
    final dir = _fallbackDir;
    if (dir == null) return;
    try {
      final file = File('${dir.path}/error_${_dateTag(now)}.log');
      if (await file.exists() && await file.length() > maxBytes) {
        // 轮转
        final rotated = File('${file.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
      }
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('[ErrorLogger] write failed: $e');
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
    return _fallbackDir?.path;
  }

  static String _dateTag(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
