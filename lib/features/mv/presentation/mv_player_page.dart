import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../l10n/l10n.dart';
import '../data/mv_repository.dart';
import '../mv_provider.dart';

/// 清晰度档位显示名。
const _qualityLabels = {
  'sd': '标清',
  'hd': '高清',
  'qhd': '超清',
  'sq': '全高清',
  'fhd': '蓝光',
};

/// MV 全屏播放页。
///
/// URL 解析在 initState 中触发（Future.then），build 不再有副作用；
/// 清晰度切换 / 失败重试通过 [_resolve] 重新解析并重建播放器。
class MvPlayerPage extends ConsumerStatefulWidget {
  const MvPlayerPage({
    super.key,
    required this.hash,
    this.title,
    this.artist,
  });

  final String hash;
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
    try {
      final url = await ref.read(mvRepoProvider).resolvePlayUrl(hash);
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      await controller.play();
      final old = _controller;
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _activeHash = hash;
      });
      old?.dispose();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _resolving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final detail = ref.watch(mvDetailProvider(widget.hash)).value;
    final qualities = detail?.hashes ?? const <String, String>{};

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: isLandscape || !_showControls
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title ?? 'MV',
                      style: const TextStyle(fontSize: 16)),
                  if (widget.artist != null)
                    Text(widget.artist!,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
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
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            // 清晰度切换
            if (_error == null && qualities.length > 1)
              Positioned(
                right: 12,
                bottom: 56,
                child: _QualityPicker(
                  qualities: qualities,
                  activeHash: _activeHash,
                  onSelected: (q) => _resolve(qualities[q]!),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.white54, size: 56),
        const SizedBox(height: 16),
        Text(context.l10n.playFailed, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Text(_error!,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(
              onPressed: () => _resolve(_activeHash ?? widget.hash),
              child: Text(context.l10n.retry),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.back),
            ),
          ],
        ),
      ],
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

  String _label(String q, String hash) =>
      '${_qualityLabels[q] ?? q.toUpperCase()}${hash == activeHash ? ' ✓' : ''}';

  @override
  Widget build(BuildContext context) {
    final active = qualities.entries
        .where((e) => e.value == activeHash)
        .map((e) => e.key)
        .firstOrNull;
    return PopupMenuButton<String>(
      color: Colors.black87,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in qualities.entries)
          PopupMenuItem(
            value: e.key,
            child: Text(
              _label(e.key, e.value),
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          _qualityLabels[active] ?? (active?.toUpperCase() ?? '清晰度'),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}
