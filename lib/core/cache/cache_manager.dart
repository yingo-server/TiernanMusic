import 'package:hive/hive.dart';

import '../config/app_config.dart';

/// 内存缓存（90 秒过期）
class MemoryCache {
  MemoryCache._();
  static final instance = MemoryCache._();

  final _cache = <String, _Entry>{};

  T? get<T>(String key) {
    final e = _cache[key];
    if (e == null) return null;
    if (DateTime.now().isAfter(e.expires)) {
      _cache.remove(key);
      return null;
    }
    return e.value as T?;
  }

  void set<T>(String key, T value, {Duration? ttl}) {
    if (_cache.length >= _maxEntries) _evict();
    _cache[key] = _Entry(
      value,
      DateTime.now().add(ttl ?? const Duration(seconds: AppConfig.memoryCacheSeconds)),
    );
  }

  /// 容量上限：超限时先清过期条目，仍超则按插入序（FIFO）淘汰最旧。
  static const _maxEntries = 200;

  void _evict() {
    final now = DateTime.now();
    _cache.removeWhere((_, e) => now.isAfter(e.expires));
    if (_cache.length >= _maxEntries) {
      final overflow = _cache.length - _maxEntries + 1;
      if (overflow > 0) {
        for (final k in _cache.keys.take(overflow).toList()) {
          _cache.remove(k);
        }
      }
    }
  }

  void clear() => _cache.clear();

  /// 按前缀清除（如刷新首页时清掉 '/yueku'、'/top/playlist'、'/rank/list' 等 key）。
  void removeWhere(bool Function(String key) test) {
    final keys = _cache.keys.where(test).toList();
    for (final k in keys) {
      _cache.remove(k);
    }
  }

  static String keyOf(String path, [Map<String, dynamic>? query]) {
    if (query == null || query.isEmpty) return path;
    final sorted = Map.fromEntries(
        query.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return '$path?${sorted.entries.map((e) => '${e.key}=${e.value}').join('&')}';
  }
}

class _Entry {
  _Entry(this.value, this.expires);
  final Object? value;
  final DateTime expires;
}

/// 歌词翻译持久缓存（按歌词 ID + 目标语言）
class LyricTranslationCache {
  LyricTranslationCache._();
  static final instance = LyricTranslationCache._();

  Box<String>? _box;

  Future<void> init() async {
    _box ??= await Hive.openBox<String>('lyric_translations');
  }

  /// B-29（第7批复核③）：键必须包含**全部影响结果的维度**（第 23 条）——
  /// 换翻译模型后，旧键下的译文对新模型无效。拼入 translateModel。
  String _key(String lyricId, String targetLang) =>
      '$lyricId:$targetLang@${AppConfig.translateModel}';

  Future<Map<int, String>?> get(String lyricId, String targetLang) async {
    await init();
    final raw = _box!.get(_key(lyricId, targetLang));
    if (raw == null) return null;
    final map = <int, String>{};
    for (final line in raw.split('\n')) {
      final idx = line.indexOf('\t');
      if (idx > 0) {
        map[int.parse(line.substring(0, idx))] = line.substring(idx + 1);
      }
    }
    return map;
  }

  Future<void> set(
      String lyricId, String targetLang, Map<int, String> translations) async {
    await init();
    final raw = translations.entries
        .map((e) => '${e.key}\t${e.value}')
        .join('\n');
    await _box!.put(_key(lyricId, targetLang), raw);
  }

  Future<void> clear() async {
    await init();
    await _box!.clear();
  }
}
