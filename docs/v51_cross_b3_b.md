# v5.1 交叉审查 B3 · 视角 B（鲁棒与代码质量）

- 范围：`lib/core/cache/**`、`lib/core/resource/**`、`lib/core/prefetch/**`、`lib/core/storage/**`（9 个 .dart 文件 / 1444 行）
- 判据：`docs/QUALITY_STANDARD.md` 32 条（任务书重点第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条），冲突时以 QUALITY_STANDARD 为准。
- 工作方式：逐文件 `file_read` 完整读、读完即落盘；只读源码，不改代码；末尾问题清单 + 复核通过项 + 逐文件 `dart analyze`。
- 特别核对：`ResourceCache.json` 的 `_inFlight` 键维度、stale 副本是否污染箱内原值、`cacheUrlFile` 失败路径半截文件、`PrefetchEngine.dispose` 后回调门禁。

---

## 1. `lib/core/cache/cache_keys.dart`（48 行，完整读）

### cache_keys.dart:31-39 缓存键的各字段未转义分隔符，不同请求可生成同一个键
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
- 证据等级：静态推演（调用方是否补做校验在后续文件核对）

---

## 2. `lib/core/cache/cache_manager.dart`（181 行，完整读）

### cache_manager.dart:19-21 / 137-139 三处 `init()` 的 `openBox` 无并发合并、无失败处理
- 级别：P1
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明并保护）、第 18 条（异步结果校验世代）、第 6 条（禁止吞掉异常/失败可观测）
- 依据：`Future<void> init() async { _box ??= await Hive.openBox<String>(boxName); }`（`LyricPersistentCache` 与 `LyricTranslationCache` 各一份，后者为 `Hive.openBox<String>('lyric_translations')`），三个类的 `init()` 都是「判空 → await 开箱」，未缓存 in-flight `Future`、未使用 `Hive.isBoxOpen`、未加互斥；`getWithStale/set/clear/get` 每个入口都先 `await init()`。同一时刻（例如启动期歌词预取与歌词翻译流同时到达）两个调用都可在 `_box == null` 时各自发起 `Hive.openBox`；开箱若因盒被其它类型打开、盒文件损坏、`Hive.close()` 后重开而抛错，`_box` 保持 `null`，异常直接冒泡且此处无日志，后续所有读写反复重试开箱。对比本范围 `ResourceCache` 里另有一套独立的开箱路径，开箱事实来源不唯一（第 5 条）。
- 影响：开箱竞态或开箱失败时歌词/翻译缓存读写整体抛异常，歌词页与翻译功能显示失败；盒损坏时不会自愈，重启前该缓存持续不可用，且线上日志无本层记录可查。
- 证据等级：静态推演（并发时序与异常传播由本文件控制流确认；Hive 内部对同名 `openBox` 是否去重不依赖，代码自身无任何保护）

### cache_manager.dart:38-48 缓存体解析的 `catch (_)` 为空体式降级，删除坏数据不留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 7 条（捕获必须精确到可处理的类型）、第 11 条（降级触发/退出条件）
- 依据：`try { decoded = jsonDecode(raw); } catch (_) { // 缓存体损坏等同未命中 ...; await _box!.delete(...); return (null, null); }`。`catch (_)` 捕获一切对象；块内只有 `delete` 和 `return`，无日志、无计数、无返回值区分「未命中」与「体损坏」，注释自称「降级可观测，第 9/16 条」（文件头 6-7 行）但代码没有任何可观测手段。注释所述「缓存体损坏等同未命中」只是本层约定，调用方拿到的 `(null,null)` 与真正无缓存完全相同。另 `await _box!.delete(...)` 本身抛错时会从 catch 块向外冒出与「未命中」不同的异常形态（第 8 条同一层异常形态不一致）。
- 影响：盒文件被写坏时缓存被静默清空，用户只看到歌词重新走网络（网络失败即歌词缺失），排查时无日志可判断是缓存损坏还是真的未命中；若删除失败则退化为未捕获异常。
- 证据等级：实锤（本文件内 `catch` 块与返回值形态可直接确认）

### cache_manager.dart:49-55 JSON 形态只验最外层 `is Map`，畸形体不清理且可能抛类型错误
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

### cache_manager.dart:146-155 翻译缓存的持久化文本无校验、无转义，`int.parse` 可抛未捕获异常
- 级别：P1
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 13 条（外部数据禁止裸类型强转）、第 9 条（失败必须可观测）
- 依据：`set` 用 `translations.entries.map((e) => '${e.key}\t${e.value}').join('\n')` 原样写入，未转义译文中的 `\t`/`\n`；`get` 用 `for (final line in raw.split('\n'))`，`if (idx > 0) { map[int.parse(line.substring(0, idx))] = line.substring(idx + 1); }`。`int.parse` 无 `onError`/try-catch：箱内任一行的行号段非纯数字（盒损坏、旧格式、译文自带换行导致的错位）即抛 `FormatException`，直接冒泡出缓存读取路径；无 tab 的行被**静默跳过**（`idx > 0` 为假），既不记录也不返回部分/失败区分，返回的是一份静默缺失若干行的 `Map<int,String>`（第 16 条空集合与缺失语义混淆）。
- 影响：盒内容异常时歌词翻译页报错，或用户看到译文逐行缺失、行号错位且无任何提示；因为写入侧允许译文含换行，这种损坏可由正常内容触发而非仅外部破坏。
- 证据等级：实锤（`set` 的拼接与 `get` 的解析/抛异常点在同一文件内成对确认）

### cache_manager.dart:57-69 / 157-168 两个 Hive 盒无条目数/体积上限，且过期条目从不淘汰
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）
- 依据：`LyricPersistentCache.set` 只 `put`，`getWithStale` 对 stale 值只读不删，唯一的删除是「JSON 解析失败」那一条，`clear()` 只能整箱清空；`LyricTranslationCache.set` 同样只 `put`，`get` 无 TTL 概念（根本没有 `storedAt`），`clear()` 整箱清空。两处都没有条目数上限、体积上限、LRU/FIFO、按 `storedAt` 的过期扫描；而 `cache_keys.dart` 声明 `CacheScope.file` 为「永久（不淘汰，仅失效回退）」。对比同文件 `MemoryCache._maxEntries = 200` 有明确容量上限（复核通过项）。
- 影响：长期使用后每首听过的歌/每种目标语言都在磁盘留下永久条目且永不回收，低端机存储与开箱加载时间持续增长；`storedAt` 已过期 7 天的歌词本体仍永久占盘并每次被当作 stale 候选。
- 证据等级：实锤（本文件内所有写入/删除/淘汰路径完整枚举）

### cache_manager.dart:19-21 / 137-139 `Hive.close()` 或外部关箱后 `_box!` 断言无世代校验
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

## 3. `lib/core/cache/resource_gateway.dart`（74 行，完整读）

### resource_gateway.dart:13-21 L1 内存缓存无容量上限、无 TTL、无淘汰
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）
- 依据：`final Map<String, Object> _memory = <String, Object>{};`，`void memoryPut(String key, Object value) => _memory[key] = value;`，除 `onUserChanged()` / `clearTransient()` / `invalidateNs()` 里的人工清理外，没有任何 `_maxEntries`、`expires`、LRU/FIFO 或体积限制；`memoryGet<T extends Object>` 也不判断时效。与同范围 `MemoryCache._maxEntries = 200` 形成两套互不相干的内存缓存实现，注释（文件头 3-4 行）称「旧四套类不再是消费方直接依赖；所有缓存读写与失效经此门面」，但本门面自身 L1 是又一套新实现（第 5 条状态/实现不单一）。
- 影响：长时间浏览（首页/歌单/详情页反复写入不同 key）内存单调增长，低端机出现卡顿甚至 OOM 被系统杀进程，用户表现为应用闪退回到桌面；清理设置页不点就永不回收。
- 证据等级：实锤（本类全部写入/删除路径在本文件内枚举完毕）

### resource_gateway.dart:18-21 / 53-56 门面不强制 L1 键由 `cacheKey` 生成，按 ns 失效可漏清
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 3 条（契约先行）、第 5 条（状态单一来源）
- 依据：`memoryPut(String key, Object value)` 接受任意裸字符串（对比 `json()` 内部才调用 `cacheKey(...)`），无用户/scope/ns/schema 维度；`invalidateNs` 用 `_memory.removeWhere((k, _) => k.contains(':$ns:u='))` 依赖调用方自觉拼出含 `:$ns:u=` 的键。只要调用方传的是 `path`、`url` 或 `MemoryCache.keyOf` 产物，该前缀判断为假，失效静默落空。文件头注释「所有缓存读写与失效经此门面」与「按 ns 精确失效」都依赖未在签名/类型上强制的约定。
- 影响：写操作（收藏/删除/编辑）后按 ns 失效仍读到旧内存值，用户看到「操作后列表不变」，需要重启或手动清缓存才恢复。
- 证据等级：静态推演（本门面不校验键形态为实锤；具体调用方传何种键不在本范围）

### resource_gateway.dart:57-61 `onUserChanged()` 只清内存，`clearTransient()` 不清永久文件与用户维度
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代/账号切换后旧数据失效）、第 23 条（缓存键维度）与第 31 条（注释与行为一致）
- 依据：`void onUserChanged() { _memory.clear(); }` 是同步方法，完全不触碰 `ResourceCache.instance` 的磁盘盒；注释写「切号/登出：用户维度整体失效（缓存键含 u=，旧账号数据不再命中）」，实际只是靠 `u=` 前缀让新账号不命中，旧账号的 L2 数据仍留在箱内，且**切回原账号时立刻命中切换前的旧数据**（无失效时间戳、无切号世代）。同理 `clearTransient()` 的注释「只清 JSON/列表与内存，**永久文件不动**」与实现一致，但 `clearJson()`/`clearLists()` 的具体清理范围需与 `ResourceCache` 核对；`onUserChanged()` 也没有对应的 `clearLists()`（列表作用域另有独立清理）。
- 影响：A→B→A 切号后，A 账号看到的是切号前的旧歌单/旧数据，且没有任何提示；用户可能在此基础上做出错误操作（如以为收藏未生效而重复收藏）。
- 证据等级：静态推演（切号世代/持久化清理路径在本文件内确认；`ResourceCache.clearJson` 行为在后续文件核对）

### resource_gateway.dart:29-45 `json()` 允许传入 `CacheScope.file`，把 36500 天 TTL 写进 L2 JSON 层
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围必须明确）、第 23 条（scope 决定层级与 TTL 的维度一致性）
- 依据：`CacheScope scope = CacheScope.json` 是公开参数且无断言/分支限制；`final key = cacheKey(... scope: scope ...)` 与 `ttl: cacheTtl(scope)` 直接透传，`ResourceCache.instance.json(...)` 是唯一的落盘目标（注释称「L2 磁盘 JSON：统一的 168h / 90s 语义」）。若调用方传 `CacheScope.file`，键被分到 `file:` 作用域而 TTL 为 36500 天，却仍写进 JSON 盒；传 `CacheScope.list` 则 90 秒 TTL + json 盒。签名承诺的 scope 语义（cache_keys.dart 第 9 行「scope：json / list / file，决定层级与 TTL」）与门面实际「只有一层」不一致。
- 影响：一次误传 scope 会让本应短期有效的数据在磁盘上近乎永久不刷新，用户长期看到过期结果；反之 list 作用域数据 90 秒后失效，造成额外请求。
- 证据等级：静态推演（参数与透传路径在本文件内确认；实际调用方是否误传不在本范围）

### resource_gateway.dart:47-49 `file()` 默认 `declaredBytes = 0` 与「bytes<=0 视为身份不可判定」的契约冲突
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键/文件身份必须覆盖全部影响结果的维度）、第 3 条（输入取值范围）
- 依据：`Future<String?> file(String url, String kind, {int declaredBytes = 0}) => ResourceCache.instance.cacheUrlFile(url, kind, declaredBytes: declaredBytes);`。`cache_keys.dart:47` 的注释约定 `bytes<=0 视为身份不可判定`，而门面把 0 作为默认值并无条件向下透传，未在此处拒绝、未要求调用方显式提供、也未声明"0 = 不校验"的语义。`kind` 与 `url` 也不经 `cacheKey`/`fileIdentity` 生成而是原样交给下层。
- 影响：调用方省略 `declaredBytes`（最易用路径）时，文件身份退化为仅 URL，服务端同一 URL 返回不同长度/不同版本内容时可能复用错版文件，用户听到截断/错版音频或看到损坏封面。
- 证据等级：静态推演（门面透传为实锤；`cacheUrlFile` 对 0 的实际处理在 `resource_cache.dart` 核对）

---

## 4. `lib/core/resource/resource_cache.dart`（331 行，完整读）

### resource_cache.dart:69-91 `_inFlight` 以调用方 `key` 分键，而箱内值以 `fullKey` 分键；不同 TTL 的调用共享同一 Future 且结果只写入首个调用方的 fullKey
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 22 条（并发假设必须写明并保护）、第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`final pending = _inFlight[key]; if (pending != null) return pending;`、`final isList = ttl == kListTtl; final fullKey = '${isList ? _listPrefix : _jsonPrefix}$key';`、`_inFlight[key] = fut;`。映射表的键是**未经 scope/TTL 修饰的调用方 `key`**，而 `_readStored(box, fullKey)` 与 `box.put(fullKey, ...)` 用的是带 `json:`/`list:` 前缀的 `fullKey`。因此两个以同一 `key` 但不同 `ttl` 调用 `json()` 的调用方（例如 `kJsonTtl` 与 `kListTtl`，或任意自定义 TTL）会被合并成同一个 `fut`：第二个调用方直接 `return pending`，既不执行自己的 `await init()`/`_readStored`/freshness 判定，也不会把自己的 `fullKey` 写进箱；`fetch` 闭包、`staleOnError`、`staleBody` 全部取自第一个调用方。类注释第 22-24 行宣称「同 key 并发只发一个 fetch」，但 key 与箱内键的维度不同，注释未声明「ttl/scope 相同」这一并发前提。
- 影响：请求「90 秒短 TTL」的调用方会拿到按 168h 语义发起的另一次请求结果，且其 list 层缓存永远得不到写入，之后每次仍重新发网络；请求 `ttl=0`（强制新鲜）的调用方会拿到已在进行中、按旧参数构造的请求结果，界面展示与本次请求不符且无世代校验。
- 证据等级：静态推演（键的拼接与早退分支在本文件内成对确认；具体调用方是否传入不同 ttl 在 `cached_api.dart` 核对）

### resource_cache.dart:86-90 `finally` 无条件 `remove`、不校验自己是否仍是持有者
- 级别：P1
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门必须成对且关闸时判断「我是否仍是当前持有者」）、第 18 条（异步结果必须校验世代）
- 依据：`_inFlight[key] = fut; try { return await fut; } finally { _inFlight.remove(key); }`，`remove` 前没有 `if (identical(_inFlight[key], fut))` 之类的身份判断。`_doFetch` 完成后，`await fut` 的每个等待者以及后续新调用都在同一事件循环里被调度；一个在 `fut` 已完成、但首个调用方的 `finally` 尚未执行的窗口内进入的新调用，`pending` 仍非 null，会 `return pending` 拿到**已经结束（可能是失败）的旧 Future**，即一次全新请求被绑定到上一世代的异常/结果。若此时另一路已经用同一 `key` 放入了新的 `fut`（如未来改动或重入），无条件 `remove` 还会把后来者的 in-flight 提前清掉，使真正的并发同时发出两个 fetch。
- 影响：切歌/切页后一次新请求可能直接抛上一次请求的错误，或复用上一世代的旧数据；并发合并偶发失效导致同一资源重复请求。
- 证据等级：静态推演（Dart 事件循环下 `await` + `finally` 的调度窗口为语言语义；代码无身份判断为实锤）

### resource_cache.dart:68-70 合并后的调用方共享同一个可变 `Map` 实例，异常对象也原样共享
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 8 条（异常契约必须单一且稳定）、第 18 条（世代校验）
- 依据：`final _inFlight = <String, Future<Map<String, dynamic>>>{};` 与 `if (pending != null) return pending;`。`_doFetch` 的 `return data;` 与回退分支的 `return Map<String, dynamic>.from(staleBody)..['__stale'] = true;` 都只产生**一个对象**，所有等待者拿到同一引用；`Future` 完成时携带的异常对象与栈也是同一个。代码没有对合并调用方说明「返回值共享、不可变更」的契约，也没有按等待者复制。任一消费方对返回 Map（含 `['__stale']`、`body` 字段）做原地增删，其它调用方立即看到被污染的结果。异常路径同样：`rethrow` 在 `_doFetch` 内产生的栈是首个调用方的 `fetch` 栈，后加入的调用方拿到的是与自己调用栈无关的异常。
- 影响：两个页面合并到同一次请求时，一处对结果做加工会让另一处显示错字段；失败时后加入的调用方拿到别的请求的异常与日志栈，线上无法定位本次失败。
- 证据等级：静态推演（返回值共享为 Dart Future 语义 + 本文件代码事实）

### resource_cache.dart:100-129 `catch (e)` 捕获一切异常后进入 stale 降级，违反「编程错误绝不进入业务降级」，且 `staleOnError` 由首个调用方决定
- 级别：P1
- 违反：QUALITY_STANDARD 第 10 条（编程错误绝不进入业务降级）、第 7 条（捕获必须精确到可处理的类型）、第 11 条（降级必须有明确的触发条件与退出条件）、第 8 条（回退路径与主路径异常形态一致）
- 依据：`try { final data = await fetch(); ... } catch (e) { if (staleOnError && staleBody != null) { ... return Map<String, dynamic>.from(staleBody)..['__stale'] = true; } rethrow; }`。`catch (e)` 无 `on` 类型限定：`fetch()` 内部出现的 `TypeError`、越界、`NoSuchMethodError`、乃至调用方主动取消（`DioException` cancel）全部被当作「网络失败」并返回旧值，实现缺陷被静默掩盖。`staleBody` 与 `staleOnError` 是 `_doFetch` 创建时从**首个调用方**捕获的，后续合并进来的调用方即使传 `staleOnError: false`（要求严格失败），也拿不到 `rethrow`；反之首个为 false 时第二个为 true 的调用方会直接收到异常。类注释第 18-21 行写「fetch 失败 → 有旧值返回旧值副本；无旧值 → 原样 rethrow」并自称「禁止静默吞异常」，实际成功/失败都返回 `Map<String,dynamic>`，仅靠一个顶层 `__stale` 标记区分，异常形态在两路径间不一致。
- 影响：`fetch` 实现有 bug 时用户长期看到旧数据而缺陷永不暴露；登录失效/被取消等本应提示的错误被换成旧列表；不同页面对同一 key 的错误处理行为随机取决于谁是首个调用方。
- 证据等级：实锤（catch 范围、参数捕获点、返回形态在本文件内确认）

### resource_cache.dart:113-119 `unawaited(ErrorLogger.instance.log(...))` 的失败无人处理，回退留痕可能落空
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 6 条（禁止吞掉异常）
- 依据：`unawaited(ErrorLogger.instance.log('stale cache used for $fullKey', StackTrace.current, source: 'resource_cache', context: 'fetch failed: $e'));` 无 `.catchError`、无 try/catch。注释自称「回退本身即带用户可见留痕：经 ErrorLogger 落盘」，但 `debugPrint` 只在 Flutter debug 通道，ErrorLogger 的日志 Future 若失败则成为无人接管的异步错误，回退实际上既无用户反馈也无持久化日志。`ErrorLogger` 实现不在本范围内，无法核对其内部是否自吞异常（此处按「本文件不保证可观测」记）。
- 影响：网络失败后界面静默展示过期数据，用户无从得知，日志侧也可能查不到；`unawaited` 的异常还可能以未处理异步错误的形式扰动机智日志。
- 证据等级：静态推演（本文件无错误处理器为实锤；ErrorLogger 内部行为未实测、不在本范围）

### resource_cache.dart:134-148 形态错误的缓存体只读不删、删除 Future 未 await 且无日志
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）、第 9 条（失败必须可观测）、第 6 条
- 依据：`try { decoded = jsonDecode(raw); } catch (_) { box.delete(key); return null; }` 中 `box.delete(key)` 返回 `Future<void>` 但**未 await 也未 unawaited**，在同步函数 `_readStored` 里被直接丢弃；删除失败会成为无人处理的异步错误。其后 `if (decoded is! Map) return null;`、`if (storedAt is! int || body is! Map) return null;` 对「JSON 合法但结构不符」的坏值**不删除**，每次调用都重新解码一次坏数据。整段无 `debugPrint`/ErrorLogger，`catch (_)` 捕获一切对象。另 `final storedAt = decoded['storedAt'];` 未校验取值范围：`storedAt` 为极大值（设备时钟跳变写入、盒被其它版本写入）时 `now < storedAt + ttl.inMilliseconds` 长期为真，该键永久「新鲜」不再刷新；`Map<String, dynamic>.from(body)` 未逐字段验证嵌套键/值形态。
- 影响：一次异常写入使该缓存键永久不可用（每次请求都白解码 + 走网络），或设备改过时间后用户长期看到旧数据且永不刷新；删除失败的异常无人可见。
- 证据等级：实锤（解析/删除/返回分支全部在本文件内）

### resource_cache.dart:235-247 `cacheUrlFile` 的早退分支不清 `.part`，失败清理不对称
- 级别：P1
- 违反：QUALITY_STANDARD 第 20 条（生命周期必须双向对称，申请的资源必须有对称释放点）、第 14 条（数据边界校验）、第 11 条（降级退出条件）
- 依据：清理 `.part` 只写在方法末尾的 `catch (e) { ... try { ... part.delete() } catch (_) {} ... }` 里。而以下路径从 `try` **中途 `return null`**，完全跳过清理：`if (cl > 0 && cl != declaredBytes) { ...; return null; }`（Content-Length 不符）以及 `if (await target.length() == declaredBytes) return target.path;` 之外的 `url.isEmpty` / `declaredBytes <= 0` 早退。若上一次中断留下同名 `.part`，本次因 HEAD 的 Content-Length 不符而「直接放弃」，该半截文件会永久留在磁盘；更关键的是 `if (await target.exists()) { if (length != declaredBytes) await target.delete(); }` 之后若 HEAD 不符而返回，半截 `.part` 与已删除的 target 同时存在。`dio.download(url, part.path)` 之前也没有先删除既有 `.part`，Dio 以同路径写入时若采用追加/既存流语义（未实测）会与残留字节混合。清理用的路径在 catch 里**重新计算** `_dirOf(kind)`（可能再次抛错）与 `_hashName(url, bytes: declaredBytes)`，且内层 `catch (_) {}` 是空体，删除失败被完全吞掉（第 6 条）。
- 影响：半截 `.part` 文件长期占盘且永久文件缓存无清理入口；后续同 URL 请求可能读到被污染/残留长度的文件，用户听到截断音频或看到损坏封面，且日志无清理失败记录。
- 证据等级：静态推演（早退分支与唯一清理点在本文件内成对确认；Dio 对既有 `.part` 的写入语义未实测）

### resource_cache.dart:224-276 `cacheUrlFile` 无 in-flight 合并、无下载并发上限、Dio 不可取消
- 级别：P1
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明并保护）、第 25 条（并发请求数必须有上限）、第 20 条（句柄必须对称释放）、第 18 条（异步结果校验世代）
- 依据：方法内没有 `_inFlight` 或任何按 `(url,declaredBytes)` 的互斥表，只有 `target`/`part` 两个由确定性文件名派生的路径。`final dio = Dio(BaseOptions(... receiveTimeout: const Duration(minutes: 10)));` 每次新建、无 `CancelToken`、无 `dio.close()`；`await dio.download(url, part.path)` 期间没有任何取消或世代判断。两个并发调用（例如快速切歌同一 URL、预取与播放同时触发）会对**同一个 `.part` 路径**同时写入，随后各自 `await part.length()`、`await part.rename(target.path)`：先 rename 者把文件移走，后者的 `rename` 抛错进 catch，catch 里还会去 `delete` 同名 `.part`（可能是另一路正在写的那个）。同时先完成者仅靠「长度 == declaredBytes」就 `rename`，内容可能是两路交错写入的损坏字节。`receiveTimeout: 10 分钟` 且无取消令牌，页面销毁后下载仍在后台跑满超时。
- 影响：同一资源并发下载时写入损坏文件并永久缓存，之后每次播放都命中这份坏文件（用户听到杂音/无法播放）；后台下载在退出页面后仍长驻并占用带宽与磁盘。
- 证据等级：静态推演（并发写同一路径、无互斥/取消/上限在本文件内实锤；损坏字节为时序推演，未实测）

### resource_cache.dart:243-269 文件身份只校验长度，未校验内容/签名；FNV-32 哈希无碰撞处理
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`static String _hashName(String url, {int bytes = 0})` 用 32 位 FNV-1a 混合 `'$url|$bytes'` 再加 `url.length`，文件名不含任何内容摘要；校验环节只有 `cl > 0 && cl != declaredBytes`、`await target.length() == declaredBytes`、`actual != declaredBytes`。注释第 216-221 行宣称「四道校验」「绝不互相覆盖/误复用」，但四道里没有一道验证内容字节；不同 URL 只要 FNV-32 碰撞且 `url.length` 与 `bytes` 相同（`suffix` 也相同）即共用一个 target。另 `cl` 为 0（chunked/无 Content-Length 头）时 `int.tryParse(...) ?? 0` 使长度预检整体跳过，仅靠下载后长度兜底。`ext = url.substring(url.indexOf('?'))` 后取 `lastIndexOf('.')` 得到 `suffix`，若 query 短且含 `/`、`?`、`=`、`&` 等字符，`suffix` 会原样进入文件名（例如 `?a=.b/c` → `.b/c`），产生带路径分隔符的目标路径，写入失败或落到非预期子目录；URL 是外部数据，此处未做任何字符白名单校验。
- 影响：CDN 返回错版/被替换但长度相同的文件会被当作正确资源永久复用；query 含特殊字符时缓存写入失败（用户看到资源反复下载）；哈希碰撞时两份不同资源互相覆盖。
- 证据等级：静态推演（校验条件与文件名构造在本文件内确认；碰撞/特殊字符未实测）

### resource_cache.dart:187-214 `putFile`/`file`/`filePath` 用 `_hashName(key)`（bytes 默认 0），与 `cacheUrlFile` 的身份维度不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 3 条（契约先行）、第 31 条（注释与行为一致）
- 依据：`putFile` 写 `File('${dir.path}/${_hashName(key)}')`、`file` 与 `filePath` 同样以 `_hashName(key)` 定位（默认 `bytes = 0`），而 `cacheUrlFile` 用 `_hashName(url, bytes: declaredBytes)` 且拒绝 `declaredBytes <= 0`。二者落在 `raw/` 目录，但同一个 URL 在两条路径下得到不同文件名，因此 `file(url)`/`filePath(url)` **永远找不到** `cacheUrlFile` 写入的文件；反过来 `putFile` 写入的文件也没有 declaredBytes 校验、没有原子 rename、直接 `f.writeAsBytes(bytes, flush: true)`，中途失败即留下半截正式文件，且后续 `file()` 不校验长度会直接读出半截内容。类注释第 26-27 行仍写「文件键由 URL 全文哈希 + kind 构成」，与实现（URL+bytes 哈希、kind 只是目录）不符。
- 影响：新旧两套字节缓存 API 互不兼容，一方写另一方读永远 miss；`putFile` 写入被中断后永久返回损坏字节给播放器，用户遇到播放失败/杂音且缓存不会自愈。
- 证据等级：实锤（两处文件名构造与拒绝条件在同一文件内成对确认；实际调用方配对关系在后续文件核对）

### resource_cache.dart:299-330 永久文件层没有任何清理入口，注释声称的「设置页 clear*」不存在
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 31 条（注释与行为一致）、第 32 条（死代码零容忍）
- 依据：文件头注释第 25-26 行写「永久不淘汰，淘汰交由设置页 clear*」、`cacheUrlFile` 注释写「永久缓存」，但本类提供的清理只有 `invalidateNs(String ns)`、`clearJson()`、`clearLists()`，三者都只操作 `_safeBox` 的 `json:`/`list:` 键，**没有任何删除 `<root>/cache/resource/**` 文件的方法，也没有条目数/总字节上限**；`ResourceGateway.clearTransient()` 明确注释「永久文件不动」。`const kFilePermanent = null;` 是声明为 `Null` 的占位常量，全类（含本范围其它文件，按已读文件核对）无任何引用；`cache_keys.dart:47` 的 `fileIdentity()` 同样未被本文件使用，本文件自行拼接 `'$url|$bytes'` 作为身份字符串。
- 影响：用户长期使用后音频/封面永久缓存单调增长且**无法通过设置页清除**，低端机磁盘被占满后下载与播放同时失败；占位常量与重复身份函数属残留死代码。
- 证据等级：实锤（本类全部公开方法在本文件内枚举完毕；`ResourceGateway.clearTransient` 已读确认）

### resource_cache.dart:39-57 `init()` 吞掉开箱异常且失败不记账，与 `cache_manager.dart` 存在两套开箱事实源
- 级别：P2
- 违反：QUALITY_STANDARD 第 22 条（并发假设必须写明）、第 5 条（状态单一来源）、第 11 条（降级必须有触发/退出条件）
- 依据：`Future<void> init() async { if (_box != null && _box!.isOpen) return; try { _box = Hive.isBoxOpen(_boxName) ? Hive.box<String>(_boxName) : await Hive.openBox<String>(_boxName); } catch (e) { debugPrint(...); _box = null; } }`。并发调用时两个调用都可观察到 `_box == null` 且 `Hive.isBoxOpen(_boxName) == false`，各自发起 `await Hive.openBox`，没有 in-flight Future 或锁保护；`catch` 里把 `_box` 置回 `null` 后正常返回，没有失败标志或退避，于是**每个 `json()` 调用都会重新尝试开箱**，盒损坏时每次请求都多一次失败 IO。注释自称「[init] 幂等」「单个 openBox 失败只留痕不崩」，实际只有留痕、不保证幂等，也没有恢复条件（第 11 条）。与 `cache_manager.dart` 的三个 `init()`（无 isBoxOpen、无 catch、异常冒泡）形成同一 Hive 库下两套互不一致的开箱/异常契约（第 8 条）。
- 影响：盒文件损坏时应用每次请求都附带一次失败开箱（额外 IO/卡顿），缓存整体不可用且用户无感知；并发开箱在启动期可能产生开箱异常日志。
- 证据等级：静态推演（控制流在本文件内确认；Hive 是否内部去重 openBox 未实测）

### resource_cache.dart:299-311 `invalidateNs` / `clearJson` / `clearLists` 只处理 String 键且不校验失效世代
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 25 条（资源上限）、第 23 条（失效维度）
- 依据：三处都是 `box.keys.whereType<String>()...toList(); await box.deleteAll(keys);`——非 String 键（Hive 允许整数键）被静默跳过，`clearJson`/`clearLists` 也只按前缀删除各自一层；`invalidateNs` 的 needle 为 `':$ns:u='`，仅依赖调用方传入的 key 字符串恰好含该片段。更关键的是这些方法**不与 in-flight 交互**：`_inFlight` 中正在跑的 `_doFetch` 在 `await init()` 之后仍持有旧的 `box` 引用，失效完成后其 `box.put(fullKey, ...)` 会把刚被删除的键重新写回，即写后失效被在途请求回灌，且没有世代/时间戳判定（第 18 条）。失效也不覆盖 L3 永久文件层。
- 影响：用户执行收藏/删除后立刻刷新仍看到旧数据（在途请求把旧响应写回已清掉的缓存），需再等一次刷新才恢复；设置页「清除缓存」后残留非 String 键的旧值。
- 证据等级：静态推演（失效与 `_doFetch` 写入路径在本文件内成对确认）

### resource_cache.dart:95-97 / 150-160 `kJsonTtl`/`kListTtl` 与 `cache_keys.dart:14-18` 的 TTL 表重复且无单一来源
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 31 条（注释与行为一致）
- 依据：本文件 `const kJsonTtl = Duration(hours: 168); const kListTtl = Duration(seconds: 90);`，`cache_keys.dart` 的 `cacheTtl` 又各自声明 `Duration(hours: 168)` / `Duration(seconds: 90)` / `Duration(days: 36500)`。`ResourceGateway.json` 用 `cacheTtl(scope)`，本文件用 `kJsonTtl` 作默认值、`ttl == kListTtl` 作层级判定；两处靠 Duration 值相等（`==` 比较微秒）隐式耦合，任意一处改动数值就会让 `json:`/`list:` 前缀判定或 TTL 静默错层。文件头注释「TTL 常量（v4.0 冻结契约）」未说明与 `cache_keys.dart` 的重复关系。
- 影响：将来调整任一 TTL 时列表缓存可能被写成 168h 的 JSON 层，用户看到长时间不刷新的旧列表；当前无用户可见错误，属整洁度/可维护性缺陷。
- 证据等级：实锤（两处常量值与引用路径在已读两个文件内确认）

---

## 5. `lib/core/resource/cached_api.dart`（84 行，完整读）

### cached_api.dart:55-83 `get`/`post` 对任意自定义 `ttl` 一律按 `CacheScope.json` 生成键，与 `ResourceCache` 的 `ttl == kListTtl` 层级判定不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 3 条（契约先行）、第 15 条（单位/语义显式）
- 依据：`final scope = ttl == kListTtl ? CacheScope.list : CacheScope.json;`、`final key = _keyOf(path, query, scope: scope);`、`return ResourceCache.instance.json(key, ..., ttl: ttl ?? kJsonTtl, ...)`。`get`/`post` 允许任意 `Duration? ttl`，但只有传入恰等于 `kListTtl` 才得到 `list:` 作用域；传 `Duration(seconds: 30)` 时键是 `json:...` 且 TTL 30 秒，传 `null` 时键的 schemaVer/scope 与传 `kJsonTtl` 完全相同却可带不同 `stale` 值。上一文件 `ResourceCache.json` 又独立用 `ttl == kListTtl` 决定箱内 `fullKey` 前缀，两处对「同一 key 不同 ttl」的语义没有契约；同一 path 以不同 ttl 调用时键相同，会命中 `ResourceCache._inFlight[key]` 的合并与「首个调用方参数决定行为」问题（见 resource_cache.dart 问题 1/3/4）。
- 影响：同一接口以不同刷新策略调用（例如首页 90 秒、详情 168h、强制刷新短 TTL）时互相串用缓存与在途请求，用户看到「刚刷新却还是旧数据」或「短期数据被长期缓存」，且 `stale` 开关随首个调用方随机生效。
- 证据等级：静态推演（键生成与透传在本文件、合并逻辑在已读 `resource_cache.dart` 内成对确认）

### cached_api.dart:30-52 `_bodyDigest` 是 32 位 FNV 且 `_stableJson` 不转义、不区分类型，POST 不同 body 可生成同一缓存键
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 14 条（数据边界）、第 31 条（注释与行为一致）
- 依据：`_stableJson` 对 Map 用 `'"$k":${_stableJson(v[k] ?? '')}'`，键和字符串值都不转义 `"``,`，`，`:` 等分隔符，数字 `1` 与字符串 `"1"` 虽输出不同但 `null` 与空串 `''` 都输出 `""`（`v[k] ?? ''`），`Map` 与某些 `Iterable` 组合也可能拼出相同文本；`_bodyDigest` 用 FNV-1a 32 位哈希（`h & 0xFFFFFFFF`）且**不对 body 为 String 的情况做转义**（`final s = body is String ? body : _stableJson(body);`）。文件头注释称「POST 键补请求体摘要（此前 POST 只按 query 分键，不同 body 串数据）」，但 32 位摘要碰撞在可控输入下可构造，且 `body == null` 时 `extra` 为 null（无摘要），`body` 为非 `null` 但空对象时又生成摘要，二者维度不统一。另 `get` 完全无法传 `body`。
- 影响：两个参数不同的 POST 请求（例如换页、换筛选条件但摘要碰撞或字符串拼接歧义）命中同一份缓存，用户看到上一个请求的结果，写操作注释声称「禁止走本类」但签名层面并无任何类型/断言阻止。
- 证据等级：静态推演（哈希宽度与字符串构造在本文件内确认；碰撞构造未实测）

### cached_api.dart:55-83 `stale` 参数在合并路径上失效，且返回 `__stale` 旧值时本类不做任何可观测处理
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（回退路径与主路径异常形态一致）、第 9 条（失败必须可观测）、第 11 条（降级触发/退出条件）
- 依据：`bool stale = true` 原样透传给 `ResourceCache.instance.json(... staleOnError: stale)`；本类返回值类型仍是 `Future<Map<String, dynamic>>`，没有读取/转换 `__stale` 标记，也没有日志。`ResourceCache._doFetch` 的回退分支对合并进来的调用方使用首个调用方的 `staleOnError`（已读确认），因此本类 `stale: false`（严格模式）在并发时可能收到带 `__stale` 的旧值；上游若不知该标记，会把旧值当新值展示，注释「写操作禁止走本类（防重与异常翻译另有语义）」只是约定无实现约束。
- 影响：明确要求「不许用旧数据」的调用方在并发场景仍拿到旧数据，界面把过期内容当作实时结果且无任何提示（例如权限/会员态相关展示错误）。
- 证据等级：静态推演（透传与已读 `_doFetch` 捕获参数成对确认；上游是否读 `__stale` 不在本范围）

### cached_api.dart:16-28 `_keyOf` 只取 `_api.userid`，未覆盖 token/区域/语言/音质等影响结果的维度
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：`userid: _api.userid.isEmpty ? '0' : _api.userid`，`ns`、`path`、`query`、`extra` 之外没有任何维度；`cache_keys.dart` 文件头把「用户身份、音质、语言、区域、时间窗」列为键维度，但本类没有注入或读取这些值的入口。同一 userid 的登录态变化（token 刷新、VIP 到期、切换语言/音质、匿名→登录但 userid 尚为 0）都生成同一键且 `kCacheSchemaVer` 硬编码为 1。
- 影响：VIP 到期或切换音质/语言后仍命中旧账号态的缓存，用户看到本不应可见的内容或得到与设置不符的音质/语言，且缓存 168h 内不会自愈。
- 证据等级：静态推演（键参数列表在本文件内确认；上游响应是否随这些维度变化不在本范围）

### cached_api.dart:5-9 注释宣称「全部键由 cacheKey 生成（唯一事实源）」，但 `ResourceCache` 内部又加 `json:`/`list:` 前缀、`MemoryCache.keyOf` 自行拼键
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 5 条（状态单一来源）
- 依据：本类注释「全部键由 [cacheKey] 生成（唯一事实源）」仅对 `get`/`post` 成立；已读 `ResourceCache.json` 在 `cacheKey` 产物外再拼 `_jsonPrefix`/`_listPrefix` 形成实际箱内键，`cache_manager.dart` 的 `MemoryCache.keyOf` 与 `LyricPersistentCache._key` 又各自定义键格式，`ResourceGateway.memoryPut` 甚至接受任意裸键。所谓「唯一事实源」在跨类链路上并不成立。
- 影响：维护者按注释以为改一处即可全局调键，实际出现「按 ns 失效漏清」「清缓存漏键」等静默失效；无直接用户可见错误，属整洁度缺陷。
- 证据等级：实锤（已读四个文件的键构造路径对照）

---

