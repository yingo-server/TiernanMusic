import 'dart:convert';
import '../../../core/net/music_api.dart';

import 'package:flutter/foundation.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/api/translate_api.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/resource/cached_api.dart';
import '../../../core/resource/lyric_translation_stream.dart';
import 'krc_decoder.dart';
import 'krc_parser.dart';

class LyricRepository {
  LyricRepository(this._api, this._translate)
      : _cached = CachedApiCall(_api, ns: 'lyric');

  // ignore: unused_field — 恒等字段：构造契约保留 _api 引用（调用方可直查 userid 等状态）
  final KugouApiClient _api;
  final TranslateApi _translate;
  final CachedApiCall _cached;

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
    // V400-B-04：候选查询统一走 ResourceCache（30 分钟歌词语义 +
    // in-flight 合并 + 失效回退），替代 MemoryCache+LyricPersistentCache 双写。
    final data = await _cached.get('/search/lyric', query: query,
        ttl: _lyricCacheTtl);
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
    // V400-B-04：/lyric 同样统一走 ResourceCache（30 分钟 + 失效回退）。
    final data = await _cached.get('/lyric', query: query,
        ttl: _lyricCacheTtl);

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
      var hit = 0;
      for (final i in missing) {
        final translation = cached[i];
        if (translation != null && translation.isNotEmpty) {
          lyric.lines[i].translation = translation;
          hit++;
        }
      }
      // V400-B-03：命中缓存也 emit 一次（UI 秒显，不等 FutureProvider 完成）。
      if (hit > 0) {
        LyricTranslationStream.instance.emit(LyricTranslationPatch(
          lyricId,
          missing.first,
          [for (final i in missing) lyric.lines[i].translation ?? ''],
        ));
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
        List<String> translated;
        try {
          translated = await _translate.translateLines(
              lines: batch, targetLanguage: targetLanguage);
        } catch (e) {
          // V400-B-03：失败批重试一次（504 网关超时场景）；
          // 重试仍失败按单批失败处理（留痕不崩不入缓存）。
          debugPrint('[lyric] 翻译批次失败，重试一次：$e');
          translated = await _translate.translateLines(
              lines: batch, targetLanguage: targetLanguage);
        }
        // F4-32（审查②-B，P1）：返回条数少于请求条数时旧实现用原文补位，
        // 译文区出现与原文一模一样的整行，且被当成「已翻译」写进持久缓存，
        // 之后即使服务恢复也不再重试。这里只接受真实返回的条目。
        final n = translated.length < batch.length ? translated.length : batch.length;
        for (var j = 0; j < n; j++) {
          final value = translated[j];
          if (value.isEmpty) continue;
          // V34-03（v3.4 审查①，P1）：`missing` 是**行号**列表，`texts` 是
          // 按 missing 顺序构建的文本数组——批内偏移 j 对应的行号是
          // `missing[i + j]`（i 也是 missing 的下标偏移），原写法正确；
          // 但若上游 translateLines 改为「按段落合并返回」（返回条数
          // ≠ 请求条数），此处 n 截断后逐行假设就失效，译文整批错位。
          // 防御：返回条数与批不等时不落缓存（不确认语义前宁可丢）。
          if (translated.length != batch.length) {
            debugPrint('[lyric] 翻译返回条数 ${translated.length} != 请求 ${batch.length}，本批不入缓存');
            break;
          }
          translations[missing[i + j]] = value;
        }
        // V400-B-03：本批成功即 emit patch（UI 实时插行，不等整批翻译完）。
        if (translated.length == batch.length && n > 0) {
          LyricTranslationStream.instance.emit(LyricTranslationPatch(
            lyricId,
            missing[i],
            [for (var j = 0; j < n; j++) translated[j]],
          ));
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
