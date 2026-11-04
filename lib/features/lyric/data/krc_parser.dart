import 'dart:convert';

/// KRC 逐字歌词解析器
///
/// 格式：[start,duration]<wordStart,wordDuration,0>字<...>
/// 同时解析 [ti:] [ar:] [al:] [offset:] 元数据和 language 翻译行
class KrcLine {
  KrcLine({
    required this.startMs,
    required this.durationMs,
    required this.words,
    required this.text,
    this.translation,
  });

  final int startMs;
  final int durationMs;
  final List<KrcWord> words;
  final String text;
  String? translation;

  int get endMs => startMs + durationMs;
}

class KrcWord {
  KrcWord({required this.startMs, required this.durationMs, required this.text});
  final int startMs;
  final int durationMs;
  final String text;
}

class KrcLyric {
  KrcLyric({
    this.title,
    this.artist,
    this.album,
    this.offsetMs = 0,
    required this.lines,
  });

  final String? title;
  final String? artist;
  final String? album;
  final int offsetMs;
  final List<KrcLine> lines;
}

class KrcParser {
  KrcParser._();

  static final _lineRe = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final _wordRe = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
  static final _metaRe = RegExp(r'^\[([a-zA-Z]+):(.*)\]$');
  static final _lrcLineRe = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$');

  static KrcLyric parse(String krcText) {
    String? title, artist, album;
    var offset = 0;
    List<String>? embeddedTranslations;
    final lines = <KrcLine>[];

    for (final raw in const LineSplitter().split(krcText)) {
      // 只 trim 行尾，避免破坏歌词正文两侧有意的空白。
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final meta = _metaRe.firstMatch(line);
      if (meta != null) {
        final key = meta.group(1)!.toLowerCase();
        final value = meta.group(2)!.trim();
        switch (key) {
          case 'ti':
            title = value;
          case 'ar':
            artist = value;
          case 'al':
            album = value;
          case 'offset':
            offset = int.tryParse(value) ?? 0;
          case 'language':
            embeddedTranslations = _decodeLanguage(value);
        }
        continue;
      }

      final m = _lineRe.firstMatch(line);
      if (m != null) {
        final words = <KrcWord>[];
        final text = StringBuffer();
        for (final wm in _wordRe.allMatches(m.group(3)!)) {
          final word = wm.group(3)!;
          final lineStart = int.parse(m.group(1)!);
          words.add(KrcWord(
            // PLY-01（审查③）：KRC 逐字时间是**相对本行开始**的偏移，
            // 必须加行首时间才是全曲绝对时间；否则除第一行外全部误判。
            startMs: lineStart + int.parse(wm.group(1)!),
            durationMs: int.parse(wm.group(2)!),
            text: word,
          ));
          text.write(word);
        }
        // 没有时间标签的尾部（例如方括号或异常文本）不能静默丢弃。
        final wordMatches = _wordRe.allMatches(m.group(3)!).toList();
        final lastWordEnd = wordMatches.isEmpty ? 0 : wordMatches.last.end;
        if (lastWordEnd < m.group(3)!.length) {
          text.write(m.group(3)!.substring(lastWordEnd));
        }
        lines.add(KrcLine(
          startMs: int.parse(m.group(1)!),
          durationMs: int.parse(m.group(2)!),
          words: words,
          text: text.toString(),
        ));
        continue;
      }

      final lrc = _lrcLineRe.firstMatch(line);
      if (lrc != null) {
        final minutes = int.parse(lrc.group(1)!);
        final seconds = double.parse(lrc.group(2)!);
        lines.add(KrcLine(
          startMs: minutes * 60000 + (seconds * 1000).round(),
          durationMs: 0,
          words: const [],
          text: lrc.group(3)!,
        ));
        continue;
      }

      // 既无时间标签也非元数据的正文：不能静默丢弃（会丢歌词）。
      // 归并到上一行，保证内容完整。
      if (lines.isNotEmpty) {
        final last = lines.removeLast();
        lines.add(KrcLine(
          startMs: last.startMs,
          durationMs: last.durationMs,
          words: last.words,
          text: last.text.isEmpty ? line : '${last.text}$line',
        ));
      }
    }

    if (embeddedTranslations != null) {
      for (var i = 0; i < lines.length && i < embeddedTranslations.length; i++) {
        if (embeddedTranslations[i].isNotEmpty) {
          lines[i].translation = embeddedTranslations[i];
        }
      }
    }
    return KrcLyric(
      title: title, artist: artist, album: album, offsetMs: offset, lines: lines,
    );
  }

  static List<String> _decodeLanguage(String value) {
    // KRC 的 language 行是 Base64(JSON)，但**结构在不同版本间不一致**，全部兼容：
    //   A) {"languageList":[{"lyricContent":[[原文,译文],...]}]}   ← 官方新格式
    //   B) [{"content":"译文"}, ...]                              ← 旧格式（顶层数组）
    //   C) ["译文", ...]                                          ← 纯数组
    // 解不开时降级为按行分割的纯文本，绝不让原歌词消失。
    try {
      final decoded = utf8.decode(base64.decode(value));
      final jsonValue = jsonDecode(decoded);

      // A) languageList 结构
      if (jsonValue is Map) {
        final list = jsonValue['languageList'];
        if (list is List) {
          final out = <String>[];
          for (final entry in list) {
            if (entry is! Map) continue;
            final content = entry['lyricContent'];
            if (content is List) {
              for (final pair in content) {
                if (pair is List && pair.length >= 2) {
                  out.add('${pair[1]}'); // [原文, 译文] → 取译文
                } else if (pair is String) {
                  out.add(pair);
                }
              }
            } else if (content is String) {
              out.add(content);
            }
          }
          if (out.isNotEmpty) return out;
        }
        // Map 里的其它形态
        final direct = jsonValue['content'] ?? jsonValue['text'];
        if (direct is String && direct.isNotEmpty) return [direct];
      }

      // B) 顶层数组（元素是 Map 或 String）
      if (jsonValue is List) {
        final out = <String>[];
        for (final item in jsonValue) {
          if (item is Map) {
            out.add('${item['content'] ?? item['text'] ?? ''}');
          } else if (item is List && item.length >= 2) {
            out.add('${item[1]}');
          } else {
            out.add('$item');
          }
        }
        if (out.isNotEmpty) return out;
      }
    } catch (_) {
      // 非标准或损坏的翻译块不应导致原歌词消失。
    }
    return value.split(RegExp(r'\r?\n'));
  }
}

class LineSplitter {
  const LineSplitter();
  List<String> split(String text) => text.split(RegExp(r'\r?\n'));
}
