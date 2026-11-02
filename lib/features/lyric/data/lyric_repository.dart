import 'dart:convert';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/api/translate_api.dart';
import '../../../core/cache/cache_manager.dart';
import 'krc_decoder.dart';
import 'krc_parser.dart';

class LyricRepository {
  LyricRepository(this._api, this._translate);

  final KugouApiClient _api;
  final TranslateApi _translate;

  /// 搜索歌词候选
  Future<LyricCandidate?> findCandidate({
    String? hash,
    String? keywords,
    String? albumAudioId,
    int? durationSec,
  }) async {
    final query = <String, dynamic>{
      if (hash != null) 'hash': hash,
      if (keywords != null) 'keywords': keywords,
      if (albumAudioId != null) 'album_audio_id': albumAudioId,
      if (durationSec != null) 'duration': durationSec,
    };
    final cacheKey = MemoryCache.keyOf('/search/lyric', query);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/search/lyric', query: query);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);

    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    final c = candidates.first as Map<String, dynamic>;
    return LyricCandidate(
      id: '${c['id']}',
      accessKey: '${c['accesskey']}',
      duration: c['duration'] is int ? c['duration'] as int : null,
    );
  }

  /// 获取并解析 KRC 歌词（客户端解密或服务端 decode=true）
  Future<KrcLyric?> fetchLyric(
    LyricCandidate candidate, {
    String format = 'krc',
  }) async {
    if (format != 'krc' && format != 'lrc') {
      throw ArgumentError.value(format, 'format', '仅支持 krc 或 lrc');
    }
    final query = {
      'id': candidate.id,
      'accesskey': candidate.accessKey,
      'fmt': format,
      'decode': 'true',
    };
    final cacheKey = MemoryCache.keyOf('/lyric', query);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/lyric', query: query);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);

    // 优先用服务端 decodeContent；LRC 的 content 是明文 Base64，KRC 则加密。
    String? krcText;
    final decoded = data['decodeContent'];
    if (decoded is String && decoded.isNotEmpty) {
      krcText = decoded;
    } else if (data['content'] is String) {
      try {
        krcText = format == 'lrc'
            ? utf8.decode(base64.decode(
                base64.normalize((data['content'] as String).trim())),
                allowMalformed: true)
            : KrcDecoder.decode(data['content'] as String);
      } catch (_) {
        // 歌词是可选内容，任何解码异常都不应影响播放
        return null;
      }
    }
    if (krcText == null || krcText.isEmpty) return null;
    return KrcParser.parse(krcText);
  }

  /// 为 KRC 歌词补齐翻译（逐行批量，按歌词ID+目标语言持久缓存）
  Future<KrcLyric> ensureTranslation(
    KrcLyric lyric,
    String lyricId,
    String targetLanguage,
  ) async {
    // 已含翻译（KRC 内嵌）则跳过
    final hasEmbedded = lyric.lines.any((l) => l.translation != null);
    if (hasEmbedded) return lyric;

    // 查缓存
    final cached =
        await LyricTranslationCache.instance.get(lyricId, targetLanguage);
    if (cached != null) {
      for (var i = 0; i < lyric.lines.length; i++) {
        final translation = cached[i];
        if (translation != null && translation.isNotEmpty) {
          lyric.lines[i].translation = translation;
        }
      }
      return lyric;
    }

    // 批量翻译（40 行一批）
    final texts = lyric.lines.map((l) => l.text).toList();
    // 只缓存**成功翻译**的行；失败批次不入缓存，下次还能重试
    final translations = <int, String>{};
    final failed = <int>{};
    const batchSize = 40;
    for (var i = 0; i < texts.length; i += batchSize) {
      final batch = texts.sublist(
          i, i + batchSize > texts.length ? texts.length : i + batchSize);
      try {
        final translated = await _translate.translateLines(
            lines: batch, targetLanguage: targetLanguage);
        for (var j = 0; j < translated.length; j++) {
          translations[i + j] = translated[j];
        }
      } catch (_) {
        // 单批失败：保留原文供显示，但**不写入缓存**（否则永久无翻译）
        for (var j = 0; j < batch.length; j++) {
          failed.add(i + j);
        }
      }
    }

    for (var i = 0; i < lyric.lines.length; i++) {
      lyric.lines[i].translation = failed.contains(i)
          ? null
          : (translations[i] ?? lyric.lines[i].text);
    }

    // 持久缓存（仅成功部分）
    if (translations.isNotEmpty) {
      await LyricTranslationCache.instance
          .set(lyricId, targetLanguage, translations);
    }
    return lyric;
  }
}

class LyricCandidate {
  LyricCandidate({required this.id, required this.accessKey, this.duration});
  final String id;
  final String accessKey;
  final int? duration;
}
