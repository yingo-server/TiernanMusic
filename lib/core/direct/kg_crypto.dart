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

import 'package:pointycastle/asn1.dart';
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
  ///
  /// 对齐 Node signatureWebParams（helper.js:40-46）：先把每个参数格式化成
  /// "k=v" 字符串，再整体 sort()。不能先 sort key 再拼——当某 key 是另一 key
  /// 的前缀且下个字符 ASCII < '='（如 'a' 与 'a-b'）时两种顺序不同（实测签名
  /// 不一致）。android 版不受影响：Node 就是先 sort key（helper.js:63-67）。
  static String web(Map<String, dynamic> params, {String data = ''}) {
    const salt = KgConfig.webSalt;
    final parts =
        params.keys.map((k) => '$k=${params[k]}').toList()..sort();
    return KgCrypto.md5('$salt${parts.join()}$data$salt');
  }

  /// 设备注册签名：md5("1014" + 排序后的值串 + "1014")
  ///
  /// currently unused：注册实际走 [android]（含 body），符合 register_dev.js
  /// 实测结论。保留时勿在新代码中误用为注册路径。
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

  static String _md5Bytes(List<int> bytes) {
    final digest = MD5Digest().process(Uint8List.fromList(bytes));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 解析 RSA 公钥，返回 (modulus, exponent)
  static (BigInt, BigInt) _rsaPublicKey(bool lite) {
    final der = base64.decode(
      (lite ? _publicKeyPemLite : _publicKeyPem).replaceAll(RegExp(r'\s'), ''),
    );
    final outer = ASN1Parser(der).nextObject() as ASN1Sequence;
    // SPKI: SEQUENCE { SEQUENCE{alg}, BIT STRING{key} }
    final keyBits = (outer.elements![1] as ASN1BitString).stringValues!;
    final keySeq =
        ASN1Parser(Uint8List.fromList(keyBits)).nextObject() as ASN1Sequence;
    final modulus = (keySeq.elements![0] as ASN1Integer).integer as BigInt;
    final exponent = (keySeq.elements![1] as ASN1Integer).integer as BigInt;
    return (modulus, exponent);
  }

  /// RSA-PKCS1 加密（对应 rsaEncrypt2）
  ///
  /// 十六进制大小写由 [uppercase] 控制，**默认小写**（对齐 Node 的
  /// `forge.util.bytesToHex`，后者输出小写）。设备注册接口的 `p` 参数
  /// 必须是小写 hex。
  ///
  /// 注意：登录用的 [rsaEncryptRawHex]（无 PKCS1 填充）是另一个函数，不要混用。
  static String rsaEncryptPkcs1(
    String data, {
    bool lite = false,
    bool uppercase = false,
  }) {
    final (modulus, exponent) = _rsaPublicKey(lite);
    final publicKey = RSAPublicKey(modulus, exponent);

    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(data)));
    final hex = encrypted
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return uppercase ? hex.toUpperCase() : hex;
  }

  /// 裸 RSA 加密（对应 Node 的 cryptoRSAEncrypt）。
  ///
  /// 与 [rsaEncryptPkcs1] 不同：**无 PKCS1 填充**，而是把明文放到
  /// keyLength 字节缓冲区**开头**、右侧补零后做 modPow（酷狗登录/用户信息
  /// 接口即用此方式），输出十六进制小写，调用方按需转大写。
  static String rsaEncryptRawHex(String data, {bool lite = false}) {
    final (modulus, exponent) = _rsaPublicKey(lite);
    final keyLength = (modulus.bitLength + 7) ~/ 8;
    final bytes = utf8.encode(data);
    if (bytes.length > keyLength) {
      throw ArgumentError('数据长度超过密钥长度');
    }
    // 右补零到 keyLength（与 Node: padded.set(buffer) 一致）
    final padded = Uint8List(keyLength)..setRange(0, bytes.length, bytes);
    var message = BigInt.zero;
    for (final b in padded) {
      message = (message << 8) | BigInt.from(b);
    }
    final cipher = message.modPow(exponent, modulus);
    return cipher.toRadixString(16).padLeft(keyLength * 2, '0');
  }

  /// AES-128-CBC + PKCS7，输出 Base64（对应 playlistAesEncrypt）
  ///
  /// seed 缺省时随机生成 6 位小写；派生：key=md5(seed)[:16], iv=md5(seed)[16:32]
  /// 注意与 Node cryptoAesEncrypt（hex 输出、32 位 key）不同——那是另一个函数。
  static AesResult aesEncryptHex(String data, {String? key, String? iv}) {
    var seed = key;
    String useKey;
    String useIv;
    if (key != null && iv != null) {
      useKey = key;
      useIv = iv;
    } else {
      seed ??= randomString(6).toLowerCase();
      final md5Key = md5(seed);
      useKey = md5Key.substring(0, 16);
      useIv = md5Key.substring(16, 32);
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
    return AesResult(str: base64.encode(out), key: seed ?? '');
  }

  /// 移植 Node 的 cryptoAesEncrypt（AES-CBC/PKCS7，**十六进制**输出）。
  ///
  /// 与 [aesEncryptHex] 不同：本函数 key 为 32 位 hex 字符串（AES-256），
  /// 输出 hex 而非 base64，用于登录/验证类接口。
  /// - 显式给出 key+iv：直接使用；
  /// - 仅给出 key：realKey=md5(key)[:32]，iv=realKey 末 16 位；
  /// - 均未给出：随机 16 位 key，按上派生（临时 key 供 RSA pk 使用）。
  static String aesEncryptCbcHex(String data, {String? key, String? iv}) {
    if (key != null && iv != null) {
      return _aesCbcHex(data, key, iv);
    }
    final tempKey = key ?? randomString(16).toLowerCase();
    final realKey = md5(tempKey); // md5 本身即 32 位
    final realIv = realKey.substring(realKey.length - 16);
    return _aesCbcHex(data, realKey, realIv);
  }

  /// 同 [aesEncryptCbcHex]，但随机临时 key 时一并返回（登录 pk 需要）。
  static AesHexResult aesEncryptCbcAuto(String data, {String? key}) {
    final tempKey = key ?? randomString(16).toLowerCase();
    final realKey = md5(tempKey);
    final realIv = realKey.substring(realKey.length - 16);
    return AesHexResult(str: _aesCbcHex(data, realKey, realIv), key: tempKey);
  }

  static String _aesCbcHex(String data, String keyStr, String ivStr) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(keyStr))),
            Uint8List.fromList(utf8.encode(ivStr)),
          ),
          null,
        ),
      );
    final out = cipher.process(Uint8List.fromList(utf8.encode(data)));
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 移植 Node 的 cryptoAesDecrypt（输入十六进制密文）。
  ///
  /// 未提供 iv 时以 md5(key)[:32] 作为真实 key、末 16 位作为 iv；
  /// 解密结果尝试 JSON 解析，失败则返回字符串。
  static dynamic aesDecryptCbcHex(String data, String key, {String? iv}) {
    final realKey = iv == null ? md5(key) : key;
    final realIv = iv ?? realKey.substring(realKey.length - 16);
    final cipherBytes = <int>[];
    for (var i = 0; i + 1 < data.length; i += 2) {
      cipherBytes.add(int.parse(data.substring(i, i + 2), radix: 16));
    }
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(realKey))),
            Uint8List.fromList(utf8.encode(realIv)),
          ),
          null,
        ),
      );
    final out = cipher.process(Uint8List.fromList(cipherBytes));
    final text = utf8.decode(out, allowMalformed: true);
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  /// 播放列表 AES 解密（对应 Node 的 playlistAesDecrypt）。
  ///
  /// key = md5(seed).substring(0, 16) —— **16 个 ASCII 字符**（AES-128 的
  /// 16 字节密钥），iv = md5(seed).substring(16, 32)（同样 16 个 ASCII 字符）。
  /// 注意：这里的 key/iv 是**字符串直接当字节**用，不是 hex 解析，
  /// 与 [aesEncryptCbcHex]（key 为 32 位 hex 字符串、AES-256）不同。
  ///
  /// [base64Str] 为 Base64 密文（Node 侧是 `Buffer.toString('base64')`），
  /// 解密后按 UTF-8 解码并尝试解析为 JSON Map；解析失败则抛出。
  static Map<String, dynamic> aesDecryptPlaylistB64(
    String base64Str,
    String seed,
  ) {
    final bytes = base64.decode(base64Str);
    final text = _aesDecryptPlaylistBytes(bytes, seed);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('播放列表 AES 解密结果不是 JSON 对象');
    }
    return decoded;
  }

  /// 与 [aesDecryptPlaylistB64] 相同，但直接吃**原始密文字节**。
  ///
  /// 设备注册接口的响应体是二进制（content-type: application/octet-stream），
  /// Node 侧是 `body.toString('base64')` 后再解密 —— 等价于直接解密原始字节。
  static String _aesDecryptPlaylistBytes(List<int> bytes, String seed) {
    final md5Key = md5(seed);
    final useKey = md5Key.substring(0, 16);
    final useIv = md5Key.substring(16, 32);
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(useKey))),
            Uint8List.fromList(utf8.encode(useIv)),
          ),
          null,
        ),
      );
    final out = cipher.process(Uint8List.fromList(bytes));
    return utf8.decode(out, allowMalformed: true);
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

/// hex 输出的 AES 加密结果（对应 Node cryptoAesEncrypt 的 {str, key}）
class AesHexResult {
  const AesHexResult({required this.str, required this.key});
  final String str; // 十六进制密文
  final String key; // 临时 key（用于 RSA pk）
}
