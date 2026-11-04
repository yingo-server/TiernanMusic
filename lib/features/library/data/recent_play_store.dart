import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

/// 最近播放记录
class RecentPlay {
  RecentPlay({
    required this.hash,
    required this.name,
    required this.artist,
    required this.cover,
    required this.ts,
    this.albumAudioId = '',
  });

  final String hash;
  final String name;
  final String artist;
  final String cover;
  final int ts; // 毫秒时间戳
  final String albumAudioId;

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'name': name,
        'artist': artist,
        'cover': cover,
        'ts': ts,
        'albumAudioId': albumAudioId,
      };

  factory RecentPlay.fromJson(Map<dynamic, dynamic> json) => RecentPlay(
        hash: '${json['hash'] ?? ''}',
        name: '${json['name'] ?? ''}',
        artist: '${json['artist'] ?? ''}',
        cover: '${json['cover'] ?? ''}',
        albumAudioId: '${json['albumAudioId'] ?? ''}',
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

  static final _changesCtrl = StreamController<void>.broadcast();

  /// 最近播放变化广播：add / clear 后触发，供 UI 订阅刷新。
  static Stream<void> get changes => _changesCtrl.stream;

  static void notifyListeners() => _changesCtrl.add(null);

  /// box 未打开时先懒打开，避免冷启动首次进入永远读到空列表。
  static Future<List<RecentPlay>> read() async {
    if (!Hive.isBoxOpen(_boxName)) await Hive.openBox(_boxName);
    final raw = _box.get(_kList, defaultValue: <dynamic>[]) as List<dynamic>;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(RecentPlay.fromJson)
        .where((r) => r.hash.isNotEmpty)
        .toList();
  }

  /// 串行队列：防止并发 add 的「读-改-写」互相覆盖（快速连播会丢记录）。
  static Future<void> _serial = Future<void>.value();

  static Future<void> add(RecentPlay item) {
    // 链式排队：后一个写入等前一个完成
    final next = _serial.then((_) => _addInner(item));
    // 失败不阻断后续（同时保留错误可观测性）
    _serial = next.catchError((Object e) {
      // ignore: avoid_print
      return;
    });
    return next;
  }

  static Future<void> _addInner(RecentPlay item) async {
    final box = Hive.isBoxOpen(_boxName) ? _box : await Hive.openBox(_boxName);
    final list = await read()
      ..removeWhere((e) => e.hash == item.hash)
      ..insert(0, item);
    if (list.length > _max) list.removeRange(_max, list.length);
    await box.put(_kList, list.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  /// 清空全部最近播放记录。
  static Future<void> clear() async {
    if (!Hive.isBoxOpen(_boxName)) return;
    await _box.delete(_kList);
    notifyListeners();
  }
}
