# v5.1 B3 视角 A：缓存层级正确性

- 审查范围：`lib/core/cache/**`、`lib/core/resource/**`、`lib/core/prefetch/**`、`lib/core/storage/**`（9 文件 / 1444 行）
- 视角 A：缓存层级正确性（三级缓存职责边界与命中顺序、cache_keys 维度贯穿、CachedApiCall/RepositoryReads 一致性、TTL 168h/90s 映射、invalidateNs/clearLists/clearJson 语义、永久文件 (URL,bytes) 四道校验、staleOnError/__stale、预加载只请求 JSON、resolveRoot 唯一性）
- 依据：`docs/QUALITY_STANDARD.md`（32 条 + 第 33 条补充），冲突时以之为准
- 只读审查，未修改任何代码文件；未编译/未跑测试

---

## 逐文件实时记录

### 文件 1/9 `lib/core/cache/cache_keys.dart`（48 行，完整读）

- 结构：`kCacheSchemaVer=1`、`CacheScope{json,list,file}`、`cacheTtl`（json=168h / list=90s / file=36500d）、`cacheKey`（ns/scope/path/query/userid/extra/schemaVer）、`cacheNsPrefix`、`fileIdentity`。
- 本文件自足问题：

### lib/core/cache/cache_keys.dart:36-42 键拼装对 query 值不做转义，含分隔符的值可产生键碰撞
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条
- 依据：第 36-40 行把 query 值直接 `'$v'` / `v.join(',')` 后以 `&`、`=`、`:` 拼接进 `'${scope.name}:$ns:u=$userid:$p:$qs:v$schemaVer$tail'`，既未转义也未做长度/类型区分；`query = {'a':'1&b=2'}` 与 `query = {'a':'1','b':'2'}` 生成的 `$qs` 都是 `a=1&b=2`。`extra`（第 40 行）同样以 `:` 直接拼接，与 `scope`/`ns`/`userid` 中的同名字符不可区分。
- 影响：不同请求（尤其搜索关键词含 `&`、`=`、`:` 时）命中同一缓存条目，返回另一关键词的结果；用户可见为「搜 A 出 B 的内容」。
- 证据等级：静态推演（键构造为纯函数，碰撞可静态构造；未实测运行时）

### lib/core/cache/cache_keys.dart:44-48 `fileIdentity` 不执行「bytes<=0 身份不可判定」的契约
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行）/第 14 条（数据边界必须校验）
- 依据：第 46 行注释声明「bytes<=0 视为身份不可判定」，第 47-48 行实现仅 `'$url|$declaredBytes'`，对 `declaredBytes<=0`、空 URL、URL 已含 `|` 均无校验/拒绝，仍返回可用字符串键；`cacheNsPrefix` 亦不含 `userid` 与 `scope`（需结合调用方判定，见后续逐文件记录）。
- 影响：若调用方未独立拦截，bytes<=0 的响应会以 `url|0` 身份被写入/复用，把不完整文件当成有效永久文件；此条为契约缺口，实际是否被拦取决于调用链（后续文件核对）。
- 证据等级：静态推演（本文件事实为实锤，后果需看调用方）

- 待跨文件核对：`cacheTtl` 的 168h/90s 是否被各层正确映射；`cacheNsPrefix` 的失效覆盖域；`fileIdentity` 的四道校验分布。

### 文件 2/9 `lib/core/cache/cache_manager.dart`（181 行，完整读）

- 结构：`LyricPersistentCache`（Hive 持久，getWithStale/set/clear）、`MemoryCache`（单例内存，200 条、默认 TTL、`keyOf`）、`_Entry`、`LyricTranslationCache`（Hive，按 lyricId+targetLang@model）。
- 本文件自足问题：

### lib/core/cache/cache_manager.dart:119-125 `MemoryCache.keyOf` 是第二套键工厂，无 ns/userid/schemaVer/scope 维度
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条
- 依据：第 120-125 行 `keyOf(path, query)` 只按 query key 排序后拼 `'$path?k=v&k=v'`，键中不存在 ns、userid、schemaVer、scope 任一维度；与 `cache_keys.dart` 第 2-4 行「全仓禁止再自行拼…所有缓存读写必须经此文件生成键」的唯一事实源声明并存两套格式。值也未转义（`'${e.key}=${e.value}'`），`{'a':'1&b=2'}` 与 `{'a':'1','b':'2'}` 生成同一键。
- 影响：走 `MemoryCache.keyOf` 的读写在切换登录账号后仍命中旧账号数据，且不同请求参数可互相串数据（用户看到别人的/别的关键字的内容）；同时按 ns 前缀失效（cacheNsPrefix）无法命中这些键。
- 证据等级：静态推演（本文件键格式事实为实锤；是否被实际读写调用待 `cached_api.dart`/`prefetch_engine.dart` 核对）

### lib/core/cache/cache_manager.dart:82-85 `MemoryCache` 默认 TTL 与 cache_keys 的 90s/168h 不是同一来源
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 15 条
- 依据：第 83-84 行 `set` 的 ttl 缺省取 `AppConfig.memoryCacheSeconds`（秒），而 `cache_keys.dart` 第 18-21 行把 TTL 定义为 scope 函数（json=168h、list=90s、file=36500d）；`MemoryCache` 不接收 `CacheScope`，也不调用 `cacheTtl`，注释「内存缓存（90 秒过期）」只是文字约定。
- 影响：内存层 TTL 与 JSON/列表层的声明不一致时，同一份数据在两级缓存中的新鲜度判定不同（内存已过期但磁盘仍新，或反之），用户可见为刷新后仍显示旧内容。
- 证据等级：静态推演（`AppConfig.memoryCacheSeconds` 具体取值待核；本文件与 TTL 单一来源不联动为实锤）

### lib/core/cache/cache_manager.dart:38-49 `getWithStale` 的 stale 返回值不受 ttl 与 storedAt 约束且坏条目不清除
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条 / 第 14 条
- 依据：第 43-48 行 `storedAt is int` 才判 fresh，`final body = decoded['body']` 后 `return (fresh ? bodyMap : null, bodyMap)`；第二返回值（stale）在 `storedAt` 缺失/非 int 或 `body` 非 Map 时仍可能返回任意旧 `bodyMap`，且第 41 行 `decoded is! Map` 分支直接返回 `(null,null)` 而不删除坏条目（对比第 36-38 行的 jsonDecode 失败分支会 delete）。
- 影响：网络失败降级时可能取到无时间标记的任意旧歌词内容（第 9/16 条所述「过期旧值」不再有过期边界），且损坏缓存体每次读取都重复走损坏分支。
- 证据等级：静态推演

### lib/core/cache/cache_manager.dart:143-150 `LyricTranslationCache` 键缺少 cache_keys 维度且值格式用 `\t`/`\n` 裸分隔
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 14 条
- 依据：第 144-145 行 `'$lyricId:$targetLang@${AppConfig.translateModel}'` 仅含三者，无 userid/schemaVer/scope/ns；第 152-158 行按 `\n` 拆行、`\t` 拆字段、`int.parse` 解析行号，写入端第 162-164 行直接 `'${e.key}\t${e.value}'`，译文含换行即破坏行结构。
- 影响：译文含换行或缓存体被改写时，读取端 `int.parse` 抛异常/错行号，歌词翻译行错位；模型以外的维度变化不失效。
- 证据等级：静态推演（`int.parse` 未捕获为实锤；触发路径需真机数据）

- 待跨文件核对：`getWithStale` 的 ttl 实参是否等于 168h；`MemoryCache.clear()` 与 `removeWhere` 被谁用于 clearLists/clearJson；Hive 的 key 是否由 `cacheKey()` 生成。

### 文件 3/9 `lib/core/cache/resource_gateway.dart`（74 行，完整读）

- 结构：单例门面；`_memory` Map（L1）、`json()`（L2，生成 cacheKey→ResourceCache.json，ttl=cacheTtl(scope)）、`file()`（L3→cacheUrlFile）、`invalidateNs`（内存+ResourceCache）、`onUserChanged`（只清内存）、`clearTransient`（内存+clearJson+clearLists）。
- 本文件自足问题：

### lib/core/cache/resource_gateway.dart:16-22 L1 内存层没有 TTL、容量上限与命中顺序实现
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条 / 第 5 条
- 依据：第 16 行 `final Map<String, Object> _memory = {}` 无上限；第 17-22 行 `memoryGet`/`memoryPut` 不记录 `storedAt`、不调用 `cacheTtl`，也没有 `_memory.remove` 过期清理；`json()`（第 25-47 行）只调用 `ResourceCache.instance.json`，从未调用 `memoryGet`/`memoryPut`，注释第 2-4 行宣称「内部按 CacheScope 分派到 内存 / 磁盘 JSON / 永久文件三层」，实际 L1 与 L2 之间不存在任何命中/回填链路。旧的 `MemoryCache.instance`（cache_manager.dart 第 70-128 行）是另一个独立单例，门面既不持有也不清除它。
- 影响：所有经门面的 JSON 请求每次都落到 L2 磁盘，L1 形同空置；`_memory` 只写不淘汰（若有消费方写入）会随进程增长；`onUserChanged()` 只清 `_memory`，旧账号在 L2 的键仍可通过同一 userid 命中（见下条）。
- 证据等级：静态推演（门面代码为实锤；是否另有消费方直接写 `_memory` 需后续文件核对）

### lib/core/cache/resource_gateway.dart:58-62 `onUserChanged` 只清 L1，L2/L3 用户维度数据不失效
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 5 条
- 依据：第 59-61 行实现仅 `_memory.clear()`；`json()` 第 33-40 行生成的键含 `u=$userid`，`invalidateNs`（第 51-55 行）与 `clearTransient`（第 65-69 行）才会调用 `ResourceCache.instance` 的清除；注释「切号/登出：用户维度整体失效（缓存键含 u=，旧账号数据不再命中）」把「键不同」当作「已失效」。
- 影响：切号后只要 userid 回到先前值（A→B→A，或登出再登录同一账号），旧账号的 168h 内 JSON/列表仍被命中，用户看到上个会话的收藏/歌单/评论；缓存体也不会因切号释放。
- 证据等级：静态推演（是否真有 A→B→A 路径影响用户，取决于上层是否传 userid；与 `cached_api.dart` 核对）

### lib/core/cache/resource_gateway.dart:25-47 `json()` 允许调用方传 `scope=file` 等任意 CacheScope，TTL/层级错配无约束
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条 / 第 15 条
- 依据：第 35 行 `CacheScope scope = CacheScope.json` 为可自由传入参数，第 42-45 行把 `cacheTtl(scope)` 直接交给 `ResourceCache.json`，方法名/注释（「L2 磁盘 JSON：统一的 168h / 90s 语义」）只声明 json=168h、list=90s；若传 `CacheScope.file`，TTL 变成 36500 天却仍写进 JSON 层。
- 影响：列表若误用 file scope 将 100 年不过期，用户长期看到过期列表；反之 JSON 误用 list scope 则 90 秒后重复请求。
- 证据等级：静态推演（接口契约缺口，尚未见误用调用点）

### lib/core/cache/resource_gateway.dart:48-50 `file()` 把 `declaredBytes=0` 默认放行给 L3
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条 / 第 14 条
- 依据：第 49 行 `int declaredBytes = 0`，第 50 行无条件转调 `ResourceCache.instance.cacheUrlFile(url, kind, declaredBytes: declaredBytes)`；`cache_keys.dart:46` 声明 bytes<=0 身份不可判定，门面未拦截也未要求必填，注释「身份=(URL,声明字节数)，校验在 ResourceCache 内四道」把校验完全外包。
- 影响：任何省略 declaredBytes 的门面调用都以 `url|0` 身份进入文件缓存；是否被下游拒绝需看 `resource_cache.dart`（后续核对），若下游放行则把长度未知的文件当永久文件。
- 证据等级：静态推演（门面放行事实为实锤）

- 待跨文件核对：`ResourceCache.json` 是否真的按 ttl 判新鲜/合并 in-flight/消费 `__stale`；`invalidateNs` 与 `clearJson`/`clearLists` 的实际语义；`cacheUrlFile` 的四道校验。

### 文件 4/9 `lib/core/prefetch/prefetch_engine.dart`（211 行，完整读）

- 结构：单例；`attach(KugouApiClient)` 构造 `CachedApiCall(api, ns:'prefetch')`；`enqueueSongs`/`updateUpcoming` 去重入队；`_startDrain` 定时消费 `_prefetchOne`（3 个 JSON）；`onPlaybackCompleted` 调 `ResourceCache.cacheUrlFile`；`dispose`。
- 本文件自足问题：

### lib/core/prefetch/prefetch_engine.dart:121-130,170-197 预热与播放侧缓存键不同 ns（`prefetch` vs 播放侧），预热结果不会被播放时复用
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 3 条
- 依据：第 76 行 `attach` 固定 `CachedApiCall(api, ns: 'prefetch')`；`CachedApiCall._keyOf`（待 `cached_api.dart` 核对）把 ns 拼入键，第 170/183/191-193 行的三次 `cached.get` 因此都写在 `prefetch` 命名空间下；文件头第 15-18 行明确宣称「与 repository 侧读写天然同键——预热命中的缓存播放时直接复用，不造双实现」，但 repository 侧读键的 ns 由各 repository 自己决定（后续 `cached_api.dart` 核对），且 `ns='prefetch'` 与 `invalidateNs(player/lyric/...)` 的失效域不交叠。
- 影响：启动预热发出的所有网络请求结果只填充 `prefetch` 命名空间，播放时读的是另一套键，导致同一 `/song/url`、`/search/lyric`、`/album/detail` 被请求两次（预热白跑、流量与耗电翻倍），预热「加速首播」目标失效。
- 证据等级：静态推演（ns 事实实锤；repository 侧 ns 取值见文件 5 复核）

### lib/core/prefetch/prefetch_engine.dart:114-119 `onPlaybackCompleted` 无条件把 declaredBytes=0 交给文件缓存
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条 / 第 3 条
- 依据：第 114-116 行注释要求「url + declaredBytes 必须来自同一次播放 JSON 响应；declaredBytes<=0 由 ResourceCache 拒绝入库」，但第 117 行 `declaredBytes = 0` 为默认值，第 120-126 行只拦截 `url.isEmpty` 就调用 `cacheUrlFile`；本方法未对 <=0 做任何前置拒绝。
- 影响：若调用方漏传声明字节数，文件以 `url|0` 身份进入永久层；是否真入库取决于 `ResourceCache` 的校验（后续核对）。
- 证据等级：静态推演

### lib/core/prefetch/prefetch_engine.dart:81-88 `enqueueSongs` 的去重集在缓存失效/清缓存后不重置，永久不再预请求
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条 / 第 11 条
- 依据：第 35-36 行 `_requested` 注释「同一 hash 本进程只预请求一轮」；第 81-88 行只 `if (!_requested.add(song.hash)) continue`，`dispose()`（第 203-210 行）才清空；`ResourceGateway.clearTransient()` 与 `invalidateNs()` 都不回调本引擎，也无 `attach` 时清空 `_requested` 的逻辑（第 76 行）。
- 影响：用户在设置页清缓存或写操作触发 ns 失效后，本进程内再次打开同一批歌曲不会重新预热，播放只能等实时网络；表现为「清缓存后长时间首播变慢」。
- 证据等级：静态推演（清缓存路径与 `_requested` 无关联为实锤）

### lib/core/prefetch/prefetch_engine.dart:165-167,173-180 预热 URL JSON 只覆盖 kapi `/song/url`，直连路径无预热
- 级别：P2
- 违反：QUALITY_STANDARD 第 27 条
- 依据：第 173-180 行注释自述「预热只覆盖 kapi 路径，直连 /v5/url 不经 kapi 也无 JSON 可缓存」，且实际 `cached.get('/song/url', ...)` 走 `KugouApiClient`（kapi 客户端）；按 REVIEW_SPEC 第三节第 1 条「所有接口必须优先使用原生网关；kapi 仅允许兜底」，预热把 kapi 路径作为唯一可预热实现。
- 影响：主路径为原生直连时，预热对播放地址完全无效，且每次启动仍会向 kapi 中转发出最多 60 首的无效请求。
- 证据等级：静态推演（注释与代码为实锤；运行时哪条路径为主需跨模块裁决，标注未实测）

- 待跨文件核对：`CachedApiCall` 的键格式/TTL/ns 默认值、`ResourceCache.cacheUrlFile` 四道校验、`clearTransient` 是否回调预加载引擎。

### 文件 5/9 `lib/core/resource/cached_api.dart`（84 行，完整读）

- 结构：`CachedApiCall(api, {ns='common'})`；`_keyOf`（cacheKey，userid 取 `_api.userid`，POST 补 `_bodyDigest`）、`_bodyDigest`（FNV 低 8 位哈希）、`_stableJson`、`get`/`post`（scope 由 `ttl == kListTtl` 反推，转调 `ResourceCache.json`）。
- 本文件自足问题：

### lib/core/resource/cached_api.dart:59-61,73-75 scope 由 `ttl == kListTtl` 反推，TTL 与作用域不是同一事实源
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 15 条
- 依据：`get` 第 59 行、`post` 第 73 行均以 `final scope = ttl == kListTtl ? CacheScope.list : CacheScope.json;` 决定键里的 `scope` 段；传给 `ResourceCache.json` 的却是 `ttl: ttl ?? kJsonTtl`（第 64/78 行），`cacheTtl(scope)`（cache_keys.dart 第 18-21 行：json=168h、list=90s）在此完全不参与。任何自定义 ttl（如 `Duration(minutes: 5)`）都产出 `scope=json` 键但用 5 分钟 TTL，而 `ResourceGateway.json()` 用 `cacheTtl(scope)`；`kListTtl`/`kJsonTtl` 是 `resource_cache.dart` 的独立常量（待核），不是 `cache_keys.dart` 的 TTL 事实源。
- 影响：同一 path+query 在 `ResourceGateway` 侧与 `CachedApiCall` 侧可得到不同 scope 键/不同 TTL，写一边读另一边永不命中（预加载与播放各自重复请求）；列表接口若用 168h 键存 90s 数据或反之，用户看到过期列表或频繁重载。
- 证据等级：静态推演（本文件逻辑实锤；`kListTtl`/`kJsonTtl` 数值与 `ResourceCache.json` 内部 TTL 使用方式待文件 7 复核）

### lib/core/resource/cached_api.dart:31-40,42-54 `_bodyDigest` 只取 UTF-16 低 8 位且 `_stableJson` 不转义，POST 键可碰撞
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 14 条
- 依据：第 35-38 行 `for (final c in s.codeUnits) { h ^= c & 0xff; ... }` 把每个 code unit 截断到低字节，中文/emoji 大量字符低字节为 0x00 或相同值；第 46-53 行 `_stableJson` 对 String 直接返回 `'"$v"'`，不转义引号/反斜杠，Map 序列化后不同 body 可得到完全相同的字符串（例如含嵌入 `","` 的值与多键值结构）。文件头第 5-6 行宣称「POST 键补请求体摘要（此前 POST 只按 query 分键，不同 body 串数据）」，但摘要只有 32 位且对非 ASCII 有系统性碰撞。
- 影响：不同请求体的 POST 落到同一缓存键，返回上一次请求的结果：评论/收藏/搜索等写或读请求可能显示别人的结果，或写操作响应被误判为已完成（与第 21 条防重相关）。
- 证据等级：静态推演（哈希实现与字符串拼接为实锤；具体碰撞输入可构造，未实测运行时）

### lib/core/resource/cached_api.dart:68-81 `post()` 默认 `stale = true` 并可缓存 POST 响应，与「写操作禁止走本类」契约无强制
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条 / 第 21 条
- 依据：第 7 行注释声明「写操作禁止走本类（防重与异常翻译另有语义）」，但 `post` 无任何写路径判定，第 79 行把 `staleOnError: stale`（默认 true）传给 `ResourceCache.json`；网络失败时可返回旧 POST 响应（stale）而不发请求。
- 影响：若上层把状态变更类 POST 经本类调用，网络失败时调用方收到「成功」旧响应，UI 显示已提交但服务端未变更；重试又被缓存短路，形成静默错误。
- 证据等级：静态推演（本类未区分读写为实锤；是否存在写调用点需跨模块核对，标注未实测）

### lib/core/resource/cached_api.dart:56-66,69-81 `get`/`post` 不接收 userid/schemaVer/extra，键维度不可覆盖
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 2 条
- 依据：第 21-29 行 `_keyOf` 固定 `userid: _api.userid.isEmpty ? '0' : _api.userid`，`schemaVer` 使用 `cacheKey` 默认值 `kCacheSchemaVer=1`，`extra` 仅给 body digest；`get`/`post` 的签名（第 56-61、69-75 行）无 userid/schemaVer/scope 参数，调用方无法为「同一 path 随音质/语言/区域变化」的响应补充维度，只能靠把参数塞进 query。
- 影响：响应形态受 Cookie/语言/音质等非 query 因素影响时，不同用户/不同设置仍共用同一键；需上层自觉填满 query，否则串数据。
- 证据等级：静态推演

- 待跨文件核对：`kJsonTtl`/`kListTtl` 数值、`RepositoryReads` 实现是否存在且与本类同键、`ResourceCache.json` 的 stale 语义。

### 跨文件对照（为判定 CachedApiCall 与 RepositoryReads 是否双实现/键规则一致，完整读了范围外的 `lib/core/net/repository_reads.dart` 63 行与 `lib/core/config/app_config.dart` 56 行；二者仅作对照，不计入 9 文件范围）

- `RepositoryReads`（63 行）：GET/POST 走 `ResourceGateway.instance.json(ns, scope, path, query, userid=_api.userid, extra=body, fetch)`；`readListTtl=cacheTtl(list)`、`readJsonTtl=cacheTtl(json)`；`invalidate()→ResourceGateway.invalidateNs(ns)`。
- `AppConfig.memoryCacheSeconds = 90`（确认 `MemoryCache` 默认 TTL 数值）。

### lib/core/resource/cached_api.dart:59-81 / lib/core/net/repository_reads.dart:26-58 CachedApiCall 与 RepositoryReads 是两套并行读实现，键规则不一致
- 级别：P0
- 违反：QUALITY_STANDARD 第 5 条 / 第 23 条 / 第 3 条
- 依据：两套实现同路径同 query 产生**不同缓存键**：①`CachedApiCall._keyOf`（cached_api.dart:21-29）scope 由 `ttl == kListTtl` 反推、ttl 缺省 `kJsonTtl`、POST 的 `extra` = 32 位 FNV `_bodyDigest`；②`RepositoryReads.get/post`（repository_reads.dart:26-58）scope 由调用方 `json` 布尔决定、ttl 由 `cacheTtl(scope)` 生成、POST 的 `extra` = `body.toString()` 原文（未摘要）、GET 无 extra；③`CachedApiCall` 直连 `ResourceCache.instance.json`，`RepositoryReads` 经 `ResourceGateway.instance.json`；④`CachedApiCall` 默认 `ns='common'`，`RepositoryReads.ns` 由构造传入，`PrefetchEngine.attach` 固定 `ns='prefetch'`；⑤失效路径只有 `RepositoryReads.invalidate()→ResourceGateway.invalidateNs`，`CachedApiCall` 无失效方法。文件头 prefetch_engine.dart:15-18 声称「统一走 CachedApiCall…与 repository 侧读写天然同键——不造双实现」与本事实相反。
- 影响：预加载（CachedApiCall/ns=prefetch）与播放/列表读（RepositoryReads/各业务 ns）互不命中，同一接口重复发请求；更严重的是**写后失效只清 RepositoryReads 一侧**：用户收藏/删除/评论后 `invalidate()` 清掉本 ns，但 `CachedApiCall` 写入的 `common`/`prefetch` 命名空间条目（168h）仍被后续读取命中，界面持续显示写操作前的旧数据（静默错误，跨账号还可能串数据）。
- 证据等级：实锤（两文件键构造与失效路径直接对照）

### lib/core/cache/resource_gateway.dart:25-47 / lib/core/net/repository_reads.dart:13-14 / lib/core/resource/cached_api.dart:59-80 TTL 映射存在两套数值口径
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 15 条
- 依据：门面侧 `ResourceGateway.json` 第 42-45 行把 `cacheTtl(scope)`（cache_keys.dart:18-21，json=168h、list=90s）传给 `ResourceCache.json`；`RepositoryReads` 第 13-14 行注释「值源自 cache_keys.cacheTtl，唯一事实源」但实际两个 `readXxxTtl` 常量在本类内未被 `get/post` 使用（TTL 已在门面内部决定）；`CachedApiCall` 第 59/64、73/78 行则用 `resource_cache.dart` 的 `kJsonTtl`/`kListTtl` 常量并允许任意 `Duration` 覆盖，同一 `CacheScope` 可对应两种 TTL。`AppConfig.memoryCacheSeconds=90` 是第四处 TTL 定义。
- 影响：TTL 修改无法全局生效（如把 json 从 168h 改成 24h），部分读路径仍按旧值缓存；用户可见为「清了缓存/等过期后仍显示旧数据」或同一页面不同块新鲜度不一致。
- 证据等级：静态推演（数值一致性待 `resource_cache.dart` 中 `kJsonTtl`/`kListTtl` 定义核对）

### 文件 6/9 `lib/core/resource/lyric_translation_stream.dart`（36 行，完整读）

- 结构：`LyricTranslationPatch(lyricId,startIndex,values)`、`LyricTranslationStream` 单例 broadcast StreamController、`emit`、`dispose`。与三级缓存层无直接读写接口。

### lib/core/resource/lyric_translation_stream.dart:8-12,18-27 声明「缓存命中时也 emit 一次」但本类与缓存层无任何连接，且补丁不带世代/用户维度
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 18 条
- 依据：第 9-11 行注释「缓存命中时也 emit 一次（UI 秒显），遵循「单一事实源+事件通知」分层」，但本文件 import 仅 `dart:async`，`emit`（第 26-29 行）只 `if (_controller.isClosed) return; _controller.add(p)`，不含任何缓存读取、ns/userid/schemaVer 维度，也不拒绝旧世代补丁；`LyricTranslationPatch` 字段仅 `lyricId/startIndex/values`（第 4-8 行）。broadcast 无监听时事件被丢弃（第 24-25 行注释自认）。
- 影响：切歌/切号瞬间发出的旧译文补丁可被新页面的订阅者按 `startIndex` 插入，用户看到上一首歌的译文行；缓存命中能否秒显完全取决于调用方是否另行 emit，无契约保证。
- 证据等级：静态推演（本类无世代校验为实锤；UI 侧是否过滤 lyricId 需跨模块核对，标注未实测）

### lib/core/resource/lyric_translation_stream.dart:33-35 `dispose()` 关闭单例控制器后无重建路径
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条
- 依据：第 32-35 行 `Future<void> dispose() => _controller.close();`，`_controller` 为 `final`，单例 `static final instance` 第 15-16 行；`emit` 第 27 行在 `isClosed` 后静默返回，不再有可订阅流。
- 影响：热重载/测试调用 dispose 后，本进程后续所有翻译增量广播被静默丢弃，歌词翻译不再实时插入（页面只能等重新进页后的缓存读取）。
- 证据等级：静态推演

- 待跨文件核对：`ResourceCache` 的 TTL 常量、in-flight、stale、四道校验、clearLists/clearJson/invalidateNs。

### 文件 7/9 `lib/core/resource/resource_cache.dart`（331 行，完整读）

- 结构：`kJsonTtl=168h`、`kListTtl=90s`、`kFilePermanent=null`；`json()`（in-flight 合并、`json:`/`list:` 前缀、`_doFetch` 写 Hive + stale 回退带 `__stale`）；`_readStored`；`_dirOf`（resolveRoot）；`_hashName`（FNV-1a(url|bytes)+url.length+bytes+ext）；`putFile/file/filePath`（bytes 缺省 0）；`cacheUrlFile`（四道校验）；`invalidateNs`/`clearJson`/`clearLists`。

### lib/core/resource/resource_cache.dart:67-70,76-77 `json()` 用 `ttl == kListTtl` 反推 `list:`/`json:` 前缀，与键内 scope 段及门面 TTL 语义可错配
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 5 条
- 依据：第 67 行 `final isList = ttl == kListTtl;` 单独决定 `fullKey` 前缀（第 68 行 `json:` 或 `list:`），而调用方传入的 `key`（cache_keys.dart:36-42）本身已含 `scope.name` 段；`kJsonTtl/kListTtl`（第 14-15 行）与 `cacheTtl`（cache_keys.dart:18-21）是两处独立定义的数值。任何自定义 ttl（`ResourceGateway.json(scope: CacheScope.file)` 传 36500 天，或 `CachedApiCall.get(ttl: 5min)`）都会落 `json:` 前缀但用非 168h TTL；同一键在 `clearJson`/`clearLists` 中的归属由 ttl 而非声明的 scope 决定。
- 影响：`clearLists()`（第 322-331 行）只删 `list:` 前缀，若列表请求经 `scope=list` 但 ttl 非 `kListTtl`（如门面 `cacheTtl(list)` 未来改动、或调用方覆盖），其条目落在 `json:` 永远不被清；用户清缓存后仍看到旧列表，或写后失效漏删。
- 证据等级：静态推演（当前数值 90s/168h 恰好相等为实锤；耦合关系是代码事实）

### lib/core/resource/resource_cache.dart:78-88 in-flight 合并以**未加前缀的 key** 为粒度，`json`/`list` 两种 TTL 的同键请求被合并
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条 / 第 22 条
- 依据：第 66-68 行 `final pending = _inFlight[key]; if (pending != null) return pending;` 用裸 `key`；第 76-77 行 `final fullKey = '${prefix}$key'` 之后才定前缀；第 84-88 行 `_inFlight[key] = fut` 与 `finally _inFlight.remove(key)`。若同 `key` 的两次调用传不同 ttl（例如 `CachedApiCall.get(ttl: kListTtl)` 与 `RepositoryReads.get(json: true)` 在 ns/query 相同的情况下），第二个请求直接返回第一个的 Future，既不按自己的 TTL 判新鲜，也不写自己的 `fullKey`。此外 `finally` 无条件 remove（第 87-88 行）不校验「我是否仍是当前持有者」，属于第 19 条的闸门归属问题（若 fut 被替换，先完成者会清掉后者的 in-flight）。
- 影响：列表/详情同键并发时，一个请求的结果被另一语义复用，168h 的详情数据与 90s 的列表数据互相覆盖/缺失；高频切页时偶发显示错误数据。
- 证据等级：静态推演

### lib/core/resource/resource_cache.dart:107-130,126-129 `__stale` 标记仅写入返回值，本类与门面、CachedApiCall、RepositoryReads 均无消费方
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条 / 第 11 条 / 第 16 条
- 依据：第 123-129 行 `return Map<String, dynamic>.from(staleBody)..['__stale'] = true;`；`_doFetch` 之外，`ResourceGateway.json`（25-47 行）、`CachedApiCall.get/post`（56-81 行）、`RepositoryReads.get/post`（26-58 行）均原样 `return` 缓存层结果，不检查 `__stale`；`CacheManager.getWithStale`（cache_manager.dart:24-49）返回的是 `(fresh, stale)` 元组且不含 `__stale` 字段，是另一套降级。注释第 123-126 行自认「此前无任何消费方=假降级」，但当前修复只是 `ErrorLogger.log`（verbose 级）与打标，仍未把「请求失败、显示的是旧数据」传递给 UI，也没有退出的触发/恢复提示。
- 影响：断网或接口失败时，页面把过期缓存当最新数据正常渲染（收藏数、歌单、评论、歌词都是旧值），无错误态/重试提示；用户无法区分「请求失败」与「确实为空/最新」，且 `__stale` 作为额外顶层字段会进入业务解析（若上游按 `body.keys` 遍历则出现未知字段）。
- 证据等级：静态推演（本范围内全部返回路径已完整核对；features 层是否另有 `__stale` 消费方不在本范围，标注未实测）

### lib/core/resource/resource_cache.dart:181-193,196-226 `putFile`/`file`/`filePath` 的文件身份与 `cacheUrlFile` 不是同一套
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 3 条
- 依据：`_hashName(String url, {int bytes = 0})` 第 181 行默认 `bytes = 0`；`putFile`/`file`/`filePath`（第 196-226 行）全部调用 `_hashName(key)` 不带 bytes，身份固定为 `(key, 0)`；`cacheUrlFile`（第 240-296 行）调用 `_hashName(url, bytes: declaredBytes)`，身份为 `(url, declaredBytes)`；两者同 URL 生成两个不同文件名，`putFile` 写入的文件 `cacheUrlFile` 永不复用，反之亦然。此外这三条 API 无 declaredBytes 参数、无长度校验，注释第 28-30 行声称「文件键由 URL 全文哈希 + kind 构成，音质/类型维度在 kind 中体现」与 (URL,bytes) 二元组契约矛盾。
- 影响：永久文件层存在两套互不兼容的身份与两个副本，占用双倍磁盘空间；下载/播放完成写入的 `putFile` 内容在播放时按 (URL,bytes) 查不到，仍触发再次下载（带宽/流量浪费），且 bytes<=0 可通过这三条入口直接入库。
- 证据等级：静态推演（三处 API 与 cacheUrlFile 的 `_hashName` 实参对照为实锤；上层是否混用需跨模块核对，标注未实测）

### lib/core/resource/resource_cache.dart:181-193 `_hashName` 只用 32 位 FNV 且扩展名取自 query，`(URL,bytes)` 身份可碰撞/路径异常
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条 / 第 17 条
- 依据：第 182-189 行 `h` 为 32 位 FNV-1a，文件名 `'${h.toRadixString(16)}_${url.length}_$bytes$suffix'`；第 190-193 行 `ext = url.contains('?') ? url.substring(url.indexOf('?')) : ''`，把**整个 query 串**当扩展名候选，取 `lastIndexOf('.')` 后 `ext.substring(dot)`，且条件 `ext.length <= 8` 使绝大多数带签名/时间戳的 URL 拿不到后缀；`bytes` 直接拼在文件名里未隔离。不同 (URL,声明字节数) 组合可能产生相同 `h` + 相同 `url.length` + 相同 `bytes`（32 位哈希碰撞）。
- 影响：极端情况下两个不同资源覆盖同一永久文件，播放/下载时返回错误文件内容（音频播不出或串歌）；query 里含 `/` 等字符时子路径串到 kind 目录之外。
- 证据等级：静态推演（碰撞需构造，标注未实测）

### lib/core/resource/resource_cache.dart:240-296 四道校验存在缺口：HEAD 无 Content-Length 时放行、HEAD 失败被整体 catch 吞掉、Dio 实例未关闭
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条 / 第 14 条 / 第 6 条
- 依据：第 249-252 行「拒绝 bytes<=0」✅（道 1）；第 262-269 行 `final cl = int.tryParse(...) ?? 0; if (cl > 0 && cl != declaredBytes) ... return null` —— `cl==0`（HEAD 无/非法 Content-Length）**不拒绝**，仍继续下载（道 2 弱化）；第 270-275 行下载后 `actual != declaredBytes` 删除 `.part` 并返回（道 3 ✅）；第 254-260 行复用前 `target.length() == declaredBytes` ✅（道 4）；但第 264-269 行 Content-Length 不符分支与 catch 分支（第 284-294 行）只 `return null` / `debugPrint`，`dio` 无 `close()`（第 261 行创建后未释放），`dio.head` 抛错被最外层 `catch (e)` 统一当下载失败留痕（第 6/7 条精确捕获缺失），且 HEAD 与 GET 之间 URL 内容可被 CDN 替换（未做 ETag/Last-Modified 校验）。
- 影响：上游不给 Content-Length（chunked）时，身份仅靠下载后长度兜底，仍可入库但过程多一次整文件下载；HEAD 失败（部分 CDN 禁 HEAD）导致永久缓存彻底不生效，播放完成 hook 静默失败、每次播放重新下载；Dio 实例未关闭占用连接资源。
- 证据等级：静态推演（四道分支逐行对照为实锤；CDN 行为标注未实测）

### lib/core/resource/resource_cache.dart:302-331 `invalidateNs` / `clearJson` / `clearLists` 语义互相重叠且漏掉 list+json 混合域
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 5 条
- 依据：`invalidateNs` 第 308-314 行按 `k.contains(':$ns:u=')` 删（跨 `json:`/`list:` 两前缀，含 userid），但 `cacheNsPrefix`（cache_keys.dart:44-45）返回 `':$ns:u='` 未被复用而是第 309 行重新手写同一字符串；`clearJson`（第 317-324 行）只删 `json:` 前缀、`clearLists`（第 327-331 行）只删 `list:` 前缀，二者合起来才等价于全清，而 `ResourceGateway.clearTransient()`（第 65-69 行）确实两个都调，所以「设置页清缓存」语义上是**全清 JSON 层**而非「只清 transient」；同时 `ResourceGateway.onUserChanged()`（第 59-61 行）连这两个都不调。`clearJson`/`clearLists` 都不清 `_inFlight`（第 38 行）与 `_memory`（门面第 16 行）。注释第 300 行「shared 域（无 ns）由 clearJson 兜底」与 `clearLists` 不分摊 list 域矛盾。
- 影响：清缓存后仍可能立刻写回刚发出的 in-flight 结果（用户清完缓存刷新又看到旧数据）；`invalidateNs` 依赖键中恰好含 `:$ns:u=`，任何不走 `cacheKey()` 的键（如 `MemoryCache.keyOf`、Hive `lyric_cache`/`lyric_translations`）永不失效；写操作后旧评论/歌单在 168h 内继续可见。
- 证据等级：静态推演（删除谓词与前缀为实锤）

### lib/core/resource/resource_cache.dart:14-16,39-49 `kFilePermanent = null` 与 openBox 失败降级为空箱后所有读写静默失效
- 级别：P2
- 违反：QUALITY_STANDARD 第 32 条 / 第 9 条
- 依据：第 16 行 `const kFilePermanent = null;` 无任何引用（注释自称「占位常量，按契约保留」）；`init()` 第 42-49 行 openBox 失败仅 `debugPrint` 后 `_box=null`，`_safeBox` 返回 null，`json()` 第 73-75 行 `stored=null`、`_doFetch` 第 100 行 `box != null` 跳过写入，调用方仍拿到正常网络结果，无「缓存不可用」的可见差异。
- 影响：存储损坏/权限异常时缓存永久不生效（每次都请求网络），用户只见加载变慢无提示；死常量增加维护误导。
- 证据等级：静态推演

- 待跨文件核对：`StoragePermissionService.resolveRoot` 唯一性与可写性判定；`secure_storage.dart` 的键维度。

### 文件 8/9 `lib/core/storage/secure_storage.dart`（124 行，完整读）

- 结构：单例 `SecureStorage`；`saveCredentials`（5 键 Future.wait，null 删除 t1/auth/dfid）、`readCredentials`（5 键并行）、`clearCredentials`（删 4 键 + 可选 `acct_token_<userid>`，保留 dfid）、`saveDfid/readDfid`、`saveAccountToken/readAccountToken/deleteAccountToken`、`Credentials`。
- 本文件自足问题（与缓存层级相关者）：

### lib/core/storage/secure_storage.dart:70-94 `clearCredentials` 保留 dfid 与 `saveCredentials` 中 dfid=null 即删除的语义冲突，且清凭证不触碰缓存层
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条 / 第 23 条
- 依据：`saveCredentials` 第 31-36 行在 `dfid == null` 时执行 `_storage.delete(key: _kDfid)`（注释第 23-24 行称「null 必须删除旧键——切号时…串号」）；`clearCredentials` 第 84-93 行注释 F-1 明确「保留 dfid」，删除列表只有 token/userid/t1/auth 与可选 acct_token；同一份 `dfid` 状态在两个方法里语义相反。且本文件不 import 任何缓存类，清凭证后没有调用 `ResourceGateway.onUserChanged()`/`invalidateNs`/`clearTransient`（对照 resource_gateway.dart:58-69）。
- 影响：登出/切换登录态时，L2 磁盘 JSON/列表缓存（键含 `u=$userid`、TTL 168h）与 `lyric_cache`/`lyric_translations` Hive 箱仍保留；再登录同一账号或 A→B→A 时，页面先渲染上一位用户的收藏/歌单/歌词；dfid 在「新登录响应不带 dfid」的切号路径被删、在登出路径保留，设备指纹状态不一致（触发风控验证/试听降权）。
- 证据等级：静态推演（本文件删除/保留逻辑实锤；缓存层未联动为跨文件对照实锤）

### lib/core/storage/secure_storage.dart:25-39,99-106 多账号 token 键直接用 userid 原文，账号缓存键维度与 userid 归一不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条 / 第 14 条
- 依据：`saveAccountToken` 第 100-104 行 `'$_kAcctTokenPrefix$userid'` 直接拼接 userid，无校验/转义/前缀隔离带；而 `CachedApiCall._keyOf`（cached_api.dart:25）、`RepositoryReads._userid`（repository_reads.dart:22）把空 userid 归一为 `'0'`，`cacheKey`（cache_keys.dart:36-42）把 userid 插在 `:u=` 与 `:$p` 之间。userid 含 `:` 或超长时，安全存储键与缓存键无法按同一身份对齐，`clearCredentials({userid})` 第 90-92 行也只能删它拼出的那一个键。
- 影响：极端 userid 下切换账号 token 未被删除（共享设备可无密码切回），缓存归属判断不一致导致串号。
- 证据等级：静态推演（键拼接事实实锤；异常 userid 需真机/上游数据，标注未实测）

### lib/core/storage/secure_storage.dart:66-93 `clearCredentials` 只删 `userid` 指定账号 token，其它账号 token 全部残留
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条 / 第 20 条
- 依据：第 87-92 行的删除列表在 `userid != null && userid.isNotEmpty` 时仅追加 `'$_kAcctTokenPrefix$userid'` 一项；`FlutterSecureStorage` 无枚举所有 key 的调用，其它 `acct_token_<other>` 项无任何清除路径（`deleteAccountToken` 第 113-114 行只按传入 userid 单个删除）。
- 影响：用户退出登录后，设备上其它账号的切换 token 仍在加密存储中，下次进「切换账号」列表仍可无密码进入旧账号（与第 70-74 行注释所声称的「登出必须清干净」不符）。
- 证据等级：静态推演（删除列表为实锤；账号切换页是否展示残留项需跨模块核对，标注未实测）

- 待跨文件核对：`StoragePermissionService.resolveRoot` 唯一性。

### 文件 9/9 `lib/core/storage/storage_permission.dart`（355 行，完整读）

- 结构：`StorageStrategy` 枚举、单例 `StoragePermissionService`；根路径常量（rootDirName/rootPath/fallbackRootDirName/subDirOf/verboseRelativePath）；`isAllFilesAccessGranted`/`requestAllFilesAccess`；`lastProbeError`；`_probeWritable`；`resolveRoot`/`resolveRootMode`；`_channel`；`apiLevel`/`_apiLevelFromOsVersion`；`isAndroid10Plus`/`needsLegacyWritePermission`；三个权限申请；`resolveStrategy`/`currentStrategy`；`publicDir`/`isPublicDirWritable`。

### lib/core/storage/storage_permission.dart:158-183 `resolveRoot` 在权限态/探测结果变化时返回不同根，永久文件缓存随授权变化整体「丢失」
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条 / 第 5 条
- 依据：第 160-166 行 `isAllFilesAccessGranted()` 为真且 `_probeWritable(Directory(rootPath))` 通过才返回 `rootPath`（`/storage/emulated/0/TierNanMusic`）；否则第 168-176 行走 `publicDir('downloads')` 得到 `$base/TiernanMusic`，第 180 行兜底再返回 `/storage/emulated/0/Download/TiernanMusic`；`ResourceCache._dirOf`（resource_cache.dart:154-160）每次 `'<resolveRoot()>/cache/resource/<kind>'`，注释（resource_cache.dart:27-28）称「永久不淘汰」。用户授予/撤销 MANAGE_EXTERNAL_STORAGE、ROM 探测瞬时失败、原生通道失败，都会让后续解析切到另一个根目录，旧文件仍在磁盘但 `filePath`/`cacheUrlFile` 的 `target.exists()` 再也查不到。
- 影响：用户开关「所有文件访问」权限或系统探测偶发失败后，已缓存的歌曲/封面/歌词全部不可见，播放重新下载、离线能力失效；磁盘上旧副本无人清理，占用空间翻倍。
- 证据等级：静态推演（三条返回分支与 `_dirOf` 组合为实锤）

### lib/core/storage/storage_permission.dart:172-176 探测失败仍返回不可写 candidate 路径，与「实测可写才返回」契约矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条 / 第 9 条
- 依据：第 174 行 `if (await _probeWritable(Directory(candidate))) return candidate;`，第 175 行 debugPrint，第 176 行 `return candidate; // 通道给了真实路径：即使探测失败也返回（调用方各有降级）`；对比第 161-166 行的 rootPath 分支在探测失败时会降级。`_probeWritable` 失败时已把 `lastProbeError` 置为失败原因（第 127-131、143-151 行），但成功路径第 140 行才置 null。
- 影响：`ResourceCache._dirOf` 会在这个不可写目录下 `create(recursive: true)`，随后 `putFile`/`cacheUrlFile` 的 writeAsBytes/`.part` 写入抛异常被 catch（resource_cache.dart:199-201、284-294 行）静默失败，永久缓存完全不生效且用户无提示。
- 证据等级：静态推演

### lib/core/storage/storage_permission.dart:183-193 `resolveRootMode` 与 `resolveRoot` 判定条件不同，设置页显示的模式与实际路径可能不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条 / 第 5 条
- 依据：`resolveRootMode` 第 187-191 行只判 `isAllFilesAccessGranted() && _probeWritable(Directory(rootPath))` 就返回 `'root'`，不调用 `publicDir` 通道；`resolveRoot` 第 168-180 行还要依赖 `publicDir('downloads')` 是否返回非空。注释第 184-186 行声称「与 resolveRoot 同口径——声称的模式与实际生效路径一致」，但两次独立探测（一次 root 探针、一次通道）在时序上可能得出不同结果；`resolveRootMode` 在 root 探针失败时直接返回 `'download'`，而 `resolveRoot` 可能返回第 180 行的硬编码 `/storage/emulated/0/Download/...`（不是通道 candidate）。
- 影响：设置页「探测到的实际可写路径/存储模式」展示与实际使用的缓存根不一致，用户按提示去文件管理器找不到下载/缓存文件。
- 证据等级：静态推演

### lib/core/storage/storage_permission.dart:240-249 `_apiLevelFromOsVersion` 对 Android 9 及以下返回版本号本身（误标 API）
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条 / 第 17 条
- 依据：第 243-248 行 `if (name <= 9) return name; // Android 9 == API 28`：Android 9 返回 9、Android 8 返回 8，而 `needsLegacyWritePermission()`（第 253-257 行）、`requestStoragePermission()`（第 264-269 行）、`currentStrategy()`（第 310-318 行）把这些值当 **API level** 与 29 比较；注释自己写「Android 9 == API 28」却返回 9。`else` 分支 `return name + 19`（Android 10→29）与低版本段不连续。
- 影响：原生通道 `apiLevel` 不可用时，Android 9 及以下被判为极低 API（虽然仍走 legacy 分支但阈值判断失真），`isAndroid10Plus`、通知权限（第 289 行 `level < 33`）等判定失去准确性；用户侧表现为权限申请/降级策略与设备真实能力不符。
- 证据等级：静态推演（映射公式为实锤；真机兜底触发频率标注未实测）

### lib/core/storage/storage_permission.dart:18-21,333-353 `currentStrategy` 与 `resolveStrategy` 在 Android 10+ 从不检查 `publicDirWritable` 实测结果
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条 / 第 29 条
- 依据：`resolveStrategy` 第 300-306 行 `if (level >= 29) return StorageStrategy.mediaStore;`，`currentStrategy` 第 310-318 行同样按 level 直接返回；`isPublicDirWritable`（第 333-353 行）虽做了通道实测并在失败时写 `lastProbeError`，但这两个策略方法都不调用它。注释第 17-18 行「这是唯一权威的存储权限来源；permission_gate.dart 只负责 UI 层提示，两者共享同一套判定逻辑」与 `currentStrategy`/`resolveRoot` 各自独立判定的事实不符。
- 影响：策略层声称 mediaStore 可用但 `resolveRoot` 实际走的是 `Directory('$base/...')` 直写（并非 MediaStore 插入），在 scoped storage 下写入失败时永久缓存/下载静默降级，用户看不到错误原因。
- 证据等级：静态推演（范围外调用方未核，标注未实测）

---

## 专项判据汇总（视角 A 主判据逐项结论）

1. **三级缓存职责边界与命中顺序**：`ResourceGateway` 宣称「按 CacheScope 分派到内存/磁盘 JSON/永久文件三层」，但 `_memory`（L1）无 TTL/上限、与 `json()`/`file()` 无任何调用关系，且另有独立 `MemoryCache.instance` 单例；实际只有 L2（Hive `resource_json`）与 L3（文件系统）两层，L2 的 `json:`/`list:` 前缀由 ttl 反推，与键内 `scope` 段重复。→ 问题 3、7-1、7-6。
2. **cache_keys 的 ns/userid/schemaVer/scope 是否贯穿**：仅 `cacheKey()` 一条路径覆盖四维；`MemoryCache.keyOf`、`LyricPersistentCache._key`、`LyricTranslationCache._key`、`_hashName`、`SecureStorage` 的 `acct_token_` 全部自拼键；`CachedApiCall` 不暴露 schemaVer/scope/userid 覆盖参数；`ResourceCache._hashName` 的文件键完全不走 `fileIdentity()`（cache_keys.dart:47-48 定义后在本范围 9 文件中无任何调用）。→ 问题 2-1、2-4、5-4、7-4、8-2。
3. **CachedApiCall 与 RepositoryReads 双实现/键一致性**：确认为两套并行实现（不同 scope 判定、不同 TTL 来源、不同 POST extra、不同 ns、不同失效能力）。→ 问题「跨文件对照 1」（P0）。
4. **TTL 168h/90s 映射一致性**：`cacheTtl`（json=168h/list=90s）、`kJsonTtl=168h`/`kListTtl=90s`、`AppConfig.memoryCacheSeconds=90s` 数值当前恰好相等，但存在三套独立定义 + `CachedApiCall` 任意 ttl 覆盖 + `scope=file` 可传 36500 天到 JSON 层。→ 问题 3-3、5-1、「跨文件对照 2」、7-1。
5. **invalidateNs / clearLists / clearJson 语义**：`invalidateNs` 跨前缀按 `:$ns:u=` 子串删除但复用手写字符串而非 `cacheNsPrefix()`；`clearJson`+`clearLists` 合起来是全清 L2（与「只清 transient」注释不符）；三者都不清 L1 `_memory`、`_inFlight`、旧 Hive 箱与 L3 文件；`onUserChanged` 连 L2 都不清。→ 问题 3-2、7-6、7-7。
6. **永久文件 (URL,声明字节数) 四道校验**：`cacheUrlFile` 中「拒绝 bytes<=0」✅、「HEAD Content-Length 不符放弃」⚠（cl==0 放行）、「下载后实际长度」✅、「复用前长度」✅；但 `putFile/file/filePath` 三条公开 API 固定 bytes=0 身份且无校验，`fileIdentity()` 从未被调用，`_hashName` 为 32 位哈希。→ 问题 1-2、3-4、4-2、7-4、7-5、7-8。
7. **staleOnError 与 `__stale` 消费**：回退触发/次优/恢复条件齐备，但 `__stale` 写入返回值后本范围 9 文件及对照的 `repository_reads.dart`/`resource_gateway.dart` 无任何消费方，UI 无失败态。→ 问题 7-3。
8. **预加载只请求 JSON 不下载文件**：`_prefetchOne` 三次调用均为 `CachedApiCall.get`（JSON）；`onPlaybackCompleted` 是独立 hook，正常预热路径不下载实际文件 ✅（复核通过项）。但预热键 ns='prefetch' 与播放侧不同键、且 URL 预热只覆盖 kapi 路径。→ 问题 4-1、4-4。
9. **StoragePermission 下沉后 resolveRoot 唯一性**：`StoragePermissionService.resolveRoot()` 在本范围内确实是唯一根解析器（`ResourceCache._dirOf` 每次调用），但该方法自身有三条可能返回不同根的分支，且 `resolveRootMode`/`currentStrategy`/`resolveStrategy` 各自独立判定，权限态变化会使永久文件层整体失联。→ 问题 9-1、9-2、9-3、9-5。

