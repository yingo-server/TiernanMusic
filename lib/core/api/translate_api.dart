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

    // V33-03（修复①，第 13 条）：choices 可能为 null 或空列表（模型限流/
    // 上游返回 `{"choices":[]}`），`choices[0]` 取不到内容 → 空翻译。
    // 已用 `?.[0]` 避免 RangeError，这里再显式判定空列表，直接退回原文，
    // 不把空串当译文塞回界面。
    final choices = res.data?['choices'];
    if (choices is! List || choices.isEmpty) return lines;
    // V35-A2-1（第 A 批，P2）：`choices[0]` 可能是非 Map（上游返回
    // `[null]` / `["str"]` 等畸形形态），`?[0]?['message']` 对非 Map
    // 会抛 NoSuchMethodError（`?.` 不保护「取下标成功但成员不存在」
    // 之外的动态分发）。显式验证类型，畸形即退回原文（第 13 条）。
    final first = choices[0];
    final content =
        (first is Map ? first['message'] : null)?['content'] as String?;
    if (content == null || content.trim().isEmpty) return lines;
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
