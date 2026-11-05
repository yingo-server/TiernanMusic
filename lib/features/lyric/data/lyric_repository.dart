import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/api/translate_api.dart';
import '../../../core/cache/cache_manager.dart';
import 'krc_decoder.dart';
import 'krc_parser.dart';

class LyricRepository {
  LyricRepository(this._api, this._translate);

  final KugouApiClient _api;
  final TranslateApi _translate;

  /// 歌词缓存 TTL。歌词内容与登录态无关、变化极慢，
  /// 90 秒的全局 TTL 会导致同一首歌每轮播放都重新走网络。
  static const Duration _lyricCacheTtl = Duration(minutes: 30);

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
    if (cached == null) {
      MemoryCache.instance.set(cacheKey, data, ttl: _lyricCacheTtl);
    }

    final candidates = data['candidates'];
    if (candidates is! List) return null;
    for (final raw in candidates) {
      // F4-26（审查②-B，P1）：外部数据禁止裸强转（第 13 条）。
      // `as Map<String, dynamic>` 在 Map<dynamic,dynamic> 上直接抛 TypeError，
      // 而直连层对 TypeError 明确 rethrow → 播放页歌词加载异常中断。
      if (raw is! Map) continue;
      final c = Map<String, dynamic>.from(raw);
      final id = c['id'];
      final accessKey = c['accesskey'] ?? c['accessKey'];
      // F4-27（审查②-B，P1）：字段缺失时旧实现字符串化成 "null"，
      // 进而发出 `id=null&accesskey=null` 的非法请求，这首歌永远没有歌词。
      // 这里跳过残缺候选，继续试下一个（第 14 条：边界校验）。
      if (id == null || accessKey == null) continue;
      final idStr = '$id'.trim();
      final keyStr = '$accessKey'.trim();
      if (idStr.isEmpty || idStr == 'null' || keyStr.isEmpty || keyStr == 'null') {
        continue;
      }
      final duration = c['duration'];
      return LyricCandidate(
        id: idStr,
        accessKey: keyStr,
        duration: duration is int ? duration : int.tryParse('$duration'),
      );
    }
    return null;
  }

  /// 获取并解析 KRC 歌词（客户端解密或服务端 decode=true）
  Future<KrcLyric?> fetchLyric(
    LyricCandidate candidate, {
    String format = 'krc',
  }) async {
    if (format != 'krc' && format != 'lrc') {
      throw ArgumentError.value(format, 'format', '仅支持 krc 或 lrc');
    }
    final lyric = await _fetchLyricByFormat(candidate, format);
    if (lyric != null) return lyric;

    // F4-28（审查②-B，P2）：KRC 解不出时改取同 id/accesskey 的 LRC。
    // 老歌、版权方只给 LRC、字段变更的场景下本可出词，旧实现直接判「暂无歌词」。
    if (format == 'krc') {
      final fallback = await _fetchLyricByFormat(candidate, 'lrc');
      if (fallback != null) {
        debugPrint('[lyric] KRC 解析失败，已降级 LRC：${candidate.id}');
        return fallback;
      }
    }
    return null;
  }

  Future<KrcLyric?> _fetchLyricByFormat(
    LyricCandidate candidate,
    String format,
  ) async {
    final query = {
      'id': candidate.id,
      'accesskey': candidate.accessKey,
      'fmt': format,
      'decode': 'true',
    };
    final cacheKey = MemoryCache.keyOf('/lyric', query);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/lyric', query: query);
    if (cached == null) {
      MemoryCache.instance.set(cacheKey, data, ttl: _lyricCacheTtl);
    }

    // 优先用服务端 decodeContent；LRC 的 content 是明文 Base64，KRC 则加密。
    String? krcText;
    final decoded = data['decodeContent'];
    if (decoded is String && decoded.isNotEmpty) {
      krcText = decoded;
    } else if (data['content'] is String) {
      final raw = data['content'] as String;
      if (format == 'lrc') {
        try {
          krcText = utf8.decode(
              base64.decode(base64.normalize(raw.trim())),
              allowMalformed: true);
        } catch (_) {
          // 歌词是可选内容，任何解码异常都不应影响播放
          return null;
        }
      } else {
        // F4-24：区分「密文损坏」与「本来就无内容」，损坏时返回 null
        // 让上层降级 LRC（第 9 条：失败留痕，不静默）。
        final result = KrcDecoder.decodeDetailed(raw);
        if (result.error != null) {
          debugPrint('[lyric] KRC 解密失败(${result.error}) id=${candidate.id}');
        }
        krcText = result.text;
      }
    }
    if (krcText == null || krcText.isEmpty) return null;
    final parsed = KrcParser.parse(krcText);
    // F4-29（审查②-B，P2）：解析出空行等同于失败，不能把空壳当成功缓存给 UI。
    return parsed.lines.isEmpty ? null : parsed;
  }

  /// 为 KRC 歌词补齐翻译（逐行批量，按歌词ID+目标语言持久缓存）
  Future<KrcLyric> ensureTranslation(
    KrcLyric lyric,
    String lyricId,
    String targetLanguage,
  ) async {
    if (lyric.lines.isEmpty) return lyric;

    // F4-30（审查②-B，P2）：旧实现只要「任意一行」带内嵌翻译就整体跳过，
    // 结果是零星几句译文 + 大量原文的半成品。改为逐行判断：
    // 缺译的行继续走翻译，已有内嵌译文的行不重复翻译。
    final missing = <int>[
      for (var i = 0; i < lyric.lines.length; i++)
        if ((lyric.lines[i].translation ?? '').isEmpty) i,
    ];
    if (missing.isEmpty) return lyric;

    // F4-31（审查②-B，P2）：缓存键必须覆盖「歌词版本」（第 23 条）。
    // 只按 lyricId 缓存会在官方改词/行数变化后错行，且永不自愈。
    final versionKey = _lyricVersionKey(lyric);
    final cached = await LyricTranslationCache.instance
        .get(lyricId, '$targetLanguage@$versionKey');
    if (cached != null) {
      for (final i in missing) {
        final translation = cached[i];
        if (translation != null && translation.isNotEmpty) {
          lyric.lines[i].translation = translation;
        }
      }
      return lyric;
    }

    // 批量翻译（40 行一批）
    final texts = [for (final i in missing) lyric.lines[i].text];
    // 只缓存**成功翻译**的行；失败批次不入缓存，下次还能重试
    final translations = <int, String>{};
    const batchSize = 40;
    for (var i = 0; i < texts.length; i += batchSize) {
      final batch = texts.sublist(
          i, i + batchSize > texts.length ? texts.length : i + batchSize);
      try {
        final translated = await _translate.translateLines(
            lines: batch, targetLanguage: targetLanguage);
        // F4-32（审查②-B，P1）：返回条数少于请求条数时旧实现用原文补位，
        // 译文区出现与原文一模一样的整行，且被当成「已翻译」写进持久缓存，
        // 之后即使服务恢复也不再重试。这里只接受真实返回的条目。
        final n = translated.length < batch.length ? translated.length : batch.length;
        for (var j = 0; j < n; j++) {
          final value = translated[j];
          if (value.isEmpty) continue;
          translations[missing[i + j]] = value;
        }
      } catch (e) {
        // 单批失败：保留原文供显示，但**不写入缓存**（否则永久无翻译）；
        // 失败必须留痕（第 9 条）
        debugPrint('[lyric] 翻译批次失败（$i..${i + batch.length - 1}）：$e');
      }
    }

    translations.forEach((index, text) {
      if (index < lyric.lines.length && text.isNotEmpty) {
        lyric.lines[index].translation = text;
      }
    });

    // 持久缓存（仅成功部分）
    if (translations.isNotEmpty) {
      // F4-31：版本号并入缓存键，歌词变版后旧译文不再命中
      await LyricTranslationCache.instance
          .set(lyricId, '$targetLanguage@$versionKey', translations);
    }
    return lyric;
  }

  /// 歌词版本标识：行数 + 全部文本的短哈希。
  ///
  /// 只用于缓存键（第 23 条），不参与显示；行数与内容同时纳入即可覆盖
  /// 「官方改词」「KRC 版本变化」两类变化。
  static String _lyricVersionKey(KrcLyric lyric) {
    var hash = 17;
    for (final line in lyric.lines) {
      for (final code in line.text.codeUnits) {
        hash = (hash * 31 + code) & 0x7fffffff;
      }
    }
    return '${lyric.lines.length}-$hash';
  }
}

class LyricCandidate {
  LyricCandidate({required this.id, required this.accessKey, this.duration});
  final String id;
  final String accessKey;
  final int? duration;
}
