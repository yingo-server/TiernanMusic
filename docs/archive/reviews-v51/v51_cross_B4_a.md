# v5.1 交叉审查 B4 · 视角 A（功能正确性）

- 范围：见任务书 43 文件；本代理通读 15 个 ✅ 文件，其余 ○ 文件做跨文件契约抽查（≤8 个）。
- 判据：QUALITY_STANDARD 33 条；视角 A 关注数据流与契约（model 字段、provider 依赖、状态机）。
- 只报问题，不修改任何代码文件。

---
## 1. lib/app/bootstrap.dart（80 行，完整读）

### bootstrap.dart:33-52 开箱失败被吞后不设失败标记，下游依赖盒的读写在本次进程内持续失败
- 级别：P2
- 违反：第 9/11 条（失败可观测、降级触发/退出条件）
- 依据：`openSafe` catch 内只 debugPrint，调用方无法得知某盒未开；后续使用该盒的模块（设备存储、歌词缓存等）将在其内部再抛错。启动阶段无重试、无退出条件。
- 影响：某盒损坏时冷启动后相关功能（如歌词缓存、设置持久化）整程失效，用户只看到功能异常无解释；日志仅 debugPrint，release 不可查。
- 证据等级：静态推演

### bootstrap.dart:63-69 看门狗触发后 timer 未置空且无停止机制，若首帧永不到达无法二次判定
- 级别：P3
- 违反：第 30 条（命名/行为一致）
- 依据：`startupWatchdog` 只在 `markFirstFrame` 中取消；触发日志后无后续动作，属一次性检查，正常。`startupError` 全局变量由 main.dart 外部写入，此处未见消费契约说明（写入点在本文件外）。
- 影响：无直接用户可见后果，整洁度。
- 证据等级：实锤（本文件内）

### bootstrap.dart:58 `startupError` 全局可变变量作为启动错误传递通道，非单一来源契约
- 级别：P3
- 违反：第 2/5 条
- 依据：全局 `Object? startupError` 由 main.dart 写、启动页读，无类型化异常契约（对比 B1 统一的 ApiException 体系），上游无法区分错误种类。
- 影响：启动错误展示粒度粗；跨文件全局可变状态是并发与测试障碍。无直接用户可见后果。
- 证据等级：实锤

## 2. lib/core/audio/audio_service_bootstrap.dart（103 行，完整读）

### audio_service_bootstrap.dart:40-46 失败重试无次数上限与退避
- 级别：P2
- 违反：第 11/25 条
- 依据：`_ensureStarted` 失败后 `_future = null` 允许无限重试；无重试计数、无退避间隔。若 init 恒失败（ROM 限制、渠道配置问题），每次点播放都重新走一遍失败流程并各写一条 ErrorLogger 日志。
- 影响：播放按钮每次点击都经历「等 init → 失败 → 友好错误」的完整延迟；日志文件被同一错误刷屏。
- 证据等级：静态推演

### audio_service_bootstrap.dart:33 静态 `_ready/_error/_future` 三态在失败时部分残留
- 级别：P3
- 违反：第 5 条
- 依据：`_error` 在一次成功重试后不清空（只有 `_ready=true`），`error` getter 会继续返回历史失败错误；消费方若同时读 `isReady` 与 `error` 会出现矛盾组合。
- 影响：诊断界面/日志可能同时显示「就绪」与旧错误；无直接用户可见后果（取决于消费方，属 ○ 抽查范围）。
- 证据等级：实锤（本文件内状态迁移）

复核通过：init 失败不缓存 Future（允许恢复）、失败留痕 ErrorLogger、不做超时放弃的注释理由充分、注释均为「为什么」性质。

## 3. lib/core/theme/app_theme.dart（278 行，完整读）

本文件为纯主题 token 装配，无数据流/状态机/网络契约。逐项核对：形状/动效常量具名（第 2 条✓）、深浅两套共享同一 token（✓）、无 I/O 无状态（第 24 条✓）、注释均为平台怪癖记录（第 31 条✓）。

### app_theme.dart:35-40 dark()/light() 每次调用都重新 `ColorScheme.fromSeed`
- 级别：P3
- 违反：第 24 条（惰性构建/不在每帧路径计算）
- 依据：`fromSeed` 涉及色调调优计算；若调用方（settings_provider/router，○ 抽查）在每次 setState 中调用 `AppTheme.dark()`，主题对象会反复重建。本文件自身无缓存。
- 影响：切设置/重建时的额外计算开销；低端机上卡顿可能，但通常只在重建时调用，后果轻微。
- 证据等级：静态推演（本文件内无缓存为实锤；调用频率待 ○ 抽查）

复核通过：无魔法值、无功能性问题，theme 层零缺陷。

## 4. lib/core/utils/friendly_error.dart（33 行，完整读）

### friendly_error.dart:24-25 错误码集合（1011/30791/401）为字面量散落，与 foundation 层错误码常量未对齐
- 级别：P3
- 违反：第 2 条（魔法值须具名常量）、第 8 条（异常契约单一）
- 依据：`switch (api.errorCode) { 1011 || 30791 || 401 => ... }` 硬编码错误码；B1 已把 20028 抽为常量 `kVerificationRequired`，此处未复用任何常量体系。
- 影响：上游错误码语义调整（新增登录失效码）时此处静默漏判，用户看到原始 message 而非「登录已过期」；无崩溃。
- 证据等级：实锤

### friendly_error.dart:29-31 非 ApiException 的领域异常（如 UpdateCheckException、格式异常）统一折叠为「操作失败」
- 级别：P3
- 违反：第 16 条（语义分离）
- 依据：`return '操作失败，请稍后重试';` 对 DioException 网络超时与本地 StateError 之外的异常不区分；`UpdateCheckException.toString()` 返回英文 message，若上屏路径经 friendlyError 会被折叠（但 update_checker 由 UI 直接处理，待其核对）。
- 影响：网络失败与逻辑失败文案相同，用户无法区分「没网」与「功能坏了」。
- 证据等级：实锤

复核通过：unwrapApi 处理 DioException(error:) 包装链、注释解释「为什么」（A2-07 背景清晰）。

## 5. lib/core/utils/update_checker.dart（226 行，完整读）

### update_checker.dart:63-65 `_pickApkUrl` 无 APK 时回落 html_url——但该 URL 不是 APK 下载链接
- 级别：P2
- 违反：第 3 条（契约）、第 13 条（字段形态）
- 依据：`if (url == null && release['html_url'] != null) url = '${release['html_url']}';`，`html_url` 是 Release 网页地址而非安装包；`acceleratedUrl` 也据此生成。UpdateInfo.downloadUrl 的契约名暗示 APK。
- 影响：无 APK 资产的 release 下，用户点「下载更新」会跳到 GitHub 网页（走代理前缀），移动端网页上再找下载入口，体验断裂；若消费方直接当文件下载则得到 HTML 文件。
- 证据等级：静态推演（消费方在 B8 范围）

### update_checker.dart:196-204 `_splitVersion` 对非数字段清洗后解析，`1.2.3-beta` core 解析会把混入的字母剥掉
- 级别：P3
- 违反：第 14 条（边界校验）
- 依据：`int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0`：`"1.2a.3"` → `"1.2.3"`（应视为无效版本却当 1.2.3）；`"abc"` → 0。GitHub tag 形态不受控（第 14 条边界假设恶意）。
- 影响：畸形 tag 可能被判定为「无更新」或「有更新」误报；仅影响更新提醒，非核心功能。
- 证据等级：静态推演

### update_checker.dart:120-124 代理 URL 拼接 `$_proxyPrefix$url`：`$url` 是完整 https URL，前缀代理形态依赖代理端约定
- 级别：P3
- 违反：第 28 条（调用方式须实测）
- 依据：`acceleratedUrl: '$_proxyPrefix$url'`，`$url` 含 scheme；该前缀代理形态（`https://proxy/https://github.com/...`）是否被 `AppConfig.proxyBase` 服务支持未在本文件验证，也无实测留样说明。
- 影响：若代理不处理双 scheme，加速下载 404，用户点「加速下载」失败（是否有加速入口在 B8）。标注：未实测。
- 证据等级：未实测

复核通过：404 与网络故障语义分离（不把无 release 当最新）、失败必抛不静默、版本比较预发布规则正确（rc < 正式）、`currentVersion` 失败兜底留有 '1.0.0' 默认值。

## 6. lib/core/widgets/error_retry.dart（248 行，完整读）

### error_retry.dart:214-231 ApiException 分支未处理 needsVerification / DioException(error:) 解包链
- 级别：P2
- 违反：第 8 条（异常契约单一稳定）、第 3 条
- 依据：本文件自建 `errorClassification`，与 `friendly_error.dart` 的 `unwrapApi`/`friendlyError` 并存两套文案映射。`error is DioException` 分支直接落 genericErrorTitle，但直连层把 ApiException 包成 DioException(error: ApiException) 抛出（friendly_error 注释 A2-07 明言），故 20028「需要人机验证」「登录已过期」等分类在此处全部退化为通用错误文案。仅当调用方先 unwrap 再传 error 才正确——契约依赖调用方纪律，无类型强制。
- 影响：出现 20028/登录过期错误时，各页面 ErrorRetry 显示通用「出错了」而非「需要完成人机验证」，用户不知道要走验证流程；同一异常在 Toast 与 ErrorRetry 文案不一致。
- 证据等级：静态推演（解包链以 friendly_error.dart 注释为据；各页面传参方式待 ○ 抽查）

### error_retry.dart:222-231 ApiException 分支直接上屏 `error.message`
- 级别：P3
- 违反：与 friendlyError 的「1011/30791/401 → 登录已过期」映射不统一
- 依据：`friendly: error.message`，未做登录过期码翻译；两套映射（friendlyError vs errorClassification）对同一 ApiException 给出不同文案。
- 影响：登录过期场景 ErrorRetry 显示英文/原始 message，而 Toast 显示中文，体验不一致。
- 证据等级：实锤（两文件对照）

复核通过：技术详情折叠、可复制、可选中；`message` 参数显式注释「调用方需保证不含原始异常」；无状态泄漏（_TechDetail 为 StatefulWidget 自持展开态）。

## 7. lib/core/widgets/section_header.dart（60 行，完整读）

纯展示组件，无数据流契约。标题/副标题/action 布局无问题。文件后半部分注释提到「渐变色 Chip」但类体在文件 60 行处截止（GradientChip 在 gradient_chip.dart，○ 抽查）——注释与文件内容不完全对应，属轻微整洁度。
- 级别：P3，违反第 31 条；无用户可见后果；实锤（本文件内）。

复核通过：零缺陷组件。

## 8. lib/core/widgets/splash_handwriting.dart（304 行，完整读）

### splash_handwriting.dart:68-90 TweenSequence 权重硬算，与 HandwritingCycle 常量重复推导
- 级别：P3
- 违反：第 31 条（重复事实源）
- 依据：`fadeInStart = writeEndMs - 30` 的 30、fade 段 `weight: fadeMs` 等在 _buildLabelOpacity 与 HandwritingCycle 两处手写毫秒推导；若改 cycle 常量需同步两处，漏改则文字淡入与笔画时序错位。
- 影响：目前数值一致（writeEnd=1670、fadeIn 1670+260=1930<holdEnd=2290、fade 段 290、tail 段 20，权重总和=2600=totalMs，核对无误）。维护性风险，无当前用户可见后果。
- 证据等级：实锤（数值核对）

### splash_handwriting.dart:206-214 opacity 计算分段使用 `ms <= holdEndMs ? 1.0 : ...`
- 级别：P3
- 违反：无（与 TweenSequence 的 fadeOutStart=holdEndMs 一致）
- 依据：核对 holdEndMs=2290，fadeMs=290，fadeEndMs=2580，ms≥fadeEndMs 早退，公式一致。
- 影响：无。
- 证据等级：实锤

复核通过：controller dispose 对称（第 20 条）、PathMetric 缓存不每帧重建（第 26 条）、等比缩放不拉伸、单实例 repaint 驱动无 Widget 重建；默认 label 中文硬编码已注释说明由调用方传 l10n 覆盖。

## 9. lib/features/home/data/models.dart（271 行，完整读）

### models.dart:71-79 歌名/歌手从 FileName 拆分时未考虑「歌手名本身含 -」且回退顺序导致歌手可能取到歌名段
- 级别：P3
- 违反：第 13/14 条（外部数据解析）
- 依据：`if (displayName.isEmpty && fileName.contains('-')) { parts = fileName.split('-'); displaySinger = ...parts.first; displayName = parts.sublist(1).join('-'); }`：歌名内含 `-`（如 "周杰伦-晴天-Live"）时歌名残留 "-Live"；且仅当 `name` 为空才走此分支，歌单 `name` 字段本身已是 "歌手 - 歌名" 合并串时不拆分，列表显示歌手为空。
- 影响：歌单场景（`name` 合并串直接当 displayName）下 HomeSong.singer 为「未知歌手」或不拆分，界面歌手列缺失；显示层瑕疵，非崩溃。
- 证据等级：静态推演（字段来源实测注释自证歌单 `name` 为合并串）

### models.dart:104-115 时长单位判定依赖字段名枚举，未知来源的毫秒字段（如 `timeLen`）会按秒展示
- 级别：P2
- 违反：第 15 条（单位必须显式）
- 依据：秒字段枚举 `['duration','Duration','time_length']`、毫秒枚举 `['timelength','timelen','timeLength']`；若上游新增同义字段（首注释只列了 5 个来源），不匹配则 duration=0，按 '--:--' 展示；若上游某字段恰在两枚举之外但实为毫秒，无兜底判定（如按数量级 >10000 判毫秒）。
- 影响：新来源歌曲时长显示 `--:--`；静态可枚举的 5 个来源均已覆盖，回归风险为未来字段。
- 证据等级：静态推演

### models.dart:176-183 HomePlaylist.id 与 globalCollectionId 互相回填，两者可能同为数字 specialid
- 级别：P3
- 违反：第 3 条（契约：globalCollectionId 语义为 collection_ 形式）
- 依据：`id = numericId.isNotEmpty ? numericId : globalId`，`globalCollectionId = globalId.isNotEmpty ? globalId : numericId`。当上游只给数字 specialid 时 globalCollectionId 混入数字 ID，与注释「必须原样作为歌单路由参数」的 collection_ 契约不符；消费方若不校验前缀直接路由 `/playlist/<数字>` 会触发上游 20010。
- 影响：仅特定来源（无 gid 字段）歌单点入可能失败，表现为歌单详情加载错误。
- 证据等级：静态推演

复核通过：`trans_param.union_cover` 优先级、`_toInt`/`_toStr` 全分支类型验证（第 13 条达标）、singerinfo List/Map 双形态处理、dailyRecommend 用 null 区分「未登录」（第 16 条达标）、duration 秒/毫秒显式换算留注释（第 15 条意识到位）。

## 10. lib/features/lyric/data/krc_parser.dart（304 行，完整读）

### krc_parser.dart:71-74 / 92-96 KRC 行解析用 `int.parse` 无 tryParse，畸形行抛 FormatException 且整首解析失败
- 级别：P2
- 违反：第 13/14 条（外部数据逐分支验证）、第 6/10 条
- 依据：`int.parse(m.group(1)!)`（行首/字内时间）与 `int.parse(wm.group(1)!)` 均无捕获；正则 `(\d+)` 已限定纯数字，但超长数字串（如损坏文件）会抛异常向上冒泡，`parse()` 整体无 try/catch，一行坏数据导致整首歌词不可用。LRC 分支的 `double.parse(m.group(2)!)` 同理（正则已限数字，风险主要在异常边界缺失）。
- 影响：缓存或网络返回畸形 KRC 时歌词页抛错而非跳过坏行，用户看到错误态而非部分歌词。
- 证据等级：静态推演

### krc_parser.dart:130-141 无时间标签正文归并到上一行时，行首首个正文行之前的逻辑：leadingText 只在 lines 为空时累积
- 级别：P3
- 违反：第 16 条（缺失语义）
- 依据：`lines.isNotEmpty` 时合并到上一行；`leadingText` 仅在 `lines` 为空时写入，但若文件是「头部提示文本 + 中间一段无时间戳正文 + 时间行」，中间正文会被并入 leadingText 后又只展示在「lines 为空」的兜底——逻辑自洽。真正问题：`leadingText` 在存在正常歌词行时被完全丢弃（兜底只在 `lines.isEmpty` 时使用），头部版权信息在有歌词时静默丢失。
- 影响：头部提示文本（版权/译者）在正常歌词存在时不可见；轻微信息缺失。
- 证据等级：实锤（本文件控制流）

### krc_parser.dart:236-243 排序不稳定风险：同 startMs 多行（LRC 重复时间戳）排序后相对顺序由 sort 稳定性决定
- 级别：P3
- 违反：第 14 条
- 依据：`lines.sort((a,b) => a.startMs.compareTo(b.startMs))`，Dart List.sort 非稳定排序；同一时间戳的重复时间标签行（F4-17 特意支持）顺序可能颠倒，逐行翻译对齐（embeddedTranslations）在排序后按新顺序套用。
- 影响：同时间戳多行 + 内嵌翻译时译文错行；边缘场景。
- 证据等级：静态推演

### krc_parser.dart:279-300 `_decodeLanguage` 失败降级为 `value.split(RegExp(r'\r?\n'))`
- 级别：P3
- 违反：第 9 条（静默降级留痕）
- 依据：catch 块空体注释「不应导致原歌词消失」，降级返回按行分割 base64 原文——base64 单行时返回 `[value]` 一条「译文」，该行非译文而是编码串，若被上层当译文套用会显示乱码；降级无任何留痕。
- 影响：损坏 language 行时译文区显示 base64 乱码；无日志可查。
- 证据等级：实锤

复核通过：逐字时间加行首偏移（PLY-01）、LRC 多时间戳支持、duration 回填、offset 减法语义、翻译条数校验宁缺毋错——历史 F4 系列修复到位；`final line = lines[i]` 后重建对象避免改 final 字段（正确）。

## 11. lib/features/mv/data/mv_collection_repository.dart（159 行，完整读）

### mv_collection_repository.dart:88-92 未登录时 `setCollected` 返回 `false`——与「取消收藏失败」不可区分
- 级别：P2
- 违反：第 16 条（空/失败/未登录语义分离）、第 3 条
- 依据：`if (userid.isEmpty || userid == '0' || token.isEmpty) return false;`，与网络失败、解密失败同返回 false；调用方（mv_provider，○ 抽查）无法区分「未登录」与「操作失败」。
- 影响：匿名用户点收藏，UI 只能显示「失败」而无法引导登录；收藏状态实际未变。
- 证据等级：静态推演

### mv_collection_repository.dart:118-121 解密成功仅验非空即返回 true，未校验解密体内 status
- 级别：P2
- 违反：第 29 条（成功判定逐端点实测）、第 14 条
- 依据：注释自承「解出 status 才算真成功」，但实现是 `return decrypted != null;`——只要解密出任意内容（含上游业务失败响应体）即视为收藏成功；服务端拒绝收藏（风控/重复/参数错）但返回加密错误体时 UI 显示成功。
- 影响：收藏状态与服务端不一致，用户以为收藏成功，回到收藏列表却找不到该 MV；注释与实现直接矛盾。
- 证据等级：实锤（注释与代码对照）

### mv_collection_repository.dart:145-147 解密失败路径回退 `res.status == 200`
- 级别：P2
- 违反：第 8 条（主路径与回退路径异常形态一致）、第 29 条
- 依据：解密异常时回退用 HTTP 200 判定成功，与主路径「解密出内容」判定口径不同；且写操作回退到 HTTP 层判定意味着风控空包/错误包在解密失败时被误判成功——与注释自述修复的历史问题（HTTP 200 即成功）同型，只是换了一条路径残留。
- 影响：同一服务端失败在两条路径上结论相反；收藏态失真问题未彻底关闭。
- 证据等级：实锤

### mv_collection_repository.dart:62-70 `fetchCollected` 把 userid/token 同时放 params 与 data（POST body），查询串重复传登录凭据
- 级别：P3
- 违反：第 28 条（参数形态须实测）
- 依据：`params: {'plat':1,'page':...,'pagesize':...}` + `data` 里又带 page/pagesize，两处冗余；凭据进 URL 有泄露面。标注：参数形态未对照实测留样，无法确证哪一处才是上游所需。
- 影响：可能仅冗余；若上游按 query 优先读取，token 出现在日志/代理的 URL 中。
- 证据等级：未实测

复核通过：D-P0-2 已修 collect/cancel_collect 分流；AES/RSA 协议形态与 Node 对照注释详实；二进制 body（base64Decode）形态正确；fromJson 对 trans_param/audio_info/video_info 全部 is Map 验证（第 13 条达标）。

## 12. lib/features/mv/presentation/mv_player_page.dart（604 行，完整读）

### mv_player_page.dart:339-354 `_collected` 初始恒为 false，未从服务端查询当前收藏态
- 级别：P1
- 违反：第 5 条（状态单一来源）、第 3 条（契约）
- 依据：`bool _collected = false;` 只由 `_toggleCollect` 本地翻转；页面加载时不调用任何「是否已收藏」查询（本文件也无此接口引用）。已收藏的 MV 进入本页显示未收藏（空心），点击「收藏」实际执行的是重复收藏或（若服务端幂等则无变化）取消收藏的反向操作语义对用户倒置。
- 影响：已收藏 MV 用户看到未收藏态，点一下图标本意「取消」实际发起「收藏」请求（服务端可能报错或重复）；收藏状态展示整体失真。
- 证据等级：实锤（本文件无任何初始收藏态查询；`fetchCollected` 存在于仓库层但未被调用）

### mv_player_page.dart:221-231 切清晰度失败仅 `_controller?.play()` 恢复，播放位置与原档一致性未验证
- 级别：P3
- 违反：第 18 条（异步结果世代）
- 依据：`on Exception catch (_) {}` 空捕获 play 恢复（该异常确为可处理类型且上层 Toast 已给反馈，轻微）；旧 controller 保留播放，无 seek 回原进度需求（未换控制器），可接受。
- 影响：无直接后果；整洁度。
- 证据等级：实锤

### mv_player_page.dart:236-242 `_listenEvents` 每次 setState 驱动整页重建，播放进度每帧变化即 setState
- 级别：P2
- 违反：第 26 条（热路径零分配）
- 依据：listener 内 `if (_phase == _Phase.normal) setState(() {});`——VideoPlayer 的 listener 在位置更新时高频回调（每几十毫秒一次），整页 ConsumerState 重建（含 build 里 `ref.watch(mvDetailProvider(...))`、控制条、AppBar 组装）。
- 影响：MV 播放期间持续高频整页重建，低端机掉帧/发热；横竖屏判断每帧重算。
- 证据等级：实锤（listener 回调频率为 video_player 已知行为，静态推演）

### mv_player_page.dart:86-92 initState 直接 `_resolve(widget.hash)` 与 `_loadDetail()` 并发，失败态由 `_mvMissing && _controller == null` 组合判定存在竞态
- 级别：P3
- 违反：第 18 条
- 依据：`_mvMissing` 由 `_loadDetail` 置位；若解析成功（normal 态）后 detail 才返回 20010，`missing` 因 `_controller != null` 为 false——正确兜住。但 `_resolve` 成功时 `setState` 里把 `_mvMissing = false`（isSwitch 分支），首次解析不带 isSwitch 也会清掉 detail 已置的 missing，两条异步置位互相覆盖，最终显示取决于完成顺序。
- 影响：详情 404 但播放地址可用时，界面在「不存在」与「正常播放」间闪烁一次后定格，结果不算错误但状态机不单调。
- 证据等级：静态推演

### mv_player_page.dart:318-327 收藏异常 Toast 直接拼接 `'$e'`（英文异常原文上屏）
- 级别：P3
- 违反：第 8 条（异常形态统一到友好文案）、friendly_error 契约
- 依据：`Toast.show(context, context.l10n.mvDetailLoadFailed + '：$e')` 与 `'${context.l10n.mvCollectAdd}：$e'`——未走 `friendlyError()`/`unwrapApi()`（core/utils/friendly_error.dart 明言 UI 层不得直接 `'$e'` 上屏）。
- 影响：网络异常时用户看到英文 DioException 文案。
- 证据等级：实锤

复核通过：生命周期全对称（orientation/UI mode/timer/controller dispose）、`created` 所有权移交防泄漏、_resolving 闸门 finally 归还（第 19 条达标）、收藏防重闸、三态分离清晰、mkv 容器知情标注。

## 13. lib/features/player/play_helper.dart（89 行，完整读）

### play_helper.dart:44-52 hash 缺失时传空串，`playQueue`/`playSong` 对空 hash 队列项无过滤
- 级别：P2
- 违反：第 14 条（边界校验）、第 3 条
- 依据：`_songFromHome` 按设计把缺失 hash 转成 `''`（V39-AUX-01 注释），但 `playHomeQueue` 把整张列表原样送入 `playQueue`，含空 hash 项的队列在播放到该首时才失败（失败链路可观测，但每首都走一次注定失败的详情/URL 请求）；`playQueue` 仅过滤空列表不过滤空 hash。
- 影响：某来源（如搜索结果缺 hash）点整列表播放，用户点击后可听到部分歌，中间穿插「播放失败」反馈，而非点播时就提示可用性。
- 证据等级：静态推演（失败链路可观测的前提是 player_controller/audio_handler 有对应处理，属 ○ 抽查）

复核通过：转换点唯一（第 1/5 条达标）、秒单位显式、hash 语义注释与 domain 契约一致；`playQueue` 空列表守卫。

## 14. lib/features/player/presentation/mini_player.dart（188 行，完整读）

### mini_player.dart:33-34 `ref.read(playerControllerProvider)` 在 build 中读取后直接用于手势回调
- 级别：P3
- 违反：第 2 条（显式依赖）
- 依据：`final controller = ref.read(playerControllerProvider);` 每次 build 读一次，Riverpod 惯例是回调内再 read；若 provider 被 override/重建（登录态切换重建 provider 容器），持有的是旧实例直到下次 build。togglePlay/next 大概率幂等，风险低。
- 影响：极端时序下点播放操作旧控制器实例；通常不可见。
- 证据等级：静态推演

### mini_player.dart:159-166 `_MiniProgressBar` 无时间文本仅比例条，total 为 0（未知时长）时恒 0.0
- 级别：P3
- 违反：第 16 条
- 依据：`total.inMilliseconds > 0` 守卫下未知时长显示 0 进度——与「未播放」无法区分，正确降级；但 positionProvider/durationProvider 为 AsyncValue，加载瞬间显示 0 后跳变，无动画。
- 影响：轻微视觉跳变；无功能问题。
- 证据等级：实锤

复核通过：进度条独立组件避免整树重建（第 26 条达标）、窄屏 LayoutBuilder 降级（V37-UI-07）、memCacheWidth 132 对应 44×3 逻辑像素（解码尺寸有据）、长按+显式队列入口双通道。

## 15. lib/features/rank/presentation/rank_detail_page.dart（190 行，完整读）

### rank_detail_page.dart:88-90 `_loadMore` 失败静默吞（空 catch），连续失败也无反馈
- 级别：P2
- 违反：第 6/9 条（失败可观测）
- 依据：`} catch (_) { // 静默：保留已有列表 }` 无日志无 Toast，`_hasMore` 保持 true，用户再点「加载更多」仍失败且无任何提示；与首屏 `_load` 的错误态（UI-02 修复）不对称。
- 影响：弱网下加载更多永远无响应无解释，用户误以为按钮失效。
- 证据等级：实锤

### rank_detail_page.dart:36-49 `_load` 无世代校验：重试/快速返回时旧响应覆盖新状态
- 级别：P3
- 违反：第 18 条
- 依据：`_load()` 直接 setState 覆盖 `_songs`；本页为单请求页面（page 固定 1），无切页竞争，但 `_load` 可被重试按钮重复触发（`_error=null` 后再次 `_load`），两次并发 `_load` 后完成者胜出，理论上乱序；单页场景实际影响小。
- 影响：极端时序下列表短暂跳变；轻微。
- 证据等级：静态推演

### rank_detail_page.dart:56-60 `_loadMore` 成功后 `_page++`，但失败重试时请求的是 `_page+1` 恰好与失败前相同页——无重复风险；`_hasMore = _songs.length < r.total` 假设 total 全量口径
- 级别：P3
- 违反：第 14 条（上游 total 形态）
- 依据：若上游 total 为去重后/排序后数量与分页不一致（未实测），`_hasMore` 永真则用户在「没有更多」和重复加载间循环。当前以「没有更多」文案兜底可停止。标注未实测。
- 影响：潜在重复条目或提前「没有更多」；需 rank_repository（○ 抽查）核对 total 口径。
- 证据等级：未实测

复核通过：三态齐备（错误重试/空数据/加载中，V3-12/UI-02 到位）、_loadingMore 闸门、MV 按钮空 hash 守卫、48dp 触控区（V37-UI-05）。

---
# 跨文件契约抽查（○ 文件，共读 4 个：player_provider / mv_repository / mv_provider / queue_sheet）

## C1. lib/features/player/player_provider.dart（227 行，抽查全文读）

### player_provider.dart:143-150 recentPlayRecorderProvider 的流订阅在 provider 重建时不取消旧订阅直到 onDispose
- 级别：P3
- 违反：第 20 条
- 依据：`ref.onDispose(sub.cancel)` 正确；但 `ref.watch(audioHandlerProvider).onSongStarted` 若 handler 依赖链（playerRepositoryProvider→kgClientProvider）重建，本 provider 重建时旧订阅取消、新订阅建立，行为正确。无问题，记录核对结论。
- 影响：无。
- 证据等级：实锤

### player_provider.dart:157-173 queueProvider 用 `handler.songs` 快照 + queue.stream 触发重发，依赖 handler.songs 已更新
- 级别：P3
- 违反：第 18 条（顺序假设未写明）
- 依据：`await for (final _ in handler.queue.stream) { yield handler.songs; }` 假设 handler 先更新 `songs` 字段再向 queue.stream 发事件；若顺序颠倒，UI 拿到旧队列。该前提在 audio_handler（○）实现，本文件未声明。
- 影响：切歌单瞬间队列 UI 可能短暂显示旧列表。
- 证据等级：静态推演（顺序契约跨文件，audio_handler 未读本批，标注待 B5 复核）

复核通过：audioPlayerProvider 用 StreamProvider 惰性重发（终审 P0-1 修复到位）、引擎未就绪各流均有稳定空值降级、togglePlay 引擎未就绪时 ensureEngineReady 拉起、cycleRepeatMode 轮转完备。

## C2. lib/features/mv/data/mv_repository.dart（399 行，抽查全文读）

### mv_repository.dart:52-53 `_hashToVideoId` 超过 128 条时 `clear()` 全清——淘汰策略粗暴但正确性无碍
- 级别：P3
- 违反：第 25 条（上限有据但实现简单）
- 依据：`if (_hashToVideoId.length > 128) _hashToVideoId.clear();`，静态 Map 无 LRU；影响仅为缓存效率。
- 影响：轻微；无用户可见后果。
- 证据等级：实锤

### mv_repository.dart:60-62 fetchDetail 走 `_cached.get('/video/detail')` 168h 缓存，但 `_resolveVideoIdByHash` 的搜索结果与 detail 分属两次缓存——hash 换算的 id 过期与 detail 缓存独立
- 级别：P2
- 违反：第 23 条（缓存键覆盖影响维度）、第 11 条（降级退出条件）
- 依据：`/video/detail` 缓存 168h（CachedApiCall ns='mv'），但 MV 清晰度 hash 会因版权/下架变化（上游随时更新视频资产）。下架 MV 的 detail 在 168h 内仍返回旧 hash，`resolvePlayUrl` 用旧 hash 打 `/video/url` 得到空结果，报「MV 暂无播放地址」而非「已下架」；且 resolvePlayUrl 本身不走缓存，与 detail 侧新旧不一致。
- 影响：MV 下架后 7 天内用户看到「暂无播放地址」误导文案（实际是已下架），重试无意义却仍可点。
- 证据等级：静态推演

### mv_repository.dart:230-233 `MvInfo.bestHash` 顺序 sq>qhd>hd>sd 与 `MvDetail.bestHash` fhd>sq>qhd>hd>sd>ld 不一致
- 级别：P2
- 违反：第 3 条（同名契约不同实现）、第 17 条
- 依据：两个 getter 同名同语义（最高画质 hash）但优先级序列不同：MvInfo 无 fhd 字段故不含 fhd（合理），但 MvDetail 有 fhd 而 MvInfo 从 h264 中只取到 qhd（`pick('sq_hash')` 自注「sq 实测不存在」、fhd 未 pick）。同一 MV 从详情路径与列表路径得到的「最高画质」不同（fhd 在列表路径被丢弃）。
- 影响：从歌曲关联 MV 列表进入播放的 MV 最高只到 qhd，fhd 资产被静默丢弃，用户无法在播放页切出 fhd（清晰度列表来自 detail，detail 有 fhd 时用户可手动切——实际可用，故为画质默认值不一致）。
- 证据等级：实锤（两 getter 对照）

### mv_repository.dart:349-353 `containers` 判定 `hashes[key] == mkvHash` 时 mkv hash 覆盖 mp4 hash 的写入顺序问题
- 级别：P3
- 违反：第 5 条
- 依据：`put('sd', mkv_sd_hash)` 仅在缺失时补（`!hashes.containsKey`），但后文 `data['${key}_hash_265'] ?? data['${key}_hash']` 循环里 put 的是同一 key 也不覆盖。containers 判 `hashes[key]==mkvHash` 只在 mkv hash 成为最终值时标 mkv——若 mp4 hash 先写入，mkv hash 被丢弃但容器标 mp4，正确。核对无误。
- 影响：无。
- 证据等级：实锤

复核通过：hash/video_id 互转双方向收口（V3990-1 P0 修复到位）、`/video/url` 直返原始 HTTP 的 Range 代理注释有实测依据、MvDetail.fromJson 对 data 数组/Map/顶层三形态全兼容（第 13 条达标）、duration 毫秒换算口径统一并留实测来源。

## C3. lib/features/mv/mv_provider.dart（34 行，抽查全文读）

### mv_provider.dart:29-33 mvDetailProvider 吞掉一切异常返回 null，与页面「不存在」态无法区分
- 级别：P2
- 违反：第 16 条（失败与缺失语义分离）、第 6 条
- 依据：`} catch (_) { return null; }`——网络失败、20010 不存在、20028 需验证统一折叠成 null；mv_player_page 里 `detail.value?.hashes` 为空时 `_loadDetail` 的独立请求会另行报错，本 provider 只影响清晰度按钮隐藏，但失败原因彻底不可观测（无日志）。
- 影响：清晰度按钮在弱网下静默消失，用户不知道是没网还是 MV 只有一档；排查无线索。
- 证据等级：实锤

### mv_provider.dart:9-12 mvRepoProvider 走 `kugouApiClientProvider`（kapi 底座），与 mv_collection_repository 的 KgClient（直连）并存两套客户端
- 级别：P3
- 违反：第 27 条（原生网关优先）
- 依据：`MvRepository(ref.watch(kugouApiClientProvider))` 走 KugouApiClient；而 MvCollectionRepository 用 kgClientProvider（KgClient 直连）。MV 详情/URL 走 kapi 底座是否属「未移植路径显式兜底」未在注释写明清理计划。标注：MV 接口（/video/detail、/video/url、/kmr/audio/mv）是否已有直连实现属 B2 范围核对项，本文件仅记录装配事实。
- 影响：若直连已移植而此处仍用 kapi，等于中转网关成为主路径（第 27 条违纪）；若未移植则合规。证据不足，标未实测待主代理裁决。
- 证据等级：未实测

复核通过：albumAudioId 空值守卫、autoDispose family 无泄漏、mvExistsProvider 与 songMvProvider 共用 findBySong（in-flight 由 CachedApiCall 合并）。

## C4. lib/features/player/presentation/queue_sheet.dart（184 行，抽查全文读）

### queue_sheet.dart:128-131 `_onTap` 中空 hash 回退按快照 index 播放，与新队列不一致时播错歌
- 级别：P2
- 违反：第 18 条（世代校验）
- 依据：`if (s.hash.isEmpty) { _play(controller, live, snapshotIndex); }`——注释只说「快照一致时才有效」但未做一致性检查即播放；队列被整体替换后 snapshotIndex 指向完全不同的歌。对比同函数非空 hash 分支有完整定位与 SnackBar 反馈。
- 影响：队列含空 hash 歌（HomeSong 无 hash 转换链）且用户停留弹层期间切了歌单，点空 hash 项会播放新队列中错位的歌，无任何提示。
- 证据等级：实锤

复核通过：三态分离（loading/error/empty，V39-AUX-10 到位）、isCurrent 双非空守卫（V39-AUX-09）、世代校验+queueChangedHint 反馈、越界显式检查（第 12 条）、memCacheWidth 按 dpr 动态计算。

---
# 逐文件 dart analyze 结果（过滤 Flutter/三方包符号缺失噪音）

说明：环境无 Flutter SDK / dio / riverpod 包，`SizedBox/Icon/Widget/StatelessWidget/AudioPlayer/LoopMode/DioException/extends_non_class` 等均为预期噪音，已过滤。以下为各文件过滤后剩余：

- lib/app/bootstrap.dart — 8 issues，全部为三方包（hive_flutter/flutter）符号缺失噪音 → **项目自有类 0 错误** ✅
- lib/core/audio/audio_service_bootstrap.dart — 4 issues，just_audio_background/flutter 噪音 → 0 ✅
- lib/core/theme/app_theme.dart — Flutter material 符号噪音（SnackBarThemeData 等）→ 0 ✅
- lib/core/utils/friendly_error.dart — dio 噪音 → 0 ✅
- lib/core/utils/update_checker.dart — DioException 噪音 + package_info_plus 噪音 → 0 ✅
- lib/core/widgets/error_retry.dart — Flutter 噪音 → 0 ✅
- lib/core/widgets/section_header.dart — Flutter 噪音 → 0 ✅
- lib/core/widgets/splash_handwriting.dart — Flutter 噪音 → 0 ✅
- lib/features/home/data/models.dart — **No issues found!（原生全绿）** ✅
- lib/features/lyric/data/krc_parser.dart — 2 issues，flutter foundation 噪音 → 0 ✅
- lib/features/mv/data/mv_collection_repository.dart — 4 issues 中 **1 条项目自有 warning**：`mv_collection_repository.dart:149:26 unnecessary_null_comparison`（`res.rawBytes` 已声明非空，`bytes != null` 恒真——与报告第 11 节「解密失败路径回退 status==200」问题相邻，属轻微微瑕）+ 3 条 flutter/dio 噪音 → 1 条自有 lint ⚠️（非错误级）
- lib/features/mv/presentation/mv_player_page.dart — Flutter/video_player 噪音 → 0 ✅
- lib/features/player/play_helper.dart — 3 issues，riverpod 噪音 → 0 ✅
- lib/features/player/presentation/mini_player.dart — Flutter 噪音 → 0 ✅
- lib/features/rank/presentation/rank_detail_page.dart — Flutter 噪音 → 0 ✅
- lib/features/player/player_provider.dart — just_audio/audio_service 噪音 → 0 ✅
- lib/features/mv/data/mv_repository.dart — 2 issues：`prefer_final_locals` info（项目自有 lint，第 230 行）+ dio 噪音 → 1 条自有 info ⚠️
- lib/features/mv/mv_provider.dart — 5 issues，riverpod 噪音 → 0 ✅
- lib/features/player/presentation/queue_sheet.dart — Flutter 噪音 → 0 ✅

**结论：19/19 文件过滤噪音后项目自有类 0 error；2 条自有 lint warning/info（mv_collection_repository.dart:149、mv_repository.dart:230），不构成功能缺陷。**

---
# 问题清单（按级别排序）

**P0：0 条**

**P1：1 条**
1. mv_player_page.dart:339-354 `_collected` 初始恒 false，不从服务端查当前收藏态——已收藏 MV 显示未收藏，收藏/取消语义对用户倒置。

**P2：10 条**
2. mv_collection_repository.dart:118-121 解密成功仅验非空即返回 true，未校验解密体内 status（注释与实现矛盾）。
3. mv_collection_repository.dart:145-147 解密失败回退 `res.status == 200`，两条路径成功判定口径不一致，风控空包误判成功。
4. mv_repository.dart:60-62 fetchDetail 走 168h 缓存，MV 下架后旧 hash 致「暂无播放地址」误导文案。
5. mv_repository.dart:230-233 MvInfo.bestHash 与 MvDetail.bestHash 画质优先级不一致，fhd 在列表路径被丢弃。
6. mv_provider.dart:29-33 mvDetailProvider 吞一切异常返回 null，失败不可观测。
7. queue_sheet.dart:128-131 空 hash 回退按快照 index 播放且未校验快照一致性，可能播错歌。
8. error_retry.dart:214-231 errorClassification 未解包 DioException(error: ApiException)，20028/登录过期退化为通用文案；与 friendlyError 两套映射。
9. mv_player_page.dart:236-242 播放器 listener 高频 setState 整页重建（第 26 条热路径）。
10. update_checker.dart:63-65 无 APK 时回落 html_url（网页地址），downloadUrl 契约失真。
11. models.dart:104-115 时长单位判定依赖字段名枚举，未知来源毫秒字段显示 --:--。
12. mv_collection_repository.dart:88-92 未登录返回 false 与失败不可区分，无登录引导。
13. play_helper.dart:44-52 空 hash 队列项不过滤，播放中途穿插失败。
14. rank_detail_page.dart:88-90 _loadMore 失败空 catch 静默，无反馈。
15. krc_parser.dart:71-96 畸形 KRC 行 int.parse 无捕获，一行坏数据整首歌词失败。

**P3：13 条**（摘要）：
- bootstrap.dart:33-52/58 开箱失败吞后无标记、startupError 全局可变通道
- audio_service_bootstrap.dart:40-46 重试无上限退避；:33 _error 成功后残留
- app_theme.dart:35-40 fromSeed 无缓存
- friendly_error.dart:24-25/29-31 错误码字面量、非领域异常折叠
- update_checker.dart:196-204/120-124 版本清洗启发式、代理双 scheme 未实测
- splash_handwriting.dart:68-90 时序权重重复推导
- models.dart:71-79/176-183 FileName 拆分、globalCollectionId 回填数字 ID
- krc_parser.dart:130-141/236-243/279-300 leadingText 丢弃、非稳定排序、_decodeLanguage 降级乱码无留痕
- mv_player_page.dart:221-231/86-92/318-327 切档恢复、missing 竞态、`'$e'` 上屏
- mv_collection_repository.dart:62-70 凭据进 URL 冗余（未实测）
- player_provider.dart:157-173 queue 顺序契约跨文件未声明；mini_player.dart:33-34/159-166 read 时机、进度跳变
- rank_detail_page.dart:36-49/56-60 世代、total 口径未实测
- mv_repository.dart:52-53 hash→id 缓存 clear 淘汰
- section_header.dart 注释与文件内容不符；mv_collection_repository.dart:149 unnecessary_null_comparison

---
# 复核通过项（本范围确认到位的设计）

1. audio_service_bootstrap：init 失败不缓存 Future（可恢复）+ ErrorLogger 留痕 + 不做超时放弃的理由注释。
2. app_theme：token 具名、双主题共享、无 I/O 无状态。
3. friendly_error：unwrapApi 处理 DioException(error:) 包装链（A2-07）。
4. update_checker：404 与网络故障语义分离、失败必抛不静默、semver 预发布比较正确。
5. error_retry：技术详情折叠/复制/选中；message 参数契约注释。
6. splash_handwriting：controller dispose 对称、PathMetric 缓存、等比缩放、TweenSequence 权重数值核对一致。
7. home/models.dart：_toInt/_toStr 全分支验证、singerinfo 双形态、dailyRecommend null 区分未登录、毫秒/秒显式换算——dart analyze 原生全绿。
8. krc_parser：PLY-01 逐字偏移、LRC 多时间戳、duration 回填、offset 减法、翻译条数校验。
9. mv_collection_repository：D-P0-2 collect/cancel 分流、二进制 body、fromJson is Map 验证。
10. mv_player_page：生命周期全对称、created 所有权移交防泄漏、_resolving 闸门 finally 归还、收藏防重、三态分离、mkv 知情标注。
11. play_helper：转换点唯一、秒单位显式、hash 契约注释与 domain 一致。
12. mini_player：进度条独立组件、窄屏降级、解码尺寸有据、队列双入口。
13. rank_detail_page：三态齐备（V3-12/UI-02）、_loadingMore 闸门、48dp 触控。
14. player_provider：audioPlayerProvider StreamProvider（终审 P0-1）、引擎未就绪稳定空值流、cycleRepeatMode 轮转完备、recentPlayRecorder onDispose 对称。
15. mv_repository：hash/video_id 双向收口（V3990-1）、/video/url Range 实测注释、fromJson 三形态兼容、duration 口径统一留实测来源。
16. mv_provider：空值守卫、autoDispose、findBySong 共用合并。
17. queue_sheet：三态分离（V39-AUX-10）、isCurrent 双非空守卫、世代校验+queueChangedHint、越界显式检查（V39-AUX-09）。
（不把无 release 当最新）、失败必抛不静默、版本比较预发布规则正确（rc < 正式）、`currentVersion` 失败兜底留有 '1.0.0' 默认值。
