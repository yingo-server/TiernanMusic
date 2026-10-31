import 'package:flutter_test/flutter_test.dart';
import 'package:tiernan_music/core/direct/kg_crypto.dart';
import 'package:tiernan_music/core/direct/kg_client.dart';
import 'package:tiernan_music/features/lyric/data/krc_decoder.dart';
import 'package:tiernan_music/features/lyric/data/krc_parser.dart';

void main() {
  group('KgCrypto', () {
    test('md5 与 Node cryptoMd5 一致', () {
      // Node: cryptoMd5('hello') = 5d41402abc4b2a76b9719d911017c592
      expect(KgCrypto.md5('hello'), '5d41402abc4b2a76b9719d911017c592');
      expect(KgCrypto.md5(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('android 签名与 Node signatureAndroidParams 一致', () {
      // Node 实测基准：salt + 排序后 key=value + data + salt → md5
      final params = <String, dynamic>{
        'dfid': 'abc',
        'mid': '123456',
        'uuid': '-',
        'appid': 1005,
        'clientver': 20489,
        'clienttime': 1793447539,
        'hash': 'b3a5',
      };
      expect(
        KgSignature.android(params),
        '5d6aefcd88827b2959ea362fa7268061',
      );
    });

    test('signKey 与 Node signKey 一致', () {
      expect(
        KgSignature.keyOf(hash: 'b3a5', mid: '123456', userid: '0', appid: 1005),
        '3629b302795a96f04993da67218980c8',
      );
    });

    test('register 签名与 Node signatureRegisterParams 一致', () {
      expect(
        KgSignature.register({'a': 'x', 'b': 'y'}),
        '9482f92396949a6b2fbf5cd46f8f9241',
      );
    });

    test('web 签名稳定可复现', () {
      final params = <String, dynamic>{'a': '1', 'b': '2'};
      // Node: md5('NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt' + 'a=1b=2' + '' + salt)
      final expected = KgCrypto.md5(
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt'
        'a=1b=2'
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt',
      );
      expect(KgSignature.web(params), expected);
    });
  });

  group('KgDevice.calculateMid', () {
    test('与 Node calculateMid 一致', () {
      // Node: calculateMid('550e8400-e29b-41d4-a716-446655440000')
      expect(
        KgDevice.calculateMid('550e8400-e29b-41d4-a716-446655440000'),
        '308741372901437977228425563242293240765',
      );
    });
  });

  group('KRC', () {
    test('解密非法输入不抛异常', () {
      expect(() => KrcDecoder.decode('not-base64!!!'), returnsNormally);
      expect(KrcDecoder.decode(''), '');
    });

    test('解析逐字时间轴', () {
      const krc = '[ti:测试]\n'
          '[ar:歌手]\n'
          '[offset:0]\n'
          '[0,3000]<0,500,0>你好<500,500,0>世界\n'
          '[3000,2000]<3000,1000,0>第二句\n';
      final lyric = KrcParser.parse(krc);
      expect(lyric.title, '测试');
      expect(lyric.artist, '歌手');
      expect(lyric.lines.length, 2);
      expect(lyric.lines.first.text, '你好世界');
      expect(lyric.lines.first.words.length, 2);
      expect(lyric.lines.first.words.first.startMs, 0);
      expect(lyric.lines.first.words.last.startMs, 500);
      expect(lyric.lines.last.startMs, 3000);
    });

    test('解析无标签正文与特殊字符', () {
      const krc = '[0,1000]<0,500,0>[A]B[C]\n'
          '无标签正文\n';
      final lyric = KrcParser.parse(krc);
      expect(lyric.lines.length, 2);
      expect(lyric.lines.first.text, '[A]B[C]');
      expect(lyric.lines.last.text, '无标签正文');
    });

    test('解析空内容不抛异常', () {
      expect(() => KrcParser.parse(''), returnsNormally);
      expect(KrcParser.parse('').lines, isEmpty);
    });
  });
}
