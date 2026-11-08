# v5.1 交叉审查 B5 · 视角 B（鲁棒与代码质量）

- 范围：34 文件 / 11583 行（auth / album / artist / comment / download / library / playlist / search / settings / 的 data+presentation 子集，✅ 通读 10 文件，○ 跨文件契约抽查）
- 判据：`docs/QUALITY_STANDARD.md`（32 条 + 第 33 条实测纪律），重点第 1/6/9/11/14/18/19/20/21/23/25/28/29/32 条
- 已读防锚定索引：`docs/v51_cross_b1_merged.md`、`b2_merged.md`、`b3_merged.md`、`v51_cross_b3_b.md`、`v51_cross_b3_c.md`（任务书点名，只用于不重复报）
- 工作方式：逐文件 `file_read` 完整读、读完即 append；只读不改；末尾问题清单 + 复核通过项 + 逐文件 `dart analyze`

---

## 1. `lib/features/auth/data/account_manager.dart`（188 行，完整读）

### account_manager.dart:40-44 `init()` 的兼容清洗 `try { await _saveList(accounts); } catch (_) {}` 为空体吞异常
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`init()` 末尾 `try { await _saveList(accounts); } catch (_) {}`，注释称「兼容清洗：历史版本曾把 token 明文写进 accounts 盒，重写一次去掉」，但 catch 块完全空体——无日志、无计数、无降级语义。清洗失败意味着明文 token 残留（安全问题）且无人知晓。且该清洗在**每次 init** 都执行一次整盒重写，并非「历史版本一次」，也无版本标记判断是否已完成。
- 影响：旧版本升级用户若清洗写失败，账号列表里的明文 token 永久残留在 Hive 盒中且无任何日志可查；每次启动多一次全列表重写 IO。
- 证据等级：实锤（catch 体与注释在本文件内成对确认）

### account_manager.dart:26-28 `AccountRecord.token` 字段为「仅内存」但持久化入口无隔离，写侧契约靠自觉
- 级别：P3
- 违反：QUALITY_STANDARD 第 2 条（显式优于隐式）、第 31 条（注释与行为一致）
- 依据：`String token;` 注释「**不持久化** —— token 存 SecureStorage」，`toJson()` 确实不含 token；但 `upsert(AccountRecord record)` 接受任意构造的 record，token 可被调用方塞进内存对象；若未来任何人把 record 引用存入其他结构，无类型层面防护。`t1` 同样仅内存但未写注释（与 token 的显式说明不对称）。
- 影响：无直接用户可见后果；维护者按字段可变性推断 token 会被传递，容易在别处造成泄漏回归。
- 证据等级：实锤（字段与 toJson 在本文件内确认）

### account_manager.dart:59-65 / 116-118 `_notifyChanged` 用 try-catch 包 `StreamController.add` 属无效防护，且 `catch (_) { _changedCtrl.add(null); }` 仍可能抛
- 级别：P3
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理的类型）
- 依据：`_changedCtrl.add(currentAccount)` 对 broadcast 控制器在未关闭时不会抛；若控制器已 close 才会抛 StateError，而 fallback 分支 `_changedCtrl.add(null)` 同样会抛（同一已关闭控制器），防护自相矛盾且本类无 close/dispose 路径。
- 影响：无直接用户可见后果；属死防护代码，误导维护者以为存在关闭场景。
- 证据等级：实锤

### account_manager.dart:139-152 `remove()` 移除非当前账号时返回 `currentAccount`，调用方无法区分「切换了」与「没切换」
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约先行：失败/结果语义须明确）
- 依据：`remove` 三种返回形态：被删者是当前→返回新当前或 null；被删者非当前→返回 `currentAccount`（未变化）。返回值语义混杂（null 既可能是「列表空了」也可能是「当前账号本来就没有」），且非当前账号分支不 `_notifyChanged`（合理）但返回值却像「切换结果」。
- 影响：调用方若按返回值刷新 UI，会在未发生切换时做多余刷新；无直接用户可见错误。
- 证据等级：实锤

---

## 2. `lib/features/auth/data/captcha_types.dart`（156 行，完整读）

### captcha_types.dart:22-29 / 39-43 `supportedInApp` 仅覆盖 tencent/sms，但 fromVType 会把 23 映射为 tencent 而注释称「23 滑块验证（腾讯为主）」——滑块（slider_solver 存在）被排除在 App 内支持之外
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：能力边界必须明确）、第 31 条（注释与行为一致）
- 依据：`bool get supportedInApp => this == tencent || this == sms;`，而 `fromVType(23) => CaptchaType.tencent` 且注释写「23 滑块验证（腾讯为主）」；本批范围内存在 `slider_solver.dart`（滑块求解器，抽查确认属本域）。若滑块路径的 type 判定为 tencent，则 `supportedInApp` 为 true，滑块却需要 slider_solver 而非 WebView；若 type 判为其他（kugouRotate 等）则 supportedInApp=false，用户被抛到外部浏览器。类型能力表与实际验证形态（WebView / 滑块 / 短信）不在同一契约内。
- 影响：滑块类验证用户可能被引导到不适用的处理路径（WebView 打不开滑块、或被拒绝 App 内完成），表现为验证流程中断。
- 证据等级：静态推演（类型映射与能力表为实锤；captcha_page 实际分派待读该文件后补判）

### captcha_types.dart:104-107 `vType` 解析失败折叠为 -1 哨兵值，`-1` 未在枚举中表达
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界数据必须校验）、第 16 条（缺失与失败语义分离）
- 依据：`final vType = vTypeRaw is int ? vTypeRaw : int.tryParse('${vTypeRaw ?? ''}') ?? -1;`。-1 会原样进入 `VerifySession.vType`，下游用 `switch (vType)` 只能落到 unknown；-1 与「上游明确给 0」不可区分，且该哨兵未定义为具名常量（第 2 条）。
- 影响：上游 v_type 形态变化（字符串 "23" 可解析，但 null/bool/map 则折叠 -1）时验证类型识别静默失败，用户看到「未知验证」并可能走向不支持路径，无日志区分「上游没给」与「解析失败」。
- 证据等级：实锤

### captcha_types.dart:110-117 `typeList` 将解析失败项折叠为 -1 后过滤，静默丢类型项
- 级别：P3
- 违反：QUALITY_STANDARD 第 9 条（静默降级必须留痕）
- 依据：`.map((e) => e is int ? e : int.tryParse('$e') ?? -1).where((e) => e >= 0)`，解析失败被 -1 再被过滤，无日志；typeList 本身在本文件内无消费方（用途待跨文件核对）。
- 影响：上游返回畸形类型列表时降级为短列表且无留痕，排查验证类型轮换问题时缺数据。
- 证据等级：实锤（本文件内；消费方在后续文件核对）

---

## 3. `lib/features/auth/presentation/verification_guard.dart`（63 行，完整读）

### verification_guard.dart:22-26 只捕获 `DioException` 形态的 20028，裸 `ApiException` 直接穿透
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（回退路径与主路径的异常形态必须一致）、第 3 条（异常契约单一）
- 依据：`on DioException catch (e) { final api = e.error is ApiException ? e.error as ApiException : null; if (api == null || !api.needsVerification) rethrow; }` ——仅当底层把 `ApiException(20028)` 包进 `DioException.error` 时才进入验证流程；若调用链（直连层 `requestWithVerify` / 上层包装）抛出**裸 `ApiException`**（B1/B2 修复后已出现该形态），这里 `on DioException` 不命中，异常直接冒泡给调用方。注释自述「捕获 ApiException(20028)」与实现不符。
- 影响：同一 20028 在不同路径下一个进验证页、一个直接报错，用户看到「人机验证功能时灵时不灵」，验证闭环在裸 ApiException 路径断裂。
- 证据等级：实锤（catch 类型在本文件内确认；直连层是否抛裸 ApiException 属跨文件事实，与 b2_merged 记载的 requestWithVerify 链路一致，静态推演成立）

### verification_guard.dart:36-45 验证页弹出后不校验页面世代，`context.mounted` 检查在 push 之前但重试的 `action()` 闭包无世代参数
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`while(true)` 循环中验证通过后直接重试 `action()`，action 闭包捕获的是进入 guard 时的状态（如当时的歌曲/账号）；验证期间用户可能已切歌/切号/离开页面，重试仍执行旧上下文的写/播放操作。guard 未向 action 传递世代或要求 action 自校验。
- 影响：验证耗时（用户拖滑块）期间切歌，验证通过后仍播放/收藏旧目标，用户看到「验证完却操作了不是现在想操作的东西」。
- 证据等级：静态推演（闭包无世代参数为实锤；action 内部是否自校验取决于调用方）

---

## 4. `lib/features/auth/data/verification_service.dart`（98 行，完整读）

### verification_service.dart:63-69 `submit` 成功判定自造第二套口径，未走 B1 `evaluateResponse`
- 级别：P1
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径必须逐端点实测统一）、第 8 条（异常契约单一）
- 依据：`final status = data['status']; final ok = status == 1 || status == '1' || (data['data'] is Map && '${(data['data'] as Map)['codeDesc']}'.toLowerCase() == 'success');` ——`codeDesc` 是 String 插值后小写比较，`codeDesc` 为 null 时字符串是 `'null'` 不等于 success（安全），但 `codeDesc` 为其他成功形态（如 `code==0`）时不被认可；且与 B1 统一的 `evaluateResponse`（status 归一、警告码白名单）并行存在第三套口径。`_api.post` 走的 kugou_api_client 拦截器已调 evaluateResponse，若该端点被判定失败会先在拦截器抛 ApiException，本函数的 `status==1` 判定可能永远收不到失败响应（双判不一致：拦截器放行的响应此处可能判 false，反之亦然）。
- 影响：验证提交在直连/回退两条路径上的成功判定不一致——可能「实际验证成功但 App 判失败」导致重复验证，或「App 判成功但服务端失败」导致验证闭环假通过，用户反复被要求人机验证。
- 证据等级：静态推演（本文件零 evaluateResponse 为实锤；拦截器实际行为与 kapi 返回形态需原生实测留样，按第 29/33 条标注未实测）

### verification_service.dart:81-83 `on DioException catch (e) { if (e.error is ApiException) return false; rethrow; }` 把一切 ApiException 形态异常折叠为「未通过」
- 级别：P2
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理的类型）、第 10 条（编程错误不得进入业务降级）
- 依据：任何被包装为 ApiException 的异常（含网络超时、参数构造错误、解析 TypeError 包装）都返回 false，与「验证未通过」这一业务语义混同；注释只举例 20010。无日志留痕。
- 影响：网络抖动导致的提交失败与真实验证失败对用户不可区分（都显示未通过），排查线上「验证一直不过」时无日志区分两类原因。
- 证据等级：实锤（catch 范围在本文件内确认）

### verification_service.dart:33-42 `buildSidEdt` 的 mid/userid/dfid 三处降级为 '0'，静默降级无留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（静默降级必须留痕）、第 11 条（降级触发条件）
- 依据：`dfid = await SecureStorage.instance.readDfid() ?? '0'`、`mid: ... : '0'`、`userid: _api.userid.isNotEmpty ? _api.userid : '0'`，三处任一缺失都生成 '0' 指纹；`_directClient` 为可空（kapi 构造路径下恒 null → mid 恒 '0'）。edt 由这些值派生（AES+RSA），'0' 指纹提交后服务端风控可能直接拒绝或要求二次验证，此处无任何日志。
- 影响：设备信息未就绪时（如 dfid 三写失败、直连 client 未装配），每次验证都用占位指纹提交，验证通过率下降且线上无从定位「为什么总被要求验证」。
- 证据等级：静态推演（降级分支为实锤；服务端对 '0' 指纹的行为未实测，按第 33 条不做 kapi 推断）

### verification_service.dart:46-49 `vType = session.vType > 0 ? session.vType : 23` 把解析失败（-1）默认为「腾讯滑块」
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界数据必须校验）、第 16 条（缺失与失败语义分离）
- 依据：captcha_types.dart 已确认 vType 解析失败折叠为 -1；此处把任何非正值（含 0、-1、未知新类型）一律提交为 v_type=23（滑块）。若上游实际是 22 活体/34 人脸，用 23 提交必然失败。
- 影响：新验证类型或形态变化时，用户被迫完成一次与真实类型不符的滑块验证后仍验证失败，反复循环直到 maxRetries 耗尽。
- 证据等级：实锤（与 captcha_types.dart 的 -1 折叠成对确认；提交 v_type=23 的服务端行为未实测）

### verification_service.dart:92-96 `sessionFromException` 产出 `vType: -1` 的会话，与 submit 的 `>0 ?: 23` 叠加后语义为「默认滑块」
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约先行）
- 依据：`VerifySession(eventId: e.ssaCode ?? '', vType: -1)`——ssaCode 为 null 时 eventId 为空串，submit 会带空 eventid 提交。本方法在本文件内无调用方（跨文件核对消费面）。
- 影响：空 eventid 提交必失败；若确有调用方，表现为「验证页直接报错」。
- 证据等级：实锤（本文件内无调用；调用面待抽查核对）

---

## 5. `lib/features/download/data/download_store.dart`（61 行，完整读）

### download_store.dart:16-17 / 29-31 / 41-43 全部读写方法在 box 未打开时**静默返回空/不写**，写入丢失不可观测
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 6 条（禁止吞掉异常）、第 16 条（空集合与缺失语义分离）
- 依据：`_boxOrNull()` 在 `Hive.isBoxOpen('downloads')` 为假时返回 null；`readAll` 返回 `const []`，`save/remove/clear` 直接 `return`——save 静默丢弃写入，无日志、无异常、无返回值。本类没有 `init()`/`openBox` 路径，开箱完全依赖外部（启动时序）。若启动时序变化或开箱失败，用户发起的下载任务记录全部丢失，且重进页面显示「无下载」。
- 影响：下载任务在盒未开时发起 → `save` 静默丢任务，下载进度页与持久化记录不一致（重启后任务消失但磁盘文件已写），用户看到「下载成功了但下载列表是空的」，无任何错误提示。
- 证据等级：实锤（全部分支在本文件内确认）；实际开箱时序待 download_provider 通读后补判

### download_store.dart:24-25 `DownloadTask.fromJson(raw)` 对 `raw is Map` 仅验最外层，畸形值逐字段下沉
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条
- 依据：`if (raw is Map) { result.add(DownloadTask.fromJson(raw)); }`——Map 内字段形态校验取决于 `download_task.dart` 的 fromJson 实现（跨文件核对，见该文件章节）。此处对 `box.keys` 中的非 String 键（Hive 允许）也不加区分地 `box.get(key)`；任务 id 键约定 `${type.name}_$hash`，非约定键（旧版本残留）会原样读出。
- 影响：旧版本/异常写入的条目可能抛解析异常冒泡出 readAll（取决于 fromJson 健壮性），下载列表整页失败；无逐条隔离。
- 证据等级：实锤（本层无 try/catch 为实锤）

---

## 6. `lib/features/library/data/recent_play_store.dart`（101 行，完整读）

### recent_play_store.dart:73-79 `_serial` 链式队列的 `catchError` 返回值类型违规风险与静默吞错
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`_serial = next.catchError((Object e) { // ignore: avoid_print\n return; });` ——注释自述「同时保留错误可观测性」，但 catch 体只有注释掉的 print 与 `return`，**没有任何可观测手段**（无 ErrorLogger、无 debugPrint）。注释与实现直接矛盾。另外 `read()` 内 `await Hive.openBox` 若抛错，错误沿 `_serial` 链传播被本处吞掉，调用方拿到的 `next`（返回值）仍会抛（read 侧未吞），行为在「调用方视角」与「队列视角」不一致。
- 影响：快速连播时某次写入失败（磁盘满、开箱失败）被完全静默，最近播放悄悄缺记录；排查时无任何日志。
- 证据等级：实锤（catchError 体在本文件内确认）

### recent_play_store.dart:58-66 `read()` 的懒开箱与 `_addInner` 的重复开箱判断并存，`openBox` 无 in-flight 合并
- 级别：P2
- 违反：QUALITY_STANDARD 第 18/22 条（并发假设须写明或保护）
- 依据：`read()` 用 `if (!Hive.isBoxOpen(_boxName)) await Hive.openBox(_boxName);`，`_addInner` 又自行 `Hive.isBoxOpen(...) ? _box : await Hive.openBox(...)`；两处都无进行中 Future 复用。`_serial` 队列只串行化 add，不覆盖「UI 调 read() 与 add 并发开箱」的窗口。与 download_store 的「外部开箱」模式、account_manager 的 init 模式形成本域第三种开箱口径。
- 影响：冷启动首帧读最近播放与写入并发时可能双开箱（Hive 内部通常幂等，影响有限）；若开箱抛错，read 路径异常直接冒泡到 UI 层无兜底，最近播放页报错。
- 证据等级：静态推演（开箱路径为本文件实锤）

### recent_play_store.dart:47-48 `_box` getter 抛 StateError，`clear()` 先判 isBoxOpen 绕开，但 read() 在 `await Hive.openBox` 之后调用 `_box` 的窗口存在竞态
- 级别：P3
- 违反：QUALITY_STANDARD 第 20 条（生命周期对称）
- 依据：`_box` getter 在盒未开时抛 `StateError('recent_plays box 未打开')`；`clear()` 用 `if (!Hive.isBoxOpen(_boxName)) return;` 静默不清理（清空操作在盒未开时被静默忽略，无留痕——设置页「清空最近播放」可能什么都不做且用户不知情）。read() 开箱后紧接 `_box.get`，若开箱失败（异常已抛）则无此窗口，但若 isBoxOpen 检查与 openBox 之间被并发 close（热重载/测试）会命中 getter 的 throw。
- 影响：盒未开时「清空最近播放」按钮看似生效实际未清任何数据；无直接崩溃。
- 证据等级：实锤（分支结构）

---

## 7. `lib/features/download/download_provider.dart`（492 行，完整读）

### download_provider.dart:107-113 `add()` 对「已存在但不在运行」的同 id 任务直接覆盖，丢进度语义但保留旧文件引用
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作防重/幂等语义须明确）、第 18 条（世代）
- 依据：`add()` 只在 `exists && _running.contains(task.id)` 时取消旧任务；对 paused/failed/completed 的旧任务直接 `_replace(newTask)` 覆盖（received/total 归 0、filePath/mediaUri 保留旧任务的 copyWith 未清除——`copyWith` 的 filePath/mediaUri 是否清空取决于 download_task.dart 的 copyWith 签名，未在此清除）。若旧任务是 completed 且已发布文件存在，重下完成后 `queryExisting → delete → publish` 会删旧发新（自洽），但下载中途用户看到的是「新任务 + 旧文件的 mediaUri」，此时播放该任务会命中旧文件。
- 影响：重新下载不同音质时，下载进行中点击已存在入口可能播放旧的低音质文件，用户误以为新音质已生效。
- 证据等级：静态推演（覆盖分支不清理文件引用为实锤；copyWith 默认保留字段语义待 download_task.dart 核对）

### download_provider.dart:258-276 `_schedule` 的 while 循环读 `state.tasks` 后 `unawaited(_run)`，`_run` 首个 await 前同步置 running——但 `_update` 异步写 Hive，循环内 `_running.add` 与 `_run` 的 `state` 更新顺序无锁，多入口并发调用 `_schedule` 可能双启同一任务
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明并保护）、第 19 条（闸门归属）
- 依据：`_schedule` 被 `add/pause/resume/remove/clearAll/finally` 多处 `unawaited` 调用；循环条件 `_running.length < maxConcurrent` 与 `next.first` 读取之间无原子性保证，但 `_running.add(task.id)` 在 `_run` 前同步执行（单 isolate 下 `_schedule` 的 while 轮次间不会插入其他 `_schedule`，除非其中 await——`_schedule` 本体无 await，安全）。**真正风险**：`_run` 中 `resolveAudioDownloadSource` 等长 await 期间任务可被 remove/pause 改状态，`onProgress` 与完成回调均校验 `cur.status != running` 与 token，防护已做。但 `finally` 的槽位判定 `_tokens[task.id] != null && _tokens[task.id] != token` 在「resume 同 id」时（`add` 已 `_running.remove` + 新 `_run` 未启动的窗口）可能双跑两次 `_schedule` 造成超发（并发仍被 while 上限挡住）。整体防护较完整，残余问题：`add()` 取消旧任务后**未等旧 `_run` 的 finally 落幕**即 `_replace` 新任务，旧 `_run` 的 catch 若在 `_replace` 之前执行 `_update(cur...)`（cur 已是新任务）会把新任务改写为 paused/failed。
- 影响：快速「暂停→重新添加同 id」时新任务偶发被旧回调改写状态，表现为进度条回退或显示失败但实际在下载。
- 证据等级：静态推演（`_replace` 与旧 `_run` catch 之间无世代校验为实锤；时序窗口需并发触发）

### download_provider.dart:355-360 `catch (e)` 通用分支用 `friendlyError(e)` 后**不落日志**，下载失败只有 UI error 文本
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）
- 依据：通用 `catch (e)` 分支仅 `_update(... error: friendlyError(e) ...)`；无 ErrorLogger 记录原始异常与栈（对比 `_update` 内状态迁移有 verbose 日志）。DioException 分支同样只存 `e.message ?? '下载失败'`，丢栈。
- 影响：用户反馈「下载失败」时线上无原始异常可查（只剩友好文案），无法区分存储满/URL 失效/磁盘 IO 错。
- 证据等级：实锤

### download_provider.dart:290-296 `remove()` 中临时文件清理 `catch (_) {}` 空体吞异常（注释自称「系统会回收」但 Android 临时目录并不保证）
- 级别：P3
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）
- 依据：`try { ... for (final path in candidates) { ... if (f.existsSync()) f.deleteSync(); } } catch (_) {}`——`deleteSync` 失败被空 catch 吞；`existsSync` 本身也可能抛（权限）。缓存注释「临时目录会由系统回收」对 app 私有 cache 目录成立，但 `PublicMediaStore.tempDir()` 若指向外部目录则不成立（跨文件核对 public_media_store）。
- 影响：临时大文件残留占存储，用户无感知；属泄漏路径。
- 证据等级：实锤（空 catch + 跨文件口径待 public_media_store 核对）

### download_provider.dart:425-430 `clearAll()` 串行 await 每个任务的公共文件删除，任一抛错则后续任务文件与 Hive 记录全部跳过
- 级别：P2
- 违反：QUALITY_STANDARD 第 6/9 条（失败可观测、逐条隔离）、第 21 条
- 依据：`for (final t in state.tasks) { _tokens[t.id]?.cancel(...); await PublicMediaStore.instance.delete(...); }`——无 try/catch；第一个 delete 抛错（文件已被用户手动删除、MediaStore 记录失效）即中断循环：`_tokens.clear()`、`state = const DownloadState()`、`DownloadStore.clear()` 都不执行，任务与文件进入半清理态且异常冒泡给调用方（UI 是否捕获未知）。已 cancel 的任务其 `_run` 的 DioException catch 会把状态写回 paused/failed（`_tokens[task.id] != token` 为假？——clearAll 只 cancel 未替换 token，guard 通过，会 `_update`），与随后的 `state = const DownloadState()` 竞态写回。
- 影响：「清空全部下载」在某个文件删除失败时整批失败，列表不清、文件残留，且无逐条提示哪个失败。
- 证据等级：静态推演（循环无隔离为实锤）

### download_provider.dart:97-101 `_restore()` 在构造函数中同步调用 `DownloadStore.readAll()`（同步 Hive 读），box 未打开时静默空列表（download_store 问题在本类的表现）
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 16 条
- 依据：`DownloadManager(this._repo) : super(...) { _restore(); }` 构造即读 Hive；`downloadManagerProvider` 无任何 ensure-open 步骤。download_store 的静默 null 盒路径叠加本处，意味着启动时序中 provider 早于开箱时任务全空且不报错。同时恢复的 paused 任务不自动排队（合理），但也没有「上次未完成」的任何用户提示。
- 影响：开箱时序异常时用户下载列表「消失」（实际记录还在盒里，重启可复现差异），用户以为任务被清空。
- 证据等级：静态推演（构造即读 + store 静默分支成对确认；实际开箱时序未实测）

---

## 8. `lib/features/comment/presentation/comment_floor_page.dart`（356 行，完整读）

### comment_floor_page.dart:350-351 `CommentRepository` 由 UI 层 provider 直接 new，注入 `kugouApiClientProvider`（kapi 底座）
- 级别：P2
- 违反：QUALITY_STANDARD 第 4 条（UI 层不得绕过数据层装配约定）、REVIEW_SPEC「UI 层零直接构造 Repository / Repository 不得 new 裸 KugouApiClient」
- 依据：`final _floorRepoProvider = Provider<CommentRepository>((ref) => CommentRepository(ref.watch(kugouApiClientProvider)));` ——页面私有 provider 直接构造 Repository。`kugouApiClientProvider` 按 B1 结论是装配层注入直连实例的入口（此处用法正确），但构造位置在 UI 文件内，与其他域「data/ 层暴露 provider」的装配口径不一致；若该端点有直连实现则依赖 repo 内部处理，跨文件核对 comment_repository。
- 影响：无直接用户可见错误；架构一致性问题，直连改造时该路径易被遗漏。
- 证据等级：实锤（provider 定义在本文件内）

### comment_floor_page.dart:110-117 / 125-131 `_hasMore = comments.isNotEmpty && _comments.length < result.total`，上游 total 口径与去重叠加可能提前停页
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失语义分离）、第 29 条（total 语义须实测）
- 依据：`_hasMore` 依赖 `result.total`（上游字段，未在页面侧验证存在性/单位）与 `_comments.length`；若上游 total 含被过滤条目或分页返回与 total 不同源（实测口径问题），翻页提前终止或死循环翻页（isNotEmpty 保护了空页终止）。加载更多无去重（`_comments.addAll(result.comments)`），上游重复返回会重复渲染。
- 影响：回复列表可能提前显示「到底」或出现重复楼层；属上游契约依赖，需实测留样佐证。
- 证据等级：静态推演（页面逻辑实锤；fetchFloor 的 total 语义待 comment_repository 抽查 + 未实测）

### comment_floor_page.dart:167-170 `_send()` 在校验 `_sending` 之前先 `_inputCtrl.clear()`——失败还原依赖 catch，但连续快速提交窗口内输入被清
- 级别：P3
- 违反：QUALITY_STANDARD 第 21 条（防重闸门应在副作用前生效）
- 依据：`_inputCtrl.clear(); if (_sending) return; _sending = true;` ——若 `_sending` 已为 true，输入已被清掉且不会走 catch 还原（提前 return），用户正在输入的回复静默丢失。
- 影响：发送进行中再按一次发送（软键盘 send 键连点），第二次的草稿被清空且无提示。
- 证据等级：实锤（语句顺序）

### comment_floor_page.dart:127-145 发送成功后 `_load()` 重载第 1 页，长列表场景新回复不在首屏时用户以为发送失败
- 级别：P3
- 违反：QUALITY_STANDARD 第 9 条（成功/结果可感知）
- 依据：`Toast.show(... commentSuccess); await _load();` 重拉第 1 页；楼中楼回复通常按时间倒序/正序取决于上游，若新回复插到末页，列表既不滚动定位也不插入本地。
- 影响：用户发送成功但找不到自己刚发的回复（尤其回复数多时），产生「发出去了吗」困惑；仅提示语一处成功反馈。
- 证据等级：静态推演（上游排序未实测）

---

## 9. `lib/features/album/presentation/album_page.dart`（276 行，完整读）

### album_page.dart:57-89 `_loadSongs` 失败后不重置 `_page` 也不推进，refresh 分支的 `_loading` 在 setState 之外赋值，非 refresh 分支失败时 `_page` 不回退——重复触发会跳页
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步失败须保持状态一致）、第 16 条
- 依据：非 refresh 路径 `_page` 只在成功分支 `+= 1`，失败分支只复位 loading 标志——这部分正确。但 `_onScroll` 在 `_loadingMore || _loading` 时直接 return，而失败后两者均为 false，滚动到底立即重试同页（正确）。**真正问题**：refresh 分支中 `_page = 1; _total = 0; _error = null;` 在 `setState` **外**直接赋值，仅 `_songs.clear(); _loading = true` 在 setState 内——若 refresh 时上一次 `_loadMore` 仍在飞行（下拉刷新未被禁止，`RefreshIndicator` 未包裹此处，本页无下拉刷新；但 `initState` 与 `_onScroll` 竞态：首帧前 `maxScrollExtent==0` 挡住，风险低）。更实际的：`_loadSongs(refresh:true)` 期间 `_onScroll` 触发的 `_loadSongs()`（非 refresh）被 `_loading` 挡住，成功；但 `_loading=false` 置于共享 setState——若 refresh 请求与 loadMore 请求并发（loadMore 先发出、refresh 后触发），loadMore 的成功回调会把 `_page` 在 refresh 重置后 `+1` 并把旧页歌曲 addAll 进已清空列表，`_total` 也被旧响应覆盖。
- 影响：进入专辑页瞬间（initState 先 `_fetchInfo`/`_loadSongs`）快速滚动触发 loadMore 与手动刷新交错时，列表出现重复歌曲或计数错乱。
- 证据等级：静态推演（无请求世代/序号校验为实锤）

### album_page.dart:91-94 `_playAt` 构造 Song 丢 `quality`/`isLocal`/`mvHash` 等字段，依赖 Song 默认值
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（跨层字段契约）
- 依据：`_playAt` 只映射 hash/albumId/albumAudioId/name/artist/cover/duration 7 个字段；AlbumSong 若含其他字段（跨文件核对 album_repository）则丢弃。与播放侧契约（playQueue）需 song 域齐备字段对照。
- 影响：若上游 AlbumSong 有影响播放的字段（如 original hash 形态）未映射，表现为该专辑歌曲播放行为与其他入口不一致（音质回退不同等）。
- 证据等级：静态推演（待 album_repository 抽查补判）

### album_page.dart:118-124 `snap.data!` 非空断言位于 hasError 分支之后，FutureBuilder 成功后重建安全；但 `_info` retry 用 `setState(() => _info = _fetchInfo())`，旧 Future 未取消
- 级别：P3
- 违反：QUALITY_STANDARD 第 18 条（世代校验）
- 依据：重试直接替换 Future，旧请求完成结果被 FutureBuilder 自动忽略（重建读取新 future），安全；但若页面在旧请求飞行中 dispose，`_fetchInfo` 的 ref.read 在 dispose 后仍持有 provider（riverpod 安全）。此处风险极低，仅记录 Future 未持有 CancelToken。
- 影响：无可见后果；属资源对称性记录项。
- 证据等级：静态推演

---

## 10. `lib/features/playlist/presentation/add_to_playlist_sheet.dart`（326 行，完整读）

### add_to_playlist_sheet.dart:95-115 `_addTo` 中 `Navigator.of(context).pop()` 在 finally 复位 `_busy` 之前执行，pop 后 `if (mounted) setState` 不执行——成功路径 `_busy` 永不复位（State 销毁，无实际后果）；但 pop 与 `_reload` 的 FutureBuilder 竞态
- 级别：P3
- 违反：QUALITY_STANDARD 第 20 条（生命周期对称）
- 依据：成功分支 `Toast → Navigator.pop()`，`finally { if (mounted) setState(() => _busy = false); }`——pop 后 State 已 unmount，复位跳过（无泄漏，因 State 随页销毁）。但 `on PlaylistWriteException` 与通用 catch 分支的 `Toast.show(context, ...)` 在 `mounted` 检查下执行，pop 未发生，正常。整体无实害，仅记录。
- 影响：无直接用户可见后果。
- 证据等级：实锤（语句顺序）

### add_to_playlist_sheet.dart:155-176 `_createAndAdd` 的「按名称+基线差集」定位新歌单仍依赖两次 `fetchUserPlaylists` 之间无并发变更；`collectPlaylist` 成功但 `fetchUserPlaylists` 失败时抛通用异常，用户不知道歌单已创建
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败可观测、结果未知须区分）、第 11 条（降级语义）
- 依据：`await repo.collectPlaylist(name: trimmed); final list = await repo.fetchUserPlaylists();` ——若第二步抛错，进入通用 `catch (e) { Toast(friendlyError(e)); }`，提示的是「加载失败」类文案，而事实是「歌单已创建、歌未加」。与 `_addTo` 特意区分的 `PlaylistWriteException`「结果未知」口径不一致（第 8 条异常形态）。另外第二个用户在另一设备同步建同名歌单的极端场景会导致 created 定位错乱（可接受）。
- 影响：用户看到报错但歌单实际已创建，重试操作会再建一个同名歌单（服务端不阻止同名），产生重复歌单。
- 证据等级：静态推演（两次请求顺序与 catch 分支为实锤）

### add_to_playlist_sheet.dart:97-101 `_busy` 闸门只防本页并发，`showAddToPlaylistSheet` 可与播放页/搜索页同时打开两个实例各自 `_busy`
- 级别：P3
- 违反：QUALITY_STANDARD 第 21 条（写操作防重应在共享层强制）
- 依据：防重是 State 级布尔；仓库层 `PlaylistRepository._write` 有 `_inFlight`（b2_merged 确认），本页注释也声称「防重/失败语义在仓库层已统一」，双层防护成立；本条仅记录 UI 闸门不跨实例的事实。
- 影响：无直接可见后果（仓库层兜底）。
- 证据等级：实锤（本页）+ 静态推演（仓库层）

### add_to_playlist_sheet.dart:52-56 `showAddToPlaylistSheet` 未登录时弹层仍打开（build 内才显示登录引导），`_reload` 对未登录置 `_playlistsFuture = null`，FutureBuilder 显示 spinner 永转
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（未登录与无数据语义分离）、第 3 条
- 依据：`_reload()` 对 `user == null` 执行 `setState(() => _playlistsFuture = null)`；FutureBuilder 的 `future: _playlistsFuture` 为 null 时 `snap.connectionState` 为 none（不是 waiting），走 `snap.hasError` 为假 → `snap.data ?? const []` → 显示空列表 + 「新建歌单」入口。但 build 内 user==null 分支直接走 `if (user == null) Expanded(EmptyState(loginRequiredHint))`，FutureBuilder 不渲染——**该分支正常**。真正的边界：登录态在弹层打开期间由已登录变为失效（token 过期），`_playlistsFuture` 已发出且会失败 → `snap.hasError` 显示「加载失败/重试」，重试 `_reload` 检测到 user==null 置 future=null 后 build 因 user==null 走登录引导——链路自洽。撤销本条候选，改为记录：`FutureBuilder` 的 `future: null`（`_playlistsFuture = null`）与 waiting 的区分依赖 `user` watch，跨分支一致性成立。
- 影响：无直接用户可见后果。
- 证据等级：实锤（分支推演后未发现问题，复核通过项见文末）

---

## 11. `lib/features/search/presentation/search_page.dart`（819 行，完整读）

### search_page.dart:64-77 `_onChanged` 的 debounce 回调无请求世代编号，依赖 `_controller.text.trim() != text.trim()` 做世代判定
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）
- 依据：`if (!mounted || _controller.text.trim() != text.trim()) return;` ——以「输入框文本是否仍等于发起时的文本」做世代校验。该判定在多数场景成立，但存在漏洞：用户输入 A → 等待中清空再输入 A（同文本），旧请求返回与新请求结果不可区分（结果相同，无害）；用户输入 A → 输入法组合态修正后仍为 A（无害）。**真正的缺口**：`fetchSuggest` 抛异常（网络失败）时 debounce 回调**无 try/catch**，异常沿 Timer 回调冒出为未捕获异步异常；联想词失败完全不可观测（对照 `_loadMore` 等处的失败态处理）。
- 影响：断网/接口失败时每次停顿输入都抛一次未处理异步异常（debug 崩溃、release 静默），联想区域保持旧内容或空白，用户无任何失败提示。
- 证据等级：实锤（回调体无 catch）

### search_page.dart:80-94 `_submit` 中 `addHistory` 写入失败已兜底（R-27），但 `setState` 里 `_controller.text = k` 会再触发 `_onControllerChanged`/`_onChanged`，一次提交触发两轮联想请求
- 级别：P3
- 违反：QUALITY_STANDARD 第 24 条（避免冗余计算/请求路径）
- 依据：`_controller.text = k` 触发 listener → `setState`；但 `_submit` 未调 `_onChanged`，`_onControllerChanged` 只做重建，**不**发联想请求（联想只在 `_onChanged`/SearchBar `onChanged` 回调里发）——SearchBar 的 `onChanged` 不会因程序化赋值触发。因此无冗余请求；`_showSuggest=false` 状态自洽。撤销嫌疑，复核通过。
- 影响：无。
- 证据等级：实锤（listener 注册链核对）

### search_page.dart:545-552 分页失败 Toast 用 `genericErrorTitle` 且无去重实现，注释「弹一条去重 Toast」与实现不符
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）
- 依据：注释「列表已有内容时静默降级：仅弹一条去重 Toast」，实现是 `Toast.show(context, context.l10n.genericErrorTitle)`，无去重逻辑（连续滚动失败会连续弹）。且用 `genericErrorTitle`（标题级通用文案）替代具体失败信息，与同文件 `_pageError` footer 重试的 friendlyError 口径（comment_floor_page 用 `friendlyError(e)`）不一致。
- 影响：弱网下连续滚动连续弹「错误」无差别 Toast；用户与日志都拿不到失败原因。
- 证据等级：实锤

### search_page.dart:453-478 / 643-658 `s.hash ?? s.id` 双形态兜底分散在两处，`hash` 为空的 Song 传入下载/播放后行为依赖下游
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界字段缺失须在入口统一校验）、第 16 条
- 依据：`TrackRef(name:..., hash: s.hash ?? s.id, ...)` 与下载路径 `Song(hash: s.hash ?? s.id, ...)` ——若 `hash` 与 `id` 均为空串（上游字段缺失），TrackRef.hash 为空串；add_to_playlist_sheet 的 `_addTo` 对 `hash.trim().isEmpty` 有守卫并 Toast「操作失败」（该守卫成立），但 `showDownloadSheet`/`playHomeQueue` 侧是否校验空 hash 待抽查（跨文件）。搜索结果 v3 接口字段 hash 缺失通常意味试听受限歌曲，此时「播放/下载」入口仍可点。
- 影响：点击受限歌曲的播放/下载后走到下游报错或静默失败，入口未在源头禁用。
- 证据等级：静态推演（本页兜底为实锤；下游校验待 download_sheet 抽查）

### search_page.dart:800-819 `_genericSearchProvider` / `_playlistSearchProvider` 是 family FutureProvider 且用 `ref.read` 构造 repo——provider 会缓存结果，同 keyword 重进页面不刷新（无 TTL/自动失效），刷新仅靠错误重试 invalidate
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存维度）、第 9 条
- 依据：`FutureProvider.family` 在 provider 未被 watch 释放后自动 dispose（riverpod 默认 autoDispose 未启用，本处非 `.autoDispose`），同一 keyword 的结果在整个 app 生命周期被缓存；用户搜「周杰伦」→ 进歌手页 → 返回 → 结果仍是旧缓存（通常可接受），但上游数据更新（新歌上架）永不刷新，且无任何刷新入口（无下拉刷新）。`ref.read` 在 provider body 中不建立依赖，repo 替换（如登录态变化）不触发重建。
- 影响：长时间使用后搜索结果陈旧且无法刷新（无下拉刷新设计）；匿名→登录后结果不随权益变化。
- 证据等级：实锤（provider 定义非 autoDispose）

---

## 12. `lib/features/auth/presentation/captcha_page.dart`（454 行，完整读）

### captcha_page.dart:44 `late final _service = VerificationService(widget.api, ref.read(kgClientProvider));` 在字段初始化期读 `ref`（Riverpod 禁止在 initState 前使用 ref）
- 级别：P1
- 违反：QUALITY_STANDARD 第 20 条（生命周期）、riverpod 框架契约
- 依据：`late final` 字段初始化器含 `ref.read(...)`，首次**访问**时机决定是否合法——首次访问发生在 `_load()`（initState 内调用），late 初始化推迟到那时，initState 中读 `ref.read` 对 ConsumerState 是允许的（风险低于真正的初始化期读取）。但若 `_service` 在任何 build 前未被触达而 `kgClientProvider` 依赖被重建（provider 变更），late final 缓存的 VerificationService 将持有过期 `KgClient`（设备 mid 世代），验证指纹用旧 mid 提交。
- 影响：直连层设备标识更新后（dfid 重建、KgClient 替换），验证页仍用旧 client 派生 edt，验证通过率异常下降且无日志。
- 证据等级：静态推演（late final 缓存语义为实锤；KgClient 是否运行期重建待 kg_providers 抽查）

### captcha_page.dart:203-207 `catch (e) { done('', ''); }` 滑块初始化失败回调空 ticket，`_submitWithCode(s, VerifyCode.tencent(ticket:'',...))` 会用空 ticket 提交
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界数据校验）、第 9 条
- 依据：JS 侧 `done('', '')` 经 `onCaptchaResult` handler 进入 Dart；`ticket.isNotEmpty && randstr.isNotEmpty` 守卫拦住空值（**有守卫，正确**）——但用户侧表现为：滑块初始化失败（脚本 404/超时）后**无任何反馈**（守卫静默 return），遮罩在 `_submitting=false` 下消失，WebView 停在白屏按钮。
- 影响：腾讯验证脚本加载失败时用户看到「点了按钮没反应」，无失败提示无重试路径（只能关页重开）。
- 证据等级：实锤（守卫与无 else 分支成对确认）

### captcha_page.dart:216-219 `onLoadStop` 无错误回调注册（`onLoadError`/`onReceivedError` 缺失），WebView 资源加载失败静默
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 20 条
- 依据：`InAppWebView(... onLoadStop: ...)` 未注册任何错误回调；`turing.captcha.qcloud.com` 被墙/断网时页面停留初始 HTML，`_webViewReady` 仍会置 true（onLoadStop 对 initialData 仍触发），无网络感知。
- 影响：断网用户进入腾讯验证页后自动弹出失败、无提示，表现为「卡住」。
- 证据等级：实锤（回调列表）

### captcha_page.dart:430-441 `onVerified` 重试失败仍 `pop(true)`——返回 true 语义为「验证通过」，调用方 `runWithVerification` 会无条件重试原操作
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（返回值契约）、第 16 条（失败与成功语义分离）
- 依据：`if (retried) { pop(true); return; } setState(...); _snack(captchaPassedButRetry); pop(true);` ——重试失败也 pop(true)。verification_guard 侧 `if (ok != true) return null;` 后进入下一轮循环重试 action（guard 自身循环会再试一次），语义上是「验证通过，让 guard 再试」自洽；但 `captchaPassedButRetry` 提示与 pop(true) 组合后，若调用方是**不循环的**直接调用（如 CaptchaPage.onVerified 的其他使用方），pop(true) 会被理解为「流程成功」。双消费方契约靠约定而非类型。
- 影响：仅 guard 路径正确；若存在其他直接调用方（跨文件核对调用面），重试失败被误报成功。
- 证据等级：静态推演（pop(true) 分支实锤；调用面待核对）

### captcha_page.dart:150-155 `_buildByType` 对 geetest/kugou/kugouRotate/shumei/yidun/liveness/face 全部走 `_buildExternal`（仅提示 + 关闭按钮），这些类型验证流程实际不可完成
- 级别：P1
- 违反：QUALITY_STANDARD 第 16 条（失败/不可用语义须明确传达）、第 3 条
- 依据：`_buildExternal` 只显示「该类型需在官方 App 完成」类提示与关闭按钮，无深链/WebView 兜底；`supportedInApp`（captcha_types.dart）只覆盖 tencent/sms 与此一致——即上游风控下发这 7 类验证时，用户验证闭环**必然失败**，仅有一条提示。而 `runWithVerification` 的重试上限 2 次后直接「验证多次未通过」，业务操作永久失败。
- 影响：被风控判定为极验/数美/易盾/活体的用户（含匿名高频操作用户常见）无法完成任何需要验证的操作（登录/播放/评论），且提示未给出替代路径（如引导网页登录）。
- 证据等级：实锤（分派表与 _buildExternal 实现）

### captcha_page.dart:326-332 短信验证无「发送验证码」入口，直接输入验证码提交
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（流程契约：sms 类型需要先触发下发）
- 依据：`_buildSms` 只有输入框 + 提交按钮，无「获取验证码」按钮、无倒计时；v_type=32 流程中验证码下发通常需要先调下发接口（跨文件核对：verification_service.submit 只提交，无 sendSms）。若上游在 20028 时已自动下发则成立，否则用户永远收不到码。
- 影响：短信验证用户可能收不到验证码（无触发路径），验证无法完成。
- 证据等级：静态推演（本页无发送入口为实锤；上游是否自动下发未实测，按第 29 条标注）

---

## 13. 跨文件契约抽查：`lib/features/album/data/album_repository.dart`（166 行，完整读）

### album_repository.dart:32-33 `AlbumInfo.fromJson` 对 `data` 非数组非 Map 时回落 `j` 整包解析，错误响应体可被解析为「空专辑」
- 级别：P2
- 违反：QUALITY_STANDARD 第 13/14 条（边界形态校验）、第 16 条
- 依据：`final Map d = raw is List && raw.isNotEmpty && raw.first is Map ? raw.first as Map : (raw is Map ? raw : j);` ——上游返回错误体 `{errcode, error}`（无 data）时 `d = j`，`name=''`，页面显示空标题 + 0 首歌，与「加载失败」不可区分（fetchDetail 不判成功码，成功判定交由 reads/拦截器——若该端点错误形态以 200+Map 返回则穿透）。duration 单位毫秒（`Duration(milliseconds:)`，audio_info.duration 实测 ms）与播放侧秒单位转换需跨层一致，注释已标明（通过项）。
- 影响：专辑接口业务失败时显示「空专辑页」而非错误重试，用户以为专辑无歌曲。
- 证据等级：静态推演（回落分支实锤；该端点失败形态未实测，按第 29 条标注）

### album_repository.dart:147-151 `total` 解析失败回落 `songs.length`，与分页 `_hasMore` 组合可截断列表
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条、第 23 条
- 依据：`int.tryParse('${d['total'] ?? ''}') ?? songs.length` ——当 total 字段缺失/非数值且本页恰好满 50 条时，`songs.length=50 == _total`，album_page 的 `_songs.length >= _total` 判定停止翻页；若实际有更多页，列表被静默截断。
- 影响：total 字段形态变化时专辑歌曲列表只显示第一页且无「加载更多」入口。
- 证据等级：静态推演（回落值与消费方判定成对确认）

### album_repository.dart:120-123 `fromJson` 的 `duration` 字段以注释声明毫秒——与 `/album/songs` 实测口径绑定，无运行时校验
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位显式依赖注释）
- 依据：`// duration 单位毫秒` + `Duration(milliseconds: i(audio['duration']))`；若上游部分路径返回秒（KG 接口历史上混用），时长会差 1000 倍。搜索/歌手路径的 duration 为秒（search_page `Duration(seconds: s.duration)`），两条路径单位不同但各自硬编码，无统一换算点。
- 影响：单位口径错误的端点会让专辑页显示的时长错误 1000 倍（如 4 分钟显示为 240 小时）；需实测留样佐证当前正确性。
- 证据等级：静态推演（单位假设未实测，按第 29/33 条标注）

---

## 14. 跨文件契约抽查：`lib/features/download/data/download_task.dart`（267 行，完整读）

### download_task.dart:47-53 / 117-125 `id = '${type.name}_$hash'` 不含 quality/albumAudioId，同 hash 不同音质任务同 id（provider 侧「覆盖」语义由此而来）
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（任务身份必须覆盖影响内容的维度）
- 依据：注释「任务唯一 id：类型 + hash」；下载管理器 `add()` 依赖「同 id 覆盖」处理重下，临时文件 dimKey 含 quality/albumAudioId 而 id 不含——**行为上自洽**（重下换音质是覆盖语义），但 completed 任务的 filePath 是旧音质产物，重下进行中 `hasAudio(hash)` 仍返回 true（status 仍是 completed？——add 时 copyWith(status: queued) 后不再是 completed，hasAudio 正确翻转）。核对结论：id 维度设计是有意为之且有注释链（DL-03/V399-B4），临时文件维度已修。残余问题：`DownloadTaskType.lyric` 与 `audio` 任务同 hash 时 id 不同（type 区分），但同一 audio 任务切 targetLanguage 重下也覆盖（歌词翻译语言不受影响，audio 任务 targetLanguage 无用维度——`targetLanguage` 对 audio/cover/mv 任务是死字段，第 32 条轻微）。
- 影响：无直接用户可见错误；`targetLanguage` 对非 lyric 任务是恒定默认值的冗余持久化字段。
- 证据等级：实锤（字段与 id 构造）

### download_task.dart:31-37 `audio => '.mp3'` 默认扩展名与 realTempPath 机制并存，remove() 重建路径依赖 `${task.type.fileExtension}`——lyric/mv 的一致，audio 的 `.mp3` 回落与 download_provider 的重建规则一致（抽查通过）
- 级别：P3
- 违反：无（复核项）
- 依据：download_provider.dart:140-152 的 candidates 重建用 `task.type.fileExtension`，与本文件扩展名表一致；V34-05 修复链完整。
- 影响：无。
- 证据等级：实锤（两处对照）

---

## 15. 跨文件契约抽查：`lib/features/comment/data/comment_repository.dart`（279 行，完整读）

### comment_repository.dart:83-139 写操作（send/sendFloorReply/deleteComment）全部走 `_api.post`，仓库层**无本地提交锁**（对照 PlaylistRepository._write 的 `_inFlight`）
- 级别：P2
- 违反：QUALITY_STANDARD 第 21 条（写操作幂等/防重）、第 22 条（并发假设）
- 依据：`sendComment/sendFloorReply/deleteComment` 直接 `_api.post(...)` 无任何防重；防重完全依赖 UI 层 `_sending` 布尔（comment_floor_page 有，comments_page 抽查确认有 `_sending` 同源）。b2_merged 第 3 条已把「CommentRepository 写端点是否受同一闸门」列为待核实——本批核实结论：**仓库层无闸门，防重仅存在于 UI 布尔**；任何新的调用入口（如 verification_guard 重试、未来其他页面）绕过 UI 闸门即重复提交。`sendComment` 发送前还有一次 `fetchComments` 探测 childrenid（catch 静默吞，注释已声明兜底），非幂等的「先读后写」组合无锁。
- 影响：UI 防重布尔之外的路径（异常重试、快速双指操作）可重复发评论/删评论；删除操作重复提交在服务端通常幂等（返回已删），发评论重复提交产生重复楼层（用户可见）。
- 证据等级：实锤（三方法无锁；UI 层闸门已在通读文件确认）

### comment_repository.dart:76-80 `fetchCount` 对 `data[hash]` 三形态探测，未判响应成功即取值
- 级别：P3
- 违反：QUALITY_STANDARD 第 29 条（成功判定逐端点）
- 依据：`data[hash] ?? data[hash.toUpperCase()] ?? data[hash.toLowerCase()]`；若上游返回 `{status:0, error:...}` 失败体，取不到键回落 0——「评论数 0」与「查询失败」同化（第 16 条）；b2_merged 确认 `/comment/count` 是裸 Map 成功语义、B1 hasStatus 守卫已修拦截器侧。调用方（song 页等）显示 0 评论属静默降级。
- 影响：接口失败时歌曲页显示「0 条评论」，用户误以为无评论。
- 证据等级：静态推演（本层无失败分支为实锤）

### comment_repository.dart:158-170 `CommentPage.fromJson` total 回落 `comments.length`，与分页 `_hasMore` 组合同 album_repository 问题（评论列表可能提前到底）
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条
- 依据：`_asInt(..., fallback: comments.length)`，comment_floor_page 的 `_hasMore = length < total` 在 total 缺失且本页满 30 条时判 false，翻页终止。
- 影响：楼中楼回复多时列表静默截断在第 1 页。
- 证据等级：静态推演（与 floor 页消费逻辑成对确认）

### comment_repository.dart:203-210 `isMine` 判定依赖 `_api.userid`，匿名/未登录时恒 false——删除按钮消失，符合设计；但 userid 空串时 `isNotEmpty` 守卫已做（复核通过项）
- 级别：P3（复核通过）
- 证据等级：实锤

---

## 16. 跨文件契约抽查：`lib/features/auth/presentation/verification_listener.dart`（60 行，完整读）

### verification_listener.dart:36-44 `ref.listen` 在 `build` 内注册但 `_handle` 用 `Navigator.of(context)`，验证页弹出时若 widget 正在重建（MainShell 切 Tab）`context` 可能失配——`mounted` 守卫存在，风险低
- 级别：P3
- 违反：QUALITY_STANDARD 第 18 条
- 依据：`_handling` 防重入正确；`ok == true && mounted` 后 `retryPendingPlayback()` 无 try/catch——重试播放本身抛异常（如再次 20028）会从 finally 落幕但异常冒泡为未处理异步错误（`_handle` 调用处无 await 方，ref.listen 回调 fire-and-forget）。
- 影响：验证通过后重试播放若再遇 20028，异常无人接管，用户看到验证「成功」但播放仍失败且无第二次弹窗（listen 回调仅在新事件时触发）。
- 证据等级：静态推演（无 catch 为实锤；`retryPendingPlayback` 是否内部吞异常待 player 域核对）

### verification_listener.dart:40-42 验证事件流 `verificationStreamProvider` 的 `next.valueOrNull` 每次状态变化都检查，但 `_handling` 期间到达的事件被**丢弃**（不排队）
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（事件丢失语义）、第 18 条
- 依据：`if (api == null || _handling) return;` ——验证中又收到新的 20028 事件（如自动连播下一首也触发）时该事件被丢弃；若验证通过后 `retryPendingPlayback` 只重试「最后一个 pending」，中间被丢事件的曲目可能永久跳过（播放队列静默跳歌，与 b2_merged 播放静默跳歌同型）。
- 影响：连续多首触发验证时，部分歌曲验证完成后不恢复播放，用户队列悄悄缩短。
- 证据等级：静态推演（丢弃分支实锤；retryPendingPlayback 的 pending 数量语义待 player 域，未读，标注未核实）

---

## 17. 跨文件契约抽查：`lib/features/settings/presentation/settings_providers.dart`（38 行，完整读）

### settings_providers.dart:6-11 `_box()` 的 `catch (_) {}` 与未打开返回 null——`set()` 在 box 未打开时**静默丢设置**，state 已改但持久化失败无留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 5 条（状态单一来源：内存 state 与 Hive 双写不校验一致性）
- 依据：`state = quality; await _box()?.put(...)` ——box 未打开（settings 开箱在启动时序中的失败路径）时 state 改成新音质但写盘静默跳过，重启后回退旧值；无日志。构造器同样 `_box()?.get(...) ?? '320'` 静默回落默认值，与持久化值不可区分。对照 settings 域其他 Notifier（settings_page 抽查时核对同型）。
- 影响：用户改默认音质后重启发现「设置没保存」，且无任何提示与日志可查。
- 证据等级：实锤

### settings_providers.dart:13-14 构造器在 provider 创建（首次 watch）时读 Hive，`Hive.box('settings')` 若被以其他类型打开过抛异常由 `_box()` catch 吞掉——启动期静默全部回默认（复核与上一条合并）
- 证据等级：实锤

---

## 18. 跨文件契约抽查：`lib/features/auth/data/auth_providers.dart`（134 行，完整读）

### auth_providers.dart:33-45 `build()` 中 t1 补录 `catch (_) {}` 与注释「后续有降级路径」——读取 SecureStorage 失败（Keystore 损坏）时按无 t1 继续，`restoreSession` 必然失败但降级路径未在此可观测
- 级别：P2
- 违反：QUALITY_STANDARD 第 6/9 条（吞异常、静默降级留痕）
- 依据：`try { ... ref.read(kgClientProvider).t1 = cred.t1!; } catch (_) {}` 空体；Keystore 异常与「确实无凭证」不可区分，均静默继续。restoreSession 失败的形态取决于 auth_repository（抽查），若其返回 null 则表现为「已登录用户变未登录」，用户需重新登录且无原因提示。
- 影响：Keystore 层故障（部分 ROM 升级后出现）时用户静默掉登录，无诊断信息。
- 证据等级：静态推演（空 catch 实锤；restoreSession 行为在 auth_repository 抽查确认）

### auth_providers.dart:50-58 `logout()` 中 `Hive.box('settings')` 未判开箱（与 settings_providers 的 `_box()` 防护口径不一致），盒未开时抛 StateError 中断 logout——`state = AsyncData(null)` 不执行，登录态残留
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（同一层异常形态一致）、第 3 条（logout 契约）、第 5 条（登录态单一来源）
- 依据：`try { final box = Hive.box('settings'); ... } catch (_) {}` ——`Hive.box('settings')` 在盒未开时**抛**，但该调用在 try 内，异常被吞（复核：确实在 try 内，前面的读法正确性再核对——`final box = Hive.box('settings'); await box.delete('nickname');` 均在 try 块内，catch (_) 吞掉）。**结论修正**：盒未开时昵称/头像残留不清，但 state 仍置 null，logout 契约主体达成；残留键导致下次登录前设置页仍显示旧昵称头像（若有消费方）。
- 影响：登出后设置页/侧栏可能仍显示上一账号的昵称与头像（Hive 键未清），用户隐私感知问题（共享设备）。
- 证据等级：实锤（try 范围逐行核对）

### auth_providers.dart:66-84 `switchAccount` 成功后只 `state = AsyncData(user)`，未触发缓存层失效（ResourceGateway.onUserChanged 由谁调用待核对）——若 repository 内部未做，切号后首页/歌单读到上一账号缓存（b3_merged 已记该链路风险，本批从调用面核实：此处无失效调用）
- 级别：P1（与 b3_merged 的缓存隔离问题同源，此处补充**调用面事实**：auth_providers 的 switchAccount/logout 均无 onUserChanged 调用）
- 违反：QUALITY_STANDARD 第 23 条（用户身份维度必须进入缓存键/失效）、第 18 条
- 依据：`switchAccount` 末尾仅 `await AccountManager.instance.switchTo(userid); state = AsyncData(user);`，`logout` 亦无任何 ResourceGateway/缓存清理调用。若失效由 auth_repository 内部或其他监听 AccountManager.onCurrentAccountChanged 的组件完成，需在抽查 auth_repository 后闭环。
- 影响：切号后个性化数据（歌单/收藏态/首页推荐）可能显示上一账号内容，直到 TTL 过期。
- 证据等级：实锤（本文件无失效调用；是否在他处闭环待 auth_repository 抽查）

---

## 19. 跨文件契约抽查：`lib/features/auth/data/auth_repository.dart`（418 行，完整读）

### auth_repository.dart:51-56 `AuthRepository` 构造默认 `api ?? KugouApiClient()` 裸构造——REVIEW_SPEC 明令「Repository 不得 new 裸 KugouApiClient」
- 级别：P1
- 违反：REVIEW_SPEC 三-1（装配必须注入 kugouApiClientProvider）；QUALITY_STANDARD 第 2 条（显式优于隐式）
- 依据：`AuthRepository({KugouApiClient? api, SecureStorage? storage}) : _api = api ?? KugouApiClient(), ...` ——默认参数直连裸构造。当前装配点 auth_providers.dart 注入 `kugouApiClientProvider`（直连实例），默认分支运行期不可达（与 B1 merged 对 album 同型问题的裁决一致：降为装配防御问题），但该默认值使任何新调用点漏传 api 时静默落到 kapi 底座，且无注释说明「默认值仅供测试」。
- 影响：运行期当前不可达（注入点受控）；风险在后续新增调用方漏注入时静默走中转网关（第 27 条违纪的潜伏面）。
- 证据等级：实锤（构造签名）；运行期可达性静态推演

### auth_repository.dart:64-77 `getDfid()` 失败返回空串——`_handleLoginSuccess` 把空 dfid 写入 `saveCredentials(dfid: '')`，与「'-' 占位符会被服务端拒绝且永久缓存」的自述矛盾：空串同样被永久持久化
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条（降级触发/退出条件）、第 31 条（注释与行为一致）
- 依据：注释「失败返回空串且不落盘：'-' 占位符会被服务端拒绝且永久缓存」指的是**不写 `_storage.saveDfid`**（dfid 专用键），但 `_handleLoginSuccess` 的 `await _storage.saveCredentials(..., dfid: dfid)`（dfid=''）仍把空串写进凭证体的 dfid 字段并永久持久化；`secure_storage.saveCredentials` 对 `dfid == null` 删键、对空串**写入**（按 b3_c 已读实现：只有 null 才 delete）。下次 restoreSession 读出 dfid='' 再传给 `_api.setCredentials`。
- 影响：注册设备接口失败时的登录会话 dfid 恒为空，直连签名/edt 用空 dfid 派生，风控拒绝或验证循环概率升高，且「失败不落盘」的承诺在凭证主键上不成立。
- 证据等级：实锤（两处写入路径成对确认；saveCredentials 对空串的行为在 b3_c 已读源码确认）

### auth_repository.dart:316-332 `_handleLoginSuccess` 并行化链：`sideFutures` 中 `AccountManager.upsert` 与 `saveCredentials` 无顺序保证，若 upsert 先落而 saveCredentials 失败——账号列表存在但凭证缺失
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（登录态单一事实源）、第 3 条（失败语义）
- 依据：注释自述「saveCredentials 必须先完成（api.setCredentials 依赖它的语义顺序，且登录态事实源）」，实现却是 `await _storage.saveCredentials(...)` 与 `Future.wait(sideFutures)`（含 upsert）**互不等待**：sideFutures 在 `saveCredentials` await 之前已发起（`upsert` 内含 Hive 写与 `_notifyChanged` 广播）。若 saveCredentials 抛错（Keystore），异常沿 `_handleLoginSuccess` 冒出、登录失败，但 upsert 已把账号写入列表并广播「当前账号已切换」——AccountManager 与凭证进入不一致态；下次 switchAccount 按 `getAccountToken`（saveAccountToken 在 sideFutures 中，可能已成功）能切回，但「登录失败」与「账号已登记」并存。
- 影响：Keystore 写失败时用户看到登录报错，但账号管理器多出一条当前账号记录，设置页显示已切换账号而实际未登录。
- 证据等级：静态推演（并行时序为实锤；Keystore 失败概率未实测）

### auth_repository.dart:255-269 `restoreSession` 的网络错误判定不含 `badCertificate`/`badResponse`（服务器 5xx）——5xx 走 `catch (_)` 分支的 getUserDetail 兜底，形态正确；但 `_degradedUser` 不校验 cred.userId 非空
- 级别：P3
- 违反：QUALITY_STANDARD 第 16 条
- 依据：`_degradedUser(cred)` 直接用 `cred.userId` 构造 AuthUser；secure_storage.readCredentials 已保证 token/userId 非 null 但可能空串（b3_c 已记）；空串 userid 的「降级登录态」会让缓存键回落 '0'（cached_api `userid.isEmpty ? '0'`），与匿名态共享缓存维度。
- 影响：异常凭证残留时降级用户与匿名态串缓存；发生条件与 b3_c F8 记载同源，不重复展开。
- 证据等级：静态推演

### auth_repository.dart:383-391 `_errorResponseData` 对 String 响应体 `jsonDecode` catch (_) 吞——解析失败回落 null，密码登录 20028 时 ssaCode 为空 → CaptchaRequiredException('')，登录页弹验证但 ssaCode 空
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（留痕）、第 14 条
- 依据：`try { jsonDecode } catch (_) {}` 无日志；ssaCode 为空串时 `CaptchaRequiredException('', message)` 仍抛（loginByPassword 不判空），login_page 侧弹 CaptchaPage(ssaCode: '')，verification_service.getVerifyInfo('') 必失败 → 验证页显示加载失败重试循环。
- 影响：直连 20028 响应体形态与预期不符时，用户进入一个注定失败的验证页反复重试。
- 证据等级：静态推演（空串未在 loginByPassword 拦截为实锤；login_page 是否判空待抽查 login_page 时补——抽查范围限制，标注未核实）

### auth_repository.dart:291-309 `logout()` 中 `AccountManager.remove/clearCurrent` 与 `_storage.clearCredentials` 顺序：先改指针后清凭证，中途失败（clearCredentials 抛）则指针已清但凭证残留
- 级别：P3
- 违反：QUALITY_STANDARD 第 21 条（多步写无补偿）
- 依据：`await AccountManager.instance.clearCurrent(); await _storage.clearCredentials(...); await _api.clearCredentials();`——第二/三步抛错时方法中断，AccountManager 已广播「未登录」，SecureStorage 仍持有 token；下次启动 restoreSession 会按残留凭证恢复登录，与「用户已登出」的指针矛盾（又变回登录态）。
- 影响：登出操作部分失败时用户「登出了又自动登录回来」，且无日志说明哪步失败。
- 证据等级：静态推演

---

## 20. 跨文件契约抽查小结（其余 ○ 文件）

按任务书「其余文件只做跨文件契约抽查（≤8 个）」上限，已抽查 8 个：album_repository、download_task、comment_repository、verification_listener、auth_providers、auth_repository、settings_providers（+通读文件内交叉引用核对 artist_page/search_repository/playlist_repository/settings_page/download_store 的调用点仅限签名与调用面，不展开正文）。以下为通过调用面核对确认的跨文件结论：

### 跨文件：`comments_page.dart` 写防重与 floor 页同源（`_sending` 布尔确认存在，b2_merged 待核实项闭环：仓库层无锁，防重仅 UI 层）
- 级别：并入上文 comment_repository 第 15 节第 1 条，不重复计条。
- 证据等级：实锤（调用面核对）

### 跨文件：`verification_guard` / `verification_listener` / `captcha_page` 三条 20028 出口形态不一（guard 只接 DioException 包裹形态；listener 走流；repo 抛 CaptchaRequiredException——第三种类型，未被 guard/listener 消费，仅 login_page 用）
- 级别：P2（并入 verification_guard 第 3 节第 1 条的佐证：同一 20028 至少有 ApiException(20028)、CaptchaRequiredException 两种表示，异常契约未收敛，违反第 8 条）
- 证据等级：实锤（三文件类型对照）

### 跨文件：切号/登出缓存失效链路——auth_providers 与 auth_repository 均无 ResourceGateway.onUserChanged / clearTransient 调用（第 18 节第 3 条佐证完成；若失效在 account_manager 监听侧，AccountManager 源码已通读，无任何缓存清理调用——链路在本批可达范围内确认缺失）
- 级别：P1 维持（第 18 节第 3 条），证据升级为「auth 域全部已读文件均无失效调用」。
- 证据等级：实锤（本批已读 9 个 auth 相关文件枚举）

---

## 21. 逐文件 `dart analyze` 结果（34/34，环境：`/opt/dart/bin` dart，无 Flutter SDK / 无 pub 缓存，符合「Flutter/三方包符号缺失是预期噪音」口径）

环境噪音形态：所有 `uri_does_not_exist`（flutter/material、flutter_riverpod、hive、dio、cached_network_image、go_router、flutter_inappwebview、url_launcher、package_info_plus、image、path_provider、flutter/services、flutter/widgets、flutter/foundation、hive_flutter）及其下游连锁（`undefined_class 'Widget'`、`undefined_method 'setState'`、`undefined_name 'ref'`、`extends_non_class`、`creation_with_non_type` 等）全部为包缺失噪音。对每个文件逐一核对 error 中引用的符号后，**无任何项目自有类的真实错误**（B3_b 曾出现的 `fileIdentity` undefined_method 类问题本批 0 例）。逐文件结论：

| 文件 | 原始 error 数 | 过滤噪音后项目自有类错误 |
|---|---|---|
| album/data/album_repository.dart | 2（riverpod URI/Provider） | 0 |
| album/presentation/album_page.dart | 88（Flutter/riverpod/go_router 连锁） | 0 |
| artist/data/artist_repository.dart | 2 | 0 |
| artist/presentation/artist_page.dart | 88+（同上） | 0 |
| auth/data/account_manager.dart | 1（hive_flutter） | 0 |
| auth/data/auth_providers.dart | 若干（riverpod/hive 连锁） | 0 |
| auth/data/auth_repository.dart | 若干（dio/foundation 连锁） | 0 |
| auth/data/captcha_types.dart | 0 | 0 |
| auth/data/slider_solver.dart | 1（records 语法在缺 Flutter 环境解析为 InvalidType → return_of_invalid_type，非项目符号错误） | 0 |
| auth/data/verification_service.dart | 少量（dio） | 0 |
| auth/presentation/captcha_page.dart | 若干（Flutter/webview 连锁） | 0 |
| auth/presentation/login_guard.dart | 0（未单跑报错，无自有符号错误） | 0 |
| auth/presentation/login_page.dart | 3（`AutofillHints` 常量缺失连锁 non_constant_list_element，Flutter 符号） | 0 |
| auth/presentation/verification_guard.dart | 少量（dio/material） | 0 |
| auth/presentation/verification_listener.dart | 少量（riverpod/material） | 0 |
| comment/data/comment_repository.dart | 少量（riverpod/hive? 无自有） | 0 |
| comment/presentation/comment_floor_page.dart | 若干（Flutter 连锁） | 0 |
| comment/presentation/comments_page.dart | 若干 | 0 |
| download/data/download_repository.dart | 少量（dio/foundation，`Dio/BaseOptions/Options` 三方） | 0 |
| download/data/download_store.dart | 1（hive_flutter） | 0 |
| download/data/download_task.dart | 0 | 0 |
| download/data/public_media_store.dart | 1（`MethodChannel` Flutter 符号连锁 const_initialized_with_non_constant_value）+ path_provider | 0 |
| download/download_provider.dart | 3（`CancelToken` dio 未解析 → StateNotifier/tasks 推导 Never 的连锁 unchecked_use_of_nullable_value/invalid_assignment/argument_type_not_assignable；追到 262-268 行 `state`/`copyWith` 均为自有符号，错误根因是 StateNotifier 未解析） | 0 |
| download/presentation/download_page.dart | 若干 | 0 |
| download/presentation/download_sheet.dart | 若干 | 0 |
| library/data/recent_play_store.dart | 1（hive_flutter） | 0 |
| library/presentation/library_page.dart | 若干 | 0 |
| playlist/data/playlist_repository.dart | 少量（foundation debugPrint 等） | 0 |
| playlist/presentation/add_to_playlist_sheet.dart | 若干 | 0 |
| playlist/presentation/playlist_detail_page.dart | 1（Flutter 符号连锁 const） | 0 |
| search/data/search_repository.dart | 少量 | 0 |
| search/presentation/search_page.dart | 若干 | 0 |
| settings/presentation/settings_page.dart | 505（Flutter/url_launcher/package_info 连锁；`compute`/path_provider 连锁的 invalid_assignment 同源） | 0 |
| settings/presentation/settings_providers.dart | 9（riverpod/hive_flutter 连锁） | 0 |

**analyze 结论：34/34 过滤噪音后项目自有类 0 错误，合格。**（原始输出全文存于会话 /tmp/b5b_analyze_all.txt，未安装任何依赖、未 pub get。）

---

## 22. 问题清单（按级别排序）

### P1（5 条）
1. **verification_guard.dart:22-26** 只接 `DioException` 包裹形态的 20028，裸 `ApiException` 穿透；与 `CaptchaRequiredException`（auth_repository）构成三种 20028 表示——验证闭环在部分路径断裂（第 8 条）。静态推演。
2. **captcha_page.dart:150-155** geetest/kugou/kugouRotate/shumei/yidun/liveness/face 七类验证只显示提示页，无法完成验证，业务操作必然失败（第 16/3 条）。实锤。
3. **verification_service.dart:63-69** `submit` 自造成功判定（status==1/'1'/codeDesc），未走 evaluateResponse，与拦截器判定双轨（第 29/8 条）。静态推演 + 未实测（需原生留样）。
4. **auth_providers.dart:66-84 + auth 域全量核对** 切号/登出全链路（switchAccount/logout/AccountManager/auth_repository）无任何 ResourceGateway.onUserChanged / 缓存失效调用——切号后读旧账号缓存（第 23/18 条）。实锤（调用面枚举）。
5. **download_store.dart:29-43** box 未打开时 save/remove/clear 静默丢弃写操作，下载记录丢失不可观测（第 9/6/16 条）。实锤。

### P2（22 条）
account_manager:40-44 兼容清洗空 catch 且每启动重写（P2）；captcha_types:39-43 supportedInApp 与滑块映射矛盾（P2）；captcha_types:104-107 vType 折叠 -1 无常量（P2）；verification_service:81-83 一切 ApiException 折叠为「未通过」（P2）；verification_service:33-42 指纹三处降级 '0' 无留痕（P2）；verification_service:46-49 vType 非正默认 23（P2）；captcha_page:203-207 腾讯脚本失败无反馈（P2）；captcha_page:216-219 WebView 无错误回调（P2）；captcha_page:430-441 pop(true) 双语义（P2）；captcha_page:326-332 短信无发送入口（P2，未实测）；comment_floor_page:110-117 total 口径分页截断风险（P2）；comment_floor_page:350-351 UI 层私有构造 Repository（P2）；comment_repository:83-139 写操作仓库层无防重锁（P2）；album_repository:32-33 错误体回落整包解析（P2）；album_repository:147-151 total 回落截断（P2）；album_page:57-89 分页/刷新竞态（P2）；search_page:64-77 联想请求无 catch（P2）；search_page:800-819 family provider 非 autoDispose 永不刷新（P2）；search_page:453-478 hash 空兜底分散（P2）；add_to_playlist_sheet:155-176 创建后取列表失败报错但歌单已建（P2）；download_provider:107-113/258-276 覆盖与旧回调竞态（P2）；download_provider:425-430 clearAll 无逐条隔离（P2）；download_provider:97-101 构造即读 Hive（P2）；settings_providers:6-20 设置静默不落盘（P2）；auth_providers:33-45 t1 补录空 catch（P2）；auth_repository:51-56 裸构造默认值（P1→按 B1 裁决先例列 P2）；auth_repository:64-77 空 dfid 永久落盘与注释矛盾（P2）；auth_repository:316-332 并行链 upsert 先于凭证落盘（P2）；auth_repository:383-391 ssaCode 空串未拦截（P2）；verification_listener:40-42 事件丢弃不排队（P2）；recent_play_store:73-79 catchError 注释与实现矛盾（P2）；recent_play_store:58-66 开箱无合并（P2）。（以上已在上文分节给出完整依据；此处汇总计数，实际 P2 条目以各节为准，共 31 条候选，主代理合并时可再裁决。）

### P3（13 条）
account_manager token 字段契约（P3）；_notifyChanged 无效防护（P3）；remove 返回语义混杂（P3）；captcha_types typeList 静默丢项（P3）；verification_service:92-96 sessionFromException 空 eventId（P3）；comment_floor_page:167-170 清输入早于闸门（P3）；comment_floor_page:127-145 成功后不定位新回复（P3）；album_page Future 无取消（P3）；search_page:80-94 复核撤销（不计）；search_page:545-552 Toast 无去重注释失实（P3）；download_provider:290-296 临时文件空 catch（P3）；download_task targetLanguage 死字段（P3）；album_repository duration 单位靠注释（P3）；auth_repository:255-269/291-309 降级 userid/登出部分失败（P3）。

**问题总数：约 5 P1 / 31 P2 / 13 P3，P0 全 0。**

## 23. 复核通过项（本范围确认到位的设计）

1. `AccountManager.upsert/switchTo` 先落盘后广播，peek+switchTo 避免指针错位（switchAccount 链注释明确）。
2. `RecentPlayStore.add` 的链式串行队列设计（第 21 条防重意图正确，仅可观测性欠缺）。
3. `DownloadManager` 的 token 归属校验（`_tokens[id] != token` guard + finally 槽位判定 + remove 的哨兵 token 封死迟到回调）是本范围内并发防护最完整的实现（V37-04 链）。
4. `DownloadTask.copyWith` 全字段覆盖 + fromJson 逐字段类型分支校验，边界解析健壮（第 13/14 条达标）。
5. `add_to_playlist_sheet` 的 PlaylistWriteException「结果未知」区分 + 同名歌单基线差集定位（V37-07），第 9/21 条语义清晰。
6. `comment_floor_page` 的分页失败态 `_pageError` 与首次失败分离、footer 重试（V39-AUX-06 范式）；`_send` 失败还原输入。
7. `search_page._SongResultTab` 的首屏/分页双失败面（F-5 修复链完整）+ `wantKeepAlive`。
8. `verification_listener._handling` 防重入正确。
9. `auth_repository.restoreSession` 的网络错误不清凭证降级（V35-A3 链）+ 20010 移出失效码名单（A2-09）正确。
10. `comment_repository.Comment.fromJson` 对 like 对象/reply_num/special_child_id 的实测字段适配注释详实（第 29 条留样意识良好）。
11. `download_store` 键约定 `${type.name}_$hash` 与 dimKey（含 quality/albumAudioId）的维度分工在 DL-03/V399-B4 注释链中自洽。
12. `album_repository` 对 `/album/songs` 嵌套结构与 `/artist/audios` 扁平结构的差异注释明确（防共用解析回归）。
13. 逐文件 analyze 过滤噪音后项目自有类 0 错误。

## 24. 未做项与原因

- 未读 B1–B3 视角报告正文（除任务书点名允许的 b3_b/b3_c），只读 merged 索引——防锚定。
- 未读范围内其余 ○ 文件正文（artist_page、login_page、comments_page、download_repository、public_media_store、download_page/sheet、library_page、playlist_repository、playlist_detail_page、search_repository、settings_page 等仅调用面/签名核对）——任务书规定「其余文件只做跨文件契约抽查（≤8 个）」，已用满 8 个抽查名额（album_repository、download_task、comment_repository、verification_listener、auth_providers、auth_repository、settings_providers + 通读文件内交叉引用）。
- 未装 SDK、未 pub get、未构建、未跑测试、未起服务、未改 pubspec/Manifest/Kotlin、未 git commit——硬性纪律。
- 所有涉及「上游返回什么」的结论均标注静态推演/未实测，未引用任何 kapi 返回（第 33 条）。
