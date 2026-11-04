# 第2批·审查②：页面 UI 与交互（只读）

- 审查对象：`TiernanMusic`，基线 commit `73e72c0`（工作区 clean）
- 审查方式：逐文件静态阅读 + 生命周期 / 导航 / 状态流核对；**未构建、未运行、未修改任何源码**
- 审查范围：`lib/features/*/presentation/**`、`lib/core/widgets/**`、`lib/core/router/app_router.dart`、`lib/core/theme/**`、`lib/core/utils/toast.dart`、`lib/main.dart` 的 UI 部分
- 约束遵守：未读 `docs/batch1_*.md`、`docs/check_*.md`；仅用 `docs/PROGRESS.md` 对照声明（发现 1 处声明与代码不符，见 UI-08）
- 结论统计：**P0 0 / P1 9 / P2 29 / P3 17**（共 55 项）

> 说明：本报告只列问题与依据，不含修复方案。行号均为当前基线 `73e72c0` 的实际行号。

---

## 一、P1：明确的交互/功能错误

### UI-01 首页骨架屏横向溢出（每次冷启动可见）
- 位置：`lib/features/home/presentation/home_page.dart:551-583`（`_HomeSkeleton`）
- 依据：骨架用固定宽度 `Row` 而非横向滚动：
  - 每日推荐：2 × `SkeletonBox(width: 220)` + 12 间距 + 左右 16 padding = **484dp**
  - 推荐歌单：3 × `width: 130` + 2 × 12 + 32 = **446dp**
  - 排行榜：2 × `width: 200` + 12 + 32 = **444dp**
  `SkeletonBox` 的 `Container(width: ...)` 不做缩放（`lib/core/widgets/shimmer.dart:92-117`）。
- 影响：主流 360 / 393 / 412dp 宽度手机上，首页 loading 阶段即出现 RenderFlex 横向溢出（黄黑条纹），首屏观感被破坏；真实内容区用的是横向 `ListView`，骨架与内容结构不一致。

### UI-02 排行榜首屏加载失败后永久转圈
- 位置：`lib/features/rank/presentation/rank_detail_page.dart:36-54`、`96-99`
- 依据：`_load()` 失败只 `ScaffoldMessenger.showSnackBar(loadFailed)`，不记录错误态；`build` 用 `_songs.isEmpty` 直接返回 `CircularProgressIndicator`。无 `_error` 字段、无重试入口、无空态。
- 影响：断网 / 接口失败时页面永远停在加载圈；服务器返回 0 首歌时同样永远转圈，榜单页不可用。

### UI-03 “我的歌单”详情页“播放全部”取错数据源
- 位置：`lib/features/playlist/presentation/playlist_detail_page.dart:195-201`
- 依据：页面顶部已按账号类型选择数据源（`userPlaylistTracksProvider(userListId)` vs `playlistTracksProvider(id)`，见 `62-63`），但“播放全部”固定 `ref.read(playlistTracksProvider(id)).value`。
- 影响：用户歌单（`?user=<listid>`）中点击“播放全部”时，取到的是公共 gid provider 的结果（可能为空/另一份列表），按钮无反应或播放的不是当前展示的歌曲。

### UI-04 播放页“评论”入口被 MV 判定连带隐藏
- 位置：`lib/features/player/presentation/full_player_page.dart:269-331`
- 依据：`_MvEntry.build` 中 `if (albumAudioId.isEmpty) return SizedBox.shrink();`，随后 `if (mv == null || mv.videoId.isEmpty) return SizedBox.shrink();`；而“评论”按钮与“播放 MV”按钮在同一个 `Row` 内，只有函数走到最后才会渲染。
- 影响：没有 MV 的歌曲（绝大多数）播放页完全不显示评论入口；歌曲评论功能只能从歌单/专辑评论入口进入，单曲评论实际不可达。

### UI-05 播放页进度条拖动时逐帧 seek，滑块与播放位置互相抢值
- 位置：`lib/features/player/presentation/full_player_page.dart:488-495`
- 依据：`Slider(value: posMs, onChanged: (v) => controller.seekTo(...))`，没有 `onChangeStart/onChangeEnd` 本地拖动值；`posMs` 直接来自 `positionProvider`（播放器 positionStream）。
- 影响：拖动过程中每次 onChanged 都发起 seek，播放器回传的旧 position 又把滑块拉回，出现滑块跳动/回弹；慢设备上拖动结束位置与实际落点不一致。

### UI-06 歌手页“专辑”Tab 滑动切换不加载数据
- 位置：`lib/features/artist/presentation/artist_page.dart:192-194`、`300-320`
- 依据：`_loadAlbums()` 只在 `TabBar.onTap` 中触发（`if (i == 1 && !_loadedAlbums) _loadAlbums();`），`TabBarView` 默认允许左右滑动；`_buildAlbums` 在 `_albums` 为空且未加载时直接返回 `EmptyState(noData)`。
- 影响：用户左右滑动切到“专辑”页时看到的是“暂无数据”，只有再次点 Tab 才会请求；同一 Tab 的点击与滑动手势行为不一致。

### UI-07 切歌后歌词列表不回位（沿用上一首滚动位置）
- 位置：`lib/features/lyric/presentation/lyric_view.dart:53-58`、`88-98`
- 依据：`didUpdateWidget` 只在 `oldWidget.lyric != widget.lyric` 时重算 `_currentIndex`，没有重置 `_didInitialScroll`，也没有调用 `_scrollTo(0/当前行, jump: true)`；`_didInitialScroll` 只在新 State 的首次行变化时置真。
- 影响：播放页常驻，切到下一首后歌词仍停留在上一首的滚动偏移；若新歌词当前行号未变化（如都从 0 开始），`build` 里 `index == _currentIndex` 不会触发任何滚动，用户要等歌词第一次换行才看到自动跟随。

### UI-08 首页轮播未随 Tab 切走 / App 退后台停止（与 PROGRESS 声明不符）
- 位置：`lib/features/home/presentation/home_page.dart:123-158`
- 依据：`_BannerCarouselState` 只有 `State`，**没有** `WidgetsBindingObserver`；停止条件仅为 `ModalRoute.of(context)?.isCurrent`（`139-140`）。`StatefulShellRoute.indexedStack` 下每个分支有独立 Navigator，分支路由始终是该分支 navigator 的 current route，`isCurrent` 无法表达“当前 Tab 是否可见”；App 退后台时路由同样仍是 current。
- 影响：首页轮播在切到搜索/音乐库 Tab 或 App 进入后台后仍每 4 秒 `animateToPage`，产生后台动画与无谓唤醒。`docs/PROGRESS.md` 的“Tab 切走停翻页 + App 后台停（WidgetsBindingObserver）”声明与代码不一致。

### UI-09 设置页两个音质开关是无消费者开关（切换无任何效果）
- 位置：`lib/features/settings/presentation/settings_page.dart:540-554`；`lib/features/settings/presentation/settings_providers.dart:29-61`
- 依据：`wifiQualityProvider` / `cellularQualityProvider` 全项目只在设置页被 `watch/read`（`rg` 结果仅 settings_page 两处），播放链路取音质走 `preferredQuality()`（`lib/core/audio/preferred_quality.dart:8-19`），只读 `defaultQuality`，不看网络类型；`settings_providers.dart` 注释也写着“预留策略开关”。
- 影响：用户打开“WiFi 自动高品质 / 流量低品质”后播放/下载行为完全不变，属于可见但无效的设置项。

---

## 二、P2：次要但明确的缺陷

### UI-10 登录成功后 `go('/home')` 丢弃来源页面
- 位置：`lib/features/auth/presentation/login_page.dart:47-49`
- 依据：`_onLoginSuccess()` 固定 `context.go('/home')`；所有调用方都用 `context.push('/login')` 打开登录（评论页 `comments_page.dart:330`、设置页 `settings_page.dart:254/263`、音乐库 `library_page.dart:391/419`、登录守卫 `login_guard.dart:35`）。
- 影响：从评论页/歌单页/设置页去登录，成功后整栈被替换到首页，用户丢失原页面与未发送内容；`ensureLoggedIn` 的“登录后继续操作”流程实际不可返回。

### UI-11 二维码登录在 status=4 但换 token 失败后卡死
- 位置：`lib/features/auth/presentation/login_page.dart:566-586`、`640-660`
- 依据：`_checkOnce` 收到 status 4 后先 `setState(() => _status = 4)` 并取消轮询，再 `loginByQrToken`；失败只 `_showError` Toast，不重置 `_status`、不设置 `_error`。刷新按钮条件为 `_status == 0 || _error != null`。
- 影响：扫码确认后若换登录态失败（网络/风控），页面永久停在“登录成功”文案，无轮询、无刷新按钮，只能退出页面重进。

### UI-12 人机验证页整页文案硬编码中文
- 位置：`lib/features/auth/presentation/captcha_page.dart:108、139、296-330、361、377、391`
- 依据：`'人机验证' / '重试' / '短信验证' / '请输入接收到的验证码完成验证' / '提交验证' / '关闭' / '未知验证类型（v_type=…）' / '直接尝试提交指纹验证'` 均为字面量，未使用 `context.l10n`；`captcha_types.dart:11-38` 的类型名称同样是中文。
- 影响：非中文界面下登录/发评论/播放触发 20028 时，全屏验证页突然变成中文，且不可翻译。

### UI-13 短信验证页没有“发送验证码”入口
- 位置：`lib/features/auth/presentation/captcha_page.dart:290-330`
- 依据：`_buildSms` 只有验证码 `TextField` + “提交验证”按钮，没有发送/重发按钮；`VerificationService` 只有 `getVerifyInfo` 与 `submit`（`verification_service.dart:25-103`），没有发送短信验证码的方法。输入框 `maxLength: 8` 与 `hintText: '6 位数字'` 也不一致（`308-310`）。
- 影响：若服务端没有在 `get/verify/info` 阶段自动下发短信，用户无任何获取验证码的入口；提示 6 位但允许输入 8 位，提交后才失败。

### UI-14 腾讯验证 WebView 加载失败时只有全屏遮罩转圈
- 位置：`lib/features/auth/presentation/captcha_page.dart:205-220`
- 依据：`InAppWebView` 只注册 `onLoadStop` 置 `_webViewReady = true`，没有 `onReceivedError/onReceivedHttpError`；`if (!_webViewReady || _submitting) Container(color: Colors.black54, child: Center(CircularProgressIndicator))`。
- 影响：验证脚本（`https://turing.captcha.qcloud.com/TCaptcha.js`）加载失败/断网时，黑色遮罩与转圈永久盖住 WebView，页面内无错误提示，只能点左上角关闭。

### UI-15 评论页/楼层页登录态用 `ref.read` 而非 `watch`，登录返回后 UI 不刷新
- 位置：`lib/features/comment/presentation/comments_page.dart:181-182`；`lib/features/comment/presentation/comment_floor_page.dart:54`
- 依据：`bool get _isLoggedIn => ref.read(authStateProvider).valueOrNull != null;`，`build` 中没有 `watch(authStateProvider)`；`authStateProvider` 变化不会触发这两个页面重建。
- 影响：未登录点发送→登录页→返回后，输入框提示仍是“登录后评论”、回复/删除菜单仍不可用、发送按钮仍走登录引导，直到页面因其他原因重建。

### UI-16 楼层页未登录时发送按钮是空实现（无任何反馈）
- 位置：`lib/features/comment/presentation/comment_floor_page.dart:296`
- 依据：`onPressed: _isLoggedIn ? _send : () {}`；同项目评论页同位置是 `() => context.push('/login')`（`comments_page.dart:330`）。
- 影响：未登录用户点发送毫无反应，与评论页行为冲突，也无法从楼层页进入登录。

### UI-17 发送评论先清空输入框，失败后草稿丢失
- 位置：`lib/features/comment/presentation/comments_page.dart:349-351`；`lib/features/comment/presentation/comment_floor_page.dart:146-148`
- 依据：`_inputCtrl.clear();` 在 `await sendComment/sendFloorReply` 之前执行；异常分支只 Toast，不回填文本。
- 影响：网络失败或 20028 验证失败后用户输入的长评论不可恢复，需要重打。

### UI-18 评论点赞图标看起来可点，实际无点击行为
- 位置：`lib/features/comment/presentation/comments_page.dart:516-526`
- 依据：`Icon(Icons.thumb_up_outlined)` 与 `Text('${comment.likeCount}')` 直接放在 `Row` 中，无 `InkWell/IconButton/onTap`；`Comment` 解析了 `like.haslike`（`comment_repository.dart:227-237`）但 UI 完全未使用。
- 影响：用户按常规点击点赞无效且无反馈；已点赞状态也无法体现。

### UI-19 楼层页顶部评论高度无上限，长评论会挤掉回复列表
- 位置：`lib/features/comment/presentation/comment_floor_page.dart:201-217`、`218-224`
- 依据：顶部 `Container` 内 `Text(widget.comment.content)` 无 `maxLines`、无滚动；下方回复列表是 `Expanded`。
- 影响：顶层评论很长（或含多行换行）时，固定区可占满整屏，回复列表高度被压到 0，页面自身又不可滚动，楼层回复无法浏览。

### UI-20 评论列表为空时无法下拉刷新
- 位置：`lib/features/comment/presentation/comments_page.dart:198-207`
- 依据：`page.comments.isEmpty` 时直接返回 `EmptyState`，`RefreshIndicator` 只在非空分支；`EmptyState` 本身不可滚动。
- 影响：首次请求成功但无评论（或评论被删光）后，页面没有下拉刷新手势，只能退出重进；与列表非空时的刷新行为不一致。

### UI-21 搜索页修改关键词后仍停留在旧结果，联想列表被屏蔽
- 位置：`lib/features/search/presentation/search_page.dart:110-118`、`160-168`
- 依据：`build` 的分支顺序是 `_submittedKeyword != null ? _SearchResults(...) : _showSuggest ? ... : _SearchLanding()`；`_onChanged` 只在 `text.trim().isEmpty` 时清空 `_submittedKeyword`，非空输入时会更新 `_suggestions/_showSuggest` 但不会清空已提交关键词。
- 影响：提交过一次搜索后再改词，页面继续显示旧关键词的结果，新的联想结果虽然已请求但永远不可见；用户必须点“×”清空后重新输入。

### UI-22 搜索歌单结果直接使用可能为数字的 ID 跳转
- 位置：`lib/features/search/presentation/search_page.dart:606-608`；`lib/features/home/data/models.dart:180-190`
- 依据：`HomePlaylist.globalCollectionId` 在 `global_collection_id/global_specialid/gid` 缺失时回退为 `numericId`（`globalId.isNotEmpty ? globalId : numericId`）；搜索歌单卡无校验直接 `context.push('/playlist/${p.globalCollectionId}')`。首页同名卡片有 `if (!gid.startsWith('collection_')) { Toast(...); return; }` 的保护（`home_page.dart:330-334`）。
- 影响：搜索接口返回数字 specialid 时，点击会进入歌单详情并触发仓库的“歌单不存在或 ID 无效（需要 collection_ 形式的全局 ID）”错误页（`playlist_repository.dart:180`），与首页行为不一致。

### UI-23 搜索联想请求异常未捕获
- 位置：`lib/features/search/presentation/search_page.dart:66-83`
- 依据：`Timer(..., () async { final list = await ...fetchSuggest(...); if (!mounted ...) return; ... })`，Timer 回调内 `await` 没有 try/catch；`fetchSuggest` 内部虽有 try/catch（`search_repository.dart:253-260`）但 `_cachedGet` 之外的异常仍可能外抛。
- 影响：联想失败时异常进入 zone 被全局 ErrorLogger 记录，UI 无任何提示，旧联想也不清除；用户看到的是“输入无反应”。

### UI-24 设置页“账号管理”与账号行点击行为完全相同（都去登录页）
- 位置：`lib/features/settings/presentation/settings_page.dart:238-266`
- 依据：账号 `ListTile.onTap` 与 `_navTile(title: accountManage).onTap` 都是 `await context.push<void>('/login'); _loadAccount();`；`LoginPage` 本身没有账号列表/资料管理界面。
- 影响：已登录用户点“账号管理”看到的是登录方式选择页，无法管理当前账号；“账号管理”文案与页面内容不符，且与上方账号行重复。

### UI-25 切换账号底部弹层不可滚动，账号多时溢出
- 位置：`lib/features/settings/presentation/settings_page.dart:313-341`
- 依据：`showModalBottomSheet<AccountRecord>(context: ..., showDragHandle: true, ...)` 未传 `isScrollControlled`，内部是 `Column(mainAxisSize: min, children: [标题, Divider, for (final a in accounts) ListTile...])`，没有 `ListView`/`Flexible`。
- 影响：默认弹层最大高度约为屏幕 9/16，3-4 个以上账号时 ListTile 总高度超过限制，出现底部裁切/溢出，排在后面的账号无法点击。

### UI-26 MV 页退出后强制锁定竖屏，且系统 UI 模式被留在 `edgeToEdge`
- 位置：`lib/features/mv/presentation/mv_player_page.dart:45-60`；`lib/features/mv/presentation/mv_player_page.dart:99-108`
- 依据：`dispose()` 固定 `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);`，项目其他地方没有恢复 `[]`（全项目仅 MV 页调用该 API）；`dispose` 还固定 `setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`。`build` 中每次构建都通过 `addPostFrameCallback` 设置系统 UI 模式。
- 影响：看过一次 MV 后，应用在本进程内被永久锁竖屏，其他页面旋转失效；退出 MV 后状态栏模式也与进入前不一致。

### UI-27 播放页歌词加载失败/无歌词时没有任何可见反馈
- 位置：`lib/features/player/presentation/full_player_page.dart:24-37`、`366-396`
- 依据：`currentLyricProvider` 返回 `(lyric, error)`，但 `_CoverOrLyric` 只判断 `lyricAsync.value?.lyric != null`，`error` 从未读取；点击“查看歌词”时若 lyric 为 null，`_showLyric` 变 true 但分支仍走 `_buildCover`。
- 影响：歌词接口失败/无歌词时，点“查看歌词”按钮毫无变化（按钮文案却已切成“查看封面”），用户无法判断是加载中、无歌词还是失败。

### UI-28 播放页音质标签使用枚举里的中文 `label`
- 位置：`lib/features/player/presentation/full_player_page.dart:171`；`lib/features/player/data/models.dart:5-9`
- 依据：`Text(quality.label)`，`AudioQuality` 的 label 固定为 `'标准' / '高品' / '无损' / 'Hi-Res' / '臻品母带'`；设置页同一概念走 `_qualityNames(context)` 的本地化映射（`settings_page.dart:44-53`）。
- 影响：英文/日文等界面播放页音质 chip 显示中文，且与设置页对同一音质的称呼不一致。

### UI-29 歌单详情“收藏”图标无状态、无取消收藏
- 位置：`lib/features/playlist/presentation/playlist_detail_page.dart:82-94`、`291-309`
- 依据：图标固定 `Icons.favorite_border`，`_collectPlaylist` 只调用 `collectPlaylist(...)`（`playlist_repository.dart:103`），仓库没有取消收藏方法；收藏成功后无 `setState`/provider 刷新。
- 影响：收藏成功后图标仍是空心，用户重复点击会重复请求；已收藏歌单无法取消，图标语义与实际状态不符。

### UI-30 歌手页头部：长简介被裁切，标题重复
- 位置：`lib/features/artist/presentation/artist_page.dart:174-183`、`330-380`
- 依据：`SliverAppBar.large` 同时设置 `title: Text(info.name)` 与 `flexibleSpace: FlexibleSpaceBar(background: _Header(info))`；`_Header` 内 88 头像 + 名称 + 统计 + 最多 3 行简介（`_IntroBlock` `maxLines: _expanded ? null : 3`）同一个 `Row`，且 `info.name` 在 `_Header` 内再次出现。`.large` 的展开高度固定（约 152dp），背景还夹着工具栏/状态栏。
- 影响：简介较长时（3 行 bodyMedium + 间距）超出背景可用高度，被 `FlexibleSpaceBar` 裁切或压到折叠标题下；折叠/展开过程中同一歌手名出现两次。

### UI-31 歌单详情歌曲列表全部显示占位封面
- 位置：`lib/features/playlist/presentation/playlist_detail_page.dart:247-266`
- 依据：`SongTile` 未传 `cover`；而 `PlaylistSong` 明明有 `cover` 字段（`playlist_repository.dart:222-242`，注释写明“歌单歌曲有直接 cover 字段”）。同一处“下载”构造 `Song` 时也未传 `cover`/`albumId`（`268-276`）。
- 影响：歌单里每首歌左侧都是灰色音符占位图，与首页/搜索/专辑/歌手列表的封面展示不一致；从歌单下载的任务也缺封面信息。

### UI-32 搜索 / 评论 / 楼层分页失败后，列表尾部永久转圈且无重试
- 位置：`lib/features/search/presentation/search_page.dart:548-556`；`lib/features/comment/presentation/comments_page.dart:232-247`；`lib/features/comment/presentation/comment_floor_page.dart:235-247`
- 依据：分页列表末尾 item 的条件都是“`_hasMore`/`hasMore` 为真就返回 `CircularProgressIndicator`”，不区分是否正在请求；请求失败只 Toast 或静默，`hasMore` 仍为 true。
- 影响：网络错误后列表底部一直显示转圈，用户以为在加载；没有“重试”入口，继续滚动会重复触发请求（搜索页 `_error` 非空时虽停止自动请求，但尾部依旧转圈）。

### UI-33 首页搜索按钮与底部“搜索”Tab 共用同一路由，返回栈语义二义
- 位置：`lib/features/home/presentation/home_page.dart:50-56`；`lib/core/router/app_router.dart:44-46`；`lib/features/search/presentation/search_page.dart:104-118`
- 依据：`/search` 既是 `StatefulShellBranch` 的初始页面，又被首页 `context.push('/search')` 调用；SearchPage 用 `Navigator.of(context).canPop()` 决定是否绘制返回箭头。
- 影响：同一个页面同时承担“Tab 根页”和“被 push 的二级页”两种角色；从首页进入后出现返回箭头与底部搜索 Tab 选中态并存，返回栈/清除搜索状态的预期不明确（可能出现同分支叠加两个搜索页）。

### UI-34 底部导航栏文案硬编码中文
- 位置：`lib/core/router/app_router.dart:108-114`
- 依据：`NavigationDestination(... label: '首页')`、`'搜索'`、`'音乐库'`、`'设置'` 均为字面量；`app_zh.arb:4-7` / `app_en.arb:185-188` 已有 `home/search/library/settings` 键。
- 影响：切换到英/日/俄等语言后，主导航仍是中文，首屏即暴露 i18n 缺口。

### UI-35 大量用户可见错误/占位文案硬编码中文（i18n 不一致）
- 位置与依据（示例，均为会被展示到 UI 的字符串）：
  - `lib/features/home/data/models.dart:130-131、189、227`：`'未知歌曲' / '未知歌手' / '未知歌单' / '未知榜单'`
  - `lib/features/search/data/search_repository.dart:135-136`：歌手副标题 `'$albumCount 专辑' / '$audioCount 歌曲'`
  - `lib/core/utils/friendly_error.dart:9-16`：`'需要完成人机验证后重试' / '登录已过期，请重新登录' / '操作失败，请稍后重试'`
  - `lib/features/player/data/player_repository.dart:313-321`、`lib/features/player/data/audio_handler.dart:324-337`：播放错误全文中文，经 `playerErrorProvider` 直接 Toast
  - `lib/core/widgets/splash_screen.dart:21`：`'汀澜音乐'`（l10n 已有 `appName`）
  - `lib/main.dart:316`：启动错误页 `'应用启动异常'`
- 影响：切换语言后错误提示、空数据占位、启动页仍为中文；与项目已建立的 l10n 体系（305 个键）不一致。

### UI-36 长文案语言下三连 `SegmentedButton` 超出可用宽度
- 位置：`lib/features/auth/presentation/login_page.dart:109-127`；`lib/features/settings/presentation/settings_page.dart:390-412`、`509-527`
- 依据：三个互斥项横向 `SegmentedButton`（登录方式 / 主题 / 歌词模式），每段只包 `Text`，无换行/省略/横向滚动。实际翻译长度：俄语 `'Вход по паролю'`、`'Вход по QR-коду'`、`'Следовать системе'`、`'Двухъязычный режим'`；德语 `'Anmeldung mit Passwort'`、`'Systemvorgabe'`、`'Zweisprachiger Vergleich'`（`app_ru.arb:148-149/194-196/392-394`、`app_de.arb:144-146/198-199/292-294`）。
- 影响：360dp 宽设备 + 俄/德界面时按钮行总宽超过可用宽度（约 328dp），出现 RenderFlex 横向溢出；设置页主题/歌词模式同样问题。

### UI-37 歌单简介展开后同一段文字重复显示
- 位置：`lib/features/playlist/presentation/playlist_detail_page.dart:157-190`
- 依据：`ExpansionTile` 的 `subtitle` 始终渲染 `detail.intro`（maxLines 2），展开后 `children` 又渲染完整 `detail.intro`（无 maxLines）。
- 影响：展开状态下顶部两行摘要与下方全文重复，长简介把歌曲列表进一步推远；收起/展开的视觉反馈被重复文案削弱。

### UI-38 歌手页专辑请求失败被静默吞掉并显示“暂无数据”
- 位置：`lib/features/artist/presentation/artist_page.dart:110-140`、`300-320`
- 依据：`_loadAlbums` 的 `catch (_) { ... _loadedAlbums = true; }` 不保存错误、不 Toast；`_buildAlbums` 在 `_albums.isEmpty` 时直接 `EmptyState(noData)`，`_loadedAlbums` 之后也不会自动重试。
- 影响：网络失败与“确实没有专辑”在 UI 上不可区分，用户无法重试；该 Tab 首次请求失败后只能退出重进。

---

## 三、P3：一致性 / 打磨

### UI-39 专辑页头部在歌曲未加载完成时显示“0 歌曲”
- 位置：`lib/features/album/presentation/album_page.dart:31、61-90、199-212`
- 依据：`_total` 初始 0，头部文案 `'${_total} ${l10n.tabSongs}'` 在 `_loadSongs` 返回前就渲染；歌曲失败时也保持 0。
- 影响：进入专辑页先闪一下“0 歌曲”，与下方转圈/骨架状态矛盾；失败时头部信息错误。

### UI-40 榜单列表没有名次
- 位置：`lib/features/rank/presentation/rank_detail_page.dart:146-160`
- 依据：`SongTile(title/artist/cover/duration)` 没有传入序号，也没有第 1/2/3 名特殊样式。
- 影响：TOP500/排行榜的核心信息“第几名”缺失，用户无法定位名次。

### UI-41 下载页点击已完成条目打开失败无提示
- 位置：`lib/features/download/presentation/download_page.dart:290-299`
- 依据：`PublicMediaStore.instance.open(...)` 的 `bool` 返回值被忽略；同页菜单里的 `'open'` 分支有 `if (!opened) Toast(...)`（`219-230`）。
- 影响：文件被系统删除/URI 失效时，点击条目没有任何反馈，用户以为点击无效。

### UI-42 下载弹层无条件提供“MV”下载
- 位置：`lib/features/download/presentation/download_sheet.dart:100-108`
- 依据：MV 选项始终渲染，`buildTask(DownloadTaskType.mv)` 只用 `song.hash/albumAudioId`，没有“是否存在 MV”的判断；播放页的 MV 存在性查询是独立的 `songMvProvider`。
- 影响：没有 MV 的歌曲也会出现 MV 下载项，点击后生成必然失败的任务，增加下载页噪音。

### UI-43 Toast 位置固定 96dp，与迷你播放器 + 底栏重叠
- 位置：`lib/core/utils/toast.dart:103`
- 依据：`bottom: media.padding.bottom + 96`；`MainShell` 底栏为 `MiniPlayer(64)` + `NavigationBar(68)`（`app_router.dart:101-114`、`mini_player.dart:44`），合计 132dp + 安全区。
- 影响：有播放内容时全局 Toast 落在迷你播放器区域内，遮挡歌名/按钮；无迷你播放器时又偏高，位置不随底栏状态变化。

### UI-44 固定高度容器不抗系统字体放大
- 位置：`lib/features/player/presentation/mini_player.dart:44-90`；`lib/features/home/presentation/home_page.dart:163、222、309、388`；`lib/features/library/presentation/library_page.dart:458`
- 依据：迷你播放器 `Container(height: 64)` 内是 44 封面 + 两行文字 + 3 个 48dp IconButton；首页横排 `SizedBox(height: 110/150/180)`、歌单横排 `170`；全项目没有 `textScaler`/`MediaQuery.textScaler` 处理。
- 影响：系统字体放大（1.5x-2x）时两行歌名/歌手在 64dp 内垂直溢出，横排卡片文字被裁切或压到下一行；这是全局可访问性缺口。

### UI-45 播放页无歌曲时仍展示完整控制区
- 位置：`lib/features/player/presentation/full_player_page.dart:60-230`
- 依据：`song` 为 null 时标题显示 `l10n.notPlaying`，但进度条、播放/暂停 FAB、上/下一首、随机/循环仍可点击；`togglePlay` 会尝试初始化音频引擎（`player_provider.dart:160-175`）。
- 影响：直接打开 `/player`（或播放失败清空当前歌）时，用户面对一套“可操作但无内容”的控制台，点击播放无明确结果。

### UI-46 最近播放不保存时长，重播时 `Song.duration` 为 0
- 位置：`lib/features/library/data/recent_play_store.dart:6-27`；`lib/features/library/presentation/library_page.dart:203-217`
- 依据：`RecentPlay` 只有 hash/name/artist/cover/ts/albumAudioId，无 duration；`_playRecent` 构造 `Song` 时也不传 `duration`（默认 `Duration.zero`）；歌词语义依赖 `durationSec`（`full_player_page.dart:26-30`）。
- 影响：最近播放列表不显示时长（与其他列表不一致）；重播时歌词候选匹配拿到 0 秒时长，可能选中错误的歌词版本。

### UI-47 播放队列弹层没有删除/清空/排序
- 位置：`lib/features/player/presentation/queue_sheet.dart:78-140`
- 依据：列表项只有 `onTap` 切歌；无 `Dismissible`/长按菜单/清空按钮；`MiniPlayer` 长按与显式队列按钮都只打开该只读弹层（`mini_player.dart:35-36、116-120`）。
- 影响：用户无法移除单曲、清空队列或调整顺序，队列只能整体替换；长列表下只能逐首切歌。

### UI-48 首页 Banner 无点击行为，`extra` 字段未使用
- 位置：`lib/features/home/presentation/home_page.dart:156-205`；`lib/features/home/data/models.dart:236-252`
- 依据：Banner item 是 `Padding > ClipRRect > CachedNetworkImage`，无 `InkWell/GestureDetector`；`HomeBanner` 解析了 `extra`（标题/跳转信息）但 UI 从未读取。
- 影响：轮播图是纯装饰，点击无反应；与“可点击 Banner”的用户预期不符，`extra` 成为死数据。

### UI-49 点歌后不等待播放结果就跳播放页，易闪现上一首
- 位置：`lib/features/home/presentation/home_page.dart:236-241、484-489`；`lib/features/album/presentation/album_page.dart:104-110`；`lib/features/artist/presentation/artist_page.dart:143-147`；`lib/features/rank/presentation/rank_detail_page.dart:87-91`
- 依据：`playHomeQueue/playQueue` 是异步但调用处不 `await`，下一行立即 `context.push('/player')`；播放页 `currentSongProvider` 在 `playSong/playQueue` 完成前仍是旧值（或 null）。
- 影响：首次播放/慢网络时播放页先显示“未在播放”或上一首的封面标题，随后才跳变；播放失败时用户已进入播放页，只能靠全局 Toast 得知。

### UI-50 设置页旧版音质值 `'hires'` 会原样显示
- 位置：`lib/features/settings/presentation/settings_page.dart:44-53、530-536`；`lib/features/settings/presentation/settings_providers.dart:12-19`
- 依据：`_qualityNames` 只有 `'128/320/flac/high/super'`，副标题用 `_qualityNames(context)[quality] ?? quality`；`DefaultQualityNotifier` 直接读取 Hive 字符串，不做 `AudioQuality.fromString` 归一化；`models.dart:28-46` 才兼容 `'hires'`。
- 影响：从旧版本升级的用户若 Hive 里仍是 `'hires'`，设置页“默认音质”显示英文 `hires`，且该值不会出现在音质选择弹层的选项中（选中态找不到对应项）。

### UI-51 加载态组件不统一（骨架屏 vs 转圈 vs 全屏 spinner）
- 位置：首页 `_HomeSkeleton`（`home_page.dart:531`）、搜索 `ListSkeleton`（`search_page.dart:451、579`）、专辑 `CircularProgressIndicator`（`album_page.dart:96-99`）、歌手 `CircularProgressIndicator`（`artist_page.dart:220、296`）、榜单 `CircularProgressIndicator`（`rank_detail_page.dart:97`）、歌单详情 `CircularProgressIndicator`（`playlist_detail_page.dart:69`）
- 依据：同类列表加载在不同页面分别使用 skeleton / 居中 spinner / `SliverFillRemaining` spinner，尺寸与占位结构各不相同。
- 影响：页面切换时加载视觉跳变明显，与搜索页注释宣称的“列表加载用骨架屏而非转圈”不一致。

### UI-52 设置页缓存统计在主 isolate 递归遍历目录
- 位置：`lib/features/settings/presentation/settings_page.dart:88-117`
- 依据：`_loadCacheSize` 在 UI isolate 中 `await for (entity in dir.list(recursive: true))` 并逐个 `entity.length()`；进入设置页 `initState` 即执行，点刷新也执行。
- 影响：缓存目录文件多/大时（下载目录、图片缓存）设置页首帧与刷新按钮明显卡顿。

### UI-53 搜索同一关键词再次提交不会刷新结果
- 位置：`lib/features/search/presentation/search_page.dart:127-136`
- 依据：`_SearchResults(key: ValueKey(_submittedKeyword), keyword: ...)`；同关键词重复提交时 key 不变，`_SongResultTab` 的 State（含 `_items/_page/_error`）被复用，`initState` 不再执行。
- 影响：用户点历史记录里的同一关键词或再次回车，看到的仍是上次缓存的列表/错误态，无法手动重试首页结果。

### UI-54 歌手页专辑 Tab 无分页；搜索非单曲 Tab 也无分页
- 位置：`lib/features/artist/presentation/artist_page.dart:292-320`；`lib/features/search/presentation/search_page.dart:578-620、640-715`
- 依据：`_albumPage` 只在 `_loadAlbums` 内自增，UI 没有加载更多入口；搜索的歌单/专辑/歌手/MV Tab 都只渲染 `r.items` 首屏（`searchByType` 默认 30 条）。
- 影响：专辑/歌手作品超过一页时后面内容永远不可达；搜索结果超出 30 条也无法继续浏览。

### UI-55 专辑详情错误态嵌套 Scaffold、无标题
- 位置：`lib/features/album/presentation/album_page.dart:92-103`
- 依据：外层 `Scaffold(body: FutureBuilder(...))`，`snap.hasError` 分支又返回一个 `Scaffold(appBar: AppBar(), body: ErrorRetry(...))`。
- 影响：错误页出现双层 Scaffold（背景/安全区行为叠加），AppBar 无标题，返回按钮依赖隐式 canPop；与其他页面使用单层 Scaffold + ErrorRetry 的结构不一致。

---

## 四、问题索引（按文件）

| 文件 | 条目 |
| --- | --- |
| `lib/features/home/presentation/home_page.dart` | UI-01、UI-08、UI-33、UI-44、UI-48、UI-49 |
| `lib/features/rank/presentation/rank_detail_page.dart` | UI-02、UI-40、UI-49 |
| `lib/features/playlist/presentation/playlist_detail_page.dart` | UI-03、UI-29、UI-31、UI-37、UI-51 |
| `lib/features/player/presentation/full_player_page.dart` | UI-04、UI-05、UI-27、UI-28、UI-45、UI-46 |
| `lib/features/artist/presentation/artist_page.dart` | UI-06、UI-30、UI-38、UI-49、UI-54 |
| `lib/features/lyric/presentation/lyric_view.dart` | UI-07 |
| `lib/features/settings/presentation/settings_page.dart` | UI-09、UI-24、UI-25、UI-36、UI-50、UI-52 |
| `lib/features/auth/presentation/login_page.dart` | UI-10、UI-11、UI-36 |
| `lib/features/auth/presentation/captcha_page.dart` | UI-12、UI-13、UI-14 |
| `lib/features/comment/presentation/comments_page.dart` | UI-15、UI-17、UI-18、UI-20、UI-32 |
| `lib/features/comment/presentation/comment_floor_page.dart` | UI-15、UI-16、UI-17、UI-19、UI-32 |
| `lib/features/search/presentation/search_page.dart` | UI-21、UI-22、UI-23、UI-32、UI-53、UI-54 |
| `lib/features/mv/presentation/mv_player_page.dart` | UI-26 |
| `lib/features/download/presentation/download_page.dart` | UI-41 |
| `lib/features/download/presentation/download_sheet.dart` | UI-42 |
| `lib/core/router/app_router.dart` | UI-33、UI-34 |
| `lib/core/utils/toast.dart` | UI-43 |
| `lib/core/widgets/splash_screen.dart`、`lib/main.dart` | UI-35 |
| `lib/core/audio/preferred_quality.dart`、`lib/features/settings/presentation/settings_providers.dart` | UI-09 |
| `lib/features/library/data/recent_play_store.dart`、`library_page.dart` | UI-46 |

---

*本报告为只读审查产物；所有结论均可按“位置”直接复核，未执行任何构建/测试/修改。*
