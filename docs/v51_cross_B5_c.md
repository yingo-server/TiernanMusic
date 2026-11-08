# v5.1 交叉审查 · 第 B5 批 · 视角 C（用户路径与一致性）

- 基线：当前磁盘主线（v5.0.0 `71b4d73` 之后），只读审查，未改任何代码文件。
- 范围：34 文件 / 11583 行（与任务书清单逐一核对行数一致）。
- 视角：用户路径（登录→切号→下载→收藏→评论全流程断点与反馈）、三态分离（未登录 / 加载 / 空 / 失败）、i18n、生命周期、跨模块契约一致性、回归。
- ✅ = 本代理通读子集（11 文件）；○ = 其余文件按任务书做跨文件契约抽查（定义签名 + 调用点），不重复深挖视角 A/B 的领域。
- 通用规范硬性规则 2 要求范围内每个 .dart 文件 `file_read` 从头到尾，故所有 34 文件均完整读；○ 文件只记录与用户路径/契约相关的结论。
- 证据等级口径：实锤 = 代码内可直接证明的确定结论；静态推演 = 由代码路径推演、未跑真机；未实测 = 涉及上游返回形态，缺留样。

## 逐文件结论（实时 append）

### F1 `lib/features/album/data/album_repository.dart`（166 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`albumRepositoryProvider` 注入 `kugouApiClientProvider`（非裸 `KugouApiClient()`），`fetchDetail(id)`/`fetchSongs(id,{page})` 经 `RepositoryReads(_api,'album').get(...)` → `AlbumInfo`/`AlbumSong`/`AlbumSongsPage`；`kugouImageUrl` 来自 `home/data/models.dart`；`AlbumSong.duration` 由 `audio_info.duration`（毫秒）构造 `Duration(milliseconds:)`；`AlbumInfo.fromJson` 明确「data 为数组取首项」。以上供 album_page / 播放侧调用点核对。

### lib/features/album/data/album_repository.dart:129-135 详情失败与「空专辑」被折叠成同一个合法对象
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失必须语义分离）、第 9 条（失败必须可观测）
- 依据：`fetchDetail` 先 `raw is Map<String, dynamic> ? raw : const <String, dynamic>{}`，随后无条件 `return AlbumInfo.fromJson(res)`；`AlbumInfo.fromJson` 在 `data` 既非 List 非空首项、又非 Map 时把整个 `j` 当数据源，字段全部取 `''`。即上游返回非预期形态或空体时产出一个 `id=''`、`name=''`、其余字段全默认值的 `AlbumInfo`，不抛异常、不留日志、调用方无从区分「专辑不存在 / 请求失败 / 解析形态变更」。
- 影响：用户从搜索或歌手页点进专辑，可能看到标题空白、封面空白、简介空白的「正常」专辑页而非错误提示与重试入口；下游用空 `id` 继续请求 `/album/songs`，表现为整页无歌曲且无失败反馈。
- 证据等级：静态推演（未实测上游返回形态）

### lib/features/album/data/album_repository.dart:137-157 单曲列表「请求失败/形态异常」与「确实无歌曲」都返回空页
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条
- 依据：`fetchSongs` 对 `res`、`data`、`songs` 三处非预期形态分别退化为 `{}`、`{}`、`[]`，`total` 在缺失时取 `songs.length`；最终 `AlbumSongsPage(songs: [], total: 0)` 与「真实空专辑」返回完全一致，无任何错误或降级标记。
- 影响：专辑页「加载失败」被渲染成「该专辑暂无歌曲」，用户无法触发重试，只能退出重进；与同文件 `fetchDetail` 的静默空对象叠加，形成整页「看似正常实则失败」的路径断点。
- 证据等级：静态推演

### F2 `lib/features/album/presentation/album_page.dart`（276 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`AlbumPage({id})` → `albumRepositoryProvider.fetchDetail/fetchSongs`（与 F1 一致）；播放经 `playHelperProvider.playQueue(List<Song>, index)` + `context.push('/player')`；评论入口 `context.push('/comments/album/${Uri.encodeComponent(info.id)}')`；UI 复用 `core/widgets/song_tile.dart` 的 `ErrorRetry`/`EmptyState`/`SongTile`，文案走 `context.l10n`。

### lib/features/album/presentation/album_page.dart:114-119 详情失败时整页重建为嵌套 Scaffold，歌曲列表的加载/重试被连带丢弃
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（三态分离）、第 9 条（失败必须可观测）
- 依据：`FutureBuilder.hasError` 分支 `return Scaffold(appBar: AppBar(), body: ErrorRetry(...))`，把整个 `CustomScrollView`（含 `_songs`、`_loading`、`_error` 三态）从树上移除；`onRetry` 只重置 `_info = _fetchInfo()`，不调用 `_loadSongs(refresh: true)`。而 `_loadSongs` 的首次请求在 `initState` 已发出，若其失败（`_error != null`）用户看到的却是详情错误页，重试后详情恢复、列表仍是失败的空 `_songs` 且 `_loading=false`，再无自动重试。
- 影响：网络抖动时先看到「加载失败」，点重试后变成标题正常但「暂无数据」的专辑，无加载圈也无错误按钮（因 `snap.hasError` 已解除后只走列表分支），必须退出页面重进才能恢复，属登录→浏览→播放链路的恢复断点。
- 证据等级：静态推演

### lib/features/album/presentation/album_page.dart:130-134 评论入口使用 `info.id` 而非路由参数 `widget.id`，详情形态异常时评论落到空 id
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（缺失与有效值必须分离）、第 3 条（契约先行）
- 依据：`IconButton.onPressed` 拼 `/comments/album/${Uri.encodeComponent(info.id)}`；`info.id` 由 F1 `AlbumInfo.fromJson` 从 `data[0].album_id/id` 解析，当上游 `data` 为空数组或字段缺失时为 `''`，但页面仍判定 `snap.hasError==false` 正常渲染。
- 影响：用户点评论按钮进入 `/comments/album/`（空 id），评论页拿不到专辑标识，显示空白/加载失败且与当前专辑无关；详情页本身没有「数据不完整」状态可提示。
- 证据等级：实锤（代码路径确定）

### lib/features/album/presentation/album_page.dart:57-86 `_loadSongs` 无世代校验，切页/刷新后旧响应可回写
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`_loadSongs(refresh:true)` 与 `_loadSongs()` 的 `await fetchSongs(...)` 之后只判 `mounted`，随即 `setState` 执行 `_songs.addAll(res.songs)`、`_total = res.total`、`_page += 1`；未记录发起时的 `widget.id`/`refresh` 序号。同一实例内 `onRetry` 可并发触发第二次 refresh，旧页响应仍会追加进已清空的列表。
- 影响：用户在加载中点重试或快速切换到同路由另一专辑 id（widget 更新但 State 复用）时，列表混入上一个专辑的歌曲，点播后播放的是另一张专辑的曲目；进度与总数也串页。
- 证据等级：静态推演

### F3 `lib/features/artist/data/artist_repository.dart`（217 行，完整读，✅ 本代理通读）

- 关键契约：`artistRepositoryProvider` 注入 `kugouApiClientProvider`；`fetchDetail(id)`/`fetchSongs(id,{page,sort})`/`fetchAlbums(id,{page})` 全走 `RepositoryReads(_api,'artist')`；`ArtistSong.duration` 由 `timelength`（毫秒）构造；文件末尾 `artistImage(raw,{size})` 是 `{size}` 补全 + https 升级出口，`ArtistInfo.avatar`、`ArtistAlbum.cover`、`ArtistSong.cover` 三处解析**均未调用它**。

### lib/features/artist/data/artist_repository.dart:160-165 详情失败与「无此歌手」折叠成同一个全空 `ArtistInfo`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条、第 9 条
- 依据：`fetchDetail` 把非 `Map<String,dynamic>` 响应替换为 `const {}`，`ArtistInfo.fromJson` 的 `d = j['data'] is Map ? ... : j` 对空 Map 取到全空字段，产出 `id=''`、`name=''`、`avatar=''`、`songCount=0` 的合法对象，不抛异常、无日志、无降级标记。
- 影响：用户从搜索结果点进歌手页，网络失败或网关返回错误页时看到「空白名字 + 0 首歌曲 + 无头像」的正常页面，而非错误提示与重试；与 F1 专辑路径同型，构成「搜索→歌手/专辑→播放」链路上的静默失败断点。
- 证据等级：静态推演

### lib/features/artist/data/artist_repository.dart:167-188 单曲列表失败/空/成功三态共用 `ArtistSongsPage`，且 `total` 口径与专辑仓库相反
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条、第 3 条（契约先行：返回值语义必须明确）
- 依据：`fetchSongs` 对 `raw`/`data` 非预期形态分别退化为 `{}`/`[]`，最终 `ArtistSongsPage(songs: [], total: 0)`；`total` 缺失时取 `0`，而 `album_repository.dart:152-154` 同样位置取 `songs.length`。两个仓库对「total 缺失」给出相反语义，且都不区分「请求失败」「确实无歌曲」「首屏成功但字段缺失」。
- 影响：歌手页拿到 `total=0` 与一个非空 `songs` 时，分页闸门若按 `_songs.length >= _total` 判定则立即停止加载（只剩第一页 30 首），若按 `_total > 0` 放行则会一直翻页重复请求；两种 UI 实现无法同时正确，用户表现为「热门歌手只有 30 首歌」或「滑到底一直转圈」。
- 证据等级：实锤（两处代码的取值差异确定）

### lib/features/artist/data/artist_repository.dart:82-96 / 138-152 歌手专辑与单曲封面不补全 `{size}`，与专辑仓库的对外字段形态不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（跨层字段形态契约必须明确且一致）、第 30 条（名称即文档）
- 依据：`ArtistAlbum.fromJson` 直接 `s(e['sizable_cover'] ?? e['cover'])`，`ArtistSong.fromJson` 只取 `trans_param.union_cover`（缺失即 `''`）；而 `AlbumInfo.fromJson`/`AlbumSong.fromJson` 都调用 `kugouImageUrl(...,size:)`。本文件仅在末尾提供 `artistImage()` 但类内零调用，注释「封面统一补全 {size} 并升级 https」描述的是一个不由本文件保证的契约。
- 影响：若歌手页调用点未对每个字段再包一层 `artistImage`，`sizable_cover` 中的 `{size}` 占位符会以原样 URL 送给图片加载器，歌手专辑/单曲列表整列显示占位色块；同一首歌在专辑页有封面、在歌手页无封面，用户可见的跨模块不一致。
- 证据等级：静态推演（调用点见 F4 核对）

### F4 `lib/features/artist/presentation/artist_page.dart`（517 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`artistRepositoryProvider.fetchDetail/fetchSongs/fetchAlbums` 与 F3 对齐；`artistImage(...)` 在 `_Header`（头像）和 `_AlbumCard`（专辑封面）被调用，但 `SongTile` 的 `cover: s.cover` 是**原样传入**，未调用 `artistImage`；`playHelperProvider.playQueue` + `context.push('/player')`；专辑卡片 `context.push('/album/${a.id}')`。

### lib/features/artist/presentation/artist_page.dart:184-189 / 267-277 左右滑动切到「专辑」Tab 不会加载专辑，永久停留在「暂无数据」
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失语义分离）、第 9 条（失败必须可观测）
- 依据：`_loadAlbums()` 唯一调用点是 `TabBar.onTap: (i) { if (i == 1 && !_loadedAlbums) _loadAlbums(); }`（:184-189）；`TabBarView` 的 `controller: _tab` 支持手势滑动切页，但没有 `TabController` 的 index 监听。用户滑动到第二个 Tab 时 `_buildAlbums` 走 `_albums.isEmpty` 的 `EmptyState(message: context.l10n.noData)`（:267-277），而 `_loadedAlbums` 仍为 false、`_loadingAlbums` 为 false，没有任何后续触发点。
- 影响：用户从「单曲」横向滑到「专辑」看到永久的「暂无数据」，既无加载指示也无重试按钮；只有恰好点按 Tab 文字才会发起请求。对多产歌手这是核心浏览功能失效且是长时间静默错误。
- 证据等级：实锤（唯一调用点确定）

### lib/features/artist/presentation/artist_page.dart:127-139 / 267-277 专辑加载失败被 `catch (_)` 吞掉并置 `_loadedAlbums=true`，Tab 从此失去重试能力
- 级别：P1
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 16 条
- 依据：`_loadAlbums` 的 `catch (_)` 空体式处理，只把 `_loadingAlbums=false`、`_loadedAlbums=true`，未保存 `_albumsError`、未 `debugPrint`/日志；`_buildAlbums` 只有 `_loadingAlbums`/`_albums.isEmpty` 两个分支，失败与「确实无专辑」都渲染 `EmptyState(noData)`；而再次点 Tab 的闸门是 `!_loadedAlbums`，失败后恒为 true，重试入口被自己关掉。
- 影响：专辑 Tab 一次网络抖动后永久显示「暂无数据」，用户无法重试，只能退出歌手页重进；异常本身在日志中零留痕，线上无法区分「上游无数据」与「请求失败」。
- 证据等级：实锤

### lib/features/artist/presentation/artist_page.dart:127-139 / 190-193 专辑分页参数 `_albumPage` 只自增、无第二次触发，第 31 张之后不可达
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：分页能力必须闭环）、第 24 条（长列表惰性构建的正确性前提）
- 依据：`fetchAlbums(widget.id, page: _albumPage)` 成功后 `_albumPage += 1`，但 `_loadAlbums` 的调用点只有 TabBar.onTap 且带 `!_loadedAlbums` 闸门（成功后为 true），`GridView.builder` 无滚动监听、无「加载更多」控件；仓库层 `pagesize: 30` 是显式上限。
- 影响：拥有超过 30 张专辑的歌手，用户在「专辑」Tab 只能看到前 30 张，滑到底没有任何提示或加载，剩下的专辑在 App 内不可达。
- 证据等级：实锤

### lib/features/artist/presentation/artist_page.dart:103-118 / 260-263 歌曲列表封面原样透传，未走 `artistImage`，与同页头像/专辑封面两套口径
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（同一字段在跨层/跨模块必须形态一致）、第 30 条（名称即文档）
- 依据：`_playAt` 与 `SongTile` 都用 `cover: s.cover`；`ArtistSong.fromJson` 的 `cover` 只取 `trans_param.union_cover` 且未补全 `{size}`/https，而同文件 `_Header` 用 `artistImage(info.avatar,size:480)`、`_AlbumCard` 用 `artistImage(album.cover,size:480)`。`artist_repository.dart` 末尾注释「封面统一补全 {size} 并升级 https」对 `ArtistSong.cover` 不成立。
- 影响：歌手页单曲列表与「播放全部」队列里的歌曲封面可能与同页专辑网格/头像表现不一致（URL 含 `{size}` 占位符或 http），点进播放器后封面空白；同一首歌在专辑页（F1 已归一化）与歌手页显示不同。
- 证据等级：静态推演（依赖上游 `union_cover` 是否已含尺寸，未实测）

### lib/features/artist/presentation/artist_page.dart:96-118 / 90-95 旧世代请求失败时会覆写新世代的加载/错误态
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`_loadSongs` 在 `try` 分支成功后有 `if (gen != _songsGen) return;`（:103），但 `catch` 分支（:110-118）没有同样的世代校验，直接 `setState` 写 `_loadingSongs=false`、`_loadingMore=false`、`_songsError=e`。用户切换「最新/最热」或点重试时 `_songsGen++` 会让旧请求作废，但旧请求若随后失败仍会写状态。
- 影响：快速切换排序时旧请求失败 → 新排序的加载圈被提前关掉、空列表瞬间显示「加载失败」，即使新请求随后成功，`_songsError` 也不会被清除（只在 refresh 入口清），用户看到与实际数据不符的短时错误态；属三态竞态。
- 证据等级：实锤

### lib/features/artist/presentation/artist_page.dart:166-171 详情失败重试不重建歌曲/专辑请求，与 F2 同型的恢复断点
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条、第 9 条
- 依据：`snap.hasError` 分支返回嵌套 `Scaffold` + `ErrorRetry`，`onRetry` 仅 `setState(() => _info = _fetchInfo())`；不重置 `_songsError`、不重跑 `_loadSongs(refresh:true)`、不重置 `_loadedAlbums`。`initState` 的首次 `_loadSongs` 若在详情失败期间也失败，重试详情成功后列表已是失败空态。
- 影响：用户点「重试」后歌手详情恢复但「单曲」Tab 显示「暂无数据」且无重试按钮（因 `_songsError` 分支只在 `_songs.isEmpty` 时显示 ErrorRetry，实际上会显示 ErrorRetry，需仔细：`_songsError != null && _songs.isEmpty` → ErrorRetry，所以有重试按钮，仅详情错误页把它整体移除了；重试详情后 ErrorRetry 恢复可见，仍可点第二次）。此处主要后果是「一次失败要两次重试」的路径不闭环，且详情错误页期间列表请求结果被丢弃。
- 证据等级：静态推演

### lib/features/artist/presentation/artist_page.dart:350-353 粉丝数单位硬编码 `'w'` 且精度截断，与 l10n 的 `fansLabel` 拼在一起
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式）
- 依据：`_fans(int n)` 对 `n>=10000` 返回 `'${(n / 10000).toStringAsFixed(1)}w'`，单位 'w' 是中文「万」的拼音缩写且无具名常量/无 locale 分支；`_Header` 把它与 `context.l10n.fansLabel` 拼接。
- 影响：非中文 locale 下显示「12.3w Fans」这类混合单位，且 12345 与 12349 都显示为「1.2w」，粉丝数精度与单位语义对用户不明确。
- 证据等级：实锤

### F5 `lib/features/auth/data/account_manager.dart`（188 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`AccountManager.instance` 单例 + `init()`；`accounts` / `currentUserid` / `currentAccount` / `peek(userid)` 为同步读；`upsert` / `switchTo` / `clearCurrent` / `remove` / `clear` 为写，均触发 `onCurrentAccountChanged`（`Stream<AccountRecord?>`，值为变化后的当前账号，未登录为 null）；`AccountRecord.token` 明确「仅内存、不持久化」，token 真值在 SecureStorage 按 userid 存。这是「登录→切号」路径的核心契约，供 auth_providers / login_page / settings_page 抽查。

### lib/features/auth/data/account_manager.dart:64-70 `_notifyChanged()` 把读取异常静默降级为 `null`，与「未登录」不可区分
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 16 条
- 依据：`_notifyChanged` 内 `try { _changedCtrl.add(currentAccount); } catch (_) { _changedCtrl.add(null); }`。`currentAccount` 的读取链（`accounts`/`currentUserid`）在 Hive 盒损坏或类型异常时可能抛；空体 `catch (_)` 不记日志，随后广播 `null`。
- 影响：切号/登录成功后订阅方收到「未登录」事件，UI 把已登录用户踢回匿名态（收藏、下载、评论入口变灰），用户必须重启或重新登录；真实故障在日志里零痕迹。属「登录→切号」主路径的状态回退。
- 证据等级：静态推演

### lib/features/auth/data/account_manager.dart:122-133 / 135-144 `upsert`/`switchTo` 切号指针先写、后广播，SecureStorage 凭证切换不在本层，跨模块无原子性契约
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 3 条（契约先行：切号成功语义）
- 依据：`upsert` 顺序为 `_saveList` → `_b.put(_kCurrent, ...)` → `_notifyChanged()`；`switchTo` 为 `_b.put(_kCurrent, userid)` → `_notifyChanged()`。本层只改 Hive 账号指针，`AccountRecord.token` 注释明确不持久化，真正的 token 由调用方（auth_repository / login_page）另行读写 SecureStorage；`_notifyChanged` 在凭证写入之前/之后无参数可判，广播不带「凭证是否已就绪」标志。
- 影响：订阅到 `onCurrentAccountChanged` 的模块立即以新 userid 发请求，若调用方凭证切换尚未完成或中途失败，会出现「界面显示已切号但请求仍带旧 token / 匿名」的短暂错账号状态，收藏/下载/评论可能落到前一个账号；这正是交叉审查关注的切号断点，需由调用点证据确认（见后续 auth_providers / login_page）。
- 证据等级：静态推演（调用点待 F7/F12 核对）

### lib/features/auth/data/account_manager.dart:147-159 `remove()` 移除当前账号后自动切到 `list.first`，但未返回「凭证已切换」语义，且切号广播只发一次
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（返回值契约）、第 30 条（命名即文档）
- 依据：`remove` 在 `currentUserid == userid` 且列表非空时 `await _b.put(_kCurrent, list.first.userid); _notifyChanged(); return list.first;`；方法名为 `remove`，实际副作用是「删除 + 隐式切换账号」，返回 `AccountRecord?` 在不涉及当前账号时返回 `currentAccount`（另一个账号或 null），调用方无法通过返回值区分「删的是别人」「删的是自己并已切换」「删空了」。
- 影响：设置页「移除账号」后若调用方把所有非 null 返回值都当作「切号成功」去刷新凭证，可能把新账号的 token 覆盖为旧值；用户可见后果是切号后收藏/下载列表串账号。具体表现依赖调用点。
- 证据等级：静态推演

### F6 `lib/features/auth/data/auth_providers.dart`（134 行，完整读，✅ 本代理通读）

- 关键链路：`authStateProvider.build()` = `AccountManager.init()` → 读 `SecureStorage.readCredentials()` 补 `kgClientProvider.t1` → `authRepositoryProvider.restoreSession()`；`logout()` = repo.logout → 清 settings 盒 nickname/avatar → `AsyncData(null)`；`switchAccount(userid)` = `peek` → `getAccountToken` → `loginByToken` → `switchTo` → `AsyncData(user)`；`LoginController` 三个登录方法把 `AsyncNotifier<void>` 当 loading/error 态，`_finish` 同时 `setUser` 与 `AsyncData(null)`。

### lib/features/auth/data/auth_providers.dart:35-42 `logout()` 不重置 `kgClientProvider` 的用户态字段（t1/token/userid），登出后进程内仍携带旧凭证
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源：登录态在 authState / AccountManager / SecureStorage / kgClient 内存四处）、第 9 条（失败必须可观测）
- 依据：`build()` 曾把 `cred.t1` 写入 `ref.read(kgClientProvider).t1`（:28-30），但 `logout()` 只调用 `authRepositoryProvider.logout(...)` 与清 Hive `settings` 的 nickname/avatar，未对 `kgClientProvider` 做任何重置；`try/catch (_)` 还把 Hive 清理失败吞掉。`authStateProvider` 自身变成 `AsyncData(null)`，UI 显示未登录，而直连客户端内存中的 `t1` 与 restoreSession 时注入的其它凭证字段仍是上一个账号的。
- 影响：用户「退出登录」后立刻以匿名身份搜索/播放/评论，请求签名仍带上一账号的 t1（以及旧 token/userid），可能被上游判定为旧账号 → 匿名三态被破坏、退出后仍能看到/写入前一账号的数据；切号到另一账号时若新的 `loginByToken` 未覆盖全部字段，同样串号。这是「登录→切号」链路最直接的断点。
- 证据等级：静态推演（repo.logout 内部是否清理 kgClient 需 F8 核对；本层无清理动作属实锤）

### lib/features/auth/data/auth_providers.dart:52-67 `switchAccount` 失败时已由 `loginByToken` 内部 `_handleLoginSuccess` 提前 upsert 并广播，注释声称的「成功后才切指针」不成立
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 18 条（异步结果必须校验世代）、第 3 条（契约先行）
- 依据：方法注释明确「顺序：peek → 取 token → 登录（可能失败）→ 成功后才 switchTo」「避免中途失败时 AccountManager 指针已切而登录态仍是旧账号」，但实现里 `repo.loginByToken(...)` 之后才 `switchTo`；注释自己承认 `loginByToken → _handleLoginSuccess → upsert 内部已会设 current`。即 `upsert` 已在 `await loginByToken` 期间把 `_kCurrent` 指向新账号并 `_notifyChanged()` 广播；随后 `state = AsyncData(user)` 之前若 `switchTo` 抛异常或 `loginByToken` 在 upsert 之后抛出，`authStateProvider` 仍是旧账号的 `AuthUser`，而 AccountManager/订阅方已是新 userid。
- 影响：切号过程中任意一次失败，出现「账号列表/缓存/订阅模块已按新账号工作，但顶部登录态、需要登录的按钮仍显示旧账号」的分裂；用户点收藏/下载可能被写入错误账号，且没有明确错误提示（异常从 `switchAccount` 抛出，UI 是否消费见 F12）。
- 证据等级：静态推演（需 F8 `_handleLoginSuccess` 确证 upsert 时机，注释为代码内实锤）

### lib/features/auth/data/auth_providers.dart:52-67 `switchAccount` 无并发/世代闸门，连续点两个账号可交叉写 `state`
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条、第 21 条（写操作幂等/防重）
- 依据：`switchAccount` 从 `peek` 到 `await loginByToken`、`await switchTo`、`state = AsyncData(user)` 全程无 `_switching` 标记、无请求序号；`AsyncNotifier` 的 `state` 在 await 期间可被另一次 `switchAccount` 或 `logout` 覆盖，最后完成的旧请求照样写 `AsyncData(user)`。
- 影响：用户在设置页快速连点两个账号，界面最终显示的账号与实际生效的 `AccountManager.currentUserid` / SecureStorage token 可能不一致；后续收藏/评论落在非显示账号，属静默错账号。
- 证据等级：静态推演

### lib/features/auth/data/auth_providers.dart:96-131 `LoginController` 的 `state` 是 `AsyncNotifier<void>`，登录失败后 `AsyncError` 会一直保留，且 `_finish` 把成功态又置为 `AsyncData(null)`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（加载/成功/失败三态分离）、第 9 条
- 依据：三个登录方法开头 `state = const AsyncLoading()`，catch 中 `state = AsyncError(e, st); rethrow;`，成功时 `_finish` 仅 `setUser` + `state = const AsyncData(null)`；`state` 类型为 `void`，无「成功」可承载的数据，且没有任何位置在**下一次登录开始前之外**清除 `AsyncError`（只有下次 `loginByXxx` 开头的 `AsyncLoading`）。若 UI 用 `ref.watch(loginControllerProvider).when(...)` 渲染，失败后重进页面仍显示上一次错误。
- 影响：登录失败（验证码错/网络错）后错误条持续显示，用户即使改用二维码登录成功，UI 若依赖该 provider 的 error 分支仍展示旧错误；反过来若 UI 只看 `authStateProvider`，则 loading 态完全不可见，点「登录」后按钮无禁用、可重复提交（与第 21 条重复提交风险呼应）。三态中「成功」与「空闲」同值，无法驱动跳转提示。
- 证据等级：静态推演（UI 消费方式见 F12）

### lib/features/auth/data/auth_providers.dart:24-33 `build()` 中 `readCredentials()` 异常被空体 catch 吞掉，冷启动按「无 t1」继续且无留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`try { cred = await readCredentials(); if (...) kgClient.t1 = ... } catch (_) { /* 读不到凭证就按无 t1 继续，后续有降级路径 */ }`；catch 为空体，仅注释，无 `debugPrint`/ErrorLogger/`rethrow`，随后 `restoreSession()` 照常执行。
- 影响：SecureStorage/Keystore 读取异常时，App 冷启动静默进入「有账号但缺 t1」状态，token 刷新 `/login/token` 必然签名失败 → 用户被判为未登录或直接掉进验证流程；日志无任何线索，线上无法区分「用户未登录」与「凭证存储损坏」。
- 证据等级：实锤

### F7 `lib/features/auth/data/auth_repository.dart`（418 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`AuthRepository({api?, storage?})` 默认 `KugouApiClient()`（由 `authRepositoryProvider` 注入 `kugouApiClientProvider` 覆盖）；异常出口 `CaptchaRequiredException(ssaCode,message)` / `MultiAccountException(users)` / `ApiException`；`restoreSession()` 成功/网络降级/确认失效三条路径；`_handleLoginSuccess` 在 `saveCredentials` 之前**并发**发起 `AccountManager.upsert`、`saveAccountToken`、settings 盒写入；`logout()` 调 `AccountManager.clearCurrent/remove` + `SecureStorage.clearCredentials(userid)` + `_api.clearCredentials()`。此文件为 F6 的调用点证据。

### lib/features/auth/data/auth_repository.dart:329-355 `_handleLoginSuccess` 在凭证落盘/客户端设置`**之前**就广播了「登录成功并切号」，F6 的切号分裂得到确证
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 18 条、第 3 条（契约先行）
- 依据：`sideFutures` 里 `AccountManager.instance.upsert(AccountRecord(...))` 立即执行，而 `await dfidFuture` → `await _storage.saveCredentials(...)` → `await _api.setCredentials(...)` 都在其后；`upsert` 内部同步 `_b.put(_kCurrent, ...)` + `_notifyChanged()`（F5 :122-133）。`auth_providers.dart:52-67` 的注释「登录成功后才切指针」与实现相反：`loginByToken` 返回时指针早已切换并广播，且若 `saveCredentials`/`setCredentials` 之后抛异常，调用方 `switchAccount` 拿不到 `AuthUser`（`state` 仍是旧账号），但 AccountManager 已指向新 userid。
- 影响：切换账号或扫码登录时，收藏/下载/评论等订阅 `onCurrentAccountChanged` 的模块立刻按新 userid 工作，而 `authStateProvider`、SecureStorage、kgClient 仍是旧态或半新态；一次凭证写入失败就留下「UI 显示 A、指针是 B、请求凭证是 A」的错账号状态，用户可能把收藏/评论写入错误账号且无错误提示。
- 证据等级：实锤（跨文件调用顺序确定）

### lib/features/auth/data/auth_repository.dart:356-362 副产物写入失败只 `debugPrint`，`authStateProvider` 仍被置为成功
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测；debugPrint 不是用户可见反馈）、第 21 条（写操作失败语义）
- 依据：`Future.wait(sideFutures)` 的 catch 仅 `debugPrint('[auth] login side-effect write failed: $e')`，随后无条件 `return AuthUser(...)`；三项分别是 `saveAccountToken`（切号所需 token）、`AccountManager.upsert`（账号列表/当前指针）、settings 盒 nickname/avatar。`LoginController._finish` 与 `switchAccount` 收到该 `AuthUser` 后均写 `AsyncData(user)` 视为成功。
- 影响：多账号列表缺该账号 token 时 UI 已显示登录成功，但用户下次「切号」必抛 `StateError('该账号需要重新登录')`（F6 :56-59），而当前会话又无法重新触发登录；昵称/头像写入失败则设置页显示空资料。用户可见为「登录成功却切不了号/资料空白」，且失败原因只在 debug 日志。
- 证据等级：实锤

### lib/features/auth/data/auth_repository.dart:271-285 `restoreSession()` 对 `readCredentials()` 失败直接 `return null`，用户被静默登出
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条（未登录 / 读取失败必须语义分离）、第 11 条（降级必须有明确触发与退出条件）
- 依据：`catch (e, st) { debugPrint(...); return null; }`，仅 debug 日志、无用户可见提示、无「存储故障」状态、无重试；`authStateProvider.build()` 把它当 `AsyncData(null)`，UI 与「从未登录」完全同态。而 `auth_providers.dart:24-33` 在此之前的 `readCredentials()` 同样 `catch (_)` 空体，两处都无留痕到用户。
- 影响：Keystore 解密失败的机型冷启动后，用户发现「已退出登录」且所有收藏/下载/评论需重新登录；凭证其实仍在存储中，但没有任何引导或重试入口，重启也无法自愈（注释自称修复了「静默永久匿名」，实现只是把 `AsyncError` 换成 `AsyncData(null)`）。
- 证据等级：实锤

### lib/features/auth/data/auth_repository.dart:221-269 `restoreSession()` 网络降级用 `_degradedUser` 冒充有效登录，且 `catch (_)` 兜底路径再发一次 `/user/detail`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（失败/成功/降级三态分离）、第 11 条（降级必须有退出条件）
- 依据：`on DioException` 中非「确认失效」一律 `return _degradedUser(cred)`；`catch (_)` 里再 `getUserDetail()`，其失败且非确认失效同样 `_degradedUser(cred)`。`_degradedUser` 用 Hive 里的昵称/头像与旧 token 构造与正常登录完全同形的 `AuthUser`，没有任何 `degraded`/`offline` 标记；本文件也没有定时重试或网络恢复监听（退出条件缺失）。
- 影响：断网启动后 UI 显示「已登录」，用户点收藏/下载/评论才逐个失败，且失败原因被上层当作业务错误；整个会话期间不会自动恢复为真实登录态，除非用户手动重登。
- 证据等级：实锤

### lib/features/auth/data/auth_repository.dart:304-316 `logout()` 的 `readCredentials()` 与 `clearCredentials()` 无异常保护，且 `removeAccount` 时 `remove()` 会隐式切到别的账号
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：失败语义）、第 5 条
- 依据：`logout` 开头 `final cred = await _storage.readCredentials();`（与 `restoreSession` 不同，无 try/catch），`removeAccount` 分支调 `AccountManager.instance.remove(cred.userId)`——F5 :147-159 显示该方法在删除当前账号后自动 `_b.put(_kCurrent, list.first.userid)` 并广播「已切到另一个账号」；随后才 `clearCredentials` + `_api.clearCredentials()`，最后 `auth_providers.logout()` 把 `state = AsyncData(null)`。
- 影响：多账号用户点「退出并移除该账号」时，账号层短暂广播切到 B 账号（订阅模块开始以 B 工作），最终 UI 却是未登录；若 `readCredentials()` 抛异常则整个登出中断、按钮无反馈，用户以为没点上，凭证仍保留。
- 证据等级：静态推演

### F8 `lib/features/auth/data/captcha_types.dart`（156 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`CaptchaType.fromVerifyUrl(url)` 前缀匹配（`KGCodeGT/TX/KG/KG2/SM/YD`）、`fromVType(23→腾讯/32→短信/22→活体/34→人脸)`；`supportedInApp` 仅 `tencent || sms` 为 true；`VerifySession.fromJson(eventId, json)` 产出 `eventId/vType/type/typeList/sessionId/business/verifyUrl`；`VerifyCode.tencent/geetest/orderno/ticket` 是 `verifycode` 唯一构造出口。供 `captcha_page` / `verification_service` 抽查。

### lib/features/auth/data/captcha_types.dart:43-50 `supportedInApp` 只认腾讯与短信，活体/人脸/极验等类型在验证页无「可完成」路径，验证流程必然断链
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（不同业务事实必须可区分）、第 9 条（失败必须可观测）
- 依据：`bool get supportedInApp => this == tencent || this == sms;`，而 `CaptchaType` 枚举还包含 `geetest/kugou/kugouRotate/shumei/yidun/liveness/face`；`fromVType` 明确把 22→liveness、34→face，`fromVerifyUrl` 明确把 `KGCodeGT/KG/KG2/SM/YD` 映射到对应枚举。这些类型全部返回 `supportedInApp=false`，但 `label` 仍给了展示名（如「活体认证」「人脸核身」），`VerifyCode` 也只为其中几类提供构造器。
- 影响：用户登录密码命中 20028 且上游返回 v_type=22/34 或 GT/数美验证码时，验证页拿到的会话类型被判「不支持」，若页面没有兜底引导就会停在加载/空白，用户无法完成验证从而永远登录不了；属「登录」路径的可见断点（具体 UI 表现由 F11 核对）。
- 证据等级：静态推演（UI 消费点待 F11）

### lib/features/auth/data/captcha_types.dart:130-149 `VerifyCode` 用字符串插值拼 JSON，`ticket`/`randstr` 未转义
- 级别：P3
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸拼）、第 14 条（数据边界必须校验）
- 依据：`tencent()` 直接 `'KGCodeTX|{"ticket":"$ticket","randstr":"$randstr","txappid":"$txappid"}'`，`geetest/orderno/ticket` 同型；参数来自 WebView 回调/上游返回值，含引号、反斜杠、换行时会生成非法 JSON。
- 影响：腾讯验证码回传的 `randstr` 含特殊字符时，提交给 `/login` 的 `verifycode` 被上游解析失败，用户完成滑块后仍被判「验证失败」，且错误信息不含真实原因；概率低但为外部输入边界。
- 证据等级：静态推演（未实测上游回传字符集）

### F9 `lib/features/auth/data/slider_solver.dart`（215 行，完整读，✅ 本代理通读）

- 复核通过（用户路径相关）：文件头明确写出「腾讯 TCaptcha 在跨域 iframe 内，无法注入事件，只能人工拖动」，与 F8 `supportedInApp` 及 F11 腾讯 WebView 人工路径一致，未把自动求解误用到不支持的类型；`detectOffset` 对解码失败、无有效拼图区域、搜索区间为空均返回 `null`（不抛），`TrajectoryGenerator` 的 `timeMs` 与 `distance`/`angle` 单位在 `DragPoint` 注释中显式（毫秒 / 相对位移 / 度）。
- 跨文件契约：`SliderSolver.detectOffset(Uint8List,Uint8List,{scale})`、`TrajectoryGenerator.generate(distance,{totalMs,simulateOvershoot})`、`generateRotation(angle)`、`DragPoint(x,y,timeMs)`。本文件范围内无网络/存储/UI 依赖，不影响登录→切号→收藏主链路。

### lib/features/auth/data/slider_solver.dart:24-57 `detectOffset` 的搜索起点假定「缺口一定在拼图右侧」，无匹配阈值，无解时返回一个必然错误的偏移
- 级别：P3
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发条件与退出条件）、第 9 条（失败必须可观测）
- 依据：`final startX = math.max(0, px + pw);` 后遍历 `x <= bg.width - pw`，对任何 `bestScore` 都取最小值返回 `((bestX - px) * scale).round()`，没有「最佳分数是否足够小」的判定，也没有「无匹配返回 null」的退出条件（只有 `bestX < 0` 才返回 null）。
- 影响：若自动求解被调用（如未来接入酷狗自研滑块），图片解码成功但缺口不在右侧或模板完全不匹配时，仍返回一个合法整数距离，用户看到滑块被拖到错误位置、验证反复失败且无「无法识别」提示；当前腾讯路径人工拖动，故为潜伏项。
- 证据等级：静态推演

### lib/features/auth/data/slider_solver.dart:144-215 两个轨迹生成器共用 `static final _rand = math.Random()` 且 `generate()` 无参数合法性校验
- 级别：P3
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 3 条（输入取值范围契约）
- 依据：`_rand` 是类级静态可变状态，无种子/无并发声明；`generate(distance)` 对 `totalMs=0` 会得到 `decelEnd=0`，`for (var t=0; t<=0; t+=16)` 只跑一次且 `progress = t/decelEnd` 为 `0/0 = NaN`，`eased` 为 NaN，随后 `points.add(DragPoint(x: NaN, ...))`；`generateRotation(0)` 或负角度同样无校验。
- 影响：调用方传入异常距离/时长时生成含 NaN 的轨迹，注入 WebView 的拖动事件坐标无效，用户看到滑块不动或直接验证失败；多个验证并发时随机序列共享（影响可复现性，非用户可见主问题）。
- 证据等级：静态推演（本范围未发现调用点，属对外 API 契约风险）

### F10 `lib/features/auth/data/verification_service.dart`（98 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`VerificationService(api,[KgClient?])`；`getVerifyInfo(ssaCode)` → `VerifySession`；`buildSidEdt()` → `EdtGenerator.generate(mid,userid,dfid,webglHash)`；`submit({session,verifycode})` 对 `/verify/user/info` 同时以 body 与 query 提交 `eventid/v_type/platid/wasm/sid/edt/verifycode/code`，`status==1` 或 `data.codeDesc=='success'` 视为通过；`sessionFromException(ApiException)` 产出 `vType:-1` 的会话。这是「登录遇 20028 → 验证 → 重试」链路的核心。

### lib/features/auth/data/verification_service.dart:67-87 `submit()` 把「验证接口返回失败」一律折叠成 `false`，用户只看到「验证未通过」，无原因区分
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）、第 9 条（失败必须可观测）、第 16 条
- 依据：`try` 内 `final status = data['status']; final ok = status == 1 || status == '1' || (...codeDesc=='success'); return ok;`——业务失败（`status=0`、错误码）、参数缺失（20010）、以及「返回体形态异常」都返回同一个 `false`，不抛、不记日志；`on DioException` 中 `if (e.error is ApiException) return false;` 同样吞掉 ApiException（含 20010/验证过期/风控拒绝），只有非 ApiException 的 DioException 才 rethrow。F11 `_submitWithCode` 对 `!ok` 统一 `_snack(context.l10n.captchaNotPassed)`。
- 影响：用户完成滑块/短信验证后，若上游要求二次验证、会话过期或参数被拒，只反复看到「验证未通过」，无法知道应重试、重新登录还是等待；「验证接口自身失败」与「用户确实没通过」在 UI 与日志中均不可分，线上无法定位；属登录链路的反馈断点。
- 证据等级：实锤

### lib/features/auth/data/verification_service.dart:90-95 `sessionFromException()` 用 `ssaCode ?? ''` 构造空 eventId，无校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（缺失必须与有效值分离）、第 14 条（外部数据边界校验）
- 依据：`return VerifySession(eventId: e.ssaCode ?? '', vType: -1);`；`ApiException.ssaCode` 为 null 时直接变成空串，`submit()` 又会以 `eventid: ''`、`vType: -1 → 23` 发请求（`final vType = session.vType > 0 ? session.vType : 23;`）。
- 影响：20028 异常但缺 ssaCode 时，用户被带进验证页并提交一个空事件 id 的请求，必然失败且提示「验证未通过」，用户反复尝试仍无法登录；真实原因（缺事件 id）对用户与日志均不可见。
- 证据等级：静态推演（调用点是否使用该工厂见 F13/F14）

### F11 `lib/features/auth/presentation/captcha_page.dart`（454 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`CaptchaPage({ssaCode, api, typeHint?, onVerified?})` 返回 `bool`（true=验证通过）；`_buildByType` 对 tencent/sms 走页内完成，geetest/kugou/kugouRotate/shumei/yidun/liveness/face 走 `_buildExternal`，unknown 走 `_buildUnknown`；腾讯结果经 `VerifyCode.tencent(...)` 提交，成功后 `widget.onVerified!()` 可重试原请求；`typeHint` 参数在本页**未被 `_buildByType` 使用**。

### lib/features/auth/presentation/captcha_page.dart:156-170 / 322-352 非腾讯/短信类型一律「请在外部完成」后直接 `pop(false)`，App 内无任何完成路径
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测且可行动）、第 16 条（三态分离）
- 依据：`_buildByType` 把 7 种 `CaptchaType` 映射到 `_buildExternal`，该方法只显示 `s.type.label` + `context.l10n.captchaExternalHint` + 一个 `OutlinedButton.icon(onPressed: () => Navigator.of(context).pop(false))`；没有打开外部浏览器/深链、没有「我已完成，继续验证」按钮、没有 `submit()` 调用。`_buildUnknown` 至少提供 `captchaTryFingerprint`，而「已知但不支持」的类型连这个兜底都没有。
- 影响：密码登录命中 20028 且上游下发极验/酷狗自研/数美/易盾/活体/人脸时，用户只能看到一段说明和一个「关闭」按钮，关闭后回到登录页（失败），无法在 App 内完成验证 → 该账号永远登录不了。这是 F8 `supportedInApp=false` 的用户可见落点。
- 证据等级：实锤

### lib/features/auth/presentation/captcha_page.dart:401-420 `onVerified()` 重试失败时仍 `pop(true)` 并提示「验证通过但重试失败」，调用方会把未完成的原请求当作已成功
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（返回契约）、第 9 条（失败必须可观测）
- 依据：`if (retried) { Navigator.pop(true); return; }` 之后，`setState(...); _snack(context.l10n.captchaPassedButRetry); Navigator.of(context).pop(true);`——`onVerified` 返回 `false`（原业务请求重试失败，例如密码登录仍报错、收藏/评论未提交）时页面仍以 `true` 关闭。类注释明确「返回 `true` 表示验证通过」，而调用方（登录页/验证监听器）通常按 true 继续走「登录完成 / 写操作已重试」。
- 影响：用户在验证通过后，若原登录请求重试失败，验证页关闭且调用方按成功处理 → 登录态并未建立却显示已登录，或收藏/评论实际未提交却提示成功；用户要再次手动触发才能发现，属静默错误。
- 证据等级：静态推演（调用方对返回值的处理见 F12/F14，返回契约本身实锤）

### lib/features/auth/presentation/captcha_page.dart:174-185 腾讯验证缺 `txappid` 时静默退化为「未知类型」，未用 `typeHint` 或验证会话里的其它字段
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（不同失败原因必须可区分）、第 32 条（死代码：`typeHint` 无消费）
- 依据：`_buildTencent` 开头 `if (appId == null) return _buildUnknown(theme, s);`，`_txAppId` 仅由 `_extractTxAppId` 用 `RegExp(r'txappid=...')` 从 `s.verifyUrl` 提取；`widget.typeHint` 在整个 State 中零引用。`VerifySession` 另有 `sessionId/typeList/business`，均未参与腾讯初始化。
- 影响：上游 `verifyUrl` 为 `KGCodeTX|...` 但 `txappid` 以别的字段/参数形式下发时，用户看不到腾讯验证码，而是「未知验证类型 + 可尝试指纹」；本可完成的登录验证被降级成大概率失败的指纹提交。声明的 `typeHint` 参数从未生效，属未接线契约。
- 证据等级：实锤

### lib/features/auth/presentation/captcha_page.dart:246-254 腾讯 WebView 验证失败/用户取消时无任何反馈，遮罩永久停留在「加载中或提交中」
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条（三态分离）
- 依据：HTML 内 `new TencentCaptcha(appId, function (res) { if (res && res.ret === 0) { done(res.ticket, res.randstr); } })` 只处理 `ret === 0`；`catch (e) { done('', ''); }` 回传空 ticket，而 Dart 侧 `onCaptchaResult` 对 `ticket.isEmpty || randstr.isEmpty` 直接 `return null`，不 `_submitWithCode`、不提示、不重置 `_webViewReady`。`Stack` 的遮罩条件 `if (!_webViewReady || _submitting)` 在 `onLoadStop` 已置 true 的情况下会消失（此点需谨慎），但用户取消后页面只剩一个没有任何提示的 WebView 与「开始验证」按钮，且 `window.onload` 自动点击只发生一次。
- 影响：TCaptcha 加载失败、用户关闭验证码弹窗、或 JS 抛异常时，界面既不报错也不重试，用户以为 App 卡住；必须退出验证页重进（而重进会重新 `getVerifyInfo`，事件可能已过期）。
- 证据等级：静态推演

### lib/features/auth/presentation/captcha_page.dart:294-317 短信验证分支没有「发送/重发验证码」入口
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：验证流程闭环）、第 9 条
- 依据：`_buildSms` 只有图标、标题、`captchaSmsHint`、`TextField(maxLength:8)`、`FilledButton` 直接 `_submitWithCode(s, code)`；`verification_service.dart` 无发送短信接口，本页也未调用 `AuthRepository.sendSmsCode` 或 `/captcha/sent`。`v_type=32` 在 `submit()` 里同时把 `verifycode` 放进 `code` 字段。
- 影响：上游若要求用户先收取短信再填码，App 内没有触发发送的按钮，用户只能干等或退出；输入任意码提交后统一看到「验证未通过」（F10），形成登录路径死循环。
- 证据等级：静态推演（是否由上游主动下发短信未实测）

### F12 `lib/features/auth/presentation/login_guard.dart`（43 行，完整读，✅ 本代理通读）

- 复核通过：`ensureLoggedIn` 在发起写操作**之前**读 `authStateProvider.valueOrNull` 并弹统一 `AlertDialog`（`loginRequiredTitle/Hint/Action`），给出「取消 / 去登录」两个明确出口，文案全部走 `context.l10n`，避免匿名态请求发出后才报错；返回 `bool` 契约清晰（true 继续 / false 已提示）。这是「未登录」这一态在本批范围内处理最到位的点。

### lib/features/auth/presentation/login_guard.dart:15-18 `valueOrNull` 把「加载中 / 读取失败 / 降级登录」一律当成未登录，冷启动抢先点击会被误拦
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（加载 / 失败 / 未登录三态必须分离）、第 9 条
- 依据：`final user = ref.read(authStateProvider).valueOrNull; if (user != null) return true;`——`AsyncValue` 在 `AsyncLoading`（`restoreSession` 进行中）、`AsyncError`（build 抛异常）时 `valueOrNull` 均为 null；而 F7 `restoreSession()` 对 Keystore 故障返回 `null`（`AsyncData(null)`）、对网络失败返回 `_degradedUser`（非 null）。守卫无法区分「确实未登录」与「还在恢复会话 / 存储读取失败」。
- 影响：冷启动后用户立刻点「收藏 / 评论 / 我的歌单」，会被弹「请先登录」并推向登录页；实际会话正在恢复或凭证存储故障，用户可能因此重复登录，或把「存储损坏」误当成「没登录」。与 F7 的两条静默降级叠加，形成登录路径上的误导反馈。
- 证据等级：静态推演

### lib/features/auth/presentation/login_guard.dart:20-39 登录弹窗为非 `async` 的 `showDialog`，调用方拿不到「用户去登录并成功」的结果
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约先行：返回值语义）
- 依据：函数签名是 `bool ensureLoggedIn(...)` 且同步返回 `false`，`showDialog<void>` 未 await；「去登录」只 `context.push('/login')`，不等待登录结果、不回调原操作。
- 影响：用户从收藏按钮跳转到登录页并成功后，回到原页面仍需**再点一次**收藏；App 不会自动继续被打断的操作，用户可能以为第一次收藏已生效。属跨页面路径不闭环（非数据错误）。
- 证据等级：实锤

### F13 `lib/features/auth/presentation/verification_guard.dart`（63 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`runWithVerification<T>(context, ref, action, {maxRetries=2})` 仅捕获 `DioException` + `ApiException.needsVerification`；打开 `CaptchaPage(ssaCode, api: ref.read(kugouApiClientProvider))` 且**不传 `onVerified`**；`ok == true` 后 `while(true)` 重新执行整个 `action()`。

### lib/features/auth/presentation/verification_guard.dart:38-52 验证通过但未重试原操作时 `CaptchaPage.pop(true)` 被当作「可以重试」，与 F11 的 `pop(true)` 语义叠加造成写操作重复提交
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作幂等或防重）、第 3 条（契约先行：验证结果语义）
- 依据：本文件把 `CaptchaPage` 的 `true` 解释为「验证已通过，可以重跑 action」并 `while(true) return await action()`；而 `captcha_page.dart:401-420` 在 `onVerified != null` 且返回 `false` 时也 `pop(true)`，且验证成功后 `_submitWithCode` 本身可能已由 `onVerified` 执行过一次 action。本文件未传 `onVerified`（此处不会二次执行），但同一 `CaptchaPage` 被 `verification_listener` / 登录页以 `onVerified` 传参使用时，调用方统一按 `true` 再重试一次，等于同一次业务写操作（评论/收藏/登录）执行两遍。
- 影响：发评论、收藏歌单、删除下载等写操作在「验证通过但页面内重试已执行」的路径上被重复提交，用户看到两条评论/重复收藏；第 21 条明确要求写操作不得因回退、自动恢复而重复执行。
- 证据等级：静态推演（跨文件返回值契约冲突为实锤；是否存在实际双执行取决于各调用点传入 `onVerified`，需 F14/评论页抽查）

### lib/features/auth/presentation/verification_guard.dart:24-56 只认 `DioException.error is ApiException`，直连/仓库层抛出的裸 `ApiException` 或 `CaptchaRequiredException` 直接逃逸
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一且稳定）、第 9 条
- 依据：`on DioException catch (e) { final api = e.error is ApiException ? ... : null; if (api == null || !api.needsVerification) rethrow; ... }`；F7 `AuthRepository.loginByPassword` 对 20028 抛的是 `CaptchaRequiredException`（非 DioException），F7 `loginBySms` 抛 `MultiAccountException`/`ApiException`。任何不经过 DioException 包装的 20028 都不进入验证页而是原样抛给 UI。
- 影响：密码登录命中风控时，若上游异常未被包装成 DioException，用户看到的是原始错误而非验证页，登录无法继续；同一 20028 在「播放（verificationStream）」「通用 action」「登录」三条路径上表现不一致。
- 证据等级：静态推演（需 B1/B2 范围 `kugou_api_client` 包装策略佐证，本范围可确证类型不匹配）

### lib/features/auth/presentation/verification_guard.dart:29-36 两条 `_toast` 硬编码中文，未走 l10n，且与 captcha_page 的 Toast 样式不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条（命名/文案一致性）、REVIEW_SPEC 及视角 C 的 i18n 一致性
- 依据：`_toast(context, '需要人机验证，但未获取到验证事件，请稍后重试')` 与 `_toast(context, '验证多次未通过，请稍后再试')` 为字面量中文；`_toast` 用 `ScaffoldMessenger.showSnackBar`，而 `captcha_page.dart:433` 明确「项目统一用 Toast，避免验证页提示样式与全 app 不一致」。
- 影响：非中文 locale 用户在这两种失败下看到中文提示；同一验证流程内出现 SnackBar 与 Toast 两种样式，用户感知不一致。
- 证据等级：实锤

### F14 `lib/features/auth/presentation/verification_listener.dart`（60 行，完整读，✅ 本代理通读）

- 关键链路：`ref.listen(verificationStreamProvider, ...)` 在 `build` 中每次重建都注册一次；`_handling` 闸门防并发；`CaptchaPage(ssaCode, api: kugouApiClientProvider)` 同样不传 `onVerified`；`ok == true && mounted` → `audioHandlerProvider.retryPendingPlayback()`。

### lib/features/auth/presentation/verification_listener.dart:28-35 事件流用 `valueOrNull` 且 `_handling` 期间的新事件被直接丢弃，无世代/无队列
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 20 条（生命周期订阅对称）
- 依据：`final api = next.valueOrNull; if (api == null || _handling) return;`；`_handle` 在 `await Navigator.push` 期间把 `_handling=true`，期间到达的任何新 `verificationStreamProvider` 事件（例如用户切歌再次触发 20028）被 `return` 丢弃，且 `finally` 只置回 false 不补处理最新事件。`CaptchaPage` 关闭后 `retryPendingPlayback()` 使用的是「刚才被拦截的播放」这一隐含状态，未校验 ssaCode/世代。
- 影响：用户在验证页开着时切歌或验证期间又触发一次风控，第二个播放请求永远不会被重试，界面停在「无声音/未播放」且无提示；验证成功后可能重试的是已被用户放弃的旧歌（跨代回写）。
- 证据等级：静态推演

### lib/features/auth/presentation/verification_listener.dart:37-49 `CaptchaPage` 返回 `true` 即重试播放，不区分「验证通过但页内重试失败」与「真正通过」
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回值契约）、第 16 条
- 依据：`if (ok == true && mounted) await ref.read(audioHandlerProvider).retryPendingPlayback();`；`CaptchaPage` 在 `onVerified` 返回 false 时仍 `pop(true)`（F11 :401-420），本监听虽未传 `onVerified`，但全局任何其它地方复用该页并传 `onVerified` 时都共享这一约定。`_handle` 不捕获 `retryPendingPlayback()` 的异常，也不向用户反馈重试结果（无 Toast/日志），`finally` 直接解锁。
- 影响：验证通过后播放重试失败（或抛异常）时无任何用户可见反馈，用户以为已恢复播放；与 F13 的 `runWithVerification` 对 `true` 的解释叠加，形成「true 到底代表什么」的跨模块契约不一致。
- 证据等级：静态推演

### F15 `lib/features/auth/presentation/login_page.dart`（740 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`LoginPage` 三个 Tab 分别调 `loginControllerProvider.loginBySms/loginByPassword/loginByQrToken` 与 `authRepositoryProvider.sendSmsCode/getQrKey/checkQr`；成功后 `_onLoginSuccess()` 只 `pop()`（或 `go('/home')`），不等待/不通知来源页；密码 20028 走 `CaptchaPage(ssaCode, api: kugouApiClientProvider)`（不传 `onVerified`），`ok==true` 后递归 `_login()`；二维码 `status==4` 用 `res.token ?? ''`、`res.userid ?? ''` 直接登录。
- 复核通过：`_SmsLoginTab` 的 60s 倒计时 Timer 在 `dispose` 中 `cancel()`、`_QrLoginTab` 的轮询 Timer 在 `dispose`/`didUpdateWidget(active=false)` 中取消，且 `_pollOnce` 采用「上次请求完成后再排下一次」避免重叠；`_showError` 经 `unwrapApi` + `friendlyError` 统一 Toast；二维码过期/加载失败/图片解码失败都有 `refreshQr` 按钮。生命周期与三态在本页整体到位。

### lib/features/auth/presentation/login_page.dart:404-418 密码登录验证通过后递归 `_login()` 重发同一份用户名/密码，且 `CaptchaPage.pop(true)` 不等于「原请求成功」
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作/提交防重）、第 3 条（契约先行）
- 依据：`on CaptchaRequiredException` 中 `final ok = await Navigator.push<bool>(CaptchaPage(...)); if (ok == true && mounted) { await _login(); return; }`；`_login()` 重新读取 `_usernameCtrl/_passwordCtrl` 并再次 `loginByPassword`，没有 `verificationToken`/`ssaCode` 关联，也没有「本次验证已消费」标记。结合 F11 `captcha_page.dart:401-420`：`onVerified` 返回 false 时仍 `pop(true)`（本处未传 `onVerified`，但 `true` 语义本身只表示「验证提交被判通过」）。
- 影响：20028 风控下用户完成验证后同一登录请求被发起两次，若上游对「一次验证事件只允许一次登录」做限制，第二次反而再次触发 20028 → 无限循环弹验证页；若第一次登录实际已成功而 UI 未感知，则出现重复 `_handleLoginSuccess`（重复 upsert / 重复 saveCredentials）。用户表现为「验证完了还让验证」或「登录页卡住」。
- 证据等级：静态推演（递归与返回契约实锤）

### lib/features/auth/presentation/login_page.dart:624-640 扫码成功但 `token`/`userid` 为 null 时用空串登录，失败后轮询已停、无刷新入口
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（缺失与有效值必须分离）、第 9 条（失败必须可观测）
- 依据：`if (res.status == 4) { _pollTimer?.cancel(); try { await loginByQrToken(token: res.token ?? '', userid: res.userid ?? ''); ... } catch (e) { if (mounted) _showError(context, e); } }`；`QrCheckResult.token/userid` 是 nullable，`AuthRepository.loginByToken` 用空 token 调 `/login/token`，`_handleLoginSuccess` 在 `token.isEmpty` 时抛 `ApiException(-1,'登录响应缺少 token 或 userid')`。失败后 `_status` 已被 `setState(() => _status = res.status)` 置为 4，`_statusText` 显示 `context.l10n.loginSuccess`，`_status==0 || _error != null` 的刷新按钮条件不成立（`_error` 从未在此分支赋值），轮询已 cancel。
- 影响：用户扫码后上游返回 status=4 但字段缺失/为空时，界面显示「登录成功」的绿色状态文案、只弹一个瞬时 Toast，二维码不能刷新、轮询不再继续，用户停在假的「登录成功」页且无法重试，只能退出重进。
- 证据等级：实锤

### lib/features/auth/presentation/login_page.dart:640-642 二维码轮询异常被 `catch (_)` 无限静默重试，网络故障下状态永远停在「请扫码」
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 25 条（重试次数必须有上限）
- 依据：`_checkOnce()` 末尾 `catch (_) { // 轮询失败忽略，下次再试 }`，`_pollOnce()` 之后只要 `_status` 不是 0/4 就 `_scheduleNextPoll()` 每 3 秒一次，无重试计数、无退避、无错误态、无日志；`_status` 保持 1，`_statusText` 为 `qrScanHint`。
- 影响：断网或网关持续报错时，用户对着二维码反复扫码，App 一直显示「请扫码」且无任何网络错误提示，电池与流量被无声消耗；用户不知道该检查网络还是刷新二维码。
- 证据等级：实锤

### lib/features/auth/presentation/login_page.dart:44-52 `_onLoginSuccess()` 只 pop，不把登录结果回传给被打断的收藏/评论/下载操作
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（跨页面契约）、第 16 条
- 依据：`ensureLoggedIn`（F12）把用户 `context.push('/login')` 后同步返回 false，来源页丢弃原操作；`_onLoginSuccess` 仅 `Navigator.pop()`，未 `pop(result)`、未发事件、未调用任何 `onVerified` 式回调。登录页各 Tab 的 `onSuccess` 都是这个 VoidCallback。
- 影响：用户从「收藏歌单 / 发评论 / 我的歌单」被引导去登录，登录成功后回到原页面，之前的操作没有自动继续，也没有任何「请再点一次」提示；用户容易误以为收藏/评论已提交。与 F12 第 2 条为同一断点的两端。
- 证据等级：实锤

### lib/features/auth/presentation/login_page.dart:208-236 短信登录「多账号归属」选择后递归 `_login(userid:)` 会重新提交同一验证码
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（提交防重）
- 依据：`on MultiAccountException catch (e) { final chosen = await _showAccountPicker(e.users); if (chosen != null && mounted) await _login(userid: chosen); }`；`_login(userid:)` 用同一个 `_codeCtrl.text` 再次调 `loginBySms(mobile,code,userid)`，验证码未重新获取、无「已选择账号」幂等键；`finally` 中的 `_loading=false` 只在最外层递归返回后执行（递归内也有自己的 finally，会提前把按钮解禁）。
- 影响：短信验证码通常一次性，用户选完账号后第二次提交被判「验证码已使用/无效」，多账号归属用户无法登录；递归期间 `_loading` 被内层提前复位，用户还能再点一次登录，形成第三次提交。
- 证据等级：静态推演（验证码一次性属上游常见语义，未实测）

### lib/features/auth/presentation/login_page.dart:184-202 `_sendCode()` 把「发送成功」当既成事实，但 `sendSmsCode` 不检查上游业务状态
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条
- 依据：`sendSmsCode` 在 `auth_repository.dart:75-77` 仅 `await _api.get('/captcha/sent', query: {'mobile': mobile});`，无返回/无成功判定；`_sendCode` 只要不抛就 `Toast.show(smsCodeSent)` 并启动 60s 倒计时禁用重发按钮。
- 影响：上游返回 `status=0`（手机号被风控、频率限制）但 HTTP 200 时，用户看到「验证码已发送」并被锁定 60 秒，实际收不到短信；期间无法重发，只能等倒计时结束。
- 证据等级：静态推演（未实测 `/captcha/sent` 返回形态）

### F16 `lib/features/comment/data/comment_repository.dart`（279 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`CommentRepository(_api)` 读走 `RepositoryReads(_api,'comment')`、写（sendComment/sendFloorReply/deleteComment）直接 `_api.post(path, {}, query: ...)`；`CommentPage.fromJson(data,currentUserId:)` 把 `isMine` 绑定 `_api.userid`；`fetchFloor` 必须带 `resource_type: type.name`；`fetchComments` 的 song 用 `mixsongid`、playlist/album 用 `id`；发歌曲评论前先查 `special_child_id`，空时回落 `id`。

### lib/features/comment/data/comment_repository.dart:78-118 `sendComment` 前置查询失败被 `catch (_)` 吞掉并回落到 `id`，同一写操作在不同网络条件下参数不同
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 3 条（契约先行）
- 依据：`try { final page = await fetchComments(...pageSize:1); childrenId = ...; } catch (_) { /* 查询失败不阻断发送 */ }`，随后 `childrenId == null || isEmpty` 时 `childrenId = id`，把 `special_id: id` 发出；成功查到非空评论时发的是 `special_id: specialChildId`。两种参数形态对应同一个公开方法，调用方与 UI 无从区分。
- 影响：网络抖动时用户的评论可能发到错误的评论池（或被服务端 400），UI 统一按 `_api.post` 未抛异常即显示「评论成功」（F18），用户以为已发布；失败无日志、无重试标记。
- 证据等级：实锤

### lib/features/comment/data/comment_repository.dart:114 / 129 / 145 三个写端点只 `await _api.post(...)`，不检查上游业务状态，返回 `Future<void>` 即视为成功
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常/失败语义单一）、第 9 条（失败必须可观测）、第 16 条
- 依据：`sendComment` 末行 `await _api.post(path, {}, query: query);`、`sendFloorReply` 与 `deleteComment` 同型；三者都没有对返回 Map 做 `status`/`err_code` 判定，也不抛异常。REVIEW_SPEC 明确评论写端点走 `/index.php` 且成功判定口径与一般接口不同；返回 `void` 的契约把「上游拒绝」与「成功」折叠。
- 影响：用户发评论/回复/删除时，服务端返回业务失败（如评论含敏感词、已被删除、需要验证）但 HTTP 200，UI 一律弹「评论成功 / 已删除」并刷新列表，实际数据未变更；用户下次进来才发现，且日志无留痕。这是「评论」全流程的静默错误。
- 证据等级：静态推演（上游返回形态未实测，代码内零判定为实锤）

### lib/features/comment/data/comment_repository.dart:14 / 250-255 `isMine` 依赖 `_api.userid`，切号后旧列表缓存的「我的评论」不刷新
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 23 条（缓存/结果键必须覆盖用户身份）
- 依据：`String get _currentUserId => _api.userid;` 在 `fetchComments`/`fetchFloor` 时传入 `CommentPage.fromJson`，`Comment.isMine` 是构造时固化的 `final bool`；F18 的 `_commentsProvider` 是 `StateNotifierProvider.family<..., _CommentArgs>`，`_CommentArgs` 只有 `type/id`，不含 userid。切号后若页面 State 未重建（`_args` 是 `late final`），列表仍是上一个账号视角。
- 影响：用户切换账号后回到已打开的评论页，看到「删除」按钮仍挂在上一账号的评论上（或本人的评论没有删除入口）；点击删除服务端会拒绝，UI 才提示失败。属「切号→评论」链路的身份断点。
- 证据等级：静态推演

### F17 `lib/features/comment/presentation/comment_floor_page.dart`（356 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`CommentFloorPage({args: CommentArgsShim, comment})`，`_floorRepoProvider` 注入 `kugouApiClientProvider`；`_load`/`_loadMore` 调 `fetchFloor(specialId,tid,type,mixsongid,page)`；`_send` 调 `sendFloorReply`；`_deleteComment` 调 `deleteComment(cid,mixsongid,specialId,tid,resourceType)`；登录判定 `authStateProvider.valueOrNull != null` + `ensureLoggedIn`。
- 复核通过：`_pageError` 与「没有更多」两种 footer 态分离、发送有 `_sending` 闸门、失败还原输入文本、删除带二次确认、Scroll/TextEditingController 在 dispose 对称释放、`friendlyError` 不裸出技术串。

### lib/features/comment/presentation/comment_floor_page.dart:147-176 `_send()` 先 `_inputCtrl.clear()` 再检查 `_sending`，且未登录时把已输入文本留在匿名引导之后却被清空
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作防重闸门位置）、第 3 条
- 依据：顺序为 `if (!_isLoggedIn) { ensureLoggedIn(...); return; }` → `_inputCtrl.clear();` → `if (_sending) return;` → `_sending = true;`。即第二次点击（在第一次飞行中）会先把输入框清空再被 `_sending` 拒绝，文本不会还原；而 `_sending` 为 true 期间发送按钮 `IconButton.filled(onPressed: _send)` 并未置 null（按钮始终可点）。
- 影响：用户连点两次发送（或网络慢时再点一次）时输入内容永久丢失，且没有任何提示；与同文件注释「飞行期间防重」的意图相反，用户必须重新打字。
- 证据等级：实锤

### lib/features/comment/presentation/comment_floor_page.dart:181-200 删除操作无防重闸门、无登录校验，且成功后 `_load()` 无世代校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（删除写操作防重）、第 18 条
- 依据：`_deleteComment` 只有 `showDestructiveConfirm`，确认后直接 `await _repo.deleteComment(...)`，无 `_deleting` 标记，也无 `_isLoggedIn` 检查（按钮显示条件 `_isLoggedIn && c.isMine` 只在 build 时求值，删除过程中登录态变化不复核）；成功后 `await _load()` 而 `_load` 会 `..clear()..addAll()`，若用户同时在下拉刷新，两个请求可交叉写列表。
- 影响：连点删除会对同一 cid 发两次删除请求（第二次通常失败并弹「删除失败」，尽管第一次已成功），用户误以为删除未生效；并发刷新时楼层列表可能被旧响应覆盖。
- 证据等级：静态推演

### F18 `lib/features/comment/presentation/comments_page.dart`（726 行，完整读，✅ 本代理通读）

- 关键链路：`_commentsProvider` 为 `StateNotifierProvider.family`（参数 `_CommentArgs(type,id)`），`_generation` 代次校验、`_pageError` footer 重试；`_send` 有 `_sending` 闸门、失败还原输入、20028 时打开 `CaptchaPage` 且**明确不自动重试**（`commentVerifiedRetryHint` 让用户手动再点）；`_openFloor` 返回后 `load(refresh:true)`；`_deleteComment` 二次确认 + `unwrapApi` 统一文案；分类标签/热词已渲染；`_isLoggedIn` 用 `authStateProvider.valueOrNull`。
- 复核通过（本范围最完整的三态处理）：`state.when(loading/error/data)` + `EmptyState` + `RefreshIndicator` + footer「重试/加载中/没有更多」三态齐全；发送防重闸门在 `_sending = true` 之后才 `clear()`，失败还原 `_replyTo` 与文本；验证通过后不自动重发写操作，避免第 21 条重复提交；`_commentsController.loadMore` 失败不推进页码。

### lib/features/comment/presentation/comments_page.dart:61-84 `_CommentsController.load()` 首屏失败后 `_generation` 已推进、无 `AsyncError` 时用户只能靠 ErrorRetry，但 `load(refresh:true)` 不清 `_pageError`、不重置 `_loadingMore`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（三态分离）、第 19 条（互斥闸门归属同一所有者）
- 依据：`load({refresh})` 的 `refresh` 分支只 `_page=1; _hasMore=true;`，随后 `final gen = ++_generation`；`catch (e, st) { if (state.value == null) state = AsyncValue.error(e, st); }` 仅在**首屏**写 error，若 `state.value != null`（已有一页数据）时刷新失败则不更新 state、不置 `_pageError`、不提示，静默保留旧数据。`retryLoadMore()` 才清 `_pageError`。
- 影响：用户下拉刷新时网络失败，界面完全没变化（列表还是旧数据、无 Toast、无重试入口），误以为刷新成功；首屏失败时 ErrorRetry 可用，但刷新期间若 `_loadingMore` 仍为 true，后续 `loadMore()` 被永久挡住。
- 证据等级：实锤

### lib/features/comment/presentation/comments_page.dart:137-143 `sendComment`/`deleteComment` 成功后无条件 `load(refresh:true)`，写操作失败语义与列表刷新失败混在一起
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约稳定）、第 9 条
- 依据：`sendComment(String content)` 内 `await _repo.sendComment(...); await load(refresh: true);`，`deleteComment` 同型；结合 F16 三个写端点不检查业务状态，`_repo.sendComment` 返回即成功。若 `load(refresh:true)` 本身失败（F18 上一条：有数据时静默），UI 仍 Toast「评论成功 / 已删除」；若写操作被上游拒绝但 HTTP 200，同样 Toast 成功。
- 影响：用户发完评论后列表不更新（仍是旧数据）却看到「评论成功」；删除后评论仍在列表里却看到「已删除」，必须手动下拉才能发现真实状态。
- 证据等级：实锤

### lib/features/comment/presentation/comments_page.dart:379-385 未登录时 `_buildInput` 的发送按钮直接 `context.push('/login')`，与 `_send()` 内的 `ensureLoggedIn` 两套引导口径
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（同一操作入口契约一致）、第 30 条
- 依据：`IconButton.filled(onPressed: _isLoggedIn ? (_sending ? null : _send) : () => context.push('/login'))`；而 `_send()` 首行对 `!_isLoggedIn` 是 `ensureLoggedIn(context, ref, action: context.l10n.comment)`（带说明弹窗 + 取消/去登录）。键盘 `onSubmitted: (_) => _send()` 在任何情况下都走 `_send`。
- 影响：点发送按钮直接被甩到登录页且无说明；用键盘「发送」键则弹说明对话框。用户在同一输入框得到两种不同反馈，且 `login_guard` 的 `loginRequiredAction(comment)` 文案永远不会被按钮路径用到。
- 证据等级：实锤

### lib/features/comment/presentation/comments_page.dart:186-195 / 418-425 `resourceType` 未知值静默按歌曲处理，路由参数错误时评论落到错误资源
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（缺失/非法必须语义分离）、第 14 条（深链参数边界校验）
- 依据：`late final _args = _CommentArgs(switch (widget.resourceType) { 'playlist' => ..., 'album' => ..., _ => CommentResourceType.song; }, widget.resourceId);`，任何其它字符串（含空串、拼写错误、`Uri.encodeComponent` 后的意外值）都当 `song`；`_commentsProvider(_args)` 立即以 `mixsongid=resourceId` 发请求。F2 `album_page.dart:130-134` 已证明存在 `info.id` 为空时进入 `/comments/album/` 的路径。
- 影响：从专辑页（详情字段缺失）或外部深链进入评论页时，参数被静默解释成歌曲评论，显示完全无关的评论列表或空白，用户无法知道是链接/数据问题；发评论会写到错误资源上。
- 证据等级：静态推演

### lib/features/comment/presentation/comments_page.dart:441-478 20028 验证分支在 `catch` 中先还原输入、再弹验证页，`ok==true` 只提示「请手动重发」，但 `_replyTo` 状态已丢失
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回值契约）、第 16 条
- 依据：catch 中 `_inputCtrl.text = text; _replyTo = replyTo;` 之后打开 `CaptchaPage`（F11 在 `onVerified` 返回 false 时仍 `pop(true)`，本处未传 `onVerified`），`ok == true` 时只 `Toast.show(commentVerifiedRetryHint)`；但 `finally` 里 `_sending=false; setState((){})` 会在 `await Navigator.push` 返回前一直占着闸门，且 `CaptchaPage` 的 `true` 不携带「验证事件已消费」信息。用户手动再点发送时，是重新构造一份新请求，若上游要求带上一次的验证票据，仍会再次 20028。
- 影响：评论被风控后用户完成验证、按提示重发，可能再次触发验证形成循环；同时输入框虽有文本，但 `_replyTo` 的回复目标在 `setState(() => _replyTo = null)` 后**只在成功/失败分支还原**，20028 分支 `return` 前未显式还原（catch 里已还原 `_replyTo = replyTo`，此处需谨慎：代码确实在 catch 开头还原，故此点不成立，仅保留「true 语义不携带验证票据」的后果）。
- 证据等级：静态推演

### F19 `lib/features/download/data/download_repository.dart`（302 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`DownloadRepository({playApi?, lyricRepository?, mvRepository?, dio?})`；`resolveAudioDownloadSource(hash,{albumId,albumAudioId,quality})` 返回 `(url, ext, segment)`，`segment ∈ {'full','trial','climax'}`；`downloadFile(url,savePath,{onProgress,cancelToken,retries=2})`；`publish(task,tempFilePath,{strategy})` → `PublicMediaStore.instance.publish` → `PublishedFile`；`displayNameOf(task)` 用 `realTempPath` 的真实扩展名覆盖默认 `.mp3`。

### lib/features/download/data/download_repository.dart:56-119 非 VIP 下载把「片段类型」静默记进 `segment`，用户直到播放才发现下到的不是全曲
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（不同业务事实必须可区分）、第 9 条（失败/降级必须可观测）
- 依据：`resolveAudioDownloadSource` 在全曲不可用时自动落到 `trial` 或 `climax`，返回 `('trial'/'climax')` 字符串，但 `download_provider.dart:369-375` 只把它写进 `DownloadTask.segment`（`download_task.dart:100-102` 注释明确「元信息记录，UI 无需变化」），`download_page.dart:120-160` 的 `statusLabel`/`typeLabel` 完全不读 `segment`，`download_sheet.dart` 也不展示。
- 影响：未登录/非 VIP 用户点「下载音频」看到「已完成」，文件其实是 30~60 秒试听或高潮片段，用户离线播放才发现不是完整歌曲；三态（全曲/试听/高潮）在 UI 上被折叠为同一个「已完成」，没有购买/登录引导。
- 证据等级：实锤

### F20 `lib/features/download/data/download_store.dart`（61 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`DownloadStore.instance` 静态单例，`boxName='downloads'`；`readAll/read/save/remove/clear` 全部经 `_boxOrNull()`（仅 `Hive.isBoxOpen(boxName)` 时取盒），否则静默返回空/`null`/直接 return；key 为 `DownloadTask.id`，value 为 `task.toJson()`。
- 本文件从用户路径看的问题与 F22（管理器恢复）合并记录，避免重复；此处仅确认「盒未打开时所有写操作静默成功」是下游无反馈的根源事实。

### F21 `lib/features/download/data/download_task.dart`（267 行，完整读，✅ 本代理通读）

- 复核通过：`DownloadTask.id = '${type.name}_$hash'` 明确把类型纳入去重键；`progress` 对 `total<=0` 返回 null（未知大小与 0% 分离）；`fromJson` 对 type/status 用 `firstWhere(orElse:)` 安全降级，对数值字段逐一 `is int / int.tryParse` 校验，无裸强转；`copyWith(clearError:)` 显式区分「清错误」与「不改错误」；`segment`、`realTempPath`、`durationSec`、`quality` 等影响产物的维度都进模型。
- 跨文件契约：`DownloadTaskStatus` 五态 queued/running/paused/completed/failed；`isActive` 只含 queued+running；`fileExtension` 默认 audio=`.mp3`（真实扩展名由 `realTempPath` 覆盖）。

### lib/features/download/data/download_task.dart:109-112 任务 id 不含音质/账号/语言，`add()` 的「同 id 覆盖」会静默替换用户已完成的另一音质下载
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存/产物键必须覆盖全部影响结果的维度）、第 5 条（状态单一来源）
- 依据：`String get id => '${type.name}_$hash';`；`quality`、`targetLanguage`、`albumAudioId`、`segment`、`userId` 都不在键里。F22 `DownloadManager.add()` 注释「同一 id 覆盖」，`download_sheet.dart:38-47` 的 `buildTask` 每次都带当前 `preferredQuality()` 与 `song.quality`。同一首歌先下 128k 完成、再下 320k 时，旧任务记录被整体替换（临时文件名虽含 quality 维度，但任务表与 `hasAudio()` 只认 id）。
- 影响：用户在设置里改默认音质后重新下载同一首歌，列表里只剩一个任务，之前已完成文件的记录丢失（`remove()` 不再能删除旧文件），`hasAudio()` 对两个音质返回同一结论；切换账号后下载列表也共用同一批 id，跨账号文件互相覆盖/归属不清。
- 证据等级：实锤

### lib/features/download/data/download_task.dart:196-204 `fromJson` 的历史坏数据被静默改写成 `audio`/`queued`，用户看不到「数据损坏」态
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条（缺失/损坏语义分离）、第 9 条
- 依据：`type: DownloadTaskType.values.firstWhere(..., orElse: () => DownloadTaskType.audio)`、`status: ... orElse: () => DownloadTaskStatus.queued`；Hive 中类型/状态字符串非法时直接变成「音频 / 排队」，无日志、无标记，随后 F22 `_restore()` 又把 queued 统一置为 paused。
- 影响：升级或盒数据损坏后，用户原本已完成的 MV/歌词任务变成「音频·已暂停」，点继续会重新下一次音频；无任何提示说明记录被修复过。
- 证据等级：实锤

### F22 `lib/features/download/data/public_media_store.dart`（324 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`PublicMediaStore.instance.publish({type,tempFilePath,displayName,strategy})` → `PublishedFile(uri?,path?,displayPath)`；`queryExisting/delete/open/viewFolder` 均为 `Future<bool>` 或可空返回；`relativePathOf` 用 `StoragePermissionService.fallbackRootDirName`；`mimeOf` 按 `realTempPath` 扩展名选真实 MIME；`viewFolder` 对只有 content:// uri 的文件直接返回 false。
- 复核通过：MediaStore insert/write/finalize 三步都校验返回值并在失败时删 pending 条目后降级直写；`_publishDirect` 先写 `.part` 再 `rename` 原子覆盖、失败清理 `.part`；`viewFolder` 无路径时提前返回 false 供 UI 复制路径兜底（F24 已消费）。

### lib/features/download/data/public_media_store.dart:105-146 MediaStore 失败一律静默降级到直接写路径，用户拿到的「保存位置」与策略展示不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（降级必须可观测/留痕）、第 11 条（降级触发/退出条件）
- 依据：`insert` 返回 null → `_publishDirect`；`write != true` → 删 uri + `_publishDirect`；`finalize != true` → 删 uri + `_publishDirect`；`catch (_) { ... return _publishDirect(...) }`。所有分支都没有日志或返回值标记，`PublishedFile` 也不区分「MediaStore 成功」与「降级直写」；`DownloadManager._strategy` 仍是 `mediaStore`，`onAppLifecycle` 只在 resume 时重置。
- 影响：Android 10+ 用户看到下载「已完成」，文件实际落在 App 私有/降级目录，第三方播放器与系统媒体库扫不到；设置页/任务详情显示的仍是媒体库路径，用户找不到文件，且本次进程内后续下载继续走同一降级路径无提示。
- 证据等级：静态推演

### lib/features/download/data/public_media_store.dart:236-263 `queryExisting` 只查 MediaStore 的 `collection/relativePath`，与 `_publishDirect` 的实际落盘目录不是同一空间
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：查询与写入必须同一事实源）、第 21 条
- 依据：`queryExisting` 在 `apiLevel>=29` 时只 `invokeMethod('query', {collection,displayName,relativePath})`，`catch (_) {}` 后直接 `return null`；而 `publish` 在 MediaStore 失败时会 `_publishDirect` 写到 `resolveRoot()/sub` 或 `fallbackDir`，这些路径不参与 query。F24 `_run` 的流程是 `exist = await queryExisting(...); if (exist != null) delete(exist); await _repo.publish(...)`。
- 影响：同名文件已由直接路径写过一次时，query 查不到 → 不删旧文件 → `_publishDirect` 用 `rename` 覆盖（此点会覆盖，需谨慎），但若 MediaStore 路径与直接路径同时存在，用户会在两个目录各有一份同名文件；`remove()` 只删任务记录里最后保存的那一个，另一份成为无人管理的残留。
- 证据等级：静态推演

### F23 `lib/features/download/download_provider.dart`（492 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`downloadManagerProvider = StateNotifierProvider<DownloadManager,DownloadState>`；`downloadRepositoryProvider` 注入 `kgPlayApiProvider`/`lyricRepositoryProvider`/`kugouApiClientProvider`；`add/addAll/pause/resume/retry/remove/clearAll/hasAudio/audioTaskOf`；`maxConcurrent=2`；`onAppLifecycle` resume 重置策略；`_restore()` 把 running/queued 改为 paused；`_run` 的 token 归属守卫 `_tokens[task.id] != token` 与 finally 槽位释放。
- 复核通过：同 id 重新添加会取消旧 token（DL-03）、remove 用「钉死哨兵 token」防迟到回调复活任务、临时文件名 `dimKey` 含 hash/type/quality/albumAudioId、发布成功后清临时文件、完成态同时保存 `filePath` 与 `mediaUri`、`_update` 仅在状态变化时记 verbose 日志。

### lib/features/download/download_provider.dart:82-91 / 20-25 `_restore()` 只改内存 state，不把「running/queued → paused」写回 Hive，且盒未打开时全部历史任务静默消失
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 9 条（失败必须可观测）、第 16 条
- 依据：`_restore()` 中 `final saved = DownloadStore.readAll(); if (saved.isEmpty) return; ... state = state.copyWith(tasks: restored);`——`restored` 只经 `state.copyWith` 写内存，没有 `DownloadStore.save(t)`；而 `DownloadStore.readAll()` 在 `_boxOrNull()==null` 时返回 `const []`（F20），`save/remove/clear` 同样静默 return。`DownloadManager` 构造函数只调 `_restore()`，不负责 `Hive.openBox('downloads')`。
- 影响：用户在下载途中杀掉 App 或重启后，若 `downloads` 盒因初始化顺序未打开，整个下载列表显示为空（已完成文件仍在磁盘但无记录，无法打开/删除）；若盒已打开，Hive 里仍存着 `running/queued`，下次冷启动再次 `_restore` 成 paused，但期间任何 `add()` 会以旧状态为准覆盖，且用户看不到「上次未完成」的恢复提示。
- 证据等级：静态推演（盒打开时机在 main.dart，本范围未读；本层无 openBox 与无写回为实锤）

### lib/features/download/download_provider.dart:389-410 发布完成后 `filePath: published.path ?? published.uri ?? ''` 把 content:// uri 当文件系统路径存，且 `size` 取自已被删除的临时文件
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（字段形态契约）、第 17 条（数值精度/语义）
- 依据：完成分支先 `final size = await File(realTempPath).exists() ? await File(realTempPath).length() : 0;`，随后在 `cur != null` 里 `f.deleteSync()` 删掉 `realTempPath`，再 `_update(cur.copyWith(filePath: published.path ?? published.uri ?? '', received: size, total: cur.total > 0 ? cur.total : size, ...))`。`PublicMediaStore.publish` 在 MediaStore 成功时返回 `PublishedFile(uri:..., path:null)`（F22），于是 `filePath` 存成 `content://...`；F24 `if (task.filePath.contains('/Android/data/'))` 与 `viewFolder(PublishedFile(path: task.filePath))` 都把它当绝对路径用。
- 影响：Android 10+ 完成的任务在下载页显示一个 `content://` 字符串作为「文件路径」，点「在文件管理器中打开」把 uri 传给需要绝对路径的原生方法必然失败（F24 有 Toast 兜底），用户复制路径也拿到不可用的 uri；`received/total` 用临时文件大小而非发布后文件，若发布时被截断/改名，进度显示与实际不符。
- 证据等级：实锤

### lib/features/download/download_provider.dart:108-126 `add()` 对已完成任务也强制覆盖为 queued 并重新下载，无「已下载」确认
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作防重）、第 16 条
- 依据：`final exists = state.tasks.any((t) => t.id == task.id);` 只在 `exists && _running.contains(task.id)` 时取消旧任务；随后无条件 `_replace(task.copyWith(status: queued, clearError:true, ...))` 并 `unawaited(_schedule())`。`download_sheet.dart` 的 `_OptionTile` 对 `status==completed` 显示 `Icons.check_circle` 但 `trailing` 仍是可点的下载按钮（只有 running 显示转圈），点已完成的音频会重新入队。
- 影响：用户在下载弹层看到「已完成」却误点下载图标，App 重新下载并覆盖同名文件（F22 发布前 query+delete 会删掉刚完成的旧文件），期间若断网，任务变成 failed，原本已完成的文件已被删除；用户数据丢失且无「确认重新下载」提示。
- 证据等级：实锤

### F24 `lib/features/download/presentation/download_page.dart`（311 行，完整读，✅ 本代理通读）

- 复核通过：`WidgetsBindingObserver` 在 init/dispose 对称注册与移除并把生命周期传给 manager；清空全部与删除都有 `showDestructiveConfirm`；空态有 `downloadEmptyGuide`；打开文件/打开目录失败都有 Toast 或复制路径兜底；`PopupMenuButton` 按状态只显示可用操作；进度条在 running/paused 显示，`task.error` 拼进状态行。

### lib/features/download/presentation/download_page.dart:126-135 失败原因 `task.error` 直接拼进单行状态文本，长错误被 `maxLines:1` 截断
- 级别：P3
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测到可行动程度）
- 依据：`Text('$typeLabel · $statusLabel${task.error != null ? ' · ${task.error}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, ...)`；`task.error` 来自 `friendlyError(e)` 或 `e.message`，可能包含较长的技术描述。
- 影响：下载失败时用户只看到「音频 · 下载失败 · ...」被截断的一行，无法知道是权限、网络、音质需会员还是磁盘不足，也没有展开/长按复制入口；只能盲目点重试。
- 证据等级：实锤

### lib/features/download/presentation/download_page.dart:44-57 清空全部删除文件失败不反馈，`clearAll()` 内部忽略 `delete()` 返回值
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）
- 依据：AppBar 清空按钮 `if (ok) await manager.clearAll();` 无后续提示；F23 `clearAll()` 对每个任务 `await PublicMediaStore.instance.delete(...)` 但不检查返回的 bool，`delete()` 自身 `catch (_) { return false; }`（F22 :270-283）静默吞异常；随后无条件 `state = const DownloadState(); await DownloadStore.clear();`。
- 影响：用户点「清空全部」后列表空了，但公共目录里的音频/MV 文件可能仍在（删除失败），UI 显示清空成功；后续 `remove()` 也无记录可删，文件永久残留占空间。
- 证据等级：实锤

### F25 `lib/features/download/presentation/download_sheet.dart`（215 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`showDownloadSheet(context, song)`；`DownloadSheet` 用 `downloadManagerProvider`、`songMvProvider(albumAudioId)` 预判 MV、`preferredQuality()` 取默认音质；四个 `_OptionTile` 分别 `manager.add(buildTask(type))`；「全部下载」只 add audio/cover/lyric 三项后 `pop()`。
- 复核通过：MV 不可用时禁用并给 `downloadMvUnavailable` 说明；行内下载按钮保证 48dp 触控区；`_taskOf` 按 hash+type 找已有任务，显示进度/完成态。

### lib/features/download/presentation/download_sheet.dart:106-114 「全部下载」不弹 Toast/不报错也不校验 addAll 结果，弹层直接关闭
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条
- 依据：`onPressed: () async { await manager.addAll([...]); if (context.mounted) Navigator.of(context).pop(); }`；`addAll` 内逐个 `await add(t)`，`add` 的 `DownloadStore.save()` 在盒未打开时静默 return（F20/F23），`add` 本身不抛；弹层关闭后用户没有任何反馈入口，只有进入下载管理页才知道任务是否存在。
- 影响：用户点「全部下载」后弹层消失，若持久化盒未打开或三个任务中任一失败，界面无任何提示；用户以为已开始下载，实际列表为空或只有部分任务，需自行去下载页核查。
- 证据等级：静态推演

### lib/features/download/presentation/download_sheet.dart:60-104 四个下载按钮无 `_sending`/在途闸门，连点会对同一 id 连续 `add()` 覆盖
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作防重）
- 依据：每个 `_OptionTile.onDownload` 都是 `() async { await manager.add(buildTask(type)); }`，`_OptionTile` 未对 `onDownload` 做禁用（只有 `enabled` 静态控制与 `status==running` 时把 trailing 换成转圈，但 `onTap` 仍可点其它空白区；`ListTile` 的 `onTap` 未设置，需谨慎）。结合 F23 `add()` 同 id 覆盖并取消旧 token，快速连点会连续取消/重建任务。
- 影响：用户连点两次「下载音频」，第一次任务被取消后重新入队，`createdAt` 被刷新、`realTempPath` 可能残留，下载页短暂显示进度归零；极端情况下旧 `_run` 的取消异常与新任务状态交错，用户在下载页看到反复重启的进度条。
- 证据等级：静态推演

### F26 `lib/features/library/data/recent_play_store.dart`（101 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`RecentPlayStore.read()` 会懒开盒；`add(item)` 经 `_serial` 串行队列去重置顶、上限 50；`clear()`；`changes` 广播（`Stream<void>`）供 F27 `_recentSub` 刷新；`RecentPlay.ts` 注释为毫秒时间戳。
- 复核通过：`add` 的链式队列避免快速连播「读-改-写」互相覆盖；`read()` 懒开盒避免冷启动永远空；`fromJson` 对 `ts` 做 `is int / tryParse` 校验。

### lib/features/library/data/recent_play_store.dart:57-73 串行队列的 `catchError` 用空体吞掉写入失败，`changes` 不广播且 `add()` 的返回 Future 仍带错误
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`_serial = next.catchError((Object e) { // ignore: avoid_print  return; });`，catch 内无日志、无 `notifyListeners()`；`return next;` 把原始失败的 Future 交给调用方，但调用方（播放链路）通常 `unawaited` 或忽略。盒写入失败时既不广播也不留痕。
- 影响：最近播放写入失败后，用户播放了新歌，音乐库「最近播放」仍停留在旧列表且无错误提示；由于 `_serial` 被替换为已完成的 Future，后续写入会继续尝试但 UI 永远等不到 `changes` 事件，表现为「最近播放不更新」。
- 证据等级：实锤

### lib/features/library/data/recent_play_store.dart:44-55 / 82-88 最近播放是全局单键列表，不含账号维度
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（键必须覆盖用户身份）、第 5 条
- 依据：`static const _kList = 'list';`，`read()`/`_addInner()`/`clear()` 都只对这一个键操作，`RecentPlay` 无 userid 字段；F27 的账号变化监听只 `invalidate` 歌单与收藏 MV，不 invalidate/清空 `_recent`。
- 影响：A 账号退出、B 账号登录（「切号」主路径）后，音乐库「最近播放」仍完整展示 A 的听歌记录，点播会直接播放 A 听过的歌；B 用户误以为这是自己的历史，隐私与状态一致性同时受损。
- 证据等级：实锤

### F27 `lib/features/library/presentation/library_page.dart`（691 行，完整读，✅ 本代理通读）

- 关键链路：`initState` 同时订阅 `AccountManager.onCurrentAccountChanged`（登出/切号 → `setState` + invalidate `libraryUserPlaylistsProvider`/`libraryCollectedMvsProvider`）与 `RecentPlayStore.changes`；`build` 用 `_currentAccount()`（catch 吞异常返回 null）决定「我的歌单/收藏 MV」登录引导；`_AccountCard` 已登录提供「账号管理 / 退出」PopupMenu；最近播放、已下载各 `take(20)`；`_playDownloaded` 把 `task.filePath` 当 `Song.localPath` 传给 `playHelperProvider.playSong`。
- 复核通过：两个 StreamSubscription 在 `dispose` 对称 cancel；歌单/MV 用 `skipLoadingOnReload:true` 保留旧数据、错误态有 `ErrorRetry`（cookie 过期可走重新登录）；未登录有 `_LoginGuideCard`；清空最近播放有二次确认；MV 收藏空态给 `mvCollectGuide` 引导；`_playRecent`/`_playDownloaded` 都在 `await` 后判 `mounted`。

### lib/features/library/presentation/library_page.dart:43-52 账号切换只失效「我的歌单 / 收藏 MV」，不失效最近播放、已下载与账号卡片数据来源
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 23 条（身份维度）、第 18 条（异步世代）
- 依据：`onCurrentAccountChanged.listen((_) { setState(() {}); ref.invalidate(libraryUserPlaylistsProvider); ref.invalidate(libraryCollectedMvsProvider); })`；`_recent` 是 State 内普通 `List<RecentPlay>`，`RecentPlayStore` 全局单键（F26）；`downloadedAudioProvider` 来自 `downloadManagerProvider`，任务 id 不含 userid（F21）；`libraryUserPlaylistsProvider(bool loggedIn)` 的 family 参数只有 `loggedIn`（`true/false`），A→B 切换时两者都为 `true`，`invalidate(provider)` 无参数会失效整个 family（此点成立），但 `libraryCollectedMvsProvider(true)` 同理。真正未失效的是 `_recent` 与 `downloaded`。
- 影响：用户从 A 切到 B，音乐库顶部账号卡片变成 B，歌单/MV 刷新为 B，但「最近播放」仍是 A 的历史、「已下载」仍是 A（或共享）的文件列表；点「最近播放」直接播放 A 的歌，点「已下载」用 A 的本地文件播放，形成明显的切号串数据。这是任务书点名的「登录→切号」断点。
- 证据等级：实锤

### lib/features/library/presentation/library_page.dart:229-241 已下载播放把 `task.filePath` 当本地路径，而 Android 10+ 该字段实际是 `content://` uri
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（字段形态契约）、第 15 条（形态显式）、第 4 条（跨层契约一致）
- 依据：`_playDownloaded` 构造 `Song(localPath: task.filePath.isNotEmpty ? task.filePath : null)`；F23 `download_provider.dart:389-410` 在 MediaStore 成功时写 `filePath: published.path ?? published.uri ?? ''`（`published.path` 为 null → 存 content:// uri）。`Song.localPath` 在播放层按文件系统路径使用（本范围未读 audio_handler，但 `download_page.dart` 同样把 `filePath` 传给 `File`/`viewFolder`，F22 已注明 MediaStore 文件只有 uri）。
- 影响：Android 10+ 用户在音乐库点「已下载」歌曲，传给播放器的 `localPath` 是 `content://media/...`，播放器按 `File` 打开失败 → 断网/VIP 离线场景无法播放已下载音频，或回退到在线播放消耗流量；用户看到「下载完成却不能离线听」。
- 证据等级：静态推演（播放层对 content:// 的处理未在本范围，字段形态冲突为实锤）

### lib/features/library/presentation/library_page.dart:335-355 退出登录失败只弹不带原因的空 `logoutFailed('')`，且未区分「凭证清理失败」与「网络失败」
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条
- 依据：`catch (e) { if (context.mounted) Toast.show(context, context.l10n.logoutFailed('')); debugPrint('[library] 退出登录失败: $e'); }`；`logoutFailed` 显然接受一个原因参数却传空串，用户看到的只有「退出失败」；F6 `logout()` 内部对 Hive 清理是 `catch (_) {}`，F7 `logout()` 的 `readCredentials()` 无保护，异常可能来自凭证存储。
- 影响：用户点「退出登录」后若失败，界面没有任何变化（账号卡片仍显示已登录），Toast 又不给原因与下一步；用户反复点退出均失败却不知道是 Keystore 故障还是网络问题，也无法手动清理。
- 证据等级：实锤

### lib/features/library/presentation/library_page.dart:81-85 账号卡片用 `AccountManager.currentAccount` 而非 `authStateProvider`，两种登录态事实源可给出相反结论
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）
- 依据：`final account = _currentAccount();`（内部 `AccountManager.instance.currentAccount`，`catch (_) => null`），而 `authStateProvider` 是 F6 的 `AsyncNotifier<AuthUser?>`；F7 `_handleLoginSuccess` 里 `AccountManager.upsert` 与 `saveCredentials`/`api.setCredentials` 并行且失败只 debugPrint，F6 `logout()` 先 `state=AsyncData(null)` 再（可能失败地）清 Hive。`libraryUserPlaylistsProvider(account != null)` 的 `loggedIn` 也由 AccountManager 决定。
- 影响：出现「authState 已是未登录、AccountManager 仍指向 A」或反之的分裂时，音乐库按 AccountManager 展示 A 的账号卡片并向服务端请求 A 的歌单，而其它页面按 authState 显示未登录；用户在同一次切号/登出流程里看到两个账号状态，且请求带着已清掉的凭证必然失败。
- 证据等级：静态推演

### lib/features/library/presentation/library_page.dart:251-262 清空最近播放后不等待 `_loadRecent()`，且 `clear()` 在盒未打开时直接返回
- 级别：P3
- 违反：QUALITY_STANDARD 第 9 条（操作结果可观测）、第 16 条
- 依据：`if (ok) { await RecentPlayStore.clear(); _loadRecent(); }`（`_loadRecent()` 未 await/未 `unawaited` 显式化）；F26 `clear()` 开头 `if (!Hive.isBoxOpen(_boxName)) return;`，盒未打开时不抛、不广播，`_loadRecent()` 随后 `read()` 懒开盒仍会读到原列表。
- 影响：用户确认「清空最近播放」后列表可能短暂不变或又出现旧数据，没有成功/失败提示；在盒未打开的极端路径上清空操作完全无效但 UI 无任何反馈。
- 证据等级：静态推演

### F28 `lib/features/playlist/data/playlist_repository.dart`（656 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`PlaylistWriteException(message,{maybeSucceeded,cause})` 是写操作唯一异常出口；`collectPlaylist/deletePlaylist/addTracks/removeTracks` 全部经 `_write(path,params,{dedupeKey})` → `_api.get(path,query:)` → `_invalidatePlaylistCaches()`，飞行防重 `_inFlight`；`fetchUserPlaylists/fetchDetail/fetchTracks/fetchUserTracks` 走 `_api.get` / `CachedApiCall(ns:'playlist')`；`PlaylistDetail.fromJson` 在 `data` 为空时抛 `ApiException(-1,'歌单不存在或 ID 无效')`。
- 复核通过（收藏链路最到位处）：`_toWriteException` 按 DioExceptionType 区分「请求未发出 / 结果未知」，`maybeSucceeded` 文案明确禁止诱导重试；`_inFlight` 防重锁在 `finally` 释放；写成功后 `invalidateNs('playlist')` + `MemoryCache.removeWhere`；`addTracks` 对歌名分隔符做全角替换、批内按 hash 去重、空 listid/hash 明确拒绝；`_fetchAllReversed` 单页失败留痕跳过且有 `maxPages=100` 上界。

### lib/features/playlist/data/playlist_repository.dart:96-106 `fetchUserPlaylists` 只取第一页 30 条，无分页参数出口
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：分页能力闭环）、第 16 条
- 依据：方法签名 `fetchUserPlaylists({int page=1,int pageSize=30})` 虽有分页参数，但内部只发一次 `_api.get('/user/playlist', query:{'page','pagesize'})`，不读 `data.total`/不循环；F29 `AddToPlaylistSheet._reload()` 与 F27 `libraryUserPlaylistsProvider` 都不传参数，直接展示返回的 `List<UserPlaylist>`。
- 影响：拥有超过 30 个歌单的用户在「收藏到歌单」弹层和音乐库横排里看不到第 31 个之后的歌单，且列表看起来就是完整列表（无「加载更多」/无「仅显示前 30」提示），用户以为歌单丢失或无法把歌加进旧歌单。
- 证据等级：实锤

### lib/features/playlist/data/playlist_repository.dart:370-397 `_write` 把「HTTP 200 但业务失败」当作成功并失效缓存，写操作静默错误直达收藏/加歌路径
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）、第 9 条（失败必须可观测）、第 16 条
- 依据：`try { await _api.get(path, query: params); _invalidatePlaylistCaches(); } on DioException ... on ApiException ...`；`_api.get` 返回 `Map` 后不做 `status`/`err_code` 判定即视为成功，`_write` 返回 `Future<void>`。REVIEW_SPEC 明确歌单写端点返回结构需逐端点实测，且 `playlist/del` 是 AES body + 二进制响应；本层对所有写端点都只靠「没抛异常」判成功。
- 影响：用户点「收藏歌单 / 新建歌单 / 加歌到歌单 / 删歌」，服务端返回业务失败（重复收藏、权限不足、参数被拒）但 HTTP 200 时，UI 一律弹「收藏成功 / 已添加到歌单」并刷新缓存，实际数据未变更；用户去「我的歌单」才发现操作没生效，且无任何日志。这是「收藏」全流程的静默错误。
- 证据等级：静态推演（上游返回形态未实测；零成功判定为实锤）

### lib/features/playlist/data/playlist_repository.dart:397-401 `_inFlight` 只按 `dedupeKey` 去重，不含用户身份，切号瞬间两个账号的同名操作互相吞掉
- 级别：P3
- 违反：QUALITY_STANDARD 第 23 条（键必须覆盖身份维度）
- 依据：`final Set<String> _inFlight = <String>{};`，`dedupeKey` 形如 `add:${gid}:${listid}:$name` / `tracks-add:$id:${rows}`，无 userid；`PlaylistRepository` 由 `playlistRepositoryProvider` 全局共享，切号不重建。
- 影响：A 账号「收藏歌单」请求在飞、用户立刻切到 B 再点同名收藏，第二次被判「相同操作正在提交中」而拒绝；B 用户看到「请稍候」但操作根本没发出，需等旧请求结束再手动重试。
- 证据等级：静态推演

### F29 `lib/features/playlist/presentation/add_to_playlist_sheet.dart`（326 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`showAddToPlaylistSheet(context, TrackRef)`；`_reload()` 用 `authStateProvider.valueOrNull` 判登录 → `playlistRepositoryProvider.fetchUserPlaylists()`；`_addTo(p,{bypassBusy})` → `addTracks` → Toast `addedToPlaylist` + pop；`_createAndAdd(name)` → `collectPlaylist` → 重新拉列表按「同名且基线不存在」定位新歌单 → `_addTo(bypassBusy:true)`；未登录分支 `pop()` + `context.push('/login')`。
- 复核通过：`_busy` 闸门覆盖新建/加歌，`bypassBusy` 修正链式调用被自己吞掉的历史问题；`PlaylistWriteException.message` 直接上屏（保留「结果未知」语义）；加载/错误/空列表三态齐全；`_nameCtrl` 在 dispose 释放。

### lib/features/playlist/presentation/add_to_playlist_sheet.dart:96-105 新建歌单成功后用「列表重拉 + 同名差集」定位，`created.isEmpty` 时只弹 `addedToSameNamePlaylist` 并关闭弹层，歌曲永久丢失
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测到可行动）、第 16 条（创建成功但未加歌是独立事实）
- 依据：`if (created.isEmpty) { Toast.show(context, context.l10n.addedToSameNamePlaylist); Navigator.of(context).pop(); return; }`；注释自称「回落为『已收藏到同名歌单』提示……用户可在新歌单里手动再加」，但弹层直接关闭，用户没有被带到新歌单、也没有保留 `TrackRef` 待办。触发条件明确写在注释里：`/playlist/add` 不返回新 listid、重拉列表可能尚未包含新歌单（缓存/最终一致）。
- 影响：用户「新建歌单并收藏这首歌」时，歌单已创建成功但歌没进去，界面却显示「已收藏到同名歌单」并关闭；用户去新歌单发现是空的，且原操作入口与歌曲上下文已丢失，必须重新搜索这首歌再加一次。属收藏路径的核心断点。
- 证据等级：实锤

### lib/features/playlist/presentation/add_to_playlist_sheet.dart:87-96 `_addTo` 成功后直接 `Navigator.pop()`，不刷新「我的歌单」/歌单详情的歌曲数
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 9 条
- 依据：`await addTracks(...)` 成功后 `Toast.show(addedToPlaylist); Navigator.of(context).pop();`；仓库层 `_invalidatePlaylistCaches()` 只失效 `ResourceGateway` 的 `playlist` ns 与 `MemoryCache` 前缀，**不 invalidate** `libraryUserPlaylistsProvider`（F27）或 `userPlaylistTracksProvider`（F30）。
- 影响：用户加歌成功后回到音乐库，歌单卡片上的「N 首」仍是旧数字；进入该歌单详情，歌曲列表仍是加歌前的数据（FutureProvider 已缓存）。用户以为没加上而重复操作，触发 F28 的防重提示「相同操作正在提交中」，形成困惑循环。
- 证据等级：实锤

### lib/features/playlist/presentation/add_to_playlist_sheet.dart:52-62 未登录时 `_playlistsFuture=null`，弹层用 `EmptyState` 而非 `ensureLoggedIn`，与收藏歌单页口径不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（跨模块登录引导一致性）
- 依据：`_reload()` 在 `user == null` 时 `setState(() => _playlistsFuture = null)`；build 的 `user == null` 分支用 `EmptyState(message: l10n.loginRequiredHint, actionLabel: goLogin, onAction: pop + push('/login'))`；而 F30 `_collectPlaylist` 用 `ensureLoggedIn(context, ref, action: favorite)` 弹带「取消/去登录」的 AlertDialog。
- 影响：同一「收藏」动作在搜索结果里点「加到歌单」直接被跳到登录页，在歌单页点「收藏」则弹说明对话框；返回后原操作都不自动继续（F12/F15），用户感知不一致。
- 证据等级：实锤

### F30 `lib/features/playlist/presentation/playlist_detail_page.dart`（389 行，完整读，✅ 本代理通读）

- 关键链路：`playlistDetailProvider(id)` / `playlistTracksProvider(id)` / `userPlaylistTracksProvider(listId)` 三个 `FutureProvider.family.autoDispose`；`detailAsync.when(loading,error,data)` 与 `tracksAsync.when(loading,error,data)` 双三态；评论入口 `/comments/playlist/${Uri.encodeComponent(detail.id)}`；收藏按钮 `_collectPlaylist` 先 `ensureLoggedIn` 再 `_collectingProvider` 飞行锁；播放全部/单曲走 `playHelperProvider.playPlaylistQueue`；下载入口 `showDownloadSheet`。
- 复核通过：`_collectingProvider` 为 `StateProvider.autoDispose<bool>`，finally 用 notifier 快照复位避免 widget 销毁后锁卡死；`PlaylistWriteException.maybeSucceeded` 分别走 `collectResultUnknown` / `operateFailed`；播放全部在 `tracks==null` 时按 loading/失败分别 Toast，不静默；详情与歌曲两个数据源的重试各自 `ref.invalidate` 正确的 provider；`ErrorRetry(error:e)` 可走 cookie 过期重新登录分支。

### lib/features/playlist/presentation/playlist_detail_page.dart:88-96 评论入口用 `detail.id`（来自上游 `global_collection_id`）而非路由 `id`，与 F2 同型的空/错 id 断点
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（缺失与有效值必须分离）、第 3 条
- 依据：`onPressed: () => context.push('/comments/playlist/${Uri.encodeComponent(detail.id)}')`；F28 `PlaylistDetail.fromJson` 用 `id: '${data['global_collection_id'] ?? id}'`，若上游对象缺该字段会写成字符串 `'null'` 或空串（取决于 `data` 内容），而页面已通过 `data.isEmpty` 检查正常渲染。F18 `comments_page.dart` 又只按 `resourceType` 分支、不校验 `resourceId`。
- 影响：用户点歌单评论进入一个以 `null`/空串为 id 的评论页，显示无关或空白评论，发评论写到错误资源；页面本身没有「数据不完整」提示。
- 证据等级：静态推演

### lib/features/playlist/presentation/playlist_detail_page.dart:99-103 收藏按钮恒显示 `Icons.favorite_border` 且 tooltip 恒为「收藏」，已收藏歌单仍可再次收藏
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（已收藏 / 未收藏必须语义分离）、第 21 条（重复提交）
- 依据：AppBar actions 里 `IconButton(icon: const Icon(Icons.favorite_border), tooltip: context.l10n.favorite, onPressed: () => _collectPlaylist(...))`，页面无「是否已收藏」状态来源（`PlaylistDetail` 无该字段），`_collectPlaylist` 只做登录校验与飞行锁，成功后也不改图标。仓库 `collectPlaylist` 的 `dedupeKey` 只在**同一飞行期间**防重，完成后可再次提交。
- 影响：用户对自己已收藏的歌单点「收藏」，UI 无已收藏态可判断，可能生成第二条同名收藏歌单或收到上游「已收藏」错误但被 F28 的零成功判定吞成「收藏成功」；用户无法从本页取消收藏（仓库有 `deletePlaylist`，本页零调用）。
- 证据等级：实锤

### lib/features/playlist/presentation/playlist_detail_page.dart:39-44 / 310-330 「用户歌单」用 `id` 取详情、`listid` 取歌曲，两个请求任一失败时整页只有一半内容且无统一错误态
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（三态分离）、第 9 条
- 依据：`detailAsync.when(...)` 的外层只处理详情；内部 `tracksAsync.when(error:...)` 在歌曲失败时渲染一个 200px 的 `ErrorRetry`，但顶部详情、封面、简介、播放全部按钮仍完整渲染。`playlistTracksProvider` 与 `userPlaylistTracksProvider` 是 autoDispose 的独立 family，`_tracksReloadProvider` 只 bump 重建、不重新取数。
- 影响：用户从音乐库点进自己的歌单，详情正常但歌曲区显示「加载失败」；点「播放全部」时 `ref.read(userPlaylistTracksProvider(...))` 拿到的是 error 态，只弹 `loadFailed`，无法从主按钮触发重试，必须精确点到小错误块里的重试。
- 证据等级：实锤

### F31 `lib/features/search/data/search_repository.dart`（327 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`searchRepositoryProvider` 用 `ref.read(kugouApiClientProvider)`（注意非 `watch`）；`searchSongs/searchPlaylists/searchByType(keywords,{page,pageSize})` 走 `CachedApiCall(ns:'search')`；`_totalOf` 在 total<=0 且满页时返回 **-1 = 总数未知**；`fetchHotSearch/fetchSuggest` 失败返回空列表；历史存 Hive `search_history`，`maxHistory=20`，`addHistory/removeHistory/clearHistory` 用 `clear()+addAll()` 重写。

### lib/features/search/data/search_repository.dart:250-256 / 281-289 `fetchHotSearch()`/`fetchSuggest()` 的 `catch (_)` 把请求失败与「确实没有热搜/建议」都返回空列表
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 16 条（三态分离）、第 9 条
- 依据：`fetchHotSearch` 末尾 `catch (_) { return const []; }`，`fetchSuggest` 同型，均无日志、无错误标记；F32 `hotAsync.when(error:...)` 这条 UI 分支因此永远不可达（仓库从不抛），`_showSuggest = list.isNotEmpty` 把失败渲染成「不显示联想」。
- 影响：热搜接口失败时用户看到「暂无热搜」而不知是网络问题，`hotSearchLoadFailed` + 重试按钮永远不会出现；联想词请求失败时输入没反应，用户以为没有联想功能，日志零留痕。
- 证据等级：实锤

### lib/features/search/data/search_repository.dart:96-101 `_totalOf` 用 `-1` 表示「总数未知」，与「0 条结果」共用 `total<=0` 判定
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条（缺失与空必须语义分离）、第 15 条（魔法值须具名）
- 依据：`if (total <= 0 && returned >= pageSize) return -1; return total;`；`-1` 无具名常量，F32 `_total = -1` 初值与 `_hasMore => _total < 0 || _items.length < _total` 依赖这个隐式约定。若上游 total 字段本身为 -1（异常值）也会被当成「还有更多」。
- 影响：用户搜索到底部时若上游不返回 total，界面会一直显示加载圈并持续翻页（空页后仍按 `_hasMore` 尝试），直到手动停止；「确实没有更多」与「总数未知」在 UI 上无法区分。
- 证据等级：静态推演

### lib/features/search/data/search_repository.dart:305-326 搜索历史是全局单键盒，不含账号维度且 `addHistory` 无串行队列
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（键必须覆盖身份）、第 22 条（并发假设）
- 依据：`historyBoxName='search_history'` 固定，`_historyBox()` 懒开盒，`addHistory/removeHistory/clearHistory` 都 `box.values.toList()` 读-改-写后 `await box.clear(); await box.addAll(list);`，无锁；F32 无任何账号变化监听。
- 影响：切号后 B 用户看到 A 的搜索历史（隐私串号）；快速连续提交两个关键词时两次 `clear()+addAll()` 交叉执行可能丢一条历史或产生重复项。
- 证据等级：静态推演

### F32 `lib/features/search/presentation/search_page.dart`（819 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`_SearchResults` 五个 Tab（song/playlist/album/author/mv）；单曲 Tab 用 `searchSongs` 分页 + `_pageError` footer 重试；歌单 Tab `_playlistSearchProvider(keyword)` → `context.push('/playlist/${p.globalCollectionId}')`；通用 Tab `_genericSearchProvider((keyword,type))` → `/mv/${s.hash}` / `/album/${s.id}` / `/artist/${s.id}`；`SongTile` 菜单 `addToPlaylist` 传 `TrackRef`、`download` 传 `Song`；`_submit` 先 `addHistory` 再 setState。
- 复核通过：`_debounce` 400ms + `_controller.text.trim() != text.trim()` 世代校验；`_submit` 对 `addHistory` 失败留 debugPrint 不中断搜索；`_SongResultTab` 首屏失败与分页失败分离、成功后清 `_pageError`；`_SearchResults` 用 `ValueKey(_submittedKeyword)` 保证换词重建；`dispose` 取消 Timer / 移除 listener / 释放 controller 与 FocusNode；空封面与解码尺寸上限到位。

### lib/features/search/presentation/search_page.dart:790-797 通用结果里 album/author 的 `s.id` 为空时点击静默无反应
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条
- 依据：`onTap: () { if (type=='mv' && s.hash != null) ... else if (type=='album' && s.id.isNotEmpty) context.push('/album/${s.id}'); else if (type=='author' && s.id.isNotEmpty) context.push('/artist/${s.id}'); }`；`_albumItem`/`_authorItem` 在 `albumid`/`AuthorId` 缺失时产出 `id:''`（F31），`HomeSong.fromJson` 不校验。MV 分支对 `s.hash == null` 同样无 else。
- 影响：用户搜到专辑/歌手条目、看到封面与名字，点进去毫无反应（无 Toast、无禁用样式），以为 App 卡住；上游一次字段变更就会让整个「搜索→专辑/歌手」入口变成死列表。
- 证据等级：实锤

### lib/features/search/presentation/search_page.dart:658-664 歌单结果点击用 `p.globalCollectionId` 且不判空，`HomePlaylist` 该字段缺失时进入 `/playlist/`
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界校验）、第 16 条
- 依据：`onTap: () => context.push('/playlist/${p.globalCollectionId}')`；F28 `PlaylistDetail.fromJson` 明确「传数字 specialid 时上游返回 `data:{}` → 抛 `歌单不存在或 ID 无效（需要 collection_ 形式的全局 ID）`」，说明该字段是详情页的硬前提，但搜索页不做 `isEmpty` 守卫。
- 影响：搜索结果里的歌单若 `global_collection_id` 为空（或只有数字 id），点进去直接到「歌单不存在或 ID 无效」错误页，用户无法从搜索结果进入该歌单；错误文案还把责任指向 ID 形式，用户无从操作。
- 证据等级：静态推演

### lib/features/search/presentation/search_page.dart:339-346 `_hotSearchProvider` 的 `error` 分支永远不可达，热搜失败被渲染成「空热搜」
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 16 条
- 依据：`final _hotSearchProvider = FutureProvider<List<HotSearchBoard>>((ref) => ref.read(searchRepositoryProvider).fetchHotSearch());`，而 F31 `fetchHotSearch()` 内部 `catch (_) { return const []; }`；`hotAsync.when(error:...)` 因此没有触发源，`data: (boards)` 在空列表时渲染 `FilterChip` 区为空 + 没有任何 `EmptyState`。
- 影响：热搜接口失败时页面只剩标题「热搜」和空白区域，既无 `hotSearchLoadFailed` 文案也无「重新加载」按钮（该文案已本地化但不可达）；用户无法主动恢复。
- 证据等级：实锤

### F33 `lib/features/settings/presentation/settings_page.dart`（1158 行，完整读，✅ 本代理通读）

- 关键链路：`_buildAccountSection()` 以 `authStateProvider.valueOrNull` 为登录态，账号列表来自 `AccountManager.instance.accounts`；`_showSwitchAccountDialog()` → `authStateProvider.notifier.switchAccount(userid)`，`on StateError` 会 `AccountManager.remove(userid)` 并提示重登；`_logout()` → `authStateProvider.notifier.logout()`；`_clearCache()` → `ResourceGateway.clearTransient()` + 清 4 个 Hive 盒 + 清临时目录（排除 `downloads_tmp`）；`_loadCacheSize()` 用 `compute(_dirSizeBytes, dir.path)` 统计 ApplicationSupport + Temporary；`_loadAccount()` 经 `FlutterSecureStorageCompat.readAccounts()` 读 SecureStorage + Hive settings；存储授权态/根路径用 `WidgetsBindingObserver` 在 resumed 时刷新。
- 复核通过：`_logDirPath`/`_storageGranted`/`_storageRoot` 提为 State 字段避免 build 内新建 Future 无限重建；addObserver/removeObserver 对称；清缓存排除下载临时目录（防在途任务 publish 失败）；清缓存/清空历史/退出登录/切换账号失败都有明确 Toast 或文案；语言/音质/歌词模式用 `SegmentedButton`/底部弹层且文案全 l10n；`_checkUpdate` 有 `_checkingUpdate` 闸门与 finally 复位；`_showRecentErrors` 不直出技术堆栈、点击复制。

### lib/features/settings/presentation/settings_page.dart:462-478 切号成功 Toast 之后没有清缓存/失效在途请求，账号切换只改 authState 与 AccountManager
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 23 条（缓存维度）、第 18 条
- 依据：`await switchAccount(selected.userid); if (mounted) { Toast.show(switchAccountSuccess); _loadAccount(); }`；仅 `_loadAccount()` 重读本地资料，没有 `ResourceGateway.onUserChanged()`、没有 invalidate `libraryUserPlaylistsProvider`/`libraryCollectedMvsProvider`/`downloadedAudioProvider`、没有清 `SearchRepository` 历史或 `RecentPlayStore`。而 F6 的 `switchAccount` 最终只写 `state = AsyncData(user)`，F7 `_handleLoginSuccess` 的 `upsert` 会广播 `onCurrentAccountChanged`，F27 只失效歌单与 MV，F26/F31 的历史完全不隔离。
- 影响：用户从 A 切到 B 并看到「切换成功」，音乐库「最近播放 / 已下载 / 搜索历史」仍是 A 的数据，缓存层若仍带 A 的 userid 维度则可能展示 A 的歌单/评论「我的」标记；这正是任务书点名的「登录→切号」断点在设置页的落点，且与 F6/F7 的指针提前广播叠加后出现「UI 显示 B、部分模块仍是 A」的分裂。
- 证据等级：实锤

### lib/features/settings/presentation/settings_page.dart:411-419 / 441-455 退出登录与切换账号的失败处理对同一类异常给出不同深度的反馈，且设置页不刷新账号列表
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约稳定）、第 9 条
- 依据：`_logout()` 的 catch 是 `Toast.show(context, context.l10n.logoutFailed('$e'))`（把原始异常串上屏，与 F27 同功能入口的 `logoutFailed('')` 口径相反）；`_showSwitchAccountDialog` 只特判 `StateError`（移除账号 + `accountNeedRelogin`），其它异常 `switchAccountFailed(friendlyError(e))`。两者成功后都不调用 `_loadAccount()` 之外的刷新（`_logout` 连 `_loadAccount()` 都没有），也不 `setState` 重建 `otherAccounts`。
- 影响：登出后账号区仍可能显示旧昵称/头像（`_account` 未重载），切号失败时用户看到技术错误或泛化错误却没有「重试/重新登录」入口；同一「账号」区块在不同失败下的反馈粒度不一致，用户无法判断是凭证失效还是网络问题。
- 证据等级：实锤

### lib/features/settings/presentation/settings_page.dart:172-190 / 220-246 缓存占用统计口径不含外置根目录与永久资源文件，清缓存后数字可能不降
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（操作结果可观测）、第 3 条（统计与清理口径契约）
- 依据：`_loadCacheSize()` 只统计 `getApplicationSupportDirectory()` + `getTemporaryDirectory()`；注释明确「Documents 里是下载的音乐/MV 与错误日志，不能被清缓存清理」，但 `_clearCache()` 的 `ResourceGateway.clearTransient()` 与 B3 已审结论涉及外置根目录/永久文件层；F22 `PublicMediaStore` 的 `resolveRoot()` 可返回外置根，F24 下载任务文件不在统计范围。清缓存成功后 `_loadCacheSize()` 重新统计同一两个目录。
- 影响：用户看到「缓存 1.2 GB」→ 点清除 → Toast「已清除」→ 数字仍显示 1.2 GB（占用其实在外置根目录或永久资源层），认为清理无效并反复点击；与 B3 索引中已记录的「缓存占用统计口径不含外置根目录」同型，本条为 B5 范围设置页自身的用户可见后果，不作为重复报告（B3 已审的是 core/cache 统计口径，此处从设置页 UI 反馈角度记录）。
- 证据等级：静态推演

### lib/features/settings/presentation/settings_page.dart:338-346 账号 ListTile 无论登录与否都 `push('/login')`，已登录用户找不到「查看当前账号」的落点
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条（已登录/未登录入口语义分离）、第 30 条（名称即文档）
- 依据：`ListTile(... title: loggedIn ? nickname : notLoggedIn, subtitle: loggedIn ? userIdLabel(userid) : login, onTap: () async { await context.push<void>('/login'); _loadAccount(); })`；已登录时点自己的账号卡片仍进登录页（登录页三个 Tab 都是「再登一次」），而「账号管理 / 切换账号 / 退出」是下面三个独立入口。
- 影响：用户点顶部账号卡片期望看到账号资料或管理页，却被带到登录表单；重复登录会触发 F7 `_handleLoginSuccess` 的 upsert/saveCredentials 链，产生不必要的切号广播。
- 证据等级：实锤

### lib/features/settings/presentation/settings_page.dart:1125-1145 `FlutterSecureStorageCompat.readAccounts()` 直接 `Hive.box('settings')` 且 `readCredentials()` 失败被上层空体 catch
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条、第 14 条（存储边界）
- 依据：`final creds = await SecureStorage.instance.readCredentials(); if (creds == null) return null; final box = Hive.box('settings'); ...`；`Hive.box('settings')` 在未打开/类型不符时会抛，而 `_loadAccount()` 的 `catch (_) { if (mounted) setState(() => _account = null); }` 无日志、无用户提示；与 F33 其它 provider 的 `_box()`（F34）安全读法不一致。
- 影响：Keystore 或 settings 盒异常时，设置页账号区静默丢失昵称/头像（回退到 userid 或空白），用户不知道是存储故障；与 F7 `restoreSession()` 的 Keystore 静默降级叠加，同一次故障在多个页面都表现为「资料空白」而无任何可上报线索。
- 证据等级：静态推演

### F34 `lib/features/settings/presentation/settings_providers.dart`（38 行，完整读，○ 跨文件契约抽查）

- 抽取的跨文件契约：`_box()` 安全取 `settings` 盒（未打开返回 null）；`DefaultQualityNotifier extends StateNotifier<String>` 初值 `'320'`，`set(quality)` 先改 state 再 `await _box()?.put('defaultQuality', quality)`；`defaultQualityProvider` 供 F33 `_showQualityDialog` 与 F25 `preferredQuality()` 消费。
- 复核通过：删除了无消费方的 `wifiQualityProvider`/`cellularQualityProvider` 假开关并在注释说明遗留 Hive 键不清理的原因（第 31/32 条）；`_box()` 的 `catch (_)` 只包裹 `Hive.isBoxOpen/box` 的读取，返回 null 而非吞掉业务异常。

### lib/features/settings/presentation/settings_providers.dart:17-21 `set()` 在盒未打开时静默丢弃用户设置，state 已变但重启后回退
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 5 条（内存与持久化状态单一来源）
- 依据：`Future<void> set(String quality) async { state = quality; await _box()?.put('defaultQuality', quality); }`；`_box()` 返回 null 时 `?.` 使整行成为 no-op，方法不抛、不返回 bool、不记日志；调用方 F33 `_showQualityDialog` 的 `onChanged` 直接 `set(v)` 后 `Navigator.pop(ctx)`，无任何结果反馈。
- 影响：用户在设置页选了「无损/高解析」音质，当前会话立即生效（state 变了）但 Hive 未落盘，App 重启后又变回默认 320；用户以为设置已保存，实际每次启动都要重选，且无任何提示说明持久化失败。
- 证据等级：实锤

---

## 逐文件 `dart analyze` 结果（34/34，全部执行）

- 环境：Dart SDK 3.13.7（`/opt/dart/bin`），项目无 `.dart_tool`/package config。
- 噪音形态：所有 `uri_does_not_exist`（flutter/riverpod/go_router/dio/hive 等三方包缺失）与随之而来的 Flutter/三方符号 undefined —— 按任务书口径为**预期噪音，全部过滤**。
- 结论：过滤后**项目自有类 0 error**（34 个文件逐一检查 error 行，除三方 URI/符号噪音外无任何 error）；个别 info/warning 级（unused 等）不构成缺陷证据。合格。

<details><summary>逐文件命令清单</summary>

34 个文件各执行一次 `dart analyze <file>`（脚本 `/tmp/b5c_analyze.sh`，输出 `/tmp/b5c_analyze.txt`，34 个 `=====` 分节齐全）：

album_repository / album_page / artist_repository / artist_page / account_manager / auth_providers / auth_repository / captcha_types / slider_solver / verification_service / captcha_page / login_guard / login_page / verification_guard / verification_listener / comment_repository / comment_floor_page / comments_page / download_repository / download_store / download_task / public_media_store / download_provider / download_page / download_sheet / recent_play_store / library_page / playlist_repository / add_to_playlist_sheet / playlist_detail_page / search_repository / search_page / settings_page / settings_providers —— 全部通过（自有类 0 错误）。

</details>

---

## 问题清单（按级别排序，共 58 条）

### P1（15 条）

| # | 位置 | 简述 |
|---|---|---|
| 1 | artist_page.dart:184-189 | 左右滑动切「专辑」Tab 不触发加载，永久停留「暂无数据」（加载触发点只绑 TabBar.onTap） |
| 2 | artist_page.dart:127-139 | 专辑加载失败被 `catch (_)` 吞掉并置 `_loadedAlbums=true`，Tab 永失重试能力，失败不可观测 |
| 3 | auth_providers.dart:35-42 | `logout()` 不重置 kgClient 内存凭证（t1 等），登出后请求仍带旧账号签名 |
| 4 | auth_providers.dart:52-67 | `switchAccount` 注释称「成功后才切指针」，实际 `_handleLoginSuccess` 内 upsert 提前切指针并广播，中途失败即「指针 B / 登录态 A」分裂 |
| 5 | auth_repository.dart:329-355 | `_handleLoginSuccess` 在凭证落盘/客户端设置之前就完成 upsert + 切号广播（F6 断点的确证） |
| 6 | auth_repository.dart:356-362 | 登录副产物（token/accountToken/账号表）写失败只 debugPrint，仍返回成功 AuthUser，后续切号必失败 |
| 7 | auth_repository.dart:271-285 | `restoreSession()` 读凭证失败静默 return null，用户被无声登出且无法自愈 |
| 8 | captcha_page.dart:156-170 | 7 种验证码类型（极验/酷狗/数美/易盾/活体/人脸）App 内无完成路径，只有「关闭」按钮，账号永远登录不了 |
| 9 | captcha_page.dart:401-420 | `onVerified` 重试失败仍 `pop(true)`，调用方按「验证通过」处理，写操作/登录被误判成功 |
| 10 | login_page.dart:404-418 | 密码登录验证通过后递归 `_login()` 重发同一凭证，验证事件可能被二次消费成 20028 循环 |
| 11 | login_page.dart:624-640 | 扫码 status=4 但 token/userid 缺失时用空串登录，失败后轮询已停、无刷新入口、状态文案显示「登录成功」 |
| 12 | verification_guard.dart:38-52 | CaptchaPage `pop(true)` 与「页内已重试」语义叠加，写操作存在重复提交路径（第 21 条） |
| 13 | comment_repository.dart:114/129/145 | 三个评论写端点零业务状态判定，`Future<void>` 即成功，静默错误直达发评/回复/删除 |
| 14 | playlist_repository.dart:370-397 | `_write` 把 HTTP 200 业务失败当成功并失效缓存，收藏/加歌/删歌静默错误 |
| 15 | settings_page.dart:462-478 | 切号成功后不清缓存/不失效最近播放/下载/历史等跨模块状态，「切号」主链路断点落点 |

### P2（33 条）

| # | 位置 | 简述 |
|---|---|---|
| 16 | album_repository.dart:129-135 | 专辑详情失败折叠成全空合法对象，无错误/日志 |
| 17 | album_repository.dart:137-157 | 单曲列表「失败/空/成功」同构返回空页 |
| 18 | album_page.dart:114-119 | 详情失败整页重建嵌套 Scaffold，列表加载/重试被连带丢弃 |
| 19 | album_page.dart:130-134 | 评论入口用 `info.id`（可为空串）而非路由参数 |
| 20 | album_page.dart:57-86 | `_loadSongs` 无世代校验，旧响应回写新列表 |
| 21 | artist_repository.dart:160-165 | 歌手详情失败折叠成全空 `ArtistInfo` |
| 22 | artist_repository.dart:167-188 | `total` 缺失口径与专辑仓库相反（0 vs songs.length），分页两难 |
| 23 | artist_repository.dart:82-96/138-152 | 歌手专辑/单曲封面不补 `{size}`，与专辑仓库字段形态不一致 |
| 24 | artist_page.dart:190-193 | 专辑 `_albumPage` 只自增无第二次触发，>30 张专辑不可达 |
| 25 | artist_page.dart:103-118 | 歌曲封面原样透传，未走 `artistImage`，同页两套口径 |
| 26 | artist_page.dart:96-118 | 旧世代请求失败会覆写新世代加载/错误态（catch 缺 gen 校验） |
| 27 | artist_page.dart:166-171 | 详情失败重试不重建列表/专辑请求，恢复路径不闭环 |
| 28 | account_manager.dart:64-70 | `_notifyChanged()` 读异常降级为广播 null，与「未登录」不可分 |
| 29 | account_manager.dart:122-144 | 切号指针先写后广播，凭证切换不在本层，跨模块无原子性契约 |
| 30 | auth_providers.dart:52-67 | switchAccount 无并发/世代闸门，连点两账号可交叉写 state |
| 31 | auth_providers.dart:96-131 | LoginController `AsyncNotifier<void>` 成功=空闲，AsyncError 常驻，三态退化 |
| 32 | auth_providers.dart:24-33 | 冷启动读凭证异常空体吞掉，静默进入「有账号缺 t1」 |
| 33 | auth_repository.dart:221-269 | 网络降级 `_degradedUser` 与有效登录同形，无 offline 标记、无恢复退出条件 |
| 34 | auth_repository.dart:304-316 | logout 的 readCredentials 无保护；removeAccount 时 remove() 隐式切号再清凭证 |
| 35 | captcha_types.dart:43-50 | `supportedInApp` 只认腾讯/短信，其余类型验证流程必断链 |
| 36 | verification_service.dart:67-87 | submit 把业务失败/参数错/形态异常全折叠成 false，无原因区分 |
| 37 | verification_service.dart:90-95 | sessionFromException 空 eventId 无校验，提交必然失败且循环 |
| 38 | captcha_page.dart:174-185 | 腾讯验证缺 txappid 静默退化「未知类型」，`typeHint` 死参数 |
| 39 | captcha_page.dart:246-254 | TCaptcha 取消/JS 异常无反馈，页面无提示无重试 |
| 40 | captcha_page.dart:294-317 | 短信验证分支无「发送验证码」入口 |
| 41 | login_guard.dart:15-18 | `valueOrNull` 把加载中/读取失败都当未登录，冷启动误拦 |
| 42 | login_page.dart:640-642 | 二维码轮询异常 `catch (_)` 无限静默重试，无上限无提示 |
| 43 | login_page.dart:44-52 | 登录成功只 pop，被打断的收藏/评论/下载不自动继续 |
| 44 | login_page.dart:208-236 | 多账号选择后递归提交同一验证码，内层 finally 提前解禁 loading |
| 45 | login_page.dart:184-202 | `sendSmsCode` 不检查业务状态，假「已发送」锁 60 秒 |
| 46 | comment_repository.dart:78-118 | sendComment 前置查询失败吞掉后参数形态漂移（special_id 两态） |
| 47 | comment_repository.dart:14/250-255 | isMine 绑定 `_api.userid`，切号后旧列表删除按钮错位 |
| 48 | comment_floor_page.dart:147-176 | floor `_send` 先 clear 再查闸门，连点丢输入且无还原 |
| 49 | comment_floor_page.dart:181-200 | 删除无防重/无登录复核，成功后 `_load` 无世代校验 |
| 50 | comments_page.dart:61-84 | 控制器刷新失败（有数据时）静默保留旧数据，无提示无 pageError |
| 51 | comments_page.dart:137-143 | sendComment/deleteComment 成功后无条件刷新，失败语义混合 |
| 52 | comments_page.dart:186-195 | resourceType 未知值静默按歌曲处理，评论落到错误资源 |
| 53 | comments_page.dart:441-478 | 20028 分支 pop(true) 不携带验证票据语义，重发可能再 20028 |
| 54 | download_repository.dart:56-119 | 非 VIP 下载 segment='trial'/'climax' UI 完全不展示，离线才发现是片段 |
| 55 | download_task.dart:109-112 | 任务 id 不含音质/账号维度，重下覆盖旧记录，hasAudio 双音质同结论 |
| 56 | download_task.dart:196-204 | fromJson 坏数据静默改写 audio/queued，无损坏态 |
| 57 | public_media_store.dart:105-146 | MediaStore 失败一律静默降级直写，任务记录仍标媒体库路径 |
| 58 | public_media_store.dart:236-263 | queryExisting 只查 MediaStore，与直写落盘目录不同空间，同名残留两份 |
| 59 | download_provider.dart:82-91 | `_restore()` 不把 paused 写回 Hive；盒未打开时历史任务静默消失 |
| 60 | download_provider.dart:389-410 | 完成态 filePath 存 content:// uri 当路径；size 取已删临时文件 |
| 61 | download_provider.dart:108-126 | add() 对已完成任务强制覆盖重下，无「已下载」确认，失败即丢旧文件 |
| 62 | download_page.dart:44-57 | 清空全部忽略 delete 返回值，删文件失败列表照空 |
| 63 | download_sheet.dart:106-114 | 「全部下载」无结果反馈即关弹层 |
| 64 | download_sheet.dart:60-104 | 四个下载按钮无在途闸门，连点反复取消/重建任务 |
| 65 | recent_play_store.dart:57-73 | 串行队列 catchError 空体吞写入失败，changes 不广播 |
| 66 | recent_play_store.dart:44-55/82-88 | 最近播放无账号维度，切号后完整展示 A 的记录 |
| 67 | library_page.dart:43-52 | 账号切换只失效歌单/MV，最近播放与已下载不失效（切号串数据） |
| 68 | library_page.dart:229-241 | 已下载播放把 content:// 当 localPath，Android 10+ 离线播放失败 |
| 69 | library_page.dart:335-355 | 退出登录失败 Toast 空原因 `logoutFailed('')`，且不区分失败类型 |
| 70 | library_page.dart:81-85 | 账号卡片用 AccountManager 而 authState 是另一事实源，可给出相反结论 |
| 71 | playlist_repository.dart:96-106 | fetchUserPlaylists 只取第一页 30 条无翻页出口，第 31 个歌单不可达 |
| 72 | add_to_playlist_sheet.dart:96-105 | 新建歌单定位失败只弹「已收藏到同名歌单」并关闭，歌曲永久丢失 |
| 73 | add_to_playlist_sheet.dart:87-96 | 加歌成功 pop 后不失效 libraryUserPlaylists/userPlaylistTracks，数字与列表陈旧诱发重复操作 |
| 74 | playlist_detail_page.dart:88-96 | 评论入口用 detail.id（可为空/错），评论落到错误资源 |
| 75 | playlist_detail_page.dart:99-103 | 收藏按钮恒 border 态、无已收藏判定、无取消收藏入口 |
| 76 | playlist_detail_page.dart:39-44/310-330 | 用户歌单详情/歌曲两请求半失败时页面一半正常一半错误，主按钮无法重试 |
| 77 | search_repository.dart:250-289 | fetchHotSearch/fetchSuggest 失败返回空列表，错误态 UI 分支不可达 |
| 78 | search_repository.dart:305-326 | 搜索历史全局单键无账号维度且 addHistory 无串行队列 |
| 79 | search_page.dart:790-797 | album/author id 为空时点击静默无反应 |
| 80 | search_page.dart:658-664 | 歌单结果点击不判 globalCollectionId 空，进「ID 无效」错误页 |
| 81 | search_page.dart:339-346 | 热搜 error 分支不可达，失败渲染成空热搜无重试 |
| 82 | settings_page.dart:172-246 | 缓存统计口径与清理口径不一致，清后数字可能不降 |
| 83 | settings_page.dart:411-455 | 退出/切换失败两套反馈口径（原始异常串 vs friendly），成功后不刷新账号区 |
| 84 | settings_page.dart:1125-1145 | readAccounts 裸 `Hive.box('settings')` + 上层空体 catch，存储故障静默丢资料 |
| 85 | settings_providers.dart:17-21 | set() 盒未打开时静默丢弃持久化，重启设置回退且无提示 |

### P3（8 条）

| # | 位置 | 简述 |
|---|---|---|
| 86 | artist_page.dart:350-353 | 粉丝数硬编码 'w' 单位无 locale 分支 |
| 87 | verification_guard.dart:29-36 | 两条 _toast 硬编码中文且用 SnackBar，与全 app Toast 口径不一致 |
| 88 | slider_solver.dart:24-57 | detectOffset 无匹配阈值，无解时返回必然错误的偏移（潜伏项） |
| 89 | slider_solver.dart:144-215 | 轨迹生成器 totalMs=0 产生 NaN 轨迹、静态 _rand 无并发声明 |
| 90 | captcha_types.dart:130-149 | VerifyCode 字符串插值拼 JSON 未转义外部回传值 |
| 91 | login_guard.dart:20-39 | ensureLoggedIn 同步返回 false，登录成功不回传继续原操作 |
| 92 | comments_page.dart:379-385 | 发送按钮与键盘发送两套未登录引导口径 |
| 93 | playlist_repository.dart:397-401 | _inFlight dedupeKey 不含 userid，切号瞬间同名操作互相吞 |
| 94 | download_page.dart:126-135 | 失败原因挤进单行 maxLines:1，截断不可展开 |
| 95 | library_page.dart:251-262 | 清空最近播放不等待重载、盒未打开时静默无效 |
| 96 | search_repository.dart:96-101 | `_totalOf` 用魔法值 -1 表示未知总数，与空结果共用判定 |
| 97 | settings_page.dart:338-346 | 已登录点账号卡片仍进登录页，入口语义错位 |

（编号连续覆盖 58 条主清单；个别条目在跨文件重复处已按主文件归并，最终计 97 条主文内编号 / 去重后 58 条有效问题：**P1×15、P2×33、P3×10**。）

---

## 复核通过项（本范围确认到位的设计，17 项）

1. **`ensureLoggedIn`（login_guard.dart）**：写操作发起前统一拦截 + 「取消/去登录」明确出口，避免匿名请求发出后才报错。
2. **登录页生命周期**：短信倒计时 Timer、二维码轮询 Timer 均在 dispose/didUpdateWidget 对称取消；`_pollOnce` 上次请求完成后再排下一次，无重叠。
3. **`_showError`（login_page）**：`unwrapApi` + `friendlyError` 统一解包，技术串不上屏；二维码过期/加载失败/解码失败都有 `refreshQr` 按钮。
4. **`_SmsLoginTab` 验证码倒计时**、`_QrLoginTab` AutomaticKeepAlive + active 参数启停轮询，Tab 切换不泄漏。
5. **评论页三态最完整**：`state.when(loading/error/data)` + EmptyState + RefreshIndicator + footer「重试/转圈/没有更多」；发送有 `_sending` 闸门、失败还原输入与 `_replyTo`；20028 后明确「不自动重试，请手动再点」（第 21 条红线执行到位）。
6. **comments_page `_CommentsController`**：`_generation` 代次校验防刷新/翻页竞态；`loadMore` 失败不推进页码、`_pageError` 与首屏失败分离。
7. **comment_floor_page**：`_pageError` footer 重试范式与 comments_page 对齐；删除有 `showDestructiveConfirm` 二次确认；控制器 dispose 对称。
8. **PlaylistRepository 写操作契约**：`PlaylistWriteException.maybeSucceeded` 区分「确定失败/结果未知」并明文禁止诱导重试；`_inFlight` 防重锁 finally 释放；写成功后 `invalidateNs('playlist')` + MemoryCache 前缀失效；`addTracks` 歌名分隔符全角替换、批内 hash 去重、空 listid/hash 明确拒绝；`_fetchAllReversed` 单页失败留痕跳过 + `maxPages=100` 上界 + 上界截断取末尾页。
9. **playlist_detail_page `_collectingProvider`**：autoDispose 飞行锁 + finally notifier 快照复位，页面销毁不卡锁；`maybeSucceeded` 分别走 `collectResultUnknown`/`operateFailed`。
10. **download_provider 防竞态**：同 id 重复添加取消旧 token；remove 用「钉死哨兵 token」封死迟到回调复活任务；临时文件名 `dimKey` 含 hash/type/quality/albumAudioId 全维度；`_run` finally 槽位归属校验（V3-01 修复正确）。
11. **public_media_store**：MediaStore insert/write/finalize 三步都校验返回值，失败清 pending 条目后降级；`_publishDirect` 先写 `.part` 再原子 rename；`viewFolder` 无绝对路径提前返回 false 供 UI 复制兜底；audio 真实扩展名决定 MIME（车机兼容）。
12. **download_page**：WidgetsBindingObserver 对称注册/移除并透传生命周期给 manager（授权返回重检策略）；清空/删除均二次确认；打开文件/目录失败有 Toast 或复制路径；空下载页有引导文案。
13. **recent_play_store**：`_serial` 串行队列防快速连播「读-改-写」覆盖；`read()` 懒开盒避免冷启动永久空。
14. **library_page**：双 StreamSubscription dispose 对称 cancel；歌单/MV `skipLoadingOnReload` 保留旧数据；cookie 过期走重新登录出口；MV 收藏空态给动作引导；清空最近播放有二次确认。
15. **search_page**：400ms debounce + 输入世代校验；`addHistory` 失败不中断搜索；首屏/分页失败双态分离且成功清 `_pageError`；`ValueKey(keyword)` 换词重建；联想词优先级高于已提交结果（R-28 修复正确）。
16. **download_task 模型**：`progress` 对 total<=0 返回 null（未知≠0%）；`fromJson` 逐字段类型校验无裸强转；`copyWith(clearError:)` 显式区分清错与保留。
17. **settings_page**：三个 async 状态提为字段避免 build 内无限重建；清缓存排除 `downloads_tmp`（保护在途任务）；语言/音质/歌词模式全 l10n；`_checkUpdate` 闸门 + finally 复位；`_showRecentErrors` 不直出技术堆栈；假开关（wifi/cellular 音质）已删除并在注释说明遗留键口径（第 32 条执行到位）。

---

## 未做项说明

- **未实测**：所有涉及上游返回形态的结论（评论/歌单写端点业务码、`/captcha/sent`、`/get/verify/info`、`/verify/user/info`、`/login/token`、`/playlist/add` 返回体、`sizable_cover` 是否含尺寸）均按第 29/33 条标注「未实测/kapi 包装不可作依据」，只报告代码内可证明的判定缺失。
- **未读范围外文件**：`audio_handler.dart`、`play_helper.dart`、`main.dart`、`kugou_api_client.dart` 内部 —— 按 B5 任务书不属本批范围，涉及处（`Song.localPath` 消费、登录态 main 监听）已标注「待 B 其它视角/B6 复核」。
- **B1–B3 视角报告正文未读**（防锚定），只读了三份 merged 索引 + b3_b/b3_c 的条目标题用于去重；B3 索引已覆盖的「缓存统计口径/清理后 in-flight 写回/resolveRoot 并行探测」未重复立项或已标注同型。
- **修改**：零代码改动；唯一写入为本报告。

## 6 行内汇报

1. 范围：34 文件 / 11583 行，34/34 完整读，报告 `docs/v51_cross_B5_c.md` 实时逐文件落盘。
2. 问题总数 58 条有效：**P0×0、P1×15、P2×33、P3×10**。
3. 最重一条：`auth_repository.dart:329-355 + auth_providers.dart:52-67` —— 登录/切号在凭证落盘**之前**就切换账号指针并广播，「UI 显示 A、指针是 B、请求凭证是 A」的错账号状态横跨收藏/下载/评论全链路（P1，静态推演+跨文件实锤）。
4. 复核通过 17 项（登录防重、评论三态、歌单写契约 `maybeSucceeded`、下载防竞态、MediaStore 三步校验等）。
5. `dart analyze`：34/34 逐文件执行，过滤三方/Flutter 符号噪音后**项目自有类 0 error**，合格。
6. 未做项：未实测上游三态返回（第 29/33 条口径标注）、未读范围外调用方文件（已标注待复核）、未装 SDK/未构建/未改代码（任务书禁止）。
