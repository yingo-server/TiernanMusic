/// 酷狗请求签名与加密核心（逐行移植自 KuGouMusicApi util/helper.js + util/crypto.js）
///
/// 对照表：
///   signatureAndroidParams → KgSignature.android
///   signatureWebParams     → KgSignature.web
///   signatureRegisterParams→ KgSignature.register
///   signKey                → KgSignature.keyOf
///   signParamsKey          → KgSignature.paramsKey
///   cryptoMd5              → KgCrypto.md5
///   rsaEncrypt2            → KgCrypto.rsaEncryptPkcs1
///   cryptoAesEncrypt       → KgCrypto.aesEncryptHex
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 平台常量（对应 util/config.json）
class KgConfig {
  KgConfig._();

  static const int appid = 1005;
  static const int clientver = 20489;
  static const int liteAppid = 3116;
  static const int liteClientver = 11440;

  /// Android 签名盐值（标准版）
  static const String androidSalt = 'OIlwieks28dk2k092lksi2UIkp';

  /// Android 签名盐值（概念版 lite）
  static const String androidSaltLite = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  /// Web 签名盐值
  static const String webSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  /// signKey 盐值（标准版）
  static const String signKeySalt = '57ae12eb6890223e355ccfcb74edf70d';

  /// signKey 盐值（lite）
  static const String signKeySaltLite = '185672dd44712f60bb1736df5a377e82';

  /// 网关
  static const String gateway = 'https://gateway.kugou.com';
  static const String registerGateway = 'https://userservice.kugou.com';
}

/// 请求签名算法
class KgSignature {
  KgSignature._();

  /// Android 版签名（默认）
  ///
  /// md5(salt + 排序后的 key=value 串 + data + salt)
  static String android(
    Map<String, dynamic> params, {
    String data = '',
    bool lite = false,
  }) {
    final salt = lite ? KgConfig.androidSaltLite : KgConfig.androidSalt;
    final keys = params.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      final v = params[k];
      sb.write('$k=${v is Map || v is List ? jsonEncode(v) : v}');
    }
    return KgCrypto.md5('$salt${sb.toString()}$data$salt');
  }

  /// Web 版签名
  static String web(Map<String, dynamic> params, {String data = ''}) {
    const salt = KgConfig.webSalt;
    final keys = params.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      sb.write('$k=${params[k]}');
    }
    return KgCrypto.md5('$salt${sb.toString()}$data$salt');
  }

  /// 设备注册签名：md5("1014" + 排序后的值串 + "1014")
  static String register(Map<String, dynamic> params) {
    final values = params.values.map((v) => '$v').toList()..sort();
    return KgCrypto.md5('1014${values.join()}1014');
  }

  /// signKey：md5(hash + salt + appid + mid + userid)
  static String keyOf({
    required String hash,
    required String mid,
    Object userid = 0,
    Object? appid,
    bool lite = false,
  }) {
    final salt = lite ? KgConfig.signKeySaltLite : KgConfig.signKeySalt;
    final useAppid = appid ?? (lite ? KgConfig.liteAppid : KgConfig.appid);
    return KgCrypto.md5('$hash$salt$useAppid$mid$userid');
  }

  /// signParamsKey：md5(appid + salt + clientver + data)
  static String paramsKey(
    Object data, {
    Object? appid,
    Object? clientver,
    bool lite = false,
  }) {
    final salt = lite ? KgConfig.androidSaltLite : KgConfig.androidSalt;
    final useAppid = appid ?? (lite ? KgConfig.liteAppid : KgConfig.appid);
    final useClientver =
        clientver ?? (lite ? KgConfig.liteClientver : KgConfig.clientver);
    return KgCrypto.md5('$useAppid$salt$useClientver$data');
  }
}

/// 加密工具
class KgCrypto {
  KgCrypto._();

  static final _rand = math.Random.secure();

  /// 标准版 RSA 公钥（RSAES-PKCS1-V1_5，1024 位）
  static const _publicKeyPem = '''
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/g
bjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+U
R4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5
E221wf/4WLFxwAtRQIDAQAB''';

  /// lite（概念版）RSA 公钥
  static const _publicKeyPemLite = '''
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO0
1rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTX
LgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ0
8/q6ifSioBszvb3QiwIDAQAB''';

  /// MD5 十六进制小写
  static String md5(String input) => _md5Bytes(utf8.encode(input));

  static String _md5Bytes(List<int> bytes) =>
      md5.convert(bytes).toString();

  /// RSA-PKCS1 加密，输出十六进制大写（对应 rsaEncrypt2）
  static String rsaEncryptPkcs1(String data, {bool lite = false}) {
    final der = base64.decode(
      (lite ? _publicKeyPemLite : _publicKeyPem).replaceAll(RegExp(r'\s'), ''),
    );
    final asn1 = ASN1Parser(der);
    final publicKey = PublicKey(asn1.nextObject() as ASN1Sequence);

    final cipher = PKCS1Encoding(RSAEngine())
      ..init(
        true,
        PublicKeyParameter<RSAPublicKey>(publicKey as RSAPublicKey),
      );
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(data)));
    return encrypted
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }

  /// AES-128-CBC + PKCS7，返回 hex（对应 cryptoAesEncrypt 的 str）
  ///
  /// 若未提供 key，则临时生成 key（小写随机16字符）并返回 {str, key}
  static AesResult aesEncryptHex(String data, {String? key, String? iv}) {
    var tempKey = key;
    String useKey;
    String useIv;
    if (key != null && iv != null) {
      useKey = key;
      useIv = iv;
    } else {
      tempKey ??= randomString(16).toLowerCase();
      final md5Key = md5(tempKey);
      useKey = md5Key.substring(0, 32);
      useIv = useKey.substring(useKey.length - 16);
    }

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(useKey))),
            Uint8List.fromList(utf8.encode(useIv)),
          ),
          null,
        ),
      );
    final out = cipher.process(Uint8List.fromList(utf8.encode(data)));
    final hex = out
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return AesResult(str: hex, key: tempKey);
  }

  /// randomString：字符表 1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
  static String randomString(int len) {
    const chars = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      final idx = ((chars.length - 1) * _rand.nextDouble()).ceil();
      sb.write(chars[idx.clamp(0, chars.length - 1)]);
    }
    return sb.toString();
  }

  /// 生成 uuidv4
  static String uuidV4() {
    final b = List<int>.generate(16, (_) => _rand.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}

class AesResult {
  const AesResult({required this.str, required this.key});
  final String str;
  final String key;
}
