/// 全屏播放页（V39 完全重写）。
///
/// 分区：错误横幅 → 顶栏 → 封面/歌词切换区 → 歌曲信息 → 功能入口
/// → 进度条 → 控制区。四态明确分离：
/// 引擎失败 / 未播放空态（含返回首页动作）/ 加载中 / 正常。
///
/// 状态单一来源（第 5 条）：只 watch player_provider.dart 已有 provider；
/// 页面不自行构造 Repository、不触网。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/image/app_image_cache.dart';
import '../../../core/providers.dart' show lyricRepositoryProvider;
import '../../../core/theme/settings_provider.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../l10n/l10n.dart';
import '../../lyric/data/krc_parser.dart';
import '../../lyric/presentation/lyric_view.dart';
import '../../download/presentation/download_sheet.dart';
import '../../mv/mv_provider.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../playlist/presentation/add_to_playlist_sheet.dart';
import '../data/models.dart';
import '../player_provider.dart';
import 'queue_sheet.dart';

/// 歌词 Provider（当前歌曲）。
///
/// 失败语义（第 16 条）：`error` 字段区分「无候选/解析失败」与正常空，
/// 不与加载中混为一谈。
final currentLyricProvider = FutureProvider.autoDispose<
    ({KrcLyric? lyric, String? error})>((ref) async {
  final song = ref.watch(currentSongProvider).valueOrNull;
  if (song == null) return (lyric: null, error: null);
  final repo = ref.watch(lyricRepositoryProvider);
  final candidate = await repo.findCandidate(
    hash: song.hash,
    albumAudioId: song.albumAudioId,
    durationSec: song.duration.inSeconds,
  );
  if (candidate == null) return (lyric: null, error: '暂无歌词');
  final lyric = await repo.fetchLyric(candidate);
  if (lyric == null) return (lyric: null, error: '歌词解析失败');
  // 翻译跟随界面语言。取语言用 platformDispatcher 而非 BuildContext：
  // Provider 是全局对象，没有 Element（第 24 条：Provider 不触碰组件树）。
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  final targetLang = locale.countryCode != null
      ? '${locale.languageCode}_${locale.countryCode}'
      : (locale.languageCode == 'zh' ? 'zh_CN' : locale.languageCode);
  final translated =
      await repo.ensureTranslation(lyric, candidate.id, targetLang);
  return (lyric: translated, error: null);
});

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 全屏播放页。
class FullPlayerPage extends ConsumerWidget {
  const FullPlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).valueOrNull;
    // 依据 audio_handler.ensureEngineReady：引擎初始化失败时 engineError
    // 非空（audio_handler.dart:60），此态与「未播放」必须区分（第 16 条）。
    final engineError = ref.watch(audioHandlerProvider).engineError;

    return Scaffold(
      body: SafeArea(
        // 大字号/窄屏防溢出（第 24/26 条）：整页纵向弹性布局，
        // 封面/歌词区用 Expanded 吃掉剩余空间，其余分区自适应高度。
        child: Column(
          children: [
            if (engineError != null)
              _EngineErrorBanner(message: engineError),
            _PlayerTopBar(song: song),
            Expanded(
              child: engineError != null && song == null
                  ? _EngineFailureView(message: engineError)
                  : song == null
                      ? _EmptyPlayerView()
                      : _PlayerContent(song: song),
            ),
          ],
        ),
      ),
    );
  }
}

/// 引擎错误横幅（V37-PLAY-03 契约保留：失败必须常驻可见，第 9 条）。
class _EngineErrorBanner extends StatelessWidget {
  const _EngineErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message,
                    style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 引擎初始化失败且无歌曲：给出「重试播放」出口。
///
/// 重试动作即「尝试播放/拉起引擎」——PlayerController.togglePlay 内部
/// 会先 ensureEngineReady()（player_provider.dart:196），失败再次
/// 横幅可见，成功则进入正常态。这是失败态与空态的核心区别。
class _EngineFailureView extends ConsumerWidget {
  const _EngineFailureView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 56, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(playerControllerProvider).togglePlay(),
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未播放空态：明确告知 + 去首页动作。
class _EmptyPlayerView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.music_off_rounded,
      message: context.l10n.notPlaying,
      actionLabel: context.l10n.goHome,
      onAction: () => context.go('/home'),
    );
  }
}

/// 正常播放态：封面/歌词 + 信息 + 入口 + 进度 + 控制。
class _PlayerContent extends ConsumerWidget {
  const _PlayerContent({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Expanded(child: _CoverOrLyric(song: song)),
        _SongInfoHeader(song: song),
        _EntryButtonsRow(song: song),
        const _ProgressBar(),
        const _ControlBar(),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// 顶部栏：收起 + 标题 + 更多菜单（下载/收藏到歌单/队列）。
class _PlayerTopBar extends ConsumerWidget {
  const _PlayerTopBar({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: context.l10n.closePlayer,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: Text(context.l10n.nowPlaying,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        PopupMenuButton<String>(
          tooltip: context.l10n.moreActions,
          onSelected: (v) {
            final s = song;
            if (v == 'download' && s != null) {
              showDownloadSheet(context, s);
            } else if (v == 'addToPlaylist' && s != null) {
              showAddToPlaylistSheet(
                context,
                TrackRef(
                  name: s.name,
                  hash: s.hash,
                  albumId: s.albumId,
                  albumAudioId: s.albumAudioId,
                ),
              );
            } else if (v == 'queue') {
              showQueueSheet(context);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'addToPlaylist',
              enabled: song != null,
              child: Row(children: [
                Icon(Icons.playlist_add_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(context.l10n.addToPlaylist),
              ]),
            ),
            PopupMenuItem<String>(
              value: 'download',
              enabled: song != null,
              child: Row(children: [
                Icon(Icons.download_outlined,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(context.l10n.download),
              ]),
            ),
            PopupMenuItem<String>(
              value: 'queue',
              child: Row(children: [
                Icon(Icons.queue_music_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(context.l10n.playQueue),
              ]),
            ),
          ],
        ),
      ],
    );
  }
}

/// 歌名 / 歌手 / 试听角标 / 实际音质。大字号窄屏用 LayoutBuilder 降级。
class _SongInfoHeader extends ConsumerWidget {
  const _SongInfoHeader({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quality = ref.watch(actualQualityProvider).valueOrNull;
    final isPreview = ref.watch(previewProvider).valueOrNull ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      child: LayoutBuilder(builder: (context, constraints) {
        // 大字号（可访问性字号 ≥1.3 倍）时标题允许两行，不再截断
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final largeText = scale > 1.3 || constraints.maxWidth < 320;
        return Column(
          children: [
            Text(
              song.name,
              maxLines: largeText ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isPreview) ...[
                  _Badge(
                    text: context.l10n.previewOnly,
                    foreground: theme.colorScheme.onTertiaryContainer,
                    background: theme.colorScheme.tertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                ],
                if (quality != null) ...[
                  Flexible(
                    child: _QualityBadge(quality: quality.label),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.foreground,
    required this.background,
  });

  final String text;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: theme.textTheme.labelSmall?.copyWith(color: foreground)),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality});

  final String quality;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(quality,
          style:
              theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// 功能入口行：评论 + MV + 队列。
///
/// V39-PLAYER-03（P1，契约保留）：评论入口必须无条件可达——只要歌曲有
/// album_audio_id 就渲染，绝不与 MV 有无绑定。路由契约：
/// app_router.dart:70 `GoRoute('/comments/:type/:id')` → CommentsPage。
class _EntryButtonsRow extends ConsumerWidget {
  const _EntryButtonsRow({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // V39-CI-1：入口行持有的是 song，albumAudioId 需从 song 取（代理重写
    // 时误用了局部变量名）；抽成局部常量保持后续分支一致。
    final albumAudioId = song.albumAudioId;
    final mvAsync = albumAudioId.isEmpty
        ? null
        : ref.watch(songMvProvider(albumAudioId));
    final mv = mvAsync?.value;
    final hasMv = mv != null && mv.videoId.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
      child: Row(
        children: [
          // 评论入口：只要能定位资源就显示；无 album_audio_id 时降级为
          // 禁用态（保证入口可发现，不静默消失）。
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.comment_outlined, size: 18),
              label: Text(context.l10n.comments,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: albumAudioId.isEmpty
                  ? null
                  : () => context.push(
                      '/comments/song/${Uri.encodeComponent(albumAudioId)}'),
            ),
          ),
          if (hasMv) ...[
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.movie_outlined, size: 18),
                label: Text(context.l10n.playMv,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () {
                  // /video/url 只认视频 hash，path 用 hash；
                  // videoId 走 query 供清晰度列表使用（mv_repository 契约）
                  final hash = mv.bestHash ?? mv.sdHash ?? '';
                  final title =
                      mv.name.isNotEmpty ? mv.name : song.name;
                  final artist =
                      mv.artist.isNotEmpty ? mv.artist : song.artist;
                  context.push(
                    '/mv/${Uri.encodeComponent(hash.isEmpty ? mv.videoId : hash)}'
                    '?videoId=${Uri.encodeComponent(mv.videoId)}'
                    '&title=${Uri.encodeComponent(title)}'
                    '&artist=${Uri.encodeComponent(artist)}',
                  );
                },
              ),
            ),
          ],
          const SizedBox(width: 12),
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.queue_music_rounded, size: 20),
              tooltip: context.l10n.playQueue,
              onPressed: () => showQueueSheet(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面 / 歌词切换。
class _CoverOrLyric extends ConsumerStatefulWidget {
  const _CoverOrLyric({required this.song});

  final Song song;

  @override
  ConsumerState<_CoverOrLyric> createState() => _CoverOrLyricState();
}

class _CoverOrLyricState extends ConsumerState<_CoverOrLyric>
    with SingleTickerProviderStateMixin {
  bool _showLyric = false;

  // V39-PLAYER-04（第 20 条资源对称）：控制器与曲线在 State 创建一次、
  // dispose 对称释放（继承旧实现的掉帧修复，不复制旧结构）。
  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final CurvedAnimation _fadeCurve =
      CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCurve.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _toggleLyric() {
    setState(() => _showLyric = !_showLyric);
    if (_showLyric) _fadeCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // V39-CI-2：build 内使用 theme 前必须先声明（代理重写漏项）。
    final theme = Theme.of(context);
    final lyricAsync = ref.watch(currentLyricProvider);
    final lyricMode = ref.watch(lyricModeProvider);
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final lyric = lyricAsync.value?.lyric;

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _showLyric && lyric != null
              ? FadeTransition(
                  opacity: _fadeCurve,
                  child: ClipRect(
                    key: const ValueKey('lyric'),
                    child: LyricView(
                      lyric: lyric,
                      position: position,
                      mode: lyricMode,
                      // onTapLine 的参数单位是毫秒（lyric_view.dart KrcLine.startMs）
                      onTapLine: (ms) => ref
                          .read(playerControllerProvider)
                          .seekTo(Duration(milliseconds: ms)),
                    ),
                  ),
                )
              : _CoverView(song: widget.song),
        ),
        // 明确的切换入口（不只靠「点封面」隐藏手势）
        Positioned(
          right: 16,
          bottom: 8,
          child: TextButton.icon(
            onPressed: _toggleLyric,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              minimumSize: const Size(48, 40),
            ),
            icon: Icon(
              _showLyric ? Icons.album_outlined : Icons.lyrics_outlined,
              size: 18,
            ),
            label: Text(_showLyric
                ? context.l10n.showCover
                : context.l10n.showLyrics),
          ),
        ),
      ],
    );
  }
}

class _CoverView extends StatelessWidget {
  const _CoverView({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('cover'),
      child: Hero(
        tag: 'album-art',
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: 1,
            child: song.cover.isNotEmpty
                ? CachedNetworkImage(
                    cacheManager: AppImageCache.instance,
                    imageUrl: song.cover,
                    fit: BoxFit.cover,
                    // 封面约屏宽（减边距）× dpr，限制解码分辨率
                    memCacheWidth:
                        (MediaQuery.sizeOf(context).width *
                                MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    errorWidget: (_, __, ___) => const _CoverPlaceholder(),
                  )
                : const _CoverPlaceholder(),
          ),
        ),
      ),
    );
  }
}

/// 进度条：拖动期间用本地值，松手才 seek（契约保留，防 position 流回拉）。
class _ProgressBar extends ConsumerStatefulWidget {
  const _ProgressBar();

  @override
  ConsumerState<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends ConsumerState<_ProgressBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    // V39-CI-2：同上，进度条分支使用 theme 需声明。
    final theme = Theme.of(context);
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final buffered =
        ref.watch(bufferedPositionProvider).valueOrNull ?? Duration.zero;
    final total = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final controller = ref.read(playerControllerProvider);

    final maxMs =
        total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0;
    final posMs = position.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();
    final bufMs = buffered.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              inactiveTrackColor:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
              secondaryActiveTrackColor:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            child: Slider(
              // 夹取上界防切歌瞬间断言
              value: (_dragMs ?? posMs).clamp(0.0, maxMs),
              max: maxMs,
              secondaryTrackValue: bufMs,
              onChangeStart: (v) => setState(() => _dragMs = v),
              onChanged: (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                // 第 20 条：异步/延迟回调先确认对象仍存活
                if (mounted) {
                  controller.seekTo(Duration(milliseconds: v.round()));
                  setState(() => _dragMs = null);
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(position), style: theme.textTheme.labelSmall),
                Text(_fmt(total), style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 控制区：随机 / 上一首 / 播放暂停 / 下一首 / 循环。
/// 大字号窄屏用 LayoutBuilder 缩小主按钮，禁止固定 72px 硬溢出。
class _ControlBar extends ConsumerWidget {
  const _ControlBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playerControllerProvider);
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffle = ref.watch(shuffleProvider).valueOrNull ?? false;
    final loopMode = ref.watch(repeatProvider).valueOrNull ?? LoopMode.off;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(builder: (context, constraints) {
        final fabSize = constraints.maxWidth < 360 ? 60.0 : 72.0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              isSelected: shuffle,
              icon: const Icon(Icons.shuffle),
              selectedIcon: const Icon(Icons.shuffle),
              tooltip: context.l10n.shuffle,
              onPressed: controller.toggleShuffle,
            ),
            IconButton(
              iconSize: 36,
              icon: const Icon(Icons.skip_previous_rounded),
              tooltip: context.l10n.previous,
              onPressed: controller.prev,
            ),
            SizedBox(
              width: fabSize,
              height: fabSize,
              child: FloatingActionButton(
                heroTag: 'play-pause-fab',
                tooltip: isPlaying ? context.l10n.pause : context.l10n.play,
                onPressed: controller.togglePlay,
                child: Icon(
                  isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: fabSize * 0.55,
                ),
              ),
            ),
            IconButton(
              iconSize: 36,
              icon: const Icon(Icons.skip_next_rounded),
              tooltip: context.l10n.next,
              onPressed: controller.next,
            ),
            IconButton(
              isSelected: loopMode != LoopMode.off,
              icon: Icon(
                switch (loopMode) {
                  LoopMode.one => Icons.repeat_one,
                  _ => Icons.repeat,
                },
              ),
              selectedIcon: Icon(
                switch (loopMode) {
                  LoopMode.one => Icons.repeat_one,
                  _ => Icons.repeat,
                },
              ),
              tooltip: loopMode == LoopMode.one
                  ? context.l10n.repeatOne
                  : context.l10n.repeat,
              onPressed: controller.cycleRepeatMode,
            ),
          ],
        );
      }),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.music_note_rounded,
            size: 96, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
