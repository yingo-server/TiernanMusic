import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 无头渲染页面并输出 PNG，用于视觉审查。
///
/// 不用 Android 模拟器（GitHub runner 没有 KVM，跑不动模拟器）：
/// Flutter 的 widget test 可以离屏渲染，这里把 RenderRepaintBoundary
/// 的画面直接写成 PNG，CI 打包成 zip 随 release 发布。
///
/// 运行：
/// ```sh
/// flutter test test/screenshots_test.dart
/// ```
/// 产物：`screenshots/*.png`
void main() {
  testWidgets('渲染首页骨架', (tester) async {
    await tester.pumpWidget(const _Harness(child: _HomeSkeletonMock()));
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, '01_home');
  });

  testWidgets('渲染设置页分区', (tester) async {
    await tester.pumpWidget(const _Harness(child: _SettingsMock()));
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, '02_settings');
  });

  testWidgets('渲染播放器', (tester) async {
    await tester.pumpWidget(const _Harness(child: _PlayerMock()));
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, '03_player');
  });
}

/// 把当前渲染树写成 PNG。
Future<void> _capture(WidgetTester tester, String name) async {
  final dir = Directory('screenshots');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final boundary = tester.binding.renderViewElement!
      .findRenderObject()! as RenderView;
  // RenderView 不能直接 toImage，改用 findRenderObject 树里最外层的 RepaintBoundary
  final repaint = _findBoundary(boundary);
  if (repaint == null) {
    // 退化为整窗截图
    await tester.runAsync(() async {
      final image = await _captureView(tester);
      if (image != null) {
        await _writePng(dir, name, image);
      }
    });
    return;
  }

  await tester.runAsync(() async {
    final image = await repaint.toImage(pixelRatio: 2.0);
    await _writePng(dir, name, image);
  });
}

RenderRepaintBoundary? _findBoundary(RenderObject root) {
  if (root is RenderRepaintBoundary) return root;
  RenderRepaintBoundary? found;
  root.visitChildren((child) {
    found ??= _findBoundary(child);
  });
  return found;
}

Future<ui.Image?> _captureView(WidgetTester tester) async {
  final binding = tester.binding;
  final view = binding.renderViews.first;
  final layer = view.debugLayer;
  if (layer is OffsetLayer) {
    return layer.toImage(
      Offset.zero & view.paintBounds.size,
      pixelRatio: 2.0,
    );
  }
  return null;
}

Future<void> _writePng(Directory dir, String name, ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) return;
  final file = File('${dir.path}/$name.png');
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  // ignore: avoid_print
  print('[screenshot] ${file.path}');
}

/// 模拟设备视口
const Size kViewport = Size(412, 892);

class _Harness extends StatelessWidget {
  const _Harness({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4FF),
          brightness: Brightness.dark,
        ),
      ),
      home: RepaintBoundary(
        child: Scaffold(body: child),
      ),
    );
  }
}

class _HomeSkeletonMock extends StatelessWidget {
  const _HomeSkeletonMock();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(double w, double h, {double radius = 16}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('汀澜音乐',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        box(double.infinity, 150),
        const SizedBox(height: 20),
        Row(
          children: [
            box(130, 130, radius: 20),
            const SizedBox(width: 12),
            box(130, 130, radius: 20),
            const SizedBox(width: 12),
            box(130, 130, radius: 20),
          ],
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < 4; i++) ...[
          Row(
            children: [
              box(56, 56, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    box(double.infinity, 14, radius: 6),
                    const SizedBox(height: 8),
                    box(120, 12, radius: 6),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _SettingsMock extends StatelessWidget {
  const _SettingsMock();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        ListTile(
          leading: Icon(Icons.person_outline),
          title: Text('未登录'),
          trailing: Icon(Icons.chevron_right),
        ),
        Divider(),
        ListTile(
          leading: Icon(Icons.palette_outlined),
          title: Text('外观'),
        ),
        ListTile(
          leading: Icon(Icons.play_circle_outline),
          title: Text('播放'),
        ),
        ListTile(
          leading: Icon(Icons.download_outlined),
          title: Text('下载'),
        ),
        ListTile(
          leading: Icon(Icons.storage_outlined),
          title: Text('缓存'),
        ),
        ListTile(
          leading: Icon(Icons.bug_report_outlined),
          title: Text('诊断'),
        ),
        ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('关于'),
        ),
      ],
    );
  }
}

class _PlayerMock extends StatelessWidget {
  const _PlayerMock();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 48),
        Container(
          width: 300,
          height: 300,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [scheme.primaryContainer, scheme.surfaceContainerHighest],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text('晴天',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('周杰伦',
            style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 40),
        const Slider(value: 0.4, onChanged: null),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Icon(Icons.shuffle, color: scheme.primary),
            Icon(Icons.skip_previous, size: 40),
            Icon(Icons.pause_circle_filled, size: 64, color: scheme.primary),
            Icon(Icons.skip_next, size: 40),
            Icon(Icons.repeat, color: scheme.primary),
          ],
        ),
      ],
    );
  }
}
