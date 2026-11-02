import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiernan_music/features/lyric/data/krc_decoder.dart';
import 'package:tiernan_music/features/lyric/data/krc_parser.dart';

void main() {
  group('KrcDecoder', () {
    test('空/非法输入返回空串而不抛异常', () {
      expect(KrcDecoder.decode(''), '');
      expect(KrcDecoder.decode('not-base64!!!'), '');
      expect(KrcDecoder.decode('aGVsbG8='), ''); // 合法 base64 但无 krc1 头
    });

    test('真实 KRC 样本可解密', () {
      // 来自酷狗真实返回（晴天，lyrics.kugou.com/download，fmt=krc，2026-11-03 采样）
      const sample =
          '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';
      final text = KrcDecoder.decode(sample);
      expect(text.isNotEmpty, isTrue, reason: '真实样本应能解密');
      // 真实 KRC：首行是 [offset:...]，正文是 [起始,时长]<起始,时长,0>字
      expect(text.contains('['), isTrue);
      expect(RegExp(r'\[\d+,\d+]').hasMatch(text), isTrue,
          reason: '应含逐行时间标签');
    });
  });

  group('KrcParser', () {
    test('解析逐字标签', () {
      const krc = '[0,2048]<0,256,0>周<256,256,0>杰\n'
          '[2048,1281]<0,256,0>词\n';
      final lyric = KrcParser.parse(krc);
      expect(lyric.lines.length, 2);
      expect(lyric.lines.first.text, '周杰伦');
      expect(lyric.lines.first.words.length, 2);
      expect(lyric.lines.first.startMs, 0);
      expect(lyric.lines.first.durationMs, 2048);
    });

    test('无时间标签正文归并到上一行（不丢内容）', () {
      const krc = '[0,1000]<0,500,0>[A]B[C]\n无标签正文\n';
      final lyric = KrcParser.parse(krc);
      expect(lyric.lines.length, 1);
      expect(lyric.lines.first.text, '[A]B[C]无标签正文');
    });

    test('解析元数据', () {
      const krc = '[ti:标题]\n[ar:歌手]\n[al:专辑]\n[offset:100]\n'
          '[0,1000]<0,500,0>词\n';
      final lyric = KrcParser.parse(krc);
      expect(lyric.title, '标题');
      expect(lyric.artist, '歌手');
      expect(lyric.album, '专辑');
      expect(lyric.offsetMs, 100);
    });

    test('内嵌翻译支持三种结构', () {
      String enc(Object v) => base64.encode(utf8.encode(jsonEncode(v)));

      // A) 官方新格式 {"languageList":[{"lyricContent":[[原文,译文],...]}]}
      final a = KrcParser.parse(
        '[0,1000]<0,500,0>Hello\n'
        '[language:${enc({
              'languageList': [
                {
                  'lyricContent': [
                    ['Hello', '你好']
                  ]
                }
              ]
            })}]\n',
      );
      expect(a.lines.first.translation, '你好');

      // B) 旧格式 [{"content":"译文"}]
      final b = KrcParser.parse(
        '[0,1000]<0,500,0>Hello\n'
        '[language:${enc([
              {'content': '你好'}
            ])}]\n',
      );
      expect(b.lines.first.translation, '你好');

      // C) 纯数组
      final c = KrcParser.parse(
        '[0,1000]<0,500,0>Hello\n'
        '[language:${enc(['你好'])}]\n',
      );
      expect(c.lines.first.translation, '你好');
    });

    test('翻译块损坏时原歌词不丢失', () {
      final lyric = KrcParser.parse(
        '[0,1000]<0,500,0>Hello\n[language:!!!not-base64!!!]\n',
      );
      expect(lyric.lines.length, 1);
      expect(lyric.lines.first.text, 'Hello');
    });
  });
}
