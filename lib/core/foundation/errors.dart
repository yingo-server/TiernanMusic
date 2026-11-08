/// v5.0 M1 / v5.1 B1 修复：业务异常唯一定义（core/foundation，零依赖）。
library;

/// 全仓 20028 唯一常量；判定必须走 [ApiException.needsVerification]
/// 或 response_policy.requiresVerification，禁止再写字面量。
const int kVerificationRequired = 20028;

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

  /// 20028 时携带的验证事件 id（body.ssaCode / ssa_code 或响应头 ssa-code）
  final String? ssaCode;

  /// /get/verify/info 返回的 url，前缀决定验证码类型（KGCodeTX| / KGCodeGT| …）
  final String? verifyUrl;

  /// 原始错误响应体，便于上层判断 fail_process 等
  final Map<String, dynamic>? body;

  bool get needsVerification => errorCode == kVerificationRequired;

  @override
  String toString() => 'ApiException($errorCode): $message';
}
