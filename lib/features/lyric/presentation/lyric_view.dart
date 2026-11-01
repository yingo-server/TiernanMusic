import 'package:flutter/material.dart';

import '../../../core/theme/settings_provider.dart';
import '../data/krc_parser.dart';

/// KRC 逐字歌词视图
///
/// 支持原文/双语/译文三种模式，当前行高亮，逐字渐变。
///
/// 性能：播放位置每秒 tick 多次，若整棵 ListView 跟着重建会明显掉帧。
/// 这里用 `ListView.builder` + 逐行组件，只让「当前行」随位置变化，
/// 其余行保持不变（元素 identity 稳定，Flutter 会跳过重建）。
class LyricView extends StatefulWidget {
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
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _scroll = ScrollController();

  /// 行高近似值（原文 + 可选译文 + 内边距）。歌词行高不固定，滚动定位取近似即可。
  static const double _itemExtentApprox = 64.0;

  /// 用户手动滚动后暂停自动跟随时长
  static const Duration _userScrollPause = Duration(seconds: 5);

  DateTime _lastUserScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _didInitialScroll = false;

  /// 上一次渲染的当前行，用于只在行号变化时 setState
  int _currentIndex = -1;

  @override
  void initState() {
    super.initState();
    _currentIndex = _findCurrentLine(_posMs);
  }

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
      _currentIndex = _findCurrentLine(_posMs);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int get _posMs => widget.position.inMilliseconds + widget.lyric.offsetMs;

  void _scrollTo(int index, {bool jump = false}) {
    if (!_scroll.hasClients) return;
    final target = (index * _itemExtentApprox)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final posMs = _posMs;
    final index = _findCurrentLine(posMs);

    // 行号变化时才重建（逐字高亮由行内组件自己处理）
    if (index != _currentIndex) {
      _currentIndex = index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        // 首帧直接定位，之后平滑跟随；用户手动滚动后 5 秒内暂停自动跟随
        final first = !_didInitialScroll;
        if (first) _didInitialScroll = true;
        final paused =
            DateTime.now().difference(_lastUserScrollAt) < _userScrollPause;
        if (first || !paused) _scrollTo(index, jump: first);
      });
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null ||
            n is UserScrollNotification) {
          _lastUserScrollAt = DateTime.now();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120),
        itemCount: widget.lyric.lines.length,
        itemBuilder: (context, i) {
          final line = widget.lyric.lines[i];
          return _LyricLineTile(
            line: line,
            isCurrent: i == index,
            mode: widget.mode,
            posMs: posMs,
            onTap: widget.onTapLine != null
                ? () => widget.onTapLine!(line.startMs)
                : null,
          );
        },
      ),
    );
  }

  int _findCurrentLine(int posMs) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return 0;
    var lo = 0, hi = lines.length - 1, result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= posMs) {
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
    super.key,
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
    final primary = theme.colorScheme.primary;
    final translation = line.translation ?? '';

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 原文（逐字高亮）
            _buildOriginal(theme, primary),
            // 译文
            if (mode == LyricDisplayMode.bilingual &&
                translation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                translation,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            ] else if (mode == LyricDisplayMode.translation &&
                translation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                translation,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOriginal(ThemeData theme, Color primary) {    if (line.words.isEmpty) {
      return Text(
        line.text,
        style: theme.textTheme.titleMedium?.copyWith(
          color: isCurrent
              ? primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.55),
          fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
          height: 1.35,
        ),
      );
    }

    // 逐字：已唱部分用主色，未唱部分用弱化色
    final spans = <TextSpan>[];
    for (final w in line.words) {
      final isPast = posMs >= w.startMs + w.durationMs;
      final isNow = posMs >= w.startMs && posMs < w.startMs + w.durationMs;
      spans.add(TextSpan(
        text: w.text,
        style: TextStyle(
          color: isPast || isNow
              ? primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.45),
          fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
          fontSize: isCurrent ? 17 : 16,
        ),
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      style: theme.textTheme.titleMedium?.copyWith(height: 1.35),
    );
  }
}
