import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/cache/cache_manager.dart';
import '../../../core/config/app_config.dart';
import '../../../core/image/app_image_cache.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/settings_provider.dart';
import '../../../core/utils/error_logger.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/utils/permission_gate.dart';
import '../../../core/utils/toast.dart';
import '../../../core/utils/update_checker.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/song_tile.dart' show SectionHeader;
import '../../../l10n/l10n.dart';
import '../../auth/data/account_manager.dart';
import '../../auth/data/auth_providers.dart';
import '../../download/data/storage_permission_service.dart';
import '../../player/data/models.dart';
import 'settings_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with WidgetsBindingObserver {
  String _cacheSize = '';
  String _version = '';
  Map<String, dynamic>? _account;

  /// 音质档位名称（运行时从 l10n 取，随语言切换；替代原硬编码中文常量）
  /// V399-B3：新增蝰蛇三档 + 魔法六档（魔法档匿名可用）。
  Map<String, String> _qualityNames(BuildContext c) => {
        '128': c.l10n.quality128,
        '320': c.l10n.quality320,
        'flac': c.l10n.qualityFlac,
        // key 必须与 AudioQuality.value 一致（'high'）；
        // 旧版写的 'hires' 由 AudioQuality.fromString 兼容
        'high': c.l10n.qualityHigh,
        'super': c.l10n.qualitySuper,
        // V399-B3：蝰蛇三档（VIP 态真实返回；非 VIP 选它时由解析链
        // 在族内降级并明确报因，不降为普通音源）
        AudioQuality.viperTape.value: c.l10n.qualityViperTape,
        AudioQuality.viperClear.value: c.l10n.qualityViperClear,
        AudioQuality.viperAtmos.value: c.l10n.qualityViperAtmos,
        // V399-B3：魔法六档（特殊音源，匿名也可用；不进通用 fallback）
        AudioQuality.magicPiano.value: c.l10n.qualityMagicPiano,
        AudioQuality.magicAcappella.value: c.l10n.qualityMagicAcappella,
        AudioQuality.magicDj.value: c.l10n.qualityMagicDj,
        AudioQuality.magicSurnay.value: c.l10n.qualityMagicSurnay,
        AudioQuality.magicSubwoofer.value: c.l10n.qualityMagicSubwoofer,
        AudioQuality.magicAncient.value: c.l10n.qualityMagicAncient,
      };

  /// 日志目录路径（**必须是 State 字段**）
  ///
  /// 若在 build() 里直接 `ErrorLogger.instance.currentDirPath()`，
  /// 每次 build 都会新建一个 Future → 完成 → setState → 再 build → 无限循环。
  late Future<String?> _logDirPath;

  /// 存储写入权限状态（同上，必须提为字段避免无限重建）
  late Future<bool> _storageGranted;

  /// V37-LOG-10：当前存储根路径与模式（'root'/'download'），
  /// 必须是 State 字段（避免 build 内新建 Future → 无限重建，同 _logDirPath）
  late Future<(String, String)> _storageRoot;

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
    // V37-LOG-10：根路径 + 模式一次性读取
    _storageRoot = _loadStorageRoot();
    // V37-PERM-02：「授权所有文件访问」跳的是系统设置页（无弹窗回调），
    // 用户在系统侧授权/取消授权后回到 App，只能靠 resumed 事件重新查询。
    // 没有 resumed 刷新时，UI 会一直停留在授权前的旧状态——这正是
    // 「权限请求网关没做好」的表象之一（第 20 条：生命周期监听对称释放）。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // V37-PERM-02：从系统设置页返回（resumed）时重查存储授权态与根目录。
    // 查询是纯只读（hasStorageWriteAccess/resolveRoot 均不弹窗），开销可控。
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        _storageGranted = PermissionGate.instance.hasStorageWriteAccess();
        _storageRoot = _loadStorageRoot();
      });
    }
  }

  /// V37-LOG-10：读取当前生效存储根（路径, 模式）。
  /// 失败时返回占位值，绝不抛异常打断设置页构建（第 11 条降级有界）。
  /// V399-B1：resolveRoot / resolveRootMode 并行（后者内部含写探针，
  /// 串行会使该 tile 延迟翻倍）。
  Future<(String, String)> _loadStorageRoot() async {
    try {
      final service = StoragePermissionService.instance;
      final results =
          await Future.wait([service.resolveRoot(), service.resolveRootMode()]);
      return (results[0], results[1]);
    } catch (_) {
      return ('-', 'download');
    }
  }

  /// V37-LOG-10：授权所有文件访问（跳系统授权页），返回后刷新状态。
  Future<void> _requestAllFilesAccess() async {
    // V37-PERM-02：permission_handler 对 MANAGE_EXTERNAL_STORAGE 的 request()
    // 会先尝试直接跳转系统授权页（部分 ROM 成功），也可能静默失败不跳转
    //（无返回跳转回调，直接落回当前态）。跳转失败时 fallback 到
    // openAppSettings()，保证用户总能到达可授权的系统界面。
    final ok = await StoragePermissionService.instance.requestAllFilesAccess();
    if (!ok) await PermissionGate.instance.openSettings();
    if (!mounted) return;
    setState(() {
      _storageRoot = _loadStorageRoot();
      _storageGranted = PermissionGate.instance.hasStorageWriteAccess();
    });
    // V37-PERM-03：request() 的返回值不是本次授权结果——系统授权页
    // 跳转**没有结果回调**，request 立即返回当前态（未授权 false）。
    // 若把它当「用户拒绝了」弹「未授权」，用户从系统页授权回来反而
    // 看到失败提示（第 31 条：误导性反馈）。resumed 刷新（V37-PERM-02）
    // 已负责回填真实状态，这里不再弹误导性提示。
  }

  @override
  void dispose() {
    // V37-PERM-02：与 initState 的 addObserver 对称释放（第 20 条）。
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      // 统计口径 = 可清理缓存：ApplicationSupport（Hive 缓存 box）+ Temporary。
      // Documents 里是下载的音乐/MV 与错误日志，不能被「清除缓存」清理；
      // 计入会导致「清了不变小」——统计口径须与清理口径一致（审查报告 F3）。
      final dirs = [
        await getApplicationSupportDirectory(),
        await getTemporaryDirectory(),
      ];
      for (final dir in dirs) {
        if (await dir.exists()) {
          // F4-47（审查③-B，P3）：递归遍历 + 每文件一次 await length() 会阻塞主 isolate
          // （缓存目录文件多时进设置页明显掉帧）。改为在后台 isolate 里同步统计，
          // 只回传一个 int（第 24 条按需计算、第 26 条热路径零分配）。
          total += await compute(_dirSizeBytes, dir.path);
        }
      }
      if (mounted) setState(() => _cacheSize = _formatBytes(total));
    } catch (_) {
      if (mounted) setState(() => _cacheSize = context.l10n.cannotCalculate);
    }
  }

  static String _formatBytes(int bytes) {    if (bytes < 1024) return '$bytes B';
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
      for (final name in ['api_cache', 'image_cache', 'lyric_translations', LyricPersistentCache.boxName]) {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).clear();
        }
      }
      // 清除临时目录
      // ⚠️ 必须排除下载临时目录（downloads_tmp）：否则正在下载的任务
      // 会在 publish 阶段找不到文件而失败，且报错与真实原因无关（终审 P1-6）。
      final tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        await for (final entity in tmp.list(recursive: false)) {
          if (entity.path.endsWith('downloads_tmp')) continue;
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
      // F4-38（审查③-B，P2）：失败不得把 FileSystemException 原文（含绝对路径/errno）
      // 弹给用户——技术细节外泄且无法据此行动（第 3 条契约 / 第 9 条反馈）。
      debugPrint('[settings] 清缓存失败: $e');
      if (mounted) {
        Toast.show(context, context.l10n.clearCacheFailed(''));
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
                  // V37-LOG-10：「存储与日志」区（verbose 开关 + 根路径 + 授权入口）
                  _buildStorageAndLoggingSection(),
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

  // ---------- 存储与日志（V37-LOG-10） ----------
  Widget _buildStorageAndLoggingSection() {
    final verbose = ref.watch(verboseLoggingProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.storageRootPath),
        // verbose 日志开关（settings_provider.verboseLoggingProvider，
        // 持久化 Hive settings box；main.dart watch 同步到 ErrorLogger）
        SwitchListTile(
          secondary: const Icon(Icons.receipt_long_outlined),
          title: Text(context.l10n.verboseLogging),
          subtitle: Text(context.l10n.verboseLoggingHint),
          value: verbose,
          onChanged: (v) =>
              ref.read(verboseLoggingProvider.notifier).set(v),
        ),
        // 当前存储根路径（实际生效路径 + 模式说明）
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(context.l10n.storageRootPath),
          subtitle: FutureBuilder<(String, String)>(
            future: _storageRoot,
            builder: (context, snap) {
              final data = snap.data;
              final path = data?.$1 ?? context.l10n.unknown;
              // F4-46 同口径：界面只显示可读的路径与模式，完整路径可复制
              final mode = data?.$2 == 'root'
                  ? context.l10n.storageModeRoot
                  : context.l10n.storageModeDownload;
              // V399-B2（B2-d）：展示「探测到的实际可写路径」——
              // resolveRoot 每次实测写入能力；探测失败时附失败原因，
              // 不再把「声称的路径」当「实际可写」误导用户（第 31 条）。
              final probeErr = StoragePermissionService.lastProbeError;
              return Text(probeErr == null
                  ? '$path\n$mode'
                  : '$path\n$mode\n${context.l10n.storageProbeFailed}: $probeErr');
            },
          ),
          isThreeLine: true,
          trailing: IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: context.l10n.copyPath,
            onPressed: () async {
              final (path, _) = await _storageRoot;
              if (!context.mounted) return;
              await Toast.copy(context, path);
            },
          ),
        ),
        // 「授权所有文件访问」按钮：已授权时隐藏（无效入口，F4-45 同口径）
        FutureBuilder<(String, String)>(
          future: _storageRoot,
          builder: (context, snap) {
            if (snap.data?.$2 == 'root') return const SizedBox.shrink();
            return ListTile(
              leading: const Icon(Icons.security_outlined),
              title: Text(context.l10n.grantAllFilesAccess),
              subtitle: Text(context.l10n.storagePermissions),
              trailing: const Icon(Icons.open_in_new),
              onTap: _requestAllFilesAccess,
            );
          },
        ),
      ],
    );
  }

  /// 统一的「可点击进入下一级」列表项：右侧用 chevron 指示可导航。
  Widget _navTile({
    required IconData leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    // V37-UI-04：条件可见性（去重入口用），false 时不构建该 ListTile
    bool visible = true,
  }) {
    if (!visible) return const SizedBox.shrink();
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
    // 登录态单一事实源：watch authStateProvider，退出/切换后即时刷新（F5）
    final user = ref.watch(authStateProvider).valueOrNull;
    final loggedIn = user != null && user.userid.isNotEmpty;
    // 昵称/头像优先用 authState，缺失时回退 Hive settings 盒（本地缓存资料）
    final avatar = (user?.avatar.isNotEmpty ?? false)
        ? user!.avatar
        : _account?['avatar'] as String?;
    final nickname = (user?.nickname.isNotEmpty ?? false)
        ? user!.nickname
        : _account?['nickname'] as String?;
    final userid = loggedIn ? user!.userid : '${_account?['userid'] ?? '-'}';
    // 可切换的账号列表（排除当前账号）
    final otherAccounts = loggedIn
        ? AccountManager.instance.accounts
            .where((a) => a.userid != user!.userid)
            .toList()
        : <AccountRecord>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.account),
        ListTile(
          leading: CircleAvatar(
            radius: 22,
            // F4-42（审查③-B，P3）：头像走全项目统一的 AppImageCache（磁盘缓存 +
            // 解码尺寸上限），裸 NetworkImage 每次进入都重新下载（第 23/25 条）。
            backgroundImage: avatar != null && avatar.isNotEmpty
                ? CachedNetworkImageProvider(avatar,
                    cacheManager: AppImageCache.instance,
                    maxWidth: 132)
                : null,
            child: avatar == null || avatar.isEmpty
                ? const Icon(Icons.person_outline)
                : null,
          ),
          title: Text(loggedIn
              ? ((nickname != null && nickname.isNotEmpty)
                  ? nickname
                  : user!.userid)
              : context.l10n.notLoggedIn),
          subtitle: Text(
              loggedIn
                  ? context.l10n.userIdLabel(userid)
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
          // F4-40（审查③-B，P2）：该入口此前与上面的「账号」条目同义（都跳 /login），
          // 与 subtitle 承诺的「切换账号」不符。改为打开账号切换弹层，
          // 无其他账号时再回落到登录页（第 30 条命名即文档）。
          // V37-UI-04：已登录且存在其他账号时，「切换账号」项承担同功能，
          // 本项隐藏，去重（第 32 条：重复入口是维护成本）。
          onTap: () async {
            if (loggedIn && otherAccounts.isNotEmpty) {
              await _showSwitchAccountDialog();
            } else {
              await context.push<void>('/login');
              _loadAccount();
            }
          },
          visible: !(loggedIn && otherAccounts.isNotEmpty),
        ),
        // 切换账号：仅已登录且存在其他账号时显示（F3）
        if (loggedIn && otherAccounts.isNotEmpty)
          _navTile(
            leading: Icons.swap_horiz_outlined,
            title: context.l10n.switchAccount,
            subtitle: null,
            onTap: _showSwitchAccountDialog,
          ),
        // 退出登录：仅已登录时显示，红色 + 二次确认（F3）
        if (loggedIn)
          ListTile(
            leading: Icon(Icons.logout,
                color: Theme.of(context).colorScheme.error),
            title: Text(context.l10n.logout,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
            onTap: _logout,
          ),
      ],
    );
  }

  /// 退出登录（二次确认）
  Future<void> _logout() async {
    final ok = await showDestructiveConfirm(
      context,
      title: context.l10n.logout,
      message: context.l10n.logoutConfirm,
      confirmLabel: context.l10n.logout,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(authStateProvider.notifier).logout();
      if (mounted) Toast.show(context, context.l10n.logoutSuccess);
    } catch (e) {
      if (mounted) Toast.show(context, context.l10n.logoutFailed('$e'));
    }
  }

  /// 多账号切换（底部弹层选择账号）
  Future<void> _showSwitchAccountDialog() async {
    final current = ref.read(authStateProvider).valueOrNull;
    final accounts = AccountManager.instance.accounts
        .where((a) => a.userid != current?.userid)
        .toList();
    if (accounts.isEmpty) return;
    final selected = await showModalBottomSheet<AccountRecord>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(context.l10n.switchAccount,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            for (final a in accounts)
              ListTile(
                leading: CircleAvatar(
                  radius: 18,
                  backgroundImage: a.avatar.isNotEmpty
                      ? CachedNetworkImageProvider(a.avatar,
                          cacheManager: AppImageCache.instance, maxWidth: 108)
                      : null,
                  child: a.avatar.isEmpty
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                title: Text(a.nickname.isNotEmpty ? a.nickname : a.userid),
                subtitle: Text(context.l10n.userIdLabel(a.userid)),
                onTap: () => Navigator.pop(ctx, a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    try {
      await ref
          .read(authStateProvider.notifier)
          .switchAccount(selected.userid);
      if (mounted) {
        Toast.show(context, context.l10n.switchAccountSuccess);
        _loadAccount();
      }
    } on StateError {
      // F4-41（审查③-B，P3）：token 失效的账号会永远留在选择列表里、每次点都失败。
      // 失效即从本地账号表移除并提示重登（第 5 条状态单一来源 / 第 11 条降级退出条件）。
      await AccountManager.instance.remove(selected.userid);
      if (mounted) {
        Toast.show(context, context.l10n.accountNeedRelogin);
        _loadAccount();
      }
    } catch (e) {
      if (mounted) Toast.show(context, context.l10n.switchAccountFailed(friendlyError(e)));
    }
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
                // F4-39（审查③-B，P2）：三段 SegmentedButton 在 360dp + 中文/大字号下
                // 必然溢出——去掉与文案重复的 18px 图标并压缩内边距，
                // 把段宽的余量还给文字（第 24 条布局健壮性/热路径零分配）。
                child: SegmentedButton<ThemeMode>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(context.l10n.themeLight),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(context.l10n.themeDark),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(context.l10n.themeSystem),
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
                  // F4-39 同源：窄屏 + 长语言（Bilingual/Übersetzung）下三段仍会溢出，
                  // 统一压缩密度与内边距。
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
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
          subtitle: _qualityNames(context)[quality] ?? quality,
          onTap: () => _showQualityDialog(quality),
        ),
        // V34-UI-04（修复②，P2）：删除「Wi-Fi 自动最高音质 / 流量省流」两个
        // 预留假开关。二者无任何消费方（grep 证实 provider 仅设置页自身读写），
        // 用户切换后行为不变（审查②：任务流 6）——第 32 条死代码零容忍。
        // provider 已从 settings_providers.dart 同步移除。
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
            for (final entry in _qualityNames(context).entries)
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
  // 批3检3 F1/F2：删除「API 地址」设置。当前直连架构下 API 地址由
  // AppConfig 常量决定，此设置项从未生效，删除以免误导用户。

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
              // F4-46（审查③-B，P3）：设备内部绝对路径（/data/user/0/...）对用户无意义、
              // 且暴露目录结构；界面只显示末级目录名，完整路径仍可复制给开发者（第 3 条）。
              final short = (path == null || path.isEmpty)
                  ? context.l10n.unknown
                  : '…/${path.split('/').where((s) => s.isNotEmpty).last}';
              return Text(
                short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
          trailing: IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: context.l10n.copyPath,
            onPressed: () async {
              final path = await ErrorLogger.instance.currentDirPath();
              if (!context.mounted) return;
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
          trailing: FutureBuilder<bool>(
            future: _storageGranted,
            builder: (context, snap) {
              // F4-45（审查③-B，P3）：已授权时不再给出「申请权限」按钮
              // （点了会重复触发系统授权流程，属无效入口，第 30 条名称与行为一致）。
              if (snap.data == true) {
                return Text(context.l10n.permissionGranted,
                    style: Theme.of(context).textTheme.labelMedium);
              }
              return TextButton(
                onPressed: () async {
                  final ok = await PermissionGate.instance.ensureStorageWrite();
                  if (!context.mounted) return;
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
              );
            },
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
                          // F4-43（审查③-B，P2）：不再把原始异常文本（含类名/绝对路径/堆栈）
                          // 直接渲染给用户——列表只显示序号，完整内容仍可点击复制上报
                          // （第 9 条可观测 / 第 3 条契约：技术细节不进用户界面）。
                          title: Text(
                            '${context.l10n.techDetail} ${i + 1}',
                            style: Theme.of(ctx).textTheme.labelLarge,
                          ),
                          trailing: const Icon(Icons.copy_all_outlined, size: 18),
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
          // F4-44（审查③-B，P3）：非中文语言下不再固定显示中文应用名；
          // 版本号未取回前显示占位符，不出现「版本：」空白（第 4 条/第 30 条）。
          title: Text(context.l10n.appName),
          subtitle: Text(
              '${context.l10n.version} ${_version.isEmpty ? '-' : _version}'),
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
                Text(
                  // E4：release notes 是 Markdown，去掉 **粗体**/标题#/列表- 符号，
                  // 列表项统一为「· 」，不引入 markdown 依赖。
                  info.releaseNotes!
                      .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
                      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
                      .replaceAll(RegExp(r'^[-*]\s?', multiLine: true), '· '),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
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

/// 递归统计目录占用字节数（在后台 isolate 执行，见 F4-47）。
int _dirSizeBytes(String path) {
  var total = 0;
  try {
    for (final entity in Directory(path).listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } catch (_) {
          // 单个文件读取失败（权限/已删除）不影响整体统计
        }
      }
    }
  } catch (_) {
    // 目录不可读 → 返回已累计值（第 11 条降级退出条件）
  }
  return total;
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
