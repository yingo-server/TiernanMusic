# 审查报告：首页 / 搜索 / 音乐库（纯读）

- 基线 commit：`bcfd024`
- 范围：home（page/repository/models）、search（page/repository）、library（page/recent_play_store）、core/widgets（song_tile/shimmer）、core/router/app_router、player/play_helper
- 严重度排序：编译阻塞 > 功能失效 > 体验瑕疵 > 代码质量

---

## 一、问题清单（按严重度）

### 功能失效

**F1. `library_page.dart:32-44, 223-226` → 登录/登出后音乐库不刷新**
`_currentAccount()` 直接读 `AccountManager.instance.currentAccount`（非响应式），页面 build 不依赖任何 auth Provider，也没有监听。登录页 `push('/login')` 返回后，底层页（StatefulShellRoute IndexedStack 保活）不会 rebuild——「我的歌单」仍显示未登录引导卡，账号卡片也不更新，直到发生其它 setState。
修法：把登录态做成 StreamProvider 并 watch。例如：

```dart
// core/providers.dart
final authStateProvider = StreamProvider<AccountRecord?>((ref) {
  // AccountManager 内部在 upsert/switchTo/clearCurrent 后 notify
  return AccountManager.instance.onCurrentAccountChanged;
});

// library_page.dart build 中
final accountAsync = ref.watch(authStateProvider);
final account = accountAsync.valueOrNull ?? _currentAccount();
```

（最小改动版：`ref.listen(authStateProvider, ...)` 或在返回音乐库时 invalidate `_userPlaylistsProvider`；但根因是缺少可监听的 auth 信号源，AccountManager 目前完全无回调。）

**F2. `library_page.dart:30-37 + recent_play_store.dart:56-59` → 播放后回到音乐库，最近播放不更新**
`_loadRecent()` 只在 initState 调一次；且 `RecentPlayStore.read()` 在 box 未打开时直接返回 `const []`（`add()` 才懒打开 box）。StatefulShellRoute 保活下 initState 不会重跑，用户从播放器返回后列表永远是旧数据。
修法：播放记录写入后发通知，页面监听。最简单：

```dart
// play_helper.dart 的 _record 末尾
RecentPlayStore.notifyListeners();

// recent_play_store.dart 增加
static final _ctrl = StreamController<void>.broadcast();
static Stream<void> get changes => _ctrl.stream;
static void notifyListeners() => _ctrl.add(null);

// library_page.dart initState
_sub = RecentPlayStore.changes.listen((_) => _loadRecent());
// dispose 中 _sub.cancel();
```

另建议 `read()` 改为：box 未打开时 `await Hive.openBox(_boxName)` 后再读（或接受 lazy-open 版本），避免首次冷启动进音乐库永远空。

**F3. `search_repository.dart:126-135 + search_page.dart:672-676` → 专辑结果用 AlbumID 走歌单路由**
`_GenericResultTab` 中 `type == 'album'` 时 `context.push('/playlist/${s.albumId}')`。专辑 `albumid` 是数字 ID，而 `/playlist/:id` 的数据源（`HomePlaylist` 注释明确写了）要求 `collection_<...>` 形式的 `global_collection_id` / `global_specialid`。点专辑结果大概率得到空详情或接口报错。
修法：专辑应走 `/album/:id` 专页（需新增）；临时止血可以先隐藏专辑 Tab 的点击：

```dart
onTap: () {
  if (type == 'mv' && s.hash != null) {
    context.push('/mv/${s.hash}');
  }
  // 专辑/歌手跳转待专门页面接入前不响应
},
```

**F4. `search_page.dart:302-315 + 415-424` → 分页失败后滚动会反复触发请求 + Toast 刷屏**
单曲 Tab 分页失败时 `_loading=false`、`_hasMore` 仍为 true（`_items.length < _total`），滚动监听条件 `!_loading && _hasMore` 依然满足——用户停在列表底部附近每次微滚都会再发一次请求并弹一条 Toast（Toast.show 未去重间隔）。同时**没有显式重试入口**（只有底部 loading 转圈位，失败后变成什么都没有）。
修法：失败且有已有内容时渲染「加载失败·点此重试」footer：

```dart
itemCount: _items.length + (_hasMore ? 1 : 0),
itemBuilder: (context, i) {
  if (i >= _items.length) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: FilledButton.tonal(
          onPressed: () { setState(() => _error = null); _loadMore(); },
          child: Text(context.l10n.reload),
        )),
      );
    }
    return const Padding(... CircularProgressIndicator ...);
  }
  ...
```

并在 scroll listener 中加节流（如 `_error != null` 时不再自动触发，只走按钮）。

### 体验瑕疵

**E1. `app_router.dart:25-40 + home_page.dart:27-31` → Banner 自动轮播在切走 Tab 后仍持续运行**
`StatefulShellRoute.indexedStack` 保活所有 branch，`_BannerCarouselState` 的 `Timer.periodic` 与 `animateToPage` 在页面不可见时照常跑（IndexedStack 的 offstage 子树仍接收动画调度），白耗电且后台 setState 累积。dispose 清理本身是对的（`_timer?.cancel(); _controller.dispose()` ✓）。
修法：用 `VisibilityDetector`/路由感知，或最简单地在 Timer 回调里检查可见性：

```dart
_timer = Timer.periodic(const Duration(seconds: 4), (_) {
  if (!mounted || widget.banners.length < 2) return;
  final route = ModalRoute.of(context);
  if (route != null && (route.isCurrent == false)) return; // 非当前 Tab 不翻页
  ...
});
```

（更严谨：`TickerMode` 包裹 + `Visibility` 判断，或走 goRouterNotifier 感知当前 branch。）

**E2. `home_page.dart:22-26` → 下拉刷新会整屏闪回骨架屏，且 RefreshIndicator 立即收起**
`onRefresh: () async => ref.invalidate(homeDataProvider)`：invalidate 使 `homeAsync` 回到 loading，整页被 `_HomeSkeleton` 替换（含大标题栏消失），布局跳动；且 future 同步返回，RefreshIndicator 转圈瞬间消失，用户感知不到刷新。另外 `MemoryCache` 90s TTL 内 invalidate 后仍命中缓存，等于"刷新无效果"。
修法：改为手动 re-fetch 并保留旧数据：

```dart
final homeDataProvider = FutureProvider.autoDispose<HomeData>((ref) { ... }); // 或
onRefresh: () => ref.refresh(homeDataProvider.future), // refresh.future 会被 await，指示器等完成
```

并给首页相关 key 传短 TTL 或在 refresh 时 `MemoryCache.instance.clear()`（至少清首页几个 key）。

**E3. `home_page.dart:437-558` → 骨架屏与实际内容结构不一致，切换时跳动**
loading 态没有 `SliverAppBar.large`（大标题从无到有）、歌单区骨架高 176 vs 实际 180、骨架缺少每日推荐/新歌 SectionHeader 的 padding（20/8）。切换瞬间整页高度变化明显。
修法：骨架屏外层同样包一层 `SliverAppBar.large` 结构（把 loading 也放进 CustomScrollView），并把 176 改 180、补 SectionHeader 同尺寸占位。

**E4. `home_repository.dart:181-186 + home_page.dart:70-107` → 区块级失败无重试入口**
聚合层单项失败置空（设计正确，一个区块失败不影响其它 ✓），但空区块直接不渲染，用户无法单独重试失败区块；只有"全部为空才抛错"。部分失败时（比如只有新歌成功）页面看起来"缺一块"且刷新只能整页 invalidate。
修法：HomeData 为每个区块带 `error` 标记（如 `Map<String, Object?> failures`），区块 header 右侧渲染小号「重试」按钮，单独重跑对应 fetch（各区块拆成独立 FutureProvider.family 最干净）。

**E5. `home_page.dart:162-166, 214-220, 296-303` → CachedNetworkImage 均未设 `memCacheWidth`**
Banner（480px 源图，实际显示 ~宽屏 150 高）、歌单封面 130×130、每日推荐 78×78、排行榜 200×150 全部按原图解码驻内存。列表滚动多页后内存压力明显。
修法（每处加一行）：

```dart
CachedNetworkImage(
  imageUrl: ...,
  memCacheWidth: (130 * MediaQuery.devicePixelRatioOf(context)).round(),
  ...
)
```

SongTile 内 52×52（song_tile.dart:88-96）同理。

**E6. `home_page.dart:159-166, 251-256` → Banner / 歌单封面无 placeholder**
有 errorWidget ✓，但网络慢时直接空白（SongTile 有 `_placeholder` ✓）。建议补 `placeholder: (_, __) => Container(color: theme.colorScheme.surfaceContainerHighest)`。

**E7. `search_page.dart:232-234` → 热搜失败静默吞掉**
`error: (_, __) => const SizedBox.shrink()`，热搜区整个消失无任何提示/重试。至少给一个可点击的「重试」或空态文案。

### 代码质量

**Q1. `search_page.dart:63-80` → `_onControllerChanged` 与 `_onChanged` 双通道刷新**
listener 里无条件 `setState(() {})`（仅为 trailing 清除按钮），每次输入都全页 rebuild；而 `_onChanged` 里又 setState。可以让 trailing 用 `ValueListenableBuilder` 只重建 trailing，或合并两个回调。功能正确（listener 在 dispose 正确移除 ✓，防抖 cancel 旧 timer ✓、响应竞态有 `_controller.text.trim() != text.trim()` 防护 ✓）。

**Q2. `search_repository.dart:154-164` → 分页正确性完全依赖接口返回 `total`**
`_totalOf` 在 `data.total` 缺失时返回 0 → `_hasMore` 恒 false，多页结果被截断为一页。建议对 `total<=0 && items.length==pageSize` 的情况兜底为"还有更多"：

```dart
int _hasMoreGuard(int total, int returned, int pageSize) =>
    (total <= 0 && returned >= pageSize) ? -1 : total;
```

**Q3. `search_repository.dart:246-256` → `addHistory` 每次 clear+addAll 全盒重写**
20 条以内无所谓，但更 Hive 惯用做法是 box 存 `List<String>` 单 key（与 RecentPlayStore 同模式），避免逐 key 写放大。逻辑本身（去重置顶、上限 20）正确 ✓。

**Q4. `recent_play_store.dart:44-47` → `_box` getter 抛 StateError 但从未被外部直接用**
`read()` 先判 `isBoxOpen`、`add()` 自行懒打开，`clear()` 也判空 —— `_box` getter 的 throw 分支实际不可达，属冗余防御；保留亦可。

**Q5. `library_page.dart:33-36` → `_loadRecent` 在 initState 里 setState**
可运行（initState 时 build 未开始，安全但多余），直接赋值即可：`_recent = RecentPlayStore.read();`

---

## 二、通过项

| 审查点 | 结论 |
|---|---|
| A1 Banner Timer dispose | ✅ `home_page.dart:130-134`：`_timer?.cancel()` + `_controller.dispose()` 顺序正确；页码用取模无越界（后台仍运行见 E1） |
| A2 Shimmer dispose | ✅ `shimmer.dart:47-50` AnimationController 正确 dispose；`didUpdateWidget` 处理 enabled 切换 ✓；`SkeletonBox/SkeletonText` 无状态无泄漏 |
| A3 区块隔离 | ✅ `home_repository.dart:163-186`：五路并发、单项 12s timeout、单项失败不炸整体（缺重试入口见 E4） |
| A4 每日推荐登录态 | ✅ `fetchDailyRecommend` 异常/未登录返回 null，UI `dailyRecommend != null && isNotEmpty` 才渲染，null 与空列表语义区分正确 |
| B7 防抖 | ✅ 400ms Timer 每次输入先 cancel，不会堆积请求；响应竞态有文本一致性校验 |
| B8 搜索历史 | ✅ `_historyBox()` 懒打开，主流程未预开 box 也不崩；getHistory 有 try/catch；去重置顶 + 上限 20 正确 |
| B9 单曲 Tab keepAlive | ✅ `AutomaticKeepAliveClientMixin`（wantKeepAlive=true，且 `super.build(context)` 已调）；歌单/通用 Tab 虽无 mixin，但依赖非 autoDispose 的 family Provider 缓存，切回不重载，等效达成 |
| B9 分页 `_hasMore/_total` | ✅ 基本正确：`_total<0`（未知总数）持续加载、`items.length < total` 停止；滚动监听有 `!_loading` 守卫，正常路径不重复触发（失败路径见 F4，total 缺失见 Q2） |
| B11 MV hash | ✅ `_mvItem` 用 `MvHash` 作 hash（注释明确 `/video/url` 只认视频 hash），路由 `/mv/${s.hash}` 传参正确 |
| C12 旧数据兼容 | ✅ `RecentPlay.fromJson` 对缺 `albumAudioId` 兜底 `''`，`ts` 非 int 兜底 0，`where((r) => r.hash.isNotEmpty)` 过滤脏数据 |
| C12 清空确认 | ✅ `showDestructiveConfirm` 返回 `ok == true` 才 clear，dialog pop(false)/barrier dismiss 均返回 null→false，正确 |
| C14 未登录引导 | ✅ 两处均 `context.push('/login')`，路由存在（app_router.dart:44） |
| D15 menuItems 配对 | ✅ 三个调用点（home `_SongTile`、search 单曲 Tab、library 最近播放）都只声明 `'download'` 且 `onMenuSelected` 都有对应 `'download'` 分支；SongTile 内 `onMenuSelected?.call` 空安全 |
| D16 player 导航 | ✅ `/player` 是根级 GoRoute（app_router.dart:45），push 后覆盖整个 shell（含底部栏+MiniPlayer），返回回到原 Tab，不会叠在 Tab 内部——符合全屏播放器惯例 |
| D17 主题 token | ✅ 基本全用 `colorScheme.*`；仅有的硬编码色（`_RankRow` 底部 `Colors.black87`/白字、`_MyPlaylistRow` 角标 `Colors.black54`/白字、`GradientChip` 白字）都压在网络图片/渐变之上，深浅色下均成立，属合理例外 |

---

## 三、总体评价

三个模块结构清晰、容错解析（models.dart 的字段别名/单位换算注释）质量很高，没有编译阻塞级问题。最需要优先处理的是 **F1/F2（音乐库登录态与最近播放的非响应式读取，属功能性缺陷）** 和 **F3（专辑跳转到错误路由）**；其次 E1（后台轮播耗电）与 E2（下拉刷新闪屏）。E5 的 `memCacheWidth` 是一行改动收益最大的内存优化。
