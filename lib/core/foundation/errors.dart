/// 业务/API 异常（v5.0 M1：上移至 core/foundation，原位置 re-export 兼容）。
///
/// 全仓错误翻译唯一出口（REFACTOR_PLAN §5.2）：20028 判定收敛在
/// [needsVerification]，其他层不得重复硬编码错误码。
class ApiException implements Exception {
  ApiException(
    this.errorCode,
    this.message, {
    this.ssaCode,
    this.verifyUrl,
    this.body,
  });

  final int errorCode;
  final String message;

  /// 20028 时携带的验证事件 id（body.ssaCode 或响应头 ssa-code）
  final String? ssaCode;

  /// /get/verify/info 返回的 url，前缀决定验证码类型（KGCodeTX| / KGCodeGT| …）
  final String? verifyUrl;

  /// 原始错误响应体，便于上层判断 fail_process 等
  final Map<String, dynamic>? body;

  bool get needsVerification => errorCode == 20028; // 唯一常量见 response_policy.dart

  @override
  String toString() => 'ApiException($errorCode): $message';
}
