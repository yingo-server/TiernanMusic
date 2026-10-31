import 'package:dio/dio.dart';

import '../config/app_config.dart';

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

  /// 批量翻译歌词行。保留换行，返回逐行译文。
  Future<List<String>> translateLines({
    required List<String> lines,
    required String targetLanguage,
  }) async {
    if (lines.isEmpty) return [];
    final joined = lines.join('\n');
    final prompt =
        '请将以下文本翻译为$targetLanguage，直接输出翻译结果，不要进行任何解释。保持行数和换行不变。\n\n$joined';

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

    final content = res.data?['choices']?[0]?['message']?['content'] as String?;
    if (content == null) return lines;
    final translated = content.split('\n');
    // 对齐行数，不足补原文
    return List.generate(
      lines.length,
      (i) => i < translated.length ? translated[i].trim() : lines[i],
    );
  }

  /// 翻译单条文本（用于 i18n 脚本）
  Future<String> translateText({
    required String text,
    required String targetLanguage,
  }) async {
    final lines = await translateLines(
        lines: [text], targetLanguage: targetLanguage);
    return lines.first;
  }
}
