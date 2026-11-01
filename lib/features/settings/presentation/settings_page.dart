import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/cache/cache_manager.dart';
import '../../../core/config/app_config.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/settings_provider.dart';
import '../../../core/utils/error_logger.dart';
import '../../../core/utils/permission_gate.dart';
import '../../../core/utils/toast.dart';
import '../../../core/utils/update_checker.dart';
import '../../../l10n/l10n.dart';
import 'settings_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _cacheSize = '';
  String _version = '';
  Map<String, dynamic>? _account;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
    _loadVersion();
    _loadAccount();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = '${info.version} (${info.buildNumber})');
    }
  }

  Future<void> _loadAccount() async {
    try {
      final raw = await const FlutterSecureStorageCompat().readAccounts();
      if (mounted) setState(() => _account = raw);
    } catch (_) {
      if (mounted) setState(() => _account = null);
    }
  }

  Future<void> _loadCacheSize() async {
    try {
      var total = 0;
      final dirs = [
        await getApplicationDocumentsDirectory(),
        await getApplicationSupportDirectory(),
        await getTemporaryDirectory(),
      ];
      for (final dir in dirs) {
        if (await dir.exists()) {
          await for (final entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is File) total += await entity.length();
          }
        }
      }
      if (mounted) setState(() => _cacheSize = _formatBytes(total));
    } catch (_) {
      if (mounted) setState(() => _cacheSize = context.l10n.cannotCalculate);
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _clearCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.clearCache),
        content: Text(context.l10n.clearCacheConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.clear)),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      MemoryCache.instance.clear();
      await LyricTranslationCache.instance.clear();
      // 清空 Hive 缓存类 box（不动 settings box）
      for (final name in ['api_cache', 'image_cache', 'lyric_translations']) {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).clear();
        }
      }
      // 清除临时目录
      final tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        await for (final entity in tmp.list(recursive: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.cacheCleared)));
      }
      _loadCacheSize();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清除失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settings)),
      body: ListView(
        children: [
          _buildAccountSection(),
          _buildAppearanceSection(),
          _buildPlaybackSection(),
          _buildDownloadSection(),
          _buildCacheSection(),
          _buildApiSection(),
          _buildDiagnosticsSection(),
          _buildAboutSection(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ---------- 账号 ----------
  Widget _buildAccountSection() {
    final avatar = _account?['avatar'] as String?;
    final nickname = _account?['nickname'] as String?;
    final loggedIn = nickname != null && nickname.isNotEmpty;
    return _Section(
      title: context.l10n.account,
      children: [
        ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundImage:
                avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
            child: avatar == null || avatar.isEmpty
                ? const Icon(Icons.person_outline)
                : null,
          ),
          title: Text(loggedIn ? nickname : context.l10n.notLoggedIn),
          subtitle: Text(loggedIn ? context.l10n.userIdLabel('${_account?['userid'] ?? '-'}') : context.l10n.login),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await context.push<void>('/login');
            _loadAccount();
          },
        ),
        ListTile(
          leading: const Icon(Icons.switch_account_outlined),
          title: Text(context.l10n.accountManage),
          subtitle: Text(context.l10n.switchAccountSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await context.push<void>('/login');
            _loadAccount();
          },
        ),
      ],
    );
  }

  // ---------- 外观 ----------
  Widget _buildAppearanceSection() {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final themeLabel = switch (themeMode) {
      ThemeMode.light => context.l10n.themeLight,
      ThemeMode.system => context.l10n.themeSystem,
      _ => context.l10n.themeDark,
    };
    final localeLabel = locale == null
        ? context.l10n.themeSystem
        : AppConfig.localeNames[locale.countryCode != null
                ? '${locale.languageCode}_${locale.countryCode}'
                : locale.languageCode] ??
            locale.toString();
    return _Section(
      title: context.l10n.appearance,
      children: [
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: Text(context.l10n.themeMode),
          subtitle: Text(themeLabel),
          onTap: () => _showThemeDialog(themeMode),
        ),
        ListTile(
          leading: const Icon(Icons.language_outlined),
          title: Text(context.l10n.appLanguage),
          subtitle: Text(localeLabel),
          onTap: () => _showLocaleDialog(locale),
        ),
      ],
    );
  }

  void _showThemeDialog(ThemeMode current) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(context.l10n.themeMode),
        children: [
          for (final (mode, label) in [
            (ThemeMode.dark, context.l10n.themeDark),
            (ThemeMode.light, context.l10n.themeLight),
            (ThemeMode.system, context.l10n.themeSystem),
          ])
            RadioListTile<ThemeMode>(
              value: mode,
              groupValue: current,
              title: Text(label),
              onChanged: (v) {
                if (v != null) ref.read(themeModeProvider.notifier).set(v);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showLocaleDialog(Locale? current) {
    String? codeOf(Locale? l) => l == null
        ? 'system'
        : (l.countryCode != null ? '${l.languageCode}_${l.countryCode}' : l.languageCode);
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(context.l10n.appLanguage),
        children: [
          SizedBox(
            width: double.maxFinite,
            height: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                RadioListTile<String>(
                  value: 'system',
                  groupValue: codeOf(current),
                  title: Text(context.l10n.themeSystem),
                  onChanged: (_) {
                    ref.read(localeProvider.notifier).set(null);
                    Navigator.pop(ctx);
                  },
                ),
                for (final code in AppConfig.supportedLocales)
                  RadioListTile<String>(
                    value: code,
                    groupValue: codeOf(current),
                    title: Text(AppConfig.localeNames[code] ?? code),
                    onChanged: (_) {
                      final parts = code.split('_');
                      ref.read(localeProvider.notifier).set(parts.length == 2
                          ? Locale(parts[0], parts[1])
                          : Locale(parts[0]));
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 播放 ----------
  Widget _buildPlaybackSection() {
    final lyricMode = ref.watch(lyricModeProvider);
    final quality = ref.watch(defaultQualityProvider);
    final wifiHigh = ref.watch(wifiQualityProvider);
    final cellularLow = ref.watch(cellularQualityProvider);
    final lyricLabel = switch (lyricMode) {
      LyricDisplayMode.original => context.l10n.lyricModeOriginal,
      LyricDisplayMode.bilingual => context.l10n.lyricModeBilingual,
      LyricDisplayMode.translation => context.l10n.lyricModeTranslation,
    };
    return _Section(
      title: context.l10n.playback,
      children: [
        ListTile(
          leading: const Icon(Icons.lyrics_outlined),
          title: Text(context.l10n.lyricDisplayMode),
          subtitle: Text(lyricLabel),
          onTap: () => _showLyricModeDialog(lyricMode),
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: Text(context.l10n.defaultQuality),
          subtitle: Text(qualityNames[quality] ?? quality),
          onTap: () => _showQualityDialog(quality),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: Text(context.l10n.wifiAutoHighQuality),
          subtitle: Text(context.l10n.wifiAutoHighQualityDesc),
          value: wifiHigh,
          onChanged: (v) => ref.read(wifiQualityProvider.notifier).set(v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.signal_cellular_alt),
          title: Text(context.l10n.cellularLowQuality),
          subtitle: Text(context.l10n.cellularLowQualityDesc),
          value: cellularLow,
          onChanged: (v) => ref.read(cellularQualityProvider.notifier).set(v),
        ),
      ],
    );
  }

  void _showLyricModeDialog(LyricDisplayMode current) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(context.l10n.lyricDisplayMode),
        children: [
          for (final (mode, label) in [
            (LyricDisplayMode.original, context.l10n.lyricModeOriginal),
            (LyricDisplayMode.bilingual, context.l10n.lyricModeBilingual),
            (LyricDisplayMode.translation, context.l10n.lyricModeTranslation),
          ])
            RadioListTile<LyricDisplayMode>(
              value: mode,
              groupValue: current,
              title: Text(label),
              onChanged: (v) {
                if (v != null) ref.read(lyricModeProvider.notifier).set(v);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showQualityDialog(String current) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(context.l10n.defaultQuality),
        children: [
          for (final entry in qualityNames.entries)
            RadioListTile<String>(
              value: entry.key,
              groupValue: current,
              title: Text(entry.value),
              onChanged: (v) {
                if (v != null) ref.read(defaultQualityProvider.notifier).set(v);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  // ---------- 下载 ----------
  Widget _buildDownloadSection() {
    return _Section(
      title: context.l10n.downloadManagement,
      children: [
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined),
          title: Text(context.l10n.downloadManagement),
          subtitle: Text(context.l10n.downloads),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push<void>('/downloads'),
        ),
      ],
    );
  }

  // ---------- 缓存 ----------
  Widget _buildCacheSection() {
    return _Section(
      title: context.l10n.cache,
      children: [
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text(context.l10n.cacheUsage),
          subtitle: Text(_cacheSize),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.l10n.recalculate,
            onPressed: () {
              setState(() => _cacheSize = context.l10n.calculating);
              _loadCacheSize();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: Text(context.l10n.clearCache,
              style: TextStyle(color: Colors.redAccent)),
          subtitle: Text(context.l10n.clearCacheDesc),
          onTap: _clearCache,
        ),
      ],
    );
  }

  // ---------- API ----------
  Widget _buildApiSection() {
    final kugouApi = ref.watch(kugouApiProvider);
    final translateApi = ref.watch(translateApiProvider);
    return _Section(
      title: 'API',
      children: [
        ListTile(
          leading: const Icon(Icons.api_outlined),
          title: Text(context.l10n.kugouApiUrl),
          subtitle: Text(kugouApi, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: context.l10n.resetToDefault,
            onPressed: () async {
              await ref.read(kugouApiProvider.notifier).reset();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.resetToDefaultDone)));
              }
            },
          ),
          onTap: () => _showApiEditDialog(
            title: context.l10n.kugouApiUrl,
            initial: kugouApi,
            onSave: (v) => ref.read(kugouApiProvider.notifier).set(v),
            onTest: _testConnectivity,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.translate_outlined),
          title: Text(context.l10n.translateApiUrl),
          subtitle:
              Text(translateApi, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _showApiEditDialog(
            title: context.l10n.translateApiUrl,
            initial: translateApi,
            onSave: (v) => ref.read(translateApiProvider.notifier).set(v),
            onTest: _testConnectivity,
          ),
        ),
      ],
    );
  }

  Future<String> _testConnectivity(String url) async {
    try {
      var target = url.trim();
      if (!target.startsWith('http')) target = 'https://$target';
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
      final resp = await dio.get<dynamic>(target);
      return '连通正常（HTTP ${resp.statusCode}）';
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != null) return '服务器可达（HTTP $code）';
      return '连接失败：${e.message ?? e}';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  void _showApiEditDialog({
    required String title,
    required String initial,
    required Future<void> Function(String) onSave,
    required Future<String> Function(String) onTest,
  }) {
    final controller = TextEditingController(text: initial);
    String? testResult;
    bool testing = false;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'https://…',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    icon: testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check, size: 18),
                    label: Text(testing ? context.l10n.testing : context.l10n.testConnectivity),
                    onPressed: testing
                        ? null
                        : () async {
                            setDialogState(() {
                              testing = true;
                              testResult = null;
                            });
                            final r = await onTest(controller.text);
                            setDialogState(() {
                              testing = false;
                              testResult = r;
                            });
                          },
                  ),
                ],
              ),
              if (testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(testResult!,
                      style: Theme.of(ctx).textTheme.bodySmall),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(context.l10n.cancel)),
            FilledButton(
              onPressed: () async {
                final v = controller.text.trim();
                if (v.isNotEmpty) await onSave(v);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 关于 ----------
  // ---------- 诊断 ----------
  Widget _buildDiagnosticsSection() {
    return _Section(
      title: context.l10n.diagnostics,
      children: [
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: Text(context.l10n.errorLogLocation),
          subtitle: FutureBuilder<String?>(
            future: ErrorLogger.instance.currentDirPath(),
            builder: (context, snap) {
              final path = snap.data;
              return Text(
                path ?? context.l10n.unknown,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
          trailing: IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: context.l10n.copyPath,
            onPressed: () async {
              final path = await ErrorLogger.instance.currentDirPath();
              if (path == null) {
                Toast.show(context, context.l10n.unknown);
                return;
              }
              await Toast.copy(context, path);
            },
          ),
          onTap: () async {
            final path = await ErrorLogger.instance.currentDirPath();
            if (path != null) await Toast.copy(context, path);
          },
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text(context.l10n.storagePermissions),
          subtitle: FutureBuilder<bool>(
            future: PermissionGate.instance.ensureStorageWrite(),
            builder: (context, snap) {
              final granted = snap.data ?? false;
              return Text(granted
                  ? context.l10n.permissionGranted
                  : context.l10n.permissionDenied);
            },
          ),
          trailing: TextButton(
            onPressed: () async {
              final ok = await PermissionGate.instance.ensureStorageWrite();
              if (!context.mounted) return;
              Toast.show(
                context,
                ok
                    ? context.l10n.permissionGranted
                    : context.l10n.permissionDenied,
              );
            },
            child: Text(context.l10n.requestPermission),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(context.l10n.recentErrors),
          subtitle: Text(context.l10n.recentErrorsCount(
              ErrorLogger.instance.recent.length.toString())),
          onTap: () => _showRecentErrors(),
        ),
      ],
    );
  }

  void _showRecentErrors() {
    final entries = ErrorLogger.instance.recent;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.recentErrors),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: entries.isEmpty
              ? Center(child: Text(context.l10n.noRecentErrors))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    title: Text(
                      entries[i].split('\n').take(3).join('\n'),
                      style: const TextStyle(fontSize: 11),
                    ),
                    onTap: () => Toast.copy(ctx, entries[i]),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection() {    return _Section(
      title: context.l10n.about,
      children: [
        ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: const Text(AppConfig.appNameCn),
          subtitle: Text('${context.l10n.version} $_version'),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(context.l10n.openSourceLicenses),
          subtitle: Text(context.l10n.licenseDesc),
          onTap: _showLicenseDialog,
        ),
        ListTile(
          leading: const Icon(Icons.system_update_alt_outlined),
          title: Text(context.l10n.checkUpdate),
          subtitle: Text(context.l10n.checkUpdateDesc),
          trailing: const Icon(Icons.chevron_right),
          onTap: _checkUpdate,
        ),
      ],
    );
  }

  Future<void> _checkUpdate() async {
    Toast.show(context, context.l10n.checkingUpdate);
    UpdateInfo info;
    try {
      info = await UpdateChecker.instance.check();
    } catch (e) {
      if (!mounted) return;
      Toast.show(context, context.l10n.updateCheckFailed);
      return;
    }
    if (!mounted) return;
    if (!info.hasUpdate) {
      Toast.show(context, context.l10n.alreadyLatestVersion);
      return;
    }
    await _showUpdateDialog(info);
  }

  Future<void> _showUpdateDialog(UpdateInfo info) async {
    final url = info.acceleratedUrl ?? info.downloadUrl;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.newVersionAvailable),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.versionLabel(info.latestVersion)),
              if (info.releaseNotes != null) ...[
                const SizedBox(height: 12),
                Text(info.releaseNotes!,
                    style: const TextStyle(fontSize: 12, height: 1.4)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.later),
          ),
          if (url != null)
            FilledButton.icon(
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(context.l10n.downloadNow),
              onPressed: () async {
                Navigator.pop(ctx);
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
        ],
      ),
    );
  }

  void _showLicenseDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.openSourceLicenses),
        content: const SingleChildScrollView(
          child: Text(
            '汀澜音乐 Tiernan Music\n\n'
            '本仓库源代码公开可见（Source Available），仅供学习与研究用途。\n\n'
            '【禁止事项】\n'
            '· 禁止将本代码或其衍生作品用于任何商业或非商业用途；\n'
            '· 禁止以任何形式分发、复制、修改后发布本软件；\n'
            '· 禁止将本项目接入的接口用于爬取或批量下载。\n\n'
            '本项目与酷狗音乐官方无任何关联，如有侵权请联系删除。\n\n'
            'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.',
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: Text(context.l10n.knowIt)),
        ],
      ),
    );
  }
}

/// 分组标题卡片
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// 读取当前账号信息。
///
/// SecureStorage 目前只暴露凭证读取，昵称/头像由 auth 模块登录后写入
/// Hive 'settings' box（nickname / avatar 键），此处一并读取。
class FlutterSecureStorageCompat {
  const FlutterSecureStorageCompat();

  Future<Map<String, dynamic>?> readAccounts() async {
    final creds = await SecureStorage.instance.readCredentials();
    if (creds == null) return null;
    final box = Hive.box('settings');
    return {
      'userid': creds.userId,
      'nickname': box.get('nickname') as String?,
      'avatar': box.get('avatar') as String?,
    };
  }
}
