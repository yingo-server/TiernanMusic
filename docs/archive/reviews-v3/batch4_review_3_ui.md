# 第4批·审查③：UI/UX 与状态一致性回归（只读）

- 基线：commit 6e46611
- 范围：home / search / player / library / settings / auth / playlist / comment / download / core(router+widgets)
- 方法：逐文件全量阅读；只记录问题+位置+依据+影响，不含修复建议

---

## 1. lib/features/home/presentation/home_page.dart

### home_page.dart:339 推荐歌单入口被 `collection_` 前缀判断吞掉
- 级别：P1
- 依据：`final gid = p.globalCollectionId; if (!gid.startsWith('collection_')) { Toast.show(context, context.l10n.playlistUnavailableSoon); return; } context.push('/playlist/...');`
- 影响：首页「推荐歌单」整排卡片在服务端返回非 `collection_` 前缀 id（或空串）时全部只弹「敬请期待」Toast，用户点了毫无跳转；这是首页最主要的运营位，点击不可达属于交互断链。空串同样命中该分支，等价于静默失败。

### home_page.dart:130-155 Banner 自动播放的「Tab 可见性」判断实际无效
- 级别：P2
- 依据：注释称 `IndexedStack 下 isCurrent 无法表达 Tab 可见性，需显式跟踪生命周期 + Tab 可见性`，但成员只有 `bool _visible = true;`，仅在 `didChangeAppLifecycleState` 里赋值；定时器里用的是 `ModalRoute.of(context)!.isCurrent`。
- 影响：StatefulShellRoute 分支页面常驻同一 ModalRoute，切到「搜索/我的」Tab 后定时器仍每 4s 调 `animateToPage`，后台持续翻页与重建，耗电且回到首页时 Banner 已跳到不确定页；注释与实际行为不符，后续维护易误判已修复。

### home_page.dart:140-142 `_visible` 变化未触发重建、也永不恢复计时
- 级别：P3
- 依据：`didChangeAppLifecycleState` 仅 `_visible = state == AppLifecycleState.resumed;`，无 `setState`；后台期间 `Timer.periodic` 仍在跑空转。
- 影响：仅靠成员变量遮住跳页，定时器本身不在后台暂停，长时间后台仍有周期性唤醒；不影响可见 UI，故降级 P3。

### home_page.dart:196-210 banner 圆点指示器不可点击、且无「第 N 张/共 M 张」语义
- 级别：P3
- 依据：`for (var i = 0; i < widget.banners.length; i++) Container(width: i == _index ? 16 : 6, height: 6, ...)`，无 GestureDetector、无 Semantics。
- 影响：Banner 条数多时用户只能等 4s 或滑动手势；读屏用户无法得知轮播位置（可访问性 G）。

### home_page.dart:177-195 Banner 点击无任何跳转
- 级别：P2
- 依据：`_BannerCarousel` 的 itemBuilder 只有 `Padding > ClipRRect > CachedNetworkImage`，无 InkWell/onTap。
- 依据补充：首页运营 banner 通常指向歌单/活动页。
- 影响：banner 是首页最大视觉点击目标却完全不可交互，用户反复点击无响应（A 可达性）。

### home_page.dart:231-250 每日推荐卡固定高 110 + 固定宽 220，大字号溢出
- 级别：P2
- 依据：`SizedBox(height: 110, child: ListView.separated(... itemBuilder: return SizedBox(width: 220, child: Card(child: Row(children:[SizedBox(width:78,height:78,...), Expanded(child: Column(children:[Text(s.name, maxLines:1...), SizedBox(height:4), Text(s.singer, maxLines:1...)])])))))`
- 影响：系统字体放大到 1.5×/2.0× 时，两行文本高度超过 110-16 的可用高度，卡片内 Column 纵向溢出（黄黑条）；中文歌名/歌手在 220 宽减 78 图后仅剩约 134px，长文案基本只能看到 4-5 字（D 布局健壮性）。

### home_page.dart:318-378 推荐歌单卡固定高 180 且文字区未约束
- 级别：P2
- 依据：`SizedBox(height: 180, ... ClipRRect(130×130) + SizedBox(height: 6) + Text(p.name, maxLines: 2))`
- 影响：130 + 6 + 两行 bodySmall（正常约 32，1.5× 时约 48）已逼近 180，字体放大即底部被裁切/溢出；且 `_HomeSkeleton` 用同一 180 高度做骨架，真实内容溢出时骨架对齐假设失效。

### home_page.dart:59-73 空态判定要求「所有区块都空」才展示
- 级别：P3
- 依据：`if (data.banners.isEmpty && data.dailyRecommend == null && data.playlists.isEmpty && data.ranks.isEmpty && data.songs.isEmpty)`
- 影响：仅 banner 有数据（其余接口失败/返回空）时，页面只剩一张轮播图 + 大片空白，无任何「暂无内容/重试」提示，用户无法判断是空数据还是加载失败（F 空态/错误态区分）。

### home_page.dart:34-42 部分区块失败无独立错误提示
- 级别：P3
- 依据：`homeAsync.when(error: ...)` 仅在整体 provider 抛错时展示；data 分支内各 section 仅按 `isNotEmpty` 决定是否渲染。
- 影响：单个接口（如排行榜）失败被静默吞掉，页面看起来「内容变少」，用户没有任何重试入口（F）。

### home_page.dart:502-518 `_SongTile` 菜单只有下载，缺失播放/收藏/下一首播放
- 级别：P3
- 依据：`menuItems: [SongTileMenuItem(value: 'download', ...)]`，`onMenuSelected` 只处理 `'download'`。
- 影响：与列表页其他位置（歌单/搜索/播放队列）的操作集不一致，用户在同一首歌的不同入口看到不同菜单，学习成本与预期错位（G/M3 一致性）。

### home_page.dart:455-465 RankRow 名称使用硬编码白色 + 黑色渐变
- 级别：P3
- 依据：`Text(r.name, style: const TextStyle(color: Colors.white, ...))` 覆盖在 `LinearGradient(colors:[Colors.transparent, Colors.black87])` 上。
- 影响：绕过 colorScheme token；亮色主题下排行榜封面若本身很亮，`Opacity(0.5)` + luminosity 混合后上半部分文字对比度不足（虽然文字在下半黑渐变上，主要问题是不随主题/对比度设置变化，G 可访问性）。

## 2. lib/features/search/presentation/search_page.dart

### search_page.dart:517-523 分页失败后 footer 永久转圈，注释承诺的「重试」按钮不存在
- 级别：P1
- 依据：滚动监听 `if (_error != null) return;  // 失败态不自动重试……只走 footer「重试」按钮`；但 footer 渲染为 `if (i >= _items.length) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));`，全文件无 error footer 分支。
- 影响：第 2 页起请求失败（弱网/超时）时，列表底部一直显示加载圈且永不停，用户上滑无反应、也无重试按钮，只能改关键词或退出页面；有数据时的失败提示只有一条 Toast（`genericErrorTitle`），无补救路径（F 错误态无重试入口）。

### search_page.dart:83-95 `_submit` 因写搜索历史失败而整次搜索被吞掉
- 级别：P2
- 依据：`await ref.read(searchRepositoryProvider).addHistory(k); setState(() { ... _submittedKeyword = k; });` —— addHistory 为真实 Hive 写入（`_historyBox()`），无 try/catch。
- 影响：本地存储不可用/配额异常（如首次启动 box 打开失败）时抛异常，`_submittedKeyword` 不会更新，用户回车后页面毫无变化、无任何提示；搜索这一核心动作被非关键副作用阻塞（A 可达性 + F 错误态）。

### search_page.dart:606-609 歌单结果直接拼接 id，不做前缀校验与 URL 编码
- 级别：P2
- 依据：`onTap: () => context.push('/playlist/${p.globalCollectionId}'),`（首页同名入口为 `if (!gid.startsWith('collection_')) { Toast...; return; } context.push('/playlist/${Uri.encodeComponent(gid)}')`）
- 影响：两条入口对同一实体采取不同策略——搜索结果不做 `collection_` 校验也不编码，若 id 含 `/`、空格或非 collection_ 前缀，会跳到不存在的路由（404/错误页）或直接崩溃；用户从搜索进入歌单大概率失败（A 可达性）。

### search_page.dart:44-46 首帧强制聚焦，未校验 mounted
- 级别：P3
- 依据：`WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());`，`dispose` 中 `_focusNode.dispose();`
- 影响：从首页 push 后立刻返回时，postFrame 回调可能在 dispose 之后执行，触发 "A FocusNode was used after being disposed" 断言（debug 崩溃/日志噪音）。

### search_page.dart:659-664 专辑/歌手/MV 结果项 id 为空时点击无反应
- 级别：P3
- 依据：`if (type == 'mv' && s.hash != null) {...} else if (type == 'album' && s.id.isNotEmpty) {...} else if (type == 'author' && s.id.isNotEmpty) {...}` —— 无 else 分支。
- 影响：服务端缺字段时 ListTile 仍有水波纹但不跳转，也无 Toast 说明；用户以为点错（A 可达性）。

### search_page.dart:328-345 热搜 Badge 文案无长度约束
- 级别：P3
- 依据：`Badge(isLabelVisible: board.keywords[i].reason != null, label: Text(board.keywords[i].reason ?? ''), offset: const Offset(8, -4), child: GradientChip(...))`
- 影响：reason 通常为「热」「新」等单字，但服务端返回长文案（如「XXX 事件热搜」）时 Badge 会撑到远超 chip 宽度，Wrap 内横向溢出/遮挡相邻 chip（D 布局 + E 长文案）。

### search_page.dart:239-246 热搜返回空列表时无空态
- 级别：P3
- 依据：`data: (boards) { final visible = ...; return Column(...); }`，boards 为空时只剩 `SectionHeader(title: 热搜)` 与空白。
- 影响：网络代理失败但返回 200+空数组时，页面显示「热搜」标题下空白，用户无法区分「无热搜」与「加载失败」，也没有重试入口（F）。

### search_page.dart:196-215 历史记录的增删不会同步到已渲染列表之外的状态
- 级别：P3
- 依据：`onDeleted: () async { await ref.read(...).removeHistory(h); _loadHistory(); }`，`_history` 仅是本 State 的局部字段，`_loadHistory` 只在 initState 与增删后调用。
- 影响：从搜索结果返回落地页时 State 被重建可覆盖大部分场景，但同一 Session 内通过其它入口（如播放页添加的历史）变化不会反映，属弱一致性问题；影响有限，P3。

## 3. lib/features/player/presentation/

### full_player_page.dart:54-62 无歌曲时整页仍是空壳，且「下载」菜单禁用但「队列」可用
- 级别：P2
- 依据：`song = ref.watch(currentSongProvider).valueOrNull;` 为 null 时，页面照常渲染标题「正在播放」、`_CoverOrLyric(song: null)` 占位图、歌名回退 `context.l10n.notPlaying`、进度条 total=0 → `maxMs = 1.0`、控制按钮全部可点（controller.prev/next 对空队列无作用）。
- 影响：直接通过 `/player` 深链、或队列清空后停留在此页时，用户看到一整套「正在播放」控件，点播放/上一首/下一首全部无反馈；进度条可拖动但 seek 无意义。属于空态未区分（F）。

### full_player_page.dart:26-34 歌词错误文案硬编码中文
- 级别：P2
- 依据：`if (candidate == null) return (lyric: null, error: '暂无歌词'); ... if (lyric == null) return (lyric: null, error: '歌词解析失败');`
- 影响：错误串直接来自 provider 层，不可本地化；且**该 error 从未在任何 UI 中被读取**（`_CoverOrLyric` 只判断 `lyricAsync.value?.lyric != null`，无 error 分支），非中文用户与中文用户都看不到任何反馈——无歌词时页面只是点「歌词」按钮后封面不变（E i18n + F 错误态）。

### full_player_page.dart:374-392 点击「显示歌词」在无歌词时无任何反应
- 级别：P2
- 依据：`AnimatedSwitcher(child: _showLyric && lyricAsync.value?.lyric != null ? FadeTransition(...) : _buildCover(context))`，而按钮的 label/icon 已切换为「显示封面」。
- 影响：无歌词歌曲点按钮后，图标算翻面（变成「显示封面」）但画面不变，用户反复点击看到封面毫无变化的「坏按钮」（A 交互可达性）。

### full_player_page.dart:393-415 歌词切换按钮浮在 `Expanded` 区域右下角，可能压住歌词行
- 级别：P3
- 依据：`Positioned(right: 16, bottom: 8, child: TextButton.icon(... minimumSize: const Size(48, 40)))` 叠在 `Stack` 上，`LyricView` 是整块填充。
- 影响：`LyricView` 未预留底部内边距时，最后一行歌词/点击区域被按钮遮挡；同时按钮无底色，在浅色封面上对比度可能不足（G 对比度、触控目标 40 高 < 48 建议值）。

### full_player_page.dart:143-185 副标题行 `Row` + `Flexible` 混用，芯片无最大宽度
- 级别：P3
- 依据：`Row(mainAxisAlignment: center, children: [if (isPreview) Container(...), if (quality != null) Container(...), Flexible(child: Text(song?.artist ...))])`
- 影响：只有歌手名是 Flexible，两个标签是固有宽度；当「试听」+「SQ」/「Hi-Res」标签本身超过可用宽度（窄屏或大字号）时整行横向溢出（D）。

### full_player_page.dart:71-76 顶部栏用 `Navigator.pop`，从深链进入时无返回对象
- 级别：P3
- 依据：`IconButton(icon: Icons.keyboard_arrow_down, onPressed: () => Navigator.of(context).pop())`
- 影响：`/player` 若成为首个路由（深链/通知跳转），pop 会退出到空白或关闭 App，收起按钮变成「退出」；无 `canPop` 兜底（A）。

### mini_player.dart:26-28 `song == null` 时返回 `SizedBox.shrink()`，但外层无动画
- 级别：P3
- 依据：`if (song == null) return const SizedBox.shrink();`
- 影响：播放结束清空队列时迷你播放器瞬间消失，下方列表内容跳动 64dp；无 AnimatedSize 过渡（体验细节，P3）。

### mini_player.dart:36-42 整条迷你播放器可点击，但 IconButton 与 InkWell 手势区重叠
- 级别：P3
- 依据：`InkWell(onTap: () => context.push('/player'), onLongPress: () => showQueueSheet(context), child: ... Row(children: [... IconButton.filled(...), IconButton(skip_next), IconButton(queue_music)]))`
- 影响：功能上正确（子按钮优先），但整条 64dp 高的可点击区在 Material 规范中属于超大触控目标，误触打开播放页概率高；且长按展开队列与点击播放在同一区域，反馈不一致（G）。

### mini_player.dart:24 / 40 背景使用 surfaceContainerHigh 叠加白/黑透明度固定值
- 级别：P3
- 依据：`color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55)`
- 影响：亮色主题下 0.55 透明背景叠加内容，如果迷你播放器悬浮在图片/彩色内容上，`onSurface` 文本对比度不稳定（G 可访问性）。

### queue_sheet.dart:44-53 队列标题栏在长语言下无 `Flexible`
- 级别：P3
- 依据：`Row(children: [Icon, SizedBox(8), Text(context.l10n.nowPlaying, ...), const Spacer(), Text(context.l10n.songCountSuffix(queue.length), ...)])`
- 影响：德语/俄语等长文案 + 队列数较大（如「1234 首歌曲」）时，两个 Text 都无 Flexible/ellipsis，Row 横向溢出（D + E 10 语言一致性）。

### queue_sheet.dart:60-120 队列项无「移除/清空」操作
- 级别：P3
- 依据：ListItem 仅有 `onTap: playQueue`，无 Dismissible、无菜单、无「清空队列」入口。
- 影响：用户无法从队列中删掉某首歌（只能靠重新播放整个歌单覆盖），是队列功能的常见预期缺口（A 功能可达性）。
