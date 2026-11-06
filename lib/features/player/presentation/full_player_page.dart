import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/image/app_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/providers.dart' show lyricRepositoryProvider;
import '../../../core/theme/settings_provider.dart';
import '../../../l10n/l10n.dart';
import '../../lyric/data/krc_parser.dart';
import '../../lyric/presentation/lyric_view.dart';
import '../../mv/mv_provider.dart';
import '../../download/presentation/download_sheet.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../playlist/presentation/add_to_playlist_sheet.dart';
import '../data/models.dart';
import '../player_provider.dart';
import 'queue_sheet.dart';

/// 歌词 Provider（当前歌曲）
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
  // 翻译（跟随界面语言）
  final locale = ref.watch(localeProvider);
  final targetLang = locale != null
      ? '${locale.languageCode}${locale.countryCode != null ? '_${locale.countryCode}' : ''}'
      : 'zh_CN';
  final translated = await repo.ensureTranslation(lyric, candidate.id, targetLang);
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
    final quality = ref.watch(actualQualityProvider).valueOrNull;
    final isPreview = ref.watch(previewProvider).valueOrNull ?? false;
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffle = ref.watch(shuffleProvider).valueOrNull ?? false;
    final loopMode = ref.watch(repeatProvider).valueOrNull ?? LoopMode.off;
    final controller = ref.read(playerControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶部栏：左侧收起、居中标题、右侧「更多」菜单（下载/队列收进菜单，
            // 避免行内排一排 IconButton）。
            Row(
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
                    if (v == 'download' && song != null) {
                      showDownloadSheet(context, song);
                    } else if (v == 'addToPlaylist' && song != null) {
                      // V34-UI-01：收藏到歌单
                      showAddToPlaylistSheet(
                        context,
                        TrackRef(
                          name: song.name,
                          hash: song.hash,
                          albumId: song.albumId,
                          albumAudioId: song.albumAudioId,
                        ),
                      );
                    } else if (v == 'queue') {
                      showQueueSheet(context);
                    }
                  },
                  itemBuilder: (context) => [
                  // V34-UI-01：收藏到歌单入口（激活 addToPlaylist 死键，
                  // 打通「搜索→播放→收藏」任务流）
                  PopupMenuItem<String>(
                    value: 'addToPlaylist',
                    enabled: song != null,
                    child: Row(
                      children: [
                        Icon(Icons.playlist_add_rounded,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Text(context.l10n.addToPlaylist),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'download',
                    enabled: song != null,
                      child: Row(
                        children: [
                          Icon(Icons.download_outlined,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Text(context.l10n.download),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'queue',
                      child: Row(
                        children: [
                          Icon(Icons.queue_music_rounded,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Text(context.l10n.playQueue),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            // MV 入口：首次构建时按 album_audio_id 查询该歌是否有 MV
            _MvEntry(song: song),
            // 封面 / 歌词切换
            Expanded(
              child: _CoverOrLyric(song: song),
            ),
            const SizedBox(height: 24),
            // 歌名 / 歌手 / 音质
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  Text(
                    song?.name ?? context.l10n.notPlaying,
                    maxLines: 1,
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            context.l10n.previewOnly,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onTertiaryContainer),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (quality != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: theme.colorScheme.primary, width: 1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(quality.label,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.primary)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          song?.artist ?? context.l10n.unknownArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // 进度条
            const _ProgressBar(),
            const SizedBox(height: 4),
            // 控制按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 状态切换用 IconButton 的 isSelected 语义（选中态用主题色）
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
                    width: 72,
                    height: 72,
                    child: FloatingActionButton(
                      heroTag: 'play-pause-fab',
                      tooltip: isPlaying ? context.l10n.pause : context.l10n.play,
                      onPressed: controller.togglePlay,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 40,
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
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// 播放页次级入口：评论（始终显示）+ MV（仅有 MV 时显示）。
///
/// UI-04（审查②）：此前评论按钮在「无 MV」early return 之后，
/// 绝大多数歌曲的播放页完全不显示评论入口。
class _MvEntry extends ConsumerWidget {
  const _MvEntry({this.song});
  final Song? song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumAudioId = song?.albumAudioId ?? '';
    if (albumAudioId.isEmpty) return const SizedBox.shrink();

    final mvAsync = ref.watch(songMvProvider(albumAudioId));
    final mv = mvAsync.value;
    final hasMv = mv != null && mv.videoId.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          // 评论入口：始终渲染，不再被 MV 判定连带隐藏
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.comment_outlined, size: 18),
            label: Text(context.l10n.comments),
            onPressed: () => context.push(
                '/comments/song/${Uri.encodeComponent(albumAudioId)}'),
          ),
          if (hasMv) ...[
            const SizedBox(width: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.movie_outlined, size: 18),
              label: Text(context.l10n.playMv),
              onPressed: () {
                final title = mv.name.isNotEmpty ? mv.name : (song?.name ?? '');
                final artist =
                    mv.artist.isNotEmpty ? mv.artist : (song?.artist ?? '');
                // /video/url 只认视频 hash，故 path 用 hash；
                // videoId 走 query 供清晰度列表使用
                final hash = mv.bestHash ?? mv.sdHash ?? '';
                context.push(
                  '/mv/${Uri.encodeComponent(hash.isEmpty ? mv.videoId : hash)}'
                  '?videoId=${Uri.encodeComponent(mv.videoId)}'
                  '&title=${Uri.encodeComponent(title)}'
                  '&artist=${Uri.encodeComponent(artist)}',
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _CoverOrLyric extends ConsumerStatefulWidget {
  const _CoverOrLyric({this.song});
  final Song? song;

  @override
  ConsumerState<_CoverOrLyric> createState() => _CoverOrLyricState();
}

class _CoverOrLyricState extends ConsumerState<_CoverOrLyric>
    with SingleTickerProviderStateMixin {
  bool _showLyric = false;
  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  /// R-01（第6批②，P2）：CurvedAnimation 在 State 创建一次并随 State 释放
  ///（第 20 条资源对称）。此前在 build 内每 tick 新建一个并挂到同一
  /// controller 上（歌词模式 build 随进度每秒执行多次），监听器无上限
  /// 累积 → 歌词页停留十几分钟后掉帧。
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

  @override
  Widget build(BuildContext context) {
    final lyricMode = ref.watch(lyricModeProvider);
    final lyricAsync = ref.watch(currentLyricProvider);
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () {
        setState(() => _showLyric = !_showLyric);
        if (_showLyric) _fadeCtrl.forward(from: 0);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _showLyric && lyricAsync.value?.lyric != null
                ? FadeTransition(
                    opacity: _fadeCurve,
                    child: ClipRect(
                      key: const ValueKey('lyric'),
                      child: LyricView(
                        lyric: lyricAsync.value!.lyric!,
                        position: position,
                        mode: lyricMode,
                        onTapLine: (ms) => ref
                            .read(playerControllerProvider)
                            .seekTo(Duration(milliseconds: ms)),
                      ),
                    ),
                  )
                : _buildCover(context),
          ),
          // 明确的切换入口（不只靠「点封面」这一隐藏手势）
          Positioned(
            right: 16,
            bottom: 8,
            child: TextButton.icon(
              onPressed: () {
                setState(() => _showLyric = !_showLyric);
                if (_showLyric) _fadeCtrl.forward(from: 0);
              },
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
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    final song = widget.song;
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
            child: song != null && song.cover.isNotEmpty
                ? CachedNetworkImage(
                    cacheManager: AppImageCache.instance,
                    imageUrl: song.cover,
                    fit: BoxFit.cover,
                    // 封面约屏宽（减去边距）× dpr，限制解码分辨率
                    memCacheWidth: (MediaQuery.sizeOf(context).width *
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

class _ProgressBar extends ConsumerStatefulWidget {
  const _ProgressBar();

  @override
  ConsumerState<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends ConsumerState<_ProgressBar> {
  /// UI-05（审查②）：拖动期间的本地值，避免 position 流把滑块拉回旧位置
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final buffered =
        ref.watch(bufferedPositionProvider).valueOrNull ?? Duration.zero;
    final total =
        ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final controller = ref.read(playerControllerProvider);
    final theme = Theme.of(context);

    final maxMs =
        total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0;
    final posMs = position.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();
    final bufMs = buffered.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              // 缓冲颜色
              inactiveTrackColor:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
              secondaryActiveTrackColor:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            child: Slider(
              // 拖动中显示本地值，松手才 seek（UI-05）；
              // V3-08（复查）：夹取上界，切歌/时长回填时防 Slider 断言
              value: (_dragMs ?? posMs).clamp(0.0, maxMs),
              max: maxMs,
              secondaryTrackValue: bufMs,
              onChangeStart: (v) => setState(() => _dragMs = v),
              onChanged: (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                controller.seekTo(Duration(milliseconds: v.round()));
                setState(() => _dragMs = null);
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

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
          child: Icon(Icons.music_note_rounded,
              size: 96,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}
