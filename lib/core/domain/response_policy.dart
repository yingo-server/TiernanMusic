/// v5.0 M4 / v5.1 B1 修复：响应策略（Bridge-N 核心，REFACTOR_PLAN_V5 §5.2）。
///
/// 网络层只负责传输；**成功/失败/风控判定全部收敛于此**。
/// v5.1 B1 三视角交叉共识修复：
/// - status / 错误码统一形态归一（字符串、double、带空白都正确处理）
/// - 不可解析的错误码判失败而非静默成功（第 13/14 条）
/// - 警告码白名单显式化：151/152/200/201 + 有数据 = 实测成功语义，
///   但 20028 等真实错误码不再被 `_hasData` 放行
/// - `ssaCode` 安全取值，不再裸强转绕过异常契约
/// - 20028 判定唯一出口复用 [ApiException.needsVerification]
library;

import '../foundation/errors.dart';

/// 解析后的统一成功/异常语义。
class ApiOutcome {
  const ApiOutcome.ok(this.body) : failure = null;
  const ApiOutcome.fail(this.failure) : body = const {};

  final Map<String, dynamic> body;
  final ApiException? failure;
  bool get isOk => failure == null;
  bool get needsVerification => failure?.needsVerification ?? false;
}

/// 数值归一：int/num/纯整数字符串（含首尾空白）→ 值；
/// **不可解析返回 null**（与「0 = 无错误」严格区分，第 14 条）。
int? _codeOf(Object? v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is bool) return null; // true/false 不是错误码
  if (v is Map || v is List) return null;
  final s = '$v'.trim();
  if (s.isEmpty) return 0;
  return int.tryParse(s);
}

/// 安全取 ssaCode：响应体 camelCase / snake_case + 外部传入响应头值。
String? _ssaOf(Map<String, dynamic> body, String? headerCode) {
  for (final k in const <String>['ssaCode', 'ssa_code', 'ssaCodeStr']) {
    final v = body[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return v.toString(); // 数值型事件 id 也不得崩
  }
  return headerCode;
}

/// 实测成功语义的警告码（PLY-10/11、F4-xx 多轮复核）：
/// 上游「有结果但需提示」的码；**不是**放行任意非零错误码。
const _warningCodes = <int>{0, 151, 152, 200, 201};

ApiOutcome evaluateResponse(
  Map<String, dynamic> body, {
  String? ssaCode,
}) {
  String msgOf() =>
      '${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}';
  final ssa = _ssaOf(body, ssaCode);

  ApiOutcome fail(int? code, {String? overrideMessage}) => ApiOutcome.fail(
        ApiException(code ?? -1, overrideMessage ?? msgOf(),
            ssaCode: ssa, body: body),
      );

  // 1) mcomment：err_code 与 status 无关，且兼容字符串；不可解析=失败。
  if (body.containsKey('err_code')) {
    final c = _codeOf(body['err_code']);
    if (c == null) return fail(-1, overrideMessage: '评论服务返回不可解析的错误码');
    if (c != 0) return fail(c);
  }

  // `status` 缺失（裸 Map 响应）必须用 hasStatus 区分，不能把 null 归一成 0
  // 再走失败分支（v5.1 B2-A 抓到的回归：comment/count 恒失败）。
  final hasStatus = body.containsKey('status') && body['status'] != null;
  final status = _codeOf(body['status']) ?? -1;
  final ec = _codeOf(body['error_code'] ?? body['errcode']);
  // error_code/errcode 存在但不可解析 → 视为失败（不静默当 0）。
  if (ec == null) return fail(-1, overrideMessage: '响应错误码不可解析');

  // 2) 风控码优先：任何 status 下 20028 都必须失败并带 ssaCode。
  if (ec == kVerificationRequired) return fail(ec);

  // 3) status == 1：无错误码成功；警告码且**确实有数据**才成功；
  //    其余非零错误码一律失败（不再被「存在任意其它键」放行）。
  if (hasStatus && status == 1) {
    if (ec == 0) return ApiOutcome.ok(body);
    if (_warningCodes.contains(ec) && _hasData(body)) {
      return ApiOutcome.ok(body);
    }
    return fail(ec);
  }

  // 4) 歌词类：status == 200 + errcode 200 是正常码；其它非零码失败。
  if (hasStatus && status == 200) {
    if (_warningCodes.contains(ec)) return ApiOutcome.ok(body);
    return fail(ec);
  }

  // 5) **有明确 status** 时的失败状态；缺失 status 的裸 Map 走第 6/7 步。
  if (hasStatus && (status == 0 || status == 2)) return fail(ec);
  if (ec != 0) return fail(ec);

  // 6) 无 status 且空响应体 = 风控/网关空包，不得当成功。
  if (body.isEmpty) {
    return ApiOutcome.fail(ApiException(-1, '空响应体（可能被风控拦截）',
        ssaCode: ssa, body: body));
  }
  // 7) 无 status 但带数据：裸 Map 成功响应（comment/count 等，实测口径）。
  return ApiOutcome.ok(body);
}

bool _hasData(Map<String, dynamic> body) {
  final d = body['data'];
  if (d is Map) return d.isNotEmpty;
  if (d is List) return d.isNotEmpty;
  // 排除所有错误/提示类键，避免「错误消息也算数据」。
  const meta = <String>{
    'status', 'error_code', 'errcode', 'err_code', 'error', 'error_msg',
    'errmsg', 'info', 'ssaCode', 'ssa_code',
  };
  return body.keys.any((k) => !meta.contains(k));
}

/// 从任意异常形态取 ApiException（不依赖 dio，foundation 层零依赖）：
/// 直连层抛裸 ApiException；Dio 拦截器抛 `DioException(error: ApiException)`。
ApiException? apiExceptionOf(Object? e) {
  if (e is ApiException) return e;
  try {
    final dynamic d = e;
    final inner = d.error;
    if (inner is ApiException) return inner;
  } catch (_) {
    // 非 DioException 形态没有 .error 成员，忽略（第 6 条：不吞真异常）。
  }
  return null;
}

/// 全仓 20028 判定唯一出口。兼容裸异常与 Dio 包装异常。
bool requiresVerification(Object? e) =>
    apiExceptionOf(e)?.needsVerification ?? false;
