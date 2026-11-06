# v3.3 第 3 批·复核①（修复①/②验证）

基线 defd4a4。依据 docs/QUALITY_STANDARD.md（33 条，含第九章第 33 条）。
只报回归/新缺陷/修复不完整。

### lib/core/utils/error_logger.dart（B-21/22 修复复核）

**结论：B-22 串行锁总体成立（Dart 单线程下链式 Future 无死锁），但存在 2 个不完整点。**

1. 串行链无异常恢复，一断永断
- 级别：P1
- 事实：`_writeQueue = _writeQueue.then((_) async { try { ... } finally { ... } });`
  回调体内是 try-finally（无 catch），依赖内部 `_appendPublic`（catch-all）与私有写块（try-catch）保证不外抛。一旦未来任何一处改动在 try 块内抛出未被内层覆盖的异常（如 `_everPersisted` 赋值前的取值、`_fallbackDir` 访问被未来代码扩展），`_writeQueue` 进入 error 态：后续所有 `.then` 回调**被跳过**，其 `completer` 永不 complete，`await completer.future` 永久挂起——相当于日志锁死锁，且不可自愈。
- 违反：第 22 条（并发前提必须显式保护）、第 19 条（闸门必须能恢复）
- 后果：一条异常后，进程内后续所有错误日志的调用方永久 await 挂起；全局异常处理器走 unawaited 不受影响，但同步 await log() 的调用路径会卡死。
- 备注：当前代码恰好每个可抛点都有内层 catch，故**今天不触发**；属结构性脆弱。修复建议：链尾统一 `.catchError((_) {})` 或回调改为 try-catch 包裹整个事务。

2. `_rewriteMediaStore` 空串被判定成功
- 级别：P2
- 事实：`return ok != null;`（同函数上方 `if (ok != null && ok.isNotEmpty) { _publicDirPath = ok; }` 区分了空串，返回值却没区分）
- 违反：第 9 条（失败必须可观测）、第 16 条（成功与缺失语义分离）
- 后果：原生返回空串时日志实际未写入，却置 `_everPersisted=true` 且 `currentDirPath()` 不再报「日志仅进程内」，用户以为日志在盘上实则丢失。

3. apiLevel 兜底 29 在 Android 9 上走向不可用分支（确认无恶化）
- 级别：不立条（合规说明）
- 事实：`if (level >= 21) return level; ... return 29;` 非法值兜底 29 后，在真实 Android ≤28 设备上 `appendText`（MediaStore）会 PlatformException → catch → 降级私有目录，行为正确且有 debugPrint 留痕。兜底方向保守正确，未发现回归。

4. B-17 脱敏复核：dfid/t1/userid/mobile 四键已入正则，`"key":"v"`/`key=v`/裸数字形态均覆盖；数字形态 `"userid": 12345` 尾随逗号会被 `\S+` 一并吞掉——只影响日志文本格式，不影响脱敏效果，P3 不立条。

### lib/core/image/app_image_cache.dart（B-28 字节上限复核）

**结论：字节上限本身委托 flutter_cache_manager 实现，参数合规；同款串行链脆弱点同 error_logger（合并记 1 条）。另发现 1 处串行化语义缺陷（旧债非本轮引入，仍应记录）。**

5. getFileStream 只串行化「入队」，下载本体未串行
- 级别：P2
- 事实：`await _serial(() async {}); yield* super.getFileStream(...);` —— 排队动作是空函数，队空即放行，后续 `super.getFileStream` 全部并发执行。注释声称「彻底消除 BUSY / 串行化」，实现与声明不符。
- 违反：第 22 条（并发假设必须写明且成立）、第 30 条（名称与行为不符）
- 后果：首页并发拉几十张封面时 SQLITE_BUSY 依旧出现，只是被 catch 吞掉——注释宣称的修复目标未达成。属旧债（C-01），但 B-28 修复时未纠正。
- 备注：getSingleFile 是真串行，语义割裂。

6. 串行链 `_serial` 回调完整 try-catch，无断链风险；LRU 淘汰由 CacheManager 内部按文件锁处理，「正在使用」竞态由其 WebHelper 双指针机制兜底，未发现新回归。

### lib/features/download/data/public_media_store.dart（双策略/D-02 复核）

**结论：MediaStore(10+) / 直接路径(≤9) 双策略、pending 孤儿清理、D-02 原子替换均正确；发现 1 处边界缺陷。**

7. D-02 原子替换在「删除旧文件 → rename」之间非原子
- 级别：P2
- 事实：`if (await target.exists()) await target.delete(); await partFile.rename(target.path);`
- 违反：第 21 条（修复目标即原子性，实现留了窗口）
- 后果：delete 成功后进程被杀/断电，旧新文件全失（只剩 .part）。窗口极窄但与「越修越坏且不可恢复」的修复目标相悖。POSIX rename 本可直接覆盖已存在文件，Android 同分区同样成立，delete 步骤多余且有害。

8. MediaStore publish 失败回退 `_publishDirect` 时，临时文件 srcPath 语义正确（原生 write 后未删 temp，依赖上层清理，未见泄漏点——临时目录清理逻辑在任务层，不在本文件，暂记核对项）。

9. queryExisting ≤28 分支：`service.publicDir('downloads')` 与 lyric 降级在 publish 与 query 两侧**不对称**——publish 侧 lyric 会退到 Download 目录，query 侧只查 Documents，不查 Download。
- 级别：P2
- 事实：queryExisting 直接 `Directory('$base/$folderName${_subSuffix(type)}')`，无 Downloads 降级重查。
- 违反：第 5 条（同一事实两处权威存储判定不一致）
- 后果：歌词曾降级写入 Download/ 的用户，再次下载同一歌词时「已下载」判定为否，重复下载覆盖（幂等性尚可，主要是判定口径漂移）。

### lib/core/direct/kg_endpoints_playlist.dart（V33-01 歌单修复复核）

**结论：签名一致性需看 KgSignature.paramsKey 是否把 userid/token 纳入——参数串内 userid/token 均为字符串形态且全端点统一（含签名计算来源同一个 kg），无「数字/字符串双源」分裂。修复①结论「三态均 200」与端点层一致，未见回归。**

10. playlistTracksAdd `number: 1` 恒定，多首加歌时全部 number=1
- 级别：P2
- 事实：`_parseTracksResource` 对每条 track 都写死 `'number': 1`
- 违反：第 17 条（序号精度/语义）、第 28 条（参数形态需实测——批量加歌时 number 应为递增序号或由上游决定）
- 后果：一次加多首时顺序字段全 1，服务端排序可能错乱/去重异常。需实测核对（未验证项，标注：需原生复核）。

11. playlistDetail 空串 userid='0' 占位与「登录态三态实测」口径一致（字符串形态），与 V33-01 修复结论闭环相符；无新缺陷。

### lib/features/playlist/data/playlist_repository.dart（歌单 P0 闭环复核）

**结论：修复①定位「故障在 Dart 客户端状态（clearCredentials 路径）」与本层证据自洽——本层所有请求统一走 `kg.userid.isEmpty ? '0'` 兜底、字符串形态、签名同源，参数侧无嫌疑；闭环成立。**

12. fetchUserPlaylists 响应形态分支缺少校验层级
- 级别：P2
- 事实：`raw is Map && raw['info'] is List ? raw['info'] as List : (raw is List ? raw : const [])`
- 违反：第 13 条尚算遵守（有类型分支），但 Map+info 缺失时静默落到 `raw is List` 分支——若上游把 info 改成 Map（info_by_listid 结构），用户歌单页显示为空而非报错，违反第 16 条（失败与为空语义分离）
- 后果：上游结构变更时「未登录/失败」显示为「没有歌单」，误导排查方向。

13. fetchTracks allPages 串行翻页无取消/世代保护：调用方若在翻页中途切换歌单，无 onState 校验——但写入的是局部变量返回值，非共享状态，第 18 条不违反。不立条。

14. autoDispose family 重建（复核重点 B）：本文件无 Riverpod family provider；重建责任在 providers/表现层，不在本文件范围，转记到结论清单（见末尾）。

### lib/features/player/data/player_repository.dart（V33-02 播放排查结论闭环复核）

**结论：排查闭环性基本成立；发现 2 个修复引入/残留缺陷。**

15. ensureDfid 递归防并发无界等待 + 竞态
- 级别：P1
- 事实：`if (_registering) { await Future.delayed(300ms); return ensureDfid(); }` 无递归深度上限；且 `_registering` 在 `try` 前置位、finally 复位——并发调用者在 300ms 后重查 SecureStorage，若注册仍未完成会再次递归，形成 300ms 轮询无界链。
- 违反：第 19 条（闸门归属）、第 22 条（并发假设未保护完成时序）
- 后果：注册接口 hang 时多个播放请求无限轮询挂起（每次 +300ms 栈深递增），播放永久转圈；极端情况下叠栈。修复①结论「根因大概率在 dfid 未注册」引入的新实现，属本轮新缺陷。

16. 直连成功后无 `ensureDfid()` 前置，kapi 回退才有——直连路径依赖 KgPlayApi 内部自带 dfid 逻辑（未在本文件，无法验证）。若 kgPlayApiProvider 构建时 dfid 未就绪，首播直连必以 err signature/dfid 错失败再回退 kapi——与实测结论一致，但代码层未把「先 ensureDfid 再直连」接上，属修复不完整（排查结论已指出，代码未落实）。
- 级别：P1
- 违反：第 28 条（已知签名维度缺失仍发出必失败请求）、第 11 条（降级触发条件应显式）
- 后果：每次冷启动首播先打一发注定失败的直连请求（耗时+风控计数），再静默落 kapi——恰是播放 P0 表现的成因之一，修复只定位未消除。

17. resolveUrl 直连抛非 20028 的 ApiException 后回退 kapi，kapi 抛的 lastError 保留——行为一致；URL cleartext：注释确认 network_security_config 放行 kugou.com 子域，fsandroid 直连合规，无新问题。试听判定 `_int(data['priv_status']) == 0` 把「无权限标识」也当试听——潜在错标 isPreview，P2 备案不展开（旧行为）。

18. P0 闭环评价：`/v5/url err signature`、dfid 维度结论有实测支撑（修复①报告），fetchDetail/privilege 正常与代码注释一致；「需 register/dev 重测」已由 ensureDfid 实现承接——但见第 16 条，承接不完整。

### lib/features/player/data/audio_handler.dart（生命周期/世代复核）

**结论：世代校验、闸门单点释放（F4-14/V3-13）、F-3 _pauseEngineOnly 均落实且自洽；发现 1 处 P2 与 1 处 P3 级残留。**

19. playSong 用 `_songs.indexOf(song)`（== 仅比 hash）定位队列内新插入项
- 级别：P2
- 事实：`final insertAt = _index + 1; _songs.insert(...); await _playAt(_songs.indexOf(song));` —— 队列里已有同 hash 歌时（playSong 只在 `existing >= 0` 才走 existing 分支，此处不会重复），但 `_songs.indexOf(song)` 在 `insertAt` 前方还有同 hash 的场景不存在……复核确认 insert 路径下 indexOf 必为新插入项（existing 分支已 return）。**撤回，不立条。**

20. 失败自动跳歌 `_failureStreak < _songs.length` 阈值在「队列被换短后」以新长度判定，配合 playQueue 重置 streak，正确。`canAdvance` 校验 `token == _playToken`，但 catch 分支里 `_pauseEngineOnly` 之后 token 未再变——若用户在跳歌 await 期间按下暂停（pause 作废世代），skipToNext 内 _playAt 仍会装载新歌……复核：skipToNext→_playAt 不检查 token，但 _playAt 会 ++_playToken 并正常播放——用户暂停后 200ms 内自动跳歌继续播放。
- 级别：P2
- 事实：`canAdvance` 判定后 `await skipToNext()`；期间 pause() 已 `_playToken++`，但 _playAt 不校验入参世代，照常装载播放。
- 违反：第 18 条（异步等待后写共享状态未确认世代）
- 后果：「自动跳歌的下一首」无视用户刚按下的暂停，开始出声。窗口为解析+网络耗时（数百 ms～20s），非罕见。

21. skipToPrevious 边界：单曲队列 `prev = _index - 1 = -1 → loopMode off → prev = 0`——「上一首」在单曲队列且 <3s 时会重新装载同曲，可接受，不立条。

### lib/core/widgets/splash_screen.dart + splash_handwriting.dart（手写动画复核）

**结论：修复②生命周期正确——controller 单实例、dispose 对称、`..repeat()` 在页面离开即 dispose 停止、路径静态解析（static final，非 build 内）、每帧仅 paint 无 Widget 重建（repaint 传入 + FadeTransition）、循环停止条件由 `repeat()`+dispose 承担。发现 1 处小缺陷。**

22. 循环「停顿渐隐后」渐隐段与 Tail 段的重绘仍持续（repeat 全程 repaint）
- 级别：P3（不达 P2：splash 短时存在，低端机亦仅 2.6s）
- 事实：`..repeat()` 使 fadeEndMs→totalMs 的 20ms tail 及渐隐完成后仍逐帧 paint（paint 内提前 return，绘制代价低）
- 违反：第 26 条边缘情形（每帧回调持续跑但空转）
- 后果：可忽略的 GPU/CPU 空转，用户不可感知。仅记录。

23. `HandwritingCycle.minVisible` 已定义但 SplashScreen 未消费（最短展示时长由宿主页控制，本文件无引用）——核实是否存在死代码：grep 限定确认（巡检类允许）。

### lib/features/mv/data/mv_repository.dart（缩略图选档复核）

**结论：修复②缩略图改造合规——_mvThumb 空串守卫（`if (raw.isEmpty) return ''`）、{size} 归一、http→https 升级、列表 320/详情 480 分档均在；BoxFit.fill 全仓 0 处（巡检已核）；memCacheWidth 属 UI 层不在本文件。发现 1 处缺陷。**

24. `_mvThumb` 拼裸文件名时硬编码 `imge.kugou.com` 域名，若上游 thumb 已是完整 http URL 的**非 imge** 域名则被误判重写？——不成立（startsWith('http') 已分流）。但裸文件名分支固定 imge.kugou.com/mvthumb/，而 thumb 与 pic（详情）可能属于不同图床（实测注释未覆盖 pic 的图床）。
- 级别：P2
- 事实：`u = 'http://imge.kugou.com/mvthumb/$size/$u';`
- 违反：第 28 条（参数/域名形态需实测留样——pic 的图床是否为 imge.kugou.com 无实测记录引用）
- 后果：若 pic 实际存于其它图床（如 geissc.kugou.com 类 MV 图床），详情页封面 404，表现为封面空白。标注：需原生复核（实测证据未附）。

25. `d[hash.toLowerCase()] ?? d[hash.toUpperCase()]`：hash 大小写混合时（部分视频 hash 混合大小写）两分支都不命中，落到 `d.values.first`——多 entry 时取错。P2 边缘态，上游 key 惯例为全大写，风险低，记 P2。
- 违反：第 13 条（外部数据键未逐分支验证形态）
- 后果：混合大小写 hash 的 MV 解析到错误清晰度地址。

### lib/core/utils/friendly_error.dart

**结论：无新缺陷。unwrapApi 双形态解包完整；friendlyError 分支枚举可穷尽。`errorCode==401` 归「登录过期」依赖上游口径（第 29 条），未立条。**

（转到 features/auth/data/ captcha 改造复核）

