import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// v5.2 用户需求：外观设置字体管理器。
///
/// 字体三来源：
/// - 系统（默认，fontFamily=null）
/// - 内置 Ubuntu Mono（assets/fonts，已随包注册）
/// - 私有字体（用户添加：本地文件 / URL 下载，存 App 支持目录 fonts/）
///
/// 思源宋体为可选内置项：包体积考虑不预置，提示用户经「添加字体」导入。
/// 所有私有字体经 `FontLoader` 运行时注册（动态字体，无需重编译）。

class CustomFont {
  const CustomFont({
    required this.id,
    required this.displayName,
    required this.filePath,
    required this.addedAtMs,
  });

  /// 稳定 id：文件名去扩展名
  final String id;
  final String displayName;
  final String filePath;
  final int addedAtMs;

  Map<String, dynamic> toMap() => {
        'id': id,
        'displayName': displayName,
        'filePath': filePath,
        'addedAtMs': addedAtMs,
      };

  static CustomFont fromMap(Map<dynamic, dynamic> m) => CustomFont(
        id: '${m['id']}',
        displayName: '${m['displayName']}',
        filePath: '${m['filePath']}',
        addedAtMs: int.tryParse('${m['addedAtMs']}') ?? 0,
      );
}

/// 字体注册表 Provider（Hive `custom_fonts` 箱持久化）。
class CustomFontStore {
  CustomFontStore._();
  static final instance = CustomFontStore._();

  static const _boxName = 'custom_fonts';
  Box<Map>? _box;

  Future<Box<Map>> _boxOrOpen() async {
    _box ??= await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  Future<List<CustomFont>> list() async {
    final box = await _boxOrOpen();
    return box.values.map(CustomFont.fromMap).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  /// 本地文件导入：复制到 App 支持目录 fonts/（原文件可删除不失效）。
  Future<CustomFont> importLocal(String sourcePath) async {
    final f = File(sourcePath);
    if (!await f.exists()) throw Exception('源文件不存在: $sourcePath');
    final ext = p.extension(sourcePath).toLowerCase();
    if (ext != '.ttf' && ext != '.otf') {
      throw Exception('仅支持 .ttf / .otf 字体文件');
    }
    final name = p.basenameWithoutExtension(sourcePath);
    return _install(name, await f.readAsBytes());
  }

  /// URL 下载导入：GET → 校验大小上限 20MB → 安装。
  Future<CustomFont> importUrl(String url, {String? displayName}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.scheme.startsWith('http')) {
      throw Exception('URL 格式无效');
    }
    final resp = await http.get(uri).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw Exception('下载失败 HTTP ${resp.statusCode}');
    }
    final bytes = resp.bodyBytes;
    if (bytes.lengthInBytes > 20 * 1024 * 1024) {
      throw Exception('字体文件超过 20MB 上限');
    }
    final guessName = displayName ?? p.basename(uri.path).replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');
    return _install(guessName.isEmpty ? 'font' : guessName, bytes);
  }

  Future<CustomFont> _install(String name, List<int> bytes) async {
    final dir = await _fontsDir();
    final safeId = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_');
    final target = File('${dir.path}/$safeId.ttf');
    await target.writeAsBytes(bytes, flush: true);

    final font = CustomFont(
      id: safeId,
      displayName: name,
      filePath: target.path,
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final box = await _boxOrOpen();
    await box.put(safeId, font.toMap());
    await _registerRuntime(font);
    return font;
  }

  Future<void> remove(String id) async {
    final box = await _boxOrOpen();
    final font = box.get(id);
    if (font != null) {
      final f = File(CustomFont.fromMap(font).filePath);
      if (await f.exists()) await f.delete();
    }
    await box.delete(id);
  }

  /// 运行时注册（App 每次启动对全部私有字体执行一次，幂等）。
  Future<void> registerAll() async {
    try {
      for (final font in await list()) {
        await _registerRuntime(font);
      }
    } catch (e) {
      debugPrint('[font] registerAll failed: $e');
    }
  }

  Future<void> _registerRuntime(CustomFont font) async {
    final f = File(font.filePath);
    if (!await f.exists()) return;
    final loader = FontLoader(font.id)..addFont(Future.value(f.readAsBytesSync()));
    await loader.load();
  }

  Future<Directory> _fontsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/fonts');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

/// 当前选中字体 id 的持久化 Provider。
/// 'system' = 系统默认；'Ubuntu Mono' = 内置；其它 = 私有字体 id。
class AppFontNotifier extends StateNotifier<String> {
  AppFontNotifier() : super('system');

  static const _key = 'appFontId';

  Future<void> load() async {
    try {
      final box = await Hive.openBox('settings');
      state = '${box.get(_key, defaultValue: 'system')}';
    } catch (e) {
      debugPrint('[font] load failed: $e');
    }
  }

  Future<void> set(String fontId) async {
    state = fontId;
    try {
      final box = await Hive.openBox('settings');
      await box.put(_key, fontId);
    } catch (e) {
      debugPrint('[font] save failed: $e');
    }
  }
}

final appFontProvider = StateNotifierProvider<AppFontNotifier, String>(
  (ref) => AppFontNotifier(),
);

final customFontsProvider =
    FutureProvider<List<CustomFont>>((ref) => CustomFontStore.instance.list());
