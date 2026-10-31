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
  Future<KrcLyric?> fetchLyric(LyricCandidate candidate) async {
    final query = {
      'id': candidate.id,
      'accesskey': candidate.accessKey,
      'fmt': 'krc',
      'decode': 'true',
    };
    final cacheKey = MemoryCache.keyOf('/lyric', query);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/lyric', query: query);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);

    // 优先用服务端 decodeContent，否则客户端解密 content
    String? krcText;
    if (data['decodeContent'] != null && (data['decodeContent'] as String).isNotEmpty) {
      krcText = data['decodeContent'] as String;
    } else if (data['content'] != null && data['contenttype'] == 0) {
      try {
        krcText = KrcDecoder.decode(data['content'] as String);
      } catch (_) {
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
        lyric.lines[i].translation = cached[i];
      }
      return lyric;
    }

    // 批量翻译（40 行一批）
    final texts = lyric.lines.map((l) => l.text).toList();
    final translations = <int, String>{};
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
        // 单批失败保留原文
        for (var j = 0; j < batch.length; j++) {
          translations[i + j] = batch[j];
        }
      }
    }

    for (var i = 0; i < lyric.lines.length; i++) {
      lyric.lines[i].translation = translations[i];
    }

    // 持久缓存
    await LyricTranslationCache.instance
        .set(lyricId, targetLanguage, translations);
    return lyric;
  }
}

class LyricCandidate {
  LyricCandidate({required this.id, required this.accessKey, this.duration});
  final String id;
  final String accessKey;
  final int? duration;
}
