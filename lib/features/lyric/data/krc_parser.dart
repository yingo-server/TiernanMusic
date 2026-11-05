import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  // F4-17（审查②-B，P1）：LRC 允许**一行多个时间戳**
  // （`[00:12.00][00:45.00]歌词`，副歌复用处极常见）。
  // 旧正则只匹配第一个时间戳，group(3) 会把第二个 `[00:45.00]` 当正文，
  // 导致方括号时间戳被显示成歌词，且第二个时间点永远不生成独立行。
  static final _lrcTimeRe = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');

  static KrcLyric parse(String krcText) {
    String? title, artist, album;
    var offset = 0;
    List<String>? embeddedTranslations;
    final lines = <KrcLine>[];
    // F4-20：文件头部无时间标签的提示文本（版权/译者注）暂存于此
    final leadingText = StringBuffer();

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

      final lrc = _lrcTimeRe.firstMatch(line);
      if (lrc != null && line.startsWith('[')) {
        // 收集行首连续的多个时间戳，正文从最后一个时间戳之后开始
        final times = <int>[];
        var cursor = 0;
        for (final m in _lrcTimeRe.allMatches(line)) {
          if (m.start != cursor) break; // 只吃行首连续时间戳
          final minutes = int.parse(m.group(1)!);
          final seconds = double.parse(m.group(2)!);
          times.add(minutes * 60000 + (seconds * 1000).round());
          cursor = m.end;
        }
        if (times.isNotEmpty) {
          final body = line.substring(cursor);
          for (final startMs in times) {
            lines.add(KrcLine(
              startMs: startMs,
              // F4-18（审查②-B，P2）：LRC 无逐字时间，duration 先留 0，
              // 全部解析完再按下一条的 startMs 回填，避免 endMs 退化为
              // 零长度区间导致整首不高亮。
              durationMs: 0,
              words: const [],
              text: body,
            ));
          }
          continue;
        }
      }

      // 既无时间标签也非元数据的正文：不能静默丢弃（会丢歌词）。
      // 归并到上一行，保证内容完整。
      if (lines.isNotEmpty) {
        final last = lines.removeLast();
        // F4-19（审查②-B，P2）：合并行若保留旧 words，words 拼出的文本与
        // text 不一致（逐字高亮下标错位 / 尾字丢失）。清空 words 让它按整行渲染。
        lines.add(KrcLine(
          startMs: last.startMs,
          durationMs: last.durationMs,
          words: const [],
          text: last.text.isEmpty ? line : '${last.text}$line',
        ));
      } else {
        // F4-20（审查②-B，P2）：头部无时间标签的提示文本（版权/译者注）
        // 旧实现直接丢弃；这里先留存，正文为空时至少还能显示出来。
        leadingText.write(line);
      }
    }

    // F4-18：LRC 行没有时长 → 用下一条 startMs 回填（最后一条按 5 秒估）。
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.durationMs > 0) continue;
      final next = i + 1 < lines.length ? lines[i + 1].startMs : 0;
      final duration = next > line.startMs ? next - line.startMs : 5000;
      lines[i] = KrcLine(
        startMs: line.startMs,
        durationMs: duration,
        words: line.words,
        text: line.text,
        translation: line.translation,
      );
    }

    // F4-21（审查②-B，P2）：视图对 lines 做二分查找，必须保证按 startMs 升序
    // （第 13 条：外部数据不得假设有序）。排序后再统一叠加 offset。
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));

    // F4-22（审查②-B，P2）：LRC/KRC 的 offset 正值语义是「歌词提前显示」，
    // 因此 startMs 减去 offset（旧实现只保存不用，逐字高亮与音频整体错位）。
    if (offset != 0) {
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        lines[i] = KrcLine(
          startMs: line.startMs - offset,
          durationMs: line.durationMs,
          words: <KrcWord>[
            for (final w in line.words)
              KrcWord(
                startMs: w.startMs - offset,
                durationMs: w.durationMs,
                text: w.text,
              ),
          ],
          text: line.text,
          translation: line.translation,
        );
      }
    }

    if (lines.isEmpty && leadingText.isNotEmpty) {
      lines.add(KrcLine(
        startMs: 0,
        durationMs: 0,
        words: const [],
        text: leadingText.toString(),
      ));
    }

    if (embeddedTranslations != null && embeddedTranslations.length == lines.length) {
      // F4-23（审查②-B，P2）：翻译只能在下标一一对应时套用。
      // 旧实现无论长度都按下标硬对齐，多语种/合并行时译文整体错行。
      for (var i = 0; i < lines.length; i++) {
        if (embeddedTranslations[i].isNotEmpty) {
          lines[i].translation = embeddedTranslations[i];
        }
      }
    } else if (embeddedTranslations != null) {
      // 条数不一致时宁可不贴（错译比无译更糟），留痕便于定位（第 9 条）
      debugPrint('[krc] 内嵌翻译条数与歌词行数不一致：'
          '${embeddedTranslations.length} vs ${lines.length}，已跳过对齐');
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
          // F4-23：多条目 = 多语种（或分段），拼接会把各段首尾相连导致
          // 译文与歌词行整体错位。只取第一个条目的内容。
          for (final entry in list) {
            if (entry is! Map) continue;
            final out = <String>[];
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
            if (out.isNotEmpty) return out;
          }
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
