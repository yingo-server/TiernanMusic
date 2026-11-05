# 第5批·审查②：功能链路复核（v3.0 终审 B 视角）

- 基线：`bc4a521`（tag v3.0.0）
- 判定依据：`docs/QUALITY_STANDARD.md`（32 条），每条结论标注「违反第 N 条」
- 方式：逐文件 file_read 全文通读，读完即落盘；未编译、未跑测试、未改代码
- 级别：P0 崩溃/数据损坏/重复提交；P1 核心功能失效或长时间静默错误；P2 次要功能/边界/性能；P3 整洁度

---

## 1. `lib/features/player/data/audio_handler.dart`（544 行，全读）

### audio_handler.dart:436-441 `_applySource` 前后双检世代
- 级别：通过（无问题）
- 事实：`if (token != _playToken) return false; await _player.setAudioSource(source); return token == _playToken;`
- 违反：无（满足第 18 条）
- 结论：`setAudioSource` 不可取消，但装载**后**再校验使其「返回后覆盖新源」不可能发生——调用方在返回 false 时一律 `return`，不再 `play()`；且 pending 请求由 finally 在其**之后**启动，装载天然串行化。修复正确。

### audio_handler.dart:394-410 `_loading` 单点释放
- 级别：通过（无问题）
- 事实：`playQueue` 只 `_playToken++` 并把新下标排队；`_loading = false` 仅出现在 `_playAt` 的 `finally`；finally 中 `_pendingIndex` 交接给 `Future.microtask(() => _playAt(pending))`
- 违反：无（满足第 19 条「闸门成对且归属同一持有者」）
- 结论：F4-14 修复成立——旧请求在飞行中时新请求不会开闸并发装载；且被作废的旧请求仍是闸门持有者，由它放行 pending，不会出现「永久挂起」。**但**由此产生一个副作用见下一条。

### audio_handler.dart:236-257 `playSong` 命中队列已有歌时未作废在途请求
- 级别：P2
- 事实：`playQueue` 显式 `_playToken++`；而 `playSong` 的 `existing >= 0` 分支直接 `await _playAt(existing)`，`_playAt` 在 `_loading == true` 时只写 `_pendingIndex` 就返回，**`_playToken` 未自增**
- 违反：第 18 条（异步结果必须校验世代）、第 19 条（新请求应使旧持有者失效）
- 后果：加载中用户点另一首已在队列的歌，在途的旧请求因 token 未变而判定「我仍有效」，会继续走完 `setAudioSource` + `play()` 并广播 `onSongStarted`；用户先听到上一首出声（几百 ms~数秒），再被 pending 切走。表现为「点 A 先响 B」+ 最近播放记录被写入错误的歌。

### audio_handler.dart:449-452 `await _player.play()` 之后再次读 `_songs[index]`
- 级别：P2
- 事实：`if (token != _playToken) return; _failureStreak = 0; await _player.play(); _playedController.add(_songs[index]);` —— 第二个 await 之后直接按下标取元素，无世代校验、无越界校验
- 违反：第 18 条（await 后写共享状态前必须校验世代）、第 12 条（跨异步等待的下标未证明有效）
- 后果：`play()` 期间若队列被 `playQueue` 整体替换成更短的列表，此处 `_songs[index]` 越界抛 `RangeError`；该语句位于 `try` 内，被 `catch (e)` 当作「播放失败」处理 → 用户看到「播放失败：RangeError…」错误条并触发跳歌，实际音频正常。—— 这正是第 7 条（宽泛捕获把编程错误伪装成业务失败）在现场生效的实例。

### audio_handler.dart:344 / 500-509 `stop()` 与 `onNotificationDeleted()` 不作废世代
- 级别：P1
- 事实：`stop()` 只 `_player.stop()` 并清 `_currentSongController`；`onNotificationDeleted()` 只 `_playerOrNull?.stop()`；两者都不 `_playToken++`、不清 `_pendingIndex`、不 `_loading = false`
- 违反：第 18 条（世代失效未体现）、第 19 条（闸门持有者未被作废）、第 5 条（播放状态单一来源被后台流程绕过）
- 后果：用户在加载中划掉通知或点停止，在途 `_playAt` 恢复后仍会执行 `await _player.play()`（token 未变），音频在「已停止」之后自行响起；通知栏状态与真实播放态分离。属核心播放行为失效，定 P1。

### audio_handler.dart:361-370 `pause()` 同样不作废世代
- 级别：P2
- 事实：`Future<void> pause() async { final p = _playerOrNull; if (p == null) return; await p.pause(); }`
- 违反：第 18 条
- 后果：缓冲中按暂停，`_playAt` 恢复后 `play()` 生效，出现「按了暂停却开始播放」。比 stop 影响轻（不涉及服务销毁），定 P2。

### audio_handler.dart:206-215 `playQueue` 的 `_playToken++` 写在 `ensureEngineReady` 之后
- 级别：P3
- 事实：`if (!await ensureEngineReady()) return; _pendingSongIndex = null; _playToken++;`
- 违反：第 2 条（副作用时序不显式）
- 后果：引擎首次初始化（可能数百 ms~数秒）期间发起的第二个 `playQueue` 不会作废第一个；两者按进入顺序串行执行，最终播放的是**后**一个（因为后者最后调用 `_playAt` 并自增 token），结果正确但用户等待时间被拉长，且 `_songs` 被两次 clear/addAll。无错误结果，降 P3。

### audio_handler.dart:432-446 `_playAt` 早退路径不复位 `_index`
- 级别：P3
- 事实：`if (index < 0 || index >= _songs.length) return;` 之前已经执行 `_index = index`（第 271 行）
- 违反：第 5 条（同一事实两处状态：`_index` 与 `_songs` 长度）
- 后果：仅当传入非法下标时 `_index` 停在不存在的项，`currentSong` 有边界判断不崩，媒体通知的 `queueIndex` 可能超出队列长度。可达性低，定 P3。

### audio_handler.dart:170-175 / 158-162 订阅与 StreamController 无对称释放
- 级别：P3
- 事实：`p.playbackEventStream.listen(_broadcastState)`、`p.processingStateStream.listen(...)` 返回值未保存、无 `cancel()`；`_currentSongController`/`_actualQualityController`/`_errorController`/`_engineReadyController`/`_previewController`/`_verificationController`/`_playedController` 均无 `close()`
- 违反：第 20 条（生命周期双向对称）
- 后果：Handler 为 App 级单例（audio_service 单实例），实际不产生泄漏累积；但若将来出现重建 handler（热重载 / 二次 `AudioService.init`）会重复订阅并造成状态重复广播。定 P3。

### audio_handler.dart:186-193 `_configureSession` 空捕获
- 级别：P3
- 事实：`try { ... } catch (_) {}`
- 违反：第 6 条（禁止空捕获）、第 9 条（失败不可观测）
- 后果：音频会话配置失败（蓝牙/A2DP 路由不生效、来电打断策略缺失）完全无痕，线上无法定位「插耳机不暂停」类反馈。

### audio_handler.dart:57-60 `ensureEngineReady` 未捕获 `ensureReady()` 自身异常
- 级别：P2
- 事实：`final ok = await AudioServiceBootstrap.ensureReady();` 无 try；同函数对失败路径精心写了 `engineError`/`playbackState`
- 违反：第 8 条（异常契约单一：失败本应统一为「返回 false」，却被异常旁路）、第 11 条（降级触发条件不完整）
- 后果：`AudioServiceBootstrap.ensureReady()` 若抛平台异常（插件未注册、Service 启动被系统拒绝），异常直接冒泡到 `playQueue`/`play()` 调用点，而 UI 侧只按「返回 false」设计，`engineError` 仍为 null，用户看到的是无提示的点击无反应或未捕获崩溃。

### audio_handler.dart:314-318 本地文件同步 IO 判定
- 级别：P3
- 事实：`(local.startsWith('content://') || File(local).existsSync())` 在播放路径同步访问文件系统
- 违反：第 26 条（热路径不做阻塞操作的精神）
- 后果：单次播放一次 stat，代价可忽略；但下载目录在 SD 卡/慢速存储上（冷启动首次访问）可能造成 UI 线程数十 ms 卡顿。定 P3。

### audio_handler.dart:379-389 本地源失效回退在线
- 级别：通过（修复正确）
- 事实：`on Exception` 分支内 `fetchDetail` → 世代校验 → `resolveUrl` → 世代校验 → `clearLocalPath: true` 清坏源
- 违反：无（符合第 11 条：触发条件=本地源装载抛 Exception，次优行为=同曲在线解析，退出条件=清 localPath 不再复用坏源）
- 结论：F4-15 修复语义成立——需交叉验证 `Song.copyWith` 是否真提供 `clearLocalPath` 且原 `localPath: null` 确为空操作（见文件 3 结论）。

### audio_handler.dart:392-409 失败跳歌与 `_failureStreak`
- 级别：P2
- 事实：`canAdvance = token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;` 但 `_failureStreak` 从不因**换队列/换歌**清零（只在成功与「不可前进」时清零）
- 违反：第 18 条（世代切换未重置派生状态）、第 22 条（并发假设未写明：streak 隐含「同一队列内连续失败」）
- 后果：在长队列里连续失败累积到 N 次后 `_failureStreak = 0` 才清零；但因为每次成功都清零，实际只在「整队都坏」时生效，与设计一致。真正的缺陷是 `playQueue` 换队列时未清零：若上一队列已连续失败 k 次（k 接近旧队列长度），新队列第一首失败即触发「停止」，用户看到「只错一首就停」。定 P2。

### audio_handler.dart:404-407 失败时仍向 UI 抛原始异常文本
- 级别：P3
- 事实：`_errorController.add('播放失败：$e')` 与 `errorMessage: '播放失败：$e'`
- 违反：第 30 条（名称/文案应表达意图）、第 13 条精神（把底层异常原文呈现给用户）
- 后果：通知栏/播放条出现 `DioException [connection error]…` 等英文栈信息，用户不可读；同时暴露内部实现细节。

### audio_handler.dart:246-252 `playSong` 覆盖 localPath 后 `indexOf`
- 级别：P3
- 事实：`_songs[existing] = _songs[existing].copyWith(localPath: song.localPath);` 然后 `await _playAt(existing)`（existing 分支）／新插入分支用 `_songs.indexOf(song)`
- 违反：第 17 条（标识符定位用相等性而非索引）
- 后果：`Song==` 只比 hash，若队列内存在两个同 hash 项（不同音质版本），`indexOf` 返回首个，可能播放到另一个版本。可达性低，定 P3。

### audio_handler.dart:517-531 随机/循环
- 级别：P3
- 事实：`_randomIndex()` 每次 `List.generate(...)..remove(_index)..shuffle()` 并在 shuffle 后取 `first`
- 违反：第 26 条（高频路径分配 + 全量 shuffle）、第 24 条（按需计算）
- 后果：千首队列每次切歌分配并洗牌一个 1000 元素列表（O(n) 分配 + O(n) shuffle），低端机上切歌有可感延迟；且 `first` 取的是洗牌后首元素，等价于随机但白做了 n-1 次交换。定 P3。

### audio_handler.dart:113-127 `_engineReadyController` 语义
- 级别：P3
- 事实：注释写「首次为 null，引擎就绪后推送真实 player」，但实现只在就绪时 `add(p)`，从不 `add(null)`
- 违反：第 31 条（注释与实现不符，属「复述了什么」且复述错了）
- 后果：后订阅者（如重建的 UI）拿不到「引擎尚未就绪」的事件，只能靠 `player` getter 判空兜底；注释误导下一位维护者写错初始化逻辑。定 P3。

**本文件小结**：A 项复核结论——`_playToken` 覆盖了 `fetchDetail`/`resolveUrl`/`setAudioSource` 三处关键 await 之后，`_applySource` 前后双检正确；**但 `await _player.play()` 之后缺校验**（P2），且 `stop`/`onNotificationDeleted`/`pause` 未作废世代（P1/P2），`playSong(existing)` 未自增 token（P2）。`_loading` 单点释放（F4-14/15/16）成立，无「关闸中又开闸」。

---

## 2. `lib/features/player/data/player_repository.dart`（353 行，全读）

### player_repository.dart:39-64 `ensureDfid` 的「简单防并发」
- 级别：P2
- 事实：`if (_registering) { await Future.delayed(300ms); return ensureDfid(); }` 递归轮询；`_registering` 在 `finally` 复位
- 违反：第 21 条（写操作必须具备去重键或本地提交锁；此处锁只是「等一等再重来」，不是去重）、第 22 条（并发假设只写在注释里且假设不成立）、第 25 条（递归重试次数无上限）
- 后果：首次播放并发的两个 `resolveUrl`（如连续点两首）都读到空 dfid，第二个白等 300ms 后若第一个仍未返回就继续递归等待（没有上限）；若第一个注册**失败**抛错并复位锁，第二个会再发一次 `/register/dev`——一次设备注册被重复提交，服务端产生两个 dfid，本地只保存其一。定 P2。

### player_repository.dart:76 / 128 `fetchDetail` 整体 `catch (_)`
- 级别：P1
- 事实：`} catch (_) { // 详情查询失败不阻塞播放 }` 后 `return song;`
- 违反：第 6 条（空捕获）、第 7 条（捕获一切，含编程错误）、第 9 条（失败不可观测）、第 10 条（编程错误进入业务降级）
- 后果：`Song.fromJson` 因上游字段类型变化抛出的 `TypeError`/`FormatException` 与真正的网络失败被同等对待，用户永久得到「未补全的 song」（无时长、无封面），且线上无任何日志可查。定 P1（长时间静默错误）。

### player_repository.dart:96-102 `fetchDetail` 的 `Map<String, dynamic>.from(detail)`
- 级别：P3
- 事实：`entries` 来自 `data.whereType<Map>()`（键类型未限定），随后 `Map<String, dynamic>.from(detail)`
- 违反：第 13 条（外部数据必须逐字段验证类型后再使用）
- 后果：若上游返回非 String 键（如 int 键 JSON 经某些解码路径），`from` 抛 `TypeError`，被上一条的空捕获吞掉 → 该歌永远补全失败。与上条同源，单列以示边界未校验。

### player_repository.dart:169-186 `resolveUrl` 的直连→kapi 回退
- 级别：P2
- 事实：`on ApiException`：只有 `errorCode == 20028` 才 rethrow，其余（含「歌曲暂无版权」「需要会员」这类**业务性拒绝**）一律回退 kapi
- 违反：第 11 条（降级没有区分「本路径不可用」与「资源本身不可用」；触发条件过宽）、第 8 条（同层失败语义不统一：有版权问题的歌会多打 5 档 kapi 请求）
- 后果：一首确实无版权的歌，直连正确判定后又被 kapi 重跑整条降级链路（最多 5 档 + 5 次 free_part ≈ 10 次请求、数十秒），最终仍报同样错误。用户感知为「点了没反应很久才报错」，且加重风控概率。定 P2。

### player_repository.dart:222-232 `_qualityFromBitrate` 的码率阈值
- 级别：P2（需与 `models.dart` 的 `AudioQuality` 序位交叉确认，见文件 3 结论）
- 事实：`if (r.bitrate >= 500000) flac; if (>= 192000) high; if (>= 96000) q320; else q128`——320000 bps 的普通 320k 曲落入 `>= 192000` → 判为 `high`
- 违反：第 15 条（单位虽已改为 bps，但档位边界与真实码率档不一一对应）、第 5 条（同一事实在 `_actualQuality` 里判断不同：kapi 路径 320000 → `q320`）
- 后果：同一首 320k 曲，直连路径显示「高品/high」、kapi 路径显示「320」，音质标签在两路径间漂移；若该值被下载链路复用还会选错档位。定 P2。

### player_repository.dart:337-346 `_actualQuality` 与 `_qualityFromBitrate` 阈值不一致
- 级别：P2
- 事实：`_actualQuality`: `<=192000 → q128`、`<=500000 → q320`；`_qualityFromBitrate`: `>=192000 → high`、`>=96000 → q320`（192000 在两处被判成 q128 与 high 两个不同档）
- 违反：第 5 条（同一判断两个来源）、第 17 条（跨层传递的换算不可追溯）
- 后果：128k（128000）在 `_actualQuality` 判 q128 正常；但 192000 恰好一档被判 q128、另一档被判 high，中间相差两个档位。UI 上表现为「刚播完的 320 歌，切到另一首后音质角标乱跳」。定 P2。

### player_repository.dart:257-260 / 302-320 `_resolveViaKapi` 第二段 free_part 的 `catch (_)`
- 级别：P3
- 事实：`} catch (_) { // 继续尝试下一档 }`
- 违反：第 6 条、第 7 条
- 后果：试听兜底期间 20028 风控/网络断开的差异被抹平，两层降级都失败后仅抛出**第一段**的 `lastError`（可能是「flac 需会员」），用户看到的错误与真实原因（被风控）不符。

### player_repository.dart:270-273 `priv_status` / `hash_offset` 作为试听判据
- 级别：P3
- 事实：`isPreview: _int(data['priv_status']) == 0 || data['hash_offset'] is Map`
- 违反：第 2 条（魔法字段/魔法值无具名常量、无注释来源）、第 29 条（该判据未见实测记录）
- 后果：判据若与上游实际含义不符，VIP 用户会被误标「试听」，或试听曲被标为完整曲；`hash_offset` 为 Map 才判定，若上游改为 List 则静默失效。定 P3。

### player_repository.dart:278-296 `canPlay` / `requiresVip` 传参形态含糊
- 级别：P3
- 事实：`canPlay(Map privilege)` 契约要求「权益条目」，但 `_songFailureMessage` 里以 `canPlay(data)` 传**整个 data**
- 违反：第 3 条（契约未声明输入形态）、第 13 条（同一函数两种输入形态靠 duck typing）
- 后果：当 `data['privilege']` 是 Map（嵌套对象）而非 int 位掩码时，`_int()` 返回 null → `value = 0` → `canPlay` 恒 true，错误文案退化为「音质 xxx 暂不可播放」，用户看不到「暂无版权」的真实原因。

### player_repository.dart:51-52 `_directPlay` 从 `_ref` 同步读取
- 级别：P3
- 事实：`KgPlayApi? get _directPlay => _ref?.read(kgPlayApiProvider);`，`_ref` 为可空
- 违反：第 2 条（依赖用可空偷懒，隐式依赖容器）、第 3 条（`_ref == null` 时静默退化为纯 kapi，无契约说明）
- 后果：任何未注入 Ref 的构造点（测试、后台任务、通知回调重建的实例）会**静默**走 kapi，播放受 20028 风控，而调用方毫不知情。定 P3（生产装配点目前注入了 Ref，故不升级）。

### player_repository.dart:322-326 `_proxyHttp` 名为代理实为恒等
- 级别：P3
- 事实：`static String _proxyHttp(String url) => url;`（注释已解释为何不再代理）
- 违反：第 30 条（名称与行为不符）、第 32 条（恒等包装属可删除的死代码）
- 后果：维护者按名字以为播放地址被代理过，排查「卡住/不能 seek」时会走错方向；恒等函数无功能价值。

### player_repository.dart:151-152 重复且错位的文档注释
- 级别：P3
- 事实：`/// 读取用户设置的默认音质（Hive settings['defaultQuality']，缺省 320）` 紧接 `/// 用户默认音质（与下载链路共用同一事实源）`，而函数体只有 `preferredQuality()`；注释声称的 Hive key 已不存在于本文件
- 违反：第 31 条（注释复述且与实现不符）、第 30 条
- 后果：读者会去本文件找 Hive 读取逻辑，浪费排查时间；「缺省 320」的真实定义在 `core/audio/preferred_quality.dart`，此处无法核对。

---

## 3. `lib/features/player/data/models.dart`（222 行，全读）

### models.dart:154-171 `Song.copyWith(clearLocalPath:)`
- 级别：通过（修复正确）
- 事实：`localPath: clearLocalPath ? null : (localPath ?? this.localPath)`，并保留 `localPath: null` 的默认参数只为兼容旧调用
- 违反：无（满足第 3 条：清除语义显式化；第 2 条：语义靠参数名而非文档）
- 结论：F4-15 修复确认成立——`localPath: null` 在原实现中确实是 no-op，`clearLocalPath: true` 才真正清除。`audio_handler` 的离线回退分支使用该参数，语义闭合。

### models.dart:8-40 `AudioQuality` 枚举与 `fallbackOrder`
- 级别：通过（结构正确）
- 事实：`q128('128','标准') < q320('320','高品') < flac('flac','无损') < high('high','Hi-Res') < superQuality('super','臻品母带')`；`fallbackOrder = [super, high, flac, q320, q128]`
- 违反：无
- 结论：由高到低序位与标签一致，降级遍历 `startIndex..length` 即「从期望档降到最低档」，正确。**据此确认** `player_repository._qualityFromBitrate` 的 `>=192000 → high` 会把 320 kbps 的普通曲标成 **Hi-Res**（差两个档位），是真实误标，非阈值口径差异。

### models.dart:34-40 / models.dart:60-62 未知音质一律降为 `q128`
- 级别：P3
- 事实：`fromString` 未命中即 `return q128`；`str(['quality'])` 为空串时同样返回 q128
- 违反：第 16 条（「未知」与「确实是 128」被合并为同一事实）、第 11 条（降级的退出条件缺失）
- 后果：上游新增音质标识（如 `ape`、`wav`、`dts`）或字段缺失时，UI 一律显示「标准」并据此发起 128 请求，用户以为自己的会员没用。定 P3（当前上游未见新档，故不升级）。

### models.dart:118-140 时长解析（秒/毫秒）——单位显式化
- 级别：通过（第 15 条落实）
- 事实：`setDuration(raw, {required bool millis})`，`duration/Duration/time_length` 按**秒**、`timelength/timelen/timeLength/info.duration` 按**毫秒**；首个非零来源胜出
- 违反：无（满足第 15 条「单位在命名与调用点显式」）
- 结论：修复正确。但有一处副作用见下条。

### models.dart:119-121 `setDuration` 的「首个非零胜出」策略
- 级别：P2
- 事实：`if (duration > Duration.zero) return;` —— 先遍历的 `duration/Duration/time_length`（秒）优先；`/privilege/lite` 若同时返回 `duration: 0` 与 `timelength: 254000` 则正确；但若返回 `duration: 254`（**毫秒**语义，254ms）则被当作 254 **秒**接受，后续 `timelength` 因已非零被丢弃
- 违反：第 15 条（字段名的单位映射是**白名单猜测**，注释即承认「按字段区分」；上游同名异义时无从发现）、第 14 条（边界未按实际响应校验量级）
- 后果：一旦上游某端点把 `duration` 改成毫秒（或反过来），时长变 1000 倍/1/1000，表现为「一首歌 4 分钟显示成 4 秒」或「进度条一开就结束」。当前无实测支持该风险，定 P2 而非 P1。

### models.dart:196-198 `Song ==` 只比 hash 且空 hash 相等
- 级别：P3
- 事实：`other is Song && other.hash == hash && other.hash.isNotEmpty`——空 hash 的两首歌永不相等（因为要求非空，实际是「空 hash 不等」）。反向看：`operator ==` 对不同音质/localPath 版本视为同一首
- 违反：第 3 条（相等契约未写明「同一 hash 即同一首」的后果）、第 17 条（标识符语义被隐式用于定位队列项）
- 后果：队列里同 hash 的在线版与离线版被视为同一项（`playSong` 已用 localPath 覆盖兜底，见文件 1 的 P3）；但若上游返回空 hash（如本地导入曲），`indexOf` 恒返回 -1 → 每次点击都插入重复项。定 P3。

### models.dart:174-196 `Song.fromJson` 的字段读取
- 级别：通过（第 13 条基本落实）
- 事实：所有取值经 `str(List<String>)` 或 `is Map` / `is List` / `is num` / `is String` 分支判断，无裸 `as Map` 强转（`json['info'] as Map` 有 `is Map` 前置）
- 违反：无
- 结论：无裸强转。唯一遗留是 `info['duration']` 等内部字段读的是 `Map<dynamic,dynamic>`，形态仍靠 `is num` 兜住，安全。

---

## 4. `lib/features/player/player_provider.dart`（225 行，全读）

### player_provider.dart:44-62 `audioPlayerProvider` 的「yield 当前值 + 订阅」窗口
- 级别：P2
- 事实：`yield handler.player; await for (final p in handler.engineReady) { yield p; }`；而 `engineReady` 来自**非 replay 的 broadcast** `StreamController`，且只在 `ensureEngineReady()` 里 `add(p)` 一次
- 违反：第 18 条（异步结果必须校验世代/当前值）、第 22 条（并发假设未写明：假定订阅一定发生在引擎创建之前）
- 后果：若引擎在 `yield null` 与真正订阅之间这一两个微任务内就绪（深链自动播放、或用户在上游 Provider 构建同帧内点播放），事件被丢弃且**再无第二次**，`audioPlayerProvider` 永久停在 null——正是注释里声称已修好的「进度条/播放键/时长全不更新」P0-1 复发路径，只是窗口更窄。修复方式（读一次当前值再订阅）未落地。定 P2（窗口窄，但后果是该 P0 症状）。

### player_provider.dart:35-39 `playerRepositoryProvider` 里 `ref.watch(kgClientProvider)` 作为副作用
- 级别：P2
- 事实：`ref.watch(kgClientProvider);` 只为「预热」，返回值丢弃；紧接着 `PlayerRepository(ref.watch(_apiClientProvider), ref)`
- 违反：第 2 条（副作用必须在签名或名称上体现）、第 5 条（同一实例被两处重建源共享）
- 后果：`watch` 意味着 `kgClientProvider` 或 `kugouApiClientProvider` 任一重建都会重建 `PlayerRepository`，进而重建 `audioHandlerProvider`——旧的 `TiernanAudioHandler` 持有的 `AudioPlayer`、七个 StreamController、`_songs`、`_index` 全部被弃用且不 `dispose`/`close`，而 audio_service 注册的仍是旧 handler。用户侧表现为：登录/换号后进度条与播放态失联、点歌无反应或双份播放。定 P2（是否重建取决于 core/providers 的依赖，本文件已足以判定「watch 用于副作用」不合理）。

### player_provider.dart:57-62 `audioEngineReadyProvider` 不是响应式的
- 级别：P2
- 事实：`final audioEngineReadyProvider = Provider<bool>((ref) => ref.watch(audioHandlerProvider).isEngineReady);` —— `isEngineReady` 只是普通 getter 读 `_initialized`，切 true 时没有任何 `ref.invalidate`/`notify`
- 违反：第 5 条（状态的派生视图未与源同步）、第 18 条（引擎就绪是异步结果，未进入可观察通道）
- 后果：UI 若在首帧读它（引擎必然未就绪）就永久拿到 `false`，用户会一直看到「音频服务启动失败」类提示，即使随后成功播放。定 P2。

### player_provider.dart:71-77 `queueProvider` 的刷新触发点
- 级别：P3
- 事实：`yield handler.songs; await for (final _ in handler.queue.stream) yield handler.songs;`；`songs` 是 `List.unmodifiable` 快照
- 违反：第 5 条（队列事实在 `_songs` 与 `queue` 两处表达，`_playAt` 改写 `_songs[index]` 后不 `_emitQueue()`）
- 后果：`_playAt` 把 `_songs[index]` 换成补全后的详情（补 cover/时长/清坏 localPath）时不广播队列，队列页/歌词页拿到的仍是旧对象——封面/时长在队列里显示不出来。重新播放同一首时才刷新。定 P3（UI 有 currentSong 兜底）。

### player_provider.dart:180-195 `recentPlayRecorderProvider` 的 fire-and-forget
- 级别：P3
- 事实：`RecentPlayStore.add(...).then((_) => RecentPlayStore.notifyListeners());` 无 `catchError`、无 dispose 后保护
- 违反：第 6 条（异常吞在未处理的 Future 里）、第 9 条（写失败无痕）、第 20 条（异步回调触及可能已销毁的作用域）
- 后果：Hive 写入失败（磁盘满/盒子未打开）会产生未捕获异步异常，Flutter 只在控制台报错；最近播放静默丢记录，用户「刚听的歌不在最近播放里」。定 P3。

### player_provider.dart:9 `import '../library/data/recent_play_store.dart'`
- 级别：P3
- 事实：player 特征模块直接依赖 library 特征模块的数据层
- 违反：第 4 条（分层单向：特征模块之间的横向依赖未收口到 core）
- 后果：library 改动会波及 player 的编译单元；两模块无法独立替换/测试。定 P3。

### player_provider.dart:196-206 `PlayerController.togglePlay` 的引擎未就绪分支
- 级别：P3
- 事实：`if (p == null) { if (!await ensureEngineReady()) return; await _handler.play(); return; }`
- 违反：第 11 条（此分支不检查「当前是否有歌」，直接 play()）
- 后果：队列为空时点击播放，`just_audio.play()` 处于无源状态，无异常但无声音，用户以为按钮失灵（无任何提示）。定 P3。

---

## 5. `lib/features/player/play_helper.dart`（92 行，全读）

### play_helper.dart:20-33 `playHomeSong` 的 `duration: Duration(seconds: s.duration)`
- 级别：待核（依 `home/data/models.dart` 的 `HomeSong.duration` 单位，见文件 15 结论；若上游是毫秒则升级为 P1）
- 事实：`Duration(seconds: s.duration)`，`s.duration` 为 `int`（或 double）
- 违反：第 15 条（单位仅靠调用点猜；`HomeSong.duration` 字段名不带单位）
- 后果：见文件 15 判定。

### play_helper.dart:18-21 / 50-53 四处 Song 构造逻辑重复
- 级别：P3
- 事实：`playHomeSong`/`playHomeQueue` 两处逐字段重复，`playPlaylistSong`/`playPlaylistQueue` 又重复一次
- 违反：第 1 条（单一职责：同一映射规则四处维护）、第 32 条（重复代码）
- 后果：上游模型加字段（如 `localPath`、`quality`）时只改一处，另一处静默退化——例如歌单页能离线播放、首页点击同一首却走在线解析。定 P3。

### play_helper.dart:34-46 `playHomeQueue` / `playPlaylistQueue` 不校验 index
- 级别：P3
- 事实：`playQueue(List<Song> songs, int index)` 有 `if (songs.isEmpty) return;`，但另两个入口直接把 `index` 透传；`TiernanAudioHandler.playQueue` 不做越界判断，`_playAt` 越界时 `return` 静默
- 违反：第 9 条（失败无反馈）、第 16 条（「无内容」与「下标错」不可区分）
- 后果：列表刷新后下标失效（异步刷新把 20 条变 18 条）时点歌，队列被替换但没有任何一首开始播放，UI 无提示。定 P3。

### play_helper.dart:20-21 `hash: s.hash ?? s.id`
- 级别：P3
- 事实：hash 缺失时用 `id` 顶替，二者语义不同（`FileHash` vs `audio_id`/`Audioid`，见 models.dart 注释）
- 违反：第 17 条（标识符精度/语义不可混用）、第 14 条（边界不校验）
- 后果：首页若某条返回 `id` 但无 `hash`，会拿错误标识去请求 `/privilege/lite` 与 `/song/url`，得到「无可用播放地址」；且 `Song==` 用该值当身份，与真实 hash 曲重复。定 P3（真实响应里 hash 普遍存在）。

---

## 6. `lib/features/lyric/data/krc_parser.dart`（304 行，全读）

### krc_parser.dart:87-96 逐字时间的行内基准
- 级别：通过（修复正确）
- 事实：`startMs: lineStart + int.parse(wm.group(1)!)`，`lineStart = int.parse(m.group(1)!)`
- 违反：无（满足第 15 条：relative-to-line 与 absolute 在调用点显式相加，并在注释里写明上游语义）
- 结论：PLY-01 修复成立。KRC 的 `<offset,dur,0>` 确为相对行首偏移，加上行首时间后才与播放进度同一时间轴；否则除第一行外全部提前。

### krc_parser.dart:99-104 行首无标签文本被静默丢弃
- 级别：P3
- 事实：正文由「逐字片段拼接 + `lastWordEnd` 之后的尾巴」组成；`lastWordEnd` 起点为 0 仅在**无任何** word 时成立，一旦存在 word 标签，第一个 `<` **之前**的文本不会被写入 `text`
- 违反：第 1 条（同一件事——「非标签文本不得丢失」——只做了一半）、第 31 条（注释只解释了尾部，未说明前缀为何可丢）
- 后果：形如 `[1000,2000]告白 <0,300,0>气球` 的行会渲染成「气球」，行首「告白 」丢失；截图上表现为个别行缺字。定 P3。

### krc_parser.dart:196-206 LRC 时长回填发生在排序之前
- 级别：P3
- 事实：回填循环用 `lines[i + 1].startMs`（**原始文件顺序**）算 `durationMs`，随后第 211 行才 `lines.sort(...)`
- 违反：第 18 条（产生的派生值未随排序后的有效序列重算）、第 5 条（时长事实由「文件顺序」这一已失效的假设生成）
- 后果：时间戳乱序的 LRC（手工编辑、多段时间戳未按升序）排序后时长仍按旧邻居计算，`endMs` 与下一行 `startMs` 重叠或留空，逐行高亮在乱序文件上跳变。当前上游多为升序，定 P3。

### krc_parser.dart:211 `lines.sort` 使用非稳定排序
- 级别：P3
- 事实：`lines.sort((a, b) => a.startMs.compareTo(b.startMs));` —— Dart `List.sort` 不保证稳定
- 违反：第 31 条（注释只写「必须升序」，未记录同时间戳多行的次序约束）
- 后果：同一 startMs 的多行（多时间戳副歌、内嵌翻译拆分）相对次序可能被打乱，译文与原文行的视觉配对偶发错位。定 P3。

### krc_parser.dart:214-236 offset 已在行内应用，但 `KrcLyric.offsetMs` 仍原样外传
- 级别：P2
- 事实：`startMs: line.startMs - offset`（含每个 word）后，仍 `return KrcLyric(..., offsetMs: offset, ...)`
- 违反：第 5 条（同一事实「偏移已生效」存在两份表达）、第 3 条（对外契约未声明 `offsetMs` 是原始元数据还是待应用量）
- 后果：调用方若按字段名把 `offsetMs` 再减一次（正是「解析器已经做了，UI 又做」的经典重复），歌词整体错位 2×offset；若调用方拿它做「已应用」判断则无害。当前需看 lyric_view 是否消费该字段——见文件 9 结论。

### krc_parser.dart:238-251 内嵌翻译的 1:1 对齐
- 级别：通过（修复正确）
- 事实：`if (embeddedTranslations != null && embeddedTranslations.length == lines.length)` 才逐行贴，否则 `debugPrint` 留痕后跳过
- 违反：无（满足第 16 条「缺失与空串分离」、第 9 条「降级留痕」）
- 结论：F4-23 修复成立；`isNotEmpty` 判断保证空译文不会把 `translation` 从非空改为空。唯一残留是长度不等时**完全不**贴（宁可无译），符合注释声明的取舍。

### krc_parser.dart:253-303 `_decodeLanguage` 的三种结构与兜底
- 级别：通过（结构覆盖正确）/ P3（兜底返回值）
- 事实：A) `{'languageList': [{'lyricContent': [[原,译],...]}]}` 取 `pair[1]`；B) 顶层 List（Map→content/text、List 对取 `[1]`、标量直取）；C) 纯字符串数组即 B 的分支；解析失败 `catch (_)` 后 `return value.split(RegExp(r'\r?\n'))`
- 违反：第 6 条（`catch (_)` 空体，仅靠函数末句兜底）、第 16 条（兜底把「解不开」变成「一段 base64 原文当译文」）
- 后果：加密/异形 language 块解码失败时，返回的是一行 base64 密文；因长度 1 ≠ 行数 N，第 238 行的 1:1 判断会把它挡掉，实际不显示——所以只是无效兜底，不会串行。定 P3。

### krc_parser.dart:52 / 281 `LineSplitter` 与 `dart:convert` 同名
- 级别：P3
- 事实：`import 'dart:convert';` 后又自定义 `class LineSplitter { List<String> split(String text) => text.split(RegExp(r'\r?\n')); }`
- 违反：第 30 条（命名与 SDK 公开类型冲突，读者无法判断用的是哪个）、第 26 条（每次调用新建 `RegExp`）
- 后果：后续维护者 `import` 里的 `LineSplitter` 被遮蔽，写 `const LineSplitter()` 时行为与预期不同（如 `const LineSplitter()` 在 SDK 里没有 `split` 直接方法）；每次解析整篇歌词多编译一次正则。定 P3。

### krc_parser.dart:20-40 `KrcLine.translation` 为可变字段
- 级别：P3
- 事实：`final` 修饰其余字段，`translation` 是 `String?` 可写，解析器在第 243 行原地 `lines[i].translation = ...`
- 违反：第 5 条（解析产物在「构造后」被再次修改，非构造期确定）
- 后果：解析结果被多页面共享（缓存复用）时，任何一处改写会影响所有持有者；目前只有解析器写，风险低。定 P3。

### krc_parser.dart:88-90 行首时间重复 `int.parse`
- 级别：P3
- 事实：`final lineStart = int.parse(m.group(1)!);` 写在 `for (final wm in _wordRe.allMatches(...))` 循环体内，每个词解析一次
- 违反：第 26 条（每条歌词行按词数重复解析同一字符串）
- 后果：一首 100 行 × 20 词的歌词多做 ~2000 次 `int.parse`，解析发生在切歌瞬间（非每帧），影响轻微。定 P3。

---

## 7. `lib/features/lyric/data/krc_decoder.dart`（102 行，全读）

### krc_decoder.dart:20-32 / 50-96 `KrcDecodeError` 四分类 + 双重形态尝试
- 级别：通过（修复正确）
- 事实：`emptyInput` / `invalidBase64` / `notKrcContainer` / `corruptPayload` 四类可枚举；`krc1` 头 4 字节校验后才 XOR；首次解压失败时按「头后另有 4 字节长度前缀」再试一次，两次都失败才返回 `corruptPayload`
- 违反：无（满足第 8 条「异常契约单一可穷尽」、第 9 条「失败可观测」、第 11 条「触发/次优/退出条件齐备」）
- 结论：F4-24/F4-25 修复成立。`krc1` 头 + 16 字节 key 循环 XOR + zlib 的顺序与上游一致；第二次尝试的 key 下标用 `(i + 4) % 16`，与「按绝对字节位置循环」严格同构，未引入错位。

### krc_decoder.dart:78-93 `on Object` 捕获
- 级别：P3
- 事实：`} on Object { ... } on Object { }`，内层空体只靠外层返回值兜底
- 违反：第 7 条（捕获一切对象，含 `RangeError`/`StateError` 等编程错误）、第 10 条（编程错误被归类为 `corruptPayload` 业务失败）
- 后果：若 `ZLibDecoder` 抛的不是数据错误而是实现错误（如内存不足的 `OutOfMemoryError`），会被报成「歌词损坏」，线上永远查不到真实原因。定 P3（该分支只处理字节级数据，实际风险低）。

### krc_decoder.dart:99-101 `decode()` 兼容旧入口
- 级别：P3
- 事实：`static String decode(String base64Content) => decodeDetailed(base64Content).text;` 注释自认「新代码请用 decodeDetailed」
- 违反：第 32 条（「仅供以后可能用」的兼容壳）、第 8 条（两个对外入口，异常语义不同：一个返回空串、一个返回枚举）
- 后果：任何仍走 `decode()` 的调用点会把「密文损坏」退化成空歌词，F4-24 的修复在那条路径上失效。是否仍有调用点需看文件 8（lyric_repository）。

---

## 8. `lib/features/lyric/data/lyric_repository.dart`（236 行，全读）

### lyric_repository.dart:23-46 搜索候选的缓存键与裸强转
- 级别：通过（修复正确）
- 事实：`MemoryCache.keyOf('/search/lyric', query)`（hash/keywords/album_audio_id/duration 全部进键）；`if (raw is! Map) continue;` 后再 `Map<String, dynamic>.from(raw)`；`id`/`accesskey` 逐字段判空并排除 `'null'`
- 违反：无（满足第 23 条「键覆盖全部影响结果的维度」、第 13/14 条「边界逐一验证」）
- 结论：F4-26/F4-27 修复成立，未发现 `as Map<String, dynamic>` 裸转残留。

### lyric_repository.dart:41-46 缓存直接存/取可变 Map
- 级别：P3
- 事实：`MemoryCache.instance.set(cacheKey, data, ...)` 存入的是 API 返回的同一个 Map 实例，命中时原样返回；`findCandidate`/`_fetchLyricByFormat` 都直接读该实例
- 违反：第 24 条精神（缓存应保存不可变快照）、第 5 条（同一份数据两个可变持有者）
- 后果：任何调用方原地修改返回 Map（当前的调用方没有，但 `LyricRepository` 是跨模块公共层）都会污染缓存，表现为「同一首歌歌词偶发错行且重启才恢复」。定 P3。

### lyric_repository.dart:88-131 `_fetchLyricByFormat` 的四种内容形态与降级
- 级别：P3（形态假设）
- 事实：`decodeContent` 优先，**无论 format 是 krc 还是 lrc 都直接当明文**；仅当 `decodeContent` 缺失且 `format == 'lrc'` 时才把 `content` 当 Base64 解；`format == 'krc'` 走 `KrcDecoder.decodeDetailed`
- 违反：第 29 条（`decodeContent` 对 LRC 一定是明文这一结论无实测样本支撑）、第 3 条（契约未写明 decodeContent 与 content 的互斥关系）
- 后果：若上游对 LRC 也返回 Base64 的 `decodeContent`，解析器拿到 Base64 串后 `lines.isEmpty` → 返回 null → 用户「暂无歌词」，且降级链已被消耗（krc→lrc 只降一次）。定 P3（待实测）。

### lyric_repository.dart:114-118 LRC Base64 失败静默
- 级别：P3
- 事实：`} catch (_) { // 歌词是可选内容，任何解码异常都不应影响播放  return null; }`
- 违反：第 9 条（失败无用户反馈也无日志）
- 后果：与同文件 KRC 分支（有 `debugPrint`）不对称：KRC 坏能查日志，LRC 坏查不到。定 P3。

### lyric_repository.dart:132-140 `fetchLyric` 用 null 同时表示「无歌词」与「全部失败」
- 级别：P2
- 事实：`_fetchLyricByFormat` 返回 null 有两种来源（上游确实无词 / 解密与解析全失败），`fetchLyric` 在 LRC 也 null 时直接 `return null`
- 违反：第 16 条（「确实为空」与「请求失败」未分离）、第 9 条（只有 krc→lrc 那一条留有日志）
- 后果：网络断开时歌词页显示「暂无歌词」，用户以为这首歌没词，不会重试；实际重试即可。定 P2。

### lyric_repository.dart:150-176 `ensureTranslation` 缓存命中即整体返回
- 级别：P2
- 事实：`final cached = await LyricTranslationCache.instance.get(...); if (cached != null) { for (final i in missing) { ... } return lyric; }`
- 违反：第 11 条（降级/缓存路径缺少「部分失败继续补」的退出条件）、第 16 条（「部分译文」与「完整译文」同一状态）
- 后果：某次翻译第 2 批失败（该批未入缓存，符合 F4-32 设计），首次写入的缓存只含第 1 批；此后每次进入都命中缓存、只补第 1 批并立即返回，「后半首歌词永远没有译文」，直到歌词版本号变化。用户看到译文只到半首，且刷新无效。定 P2。

### lyric_repository.dart:178-211 批量翻译的下标映射
- 级别：通过（修复正确）
- 事实：`translations[missing[i + j]] = value;`（`i` 为批内起点，`j` 为返回序号），`n = min(translated.length, batch.length)`，空串跳过
- 违反：无（满足第 17 条「索引全程保持为全曲行下标」）
- 结论：F4-32 修复成立——返回条数不足时不再用原文补位，也不会把半批结果写进缓存（`translations` 只含真实返回项）。

### lyric_repository.dart:213-218 缓存写入「仅成功部分」
- 级别：通过（修复正确）
- 事实：`if (translations.isNotEmpty) await LyricTranslationCache.instance.set(lyricId, '$targetLanguage@$versionKey', translations);`
- 违反：无（满足第 23 条：语言 + 歌词版本并入键）
- 结论：F4-31 修复成立，键维度 = 歌词 id + 目标语言 + `行数-内容哈希`，不存在串数据。注意与上面 P2 的交互：写侧正确、读侧过早返回。

### lyric_repository.dart:220-230 `_lyricVersionKey`
- 级别：P3
- 事实：`hash = (hash * 31 + code) & 0x7fffffff`，返回 `'${lines.length}-$hash'`
- 违反：第 25 条（哈希空间仅 31 位，理论上可碰撞）
- 后果：31 位空间在单曲维度内碰撞概率可忽略（需同长度 + 同哈希），仅理论风险；但译者改一两个字符后哈希不同会整首重译，浪费一次全量翻译请求。定 P3。

### lyric_repository.dart:66-69 / 10-12 `ArgumentError` 与 null 混用的契约
- 级别：P3
- 事实：`throw ArgumentError.value(format, 'format', '仅支持 krc 或 lrc')`；其余失败一律 `return null`
- 违反：第 8 条（同层对外异常类型不统一：调用方要么处理 null 要么处理 ArgumentError，且 `format` 只在编译期已知，属编程错误）
- 后果：调用点若传错 format（内部写死字符串，风险低）会以未捕获异常形式炸在 UI 层。定 P3。

---

## 9. `lib/features/lyric/presentation/lyric_view.dart`（287 行，全读）

### lyric_view.dart:71-89 `_scrollTo` 未计入 120px 顶部 padding
- 级别：P2
- 事实：`var offset = 0.0;` 起累加各估算行高，`final target = (offset - viewport / 2).clamp(...)`；而 `ListView.builder` 的 `padding: EdgeInsets.symmetric(horizontal: 24, vertical: 120)` 使第 0 行顶部位于滚动坐标 120 处，代码里没有任何 `+120`
- 违反：第 31 条（F4-34 注释明确写「扣除顶部 padding」，实现里没有，注释在假装已修）、第 17 条（视图坐标与列表坐标两套基准混用）
- 后果：自动跟随的每一行都恒定偏高 120px（约两行），当前行落在视口上方 1/4 处而非中间；用户会觉得「歌词一直卡在屏幕上部」，且随行高估算误差再叠加。定 P2。

### lyric_view.dart:95-101 / 168-176 每 tick 全列表重建，与注释声明相反
- 级别：P3
- 事实：注释写「只让当前行随位置变化，其余行保持不变（元素 identity 稳定，Flutter 会跳过重建）」；实际 `_LyricLineTile(... posMs: posMs ...)` 把每次都变的 `posMs` 传给**每个**可见行，且 tile 不是 const、没有 `shouldRebuild` 判断
- 违反：第 31 条（注释描述的行为与实现不符）、第 26 条（每 200ms 重建可见 10 行并重新分配 `TextSpan` 列表）
- 后果：逐字高亮要求每行都拿到 posMs 才成立，重建不可避免；但注释会让后来者以为有优化而不再处理，长列表滚动的掉帧无从优化。定 P3。

### lyric_view.dart:187-198 相邻索引比较用 `!=` 而非身份
- 级别：P3
- 事实：`if (oldWidget.lyric != widget.lyric)` —— 未重写 `KrcLyric.==`，等价身份比较
- 违反：第 2 条（依赖隐式身份语义）
- 后果：若将来给 `KrcLyric` 加值相等（如缓存复用同一实例），换歌后 `_currentIndex` 不重算，首帧高亮停在上一首的行号。定 P3。

### lyric_view.dart:160-166 空歌词只显示「暂无歌词」
- 级别：P3
- 事实：`if (lines.isEmpty) return Center(child: Text('暂无歌词'))`
- 违反：第 16 条（「加载中 / 纯音乐 / 解密失败 / 确实无词」被合并）
- 后果：与文件 8 的 P2 同源，UI 侧无重试入口；用户无法判断是网络问题还是真没词。定 P3（加载中的区分由页面层负责，故不升级）。

### lyric_view.dart:181-186 用户滚动暂停的判据
- 级别：P3
- 事实：`if (n is ScrollStartNotification && n.dragDetails != null || n is UserScrollNotification) _lastUserScrollAt = DateTime.now();`
- 违反：第 2 条（魔法 5 秒 + 依赖 Flutter 通知细则的隐式假设，未写明）
- 后果：若 `animateTo`（程序化滚动）也触发 `UserScrollNotification`，自动跟随每滚一次就自锁 5 秒，长段无行变化后恢复时表现为「歌词跟不上」。当前实现依赖 Flutter 只对用户拖拽发 UserScrollNotification 的细节，未注释说明，换版本即可能回归。定 P3。

### lyric_view.dart:288 `_buildOriginal` 大括号与函数名同行
- 级别：P3
- 事实：`Widget _buildOriginal(ThemeData theme, Color primary) {    if (line.words.isEmpty) {`
- 违反：第 30 条精神（可读性/格式一致性，`dart format` 未通过）
- 后果：无功能影响，但说明该文件未过格式化门禁，后续 diff 噪音大。定 P3。

### lyric_view.dart:212-232 逐字高亮判定
- 级别：通过
- 事实：`isPast = posMs >= w.startMs + w.durationMs`、`isNow = posMs >= w.startMs && posMs < w.startMs + w.durationMs`；绝对毫秒与 parser 输出的绝对 `startMs` 同一时间轴
- 违反：无（满足第 15 条：posMs 与 word startMs 都是全曲毫秒）
- 结论：与 krc_parser 的 PLY-01 修复配套正确；若 parser 未加行首时间，此处会整首错位，反向印证修复必要。

---
