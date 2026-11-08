import 'package:dio/dio.dart';
import '../../../core/foundation/errors.dart' show ApiException;

import '../../../core/api/kugou_api_client.dart';
import '../../../core/direct/kg_client.dart';
import '../../../core/storage/secure_storage.dart';
import 'captcha_types.dart';
import '../../../core/direct/edt_generator.dart';

/// 人机验证服务
///
/// 依据 KuGouMusicApi issue #206 的流程：
/// 1. 业务请求返回 20028 + ssaCode
/// 2. `/get/verify/info?eventid=<ssaCode>` → 拿 v_type 与 url（判断验证码类型）
/// 3. 按类型产出 verifycode，连同 eventid/v_type/sid/edt 提交 `/verify/user/info`
/// 4. 成功后**重试原请求**
class VerificationService {
  VerificationService(this._api, [KgClient? client]) : _directClient = client;

  final KugouApiClient _api;

  /// 直连客户端（mid 权威来源：KgDevice 由 guid 计算）
  final KgClient? _directClient;

  /// 获取验证类型信息
  Future<VerifySession> getVerifyInfo(String ssaCode) async {
    final data = await _api.get('/get/verify/info', query: {'eventid': ssaCode});
    return VerifySession.fromJson(ssaCode, data);
  }

  /// 生成 sid / edt（行为指纹）
  ///
  /// mid/userid/dfid 都取当前设备与登录态，缺失时降级为 "0"
  Future<EdtResult> buildSidEdt() async {
    final dfid = await SecureStorage.instance.readDfid() ?? '0';
    return EdtGenerator.generate(
      // mid 权威来源是直连层 KgDevice（由 guid 计算），KugouApiClient 不再持有
      mid: (_directClient?.device.mid.isNotEmpty ?? false)
          ? _directClient!.device.mid
          : '0',
      userid: _api.userid.isNotEmpty ? _api.userid : '0',
      dfid: dfid,
      webglHash: _api.webglHash,
    );
  }

  /// 提交验证，成功返回 true
  Future<bool> submit({
    required VerifySession session,
    String? verifycode,
  }) async {
    final edt = await buildSidEdt();
    final vType = session.vType > 0 ? session.vType : 23;

    final query = <String, dynamic>{
      'eventid': session.eventId,
      'v_type': vType,
      'platid': 2,
      'wasm': 1,
      'sid': edt.sid,
      'edt': edt.edt,
      if (verifycode != null) 'verifycode': verifycode,
      // v_type=32 手机验证码走 code 字段
      if (vType == 32 && verifycode != null) 'code': verifycode,
    };

    try {
      // P1-6（审查①）/ V3-05（复查）：Node verify_user_info.js:40-48 是 POST。
      // 直连层 `case 'verify/user/info'` 只把 **body** 传给端点实现，
      // query 会被丢弃——此前参数全放 query 导致直连分支拿到空 eventid。
      // 修复：参数同时放 body（端点读 body）与 query（kapi 回退读 query）。
      final data = await _api.post(
        '/verify/user/info',
        query,
        query: query,
      );
      final status = data['status'];
      final ok = status == 1 ||
          status == '1' ||
          (data['data'] is Map &&
              '${(data['data'] as Map)['codeDesc']}'.toLowerCase() ==
                  'success');
      return ok;
    } on DioException catch (e) {
      // 验证接口自身失败（如 20010 参数缺失）视为未通过
      if (e.error is ApiException) return false;
      rethrow;
    }
  }

  /// 需要验证的事件
  VerifySession sessionFromException(ApiException e) {
    return VerifySession(
      eventId: e.ssaCode ?? '',
      vType: -1,
    );
  }
}
