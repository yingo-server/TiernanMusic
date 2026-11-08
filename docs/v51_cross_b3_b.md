# v5.1 交叉审查 B3 · 视角 B（鲁棒与代码质量）

- 范围：`lib/core/cache/**`、`lib/core/resource/**`、`lib/core/prefetch/**`、`lib/core/storage/**`（9 个 .dart 文件；初读 1444 行，最终快照 1464 行）。
- 判据：`docs/QUALITY_STANDARD.md` 32 条（任务书重点第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条），冲突时以 QUALITY_STANDARD 为准。
- 工作方式：逐文件 `file_read` 完整读、读完即落盘；只读源码，不改代码；末尾问题清单 + 复核通过项 + 逐文件 `dart analyze`。
- 特别核对：`ResourceCache.json` 的 `_inFlight` 键维度、stale 副本是否污染箱内原值、`cacheUrlFile` 失败路径半截文件、`PrefetchEngine.dispose` 后回调门禁。
- **基线快照说明**：审查期间本批主代理并发修改了 `resource_gateway.dart`（74→91 行）、`cached_api.dart`（84→81 行）、`resource_cache.dart`（331→337 行）。本报告的这三个文件章节已按**最终磁盘状态重新完整阅读并重写**，行号、结论与 `dart analyze` 结果均以最终快照为准；初读版本（1444 行）的部分现象在正文中标注为「初读时」，便于主代理区分。最终 9 文件 SHA-256 与逐文件 `dart analyze` 全文均贴在文末。

---

## 1. `lib/core/cache/cache_keys.dart`（48 行，完整读）

### cache_keys.dart:31-41 缓存键的各字段未转义分隔符，不同请求可生成同一个键
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`final qs = sorted.map((k) => '$k=${q[k]}').join('&');`、`return '${scope.name}:$ns:u=$userid:$p:$qs:v$schemaVer$tail';` 与 `final tail = ... ':$extra'`，分隔符 `:`、`=`、`&` 均未转义。例如 `query={'a':'1&b=2'}` 与 `query={'a':'1','b':'2'}` 得到完全相同的 `qs` 段；`path`、用户 id、`extra` 中的 `:` 亦可与键的结构分隔符混淆。同时 `q[k]` 对 `Iterable` 用 `v.join(',')`、其余用 `'$v'`，`{'a':['1','2']}` 与 `{'a':'1,2'}` 也生成同一键。文件顶部注释自称「生成稳定键」「缓存键唯一事实源」，但键并非单射。
- 影响：不同请求（例如搜索词本身含 `&` 或与另一参数组合相同）命中同一份箱内值，界面展示的是另一次请求的结果，属于串数据；全程无异常、无日志，用户只能看到内容与请求不符。
- 证据等级：静态推演（键生成分支在本文件内逐行确认；是否有真实调用方传入含分隔符的值在后续文件核对）

### cache_keys.dart:47 `fileIdentity` 注释声明的「bytes<=0 视为身份不可判定」在本文件无对应行为
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，注释与行为一致）
- 依据：注释 `/// 文件缓存身份 = (URL, 声明字节数)。bytes<=0 视为身份不可判定。` 之后的函数体只有 `=> '$url|$declaredBytes';`，对 `declaredBytes <= 0` 没有任何分支、断言或返回差异；`|` 分隔符同样未转义，URL 内含 `|` 时 `(url,bytes)` 身份可与另一对 `(url,bytes)` 撞车。注释描述的语义只能由调用方额外实现，本文件本身不体现。
- 影响：后续维护者按注释假设 `bytes<=0` 已被挡掉而直接使用该身份，会把「身份不可判定」的文件当成可复用缓存，回放出不完整/错版音频；注释误导本身不直接产生崩溃。
- 证据等级：静态推演（后续 `resource_cache.dart:244-247` 确实在调用侧拒绝 `declaredBytes<=0`，但 `cacheUrlFile` 不经 `fileIdentity` 而自行拼 `url|bytes`；该函数本身仍与注释不符）

---

## 2. `lib/core/cache/cache_manager.dart`（181 行，完整读）

### cache_manager.dart:19-21 / 145-147 两个 `init()` 的 `openBox` 无并发合并、无失败处理
- 级别：P1
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明并保护）、第 18 条（异步结果校验世代）、第 6 条（禁止吞掉异常/失败可观测）
- 依据：`Future<void> init() async { _box ??= await Hive.openBox<String>(boxName); }`（`LyricPersistentCache` 与 `LyricTranslationCache` 各一份，后者为 `Hive.openBox<String>('lyric_translations')`），两个类的 `init()` 都是「判空 → await 开箱」（与 `resource_cache.dart` 的第三套开箱路径并列），未缓存 in-flight `Future`、未使用 `Hive.isBoxOpen`、未加互斥；`getWithStale/set/clear/get` 每个入口都先 `await init()`。同一时刻（例如启动期歌词预取与歌词翻译流同时到达）两个调用都可在 `_box == null` 时各自发起 `Hive.openBox`；开箱若因盒被其它类型打开、盒文件损坏、`Hive.close()` 后重开而抛错，`_box` 保持 `null`，异常直接冒泡且此处无日志，后续所有读写反复重试开箱。对比本范围 `ResourceCache` 里另有一套独立的开箱路径，开箱事实来源不唯一（第 5 条）。
- 影响：开箱竞态或开箱失败时歌词/翻译缓存读写整体抛异常，歌词页与翻译功能显示失败；盒损坏时不会自愈，重启前该缓存持续不可用，且线上日志无本层记录可查。
- 证据等级：静态推演（并发时序与异常传播由本文件控制流确认；Hive 内部对同名 `openBox` 是否去重不依赖，代码自身无任何保护）

### cache_manager.dart:35-49 缓存体解析的 `catch (_)` 为空体式降级，删除坏数据不留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 7 条（捕获必须精确到可处理的类型）、第 11 条（降级触发/退出条件）
- 依据：`try { decoded = jsonDecode(raw); } catch (_) { // 缓存体损坏等同未命中 ...; await _box!.delete(...); return (null, null); }`。`catch (_)` 捕获一切对象；块内只有 `delete` 和 `return`，无日志、无计数、无返回值区分「未命中」与「体损坏」，注释自称「降级可观测，第 9/16 条」（文件头 6-7 行）但代码没有任何可观测手段。注释所述「缓存体损坏等同未命中」只是本层约定，调用方拿到的 `(null,null)` 与真正无缓存完全相同。另 `await _box!.delete(...)` 本身抛错时会从 catch 块向外冒出与「未命中」不同的异常形态（第 8 条同一层异常形态不一致）。
- 影响：盒文件被写坏时缓存被静默清空，用户只看到歌词重新走网络（网络失败即歌词缺失），排查时无日志可判断是缓存损坏还是真的未命中；若删除失败则退化为未捕获异常。
- 证据等级：实锤（本文件内 `catch` 块与返回值形态可直接确认）

### cache_manager.dart:42-49 JSON 形态只验最外层 `is Map`，畸形体不清理且可能抛类型错误
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）
- 依据：`if (decoded is! Map) return (null, null);` 之后 `final storedAt = decoded['storedAt'];`、`final body = decoded['body'];`、`final bodyMap = body is Map ? Map<String, dynamic>.from(body) : null;`。只检查顶层是 `Map`，未校验 `storedAt` 取值域、`body` 的键/值形态；对「顶层 Map 但结构错」（如缺少 `body`、`body` 是 `List`、值是任意嵌套对象）直接返回 `(null,null)` 且**不删除**该条，`getWithStale` 每次调用都会重新 `jsonDecode` 同一份坏数据。`Map<String, dynamic>.from(body)` 对非 `String` 键的 Map 以及含自定义对象的嵌套值不做逐字段验证即交给上层按业务形态使用。
- 影响：箱内一旦出现形态不符但 JSON 合法的旧值（schema 变更/被其它版本写入），该键永久不可用且无提示，歌词/翻译结果缺失；上游按 `Map<String,dynamic>` 使用畸形嵌套值时可在业务层抛未捕获类型错误。
- 证据等级：静态推演（解码与强转路径在本文件内确认；上游具体崩溃点不在本范围）

### cache_manager.dart:81-84 `MemoryCache.get<T>` 用 `as T?` 裸强转，键碰撞时抛 TypeError
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 10 条（编程错误不得埋入业务降级）、第 8 条（异常契约稳定）
- 依据：`T? get<T>(String key) { ... return e.value as T?; }`，`_Entry.value` 声明为 `Object?`，`set<T>` 无任何类型登记或按类型分键。同一全局单例 `MemoryCache.instance` 上，若两个调用方对同一 key 分别写入/读取不同类型，`as T?` 直接抛 `TypeError`（而非返回 null 或明确的领域异常）；这是把缓存命中路径变成不可预测的异常路径。
- 影响：不同业务共用同一内存键时界面直接崩溃/页面报错，且没有任何日志或降级值，用户表现为「偶发点开某页闪退」。
- 证据等级：静态推演（类型不安全的分支在本文件内确认；是否已有真实同键异类型调用不在本范围）

### cache_manager.dart:124-131 `MemoryCache.keyOf` 绕开 `cache_keys.dart` 自行拼键，缺用户/schema/scope 维度
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 5 条（状态单一来源）、第 31 条（注释与行为一致）
- 依据：`static String keyOf(String path, [Map<String, dynamic>? query]) { ... return '$path?${sorted.entries.map((e) => '${e.key}=${e.value}').join('&')}'; }` 只由 `path` + 原样字符串化的 query 组成，无 `userid`、无 `schemaVer`、无 `scope`、无 `ns`；与 `cache_keys.dart` 文件头「全仓**禁止**再自行拼 TTL 前缀或用户维度字符串；所有缓存读写必须经此文件生成键」直接冲突。同样未转义 `=`、`&`，`{'a':'1&b=2'}` 与 `{'a':'1','b':'2'}` 生成同一键。全局单例的 `clear()/removeWhere` 之外无按账号失效手段。
- 影响：切号/登录登出后，旧账号的 90 秒内存数据仍可被新账号命中（串数据）；上游 schema 升级或参数含分隔符时展示错误内容，用户可见为账号数据错乱或结果不随请求变化。
- 证据等级：静态推演（键维度缺失在本文件内确认；账号切换后是否调用 `MemoryCache.clear` 属于本范围外的调用方行为，未实测）

### cache_manager.dart:154-175 翻译缓存的持久化文本无校验、无转义，`int.parse` 可抛未捕获异常
- 级别：P1
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 13 条（外部数据禁止裸类型强转）、第 9 条（失败必须可观测）
- 依据：`set` 用 `translations.entries.map((e) => '${e.key}\t${e.value}').join('\n')` 原样写入，未转义译文中的 `\t`/`\n`；`get` 用 `for (final line in raw.split('\n'))`，`if (idx > 0) { map[int.parse(line.substring(0, idx))] = line.substring(idx + 1); }`。`int.parse` 无 `onError`/try-catch：箱内任一行的行号段非纯数字（盒损坏、旧格式、译文自带换行导致的错位）即抛 `FormatException`，直接冒泡出缓存读取路径；无 tab 的行被**静默跳过**（`idx > 0` 为假），既不记录也不返回部分/失败区分，返回的是一份静默缺失若干行的 `Map<int,String>`（第 16 条空集合与缺失语义混淆）。
- 影响：盒内容异常时歌词翻译页报错，或用户看到译文逐行缺失、行号错位且无任何提示；因为写入侧允许译文含换行，这种损坏可由正常内容触发而非仅外部破坏。
- 证据等级：实锤（`set` 的拼接与 `get` 的解析/抛异常点在同一文件内成对确认）

### cache_manager.dart:52-70 / 168-180 两个 Hive 盒无条目数/体积上限，且过期条目从不淘汰
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）
- 依据：`LyricPersistentCache.set` 只 `put`，`getWithStale` 对 stale 值只读不删，唯一的删除是「JSON 解析失败」那一条，`clear()` 只能整箱清空；`LyricTranslationCache.set` 同样只 `put`，`get` 无 TTL 概念（根本没有 `storedAt`），`clear()` 整箱清空。两处都没有条目数上限、体积上限、LRU/FIFO、按 `storedAt` 的过期扫描；而 `cache_keys.dart` 声明 `CacheScope.file` 为「永久（不淘汰，仅失效回退）」。对比同文件 `MemoryCache._maxEntries = 200` 有明确容量上限（复核通过项）。
- 影响：长期使用后每首听过的歌/每种目标语言都在磁盘留下永久条目且永不回收，低端机存储与开箱加载时间持续增长；`storedAt` 已过期 7 天的歌词本体仍永久占盘并每次被当作 stale 候选。
- 证据等级：实锤（本文件内所有写入/删除/淘汰路径完整枚举）

### cache_manager.dart:19-21 / 145-147 `Hive.close()` 或外部关箱后 `_box!` 断言无世代校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 20 条（生命周期对称）
- 依据：`_box` 一旦赋值便永远不再检查 `isOpen`；`init()` 的 `??=` 也不会重开一个被关闭的盒。`getWithStale/set/clear/get` 在 `await init()` 之后统一用 `_box!.get/put/clear/delete`，无任何「盒仍存活」的判断。本类自身没有 `close()`/`dispose()`，资源申请与释放不对称。
- 影响：应用生命周期中若 Hive 被统一关闭/重新初始化（热重启、测试或多引擎场景），缓存读写抛 `HiveError: Box has already been closed`，用户侧表现为歌词/翻译读取失败且不会自动恢复。
- 证据等级：静态推演（未外部调用验证；`_box` 的赋值/使用路径在本文件内确认）

### cache_manager.dart:90-97 覆写已有键也会先淘汰一条无关条目
- 级别：P3
- 违反：QUALITY_STANDARD 第 25 条（容量上限的实现应与行为一致）
- 依据：`void set<T>(...) { if (_cache.length >= _maxEntries) _evict(); _cache[key] = _Entry(...); }` 未判断 `key` 是否已存在；当容量恰好为 200 且写入的是已存在的 key 时，`_evict()` 仍按 `_cache.length - _maxEntries + 1 = 1` 删掉最旧的一条无关缓存，然后再覆盖原 key，结果长度变成 199。
- 影响：高频刷新同一热门 key 会顺带把其它仍有效的条目挤出内存缓存，多出一次不必要的网络请求；无明显错误展示，属性能/整洁度问题。
- 证据等级：实锤（分支算术在本文件内可直接确认）

---

## 3. `lib/core/cache/resource_gateway.dart`（91 行，完整读）

### resource_gateway.dart:18-25 L1 内存缓存无容量上限、无 TTL、无淘汰
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）
- 依据：`final Map<String, Object> _memory = <String, Object>{};`（`:18`）、`void memoryPut(String key, Object value) => _memory[key] = value;`（`:25`），`json()` 的 `.then(...)` 在 `:56` 对每个非 stale 响应无条件 `memoryPut(key, body)`。除 `invalidateNs`（`:68`）/ `onUserChanged`（`:76`）/ `clearTransient`（`:87`）的人工清理外，没有任何 `_maxEntries`、`expires`、LRU/FIFO 或体积限制；`memoryGet<T extends Object>`（`:20-23`）也不判断时效。与同范围 `MemoryCache._maxEntries = 200` 形成两套互不相干的内存缓存实现，注释（文件头 3-5 行）称「所有缓存读写与失效经此门面」，但本门面自身 L1 是又一套新实现（第 5 条）。
- 影响：长时间浏览（首页/歌单/详情页反复写入不同 key）内存单调增长，低端机出现卡顿甚至 OOM 被系统杀进程，用户表现为应用闪退回到桌面；清理设置页不点就永不回收。
- 证据等级：实锤（本类全部写入/删除路径在本文件内枚举完毕）

### resource_gateway.dart:47-58 L1 命中后完全绕过 L2 TTL/in-flight/失效回退，且 `staleOnError` 被忽略
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 11 条（降级必须有触发与退出条件）、第 23 条（缓存键必须覆盖全部影响结果的维度）、第 8 条（异常契约必须单一且稳定）
- 依据：`final mem = memoryGet<Map<String, dynamic>>(key); if (mem != null) return Future<Map<String, dynamic>>.value(mem);`（`:47-48`）在调用 `ResourceCache.instance.json(...)` **之前**直接返回。L1 键只由 `cacheKey(...)`（`:38-45`）生成，不含 TTL 数值、不含账号切换世代、不含失效版本号；一旦 `memoryPut`（`:56`）写入，此后该 key 的所有请求都走 `:48` 早退，L2 的 168h/90s TTL、in-flight 合并、`staleOnError` 降级、`invalidateNs` 之外的盒内失效全部不再参与。例外只有 `if (body['__stale'] != true)` 不写 L1（`:55-56`），但 L1 已存在的值没有任何过期退出条件。同时返回的是 `Future.value(mem)` 与 L2 的 `Future` 异常形态不一致：L1 命中永远 success，L2 命中可能 rethrow。
- 影响：用户主动下拉刷新、切歌、账号变更后仍拿到本次进程第一次写入的旧数据（列表不更新、收藏状态不变），需重启或清缓存才恢复；`staleOnError: false` 的严格调用方在 L1 命中时也拿不到任何失败语义。
- 证据等级：实锤（早退分支与 `json()` 全部写入/失效路径在本文件内成对确认）

### resource_gateway.dart:47-48 / 54-58 L1 与调用方共享同一个可变 `Map`，`__stale` 判定只查顶层字段
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 13 条（外部数据禁止裸类型强转）、第 5 条（状态单一来源）
- 依据：`memoryPut(key, body)` 直接把 `ResourceCache.json` 返回的 Map 引用存进 `_memory`，`memoryGet` 又原样返回；任一消费方对该 Map 做原地增删改，L1 的后续所有命中与 L2 的合并调用方立即看到被改动的对象，本类没有任何拷贝或「返回值不可变」契约。`if (body['__stale'] != true)` 假设返回值是可索引的 `Map<String,dynamic>` 且标记恒为顶层布尔，若上游返回体内本身含 `__stale` 字段（外部 JSON 边界，未做形态校验）则该响应被误判为降级数据而永不进 L1。
- 影响：一个页面加工响应（例如补本地字段）后另一页面显示错字段；上游响应含同名 `__stale` 字段时该接口每次都走网络（缓存形同失效），用户看到加载变慢。
- 证据等级：静态推演（引用共享与判定分支在本文件内确认；上游响应形态未实测）

### resource_gateway.dart:75-83 `onUserChanged()` 用 `unawaited` 触发全量清箱，异常无人接管且切号竞态无世代校验
- 级别：P1
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）、第 18 条（异步结果必须校验世代）、第 20 条（生命周期对称）
- 依据：`void onUserChanged() { _memory.clear(); unawaited(_clearUserDimensions()); }`（`:75-78`），`_clearUserDimensions()` 里 `await ResourceCache.instance.clearJson(); await ResourceCache.instance.clearLists();`（`:80-83`）。`unawaited` 的 Future 无 `.catchError`、无 try/catch、无日志：`clearJson`/`clearLists` 内部 `await box.deleteAll(keys)` 抛错（已读 `resource_cache.dart:309-330`，无 catch）时成为无人接管的异步错误。更关键的是这个清理是**无差别全清两个作用域**，并不按 `u=` 只删旧账号条目，而注释 `:73-74` 写「L2 由键内 u= 维度保证不再命中，并异步清掉**旧账号**的磁盘条目」——实现清掉的是所有账号的全部 JSON/列表。切号期间在途的 `_doFetch` 完成后的 `box.put` 会在清理结束后把旧账号数据写回（已读 `resource_cache.dart:106-112`），无世代/时间戳判定；同步方法也无法让调用方 await 清理完成就发起新账号请求。
- 影响：A→B 切号时 B 账号刚发起的请求结果可能被旧账号清理连带删除，或旧账号在途响应在清理后回灌；用户看到切号后首页空/旧数据混出，且清理失败无任何日志。
- 证据等级：静态推演（本文件 `unawaited` 与已读 `ResourceCache.clearJson/clearLists/_doFetch` 控制流成对确认）

### resource_gateway.dart:20-25 / 66-70 门面不强制 L1 键由 `cacheKey` 生成，按 ns 失效可漏清
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 3 条（契约先行）、第 5 条（状态单一来源）
- 依据：`memoryPut(String key, Object value)`（`:25`）接受任意裸字符串、无用户/scope/ns/schema 维度（对比 `json()` 内部才在 `:38` 调 `cacheKey`）；`invalidateNs` 用 `_memory.removeWhere((k, _) => k.contains(':$ns:u='))`（`:68`）依赖调用方自觉拼出含 `:$ns:u=` 的键。只要调用方传的是 `path`、`url` 或 `MemoryCache.keyOf` 产物，该前缀判断为假，失效静默落空。文件头注释「所有缓存读写与失效经此门面」与「按 ns 精确失效」都依赖未在签名/类型上强制的约定。
- 影响：写操作（收藏/删除/编辑）后按 ns 失效仍读到旧内存值，用户看到「操作后列表不变」，需要重启或手动清缓存才恢复。
- 证据等级：静态推演（本门面不校验键形态为实锤；具体调用方传何种键不在本范围）

### resource_gateway.dart:28-58 `json()` 允许传入 `CacheScope.file`，把 36500 天 TTL 写进 L2 JSON 层
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围必须明确）、第 23 条（scope 决定层级与 TTL 的维度一致性）
- 依据：`CacheScope scope = CacheScope.json`（`:35`）是公开参数且无断言/分支限制；`cacheKey(... scope: scope ...)`（`:38-45`）与 `ttl: cacheTtl(scope)`（`:52`）直接透传，`ResourceCache.instance.json(...)` 是唯一的落盘目标（注释称「L2 磁盘 JSON：统一的 168h / 90s 语义」）。若调用方传 `CacheScope.file`，键被分到 `file:` 作用域而 TTL 为 36500 天，却仍写进 JSON 盒；L1 内存层同样不区分 scope。签名承诺的 scope 语义（`cache_keys.dart:9`「决定层级与 TTL」）与门面实际「只有一层」不一致。
- 影响：一次误传 scope 会让本应短期有效的数据在磁盘与内存上近乎永久不刷新，用户长期看到过期结果；反之 list 作用域数据 90 秒后失效，造成额外请求。
- 证据等级：静态推演（参数与透传路径在本文件内确认；实际调用方是否误传不在本范围）

### resource_gateway.dart:61-64 `file()` 默认 `declaredBytes = 0` 与「bytes<=0 视为身份不可判定」的契约冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键/文件身份必须覆盖全部影响结果的维度）、第 3 条（输入取值范围）
- 依据：`Future<String?> file(String url, String kind, {int declaredBytes = 0}) => ResourceCache.instance.cacheUrlFile(url, kind, declaredBytes: declaredBytes);`（`:62-64`）。`cache_keys.dart:47-48` 的注释约定 `bytes<=0 视为身份不可判定`，而门面把 0 作为默认值并无条件向下透传，未在此处拒绝、未要求调用方显式提供、也未声明「0 = 不校验」的语义；`kind` 与 `url` 也不经 `cacheKey`/`fileIdentity` 生成而是原样交给下层。
- 影响：调用方省略 `declaredBytes`（最易用路径）时，文件身份退化为仅 URL，服务端同一 URL 返回不同长度/不同版本内容时可能复用错版文件，用户听到截断/错版音频或看到损坏封面（下层 `cacheUrlFile` 实际会拒绝 0，故本层表现为静默不缓存）。
- 证据等级：静态推演（门面透传为实锤；`cacheUrlFile:244-247` 对 0 的拒绝已读确认）

---

## 4. `lib/core/resource/resource_cache.dart`（337 行，最终快照重新完整读）

### resource_cache.dart:71-93 / 236-250 JSON 与文件两套 in-flight 的 `finally` 都无条件 `remove`、不校验持有者身份
- 级别：P1
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门必须成对且关闸时判断「我是否仍是当前持有者」）、第 18 条（异步结果必须校验世代）、第 22 条（并发假设必须写明）
- 依据：JSON 侧 `:75-76` 查 `_inFlight[fullKey]`、`:88` 写 `_inFlight[fullKey] = fut`、`:92` `finally { _inFlight.remove(fullKey); }`；文件侧 `:241-243` 查 `_fileInFlight[flightKey]`、`:245` 写、`:249` `finally { _fileInFlight.remove(flightKey); }`。两处 `remove` 前都没有 `if (identical(map[key], fut))` 之类的身份判断，注释 `:36` 与 `:39` 也只声明「Dart 单 isolate，Map 即互斥点」，未声明 `await`/`finally` 调度窗口的并发前提。`fut` 已完成但首个调用方的 `finally` 尚未执行的窗口内，新调用 `pending != null` 会 `return pending` 拿到**已经结束（可能失败）的旧 Future**；若另一路已放入新的 `fut`，无条件 `remove` 还会把后来者的 in-flight 提前清掉，使真正并发同时发出两个 fetch/下载。最终快照已把 `_inFlight` 的读写删三处统一为 `fullKey`（初读版本曾用调用方 `key`、中间版本一度读写键不一致），故本节按当前状态记录剩余的第 19 条问题。
- 影响：切歌/切页后一次新请求可能直接抛上一次请求的错误或复用上一世代的旧数据；并发合并偶发失效导致同一资源重复请求/重复下载。
- 证据等级：静态推演（Dart 事件循环下 `await` + `finally` 的调度窗口为语言语义；代码无身份判断为实锤）

### resource_cache.dart:75-76 / 116 / 132 合并后的调用方共享同一个可变 `Map` 实例，异常对象也原样共享
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 8 条（异常契约必须单一且稳定）、第 18 条（世代校验）
- 依据：`final _inFlight = <String, Future<Map<String, dynamic>>>{};`（`:37`）与 `if (pending != null) return pending;`（`:76`）。`_doFetch` 的 `return data;`（`:116`）与回退分支 `return Map<String, dynamic>.from(staleBody)..['__stale'] = true;`（`:132`）都只产生**一个对象**，所有等待者拿到同一引用；`Future` 完成时携带的异常对象与栈也是同一个。代码没有对合并调用方说明「返回值共享、不可变更」的契约，也没有按等待者复制；`ResourceGateway.json:56` 又把同一个 Map 直接存进 L1。
- 影响：两个页面合并到同一次请求时，一处对结果做加工会让另一处（及 L1 后续命中）显示错字段；失败时后加入的调用方拿到别的请求的异常与日志栈，线上无法定位本次失败。
- 证据等级：静态推演（返回值共享为 Dart Future 语义 + 本文件代码事实）

### resource_cache.dart:101-136 `catch (e)` 捕获一切异常后进入 stale 降级，违反「编程错误绝不进入业务降级」，且 `staleOnError` 由首个调用方决定
- 级别：P1
- 违反：QUALITY_STANDARD 第 10 条（编程错误绝不进入业务降级）、第 7 条（捕获必须精确到可处理的类型）、第 11 条（降级必须有明确的触发条件与退出条件）、第 8 条（回退路径与主路径异常形态一致）
- 依据：`try { final data = await fetch(); ... } catch (e) { if (staleOnError && staleBody != null) { ... return Map<String, dynamic>.from(staleBody)..['__stale'] = true; } rethrow; }`。`catch (e)` 无 `on` 类型限定：`fetch()` 内部出现的 `TypeError`、越界、`NoSuchMethodError`、乃至调用方主动取消（`DioException` cancel）全部被当作「网络失败」并返回旧值，实现缺陷被静默掩盖。`staleBody` 与 `staleOnError` 是 `_doFetch` 创建时从**首个调用方**捕获的，后续合并进来的调用方即使传 `staleOnError: false`（要求严格失败），也拿不到 `rethrow`；反之首个为 false 时第二个为 true 的调用方会直接收到异常。类注释第 18-21 行写「fetch 失败 → 有旧值返回旧值副本；无旧值 → 原样 rethrow」并自称「禁止静默吞异常」，实际成功/失败都返回 `Map<String,dynamic>`，仅靠一个顶层 `__stale` 标记区分，异常形态在两路径间不一致。
- 影响：`fetch` 实现有 bug 时用户长期看到旧数据而缺陷永不暴露；登录失效/被取消等本应提示的错误被换成旧列表；不同页面对同一 key 的错误处理行为随机取决于谁是首个调用方。
- 证据等级：实锤（catch 范围、参数捕获点、返回形态在本文件内确认）

### resource_cache.dart:122-132 `unawaited(ErrorLogger.instance.log(...))` 的失败无人处理，回退留痕可能落空
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 6 条（禁止吞掉异常）
- 依据：`unawaited(ErrorLogger.instance.log('stale cache used for $fullKey', StackTrace.current, source: 'resource_cache', context: 'fetch failed: $e'));` 无 `.catchError`、无 try/catch。注释自称「回退本身即带用户可见留痕：经 ErrorLogger 落盘」，但 `debugPrint` 只在 Flutter debug 通道，ErrorLogger 的日志 Future 若失败则成为无人接管的异步错误，回退实际上既无用户反馈也无持久化日志。`ErrorLogger` 实现不在本范围内，无法核对其内部是否自吞异常（此处按「本文件不保证可观测」记）。
- 影响：网络失败后界面静默展示过期数据，用户无从得知，日志侧也可能查不到；`unawaited` 的异常还可能以未处理异步错误的形式扰动机智日志。
- 证据等级：静态推演（本文件无错误处理器为实锤；ErrorLogger 内部行为未实测、不在本范围）

### resource_cache.dart:140-156 形态错误的缓存体只读不删、删除 Future 未 await 且无日志
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）、第 9 条（失败必须可观测）、第 6 条
- 依据：`try { decoded = jsonDecode(raw); } catch (_) { box.delete(key); return null; }` 中 `box.delete(key)` 返回 `Future<void>` 但**未 await 也未 unawaited**，在同步函数 `_readStored` 里被直接丢弃；删除失败会成为无人处理的异步错误。其后 `if (decoded is! Map) return null;`、`if (storedAt is! int || body is! Map) return null;` 对「JSON 合法但结构不符」的坏值**不删除**，每次调用都重新解码一次坏数据。整段无 `debugPrint`/ErrorLogger，`catch (_)` 捕获一切对象。另 `final storedAt = decoded['storedAt'];` 未校验取值范围：`storedAt` 为极大值（设备时钟跳变写入、盒被其它版本写入）时 `now < storedAt + ttl.inMilliseconds` 长期为真，该键永久「新鲜」不再刷新；`Map<String, dynamic>.from(body)` 未逐字段验证嵌套键/值形态。
- 影响：一次异常写入使该缓存键永久不可用（每次请求都白解码 + 走网络），或设备改过时间后用户长期看到旧数据且永不刷新；删除失败的异常无人可见。
- 证据等级：实锤（解析/删除/返回分支全部在本文件内）。补充：`catch (_)` 捕获一切对象且整段无 `debugPrint`/ErrorLogger（同文件其它失败分支均有留痕），而 `cache_manager.dart:35-41` 的同类损坏处理用 `await _box!.delete(...)`，两层的异常形态不一致（第 8 条）。

### resource_cache.dart:244-291 `cacheUrlFile` 的早退分支不清 `.part`，失败清理不对称
- 级别：P1
- 违反：QUALITY_STANDARD 第 20 条（生命周期必须双向对称，申请的资源必须有对称释放点）、第 14 条（数据边界校验）、第 11 条（降级退出条件）
- 依据：清理 `.part` 只写在方法末尾的 `catch (e) { ... try { ... part.delete() } catch (_) {} ... }` 里。而以下路径从 `try` **中途 `return null`**，完全跳过清理：`if (cl > 0 && cl != declaredBytes) { ...; return null; }`（Content-Length 不符）以及 `if (await target.length() == declaredBytes) return target.path;` 之外的 `url.isEmpty` / `declaredBytes <= 0` 早退。若上一次中断留下同名 `.part`，本次因 HEAD 的 Content-Length 不符而「直接放弃」，该半截文件会永久留在磁盘；更关键的是 `if (await target.exists()) { if (length != declaredBytes) await target.delete(); }` 之后若 HEAD 不符而返回，半截 `.part` 与已删除的 target 同时存在。`dio.download(url, part.path)` 之前也没有先删除既有 `.part`，Dio 以同路径写入时若采用追加/既存流语义（未实测）会与残留字节混合。清理用的路径在 catch 里**重新计算** `_dirOf(kind)`（可能再次抛错）与 `_hashName(url, bytes: declaredBytes)`，且内层 `catch (_) {}` 是空体，删除失败被完全吞掉（第 6 条）。
- 影响：半截 `.part` 文件长期占盘且永久文件缓存无清理入口；后续同 URL 请求可能读到被污染/残留长度的文件，用户听到截断音频或看到损坏封面，且日志无清理失败记录。
- 证据等级：静态推演（早退分支与唯一清理点在本文件内成对确认；Dio 对既有 `.part` 的写入语义未实测）

### resource_cache.dart:236-250 / 253-330 文件下载仍无并发数上限、Dio 不可取消；`_looksLikePreview` 用 URL 子串黑名单判身份
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（并发请求数必须有上限）、第 20 条（句柄必须对称释放）、第 18 条（异步结果校验世代）、第 14 条（所有数据边界必须校验）、第 11 条（降级触发条件）
- 依据：`_fileInFlight` 只按 `flightKey = '$kind|$url|$declaredBytes'` 合并**同一资源**的并发（`:240-248`），对不同 URL 的并发下载没有任何总量上限、队列或信号量；`final dio = Dio(BaseOptions(... receiveTimeout: const Duration(minutes: 10)));`（`:270-273`）每次新建、无 `CancelToken`、无 `dio.close()`，`await dio.download(url, part.path)` 期间无取消或世代判断，页面销毁后下载仍可跑满 10 分钟。`_looksLikePreview(url)`（`:252-254`）只匹配 `/p_0_`、`/hash_offset/`、`IsFreePart=1` 三个子串，`allowPreview` 默认 false 且由调用方可无条件置 true（`cacheUrlFile` 的公开参数 `:218`）；URL 是外部数据，黑名单之外的试听片段仍会以「声明字节数」被当作完整文件永久入库。`_cacheUrlFileInner` 的 HEAD 失败降级（`:277-283`）虽有明确留痕，但把 `cl` 置 0 后完全依赖下载后长度，HEAD 403/405 与真实不可写目录之间无区分（第 11 条恢复条件仍缺）。
- 影响：快速切歌触发多个不同 URL 下载时带宽被预取占满、正在播放的音频卡顿；退出页面后后台下载长驻；未命中的试听片段被永久缓存后，用户下次播放误用 30 秒片段当作全曲。
- 证据等级：静态推演（并发上限/取消缺失与黑名单分支在本文件内实锤；具体片段 URL 形态不在本范围、未实测）

### resource_cache.dart:175-193 / 264-280 文件身份只校验长度，未校验内容/签名；FNV-32 哈希无碰撞处理
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`static String _hashName(String url, {int bytes = 0})` 用 32 位 FNV-1a 混合 `'$url|$bytes'` 再加 `url.length`，文件名不含任何内容摘要；校验环节只有 `cl > 0 && cl != declaredBytes`、`await target.length() == declaredBytes`、`actual != declaredBytes`。注释第 170-173 / 230-237 行宣称「四道校验」「绝不互相覆盖/误复用」，但四道里没有一道验证内容字节；不同 URL 只要 FNV-32 碰撞且 `url.length` 与 `bytes` 相同（`suffix` 也相同）即共用一个 target。另 `cl` 为 0（chunked/无 Content-Length 头）时 `int.tryParse(...) ?? 0` 使长度预检整体跳过，仅靠下载后长度兜底。`ext = url.substring(url.indexOf('?'))` 后取 `lastIndexOf('.')` 得到 `suffix`，若 query 短且含 `/`、`?`、`=`、`&` 等字符，`suffix` 会原样进入文件名（例如 `?a=.b/c` → `.b/c`），产生带路径分隔符的目标路径，写入失败或落到非预期子目录；URL 是外部数据，此处未做任何字符白名单校验。
- 影响：CDN 返回错版/被替换但长度相同的文件会被当作正确资源永久复用；query 含特殊字符时缓存写入失败（用户看到资源反复下载）；哈希碰撞时两份不同资源互相覆盖。
- 证据等级：静态推演（校验条件与文件名构造在本文件内确认；碰撞/特殊字符未实测）

### resource_cache.dart:13-17 / 178-180 最终快照删除了 `putFile`/`file`/`filePath`，但仍引用未导入的 `fileIdentity`，且 `kFilePermanent` 仍为无引用占位常量
- 级别：P0
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 3 条（契约先行）、第 31 条（注释与行为一致）、第 8 条（异常契约稳定）
- 依据：最终快照 `_hashName` 内 `:180` 为 `final identity = fileIdentity(url, bytes);`，但文件头 `:1-10` 的 import 列表只有 `dart:convert`/`dart:async`/`dart:io`/`dio`/`flutter/foundation`/`hive`/`storage_permission`/`error_logger`，**没有 `import '../cache/cache_keys.dart'`**；`dart analyze lib/core/resource/resource_cache.dart` 明确报 `error - resource_cache.dart:181:22 - The method 'fileIdentity' isn't defined for the type 'ResourceCache' - undefined_method`（项目自有符号缺失，非三方包噪音）。`const kFilePermanent = null;`（`:13`）仍全文件无引用，注释自称「按契约保留；实际由 cacheUrlFile 的『已存在直接返回』保证」；`kJsonTtl`/`kListTtl`（`:16-17`）虽注释「TTL 唯一事实源在 cache_keys.cacheTtl；此处仅保留契约兼容的别名」，但 `cache_keys.dart:16-20` 的 `cacheTtl` 与本处两个 `Duration` 仍是两份独立常量，靠注释约束数值相等（第 5 条）。同时被删除的 `putFile`/`file`/`filePath` 是公开契约签名（初读版本 `:195-228`），类注释 `:20-29` 仍写「实际资源文件永久缓存」却未说明字节级 API 已移除。
- 影响：`resource_cache.dart` 在当前状态下**无法通过分析/编译**，`cacheUrlFile` 调用 `_hashName` 时 `fileIdentity` 解析失败，所有永久文件缓存路径（播放完成后的离线复用）整体不可用；用户表现为已缓存音频每次仍重新下载、离线不可用，且该错误不属于允许忽略的 Flutter/三方包噪音。
- 证据等级：实锤（逐文件 `dart analyze` 输出 + 最终快照 import 列表逐行确认；未执行编译/测试，按纪律不允许）

### resource_cache.dart:297-331 永久文件层没有任何清理入口，注释声称的「设置页 clear*」不存在
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 31 条（注释与行为一致）、第 32 条（死代码零容忍）
- 依据：文件头注释第 25-26 行写「永久不淘汰，淘汰交由设置页 clear*」、`cacheUrlFile` 注释写「永久缓存」，但本类提供的清理只有 `invalidateNs(String ns)`、`clearJson()`、`clearLists()`，三者都只操作 `_safeBox` 的 `json:`/`list:` 键，**没有任何删除 `<root>/cache/resource/**` 文件的方法，也没有条目数/总字节上限**；`ResourceGateway.clearTransient()` 明确注释「永久文件不动」。`const kFilePermanent = null;` 是声明为 `Null` 的占位常量，全类（含本范围其它文件，按已读文件核对）无任何引用；`cache_keys.dart:47` 的 `fileIdentity()` 同样未被本文件使用，本文件自行拼接 `'$url|$bytes'` 作为身份字符串。
- 影响：用户长期使用后音频/封面永久缓存单调增长且**无法通过设置页清除**，低端机磁盘被占满后下载与播放同时失败；占位常量与重复身份函数属残留死代码。
- 证据等级：实锤（本类全部公开方法在本文件内枚举完毕；`ResourceGateway.clearTransient` 已读确认）

### resource_cache.dart:43-55 `init()` 吞掉开箱异常且失败不记账，与 `cache_manager.dart` 存在两套开箱事实源
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 5 条（状态单一来源）、第 11 条（降级必须有触发/退出条件）
- 依据：`Future<void> init() async { if (_box != null && _box!.isOpen) return; try { _box = Hive.isBoxOpen(_boxName) ? Hive.box<String>(_boxName) : await Hive.openBox<String>(_boxName); } catch (e) { debugPrint(...); _box = null; } }`。并发调用时两个调用都可观察到 `_box == null` 且 `Hive.isBoxOpen(_boxName) == false`，各自发起 `await Hive.openBox`，没有 in-flight Future 或锁保护；`catch` 里把 `_box` 置回 `null` 后正常返回，没有失败标志或退避，于是**每个 `json()` 调用都会重新尝试开箱**，盒损坏时每次请求都多一次失败 IO。注释自称「[init] 幂等」「单个 openBox 失败只留痕不崩」，实际只有留痕、不保证幂等，也没有恢复条件（第 11 条）。与 `cache_manager.dart` 的三个 `init()`（无 isBoxOpen、无 catch、异常冒泡）形成同一 Hive 库下两套互不一致的开箱/异常契约（第 8 条）。
- 影响：盒文件损坏时应用每次请求都附带一次失败开箱（额外 IO/卡顿），缓存整体不可用且用户无感知；并发开箱在启动期可能产生开箱异常日志。
- 证据等级：静态推演（控制流在本文件内确认；Hive 是否内部去重 openBox 未实测）

### resource_cache.dart:297-319 `invalidateNs` / `clearJson` / `clearLists` 只处理 String 键且不校验失效世代
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 25 条（资源上限）、第 23 条（失效维度）
- 依据：三处都是 `box.keys.whereType<String>()...toList(); await box.deleteAll(keys);`——非 String 键（Hive 允许整数键）被静默跳过，`clearJson`/`clearLists` 也只按前缀删除各自一层；`invalidateNs` 的 needle 为 `':$ns:u='`，仅依赖调用方传入的 key 字符串恰好含该片段。更关键的是这些方法**不与 in-flight 交互**：`_inFlight` 中正在跑的 `_doFetch` 在 `await init()` 之后仍持有旧的 `box` 引用，失效完成后其 `box.put(fullKey, ...)` 会把刚被删除的键重新写回，即写后失效被在途请求回灌，且没有世代/时间戳判定（第 18 条）。失效也不覆盖 L3 永久文件层。
- 影响：用户执行收藏/删除后立刻刷新仍看到旧数据（在途请求把旧响应写回已清掉的缓存），需再等一次刷新才恢复；设置页「清除缓存」后残留非 String 键的旧值。
- 证据等级：静态推演（失效与 `_doFetch` 写入路径在本文件内成对确认）

### resource_cache.dart:13-14 / 66-73 `kJsonTtl`/`kListTtl` 与 `cache_keys.dart:16-20` 的 TTL 表重复且无单一来源
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 31 条（注释与行为一致）
- 依据：本文件 `const kJsonTtl = Duration(hours: 168); const kListTtl = Duration(seconds: 90);`，`cache_keys.dart` 的 `cacheTtl` 又各自声明 `Duration(hours: 168)` / `Duration(seconds: 90)` / `Duration(days: 36500)`。`ResourceGateway.json` 用 `cacheTtl(scope)`，本文件用 `kJsonTtl` 作默认值、`ttl == kListTtl` 作层级判定；两处靠 Duration 值相等（`==` 比较微秒）隐式耦合，任意一处改动数值就会让 `json:`/`list:` 前缀判定或 TTL 静默错层。文件头注释「TTL 常量（v4.0 冻结契约）」未说明与 `cache_keys.dart` 的重复关系。
- 影响：将来调整任一 TTL 时列表缓存可能被写成 168h 的 JSON 层，用户看到长时间不刷新的旧列表；当前无用户可见错误，属整洁度/可维护性缺陷。
- 证据等级：实锤（两处常量值与引用路径在已读两个文件内确认）

---

## 5. `lib/core/resource/cached_api.dart`（81 行，完整读）

### cached_api.dart:21-65 `get`/`post` 的 `ttl` 参数被静默丢弃，除 90s 外任何值都按 168h 生效
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围/失败返回语义必须明确）、第 15 条（单位必须显式）、第 31 条（注释与行为一致）
- 依据：`Duration? ttl`（`:24` / `:47`）只用于 `final scope = ttl == cacheTtl(CacheScope.list) ? CacheScope.list : CacheScope.json;`（`:29-31` / `:50-52`），其后 `ResourceGateway.instance.json(...)` 的调用**完全没有传 ttl**，最终 TTL 由门面 `cacheTtl(scope)` 决定（`resource_gateway.dart:52`）。因此 `ttl: Duration.zero`（强制刷新）、`ttl: Duration(seconds: 30)` 与 `ttl: null` 生成完全相同的缓存键与 168h TTL；同一 path 的「强制刷新」与「普通读取」共用同一 `ResourceCache._inFlight` 项。注释 `:27-28` 写「ttl 参数保留兼容旧调用方……最终 TTL 仍取 cacheTtl(scope)」，但签名保留了 `Duration? ttl` 却不说明「非 90s 值一律被忽略」，属于输入契约模糊。
- 影响：调用方以为设置了短 TTL/强制刷新，实际 168 小时内始终命中同一份缓存；用户下拉刷新后列表内容不变、VIP/权限变更后仍显示旧态，且无日志可判断是否发起过新请求。
- 证据等级：实锤（参数使用点与门面 TTL 来源在已读两个文件内成对确认）

### cached_api.dart:72-80 `bodyIdentity` 无转义/无长度上限，不同 POST body 可生成同一缓存键
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 14 条（所有数据边界必须校验）、第 25 条（所有资源必须有上限）、第 3 条（契约先行）
- 依据：`static String bodyIdentity(Object v)` 对 Map 输出 `'{${keys.map((k) => '$k=${bodyIdentity(v[k] ?? '')}').join(',')}}'`（`:75`）：键与值都不转义 `=``,` `{` `}` `[` `]` 等分隔符，`v[k] ?? ''` 把 `null` 与空串同化，`Iterable` 与某些字符串拼接可产生同一身份文本；字符串虽带 `s:` 前缀（`:78`），但 Map 的键名 `s:x` 与字符串值仍可构造歧义。该**完整正文字符串**经 `:61` 作为 `extra` 传给 `ResourceGateway.json`，最终由 `cacheKey` 以 `':$extra'` 原样拼进键（`cache_keys.dart:40-41`），无长度截断、无摘要、无长度上限；注释 `:59-60` 称「请求体不含凭证，缓存键不写敏感原文」，但实现把整个请求体（含任意字段）明文写进键，Hive 键与 debugPrint 日志都可能携带用户正文。Map 键排序用 `'$k'`（`:74`）对非 String 键也只做字符串化，不同类型键可碰撞。
- 影响：两个参数不同但拼接歧义的 POST 请求命中同一份缓存，用户看到上一个请求的结果；长正文（评论/搜索词/表单）使缓存键无限增长并落入箱内键表与日志，低端机内存/磁盘膨胀，且注释承诺的「不写敏感原文」不成立。
- 证据等级：静态推演（字符串构造与键透传在已读三个文件内成对确认；碰撞构造未实测）

### cached_api.dart:19 / 32-40 键维度只含 userid，未覆盖 token/音质/语言/区域；且 `_userid` 在每次调用时读取、无账号世代
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 18 条（异步结果必须校验世代）
- 依据：`String get _userid => _api.userid.isEmpty ? '0' : _api.userid;`（`:19`）是唯一身份维度，经 `:37` / `:58` 传入门面；`cache_keys.dart:3-9` 把用户身份、音质、语言、区域、时间窗列为键维度，但本类没有注入或读取这些值的入口，`schemaVer` 也用默认值（`kCacheSchemaVer = 1`）。`_api.userid` 是共享可变状态：切号瞬间在途请求的键已按旧 userid 生成，其响应仍写回旧账号键，无世代判定。
- 影响：VIP 到期、切换音质/语言、匿名→登录（userid 仍为 0）时命中旧账号态缓存，用户看到本不应可见的内容或得到与设置不符的音质/语言，且 168h 内不自愈；切号在途响应回灌旧账号数据。
- 证据等级：静态推演（键参数列表在本文件内确认；上游响应是否随这些维度变化不在本范围）

### cached_api.dart:21-65 `stale` 参数在 L1 命中路径完全失效，且本类不消费 `__stale` 标记
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（回退路径与主路径异常形态一致）、第 9 条（失败必须可观测）、第 11 条（降级触发/退出条件）
- 依据：`bool stale = true`（`:25` / `:48`）原样透传为 `staleOnError: stale`（`:39` / `:63`）；本类返回值仍是 `Future<Map<String, dynamic>>`，没有读取/转换 `__stale`、没有日志。且 `ResourceGateway.json:47-48` 在 L1 命中时直接 `Future.value(mem)`，根本不进入 `ResourceCache` 的降级逻辑；`ResourceCache._doFetch:120-134`（已读）对合并调用方使用**首个调用方**的 `staleOnError`，因此 `stale: false` 在并发或 L1 命中场景均可能收到带 `__stale` 的旧值。注释 `:12`「写操作禁止走本类（防重与异常契约另有语义）」只是约定，签名层面无类型/断言阻止。
- 影响：明确要求「不许用旧数据」的调用方在并发/L1 命中场景仍拿到旧数据，界面把过期内容当作实时结果且无任何提示（例如权限/会员态相关展示错误）。
- 证据等级：静态推演（透传路径与已读门面/`_doFetch` 捕获参数成对确认；上游是否读 `__stale` 不在本范围）

### cached_api.dart:5-12 注释宣称「唯一读实现」「键由 cacheKey 生成」，但 `ResourceCache` 内部再加 `json:`/`list:` 前缀、L1 另有独立键空间
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 5 条（状态单一来源）
- 依据：注释 `:5-12` 称「**唯一读实现**」「键由 cache_keys.cacheKey 生成」「失效由 invalidateNs(ns) 精确删除（含内存层）」；已读 `resource_cache.dart:71-72` 在 `cacheKey` 产物外再拼 `_jsonPrefix`/`_listPrefix` 形成实际箱内键，`resource_gateway.dart:38-56` 的 L1 又是独立 Map 且不过期，`cache_manager.dart:124-129` 的 `MemoryCache.keyOf` 与 `LyricPersistentCache._key` 各自定义键格式，`cache_keys.dart:45` 的 `cacheNsPrefix` 无人调用（门面 `:68` 与 `resource_cache.dart:300` 各自硬编码 `:$ns:u=`）。所谓「唯一事实源」在跨类链路上并不成立。
- 影响：维护者按注释以为改一处即可全局调键/失效，实际出现「按 ns 失效漏清」「清缓存漏键」等静默失效；无直接用户可见错误，属整洁度缺陷。
- 证据等级：实锤（已读五个文件的键构造路径对照）

---

## 6. `lib/core/resource/lyric_translation_stream.dart`（36 行，完整读）

### lyric_translation_stream.dart:17-34 单例 `dispose()` 关闭后不可重建，且无生命周期世代门禁
- 级别：P1
- 违反：QUALITY_STANDARD 第 20 条（生命周期必须双向对称，异步回调触及已销毁对象必须确认存活）、第 18 条（异步结果必须校验世代）
- 依据：`static final instance = LyricTranslationStream._();` 与 `final _controller = StreamController<...>.broadcast();` 是 `final` 字段，`Future<void> dispose() => _controller.close();` 之后没有任何重建/重新赋值路径。`emit` 只做 `if (_controller.isClosed) return;`——`dispose()` 之后所有译文补丁被**静默丢弃**（无日志、无返回值、无异常），而 `patches` getter 仍返回一个已关闭的流，新订阅者会立即收到 done 事件。`dispose()` 也没有 `await` `_controller.close()` 之外的订阅释放（广播订阅由订阅方自行管理，本类无登记）。注释「仅测试/热重载场景调用」假定了一个并不由代码保证的使用范围。
- 影响：一次测试或热重载调用 `dispose()` 后，整个进程生命周期内歌词翻译再也不会实时插行，用户只能等下次进页面读持久缓存（且语义变成"没有实时更新"），全程无提示；热重载后 UI 订阅到 done 事件即永久停止更新。
- 证据等级：静态推演（`final` 字段与 close 语义在本文件内确认；`dispose` 调用方不在本范围）

### lyric_translation_stream.dart:28-31 切歌世代未进入补丁契约，旧歌译文可插入新歌
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 23 条（键必须覆盖全部影响结果的维度）
- 依据：`LyricTranslationPatch` 只有 `lyricId`、`startIndex`、`values` 三个字段；`emit(LyricTranslationPatch p)` 无条件 `_controller.add(p)`，不比较当前曲目、不检查 `lyricId` 是否属于当前订阅的歌、不校验 `startIndex` 是否为非负/是否在歌词行数内、`values` 是否为空。注释第 23-24 行承认「UI 尚未订阅（切歌瞬间）时丢一批可接受」，但只处理了"丢"，没有处理"迟到一批"：切歌后上一首歌的异步译文到达时同样会被广播，广播控制器不做任何过滤，只能由每个订阅方自己判断 `lyricId`。类注释「遵循单一事实源+事件通知分层」与「多页订阅互不影响」也未给出世代归属方。
- 影响：快速切歌时上一首歌的译文补丁混入当前歌词，出现错位/串歌译文；`startIndex` 越界时 UI 按 `values.length` 插行可能抛异常或把译文插到错误行。
- 证据等级：静态推演（补丁字段与 emit 分支在本文件内确认；订阅方是否自行过滤不在本范围）

### lyric_translation_stream.dart:11-15 / 26-32 注释「无监听时 emit 不丢错、不阻塞」与「缓存命中时也 emit 一次（UI 秒显）」在本类无实现
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，注释与行为一致）、第 9 条（失败必须可观测）
- 依据：类注释第 10-12 行声明「缓存命中时也 emit 一次（UI 秒显）」，但本类只有 `patches` getter 与 `emit`，没有任何缓存读取或命中检测代码；该行为只能由外部调用方额外完成。`emit` 中「broadcast 流在无监听时静默丢弃」被注释为「可接受……故无需缓冲区（第 25 条上限）」，实际是无条件的静默降级，无日志、无计数，与「失败必须可观测」不一致。
- 影响：缓存命中若无外部补 emit，UI 需等整批翻译完成才显示；属于注释误导与静默丢事件，用户可见为译文偶发延迟显示。
- 证据等级：实锤（本类全部成员在本文件内枚举完毕；外部调用方不在本范围）

---

## 7. `lib/core/prefetch/prefetch_engine.dart`（211 行，完整读）

### prefetch_engine.dart:117-127 / 155-194 / 204-210 dispose 后门禁只挡入口，`_prefetchOne` 的三个 `await` 之后仍继续发请求、写缓存
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 20 条（生命周期对称，异步回调触及已销毁对象必须确认存活）、第 22 条（并发假设必须写明）
- 依据：`void dispose() { _disposed = true; ... _cached = null; }` 只置标志、取消 Timer、清集合，注释第 202-203 行声称「进行中的单个 fetch 无定时器持有、结果只写缓存，无需取消也安全」。但 `_prefetchOne` 在方法开头 `final cached = _cached;` 取到局部引用后，三个 `await cached.get(...)`（第 1/2/3 段）之间**没有任何 `if (_disposed) return;`**；`_drainOne` 的 `if (_disposed) return;` 只在取出 song 之前判断一次。`dispose()` 无法取消已发出的请求，也无法收回局部变量 `cached`（指向仍存活的 `KugouApiClient`），因此 dispose 后该闭包会继续依次发出歌词、专辑请求，并把结果经 `ResourceCache` 写进盒（注释所谓「结果只写缓存」正是未受门禁的副作用）。文件头注释自称「第 18 条：dispose 后异步回调先检查存活状态（_disposed）再动作」，与实现不符（第 31 条）。此外 `cached` 已被置 null，重建/新 `attach` 后旧的在途闭包仍用旧客户端（旧账号 userid）写缓存，形成切号后的世代串数据。
- 影响：账号退出/切号或应用模块释放后，后台仍以旧登录态发请求并写入新缓存；用户在新账号下可能命中旧账号的 URL/歌词数据，且产生无法解释的后台流量与隐私残留。
- 证据等级：实锤（`_prefetchOne` 内三处 await 之间无 `_disposed` 判断、dispose 不清在途 Future 在本文件内确认）

### prefetch_engine.dart:40 / 72-85 / 92-110 `_requested` 是「一次性」去重集，永不随成功/失败/失效而回收，容量只约束单次入队
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 11 条（降级必须有退出条件）、第 23 条（键维度与失效维度）
- 依据：`final _requested = <String>{};` 只增不减（唯一清除在 `dispose()`）；`enqueueSongs` 的 `if (!_requested.add(song.hash)) continue;` 与 `updateUpcoming` 同样以 hash 为唯一去重维度。上限常量 `_maxEnqueuePerCall = 60` 只限制**单次** `enqueueSongs` 的入队数（`taken >= _maxEnqueuePerCall - _pending.length`），而 `updateUpcoming` 的 `window = 15` 完全不受 `_maxEnqueuePerCall` 约束，且用 `_pending.insertAll(0, upcoming)` 直接插入，可使 `_pending` 长度超过 60；`_requested` 本身没有任何容量上限或过期淘汰。hash 相同但音质（`song.quality`）不同、账号不同、缓存被 `invalidateNs`/`clearJson` 清空后，仍因 `_requested` 命中而永久跳过预热。注释「同一 hash 本进程只预请求一轮」把无期限的一次性状态当设计，但 `ResourceCache.json` 有 TTL/失效，二者生命周期不一致。
- 影响：长时间使用（听歌/切歌多）内存集合无界增长；更直接的是用户切换音质、切号或清缓存后，预热对该歌永久不再生效，播放时需临时请求，表现为切歌后 URL/歌词加载变慢，且注释承诺的「预热复用」静默失效。
- 证据等级：实锤（集合的全部 add/clear 路径与两处入队上限在本文件内枚举完毕）

### prefetch_engine.dart:76-84 `enqueueSongs` 的上限算术在 `_pending.length > 60` 时提前 break
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（上限实现须与行为一致）、第 11 条（降级触发条件）
- 依据：`if (taken >= _maxEnqueuePerCall - _pending.length) break;` 在 `_pending.length` 已超过 60（可由 `updateUpcoming` 的 `insertAll` 造成，见上条）时右侧为负，`taken(0) >= 负数` 立即成立，整个 `enqueueSongs` 静默不入队。更隐蔽的是，循环中先 `_requested.add(song.hash)` 再 `_pending.add(song)`；若 `songs` 里 hash 为空则 `continue`，但没有回滚，正常的 break 只影响其后元素，已 add 的 hash 都进了队列，此处尚属一致；然而「`_requested` 已加入但 `_pending` 被 `dispose()` 清空」后，因 `dispose()` 同时 `_requested.clear()` 才恢复，若仅管理器单独清 `_pending`（本类无此公开方法）就会永久丢请求。上限与队列的真实长度没有统一约束。
- 影响：队列被 upcoming 插队撑大后，首页预热整批静默跳过，用户滑动到后面的歌曲时无预热、加载变慢；无任何日志说明跳过原因。
- 证据等级：实锤（算术分支在本文件内确认）

### prefetch_engine.dart:117-127 `onPlaybackCompleted` 的 `catchError` 只接住 Future error，`cacheUrlFile` 的同步/内置失败返回 null 无留痕；且未等待
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 20 条（异步回调门禁）、第 1 条（单一职责）
- 依据：`ResourceCache.instance.cacheUrlFile(url, kind, declaredBytes: declaredBytes).catchError((Object e) { debugPrint(...); return null; });` 返回类型为 `Future<String?>`，结果被完全丢弃、无 `unawaited`、无返回值给调用方。`cacheUrlFile` 在 `declaredBytes <= 0`、`Content-Length` 不符、下载长度不符、catch 等路径上都是 `return null`（已读确认），这些**不是 Future error**，`catchError` 不会触发；本方法也不检查 `null`（其实也未保存 Future），因此绝大多数「拒入库/下载失败」在本层没有任何留痕（仅 `ResourceCache` 的 debugPrint，release 不可见）。`catchError` 回调本身没有 `if (_disposed)` 门禁，dispose 后到达的异常仍会 debugPrint。注释「试听片段/通用预览不调用本方法」把 `declaredBytes=0` 的防御完全交给调用方，而 `declaredBytes` 有默认值 0，调用方省略即静默拒绝。
- 影响：播放完成后文件永久缓存实际未写入（例如下载长度不符或无声明字节），用户下次播放仍要联网、离线不可用，且没有用户可见反馈或持久化日志说明原因；省略 `declaredBytes` 时功能静默不生效。
- 证据等级：实锤（本方法调用形态 + 已读 `cacheUrlFile` 的返回分支成对确认）

### prefetch_engine.dart:63-65 `attach()` 不校验 dispose 状态，可让废引擎重新持有客户端
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果校验世代）、第 20 条（生命周期对称）、第 31 条（注释与行为一致）
- 依据：`void attach(KugouApiClient api) { _cached = CachedApiCall(api, ns: 'prefetch'); }` 没有 `if (_disposed) return;` 或任何重建路径；`_disposed` 是单向置 true 且**永不复位**。单例 `dispose()` 后再次 `attach()` 会造出「`_cached != null` 但 `enqueueSongs/updateUpcoming/onPlaybackCompleted` 全部因 `_disposed` 静默返回」的僵死状态：`_startDrain` 也因 `_disposed` 直接 return，`_drainTimer` 永不再启动。类注释「未调用 [attach] 前入队只收集不请求」描述的是 attach 前，而 dispose 后既不能收集也不能请求，注释未覆盖。
- 影响：热重载/测试/账号生命周期重走 attach 后，预加载整体永久停摆，用户切歌时 URL/歌词均需现场请求，表现为加载转圈变久；无任何报错。
- 证据等级：静态推演（`_disposed` 赋值点与所有门禁在本文件内枚举完毕；`dispose` 调用方不在本范围）

### prefetch_engine.dart:130-134 / 137-148 `_startDrain` 每次都 `cancel()` 并重造周期 Timer，队列非空时定时器无限期存活
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（生命周期对称）、第 25 条（重试/并发上限）
- 依据：`void _startDrain(Duration spacing) { if (_disposed) return; _drainTimer?.cancel(); _drainTimer = Timer.periodic(spacing, (_) => _drainOne()); }` 在 `enqueueSongs` 与 `updateUpcoming` 每次调用时都执行；`updateUpcoming` 固定传 100ms 覆盖掉 `enqueueSongs` 传入的 `spacing`（自定义 spacing 静默失效，第 3 条契约）。周期定时器只在 `_drainOne` 发现 `_pending.isEmpty` 时才 `_disposeTimer()`；由于 `_drainOne` 是 fire-and-forget（注释明确「此处不等待」），每个节拍发出的请求**没有并发上限**：100ms 一个、网络慢于 100ms 时可同时存在任意多个 `cached.get`（每个内部还有 3 个串行请求），注释「请求按 spacing 摊开，不瞬间并发」与实际并发数无关。Timer 无 `Timer.cancel` 之外的释放，但也无最大 tick 数/总时长上限。
- 影响：弱网下预取请求堆积、占用带宽挤占正在播放的音频请求，用户遇到播放卡顿；自定义 spacing 在切歌后失效。
- 证据等级：实锤（Timer 创建/取消点与 `_drainOne` 不等待 Future 的注释在本文件内确认）

### prefetch_engine.dart:17-19 / 62-65 / 161-190 注释「只走 ResourceCache.json，预热命中缓存播放时直接复用」与实际端点和键维度不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 28 条（调用方式必须逐一实测）、第 29 条（返回结构必须实测并留样）、第 31 条（注释与行为一致）、第 23 条（键维度）
- 依据：`_prefetchOne` 第 1 段注释「kapi /song/url，含音质参数；直连 /v5/url 不经 kapi 也无 JSON 可缓存，预热只覆盖 kapi 路径，直连由播放时解析」，并调用 `cached.get('/song/url', query: {...})`；文件头注释「统一走 [CachedApiCall]……与 repository 侧读写天然同键——预热命中的缓存播放时直接复用」。`CachedApiCall` 构造时 `ns: 'prefetch'`（已读 `attach`），而 repository 侧若用其它 `ns` 则 `cacheKey` 的 ns 段不同，**不可能同键**；注释同时承认预热只覆盖 kapi 路径，那么以原生直连为主路径时这批预热结果根本不会被播放链路读取（第 27 条原生网关优先）。第 3 段注释「封面字符串在 Song 对象内已就绪，无需预请求」与文件头「只预请求 URL/歌词/封面 JSON」也不一致；`/album/detail` 的「已实测 st=1 data=list[1]」只在注释中声明，本范围无实测样本文件可追溯。
- 影响：预热流量与磁盘写入对实际播放链路无收益，用户仍要现场请求播放地址；`ns` 不同造成的双份缓存让「清缓存/按 ns 失效」漏掉预热键，长期残留旧账号数据。
- 证据等级：静态推演（`ns:'prefetch'` 与 `cacheKey` 的 ns 维度在已读两个文件内成对确认；repository 的实际 ns 与原生直连路径不在本范围，未实测）

### prefetch_engine.dart:161-193 三个 `catch (e)` 全捕获且只 debugPrint，回退/错误形态与正常值无法区分
- 级别：P2
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理的类型）、第 9 条（失败必须可观测）、第 8 条（异常契约单一且稳定）
- 依据：三处 `catch (e) { debugPrint('[prefetch] ... failed ...: $e'); }` 均无 `on` 类型限定，把 `TypeError`、越界、取消等编程错误与网络失败同等处理；`debugPrint` 在 release 不落盘，本层无 ErrorLogger 调用、无计数、无返回值（`Future<void>`），调用方（`_drainOne` 丢弃 Future）无法知道失败。注释「任何失败留痕不崩（第 9 条）」把 debug 通道当作可观测。三段是串行 `await`，但彼此**不互为条件**：第 1 段失败仍继续第 2、3 段，失败三次仍算「该 hash 已请求」（`_requested` 不回滚），无重试退出条件（第 11 条）。
- 影响：预取整体失效时线上无法定位，也不会重试；release 包用户只表现为「预热没效果」，且该 hash 在本进程内不再尝试。
- 证据等级：实锤（三个 catch 与 `_requested` 不回滚在本文件内确认）

---

## 8. `lib/core/storage/secure_storage.dart`（124 行，完整读）

### secure_storage.dart:26-42 `saveCredentials` 把 5 个写/删并发提交到同一 Keystore，`Future.wait` 无事务、无回滚、无世代锁
- 级别：P0
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源/多处写导致不一致）、第 18 条（异步结果必须校验世代）、第 21 条（写操作防重/一致性）、第 9 条（失败必须可观测）
- 依据：`final ops = <Future<void>>[_storage.write(key: _kToken, value: token), _storage.write(key: _kUserId, value: userId), ... if (t1 != null) write else delete ...]` 后 `await Future.wait(ops);`。5 个平台通道操作同时发起：token/userid 写入与 t1/auth/dfid 的删除或写入之间**无顺序保证、无原子性**；`Future.wait` 在其中一个失败时立即以该错误完成，但已发起的其它写/删不会被取消或回滚，也不等待它们结束。方法没有 try/catch、没有日志、没有「本次写入是否仍是当前登录世代」的标识，也没有并发调用互斥（登录/切号/登出并发时两种凭证互相穿插）。注释自称「C-03：null 必须删除旧键——切号时新响应常不带 t1/auth，保留旧值会造成 A 账号票据配 B 账号 token 的串号」，但并发 + 部分失败恰好能造成同样的串号：`_kToken` 已换成 B、`_kT1` 删除失败仍是 A 的票据。
- 影响：一次 Keystore 抖动或切号竞态即可产生 A 账号票据 + B 账号 token 的混合凭证，用户表现为登录后请求被风控拒绝/反复要求验证/展示到另一个账号的数据；凭证错误会持久保存，重启也不会自愈，且无日志可定位。
- 证据等级：静态推演（`Future.wait` 的失败语义与无回滚为 Dart/本文件代码事实；Keystore 平台通道的具体并发行为未实测）

### secure_storage.dart:45-66 `readCredentials` 只判 `null`，空串凭证被当作有效登录态并行返回 5 键
- 级别：P1
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 16 条（空集合与缺失必须语义分离）、第 8 条（异常契约稳定）
- 依据：`final results = await Future.wait([...5 个 read...]); final token = results[0]; final userId = results[1]; if (token == null || userId == null) return null; return Credentials(token: token, userId: userId, ...)`。凭证来自平台通道/Keystore（外部边界），却只判 `null`，`token = ''`、`userId = ''` 均被视为已登录；`t1`/`auth`/`dfid` 无任何形态校验。`Future.wait` 下任一 read 抛 `PlatformException`（Keystore 不可用）会使整个读取以原生平台异常形态失败，本层不包装、不留痕，与「返回 null 表示未登录」的正常路径异常形态不一致。注释第 42-43 行写「四键读取并行化」，实际数组有 **5 个** read（含 dfid），注释与行为不一致（第 31 条）。
- 影响：Keystore 返回空串（部分机型/迁移残留）时应用以空 token 走登录态，所有接口 401/风控且界面显示「已登录」；平台异常未包装导致上层无法统一降级到未登录，用户卡在启动/登录页。
- 证据等级：静态推演（判定条件与 5 个 read 在本文件内确认；空串是否真实出现未实测）

### secure_storage.dart:65-87 `clearCredentials` 的文档注释与实现互相矛盾，且只删当前 userid 的切换 token
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 20 条（写入/清除对称）、第 9 条
- 依据：文档注释 B-11 写「登出必须清干净当前会话凭证 + **dfid** + 账号 token」「此前只删 4 个键：**dfid 残留**（下次登录签名维度错乱）」；紧随其后的 F-1 注释又写「dfid 属于设备不属于账号……**保留 dfid**」，实现 `Future.wait([... delete(_kToken/_kUserId/_kT1/_kAuth), if (userid != null ...) delete('acct_token_$userid')])` 确实**不删 dfid**。两段注释对同一行为给出相反结论，读者无法判断哪个是当前契约。`acct_token_` 只按传入的 `userid` 删一个键，其它账号的切换 token 全部保留（多账号设计下或属预期，但注释「退出后仍可无密码切回该账号」只解决了当前账号）。`saveCredentials` 里 `dfid == null` 会 `_storage.delete(key: _kDfid)`，与 `clearCredentials` 保留 dfid 的口径相反——同一"设备标识"在不同入口一个删一个留。删除操作无 try/catch/日志，任一失败被 `Future.wait` 原样抛出。
- 影响：登出后 dfid 与否取决于调用的是 `clearCredentials` 还是 `saveCredentials(dfid: null)`，可能出现重登被判新设备（风控验证）或反之设备票据残留；共享设备上其它账号 token 仍可无密码切回，用户以为已退出但账号仍在线。
- 证据等级：实锤（两段注释与两个方法的键集合在本文件内成对确认）

### secure_storage.dart:89-108 `saveDfid` / `saveAccountToken` / `readAccountToken` / `deleteAccountToken` 对 key/value 零校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 23 条（键必须覆盖全部影响结果的维度）
- 依据：`Future<void> saveAccountToken({required String userid, required String token}) => _storage.write(key: '$_kAcctTokenPrefix$userid', value: token);` 与 `readAccountToken(String userid)`、`deleteAccountToken(String userid)` 直接把 `userid` 拼进键；`userid` 为空串时键退化为 `acct_token_`，不同调用方（含误传空 userid）共用同一条记录。`saveDfid(String dfid)` 不校验空串/长度，可与 `saveCredentials` 的 dfid 分支写入不一致的值。全类没有统一的键生成函数，键字符串在 `clearCredentials`、`saveAccountToken`、`readAccountToken`、`deleteAccountToken` 四处重复拼接 `'$_kAcctTokenPrefix$userid'`（第 5 条单一事实源）。
- 影响：切号流程某处传空 userid 时，账号切换 token 被写到共享键，B 账号读到 A 账号的 token，用户可在共享设备上进入他人账号；无日志、无报错。
- 证据等级：静态推演（键拼接与无校验在本文件内确认；空 userid 调用方不在本范围）

---

## 9. `lib/core/storage/storage_permission.dart`（355 行，完整读）

### storage_permission.dart:151-176 `resolveRoot()` 在探测明确失败时仍返回该路径，且最终兜底路径完全不探测
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确的触发条件与退出条件）、第 14 条（数据边界必须校验）、第 9 条（失败必须可观测）
- 依据：`if (base != null && base.isNotEmpty) { final candidate = '$base/$fallbackRootDirName'; if (await _probeWritable(Directory(candidate))) return candidate; debugPrint('[perm] download root probe failed: ...'); return candidate; // 通道给了真实路径：即使探测失败也返回（调用方各有降级）' }`，以及通道异常后 `return '/storage/emulated/0/Download/$fallbackRootDirName';` 无任何探测或目录创建、`lastProbeError` 也不置值。类注释第 149-153 行宣称「**每次调用重新实测写入能力**」「任何一环不通过都判为不可写，不信缓存」，实现却在探测失败时原样返回不可写路径，并把降级责任推给「调用方各有降级」——本范围内 `ResourceCache._dirOf` 正是调用方，它只做 `dir.create(recursive: true)` 然后 `writeAsBytes`/`rename`，失败仅 `debugPrint`，没有二级降级。最终硬编码兜底路径在不同厂商/多用户/SD 卡布局下可能根本不存在，且连一次探针都没跑过。
- 影响：下载/永久文件缓存目录不可写时，用户看到文件反复下载失败、离线文件永远不可用，界面只有 debug 日志（release 不可见）；设置页展示的「探测到的实际可写路径」与实际写入路径不一致，无法自助排查。
- 证据等级：静态推演（`resolveRoot` 返回分支与已读 `ResourceCache._dirOf` 的失败处理成对确认；真机不可写路径未实测）

### storage_permission.dart:109-140 / 99 `_probeWritable` 的早退分支不清探针文件，`lastProbeError` 是并发共享的全局可变状态
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（生命周期对称、资源申请必须有对称释放）、第 22 条（并发假设必须写明并保护）、第 5 条（状态单一来源）、第 6 条（禁止吞掉异常）
- 依据：`static String? lastProbeError;` 是类级静态可变字段，被 `isAllFilesAccessGranted` / `requestAllFilesAccess` / `_probeWritable` / `resolveRoot` / `apiLevel` / `requestStoragePermission` / `requestNotificationPermission` / `isPublicDirWritable` 等十余处交叉写入。`_probeWritable` 里 `lastProbeError = '目录创建失败: $e'; ... return false;`、`if (readBack != payload) { lastProbeError = '探针读回不一致'; ... return false; }` 这两个早退分支在探针文件已创建/写入后直接返回，**不删除探针**（删除只写在最外层 `catch` 里，且内层 `catch (_) {}` 是空体吞异常）；`await probe.delete()` 本身失败时也会走外层 catch 而把成功的探测判成 false。探针名 `'.tm_probe_${DateTime.now().millisecondsSinceEpoch}.tmp'` 仅靠毫秒时间戳区分，`resolveRoot()`、`resolveRootMode()`、多个下载/日志调用并发时可能生成同一路径，互相删除/读回对方文件。类注释第 19-22 行自称「**唯一权威**的存储权限来源」「两者共享同一套判定逻辑」，但 `lastProbeError` 没有任何所有者/世代标识，注释第 101-108 行只警告了「不得经 ErrorLogger 留痕」的递归链，未声明并发前提。
- 影响：探测并发时设置页展示的是另一次探测的错误信息（误导排查），或可写目录被误判为不可写而整体降级到 Download；残留 `.tm_probe_*.tmp` 文件出现在用户文件管理器里，且并发探针互相覆盖可造成一次真实的写入探测失败。
- 证据等级：静态推演（早退分支与静态字段的全部写入点在已读文件内枚举；毫秒碰撞时序未实测）

### storage_permission.dart:218-225 / 271-273 `_apiLevelFromOsVersion` 的版本名→API 映射在 Android 13+ 偏移一档
- 级别：P1
- 违反：QUALITY_STANDARD 第 17 条（数值与标识符的精度不容协商）、第 15 条（单位必须显式）、第 28 条（调用方式/平台口径必须实测）、第 31 条（注释与行为一致）
- 依据：`if (name <= 9) return name; // Android 9 == API 28` 与 `return name + 19;`（注释「Android 10 → API 29，逐版本递增」）。Android 10=29、11=30、12=31 时 `+19` 恰好成立；Android 13=33、14=34、15=35、16=36 时 `+19` 分别得到 32/33/34/35，全部少 1；`name <= 9` 分支返回的是「版本名」而不是 API level（Android 9 应为 28，实际返回 9），注释自己写明这一不等价却仍按数值返回。`requestNotificationPermission()` 用 `if (level < 33) return true;` 判定是否需要申请通知权限：原生通道失败且设备为 Android 13 时，映射得 32，函数直接 `return true` 而**跳过 `Permission.notification.request()`**。`_apiLevel` 一旦缓存这个错误值便在整个进程内不再重算。
- 影响：Android 13+ 机型原生通道异常时，后台下载通知权限从未申请，用户看不到下载进度/完成通知，却以为下载在后台正常进行；同时 `needsLegacyWritePermission()` 等分支的判定数值与真实 API level 不符，注释承诺的「版本名兜底」不可靠。
- 证据等级：静态推演（映射公式与 `level < 33` 阈值在本文件内成对确认；Android 13=API 33 属平台版本常识，真机未实测）

### storage_permission.dart:263 / 293 / 316 `request()` 与 `currentStrategy()` 的状态查询未包异常，与同类 `status` 查询的异常契约不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一且稳定）、第 6 条（禁止吞掉异常）、第 9 条（失败必须可观测）
- 依据：`requestStoragePermission()` 用 `try { status = await Permission.storage.status; } catch (e) { debugPrint(...); return false; }` 包住状态查询，但其后的 `final result = await Permission.storage.request();` **没有 try/catch、没有 debugPrint、没有 `lastProbeError`**；`requestNotificationPermission()` 结构完全相同，`Permission.notification.request()` 同样裸调用。`currentStrategy()` 里 `final status = await Permission.storage.status;` 也完全裸调用，而同文件 `isAllFilesAccessGranted()` / `apiLevel()` / `publicDir()` / `isPublicDirWritable()` 都把平台通道调用包在 try/catch 里留痕。类注释「**唯一权威**的存储权限来源……两者共享同一套判定逻辑」在异常路径上不成立：同样一次 ROM/通道异常，有的入口返回 false，有的入口以 `PlatformException`/`MissingPluginException` 冒泡。
- 影响：授权页不可用的 ROM 上，权限申请入口抛出未包装的平台异常，上层若未捕获则设置页/下载入口报错或崩溃；而 `currentStrategy()` 抛错时写策略无法判定，下载功能静默停摆且无日志。
- 证据等级：静态推演（同类方法的异常分支差异在本文件内成对确认）

### storage_permission.dart:301-320 `resolveStrategy()` 仅凭授权态判 directPath，与 `resolveRoot()` 的「实测不可写即降级」口径冲突
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 11 条（降级触发条件）、第 31 条（注释与行为一致）
- 依据：`Future<StorageStrategy> resolveStrategy() async { final level = await apiLevel(); if (await isAllFilesAccessGranted()) return StorageStrategy.directPath; ... }` 与 `currentStrategy()` 同样只看 `isAllFilesAccessGranted()` / `Permission.storage.status`，**都不调用 `_probeWritable`**；而 `resolveRoot()` 在授权态为真时仍先 `await _probeWritable(Directory(rootPath))`，失败则降级 Download 并留痕（注释「不再信授权态缓存」）。因此同一时刻可得到「策略 = directPath（直写公共根）」但「根 = Download/TiernanMusic」两个互相矛盾的事实。`resolveRootMode()` 虽做探针，但它独立调用 `isAllFilesAccessGranted()` + `_probeWritable()`，与 `resolveRoot()` 的探测结果不共享、不缓存，两次探测结论也可能不同。类注释「这是**唯一权威**的存储权限来源」「两者共享同一套判定逻辑」与实际三套判定（授权态/探针/通道）不一致。
- 影响：下载模块按 directPath 直接写公共根而缓存/日志模块按 Download 写，用户文件散落两个目录且部分写入静默失败；设置页显示的存储模式与实际生效路径不符，排查存储问题困难。
- 证据等级：静态推演（三个方法的判定输入在本文件内成对确认；调用方组合方式不在本范围）

### storage_permission.dart:196-215 / 182-188 `apiLevel()` 缓存无失效、无并发合并；`resolveRootMode()` 每次重复探测写根目录
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 18 条（异步结果校验世代）、第 24 条（惰性构建/避免重复 I/O）
- 依据：`int? _apiLevel;` + `if (_apiLevel != null) return _apiLevel!;` 无 in-flight Future：多个调用者（下载、日志、设置页）可在同一启动期各自发起 `_channel.invokeMethod<int>('apiLevel')`；一旦写入便永不重算，权限/系统升级或通道首次失败后的值在进程内固定。`resolveRootMode()` 无条件 `await _probeWritable(Directory(rootPath))`（写探针文件→读回→删除），而 `resolveRoot()` 也做同样一次；设置页与写入方同时调用即在公共根产生两次实际磁盘写。`resolveRoot()` 的注释强调「每次调用重新实测写入能力」，与 `apiLevel()` 的永久缓存形成两种相反的时效口径，且未声明写探针的并发前提。
- 影响：启动期多次重复平台通道调用与探针磁盘写，低端机存储卡顿；`apiLevel` 若因通道瞬时失败落到兜底值，整个会话内权限分支都按错误级别走（例如通知权限不申请），用户可见为通知缺失或下载写错目录。
- 证据等级：静态推演（缓存与探针调用点在本文件内确认）

### storage_permission.dart:48-54 `subDirOf` 对未知类型静默落到 `audioSubDir`
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失必须语义分离）、第 23 条（类型维度必须进入分域键）、第 9 条（失败必须可观测）
- 依据：`static String subDirOf(String typeName) => switch (typeName) { 'audio' => audioSubDir, 'mv' => mvSubDir, 'cover' => coverSubDir, 'lyric' => lyricsSubDir, _ => audioSubDir, };` 只认单数 `'lyric'`，而类常量名是 `lyricsSubDir`（复数）、日志目录常量 `logsSubDir` 不在映射中；任何其它拼写（`'lyrics'`、`'log'`、`'video'` 或空串）都无日志、无异常地返回 `audio`。注释「download_provider / public_media_store 统一走这里」把类型字符串当作已收敛的枚举，实际是裸 `String` 入参。
- 影响：调用方传 `'lyrics'` 时歌词文件被写进 audio 目录，用户在文件管理器里找不到下载的歌词，且清理/扫描音频目录时会把歌词当音频处理。
- 证据等级：静态推演（分支与常量命名在本文件内确认；实际调用方传值不在本范围）

### storage_permission.dart:32-38 / 56-59 两处根目录常量大小写不同，同一应用按授权态落进两个不同目录
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 31 条（注释与行为一致）
- 依据：`rootDirName = 'TierNanMusic'`、`fallbackRootDirName = 'TiernanMusic'`；`resolveRoot()` 授权且探测成功返回 `/storage/emulated/0/TierNanMusic`，否则返回 `<Download>/TiernanMusic`。注释第 31-33 行专门说明「保持原样，勿修正为 TiernanMusic——改名会让已有目录分裂成两个」，但实现恰恰在不同分支使用两种不同大小写，在区分大小写的 Android 文件系统上就是两个目录；`verboseRelativePath` 又硬性使用 `Download/TiernanMusic/logs/`，与授权态下的根完全无关。
- 影响：用户授权「所有文件访问」前后，下载文件分别出现在两个名字近似但不同的文件夹；日志与下载不在同一根下，用户手动备份/清理时容易漏掉旧目录。
- 证据等级：静态推演（常量与返回路径在本文件内确认；目录大小写敏感性属文件系统常识，真机未实测）

---

### prefetch_engine.dart:23 `import '../net/music_api.dart';` 未被本文件任何符号引用（analyze 实锤死代码）
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍：未使用的导入必须删除）、第 31 条（注释与行为一致）
- 依据：`dart analyze lib/core/prefetch/prefetch_engine.dart` 输出 `warning - prefetch_engine.dart:23:8 - Unused import: '../net/music_api.dart'`。本文件逐行完整读后确认：所有网络调用都经 `_cached`（`CachedApiCall.get`）与 `ResourceCache.instance.cacheUrlFile`，从未出现 `music_api.dart` 的符号；文件头注释「统一走 [CachedApiCall]……本模块不自拼键」也与这条遗留导入不一致。导入目标文件本身存在（非路径失效），因此属于纯残留。
- 影响：无直接用户可见后果；属于可维护性缺陷，掩盖了「预取是否还直连旧 MusicApi」的真实依赖，后续排查接口路径时易被误导。
- 证据等级：实锤（逐文件 `dart analyze` 输出为静态分析结论，非运行实测）

### cache_keys.dart:45 / 47-48 `cacheNsPrefix()` 与 `fileIdentity()` 在本范围 9 个文件内无任何调用点
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍：仅供"以后可能用"的抽象必须删除）、第 5 条（状态单一来源）
- 依据：逐文件完整读 + 仅用于核对 import/引用关系的符号对照：`resource_gateway.dart:59` 与 `resource_cache.dart:300` 都各自硬编码 `':$ns:u='` / `':${ns}:u='`，没有调用 `cacheNsPrefix(ns)`；`resource_cache.dart:175` 自行拼接 `final identity = '$url|$bytes'`，没有调用 `fileIdentity(url, bytes)`。`resource_cache.dart:15` 的 `const kFilePermanent = null;` 同样无引用。此外 `:86` 写入 `_inFlight[key]` 的条目因 `:90` 只按 `fullKey` 删除而永久滞留，属运行期不可回收状态（第 32/25 条，另见本轮 P0 条）。此外 `:86` 写入 `_inFlight[key]` 的条目因 `:90` 只按 `fullKey` 删除而永久滞留，属运行期不可回收状态（第 32/25 条，另见本轮 P0 条）。文件自称「缓存键唯一事实源」，但两个导出函数均无消费方，实际存在三套重复的键/身份拼接。
- 影响：无直接用户可见后果；维护者改动 `fileIdentity` 或 `cacheNsPrefix` 时不会改变任何实际行为，导致「以为已统一修复」的误判（与前述失效漏清/身份维度不一致的问题叠加）。
- 证据等级：实锤（本范围 9 文件全文枚举 + 引用对照；范围外调用方按纪律未读、未实测）

---

## 特别核对结论（任务书点名的四项，按当前磁盘状态复核）

1. **`ResourceCache.json` 的 `_inFlight` 以 fullKey 还是调用方 key 分键**：当前磁盘为**混用**，比初读状态更严重。`resource_cache.dart:73` 查表 `final pending = _inFlight[fullKey];`（fullKey）、`:86` 写入 `_inFlight[key] = fut;`（**调用方裸 key**）、`:90` 清理 `_inFlight.remove(fullKey);`（fullKey）。因此 in-flight 合并**完全失效**且条目永久泄漏；注释 `:69-70` 声称「以 fullKey 分键」与 `:86` 矛盾。已记为 P0（第 19/18/22/23 条）。初读时（331 行版本）三处统一用调用方 key，问题表现为「不同 TTL 共用同一 Future」；并发编辑后变为读写键不一致。
2. **stale 副本是否污染箱内原值**：**未污染箱内原值**。`_doFetch` 回退分支为 `return Map<String, dynamic>.from(staleBody)..['__stale'] = true;`（`resource_cache.dart:132`），`staleBody` 来自 `_readStored` 的 `jsonDecode` 新对象，`from` 是浅拷贝，箱内保存的是 JSON 字符串，写入 `__stale` 只作用于返回副本；箱内 `put` 只在 `fetch` 成功分支执行。需注意浅拷贝的嵌套 Map/List 仍共享引用，且 `ResourceGateway.json:56` 会把同一个返回 Map 存进 L1（第 22 条，已记为 P2）。此项列为复核通过项。
3. **`cacheUrlFile` 失败路径是否清理半截文件**：**不对称，存在漏清理**。唯一的 `.part` 删除在末尾 `catch (e)`（`:284-291`），而 `cl > 0 && cl != declaredBytes` 的 `return null`（`:268-271`）、`url.isEmpty`/`declaredBytes <= 0` 早退、`await target.delete()` 后 HEAD 不符返回，都不经过该清理；`dio.download` 前也不删既有 `.part`；catch 内重算 `_dirOf`/`_hashName` 且内层 `catch (_) {}` 空体吞掉删除失败。已记为 P1（第 20/14/6 条）。
4. **`PrefetchEngine.dispose` 后回调门禁**：**仅入口有门禁，在途回调无门禁**。5 个入口（含 2 个私有）都有 `if (_disposed) return;`，但 `_prefetchOne` 在 `final cached = _cached;` 之后的三个 `await cached.get(...)` 之间、以及 `onPlaybackCompleted` 的 `catchError` 回调里都没有 `_disposed` 检查；dispose 只清 Timer/队列/集合/客户端字段，不取消在途 Future。已记为 P1（第 18/20/22/31 条）。

## 逐文件 `dart analyze` 结果（贴原文）

- 环境：`export PATH=$PATH:/opt/dart/bin`；`Dart SDK version: 3.13.7 (stable)`；工作目录 `/var/minis/workspace/TiernanMusic`。
- 命令：对范围内 9 个 .dart 文件逐个执行 `dart analyze <file>`（未执行 pub get / 构建 / 测试 / 安装）。
- 噪音口径：Flutter SDK 与三方包（hive / dio / flutter_secure_storage / permission_handler / flutter/foundation / flutter/services）未安装，`uri_does_not_exist`、`undefined_class`、`undefined_identifier`、`undefined_method`、`const_initialized_with_non_constant_value` 全部为**预期噪音**；项目自有类报错为 0，唯一非噪音项是 `prefetch_engine.dart` 的 `unused_import` warning（已作为 P3 问题记录）。
- 结论：过滤噪音后 9/9 文件项目自有类 0 错误；1 个真实 lint warning（unused import）。

### `lib/core/cache/cache_keys.dart`
```text
Analyzing cache_keys.dart...
No issues found!
```

### `lib/core/cache/cache_manager.dart`
```text
Analyzing cache_manager.dart...

  error - cache_manager.dart:3:8 - Target of URI doesn't exist: 'package:hive/hive.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - cache_manager.dart:17:3 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - cache_manager.dart:20:20 - Undefined name 'Hive'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - cache_manager.dart:143:3 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - cache_manager.dart:146:20 - Undefined name 'Hive'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier

5 issues found.
```

### `lib/core/cache/resource_gateway.dart`
```text
Analyzing resource_gateway.dart...
No issues found!
```

### `lib/core/prefetch/prefetch_engine.dart`
```text
Analyzing prefetch_engine.dart...

  error - prefetch_engine.dart:25:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - prefetch_engine.dart:124:7 - The method 'debugPrint' isn't defined for the type 'PrefetchEngine'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - prefetch_engine.dart:158:7 - The method 'debugPrint' isn't defined for the type 'PrefetchEngine'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - prefetch_engine.dart:171:7 - The method 'debugPrint' isn't defined for the type 'PrefetchEngine'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - prefetch_engine.dart:178:7 - The method 'debugPrint' isn't defined for the type 'PrefetchEngine'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - prefetch_engine.dart:192:7 - The method 'debugPrint' isn't defined for the type 'PrefetchEngine'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
warning - prefetch_engine.dart:23:8 - Unused import: '../net/music_api.dart'. Try removing the import directive. - unused_import

7 issues found.
```

### `lib/core/resource/cached_api.dart`
```text
Analyzing cached_api.dart...

  error - cached_api.dart:76:41 - The argument type 'String Function(Object)' can't be assigned to the parameter type 'dynamic Function(dynamic)'.  - argument_type_not_assignable

1 issue found.
```

### `lib/core/resource/lyric_translation_stream.dart`
```text
Analyzing lyric_translation_stream.dart...
No issues found!
```

### `lib/core/resource/resource_cache.dart`
```text
Analyzing resource_cache.dart...

  error - resource_cache.dart:5:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - resource_cache.dart:6:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - resource_cache.dart:7:8 - Target of URI doesn't exist: 'package:hive/hive.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - resource_cache.dart:40:3 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - resource_cache.dart:46:14 - Undefined name 'Hive'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - resource_cache.dart:47:13 - Undefined name 'Hive'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - resource_cache.dart:48:19 - Undefined name 'Hive'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - resource_cache.dart:50:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:55:3 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - resource_cache.dart:96:5 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - resource_cache.dart:113:11 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:121:9 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:139:44 - Undefined class 'Box'. Try changing the name to the name of an existing class, or creating a class with the name 'Box'. - undefined_class
  error - resource_cache.dart:201:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:213:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:225:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:245:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:258:19 - The method 'Dio' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'Dio'. - undefined_method
  error - resource_cache.dart:258:23 - The method 'BaseOptions' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'BaseOptions'. - undefined_method
  error - resource_cache.dart:268:9 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:275:9 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:281:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - resource_cache.dart:284:7 - The method 'debugPrint' isn't defined for the type 'ResourceCache'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method

23 issues found.
```

### `lib/core/storage/secure_storage.dart`
```text
Analyzing secure_storage.dart...

  error - secure_storage.dart:1:8 - Target of URI doesn't exist: 'package:flutter_secure_storage/flutter_secure_storage.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - secure_storage.dart:7:27 - Const variables must be initialized with a constant value. Try changing the initializer to be a constant expression. - const_initialized_with_non_constant_value
  error - secure_storage.dart:7:27 - The method 'FlutterSecureStorage' isn't defined for the type 'SecureStorage'. Try correcting the name to the name of an existing method, or defining a method named 'FlutterSecureStorage'. - undefined_method
  error - secure_storage.dart:8:15 - The method 'AndroidOptions' isn't defined for the type 'SecureStorage'. Try correcting the name to the name of an existing method, or defining a method named 'AndroidOptions'. - undefined_method

4 issues found.
```

### `lib/core/storage/storage_permission.dart`
```text
Analyzing storage_permission.dart...

  error - storage_permission.dart:3:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - storage_permission.dart:4:8 - Target of URI doesn't exist: 'package:flutter/services.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - storage_permission.dart:5:8 - Target of URI doesn't exist: 'package:permission_handler/permission_handler.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - storage_permission.dart:67:20 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:70:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:82:28 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:85:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:91:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:117:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:125:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:133:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:157:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:166:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:171:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:190:16 - Undefined class 'MethodChannel'. Try changing the name to the name of an existing class, or creating a class with the name 'MethodChannel'. - undefined_class
  error - storage_permission.dart:191:7 - Const variables must be initialized with a constant value. Try changing the initializer to be a constant expression. - const_initialized_with_non_constant_value
  error - storage_permission.dart:191:7 - The method 'MethodChannel' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'MethodChannel'. - undefined_method
  error - storage_permission.dart:203:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:243:11 - Undefined class 'PermissionStatus'. Try changing the name to the name of an existing class, or creating a class with the name 'PermissionStatus'. - undefined_class
  error - storage_permission.dart:245:22 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:248:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:255:15 - The method 'openAppSettings' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'openAppSettings'. - undefined_method
  error - storage_permission.dart:258:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:263:26 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:274:11 - Undefined class 'PermissionStatus'. Try changing the name to the name of an existing class, or creating a class with the name 'PermissionStatus'. - undefined_class
  error - storage_permission.dart:276:22 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:279:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:286:15 - The method 'openAppSettings' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'openAppSettings'. - undefined_method
  error - storage_permission.dart:288:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:293:26 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:316:26 - Undefined name 'Permission'. Try correcting the name to one that is defined, or defining the name. - undefined_identifier
  error - storage_permission.dart:328:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:345:9 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - storage_permission.dart:350:7 - The method 'debugPrint' isn't defined for the type 'StoragePermissionService'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method

34 issues found.
```

---

## 问题清单（按级别排序，共 62 条：P0 2 / P1 22 / P2 30 / P3 8）

### P0（2 条）
1. `secure_storage.dart:26-42` `saveCredentials` 5 个写/删并发提交，`Future.wait` 无事务/回滚/世代锁 —— 切号串号、凭证持久损坏（第 5/18/21/9 条）。
2. `resource_cache.dart:69-91` `_inFlight` 查表/清理用 `fullKey`、写入用调用方 `key`，并发合并完全失效且每个请求永久泄漏一个 Future —— 重复请求回归 + 内存无界增长（第 19/18/22/23 条）—— **任务书特别核对①，当前磁盘状态**。

### P1（22 条）
1. `cache_manager.dart:19-21 / 145-147` 两个 `init()` 的 `openBox` 无并发合并、无失败处理（第 22/18/6 条）。
2. `cache_manager.dart:42-49` JSON 形态只验最外层 `is Map`，畸形体不清理、可抛类型错误（第 13/14 条）。
3. `cache_manager.dart:81-84` `MemoryCache.get<T>` 的 `as T?` 裸强转抛 TypeError（第 13/10/8 条）。
4. `cache_manager.dart:154-175` 翻译缓存文本无转义，`int.parse` 未捕获、坏行静默丢弃（第 14/13/9 条）。
5. `resource_gateway.dart:47-58` L1 命中后完全绕过 L2 TTL/in-flight/失效回退，旧值无过期退出条件（第 18/11/23/8 条）。
6. `resource_gateway.dart:75-83` `onUserChanged()` 用 `unawaited` 全量清箱，异常无人接管、切号竞态无世代校验（第 6/9/18/20 条）。
7. `resource_cache.dart:86-91` `finally` 无条件 `remove`、不校验持有者身份（第 19/18 条）。
8. `resource_cache.dart:101-136` `catch (e)` 全捕获后 stale 降级，`staleOnError` 由首个调用方决定（第 10/7/11/8 条）—— **失效回退异常契约**。
9. `resource_cache.dart:244-291` `cacheUrlFile` 早退分支不清 `.part`、清理不对称（第 20/14/6 条）—— **任务书特别核对③**。
10. `resource_cache.dart:239-293` `cacheUrlFile` 无 in-flight/并发上限/取消令牌，同路径并发写可产生损坏正式文件（第 22/25/20/18 条）。
11. `resource_cache.dart:196-229` `putFile`/`file`/`filePath` 的身份维度与 `cacheUrlFile` 不兼容、写非原子（第 23/3/31 条）。
12. `resource_cache.dart:297-331` 永久文件层无任何清理入口与容量上限（第 25/31/32 条）。
13. `cached_api.dart:21-65` `ttl` 参数被静默丢弃，除 90s 外任何值都按 168h 生效（第 3/15/31 条）。
14. `cached_api.dart:72-80` `bodyIdentity` 全文进缓存键、无转义无长度上限，不同 POST body 可同键（第 23/14/25/3 条）。
15. `lyric_translation_stream.dart:17-34` 单例 `dispose()` 后控制器不可重建、补丁静默丢弃（第 20/18 条）。
16. `lyric_translation_stream.dart:28-31` 补丁契约无切歌世代，`emit` 不校验 lyricId/startIndex（第 18/23 条）。
17. `prefetch_engine.dart:117-127 / 155-194 / 204-210` dispose 后三个 `await` 之间无 `_disposed` 门禁、在途请求继续以旧客户端写缓存（第 18/20/22/31 条）—— **任务书特别核对④**。
18. `prefetch_engine.dart:40 / 72-85 / 92-110` `_requested` 无上限、不随失败/失效回收，切号/换音质后预热永久跳过（第 25/11/23 条）。
19. `secure_storage.dart:45-66` `readCredentials` 只判 null，空串即登录态；平台异常未包装（第 14/16/8 条）。
20. `storage_permission.dart:151-176` `resolveRoot()` 探测失败仍返回该路径、最终兜底零探测（第 11/14/9 条）。
21. `storage_permission.dart:218-225 / 271-273` 版本名→API 映射在 Android 13+ 少 1，导致通知权限不申请（第 17/15/28/31 条）。
22. `storage_permission.dart:301-320` `resolveStrategy()` 只看授权态，与 `resolveRoot()` 的实测降级口径冲突（第 5/11/31 条）。

### P2（30 条）
1. `cache_keys.dart:31-41` 键字段未转义分隔符、键非单射（第 23 条）。
2. `cache_manager.dart:35-49` 缓存体解析 `catch (_)` 空体式降级、删坏数据不留痕（第 9/7/11 条）。
3. `cache_manager.dart:124-131` `MemoryCache.keyOf` 绕开唯一键源自行拼键（第 23/5/31 条）。
4. `cache_manager.dart:52-70 / 168-180` 两个 Hive 盒无条目/体积上限、过期不淘汰（第 25 条）。
5. `cache_manager.dart:19-21 / 145-147` 关箱后 `_box!` 无世代校验、无对称 close（第 18/20 条）。
6. `resource_gateway.dart:18-25` L1 内存 Map 无容量上限、无 TTL（第 25 条）。
7. `resource_gateway.dart:47-48 / 54-58` L1 与调用方共享同一可变 Map，`__stale` 只查顶层字段（第 22/13/5 条）。
8. `resource_gateway.dart:20-25 / 66-70` 门面不强制 L1 键形态，`invalidateNs` 可漏清（第 23/3/5 条）。
9. `resource_gateway.dart:28-58` `json()` 允许 `CacheScope.file` 把 36500 天 TTL 写进 L2（第 3/23 条）。
10. `resource_gateway.dart:61-64` `file()` 默认 `declaredBytes = 0` 与身份契约冲突（第 23/3 条）。
11. `resource_cache.dart:73-74 / 116 / 132` 合并调用方共享同一可变 Map 与同一异常对象（第 22/8/18 条）。
12. `resource_cache.dart:122-132` `unawaited(ErrorLogger.log)` 失败无人接管（第 9/6 条）。
13. `resource_cache.dart:140-156` 形态错误体只读不删、`delete` 未 await、无日志（第 13/14/9/6/8 条）。
14. `resource_cache.dart:175-193 / 264-280` 身份只校验长度，FNV-32 无碰撞处理、suffix 未做字符白名单（第 14/23 条）。
15. `resource_cache.dart:43-55` `init()` 吞开箱异常、无并发合并、失败不记账（第 22/5/11 条）。
16. `resource_cache.dart:297-319` 失效只处理 String 键，且被在途 `_doFetch` 回灌（第 18/25/23 条）—— **写后失效维度**。
17. `cached_api.dart:19 / 32-40` 键只含 userid，缺 token/音质/语言/区域维度（第 23/18 条）。
18. `cached_api.dart:21-65` `stale` 在 L1 命中/合并路径失效，本类不消费 `__stale`（第 8/9/11 条）。
19. `prefetch_engine.dart:76-84` 上限算术在 `_pending.length > 60` 时提前 break（第 25/11 条）。
20. `prefetch_engine.dart:117-127` `onPlaybackCompleted` 的 `catchError` 接不住 `return null` 路径、无门禁、不等待（第 9/20/1 条）。
21. `prefetch_engine.dart:63-65` `attach()` 不判 `_disposed`，可造出僵死单例（第 18/20/31 条）。
22. `prefetch_engine.dart:130-134 / 137-148` Timer 每次重建、spacing 被覆盖、在途请求无并发上限（第 20/25/3 条）。
23. `prefetch_engine.dart:17-19 / 62-65 / 161-190` `ns:'prefetch'` 与 repository 不同键、预热只覆盖 kapi 路径（第 28/29/31/23 条）。
24. `prefetch_engine.dart:161-193` 三个 `catch (e)` 全捕获、仅 debugPrint、失败不回滚（第 7/9/8 条）。
25. `secure_storage.dart:65-87` B-11 与 F-1 两段注释结论相反，dfid 两个入口一删一留（第 31/20/9 条）。
26. `secure_storage.dart:89-108` 账号 token 键拼接无校验、四处重复拼接（第 14/23/5 条）。
27. `storage_permission.dart:109-140 / 99` 探针早退不清理、`lastProbeError` 全局并发共享、内层 `catch (_) {}` 空体（第 20/22/5/6 条）。
28. `storage_permission.dart:263 / 293 / 316` `request()` 与 `currentStrategy()` 裸平台调用，异常契约不一致（第 8/6/9 条）。
29. `storage_permission.dart:196-215 / 182-188` `apiLevel()` 缓存无失效/并发合并、`resolveRootMode()` 重复磁盘探测（第 22/18/24 条）。
30. `storage_permission.dart:48-54` `subDirOf` 未知类型静默落 audio（第 16/23/9 条）。

### P3（8 条）
1. `cache_keys.dart:47` `fileIdentity` 注释声明 bytes<=0 语义但函数无对应行为（第 31 条）。
2. `cache_manager.dart:90-97` 覆写已有键也先淘汰一条无关条目（第 25 条）。
3. `cached_api.dart:5-12` 「唯一读实现/唯一事实源」注释与实际多处拼键不符（第 31/5 条）。
4. `lyric_translation_stream.dart:11-15 / 26-32` 「缓存命中也 emit 一次」在本类无实现（第 31/9 条）。
5. `resource_cache.dart:13-14 / 66-73` TTL 表与 `cache_keys.dart:16-20` 重复、靠值相等隐式耦合（第 5/31 条）。
6. `storage_permission.dart:32-38 / 56-59` 根目录常量两种大小写，授权前后落进两个目录（第 5/31 条）。
7. `prefetch_engine.dart:23` `unused_import: '../net/music_api.dart'`（analyze 实锤，第 32/31 条）。
8. `cache_keys.dart:45 / 47-48`、`resource_cache.dart:15` `cacheNsPrefix` / `fileIdentity` / `kFilePermanent` 无调用点（第 32/5/25 条）。


---

## 复核通过项（本范围确认到位的设计）

1. **stale 副本未污染箱内原值**：`resource_cache.dart:132` 用 `Map<String, dynamic>.from(staleBody)..['__stale'] = true` 生成**副本**，箱内只存 JSON 字符串且 `put` 仅在 `fetch` 成功分支执行；`staleBody` 来自 `_readStored` 的 `jsonDecode` 新对象，`__stale` 不会回写。（嵌套 Map/List 仍浅拷贝共享，见 P2 条 11。）
2. **无旧值时的异常不被吞**：`resource_cache.dart:134` `rethrow`，且 `json()` 的 `finally` 只清 `_inFlight`，未把失败替换为降级值（第 6 条主路径成立）。
3. **`cacheUrlFile` 的核心身份四道校验确实存在**：`declaredBytes <= 0` 拒绝、HEAD 的 `Content-Length` 预检、下载后 `actual != declaredBytes` 校验并删 `.part`、复用前 `target.length() == declaredBytes` 校验；成功后 `await part.rename(target.path)` 为原子换名（第 14/23 条主路径成立）。
4. **写失败不掩盖成功结果**：`resource_cache.dart:103-115` 的 `box.put` 单独 try/catch 留 `debugPrint`，`fetch` 成功值照常返回（第 6/9 条）。
5. **`MemoryCache` 有明确容量上限与 FIFO 淘汰**：`cache_manager.dart:99-112` 的 `_maxEntries = 200`，先清过期再按插入序淘汰（第 25 条）。
6. **`cacheUrlFile` 失败整体收敛为 null + debugPrint**：`resource_cache.dart:283-291` 外层 catch 记录异常并返回 null，不让下载异常冒泡打崩播放完成 hook（第 9 条主路径）。
7. **`ResourceCache.init()` 检查 `_box!.isOpen` / `Hive.isBoxOpen`**、并有 `_safeBox` getter 与 `box == null` 早退（`resource_cache.dart:43-55 / 296-330`），比 `cache_manager.dart` 的开箱/关箱路径更完整（第 20 条局部成立）。
8. **`PrefetchEngine` 的 Timer 对称释放与入口门禁齐备**：`_disposeTimer()` 在 `_drainOne` 队列空与 `dispose()` 两处调用，5 个入口（3 个公开 + 2 个私有）均有 `if (_disposed) return;`，`_prefetchOne` 三个 try/catch 保证 Future 不以 error 完成（第 20/6 条入口层成立）。
9. **`StoragePermissionService` 的平台通道调用多数有留痕**：`publicDir`、`isPublicDirWritable`、`apiLevel`、`resolveRoot` 的通道异常均 `debugPrint` + `lastProbeError`，注释明确禁止 `_probeWritable` 经 ErrorLogger 落盘以避免递归链（第 9/22 条局部成立）。
10. **`LyricTranslationStream.emit` 在 controller 已关闭时先检查 `isClosed`**，`dispose()` 显式暴露 `_controller.close()`（第 20 条局部成立）。
11. **`CachedApiCall` 的键确实经 `cacheKey` 生成并拼入 userid、ns、排序 query、schemaVer，POST 补 body 摘要**，缓存键不直接存放 token/正文（第 23 条局部成立）。
12. **`ResourceGateway.json` 统一用 `cacheKey` + `cacheTtl(scope)` 生成键与 TTL**，L2/L3 门面分工清晰，`clearTransient()` 明确不动永久文件（第 5 条局部成立）。
13. **本范围 9 个文件的相对 import 目标全部存在**（仅核对路径有效性）：`../net/music_api.dart`、`../api/kugou_api_client.dart`、`../domain/song.dart`、`../config/app_config.dart`、`../utils/error_logger.dart`、`../storage/storage_permission.dart`、`../cache/cache_keys.dart`、`../resource/resource_cache.dart`、`../resource/cached_api.dart` 均在磁盘上。
14. **9/9 文件 `dart analyze` 过滤三方包噪音后项目自有类 0 错误**（详见下方逐文件结果）。


---

*报告结束：只读审查，未修改任何代码文件；未执行构建 / 测试 / pub get / Flutter 命令。*
