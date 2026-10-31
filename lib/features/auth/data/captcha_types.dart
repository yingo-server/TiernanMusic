/// 酷狗人机验证类型定义
///
/// 依据 KuGouMusicApi issue #206：
/// - `/get/verify/info` 返回 `url`，其前缀决定验证码类型
/// - `verifycode` 格式随类型变化
library;

/// 验证码类型
enum CaptchaType {
  /// 极验 GT
  geetest('KGCodeGT', '极验验证'),

  /// 腾讯 TCaptcha
  tencent('KGCodeTX', '腾讯验证码'),

  /// 酷狗自研
  kugou('KGCodeKG', '酷狗验证'),

  /// 酷狗旋转
  kugouRotate('KGCodeKG2', '酷狗旋转验证'),

  /// 数美
  shumei('KGCodeSM', '数美验证'),

  /// 网易易盾
  yidun('KGCodeYD', '易盾验证'),

  /// 手机短信验证码
  sms('', '手机验证码'),

  /// 活体认证（v_type=22）
  liveness('', '活体认证'),

  /// 人脸核身（v_type=34）
  face('', '人脸核身'),

  /// 未知类型
  unknown('', '未知验证');

  const CaptchaType(this.codePrefix, this.label);

  /// verifycode 的前缀，如 `KGCodeTX`
  final String codePrefix;

  /// 展示名称
  final String label;

  /// 是否可通过 App 内 WebView 完成
  bool get supportedInApp => this == tencent || this == sms;

  /// 从 `/get/verify/info` 的 url 前缀识别类型
  static CaptchaType fromVerifyUrl(String? url) {
    if (url == null || url.isEmpty) return CaptchaType.unknown;
    for (final t in CaptchaType.values) {
      if (t.codePrefix.isNotEmpty && url.startsWith(t.codePrefix)) return t;
    }
    return CaptchaType.unknown;
  }

  /// 从 v_type 推断（url 缺失时兜底）
  ///
  /// 23 滑块验证（腾讯为主）、32 手机验证码、22 活体、34 人脸
  static CaptchaType fromVType(int? vType) {
    return switch (vType) {
      23 => CaptchaType.tencent,
      32 => CaptchaType.sms,
      22 => CaptchaType.liveness,
      34 => CaptchaType.face,
      _ => CaptchaType.unknown,
    };
  }
}

/// 验证会话信息（来自 /get/verify/info）
class VerifySession {
  const VerifySession({
    required this.eventId,
    required this.vType,
    this.type = CaptchaType.unknown,
    this.typeList = const [],
    this.sessionId,
    this.business,
    this.verifyUrl,
  });

  /// 即 ssaCode
  final String eventId;
  final int vType;
  final CaptchaType type;
  final List<int> typeList;
  final String? sessionId;
  final int? business;

  /// 原始 url 字段（酷狗用它标识验证码类型）
  final String? verifyUrl;

  factory VerifySession.fromJson(String eventId, Map<String, dynamic> json) {
    final data = (json['data'] as Map<String, dynamic>?) ?? json;
    final url = data['url']?.toString();
    final vTypeRaw = data['v_type'];
    final vType = vTypeRaw is int
        ? vTypeRaw
        : int.tryParse('${vTypeRaw ?? ''}') ?? -1;
    var type = CaptchaType.fromVerifyUrl(url);
    if (type == CaptchaType.unknown) {
      type = CaptchaType.fromVType(vType);
    }
    final typeListRaw = data['v_type_list'];
    final typeList = typeListRaw is List
        ? typeListRaw
            .map((e) => e is int ? e : int.tryParse('$e') ?? -1)
            .where((e) => e >= 0)
            .toList()
        : <int>[];
    return VerifySession(
      eventId: eventId,
      vType: vType,
      type: type,
      typeList: typeList,
      sessionId: data['sessionid']?.toString(),
      business: data['business'] is int
          ? data['business'] as int
          : int.tryParse('${data['business'] ?? ''}'),
      verifyUrl: url,
    );
  }
}

/// 构造函数化 verifycode
class VerifyCode {
  VerifyCode._();

  /// 腾讯：KGCodeTX|{"ticket":"..","randstr":"..","txappid":".."}
  static String tencent({
    required String ticket,
    required String randstr,
    required String txappid,
  }) =>
      'KGCodeTX|{"ticket":"$ticket","randstr":"$randstr","txappid":"$txappid"}';

  /// 极验：KGCodeGT|{"geetest_challenge":"..","geetest_validate":"..","geetest_seccode":".."}
  static String geetest({
    required String challenge,
    required String validate,
    required String seccode,
  }) =>
      'KGCodeGT|{"geetest_challenge":"$challenge","geetest_validate":"$validate","geetest_seccode":"$seccode"}';

  /// 酷狗自研 / 旋转：KGCodeKG|{"orderno":".."} / KGCodeKG2|{"orderno":".."}
  static String orderno({required String prefix, required String orderNo}) =>
      '$prefix|{"orderno":"$orderNo"}';

  /// 数美 / 易盾：KGCodeSM|{"ticket":".."} / KGCodeYD|{"ticket":".."}
  static String ticket({required String prefix, required String ticket}) =>
      '$prefix|{"ticket":"$ticket"}';
}
