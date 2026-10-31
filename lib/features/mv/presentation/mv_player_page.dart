import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/providers.dart';
import '../data/mv_repository.dart';

final _mvRepoProvider =
    Provider<MvRepository>((ref) => MvRepository(ref.watch(kugouApiClientProvider)));

final _mvUrlProvider = FutureProvider.autoDispose
    .family<String, String>((ref, hash) {
  return ref.watch(_mvRepoProvider).resolvePlayUrl(hash);
});

/// MV 全屏播放页
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

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _initPlayer(String url) async {
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      await controller.play();
      if (mounted) setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final urlAsync = ref.watch(_mvUrlProvider(widget.hash));

    // URL 解析成功后初始化播放器
    if (urlAsync.hasValue && _controller == null && _error == null) {
      _initPlayer(urlAsync.value!);
    }
    if (urlAsync.hasError && _error == null) {
      _error = '${urlAsync.error}';
    }

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
        child: Center(
          child: _error != null
              ? _buildError()
              : _controller == null
                  ? const CircularProgressIndicator()
                  : _buildPlayer(isLandscape),
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
        const Text('播放失败', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Text(_error!,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
      ],
    );
  }
}
