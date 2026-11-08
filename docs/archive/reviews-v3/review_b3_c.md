# 批3检3 审查报告：Provider 生命周期 / 内存 / 跨模块一致性

- 审查对象：TiernanMusic @ `db7bafc`（纯读，未修改任何文件）
- 审查人：批3检3
- 日期：2026-11-02

严重度分级：🔴 编译阻塞 → 🟠 功能失效 → 🟡 体验瑕疵 → ⚪ 代码质量

---

## 🔴 编译阻塞

无。

---

## 🟠 功能失效

### F1. 「酷狗 API 地址」设置是空操作（改了没有任何地方消费）
- `lib/features/settings/presentation/settings_providers.dart:70-83`（KugouApiNotifier）
- 问题：`kugouApiProvider` 状态只在 settings_page 读写，全工程 `rg "kugouApiProvider"` 除定义/设置页外**无任何消费者**。真正生效的 base 是 `AppConfig.kugouApiBase`（`static const`，`lib/core/api/kugou_api_client.dart:45,157,194` 直接引用）。用户在设置页改 API 地址后 Dio 的 baseUrl 不变。
- 精确修法（二选一）：
  ```dart
  // 方案 A：删除该设置项（KugouApiNotifier / kugouApiProvider / 设置页 UI）
  // 方案 B：KugouApiClient 改为读取可变配置
  class ApiConfig {
    static String kugouApiBase = AppConfig.kugouApiBase; // 非 const，可被设置页覆盖
  }
  // kugou_api_client.dart:45
  baseUrl: baseUrl ?? ApiConfig.kugouApiBase,
  // KugouApiNotifier.set 中同步：ApiConfig.kugouApiBase = url;
  // 注意：单例 client 已创建，改 base 后需重建 client 或重启生效——方案 A 更稳妥。
  ```

### F2. 「翻译 API 地址」设置同样是空操作
- `lib/features/settings/presentation/settings_providers.dart:85-98`（TranslateApiNotifier）
- 问题：`core/providers.dart:14` 的 `translateApiProvider = Provider((ref) => TranslateApi())` 直接 `new TranslateApi()`，其内部 Dio 用 `AppConfig.translateApiBase` 常量（`lib/core/api/translate_api.dart` 构造函数）。设置页改地址后不生效。
- 精确修法：
  ```dart
  // core/providers.dart
  final translateApiProvider = Provider<TranslateApi>((ref) {
    final base = ref.watch(settingsTranslateApiBaseProvider); // 引 settings_providers 的值
    return TranslateApi(baseUrl: base);
  });
  // translate_api.dart 增加 baseUrl 参数：
  TranslateApi({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConfig.translateApiBase, ...
  ```
  注意 `Provider` 默认非 autoDispose，改地址后不会自动重建；如需立即生效应改为 `ref.watch(translateApiProvider.notifier)` 后手动 `ref.invalidate(translateApiProvider)`，或接受"下次启动生效"并在 UI 标注。

### F3. 全工程没有任何 UI 入口调用退出登录 / 账号切换
- `lib/features/auth/data/auth_providers.dart:28`（`AuthStateNotifier.logout`）、`:42`（`switchAccount`）
- 问题：`rg "logout"` 显示除 `auth_repository.dart` 内部（token 失效时自清）外**没有任何调用方**。l10n 已备 `'logout': '退出登录'` 词条、settings_page 的账号区（`_buildAccountSection`，约 :194-229）只有「去登录」/「账号管理」两个入口且都只是 `push('/login')`，login_page 中也 rg 不到 `AccountManager / switchTo / logout`。结果：`AuthStateNotifier.logout/switchAccount`、`AccountManager.remove/clear`、`SecureStorage.deleteAccountToken` 均为死代码，用户**无法退出登录、无法管理多账号**。
- 精确修法（settings_page `_buildAccountSection` 中，已登录时加一项）：
  ```dart
  ListTile(
    leading: const Icon(Icons.logout),
    title: Text(context.l10n.logout),
    onTap: () async {
      final ok = await showDestructiveConfirm(...); // 复用现有确认弹窗
      if (ok) {
        await ref.read(authStateProvider.notifier).logout();
        if (context.mounted) context.go('/home');
      }
    },
  )
  ```

### F4. 内存缓存无容量上限，过期条目只在被读时才清除
- `lib/core/cache/cache_manager.dart:8-38`（MemoryCache）
- 问题：`_cache` 是普通 Map，`set()` 无淘汰；过期条目只有 `get<T>()` 恰好命中同一 key 时才 remove。首页/榜单/歌单等大量 key 只写不读（或长期不再读），进程内无限增长。此前评审建议的「200 条上限 + 写入时清理过期」**未实现**。
- 精确修法：
  ```dart
  static const _maxEntries = 200;
  void set<T>(String key, T value, {Duration? ttl}) {
    if (_cache.length >= _maxEntries) _evict();
    _cache[key] = _Entry(value,
        DateTime.now().add(ttl ?? const Duration(seconds: AppConfig.memoryCacheSeconds)));
  }
  void _evict() {
    final now = DateTime.now();
    _cache.removeWhere((_, e) => now.isAfter(e.expires)); // 先清过期
    if (_cache.length >= _maxEntries) {                    // 仍超限则 FIFO 淘汰
      final keys = _cache.keys.toList();
      for (final k in keys.take(_cache.length - _maxEntries + 1)) {
        _cache.remove(k);
      }
    }
  }
  ```

### F5. 账号切换/登录后，设置页账号展示数据（nickname/avatar）不随 authState 刷新
- `lib/features/settings/presentation/settings_page.dart:194-229, 922-938`
- 问题：设置页账号卡片读的是 Hive `'settings'` 盒的 `nickname/avatar`（`FlutterSecureStorageCompat.readAccounts`），且只在 `push('/login')` 返回后 `_loadAccount()` 刷新。但 `AuthStateNotifier.switchAccount`（auth_providers.dart:42-54）换账号时**不写** settings 盒的 nickname/avatar，也不通知设置页 → 切换账号后设置页仍显示旧昵称/头像；`AuthStateNotifier.logout` 虽删了这两个键，但设置页不 watch，退出后（若经由 F3 修复的入口）仍显示旧账号直到手动进出页面。音乐库页用 `AccountManager.onCurrentAccountChanged`（library_page.dart:40）订阅了，设置页没有。
- 精确修法：登录成功处（auth_repository.dart:340-344 `_handleLoginSuccess`）已有写盒逻辑，补充 switchAccount；设置页改用单一事实源：
  ```dart
  // settings_page _SettingsPageState.build 内
  final account = ref.watch(accountCardProvider); // 新增 provider
  // settings_providers.dart
  final accountCardProvider = Provider<Map<String, dynamic>?>((ref) {
    final user = ref.watch(authStateProvider).value;
    if (user == null) return null;
    final box = Hive.isBoxOpen('settings') ? Hive.box('settings') : null;
    return {
      'userid': user.userid,
      'nickname': user.nickname.isNotEmpty
          ? user.nickname
          : box?.get('nickname') as String?,
      'avatar': user.avatar.isNotEmpty ? user.avatar : box?.get('avatar') as String?,
    };
  });
  ```
  （`switchAccount` 成功后补写 settings 盒 nickname/avatar，与 `_handleLoginSuccess` 一致。）

---

## 🟡 体验瑕疵

### W1. 应用级 `WidgetsBindingObserver` 缺失：后台时轮播 Timer 继续翻页、无 didHaveMemoryPressure 处理
- `lib/main.dart`（TiernanMusicApp）、`lib/features/home/presentation/home_page.dart:123-152`
- 问题：全工程仅 `DownloadPage` 注册了 lifecycle observer（download_page.dart:21）。首页轮播 Timer 的保活判断只看 `ModalRoute.isCurrent`（IndexedStack 下所有 tab 路由都"current"？实际只挡了非当前 tab，App 整体退到后台时 Timer 仍每 4 秒 `animateToPage`）。且无任何 `didHaveMemoryPressure` 处理（审查点 18）。
- 精确修法：
  ```dart
  // home_page.dart _BannerCarouselState
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _startAutoPlay();
  }
  // _startAutoPlay 的回调里首行加：
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
  ```
  同时在根组件（如 `TiernanMusicApp` 改 ConsumerStatefulWidget）注册 observer，在 `didHaveMemoryPressure` 中 `MemoryCache.instance.clear()`：
  ```dart
  @override
  void didHaveMemoryPressure() => MemoryCache.instance.clear();
  ```

### W2. 4 处封面 CachedNetworkImage 缺 memCacheWidth（此前修复的漏网）
- `lib/features/player/presentation/queue_sheet.dart:75`
- `lib/features/player/presentation/full_player_page.dart:421`
- `lib/features/playlist/presentation/playlist_detail_page.dart:106`
- `lib/features/search/presentation/search_page.dart:608`（搜索结果歌单横滑封面）
- 问题：无 `memCacheWidth` 时按原图分辨率解码进内存缓存，封面列表场景占用可达数倍。其余站点（song_tile/mini_player/home_page/library_page/search_page:671）已带参数，属漏网。
- 精确修法（各处按显示尺寸补，示例 queue_sheet）：
  ```dart
  CachedNetworkImage(
    imageUrl: s.cover,
    memCacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(), // 按实际尺寸
    ...
  )
  ```
  另：评论头像两处 `NetworkImage`（comments_page.dart:459、comment_floor_page.dart:234）无 cacheWidth 也无磁盘缓存，建议换 `CachedNetworkImage` + `memCacheWidth: 96`。

### W3. verification_listener 中的空 ref.listen 是无效代码
- `lib/features/auth/presentation/verification_listener.dart:32-34`
- 问题：`ref.listen(audioHandlerProvider, (p, n) { /* 仅注释 */ })` 无任何作用，还让 MainShell 每次 rebuild 都走一遍订阅登记。
- 精确修法：整段删除。

### W4. main() 看门狗 Timer 是一次性但永不取消（后台被杀前一直持有）
- `lib/main.dart:150-157`
- 问题：15 秒看门狗 Timer 一次性触发，触发后闭包释放，无泄漏风险，但若 15 秒内进程进入后台纯属多余持有。⚪ 级别，可忽略；如要严谨：
  ```dart
  final watchdog = Timer(const Duration(seconds: 15), () { ... });
  // addPostFrameCallback 中：watchdog.cancel();（首帧渲染即取消）
  ```

---

## ⚪ 代码质量 / 一致性备注

### Q1. kgClientProvider 与 kugouApiClientProvider 的类型与主从关系（审查点 4/14）— 通过，附说明
- 主链：`kgDeviceProvider`（main override）→ `kgClientProvider`（KgClient，签名/直连）→ `kgDirectApiProvider`（KgDirectApiClient extends KugouApiClient）→ `kugouApiClientProvider`（core/providers.dart:11-13 直接返回 `ref.watch(kgDirectApiProvider)`）。全工程单一 API 客户端，无混用 FutureProvider 的类型问题。
- CookieJar：`KugouApiClient` 构造不传 `cookieStoragePath` 时用静态 `sharedCookieJar`（kugou_api_client.dart:41-43），main() 启动时已设置 `cookieStoragePath`（main.dart:105-112）→ 首个实例创建的 shared jar 即 PersistCookieJar，AuthRepository（auth_repository.dart:58 `KugouApiClient()`）、KgDirectApiClient 全部共享同一 jar，登录 Cookie 真正共享。**通过**。
- 但注意 `KugouApiClient.cookieStoragePath` 是静态可变量，若 sharedCookieJar 在 main 设置路径**之前**被任何代码触碰（当前没有），会退化为内存 jar —— 建议把 `cookieStoragePath` 设为 non-null 前禁止读的断言，或加注释锁死初始化顺序。

### Q2. 登录态四处数据源同步机制（审查点 11）— 基本收敛，单点缺陷见 F5
- 事实源：`authStateProvider`（AsyncNotifier）。同步链：
  1. 登录/恢复：`AuthRepository._handleLoginSuccess` 同时 `SecureStorage.saveCredentials` + `_api.setCredentials`（kapi 侧）+ `AccountManager.upsert` + Hive settings 昵称头像。
  2. 任何 authState 变化：`main.dart:170-184 ref.listen` 把 token/userid/t1 同步进直连 `KgClient`（退出时清空 t1 ✓）。
  3. `AccountManager.onCurrentAccountChanged` 广播给 library_page。
- 缺口：`switchAccount` 不写 Hive settings 昵称头像（F5）；`AuthRepository.logout` 走 `AccountManager.clearCurrent()` 触发广播 ✓；KgClient.t1 只在退出清空，账号 A→B 切换时 loginByToken 会刷新 t1 ✓。

### Q3. 退出登录后的模块响应（审查点 12）— 数据层齐全，UI 层缺入口（F3）
- 若 logout 被调用：authState → null；main.dart 监听清 KgClient 凭证；`_api.clearCredentials()` 清共享 CookieJar；SecureStorage 清 token；Hive 清昵称头像。音乐库页监听广播自动刷新 ✓；评论页每处 `ref.watch/read(authStateProvider)` 实时判断 ✓。下载/播放历史为本地数据，不随退出清除（设计如此，可接受）。播放器不因退出停止（应继续，✓）。

### Q4. ref.watch 在异步/回调中的使用（审查点 2）— 通过
- 全部 13 个文件中，`ref.watch` 均在 provider build / async* 体内首段同步区使用；`ref.read` 用于回调与事件处理器（auth_providers `_finish`、download 的 StateNotifier 不用 ref、main.dart listen 回调内 `ref.read` ✓）。无违规。

### Q5. ref.listen 在 build 中的使用（审查点 5）— 通过
- main.dart:170 与 verification_listener.dart:30/32 均为 ConsumerWidget.build 内 `ref.listen` —— Riverpod 2.x 标准用法，框架按 build 去重登记，不会重复回调。合规。

### Q6. Provider 类型选择（审查点 1）— 通过
- 客户端/仓库/路由/主题全部非 autoDispose（应用级单例，正确）；`currentSongProvider/queueProvider/positionProvider` 等 StreamProvider 也非 autoDispose 但挂在常驻 audioHandler 的流上，属应用级状态，正确。`loginControllerProvider`（AsyncNotifier<void>）非 autoDispose：登录页销毁后 error/loading 状态残留，下次进登录页直接看到旧 AsyncError —— 建议改 `AsyncNotifierProvider.autoDispose` 或进入登录页时 `ref.invalidate(loginControllerProvider)`。体验级别，不单列。

### Q7. 循环依赖（审查点 3）— 无
- 依赖图：auth → core/api；player → core + direct；download → core + direct + mv；core/providers → direct。单向无环。

### Q8. StreamController close（审查点 6）— 一致：全部单例不 close
- audio_handler 3 个 broadcast controller、AccountManager._changedCtrl、RecentPlayStore._changesCtrl 均为进程级单例且从不 close —— 与"单例可不 close"约定一致。✓

### Q9. Timer 盘点（审查点 7）— 通过
- home 轮播：dispose 取消 ✓（除 W1 后台不暂停）；toast 静态 timer：show 前 cancel ✓；search debounce、login 倒计时/轮询：均有 cancel；无全局 static Timer.periodic 裸奔（toast 除外，已管理）。

### Q10. Hive box close（审查点 9）— 通过
- 所有 box（device/settings/accounts/recent_plays/search_history/lyric_translations/downloads）为 App 生命周期单例，main() 统一打开，无 close 需求，无中途重开。✓

### Q11. 错误处理统一性（审查点 15）— 基本统一，两处吞错值得升级
- DioException/ApiException 的分流在 restoreSession（auth_repository.dart:229-262，网络错不清凭证 ✓）、audio_handler（20028 上抛不跳歌 ✓）、download（cancel→paused，其余→failed ✓）三处语义一致。
- 吞错点：`KgDeviceStore.loadSync` 的 `catch (_) {}`（kg_providers.dart:41）与 `saveDfidSync` 的 catch（:76）——设备身份损坏会静默重新生成并覆盖旧 dfid，属可接受自愈，但建议加 `debugPrint`。其余 60+ 处 `catch (_) {}` 多为「清理失败不阻塞主流程」的降级守卫，模式统一。

### Q12. main() 启动顺序与降级（审查点 16）— 通过
- Hive.initFlutter 失败继续 → 逐 box openSafe → cookie 目录失败继续 → 设备身份三级兜底（box 未开→内存生成）→ JustAudioBackground 8s timeout 失败不阻塞 → device 仍 null 则 `_startupError` 走错误页（此时 kgClientProvider 的 UnimplementedError 不会触发，因为 StartupErrorPage 不消费任何依赖 override 的 provider）。链路完整。✓
- 一个小注意点：JustAudioBackground.init 失败后 `audioHandlerProvider` 首次读取仍会创建 `TiernanAudioHandler`，`AudioPlayer` 带背景 tag 的 `setAudioSource` 可能抛平台异常 —— 已被 `_playAt` 的 catch 捕获并走 error 状态，不会崩。可接受。

---

## 通过项汇总（无需改动）

| 审查点 | 结论 |
|---|---|
| 1 Provider 类型 | ✓（loginController 残留 error 为小瑕疵，见 Q6） |
| 2 ref.watch 在异步/回调 | ✓ 无违规 |
| 3 循环依赖 | ✓ 无 |
| 4 FutureProvider 混用 | ✓ 全 Provider 单例链 |
| 5 build 内 ref.listen | ✓ 合规 |
| 6 StreamController close | ✓ 单例一致不 close |
| 7 Timer 取消 | ✓（后台翻页见 W1） |
| 8 MemoryCache 上限 | ✗ 未实现（F4） |
| 9 Hive close | ✓ 无需 |
| 10 memCacheWidth | 4 处漏网（W2） |
| 11 登录态单一事实源 | 基本收敛（F5 残留） |
| 12 退出链路 | 数据层 ✓、UI 入口缺失（F3） |
| 13 设置传播 | 主题/语言 ✓；音质逐次生效 ✓（当前队列不变属合理）；API 地址设置失效（F1/F2） |
| 14 kgDirectApi 主从 | ✓ CookieJar 共享真实生效 |
| 15 错误统一性 | 基本统一（Q11） |
| 16 启动降级 | ✓ 完整 |
| 17 后台行为 | 仅下载页有 observer（W1） |
| 18 didHaveMemoryPressure | ✗ 无（W1 一并修） |
