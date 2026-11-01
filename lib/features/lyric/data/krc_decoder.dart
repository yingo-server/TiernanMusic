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
  ///
  /// 输入非法（空、非 Base64、非 krc1 头）时返回空串而非抛异常——
  /// 歌词是可选内容，不能因为一条脏数据让整个播放页崩掉。
  static String decode(String base64Content) {
    if (base64Content.trim().isEmpty) return '';
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64.normalize(base64Content.trim()));
    } catch (_) {
      return '';
    }
    if (bytes.length <= 4 ||
        bytes[0] != 0x6b || bytes[1] != 0x72 ||
        bytes[2] != 0x63 || bytes[3] != 0x31) {
      return '';
    }

    // 跳过 4 字节 'krc1' 头
    final body = bytes.sublist(4);

    // XOR 解密
    final decrypted = Uint8List(body.length);
    for (var i = 0; i < body.length; i++) {
      decrypted[i] = body[i] ^ _key[i % 16];
    }

    // zlib 解压（数据损坏时抛 ArchiveException，捕获后返回空串）
    try {
      final decompressed = const ZLibDecoder().decodeBytes(decrypted);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}
