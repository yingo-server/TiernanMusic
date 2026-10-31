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
import 'settings_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _cacheSize = '计算中…';
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
      if (mounted) setState(() => _cacheSize = '无法计算');
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
        title: const Text('清除缓存'),
        content: const Text('将清除图片缓存、接口缓存与歌词翻译缓存，不会删除账号数据。确定继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除')),
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
            .showSnackBar(const SnackBar(content: Text('缓存已清除')));
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
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _buildAccountSection(),
          _buildAppearanceSection(),
          _buildPlaybackSection(),
          _buildCacheSection(),
          _buildApiSection(),
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
      title: '账号',
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
          title: Text(loggedIn ? nickname : '未登录'),
          subtitle: Text(loggedIn ? 'ID: ${_account?['userid'] ?? '-'}' : '点击登录酷狗账号'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await context.push<void>('/login');
            _loadAccount();
          },
        ),
        ListTile(
          leading: const Icon(Icons.switch_account_outlined),
          title: const Text('账号管理'),
          subtitle: const Text('切换或管理已登录的账号'),
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
      ThemeMode.light => '浅色',
      ThemeMode.system => '跟随系统',
      _ => '深色',
    };
    final localeLabel = locale == null
        ? '跟随系统'
        : AppConfig.localeNames[locale.countryCode != null
                ? '${locale.languageCode}_${locale.countryCode}'
                : locale.languageCode] ??
            locale.toString();
    return _Section(
      title: '外观',
      children: [
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: const Text('主题模式'),
          subtitle: Text(themeLabel),
          onTap: () => _showThemeDialog(themeMode),
        ),
        ListTile(
          leading: const Icon(Icons.language_outlined),
          title: const Text('界面语言'),
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
        title: const Text('主题模式'),
        children: [
          for (final (mode, label) in [
            (ThemeMode.dark, '深色'),
            (ThemeMode.light, '浅色'),
            (ThemeMode.system, '跟随系统'),
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
        title: const Text('界面语言'),
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
                  title: const Text('跟随系统'),
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
      LyricDisplayMode.original => '仅原文',
      LyricDisplayMode.bilingual => '双语对照',
      LyricDisplayMode.translation => '仅译文',
    };
    return _Section(
      title: '播放',
      children: [
        ListTile(
          leading: const Icon(Icons.lyrics_outlined),
          title: const Text('歌词显示模式'),
          subtitle: Text(lyricLabel),
          onTap: () => _showLyricModeDialog(lyricMode),
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('默认音质'),
          subtitle: Text(qualityNames[quality] ?? quality),
          onTap: () => _showQualityDialog(quality),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: const Text('Wi-Fi 下自动最高音质'),
          subtitle: const Text('连接 Wi-Fi 时优先播放无损/Hi-Res（预留）'),
          value: wifiHigh,
          onChanged: (v) => ref.read(wifiQualityProvider.notifier).set(v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.signal_cellular_alt),
          title: const Text('流量下降低音质'),
          subtitle: const Text('使用移动网络时自动切换为标准音质（预留）'),
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
        title: const Text('歌词显示模式'),
        children: [
          for (final (mode, label) in [
            (LyricDisplayMode.original, '仅原文'),
            (LyricDisplayMode.bilingual, '双语对照'),
            (LyricDisplayMode.translation, '仅译文'),
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
        title: const Text('默认音质'),
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

  // ---------- 缓存 ----------
  Widget _buildCacheSection() {
    return _Section(
      title: '缓存',
      children: [
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('缓存占用'),
          subtitle: Text(_cacheSize),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新计算',
            onPressed: () {
              setState(() => _cacheSize = '计算中…');
              _loadCacheSize();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: const Text('清除缓存',
              style: TextStyle(color: Colors.redAccent)),
          subtitle: const Text('清除接口、图片与歌词翻译缓存'),
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
          title: const Text('酷狗 API 地址'),
          subtitle: Text(kugouApi, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: '重置为默认',
            onPressed: () async {
              await ref.read(kugouApiProvider.notifier).reset();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已重置为默认地址')));
              }
            },
          ),
          onTap: () => _showApiEditDialog(
            title: '酷狗 API 地址',
            initial: kugouApi,
            onSave: (v) => ref.read(kugouApiProvider.notifier).set(v),
            onTest: _testConnectivity,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.translate_outlined),
          title: const Text('翻译 API 地址'),
          subtitle:
              Text(translateApi, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _showApiEditDialog(
            title: '翻译 API 地址',
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
                    label: Text(testing ? '测试中…' : '测试连通性'),
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
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final v = controller.text.trim();
                if (v.isNotEmpty) await onSave(v);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 关于 ----------
  Widget _buildAboutSection() {
    return _Section(
      title: '关于',
      children: [
        ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: const Text(AppConfig.appNameCn),
          subtitle: Text('版本 $_version'),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('开源许可证'),
          subtitle: const Text('源代码可见，禁止使用'),
          onTap: _showLicenseDialog,
        ),
        ListTile(
          leading: const Icon(Icons.code_outlined),
          title: const Text('GitHub 仓库'),
          subtitle: const Text('github.com/tiernan/music'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () async {
            final uri = Uri.parse('https://github.com/tiernan/music');
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
      ],
    );
  }

  void _showLicenseDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开源许可证'),
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
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
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
