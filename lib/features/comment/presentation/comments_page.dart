import 'package:flutter/material.dart';

class CommentsPage extends StatelessWidget {
  const CommentsPage({super.key, required this.resourceType, required this.resourceId});
  final String resourceType;
  final String resourceId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('评论')),
      body: Center(child: Text('评论: $resourceType/$resourceId')),
    );
  }
}
