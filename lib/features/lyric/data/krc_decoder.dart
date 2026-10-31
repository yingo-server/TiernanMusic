import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

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

  /// 解密 Base64 编码的加密 KRC
  static String decode(String base64Content) {
    final bytes = base64.decode(base64.normalize(base64Content.trim()));
    if (bytes.length <= 4 ||
        bytes[0] != 0x6b || bytes[1] != 0x72 ||
        bytes[2] != 0x63 || bytes[3] != 0x31) {
      throw const FormatException('无效的 KRC 内容或文件头');
    }

    // 跳过 4 字节 'krc1' 头
    final body = bytes.sublist(4);

    // XOR 解密
    final decrypted = Uint8List(body.length);
    for (var i = 0; i < body.length; i++) {
      decrypted[i] = body[i] ^ _key[i % 16];
    }

    // zlib 解压
    final decompressed = const ZLibDecoder().decodeBytes(decrypted);
    return utf8.decode(decompressed, allowMalformed: true);
  }
}
