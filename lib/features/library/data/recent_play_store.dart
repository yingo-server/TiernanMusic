import 'package:hive_flutter/hive_flutter.dart';

/// 最近播放记录
class RecentPlay {
  RecentPlay({
    required this.hash,
    required this.name,
    required this.artist,
    required this.cover,
    required this.ts,
  });

  final String hash;
  final String name;
  final String artist;
  final String cover;
  final int ts; // 毫秒时间戳

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'name': name,
        'artist': artist,
        'cover': cover,
        'ts': ts,
      };

  factory RecentPlay.fromJson(Map<dynamic, dynamic> json) => RecentPlay(
        hash: '${json['hash'] ?? ''}',
        name: '${json['name'] ?? ''}',
        artist: '${json['artist'] ?? ''}',
        cover: '${json['cover'] ?? ''}',
        ts: (json['ts'] is int) ? json['ts'] as int : int.tryParse('${json['ts']}') ?? 0,
      );
}

/// 最近播放存储：Hive box 'recent_plays'，key 固定 'list'，最多 50 条，去重置顶。
class RecentPlayStore {
  RecentPlayStore._();
  static const _boxName = 'recent_plays';
  static const _kList = 'list';
  static const _max = 50;

  static Box<dynamic> get _box => Hive.isBoxOpen(_boxName)
      ? Hive.box(_boxName)
      : throw StateError('recent_plays box 未打开');

  static List<RecentPlay> read() {
    if (!Hive.isBoxOpen(_boxName)) return const [];
    final raw = _box.get(_kList, defaultValue: <dynamic>[]) as List<dynamic>;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(RecentPlay.fromJson)
        .where((r) => r.hash.isNotEmpty)
        .toList();
  }

  static Future<void> add(RecentPlay item) async {
    final box = Hive.isBoxOpen(_boxName) ? _box : await Hive.openBox(_boxName);
    final list = read()
      ..removeWhere((e) => e.hash == item.hash)
      ..insert(0, item);
    if (list.length > _max) list.removeRange(_max, list.length);
    await box.put(_kList, list.map((e) => e.toJson()).toList());
  }
}
