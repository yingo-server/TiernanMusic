# 批4检1：性能与资源审查（纯读）

- 基线：commit `3d74378`（批3修1/修2/修3 之后）
- 范围：12 个性能敏感文件 + main.dart / player_provider.dart / home_repository.dart（交叉引用）
- 严重度排序：🔴 功能失效 > 🟠 性能退化 > 🟡 体验瑕疵 > ⚪ 代码质量

---

## 🔴 高：下载进度回调导致 Hive 写放大 + O(n) 状态拷贝风暴

**文件**：`lib/features/download/download_provider.dart:283-292`（`onProgress`）→ `_update`（:258-261）

问题：Dio 的 `onReceiveProgress` 每收到一个网络 chunk 触发一次（大文件可达每秒数十次）。每次回调：
1. `_find` 线性扫描全部任务；
2. `_replace` 复制整个任务列表（`[...state.tasks]`）并整体 `state =` —— 触发所有 `watch(downloadManagerProvider)` 的 widget 重建；
3. `_update` 里 `unawaited(DownloadStore.save(task))` —— **每个 chunk 一次 Hive 落盘**。

下载一个 10MB 音频按 8KB chunk 算就是 1200+ 次状态替换与 1200+ 次 Hive 写，并发 2 任务时 IO 放大更明显（审查点 13）。持久化只需要「终态 + 低频进度」。

**修法**：进度回调节流（500ms 或 1% 步进），终态才立即写：

```dart
DateTime _lastProgressFlush = DateTime.fromMillisecondsSinceEpoch(0);

void onProgress(int received, int total) {
  final cur = _find(task.id);
  if (cur == null || cur.status != DownloadTaskStatus.running) return;
  final now = DateTime.now();
  final progressed = total > 0 &&
      (received - cur.received) >= (total ~/ 100); // 至少前进 1%
  if (!progressed && now.difference(_lastProgressFlush).inMilliseconds < 500) {
    _lastProgressFlush = now; // 内存里仍可暂存最新值
    return;
  }
  _lastProgressFlush = now;
  _update(cur.copyWith(
    received: received, total: total,
    updatedAt: now.millisecondsSinceEpoch,
  ));
}
```

更彻底的做法：进度仅更新内存（拆一个独立的轻量 `_progressNotifier` 供进度条监听），Hive 只在 running→paused/failed/completed 等状态迁移时写。

---

## 🔴 高：ErrorLogger 每条日志触发一次「读旧文件 + 全量重写」——错误风暴 O(n²)

**文件**：`lib/core/utils/error_logger.dart:109-113`（`log` → `_appendPublic`）→ `:204-217`（`_rewriteMediaStore`）

问题：Android 10+ 路径上，每条日志都走一次 MethodChannel `appendText`，注释自述原生层「读旧内容 + 超限轮转 + 整份重写」。日志文件上限 5MB，临近上限时每写一条日志都要读出并重写最多 5MB → 错误风暴（如网络异常被每次播放重试触发）时写放大 O(n²)，且是主 isolate 与平台通道间的同步开销。另外 `apiLevel`（:255-262）每条日志都发一次 MethodChannel 查询。

批3 修过「按天聚合、整份重写」，把 MediaStore 插入次数从每条一次降为每文件一次，方向正确，但**没有在 Dart 侧聚合批量写入**——单条一通道调用依旧。

**修法**：Dart 侧内存缓冲 + 定时/定量落盘：

```dart
final StringBuffer _pending = StringBuffer();
Timer? _flushTimer;

Future<void> log(Object error, StackTrace? stack, {...}) async {
  // ...构造 text、更新 _recent、debugPrint（现有逻辑不变）...
  _pending.write(text);
  _flushTimer ??= Timer(const Duration(seconds: 2), _flush);
}

Future<void> _flush() async {
  _flushTimer = null;
  final text = _pending.toString();
  _pending.clear();
  if (text.isEmpty) return;
  await init();
  if (await _appendPublic('error_${_dateTag(DateTime.now())}.log', text)) return;
  // ...现有私有目录降级逻辑...
}

static int? _apiLevelCache;
static Future<int> get apiLevel async =>
    _apiLevelCache ??= await _loadApiLevel(); // 进程内缓存一次
```

---

## 🟠 中：_CoverOrLyric 每秒多次整树重建（含封面 / AnimatedSwitcher / LyricView 全部行）

**文件**：`lib/features/player/presentation/full_player_page.dart:356-360`（`_CoverOrLyricState.build` watch `positionProvider`）

问题：审查点 1/2。`_CoverOrLyric` 直接 watch `positionProvider`（positionStream，每秒多次 emit），导致：
- 显示封面时：每次 tick 重建 Stack / AnimatedSwitcher / Hero / CachedNetworkImage / TextButton——完全不必要的重建；
- 显示歌词时：`LyricView.build` 每次执行，`ListView.builder` 的可见 `_LyricLineTile` 全部重新 build（元素复用但 build 重跑），每行的逐字 TextSpan 列表重算。

mini_player 已正确隔离（`_MiniProgressBar` 单独 watch，:150-168，✅ 通过项）；full_player 的 `_ProgressBar` 也已隔离（:467-470，✅），但歌词/封面区域漏了。`LyricView` 内部的「行号变化才 setState」（:96-108）设计是对的，但它控制不了**父级**每 tick 把它整个重建。

**修法**：把 position 的消费下推到 `LyricView` 内部（新增一个仅监听 position 的包装），或拆一层：

```dart
// _CoverOrLyricState.build 不再 watch position：
final lyricAsync = ref.watch(currentLyricProvider);
final lyricMode = ref.watch(lyricModeProvider);
// ...AnimatedSwitcher 内：
child: _showLyric && lyricAsync.value?.lyric != null
    ? FadeTransition(
        ...,
        child: ClipRect(
          key: const ValueKey('lyric'),
          child: _LiveLyricView(              // 新增：只有它 watch positionProvider
            lyric: lyricAsync.value!.lyric!,
            mode: lyricMode,
            onTapLine: (ms) => ref.read(playerControllerProvider)
                .seekTo(Duration(milliseconds: ms)),
          ),
        ),
      )
    : _buildCover(context),

class _LiveLyricView extends ConsumerWidget {
  const _LiveLyricView({required this.lyric, required this.mode, this.onTapLine});
  final KrcLyric lyric;
  final LyricDisplayMode mode;
  final ValueChanged<int>? onTapLine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    return LyricView(lyric: lyric, position: position, mode: mode, onTapLine: onTapLine);
  }
}
```

这样封面态零重建，歌词态只有 `LyricView` 外壳随 tick 重建（其行内 Tile 因元素 identity 稳定而跳过无意义 layout，仅当前行视觉更新）。

补充（审查点 2 结论）：逐字高亮实现正确——单个 `Text.rich` + 每字一个 `TextSpan`（`lyric_view.dart:196-213`），不是每字一个 Text widget；当前行切换时只 setState 一次并复用 ListView 元素（:96-108，`_currentIndex` 守卫）✅。

---

## 🟠 中：启动阶段 10 个串行 await（含最长 8s 的 JustAudioBackground.init）在 runApp 之前

**文件**：`lib/main.dart:63-108`（审查点 15/16）

问题：`runApp` 前依次 `await`：`Hive.initFlutter` → 7 个 `openSafe`（**串行**）→ `getApplicationDocumentsDirectory` → `JustAudioBackground.init`（timeout 8s）。最坏情况首帧被拖 8s+（原生启动屏卡住）。每个 await 都是启动延迟，其中：
- `lyric_translations`、`downloads` 两个 box 可 lazy（用到时再开；`LyricTranslationCache.init` / `DownloadStore` 已各自 `await init()` 兜底，见 `cache_manager.dart:75-79` ✅）；
- 7 个 openSafe 可以并行；
- `JustAudioBackground.init` 可延后到首次进入播放页（audio_handler 已是延迟创建模式，:26-29 ✅，但 audio_service 初始化没有跟着延迟）。

**修法**（保守版，不改动风险面）：

```dart
// 并行开箱 + 延后两个非首帧必需 box
await Future.wait([
  openSafe(KgDeviceStore.boxName, stringValues: true),
  openSafe('settings'),
  openSafe('accounts'),
  openSafe('recent_plays'),
  openSafe('search_history', stringValues: true),
  // openSafe('lyric_translations', stringValues: true), // 惰性：LyricTranslationCache.init 自带
  // openSafe('downloads'),                              // 惰性：DownloadStore 首次读取时开
]);

// JustAudioBackground.init 移到 audioHandlerProvider 首次被消费时（或 HomePage initState），
// try/catch 语义保持不变
```

容错结构（每个子步骤独立 try/catch、最终必 runApp）✅ 是本文件的亮点，保持不动。

---

## 🟠 中：搜索页每个按键 `setState(() {})` 重建整页

**文件**：`lib/features/search/presentation/search_page.dart:57-60`（`_onControllerChanged`）

问题：审查点 5。`_controller.addListener` 里为刷新 SearchBar 的清除按钮对**整个页面** setState（整页含 TabBarView 与结果列表）。建议词本身有 400ms debounce（:71-88 ✅），但击键重建仍每次触发。全文件空 setState 共 2 处：此处 + `_SearchPageState._onChanged/_submit/_clear` 内的带值 setState（合理）+ `lyric_view.dart:104` 的 `setState(() {})`（行切换触发，必要且低频，可接受）。

**修法**：把 SearchBar 抽成只依赖 `_controller` 的 `ValueListenableBuilder<TextEditingValue>`，或让 trailing 的清除按钮改为监听 controller 的独立 widget，页面级 setState 仅在 `_showSuggest/_submittedKeyword` 变化时发生：

```dart
trailing: [
  ValueListenableBuilder<TextEditingValue>(
    valueListenable: _controller,
    builder: (_, v, __) => v.text.isEmpty
        ? const SizedBox.shrink()
        : IconButton(icon: const Icon(Icons.close), tooltip: context.l10n.clear, onPressed: _clear),
  ),
],
// _onControllerChanged 整个删除
```

---

## 🟡 低：_PlaylistResultTab 封面缺 memCacheWidth（批2修1 漏网）

**文件**：`lib/features/search/presentation/search_page.dart:594-601`

问题：审查点 6。网格 2 列、每格约屏宽一半，却未设 `memCacheWidth`，原图（歌单封面常见 480~1080px）按原尺寸解码驻留。其余覆盖情况已核对：song_tile 52px（:98）、mini_player 132（:96）、full_player 封面按屏宽×dpr（:478-480）、home banner 400×dpr（:189）、daily 78×dpr、playlist 行 130×dpr、rank 200×dpr、搜索 generic 48×dpr —— **仅此处遗漏**。Banner 480px 已有 400×dpr 上限，无特殊问题。

**修法**：

```dart
child: CachedNetworkImage(
  imageUrl: p.cover,
  width: double.infinity,
  fit: BoxFit.cover,
  memCacheWidth: (MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context) ~/ 2)
      .round(),
  errorWidget: ...
```

---

## 🟡 低：LyricView 手动滚动暂停自动跟随的判定过宽

**文件**：`lib/features/lyric/presentation/lyric_view.dart:60-62, 126-128`

问题：体验瑕疵。`ScrollStartNotification && n.dragDetails != null || n is UserScrollNotification` 会把**程序触发的 animateTo 产生的滚动结束**（UserScrollNotification idle/direction 变化）也算作「用户滚动」边界情形；`_scrollTo` 的 animateTo 每行切换都发起新动画，若上一动画未完成会 `animateTo` 打断重定向，视觉上偶有跳变。属瑕疵非缺陷，优先级低；可改为只认 `n.dragDetails != null` 的 ScrollStartNotification 与 `UserScrollNotification.direction != ScrollDirection.idle`。

---

## 通过项（核对无问题）

| 审查点 | 结论 |
|---|---|
| 1 进度 tick 隔离 | mini_player ✅（`_MiniProgressBar` 独立 watch，mini_player.dart:150-168）；full_player 的 Slider ✅（`_ProgressBar` 独立，full_player_page.dart:467）；歌词区 ❌ 见上（唯一遗漏） |
| 2 歌词逐字实现 | `Text.rich`+TextSpan ✅；行切换仅一次 setState + 二分查找 `_findCurrentLine`（:137-149）✅ |
| 3 首页重建 | `homeDataProvider` 是单一 FutureProvider，刷新才整页重建；刷新走 `ref.refresh(future)` 保留旧数据（home_page.dart:44-50）✅；`fetchHomeData` 5 路并发 + 单项 12s 超时 + 独立容错（home_repository.dart:139-186）✅ |
| 4 watch 粒度 | 未发现「watch 整个 provider 只用一个字段」的实质性问题；player_provider 均为细粒度独立 StreamProvider ✅ |
| 5 空 setState | 2 处必要（LyricView 行切换、SearchBar 刷新），后者见上 🟠 |
| 6 memCacheWidth | 除 _PlaylistResultTab 一处遗漏外全覆盖 ✅；Banner 有 400×dpr 上限 ✅ |
| 7 builder vs Column | 首页大列表用 `SliverList.separated`，横排/网格全部 `ListView.builder`/`GridView.builder`/`PageView.builder`；骨架屏 Row 固定 2~5 项可接受 ✅。搜索热搜 `Wrap`+Column 一次性构建几十个 chip，量小可接受 |
| 8 MemoryCache 上限 | `cache_manager.dart:31-45` 实现正确：先清过期，仍超按插入序 FIFO 淘汰（LinkedHashMap 保序）；200 条上限合理；`didHaveMemoryPressure` 清空（main.dart:232-234）✅ |
| 9 Stream 泄漏 | 三个 broadcast controller（audio_handler.dart:44-50）均为 app 生命周期单例，订阅方全为 Riverpod StreamProvider（自动管理）；搜索页 Timer/ScrollController/TextEditingController/FocusNode 均 dispose ✅；_BannerCarousel Timer cancel + 非当前 tab 不翻页（home_page.dart:111-117，省电加分）✅ |
| 10 闭包捕获 | `_BannerCarouselState` 的 Timer 回调经 `mounted` 守卫（:114）✅；audio_handler 的 `_pendingIndex` 用 `Future.microtask` 避免 finally 递归（:216-221）✅；未发现 Timer/订阅捕获 BuildContext |
| 11 Hive 写播放进度 | **未发现**播放进度写 Hive；`recent_plays` 只在切歌时写（player_repository 侧），进度仅 positionStream 内存流 ✅ |
| 12 日志聚合 | Dart 侧 `_recent` 上限 200 ✅；MediaStore 已按天单文件 ✅；但错误风暴下仍有每条一次通道调用 + 整份重写，见 🔴 |
| 13 下载并发 | maxConcurrent=2 ✅、指数退避重试 2 次、4xx 不重试（download_repository.dart:112-146）✅；进度回调 IO 放大见 🔴 |
| 14 重复请求 | MemoryCache 90s TTL 覆盖首页全部接口；搜索建议 400ms debounce ✅；热搜 FutureProvider 缓存 ✅。下拉刷新主动清缓存是有意为之 ✅ |

## 代码质量备注（不计严重度）

- `download_provider.dart:100`：`addAll` 串行 await 每个 `add`（内部又各自 `_schedule()`），批量 3 个任务（音频+封面+歌词）会触发 3 次调度循环，建议批量入列后调度一次。
- `cache_manager.dart:31`：`get` 命中过期才淘汰，未命中不触发清理；配合 `_evict` 已够用，无需改动。
- `lyric_view.dart:14` 常量 `_itemExtentApprox = 64.0` 与实际行高（17px 字号+译文可能 2 段）存在偏差，长歌词跳转定位会累积误差；可考虑 `itemExtent` 固定或 `Scrollable.ensureVisible` 方案。

## 结论

无功能失效级问题。最值得修的两项是 **下载进度 Hive 写放大**（一行节流即可解决）和 **ErrorLogger 错误风暴 O(n²)**；播放器 UI 的进度隔离已基本做到位，仅剩歌词/封面区域一处整树重建。
