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

  static final _lineRe = RegExp(r'\[(\d+),(\d+)\](.*)');
  static final _wordRe = RegExp(r'<(\d+),(\d+),0>([^<]*)');
  static final _metaRe = RegExp(r'^\[(ti|ar|al|offset|language|au|by|re):(.*)\]$');

  static KrcLyric parse(String krcText) {
    String? title, artist, album;
    var offset = 0;
    final lines = <KrcLine>[];

    for (final raw in const LineSplitter().split(krcText)) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      final meta = _metaRe.firstMatch(line);
      if (meta != null) {
        final key = meta.group(1)!;
        final value = meta.group(2)!.trim();
        switch (key) {
          case 'ti':
            title = value;
            break;
          case 'ar':
            artist = value;
            break;
          case 'al':
            album = value;
            break;
          case 'offset':
            offset = int.tryParse(value) ?? 0;
            break;
          case 'language':
            // 内嵌翻译，暂存，后面按行附加
            break;
        }
        continue;
      }

      final m = _lineRe.firstMatch(line);
      if (m == null) continue;

      final start = int.parse(m.group(1)!);
      final duration = int.parse(m.group(2)!);
      final body = m.group(3)!;

      final words = <KrcWord>[];
      final sb = StringBuffer();
      for (final wm in _wordRe.allMatches(body)) {
        final w = KrcWord(
          startMs: int.parse(wm.group(1)!),
          durationMs: int.parse(wm.group(2)!),
          text: wm.group(3)!,
        );
        words.add(w);
        sb.write(w.text);
      }

      lines.add(KrcLine(
        startMs: start,
        durationMs: duration,
        words: words,
        text: sb.toString(),
      ));
    }

    return KrcLyric(
      title: title,
      artist: artist,
      album: album,
      offsetMs: offset,
      lines: lines,
    );
  }
}

class LineSplitter {
  const LineSplitter();
  List<String> split(String text) => text.split(RegExp(r'\r?\n'));
}
