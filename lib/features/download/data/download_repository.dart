import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/direct/kg_play_api.dart';
import '../../lyric/data/krc_parser.dart';
import '../../lyric/data/lyric_repository.dart';
import '../../mv/data/mv_repository.dart';
import 'download_task.dart';
import 'public_media_store.dart';
import '../../../core/storage/storage_permission.dart';

/// 下载执行器。
///
/// 负责：解析直连播放地址、Dio 下载文件、歌词抓取落盘。
class DownloadRepository {
  DownloadRepository({
    KgPlayApi? playApi,
    LyricRepository? lyricRepository,
    MvRepository? mvRepository,
    Dio? dio,
  })  : _playApi = playApi,
        _lyricRepository = lyricRepository,
        _mvRepository = mvRepository,
        _dio = dio ??
            Dio(BaseOptions(
              // CDN 挂起时任务不能永远停在 running
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 10),
            ));

  final KgPlayApi? _playApi;
  final LyricRepository? _lyricRepository;
  final MvRepository? _mvRepository;
  final Dio _dio;

  /// 直连酷狗 CDN 需要的 UA 头
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// V399-B4：下载音频唯一解析入口。
  ///
  /// 非 VIP（仅试听权益）时，同时比较 API **声明的字节数**（不下载比对）：
  ///  - 试听片段：/v5/url 响应体 `filesize`；
  ///  - 高潮片段：`hash_offset.start_byte/end_byte` 之差（offset_hash 标识）。
  /// 选长者作为下载源；高潮片段更长时用 offset_hash 再发一次**元数据请求**
  /// 拿它的直连 URL（仍是 API 调用，不是下载）。
  ///
  /// 历史：resolveAudioUrl / resolveAudioExt / resolveAudioUrlWithExt 三个
  /// 方法已被本实现取代并删除（第 32 条死代码零容忍）；全曲（VIP/免费）
  /// 情形下行为与原 resolveAudioUrlWithExt 一致（单次 songUrl 同时拿
  /// url + 扩展名）。
  ///
  /// 返回 (url, ext, 片段类型)；片段类型 'full'/'trial'/'climax' 供任务
  /// 元信息（DownloadTask.segment）记录。
  Future<(String, String, String)> resolveAudioDownloadSource(
    String hash, {
    required String albumId,
    required String albumAudioId,
    required String quality,
  }) async {
    final api = _playApi;
    if (api == null) throw StateError('播放接口未初始化');
    final albumIdInt = int.tryParse(albumId) ?? 0;
    final audioIdInt = int.tryParse(albumAudioId) ?? 0;

    // 1) 先试全曲（VIP/免费曲直接走原路径）
    final full = await api.songUrl(
      hash: hash,
      albumId: albumIdInt,
      albumAudioId: audioIdInt,
      quality: quality,
    );
    if (full.hasUrl && !full.isPreview) {
      final (url, ext) = _urlAndExt(full);
      return (url, ext, 'full');
    }

    // 2) 非全曲：试听通道（IsFreePart=1），从同一响应里读两段声明的字节数
    final preview = await api.songUrl(
      hash: hash,
      albumId: albumIdInt,
      albumAudioId: audioIdInt,
      quality: quality,
      freePart: true,
    );
    if (!preview.hasUrl) {
      throw StateError(preview.message.isEmpty
          ? '该音质需要会员或付费，且无试听片段'
          : '该音质需要会员或付费（${preview.message}）');
    }
    final trialUrl = preview.bestUrl!;
    final trialBytes = preview.previewFileSize;
    final climaxBytes = preview.offsetFileSize;

    // 3) 择优：高潮片段声明字节数更长且能解析到 URL 时选高潮（不下载比对）
    if (preview.offsetHash.isNotEmpty && climaxBytes > trialBytes) {
      try {
        final climax = await api.songUrl(
          hash: preview.offsetHash,
          albumId: albumIdInt,
          albumAudioId: audioIdInt,
          quality: quality,
        );
        if (climax.hasUrl && !climax.isPreview) {
          final (url, ext) = _urlAndExt(climax);
          return (url, ext, 'climax');
        }
      } catch (_) {
        // V399-B4：高潮片段解析失败必须留痕并回落试听（第 9 条），不可静默
        debugPrint('[download] climax(offset_hash) 解析失败，回落试听片段');
      }
    }
    final (_, ext) = _urlAndExt(preview);
    return (trialUrl, ext, 'trial');
  }

  /// 从 PlayUrlResult 取直连 URL 与真实容器扩展名（本文件内共用）
  static (String, String) _urlAndExt(PlayUrlResult result) {
    final url = result.bestUrl!;
    const audioExts = {'mp3', 'flac', 'ogg', 'm4a', 'wav', 'aac', 'ape'};
    final ext = result.extName.trim().toLowerCase();
    if (audioExts.contains(ext) && ext != 'mp3') return (url, '.$ext');
    final m =
        RegExp(r'\.(mp3|flac|ogg|m4a|wav|aac|ape)(\?|$)').firstMatch(url);
    return (url, m != null ? '.${m.group(1)}' : '.mp3');
  }

  /// 解析 MV 播放地址（http → 代理 https）
  Future<String> resolveMvUrl(String albumAudioId, String mvHash) async {
    final repo = _mvRepository;
    if (repo == null) throw StateError('MV 接口未初始化');
    if (mvHash.isNotEmpty) return repo.resolvePlayUrl(mvHash);
    final list = await repo.findBySong(albumAudioId);
    if (list.isEmpty) throw StateError('该歌曲暂无 MV');
    final best = list.first;
    final hash = best.bestHash;
    if (hash == null || hash.isEmpty) throw StateError('该 MV 暂无可用清晰度');
    return repo.resolvePlayUrl(hash);
  }

  /// 下载单个文件到 [savePath]。
  ///
  /// [onProgress] 回调 (received, total)；[cancelToken] 支持取消；
  /// 仅对可重试错误（网络层错误、超时、5xx）重试 [retries] 次，
  /// 指数退避：1s、2s、4s…。404/403 等 4xx 不重试。
  Future<void> downloadFile(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    int retries = 2,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await _dio.download(
          url,
          savePath,
          cancelToken: cancelToken,
          options: Options(
            headers: {
              'User-Agent': userAgent,
              'Referer': 'https://www.kugou.com/',
            },
            followRedirects: true,
          ),
          onReceiveProgress: onProgress,
        );
        return;
      } on DioException catch (e) {
        if (cancelToken != null && cancelToken.isCancelled) rethrow;
        if (!_isRetryable(e) || attempt > retries) rethrow;
        // 指数退避：1s, 2s, 4s...
        await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
      }
    }
  }

  /// 是否值得重试：网络层错误/超时/5xx。4xx（404/403/签名过期）不重试。
  static bool _isRetryable(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return true;
      default:
        final status = e.response?.statusCode ?? 0;
        return status >= 500 && status < 600;
    }
  }

  /// 下载封面
  Future<String> downloadCover(String url, String savePath,
      {void Function(int received, int total)? onProgress,
      CancelToken? cancelToken}) async {
    await downloadFile(
      url,
      savePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return savePath;
  }

  /// 下载歌词：KRC 原文 + 翻译文本，落盘为纯文本文件。
  Future<String> downloadLyric(
    DownloadTask task,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final repo = _lyricRepository;
    if (repo == null) throw StateError('歌词接口未初始化');
    final candidate = await repo.findCandidate(
      hash: task.hash,
      albumAudioId: task.albumAudioId,
      durationSec: task.durationSec,
    );
    if (candidate == null) throw StateError('暂无歌词');
    var lyric = await repo.fetchLyric(candidate);
    if (lyric == null) throw StateError('歌词解析失败');
    lyric = await repo.ensureTranslation(
        lyric, candidate.id, task.targetLanguage);
    final content = _lyricToText(lyric);
    final file = File(savePath);
    await file.writeAsString(content);
    onProgress?.call(content.length, content.length);
    return savePath;
  }

  /// 发布到公共目录，返回可访问位置。
  Future<PublishedFile> publish(
    DownloadTask task,
    String tempFilePath, {
    required StorageStrategy strategy,
  }) {
    final name = displayNameOf(task);
    return PublicMediaStore.instance.publish(
      type: task.type,
      tempFilePath: tempFilePath,
      displayName: name,
      strategy: strategy,
    );
  }

  /// 公共目录中的显示文件名
  ///
  /// V35-B3（第 B 批，P1）：audio 的真实扩展名由服务端 extName 决定
  ///（.flac/.m4a），V34-05 只修了临时文件链，**发布名仍用默认 .mp3**
  /// → .flac 内容以 .mp3 名入库（MIME 也错）。修复：realTempPath
  /// 非空时从其提取扩展名覆盖默认值。
  static String displayNameOf(DownloadTask task) {
    final base = '${task.artist} - ${task.title}'.trim();
    var safe = (base.isEmpty ? task.hash : base)
        // 非法字符 + Windows 控制字符
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    // 去尾部点/空格（Windows 同步到 NTFS/exFAT 时会报错）
    safe = safe.replaceAll(RegExp(r'[.\s]+$'), '');
    if (safe.isEmpty) safe = task.hash;
    var ext = task.type.fileExtension;
    if (task.type == DownloadTaskType.audio && task.realTempPath.isNotEmpty) {
      final realExt = task.realTempPath.substring(
          task.realTempPath.lastIndexOf('.'));
      if (realExt.length > 1) ext = realExt;
    }
    return '$safe$ext';
  }

  /// KRC → 可读文本（原文 + 译文对照）
  static String _lyricToText(KrcLyric lyric) {
    final buffer = StringBuffer();
    if (lyric.title != null && lyric.title!.isNotEmpty) {
      buffer.writeln('[ti]${lyric.title}');
    }
    if (lyric.artist != null && lyric.artist!.isNotEmpty) {
      buffer.writeln('[ar]${lyric.artist}');
    }
    for (final line in lyric.lines) {
      final ts = _fmtMs(line.startMs);
      buffer.writeln('$ts ${line.text}');
      final tr = line.translation;
      if (tr != null && tr.isNotEmpty) {
        buffer.writeln('$ts $tr');
      }
    }
    return buffer.toString();
  }

  static String _fmtMs(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10;
    return '[${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}]';
  }
}
