import 'package:flutter/material.dart';

class FullPlayerPage extends StatelessWidget {
  const FullPlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放')),
      body: const Center(child: Text('播放器')),
    );
  }
}
