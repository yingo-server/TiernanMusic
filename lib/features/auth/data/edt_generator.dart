/// 酷狗行为指纹 sid/edt 生成器（Dart 移植）
///
/// 逐行对照 `KuGouMusicApi/util/generate_simulate.js` 移植：
///   generateSimulate → EdtGenerator.generate
///   generateEDTData  → _generateEdtData
///   bezierPath       → _bezierPath
///   f3 / f5 / f6     → _f3 / _f5 / _f6
///   fs3 / fs5 / fs6  → _fs3 / _fs5 / _fs6
///   ri               → _ri
///   randomString     → _randomString
///
/// 加密方案（与 Node 版一致）：
///   明文 → AES-128-CBC(key=随机16字符字符串, iv="kugousecurity123", PKCS7) → Base64 = EDT
///   key  → RSA-OAEP(md=SHA-256, mgf1=SHA-256) → Base64 = SID
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

class EdtResult {
  const EdtResult({required this.sid, required this.edt});
  final String sid;
  final String edt;
}

/// MD5 工具（避免与 pointycastle/crypto 包顶层函数遮蔽）
class KgCryptoHelper {
  KgCryptoHelper._();
  static String md5Hex(List<int> bytes) {
    final d = MD5Digest().process(Uint8List.fromList(bytes));
    return d.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class EdtGenerator {
  EdtGenerator._();

  /// 与 Node 版一致的固定 IV（ASCII "kugousecurity123"）
  static const _iv = 'kugousecurity123';

  /// 从酷狗 WASM 提取的 RSA-2048 公钥（SPKI / PEM）
  static const _publicKeyPem = '''
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoW2+Ylo8ALePSQTP0xBF
lFmEOHvBD9tS+s7DBlfKEu3RzzvZTaX1JtYbX4+AVUqj6ARz8IM+CKByqGFvbHN/
W64XxNI+q7z36ajCL3VTJ2W5G9MCJitc6oGbire4NQfhaEq0nC+hxBWQvCbIFflA
2ItrLUbSU7z1bHA/a+jlQm4OWvY+IKnTryOJTPuT1yNOVjbJ8wBLKy2DgQr9pPqW
PmEQtGpR5IM9V8Kao6PaSdKYOWGbX3i2+RzIKhvZUxxtJwdVbqPlDPlW9h4/xIBc
56Lgvr4aIl8nFtwbj4UJVUTFuGrs0tY9H/tXvZ22dUCKuGxW/gW7ZF+gXz6vHtYa
rQIDAQAB''';

  static final _rand = math.Random.secure();

  /// 哨兵值（每次生成重新随机，范围 0xFFFFFFFF-19 ~ 0xFFFFFFFF）
  static int _sentinel = 0xffffffff;

  /// 生成 sid / edt
  ///
  /// [mid] 设备 MID，缺失传 '0'
  /// [userid] 用户 ID，未登录传 '0'
  /// [dfid] register_dev 返回的设备 id，缺失传 '0'
  /// [webglHash] WebGL 指纹哈希（字符串十进制），建议固定
  static EdtResult generate({
    required String mid,
    required String userid,
    required String dfid,
    required String webglHash,
    String? fixedKey,
    int? timestampMs,
  }) {
    _sentinel = 0xffffffff - _ri(0, 19);

    // key = MD5(随机16字符) 的 hex 前 16 位
    final key = fixedKey ??
        KgCryptoHelper.md5Hex(utf8.encode(_randomString(16)))
            .substring(0, 16);

    final points = _ri(30, 60);
    final startX = _ri(200, 600);
    final startY = _ri(200, 500);
    final endX = _ri(500, 700);
    final endY = _ri(80, 150);

    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final data = _generateEdtData(
      startX: startX,
      startY: startY,
      endX: endX,
      endY: endY,
      mousePoints: points,
    );

    final plaintext =
        'mid=${_nz(mid)};userid=${_nz(userid)};dfid=${_nz(dfid)};'
        'webgl=${_nz(webglHash)};webdriver=0;ts=$ts;data=$data';

    final edt = _aesEncryptBase64(plaintext, key);
    final sid = _rsaOaepEncryptBase64(key);
    return EdtResult(sid: sid, edt: edt);
  }

  static String _nz(String v) => v.isEmpty ? '0' : v;

  // ---------------------------------------------------------------
  // 行为数据生成（对应 generateEDTData）
  // ---------------------------------------------------------------

  static String _generateEdtData({
    required int startX,
    required int startY,
    required int endX,
    required int endY,
    required int mousePoints,
  }) {
    final entries = <String>[];
    var ts = 0;
    var ei = 0;

    // 初始化：两个 type-5 零事件 + 哨兵
    entries.add(_f5(0, 0));
    entries.add(_fs5(0));
    entries.add(_f5(0, 0));
    entries.add(_fs5(0));

    // 窗口事件 type-6，尺寸 750x500
    ts += _ri(5, 20);
    entries.add(_f6(ts, ei, 750, 500));
    entries.add(_fs6(ei, 750, 500));
    ei++;

    // 3 次滚动事件 type-5
    for (var i = 0; i < 3; i++) {
      ts += _ri(80, 600);
      entries.add(_f5(ts, ei));
      entries.add(_fs5(ei));
      ei++;
    }

    // 鼠标轨迹 type-3
    final path = _bezierPath(startX, startY, endX, endY, mousePoints);
    var si = 0;
    for (var i = 0; i < path.length; i++) {
      final p = path[i];
      ts += _ri(8, 50);
      entries.add(_f3(ts, si, p.$1.round(), p.$2.round()));
      entries.add(_fs3(si, p.$1.round(), p.$2.round()));

      if (i > 0 && i % 12 == 0) {
        ts += _ri(20, 60);
        entries.add(_f5(ts, ei));
        entries.add(_fs5(ei));
        ei++;
      }
      si = (si + 1) % 2;
    }

    // 结束事件：最后一次移动带 ±5 微调，哨兵用未抖动坐标
    ts += _ri(5, 30);
    entries.add(_f3(
      ts,
      1,
      (endX + _ri(-5, 5)).round(),
      (endY + _ri(-5, 5)).round(),
    ));
    entries.add(_fs3(1, endX.round(), endY.round()));

    return entries.join(':');
  }

  /// 三阶贝塞尔路径（对应 bezierPath）
  static List<(double, double)> _bezierPath(
    int sx,
    int sy,
    int ex,
    int ey,
    int n,
  ) {
    final c1x = sx + (ex - sx) * 0.3 + _ri(-80, 80);
    final c1y = sy + (ey - sy) * 0.2 + _ri(-60, 60);
    final c2x = sx + (ex - sx) * 0.7 + _ri(-60, 60);
    final c2y = sy + (ey - sy) * 0.8 + _ri(-40, 40);

    final pts = <(double, double)>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      final u = 1 - t;
      final x = u * u * u * sx +
          3 * u * u * t * c1x +
          3 * u * t * t * c2x +
          t * t * t * ex;
      final y = u * u * u * sy +
          3 * u * u * t * c1y +
          3 * u * t * t * c2y +
          t * t * t * ey;
      // 抖动幅度从 3px 递减到 0.5px
      final jitter = math.max(0.5, 3 - t * 2.5);
      pts.add((
        x + (_rand.nextDouble() - 0.5) * jitter,
        y + (_rand.nextDouble() - 0.5) * jitter,
      ));
    }
    return pts;
  }

  // 事件格式化（对应 f3/f5/f6 与 fs3/fs5/fs6）
  static String _f3(int t, int i, int x, int y) => '3,$t,$i,$x,$y';
  static String _f5(int t, int i) => '5,$t,$i';
  static String _f6(int t, int i, int x, int y) => '6,$t,$i,$x,$y';
  static String _fs3(int i, int x, int y) => '3,$_sentinel,$i,$x,$y';
  static String _fs5(int i) => '5,$_sentinel,$i';
  static String _fs6(int i, int x, int y) => '6,$_sentinel,$i,$x,$y';

  /// 闭区间随机整数（对应 ri）
  static int _ri(int min, int max) =>
      _rand.nextInt(max - min + 1) + min;

  /// 对应 randomString：字符表 1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
  static String _randomString(int len) {
    const chars = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      // 与 Node 版保持一致：ceil((len-1) * random())
      final idx = ((chars.length - 1) * _rand.nextDouble()).ceil();
      sb.write(chars[idx.clamp(0, chars.length - 1)]);
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------
  // 加密
  // ---------------------------------------------------------------

  /// AES-128-CBC + PKCS7，输出 Base64（对应 CryptoJS.AES.encrypt(...).toString()）
  static String _aesEncryptBase64(String plaintext, String key) {
    final keyBytes = Uint8List.fromList(utf8.encode(key));
    final ivBytes = Uint8List.fromList(utf8.encode(_iv));
    // PaddedBlockCipher 自动做 PKCS7 填充（与 CryptoJS 默认一致）
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(keyBytes), ivBytes),
          null,
        ),
      );
    final input = Uint8List.fromList(utf8.encode(plaintext));
    final out = cipher.process(input);
    return base64.encode(out);
  }

  /// RSA-OAEP(SHA-256) 加密 key，输出 Base64
  static String _rsaOaepEncryptBase64(String key) {
    final derBytes = base64.decode(_publicKeyPem.replaceAll(RegExp(r'\s'), ''));
    final outer = ASN1Parser(derBytes).nextObject() as ASN1Sequence;
    final keyBits = (outer.elements![1] as ASN1BitString).stringValues!;
    final keySeq = ASN1Parser(Uint8List.fromList(keyBits)).nextObject()
        as ASN1Sequence;
    final modulus =
        (keySeq.elements![0] as ASN1Integer).integer as BigInt;
    final exponent =
        (keySeq.elements![1] as ASN1Integer).integer as BigInt;

    final oaep = OAEPEncoding(RSAEngine())
      ..init(
        true,
        PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, exponent)),
      );

    final data = Uint8List.fromList(utf8.encode(key));
    final out = oaep.process(data);
    return base64.encode(out);
  }
}
