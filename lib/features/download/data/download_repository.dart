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
    // DL-01（审查③）：试听片段（60s）不能当完整歌曲落盘——
    // isPreview 时直接拒绝，错误信息带上 failProcess 让用户知道原因。
    if (result.isPreview) {
      throw StateError(result.failProcess.isNotEmpty
          ? '该音质需要会员或付费（${result.failProcess.join('/')}），不支持下载'
          : '仅获取到试听片段，完整歌曲需要相应权益');
    }
    // 直连原始地址（kugou 子域已允许 cleartext），代理不支持 Range 会拖慢/截断下载
    return url;
  }

  /// DL-02（审查③）：服务端实际扩展名（extName 缺失时从 URL 推断）。
  /// 供下载侧写入正确的文件名与 MIME，不再硬编码 .mp3。
  Future<String> resolveAudioExt(
      {required String hash,
      required String albumId,
      required String albumAudioId,
      required String quality}) async {
    final api = _playApi;
    if (api == null) return '.mp3';
    final result = await api.songUrl(
      hash: hash,
      albumId: int.tryParse(albumId) ?? 0,
      albumAudioId: int.tryParse(albumAudioId) ?? 0,
      quality: quality,
    );
    final ext = result.extName.trim().toLowerCase();
    if (ext.isNotEmpty && ext != 'mp3') return '.$ext';
    // 从 URL 路径兜底
    final url = result.bestUrl ?? '';
    final m = RegExp(r'\.(mp3|flac|ogg|m4a|wav)(\?|$)').firstMatch(url);
    return m != null ? '.${m.group(1)}' : '.mp3';
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
  static String displayNameOf(DownloadTask task) {
    final base = '${task.artist} - ${task.title}'.trim();
    var safe = (base.isEmpty ? task.hash : base)
        // 非法字符 + Windows 控制字符
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    // 去尾部点/空格（Windows 同步到 NTFS/exFAT 时会报错）
    safe = safe.replaceAll(RegExp(r'[.\s]+$'), '');
    if (safe.isEmpty) safe = task.hash;
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
