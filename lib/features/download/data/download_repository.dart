import 'dart:io';

import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/direct/kg_play_api.dart';
import '../../lyric/data/krc_parser.dart';
import '../../lyric/data/lyric_repository.dart';
import '../../mv/data/mv_repository.dart';
import 'download_task.dart';
import 'public_media_store.dart';
import 'storage_permission_service.dart';

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
        _dio = dio ?? Dio();

  final KgPlayApi? _playApi;
  final LyricRepository? _lyricRepository;
  final MvRepository? _mvRepository;
  final Dio _dio;

  /// 直连酷狗 CDN 需要的 UA 头
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 解析音频直连播放地址（http → 代理 https）
  Future<String> resolveAudioUrl(
    String hash, {
    String albumId = '',
    String albumAudioId = '',
    String quality = '128',
  }) async {
    final api = _playApi;
    if (api == null) throw StateError('播放接口未初始化');
    final result = await api.songUrl(
      hash: hash,
      albumId: int.tryParse(albumId) ?? 0,
      albumAudioId: int.tryParse(albumAudioId) ?? 0,
      quality: quality,
    );
    final url = result.bestUrl;
    if (url == null || url.isEmpty) {
      throw StateError(result.message.isEmpty ? '无可用播放地址' : result.message);
    }
    return AppConfig.proxyMvUrl(url);
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
  /// 失败时自动重试 [retries] 次（每次重试从头开始）。
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
      } catch (e) {
        if (cancelToken != null && cancelToken.isCancelled) rethrow;
        if (attempt > retries) rethrow;
      }
    }
  }

  /// 下载封面
  Future<String> downloadCover(String url, String savePath,
      {void Function(int received, int total)? onProgress,
      CancelToken? cancelToken}) async {
    await downloadFile(
      AppConfig.proxyMvUrl(url),
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
  Future<PublicMediaStore.PublishedFile> publish(
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
  static String displayNameOf(DownloadTask task) {
    final base = '${task.artist} - ${task.title}'.trim();
    final safe = (base.isEmpty ? task.hash : base)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return '$safe${task.type.fileExtension}';
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
