/// v5.0 M4：响应策略（Bridge-N 的核心，REFACTOR_PLAN_V5 §5.2）。
///
/// 网络层（KgClient / KugouApiClient）只负责传输；**成功/失败/风控判定
/// 全部收敛于此**。此前 `_wrap` 散在 kg_direct_api_client，20028 判定
/// 又在 player_repository / friendly_error 各写一份，语义漂移的根源。
library;

import '../foundation/errors.dart';

const int kVerificationRequired = 20028;

/// 解析后的统一成功/异常语义。
class ApiOutcome {
  const ApiOutcome.ok(this.body) : failure = null;
  const ApiOutcome.fail(this.failure) : body = const {};

  final Map<String, dynamic> body;
  final ApiException? failure;
  bool get isOk => failure == null;
  bool get needsVerification => failure?.needsVerification ?? false;
}

/// 唯一成功判定入口（从 kg_direct_api_client._wrap 上移，行为逐分支保持）。
ApiOutcome evaluateResponse(
  Map<String, dynamic> body, {
  String? ssaCode,
}) {
  int codeOf(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);
  final status = body['status'];
  final errorCode = codeOf(body['error_code'] ?? body['errcode']);
  String msgOf() =>
      '${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}';

  ApiOutcome fail(int code) => ApiOutcome.fail(
        ApiException(code == 0 ? -1 : code, msgOf(),
            ssaCode: body['ssaCode'] as String? ?? ssaCode, body: body),
      );

  // mcomment：err_code 优先，与 status 无关（兼容字符串形态）。
  final errCode = body['err_code'];
  if (errCode != null && codeOf(errCode) != 0) return fail(codeOf(errCode));

  if (status == 1) {
    if (errorCode == 0 || _hasData(body)) return ApiOutcome.ok(body);
    return fail(errorCode);
  }
  // 歌词类：status=200 + errcode=200 是正常码。
  if (status == 200) return ApiOutcome.ok(body);
  if (status == 0 || status == 2 || errorCode != 0) return fail(errorCode);
  if (body.isEmpty) {
    return ApiOutcome.fail(ApiException(-1, '空响应体（可能被风控拦截）',
        ssaCode: ssaCode, body: body));
  }
  return ApiOutcome.ok(body);
}

bool _hasData(Map<String, dynamic> body) {
  final d = body['data'];
  if (d is Map) return d.isNotEmpty;
  if (d is List) return d.isNotEmpty;
  return body.keys.any((k) => k != 'status' && k != 'error_code' && k != 'errcode');
}

/// 全仓 20028 判定唯一出口。消费方不得再硬编码错误码。
bool requiresVerification(Object? e) =>
    e is ApiException && e.errorCode == kVerificationRequired;
