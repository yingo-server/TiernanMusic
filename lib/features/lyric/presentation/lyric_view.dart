import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../core/resource/lyric_translation_stream.dart';
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
    this.lyricId,
    this.songHash,
  });

  final KrcLyric lyric;
  final Duration position;
  final LyricDisplayMode mode;
  final ValueChanged<int>? onTapLine;

  /// 歌词 ID（/search/lyric 候选 id）。
  ///
  /// V400-A-03：用于匹配 [LyricTranslationStream] 补丁的 `patch.lyricId`
  /// （冻结契约：B 按 candidate.id emit）。为 null 时退化为「只接受当前
  /// 歌词代际内、下标范围合法」的补丁（原则 23：匹配键尽量覆盖维度）。
  final String? lyricId;

  /// 所属歌曲 hash（V400-A-03：原则 18 的代际键之一）。
  ///
  /// 换歌后即使候选 id 恰好复用，旧歌词/旧译文也不得写入新歌视图。
  final String? songHash;

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

  // V400-A-03：翻译增量订阅。
  //
  // 原文歌词随 provider 先秒显；译文由 B 的 [LyricTranslationStream]
  // 按批广播（每批完成即 emit，不等整首），这里逐批写入
  // `line.translation` 后只 setState 一次（原则 20：订阅与 dispose 对称；
  // 原则 18：写入前校验补丁与当前歌词代际匹配）。
  StreamSubscription<LyricTranslationPatch>? _patchSub;

  /// 本 State 接收补丁时的歌词对象（didUpdateWidget 换词后代际失效）
  KrcLyric? _boundLyric;

  /// 与 _boundLyric 同代的歌曲 hash（补丁写入前的代际校验用）
  String? _boundSongHash;

  @override
  void initState() {
    super.initState();
    _currentIndex = _findCurrentLine(_posMs);
    _boundLyric = widget.lyric;
    _boundSongHash = widget.songHash;
    _subscribePatches();
  }

  /// 订阅译文增量广播（冻结契约：LyricTranslationStream.instance.patches）。
  void _subscribePatches() {
    _patchSub = LyricTranslationStream.instance.patches
        .listen(_onTranslationPatch, onError: (Object e) {
      // 广播异常不应拖垮歌词显示（第 7 条：只捕获并留痕）
      debugPrint('[lyric_view] 翻译补丁流错误：$e');
    });
  }

  void _onTranslationPatch(LyricTranslationPatch p) {
    if (!mounted) return;
    final lyric = _boundLyric;
    if (lyric == null) return;
    // 原则 18（世代校验）：换歌后旧补丁不得写入新歌词。
    // 歌曲代际（songHash，切歌必变）优先；候选 id 一致时再要求相等。
    final wantHash = widget.songHash;
    if (wantHash != null && wantHash.isEmpty == false) {
      final currentHash = _boundSongHash;
      if (currentHash == null || currentHash != wantHash) return;
    }
    final wantId = widget.lyricId;
    if (wantId != null && p.lyricId != wantId) return;
    final lines = lyric.lines;
    var changed = false;
    final values = p.values;
    // v5.3 B-14 重写：补丁按行号直写（lineIndices 与 values 等长）。
    // 旧契约 `startIndex + j` 连续写回在 missing 非连续时（F4-30 逐行
    // 判定后是常态）把译文插错行且缓存命中时永久错。lineIndices 为空
    // 的旧形态补丁退回连续写（防御，本仓调用点已全部迁移）。
    if (p.lineIndices.isEmpty) {
      if (p.startIndex < 0 || p.startIndex >= lines.length) return;
      for (var j = 0; j < values.length; j++) {
        final i = p.startIndex + j;
        if (i >= lines.length) break;
        final v = values[j];
        if (v.isEmpty) continue;
        if ((lines[i].translation ?? '').isEmpty) {
          lines[i].translation = v;
          changed = true;
        }
      }
    } else {
      final idx = p.lineIndices;
      for (var j = 0; j < values.length && j < idx.length; j++) {
        final i = idx[j];
        if (i < 0 || i >= lines.length) continue; // 越界行丢弃，不中断整批
        final v = values[j];
        if (v.isEmpty) continue;
        if ((lines[i].translation ?? '').isEmpty) {
          lines[i].translation = v;
          changed = true;
        }
      }
    }
    if (changed) setState(() {});
    // 不动滚动位置：_scrollTo 只由当前行号变化触发，插入译文后
    // 各行高度估算（_estimateLineHeight 含译文分支）在下次定位时自然生效。
  }

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
      _currentIndex = _findCurrentLine(_posMs);
      _boundLyric = widget.lyric;
      _boundSongHash = widget.songHash;
    }
  }

  @override
  void dispose() {
    // V400-A-03：与 initState 的订阅对称取消（原则 20）
    _patchSub?.cancel();
    _patchSub = null;
    _scroll.dispose();
    super.dispose();
  }

  int get _posMs => widget.position.inMilliseconds;

  /// F4-33（审查②-B，P2）：offset 已在 [KrcParser.parse] 内统一叠加到
  /// startMs/wordStartMs（正值=歌词提前）。这里若再加一次会双重平移，
  /// 带 offset 的歌词整首与音频错开。
  void _scrollTo(int index, {bool jump = false}) {
    if (!_scroll.hasClients || index < 0) return;
    // F4-34（审查②-B，P1）：旧实现用固定 64px × 行号，忽略 120px 垂直 padding
    // 与行高浮动（双语行更高），偏差随行号线性累积，唱到后半段当前行跑到屏外。
    // 改为「按行估算高度 + 扣除顶部 padding + 让当前行居中」。
    final lines = widget.lyric.lines;
    final viewport = _scroll.position.viewportDimension;
    var offset = 0.0;
    final upper = index < lines.length ? index : lines.length;
    for (var i = 0; i < upper; i++) {
      offset += _estimateLineHeight(lines[i]);
    }
    offset += _estimateLineHeight(
            index < lines.length ? lines[index] : lines.last) /
        2;
    final target = (offset - viewport / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
  }

  /// 单行高度估算：基础行高 + 译文行（双语模式且该行有译文时）。
  ///
  /// 估算是刻意的（第 24 条：不得在每帧路径做真实布局测量），
  /// 但必须把「是否有译文」这一最显著的变量纳入，否则双语模式整体偏移。
  double _estimateLineHeight(KrcLine line) {
    final hasTranslation = widget.mode == LyricDisplayMode.bilingual &&
        (line.translation ?? '').isNotEmpty;
    return hasTranslation ? 76 : _itemExtentApprox;
  }

  @override
  Widget build(BuildContext context) {
    final posMs = _posMs;
    final lines = widget.lyric.lines;
    if (lines.isEmpty) {
      // F4-35（审查②-B，P2）：无歌词时旧实现渲染 0 项列表，用户只看到一片空白，
      // 无法区分「纯音乐/解密失败/加载中」。
      // V34-UI-07a（修复②，P2）：硬编码中文「暂无歌词」改走 l10n，并补
      // 「怎么会有内容」的引导（易用性：任务流 5；第 30 条）。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            context.l10n.lyricEmptyGuide,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    final index = _findCurrentLine(posMs);

    // F4-36（审查②-B，P2）：旧实现在 build 中直接改 `_currentIndex` 并靠
    // postFrame setState 触发重建——状态在构建期间被改写，快速 seek 时会
    // 叠加多个回调。改为「只在行号真正变化时排一次回调」，
    // 并用 _pendingBuild 保证同一帧只排入一个（第 24 条：build 必须是纯的）。
    if (index != _currentIndex && !_pendingRebuild) {
      _pendingRebuild = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingRebuild = false;
        if (!mounted) return;
        setState(() => _currentIndex = index);
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
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final line = lines[i];
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

  /// 本次 build 是否已排入「行号变化」回调（防止快速 seek 叠加 setState）
  bool _pendingRebuild = false;

  int _findCurrentLine(int posMs) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return -1;
    var lo = 0, hi = lines.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
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
                  // V400-A-03：译文 14 → 12，与原文 16/17 层次分明
                  fontSize: 12,
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
                  // V400-A-03：纯译文模式同步降到 12（原 titleMedium 默认更大）
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOriginal(ThemeData theme, Color primary) {
    if (line.words.isEmpty) {
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
