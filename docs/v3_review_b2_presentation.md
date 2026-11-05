# 第6批·审查②：表现层与交互（v3.0 终审 B 视角）

- 基线：`8c6a084`（`fix(V3-12): 澄清语言双源关系`）
- 范围：8 个文件，逐行完整阅读（共 2824 行）
  `player/presentation/full_player_page.dart`、`player/presentation/mini_player.dart`、
  `player/presentation/queue_sheet.dart`、`lyric/presentation/lyric_view.dart`、
  `player/play_helper.dart`、`player/player_provider.dart`、
  `search/presentation/search_page.dart`、`home/presentation/home_page.dart`
- 交叉核对（为验证表现层结论而完整读，不参与评分）：
  `core/theme/settings_provider.dart`、`core/router/app_router.dart`、`lib/main.dart`、
  `core/widgets/song_tile.dart`、`features/home/data/models.dart`、
  `features/player/data/models.dart`、`features/lyric/data/krc_parser.dart`、
  `features/mv/mv_provider.dart`
- 重点条款：第 20 / 24 / 26 / 18 / 16 条；其余条款出现即记。
- 方法：完整阅读 + 依赖契约核对（Riverpod `autoDispose` 语义、go_router `StatefulShellRoute.indexedStack` 的分支路由语义、just_audio 流语义）。未编译、未运行、未改动业务代码。

> 一句话结论：本批没有 P0/P1。dispose 对称性（第 20 条）整体做得好，唯一硬缺口是「在 build 里 new 的 `CurvedAnimation`」；真正的系统性问题在**热路径**（第 26 条，歌词页与全屏页随 position 全量重建）和**搜索页的状态互斥**（第 5/16 条，联想词永久不可达、加载更多失败后永久转圈）。

---

## 一、`lib/features/player/presentation/full_player_page.dart`

### R-01 `full_player_page.dart:378` build 内创建 `CurvedAnimation`，从不 dispose
- 级别：P2
- 依据：`opacity: CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic)` 位于 `build` 的 `AnimatedSwitcher` 分支内。`_fadeCtrl` 在 `dispose()` 里被释放（:351-356 ✔），但 `CurvedAnimation` 作为 `AnimationWithParentMixin` 会向父 controller 注册状态监听，官方要求用后 `dispose`。而本页在 :363 `ref.watch(positionProvider)`，歌词模式下 `build` 随播放进度每秒执行 ~4–10 次，即每 tick 新建一个 `CurvedAnimation` 并挂在同一个 controller 上。
- 违反第 20 条（资源必须对称释放）；连带第 25 条（无上限累积）、第 24 条（build 内分配对象）。
- 影响：歌词模式下播放越久，`_fadeCtrl` 上的监听器越多，每次 controller 通知都要遍历全部死监听器；表现为歌词页停留十几分钟后开始掉帧、内存缓慢上涨，且只有退出播放页才回收。

### R-02 `full_player_page.dart:363` 封面子树随播放进度全量重建
- 级别：P2
- 依据：`_CoverOrLyric.build` 第一行 `ref.watch(positionProvider)`，而它包裹的不只是 `LyricView`，还包括 `_buildCover`（:414-450：`Hero` + `CachedNetworkImage` + `BoxShadow` + `AspectRatio`）以及 `Positioned` 里的切换按钮。同一份 position 已经被拆出独立组件 `_ProgressBar`（:474）消费，说明作者知道要隔离；`mini_player.dart` 也专门拆了 `_MiniProgressBar`，唯独全屏页把 position 提到了封面之上。
- 违反第 26 条（每帧路径零分配/零重建）。
- 影响：暂停时无影响，一旦播放，全屏页每秒重建 ~10 次含图片解码器与阴影的子树，在低端机上下拉/点击有明显延迟，并持续触发 `CachedNetworkImage` 的 `build` 与 `MediaQuery` 查询。

### R-03 `full_player_page.dart:20-38, 376` 歌词 provider 的 `error` 字段从未被消费，失败/加载/无歌词三者同一表现
- 级别：P2
- 依据：`currentLyricProvider` 的返回类型是 `({KrcLyric? lyric, String? error})`，内部产出 `'暂无歌词'` / `'歌词解析失败'` 两种 error（:27, :31），但全页只有 `lyricAsync.value?.lyric != null` 一处判断（:376），`error` 在 `lib/` 范围内无读者——是「无人写入后无人读取」的死状态。叠加：加载中 `value == null`，也走同一个封面分支。
- 违反第 9 条（失败必须可观测）、第 16 条（空/加载/失败必须语义分离）、第 32 条（无人读取的状态）。
- 影响：歌词接口失败或解析失败时，用户看到的是封面，点击「显示歌词」毫无反应；用户无法区分「这首歌没有歌词」「还在加载」「加载失败该重试」，也就永远不会去重试。（注：`main.dart:243` 只把 `playerErrorProvider` 转 Toast，不含歌词错误。）

### R-04 `full_player_page.dart:396-404` 切换按钮的文案/图标与真实显示内容不一致
- 级别：P2
- 依据：`_showLyric` 是唯一的显示开关（:376 还要 `&& lyric != null`）。当 `_showLyric == true` 但歌词为空时，画面仍是封面，而按钮已经切成 `Icons.album_outlined` + `l10n.showCover`（:390-404）。
- 违反第 16 条（同一视图承载了两个不同事实）、第 30 条（名称/文案与行为不符）。
- 影响：用户在无歌词的歌曲上点「显示歌词」，看到按钮变成「显示封面」却还是封面，再点一次回到「显示歌词」——两次点击视觉零变化，判定为按钮失灵。

### R-05 `full_player_page.dart:270-277` `_MvEntry` 一名两职；`albumAudioId` 为空时评论入口被连带隐藏
- 级别：P3
- 依据：类名与文档注释（:264-269）声明「评论始终显示 + 仅有 MV 时显示」，但 :277 `if (albumAudioId.isEmpty) return const SizedBox.shrink();` 在渲染评论按钮之前就早退。同一组件内既管评论入口又管 MV 查询与跳转。
- 违反第 1 条（单一职责）、第 16 条（「没有 albumAudioId」被当成「没有这两个功能」）。
- 影响：`albumAudioId` 缺失的曲目（部分来源字段不全）播放页既没有评论入口也没有任何说明，用户会认为该功能不存在；同时该组件的改动理由有两个（评论入口调整 / MV 入口调整）。

### R-06 `full_player_page.dart:279-281` MV 查询的加载中/失败与「无 MV」同形
- 级别：P3
- 依据：`final mv = mvAsync.value;` 直接取 value，忽略 `mvAsync.isLoading / hasError`；`_MvEntry` 里一次 `songMvProvider(albumAudioId)` 请求（`mv_provider.dart` 为 `autoDispose`，不会串歌 ✔）。
- 违反第 16 条。
- 影响：进入播放页时 MV 按钮迟到约一个网络往返才出现（布局横向跳一下）；查询失败时按钮永久消失，用户无法判断是「本曲没有 MV」还是「查询失败」。

### R-07 `full_player_page.dart:469-476, 505-513` 拖动中切歌：`_dragMs` 跨曲残留
- 级别：P3
- 依据：`_dragMs` 只在 `onChangeStart/onChanged/onChangeEnd` 里维护，没有在 `currentSongProvider` 变化时清空。切歌后 `posMs` 变成 0，但 `value: (_dragMs ?? posMs)`（:501）仍用旧曲的毫秒值，仅被 `clamp(0.0, maxMs)` 夹到新曲时长内。`onChangeEnd` 无条件 `controller.seekTo(Duration(milliseconds: v.round()))`。
- 违反第 18 条（异步/外部事件后仍在写共享状态，无世代校验）。
- 影响：用户正拖着滑块时自动切到下一首，松手会把**新歌**跳到旧歌的位置（例如 3:20），表现为「切歌后突然从中间开始播」。

### R-08 `full_player_page.dart:511` `seekTo` 的失败未处理
- 级别：P3
- 依据：`onChangeEnd` 里 `controller.seekTo(...)` 未 `await`、未 `catch`；`PlayerController.seekTo` 直接透传 `_handler.seek`，引擎未就绪时会拒绝。
- 违反第 9 条（失败不可观测）。
- 影响：音频服务启动失败的场景下拖进度条，滑块先跳到目标再被 position 流拉回，用户得不到任何解释。

---

## 二、`lib/features/player/presentation/mini_player.dart`

### R-09 `mini_player.dart:18-31` 无状态的 `ConsumerStatefulWidget`
- 级别：P3
- 依据：`_MiniPlayerState` 没有任何字段、`initState`、`dispose`，`build` 里只用 `ref.watch/read`。可用 `ConsumerWidget`。
- 违反第 32 条（多余抽象）。
- 影响：无功能后果；每次都多一层 `State` 对象与生命周期开销，且向后来者暗示「这里有需要保住的状态」。

### R-10 `mini_player.dart:44-56, 150-166` 每 tick 重建的子树位于 `BackdropFilter` 之内
- 级别：P3
- 依据：`ClipRect > BackdropFilter(blur 18) > Container > Column > _MiniProgressBar`。进度条每个 position tick 改 `LinearProgressIndicator.value`，其重绘范围在模糊层内部，模糊层每帧都需要重新合成背景。
- 违反第 26 条（高频事件路径上的合成开销）。
- 影响：首页/歌单页滚动时底部同时存在 18px 高斯模糊与每秒数次的进度重绘，低端机上底部区域会先出现掉帧（该条为性能退化，非功能性错误）。

---

## 三、`lib/features/player/presentation/queue_sheet.dart`

### R-11 `queue_sheet.dart:105-110` 先 pop 再用闭包快照播放，无世代校验
- 级别：P3
- 依据：`onTap: () async { Navigator.pop(); if (isCurrent) return; await controller.playQueue(queue, i); }`。`queue` 与 `i` 是 `itemBuilder` 构建时的快照（:44 `ref.watch(queueProvider)`），`await` 期间队列可能已被自动切歌/上一首改写。
- 违反第 18 条。
- 影响：点歌的同一瞬间若有自动切歌，`playQueue(queue, i)` 会把整条队列重置成旧列表并从旧下标开始，用户听到的不是点的那首，且「随机播放」的历史被重置。

### R-12 `queue_sheet.dart:74` 空 hash 会让多行同时显示「正在播放」
- 级别：P3
- 依据：`final isCurrent = current?.hash == s.hash;`。`Song.hash` 允许为空串（`Song.fromJson` 的 `str([...])` 可返回 `''`），空串与空串相等。
- 违反第 17 条（标识符必须唯一且可判定）。
- 影响：队列里包含 hash 缺失的曲目时，这些行全部高亮并带 `graphic_eq` 图标，用户无法判断到底在播哪首。

### R-13 `queue_sheet.dart:43` 队列加载中显示「队列为空」
- 级别：P3
- 依据：`ref.watch(queueProvider).valueOrNull ?? const []`，`StreamProvider` 首帧无值，直接落到 `EmptyState(queueEmpty)`。
- 违反第 16 条。
- 影响：冷启动后首次打开队列弹层会先闪一帧「队列为空」，随后才出现列表。

---

## 四、`lib/features/lyric/presentation/lyric_view.dart`

### R-14 `lyric_view.dart:129-141` 后帧回调捕获过时的 `index`，且 `_pendingRebuild` 阻止重排
- 级别：P2
- 依据：`if (index != _currentIndex && !_pendingRebuild) { _pendingRebuild = true; addPostFrameCallback((_) { ... setState(() => _currentIndex = index); ... _scrollTo(index, jump: first); }) }`。`index` 是本次 `build` 的局部值；若在回调执行前又发生一次 build（position tick 或 seek），新 `index` 因 `_pendingRebuild == true` 被丢弃，回调仍用旧 `index` 滚动。
- 违反第 18 条（等待之后写入前必须确认自己仍是当前那一次）、第 24 条（build 内改状态）。
- 影响：拖动进度条跳到副歌时，列表先平滑滚到旧行（300ms 动画），下一 tick 才再滚到正确行——用户看到歌词「滚错再滚回来」，快速连续 seek 时更明显。

### R-15 `lyric_view.dart:158-162, 205-260` 所有可见行每 tick 重建并重新分配 `TextSpan`/`TextStyle`
- 级别：P2
- 依据：`_LyricLineTile(posMs: posMs)` 把位置传给每一行，`_buildOriginal` 对 `line.words` 逐字生成 `TextSpan` 且每个词 `new TextStyle(...)`（:238-248）。`ListView.builder` 的 `itemBuilder` 在父 `build` 后对所有已构建（可见）项重新执行，而父 `build` 每个 position tick 都跑（由 `full_player_page.dart:363` 驱动）。文件头注释（:8-11）声称「只让当前行随位置变化，其余行保持不变」，与实际不符。
- 违反第 26 条（每帧路径不得分配大对象、不得做线性遍历）；注释同时违反第 31 条。
- 影响：一屏 12–15 行、每行 10–30 个字，每 tick 分配数百个 `TextSpan` + `TextStyle`；低端机上歌词页持续播放时掉帧、GC 抖动，滑动更卡。

### R-16 `lyric_view.dart:129-137, 173` build 函数内写实例状态并排入副作用
- 级别：P2
- 依据：`_pendingRebuild = true;` 直接发生在 `build` 体内（:130），`_pendingRebuild` 字段声明在文件末尾 :173。构建函数因此不纯：同一帧内重复 build 的行为依赖于上一次 build 的写入。
- 违反第 24 条（build 必须是纯函数，不含状态变更）。
- 影响：高亮与滚动落后一帧（与 R-14 同源），且这种「build 里改状态」在热重载/重建顺序变化时表现不可预测——同一份 `position` 可能产生两种滚动结果。

### R-17 `lyric_view.dart:113-121` 「暂无歌词」硬编码中文
- 级别：P3
- 依据：`Text('暂无歌词')` 未走 `context.l10n`；`lyric_view.dart` 甚至没有 import `l10n`，而项目其余用户可见文案均已 l10n 化。
- 违反第 30 条（名称/文案即文档，用户可见文案不得写死单一语言）。
- 影响：英文/繁体界面里出现唯一一句中文；同时该处也无法区分纯音乐、解密失败、加载中（第 16 条已在 R-03 记录于上层）。

### R-18 `lyric_view.dart:100-104` 行高估算只覆盖 `bilingual`，漏掉 `translation`
- 级别：P3
- 依据：`hasTranslation = widget.mode == LyricDisplayMode.bilingual && translation.isNotEmpty`，但 `LyricDisplayMode.translation` 在 :224-237 同样渲染第二行译文（`titleMedium`），行高与单行不同。`_scrollTo` 的累计偏移依赖该估算。
- 违反第 24 条（估算必须覆盖所有显著变量——文件自己在注释里立了这条规矩）。
- 影响：译文模式下双行行被按 64px 计而实际 ~76px，误差随行号线性累积，播到后半段当前行偏出屏幕中心（与 F4-34 修复过的同类问题同型）。

### R-19 `lyric_view.dart:71-85` 注释称「扣除顶部 padding」，实际未计入 120px
- 级别：P3
- 依据：`ListView` 使用 `padding: EdgeInsets.symmetric(vertical: 120)`（:154），即内容真正起点是滚动偏移 120；`_scrollTo` 从 `offset = 0` 开始累加行高，未加 120。注释（:75-77）写「扣除顶部 padding 并让当前行居中」。
- 违反第 31 条（注释解释了「为什么」，但没有解释「实际行为」，反而陈述了未实现的动作）。
- 影响：每一次自动跟随的目标位置恒定偏上 120px（约两行），首行 `jump` 时更明显；用户看到的「当前行」长期停在屏幕中线偏上位置。

---

## 五、`lib/features/player/play_helper.dart`

### R-20 `play_helper.dart:27, 45, 66` `hash` 缺失时用 `id` 冒充 `hash`
- 级别：P2
- 依据：`hash: s.hash ?? s.id`。`HomeSong.id` 在 `models.dart:130-132` 的取值是 `hash.isNotEmpty ? hash : mixsongid/audio_id/id`——即当 `hash` 为空时，`id` 是一个**语义不同**的音频 id，不是可播放的 file hash。播放接口 `/v5/url` 只认 hash。
- 违反第 16 条（缺失与空值必须语义分离）、第 13 条（不得对上游数据形态做假设）。
- 影响：无 hash 的曲目在首页/搜索结果里与正常曲目完全同形，点下去能进播放页、能排队，但永远不会出声，用户只会看到一条通用「播放失败」Toast，且失败后自动跳歌，把整条队列一起带偏。

### R-21 `play_helper.dart:29-38 / 47-62 / 64-76` 同一 `Song` 转换逻辑复制三份
- 级别：P3
- 依据：`playHomeSong`、`playHomeQueue`、`playPlaylistSong/Queue` 各自手写一遍「hash 兜底 / albumId / albumAudioId / duration 秒转 / cover 兜底」，字段口径靠人肉对齐。
- 违反第 1 条（一个单元只做一件事，转换应只有一个实现）。
- 影响：后续 `Song` 增加字段（如 `localPath`、`quality`）时极易只改一处，导致「首页播放有音质偏好、歌单播放没有」这类漂移，且没有任何编译期提示。

### R-22 `play_helper.dart:27 et al.` 时长以裸 `int` 秒跨层传递，单位只存在于注释
- 级别：P3
- 依据：`duration: Duration(seconds: s.duration)`，`s.duration` 为 `HomeSong.duration`（`final int duration; // 秒`）。同一字段在 `SongTile(duration: s.duration)`（`search_page.dart:531`、`home_page.dart:481`）里原样以 int 传递，单位仅靠注释与白名单字段名维护。
- 违反第 15 条（单位必须在命名或类型上体现，不得靠注释）。
- 影响：一旦某个数据源把该字段填成毫秒（历史上 `timelength/timelen` 就是毫秒），进度条 max 会变成 1000 倍、时长显示 41:40，且没有任何异常抛出——表现为「进度条永远走不到头」，排查成本极高。

---

## 六、`lib/features/player/player_provider.dart`

### R-23 `player_provider.dart:144-145` `audioEngineReadyProvider` 是非响应式的可变状态快照
- 级别：P3
- 依据：`Provider<bool>((ref) => ref.watch(audioHandlerProvider).isEngineReady)` 读取一个 getter，不订阅任何流；而引擎是「首次播放时才惰性创建」（同文件 :197-204 `togglePlay` 里 `ensureEngineReady` 即为此路径）。
- 违反第 5 条（同一事实单一来源，派生状态必须随源变化）。
- 影响：启动时读到 `false` 的值会被 Provider 永久缓存；任何用它在 UI 上提示「音频服务不可用」的地方，在首次播放成功后仍会显示错误状态，只能重启 App 才消失。

### R-24 `player_provider.dart:85-92` `await for` + `yield*` 让世代切换依赖内层流自行结束
- 级别：P3
- 依据：`await for (final p in ref.watch(audioPlayerProvider.stream)) { ... yield* p.positionStream; }`。外层循环只有在 `p.positionStream` **关闭**之后才会取下一个 player；`audioPlayerProvider`（:39-43）的设计明确允许多次 yield（`engineReady` 流式补发）。
- 违反第 18 条（异步结果的有效性未做世代校验，切换后可能停在上一个源）。
- 影响：若引擎被重建而旧 `AudioPlayer` 未 dispose（`positionStream` 不关闭），进度/缓冲/时长会永久停在上一个实例上——表现为暂停键正常但进度条不动，且用户无法通过任何操作恢复。

### R-25 `player_provider.dart:70-77` `queueProvider` 每次发射同一个可变 `List` 引用
- 级别：P3
- 依据：`yield handler.songs;` + `await for (final _ in handler.queue.stream) { yield handler.songs; }`——事件只是「通知变了」，载荷是同一个 List 实例（若 `handler.songs` 原地增删）。
- 违反第 5 条（状态单一来源，但把可变引用直接交给 UI 层）。
- 影响：下游 `QueueSheet`/`_MiniProgressBar` 拿到的是同一引用，任何对 `songs` 的原地修改都会「回写」到已经渲染的组件里；若某次修改没有触发 `queue.stream`，弹层就会与实际队列不一致（点 A 播 B）。

---

## 七、`lib/features/search/presentation/search_page.dart`

### R-26 `search_page.dart:84-95` `_submit` 在 `await` 之后 `setState`，没有 `mounted` 检查
- 级别：P2
- 依据：`await ref.read(searchRepositoryProvider).addHistory(k);` 之后紧跟 `setState(() { _controller.text = k; ... })`。同文件其它异步点（:75 `_onChanged` 回调、:218 `_loadHistory`、:456/466 `_loadMore`）都做了 `mounted` 判断，唯独这里漏了。
- 违反第 18 条（异步结果必须校验世代/存活）。
- 影响：按回车的瞬间点返回或切 Tab（Hive 写盘有 IO 延迟），会抛 `setState() called after dispose`——debug 下红屏/断点，release 下日志噪声，且该次搜索被静默丢弃。

### R-27 `search_page.dart:88` `addHistory` 失败即中断整个提交链路
- 级别：P2
- 依据：`await addHistory(k)` 无 try/catch，异常向上冒泡到 `onSubmitted` 的 void 回调（未捕获）→ 后面的 `_submittedKeyword = k` 永不执行。
- 违反第 6 条（捕获后必须转译/记录/降级——这里是完全不处理）、第 9 条（失败无反馈）。
- 影响：Hive box 打不开或写入异常（低存储、损坏）时，用户按回车**毫无反应**，搜索框有字但结果区不动，用户只会反复按回车；一个「记录搜索历史」的次要功能失败连带主功能（搜索）失败。

### R-28 `search_page.dart:154-161` `_submittedKeyword != null` 优先于 `_showSuggest`，导致首次搜索后联想词永久不可达
- 级别：P2
- 依据：分支是 `_submittedKeyword != null ? _SearchResults : (_showSuggest ? _SuggestList : _SearchLanding)`。`_submittedKeyword` 只在 `_onChanged` 且文本为空时被置 null（:66-70），而 `_onChanged` 在输入非空文本时只设置 `_showSuggest`。于是「已提交过一次 + 用户继续输入」这个最常见状态下，`_showSuggest == true` 却永远走不到 `_SuggestList`——该分支在这一状态下不可达。
- 违反第 5 条（互斥状态用两个平行布尔表达，且优先级使其中一个失效）、第 32 条（不可达分支）。
- 影响：第一次搜索之后，再改关键词时下拉联想**再也不会出现**（100% 复现、无任何报错），用户只能盲打完整关键词回车；改了词也看不到建议，体验退化为「命令行搜索」。

### R-29 `search_page.dart:433, 514-522` 加载更多失败且已有数据：footer 永久转圈且无法重试
- 级别：P2
- 依据：失败分支（:465-472）只把 `_error = e`、`_loading = false`，不清 `_items`；`itemCount: _items.length + (_hasMore ? 1 : 0)` 仍为真，footer 是无条件 `CircularProgressIndicator`（:518-522），且滚动监听在 `_error != null` 时直接 return（:433），不再触发 `_loadMore`。全页唯一的「重试」入口在 :486 的 `_error != null && _items.isEmpty` 分支，此时不成立。
- 违反第 16 条（「加载中」与「失败」映射成同一个视图）、第 9 条（失败只剩一次性 Toast）。
- 影响：翻到第 3 页时网络抖一下，底部就开始永久转圈，再怎么下拉都不会再加载，用户以为「还有更多正在加载」——实际已死锁，唯一自救是重新搜索。

### R-30 `search_page.dart:609-613` 歌单结果封面按原图解码，且无空 cover 守卫
- 级别：P2
- 依据：`CachedNetworkImage(imageUrl: p.cover, width: double.infinity, fit: BoxFit.cover)`——没有 `memCacheWidth`（同文件 :682 的 48px 列表项、`song_tile.dart:88`、`home_page` 全站都有），也没有 `cover.isNotEmpty` 判断。
- 违反第 25 条（图片解码尺寸无上限）、第 14 条（边界不做校验：空 URL 直接请求）。
- 影响：歌单网格每张图按上游原图（常见 640–1080 见方）解码，单张 1–4MB；滚过一屏 20 张就是几十 MB，低端机直接 OOM/被杀；空封面时还会为 `''` 发一次无意义的图片请求。

### R-31 `search_page.dart:620-624, 706-710` 两个搜索 `family` provider 未 `autoDispose`
- 级别：P2
- 依据：`_playlistSearchProvider` 与 `_genericSearchProvider` 都是 `FutureProvider.family`（无 `.autoDispose`），键是新关键词/类型元组。对照：`mv_provider.dart` 全部带 `autoDispose`，`currentLyricProvider` 也带。
- 违反第 25 条（内存缓存条目无上限）。
- 影响：每搜索一个新词就永久留下 2 份完整结果列表（含每条 `HomeSong` 的 String 字段），长会话（几十次搜索）内存单调上涨且永不回收；切换 Tab 回来还会命中旧缓存造成内容过期。

### R-32 `search_page.dart:43-47` 首帧 `requestFocus` 无 `mounted` 检查
- 级别：P3
- 依据：`addPostFrameCallback((_) => _focusNode.requestFocus())`，回调里没有 `mounted` 判断，而 `dispose` 会 `_focusNode.dispose()`（:54）。
- 违反第 20 条（异步回调触及已释放对象必须先确认存活）。
- 影响：极端时序（首帧前就被 pop）下对已 dispose 的 `FocusNode` 调用 `requestFocus` 抛异常；正常路径无感。

### R-33 `search_page.dart:268-282` 热搜返回空数组时留下一个只有标题的空白区
- 级别：P3
- 依据：`data: (boards) { final visible = ...; return Column(children: [...for (final board in visible)...]); }`，没有 `boards.isEmpty` 分支；而 `error`/`loading` 都有对应视图。
- 违反第 16 条（确实为空应给出提示，而不是渲染空容器）。
- 影响：服务端返回 `[]`（无热搜档期）时，页面出现「热门搜索」标题下面一片空白，用户以为渲染坏了。

### R-34 `search_page.dart:210-223` 清空历史的 `await` 之后无 `mounted` 检查即用 `ref`
- 级别：P3
- 依据：`await showDestructiveConfirm(...)` → `await clearHistory()` → `_loadHistory()`（内部 `ref.read` 在 `mounted` 判断之前执行）。
- 违反第 18 条。
- 影响：确认框停留期间页面被销毁（切 Tab 重建/路由替换）时，`ref.read` 在已 dispose 的 `ConsumerState` 上调用会抛异常，清空动作的结果不可见。

### R-35 `search_page.dart:340-372` `TabBarView` 预建相邻 Tab，一次搜索并发 3 个请求
- 级别：P3
- 依据：`DefaultTabController(length: 5)` + `TabBarView(children: [ _SongResultTab, _PlaylistResultTab, _GenericResultTab(album), _GenericResultTab(author), _GenericResultTab(mv) ])`。`TabBarView` 会构建当前页与相邻页，`_SongResultTab.initState` 直接 `_loadMore()`，两个 `FutureProvider` 在首次 `watch` 时立即取数。
- 违反第 24 条（惰性构建：非当前 Tab 不应产生副作用/IO）。
- 影响：只想搜歌的用户，一次搜索会打 3 个接口（歌曲 + 歌单 + 专辑），之后每切一个 Tab 再打 1 个；弱网下首屏等待变长、流量放大，且失败率叠加（任一接口超时都会在对应 Tab 显示错误）。

### R-36 `search_page.dart:607-608` 空 `globalCollectionId` 直接拼路由
- 级别：P3
- 依据：`context.push('/playlist/${p.globalCollectionId}')`，未判空（`HomePlaylist.fromJson` 在缺失时会把 `numericId` 兜底进来，也可能两者皆空）。
- 违反第 14 条（边界参数未校验）。
- 影响：点到一个缺 ID 的歌单卡片，跳到 `/playlist/` → 路由匹配失败，落到错误页，用户以为 App 崩了。

### R-37 `search_page.dart:672-683` MV 结果 `hash == null` 时点击完全无反馈
- 级别：P3
- 依据：`if (type == 'mv' && s.hash != null) { context.push(...) } else if ...`——三个条件都不满足时什么也不做，`onTap` 仍非空（`ListTile` 有涟漪）。
- 违反第 9 条（失败/不可用必须给出反馈）。
- 影响：点一条缺 hash 的 MV 结果，有波纹、无跳转、无提示，用户反复点。

---

## 八、`lib/features/home/presentation/home_page.dart`

### R-38 `home_page.dart:75-78` 未登录（`dailyRecommend == null`）与「已登录但推荐为空」渲染完全相同
- 级别：P2
- 依据：`if (data.dailyRecommend != null && data.dailyRecommend!.isNotEmpty)` → 否则什么都不渲染。模型已经明确区分（`models.dart:255-256`：「每日推荐（未登录为 null，区分于空列表）」），UI 把两种事实合并成「没有这一块」。
- 违反第 16 条（未登录 / 已登录无内容必须语义分离）。
- 影响：未登录用户首页永远缺一块推荐，且没有任何「登录后查看每日推荐」的引导——这正是登录转化的主入口；用户只觉得首页内容少，不知道是权限导致的。

### R-39 `home_page.dart:490-500, 244-250` 播放入口 fire-and-forget，随后立即 push 播放页
- 级别：P2
- 依据：`helper.playHomeQueue(queue!, index); context.push('/player');`（:493-498），`_DailyRecommend` 的 `onTap` 同型（:247-249）。`playHomeQueue` 返回 `Future<void>`，既未 `await` 也未 `catchError`；`PlayerController.playQueue` 直接透传 handler，失败（无权益/无 hash/网络）时异常逃逸到 zone（`main.dart` 的 `runZonedGuarded` 只记录日志）。
- 违反第 9 条（失败要么用户可见要么日志——此处用户看到的是「播放页开了」但没声音）、第 18 条（后续 UI 跳转不等待结果有效性）。
- 影响：无版权/无 hash 的曲目点了之后照样进入全屏页，页面上仍是**上一首**的歌名封面（`currentSongProvider` 未变），用户完全无法判断是「点错了」还是「播放失败」；失败还会触发自动跳歌，把队列往下带一首。

### R-40 `home_page.dart:39-42` UI 层直接按路径前缀清理数据层缓存
- 级别：P3
- 依据：`onRefresh` 里 `MemoryCache.instance.removeWhere((k) => k.startsWith('/yueku') || k.startsWith('/top/playlist') || k.startsWith('/rank/list'))`，然后 `ref.refresh(homeDataProvider.future)`。缓存键的拼装规则（`MemoryCache.keyOf(path, query)`）属于数据层，UI 只应表达「刷新首页」。
- 违反第 4 条（分层单向依赖，UI 不得绕过数据层直接触达存储）、第 23 条（缓存维度知识散落在两处，必然漂移）。
- 影响：数据层一旦改路径（例如统一到 `gateway.kugou.com` 的新 path），这段前缀清空静默失效，用户下拉刷新后仍是 90s TTL 内的旧内容——「刷新没反应」，且没有任何报错。

### R-41 `home_page.dart:146-150` 注释声称的「非当前 Tab 不后台翻页」并未生效
- 级别：P3
- 依据：`final route = ModalRoute.of(context); if (route != null && !route.isCurrent) return;`。`MainShell` 用 `StatefulShellRoute.indexedStack`（`app_router.dart:27-43`），每个分支有自己的 Navigator，`/home` 在自己的分支里始终是栈顶，`isCurrent` 在切到搜索/设置 Tab 后仍为 `true`；`_visible` 只跟随 App 生命周期（:140-142）。
- 违反第 31 条（注释陈述了未实现的机制，属误导性文档），并连带第 26 条（隐藏 Tab 内的无效动画）。
- 影响：停在搜索 Tab 时，首页轮播每 4 秒仍在请求翻页（`animateToPage` 每次创建一个 400ms 动画）；切回首页时可能连续跳跃多张 Banner。注释让下一个维护者以为已经防住了。

### R-42 `full_player_page.dart:62-66`（跨文件·路由可达性）/ `/player` 可在无歌时被打开，且无空态处理
- 级别：P3
- 依据：`song?.name ?? context.l10n.notPlaying`、`_MvEntry(song: null)`（:277 早退）、`_ProgressBar` 显示 00:00/00:00、播放键调用 `togglePlay` 可能启动空播放。路由 `/player` 是顶层 `GoRoute`，任何 `context.push('/player')` 或深链均可直达。
- 违反第 16 条（「没有歌曲」这一事实只体现为文案，操作区不区分）。
- 影响：从 MV 页/异常路径/深链进入时是一个所有控件都「看起来能用但什么都不会发生」的空播放页，没有空态引导。

---

## 九、第 20 条全量核对表（申请/释放对称性）

| # | 资源 | 位置 | 释放点 | 结论 |
|---|---|---|---|---|
| 1 | `AnimationController _fadeCtrl` | full_player:342 | :353 `dispose` | ✅ 对称 |
| 2 | `CurvedAnimation`（build 内新建） | full_player:378 | 无 | ❌ R-01 |
| 3 | `ScrollController _scroll` | lyric_view:35 | :59 `dispose` | ✅ |
| 4 | `addPostFrameCallback`（歌词滚动） | lyric_view:131 | 回调首行 `if (!mounted) return` | ✅（但世代旧 → R-14） |
| 5 | `ScrollController _scroll` | search:407 | :445 `dispose` | ✅ |
| 6 | `Timer _debounce` | search:34 | :50 `cancel`（dispose）+ 每次变更前 cancel | ✅ |
| 7 | `TextEditingController` + listener | search:31 | :51 移除监听、:52 `dispose` | ✅ |
| 8 | `FocusNode` | search:32 | :53 `dispose` | ✅ |
| 9 | `addPostFrameCallback(requestFocus)` | search:43 | 无 `mounted` 判断 | ❌ R-32 |
| 10 | `Timer _timer`（轮播） | home:146 | :166 `cancel`（dispose） | ✅ 且回调有 `mounted` |
| 11 | `WidgetsBindingObserver` | home:135 | :167 `removeObserver` | ✅ |
| 12 | `PageController` | home:130 | :168 `dispose` | ✅ |
| 13 | `provider` 订阅（`StreamProvider`/`autoDispose`） | 全批 | Riverpod 自动 | ✅ |
| 14 | `onSongStarted` 订阅 | player_provider:163 | `ref.onDispose(sub.cancel)` | ✅ |
| 15 | `autoDispose` 的 future 在途 | full_player:20 | Riverpod 丢弃结果，但请求不可取消 | ⚠️ 仅浪费流量，不记问题 |

**第 20 条结论**：申请-释放配对是该代码库做得最好的一块（14/15 项干净）。真正的缺陷集中在「在被销毁前后仍可能被使用的对象」（#2、#9）与「回调捕获过期世代」（#4，已单列 R-14）。

## 十、第 24 / 26 / 18 / 16 条覆盖摘要

- 第 24 条（build 内 I/O/解析/状态变更、惰性构建）：R-01（build 内分配）、R-14/R-16（build 内改状态并排副作用）、R-18（估算漏变量）、R-35（非当前 Tab 预取）。
  未发现 build 内直接 I/O 或网络调用（所有网络都在 provider/回调里）——这一点是达标的。
- 第 26 条（热路径分配）：R-02（封面子树随 tick 重建）、R-10（模糊层内 tick 重绘）、R-15（每行每 tick 重建 + 逐字 TextSpan 分配）。**本批最主要的技术债在此。**
- 第 18 条（异步后无世代校验）：R-07、R-11、R-14、R-24、R-26、R-34、R-39。搜索页 `_loadMore`/`_onChanged`/`_loadHistory` 已正确加了 `mounted` 与文本相等校验，属修复到位，不记问题。
- 第 16 条（空/加载/错误三态）：R-03、R-04、R-05、R-06、R-13、R-29、R-33、R-38、R-42。首页骨架屏（`_HomeSkeleton`）、错误页（`ErrorRetry`）、空态（`EmptyState`）三件套齐全，属达标；缺口在「部分字段缺失/部分接口失败」这类中间态。

## 十一、已确认到位（复核通过，不记问题）

1. `lyric_view` 的 `_pendingRebuild` 在回调内**先**置 false 再 `mounted` 判断，且首帧 `jump` 后续 `animateTo` 的区分正确（F4-34/F4-35 修复有效）。
2. `_ProgressBar` 的 `_dragMs` 本地值与 `value.clamp(0.0, maxMs)`（V3-08）确实修掉了「切歌时 Slider 断言」与「tick 把滑块拉回」两个问题。
3. `_MiniProgressBar` 的拆分真实生效：`MiniPlayer` 只 watch 歌曲与播放态，位置订阅被隔离在 2px 进度条内。
4. `search_page._loadMore` 的 `_loading` 闸门是**同步**置位的（:451 在 await 之前），双击/连续滚动不会触发重复分页请求（第 19 条达标）。
5. `_SongResultTab` 的两个 await 分支都做了 `mounted` 判断；`AutomaticKeepAliveClientMixin` + `super.build(context)` 使用正确。
6. 轮播定时器的 `!mounted || banners.length < 2 || !_visible` 短路顺序正确，回调不会触及已销毁 context。
7. `main.dart:243` 已把 `playerErrorProvider` 统一转 Toast，播放失败有全局可观测出口（这是 R-03 只针对**歌词**错误的原因）。
8. `mv_provider` 的 `songMvProvider` 是 `family.autoDispose`，播放页切歌不会残留上一个歌的 MV 结果（第 23 条维度正确）。

---

## 十二、问题清单（按级别）

**P0（0 项）**：无。

**P1（0 项）**：无。

**P2（16 项）**
1. R-01 全屏页 build 内 new `CurvedAnimation` 且不 dispose（第 20/26 条）
2. R-02 封面子树随 position tick 全量重建（第 26 条）
3. R-03 歌词 error 字段无人消费，加载/失败/无歌词同一表现（第 9/16/32 条）
4. R-04 歌词切换按钮文案与真实显示不一致（第 16/30 条）
5. R-14 歌词后帧回调捕获过期 index，seek 后先滚错行（第 18/24 条）
6. R-15 所有可见歌词行每 tick 重建并逐字分配 TextSpan/TextStyle（第 26 条）
7. R-16 `lyric_view.build` 内写实例状态（第 24 条）
8. R-20 hash 缺失时用 id 冒充 hash（第 13/16 条）
9. R-26 搜索提交 `await` 后 setState 无 mounted 检查（第 18 条）
10. R-27 搜索历史写入失败即中断整个提交（第 6/9 条）
11. R-28 首次搜索后联想词永久不可达（第 5/32 条）
12. R-29 加载更多失败后 footer 永久转圈且无法重试（第 9/16 条）
13. R-30 歌单结果封面无解码上限、无空 cover 守卫（第 14/25 条）
14. R-31 两个搜索 family provider 未 autoDispose（第 25 条）
15. R-38 未登录与「推荐为空」渲染相同（第 16 条）
16. R-39 播放入口 fire-and-forget 后立即 push 播放页（第 9/18 条）

**P3（26 项）**
R-05、R-06、R-07、R-08、R-09、R-10、R-11、R-12、R-13、R-17、R-18、R-19、R-21、R-22、R-23、R-24、R-25、R-32、R-33、R-34、R-35、R-36、R-37、R-40、R-41、R-42

## 十三、统计表

| 文件 | P0 | P1 | P2 | P3 | 合计 | 主要问题域 |
|---|---|---|---|---|---|---|
| full_player_page.dart | 0 | 0 | 4 | 5 | 9 | 生命周期(1)、热路径(1)、三态(3)、拖动竞态(2)、空态(1) |
| mini_player.dart | 0 | 0 | 0 | 2 | 2 | 性能(1)、冗余结构(1) |
| queue_sheet.dart | 0 | 0 | 0 | 3 | 3 | 竞态(1)、标识符(1)、三态(1) |
| lyric_view.dart | 0 | 0 | 3 | 3 | 6 | 世代/纯函数(2)、热路径(1)、估算与注释(2)、i18n(1) |
| play_helper.dart | 0 | 0 | 1 | 2 | 3 | 语义兜底(1)、重复实现(1)、单位(1) |
| player_provider.dart | 0 | 0 | 0 | 3 | 3 | 非响应式状态(2)、可变共享(1) |
| search_page.dart | 0 | 0 | 6 | 6 | 12 | 订阅生命周期(2)、状态互斥(1)、分页失败态(1)、内存上限(2)、边界/反馈(4) |
| home_page.dart | 0 | 0 | 2 | 2 | 4 | 三态(1)、播放失败反馈(1)、分层(1)、注释失效(1) |
| **合计** | **0** | **0** | **16** | **26** | **42** | 第20条 2 项 / 第24条 3 项 / 第26条 3 项 / 第18条 7 项 / 第16条 9 项 |

> 条款分布（按引用次数，含多引用）：第 16 条 12、第 18 条 9、第 24 条 7、第 26 条 5、第 20 条 4、第 9 条 7、第 25 条 3、第 5 条 4、第 32 条 4、第 30 条 3、第 31 条 3、第 14 条 3、第 4 条 2、第 13 条 2、第 15 条 1、第 17 条 1、第 1 条 2、第 6 条 1、第 23 条 1。
