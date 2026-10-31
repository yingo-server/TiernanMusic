import 'package:flutter/material.dart';

class MvPlayerPage extends StatelessWidget {
  const MvPlayerPage({super.key, required this.hash});
  final String hash;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MV')),
      body: Center(child: Text('MV: $hash')),
    );
  }
}
