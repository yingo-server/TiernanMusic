# 第4批·审查③-续：音乐库/设置/认证/歌单/评论/下载/路由与组件

- 基线：`6e46611`
- 范围：library / settings / auth / playlist / comment / download / router / core/widgets
- 已排除：home_page / search_page / 播放器三页（见 `docs/batch4_review_3_ui.md`）
- 口径：所有网络数据必须走酷狗原生网关，kapi 仅作未移植路径兜底；UI/provider 层出现 kapi 痕迹或绕过 `data/` 直发请求即记为问题

## 1. lib/features/library/presentation/library_page.dart

### lib/features/library/presentation/library_page.dart:9 引入 core/providers 的 kugouApiClientProvider 但页面内未使用
- 级别：P2
- 依据：`import '../../../core/providers.dart' show kugouApiClientProvider;` 全文再无任何 `kugouApiClientProvider` 引用
- 影响：UI 层与底层 API 客户端装配产生无意义耦合，是「UI 直接持有客户端」的危险先例；同时暴露该页曾被用于直发请求的痕迹，与「UI 层零直接构造/调用客户端」分层要求相悖

### lib/features/library/presentation/library_page.dart:400-425 已登录账号卡片无任何可点区域
- 级别：P2
- 依据：`_AccountCard` 中 `Row(...)` 只有 `if (account == null) FilledButton(...)`，登录后整卡无 `onTap`、无 `PopupMenuButton`
- 影响：用户登录后在音乐库页看不到「切换账号 / 退出登录 / 个人主页」任何入口，账号卡片退化为纯展示；只能去别的页面找退出入口

### lib/features/library/presentation/library_page.dart:293-330 「我收藏的 MV」一次性渲染全量且无上限
- 级别：P2
- 依据：`for (final mv in list) ListTile(...)` 直接塞进 `Column`，无 `.take(n)`、无分页、无 `ListView.builder`
- 影响：收藏量上百时整页卡顿、内存暴涨；同页「最近播放」「已下载」都用 `.take(20)` 限制，MV 区块独缺限制，口径不一致

### lib/features/library/presentation/library_page.dart:112-186 最近播放/已下载列表均截断 20 条且无「查看全部」
- 级别：P3
- 依据：`for (final r in _recent.take(20))`、`for (final task in downloaded.take(20))`
- 影响：第 21 条之后的内容在音乐库页永远不可达，页面上也没有「更多」跳转，用户只能靠别的入口找歌；已下载区块虽有「下载管理」按钮但这属另一个任务而非本列表的延续

### lib/features/library/presentation/library_page.dart:466-540 歌单卡片固定 height:170 + 2 行标题，大字体下会溢出
- 级别：P3
- 依据：`SizedBox(height: 170, ...)` 内为 120 封面 + 6 间距 + `Text(p.name, maxLines: 2, style: bodySmall)`
- 影响：系统字体放大到 1.3x 以上时两行歌单名超出剩余 ~44px 余量，出现黄黑条溢出；`_PlaylistRowSkeleton` 同样写死 170，与真实卡片一起崩

### lib/features/library/presentation/library_page.dart:537 歌单名区域无横向约束保护
- 级别：P3
- 依据：`Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis)` 位于 `Column(crossAxisAlignment: start)` 且宽度由 `SizedBox(width:120)` 提供
- 影响：超长单行歌单名（无空格）在部分字体回退场景会触发横向溢出警告，虽被 ellipsis 兜住但视觉上被硬切

### lib/features/library/presentation/library_page.dart:200-260 最近播放 / 已下载空态与错误态区分不足
- 级别：P3
- 依据：最近播放只有 `EmptyState(message: noRecentlyPlayed)`；`RecentPlayStore.read()` 失败时 `_loadRecent` 无 catch，直接抛出
- 影响：本地记录读取异常时页面如常显示「暂无最近播放」，用户误以为记录被清空，无从得知是读取失败

### lib/features/library/presentation/library_page.dart:44-56 登录态订阅只覆盖 AccountManager，未覆盖下载/收藏库跨账号切换
- 级别：P3
- 依据：`_authSub` 仅 `setState` + `invalidate(_userPlaylistsProvider)`，`_collectedMvsProvider(true)` 未失效
- 影响：切换账号（A→B）后「我收藏的 MV」仍展示上一个账号的收藏，`autoDispose` 因页面保活不会自动重建，直到离开页面才刷新
## 2. lib/features/settings/presentation/settings_page.dart

### lib/features/settings/presentation/settings_page.dart:520-560 三个 SegmentedButton 段落在窄屏中文下横向溢出
- 级别：P2
- 依据：`SegmentedButton<ThemeMode>` 三段各含 `icon(18)` + 中文标签（浅色/深色/跟随系统），同页 `SegmentedButton<LyricDisplayMode>` 三段为「原文 / 双语 / 译文」
- 影响：360dp 宽设备 + 系统字体放大时，跟随系统段必然挤压溢出，`Row` 报黄黑条；M3 SegmentedButton 不会自动省略文案

### lib/features/settings/presentation/settings_page.dart:170-186 清缓存失败把原始异常文本直接弹给用户
- 级别：P2
- 依据：`Toast.show(context, context.l10n.clearCacheFailed('$e'))`
- 影响：FileSystemException 全文（含绝对路径、errno）出现在 Toast，泄露技术细节且用户无法据此行动；与「错误信息不泄露技术细节」口径冲突

### lib/features/settings/presentation/settings_page.dart:190-200 「账号」与「账号管理」两个入口完全同义
- 级别：P2
- 依据：账号 ListTile 与 `_navTile(title: accountManage, subtitle: switchAccountSubtitle)` 的 `onTap` 都是 `await context.push<void>('/login'); _loadAccount();`
- 影响：用户点「账号管理」期待看到账号列表/绑定管理，实际被再跳一次登录页；`switchAccountSubtitle` 文案承诺的能力在两处都不存在（真正的切换只在第三个条件项里）

### lib/features/settings/presentation/settings_page.dart:240-300 切换账号弹层对已失效账号只提示不清理
- 级别：P3
- 依据：`on StateError { Toast.show(accountNeedRelogin) }`，账号条目仍留在 `AccountManager.instance.accounts`，`_showSwitchAccountDialog` 每次仍列出它
- 影响：token 失效账号永远留在选择列表且每次点都失败，用户无法从 UI 移除，只能反复撞同一个错误

### lib/features/settings/presentation/settings_page.dart:100-140 缓存统计在主 isolate 递归遍历两个目录
- 级别：P3
- 依据：`await for (final entity in dir.list(recursive: true, ...)) { if (entity is File) total += await entity.length(); }`
- 影响：缓存目录含大量文件时进设置页明显卡顿掉帧；每个文件一次 `await length()` 造成大量 IO 往返

### lib/features/settings/presentation/settings_page.dart:150-155 缓存读取失败无重试入口
- 级别：P3
- 依据：catch 后仅 `setState(() => _cacheSize = cannotCalculate)`，无重试按钮（只有同行 IconButton 手动刷新，但用户不知道那是重试）
- 影响：一旦首次统计失败，行内一直显示「无法计算」，用户不清楚点刷新图标可重试

### lib/features/settings/presentation/settings_page.dart:737-800 诊断区把绝对文件路径直接展示并可一键复制
- 级别：P3
- 依据：`FutureBuilder(future: _logDirPath, ... Text(path ?? unknown))`，尾部 IconButton 复制路径
- 影响：普通用户看到 `/data/user/0/...` 一类路径无意义；同时把设备内部目录结构暴露在 UI 上

### lib/features/settings/presentation/settings_page.dart:760-790 请求存储权限后按钮始终存在、无「已授权」禁态
- 级别：P3
- 依据：`trailing: TextButton(onPressed: ... ensureStorageWrite())` 无条件渲染，granted 时仍显示「申请权限」
- 影响：已授权状态下按钮语义错误，点了会再弹一次系统授权流程（部分 ROM 直接跳到设置页），属无效操作入口

### lib/features/settings/presentation/settings_page.dart:800-830 最近错误弹层直接渲染原始异常文本（含堆栈）
- 级别：P2
- 依据：`Text(entries[i].split('\n').take(3).join('\n'), style: labelSmall)`
- 影响：异常类名、文件路径、内部实现细节暴露给普通用户；三行硬切还可能把关键信息截断

### lib/features/settings/presentation/settings_page.dart:690-700 版本号/应用名走硬编码常量与异步版本串
- 级别：P3
- 依据：`title: const Text(AppConfig.appNameCn)`、`subtitle: Text('${context.l10n.version} $_version')`
- 影响：非中文语言下关于页仍显示中文应用名；`_version` 初值为空串，PackageInfo 返回前显示「版本：」空白

### lib/features/settings/presentation/settings_page.dart:210-235 头像使用裸 NetworkImage，未走 AppImageCache
- 级别：P3
- 依据：`backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null`
- 影响：与全项目统一的 `AppImageCache` 缓存策略不一致（library 页已用 CachedNetworkImageProvider + cacheManager），设置页头像每次进入重新下载、无磁盘缓存、无错误占位

### lib/features/settings/presentation/settings_page.dart:900-925 更新下载优先使用 acceleratedUrl，未做域名/协议校验
- 级别：P3
- 依据：`final url = info.acceleratedUrl ?? info.downloadUrl;` 随后直接 `launchUrl(Uri.parse(url), externalApplication)`
- 影响：update 链接落到外部加速域名，用户无法判断来源；`Uri.parse` 对异常串也可能不抛错而打开浏览器失败页
## 3. lib/features/settings/presentation/settings_providers.dart

### lib/features/settings/presentation/settings_providers.dart:14-62 持久化直接读写 Hive，presentation 层承担 storage 职责
- 级别：P2
- 依据：`_box()?.put('defaultQuality', quality)`、`_box()?.put('wifiAutoHighQuality', v)`、`_box()?.put('cellularLowerQuality', v)` 全在 `presentation/` 目录
- 影响：presentation 层不是唯一可以持有存储的层，但把 key 与默认值散落在 UI 目录后，任何非 UI 代码（如播放器选音质）只能反向依赖 UI 目录；多端审计时无法从一张表看出所有持久化键

### lib/features/settings/presentation/settings_providers.dart:56-62 流量降质与 Wi-Fi 提质的存储键命名不成体系
- 级别：P3
- 依据：`'wifiAutoHighQuality'` vs `'cellularLowerQuality'`（后者与 Provider 名 cellularQuality / 开关文案 cellularLowQuality 均不一致）
- 影响：后续迁移/读取旧值时容易漏改；同一语义在 3 处有 3 个拼法（provider 名、Hive key、l10n key）

### lib/features/settings/presentation/settings_providers.dart:21-24 set() 先改内存态再 await 写盘，写盘异常无处理
- 级别：P3
- 依据：`state = quality; await _box()?.put(...)`，且返回值无人 await（调用处 `ref.read(defaultQualityProvider.notifier).set(v)`）
- 影响：磁盘写失败时 UI 开关已翻转但重启后回退，用户遇到「设置不生效」而无任何提示；抛出的异常成为未捕获 Future 错误

### lib/features/settings/presentation/settings_providers.dart:5-11 box 未打开时静默返回 null
- 级别：P3
- 依据：`if (Hive.isBoxOpen('settings')) return ...; return null;` 之外无任何回退/日志
- 影响：Hive 初始化顺序变动时，所有设置静默回落到默认值且写盘全部空转，用户改设置「看起来成功但永远不保存」，排查时无任何线索

### lib/features/settings/presentation/settings_providers.dart:14-17 defaultQuality 默认值 '320' 写死在两处
- 级别：P3
- 依据：构造器 `defaultValue: '320'` 与 fallback `?? '320'` 重复；页面 `_qualityNames` 用 'high'/'super' 而默认档注释仍写 128/320/flac/high/super
- 影响：默认档若调整需改两处，漏改则首次启动值与前次读取值不一致
## 4. lib/features/auth/presentation/login_page.dart

### lib/features/auth/presentation/login_page.dart:395-400 UI 层取 API 客户端并作为构造参数注入验证码页
- 级别：P1
- 依据：`builder: (_) => CaptchaPage(ssaCode: e.ssaCode, api: ref.read(kugouApiClientProvider))`，同文件顶部 `import '../../../core/api/kugou_api_client.dart'` 与 `import '../../../core/providers.dart' show kugouApiClientProvider`
- 影响：表现层直接持有网络客户端并向下传递，验证码链路的装配发生在 UI 而不是 `auth/data/`；一旦客户端实现/网关策略调整（原生网关 vs kapi 回退），需要改 UI 代码，且任何页面都可照此模式绕过 `data/` 直发请求

### lib/features/auth/presentation/login_page.dart:172-180 参数校验提示被统一错误兜底覆盖成「操作失败」
- 级别：P2
- 依据：`_showError(context, context.l10n.phoneInvalid)` / `_showError(context, context.l10n.codeInvalid)` 传入的是 String，而 `_showError` 走 `friendlyError(e)`：`friendlyError` 对非 ApiException/StateError 一律返回硬编码 `'操作失败，请稍后重试'`
- 影响：手机号格式错误、验证码为空、用户名密码为空三种情况用户都只看到「操作失败，请稍后重试」，完全不知道错在哪个字段；且该文案为中文硬编码，10 语言环境下始终中文

### lib/features/auth/presentation/login_page.dart:544 二维码加载失败把原始异常串拼进用户文案
- 级别：P2
- 依据：`_error = context.l10n.qrLoadFailed('$e');`
- 影响：与同文件 `_showError` 明确「必须经 unwrapApi 解包，否则落到 '$e' 显示技术文本」的注释自相矛盾；二维码页直接显示 `DioException [connection error]...` 一类技术文本

### lib/features/auth/presentation/login_page.dart:36-38 登录成功一律 `context.go('/home')`，丢弃来源页
- 级别：P2
- 依据：`void _onLoginSuccess() { if (mounted) context.go('/home'); }`
- 影响：从音乐库/设置/评论页被引导登录后，返回栈被整体替换，用户登录完成落在首页而不是回到原来的操作位置（如评论输入框、歌单收藏）

### lib/features/auth/presentation/login_page.dart:392-403 验证码页走 `Navigator.push(MaterialPageRoute)`，绕过 GoRouter
- 级别：P3
- 依据：`Navigator.of(context).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: ...))`
- 影响：与全项目 go_router 路由体系脱节：无路由名、无法深链、系统返回与 `/login` 的返回语义不一致，后续接入分析/恢复栈时该页不可见

### lib/features/auth/presentation/login_page.dart:657-680 二维码错误态同时出现两个刷新按钮
- 级别：P3
- 依据：状态行下方 `if (_status == 0 || _error != null) ... FilledButton.tonalIcon(onPressed: _loadQr, label: refreshQr)`，同时 `_buildQrContent()` 的错误分支内还有一组相同的 `refreshQr` 按钮
- 影响：错误时屏幕上下各一个「刷新二维码」，重复入口；用户不确定哪个生效

### lib/features/auth/presentation/login_page.dart:63-68 登录页无隐私政策/用户协议同意入口
- 级别：P3
- 依据：全页仅 Logo + 三种登录方式，无任何协议勾选或链接
- 影响：应用商店合规审核常见驳回点；用户无法在收集手机号前获知数据处理方式

### lib/features/auth/presentation/login_page.dart:243-250 发送验证码按钮不设最小高度/不参与 Row 弹性
- 级别：P3
- 依据：`Row(children: [Expanded(TextField...), SizedBox(width:12), FilledButton.tonal(... Text(resendIn(_countdown)))])`
- 影响：倒计时文案「60s 后重新发送」较长，字体放大或窄屏时按钮挤压输入框甚至横向溢出；按钮高度由内容决定，可能低于 48dp 触控目标

### lib/features/auth/presentation/login_page.dart:180 手机号校验仅接受中国大陆 11 位号码
- 级别：P3
- 依据：`RegExp(r'^1\d{10}$')`
- 影响：港澳台/海外账号（酷狗支持国际区号）永远提示号码非法，且文案 `phoneHintCn` 也固定 +86，10 语言环境下不成立

### lib/features/auth/presentation/login_page.dart:290-300 多账号归属选择忽略用户取消，且列表无空态
- 级别：P3
- 依据：`final chosen = await _showAccountPicker(e.users); if (chosen != null && mounted) { await _login(userid: chosen); }` —— chosen 为 null 时无任何提示
- 影响：用户误触关闭弹层后停在本页、按钮恢复可点，不知道登录没完成；若 `users` 为空则弹层只有标题+分隔线

### lib/features/auth/presentation/login_page.dart:317-320 账号昵称缺省值用字符串拼接而非 l10n 占位
- 级别：P3
- 依据：`'${u['nickname'] ?? u['name'] ?? context.l10n.account + ' $userid'}'`
- 影响：RTL 语言与语序不同的语言下「账号 12345」拼接不可本地化；且整段被外层 `'${...}'` 二次包裹，容易与后续格式化冲突
## 5. lib/features/auth/presentation/captcha_page.dart

### lib/features/auth/presentation/captcha_page.dart:104-115 人机验证页全部文案为硬编码中文
- 级别：P1
- 依据：`AppBar(title: const Text('人机验证'))`、`label: const Text('重试')`、`'获取验证信息失败：$e'`，以及 `'短信验证'`、`'请输入接收到的验证码完成验证'`、`labelText: '验证码'`、`hintText: '6 位数字'`、`'提交验证'`、`'该验证类型需要在酷狗官方 App 内完成。...'`、`'未知验证类型（v_type=${s.vType}）'`、`'直接尝试提交指纹验证'`、`'验证未通过，请重试'`、`'提交失败：$e'`、`'验证已通过，但请求仍需重试'`
- 影响：10 语言环境下本页整体不可本地化，非中文用户在一个阻断登录的强流程里完全读不懂提示；本文件是全项目唯一完全绕开 `context.l10n` 的用户可见页面

### lib/features/auth/presentation/captcha_page.dart:118-135 加载失败文案把原始异常直接拼进界面
- 级别：P2
- 依据：`_error = '获取验证信息失败：$e';` 随后 `Text(_error!)`
- 影响：暴露 `DioException [bad response]: ...`、内部 URL、错误码等技术细节；同时因为整串无法本地化

### lib/features/auth/presentation/captcha_page.dart:418-425 提交失败同样拼接原始异常
- 级别：P2
- 依据：`_snack('提交失败：$e');`
- 影响：验证码提交流程失败时用户看到英文异常文本，且该页错误提示用 SnackBar，与项目「统一用 Toast 避免 Snackbar 刷屏」的既定约定不一致（对比 login_page 的 `_showError` 注释）

### lib/features/auth/presentation/captcha_page.dart:52-56 页面自建 VerificationService，UI 层直接组装服务
- 级别：P2
- 依据：`late final VerificationService _service = VerificationService(widget.api, ref.read(kgClientProvider));`
- 影响：验证服务在 State 里 new 出来，`widget.api` 由登录页 `ref.read(kugouApiClientProvider)` 传入，`kgClientProvider` 又由本页读；同一条链在 UI 层被拆成两处装配，绕过 `data/` 的 Provider 装配，任一环节替换（原生网关/kapi 兜底切换）都要改 UI

### lib/features/auth/presentation/captcha_page.dart:372-380 未知类型页把服务端 verifyUrl 原文上屏
- 级别：P2
- 依据：`Text(s.verifyUrl ?? '服务端未返回验证 url', ...)`
- 影响：把内部验证服务地址（可能含 eventid 等一次性凭据）展示给用户，属技术细节与凭据外泄；用户也无法据此行动

### lib/features/auth/presentation/captcha_page.dart:236-244 腾讯验证码 WebView 拦截 onLoadStop 后 setState，未判 mounted
- 级别：P3
- 依据：`onLoadStop: (_, __) => setState(() => _webViewReady = true)`
- 影响：验证弹层内完成/关闭过程中 WebView 仍可能触发 loadStop，页面已 dispose 时 setState 抛异常（debug 崩溃，release 静默）

### lib/features/auth/presentation/captcha_page.dart:247-260 「开始验证」提示文案压在 WebView 之上可遮挡官方弹层
- 级别：P3
- 依据：`Positioned(left:16,right:16,bottom:16, child: Text('如验证码未自动弹出...'))` 叠加在 `InAppWebView` 上
- 影响：腾讯验证弹层为半屏底部弹层时，这行提示与官方按钮重叠，用户点击落到提示文字上而无响应

### lib/features/auth/presentation/captcha_page.dart:300-320 WebView 注入 HTML 通过字符串插值拼 eventId/appId
- 级别：P3
- 依据：`final appIdJson = jsonEncode(appId); final eventJson = jsonEncode(eventId);` 插入 `'''...var appId = $appIdJson;...'''`
- 影响：目前经 jsonEncode 转义尚可，但整段 HTML 无 CSP、外部引入 `https://turing.captcha.qcloud.com/TCaptcha.js`，WebView 也未限制导航，若 eventId 来源校验放松即成为注入面

### lib/features/auth/presentation/captcha_page.dart:290-300 腾讯验证 init 失败只 `done('', '')`，无任何用户反馈
- 级别：P3
- 依据：`catch (e) { done('', ''); }`，而 handler 侧要求 `ticket.isNotEmpty && randstr.isNotEmpty` 才提交
- 影响：TencentCaptcha 初始化失败时页面静默无反应（既不提交也不提示），用户以为卡死，只能退出

### lib/features/auth/presentation/captcha_page.dart:163-172 SMS 分支提交按钮空验证码直接 return，无提示
- 级别：P3
- 依据：`if (code.isEmpty) return;`
- 影响：用户点「提交验证」无任何反馈，不知道是没填还是失败

### lib/features/auth/presentation/captcha_page.dart:129-136 错误态只有「重试」，无「关闭/返回」
- 级别：P3
- 依据：`_buildError` 仅一个 `FilledButton.tonalIcon(onPressed: _load, label: '重试')`
- 影响：getVerifyInfo 持续失败（如 ssaCode 已过期）时用户陷入重试死循环，只能靠系统返回手势退出

### lib/features/auth/presentation/captcha_page.dart:196-215 短信验证码输入框无倒计时/重发入口
- 级别：P3
- 依据：`_buildSms` 只有 `TextField` + 提交按钮，无「重新发送」与剩余时间
- 影响：验证码未收到时用户无任何自救手段，只能退出整个登录流程重来（而重来会换新 ssaCode）
## 6. lib/features/playlist/presentation/playlist_detail_page.dart

### lib/features/playlist/presentation/playlist_detail_page.dart:7/19 UI 层引入并持有 API 客户端 Provider，且实际未使用
- 级别：P2
- 依据：`import '../../../core/providers.dart' show kugouApiClientProvider;`、`final _playlistRepoProvider = playlistRepositoryProvider;`，全文无 `kugouApiClientProvider` 使用
- 影响：与 library_page 同一模式——UI 文件顶部挂着网络客户端 import，任何人补齐实现时最省事的做法就是在此页 `ref.read(kugouApiClientProvider)` 直发请求，绕过 `playlist/data/`；分层已出现松口

### lib/features/playlist/presentation/playlist_detail_page.dart:290-310 收藏歌单无状态反馈，可重复收藏且图标永不变化
- 级别：P2
- 依据：`icon: const Icon(Icons.favorite_border)` 写死；成功后仅 `Toast.show(collectSuccess)`，无 `ref.invalidate`、无本地 state
- 影响：用户无法判断是否已收藏，重复点击会反复调用 `collectPlaylist`；若服务端就「已收藏」报错，用户会看到「操作失败」而实际早已成功

### lib/features/playlist/presentation/playlist_detail_page.dart:45-57 页面 id 与详情 id 混用，评论入口可能指向错误资源
- 级别：P2
- 依据：路由参数为 `this.id`（library_page 传的是 `globalCollectionId`，缺省用 `listid`），评论入口却用 `detail.id`：`context.push('/comments/playlist/${Uri.encodeComponent(detail.id)}')`
- 影响：在 library_page 里当 `gid` 为空时会用 `listid` 拼路由，此时 `detail.id` 与 `id` 可能不同（一个是数字 listid、一个来自 detail 的全局 id），评论区可能落到另一个歌单或返回空评论

### lib/features/playlist/presentation/playlist_detail_page.dart:172-186 「播放全部」按钮在 track 尚未加载时静默无响应
- 级别：P2
- 依据：`final tracks = tracksAsync.value; if (tracks != null && tracks.songs.isNotEmpty) { ... }`，else 分支无任何提示，且 `onPressed` 始终非 null（按钮看起来可用）
- 影响：详情页加载完成而歌曲仍 loading/失败时，用户点「播放全部」毫无反应，误以为应用卡死；按钮应反映可用状态或给出提示

### lib/features/playlist/presentation/playlist_detail_page.dart:186-200 歌曲列表未显示封面
- 级别：P3
- 依据：`SongTile(title:..., artist:..., duration:..., onTap:...)` 未传 `cover`（同页 `_InfoChip`、`detail.cover` 已拿到封面）
- 影响：歌单详情每一行都是无封面空位，与「最近播放/已下载」行样式不一致，长列表辨识度低

### lib/features/playlist/presentation/playlist_detail_page.dart:36-40 `_tracksReloadProvider` 已无写入方
- 级别：P3
- 依据：`final _tracksReloadProvider = StateProvider<int>((ref) => 0);` 与 `ref.watch(_tracksReloadProvider);`（build 中），注释「加载更多后 bump 触发本页重建」，但全文件没有任何 `_tracksReloadProvider.notifier` 写入；`_buildTracksSlivers` 里也只剩 `SliverList`，无「加载更多」按钮
- 影响：`SliverMainAxisGroup` 只包一个 sliver、注释承诺的「>100 首不再静默截断」与加载更多入口实际都不存在；超过仓库 `allPages` 上限的曲目静默消失

### lib/features/playlist/presentation/playlist_detail_page.dart:404-412 收藏失败把原始异常拼进 Toast
- 级别：P2
- 依据：`Toast.show(context, context.l10n.operateFailed('$e'))`
- 影响：与项目 `unwrapApi` / `friendlyError` 契约冲突，用户看到 `DioException ...` 技术文本

### lib/features/playlist/presentation/playlist_detail_page.dart:122-140 头图 errorWidget 只有一块纯色，无占位图标
- 级别：P3
- 依据：`errorWidget: (_, __, ___) => Container(color: theme.colorScheme.surfaceContainerHighest)`
- 影响：封面 404/无网时 280px 高头部整块灰板，无歌单图标，用户误以为页面空白

### lib/features/playlist/presentation/playlist_detail_page.dart:200-215 简介 ExpansionTile 的 subtitle 与 children 重复全文
- 级别：P3
- 依据：`subtitle: Text(detail.intro, maxLines: 2)` + 展开后 `Text(detail.intro)` 全文
- 影响：简介较长时展开只是把同一段话再完整展示一遍（前两行重复），信息冗余且无「收起」以外的价值

### lib/features/playlist/presentation/playlist_detail_page.dart:76-90 收藏按钮无 VIP/权限降级、无已收藏态判定依据
- 级别：P3
- 依据：`_collectPlaylist` 只调 `collectPlaylist(name:, listCreateGid:)`，无「是否已收藏」前置查询
- 影响：匿名以外的非 VIP 场景（若服务端要求）失败后只能看到通用错误，缺少降级说明

### lib/features/playlist/presentation/playlist_detail_page.dart:1-14 ErrorRetry / EmptyState / ListSkeleton 依赖 song_tile.dart 的二次导出
- 级别：P3
- 依据：正文使用 `ErrorRetry`、`EmptyState`、`ListSkeleton`，但本文件未 import 对应文件；实际来自 `core/widgets/song_tile.dart` 末尾的 `export 'section_header.dart'; export 'gradient_chip.dart'; export 'list_skeleton.dart'; export 'empty_state.dart'; export 'error_retry.dart';`
- 影响：core 组件之间形成「以 song_tile 为事实 barrel」的隐式依赖，删改 song_tile 的一个 export 会连带整页编译失败；同时 settings_page 又用 `show SectionHeader` 从 song_tile 取 SectionHeader，依赖方向与文件所在位置相反
