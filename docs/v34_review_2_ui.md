# v3.4 审查②：UI 专档——细节处理与易用性

基线 ac188b2 (v3.3.0)。审查纪律：逐文件完整阅读；只读；问题可指回 QUALITY_STANDARD 或标注「易用性：任务流 X」。

## 审查记录

### full_player_page.dart:<~171> 封面/歌词切换：切回封面无动画重置，手势与按钮行为不一致
- 级别：P3
- 事实：onTap 与 TextButton 两个入口切换 _showLyric 时，仅进入歌词模式执行 `_fadeCtrl.forward(from: 0)`；切回封面只有 AnimatedSwitcher 300ms 淡切。两处逻辑重复维护，若日后只改一处会出现手势/按钮行为分叉。
- 违反：第 1 条（单一职责）/动效一致性（本档维度 A）
- 后果：轻微；当前一致，属可维护性隐患。

### full_player_page.dart:<_MvEntry> songMvProvider 阻塞评论入口渲染条件
- 级别：P2
- 事实：评论按钮虽然不再被 MV early-return 连带隐藏（已修 UI-04），但整行 `if (albumAudioId.isEmpty) return SizedBox.shrink()` —— 歌曲 albumAudioId 为空时评论入口也消失；且 mv 查询在异步期间行内只有评论按钮，MV 按钮加载完成后突然插入，布局跳动（无 AnimatedSize/占位）。
- 违反：易用性：任务流 4（MV 入口可达性）；动效一致性（插入无过渡）
- 后果：MV 查询慢的设备上点开播放页瞬间按钮「跳出来」，误触风险；albumAudioId 缺失歌曲失去评论入口。

### full_player_page.dart:<_ProgressBar:496> 拖动进度条时时间标签仍显示旧 position
- 级别：P3
- 事实：滑块 value 用 `_dragMs`，但下方时间标签直接渲染 `position` 流；拖动中滑块位置与左端时间文本不一致（UI-05 只修了一半）。
- 违反：易用性：细节处理（反馈一致性）
- 后果：拖动时用户看到滑块在 3:20 而标签停在 1:05，短暂困惑；松手恢复。
### mini_player.dart:<~148> 迷你播放器塞 3 个 IconButton，48dp 触控目标挤压文本区
- 级别：P2
- 事实：64 高的 MiniPlayer 内并排 IconButton.filled + 两个默认 IconButton（各 48dp 宽），加上 44 封面与间距，歌名可用宽度被压到很窄，长标题几乎必然截断；三个相邻按钮之间无额外间距，误触面大。
- 违反：触控目标/误触面（本档维度 A）；第 24 条无关。
- 后果：长歌名只剩几个字符；横屏/小屏设备上点「下一首」易误触「队列」。

### mini_player.dart:<_MiniPlaceholder> 硬编码 Colors.grey 绕过主题
- 级别：P3
- 事实：`color: Colors.grey` 未用 colorScheme token；同文件其它占位/图标均走 onSurfaceVariant。
- 违反：颜色 token（本档维度 C）
- 后果：暗色主题下占位图标灰度不随主题调整，视觉不齐。
### queue_sheet.dart:<~85> 队列表头文案用 nowPlaying 而非 playQueue，语义错位
- 级别：P3
- 事实：队列弹层标题渲染 `context.l10n.nowPlaying`（「正在播放」），但这是播放队列面板；l10n 已有 playQueue 键。
- 违反：微文案（本档维度 A）；第 30 条
- 后果：用户看到的标题与入口语义不一致。

### queue_sheet.dart:<~100> 打开队列不自动滚动到当前曲目
- 级别：P2
- 事实：ListView.builder 无 initialScrollOffset/controller，队列长时当前曲目可能在屏幕外，用户需手动翻找；当前曲目仅靠 selected 颜色区分。
- 违反：易用性：任务流（播放反馈）
- 后果：长队列下「当前在哪首」不可见，需滚动寻找。

### queue_sheet.dart:<_QueuePlaceholder> 硬编码 Colors.grey
- 级别：P3
- 事实：同 mini_player 问题，绕过主题 token。
- 违反：颜色 token（维度 C）
- 后果：暗色主题占位图标不协调。
### lyric_view.dart:<~152> 空态文案硬编码中文「暂无歌词」，未走 l10n
- 级别：P2
- 事实：`lines.isEmpty` 时渲染字面量 `'暂无歌词'`，全 app 其它文案均走 context.l10n；英文界面下歌词空态仍显示中文。且文案只说「没有」，未告诉用户原因/下一步（易用性任务流 5：空态指引）。
- 违反：第 30 条/微文案；易用性：任务流 5
- 后果：英文用户看到中文；纯音乐与解析失败无法区分。

### lyric_view.dart:<~250> 歌词行 onTap 无任何点击反馈（无水波纹/高亮）
- 级别：P3
- 事实：_LyricLineTile 用裸 GestureDetector（opaque），无 InkWell/Ripple；相邻列表项（queue_sheet 用 ListTile 有水波纹）行为不一致。
- 违反：动效一致性/水波纹全员覆盖（维度 A）
- 后果：点击歌词行 seek 成功但无视觉确认，用户不确定是否点中。

### lyric_view.dart:<~186> 手动滚动后自动跟随暂停仅 5 秒，且无「回到当前行」按钮
- 级别：P3
- 事实：用户翻看历史歌词 5 秒后视图突然自动滚回当前行（animateTo 300ms），期间无任何提示或跳回入口；用户正在阅读时被打断。
- 违反：易用性：细节处理（手势反馈可预期）
- 后果：阅读体验被打断；这是「暂停跟随」方案下常见的突兀回跳。
### splash_screen.dart / splash_handwriting.dart 手写动画极端行为回归：结论——安全
- 级别：无问题（回归记录）
- 事实：控制器在 State.dispose 对称释放；快速返回/立刻切深链导致 splash 被移除时，Route 离屏后 TickerMode 置 disabled，`repeat()` 停帧；painter 每帧零重建（repaint 直挂 controller），路径度量缓存一次。`HandwritingCycle.minVisible` 已定义供调用方保证最短可见时长。
- 违反：无
- 后果：无；极端行为下无泄漏、无重建风暴。

### splash_handwriting.dart:<24> 默认 label 硬编码中文「汀澜音乐」
- 级别：P3
- 事实：`this.label = '汀澜音乐'` 默认值为中文字面量，依赖调用方传 l10n 覆盖；若任一调用点漏传，英文环境显示中文品牌名。
- 违反：第 2 条（显式优于隐式）/微文案
- 后果：潜在文案漏翻；需核对 main.dart 传参（见任务流走查）。
### home_page.dart:<~118> Banner 轮播可点击但无任何 onTap
- 级别：P2
- 事实：_BannerCarousel 的 PageView item 只是 CachedNetworkImage + ClipRRect，无 InkWell/GestureDetector。用户看到横幅图默认可点（全行业惯例），点击无反应也无反馈。若数据中 banner 确无跳转链接，则应不展示或展示引导文案。
- 违反：易用性：任务流 5（可预期交互）；手势反馈（维度 A）
- 后果：用户点 banner 无反应，误以为卡死/未登录。

### home_page.dart:<~430 _RankRow> 排行榜卡标题用硬编码 Colors.white/Colors.black87
- 级别：P3
- 事实：渐变底部遮罩 `Colors.transparent, Colors.black87` 与文字 `Colors.white` 硬编码，绕过主题 token。同类卡片（歌单卡）文字用 theme.textTheme。
- 违反：颜色 token（维度 C）
- 后果：深浅色一致性依赖遮罩效果，token 漂移无感知。

### home_page.dart:<~229 每日推荐卡> 播放整组队列后 push /player，但卡上无「正在播放」状态反馈
- 级别：P3
- 事实：每日推荐/新歌 tile 点击即播放并跳播放页，反馈充分（跳页即反馈），可接受；但 banner 之外的 PlaylistRow 点击无效 id 时 Toast「即将可用」是好的微文案范例。无新问题，仅记录。
- 违反：无（正面记录）
- 后果：无。
### search_page.dart:<~690 _GenericResultTab.onTap> 条目不可跳转时静默无反应
- 级别：P2
- 事实：专辑/歌手/MV 结果 onTap 只在 `s.hash != null` / `s.id.isNotEmpty` 时 push；条件不满足时整个 onTap 直接 return，无 Toast、无禁用态、无视觉区分。数据层缺字段的条目在界面上与正常条目一模一样，点了没反应。
- 违反：第 9 条（失败必须可观测）/易用性：任务流 1
- 后果：用户点击无反应，反复点击，判定 App 坏了；正确做法是不可跳转项禁用视觉或 Toast 说明。

### search_page.dart:<~200> 联想词出现后无「返回历史/落地页」的路径提示，建议列表覆盖已提交结果无过渡
- 级别：P3
- 事实：_showSuggest 直接条件切换三个视图，无 AnimatedSwitcher；且联想态下用户之前的搜索结果被整体替换，只能再点一次提交恢复。体验可接受但切换突兀。
- 违反：动效一致性（维度 A）
- 后果：视图硬切，轻微。

### search_page.dart:搜索→播放→收藏任务流走查结论（见文末表）
- 级别：记录
- 事实：搜索结果 SongTile 无「收藏/添加到歌单」菜单项，只有 download。播放页有评论/MV 入口但**全屏播放页没有任何「收藏到歌单」按钮**（见 full_player_page 全文核实：顶部菜单只有 download/queue，控制区只有 shuffle/prev/play/next/repeat）。
- 违反：易用性：任务流 1
- 后果：「搜索一首歌 → 收藏到歌单」必须退出播放页去找入口（如库页长按），断点严重；详见走查表。
### library_page.dart:<~155> 歌单加载失败时 ErrorRetry 无登录态区分
- 级别：P3
- 事实：`playlistsAsync` error 分支直接渲染 _PlaylistRowError（重试），未区分「登录态中途失效/cookie 过期」与普通网络错误；第 16 条要求未登录与失败语义分离——登录态在 UI 有 account!=null，但服务端 401 时界面仍引导「重试」而不是「重新登录」。
- 违反：第 16 条 / 易用性：任务流 3
- 后果：cookie 过期用户点「重试」永远失败，没有「去登录」出口。

### library_page.dart:<~380 _MyPlaylistRow> 歌单卡点击用裸 GestureDetector，无水波纹
- 级别：P3
- 事实：我的歌单横排卡用 GestureDetector，而首页 _PlaylistRow 用 Material+InkWell（有水波纹）。同类交互两页反馈不一致。
- 违反：动效一致性（维度 A）
- 后果：库页点歌单卡无按压反馈。

### library_page.dart:<~365 收藏 MV 空态> 空态文案用通用 noData
- 级别：P3
- 事实：`list.isEmpty` 时 message: context.l10n.noData（「暂无数据」），未说明「在 MV 播放页点收藏即可加入」，其它区块空态均有引导（未登录有引导卡、下载有空态+管理入口）。同时 `mv.hash.isEmpty` 时 onTap 直接 return，无反馈（同 search_page 问题）。
- 违反：易用性：任务流 5、任务流 4
- 后果：用户不知道如何收藏 MV；坏数据 MV 点击无反应。

### library_page.dart:<~490 账号卡片> 登录态感知良好（正面记录）
- 级别：记录
- 事实：账号卡片常显于库页顶部，显示昵称+userid， PopupMenu 提供账号管理/退出；切换账号后歌单与收藏 MV 均 invalidate。任务流 3「哪里知道自己是哪个号」满足。
- 违反：无
- 后果：无。
### playlist_detail_page.dart:<~285> 播放全部按钮在曲目为空/未加载时静默无反应
- 级别：P2
- 事实：FilledButton「播放全部」`if (tracks != null && tracks.songs.isNotEmpty)` 才播放；tracks 未加载或为空时点击无任何 Toast/禁用。曲目还在加载时用户点按钮 → 无反应。
- 违反：第 9 条 / 易用性：任务流 1
- 后果：进入歌单立刻点播放全部 → 无反应，用户重复点击。

### playlist_detail_page.dart:<~115> 收藏歌单按钮无选中态
- 级别：P2
- 事实：IconButton 永远显示 `Icons.favorite_border`（未选中样式），无论该歌单是否已收藏；本页没有任何「是否已收藏」状态查询。用户无法知道自己是否已收藏过，重复收藏只能靠服务端报错。
- 违反：第 5 条（状态单一来源）/易用性
- 后果：已收藏的歌单仍显示空心爱心，点击后再收藏一次。

### playlist_detail_page.dart:<~370> 收藏失败 catch-all 把原始异常文本拼进 Toast
- 级别：P3
- 事实：`Toast.show(context, context.l10n.operateFailed('$e'))` —— 通用 catch 把 `'$e'`（可能是英文堆栈摘要/网络类名）直接展示给用户，与上方 PlaylistWriteException 分支「不把原始异常文本拼给用户」的自我要求相矛盾。
- 违反：第 9 条/微文案（维度 A）
- 后果：用户看到「Toast: SocketException: ...」类技术文案，无下一步指引（对比热搜索失败有「重试」按钮）。

### playlist_detail_page.dart:<_InfoChip> 硬编码 Colors.white/Colors.black38
- 级别：P3
- 事实：角标颜色硬编码；有黑色渐变遮罩支撑属刻意设计，但仍是硬编码色绕过主题（与 _RankRow 同类）。
- 违反：颜色 token（维度 C）
- 后果：token 漂移无感知，轻微。
### comments_page.dart:<~640 _CommentTags> 分类/热词 Chip 无 onTap，纯装饰却长得可点
- 级别：P2
- 事实：classifies/hotWords 渲染为 Chip（M3 中 Chip 默认暗示可点按），但无 onPressed/onSelected —— 用户点「分类标签」筛选评论无任何反应。
- 违反：易用性：可预期交互（维度 A）；第 30 条
- 后果：用户点击分类/热词无反应，误以为功能坏了。

### comments_page.dart:<~590> 点赞图标是纯展示，长得像可点按钮
- 级别：P3
- 事实：thumb_up 图标+计数渲染在行内，无 InkWell/无点赞接口调用；评论区的点赞是通用预期操作。与楼中楼入口（可点）混排，反馈不一致。
- 违反：图标语义/易用性（维度 A、C）
- 后果：用户点👍无反应。

### comments_page.dart:<~430/620> 两处仍把 '$e' 拼给用户（验证失败/删除失败分支）
- 级别：P3
- 事实：`commentFailed('$e')`（captcha 分支）与 `deleteFailed('$e')` 直接输出原始异常；同文件 _send 主分支已用 unwrapApi 解包出友好 message，处理不彻底。
- 违反：微文案（维度 A）；第 9 条
- 后果：部分失败路径用户看到技术串。
### comment_floor_page.dart:<~288> 未登录时发送按钮 onPressed 为空函数
- 级别：P2
- 事实：`onPressed: _isLoggedIn ? _send : () {}` —— 未登录点发送按钮无任何反应（连登录引导都没有）。对比 comments_page 同一位置：未登录点击会 push('/login')。同动作两页行为不一致。
- 违反：第 9 条 / 图标语义一致性（维度 C）/易用性
- 后果：楼中楼页未登录点发送「死按钮」，而评论主页会带你去登录。

### comment_floor_page.dart:<~115> 错误信息直接存 '$e' 技术串并渲染
- 级别：P3
- 事实：`_error = '$e'` 传给 ErrorRetry（会显示原始异常文本）；comments_page 用 unwrapApi 出友好文案，此处未解包。
- 违反：微文案（维度 A）；第 9 条
- 后果：加载失败用户看到技术串而非「网络错误，请重试」。

### comment_floor_page.dart:<~280> 楼中楼回复行无「回复该楼层」入口
- 级别：P3
- 事实：ListTile 只有删除（自己的）trailing，无回复操作；输入框只能回复顶层评论。与 comments_page 的 PopupMenu（回复/删除）能力不对齐。
- 违反：视觉一致性（维度 C）/易用性
- 后果：功能不对齐：主页能回复楼层，进楼中楼反而不能。
### download_page.dart:<~230 'folder'> 「在文件管理器打开」失败兜底只复制路径，无下一步指引
- 级别：P2
- 事实：viewFolder 失败时 `Toast.copy(context, path)` 只复制路径到剪贴板。任务流 2「下载→文件管理器找到它」的断点：用户复制到一个绝对路径后，仍需自己打开文件管理器粘贴导航——多数文件管理器不支持地址栏导航到任意路径。且 toast 未说明「已复制路径，请在文件管理器粘贴」的下一步。
- 违反：易用性：任务流 2；微文案（错误提示需给下一步动作）
- 后果：这是任务流 2 的主要断点：下载成功但用户不知道文件在哪、复制路径也无从使用。

### download_page.dart:<~252 onTap> 打开失败无反馈
- 级别：P3
- 事实：ListTile onTap 打开完成文件不 await、不检查返回值（PopupMenu 'open' 分支有 Toast，行点击分支没有）。打开失败时点击无反应。
- 违反：第 9 条（同动作两处处理不一致，维度 C）
- 后果：点已完成的下载行偶发无反应（无应用可打开该类型时）。

### download_page.dart:<~55 空态> 空下载页文案无「去下载」入口
- 级别：P3
- 事实：EmptyState 只有 message，无 actionLabel；库页同区块有「下载管理」跳转，此处反而没有引导用户去哪里下载。
- 违反：易用性：任务流 5
- 后果：轻；用户可自行返回。
### download_sheet.dart:<~38> 「下载 MV」选项对无 MV 的歌曲仍显示且可点
- 级别：P2
- 事实：DownloadSheet 四个选项无条件渲染（音频/封面/歌词/MV）。歌曲无 MV 时点「下载 MV」会创建注定失败的任务（或下载失败后用户才看到 failed）。未按 song.albumAudioId / 是否有 MV 预判禁用。
- 违反：易用性（维度 A 可预期交互）
- 后果：无 MV 的歌点下载 MV → 转圈→失败，用户困惑。

### download_sheet.dart:<~150 _OptionTile> 失败态无视觉区分与重试入口
- 级别：P2
- 事实：trailing 只处理 completed/running 两种状态；failed 任务显示为普通下载 IconButton（与未下载一模一样），点它=重新 add（等效重试但用户不知道），error 信息只有下载管理页可见。
- 违反：第 16 条（失败与未开始语义混同）/第 9 条
- 后果：弹层里失败的下载看起来像没下载过，错误不可见。

### download_sheet.dart:<~100> 每项点击下载无即时反馈（无 Toast/动画）
- 级别：P3
- 事实：点 IconButton 后状态依赖 manager.add → provider 更新→ running 转圈；音频任务通常瞬间转 running 反馈尚可，但「下载全部」点了直接 pop sheet，无「已加入下载队列」确认；且 addAll 不含 MV（与四选项并列展示逻辑不一致，属刻意但无说明）。
- 违反：微文案/反馈（维度 A）
- 后果：轻微；「下载全部」不含 MV 未向用户说明。
### settings_page.dart:<~600 _showSwitchAccountDialog> 弹层 builder 里用外层 context 的 l10n/Theme
- 级别：P3
- 事实：`showModalBottomSheet` 的 builder 参数是 ctx，但标题 Text 用 `context.l10n`（外层 State 的 context），样式用 `Theme.of(ctx)`——混用。切语言后 sheet 标题文案以打开时刻为准尚可，但两者不一致属隐患。
- 违反：第 2 条（显式优于隐式）
- 后果：轻微，目前可见。

### settings_page.dart:<~250 账号区> 账号管理/切换账号/账号三项功能重叠、可发现性冗余
- 级别：P3
- 事实：未登录时「账号管理」subtitle 是 switchAccountSubtitle 但行为是跳 /login；已登录有其他账号时同时出现「账号管理」「切换账号」两个等价入口（都调 _showSwitchAccountDialog），重复入口增加辨识负担。
- 违反：易用性：任务流 6（设置可发现性）；第 32 条边缘
- 后果：用户面对两个同功能菜单项，不知区别。

### settings_page.dart:<~770 _dirSizeBytes> 单文件读取失败静默吞掉，缓存大小可能偏差
- 级别：记录（合规）
- 事实：catch 注释说明了降级语义，符合第 11 条（有触发条件与退出条件），不算问题；仅记录。
- 违反：无
- 后果：无。

### settings_page.dart 设置可发现性总体评价（任务流 6）
- 级别：记录
- 事实：各开关均带 subtitle 说明（wifiAutoHighQualityDesc 等），危险操作均红色+二次确认，弹层类入口用 chevron、Dialog 类入口无 chevron（checkUpdate 处已注明）。设置项可发现性整体良好；唯一开关语义较弱的是「流量省流」与「WiFi 自动高品质」的优先级关系未在文案中说明（两者同时开启时行为用户难推断）。
- 违反：易用性：任务流 6（轻微）
- 后果：两个音质开关同时开启时的实际档位用户无法推断。
### login_page.dart:<~620 _loadQr> 二维码加载失败文案拼 '$e'
- 级别：P3
- 事实：`_error = context.l10n.qrLoadFailed('$e')`，与本页 _showError 统一解包的口径不一致；qrLoadFailed 之后用户只能刷新二维码，无「检查网络/稍后再试」指引。
- 违反：微文案（维度 A）
- 后果：失败提示可能含技术串。

### login_page.dart:<~415 手机验证码登录> 成功后 context.go('/home') 强制跳首页
- 级别：P3
- 事实：`_onLoginSuccess` 固定 `context.go('/home')`。若用户是从库页「去登录」进入（任务流 3），登录成功后被甩到首页而非原页面，需自己再点回「我的」才能看歌单——多两次点击。
- 违反：易用性：任务流 3（登录后返回原任务）
- 后果：登录→看歌单任务被中断，需手动重走路径。

### login_page.dart:<~130 Logo> 硬编码 Colors.white 图标色
- 级别：P3
- 事实：渐变背景上 Icon 固定 Colors.white；QR 底板固定 Colors.white。二维码底板用白是刻意的（扫码对比度），可接受；Logo 图标色同理在渐变上。记录为硬编码色绕过主题的例外。
- 违反：颜色 token（维度 C）——属有理由的例外
- 后果：无实际可见问题。
### captcha_page.dart:<多处> 整页 UI 文案硬编码中文，未走 l10n
- 级别：P2
- 事实：AppBar 标题 '人机验证'、错误态 '获取验证信息失败：$e' 与 '重试'、短信验证页所有文案、外部验证说明、'验证未通过，请重试'、'提交失败：$e' 全部为中文字面量。全 app 其它页面均走 context.l10n（设置页/评论页等已本地化）。
- 违反：第 30 条/微文案（维度 A）
- 后果：英文界面下人机验证页整页中文；且 '$e' 技术串直出（'获取验证信息失败：DioException…'）。

### captcha_page.dart:<_snack> 用 SnackBar 而全项目统一用 Toast
- 级别：P3
- 事实：`_snack` 走 ScaffoldMessenger SnackBar；项目注释（login_page `_showError`）明确「项目统一用 Toast，避免 Snackbar 刷屏」。反馈组件不一致。
- 违反：视觉一致性（维度 C）
- 后果：验证页的提示样式与全 app 其它提示不同（位置/时长/外观）。

### captcha_page.dart:<~120 _load 错误> 错误信息未给下一步动作（有重试按钮，尚可）
- 级别：记录
- 事实：错误态有「重试」按钮，符合「错误提示给下一步」要求；问题仅在文案语言与 '$e' 拼接（上一条已记）。
- 违反：无额外
- 后果：无。
### app_router.dart:<~99 '/rank'> 错误页文案硬编码中文「排行榜参数无效」
- 级别：P3
- 事实：深链非法时渲染 `Text('排行榜参数无效')`，未走 l10n（同文件底部导航已修 F4-31，此处漏改）。错误也无「返回首页」动作。
- 违反：微文案（维度 A）/易用性：任务流 5
- 后果：英文用户看到中文错误；错误页无法脱出（只能系统返回手势，此页无 AppBar）。

### app_router.dart:<全局> 二级页过渡动画统一用默认 MaterialApp 转场（无自定义），Android 上为淡入淡出、iOS 为滑动——一致性可接受
- 级别：记录
- 事实：GoRoute 均未自定义 pageBuilder，转场走平台默认；播放页/评论页/MV 页均为同一默认过渡。无时长/曲线不一致问题。
- 违反：无
- 后果：无（正面记录）。MV 播放页这类全屏沉浸页可以考虑 fullscreenDialog，但非缺陷。

### app_router.dart:<MainShell> 底部导航与 MiniPlayer 叠放：MiniPlayer 高 64 + NavigationBar 80，在小屏挤占内容区
- 级别：记录
- 事实：Column(min) 组合结构正确；MiniPlayer 3 按钮 48dp 触控目标问题已在 mini_player 记录，此处不重复。
- 违反：无
- 后果：无。
### app_en.arb:<~445 尾部> 英文包尾部 5 个键仍是中文原文
- 级别：P2
- 事实：`previewOnly: "试听"`、`loginRequiredTitle: "需要登录"`、`loginRequiredHint`、`loginRequiredAction` 在 app_en.arb 中为中文未翻译。previewOnly 显示在播放页（isPreview 徽标），英文用户会看到中文「试听」徽标；loginRequiredAction 用于 ensureLoggedIn 弹窗（收藏等操作触发）。
- 违反：微文案/l10n 完整性（维度 A）
- 后果：英文界面下播放页与登录引导弹窗混入中文。

### app_en.arb / app_zh.arb:<comment vs comments> 两键文案疑似互换
- 级别：P3
- 事实：zh 中 `comment` 与 `comments` 都是「评论」；en 中 `comment: "Comments"`、`comments: "Comment"`（单复数互换）。comments_page 用 comments 作为 AppBar 标题，_SmsLoginTab 用 comment 作 ensureLoggedIn 的 action 描述。单复数颠倒说明键语义混乱（第 30 条）。
- 违反：第 30 条命名即文档；微文案单复数
- 后果：英文界面「回复评论」类句子可能读作「Comments」。

### app_zh.arb:<wifiAutoHighQualityDesc> 「（预留）」字样暴露未实装开关
- 级别：P2
- 事实：zh/en 文案均含「(reserved)/（预留）」，即设置页两个音质 Switch 是假开关（改了不生效）。在设置页向用户展示不生效的开关且仅以小字标注预留，用户切换后行为不变。
- 违反：易用性：任务流 6（开关意义不明）；第 11 条降级退出条件
- 后果：用户打开「Wi-Fi 自动最高音质」后无任何效果，误判 App 有 bug。

### l10n 总体（维度 A 微文案）正面记录
- 级别：记录
- 事实：空态文案普遍带引导（noRecentlyPlayed「去首页挑首歌吧」、queueEmpty「先去播放几首歌吧」、noComments「快来抢沙发」），错误文案多含下一步（authErrorRetry、networkErrorHint）；质量较高。
- 违反：无
- 后果：无。

---

## 易用性任务流走查表

| # | 任务流 | 路径与点击数 | 断点/反馈缺失 |
|---|---|---|---|
| 1 | 搜索→播放→收藏到歌单 | 搜索 Tab→输入→提交→点歌曲（≈3 次点击，进入播放页）→播放页**无「收藏到歌单」任何入口**（顶部菜单仅下载/队列；控制区仅 shuffle/prev/play/next/repeat）→ 必须返回→库页→找歌单→…… | **严重断点**：搜索结果 SongTile 菜单只有 download；播放页无收藏按钮；`addToPlaylist` l10n 键存在但无任何页面使用（死键）。任务流无法在合理步数内完成 |
| 2 | 下载→文件管理器找到 | 更多菜单→下载→音频（2 次）→下载管理→条目菜单→「在文件管理器中查看」（4 次）；成功时 displayPath 已显示在条目下（好）；若 viewFolder 失败只复制路径 | 断点：文件管理器打开失败时兜底=复制绝对路径，用户仍找不到文件；降级目录（Android/data）有 error 色提示（好）。总体中上 |
| 3 | 登录→看歌单→切号 | 库页未登录卡「登录」→登录成功**强制 go('/home')**→手动点回「我的」Tab→歌单（+2 次点击）；切号：库页账号卡菜单或设置页，均有切换弹层，切后歌单/收藏 MV 正确失效 | 断点：登录成功不返回来源页；cookie 过期时歌单 error 态只给「重试」无「重新登录」出口 |
| 4 | MV 观看→收藏 MV | 播放页 MV 按钮→MV 页（mv_player_page 本档未列入范围，播放页入口可达）；库页「我收藏的 MV」区块可达；但收藏 MV 的入口在 MV 页内（未走查），库页空态用通用「暂无数据」无引导 | 半断点：库页空态不告诉用户去哪收藏 MV |
| 5 | 空态指引 | 多数空态带引导（首页 EmptyState+重试、库页登录卡、下载空态+管理入口）；缺口：歌词空态硬编码中文且不区分原因、歌单 MV 收藏空态用 noData、下载页空态无动作 | 局部达标 |
| 6 | 设置可发现性 | 分区清晰（账号/外观/播放/下载/缓存/诊断/关于）；开关均有 subtitle；弹层与导航入口的 trailing 图标有区分规则 | 缺口：两个音质开关为「预留」假开关；「账号管理」与「切换账号」双入口同功能 |

## 新改动回归记录

1. **手写动画极端行为**：SplashHandwriting 控制器 dispose 对称、repaint 直挂 controller 零重建、离屏 Ticker 停帧——快速双击返回/切深链下安全，无泄漏（见上文详细条目）。
2. **歌单/库页刷新修复体验**：libraryUserPlaylistsProvider 在账号切换流（AccountManager.onCurrentAccountChanged）与 main.dart 全局监听双路 invalidate，登录→进库页时 provider autoDispose 重新拉取；home 下拉刷新清 MemoryCache 避免 90s TTL 内「刷新无效果」。体验链路完整，未发现回归。
3. **MV 320 缩略图清晰度**：mv_player_page.dart 不在本档 20 文件清单内，未走查（据 full_player_page 的 MV 入口仅确认入口可达性）。标注为**未验证**。

## dart analyze（过滤噪音）

## dart analyze（过滤噪音）

dart analyze（本机未装 Flutter 依赖，全部 `undefined / uri_does_not_exist / override_on_non_overriding_member` 为包未解析噪音，已过滤）：
- 过滤后仅存 `dead_code` 3 处：kugou_api_client.dart:165、kg_direct_api_client.dart:199、**error_retry.dart:227**（core/widgets 本档范围内，ErrorRetry 末尾不可达分支，第 32 条死代码，P3）。
- import 头核对：本档各页新增 Flutter 符号（SegmentedButton / IconButton.filled / Badge / AnimatedSwitcher 等）均在各自 `package:flutter/material.dart` 导入下，未发现未导入符号（v3.2.1 P0 类问题未复现）。

## 问题清单（按级别）

### P1
（无——本档未发现核心功能失效级问题）

### P2（11 条）
1. full_player_page `_MvEntry`：MV 查询期间按钮行无占位，加载完成后突然插入布局跳动；albumAudioId 为空时评论入口连带消失。
2. mini_player：64 高内 3 个 48dp IconButton 并排无间距，长歌名被压窄、误触面大。
3. queue_sheet：打开队列不自动滚动到当前曲目，长队列下「当前在哪」不可见。
4. lyric_view 空态：硬编码中文「暂无歌词」且不区分纯音乐/解析失败/加载中。
5. search_page `_GenericResultTab.onTap`：缺 hash/id 的条目点击静默无反应，无禁用态无提示。
6. playlist_detail「播放全部」：曲目未加载/为空时点击静默无反应；收藏按钮永远空心、无已收藏态。
7. comments_page `_CommentTags`：分类/热词 Chip 纯装饰却长得可点，点击无反应。
8. comment_floor_page：未登录发送按钮 `onPressed: () {}` 死按钮（评论主页同位置会引导登录，两页行为不一致）。
9. captcha_page：整页 UI 文案硬编码中文（标题/错误/短信验证/提交按钮），英文界面下整页中文且 '$e' 直出。
10. app_en.arb：`previewOnly`、`loginRequired*` 4 键未翻译仍为中文；设置页两个音质开关是「（预留）」假开关，切换无任何效果。
11. download_sheet：「下载 MV」对无 MV 的歌曲仍显示可点；failed 任务在弹层里与未下载同外观（失败不可见）。

### P3（17 条）
1. full_player：进度条拖动时左端时间标签不跟随 `_dragMs`（UI-05 只修了一半）。
2. full_player：封面/歌词切换的两处重复逻辑，切回封面无动画重置。
3. mini_player / queue_sheet `_MiniPlaceholder` / `_QueuePlaceholder`：硬编码 Colors.grey 绕过主题。
4. queue_sheet：队列表头误用 nowPlaying 文案。
5. lyric_view：歌词行 onTap 无水波纹；手动滚动 5 秒后突然自动回跳且无「回到当前行」入口。
6. home_page `_RankRow`：Colors.white/Colors.black87 硬编码。
7. home_page Banner：可滑动横幅无任何 onTap，点击无反应。
8. library_page：歌单 error 态不区分 cookie 过期（应给「重新登录」出口）；我的歌单卡用裸 GestureDetector 无水波纹；收藏 MV 空态用通用 noData、hash 为空点击无反应。
9. playlist_detail：catch-all 把 `'$e'` 拼进 Toast；_InfoChip 硬编码色。
10. comments_page：点赞图标纯展示不可点；验证失败/删除失败分支仍拼 `'$e'`。
11. comment_floor_page：错误信息存 `'$e'` 渲染；楼层回复无「回复该楼层」入口（与主页能力不对齐）。
12. download_page：「在文件管理器打开」失败只复制路径（微文案无下一步）；行点击打开失败无 Toast（与菜单分支不一致）。
13. download_sheet：「下载全部」不含 MV 且未说明。
14. settings_page：「账号管理」与「切换账号」双入口同功能；sheet 内 context/ctx 混用。
15. login_page：二维码失败文案拼 `'$e'`；登录成功固定 go('/home') 不返回来源页。
16. app_router：'排行榜参数无效' 硬编码中文错误页且无返回动作。
17. error_retry.dart:227 dead_code（dart analyze 证实）。

### 正面记录（合规）
- splash_handwriting 动画资源对称、零重建，极端行为安全；minVisible 机制完整。
- l10n 空态文案普遍带行动引导；危险操作全员红色+二次确认；弹层/导航入口图标有区分规则。
- 库页账号切换 invalidate 链完整；home 刷新清 MemoryCache 体验良好。
