import 'dart:async';

import 'package:file/file.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 全局图片缓存（串行化）。
///
/// 【为什么需要】
/// `flutter_cache_manager` 用 sqflite 记录缓存元数据，本身**不做并发控制**。
/// 首页/列表一次并发拉几十张封面时，多个事务同时 `BEGIN EXCLUSIVE`，
/// 真机实测会刷出大量：
///
///   DatabaseException(database is locked (code 5 SQLITE_BUSY))
///   sql 'BEGIN EXCLUSIVE'
///
/// 这些异常会被 Flutter 的全局错误处理捕获、写进错误日志（每次几十条），
/// 既污染日志又拖慢 IO。
///
/// 【做法】
/// 用同一个 CacheManager 实例，并把「下载/写入」操作串行化——同一时刻只有
/// 一个 DB 事务，彻底消除 BUSY；图片仍并行渲染（解码不受影响）。
///
/// 所有 `CachedNetworkImage` / `CachedNetworkImageProvider` 都必须显式
/// 传 `cacheManager: AppImageCache.instance`，否则会退回默认实例，
/// 又变成多实例并发写同一个 DB。
class AppImageCache extends CacheManager {
  AppImageCache._()
      : super(Config(
          'tiernanImageCache',
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 600,
          // B-28（v3.3 修复①，第 25 条）：原无字节上限，低端机长期积累封面
          // 撑爆内部存储。加 500MB 硬上限，CacheManager 按 LRU 自动淘汰最旧条目。
          maxCacheSizeBytes: 500 * 1024 * 1024,
        ));

  static final AppImageCache instance = AppImageCache._();

  /// 串行队列：把下载与写入排成一条链，避免并发 DB 事务。
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) =>
      _serial(() => super.getSingleFile(url, key: key, headers: headers));

  /// C-01（审查②）：CachedNetworkImage 的加载链路走 getFileStream，
  /// 不串行化则 sqflite 并发写事务 → SQLITE_BUSY。
  /// async* 包串行队列：每次调用排队，消费 super 的流并转发。
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    await _serial(() async {});
    yield* super.getFileStream(url,
        key: key, headers: headers, withProgress: withProgress);
  }
}
