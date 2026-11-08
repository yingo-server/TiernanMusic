import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../app/di.dart';
import 'captcha_page.dart';

/// 统一处理「20028 需要人机验证」
///
/// 用法：把可能触发验证的操作包起来
/// ```dart
/// final ok = await runWithVerification(context, ref, () => play());
/// ```
///
/// 行为：捕获 ApiException(20028) → 打开验证页 → 验证通过后自动重试原操作，
/// 最多重试 [maxRetries] 次（每次验证都会刷新 ssaCode）。
Future<T?> runWithVerification<T>(
  BuildContext context,
  WidgetRef ref,
  Future<T> Function() action, {
  int maxRetries = 2,
}) async {
  var attempt = 0;
  while (true) {
    try {
      return await action();
    } on DioException catch (e) {
      final api = e.error is ApiException ? e.error as ApiException : null;
      if (api == null || !api.needsVerification) rethrow;
      final ssaCode = api.ssaCode;
      if (ssaCode == null || ssaCode.isEmpty) {
        _toast(context, '需要人机验证，但未获取到验证事件，请稍后重试');
        return null;
      }
      if (attempt >= maxRetries) {
        _toast(context, '验证多次未通过，请稍后再试');
        return null;
      }
      attempt++;

      if (!context.mounted) return null;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CaptchaPage(
            ssaCode: ssaCode,
            api: ref.read(kugouApiClientProvider),
          ),
        ),
      );
      if (ok != true) return null;
      // 验证通过，循环重试原操作
    }
  }
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));
}
