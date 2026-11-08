# v3.5 C 批·审查②：表现层 UI 逻辑深审（v35_review_C2）

基线 a819334（工作分支 HEAD）。定位：UI 专档（v34_review_2）审观感与任务流，**本档审逻辑正确性**——生命周期/世代/三态分离/状态刷新链/跨文件契约双向核对。

硬性规则：完整 file_read 逐行；不编译不装包不 clone；噪音过滤只适用于 Flutter SDK 符号，**项目自有类报错即真错误**；跨文件改动双向核对。dart analyze 未使用（本档以通读为准，规则 3 允许但非必需）。

---

## 一、add_to_playlist_sheet.dart（新文件首审，305 行，已全文读完）

### add_to_playlist_sheet.dart:87-97 新建歌单后加歌被自身 _busy 闸门吞掉，静默不加歌
- 级别：**P1**
- 事实：`_createAndAdd` 进入即 `setState(() => _busy = true)`（:121），随后 `collectPlaylist` → `fetchUserPlaylists` → 命中同名歌单后调用 `await _addTo(created.first)`（:142）。而 `_addTo` 第一行 `if (_busy) return;`（:88）。`_busy` 在整个 `_createAndAdd` 期间恒为 true，直到其 `finally` 才复位——因此 `_addTo` **无条件在第一行直接 return**，`await` 立即完成，随后 `finally` 复位 `_busy`。整个「新建歌单并加歌」主路径**从不执行 addTracks，也不弹任何提示**。
- 违反：第 19 条（互斥闸门归属：`_busy` 是单闸门，被嵌套复用为两个互斥操作的锁，持有者在等待子操作时子操作被闸死）；第 21 条反面——防重闸门误伤唯一一次合法提交。
- 后果：用户输入歌单名点确认 → 歌单创建成功、弹层关闭、**歌没进去，且没有任何提示**（连 collectSuccess 都不弹，因为走的是 created 非空分支）。核心任务流「搜索→收藏到歌单→新建歌单」静默丢歌。
- 修法建议：`_addTo` 增加内部 `_addToLocked`（不做 busy 判断），或 `_createAndAdd` 在调用前临时复位/直接 inline 加歌逻辑。

### add_to_playlist_sheet.dart:196-204 「去登录」按钮只关弹层，不跳登录页
- 级别：**P1**
- 事实：未登录分支 `EmptyState(actionLabel: l10n.goLogin, onAction: () { Navigator.of(context).pop(); })`，其后注释声称「走全局 /login 路由，与 ensureLoggedIn 引导一致」——但**代码里没有任何路由跳转**，只有 pop。注释与实现脱钩。
- 违反：第 9 条（引导动作无实效）；第 31 条（注释复述了一个不存在的实现）。
- 后果：用户点「去登录」→ 弹层关闭，停在原地。任务流断裂且用户以为是误触。
- 修法：pop 后 `Navigator.of(context).pushNamed('/login')`（核对 app_router 的实际路由名后补上），或复用项目内 ensureLoggedIn 引导入口。

### add_to_playlist_sheet.dart:129-145 按名称定位新歌单存在同名旧歌单竞态
- 级别：**P2**
- 事实：`collectPlaylist(name: trimmed)` 后重新拉取并 `list.where((p) => p.name == trimmed)`，取 `created.first`。若用户**此前已有同名歌单**（酷狗允许重名），匹配到的可能是旧歌单——歌被加进旧歌单，用户在新歌单里找不到。且 `created.first` 在多条同名时选择顺序未定义。
- 违反：第 18 条（异步等待期间世界已变，未校验「这条匹配确实是刚创建的那条」）；第 16 条（同名多义未分离）。
- 后果：歌进了错的歌单——数据写入到了用户意料之外的位置（低危但属「写入目标错误」）。
- 修法：比较创建前快照差集（before/after diff），而非全量按名称匹配。

### add_to_playlist_sheet.dart:117-124（轻微）空名检查的 Toast 无 mounted 保护、且 _busy 置位早于校验
- 级别：P3
- 事实：`_createAndAdd` 先判 `trimmed.isEmpty` 并 `Toast.show`，此处尚无问题；但校验通过前未置 busy、校验失败路径与 `_addTo` 的失败路径文案来源不同（`playlistNameEmpty` vs `operationFailed`），行为一致。真正的小问题：`Toast.show(context, ...)`（:126）在 build 期外直接用 context，未守 mounted——本方法由按钮触发、同步调用，风险极低，仅与同文件其他路径（全部有 `if (mounted)`）风格不一致。
- 违反：一致性（第 20 条精神：异步触界统一守卫）。
- 后果：几乎无用户可见影响。

### add_to_playlist_sheet.dart 三态与契约（核对通过项）
- FutureBuilder 三态分离正确：waiting / hasError(可重试 EmptyState) / data，且空列表有独立空态（第 16 条 ✅）。
- `PlaylistWriteException` 单独捕获并展示仓库层 message，其余走 friendlyError（第 7/8 条 ✅）。
- TrackRef 契约：`widget.track.hash` 与 `p.listid` 均在调用前 trim 非空校验（第 14 条 ✅）。**跨文件双向核对**：见 §九 full_player_page 段（传入来源为 `TrackRef` 构造，hash 字段存在）。

---

## 二、captcha_page.dart（i18n 脱钩收尾复核，445 行，已全文读完）

### captcha_page.dart:88/349-371/386-402/408-425/433-437 9 个 i18n 死键已补进 arb，但代码一处都没换——修复做了一半
- 级别：**P2**
- 事实：A3 指出 5 处硬编码 + 9 死键后，`app_zh_CN.arb:552-573` 新增了 `captchaLoadFailed / captchaSmsTitle / captchaSmsHint / captchaSmsCodeLabel / captchaSmsCodeHint / captchaExternalHint / captchaUnknownType / captchaNoVerifyUrl / captchaTryFingerprint`（连同 ru/zh_TW 均已补齐），**但 captcha_page.dart 中对应的硬编码中文全部原样保留**，9 个新键无一被引用（死键依旧死）：
  1. :88 `_error = '获取验证信息失败：$e'` ↔ `captchaLoadFailed`
  2. :349 `Text('短信验证')` ↔ `captchaSmsTitle`
  3. :352 `'请输入接收到的验证码完成验证'` ↔ `captchaSmsHint`
  4. :358 `labelText: '验证码'` ↔ `captchaSmsCodeLabel`
  5. :359 `hintText: '6 位数字'` ↔ `captchaSmsCodeHint`
  6. :398-401 `'该验证类型需要在酷狗官方 App 内完成。…'` ↔ `captchaExternalHint`
  7. :419 `'未知验证类型（v_type=${s.vType}）'` ↔ `captchaUnknownType`（带 {type} 占位）
  8. :423 `s.verifyUrl ?? '服务端未返回验证 url'` ↔ `captchaNoVerifyUrl`
  （`captchaTryFingerprint` 有被引用 ✅，但 `captchaHint`、`captchaSms*` 等仍为死键。）
- 违反：第 32 条（死代码零容忍——9 个三语 arb 键全部无人消费）；i18n 契约（arb 是唯一文案源，硬编码绕过翻译体系，俄语/繁体用户在此页看到简体中文）。
- 后果：非中文语言用户在人机验证页（错误提示、短信验证整屏、外部验证整屏、未知类型整屏）看到简体中文；约 8 个键 × 3 语言 = 24 条翻译成果无效。
- 修法：逐处替换为 `context.l10n.captchaXxx`；`'获取验证信息失败：$e'` 建议改为 `l10n.captchaLoadFailed` + debugPrint 留痕（第 9 条，'$e' 不该直出给用户）。

### captcha_page.dart:56-58 `VerificationService` 字段初始化即 `ref.read`，late final 于 dispose 后异常路径
- 级别：P3
- 事实：`late final _service = VerificationService(widget.api, ref.read(kgClientProvider));` 首次访问才初始化，无实际问题；记录为核对通过（mounted 守卫在 `_load`/`_submitWithCode` 全覆盖 ✅，`_smsCodeCtrl.dispose()` 对称 ✅）。
- （无违规，核对通过项，记录防止后续回归。）

### captcha_page.dart 其余核对通过项
- `_submitWithCode`：`_submitting` 防重（第 21 条 ✅）；异步后 `if (!mounted) return` 全覆盖（第 20 条 ✅）；失败文案 `captchaSubmitFailed` + debugPrint（第 9 条 ✅）。
- 三态分离：_loading / _error / 按类型分发，错误态带重试按钮（第 16 条 ✅）。
- 注意点（不计问题）：`onVerified` 重试失败路径 pop(true)（:434-436）——验证已通过但原请求重试失败仍返回 true，调用方语义为「验证通过」，与 l10n `captchaPassedButRetry` 提示一致，契约可接受但建议在 `CaptchaPage.onVerified` 文档注释中写明「返回 true 不代表原请求成功」（第 3 条契约）。

---

## 三、full_player_page.dart（580 行，已全文读完）

### full_player_page.dart:23-28 歌词 error 文案硬编码中文（'暂无歌词' / '歌词解析失败'）
- 级别：P3
- 事实：`currentLyricProvider` 中 `return (lyric: null, error: '暂无歌词');`、`error: '歌词解析失败'` 未走 l10n。俄语/繁体用户歌词占位为简体中文。与 captcha_page 同类（第 32 条/i18n 契约）。
- 其余：provider 世代由 riverpod（watch currentSongProvider 触发重算）保证，await 后无需手动比对（第 18 条核对通过）。

### full_player_page.dart:79-118 收藏到歌单入口（V34-UI-01 后）：TrackRef 契约双向核对通过
- `TrackRef(name/hash/albumId/albumAudioId)` 均以 song 显式字段填充；菜单项 `enabled: song != null` + onSelected 内再判空双保险 ✅。与 §一 add_to_playlist_sheet 消费面（track.hash）及 `PlaylistRepository.addTracks(listid, [TrackRef])` 契约一致。

### full_player_page.dart:201-246 _MvEntry（UI-04 修复后回归核对通过）
- 评论按钮移到 MV 判定之前；`albumAudioId.isEmpty` 时两者一起隐藏（评论路由同样依赖 album_audio_id，合理）。MV hash 回退链 `bestHash ?? sdHash ?? ''` 判空后转 videoId ✅。

### full_player_page.dart:405-409 点「显示歌词」但歌词未加载完成时无反馈
- 级别：P3
- 事实：`_showLyric && lyricAsync.value?.lyric != null` 不满足时仍渲染封面；按钮点击却执行 `forward(from: 0)` 且切换按钮文案 →「显示封面」。歌词加载中/无歌词/加载失败三种状态都表现为「点了没反应」。
- 违反：第 9 条（动作无反馈）、第 16 条（「加载中」「确实无」未分离）。
- 后果：网络慢时用户连续点击，行为像失灵。
- 修法：lyricAsync loading 给 spinner、error 给占位提示，再渲染 LyricView。

### full_player_page.dart:487-505 拖动进度条期间歌曲自动切换：松手 seek 落到新歌
- 级别：P3
- 事实：`_dragMs` 只在 `onChangeEnd` 清除（:502）。若拖动过程中歌曲自动切换（播完下一首），松手时 `controller.seekTo(v.round())` 的 v 是相对旧歌时长的值——把**新歌**跳到错误位置（seekTo 若被 clamp 到末尾还可能触发连跳）。
- 违反：第 18 条（事件间的世界变化未校验）。
- 后果：低概率但真实的错误进度/连跳。修法：watch 当前歌曲，变化时作废悬置手势并复位 `_dragMs`。

### full_player_page.dart 其余核对通过项
- `_fadeCtrl/_fadeCurve` 生命周期对称（R-01 修复有效）✅；`posMs/bufMs` clamp 防 Slider 断言（V3-08 修复有效）✅；tooltip 与状态同步 ✅。

---

## 四、mini_player.dart（180 行，已全文读完）——核对通过，无正式问题

- `song == null` 返回 SizedBox.shrink，不渲染空壳 ✅。
- Hero tag 'album-art' 与 full_player_page:458 一致（双向核对 ✅），迷你↔全屏封面过渡成立。
- 点击 push '/player'、长按队列 + 队列显式图标按钮三入口均有效 ✅。
- `_MiniProgressBar` 独立 watch position，整条不随进度重建（性能设计 ✅），progress clamp 0..1 ✅。
- 观察（不计问题）：64 高度行内 3 个 IconButton，<360dp 设备歌名文本区被压至 <80px。

---

## 五、queue_sheet.dart（129 行，已全文读完）——核对通过，无正式问题

- 点选队列项：先 pop 再 `await controller.playQueue(queue, i)`，await 后不触 context/setState，第 20 条不适用 ✅。
- 空队列 EmptyState 独立空态 ✅；`queueProvider.valueOrNull ?? []` 把瞬时 loading 并入空态，窗口极短（内存态数据源），记录为合理取舍（第 16 条轻微，不计问题）。
- `isCurrent` 以 hash 比对：同 hash 双条目时两条都高亮——数据层去重属队列来源职责，此处仅展示，核对通过。

---

## 六、playlist_detail_page.dart（377 行，已全文读完）

### playlist_detail_page.dart:349-357 收藏失败 toast 文案：`operateFailed('操作结果未知，请到「我的音乐」确认')` 直接传中文字面量进 l10n 函数
- 级别：P3
- 事实：`context.l10n.operateFailed('操作结果未知，请到「我的音乐」确认')`——把硬编码中文当作参数传给带占位的 l10n 函数；而仓库层 `PlaylistWriteException.message` 本就是面向用户的整理文案（add_to_playlist_sheet :101 注释明示），此处不走 `e.message` 却手工拼中文。俄语/繁体用户收到简体中文提示。且第二分支 `operateFailed('$e')`（:356）把原始异常直出，违反 add_to_playlist_sheet 同类路径已纠正的口径（第 9 条）。
- 违反：i18n 契约；第 9 条（'$e' 技术串直出）。
- 后果：非中文用户收简体中文/技术串；与同批新弹层的错误文案口径不一致。
- 修法：maybeSucceeded → 新增 l10n 键 `operateResultUnknown`；普通分支 → `operateFailed(e.message)`；兜底 → friendlyError(e)。

### playlist_detail_page.dart:168-188 「播放全部」按钮静默无反馈（无歌时）
- 级别：P3
- 事实：`if (tracks != null && tracks.songs.isNotEmpty) { …playPlaylistQueue… }` else 分支**什么都不做**。tracks 未加载完（value 为 null）或为空列表时点击按钮无任何反馈（无 toast、无禁用态）。
- 违反：第 9 条（无反馈）、第 16 条（加载中与空列表未区分）。
- 后果：数据加载中点击「播放全部」像死按钮。
- 修法：加载中禁用或转圈；空列表 toast「歌单暂无歌曲」。

### playlist_detail_page.dart:299-321 _collectPlaylist 防重锁（V3-14/F-4 修复后回归核对通过）
- `ensureLoggedIn` 前置 ✅；autoDispose 锁与页面共存亡、notifier 快照复位 + try/catch（F-4 修复在位）✅；maybeSucceeded 语义分支存在（文案问题见上条）。
- 注意：`collectPlaylist(name: detail.name, listCreateGid: detail.id)` 与 add_to_playlist_sheet 的 `collectPlaylist(name:)` 是同一仓库方法的不同形态——**跨文件双向核对**：仓库支持 listCreateGid 可选参数，两处调用各自合法 ✅（方法签名核对通过）。

### playlist_detail_page.dart 其余核对通过项
- 双数据源（gid/listid）在 build、播放全部、错误重试三处一致（V3-06 修复在位 ✅）。
- detail / tracks / 空列表三态分离正确（第 16 条 ✅）；`_tracksReloadProvider` watch 用于加载更多后重建（注释说明了原因）✅。
- `_collectingProvider` 声明与注释一致（F-4 终审要求）✅。

---

## 七、comments_page.dart（656 行）+ comment_floor_page.dart（310 行），均已全文读完

### comments_page.dart:454-459（_send 匿名分支）楼层回复未登录引导与顶层不一致
- 级别：P3（本条在 comments_page，floor 页同题见下）
- 事实：`_send` 未登录走 `ensureLoggedIn(context, ref, action: …)`（有引导）；但**楼中楼页** comment_floor_page:248 `onPressed: _isLoggedIn ? _send : () {}`——未登录点发送按钮**空操作**（连输入框 hint 都提示去登录，按钮却什么都不做）。
- 违反：第 9 条（动作无反馈）；与 comments_page:391-393（`context.push('/login')`）行为不一致——**同动作不同行为**。
- 后果：楼中楼页未登录用户点发送无任何反应。
- 修法：与 comments_page 对齐，未登录 `context.push('/login')`。

### comments_page.dart:106-113 load() 错误态在已有数据时被静默吞掉（refresh 失败无感知）
- 级别：P3
- 事实：`catch (e, st) { if (state.value == null) state = AsyncValue.error(e, st); }` ——已有内容时下拉刷新失败**完全静默**（无 toast、无日志），用户下拉后列表纹丝不动，不知道刷新失败。
- 违反：第 9 条（失败必须可观测——此处连 debugPrint 都没有）。
- 后果：弱网下刷新失败不可感知。
- 修法：至少 debugPrint 留痕；最好 toast。

### comments_page.dart:128-135 loadMore 静默失败无 footer 重试入口
- 事实：`catch (_) {}` 空 catch（注释说明保留重试机会），但列表 footer 只有 `_hasMore` 时的转圈——loadMore 失败后 `_loadingMore=false`、`_hasMore` 不变，footer 回到转圈但**没有触发方**（onScroll 只在滚动时触发），停在最底部的用户看到永远转圈（轻微抖动滚动能再次触发，但纯静止则卡住）。
- 违反：第 6 条（空 catch 无留痕）；第 9 条。
- 后果：loadMore 失败后 footer 永久转圈直到用户再滚一毫米。
- 修法：失败时置 `_pageError`，footer 渲染重试按钮（search_page `_SongResultTab` 已有正确范式）。

### comments_page.dart:413-437 风控验证码路径核对通过
- 20028 → CaptchaPage；验证通过**不自动重试**（红线遵守 ✅）；unwrapApi 解包（A2-07 修复在位 ✅）。注：失败文案 `commentFailed('$e')` 直出原始异常（:433），与 :439 的 V3-09 修复口径不一致——归入本批 i18n/文案问题，P3。

### comments_page.dart / comment_floor_page.dart 其余核对通过项
- `_CommentsController` 世代计数（refresh/loadMore 并发丢弃旧结果，第 18 条 ✅，显式注释）。
- dispose 对称：两个页面的 controller/focus/listener 均释放 ✅。
- `_openFloor` 返回后 `if (mounted)` 守卫刷新 ✅。
- floor 页 `_load`/`_loadMore` 有 mounted 守卫、空 catch 同题（上面已列）。
- 三态：loading skeleton / error retry / empty / data 四态齐全 ✅（floor 页 `_comments.isEmpty && !_loading` 的空态判定正确）。

---

## 八、settings_page.dart（997 行，已全文读完）

### settings_page.dart 全文核对通过——假开关移除（V34-UI-04）跨文件双向核对 ✅
- 事实：播放区块仅剩歌词模式 SegmentedButton + 默认音质两项；`wifiAutoHighQuality / cellularLowerQuality` UI 已删（:569-574 注释），`settings_providers.dart:32-34` 注释确认 provider 已删、Hive 遗留键不再读取（降级退出条件写明 ✅）。**双向核对通过**：页面无引用、provider 无定义、写入端（Hive 历史键）有明确「不再读取」声明。
- **残留（P3，死键）**：`app_zh_CN.arb:145-146` 的 `wifiAutoHighQuality / wifiAutoHighQualityDesc` 键仍在三语 arb 中无人消费——与 captcha 死键同类，违反第 32 条，应随开关一起删。

### settings_page.dart 其余核对通过项（本档重点维度）
- 生命周期：`_logDirPath / _storageGranted` 提为 State 字段防无限重建（注释写明为什么，第 31 条 ✅）；`_loadCacheSize/_loadVersion/_loadAccount` 异步后均有 `if (mounted)` ✅；`_logout` 在 dialog await 后 `!ok || !mounted` 双守卫 ✅。
- 世代（第 18 条）：`_checkingUpdate` 防重 + finally 复位 ✅；缓存大小「计算中…」占位 + 重算按钮 ✅。
- 三态：诊断区 FutureBuilder 的 loading/unknown/denied 各有文案；错误日志列表空态 `noRecentErrors` ✅。
- F4-38/F4-43/F4-46 修复在位（技术串不直出、绝对路径不显示）✅。
- `_showSwitchAccountDialog` 中 `context.l10n` 在 sheet builder 里用外层 context（:242-244 标题用 `context.l10n` 而 subtitle 用同 context）——sheet 弹出期间页面仍在树中，语境安全，核对通过。
- `FlutterSecureStorageCompat.readAccounts`：`Hive.box('settings')` 若 box 未打开会抛——调用处 `_loadAccount` 有 try/catch ✅。

### settings_page.dart 小观察（不计问题）
- `_clearCache` 中 `clearCacheFailed('')` 传空串给占位函数（l10n 定义大概率为「清除缓存失败{reason}」形态），空占位可接受但略含糊；失败已 debugPrint 留痕（第 9 条 ✅）。

---

## 九、跨文件改动双向核对汇总（本档硬性条款）

| 改动点 | A 面 | B 面 | 结论 |
|---|---|---|---|
| V34-UI-01 收藏到歌单弹层 | full_player_page:92-100 / search_page:630-650 传 `TrackRef` | add_to_playlist_sheet 消费 `track.hash`→`addTracks(listid,[TrackRef])` | 契约一致 ✅（但 sheet 内部 §一 P1×2） |
| V34-UI-01 search_page 菜单项补验 | SongTileMenuItem 'addToPlaylist' 在位，`hash: s.hash ?? s.id` 回退 | 与 download 菜单并存，onMenuSelected 双分支覆盖 | ✅ |
| V34-UI-04 假开关移除 | settings_page UI 删除 | settings_providers provider 删除 + Hive 遗留键不读取声明 | ✅（arb 残留 2 死键，P3） |
| A3 captcha i18n | arb 新增 9 键 ×3 语言 | captcha_page 代码 0 处替换 | **双向断裂 ❌（P2，§二）** |
| _pageError 收敛（search_page F-5） | `_SongResultTab` 分页失败独立态 + footer 重试 + 成功清态 | comments_page loadMore 未采用同范式（空 catch + 永久转圈 footer） | search ✅ / comments ❌（P3，§七） |
| UI-05/V3-08 进度条 | `_dragMs` 本地值 + clamp | 全屏播放页生效；mini_player 线性进度条无拖动，不适用 | ✅ |
| F-4 收藏飞行锁 autoDispose | playlist_detail 锁与页面共存亡 | add_to_playlist_sheet 未加锁但 `_busy` 单闸门防重 | sheet 有防重 ✅（但 §一 P1 嵌套闸死） |

---

## 十、问题清单（按级别）

| # | 位置 | 级别 | 标题 |
|---|---|---|---|
| 1 | add_to_playlist_sheet.dart:88,142 | **P1** | 新建歌单后加歌被自身 `_busy` 闸门吞掉，静默不加歌 |
| 2 | add_to_playlist_sheet.dart:196-204 | **P1** | 「去登录」按钮只 pop 不跳登录页（注释与实现脱钩） |
| 3 | add_to_playlist_sheet.dart:129-145 | P2 | 按名称定位新歌单：同名旧歌单竞态，歌进错歌单 |
| 4 | captcha_page.dart:88,349-437 | P2 | 9 个 i18n 键已进 arb 但代码 0 处替换，硬编码中文残留 |
| 5 | playlist_detail_page.dart:349-357 | P3 | 收藏失败文案硬编码中文参数 / `'$e'` 直出 |
| 6 | playlist_detail_page.dart:168-188 | P3 | 「播放全部」在未加载/空列表时点击无反馈 |
| 7 | comment_floor_page.dart:248 | P3 | 楼中楼未登录点发送空操作（与 comments_page 行为不一致） |
| 8 | comments_page.dart:106-113 | P3 | 已有内容时刷新失败完全静默（无留痕无反馈） |
| 9 | comments_page.dart:128-135 | P3 | loadMore 失败后 footer 永久转圈（空 catch + 无重试入口） |
| 10 | full_player_page.dart:405-409 | P3 | 点「显示歌词」在歌词未就绪时无反馈 |
| 11 | full_player_page.dart:487-505 | P3 | 拖动进度条期间切歌，松手 seek 落到新歌错误位置 |
| 12 | full_player_page.dart:26-28 | P3 | 歌词 error 文案硬编码中文（'暂无歌词'等） |
| 13 | app_zh_CN.arb:145-146 | P3 | 假开关删除后 wifiAutoHighQuality 2 死键残留 |
| 14 | add_to_playlist_sheet.dart:126 | P3 | `_createAndAdd` Toast 无 mounted 守卫（风格不一致） |

共 14 条：P1×2、P2×2、P3×10。

### 假开关移除后复核结论（任务重点）
V34-UI-04 的修复本体（UI + provider 双删）完整、双向核对通过；遗留 2 个三语死键未随删（计入 #13）。

### captcha i18n 复核结论（任务重点）
A3 报告准确：arb 侧 9 键已补齐（含 ru/zh_TW），但 captcha_page.dart 一处都没换，5 处硬编码原样保留（`:88 / :349 / :352 / :358-359 / :398-401 / :419 / :423`，共 8 个替换点对应 8 个键；`captchaTryFingerprint` 已引用，`captchaHint` 等 9 键中 8 个仍死）。「脱钩收尾」实际未收尾。

### 生命周期/三态全量复核结论（第 20/16 条，9 文件全读）
- dispose/mounted：10 个 State 类全部对称释放、异步后守卫齐全——**除 comments_page:106（刷新失败静默）外无生命周期违规**。
- 三态分离：settings、playlist_detail、queue_sheet、captcha、comments、floor、search、add_to_playlist_sheet 均有 loading/error/empty 独立态；仅 full_player_page 歌词区（#10）与 playlist_detail 播放全部按钮（#6）把加载中/空并入「无反馈」。



