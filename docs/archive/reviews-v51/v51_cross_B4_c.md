### F13 `lib/features/player/data/player_repository.dart`（506 行，完整读 1-506）

### lib/features/player/data/player_repository.dart:64-124 / 220-235 `ensureDfid` 失败后用 `/register/dev`（kapi 兜底）作为唯一注册路径，且失败异常对用户完全不可观测
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 27/33 条（kapi 只可作显式兜底，返回不可作判定依据）
- 依据：`ensureDfid()` 在缓存缺失时走 `_api.get('/register/dev')`（:88），注释 :80-85 明确写「走 kapi 中转……原生注册在 KgClient.registerDevice……真正缺失时走 kapi 兜底」——即运行时主路径是 kapi 而非原生 `userservice risk/v3/r_register_dev`；`data['dfid']` 为空时 `throw ApiException(-1, '注册设备失败：未返回 dfid')`（:90-92），`catch (e) { rethrow; }`（:118-119）无日志、无 ErrorLogger、无用户可见提示。`_resolveViaDirect`（:250）与 `_resolveViaKapi`（:350）都在最开始 `await ensureDfid()`；`resolveUrl` 的 `catch (e)` 分支（:224-235）只 `debugPrint` 并继续回退。统计核对：`audio_handler.dart:71` 会对播放异常调 `ErrorLogger.instance.log`，但 `ensureDfid` 抛出的 `ApiException` 在 `resolveUrl` 的 `on ApiException catch (e)`（:217-221）里若非 20028/非特殊档会静默落到 kapi 路径，而 kapi 路径又再次 `ensureDfid()` 抛同样异常。
- 影响：设备票据缺失（首次安装/清除数据/存储损坏）时，用户点播任意歌曲都会走到「注册失败 → 直连失败 → kapi 回退 → 再次注册失败」的闭环，界面表现为一直转圈或一句通用播放失败，且没有任何可检索日志说明是「kapi 注册未返回 dfid」；用户重试/重启都无法恢复，必须靠清除数据碰运气。第 33 条要求 kapi 返回必须标注「包装结果，需原生复核」，此处把它当成设备身份的唯一来源。
- 证据等级：静态推演（`_api.get('/register/dev')` 的实际网关分派不在本代理通读范围；按本文件注释陈述推演）

### lib/features/player/data/player_repository.dart:203-236 `resolveUrl` 的 `on ApiException catch` 只按 `requiresVerification`/`isSpecial` 上抛，其余业务错误（版权、需会员、地区限制）静默回退 kapi
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败可观测）、第 11 条（降级须有明确触发条件）、第 27 条
- 依据：`on ApiException catch (e) { if (requiresVerification(e) || preferred.isSpecial) rethrow; // 其它错误回退 kapi 再试 }`（:217-221）既没有 `debugPrint(e)` 也不带 `e` 的任何信息进入回退；`_resolveViaKapi` 从零开始重新按 `fallbackOrder` 打一遍 `/song/url`（:350-397），最终抛 `lastError ?? ApiException(-1, '没有可尝试的播放音质')`（:415），把直连已经明确给出的「歌曲暂无版权/需要会员/地区限制」覆盖成一句无因的失败文案。对照同方法 `catch (e)` 分支（:222-235）至少 `debugPrint` 留痕。
- 影响：用户点播无版权或付费歌曲，直连已返回明确原因，界面却显示「没有可尝试的播放音质」或长时间转圈后才失败；用户无法得知需要会员/无版权，客服日志里也查不到直连拒绝原因。回退对这类明确业务错误没有意义，却多打一轮请求。
- 证据等级：实锤

### lib/features/player/data/player_repository.dart:340 / 399-415 试听兜底第二轮的 `catch (_)` 空体 + 最终异常丢失所有中间错误，`data['status']` 判失败条件与 `canPlay` 口径不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 8 条（异常契约单一）、第 29 条（成功判定须逐端点确认）
- 依据：第二轮 `free_part` 试听循环（:399-413）`catch (_) { // 继续尝试下一档 }`（:411-412）空体吞掉所有异常，包括 `TypeError`、`DioException`、`ApiException`；最终 `throw lastError ?? ApiException(-1, '没有可尝试的播放音质')`（:415）只保留**第一轮**最后一档的错误，第二轮全部失败原因丢失。成功判定 `final errorCode = _int(data['errcode'] ?? data['error_code']); final status = _int(data['status']); if (errorCode != 0 || (status != null && status != 1))`（:359-363）与本文件 `canPlay`（:419-424，`status != 1` 且 `privilege & 8`）以及 REVIEW_SPEC 的「成功判定不统一」口径不一致；`_int(null)` 返回 `int.tryParse('null') == null`，`errorCode` 为 null 时 `null != 0` 为 **true**，即任何不带 errcode 的成功响应都会被判为失败并 `continue`。`dart analyze` 在 :340 也报 `unnecessary_null_comparison`（`r.bitrate != null` 恒真），属同一类类型契约漂移的信号。
- 影响：上游播放响应不带 `errcode` 字段（或字段改名为 `errorcode`）时，所有音质被当成失败、再走一遍试听、最后抛「没有可尝试的播放音质」，用户点播直接失败；日志里完全没有「某个字段缺失」的线索（第 29 条：成功判定口径未留样）。
- 证据等级：静态推演（上游真实返回形态未实测；判失败条件在本文件内可静态确证）

### lib/features/player/data/player_repository.dart:20-35 / 274-292 `PlayableResult.expectedBytes` 在直连路径用 `previewFileSize` 表示「整曲 JSON 声明字节数」，而 `isPreview` 时取 `offsetFileSize`，字段名与语义相反
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条（单位/语义必须显式）、第 30 条（命名即文档）、第 23 条（缓存键维度）
- 依据：`PlayableResult.expectedBytes` 注释（:27-31）声明「播放 JSON 声明的字节数……永久缓存实际文件只允许在 `(url, expectedBytes)` 与请求 JSON 完全一致时写入/复用」；但 `_resolveViaDirect` 中整曲用 `expectedBytes: result.previewFileSize`（:283），试听用 `result.offsetFileSize > 0 ? result.offsetFileSize : result.previewFileSize`（:278-281）。注释 :276-278 解释「`PlayUrlResult.previewFileSize` 是『JSON 声明字节数』通用字段，非仅试听专用」——即命名 `preview*` 承载整曲大小，`offset*` 承载试听区间。`_resolveViaKapi` 的 `_declaredBytes`（:444-453）又优先取 `hash_offset` 区间差值（试听区间），无区间才取 `filesize`。两条路径对「完整文件字节数」的取法来自不同字段，与 B3 已审「`declaredBytes` 在 kapi 回退路径可能取试听区间差值」相邻但不同：这里是直连路径字段命名与语义反转造成的跨层契约不一致。
- 影响：永久文件缓存按 `(url, expectedBytes)` 判身份，直连与 kapi 给同一 URL 算出不同的「声明字节数」时，缓存命中失败或把试听片段按整曲大小登记；用户重复播放同一首歌时反复回源下载，或被判定为损坏文件重新下载。
- 证据等级：静态推演（`PlayUrlResult` 字段来源不在本代理通读范围）

### lib/features/player/data/player_repository.dart:1-2 / 39-40 / 429-441 多个 import 与注释块为死代码或重复
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 31 条
- 依据：`import '../../../core/net/music_api.dart';`（:2）在 506 行内无符号引用（本文件只用 `KugouApiClient`、`CachedApiCall`、`ResourceCache` 相关符号，见 import 列表 :6-16；`kListTtl` 来自 resource_cache.dart）；:429-441 是两段重复的「播放地址不再走前缀代理」文档注释（:429-435 与 :436-441），内容几乎逐字相同却都不附着在任何方法/字段上，只后接 `_actualQuality`（:443）。`canPlay`/`requiresVip`（:419-427）在本文件内 `_songFailureMessage` 有调用 `canPlay`，`requiresVip` 也有调用，非死代码。
- 影响：无用户可见后果；维护者误以为存在代理层、或按注释去找 `music_api` 依赖会落空，定 P3。
- 证据等级：实锤

### 复核通过（F13）
- :70-78 / :116-122 `_registering` + `_registeringFuture` + `Completer` 让并发等待者挂在同一 Future 上，并在 `finally` 成对复位；`_registerRetries >= 3` 有界防无限轮询（第 19/21/25 条）。
- :100-112 dfid 注册结果三写同步（SecureStorage / `kgClient.device.dfid` / `KgDeviceStore.saveDfidSync`），且失败单独 `debugPrint`（第 5/9 条）。
- :145-192 `fetchDetail` 对「data 是 List」按 hash 精确匹配、未命中返回原 song，避免 A 歌用 B 歌详情；解析失败按 `TypeError/FormatException` 与网络失败分类留痕，且不阻塞播放（第 7/9/14 条）。
- :155-159 / :175-179 两个分支都显式 `copyWith(localPath: song.localPath)`，离线歌曲播过一次后不会被详情覆盖成在线播放（回归防护到位）。
- :243-248 `startIndex < 0` 时从最低档开始、特殊音源族内降级不越族边界、`requiresVerification` 时立即 break 保留 ssaCode（第 11/3 条）。
- :468-481 `_firstUrl` 用 `Uri.tryParse` + `hasScheme` + `host` 三重校验，拒绝畸形 URL（第 14 条）。

#### F13 `dart analyze lib/features/player/data/player_repository.dart`
```
8 issues found（7 error + 1 warning）
噪音归类：uri_does_not_exist ×2（package:flutter/foundation.dart、flutter_riverpod）
          undefined_class ×1（Ref）/ undefined_method ×4（debugPrint）
          warning unnecessary_null_comparison ×1（:340 `r.bitrate != null` 恒真，
          非项目自有类错误；已作为 F13 第 3 条的类型契约漂移佐证）
项目自有类错误：0（core/net/music_api.dart、core/api/kugou_api_client.dart、
          core/audio/preferred_quality.dart、core/direct/kg_play_api.dart / kg_client.dart /
          kg_providers.dart、core/storage/secure_storage.dart、core/resource/cached_api.dart /
          resource_cache.dart、core/domain/song.dart / quality.dart / response_policy.dart、
          core/foundation/errors.dart 相对 import 均存在）→ 合格
```

### F14 `lib/features/player/presentation/full_player_page.dart`（854 行，完整读 1-720 + 721-854）

### lib/features/player/presentation/full_player_page.dart:38-86 `currentLyricProvider` 把「无候选 / 解析失败」写成硬编码中文字符串，且 `LyricView` 从不消费 `error`，歌词失败态在 UI 上不可见
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（失败与空态语义分离）、第 9 条（失败可观测）、i18n 一致性
- 依据：`currentLyricProvider` 返回记录类型 `({KrcLyric? lyric, String? error, String? lyricId, String? songHash})`（:38-39），两个失败分支分别 `return (lyric: null, error: '暂无歌词', ...)`（:51-53）与 `return (lyric: null, error: '歌词解析失败', ...)`（:55-57），均为硬编码中文；注释 :35-37 明确宣称「`error` 字段区分『无候选/解析失败』与正常空，不与加载中混为一谈」。但 `_CoverOrLyricState.build` 只取 `final lyric = lyricAsync.value?.lyric;`（:541）与 `lyricId`/`songHash`（:543-544），**`error` 在全文件 854 行内零消费**；`lyric == null` 时 `AnimatedSwitcher` 的 child 走 `_CoverView`（:548-566），即切到歌词页看到的是专辑封面，不是任何错误文案。同时 `lyricAsync.isLoading` / `hasError` 也未被使用，加载态与失败态都呈现同一张封面。
- 影响：用户点「显示歌词」后，若歌词查询/解密失败或还在加载，界面毫无变化（仍是封面），也没有「重试」入口；英文/其它语言用户即使将来接了 error 也会看到中文。失败原因（无候选 vs 解析失败 vs 网络异常）全部折叠，用户反复点击切换按钮不会得到反馈。与 `LyricView` 的 `lyricEmptyGuide`（F11 第 1 条）叠加：即使 provider 返回了空 `KrcLyric`，也只显示一句「暂无歌词」引导。
- 证据等级：实锤

### lib/features/player/presentation/full_player_page.dart:432-461 `songMvProvider` 的 loading/error 态被折叠成「没有 MV」，MV 入口会闪烁或永久消失
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（加载/失败/确实为空语义分离）、第 9 条
- 依据：`final mvAsync = albumAudioId.isEmpty ? null : ref.watch(songMvProvider(albumAudioId)); final mv = mvAsync?.value; final hasMv = mv != null && mv.videoId.isNotEmpty;`（:435-438）；`hasMv` 为 false 时 `if (hasMv) ...[ SizedBox + Expanded(MV 按钮) ]`（:488-513）整块不渲染。既没有 `mvAsync?.isLoading` 的占位/骨架，也没有 `mvAsync?.hasError` 的提示或重试；`mv_provider.dart:19-25` 的 `findBySong` 异常会直接以 FutureProvider error 态传播（F12 第 2 条）。而同一行里的评论按钮明确用 `onPressed: albumAudioId.isEmpty ? null : ...` 保留「禁用态」以保证入口可发现（:447-460，注释 :428-431 也写明「绝不与 MV 有无绑定」），MV 按钮却没有任何等价处理。
- 影响：（1）切歌后 MV 查询结果未回来时入口行只有 2 个按钮，几百毫秒后突然多出 1 个按钮，用户点击位置随布局重排而偏移，容易误点；（2）网络失败时 MV 按钮永久消失，用户以为这首歌没有 MV，且无重试入口；（3）与同排评论按钮「保留禁用态」的一致性口径相反。
- 证据等级：静态推演（FutureProvider 的具体重建时机未实测）

### lib/features/player/presentation/full_player_page.dart:538-566 `_showLyric` 为 true 但 `lyric == null` 时按钮文案已变成「显示封面」，界面却仍显示封面
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 9 条（操作反馈）
- 依据：`_toggleLyric()` 无条件 `setState(() => _showLyric = !_showLyric)`（:529-532）；`AnimatedSwitcher` 的分支条件是 `_showLyric && lyric != null`（:548），只要歌词尚未就绪/失败就渲染 `_CoverView`。而右下切换按钮的图标与文案**只看 `_showLyric`**：`_showLyric ? Icons.album_outlined : Icons.lyrics_outlined` 与 `_showLyric ? context.l10n.showCover : context.l10n.showLyrics`（:578-585）。即状态机有 4 种组合，UI 只表达 2 种。
- 影响：用户点「显示歌词」后，按钮立刻变成「显示封面」，但屏幕内容还是封面且没有任何解释；用户会以为点击无效而反复点，实际每次点击只是把 `_showLyric` 在 true/false 间翻转。这是「操作 → 反馈」链路的直接断点，与上一条的 `error` 未消费叠加。
- 证据等级：实锤

### lib/features/player/presentation/full_player_page.dart:88-93 `_fmt` 与 `LyricView`/`SongTile` 的时长格式三套口径，`total` 为 0 时显示 `00:00`
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位/格式单一来源）、第 30 条
- 依据：`String _fmt(Duration d)`（:88-93）用 `inMinutes.remainder(60)` + `padLeft(2,'0')`，即 ≥1 小时显示为 `00:00`（小时被 remainder 丢弃）；`song_tile.dart:216-217` 用 `sec ~/ 60` 不补零、超过 60 分钟显示 `60:00`；`rank_repository.dart:97` 用 `Duration(milliseconds: ms)`。全屏播放器 :747-751 把 `_fmt(position)` 与 `_fmt(total)` 直接摆在进度条两端，`total` 默认 `Duration.zero`（:704）时显示 `00:00`，与「加载中/未知时长」不可区分。
- 影响：长音频（>1h）在播放器上显示错误时长；缓冲阶段进度条右侧显示 `00:00`，用户误以为歌曲时长就是 0 或文件损坏。三处格式互不统一，定 P3。
- 证据等级：实锤

### lib/features/player/presentation/full_player_page.dart:700-742 `_ProgressBar` 用 `total.inMilliseconds > 0 ? ... : 1.0` 兜底，`secondaryTrackValue: bufMs` 未夹到 `maxMs` 的 Slider 语义边界
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（边界值校验）、第 17 条（进度精度）
- 依据：`maxMs = total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0`（:706）；`posMs`/`bufMs` 都 clamp 到 `[0, total.inMilliseconds]`（:707-708），当 `total == Duration.zero` 时二者恒为 0，而 `maxMs` 是 1.0，Slider 显示一个可拖动的 0/1 轨道；`onChangeEnd` 里 `controller.seekTo(Duration(milliseconds: v.round()))`（:734）在 total 为 0 时仍会发起 seek（最多 1ms）。注释 :696 只说明「拖动期间用本地值，松手才 seek」，未说明这段兜底的触发/退出条件。
- 影响：切歌瞬间或时长未就绪时用户误触进度条，会向引擎发出一次无意义 seek，可能打断刚开始的播放；视觉上出现一个「有 1ms 长度」的假进度条。定 P3（边界态）。
- 证据等级：静态推演

### lib/features/player/presentation/full_player_page.dart:41-86 语言切换/歌词模式切换后 `currentLyricProvider` 不重新翻译，`ensureTranslation` 只在首次加载时调用一次
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存/结果键必须覆盖语言维度）、第 18 条（结果世代）
- 依据：`targetLang` 在 provider 内由 `WidgetsBinding.instance.platformDispatcher.locale` 取（:69-73），但 `FutureProvider.autoDispose` 的依赖只有 `currentSongProvider`（:40）、`lyricRepositoryProvider`（:45）、`lyricModeProvider`（:77）——`locale` 不是被 watch 的 provider，系统语言变化不会让该 Future 失效。`ensureTranslation(lyric, candidate.id, targetLang, songHash: song.hash)`（:80-81）只在本次 provider 求值时跑一次。统计核对：`lyricModeProvider` 来自 `core/theme/settings_provider.dart`，用户在设置页切「原文/双语/译文」会因 :77 的 watch 触发重算，但切 App 语言不会。
- 影响：用户把系统语言从中文切到英文（或反向）后回到播放页，双语歌词仍是旧语言译文；只有切歌或重进页面才可能刷新。用户在设置里改语言得到的是「部分界面变了、歌词没变」的不一致体验。
- 证据等级：静态推演（Riverpod autoDispose 在语言变化时的具体行为未实测）

### 复核通过（F14）
- :96-120 四态明确分离：`engineError` 常驻横幅 + 引擎失败且无歌曲时 `_EngineFailureView`（带「重试播放」）+ 无歌曲 `_EmptyPlayerView`（带「返回首页」）+ 正常态，页面不自行构造 Repository、不触网（第 5/9/16 条）。
- :69-86 `currentLyricProvider` 用 `songHash` 记录代际，翻译 await 后 `ref.read(currentSongProvider)` 再比对 hash，不一致则作废本次结果（第 18 条）；原文模式不触发翻译 API（第 24 条）。
- :541-560 `LyricView` 同时透传 `lyricId` 与 `songHash`，补丁代际校验的两个键都到位（与 F11 第 4 条的 null 分支风险相对：本调用方确实传了两个键）。
- :299-320 `_SongInfoHeader` 用 `MediaQuery.textScalerOf(context).scale(14)/14` 判大字号、`LayoutBuilder` 判窄屏，标题允许两行不截断（可访问性）。
- :513-535 `_CoverOrLyricState` 的 `_fadeCtrl`/`_fadeCurve` 在 `dispose()` 对称释放（第 20 条）。
- :730-740 进度条 `onChangeEnd` 先 `if (mounted)` 再 seek，异步/延迟回调确认对象存活（第 18/20 条）。
- :447-460 评论入口在 `albumAudioId.isEmpty` 时渲染禁用态而非消失，保证入口可发现（第 9 条）。
- :818-830 `_CoverPlaceholder` 用主题色，封面加载失败有确定占位（对比 F7 的三态混同，此处至少有占位）。

#### F14 `dart analyze lib/features/player/presentation/full_player_page.dart`
```
329 issues found（329 error）
噪音归类：uri_does_not_exist ×5（cached_network_image、flutter/material.dart、
          flutter_riverpod、go_router、just_audio 三方包缺失）
          undefined_identifier ×106 / undefined_method ×104 / undefined_class ×43 /
          creation_with_non_type ×31 / override_on_non_overriding_member ×19 /
          extends_non_class ×16 / undefined_super_member ×2 /
          super_formal_parameter_without_associated_named ×1 /
          mixin_with_non_class_superclass ×1 / mixin_of_non_class ×1
          （全部为上述 5 个包缺失导致 Widget/ConsumerWidget/Icon/context.l10n/
          LoopMode/FutureProvider 等符号无法解析的级联噪音）
项目自有类错误：0（core/image/app_image_cache.dart、app/di.dart、
          core/theme/settings_provider.dart、core/widgets/empty_state.dart、l10n/l10n.dart、
          auth/presentation/login_guard.dart、lyric/data/krc_parser.dart、
          lyric/presentation/lyric_view.dart、download/presentation/download_sheet.dart、
          mv/mv_provider.dart、playlist/data/playlist_repository.dart、
          playlist/presentation/add_to_playlist_sheet.dart、core/domain/song.dart、
          player_provider.dart、queue_sheet.dart 相对 import 全部存在）→ 合格
```

## 跨文件契约抽查（○ 文件，共 8 个：只读签名与调用点，不通读其余 ○ 文件）

抽查文件清单（≤8）：`app/di.dart`、`app/bootstrap.dart`、`core/audio/audio_service_bootstrap.dart`、`core/utils/friendly_error.dart`、`core/utils/update_checker.dart`、`core/theme/settings_provider.dart`、`core/widgets/error_retry.dart`、`features/rank/presentation/rank_detail_page.dart`。
辅助核对（仅统计/调用点，不计入 8 个）：`main.dart`、`settings_page.dart`、`play_helper.dart`、`full_player_page.dart` 已在 F14 通读。

### X1 `lib/core/utils/friendly_error.dart` + `lib/core/widgets/error_retry.dart` 两套「异常→用户文案」出口互不知晓，`friendlyError` 未解包，`errorClassification` 未复用
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 8 条（异常契约单一且稳定）、i18n 一致性
- 依据：`friendly_error.dart:3` 注释宣称「此 helper 是表现层解包的**唯一入口**」，提供 `unwrapApi`（:12-18）与把异常转中文的 `friendlyError`（:23-32）；统计核对全库 8 个文件调用 `friendlyError(`（登录页、设置页、歌单页、评论页、下载 provider 等）。而 `error_retry.dart:190-248` 另有一套 `errorClassification(context, error)`，按 `DioException`/`ApiException` 分类并使用 `context.l10n.networkErrorTitle/genericErrorTitle/...`（:195-246），被 `ErrorRetry` 组件（:22-24）与 9 个页面的错误态使用；`errorClassification` 对 `ApiException` 直接取 `error.message`（:230-236）而不是 `unwrapApi` + `friendlyError`，对 `DioException(error: ApiException)` 这种直连层包装形态（friendly_error.dart:5-7 明确描述）归类为通用错误文案而非 `needsVerification` / 登录过期文案。两套出口的文案集合也不同：一套全部硬编码中文（:26-31），一套走 l10n。
- 影响：同一条直连 20028 风控异常，在登录页/Toast 里显示「需要完成人机验证后重试」，在首页/搜索/歌单的 `ErrorRetry` 错误页显示通用「操作失败」；英文用户看到中英混排。用户按其中一处文案去操作（例如重新登录）在另一处得不到对应引导，且 `ErrorRetry` 的「技术详情」里虽有 raw，但主文案完全丢失了验证/登录过期语义。
- 证据等级：实锤（两套实现与调用点均可静态确证）

### X2 `lib/app/bootstrap.dart:18/21/23/53-79` 声明的看门狗与并行启动编排在 `main.dart` 中零调用，形成两套并行的启动事实源
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 32 条（死代码）
- 依据：`bootstrap.dart` 导出 `startupError`（:18）、`firstFrameRendered`（:21）、`startupWatchdog`（:23）、`startWatchdog()`（:53-59）、`markFirstFrame()`（:62-66）、`bootstrapServices()`（:69-79）。统计核对：全库除本文件自身外，只有 `main.dart:17` import 了 `openHiveBoxes`；`main.dart:141-165` 自己实现了 `_firstFrameRendered`、`_watchdog` 与 15 秒 `Timer`，`main.dart:127/160` 用的是 `_startupError`；`main.dart:107-110` 直接调 `AudioServiceBootstrap.start()`、`main.dart:204` 直接 `unawaited(PermissionGate.instance.ensureNotification())`。`startWatchdog`/`markFirstFrame`/`bootstrapServices`/`startupError`/`firstFrameRendered`/`startupWatchdog` 在全库无调用点。
- 影响：启动看门狗有两份 15 秒逻辑，其中 `bootstrap.dart:53-59` 那份会 `ErrorLogger.instance.log('first frame timeout', ...)`，但实际从不运行；用户遇到「卡启动屏」时只有 `debugPrint`（release 不可见），日志里查不到首帧超时记录。`bootstrapServices()` 里对通知权限/音频引擎失败的 `catchError` 留痕也从未执行，实际走 `main.dart` 的无 catchError 路径。
- 证据等级：实锤

### X3 `lib/app/bootstrap.dart:25-45` 开箱失败仅 debugPrint 且继续 runApp，登录/歌词/缓存等盒缺失时 UI 无任何可见提示
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 11 条（降级须有触发/退出条件）
- 依据：`openSafe` 的 `catch (e) { debugPrint('[bootstrap] openBox($name) failed: $e'); }`（:31-33）吞掉开箱异常后不重试、不记账、不通知 UI；10 个盒子（:36-45）任一失败都直接跳过。`main.dart:80` `await openHiveBoxes()` 后照常 `runApp`；`settings_provider.dart:8-14` 的 `_settingsBoxProvider` 在 `Hive.isBoxOpen('settings')` 为 false 时返回 null（内存态），`ThemeModeNotifier.set`/`LocaleNotifier.set`/`LyricModeNotifier.set`/`VerboseLoggingNotifier.set` 全部 `await _box?.put(...)`——box 为 null 时写操作静默变成 no-op。
- 影响：Hive 首次开箱失败（存储满/权限异常）时，用户在设置页改主题、语言、歌词模式、详细日志开关，界面当下生效但重启后全部回退；用户完全没有「设置未保存」的提示，也没有可检索日志（debugPrint 在 release 不可见），会把这归因为「App 记不住设置」而反复操作。
- 证据等级：静态推演（`main.dart` 的启动错误页是否展示 `_startupError` 未在通读范围完整核对；本代理只读到 :127 的赋值与 debugPrint）

### X4 `lib/core/utils/update_checker.dart:59-64` `currentVersion()` 失败静默兜底为 `'1.0.0'`，与「失败不得当成已是最新」的自身契约冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条（降级须有明确触发条件与退出条件）、第 9 条、第 16 条
- 依据：`currentVersion()` 的 `catch (_) { return '1.0.0'; }`（:62-64）空体吞异常且返回硬编码版本；而 `check()` 的注释 :77-79 明确「**失败时抛异常**：网络故障、接口异常都不能被当成『已是最新版本』」，`_fetchLatestRelease()`（:115-133）也严格区分 404 与其它失败。`_compareVersion(latest, current) > 0`（:94）在 `current` 被伪造成 1.0.0 时，任何真实版本号都会被判为「有新版本」。统计核对：`settings_page.dart:1009-1021` 拿到 `hasUpdate=true` 后弹更新对话框、`hasUpdate=false` 时 Toast「已是最新版本」。
- 影响：`PackageInfo.fromPlatform()` 在部分 ROM/安装渠道抛异常时，用户每次点「检查更新」都被提示有一个远高于当前版本的新版本（实际可能就是同一版本），引导去下载覆盖安装；失败原因在日志中完全没有留痕。与 :77-79 宣称的失败口径直接相反。
- 证据等级：实锤

### X5 `lib/features/rank/presentation/rank_detail_page.dart:57-73` + `lib/features/rank/data/rank_repository.dart:107-129` 加载更多的错误被静默吞掉且 `_error` 未清，失败后按钮布局不变、用户无反馈
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败可观测）、第 16 条
- 依据：`_loadMore()` 的 `catch (_) { // 静默：保留已有列表 }`（:68-70）空体，只有 `finally` 复位 `_loadingMore`（:71-72）；`_error` 这个字段只在 `_load()` 的 catch（:49-52）与重试按钮（:120-123）里被写/清，加载更多失败时从不清空也不赋值。首屏错误态的渲染条件是 `_songs.isEmpty`（:104-110）——第二页失败时 `_songs` 非空，永远走不到错误态。叠加 F10 第 1 条：`fetchRankSongs` 对形态异常返回 `total = songs.length`，`_hasMore = _songs.length < r.total`（:46、:66）会变 false，「加载更多」按钮被替换成 `noMore` 文案。
- 影响：用户点「加载更多」遇到网络失败，转圈结束后列表原样、按钮仍在（可反复点）却没有任何错误提示；若上游返回形态异常则直接显示「没有更多了」，用户以为榜单只有当前这几十首歌，无法重试也无从知晓是请求失败。这是「进入榜单 → 翻页 → 反馈」的断点。
- 证据等级：实锤

### X6 `lib/features/player/presentation/full_player_page.dart:69-73` + `lib/core/theme/settings_provider.dart:50-72` 歌词翻译取「系统 locale」而 App 有独立的 `localeProvider`，应用内切换语言后译文语言不跟随
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（结果键必须覆盖语言维度）、第 5 条（状态单一来源）
- 依据：`currentLyricProvider` 用 `WidgetsBinding.instance.platformDispatcher.locale`（:69-73）算 `targetLang`；注释 :67-68 明确写「取语言用 platformDispatcher 而非 BuildContext：Provider 是全局对象，没有 Element」。但 `settings_provider.dart:48-72` 提供 `LocaleNotifier`/`localeProvider`（应用内语言设置，持久化到 Hive），`main.dart:334/351` 把 `ref.watch(localeProvider)` 作为 `MaterialApp.locale`。即应用真实的界面语言事实源是 `localeProvider`，歌词译文却用另一份（系统 locale），且该值不是 Riverpod 依赖，语言变化不会触发 provider 重算（F14 第 6 条的落地证据）。
- 影响：用户在设置里把 App 语言切成英文（系统仍为中文）后，界面变英文但双语歌词译文仍是中文；反之亦然。用户「设置语言 → 返回播放页」这条路径得到不一致结果，且切歌前不会自行修正。
- 证据等级：实锤

### X7 `lib/core/audio/audio_service_bootstrap.dart:41-47` + `lib/app/bootstrap.dart:74-76` 并行 `ensureReady()` 的 `whenComplete` 无条件把 `_future` 置 null，可能让「成功」被后续调用者重复 init
- 级别：P3
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门须归属同一所有者）、第 22 条
- 依据：`_ensureStarted()` 里 `final f = _future ??= _init(); return f.whenComplete(() { if (_ready == false) _future = null; });`（:42-47）——`whenComplete` 在 `_init` 成功时 `_ready=true`，不清 `_future`；但多个调用者共享同一个 `f`，每个调用者都会注册一个独立的 `whenComplete`，且 `_ready` 是全局静态值，任一并发调用者观察到 `_ready == false`（例如 `ensureReady()` 在 `bootstrapServices` 与 `audio_handler.dart:59` 同时发起、其中一个尚未完成）就会把 `_future` 置 null，导致下一次播放重新跑一次 `JustAudioBackground.init()`。`ensureReady()` 的 `catch (_) { return false; }`（:97-100）也吞掉异常不留痕。
- 影响：极端并发下后台播放服务被重复初始化，可能出现通知栏控制短暂重复/前台服务抖动；`catch (_)` 让「初始化为何失败」只能从 `_error` 这个静态字段查，用户侧无额外提示。正常启动序列（main.dart:110 先 start、audio_handler 播放前 ensureReady）不易触发，定 P3。
- 证据等级：静态推演

### 跨文件复核通过（抽查）
- `app/di.dart:12-15` `kugouApiClientProvider` 恒 `ref.watch(kgDirectApiProvider)`，`lyricRepositoryProvider`（:21-23）注入同一实例；本批 ✅ 通读的 `home_repository.dart:13` 与 `rank_repository.dart:132`、`mv_provider.dart:7` 全部经该 provider 装配，**无一处 new 裸 `KugouApiClient()`**（第 27 条 + REVIEW_SPEC §5）。
- `core/widgets/error_retry.dart:25-75` 主文案 + 副提示 + 「重载」按钮 + 折叠「技术详情」（`SelectableText` + 复制）四位一体，绝不把原始异常直接上屏（第 9/14 条）；`Toast.copy`（toast.dart:45-50）与它形成「点文案即复制」的一致交互。
- `features/rank/presentation/rank_detail_page.dart:27-32 / 92-132` 首屏区分 `_error`（错误+重试）、`_loaded`（空态 `noData`）、未加载（进度圈）三态，且 `_load()`/`_loadMore()` 都在写状态前 `if (!mounted) return`（第 16/18 条）；`SongTile` 的 MV trailing 显式补足 48dp 触控区（与 F7 一致）。
- `features/player/play_helper.dart:24-52` HomeSong/PlaylistSong → Song 各只有一个转换点，hash 缺失时不用 id 冒充、时长显式 `Duration(seconds: ...)`（第 15/14 条）；`playQueue` 空列表早退（:86-89）。
- `core/utils/update_checker.dart:115-133 / 137-147` 404 与其它失败严格分离、`assets` 逐一 `is Map` 校验、更新说明截断 1200 字符（第 14/25 条）；`_compareVersion`（:150-190）按 semver 处理预发布后缀与 build number。

