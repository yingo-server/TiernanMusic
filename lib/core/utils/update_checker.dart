import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 版本检查结果
class UpdateInfo {
  const UpdateInfo({
    required this.hasUpdate,
    required this.latestVersion,
    required this.latestTag,
    this.downloadUrl,
    this.acceleratedUrl,
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
    // 通过 GitHub API 获取结构化 release 信息（走前缀代理加速）
    final apiUrl =
        '$_proxyPrefix' 'https://api.github.com/repos/$_repoPath/releases/latest';
    try {
      final res = await _dio.get<Map<String, dynamic>>(apiUrl);
      final data = res.data;
      if (data != null && data['tag_name'] != null) return data;
      return null;
    } on DioException catch (e) {
      // 404 = 仓库还没有发布任何 Release（不是网络故障）
      if (e.response?.statusCode == 404) return null;
      debugPrint('[UpdateChecker] api failed: $e');
      rethrow;
    } catch (e) {
      debugPrint('[UpdateChecker] api failed: $e');
      rethrow;
    }
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
  ///
  /// 规则（对齐 semver）：
  ///  - 先比较三段数字版本号（`1.2.3`）
  ///  - 数字相同时，**带预发布后缀的版本更旧**：`1.0.0-rc1 < 1.0.0`
  ///  - 两边都有预发布后缀时，逐段比较预发布标识（数字按数值比，其余按 ASCII 比）
  ///  - build number（`1.0.0+42`）不参与比较
  static int _compareVersion(String a, String b) {
    final va = _splitVersion(a);
    final vb = _splitVersion(b);

    final len = va.core.length > vb.core.length
        ? va.core.length
        : vb.core.length;
    for (var i = 0; i < len; i++) {
      final x = i < va.core.length ? va.core[i] : 0;
      final y = i < vb.core.length ? vb.core[i] : 0;
      if (x != y) return x - y;
    }

    // 核心版本相同：比较预发布后缀
    final pa = va.pre;
    final pb = vb.pre;
    if (pa.isEmpty && pb.isEmpty) return 0;
    // 1.0.0-rc1 < 1.0.0（正式版比预发布版新）
    if (pa.isEmpty) return 1;
    if (pb.isEmpty) return -1;

    final plen = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < plen; i++) {
      if (i >= pa.length) return -1; // 标识更少者更旧
      if (i >= pb.length) return 1;
      final x = pa[i];
      final y = pb[i];
      final nx = int.tryParse(x);
      final ny = int.tryParse(y);
      if (nx != null && ny != null) {
        if (nx != ny) return nx - ny;
      } else {
        final cmp = x.compareTo(y);
        if (cmp != 0) return cmp;
      }
    }
    return 0;
  }

  /// 拆分版本号：`1.0.0-rc.1+42` → core=[1,0,0], pre=['rc',1]
  static ({List<int> core, List<String> pre}) _splitVersion(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 去掉 build number
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    // 拆分预发布后缀
    var pre = <String>[];
    final dash = s.indexOf('-');
    if (dash >= 0) {
      final preStr = s.substring(dash + 1);
      s = s.substring(0, dash);
      pre = preStr
          .split('.')
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    final core = s
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList(growable: false);
    return (core: core, pre: pre);
  }
}
