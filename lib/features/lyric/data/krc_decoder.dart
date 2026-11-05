import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// KRC 解密结果
///
/// F4-24（审查②-B，P2）：旧实现把「空串 / 非法 Base64 / 非 krc1 头 / 解压失败」
/// 统一返回 `''`，调用方无法区分「本来就是明文歌词」与「密文损坏」，
/// 损坏时被当成「无歌词」静默吞掉（QUALITY_STANDARD 第 9 条：失败必须可观测）。
enum KrcDecodeError {
  emptyInput,
  invalidBase64,
  notKrcContainer,
  corruptPayload,
}

class KrcDecodeResult {
  const KrcDecodeResult.success(this.text) : error = null;
  const KrcDecodeResult.failure(this.error) : text = '';

  final String text;
  final KrcDecodeError? error;

  bool get isSuccess => error == null;
}

/// KRC 解密器
///
/// 流程：Base64 解码 → 跳过 4 字节 'krc1' 头 → 16 字节固定 key 循环 XOR
/// → zlib 解压为 UTF-8
class KrcDecoder {
  KrcDecoder._();

  static const List<int> _key = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
    0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
  ];

  /// 解密并返回结构化结果（调用方据此决定是否改取 LRC 明文）
  static KrcDecodeResult decodeDetailed(String base64Content) {
    if (base64Content.trim().isEmpty) {
      return const KrcDecodeResult.failure(KrcDecodeError.emptyInput);
    }
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64.normalize(base64Content.trim()));
    } catch (_) {
      return const KrcDecodeResult.failure(KrcDecodeError.invalidBase64);
    }
    if (bytes.length <= 4 ||
        bytes[0] != 0x6b || bytes[1] != 0x72 ||
        bytes[2] != 0x63 || bytes[3] != 0x31) {
      return const KrcDecodeResult.failure(KrcDecodeError.notKrcContainer);
    }

    // 跳过 4 字节 'krc1' 头
    final body = bytes.sublist(4);

    // XOR 解密
    final decrypted = Uint8List(body.length);
    for (var i = 0; i < body.length; i++) {
      decrypted[i] = body[i] ^ _key[i % 16];
    }

    // zlib 解压（数据损坏时抛异常 → 归类为 corruptPayload）
    try {
      return KrcDecodeResult.success(_inflateUint8List(decrypted));
    } on Object {
      // F4-25（审查②-B，P2）：部分服务端在 'krc1' 头后还有 4 字节长度前缀，
      // 直接解压会失败。这里只多试一次「跳过长度前缀」的形态，
      // 不在成功路径上增加任何开销，且失败仍可观测（不是静默）。
      if (body.length > 8) {
        try {
          final shifted = Uint8List(body.length - 4);
          for (var i = 0; i < shifted.length; i++) {
            shifted[i] = body[i + 4] ^ _key[(i + 4) % 16];
          }
          return KrcDecodeResult.success(_inflateUint8List(shifted));
        } on Object {
          // 落到下面的失败返回
        }
      }
      return const KrcDecodeResult.failure(KrcDecodeError.corruptPayload);
    }
  }

  static String _inflateUint8List(Uint8List data) {
    final decompressed = const ZLibDecoder().decodeBytes(data);
    final text = utf8.decode(decompressed, allowMalformed: true);
    if (text.trim().isEmpty) {
      throw const FormatException('KRC 解压结果为空');
    }
    return text;
  }

  /// 解密 Base64 编码的加密 KRC
  ///
  /// 兼容旧调用点：失败返回空串。新代码请用 [decodeDetailed] 以区分失败原因。
  static String decode(String base64Content) =>
      decodeDetailed(base64Content).text;
}
