import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/utils/toast.dart';
import '../../../l10n/l10n.dart';
import '../../player/player_provider.dart';
import '../data/mv_collection_repository.dart';
import '../data/mv_repository.dart';
import '../mv_provider.dart';

/// MV 全屏播放页（V3990-2 完全重写）。
///
/// 三态分离：[_Phase.loading]（解析/初始化中）→
/// [_Phase.normal]（播放器就绪）→ [_Phase.failed]（含归因与重试）；
/// MV 不存在（详情 20010 / hash 反查失败）走 failed 态的「不存在」文案。
///
/// 生命周期对称：控制器 dispose / 方向锁恢复 / 系统 UI 恢复 / 生命周期
/// 暂停 / 进度与播放态订阅，全部在 dispose 成对释放（第 20 条）。
///
/// 音频互斥：进入本页即暂停音频队列（TiernanAudioHandler.pause，作废
/// 世代防缓冲续播）；返回后是否恢复由用户在播放页决定，不做自动恢复。
class MvPlayerPage extends ConsumerStatefulWidget {
  const MvPlayerPage({
    super.key,
    required this.hash,
    this.videoId,
    this.title,
    this.artist,
  });

  /// 视频 hash（/video/url 只认它；详情经 V3990-1 在 repository 层换算）
  final String hash;

  /// 视频 id（/video/detail 只认它，用于清晰度列表）
  final String? videoId;
  final String? title;
  final String? artist;

  @override
  ConsumerState<MvPlayerPage> createState() => _MvPlayerPageState();
}

enum _Phase { loading, normal, failed }

class _MvPlayerPageState extends ConsumerState<MvPlayerPage> {
  VideoPlayerController? _controller;
  _Phase _phase = _Phase.loading;

  String? _errorDetail; // 失败原因（技术细节，可展开）
  bool _mvMissing = false; // 详情不可得（不存在/已下架）

  bool _showControls = true;
  Timer? _hideTimer; // 控制条自动隐藏（dispose 成对取消）

  String? _activeHash; // 当前正在播放的清晰度 hash
  bool _resolving = false; // 解析互斥闸门（第 19 条，finally 开闸）
  bool _resolvingStarted = false; // 本次是否处于解析期（加载/缓冲文案区分）

  // 收藏防重（第 21 条）
  bool _collecting = false;
  bool _collected = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _pauseAudioQueue();
    _loadDetail();
    _resolve(widget.hash);
  }

  /// 进入 MV 播放前暂停音频队列（互斥）。
  /// pause() 本身作废音频在途世代（audio_handler V3-02），不会自动续播。
  void _pauseAudioQueue() {
    try {
      ref.read(audioHandlerProvider).pause();
    } on Exception catch (e) {
      // 互斥失败不阻断 MV 播放，但必须留痕（第 9 条）
      debugPrint('[mv] pause audio queue failed: $e');
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    // 恢复系统 UI（进入横屏时隐藏了状态栏）——与 initState 进入全屏对称
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 拉取详情（清晰度列表）。V3990-1 后 fetchDetail 内部已做 hash→video_id
  /// 收口，这里无论传的是 hash 还是 id 都能取到；失败分「不存在」与
  /// 「网络失败」两种事实（第 16 条语义分离），不吞异常。
  Future<void> _loadDetail() async {
    try {
      final detail = await ref
          .read(mvRepoProvider)
          .fetchDetail(widget.videoId ?? widget.hash);
      if (!mounted) return;
      if (detail.videoId.isEmpty && detail.hashes.isEmpty) {
        // 详情成功但数据为空：MV 不存在（与网络失败分离）
        setState(() => _mvMissing = true);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      // 详情失败不阻断播放（resolvePlayUrl 只需 hash），但若后续解析也
      // 失败，_errorDetail 会带上这里的原因；20010/反查失败视为不存在。
      if (e.errorCode == 20010 || e.errorCode == -1) {
        setState(() {
          _mvMissing = true;
          _errorDetail = e.message;
        });
      } else {
        setState(() => _errorDetail = e.message);
      }
    } on Exception catch (e) {
      if (mounted) setState(() => _errorDetail = '$e');
    }
  }

  /// 解析播放地址并初始化播放器（首次 / 重试 / 切清晰度共用）。
  Future<void> _resolve(String hash) async {
    if (_resolving) return; // 互斥闸门
    _resolving = true;
    _resolvingStarted = true;
    final isSwitch = _controller != null; // 切清晰度（非首次解析）
    if (mounted) {
      setState(() {
        _errorDetail = null;
        _mvMissing = false;
        if (!isSwitch) _phase = _Phase.loading;
      });
    }
    VideoPlayerController? created;
    try {
      final url = await ref.read(mvRepoProvider).resolvePlayUrl(hash);
      created = VideoPlayerController.networkUrl(Uri.parse(url));
      await created.initialize();
      await created.play();
      final old = _controller;
      if (!mounted) {
        await created.dispose();
        created = null;
        return;
      }
      setState(() {
        _controller = created;
        _activeHash = hash;
        _phase = _Phase.normal;
      });
      created = null; // 所有权已移交 _controller，勿在 finally 释放
      old?.dispose();
      _listenEvents(_controller!);
      _scheduleHide();
    } catch (e) {
      // 初始化失败必须释放刚创建的原生播放器，否则每次重试泄漏一个
      await created?.dispose();
      created = null;
      if (!mounted) return;
      if (isSwitch) {
        // 切档失败：恢复旧画面播放 + toast（不显示全屏错误 UI）
        try {
          await _controller?.play();
        } on Exception catch (_) {}
        Toast.show(context, context.l10n.qualitySwitchFailed);
      } else {
        setState(() {
          _phase = _Phase.failed;
          _errorDetail = '$e';
        });
      }
    } finally {
      _resolving = false; // 闸门由持有者关闭（第 19 条）
      _resolvingStarted = false;
    }
  }

  /// 订阅播放器事件：错误归因 + 播放态驱动控制条刷新（不再靠 setState 手点）。
  /// 监听器随控制器 dispose 一起销毁（VideoPlayerController.addListener
  /// 生命周期与控制器绑定），重建时对旧控制器 dispose 自动解除（第 20 条）。
  void _listenEvents(VideoPlayerController controller) {
    controller.addListener(() {
      if (!mounted) return;
      if (controller.value.hasError) {
        final desc = controller.value.errorDescription ?? '';
        if (_errorDetail != desc) {
          setState(() => _errorDetail = desc);
          Toast.show(context, context.l10n.mvPlayError);
        }
        return;
      }
      // isPlaying / buffering 变化驱动一次轻量重建（控制条图标/缓冲圈）
      if (_phase == _Phase.normal) setState(() {});
    });
  }

  // ---------- 控制条自动隐藏 ----------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _controller?.value.isPlaying == true) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  // ---------- 收藏 ----------

  /// V3990-2：收藏 / 取消收藏。异常不再统一按「需登录」提示——
  /// 网络失败与未登录是两种事实（第 6/7/16 条），分别归因。
  Future<void> _toggleCollect() async {
    if (_collecting) return; // 防重（第 21 条）
    final videoId = int.tryParse(widget.videoId ?? '');
    if (videoId == null) {
      // 无 videoId（深链只带 hash）无法调用收藏接口，如实告知而非静默失败
      if (mounted) Toast.show(context, context.l10n.mvNoSource);
      return;
    }
    final next = !_collected;
    setState(() => _collecting = true);
    try {
      final ok = await ref
          .read(mvCollectionRepositoryProvider)
          .setCollected(videoId, collect: next);
      if (!mounted) return;
      if (ok) {
        setState(() => _collected = next);
        Toast.show(
            context,
            next
                ? context.l10n.mvCollectSuccess
                : context.l10n.mvCollectRemoved);
      } else {
        // 仓库层返回 false 仅在未登录/风控空包场景（setCollected 契约）
        Toast.show(context, context.l10n.mvCollectLoginFirst);
      }
    } on ApiException catch (e) {
      if (mounted) Toast.show(context, context.l10n.mvDetailLoadFailed + '：$e');
    } on Exception catch (e) {
      if (mounted) {
        Toast.show(context, '${context.l10n.mvCollectAdd}：$e');
      }
    } finally {
      if (mounted) setState(() => _collecting = false);
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // 全屏（横屏）时隐藏状态栏，退出恢复（dispose 对称）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(
        isLandscape
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      );
    });
    final detail = ref.watch(mvDetailProvider(widget.videoId ?? widget.hash));
    final qualities = detail.value?.hashes ?? const <String, String>{};
    final containers = detail.value?.containers ?? const <String, String>{};
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: isLandscape || !_showControls || _phase != _Phase.normal
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title ?? context.l10n.mv,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.white)),
                  if (widget.artist != null)
                    Text(widget.artist!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white54)),
                ],
              ),
            ),
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: switch (_phase) {
                _Phase.loading => _buildLoading(theme),
                _Phase.failed => _buildError(theme, isLandscape),
                _Phase.normal => _buildPlayer(isLandscape),
              },
            ),
            // 横屏返回按钮浮层
            if (isLandscape && _showControls)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back,
                      color: Colors.white, shadows: [
                        Shadow(color: Colors.black54, blurRadius: 8),
                      ]),
                  tooltip: context.l10n.back,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            // 清晰度切换（含当前档指示 + mkv 容器标注，V3990-2）
            if (_phase == _Phase.normal && qualities.length > 1)
              Positioned(
                right: 12,
                bottom: 108,
                child: _QualityPicker(
                  qualities: qualities,
                  containers: containers,
                  activeHash: _activeHash,
                  onSelected: (q) => _resolve(qualities[q]!),
                ),
              ),
            // 竖屏：底部浮层操作条（主/次按钮层级明确）
            if (!isLandscape && _showControls && _phase == _Phase.normal)
              Positioned(
                left: 12,
                right: 12,
                bottom: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text(context.l10n.back),
                    ),
                    IconButton(
                      tooltip: _collected
                          ? context.l10n.mvCollectRemove
                          : context.l10n.mvCollectAdd,
                      icon: Icon(
                        _collected
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color:
                            _collected ? Colors.redAccent : Colors.white,
                      ),
                      onPressed: _collecting ? null : _toggleCollect,
                    ),
                    FilledButton.icon(
                      onPressed: () => _resolve(_activeHash ?? widget.hash),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 加载态：区分「解析中」与「缓冲中」两种事实（第 16 条）。
  Widget _buildLoading(ThemeData theme) {
    final resolving = _resolvingStarted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: Colors.white70),
        const SizedBox(height: 12),
        Text(
          resolving ? context.l10n.loading : context.l10n.mvBuffering,
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
        ),
      ],
    );
  }

  /// 失败态：三态之一，含归因与重试/返回；MV 不存在给明确文案（无重试——
  /// 资源不存在重试无意义，降级触发/退出条件明确，第 11 条）。
  Widget _buildError(ThemeData theme, bool isLandscape) {
    final missing = _mvMissing && _controller == null;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            missing ? Icons.video_camera_off_outlined : Icons.error_outline,
            color: Colors.white54,
            size: 56,
          ),
          const SizedBox(height: 16),
          Text(
            missing ? context.l10n.mvNotExist : context.l10n.playFailed,
            style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          if (_errorDetail != null) ...[
            const SizedBox(height: 8),
            Text(_errorDetail!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white38),
                textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!missing)
                FilledButton.icon(
                  onPressed: () => _resolve(_activeHash ?? widget.hash),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(context.l10n.retry),
                ),
              if (!missing) const SizedBox(width: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.back),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(bool isLandscape) {
    final controller = _controller!;
    final value = controller.value;
    final buffering = value.isBuffering && !value.isPlaying;
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(
          aspectRatio: value.aspectRatio,
          child: VideoPlayer(controller),
        ),
        // 缓冲态视觉（转圈叠在画面上，区分于黑屏卡死）
        if (buffering)
          const CircularProgressIndicator(color: Colors.white70),
        if (_showControls) ...[
          IconButton(
            iconSize: 64,
            color: Colors.white,
            tooltip: value.isPlaying ? context.l10n.pause : context.l10n.play,
            icon: Icon(value.isPlaying
                ? Icons.pause_circle
                : Icons.play_circle),
            onPressed: () {
              value.isPlaying ? controller.pause() : controller.play();
              setState(() {});
              if (value.isPlaying) _scheduleHide();
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.white,
                bufferedColor: Colors.white30,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 清晰度选择按钮（V3990-2：当前档指示 + mkv 容器标注）。
class _QualityPicker extends StatelessWidget {
  const _QualityPicker({
    required this.qualities,
    required this.containers,
    required this.activeHash,
    required this.onSelected,
  });

  final Map<String, String> qualities; // quality -> hash
  final Map<String, String> containers; // quality -> 'mp4' | 'mkv'
  final String? activeHash;
  final ValueChanged<String> onSelected;

  String _label(BuildContext context, String q) {
    return switch (q) {
      'sd' => context.l10n.mvQualitySd,
      'hd' => context.l10n.mvQualityHd,
      'qhd' => context.l10n.mvQualityQhd,
      'sq' => context.l10n.mvQualitySq,
      'fhd' => context.l10n.mvQualityFhd,
      _ => q.toUpperCase(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = qualities.entries
        .where((e) => e.value == activeHash)
        .map((e) => e.key)
        .firstOrNull;
    return PopupMenuButton<String>(
      color: Colors.black87,
      tooltip: context.l10n.mvQualitySelect,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in qualities.entries)
          PopupMenuItem(
            value: e.key,
            child: Row(
              children: [
                if (e.value == activeHash)
                  const Icon(Icons.check_rounded,
                      size: 18, color: Colors.white)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(
                  _label(context, e.key),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white),
                ),
                // mkv 容器档标注（知情选择：部分设备对 mkv 解码差）
                if (containers[e.key] == 'mkv') ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      context.l10n.mvMkvContainer,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.white54, fontSize: 10),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.high_quality_rounded,
                size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              active == null
                  ? context.l10n.mvQualitySelect
                  : _label(context, active),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
