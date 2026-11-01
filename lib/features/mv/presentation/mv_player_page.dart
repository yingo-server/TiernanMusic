import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../l10n/l10n.dart';
import '../mv_provider.dart';

/// MV 全屏播放页。
///
/// URL 解析在 initState 中触发（Future.then），build 不再有副作用；
/// 清晰度切换 / 失败重试通过 [_resolve] 重新解析并重建播放器。
class MvPlayerPage extends ConsumerStatefulWidget {
  const MvPlayerPage({
    super.key,
    required this.hash,
    this.videoId,
    this.title,
    this.artist,
  });

  /// 视频 hash（/video/url 只认它）
  final String hash;

  /// 视频 id（/video/detail 只认它，用于清晰度列表）
  final String? videoId;
  final String? title;
  final String? artist;

  @override
  ConsumerState<MvPlayerPage> createState() => _MvPlayerPageState();
}

class _MvPlayerPageState extends ConsumerState<MvPlayerPage> {
  VideoPlayerController? _controller;
  bool _showControls = true;
  String? _error;
  String? _activeHash; // 当前正在播放的清晰度 hash
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _resolve(widget.hash);
  }

  @override
  void dispose() {
    _controller?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 解析播放地址并初始化播放器（清晰度切换 / 重试共用）。
  Future<void> _resolve(String hash) async {
    if (_resolving) return;
    _resolving = true;
    if (mounted) setState(() {
      _error = null;
      _controller?.pause();
    });
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
      });
      created = null; // 已交给 _controller，勿在 finally 释放
      old?.dispose();
    } catch (e) {
      // 初始化失败必须释放刚创建的原生播放器，否则每次重试泄漏一个
      await created?.dispose();
      if (mounted) setState(() => _error = '$e');
    } finally {
      _resolving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final detail = ref
        .watch(mvDetailProvider(widget.videoId ?? widget.hash))
        .value;
    final qualities = detail?.hashes ?? const <String, String>{};
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: isLandscape || !_showControls
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title ?? 'MV',
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
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: _error != null
                  ? _buildError()
                  : _controller == null
                      ? const CircularProgressIndicator()
                      : _buildPlayer(isLandscape),
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
            // 清晰度切换（PopupMenu）
            if (_error == null && qualities.length > 1)
              Positioned(
                right: 12,
                bottom: 108,
                child: _QualityPicker(
                  qualities: qualities,
                  activeHash: _activeHash,
                  onSelected: (q) => _resolve(qualities[q]!),
                ),
              ),
            // 竖屏：底部浮层操作条（主/次按钮层级明确）
            if (!isLandscape && _showControls && _error == null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 次要操作：OutlinedButton
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text(context.l10n.back),
                    ),
                    // 主操作：FilledButton
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

  Widget _buildPlayer(bool isLandscape) {
    final controller = _controller!;
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
        if (_showControls) ...[
          // 播放/暂停
          IconButton(
            iconSize: 64,
            color: Colors.white,
            tooltip: controller.value.isPlaying
                ? context.l10n.pause
                : context.l10n.play,
            icon: Icon(controller.value.isPlaying
                ? Icons.pause_circle
                : Icons.play_circle),
            onPressed: () {
              controller.value.isPlaying
                  ? controller.pause()
                  : controller.play();
              setState(() {});
            },
          ),
          // 进度条
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

  Widget _buildError() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white54, size: 56),
          const SizedBox(height: 16),
          Text(context.l10n.playFailed,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.white38),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 主操作：FilledButton（重试）
              FilledButton.icon(
                onPressed: () => _resolve(_activeHash ?? widget.hash),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.retry),
              ),
              const SizedBox(width: 12),
              // 次要操作：OutlinedButton（返回）
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.back),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 清晰度选择按钮（PopupMenu，从 videoDetail 的 hashes 取档位）。
class _QualityPicker extends StatelessWidget {
  const _QualityPicker({
    required this.qualities,
    required this.activeHash,
    required this.onSelected,
  });

  final Map<String, String> qualities; // quality -> hash
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
                // 选中态用 check 图标（不再叠加文本 ✓）
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
