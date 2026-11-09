/// 全屏播放页（V39 完全重写；v5.3-R2 P4 布局重排）。
///
/// 分区：网络阶段条 → 错误横幅 → 顶栏 → 封面/歌词切换区 → 歌曲信息（三层）
/// → 功能入口（语义唯一）→ 进度条 → 控制区。四态明确分离：
/// 引擎失败 / 未播放空态（含返回首页动作）/ 加载中（阶段条可见）/ 正常。
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
import '../../../app/di.dart' show lyricRepositoryProvider;
import '../../../core/theme/settings_provider.dart'
    show LyricDisplayMode, lyricModeProvider;
import '../../../core/domain/quality.dart' show AudioQuality;
import '../../settings/presentation/settings_providers.dart'
    show defaultQualityProvider;
import '../../../core/widgets/empty_state.dart';
import '../../../l10n/l10n.dart';
import '../../download/presentation/download_sheet.dart';
import '../../lyric/data/krc_parser.dart';
import '../../lyric/presentation/lyric_view.dart';
import '../../mv/mv_provider.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../playlist/presentation/add_to_playlist_sheet.dart';
import '../../../core/domain/song.dart';
import '../player_provider.dart';
import 'network_phase_indicator.dart';
import 'queue_sheet.dart';

/// 歌词 Provider（当前歌曲）。
///
/// 失败语义（第 16 条）：`error` 字段区分「无候选/解析失败」与正常空，
/// 不与加载中混为一谈。
final currentLyricProvider =
    FutureProvider.autoDispose<
      ({KrcLyric? lyric, String? error, String? lyricId, String? songHash})
    >((ref) async {
      final song = ref.watch(currentSongProvider).valueOrNull;
      if (song == null)
        return (lyric: null, error: null, lyricId: null, songHash: null);
      final repo = ref.watch(lyricRepositoryProvider);
      // V400-A-04：记录本代歌词所属歌曲 hash，后续异步写入前做世代校验
      // （原则 18：切歌后旧结果不得污染新歌曲的 UI）。
      final songHash = song.hash;
      final candidate = await repo.findCandidate(
        hash: song.hash,
        albumAudioId: song.albumAudioId,
        durationSec: song.duration.inSeconds,
      );
      if (candidate == null) {
        return (lyric: null, error: '暂无歌词', lyricId: null, songHash: songHash);
      }
      final lyric = await repo.fetchLyric(candidate);
      if (lyric == null) {
        return (
          lyric: null,
          error: '歌词解析失败',
          lyricId: null,
          songHash: songHash,
        );
      }
      // V400-A-04：candidate.id 透传给 LyricView，用于匹配翻译补丁的
      // patch.lyricId（冻结契约 LyricTranslationStream，B 按 candidate.id emit）。
      final lyricId = candidate.id;
      // 翻译跟随界面语言。取语言用 platformDispatcher 而非 BuildContext：
      // Provider 是全局对象，没有 Element（第 24 条：Provider 不触碰组件树）。
      final locale = WidgetsBinding.instance.platformDispatcher.locale;
      final targetLang = locale.countryCode != null
          ? '${locale.languageCode}_${locale.countryCode}'
          : (locale.languageCode == 'zh' ? 'zh_CN' : locale.languageCode);
      // V399-A3（P1，非必要不翻译）：纯原文模式（original）不翻译——
      // 既省翻译 API 配额，也避免无谓网络等待。双语/纯译文模式才补译文。
      if (ref.watch(lyricModeProvider) == LyricDisplayMode.original) {
        return (
          lyric: lyric,
          error: null,
          lyricId: lyricId,
          songHash: songHash,
        );
      }
      final translated = await repo.ensureTranslation(
        lyric,
        candidate.id,
        targetLang,
        songHash: song.hash,
      );
      // 原则 18（世代校验）：翻译 await 期间用户可能已切歌——当前歌曲
      // 与发起时不一致则本次结果作废（不 yield 旧歌译文/歌词）。
      final now = ref.read(currentSongProvider).valueOrNull;
      if (now == null || now.hash != songHash) {
        return (lyric: null, error: null, lyricId: null, songHash: null);
      }
      return (
        lyric: translated,
        error: null,
        lyricId: lyricId,
        songHash: songHash,
      );
    });

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 歌词/封面切换状态（v5.3-R2 P4，修 C-38）。
///
/// 从 _CoverOrLyricState 的私有 bool 提升为 provider：入口行按钮与
/// 封面区视图共用同一状态（语义唯一、两处入口同步），切歌时保留用户偏好。
/// 页面级 UI 状态，非全局业务状态，autoDispose 随页面释放。
final lyricVisibleProvider =
    StateNotifierProvider.autoDispose<LyricVisibleController, bool>(
      (ref) => LyricVisibleController(),
    );

class LyricVisibleController extends StateNotifier<bool> {
  LyricVisibleController() : super(false);

  void toggle() => state = !state;
}

/// 全屏播放页（V39 完全重写；v5.3-R2 P4 布局重排）。
class FullPlayerPage extends ConsumerWidget {
  const FullPlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // v5.3 P1：三处播放 UI 共用同一 PlayerState 映射；在这里固定「订阅点」，
    // 保证 queue_sheet / mini_player / 全屏页的离散态同步（A-16）。
    final playerState = ref.watch(playerStateProvider).valueOrNull;
    final song = playerState?.currentSong;
    // 引擎错误是 PlayerSnapshot 的一部分（成功后由 reducer 清除，A-09）。
    final engineError = playerState?.engineError;
    // v5.3-R2（修 C-34 UI 侧）：播放链路错误（resolveUrl 超时/权益不足等）
    // 最近一条也渲染为横幅——有歌曲残留时此前完全没有失败可见面。
    // engineError 优先；横幅语义「发生了什么 + 下一步（重试按钮见下方横幅）」。
    // audio_handler 不动（范围硬约束），只读 playerErrorProvider 现有流。
    final playerError = ref.watch(playerErrorProvider).valueOrNull;
    final banner = engineError ?? playerError;

    return Scaffold(
      body: SafeArea(
        // 大字号/窄屏防溢出（第 24/26 条）：整页纵向弹性布局，
        // 封面/歌词区用 Expanded 吃掉剩余空间，其余分区自适应高度。
        child: Column(
          children: [
            // v5.3 P2：网络阶段指示器（>500ms 的解析/缓冲必须可见，原则 34）。
            const NetworkPhaseIndicator(),
            if (banner != null) _EngineErrorBanner(message: banner),
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

/// 引擎/播放错误横幅（V37-PLAY-03 契约保留：失败必须常驻可见，第 9 条）。
///
/// v5.3-R2（修 C-35 横幅不可操作）：追加「重试」按钮——横幅 = 发生了什么
///（message）+ 下一步（点击重试，togglePlay 内部会先 ensureEngineReady）。
/// message 为 null 时不渲染（空态契约上移到调用方）。
class _EngineErrorBanner extends ConsumerWidget {
  const _EngineErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                // ≥48dp 触控（质量要求 3）
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  visualDensity: VisualDensity.compact,
                  foregroundColor: theme.colorScheme.onErrorContainer,
                ),
                onPressed: () => ref.read(playerControllerProvider).retry(),
                child: Text(context.l10n.retry),
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
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => ref.read(playerControllerProvider).retry(),
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
///
/// v5.3-R2（修 C-40）：固定分区包滚动兜底——正常竖屏下 Expanded 封面区
/// 行为不变（LayoutBuilder maxHeight 足够时仍用 Column+Expanded）；高度
/// 不足（横屏/大字号 2 行歌名）时切换为 SingleChildScrollView，固定区
/// 总高可超出视口而不再 RenderFlex overflow / 封面被压没。
class _PlayerContent extends ConsumerWidget {
  const _PlayerContent({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fixed = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SongInfoHeader(song: song),
        _EntryButtonsRow(song: song),
        const _ProgressBar(),
        const _ControlBar(),
        const SizedBox(height: 12),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 经验阈值：固定区约 320dp（信息 90 + 入口 58 + 进度 66 + 控制 92），
        // 剩余高度不足以展示封面（<180dp）时进入滚动模式。
        final canFitCover = constraints.maxHeight > 500;
        if (canFitCover) {
          return Column(
            children: [
              Expanded(child: _CoverOrLyric(song: song)),
              fixed,
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(height: 260, child: _CoverOrLyric(song: song)),
              fixed,
            ],
          ),
        );
      },
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
        const Spacer(),
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
            } else if (v == 'queue' && s != null) {
              showQueueSheet(context);
            } else if (v == 'audioEffect') {
              // v5.5：音质/音效设置从设置页深层弹层收进「更多」——
              // 14 档（含蝰蛇/魔法）可滚动选择，选中即作用于下一首播放。
              _showAudioQualitySheet(context, ref);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'addToPlaylist',
              enabled: song != null,
              child: Row(
                children: [
                  Icon(
                    Icons.playlist_add_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                  Icon(
                    Icons.download_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(context.l10n.download),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'audioEffect',
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(context.l10n.audioQualityEffects),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'queue',
              enabled: song != null, // v5.3-R2（修 C-45）：空态下队列不可点
              child: Row(
                children: [
                  Icon(
                    Icons.queue_music_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(context.l10n.playQueue),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// v5.5：音质/音效设置弹层（14 档，可滚动；play 页「更多」入口）。
///
/// 分组：标准音质 5 档 / 蝰蛇音源 3 档 / 魔法音效 6 档。选中写入
/// `defaultQualityProvider`（Hive 持久化），下一首播放即按新档解析；
/// 当前曲不中断重解析（避免「切音效卡一下」）。
void _showAudioQualitySheet(BuildContext context, WidgetRef ref) {
  final current = ref.read(defaultQualityProvider);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Text(
                    context.l10n.audioQualityEffects,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: MaterialLocalizations.of(ctx).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final q in AudioQuality.values)
                    RadioListTile<String>(
                      value: q.value,
                      groupValue: current,
                      dense: true,
                      title: Text(q.label),
                      subtitle: q.isSpecial
                          ? Text(
                              q.isMagic
                                  ? context.l10n.magicEffectHint
                                  : context.l10n.viperEffectHint,
                            )
                          : null,
                      onChanged: (v) async {
                        if (v == null) return;
                        await ref.read(defaultQualityProvider.notifier).set(v);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 歌名 / 歌手：两层信息层级（v5.5 用户口径：徽标文字移出播放页，
/// 音质/试听状态在「更多」菜单里，播放页只剩歌词文字与歌曲身份）。
///   L1 歌名：titleLarge，大字号/窄屏允许 2 行
///   L2 歌手：bodyMedium，独立一行（永远完整可读，不与徽标竞争）
///   L3 徽标行：试听 + 实际音质，独立 Row（无徽标时整行不占高度）
class _SongInfoHeader extends ConsumerWidget {
  const _SongInfoHeader({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 大字号（可访问性字号 ≥1.3 倍）时标题允许两行，不再截断
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final largeText = scale > 1.3 || constraints.maxWidth < 320;
          return Column(
            children: [
              // L1 歌名（大）
              Text(
                song.name,
                maxLines: largeText ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              // L2 歌手（中）：独立一行，不与徽标抢宽
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // v5.5：徽标文字从播放页移除（用户口径：按钮/非歌词文字清零）。
              // 试听与当前音质改在「更多」菜单里以图标状态呈现。
            ],
          );
        },
      ),
    );
  }
}

/// 功能入口行：评论 + MV（三态）+ 歌词切换。
///
/// v5.3-R2 P4 语义唯一化（PLAN 质量要求 3，修 C-37/C-38/C-42/C-43）：
///  - 「收藏到歌单」与「播放队列」收敛到顶栏「更多」菜单，入口行不再重复；
///  - 歌词切换从封面右下角 40dp 悬浮按钮迁入入口行（≥48dp、有 active 态），
///    与 _CoverOrLyric 的 _showLyric 状态共用 [lyricVisibleProvider]；
///  - 按钮高度 48dp，label maxLines 1 + ellipsis。
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
    final showLyric = ref.watch(lyricVisibleProvider);
    final theme = Theme.of(context);

    // v5.5 用户口径：播放页除歌词外**不出现任何按钮文字**，
    // 且按钮无边框——纯图标 + tooltip（长按可发现性），全部 ≥48dp。
    Widget entryButton({
      required IconData icon,
      required String semantic,
      required VoidCallback? onPressed,
      bool selected = false,
    }) {
      return Semantics(
        button: true,
        label: semantic,
        child: SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: Icon(icon, size: 22),
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            tooltip: semantic,
            onPressed: onPressed,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 4),
      child: Row(
        children: [
          // 评论入口：只要能定位资源就显示；无 album_audio_id 时降级为
          // 禁用态（保证入口可发现，不静默消失）。
          Expanded(
            child: entryButton(
              icon: Icons.comment_outlined,
              semantic: context.l10n.comments,
              onPressed: albumAudioId.isEmpty
                  ? null
                  : () => context.push(
                      '/comments/song/${Uri.encodeComponent(albumAudioId)}',
                    ),
            ),
          ),
          const SizedBox(width: 8),
          // 歌词切换入口（v5.3-R2：从封面右下角悬浮按钮迁入，语义唯一）。
          Expanded(
            child: entryButton(
              icon: showLyric ? Icons.album_outlined : Icons.lyrics_outlined,
              semantic: showLyric
                  ? context.l10n.showCover
                  : context.l10n.showLyrics,
              selected: showLyric,
              onPressed: () => ref.read(lyricVisibleProvider.notifier).toggle(),
            ),
          ),
          // v5.3-R2（修 C-43）：MV 按钮三态——loading 禁用占位（入口行宽度
          // 稳定不跳变）/ 无 MV 隐藏 / 有 MV 可点。不再「加载中整个按钮消失」。
          if (mvAsync != null || hasMv) ...[
            const SizedBox(width: 8),
            Expanded(
              child: entryButton(
                icon: Icons.movie_outlined,
                semantic: context.l10n.playMv,
                // loading（mvAsync 无值）时禁用占位，防止 3→4 列宽度跳变
                onPressed: !hasMv
                    ? null
                    : () {
                        // /video/url 只认视频 hash，path 用 hash；
                        // videoId 走 query 供清晰度列表使用（mv_repository 契约）
                        final hash = mv.bestHash ?? mv.sdHash ?? '';
                        final title = mv.name.isNotEmpty ? mv.name : song.name;
                        final artist = mv.artist.isNotEmpty
                            ? mv.artist
                            : song.artist;
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
  // v5.3-R2（修 C-38）：切换状态提升为 lyricVisibleProvider——入口行
  // 「歌词」按钮与本视图共用同一状态（此前悬浮按钮 40dp 且与封面重叠）。

  // V39-PLAYER-04（第 20 条资源对称）：控制器与曲线在 State 创建一次、
  // dispose 对称释放（继承旧实现的掉帧修复，不复制旧结构）。
  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final CurvedAnimation _fadeCurve = CurvedAnimation(
    parent: _fadeCtrl,
    curve: Curves.easeOutCubic,
  );

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
    // V39-CI-2：build 内使用 theme 前必须先声明（代理重写漏项）。
    final theme = Theme.of(context);
    final lyricAsync = ref.watch(currentLyricProvider);
    final lyricMode = ref.watch(lyricModeProvider);
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final lyric = lyricAsync.value?.lyric;
    // V400-A-04：歌词 id + 所属歌曲 hash 透传（匹配翻译补丁 / 世代校验）
    final lyricId = lyricAsync.value?.lyricId;
    final songHash = lyricAsync.value?.songHash;
    final showLyric = ref.watch(lyricVisibleProvider);
    // 切到歌词视图时重放淡入动画（原 _toggleLyric 行为）。
    if (showLyric) _fadeCtrl.forward(from: 0);

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: showLyric
              ? _LyricPhaseView(
                  key: const ValueKey('lyric'),
                  lyricAsync: lyricAsync,
                  songHash: songHash,
                  lyric: lyric,
                  lyricId: lyricId,
                  lyricMode: lyricMode,
                  position: position,
                  onTapLine: (ms) => ref
                      .read(playerControllerProvider)
                      .seekTo(Duration(milliseconds: ms)),
                  onRetry: () => ref.invalidate(currentLyricProvider),
                )
              : _CoverView(song: widget.song),
        ),
        // v5.3-R2：移除右下角 40dp 悬浮歌词切换按钮（修 C-38）——入口行
        // 已有 ≥48dp 且带 active 态的「歌词/封面」按钮，此处属语义重复。
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

    final maxMs = total.inMilliseconds > 0
        ? total.inMilliseconds.toDouble()
        : 0.0;
    final posMs = position.inMilliseconds
        .clamp(0, total.inMilliseconds)
        .toDouble();
    final bufMs = buffered.inMilliseconds
        .clamp(0, total.inMilliseconds)
        .toDouble();
    // v5.3-R2（修 C-44）：未取到时长前禁用滑块——此前用假上界 1ms 可拖可 seek。
    final enabled = total.inMilliseconds > 0;
    // 拖动期间左下角时间跟随拇指值（松手前不回跳 position）。
    final shownPos = Duration(milliseconds: (_dragMs ?? posMs).round());

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              inactiveTrackColor: theme.colorScheme.onSurfaceVariant.withValues(
                alpha: 0.2,
              ),
              secondaryActiveTrackColor: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.45),
            ),
            child: Slider(
              // 夹取上界防切歌瞬间断言
              value: (_dragMs ?? posMs).clamp(0.0, maxMs > 0 ? maxMs : 0.0),
              max: maxMs > 0 ? maxMs : 1.0,
              secondaryTrackValue: bufMs,
              onChanged: enabled
                  ? (v) => setState(() => _dragMs = v)
                  : null, // disabled：duration 未知时不可拖（质量要求 3 三态）
              onChangeStart: enabled
                  ? (v) => setState(() => _dragMs = v)
                  : null,
              onChangeEnd: enabled
                  ? (v) {
                      // 第 20 条：异步/延迟回调先确认对象仍存活
                      if (mounted) {
                        controller.seekTo(Duration(milliseconds: v.round()));
                        setState(() => _dragMs = null);
                      }
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(shownPos), style: theme.textTheme.labelSmall),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
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
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
                icon: Icon(switch (loopMode) {
                  LoopMode.one => Icons.repeat_one,
                  _ => Icons.repeat,
                }),
                selectedIcon: Icon(switch (loopMode) {
                  LoopMode.one => Icons.repeat_one,
                  _ => Icons.repeat,
                }),
                tooltip: loopMode == LoopMode.one
                    ? context.l10n.repeatOne
                    : context.l10n.repeat,
                onPressed: controller.cycleRepeatMode,
              ),
            ],
          );
        },
      ),
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
        child: Icon(
          Icons.music_note_rounded,
          size: 96,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 歌词三态视图（v5.3 质量原则 34「加载必须可见」的实现）。
///
/// 三态明确分离、互不混淆（第 16 条：错误 ≠ 空 ≠ 加载中）：
/// 1. **加载态**：骨架行占位，加载过程阶段可见，禁止静默回落到空白；
///    refresh 期间同样显示骨架而非旧内容闪断。
/// 2. **错误态**：区分「无候选（暂无歌词）」与「解析失败」，
///    文案说明发生了什么 + 提供重试动作。
/// 3. **数据态**：交给 [LyricView]，透传 lyricId/songHash 供翻译补丁
///    世代校验（V400-A-04，原则 18）。
class _LyricPhaseView extends ConsumerWidget {
  const _LyricPhaseView({
    super.key,
    required this.lyricAsync,
    required this.songHash,
    required this.lyric,
    required this.lyricId,
    required this.lyricMode,
    required this.position,
    required this.onTapLine,
    required this.onRetry,
  });

  /// 歌词加载结果（currentLyricProvider 的 AsyncValue），状态单一来源（第 5 条）。
  final AsyncValue<
    ({KrcLyric? lyric, String? error, String? lyricId, String? songHash})
  >
  lyricAsync;

  /// 当前歌词所属歌曲 hash（原则 18：切歌世代校验，防旧结果污染）。
  final String? songHash;

  /// 非空时进入数据态（来源与 [lyricAsync] 同代，由调用方保证）。
  final KrcLyric? lyric;

  /// 歌词候选 id（冻结契约 LyricTranslationStream，B 按 candidate.id emit）。
  final String? lyricId;

  final LyricDisplayMode lyricMode;

  final Duration position;

  final ValueChanged<int> onTapLine;

  /// 错误态的重试动作（由调用方 invalidate provider，页面不自行触网）。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // ── 加载态（含 refresh 重载）：骨架行，加载必须可见（原则 34）。
    if (lyricAsync.isLoading) {
      return const _LyricSkeleton();
    }

    // ── 错误态：区分「无候选」与「解析失败」（第 16 条），
    //    文案 = 发生了什么 + 重试动作。
    final error = lyricAsync.value?.error;
    if (error != null) {
      return EmptyState(
        icon: Icons.lyrics_outlined,
        message: error,
        actionLabel: context.l10n.retry,
        onAction: onRetry,
      );
    }

    // ── 数据态：正常歌词。
    final data = lyric;
    if (data != null) {
      return LyricView(
        lyric: data,
        position: position,
        mode: lyricMode,
        onTapLine: onTapLine,
        lyricId: lyricId,
        songHash: songHash,
      );
    }

    // ── 兜底空态：provider 正常返回但无歌词（理论上 error 已覆盖，
    //    此处防御性兜底，不给空白屏）。
    return EmptyState(
      icon: Icons.music_off_outlined,
      message: context.l10n.lyricEmptyGuide,
    );
  }
}

/// 歌词加载骨架：3 组「主线 + 副线」占位行，模拟歌词版式，
/// 使加载阶段可感知（原则 34：超过 500ms 的阶段必须可见）。
class _LyricSkeleton extends StatefulWidget {
  const _LyricSkeleton();

  @override
  State<_LyricSkeleton> createState() => _LyricSkeletonState();
}

class _LyricSkeletonState extends State<_LyricSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.surfaceContainerHighest;
    final highlightColor = theme.colorScheme.surfaceContainer;

    Widget line(double width, {double height = 16}) {
      return FadeTransition(
        opacity: _opacity,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: baseColor,
            gradient: LinearGradient(
              colors: [baseColor, highlightColor, baseColor],
            ),
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 3; i++) ...[
              line(220 * (1 - i * 0.18), height: 18),
              const SizedBox(height: 8),
              line(140 - i * 20, height: 13),
              const SizedBox(height: 28),
            ],
          ],
        ),
      ),
    );
  }
}
