import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_config.dart';

/// 版本检查结果
class UpdateInfo {
  const UpdateInfo({
    required this.hasUpdate,
    required this.latestVersion,
    required this.latestTag,
    this.downloadUrl,
    this.releaseNotes,
    this.publishedAt,
  });

  final bool hasUpdate;
  final String latestVersion;
  final String latestTag;

  /// 直连 GitHub 的下载链接
  final String? downloadUrl;

  /// 带前缀加速的下载链接
  final String? acceleratedUrl;

  final String? releaseNotes;
  final DateTime? publishedAt;
}

/// 检查更新。
///
/// 使用**前缀代理**访问 GitHub API / Release，避免直连 GitHub 速度慢或被墙。
class UpdateChecker {
  UpdateChecker._();
  static final instance = UpdateChecker._();

  static const _proxyPrefix = 'https://proxy.344977.xyz/';
  static const _repoPath = 'yingo-server/TiernanMusic';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': 'TiernanMusic/1.0.0 Android'},
  ));

  /// 当前版本
  Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '1.0.0';
    }
  }

  /// 检查是否有新版本
  Future<UpdateInfo> check() async {
    final current = await currentVersion();
    final release = await _fetchLatestRelease();
    if (release == null) {
      return UpdateInfo(
        hasUpdate: false,
        latestVersion: current,
        latestTag: '',
      );
    }

    final tag = '${release['tag_name'] ?? ''}';
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    final hasUpdate = _compareVersion(latest, current) > 0;

    // 优先挑 arm64 的 APK（绝大多数设备）
    var url = _pickApkUrl(release);
    if (url == null && release['html_url'] != null) {
      url = '${release['html_url']}';
    }

    return UpdateInfo(
      hasUpdate: hasUpdate,
      latestVersion: latest.isEmpty ? current : latest,
      latestTag: tag,
      downloadUrl: url,
      acceleratedUrl: url == null ? null : '$_proxyPrefix$url',
      releaseNotes: _extractNotes(release),
      publishedAt: DateTime.tryParse('${release['published_at'] ?? ''}'),
    );
  }

  Future<Map<String, dynamic>?> _fetchLatestRelease() async {
    // 优先走 GitHub API（拿结构化数据），失败再退回 releases/latest 页面
    final apiUrl =
        '$_proxyPrefixhttps://api.github.com/repos/$_repoPath/releases/latest';
    try {
      final res = await _dio.get<Map<String, dynamic>>(apiUrl);
      final data = res.data;
      if (data != null && data['tag_name'] != null) return data;
    } catch (e) {
      debugPrint('[UpdateChecker] api failed: $e');
    }
    return null;
  }

  /// 从 release 的 assets 里挑一个 APK
  String? _pickApkUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;
    String? fallback;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = '${a['name'] ?? ''}';
      final url = '${a['browser_download_url'] ?? ''}';
      if (!name.endsWith('.apk') || url.isEmpty) continue;
      if (name.contains('arm64')) return url;
      fallback ??= url;
    }
    return fallback;
  }

  String? _extractNotes(Map<String, dynamic> release) {
    final body = release['body'];
    if (body is! String || body.trim().isEmpty) return null;
    final trimmed = body.trim();
    return trimmed.length > 1200 ? '${trimmed.substring(0, 1200)}…' : trimmed;
  }

  /// 语义化版本比较：a > b 返回正数
  static int _compareVersion(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  static List<int> _parts(String v) {
    final cleaned = v.split('-').first.split('+').first;
    return cleaned
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  /// 应用名（用于更新提示）
  static String get appName => AppConfig.appNameCn;

  /// 调试输出用
  static String encode(Object o) => jsonEncode(o);
}
