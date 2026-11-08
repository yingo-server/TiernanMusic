import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// v5.1 B1：翻译失败统一降级为「原文」并可观测。
/// 返回码语义：ok=真译文，fallback=原文（超时/限流/畸形/行数不符），
/// 供上层决定是否重试与是否写缓存（第 6/9/16 条）。
class TranslateResult {
  const TranslateResult(this.lines, {required this.ok, this.reason});
  final List<String> lines;
  final bool ok;
  final String? reason;

  factory TranslateResult.fallback(List<String> original, String reason) =>
      TranslateResult(List<String>.unmodifiable(original),
          ok: false, reason: reason);
}

class TranslateApi {
  TranslateApi()
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
          headers: {
            'Content-Type': 'application/json',
            // B 站 WAF 拦截无 UA 请求（412）
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/126.0.0.0 Mobile Safari/537.36',
          },
        ));

  final Dio _dio;

  /// 批量翻译歌词行。任何失败都不抛：**显式返回原文降级**，
  /// 原文/译文可判定（ok=false 不写持久缓存、可重试）。
  Future<TranslateResult> translateLines({
    required List<String> lines,
    required String targetLanguage,
  }) async {
    if (lines.isEmpty) return const TranslateResult([], ok: true);
    final joined = lines.join('\n');
    final prompt =
        '请将以下文本翻译为$targetLanguage，直接输出翻译结果，不要进行任何解释。保持行数和换行不变。\n\n$joined';

    Map<String, dynamic>? body;
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        AppConfig.translateApiBase,
        data: {
          'model': AppConfig.translateModel,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0,
          'max_tokens': AppConfig.lyricTranslateMaxTokens,
          'chat_template_kwargs': {'enable_thinking': false},
        },
      );
      body = res.data;
    } catch (e) {
      final reason = 'translate request failed: $e';
      debugPrint('[translate] $reason — fallback to original');
      return TranslateResult.fallback(lines, reason);
    }

    final choices = body?['choices'];
    if (choices is! List || choices.isEmpty) {
      return TranslateResult.fallback(lines, 'empty choices');
    }
    final first = choices[0];
    if (first is! Map) {
      return TranslateResult.fallback(lines, 'malformed choice');
    }
    final message = first['message'];
    if (message is! Map) {
      return TranslateResult.fallback(lines, 'malformed message');
    }
    final content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      return TranslateResult.fallback(lines, 'empty content');
    }
    final translated = content.split('\n');
    // v5.1 B1：行数不符不再「不足补原文」制造混合结果——
    // 整批退回原文，避免用户看到半译半不译（第 3/16 条）。
    if (translated.length != lines.length) {
      debugPrint('[translate] line count ${translated.length} != '
          '${lines.length} — fallback to original');
      return TranslateResult.fallback(lines, 'line count mismatch');
    }
    final out = <String>[
      for (final line in translated) line.trim(),
    ];
    return TranslateResult(out, ok: true);
  }

  /// 兼容旧调用方：只要行列表（降级为原文）。
  Future<List<String>> translateLinesCompat({
    required List<String> lines,
    required String targetLanguage,
  }) =>
      translateLines(lines: lines, targetLanguage: targetLanguage)
          .then((r) => r.lines);

  /// 翻译单条文本（用于 i18n 脚本）；空文本明确返回空串。
  Future<String> translateText({
    required String text,
    required String targetLanguage,
  }) async {
    if (text.trim().isEmpty) return '';
    final r = await translateLines(
        lines: [text], targetLanguage: targetLanguage);
    return r.lines.isEmpty ? text : r.lines.first;
  }
}
