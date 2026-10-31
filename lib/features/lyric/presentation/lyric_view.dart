import 'package:flutter/material.dart';

import '../../../core/theme/settings_provider.dart';
import '../data/krc_parser.dart';

/// KRC 逐字歌词视图
///
/// 支持原文/双语/译文三种模式，当前行高亮，逐字渐变。
class LyricView extends StatelessWidget {
  const LyricView({
    super.key,
    required this.lyric,
    required this.position,
    this.mode = LyricDisplayMode.bilingual,
    this.onTapLine,
  });

  final KrcLyric lyric;
  final Duration position;
  final LyricDisplayMode mode;
  final ValueChanged<int>? onTapLine;

  @override
  Widget build(BuildContext context) {
    final posMs = position.inMilliseconds + lyric.offsetMs;
    final currentIndex = _findCurrentLine(posMs);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120),
      itemCount: lyric.lines.length,
      itemBuilder: (context, index) {
        final line = lyric.lines[index];
        final isCurrent = index == currentIndex;
        return _LyricLineTile(
          line: line,
          isCurrent: isCurrent,
          mode: mode,
          posMs: posMs,
          onTap: onTapLine != null ? () => onTapLine!(line.startMs) : null,
        );
      },
    );
  }

  int _findCurrentLine(int posMs) {
    var lo = 0, hi = lyric.lines.length - 1, result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lyric.lines[mid].startMs <= posMs) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    required this.line,
    required this.isCurrent,
    required this.mode,
    required this.posMs,
    this.onTap,
  });

  final KrcLine line;
  final bool isCurrent;
  final LyricDisplayMode mode;
  final int posMs;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withOpacity(0.55);

    final showOriginal = mode != LyricDisplayMode.translation;
    final showTranslation = mode != LyricDisplayMode.original &&
        line.translation != null &&
        line.translation != line.text;

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showOriginal)
              _buildLine(theme, color, isCurrent),
            if (showTranslation) ...[
              const SizedBox(height: 4),
              Text(
                line.translation!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color.withOpacity(0.85),
                  fontSize: isCurrent ? 15 : 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLine(ThemeData theme, Color color, bool isCurrent) {
    // 当前行且是逐字歌词时做逐字高亮
    if (isCurrent && line.words.isNotEmpty) {
      return Wrap(
        children: [
          for (final word in line.words)
            _WordSpan(
              word: word,
              lineStartMs: line.startMs,
              posMs: posMs,
              style: theme.textTheme.titleLarge!.copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
              activeColor: theme.colorScheme.primary,
              inactiveColor: theme.colorScheme.onSurface.withOpacity(0.55),
            ),
        ],
      );
    }
    return Text(
      line.text,
      style: (isCurrent ? theme.textTheme.titleLarge : theme.textTheme.bodyLarge)
          ?.copyWith(
        color: color,
        fontSize: isCurrent ? 22 : 17,
        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
      ),
    );
  }
}

class _WordSpan extends StatelessWidget {
  const _WordSpan({
    required this.word,
    required this.lineStartMs,
    required this.posMs,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
  });

  final KrcWord word;
  final int lineStartMs;
  final int posMs;
  final TextStyle style;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    final absStart = lineStartMs + word.startMs;
    final absEnd = absStart + word.durationMs;
    final progress = posMs <= absStart
        ? 0.0
        : posMs >= absEnd
            ? 1.0
            : (posMs - absStart) / word.durationMs;

    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: [activeColor, inactiveColor],
        stops: [progress, progress],
      ).createShader(bounds),
      child: Text(word.text, style: style.copyWith(color: Colors.white)),
    );
  }
}
