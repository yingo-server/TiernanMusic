/// 存储状态诊断页（v5.3-R2 P3，PLAN「权限网关（状态透出）」落地）。
///
/// 数据源单一来源（第 5 条）：只调 `StoragePermissionService` 现有公开 API
/// （resolveRoot / isAllFilesAccessGranted / requestAllFilesAccess），
/// 不复刻任何判定逻辑、不 import features/*/data、不触网。
///
/// 满足 PLAN P3 四要素：
///  1. 五级回退链逐级 ✓/✗（由生效 level 推导：L≤生效级=✓，其后=未生效）
///  2. 当前生效级别 + 实际路径（可复制）+ 模式说明
///  3. 一键重新探测（loading 态防连点，质量要求 3）
///  4. 跳系统授权 + 返回后自动重探测；按钮可见性按授权态推导（修 C-23）
///
/// 三态渲染（第 16 条）：loading=进度指示 / error=原因+重试 / data=结果，
/// 禁止空 catch 静默降级（修 C-21 页面侧）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_permission.dart';
import '../../../core/utils/toast.dart';
import '../../../l10n/l10n.dart';

/// 诊断页状态（页面内 StateNotifier，不进全局 provider——
/// 生命周期与页面一致，避免全局常驻探测状态）。
sealed class StorageDiagState {
  const StorageDiagState();
}

/// 探测进行中。
class StorageDiagLoading extends StorageDiagState {
  const StorageDiagLoading();
}

/// 探测失败（resolveRoot 抛出异常，如 MissingPluginException）。
class StorageDiagError extends StorageDiagState {
  const StorageDiagError(this.message);

  final String message;
}

/// 探测成功。
class StorageDiagData extends StorageDiagState {
  const StorageDiagData(this.resolution);

  final StorageResolution resolution;
}

class StorageDiagController extends StateNotifier<StorageDiagState> {
  StorageDiagController() : super(const StorageDiagLoading()) {
    probe();
  }

  /// 探测中标志：防连点（质量要求 3），与状态分开（resumed 重探测时
  /// 状态保持 Data、按钮仍需禁用）。
  bool _busy = false;

  Future<void> probe() async {
    if (_busy) return;
    _busy = true;
    // 探测期间保留旧数据展示（如有），不闪成整页 loading（第 16 条：
    // 刷新 ≠ 清空）。首次探测才进 Loading 态。
    if (state is StorageDiagData) {
      state = StorageDiagRefreshing((state as StorageDiagData).resolution);
    } else {
      state = const StorageDiagLoading();
    }
    try {
      final res = await StoragePermissionService.instance.resolveRoot();
      state = StorageDiagData(res);
    } catch (e) {
      // 第 6/9 条：捕获必须留痕；页面给「发生了什么 + 下一步」。
      debugPrint('[storage-diag] resolveRoot failed: $e');
      state = StorageDiagError(e.toString());
    } finally {
      _busy = false;
    }
  }
}

/// 刷新中（保留旧数据 + 细进度条）。
class StorageDiagRefreshing extends StorageDiagState {
  const StorageDiagRefreshing(this.resolution);

  final StorageResolution resolution;
}

final storageDiagProvider =
    StateNotifierProvider<StorageDiagController, StorageDiagState>(
        (ref) => StorageDiagController());

/// 五级回退链的固定展示口径（与 storage_permission.dart 注释一一对应）。
const _levelNames = <int, String>{
  1: 'TierNanMusic（根目录）',
  2: 'Download/TiernanMusic（MediaStore）',
  3: 'Download/TiernanMusic（publicDir）',
  4: 'App 外部私有目录',
  5: '应用内部私有目录（兜底）',
};

/// 存储状态诊断页。
class StorageDiagPage extends ConsumerStatefulWidget {
  const StorageDiagPage({super.key});

  @override
  ConsumerState<StorageDiagPage> createState() => _StorageDiagPageState();
}

class _StorageDiagPageState extends ConsumerState<StorageDiagPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // PLAN P3：授权页返回（resumed）自动重探测。
    if (state == AppLifecycleState.resumed) {
      ref.read(storageDiagProvider.notifier).probe();
    }
  }

  Future<void> _goGrant() async {
    // requestAllFilesAccess 内部跳系统「所有文件访问」页并等返回真实授权态。
    // 异常留痕（第 9 条），不静默。
    bool ok = false;
    try {
      ok = await StoragePermissionService.instance.requestAllFilesAccess();
    } catch (e) {
      debugPrint('[storage-diag] requestAllFilesAccess failed: $e');
    }
    if (!mounted) return;
    // 返回后无论结果都重探测（授权态与写探针可能都变了）。
    ref.read(storageDiagProvider.notifier).probe();
    if (!mounted) return;
    final l = context.l10n;
    Toast.show(context, ok ? l.permissionGranted : l.permissionDenied);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final state = ref.watch(storageDiagProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.storageDiag)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // 授权态卡片：按钮可见性按真实授权态推导（修 C-23），
            // 而非 mode==root 推导。
            FutureBuilder<bool>(
              future:
                  StoragePermissionService.instance.isAllFilesAccessGranted(),
              builder: (context, snap) {
                final granted = snap.data ?? false;
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      granted
                          ? Icons.verified_user_outlined
                          : Icons.gpp_maybe_outlined,
                      color: granted
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    title: Text(l.permissionDenied),
                    subtitle: Text(granted
                        ? l.permissionGranted
                        : '${l.permissionDenied} · ${l.goGrant}'),
                    trailing: snap.connectionState == ConnectionState.waiting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : granted
                            ? null
                            : TextButton(
                                onPressed: _goGrant,
                                child: Text(l.goGrant),
                              ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            switch (state) {
              StorageDiagLoading() => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: CircularProgressIndicator(),
                  ),
                ),
              StorageDiagError(:final message) => _DiagErrorView(
                  message: message,
                  onRetry: () =>
                      ref.read(storageDiagProvider.notifier).probe()),
              StorageDiagRefreshing(:final resolution) => _ResultList(
                  resolution: resolution,
                  refreshing: true,
                  onReprobe: () =>
                      ref.read(storageDiagProvider.notifier).probe()),
              StorageDiagData(:final resolution) => _ResultList(
                  resolution: resolution,
                  refreshing: false,
                  onReprobe: () =>
                      ref.read(storageDiagProvider.notifier).probe()),
            },
          ],
        ),
      ),
    );
  }
}

/// 探测失败视图：「发生了什么 + 下一步」（PLAN P4 错误态结构）。
class _DiagErrorView extends StatelessWidget {
  const _DiagErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded,
              size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(l.storageProbeFailedShort,
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(l.retry),
          ),
        ],
      ),
    );
  }
}

/// 探测结果区：生效级别 + 路径 + 五级回退链逐级 ✓/✗ + 探测历史。
class _ResultList extends StatelessWidget {
  const _ResultList({
    required this.resolution,
    required this.refreshing,
    required this.onReprobe,
  });

  final StorageResolution resolution;
  final bool refreshing;
  final VoidCallback onReprobe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final activeLevel = resolution.level;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 生效级别 + 模式（C-57 根治：不再用一句「Download 模式」覆盖 L2-L5，
        // 直接展示真实生效级别与路径）。
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text('${l.storageLevel}: L$activeLevel'),
            subtitle: Text(resolution.path,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: IconButton(
              icon: const Icon(Icons.copy_all_outlined),
              tooltip: l.copyPath,
              onPressed: () => Toast.copy(context, resolution.path),
            ),
          ),
        ),
        // 一键重新探测：loading 态防连点（质量要求 3 三态）。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: OutlinedButton.icon(
            onPressed: refreshing ? null : onReprobe,
            icon: refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.radar_outlined),
            label: Text(refreshing ? l.storageProbeRunning : l.storageReprobe),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(l.storageProbeLog,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        // 五级回退链逐级 ✓/✗：L≤生效级=✓；其后=未生效（未执行或失败）。
        for (var i = 1; i <= 5; i++)
          ListTile(
            dense: true,
            leading: Icon(
              i < activeLevel || i == activeLevel
                  ? Icons.check_circle_outline
                  : Icons.circle_outlined,
              size: 20,
              color: i <= activeLevel
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            title: Text('L$i · ${_levelNames[i] ?? ''}'),
            subtitle: i == activeLevel
                ? Text(l.storageLevel)
                : null,
            trailing: i == activeLevel
                ? Text(
                    '✓',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  )
                : null,
          ),
        // 探测历史（服务层 probeLog 原文，等宽字号便于排障）。
        if (resolution.probeLog.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              resolution.probeLogText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}
