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
  ///
  /// **必须以 `/` 结尾**：MediaStore 的 RELATIVE_PATH 规范要求目录形式，
  /// 原生 ≤28 分支也会按同样约定去掉 `Documents/` 前缀后拼接，两边保持一致。
  static String get _relativePath =>
      'Documents/$folderName/$logsDirName/';

  /// 单个日志文件上限，超过后轮转
  static const int maxBytes = 5 * 1024 * 1024;

  /// 内存中的最近日志（供「诊断」页展示）
  static final List<String> _recent = <String>[];
  static List<String> get recent => List.unmodifiable(_recent);

  Directory? _fallbackDir;

  /// B-22（v3.3 修复①，第 22 条）：并发写串行锁。全局未捕获异常 / FlutterError
  /// 可能在同帧内多次触发 [log]，公共目录（MediaStore）与私有目录的
  /// 追加/轮转若无互斥会互相截断或丢日志。用一条串行链保证同一时刻只有一个
  /// 写事务在进行。
  Future<void> _writeQueue = Future<void>.value();

  /// 本次进程是否成功落盘过（公共或私有）；全失败时为 false。
  bool _everPersisted = false;

  /// 原生返回的实际公共写入位置（公共目录写入成功后才有值）
  String? _publicDirPath;

  /// 降级写入私有目录成功后记录的实际路径
  String? _fallbackWrittenPath;

  /// 初始化日志目录（应用私有降级目录）
  ///
  /// 失败时**不缓存失败状态**，保证下次调用会重试——
  /// 否则一次失败会让日志永久丢失。
  Future<void> init() async {
    if (_fallbackDir != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$folderName/$logsDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _fallbackDir = dir;
    } catch (e) {
      debugPrint('[ErrorLogger] fallback dir failed: $e');
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
    // C-02（审查②）：落盘前必须脱敏——日志在公共 Documents 目录，
    // 任何 DioException 的 toString 都可能带 token/t1 查询参数。
    final text = _redact(sb.toString());

    _recent.insert(0, text);
    if (_recent.length > 200) _recent.removeLast();

    debugPrint('[ErrorLogger] $source: $error');

    await init();
    final fileName = 'error_${_dateTag(now)}.log';

    // B-22（v3.3 修复①，第 22 条）：整段落盘（公共 + 降级）放进串行链，
    // 避免并发 log 互相截断。同一时刻只有一个写事务。
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        // 优先写公共目录（文件管理器可见）
        if (await _appendPublic(fileName, text)) {
          _everPersisted = true;
          return;
        }
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
          _fallbackWrittenPath = dir.path;
          _everPersisted = true;
        } catch (e) {
          debugPrint('[ErrorLogger] write failed: $e');
        }
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    await completer.future;
  }

  /// 写入公共目录：Android 10+ 用原生 MediaStore；≤9 直写公共 Documents。
  Future<bool> _appendPublic(String fileName, String text) async {
    try {
      final level = await apiLevel;
      if (level >= 29) {
        // MediaStore 每次插入都是新文件，无法追加 —— 所以按天聚合，
        // 由 Dart 侧缓存当日内容，退出/超限时整份重写。
        return await _rewriteMediaStore(fileName, text);
      }
      // ≤9：写公共 Documents 需要 WRITE_EXTERNAL_STORAGE。
      // 这里**不主动弹权限框**（日志是隐式路径，突然弹窗体验很差），
      // 只读取当前授权状态；未授权则直接降级到 App 私有目录。
      if (!await _hasStoragePermission()) return false;
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
      _publicDirPath = dir.path;
      return true;
    } catch (e) {
      debugPrint('[ErrorLogger] public write failed: $e');
      return false;
    }
  }

  /// 检查是否已有存储权限（不弹窗）
  ///
  /// 日志写入属于隐式路径，绝不能突然弹出权限请求框。
  /// 用户可在「设置 → 诊断 → 存储权限」手动授权。
  Future<bool> _hasStoragePermission() async {
    try {
      final service = StoragePermissionService.instance;
      final strategy = await service.currentStrategy();
      return strategy != StorageStrategy.appFallback;
    } catch (e) {
      debugPrint('[ErrorLogger] permission check failed: $e');
      return false;
    }
  }

  /// Android 10+：MediaStore 写入。
  /// 原生层负责「读旧内容 + 超限轮转 + 整份重写」，并返回实际写入位置。
  Future<bool> _rewriteMediaStore(String fileName, String text) async {
    try {
      final ok = await _channel.invokeMethod<String>('appendText', {
        'displayName': fileName,
        'relativePath': _relativePath,
        'content': text,
        'maxBytes': maxBytes,
      });
      if (ok != null && ok.isNotEmpty) {
        _publicDirPath = ok;
      }
      return ok != null;
    } catch (e) {
      debugPrint('[ErrorLogger] media store write failed: $e');
      return false;
    }
  }


  /// 对日志文本脱敏：token/authorization/签名等敏感字段打码。
  ///
  /// 日志落在公共 Documents 目录（文件管理器可见，且用户可能分享），
  /// 响应体/header 中的凭据必须先脱敏再落盘。
  ///
  /// V33-03（修复①，第 13/14 条）：B-17 旧正则只覆盖 `token/authorization/
  /// sign/cookie` 等，漏掉 `dfid/t1/userid/mobile` 这类同属凭证的字段，
  /// 导致 `"dfid":"xxxx"`、`"t1":"..."`、手机号在公共日志里明文残留。
  /// 补 `dfid|t1|userid|mobile（仅 11 位数字）` 键，并兼容
  /// `"key":`/`'key':`/key=value/key: value 四种形态。
  static String _redact(String s) {
    // key=value / key: value / "key":"value" / 'key':'value' 形式
    // （覆盖 header 与 JSON / YAML body）。
    // V33-03（修复①，第 13/14 条，B-17）：新增 dfid / t1 / userid / mobile 键，
    // 兼容双引号与单引号两种 JSON 形态。用普通字符串（非 raw）以正确转义引号。
    s = s.replaceAllMapped(
      RegExp(
        '((?:authorization|token|access[_-]?token|refresh[_-]?token|api[_-]?key|'
        'secret|sign(ature)?|cookie|session(?:_id)?|dfid|t1|userid|mobile)\\s*[=:]\\s*)'
        '(?:"([^"]*)"|\'([^\']*)\'|(\\S+))',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}***',
    );
    // 仅对 11 位手机号做兜底（避免误伤普通数字），兼容带引号形态
    s = s.replaceAllMapped(
      RegExp(r'("mobile"\s*:\s*")(1\d{10})(")'),
      (m) => '${m.group(1)}***${m.group(3)}',
    );
    // Bearer / Basic 凭据
    s = s.replaceAllMapped(
      RegExp(r'(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (m) => '${m.group(1)} ***',
    );
    return s;
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
      final s = _redact(body.toString());
      sb.writeln('响应: ${s.length > 800 ? '${s.substring(0, 800)}…' : s}');
    }
    await log(error, null, source: 'api', context: sb.toString());
  }

  /// 全局未捕获异常（FlutterError.onError）
  ///
  /// **不再调用 [FlutterError.presentError]**：它会把同一异常再打印一遍
  /// （红屏/控制台重复输出），与本方法自己的落盘日志重复。
  void handleFlutterError(FlutterErrorDetails details) {
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
  ///
  /// **只返回「实际确认写入」过的路径**：
  ///  - [_publicDirPath]：原生 MediaStore / 公共 Documents 写入成功后回传的真实位置；
  ///  - [_fallbackWrittenPath]：降级到 App 私有目录并成功落盘后的目录。
  ///
  /// 尚未真正写入过任何日志时返回 null —— 不能把「计划路径」当成「实际路径」误导用户。
  ///
  /// B-20（v3.3 修复①，第 9 条）：若本次进程从未成功落盘（公共与私有双双失败），
  /// 返回哨兵串「（日志仅进程内）」而非 null/假路径——让用户明确知道日志
  /// 此刻只在内存、重启即丢，而不是误以为写到了某个目录。
  Future<String?> currentDirPath() async {
    await init();
    final public = _publicDirPath;
    if (public != null && public.isNotEmpty) {
      return public.endsWith('/')
          ? public.substring(0, public.length - 1)
          : public;
    }
    if (_fallbackWrittenPath != null && _fallbackWrittenPath!.isNotEmpty) {
      return _fallbackWrittenPath;
    }
    if (!_everPersisted) return '（日志仅进程内）';
    return null;
  }

  /// Android API 级别
  ///
  /// 优先走原生通道（返回真实 Build.VERSION.SDK_INT）；
  /// 通道不可用时退回 [StoragePermissionService] 的版本名映射兜底。
  ///
  /// B-21（v3.3 修复①，第 13 条）：旧实现通道失败恒返回 29。原生通道偶发回
  /// 单数字（如 Android 9 上报 `9` 而非真实 `28`），若直接用作 SDK 级别会
  /// 让 ≤28 分支判定错乱。这里对「明显非法」的返回值（≤0 或低于最低支持
  /// 版本 21）统一兜底到 29（走 MediaStore 现代路径，最保守、不会主动去碰
  /// 需要 WRITE_EXTERNAL_STORAGE 的旧分支），避免误判。
  static Future<int> get apiLevel async {
    try {
      final level = await StoragePermissionService.instance.apiLevel();
      if (level >= 21) return level;
    } catch (_) {}
    return 29;
  }

  static String _dateTag(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
