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
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart' show SectionHeader;
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

  /// 日志目录路径（**必须是 State 字段**）
  ///
  /// 若在 build() 里直接 `ErrorLogger.instance.currentDirPath()`，
  /// 每次 build 都会新建一个 Future → 完成 → setState → 再 build → 无限循环。
  late Future<String?> _logDirPath;

  /// 存储写入权限状态（同上，必须提为字段避免无限重建）
  late Future<bool> _storageGranted;

  /// 「检查更新」进行中（用于显示进度圈）
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
    _loadVersion();
    _loadAccount();
    _logDirPath = ErrorLogger.instance.currentDirPath();
    _storageGranted = PermissionGate.instance.hasStorageWriteAccess();
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
    // 危险操作：error 色 + 二次确认 Dialog。
    final confirm = await showDestructiveConfirm(
      context,
      title: context.l10n.clearCache,
      message: context.l10n.clearCacheConfirm,
      confirmLabel: context.l10n.clear,
    );
    if (!confirm) return;

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
        Toast.show(context, context.l10n.cacheCleared);
      }
      _loadCacheSize();
    } catch (e) {
      if (mounted) {
        Toast.show(context, context.l10n.clearCacheFailed('$e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // M3 规范：顶层页面用大标题（SliverAppBar.large）。
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(context.l10n.settings),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildAccountSection(),
                  _buildAppearanceSection(),
                  _buildPlaybackSection(),
                  _buildDownloadSection(),
                  _buildCacheSection(),
                  _buildApiSection(),
                  _buildDiagnosticsSection(),
                  _buildAboutSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 统一的「可点击进入下一级」列表项：右侧用 chevron 指示可导航。
  Widget _navTile({
    required IconData leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(leading),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  // ---------- 账号 ----------
  Widget _buildAccountSection() {
    final avatar = _account?['avatar'] as String?;
    final nickname = _account?['nickname'] as String?;
    final loggedIn = nickname != null && nickname.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.account),
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
          subtitle: Text(
              loggedIn
                  ? context.l10n.userIdLabel('${_account?['userid'] ?? '-'}')
                  : context.l10n.login),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await context.push<void>('/login');
            _loadAccount();
          },
        ),
        _navTile(
          leading: Icons.switch_account_outlined,
          title: context.l10n.accountManage,
          subtitle: context.l10n.switchAccountSubtitle,
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
    final localeLabel = locale == null
        ? context.l10n.themeSystem
        : AppConfig.localeNames[locale.countryCode != null
                ? '${locale.languageCode}_${locale.countryCode}'
                : locale.languageCode] ??
            locale.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.appearance),
        // M3 规范：少量互斥选项的「单选切换」用 SegmentedButton，
        // 而不是 ListTile + Dialog 弹层。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.themeMode,
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(context.l10n.themeLight),
                      icon: const Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(context.l10n.themeDark),
                      icon: const Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(context.l10n.themeSystem),
                      icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                    ),
                  ],
                  selected: {themeMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => ref
                      .read(themeModeProvider.notifier)
                      .set(s.first),
                ),
              ),
            ],
          ),
        ),
        _navTile(
          leading: Icons.language_outlined,
          title: context.l10n.appLanguage,
          subtitle: localeLabel,
          onTap: () => _showLocaleDialog(locale),
        ),
      ],
    );
  }

  void _showLocaleDialog(Locale? current) {
    String? codeOf(Locale? l) => l == null
        ? 'system'
        : (l.countryCode != null
            ? '${l.languageCode}_${l.countryCode}'
            : l.languageCode);
    // M3 规范：长列表选项用底部弹层（showModalBottomSheet），不用居中 Dialog。
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(context.l10n.appLanguage,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                itemCount: AppConfig.supportedLocales.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return RadioListTile<String>(
                      value: 'system',
                      groupValue: codeOf(current),
                      title: Text(context.l10n.themeSystem),
                      onChanged: (_) {
                        ref.read(localeProvider.notifier).set(null);
                        Navigator.pop(ctx);
                      },
                    );
                  }
                  final code = AppConfig.supportedLocales[i - 1];
                  return RadioListTile<String>(
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
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------- 播放 ----------
  Widget _buildPlaybackSection() {
    final lyricMode = ref.watch(lyricModeProvider);
    final quality = ref.watch(defaultQualityProvider);
    final wifiHigh = ref.watch(wifiQualityProvider);
    final cellularLow = ref.watch(cellularQualityProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.playback),
        // M3 规范：少量互斥选项用 SegmentedButton（单选语义）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.lyricDisplayMode,
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<LyricDisplayMode>(
                  segments: [
                    ButtonSegment(
                      value: LyricDisplayMode.original,
                      label: Text(context.l10n.lyricModeOriginal),
                    ),
                    ButtonSegment(
                      value: LyricDisplayMode.bilingual,
                      label: Text(context.l10n.lyricModeBilingual),
                    ),
                    ButtonSegment(
                      value: LyricDisplayMode.translation,
                      label: Text(context.l10n.lyricModeTranslation),
                    ),
                  ],
                  selected: {lyricMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => ref
                      .read(lyricModeProvider.notifier)
                      .set(s.first),
                ),
              ),
            ],
          ),
        ),
        _navTile(
          leading: Icons.high_quality_outlined,
          title: context.l10n.defaultQuality,
          subtitle: qualityNames[quality] ?? quality,
          onTap: () => _showQualityDialog(quality),
        ),
        // 状态切换用 SwitchListTile（label 在左，switch 在右）
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

  void _showQualityDialog(String current) {
    // M3 规范：选项列表用底部弹层，不用居中 Dialog。
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(context.l10n.defaultQuality,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------- 下载 ----------
  Widget _buildDownloadSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.downloadManagement),
        _navTile(
          leading: Icons.download_for_offline_outlined,
          title: context.l10n.downloads,
          subtitle: context.l10n.downloadManagement,
          onTap: () => context.push<void>('/downloads'),
        ),
      ],
    );
  }

  // ---------- 缓存 ----------
  Widget _buildCacheSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.cache),
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
        // 危险操作：删除类用 error 色 + 二次确认
        ListTile(
          leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          title: Text(context.l10n.clearCache,
              style: TextStyle(color: theme.colorScheme.error)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.apiSection),
        ListTile(
          leading: const Icon(Icons.api_outlined),
          title: Text(context.l10n.kugouApiUrl),
          subtitle:
              Text(kugouApi, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: context.l10n.resetToDefault,
            onPressed: () async {
              await ref.read(kugouApiProvider.notifier).reset();
              if (mounted) {
                Toast.show(context, context.l10n.resetToDefaultDone);
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
          trailing: const Icon(Icons.chevron_right),
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
      return context.l10n.apiConnectionOk(resp.statusCode ?? 0);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != null) return context.l10n.apiServerReachable(code);
      return context.l10n.apiConnectionFailed(e.message ?? e.toString());
    } catch (e) {
      return context.l10n.apiConnectionFailed(e.toString());
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
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(testing
                      ? context.l10n.testing
                      : context.l10n.testConnectivity),
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

  // ---------- 诊断 ----------
  Widget _buildDiagnosticsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.diagnostics),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: Text(context.l10n.errorLogLocation),
          subtitle: FutureBuilder<String?>(
            future: _logDirPath,
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
            future: _storageGranted,
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
              if (!mounted) return;
              // 重新查询状态并刷新展示
              final future = PermissionGate.instance.hasStorageWriteAccess();
              setState(() => _storageGranted = future);
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
              ErrorLogger.recent.length.toString())),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showRecentErrors(),
        ),
      ],
    );
  }

  void _showRecentErrors() {
    final entries = ErrorLogger.recent;
    // M3 规范：长列表用底部弹层，不用居中 Dialog。
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(context.l10n.recentErrors,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(child: Text(context.l10n.noRecentErrors))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (_, i) => ListTile(
                          dense: true,
                          title: Text(
                            entries[i].split('\n').take(3).join('\n'),
                            style: Theme.of(ctx).textTheme.labelSmall,
                          ),
                          onTap: () => Toast.copy(ctx, entries[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 关于 ----------
  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.about),
        ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: const Text(AppConfig.appNameCn),
          subtitle: Text('${context.l10n.version} $_version'),
        ),
        _navTile(
          leading: Icons.description_outlined,
          title: context.l10n.openSourceLicenses,
          subtitle: context.l10n.licenseDesc,
          onTap: _showLicenseDialog,
        ),
        ListTile(
          leading: const Icon(Icons.system_update_alt_outlined),
          title: Text(context.l10n.checkUpdate),
          subtitle: Text(context.l10n.checkUpdateDesc),
          // 弹 Dialog 的入口不用「进入下一页」的箭头图标；
          // 检查中用 CircularProgressIndicator 代替图标。
          trailing: _checkingUpdate
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _checkingUpdate ? null : _checkUpdate,
        ),
      ],
    );
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    Toast.show(context, context.l10n.checkingUpdate);
    try {
      final info = await UpdateChecker.instance.check();
      if (!mounted) return;
      if (!info.hasUpdate) {
        Toast.show(context, context.l10n.alreadyLatestVersion);
        return;
      }
      await _showUpdateDialog(info);
    } catch (e) {
      if (!mounted) return;
      Toast.show(context, context.l10n.updateCheckFailed);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
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
                    style: Theme.of(ctx).textTheme.bodySmall),
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
                if (!await canLaunchUrl(uri)) {
                  if (context.mounted) {
                    Toast.show(context, context.l10n.openFailed);
                  }
                  return;
                }
                final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
                if (!ok && context.mounted) {
                  Toast.show(context, context.l10n.openFailed);
                }
              },
            ),
        ],
      ),
    );
  }

  void _showLicenseDialog() {
    // M3 规范：纯内容展示（无需决策）用底部弹层，不用 Dialog。
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(context.l10n.openSourceLicenses,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Text(context.l10n.licenseBody),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(context.l10n.knowIt),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
