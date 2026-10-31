import 'package:hive_flutter/hive_flutter.dart';

import 'download_task.dart';

/// 下载任务持久化：Hive box 'downloads'。
///
/// key = 任务 id（`${type.name}_$hash`），value = 任务 JSON。
class DownloadStore {
  DownloadStore._();
  static final instance = DownloadStore._();

  static const boxName = 'downloads';

  static Box<dynamic>? _boxOrNull() =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// 读取全部任务（按创建时间倒序）。
  static List<DownloadTask> readAll() {
    final box = _boxOrNull();
    if (box == null) return const [];
    final result = <DownloadTask>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        result.add(DownloadTask.fromJson(raw));
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 读取单个任务。
  static DownloadTask? read(String id) {
    final box = _boxOrNull();
    if (box == null) return null;
    final raw = box.get(id);
    if (raw is Map) return DownloadTask.fromJson(raw);
    return null;
  }

  /// 写入（新增或更新）。
  static Future<void> save(DownloadTask task) async {
    final box = _boxOrNull();
    if (box == null) return;
    await box.put(task.id, task.toJson());
  }

  /// 删除。
  static Future<void> remove(String id) async {
    final box = _boxOrNull();
    if (box == null) return;
    await box.delete(id);
  }

  /// 清空全部记录。
  static Future<void> clear() async {
    final box = _boxOrNull();
    if (box == null) return;
    await box.clear();
  }
}
