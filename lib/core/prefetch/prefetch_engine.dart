/// 预加载引擎（v4.0.1-C1，标 V401-C1-01）。
///
/// 职责（TASK_v400_arch.md 模块二冻结契约 + TASK_v400_c.md C1 窄变体）：
/// - 启动预热：[enqueueSongs] 按 [spacing] 逐个入队，只预请求
///   URL/歌词/封面 **JSON**（走 `ResourceCache.json`，不下载实际文件）；
/// - 播放队列补充：[updateUpcoming] 对未来 [window] 首去重补充；
/// - 完整播放完成 hook：[onPlaybackCompleted] 调
///   `ResourceCache.instance.cacheUrlFile(url, kind)` 把实际文件永久缓存。
///
/// 纪律对应（QUALITY_STANDARD.md）：
/// - 第 5/22 条：入队/去重状态单一来源（本类内存 Map），单 isolate 前提显式；
/// - 第 9/6 条：所有 fetch 异步异常必须接住并 debugPrint 留痕，绝不上抛
///   阻塞调用方（fire-and-forget）；
/// - 第 25 条：预热任务总量、单次 pending 数量都有常量上界，Timer 对称释放；
/// - 第 18 条：dispose 后异步回调先检查存活状态（_disposed）再动作。
///
/// 缓存键维度（第 23 条）：统一走 [CachedApiCall]（其 _keyOf 已拼 path +
/// 排序 query + userid），本模块不自拼键，与 repository 侧读写天然同键
/// ——预热命中的缓存播放时直接复用，不造双实现。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/player/data/models.dart';
import '../api/kugou_api_client.dart';
import '../resource/cached_api.dart';
import '../resource/resource_cache.dart';

class PrefetchEngine {
  PrefetchEngine._();

  static final instance = PrefetchEngine._();

  /// 已入队（预热 + upcoming 共用）的 hash 去重集（第 5 条：单一事实源）。
  /// 同一 hash 本进程只预请求一轮；in-flight 合并由 ResourceCache 内部
  /// （_inFlight）兜底，这里是「不再二次入队」的上游闸门。
  final _requested = <String>{};

  /// 待处理队列：逐个按 spacing 消费（第 25 条：有界，enqueueSongs 截断）。
  final _pending = <Song>[];

  Timer? _drainTimer;

  /// 消费循环中的 Songs（防 dispose 后定时器已取消但闭包仍在跑）。
  bool _disposed = false;

  /// 预热单次入队上限（第 25 条：一切资源必须有上限）。
  /// 首页各类型 + 收藏歌单歌曲总数可能上千，逐个 100ms 也排不完，
  /// 取 60 首（约 6 秒排空）覆盖首屏可见量级。
  static const int _maxEnqueuePerCall = 60;

  /// API 客户端：只读使用（userid 等登录态由进程内共享 CookieJar 与
  /// KugouApiClient.userid 承载，第 23 条键维度由 CachedApiCall 拼）。
  ///
  /// 显式注入（第 2 条）而非内部 new：调用方把进程内已登录态的 client
  /// 传进来（CachedApiCall 内部读 api.userid 拼缓存键维度）；未调用
  /// [attach] 前入队只收集不请求。
  CachedApiCall? _cached;

  void attach(KugouApiClient api) {
    _cached = CachedApiCall(api);
  }

  /// 启动预热：按 [spacing] 逐个入队（冻结契约签名）。
  ///
  /// 只预请求 URL/歌词/封面 JSON（[_prefetchOne]），不下载实际文件。
  /// 已在 [requested] 集合中的 hash 直接跳过（幂等，第 21 条）。
  /// 非阻塞：本方法同步返回，网络全部在后台排队进行。
  void enqueueSongs(Iterable<Song> songs,
      {Duration spacing = const Duration(milliseconds: 100)}) {
    if (_disposed) return;
    var taken = 0;
    for (final song in songs) {
      if (taken >= _maxEnqueuePerCall - _pending.length) break;
      if (song.hash.isEmpty) continue;
      if (!_requested.add(song.hash)) continue; // 已命中缓存/已入队：跳过
      _pending.add(song);
      taken++;
    }
    if (_pending.isEmpty) return;
    _startDrain(spacing);
  }

  /// 播放队列未来 [window] 首补充（冻结契约签名）。
  ///
  /// 队列变化/切歌时重入安全：已请求过的 hash 跳过；shuffle 时调用方
  /// 传入的 [queue] 本身就是当前队列序（本模块不重排，第 1 条单一职责
  /// ——shuffle 语义归 player_provider）。
  void updateUpcoming(List<Song> queue, int currentIndex, {int window = 15}) {
    if (_disposed) return;
    if (queue.isEmpty) return;
    // 边界校验（第 14 条）：currentIndex 越界时按队首处理，不抛。
    final start = (currentIndex < 0 || currentIndex >= queue.length)
        ? 0
        : currentIndex;
    final upcoming = <Song>[];
    for (var i = start; i < queue.length && upcoming.length < window; i++) {
      final song = queue[i];
      if (song.hash.isEmpty) continue;
      if (!_requested.add(song.hash)) continue;
      upcoming.add(song);
    }
    if (upcoming.isEmpty) return;
    // upcoming 优先级高于启动预热余量：插队头（第 24 条：近的先算）。
    _pending.insertAll(0, upcoming);
    _startDrain(const Duration(milliseconds: 100));
  }

  /// 完整播放完成 hook（V402：声明字节数为身份的一部分）。
  ///
  /// [url] + [declaredBytes] 必须来自**同一次播放 JSON 响应**；
  /// declaredBytes<=0（未声明）由 ResourceCache 拒绝入库（第 14 条）。
  /// 试听片段/通用预览不调用本方法（audio_handler 判 isPreview）。
  void onPlaybackCompleted(String url, String kind,
      {int declaredBytes = 0}) {
    if (_disposed) return;
    if (url.isEmpty) return;
    ResourceCache.instance
        .cacheUrlFile(url, kind, declaredBytes: declaredBytes)
        .catchError((Object e) {
      debugPrint('[prefetch] cacheUrlFile($kind) failed: $e');
      return null;
    });
  }

  /// 启动/续期消费定时器（对称释放点：_disposeTimer）。
  void _startDrain(Duration spacing) {
    if (_disposed) return;
    _drainTimer?.cancel();
    _drainTimer = Timer.periodic(spacing, (_) => _drainOne());
  }

  /// 每个节拍消费一首（第 24 条：请求按 spacing 摊开，不瞬间并发）。
  void _drainOne() {
    if (_disposed) return;
    if (_pending.isEmpty) {
      _disposeTimer();
      return;
    }
    final song = _pending.removeAt(0);
    // fire-and-forget 但异常必接住（第 6 条）：_prefetchOne 内部全捕获，
    // Future 永不 error 完成，此处不等待即安全（无 async_awaited lint，
    // unawaited 未在依赖内，不引额外 import）。
    _prefetchOne(song);
  }

  /// 预请求一首歌的 URL/歌词/封面 JSON。
  ///
  /// 只走 ResourceCache.json（168h TTL，kJsonTtl 默认值），已命中缓存的
  /// 直接返回不发网络（由 ResourceCache 判定，本模块不重复判缓存）。
  /// 任何失败留痕不崩（第 9 条）。
  Future<void> _prefetchOne(Song song) async {
    final cached = _cached;
    if (cached == null) {
      debugPrint('[prefetch] attach() not called, skip prefetch: ${song.hash}');
      return;
    }
    try {
      // 1) 播放地址 JSON（kapi /song/url，含音质参数；直连 /v5/url 不经
      //    kapi 也无 JSON 可缓存，预热只覆盖 kapi 路径，直连由播放时解析）。
      await cached.get('/song/url', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
        'quality': song.quality.value,
      });
    } catch (e) {
      debugPrint('[prefetch] url json failed (${song.name}): $e');
    }
    try {
      // 2) 歌词候选 JSON（/search/lyric；歌词正文 /lyric 依赖候选里的
      //    id/accesskey，候选 JSON 命中后正文在播放时一并命中缓存）。
      await cached.get('/search/lyric', query: {'hash': song.hash});
    } catch (e) {
      debugPrint('[prefetch] lyric json failed (${song.name}): $e');
    }
    try {
      // 3) 封面：song.cover 已是解析好的图片 URL（models 解析阶段完成），
      //    项目无独立的「封面 JSON」接口（api_verified.md 实测只有
      //    album/detail 等专辑接口，返回体是歌曲列表而非封面 JSON）——
      //    为封面预热再造一个未实测端点违背第 28 条（调用方式必须逐一
      //    实测）。封面字符串在 Song 对象内已就绪，无需预请求。
      //    album_id 非空时预热 album/detail（已实测，st=1 data=list[1]），
      //    供播放页/详情页后续直接命中缓存。
      if (song.albumId.isNotEmpty) {
        await cached.get('/album/detail', query: {'album_id': song.albumId});
      }
    } catch (e) {
      debugPrint('[prefetch] cover/album json failed (${song.name}): $e');
    }
  }

  /// 定时器对称释放（第 20 条）。
  void _disposeTimer() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  /// 释放（冻结契约签名）：取消定时器、清队列与去重集。
  /// 进行中的单个 fetch 无定时器持有、结果只写缓存，无需取消也安全。
  void dispose() {
    _disposed = true;
    _disposeTimer();
    _pending.clear();
    _requested.clear();
    _cached = null;
  }
}
