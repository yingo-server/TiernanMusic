# v5.1 交叉审查 B3 · 视角 C（用户路径与一致性）

- 报告文件：`docs/v51_cross_b3_c.md`
- 范围：`lib/core/cache/**`、`lib/core/resource/**`、`lib/core/prefetch/**`、`lib/core/storage/**`（9 文件 / 1444 行）
- 视角：真实用户路径、三态（匿名/普通/VIP）、生命周期、跨模块契约（B1 evaluateResponse / B2 播放响应异常）、v5.0 重构回归风险
- 判据：`docs/QUALITY_STANDARD.md`（冲突时优先）；只报问题，不含修复建议，未改任何代码文件
- 落盘方式：每读完一个文件立即 append

## 逐文件记录

### F1 `lib/core/cache/cache_keys.dart`（48 行，完整读）

### lib/core/cache/cache_keys.dart:33-45 query 值未经转义直接以 `&`/`=`/`:` 拼键，键不唯一
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度 / 请求身份不可歧义）
- 依据：`q[k] = v is Iterable ? v.join(',') : '$v'`，随后 `sorted.map((k) => '$k=${q[k]}').join('&')` 与 `'${scope.name}:$ns:u=$userid:$p:$qs:v$schemaVer$tail'`；值中的 `&`、`=`、`:`、`|` 均无转义。例：query `{'a':'x&b=y'}` 生成 `a=x&b=y`，与 query `{'a':'x','b':'y'}` 生成完全相同的字符串；`Iterable.join(',')` 同理可与含逗号的单值碰撞。`fileIdentity()` 也直接 `'$url|$declaredBytes'`，URL 自带 `|` 或 query 时身份不可分辨。
- 影响：用户输入含 `&`/`=` 的关键词、或以数组形态传 id 列表时，冷启动/下拉刷新可能命中另一个请求的缓存，展示与本次输入不符的列表；不同文件 URL 可能被判为同一身份而复用错误文件。
- 证据等级：静态推演（拼接规则为实锤，是否命中取决于上游实际 query 值，未实测）

### lib/core/cache/cache_keys.dart:30-33 注释「null 视为空串」与实现相反
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」且须与行为一致）
- 依据：文件头注释写「null 视为空串」，但 `query?.forEach` 内 `if (v == null) return;` 直接丢弃该键；而显式空串会生成 `k=`，两者键不同。
- 影响：无直接用户可见后果；但按注释推断「切号/失效维度」时会误判哪些请求共享同一键，v5.0 重构后按文档核对键唯一性的维护者会得出错误结论，间接放大串数据风险。
- 证据等级：实锤

### lib/core/cache/cache_keys.dart:24-27 维度覆盖依赖调用方自觉（userid 默认 '0'、schemaVer 全局单一）
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条
- 依据：`userid = '0'` 为默认值且无校验；`kCacheSchemaVer = 1` 是跨全部 ns 的单一版本号，`cacheKey` 无 ns↔版本映射。任何调用方漏传 userid 即与匿名态共享键；任一上游响应结构变更若提升该常量，会把首页/歌单 90s、歌词 168h、翻译等所有缓存整体击穿（还是不提升则新旧结构混读，两难）。
- 影响：切号/登出后若某路径漏传 userid，会看到上一账号的列表或歌词；版本提升后的首次冷启动全部回源，首帧变慢。此项需与调用方逐一核对，见后续文件记录。
- 证据等级：静态推演（默认值为实锤；漏传与否在后续文件核对）

### F2 `lib/core/cache/cache_manager.dart`（181 行，完整读）

### lib/core/cache/cache_manager.dart:125-131 `MemoryCache.keyOf` 自造键，无 userid / ns / schemaVer / scope 维度
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度）、第 5 条（同一事实单一来源）
- 依据：`keyOf(String path, [Map<String,dynamic>? query])` 仅返回 `'$path?${...join('&')}'`，与 `cache_keys.dart` 文件头「全仓**禁止**再自行拼 TTL 前缀或用户维度字符串；所有缓存读写必须经此文件生成键」以及 `cacheKey()` 的 `scope:ns:u=...:v...` 格式并存两套键格式；`MemoryCache.set` 默认 TTL 取 `AppConfig.memoryCacheSeconds`，与 `cacheTtl(CacheScope.list)=90s` 是第二个 TTL 事实源。
- 影响：任何仍走 `MemoryCache.keyOf` 的列表请求在切号/登出后 90s 内继续命中上一账号的首页/歌单数据；且新格式的 `cacheNsPrefix`（`:ns:u=`）无法匹配旧格式键，按 ns 的下拉刷新/写后失效对这些条目永不生效，用户下拉后仍看到旧数据。属于 v5.0 M3「缓存键唯一事实源」重构未收口的回归风险（是否实际命中取决于调用方，见 F3/F5/F6 核对）。
- 证据等级：静态推演（两套键格式并存为实锤；串数据需调用方使用该 API，待核对）

### lib/core/cache/cache_manager.dart:91-108 `_evict` 按首次插入序 FIFO，覆盖已存在 key 不刷新顺序
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（缓存上限策略须有据可依）、第 24 条（惰性/按需）
- 依据：`set()` 仅 `_cache[key] = _Entry(...)`，Dart 默认 `LinkedHashMap` 对已存在 key 的赋值不移动到末尾；`_evict()` 用 `_cache.keys.take(overflow)` 淘汰最旧的首次插入项。容量 200 时，长期反复刷新的首页/歌单热键因是最早插入的 k 个而优先被淘汰。
- 影响：用户下拉刷新后立即再次进入首页/歌单，缓存已被淘汰，冷启动首帧需重新回源，出现骨架屏/白屏闪烁；越是常访问的页面越容易被淘汰。
- 证据等级：静态推演

### lib/core/cache/cache_manager.dart:148-155 翻译缓存 `get()` 对磁盘内容零校验，`int.parse` 与分隔符未处理
- 级别：P1
- 违反：QUALITY_STANDARD 第 13/14 条（外部/磁盘数据必须逐分支验证后再使用）、第 9 条
- 依据：`for (final line in raw.split('\n')) { final idx = line.indexOf('\t'); if (idx > 0) map[int.parse(line.substring(0, idx))] = line.substring(idx+1); }`。`set()` 用 `'${e.key}\t${e.value}'` 写入，译文字符串本身允许含 `\t` 与 `\n`；含换行时下一行 `idx<=0` 被静默跳过（丢行），含非数字前缀时 `int.parse` 抛 `FormatException` 且本函数无捕获、无日志。
- 影响：用户切到已缓存过翻译的歌曲时，歌词翻译行号错位（译文与原文不同行）或歌词页直接抛未捕获异常显示错误态；译文尾部含换行时后半段译文永久丢失，且每次打开都复现。
- 证据等级：静态推演（写入/解析格式为实锤；上游译文是否含换行未实测）

### lib/core/cache/cache_manager.dart:140-143 翻译缓存键不含源歌词版本，且无 TTL/容量
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条、第 25 条
- 依据：`_key` 仅 `'$lyricId:$targetLang@${AppConfig.translateModel}'`；`set()` 直接 `put` 且 `clear()` 前无任何过期或条目数上限，注释只说明「换模型后旧键无效」。
- 影响：上游同一 lyricId 歌词被修订（错字/断句/新增行）后，用户看到的仍是按旧原文行号生成的译文，译文与原文逐行错位且无任何自动恢复时机；长期使用时 Hive 盒无限增长，低端机存储持续被占用。
- 证据等级：静态推演

### lib/core/cache/cache_manager.dart:35-41 损坏缓存体被静默删除，且 `decoded is! Map` 分支不清理
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测：用户可见反馈或日志二者至少其一）、第 14 条
- 依据：`catch (_) { await _box!.delete(...); return (null,null); }` 无日志、无返回值区分「损坏」与「从未缓存」；`if (decoded is! Map) return (null,null);` 完全不删除坏条目，后续每次 `getWithStale` 都短路。
- 影响：离线/弱网时用户原本可依赖的「过期旧歌词」被一次解析失败抹掉，歌词区空白且没有任何「缓存损坏」提示；结构异常（合法 JSON 但非 Map）时该 key 永远无法回退到旧歌词，直到一次成功的网络请求覆盖。
- 证据等级：实锤（代码事实）；用户实际触发频率未实测

### lib/core/cache/cache_manager.dart:18-21 / 133-136 两个单例各自 `_box ??= await Hive.openBox`，无 in-flight 合并
- 级别：P3
- 违反：QUALITY_STANDARD 第 18/22 条（并发前提须写明或保护）
- 依据：`init()` 无进行中 Future 复用；`LyricPersistentCache` 与 `LyricTranslationCache` 各自持有 `_box`，`clear()` 也先 `await init()`。
- 影响：冷启动首帧同时触发「歌词原文秒显」与「译文读取」时，两个开箱操作并发进入；`clear()`（清缓存）与 `get()` 竞态时可能读到清空后的空值，用户表现为切换歌曲时偶发歌词不显示。Hive 自身对同名 box 通常幂等，故影响有限。
- 证据等级：静态推演

### F3 `lib/core/cache/resource_gateway.dart`（74 行，完整读）

### lib/core/cache/resource_gateway.dart:26-30 `memoryGet/memoryPut` 无 TTL、无容量、无 userid 校验
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 23 条（用户身份维度）
- 依据：`final Map<String, Object> _memory = {}` 与 `memoryPut(String key, Object value) => _memory[key] = value`，不调用 `cacheKey()`、无 `cacheTtl()`、无 `_maxEntries`、无过期时间；门面文件头宣称「所有缓存读写与失效经此门面，内部按 CacheScope 分派」。L1 的过期语义实际完全由调用方是否自觉传规范化 key/自行清理决定。
- 影响：首页/歌单列表若经 L1 缓存，90s TTL 不生效，用户下拉刷新或 90s 后重进仍看到旧列表；进程长期驻留（听歌数小时）时 L1 无上限增长，低端机内存压力上升；若调用方 key 不含 u=，切号后 `onUserChanged()` 全清尚可兜住，但单次页面内频繁刷新不会失效。
- 证据等级：静态推演（无 TTL/上限为实锤；具体页面是否使用 L1 属跨模块调用，未实测）

### lib/core/cache/resource_gateway.dart:57-61 `onUserChanged()` 只清 L1，磁盘 L2 靠「键含 u=」被动不命中，L3 永久文件完全不隔离
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（用户身份必须进入缓存键）、第 16 条（语义分离）
- 依据：`onUserChanged() { _memory.clear(); }` 是同步 void，未调用 `ResourceCache` 任何清理；`json()` 默认 `userid='0'`，无必填校验；`file(url, kind, {declaredBytes=0})` 生成的身份仅 `(URL,bytes)`，`fileIdentity()` 无 userid 参数。旧账号数据仍留在磁盘，任何漏传 userid 或后续回填 `'0'` 的路径会立即串回上一账号内容。
- 影响：切号/登出后，未显式传 userid 的首页/歌单/歌词请求会读到旧账号的 168h 磁盘缓存（如个性化歌单、会员可见字段）；账号 A 缓存的会员音频文件对账号 B 直接可用，反之账号 B 看到 A 的下载/永久文件命中状态，「不串数据」只靠调用方纪律而非门面保证。
- 证据等级：静态推演（门面行为实锤；是否漏传 userid 需结合调用方，见 F5/F6）

### lib/core/cache/resource_gateway.dart:31-48 `scope` 默认 `json`(168h) 且 `staleOnError` 默认 true，列表调用方一漏参数即语义反转
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围与失败返回语义必须明确）、第 2 条（显式优于隐式）
- 依据：`CacheScope scope = CacheScope.json` 为默认值；`ttl: cacheTtl(scope)` 使首页/歌单这类列表一旦漏传 `CacheScope.list` 就按 168h 缓存；`staleOnError = true` 默认开启失效回退。
- 影响：冷启动首页/歌单列表本应 90s 缓存，漏参后一周内不回源，用户下拉刷新拿到旧榜单；断网时静默返回最多 168h 前的旧内容且无「离线」标识，用户以为已刷新成功。这是 v5.0 三级门面重构的典型回归面。
- 证据等级：静态推演（默认值为实锤；调用方是否漏参见后续文件核对）

### lib/core/cache/resource_gateway.dart:63-67 `invalidateNs` 的 L1 失效依赖字符串包含 `:ns:u=`
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（键格式应单一事实源）、第 23 条
- 依据：`_memory.removeWhere((k, _) => k.contains(':$ns:u='))` 直接内联匹配串，而 `cacheNsPrefix()` 已定义同样格式；由于 `memoryPut` 不强制用 `cacheKey()`，任何非规范 key（包括 F2 的 `MemoryCache.keyOf` 旧格式）都不会被失效，且无返回值/计数器说明清了几个。
- 影响：写操作（收藏/加歌单）后按 ns 失效，内存里的旧首页/歌单条目仍被读到，用户看到「已添加」提示但列表数字/内容不变，需等 TTL 或重启；失效是否生效不可观测。
- 证据等级：静态推演

### lib/core/cache/resource_gateway.dart:70-73 `clearTransient()` 未清翻译/歌词持久盒，与「清缓存」设置语义不符且不返回统计
- 级别：P2
- 违反：QUALITY_STANDARD 第 30 条（名称即文档/行为一致）、第 9 条（失败可观测）
- 依据：`clearTransient()` 仅 `ResourceCache.instance.clearJson()`、`clearLists()` 与 `_memory.clear()`；`LyricPersistentCache.clear()`、`LyricTranslationCache.clear()` 均未被调用（F2 中二者各自持有 Hive 盒）。方法无返回值，调用方无法知道清理了什么、是否失败。
- 影响：用户在设置页「清除缓存」后，磁盘占用几乎不下降，歌词 168h 缓存与译文仍在，用户会重复点击或误以为功能失效；清缓存不动永久文件的目标达成，但「临时缓存」边界与 UI 文案若承诺全部缓存则不一致（具体文案在 B8 范围，未实测）。
- 证据等级：静态推演

### F4 `lib/core/prefetch/prefetch_engine.dart`（211 行，完整读）

### lib/core/prefetch/prefetch_engine.dart:101-113 `updateUpcoming` 从 currentIndex 起算，「未来 15 首」实为当前 + 未来 14 首
- 级别：P2
- 违反：QUALITY_STANDARD 第 17 条（索引边界与契约一致）、第 30 条（名称/注释与行为一致）
- 依据：注释与方法名声明「播放队列未来 [window] 首补充」，`final start = ... ? 0 : currentIndex;`，`for (var i = start; i < queue.length && upcoming.length < window; i++)` 把 `queue[currentIndex]`（正在播放的这首歌）计入 window；`Song.hash` 非空时它占一个名额。
- 影响：第 15 首即将播放的歌始终没有预取播放地址/歌词 JSON，切到该首时比前 14 首多一次回源等待，表现为偶发缓冲或歌词晚出；队列边界（currentIndex 越界按 0 处理）时更把队首当「未来」预取，实际未来 14 首。
- 证据等级：实锤（循环边界）；真机缓冲时长未实测

### lib/core/prefetch/prefetch_engine.dart:88-94 / 104-111 `_startDrain` 每次入队取消并重建 periodic Timer，首个节拍可被反复推迟
- 级别：P2
- 违反：QUALITY_STANDARD 第 19 条（互斥闸门/同一所有者成对管理）、第 24 条（惰性按需、不延迟热路径）
- 依据：`_startDrain(spacing) { _drainTimer?.cancel(); _drainTimer = Timer.periodic(spacing, (_) => _drainOne()); }`；`enqueueSongs`、`updateUpcoming` 均无条件调用它，且没有「已有 timer 就不重建」的判断。首个 `_drainOne()` 只在 `spacing` 到期后执行。
- 影响：首页多个分区在首帧后连续调用预热、或切歌频繁触发 `updateUpcoming` 时，定时器反复重置，100ms/首的队列可以一直不消费；用户点第 1 首歌时预热缓存仍为空，「首帧不阻塞」变成了「预热迟迟不发生」，播放 URL 与歌词临时回源。
- 证据等级：静态推演（Timer 重建为实锤；页面调用频率未实测）

### lib/core/prefetch/prefetch_engine.dart:36-39 / 85-86 / 108-110 `_requested`、`_pending` 实际无上界，upcoming 可绕过 60 首上限
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）
- 依据：`final _requested = <String>{}`、`final _pending = <Song>[]`；`enqueueSongs` 用 `_maxEnqueuePerCall - _pending.length` 截断，但 `updateUpcoming` 直接 `_pending.insertAll(0, upcoming)`，无任何 `_pending.length` 检查；`_requested.add(song.hash)` 在 `dispose()` 之前从不移除，且键只有 hash（不含音质/userid/队列世代）。
- 影响：长听歌会话（数百首队列、反复切歌单）中内存集合持续增长，低端机内存上升；用户切换音质或切号后，同 hash 因 `_requested` 已存在而永久跳过预热，新音质/新账号的播放地址 JSON 始终不提前就绪，切歌时多一次等待。
- 证据等级：静态推演

### lib/core/prefetch/prefetch_engine.dart:155-195 预热主路径写死 kapi `/song/url` / `/search/lyric` / `/album/detail`，与「只走原生网关」及播放侧直连不对齐
- 级别：P1
- 违反：QUALITY_STANDARD 第 27 条（接口只走原生网关，中转仅可作为显式兜底并写明原因与清理计划）、REVIEW_SPEC 三-1
- 依据：`await cached.get('/song/url', query: {...})` 的注释明写「kapi /song/url，含音质参数；直连 /v5/url 不经 kapi 也无 JSON 可缓存，预热只覆盖 kapi 路径，直连由播放时解析」；另两个路径为 `/search/lyric` 与 `/album/detail`。`CachedApiCall` 以 `KugouApiClient` 为底座（见 F5），此处没有直连分支、没有「上游真实不可用才回退」条件，也无清理计划。
- 影响：冷启动首页后台发出 60×N 个中转网关请求，而实际播放走直连 `/v5/url`，预热结果对播放命中率基本无效；用户首播仍要等直连返回，且中转返回成功口径与原生不一致时，预热的「成功」日志会让线上误判预热可用。这是 B1/B2 原生网关契约与本批缓存层的跨模块不对齐。
- 证据等级：静态推演（本文件注释 + F5 待核对）；未实测

### lib/core/prefetch/prefetch_engine.dart:121-134 `onPlaybackCompleted` 无试听/预览判定，仅靠注释要求调用方判断
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围必须在接口层明确）、第 11 条（降级触发/退出条件）
- 依据：方法签名 `onPlaybackCompleted(String url, String kind, {int declaredBytes = 0})` 只有 url/kind/declaredBytes，无 `isPreview`、无来源世代、无响应体对象；注释「试听片段/通用预览不调用本方法（audio_handler 判 isPreview）」把唯一防线放在调用方；`declaredBytes` 默认 0，调用方漏传即静默不入库。方法 fire-and-forget，`catchError` 只 debugPrint，返回 `null` 后调用方无法区分「成功永久缓存」「身份不足被拒」「写盘失败」。
- 影响：B2 播放响应异常（返回试听片段但带正常 bytes 字段、或 bytes 字段缺失/为 0）时，试听片段可能被当作完整文件永久缓存，用户后续播放永远得到 30s 片段；反过来完整播放后若字段缺失则「永久缓存」静默失效，用户重复下载同一文件而不知情。用户路径「完整播放后永久缓存且试听绝不入库」在本层没有可验证的闸门。
- 证据等级：静态推演（接口事实为实锤；B2 响应字段形态需结合播放侧源码核对，未实测）

### lib/core/prefetch/prefetch_engine.dart:158-192 单首预热 3 个请求串行 await，但多首之间无并发上限
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（并发请求数必须有上限）
- 依据：`Timer.periodic` 每 100ms `_drainOne()` fire-and-forget 一次 `_prefetchOne(song)`；`_prefetchOne` 内 3 个 `await cached.get(...)` 串行，但 `_drainOne` 不等待完成，慢网时最多可累积「每 100ms 一首 × 3 请求」的并发，无计数器、无 pending 上限（前面的 `_pending` 本身也无界）。
- 影响：弱网/离线边缘时后台预热与用户当前播放、首页首帧争抢连接和带宽，表现为列表图片/歌词加载变慢；离线时每次节拍都失败并只写 debugPrint，用户无任何「离线」提示，但列表仍可能展示过期缓存，属于「失效回退用户不可感知」的上游放大器。
- 证据等级：静态推演

### F5 `lib/core/resource/cached_api.dart`（84 行，完整读）

### lib/core/resource/cached_api.dart:55-58 / 69-72 `ttl` 与 `scope` 双通道判定，除恰等 90s 外一律按 168h 键
- 级别：P1
- 违反：QUALITY_STANDARD 第 15 条（单位/量纲必须显式且全程一致）、第 23 条（TTL/scope 属影响结果的维度）
- 依据：`final scope = ttl == kListTtl ? CacheScope.list : CacheScope.json;` 用 `Duration` 相等比较推断 scope；`ttl: ttl ?? kJsonTtl` 又把 ttl 独立传给 `ResourceCache.json`。`kListTtl` 与 `cacheTtl(CacheScope.list)` 均为 90s，只有调用方显式传 `kListTtl` 才是 list 键；传 `kListTtl` 之外的任何列表 TTL（哪怕 90s±1ms）都得到 `json:...` 键但 90s TTL，而 `cacheTtl(CacheScope.json)` 声明为 168h；`ResourceGateway.json()` 走 `cacheTtl(scope)`，同一路径两种入口生成的键/TTL 组合不一致。
- 影响：首页/歌单列表在 `ResourceGateway` 与 `CachedApiCall` 两条入口之间互不命中（重复回源、冷启动首帧变慢），或同一逻辑列表同时存在 168h 键与 90s 键两份数据，用户下拉刷新后不同页面看到不同新旧内容。v5.0 三级门面重构后「唯一事实源」未覆盖 TTL↔scope 映射。
- 证据等级：实锤（两处比较与默认值）；具体调用方传参组合未实测

### lib/core/resource/cached_api.dart:20-27 / 54-82 缓存层不调用 B1 `evaluateResponse`，业务错误被当成功写进缓存
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（失败时返回语义须明确）、第 29 条（成功判定口径须逐端点确认）、第 23 条
- 依据：`get`/`post` 的 fetch 闭包直接 `() => _api.get(path, query: query)` / `_api.post(...)`，闭包返回 `Future<Map<String,dynamic>>` 后原样交给 `ResourceCache.json`；本文件没有任何状态码/err_code/status 判定，也没有引入 B1 的 `evaluateResponse`/`ResponsePolicy`。`CachedApiCall` 无 NS 与端点的成功口径表（REVIEW_SPEC 逐端点 status==1 / 200 / err_code==0 / 裸 Map 不统一）。
- 影响：B1/B2 在直连层用 `evaluateResponse` 判定的业务失败（如 `status=0`、err_code≠0、20028 登录态失效、播放地址返回试听/空 URL）若以普通 Map 形式回传，会被本缓存层按 TTL 缓存 168h 或 90s；用户下拉刷新、甚至重启后仍拿到「失败响应」渲染为空列表/错误内容，且 `staleOnError` 不会触发（因为没抛异常）。这是跨模块契约不对齐的核心回归风险。
- 证据等级：静态推演（本文件零成功判定为实锤；B1/B2 是否向本类注入该类响应需结合调用方，未实测）

### lib/core/resource/cached_api.dart:63-82 `post()` 可被缓存，写操作防重仅靠注释
- 级别：P1
- 违反：QUALITY_STANDARD 第 21 条（写操作必须幂等或有防重）、第 3 条（契约）
- 依据：类注释「写操作禁止走本类（防重与异常翻译另有语义）」，但 `post()` 是公开方法、无 path 白名单/黑名单、无「仅只读端点」校验；`post` 的 fetch 直接 `_api.post(path, data, query: query)`，且 `stale = true` 默认。`_keyOf` 把 body 摘要拼进键，同一 body 命中缓存后不会再次提交。
- 影响：任何业务调用方把 POST 写接口（收藏/评论/加歌单）接到这个类，首次提交成功后结果被缓存，用户重试「加收藏」时 UI 显示成功但服务端未再次变更；更糟的是异常回退 `stale=true` 会把上一次的写结果当作降级值返回，用户以为操作成功却无服务端状态。与 REVIEW_SPEC「`_directOrFallback` 写操作不得因回退重复提交」的口径形成两个方向的错配。
- 证据等级：静态推演（公开可缓存 post 为实锤；实际调用方是否误用未实测）

### lib/core/resource/cached_api.dart:30-49 `_bodyDigest` FNV 只取 `c & 0xff` 且 `_stableJson` 不转义、无类型标签
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界数据必须校验）、第 23 条（键须覆盖全部维度）
- 依据：`for (final c in s.codeUnits) { h ^= c & 0xff; ... }` 截断每个 codeUnit 为低 8 位；`_stableJson` 对 Map 键 `'"$k":' ...`、String `'"$v"'` 无转义，对 `null` 与空串同写 `''`（`v[k] ?? ''`），数字/布尔都走 `'$v'`。32 位 FNV 本身碰撞概率不可忽略，中文/emoji body 的低 8 位截断进一步放大碰撞，字符串 `1` 与数字 `1` 的稳定串也不同（此处反而造成同义不同键）。
- 影响：不同请求体（不同搜索词/不同 id/不同分页参数）可能撞进同一缓存条目，用户看到与本次操作不符的列表或详情；含引号/换行的正文会生成歧义串，触发同类串数据。
- 证据等级：静态推演（算法实锤；实际碰撞未实测）

### lib/core/resource/cached_api.dart:22-25 `userid` 依赖 `_api.userid`，登录态变化不刷新键中的「匿名/普通/VIP」
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（三态属影响结果维度）、第 5 条
- 依据：唯一用户维度为 `userid: _api.userid.isEmpty ? '0' : _api.userid`；无 VIP/会员等级、无登录方式、无 CookieJar 版本。匿名→登录（同一 userid 不变的过程态）、非 VIP→VIP、VIP 到期都不会改变键。
- 影响：用户开通会员或会员到期后 168h 内，缓存层仍返回按旧权益生成的音质/可播放字段，出现「已开通仍只能试听」或「到期后仍能播放高音质」的界面与结算不一致；切号时若 `KugouApiClient.userid` 更新晚于缓存读取（B1 CookieJar 时序），旧账号数据会被读到。
- 证据等级：静态推演

### F6 `lib/core/resource/lyric_translation_stream.dart`（36 行，完整读）

### lib/core/resource/lyric_translation_stream.dart:23-29 切歌瞬间 emit 无缓冲、无世代校验，译文补丁永久丢失或跨歌串入
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 16 条（缺失/失败语义分离）
- 依据：`emit(p)` 只检查 `_controller.isClosed` 后 `_controller.add(p)`；broadcast 流在无监听时事件直接丢弃（注释自认「UI 尚未订阅（切歌瞬间）时丢一批可接受，持久缓存兜底下次秒显」），但 `LyricTranslationCache.set()`（F2:157-165）不在本文件也不在 emit 路径，本文件不写任何持久缓存。`LyricTranslationPatch` 只有 `lyricId/startIndex/values`，无歌曲播放世代/请求 id；订阅端若不自行比对 lyricId，旧歌的迟到译文会按 startIndex 插到新歌歌词里。
- 影响：用户快速切歌时，前一首歌已完成的一批译文既没有写入持久缓存也没有缓冲，重回该歌需重新翻译等待；更严重的是旧歌译文迟到会被按行号插入当前新歌歌词区，出现译文与原文完全无关的错行内容。「翻译失败回退 / 原文秒显」路径在此无三态区分，失败与「无译文」都表现为空白。
- 证据等级：静态推演（broadcast 丢弃与无世代字段为实锤；订阅端是否比对 lyricId 在 B5 范围，未实测）

### lib/core/resource/lyric_translation_stream.dart:32-35 `dispose()` 关闭进程级单例流后无重建路径，热重载永久失声
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（生命周期双向对称：关闭必须有对称的重建/存活检查）
- 依据：`static final instance = LyricTranslationStream._()`，`final _controller = StreamController.broadcast()`；`dispose() => _controller.close()` 把 final 控制器关闭后，`emit()` 只剩 `if (_controller.isClosed) return;` 静默返回，没有任何 reopen/重新赋值路径。
- 影响：注释声称「仅测试/热重载场景调用」，但真机热重载后新的歌词页订阅的是已关闭的 stream，译文增量永不到达；用户看到原文正常但译文永远不出现，且无任何错误或日志。
- 证据等级：静态推演

### lib/core/resource/lyric_translation_stream.dart:14-17 注释宣称「缓存命中时也 emit 一次（UI 秒显）」但本类零缓存逻辑
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释复述了不存在的行为）
- 依据：本文件 36 行内没有 `LyricTranslationCache` / `LyricPersistentCache` import，也没有 `get/set` 调用；`emit` 需要外部主动调用，「缓存命中也 emit」不是本类职责。
- 影响：无直接可见后果；按注释推断「译文缓存命中必秒显」会误判歌词页行为，回归测试容易漏掉缓存命中未 emit 的分支。
- 证据等级：实锤

### F7 `lib/core/resource/resource_cache.dart`（331 行，完整读 1-170 + 171-331）

### lib/core/resource/resource_cache.dart:64-88 in-flight 写入不校验失效世代，下拉刷新后被旧请求回写覆盖
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 19 条（闸门归属同一所有者）
- 依据：`json()` 用 `_inFlight[key]` 合并请求，`_doFetch()` 在 `await fetch()` 成功后无条件 `await box.put(fullKey, ...)`；`clearLists()` / `clearJson()` / `invalidateNs()` 只执行 `box.deleteAll(keys)`，既不触碰 `_inFlight`，也不给写入方任何 generation/epoch 参数；`finally { _inFlight.remove(key); }` 只由首个调用者执行，无「我是否仍是当前持有者」判断。
- 影响：用户在首页下拉刷新（清 list 缓存）时，刷新前发出的慢请求返回后把旧一代响应写回箱里；本次刷新拿到的仍是旧数据，且接下来 90s 内再次下拉也命中这份旧数据。「下拉刷新立即生效」在慢网/并发下不成立，且用户无任何提示。
- 证据等级：静态推演（代码路径为实锤；真机时序未实测）

### lib/core/resource/resource_cache.dart:104-128 失效回退只有 `__stale` 打标与 verbose 日志，用户不可感知
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须产生用户可见反馈或可检索日志）、第 16 条（请求失败与确实为空语义分离）
- 依据：catch 分支 `unawaited(ErrorLogger.instance.log(...))` + `debugPrint` + `return Map<String,dynamic>.from(staleBody)..['__stale'] = true;`；注释自认「`__stale` 此前无任何消费方=假降级」，本文件与 `ResourceGateway` 均不检查该标记，`ResourceGateway.json()` 只是把 Map 原样返回。降级触发条件只有「fetch 抛异常」，退出条件靠下一次成功覆盖，但无 UI/Toast/状态位。
- 影响：断网或 B2 播放接口异常时，用户看到最多 168h 前（歌词/JSON）或任意旧（列表）的内容，界面与「刷新成功」完全一致；离线状态下收藏数/榜单/歌词修订看起来「明明变了又变回去」，用户无法区分「离线旧数据」「确实为空」「请求失败」。这是「网络断开时失效回退是否用户可感知」的直接答案：不可感知。
- 证据等级：实锤（无消费方、无 UI 状态）；B6/B8 是否另有 `__stale` 消费方未在范围内核对，未实测

### lib/core/resource/resource_cache.dart:234-297 永久文件身份四道校验不覆盖「试听片段」，bytes>0 即可入库
- 级别：P0
- 违反：QUALITY_STANDARD 第 14 条（外部数据边界必须校验）、第 3 条（契约：输入取值范围与幂等语义）、第 23 条（试听/全曲属影响结果的维度）
- 依据：`cacheUrlFile(url, kind, {declaredBytes = 0})` 的四道校验依次为 `declaredBytes<=0` 拒绝、已存在文件 `length()==declaredBytes` 复用、HEAD `content-length` 相等、下载后 `actual==declaredBytes`；签名中没有 `isPreview`、没有时长、没有「来源为完整播放响应」的凭据。`kind` 由调用方任意传。注释称「试听/全曲……只要声明字节数不同就是不同资源」，但试听片段的声明字节数同样是正数，四道校验全部通过；`PrefetchEngine.onPlaybackCompleted`（F4:121-134）也把 isPreview 判定完全推给调用方。
- 影响：B2 播放响应异常返回 30s 试听（含正确 bytes 字段）且被判为完整播放后，试听片段被写入永久目录；随后同一 (URL,bytes) 命中复用，用户后续每次播放该歌都只听到片段，且清缓存不动永久文件，错误文件永久驻留、无法自愈。属用户数据/资源内容损坏，且「试听片段绝不入库」这一硬口径在缓存层没有任何强制点。
- 证据等级：静态推演（校验点为实锤；B2 响应是否含试听且 bytes>0 需结合播放侧核对，未实测）

### lib/core/resource/resource_cache.dart:176-190 / 198-231 / 260-284 文件读写两套身份：putFile/file/filePath 用 url|0，cacheUrlFile 用 url|declaredBytes
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（同一事实单一来源）、第 3 条（契约返回值语义）、第 23 条
- 依据：`putFile(String key, List<int> bytes)`、`file(String key)`、`filePath(String key)` 都调用 `_hashName(key)`（默认 `bytes = 0` → `'$url|0'`）；`cacheUrlFile` 调用 `_hashName(url, bytes: declaredBytes)` → `'$url|$declaredBytes'`；`cache_keys.dart:48` 另有唯一事实源 `fileIdentity(url, declaredBytes)`，本文件完全不引用，自行拼 `'$url|$bytes'` 与自有 FNV。`ResourceGateway.file()` 只暴露 `cacheUrlFile`。
- 影响：完整播放后文件确实落盘，但通过 `filePath(url)` / `file(url)` 读取永远返回 null；当上层用这三者之一判断「已永久缓存」时会重复下载、重复写盘，用户消耗流量且看不到缓存生效。两套身份还意味着同一 URL 的不同 bytes 版本与「无 bytes 版本」并存，磁盘出现两份永远不会被清理的副本。
- 证据等级：实锤（哈希输入不同）；上层具体调用哪个 API 未实测

### lib/core/resource/resource_cache.dart:262-267 / 277-282 文件下载无 in-flight 合并，同名 `.part` 并发写导致永久缓存内容损坏
- 级别：P0
- 违反：QUALITY_STANDARD 第 18/22 条（并发假设必须写明或保护）、第 21 条（写操作防重）
- 依据：`cacheUrlFile` 全程没有类似 `json()` 的 `_inFlight` 合并；`final part = File('${target.path}.part')`、`await dio.download(url, part.path)`，两个并发调用（同 URL 同 bytes，例如连续两首切回或 completed hook 被触发两次）共用同一个 `.part` 路径；最终都 `await part.rename(target.path)`，第二次 rename 可能作用于已被第一次改名后不存在的路径，或两者交错写入产生混合字节；`actual == declaredBytes` 的长度校验无法检出等长的内容错乱。类注释只声明 JSON 的「Dart 单 isolate，Map 即互斥点」，文件下载路径无并发说明。
- 影响：用户完整播放后再次快速切回同一首，永久缓存文件可能变成两路字节混合的损坏音频，后续命中该文件时播放杂音/直接失败；由于文件永久不淘汰且长度校验通过，损坏会一直复现。
- 证据等级：静态推演（无并发保护为实锤；真机复现未实测）

### lib/core/resource/resource_cache.dart:271-275 HEAD 失败即整体放弃，完整播放后的永久缓存静默失效
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级触发/退出条件）、第 9 条（失败可观测）
- 依据：`final head = await dio.head(url); final cl = int.tryParse('${head.headers.value('content-length') ?? ''}') ?? 0; if (cl > 0 && cl != declaredBytes) return null;`。HEAD 请求本身抛异常（CDN 对 HEAD 返回 405/403/超时）时直接落入最外层 `catch`，`debugPrint` 后返回 null；没有跳过 HEAD 直接 GET 的次优行为，也没有对 405 的已知条件分支。`Dio` 实例每次新建且未 `close()`（第 20 条资源不对称）。
- 影响：很多 CDN 不支持 HEAD 或声明长度与 JSON 口径不同（含 gzip/Range 差异）时，每次完整播放都无法永久缓存，用户每次都要重新流式加载同一文件；失败只写 debugPrint，界面无任何「缓存未生效」提示，重复消耗流量却不知原因。
- 证据等级：静态推演（HEAD 单点失败为实锤；具体 CDN 行为未实测，REVIEW_SPEC 第 28/29 条要求实测留样，本处无样）

### lib/core/resource/resource_cache.dart:227-229 / 303-330 永久文件无体积上限、无任何删除入口，注释却称「淘汰交由设置页 clear*」
- 级别：P1
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 31 条（注释与行为一致）、第 32 条
- 依据：`_dirOf(kind)` 直接 `Directory('$root/cache/resource/$kind')`，`kind` 作为路径段未经校验；`clearJson()` / `clearLists()` / `invalidateNs()` 都只操作 Hive JSON 箱，本文件没有 `clearFiles()` 或按 kind 删除文件的方法，`ResourceGateway.clearTransient()` 也不碰文件目录。`kFilePermanent = null` 被注释为「占位常量，按契约保留」却无任何引用；类注释称「实际资源文件永久缓存……永久不淘汰，淘汰交由设置页 clear*」与不存在的方法矛盾。`dio.download` 无最大字节数限制（仅 10 分钟 receiveTimeout）。
- 影响：用户长期听歌后外置/内部目录被永久音频占满，低端机出现「存储空间不足」、后续缓存写入失败（只 debugPrint），但设置页「清缓存」永远清不掉这些文件，用户只能靠卸载应用或手动找目录；清缓存不动永久文件的口径被满足，代价是无退出条件。
- 证据等级：实锤（无删除入口 + 注释矛盾）；存储耗尽未实测

### lib/core/resource/resource_cache.dart:131-149 损坏缓存删除不 await、不记日志，形态异常分支永不清理
- 级别：P2
- 违反：QUALITY_STANDARD 第 6 条（禁止吞异常）、第 9 条（失败可观测）、第 14 条
- 依据：`catch (_) { box.delete(key); return null; }` 删除 Future 未 await、无 catch；`if (decoded is! Map) return null;`、`if (storedAt is! int || body is! Map) return null;` 三个分支都不删除坏条目、不打日志。`storedAt` 用 `DateTime.now().millisecondsSinceEpoch` 比较 `now < storedAt + ttl.inMilliseconds`，无时钟回拨/未来时间校验。
- 影响：Hive 写入失败（磁盘满）时 `box.delete` 自身抛未处理异步异常；合法 JSON 但结构损坏的条目占据 key，导致该 key 永远无法进入失效回退，离线时歌词/列表直接失败而非显示旧值。用户设备时间被调快后所有缓存立即「过期」→ 冷启动全量回源变慢；调慢后 90s 列表缓存长期不刷新，下拉刷新拿旧数据。
- 证据等级：静态推演（代码事实实锤；时钟/磁盘场景未实测）

### lib/core/resource/resource_cache.dart:12-14 / 64-67 / 77-80 TTL 三处事实源、in-flight 键不含 scope
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条、第 15 条（单位须显式且全程一致）、第 23 条
- 依据：本文件 `const kJsonTtl = Duration(hours:168)`、`kListTtl = Duration(seconds:90)`、`kFilePermanent = null`；`cache_keys.dart:24-27` 另定义 `cacheTtl(CacheScope.json)=168h / list=90s / file=36500d`；`cached_api.dart:55` 又用 `ttl == kListTtl` 反推 scope。本文件 `final isList = ttl == kListTtl; final fullKey='${isList ? _listPrefix : _jsonPrefix}$key'`，`_inFlight` 却以未带前缀的 `key` 为键。
- 影响：同一 path/query 以 168h 与 90s 两种 ttl 并发调用时共用一个 in-flight Future，后发起者拿到按另一 TTL 语义缓存的数据；任一常量被改动后首页 90s 与歌词 168h 语义同时漂移，v5.0「唯一事实源」重构回归风险高。
- 证据等级：实锤（常量重复定义与键前缀差异）

### lib/core/resource/resource_cache.dart:83-86 / 90-101 `init()` 失败后全量回源且无任何用户/日志可见的降级状态
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 11 条（降级须有明确触发与退出条件）
- 依据：`catch (e) { debugPrint('[resource] openBox($_boxName) failed: $e'); _box = null; }`；`json()` 在 `box == null` 时仍继续 `fetch()` 并 `return data`，无内存兜底、无标志位、无重试/恢复策略，`_doFetch` 的写缓存分支 `if (box != null)` 直接跳过。
- 影响：Hive 开箱失败（B4 启动顺序异常、磁盘只读）时，冷启动首页/歌单每次都走网络，歌词 168h 原文秒显完全失效、离线时直接报错；用户只看到加载慢/失败，无任何可诊断信息，`__stale` 也永远不会有旧值可用。
- 证据等级：静态推演

### lib/core/resource/resource_cache.dart:96-101 / 104-112 成功写入不做响应成功判定，也不校验可序列化内容
- 级别：P1
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径逐端点确认）、第 3 条（失败返回语义）、REVIEW_SPEC 三-4
- 依据：`final data = await fetch();` 之后无条件 `jsonEncode({'storedAt':..., 'body': data})` 并 `return data`；无 `status==1` / `status==200` / `err_code==0` / 裸 Map 分端点判定，无 B1 `evaluateResponse`/`ResponsePolicy` 调用，也不校验 `data` 是否含错误码字段。`jsonEncode` 抛异常时也只 debugPrint，不影响返回。
- 影响：B1/B2 直连层的业务失败响应（登录态 20028、试听/无版权、err_code≠0）以 Map 返回即被缓存 168h/90s，用户在恢复登录、切换账号、网络恢复后仍看到旧的错误数据，下拉刷新也无法摆脱（`staleOnError` 仅在抛异常时触发）。跨模块「成功判定」契约在缓存层完全缺失。
- 证据等级：静态推演（无判定为实锤；上游是否把失败当 Map 返回需结合 B1/B2，未实测）

### F8 `lib/core/storage/secure_storage.dart`（124 行，完整读）

### lib/core/storage/secure_storage.dart:76-86 `clearCredentials` 与 `saveCredentials` 的 dfid 语义自相矛盾，登出后设备票据可跨账号串用
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（同一状态多处修改且不一致）、第 23 条（身份维度须进入缓存/凭证键）
- 依据：`saveCredentials` 对 `dfid == null` 执行 `_storage.delete(key: _kDfid)`（注释「切号时新响应常不带 t1/auth，保留旧值会造成 A 账号票据配 B 账号 token 的串号」），而 `clearCredentials` 的 F-1 注释改口「dfid 属于设备不属于账号」，保留 `_kDfid` 不删；`clearCredentials` 也只在传入 `userid` 时删 `acct_token_<userid>`，无 userid 时全部账号切换 token 残留。
- 影响：用户登出后换另一账号登录，若登录响应不带 dfid（切号常见），`saveCredentials` 会删掉设备 dfid，与 F-1「避免每次被判新设备」的目标相反，用户遭遇风控验证/试听降权；若不走 saveCredentials 直接以保留的 dfid 发请求，则设备票据与上一账号会话残留（acct_token 未删）共存，共享设备上可直接无密码切回上一账号。「切号/登出后不串数据」在凭证层不一致。
- 证据等级：静态推演（两处注释/行为相反为实锤；登录响应 dfid 形态未实测）

### lib/core/storage/secure_storage.dart:29-40 五个键的写入/删除并发 `Future.wait`，无原子性、异常时部分落盘
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（失败时返回语义须明确）、第 5 条（登录态单一事实源）、第 21 条（写操作幂等/防重）
- 依据：`ops` 里 token/userid/t1/auth/dfid 的 `write`/`delete` 全部同时发起，`await Future.wait(ops)` 无顺序、无事务、无「失败回滚」；`readCredentials()` 只要 `token != null && userId != null` 就返回 `Credentials`。Keystore 在部分写失败时（磁盘满/加密异常）无任何补偿，异常直接抛给调用方但部分键已写入。
- 影响：切号过程中任一键写入失败，用户会拿到「B 账号 userId + A 账号 token/dfid」的混合凭证，后续首页/歌单请求以错误身份回源，表现为歌单为空、个人信息错乱或 20028 反复要求登录；由于 `clearCredentials` 也可能部分失败，登出后仍能恢复出一个「半登录」态。与 B1 CookieJar 时序、`CachedApiCall` 的 `userid` 取值直接串联。
- 证据等级：静态推演（并发写为实锤；Keystore 部分失败概率未实测）

### lib/core/storage/secure_storage.dart:40 / 46-62 / 76-86 登出/切号不通知缓存层，缓存隔离完全依赖调用链顺序
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（生命周期/世代校验）、第 23 条
- 依据：`SecureStorage` 无任何 `ResourceGateway` / `ResourceCache` / `onUserChanged` 引用；`clearCredentials()`、`saveCredentials()` 返回 `Future<void>` 且不产生账号世代标识。缓存层的 `userid` 取自 `_api.userid`（F5:22-25），`ResourceGateway.onUserChanged()` 只清内存（F3:57-61）。
- 影响：切号/登出若在 `onUserChanged()` 之前就有在途的列表/歌词请求，其返回结果按旧 userid 写入磁盘；新账号随后读到旧账号缓存（168h 歌词/90s 列表）。凭证变更与缓存失效两个生命周期无契约绑定，属于 v5.0 重构后的账号切换回归风险。
- 证据等级：静态推演（跨模块调用顺序未在范围内核对，未实测）

### lib/core/storage/secure_storage.dart:96-103 多账号 token 只有单条删除，无「清空所有账号」入口
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（写入/清除对称）、第 5 条
- 依据：`saveAccountToken` / `readAccountToken` / `deleteAccountToken` 按 `'acct_token_$userid'` 单键操作；`clearCredentials({String? userid})` 只在 userid 非空时删一个键；FlutterSecureStorage 无枚举键 API，本类也未维护已写入 userid 集合。
- 影响：用户多次切号后退出登录且调用方未传 userid，其他账号的切换 token 永久留在加密存储里，共享设备上的下一位使用者仍可无密码切回这些账号；用户手动「清除应用数据」之外没有清理路径。
- 证据等级：实锤（无批量删除入口）；具体调用方是否传 userid 未实测

### lib/core/storage/secure_storage.dart:46-62 `readCredentials` 对 token/userId 只判 null，空串被视为有效登录态
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（外部/平台通道数据必须校验）、第 16 条（未登录与已登录语义分离）
- 依据：`if (token == null || userId == null) return null;` 无 `isEmpty`/空白/格式校验；返回 `Credentials(token: token, userId: userId, ...)`。
- 影响：Keystore 里残留空串凭证时，应用把「未登录」误判为「已登录但 userid 为空」，缓存键回落到 `'0'`（F5 `userid.isEmpty ? '0'`），首页/歌单以匿名态回源却又显示登录 UI，三态（匿名/普通/VIP）边界错乱；用户反复重启也保持该错误态直到手动清数据。
- 证据等级：静态推演

### F9 `lib/core/storage/storage_permission.dart`（355 行，完整读 1-180 + 181-355）

### lib/core/storage/storage_permission.dart:158-171 实测写探针失败时仍返回不可写路径，永久缓存写入落到 debugPrint 黑洞
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发条件与次优行为）、第 9 条（失败必须可观测）
- 依据：`final candidate = '$base/$fallbackRootDirName'; if (await _probeWritable(Directory(candidate))) return candidate; debugPrint(...); return candidate; // 通道给了真实路径：即使探测失败也返回（调用方各有降级）`。注释声称「调用方各有降级」，但本范围内唯一消费方 `ResourceCache._dirOf()` 是 `final root = await resolveRoot(); final dir = Directory('$root/cache/resource/$kind'); await dir.create(recursive:true);`，无备用根、无异常分支；`putFile`/`cacheUrlFile` 写失败只 `debugPrint` 后返回 null。最后的保守兜底 `'/storage/emulated/0/Download/$fallbackRootDirName'` 更是完全没有探测。
- 影响：用户拒绝了「所有文件访问」、或 ROM/SD 卡让 Download 目录只读时，设置页显示的是一条「探测到的实际可写路径」，实际一个字节都写不进去；完整播放的永久缓存、日志、下载文件静默失败（无 Toast/无错误态），用户反复播放仍重新下载，且在 Android 10+ 直接写 `/storage/emulated/0/...` 受 scoped storage 限制，失败概率更高。这正是「外置目录授权/降级的实际可写路径」要求的反例。
- 证据等级：静态推演（返回不可写路径 + 消费方无降级的链路为实锤；真机 ROM 行为未实测）

### lib/core/storage/storage_permission.dart:181-187 `resolveRootMode()` 与 `resolveRoot()` 可给出互相矛盾的模式名
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（同一事实单一来源）、第 31 条（注释与行为一致）
- 依据：`resolveRootMode()` 独立再跑一次 `isAllFilesAccessGranted() && _probeWritable(...)` 返回 'root'/'download'；`resolveRoot()` 在通道返回路径且探针失败时仍返回该路径（F9 第一条），在授权态为真但探针失败时返回 Download 路径。两次探测时点不同（用户刚在系统设置页授权/撤销、或 SD 卡被卸载）就会不一致；注释声称「与 resolveRoot 同口径——声称的模式与实际生效路径一致」。
- 影响：设置页显示「根目录模式」，实际文件却写到 Download（或反之），用户按显示路径去文件管理器找下载/歌词/永久缓存文件找不到；授权后 UI 不更新或显示错误模式，用户以为授权没生效而反复跳设置页。
- 证据等级：静态推演

### lib/core/storage/storage_permission.dart:44-50 / 155-171 两套根目录拼写（`TierNanMusic` vs `TiernanMusic`）随授权态切换
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（同一份事实单一来源）、第 16 条（状态语义分离）
- 依据：`rootDirName = 'TierNanMusic'`、`rootPath = '/storage/emulated/0/$rootDirName'`；`fallbackRootDirName = 'TiernanMusic'`，Download 降级用后者。注释说明是用户拼写保留，但授权态变化会让同一用户的文件分裂到两个根；`resolveRoot()` 无任何迁移/合并/提示逻辑。
- 影响：用户在设置里授予「所有文件访问」后，之前下载/永久缓存的音频仍在 `Download/TiernanMusic`，新文件写到 `/storage/emulated/0/TierNanMusic`；文件管理器出现两个相似目录，用户找不到旧文件、误以为数据丢失，且永久文件缓存（ResourceCache）按新根重新下载一遍。
- 证据等级：实锤（常量与分支）；文件系统实际表现未实测

### lib/core/storage/storage_permission.dart:207-221 Android 版本名→API 映射漏掉 Android 9 且 `Android 9 == API 28` 注释与代码冲突
- 级别：P1
- 违反：QUALITY_STANDARD 第 14 条（平台通道/版本边界必须校验）、第 13 条、第 15 条（单位/取值显式）
- 依据：`if (name <= 9) return name; // Android 9 == API 28` 返回 9，而 `needsLegacyWritePermission()` 用 `level < 29` 判定、`apiLevel()` 通道正常时拿的是真正 API 级别；`if (name == null) return 29`。Android 9 实际 API 28，Android 8 是 26/27，Android 7 是 24/25，映射 `name + 19` 只对 Android 10(29) 及以上成立，`name<=9` 分支全错。注释自称修正了「把 Android 10(API 29) 误判成 API 10」。
- 影响：原生通道返回 0（ROM 不实现 `apiLevel`）的 Android 9 及以下设备，映射值 1..9 被当成 API 级别：`resolveStrategy()` 走 `requestStoragePermission()`（尚可），但 `isAndroid10Plus()` 恒 false、`needsLegacyWritePermission()` 返回 true，MediaStore 分支永远进不去；在 Android 10+ 若版本名含「Android 9」之外的小版本或厂商改写字符串时 `name==null` 直接按 29 处理，导致 Android 9 设备误走 mediaStore 策略，公共目录写入被拒，用户下载/永久缓存静默失败。
- 证据等级：静态推演（映射算术为实锤；厂商版本名形态未实测）

### lib/core/storage/storage_permission.dart:305-316 `resolveStrategy()`/`currentStrategy()` 只凭授权态返回 directPath，不做写探针
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级触发条件必须明确）、第 29 条（结论须可追溯到实测）
- 依据：`resolveStrategy()` 第一条 `if (await isAllFilesAccessGranted()) return StorageStrategy.directPath;`；`currentStrategy()` 同样；`isAllFilesAccessGranted()` 只读 `Permission.manageExternalStorage.isGranted`。而 `resolveRoot()` 注释强调「不再信授权态缓存，每次实测写入能力」。`isPublicDirWritable()` 有原生探测但这两个策略方法完全不调用。
- 影响：授权态为真但目录不可写（F9 第一条场景），上层拿到 `directPath` 策略直写 `/storage/emulated/0/TierNanMusic`，每次写入抛异常被 `debugPrint` 吞掉；用户看到「已授权」但下载/缓存一直失败，且没有降级到 `appFallback`（App 私有目录）这一已知次优行为。权限网关与实际可写路径脱节。
- 证据等级：静态推演

### lib/core/storage/storage_permission.dart:319-326 `currentStrategy()` 的 `Permission.storage.status` 无异常捕获
- 级别：P2
- 违反：QUALITY_STANDARD 第 6/7 条（捕获必须精确到可处理类型且不吞）、第 9 条
- 依据：同文件 `requestStoragePermission()` 对 `Permission.storage.status` 包了 try/catch + `lastProbeError`，而 `currentStrategy()` 直接 `final status = await Permission.storage.status;`，无 try/catch、无留痕。`apiLevel()` 的异常已吞成 0 并兜底。
- 影响：Android 9 及以下设备权限插件抛平台异常时，设置页/权限网关读取当前策略直接崩溃或显示错误态（无日志），用户无法进入「存储模式」页面确认降级路径；`lastProbeError` 也不会记录原因。
- 证据等级：静态推演（异常未捕获为实锤；插件是否抛未实测）

### lib/core/storage/storage_permission.dart:101 / 92-99 `lastProbeError` 为进程级静态可变状态，多个 resolveRoot 并发互相覆盖
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 5 条（全局状态多处修改）
- 依据：`static String? lastProbeError;` 在 `isAllFilesAccessGranted`、`requestAllFilesAccess`、`_probeWritable`、`resolveRoot`、`apiLevel` 等多个异步路径中赋值；`_probeWritable` 每次成功都写 `lastProbeError = null`，失败写原因；`resolveRoot()` 在降级分支读取 `lastProbeError ?? '-'`。`ResourceCache._dirOf()`（每次文件读写）、ErrorLogger、下载模块都会并发调用 `resolveRoot()`。
- 影响：一次成功的探测把另一次失败探测的原因清成 null，设置页「探测到的实际可写路径」区域时有时无；用户按日志排查「为什么缓存没写进去」时看到的是无关路径或空值，无法定位。
- 证据等级：静态推演

### lib/core/storage/storage_permission.dart:114-140 `_probeWritable` 探针文件带时间戳命名，并发/异常残留文件永久留在用户目录
- 级别：P3
- 违反：QUALITY_STANDARD 第 20 条（资源对称释放）、第 25 条（上限）
- 依据：`'/.tm_probe_${DateTime.now().millisecondsSinceEpoch}.tmp'`；写探针、读回、删除三步，只有 `readBack != payload` 分支直接 `return false` 而不删除探针；异常分支尝试删除但 `catch (_) {}` 静默失败。注释称「下一个探针换名，不冲突」。
- 影响：用户在根目录模式下打开文件管理器可见 `.tm_probe_*.tmp` 垃圾文件；读回不一致或删除失败时每探测一次留一个文件，目录里逐渐累积，且无任何清理入口（清缓存不碰该目录）。
- 证据等级：实锤（分支未删除）

## 跨模块契约核对（完整读上游业务代码，非范围文件不计入 9 文件）

已完整读：`lib/core/domain/response_policy.dart`(141)、`lib/core/foundation/errors.dart`(33)、`lib/core/config/app_config.dart`(56)、`lib/core/api/kugou_api_client.dart`(193)、`lib/core/api/translate_api.dart`(116)、`lib/core/direct/kg_play_api.dart`(507)、`lib/core/direct/kg_direct_api_client.dart`(654)、`lib/core/direct/kg_endpoints_media.dart`(131)、`lib/core/direct/kg_providers.dart`(109)、`lib/core/net/music_api.dart`(62)、`lib/app/di.dart`(40)、`lib/app/bootstrap.dart`(80)、`lib/core/utils/permission_gate.dart`(92)、`lib/features/home/data/home_repository.dart`(198)、`lib/features/lyric/data/lyric_repository.dart`(276)、`lib/features/lyric/presentation/lyric_view.dart`(379)。

### 更正 F5 第 2 条（缓存层不调用 B1 evaluateResponse 的定性）
- 事实：`KugouApiClient` 构造时的 `onResponse` 拦截器（:38-57）已对 `Map<String,dynamic>` 响应统一调用 `evaluateResponse`，失败 `handler.reject(DioException(error: ApiException))`；`KgDirectApiClient._wrap`（:76-80）同样调 `evaluateResponse`；`KgPlayApi.PlayUrlResult.fromResponse`（:333-336）也先 `evaluateResponse` 再解析。故「业务失败响应被直接写进缓存」对本范围默认装配路径**不成立**，F5 第 2 条应降级为下列可证的不对齐点，证据等级改为静态推演/部分未实测。以下四条为新结论。

### lib/core/cache/resource_gateway.dart:20-24 + lib/core/net/music_api.dart:41-48 缓存层与 B1 判定单点未对齐：直连路径绕过拦截器，成功判定只靠 `_wrap`
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（跨层契约：失败时返回语义须单一且稳定）、第 29 条（成功判定口径逐端点确认）
- 依据：`MusicApi.of(KugouApiClient)` 与 `CachedApiCall` 的 fetch 都调到 `KugouApiClient.get/post`；`app/di.dart:13-15` 把 `kugouApiClientProvider` 装配为 `KgDirectApiProvider`（`KgDirectApiClient`），其 `get/post` 覆写为 `_directOrFallback(() => _epXxx(q), kapi, ...)`，直连分支走 `KgClient.request` → `KgResponse`，**不经过 Dio 的 `onResponse` 拦截器**。直连分支唯一的成功判定是 `_wrap()` 里的 `evaluateResponse(r.body, ssaCode: r.ssaCode)`；`KgClient` 把网络异常折成假 502 `KgResponse`（`kg_play_api.dart:335-338` 明确提到「HTTP 层异常（kg_client 把 DioException 折成 502 假响应）」），而 `_wrap()` 不检查 `r.status`，只判 body。`MusicApi.evaluate()` 暴露 `evaluateResponse` 给 L4，但 `CachedApiCall` / `ResourceCache` / `ResourceGateway` 都不调用它。
- 影响：直连层 body 为裸 Map 但 HTTP 为假 502（网关超时/风控空包带残留字段）时，`_wrap` 可能判成功，`ResourceCache._doFetch` 无条件 `box.put` 缓存 168h/90s；用户在网络恢复、重新登录后仍拿到空/错的列表或歌词，且 `staleOnError` 不触发（未抛异常）。B1「成功判定唯一出口」在缓存链路里没有强制点，属 v5.0 M4 迁移后的跨模块回归口。
- 证据等级：静态推演（装配与覆写链为实锤；假 502 的具体 body 形态未实测）

### lib/core/prefetch/prefetch_engine.dart:160-167 / 176-178 + lib/features/lyric/data/lyric_repository.dart:31,39-45,112 预热与实播使用不同 ns/不同 query/不同 TTL，预热结果永不命中
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（同一缓存键唯一事实源）、第 23 条（键须覆盖全部维度）
- 依据：`attach()` 构造 `CachedApiCall(api, ns: 'prefetch')`；`LyricRepository` 构造 `CachedApiCall(_api, ns: 'lyric')`，`cacheKey()` 把 ns 拼进键首段。预热 `/search/lyric` 只传 `{'hash': song.hash}`，实播 `findCandidate` 传 hash/keywords/album_audio_id/duration 的可选组合并显式 `ttl: Duration(minutes:30)`；预热 `cached.get('/search/lyric', query: ...)` 不传 ttl → `kJsonTtl=168h` + `json:` 前缀。预热 `/song/url` 传 `quality: song.quality.value` 等 4 参，实播走 `KgDirectApiClient` 的 `/v5/url`（`kg_endpoints_media.dart:70-98`）且 `KgSharedParams.songUrl` 另有 `freePart/IsFreePart/page_id/ssa_flag` 等 15+ 参数；`KgDirectApiClient.get` 的 `case 'song/url'` 直连返回体无 `filesize` 之外的 kapi 兼容保证。
- 影响：冷启动后台 60 首预热全部写入 `prefetch` 命名空间的独立缓存，播放时按 `lyric`/`player` 命名空间重新回源；用户感知为「预热跑满了但首播依然等歌词/等 URL」，后台流量白白消耗。歌词「168h 缓存与原文秒显」口径也与真实 30min TTL 不符——同一首歌每 30 分钟重回源一次，离线时 `staleOnError` 最多只有 30 分钟内的旧值可用。
- 证据等级：实锤（ns / ttl / query 三处不一致）；真机命中率未实测

### lib/core/resource/resource_cache.dart:104-128 + lib/features/home/data/home_repository.dart:36-38 / lib/features/lyric/data/lyric_repository.dart:41-44 `__stale` 打标在所有实际调用方均无消费，网络断开回退完全不可感知
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条、第 16 条
- 依据：`HomeRepository._cachedGet` 直接 `return _cached.get(path, query: query, ttl: kListTtl)`；`LyricRepository.findCandidate` / `_fetchLyricByFormat` 直接 `await _cached.get(...)`；三处都不检查 `__stale`，也不把它转成 UI 状态。`ResourceCache` 注释自认「`__stale` 此前无任何消费方=假降级」，仅 `ErrorLogger`（verbose 开关）与 `debugPrint` 留痕。`HomeRepository.fetchHomeData()` 对失败区块统一 `catch (_) { return const []; }`（:148-162），把「离线旧数据」「请求失败」「确实为空」进一步压成同一个空列表。
- 影响：断网时用户下拉刷新看到旧首页/旧歌词但界面与在线成功完全一致；无网络提示、无「数据可能过期」标识，且首页各区块失败时被置空，用户以为「歌单被清空」。歌词原文「秒显」与译文降级（B1 `TranslateResult.ok=false` 留原文）混在一起，用户无法知道当前是缓存、失败还是真无译文。
- 证据等级：实锤（调用方零消费）；verbose 日志默认开关状态未实测

### lib/core/prefetch/prefetch_engine.dart:121-134 + lib/core/direct/kg_play_api.dart:264-277,333-365 「试听片段绝不入库」在播放响应契约与缓存 hook 之间断层
- 级别：P0（与 F7 第 3 条同一根因的跨模块证据补全）
- 违反：QUALITY_STANDARD 第 3 条、第 14 条、第 23 条
- 依据：B2 `PlayUrlResult` 明确定义 `isPreview`（:271）、`previewFileSize`（:305）、`offsetFileSize`（:309）、`failProcess`（:289），`fromResponse` 用 `endMs-startMs<=65000` 或 URL 含 `/p_0_` 判试听，并读取 `b['filesize']`（:354-356）为**正数声明字节数**。而 `onPlaybackCompleted(url, kind, {declaredBytes = 0})` 的签名完全没有 `isPreview/failProcess/PlayUrlResult`，`ResourceCache.cacheUrlFile` 只校验 `declaredBytes>0`、HEAD、实际长度；`KgDirectApiClient.get('song/url')` 的 `_epMedia.songUrl` 用 `KgSharedParams.songUrl`，`IsFreePart` 支持 0/1 两态。两层之间不存在「完整播放凭据」的传递。
- 影响：试听响应带合法 `filesize` 时，四道校验全部通过，30s/65s 片段被永久缓存；用户后续每次播放都命中片段，且清缓存不动永久文件（F3:70-73），错误不可自愈。反过来，若 `filesize` 未声明（0），`cacheUrlFile` 直接拒绝，完整播放后的永久缓存静默失效，用户每次重下。
- 证据等级：静态推演（两侧签名为实锤；上层 completed hook 是否传 isPreview 之外的闸门在 B5 范围，未实测）

### lib/core/resource/resource_cache.dart:302-330 + lib/core/net/music_api.dart:50-58 / lib/app/di.dart:32-39 写后 ns 失效无法覆盖按 ns 缓存的读路径
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条、第 18 条（世代）
- 依据：`MusicApi.invalidate(ns)` 经 `app/di.dart` 注入 `ResourceGateway.invalidateNs`；后者 `ResourceCache.invalidateNs` 用 `k.contains(':$ns:u=')` 匹配 `box.keys`。而 `CachedApiCall._keyOf` 生成的键格式为 `cacheKey()` 的 `'${scope.name}:$ns:u=$userid:$p:$qs:v$schemaVer$tail'`，`ResourceCache.json` 又加 `'list:'`/`'json:'` 前缀——字符串确实包含 `:ns:u=`；但 `MemoryCache.keyOf`（F2:125-131）产出的旧格式键、`ResourceGateway._memory` 中未按 `cacheKey()` 生成的键都不在该匹配里，且 `invalidateNs` 不取消 in-flight（F7 第 1 条）。
- 影响：收藏/加歌单后写操作成功、UI 提示成功，但内存旧列表与在途请求回写的旧一代数据仍在，用户看到歌单数/内容不更新，必须等 90s TTL 或重启。这是「下拉刷新立即生效」与「写后失效」共用的用户路径回归风险。
- 证据等级：静态推演（键格式比对为实锤；具体写操作调用链未逐文件核对）

### lib/core/storage/storage_permission.dart:157-171 + lib/core/utils/permission_gate.dart:23-26 `ensureStorageWrite()` 在 Android 10+ 恒返回 true，不校验实际可写路径
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级触发条件与次优行为）、第 9 条
- 依据：`PermissionGate.ensureStorageWrite()` 只调 `_service.requestStoragePermission()`；后者 `if (level >= 29) return true; // MediaStore 免权限`，没有 `_probeWritable`、没有 `resolveRoot()`、没有 `appFallback` 分支；`ResourceCache._dirOf()` 直接把 `resolveRoot()` 结果拼成 `Directory('$root/cache/resource/$kind')` 并 `create(recursive:true)`。
- 影响：Android 10+ 未授予「所有文件访问」时，权限网关告诉上层「可写」，但 `resolveRoot()` 返回的 Download 路径在 scoped storage 下不可直接写；永久文件缓存/下载写入全部被 `debugPrint` 吞掉，用户看不到任何失败反馈，也无法从设置页判断该去授权还是已被降级到私有目录。
- 证据等级：静态推演（三处代码链为实锤；Android 版本行为未实测）

### lib/core/cache/resource_gateway.dart:57-61 + lib/features/auth 侧契约（本范围未读） `onUserChanged()` 无调用证据、且只清内存
- 级别：P1（与 F3 第 2 条合并，作为跨模块生命周期证据）
- 违反：QUALITY_STANDARD 第 18 条、第 23 条
- 依据：在本批 9 文件 + 已完整读的 `di.dart` / `bootstrap.dart` / `net/music_api.dart` / `kg_providers.dart` / `home_repository.dart` / `lyric_repository.dart` 中，`onUserChanged` 没有任何调用点；`SecureStorage.clearCredentials()` 与 `KgDirectApiClient.clearCredentials()`（:52-57）都不触发缓存失效或账号世代递增。缓存键的 userid 取自 `_api.userid`（`CachedApiCall._keyOf`），其更新只在 `KugouApiClient.setCredentials/clearCredentials`。
- 影响：切号/登出后旧账号 168h 歌词、30min 歌词候选、90s 首页列表仍完整留在磁盘；只要新会话的 `userid` 与旧会话一致（同一账号登出重登、VIP 状态变化、CookieJar 尚未同步），或某调用方漏传身份，就会直接读到上一会话的数据。用户可见为「换了账号仍看到上一个人的每日推荐/歌词」，且无「正在切换账号」状态位。
- 证据等级：静态推演（本范围与已读上游零调用为实锤；B7 账号模块是否另有调用未读，未实测）

### 补充：歌词 168h 口径与实现不符（F3 第 3 条的落地证据）
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条（TTL 语义须显式一致）、第 31 条（注释/契约与实现一致）
- 依据：`cache_keys.dart:24-26` 声明 `CacheScope.json => 168h`；`LyricRepository` 显式 `static const Duration _lyricCacheTtl = Duration(minutes: 30)` 并传给所有 `/search/lyric`、`/lyric` 读取；`CachedApiCall.get` 因 `ttl != kListTtl` 归为 `CacheScope.json` 键，但 `ResourceCache.json` 的 `ttl` 参数是 30min。注释「替代 MemoryCache+LyricPersistentCache 双写」后，`cache_manager.dart` 的 `LyricPersistentCache`（168h 可配置）仍完整存在，`bootstrap.dart:40` 仍开 `lyric_cache` 盒，但本批已读调用方无人再使用它。
- 影响：歌词缓存实际 30 分钟过期，用户每半小时重听同一首歌都要重新回源；离线时最多只能回退到 30 分钟内的旧歌词，与「168h 缓存与原文秒显」的产品口径不符；`lyric_cache` 盒与 `LyricPersistentCache` 成为 v5.0 重构后未清理的死路径，设置页清缓存（F3:70-73）也不清它。
- 证据等级：实锤（三处 TTL 与注释）；真机离线时长未实测

### 补充：外置授权根目录下的永久缓存没有「私有目录」降级
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（已知条件下的已知次优行为）
- 依据：`StorageStrategy.appFallback` 枚举值（:11-14）与 `currentStrategy()` 的低版本分支存在，但 `resolveRoot()`（:146-171）三条返回路径全部是公共路径或硬编码 `/storage/emulated/0/Download/...`，从不返回 `getExternalStorageDirectory()` 之类 App 私有目录；`ResourceCache._dirOf()` 无任何 fallback，`putFile/cacheUrlFile` 写失败只 `debugPrint`。
- 影响：用户拒绝存储权限、或 Android 11+ 未开「所有文件访问」时，设计上声明的「降级到 App 私有外部目录」在永久文件缓存链路上根本不可达；完整播放后的文件永久无法落盘，用户每次重播都重新下载，且无任何可感知提示。
- 证据等级：实锤（枚举与所有返回路径）

## 复核更正（完整读调用方后，按实码收紧/撤销部分定性）

为核对用户路径，另完整读了 `lib/main.dart`(432)、`lib/features/player/data/player_repository.dart`(506)、`lib/features/player/data/audio_handler.dart`(701)、`lib/features/player/player_provider.dart`(227)、`lib/features/player/play_helper.dart`(89)、`lib/features/home/presentation/home_page.dart`(657)、`lib/features/playlist/data/playlist_repository.dart`(656)、`lib/features/settings/presentation/settings_page.dart`(1158)、`lib/core/utils/error_logger.dart`(486)。下列为对已落盘条目的更正，原条目保留但以本段为准；计数按本段口径在末尾清单重算。

### 撤销：F2 `MemoryCache.keyOf` 的「切号/登出后串数据 P1」定性
- 依据：`main.dart:292-296` 的 `authStateProvider` 监听在每次登录态变化时 `ref.invalidate(homeDataProvider)` 并调用 `ResourceGateway.instance.onUserChanged()`；`playlist_repository.dart:421-429` 写后同时 `invalidateNs('playlist')` 与 `MemoryCache.instance.removeWhere(...)`。旧格式键确实存在（F2 实锤），但当前已读调用方并未用它承载首页/歌单列表，且切号有清内存兜底。
- 残余问题：`cache_keys.dart` 文件头「全仓禁止再自行拼键」与 `MemoryCache.keyOf` 并存、`MemoryCache` 默认 TTL 取 `AppConfig.memoryCacheSeconds` 与 `cacheTtl(list)` 双事实源属设计/整洁度问题，降为 **P3（第 5/31 条，用户可见后果未证实）**。

### 撤销：F3 `clearTransient()` 未清翻译/歌词持久盒 的 P2 定性
- 依据：`settings_page.dart:207-248` 的 `_clearCache()` 在 `await ResourceGateway.instance.clearTransient()` 之后显式 `Hive.box(name).clear()` 遍历 `['api_cache','image_cache','lyric_translations', LyricPersistentCache.boxName]`；歌词/译文盒实际被清。改为 **复核通过项**（清缓存不动永久文件的口径在设置页达成）。

### 撤销：F4「预热主路径写死 kapi」的 P1 定性
- 依据：`main.dart:207-210` 把 `ref.read(kugouApiClientProvider)` 注入 `PrefetchEngine.attach(api)`；`app/di.dart:12-15` 把该 provider 装配为 `KgDirectApiProvider`（`KgDirectApiClient`）。`KgDirectApiClient.get` 对 `/song/url`、`/search/lyric`、`/album/detail` 均有直连分派且 `fallbackToKapi = false`（:92-93、:165-176、:284-287）。`prefetch_engine.dart:161-163` 的「kapi /song/url」注释是过期注释，不是运行期行为。
- 残余问题：预热注释与实装矛盾、**预热键与实播键不命中**（见跨模块第 2 条，仍为 P1）；「写死 kapi」本身降为 **P3（第 31 条，注释误导）**。

### 撤销：F4 `onPlaybackCompleted` 无试听判定的 P1 定性（本范围接口层仍有残余风险）
- 依据：`audio_handler.dart:83-96` 的 completed 回调前置闸门为 `_lastPlayUrl.startsWith('http') && !_lastIsPreview && _lastDeclaredBytes > 0`；`_setLastSource()`（:247-251）原子写入 URL/bytes/isPreview；`player_repository.dart:274-283` 明确按 `result.isPreview` 设置 `PlayableResult.isPreview` 与 `expectedBytes`。试听片段在当前播放链路上**不会**调用 `onPlaybackCompleted`。
- 残余问题：`ResourceCache.cacheUrlFile` 本身仍无「完整播放凭据」（F7 第 3 条）；但「试听片段被永久缓存」在已读链路上不成立，F7 第 3 条由 **P0 降为 P2（第 3 条，防御性契约缺失，用户可见后果未实测）**，跨模块「试听绝不入库断层」条目同步撤销。

### 撤销：F6「译文补丁跨歌串入」的 P1 定性
- 依据：`lyric_view.dart:105-129` 的 `_onTranslationPatch` 用 `widget.songHash` 与 `_boundSongHash` 比对、用 `widget.lyricId` 与 `p.lyricId` 比对，且 `didUpdateWidget`（:151-159）换词时重绑代际；`lyric_repository.dart:161-176` 缓存命中也主动 emit。
- 残余问题：broadcast 无缓冲 + `emit()` 不写持久缓存，订阅晚于 emit 时该批译文确实丢失，但 `lyric_repository.dart:246-252` 成功批次已写 `LyricTranslationCache`，下次进入可读；降为 **P2（第 20 条，切歌瞬间本批 UI 译文不出现，需重进页面）**。

### 撤销：F5 `post()` 可被缓存导致重复提交 的 P1 定性
- 依据：`core/net/music_api.dart:41-48` 的 `write()` 明确「**不缓存**」并直接 `_client.post(...)`；`playlist_repository.dart:365-389` 的 `_write()` 走 `_api.get(path, query: params)`（直连写分派在 get 分支）且不经 `CachedApiCall`；已读调用方无人把写操作接到 `CachedApiCall.post`。
- 残余问题：`CachedApiCall.post` 仍是公开可缓存的写入口，仅靠类注释约束，降为 **P3（第 3/32 条，防御性契约缺失）**。

### 撤销：F7「成功写入不做响应成功判定」与 F5「业务错误被当成功写进缓存」的 P1 定性
- 依据：`KugouApiClient` 的 `onResponse` 拦截器（:38-57）与 `KgDirectApiClient._wrap`（:76-80）都统一走 B1 `evaluateResponse`；`KgPlayApi.PlayUrlResult.fromResponse`（:333-336）同样。业务失败会抛 `DioException/ApiException`，`ResourceCache._doFetch` 走 catch 分支而非 `box.put`。
- 残余问题：直连路径绕过 Dio 拦截器、只靠 `_wrap` 且 `_wrap` 不检查假 502 `KgResponse.status`（跨模块第 1 条，保留 P1）；「缓存层不判成功」本身降为 **P3（第 3 条，防御性契约）**。

### 撤销：跨模块「`onUserChanged()` 无调用证据」的 P1 定性
- 依据：`main.dart:292-296` 登录态变化监听确实调用 `ResourceGateway.instance.onUserChanged()`；`main.dart:246-249` 内存压力也调用。**但** `onUserChanged()` 只 `_memory.clear()`，磁盘 `resource_json` 盒仍按 `u=` 键被动隔离，且该方法被复用于「内存压力」与「切号」两种语义（第 30 条）。降为 **P2（第 30/23 条，命名与行为不符 + 磁盘不主动失效）**。

### 新增（以完整读到的调用链为证据）

### lib/features/settings/presentation/settings_page.dart:165-183 / 207-248 缓存占用统计口径不含外置根目录，清缓存后数字不降
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败/结果必须可观测）、第 30 条（缓存占用文案与实际清理口径一致）
- 依据：`_loadCacheSize()` 只统计 `getApplicationSupportDirectory()` 与 `getTemporaryDirectory()`（注释「统计口径 = 可清理缓存」）；`_clearCache()` 清的是 `ResourceGateway.clearTransient()` + Hive box + tmp，而永久文件落在 `StoragePermissionService.resolveRoot()` 返回的 `/storage/emulated/0/TierNanMusic/cache/resource/...` 或 `Download/TiernanMusic/...`（F9 常量）。设置页 `cacheUsage` 显示的数字**不包含**这些外置文件，`clearCacheDesc` 也未说明永久文件不动。
- 影响：用户设备被永久音频缓存占满后，设置页「缓存占用」仍显示几十 KB；点「清除缓存」提示成功但可用空间毫无变化，用户反复清理或误判为 App 故障，且没有任何入口能看到/清理永久文件（F7 第 6 条无删除方法）。
- 证据等级：实锤（统计目录与文件根目录不同）；真机存储占用未实测

### lib/main.dart:288-296 登录态同步只 invalidate 首页/库页 provider，不清磁盘缓存与在途请求
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条（异步结果须校验世代）、第 23 条
- 依据：`applyAuth()` 内 `ref.invalidate(homeDataProvider)` / `libraryUserPlaylistsProvider` / `libraryCollectedMvsProvider` + `ResourceGateway.instance.onUserChanged()`；`onUserChanged()` 仅 `_memory.clear()`，不触碰 `ResourceCache._box`、不取消 `_inFlight`、不递增账号世代。`CachedApiCall._keyOf` 的 userid 取自 `_api.userid`，而此处只更新 `client.userid`（KgClient），`KugouApiClient.userid` 由 `setCredentials/clearCredentials` 单独维护。
- 影响：切号瞬间已在飞的首页/歌单/歌词请求返回后按旧 `userid` 写入磁盘；新账号 `invalidate` 重取时若 `_inFlight` 仍在，会直接拿到旧一代 Future（F7 第 1 条），用户看到上一账号的每日推荐/歌单，且下拉刷新在途期间也可能被旧请求回写覆盖。
- 证据等级：静态推演（装配与调用链实锤；真机时序未实测）

### lib/core/storage/storage_permission.dart:158-171 + lib/features/settings/presentation/settings_page.dart:119-130 `resolveRoot()` 与 `resolveRootMode()` 在设置页并行探测，互相覆盖 `lastProbeError`
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条、第 9 条
- 依据：设置页 `_loadStorageRoot()` 用 `Future.wait([service.resolveRoot(), service.resolveRootMode()])`；两方法内部都调 `_probeWritable(Directory(rootPath))`，`_probeWritable` 每次成功写 `lastProbeError = null`、失败写原因（F9 第 7 条）。`settings_page.dart:317-323` 的 FutureBuilder 在 `snap.data` 到达后读 `StoragePermissionService.lastProbeError` 显示「探测失败原因」。
- 影响：两个 probe 并发时，一个成功会把另一个失败原因清掉；用户在「存储根路径」tile 上看不到 `storageProbeFailed` 提示，或看到的是与当前路径无关的失败文本，无法判断为何下载/永久缓存没写进去。
- 证据等级：静态推演（并发与共享静态字段实锤）

### lib/core/prefetch/prefetch_engine.dart:85-94 / lib/features/player/data/audio_handler.dart:261-266 每次队列变化都重置 100ms 节拍，队列预热在切歌密集时可长期不消费
- 级别：P2（与 F4 第 2 条合并，补充真机触发路径）
- 违反：QUALITY_STANDARD 第 19 条
- 依据：`audio_handler._emitQueue()` 在 `playQueue`、`playSong`、队列替换时调用 `PrefetchEngine.instance.updateUpcoming(_songs, _index)`；`updateUpcoming` 无条件 `_startDrain(const Duration(milliseconds:100))`，而 `_startDrain` 先 `_drainTimer?.cancel()` 再新建 periodic Timer，首个 `_drainOne()` 要等 100ms。
- 影响：用户连续切歌/拖动队列时，每次切歌都把 100ms 计时清零，预热队列迟迟不消费；「未来 15 首」的 URL/歌词 JSON 到切到那首时仍未就绪，播放前多一次回源等待。
- 证据等级：静态推演

### lib/features/lyric/data/lyric_repository.dart:31,39-45,112 + lib/core/cache/cache_keys.dart:24-27 歌词实际 30min TTL 与 `cacheTtl(json)=168h` 契约并存（复核通过项撤销一条）
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条、第 15 条
- 依据：`LyricRepository._lyricCacheTtl = Duration(minutes:30)` 显式传入 `/search/lyric` 与 `/lyric`；`CachedApiCall.get` 因 `ttl != kListTtl` 一律归 `CacheScope.json`，而 `cacheTtl(CacheScope.json)=168h`；`ResourceGateway.json()` 默认 `cacheTtl(scope)` 才是 168h。`LyricPersistentCache.getWithStale(ttl:...)` 支持任意 TTL 但本批已读调用方无人再用它，`bootstrap.dart:40` 仍开 `lyric_cache` 盒。
- 影响：用户口径「歌词 168h 缓存 + 原文秒显」在实播链路只有 30 分钟；离线重听超过 30 分钟的歌会重新回源，失败时 `staleOnError` 只能拿到 30 分钟内的旧值（且无 UI 标识，见跨模块第 3 条）。同一份「歌词 TTL」事实在三个文件里各有一套，v5.0 重构回归风险高。
- 证据等级：实锤（三处常量/调用）

### lib/core/resource/resource_cache.dart:234-297 + lib/features/player/data/player_repository.dart:274-283,409-430 完整播放永久缓存的 `declaredBytes` 在 kapi 回退路径可能取试听区间差值
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条、第 23 条
- 依据：`PlayerRepository._declaredBytes()`（:478-488）优先取 `hash_offset.end_byte - start_byte`，其次 `filesize`；`_resolveViaKapi` 的 `isPreview` 判定为 `_int(data['priv_status']) == 0 || data['hash_offset'] is Map`（:409-413），全曲响应若带 `hash_offset` 也被标 `isPreview=true`；直连路径注释（:274-283）把 `previewFileSize` 解释为「整曲 JSON 的 filesize 通用字段」。完整播放时 `audio_handler` 只在 `!_lastIsPreview` 时入库。
- 影响：服务端对全曲也返回 `hash_offset` 时，用户完整听完后永久缓存静默不发生（被判试听），每次重播重新下载；反之若区间差值恰好等于全曲长度，则身份仍可入库。用户无法从界面判断「这首歌是否已永久缓存」，且 `cacheUrlFile` 失败只 debugPrint。
- 证据等级：静态推演（判定与字段来源实锤；上游全曲是否带 hash_offset 未实测留样，第 29 条要求实测）

### lib/core/cache/resource_gateway.dart:70-73 + lib/features/settings/presentation/settings_page.dart:218-224 清缓存后歌词/列表缓存立即失效，但 `ResourceCache._inFlight` 中的请求会立刻写回
- 级别：P1
- 违反：QUALITY_STANDARD 第 18 条、第 21 条
- 依据：`_clearCache()` 先 `await ResourceGateway.instance.clearTransient()`（内部 `clearJson()`/`clearLists()` 只 `box.deleteAll(keys)`），随后清 Hive 其它盒；两个方法都不触碰 `ResourceCache._inFlight`，也不阻止其 `_doFetch` 的 `box.put`。`settings_page.dart:243` 随即 `Toast.show(context.l10n.cacheCleared)` 并 `_loadCacheSize()`。
- 影响：用户点「清除缓存」时首页/歌词仍有在途请求，提示「已清除」后几秒内旧响应写回 `resource_json` 盒；再次查看占用或重进页面发现缓存又回来了，用户以为清理功能失效并反复操作。与下拉刷新 in-flight 回写（F7 第 1 条）是同一根因在设置页的可见后果。
- 证据等级：静态推演

## 补充更正（计数以本清单为准）

### 更正 F2 第 4 条（翻译缓存键不含源歌词版本）
- 依据：`lyric_repository.dart:157-160` 的 `_lyricVersionKey(lyric)`（行数 + 全文本短哈希）被拼入 `targetLanguage`，传给 `LyricTranslationCache.get(lyricId, '$targetLanguage@$versionKey')`；`_key` 再拼 `@translateModel`。歌词版本确实进入键。原「不含版本」判断不成立，该条降为 **P3**（仅剩无独立 TTL/条目数上限，且设置页有清盒入口）。

### 更正 F3 第 1 / 第 3 条（L1 与 `json()` 默认值）
- 依据：本批 9 文件与已完整读的调用方中，`ResourceGateway.memoryGet/memoryPut/json()` 未发现消费方；实际读路径都直连 `CachedApiCall` + `ResourceCache`（`home_repository.dart:36-38`、`playlist_repository.dart:52-55`、`lyric_repository.dart:41-44`、`player_repository.dart:126-131`）。`ResourceGateway` 被消费的是 `invalidateNs` / `onUserChanged` / `clearTransient`。
- 结论：无 TTL/上限与默认 168h/stale 仍是门面契约缺陷，但「用户下拉刷新看到旧列表」的后果取决于未来调用方，降为 **P2（第 3/25 条，防御性契约，用户可见后果未实测）**。

### 更正 F8 第 3 条（登出/切号不通知缓存层）
- 依据：`main.dart:288-296` 的 `authStateProvider` 监听在登录态变化时调用 `ResourceGateway.instance.onUserChanged()` 并 invalidate 首页/库 provider，凭证层与缓存层**存在**装配点。
- 结论：仍有磁盘 L2 不主动清、在途请求不取消、`KgClient.userid` 与 `KugouApiClient.userid` 两条身份链不同步的问题（见新增条目），原「完全依赖调用链顺序」定性降为 **P2**。

### 更正 F9 第 4 条（版本名→API 映射的后果口径）
- 依据：`ErrorLogger.apiLevel`（`error_logger.dart:465-471`）对 `StoragePermissionService.apiLevel()` 返回值 `<21` 统一兜底为 29，因此通道失败且版本名兜底得到 1..9 时，日志模块反而会走 Android 10+ 的 MediaStore 分支；而 `StoragePermissionService` 自身消费者（`needsLegacyWritePermission`）按 `<29` 走旧权限分支。两处对同一错误 level 得出相反分支。
- 结论：映射算术错误与「同一事实多源」仍成立，级别保留 **P1**，证据等级静态推演（厂商版本名形态未实测）。

### 新增：lib/core/prefetch/prefetch_engine.dart:23 未使用 import
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码/未使用导入零容忍）
- 依据：`import '../net/music_api.dart';` 在本文件 211 行内无任何符号引用；`dart analyze` 报 `warning - prefetch_engine.dart:23:8 - Unused import: '../net/music_api.dart'`。同文件 `:24` 的 `import 'package:flutter/foundation.dart';` 仅用于 `debugPrint`。
- 影响：无用户可见后果；v5.0 M4 Bridge-N 迁移后残留的 import，会让维护者误判预热经 `MusicApi` 门面（实际经 `CachedApiCall`），与 F4 过期注释共同放大契约误读。
- 证据等级：实锤（analyze 输出）

## 问题清单（按级别排序；以「复核更正」为最终裁决）

计数口径：正文共 69 条 `- 级别` 记录，剔除 5 条被撤销/合并项后 = **64 条**（P0 1 / P1 22 / P2 30 / P3 11）。撤销/合并不计：① `resource_gateway.dart:70-73` 未清歌词/译文盒（设置页已清）；② `prefetch_engine.dart:121-134` 无试听判定（`audio_handler` 有 completed 闸门）；③ 跨模块「试听绝不入库断层 P0」（同一闸门证据，撤销）；④ 复核新增「队列重置 Timer」（并入 F4 Timer 条目）；⑤ 复核新增「歌词 30min TTL」（并入跨模块「168h 口径」条目）。下钻「依据/影响/证据等级」见正文各条。

### P0（1）

- P0｜静态推演｜`lib/core/resource/resource_cache.dart:262-267,277-282` 同名 `.part` 并发下载/改名导致永久文件内容损坏（第 18/22/21 条）

### P1（22）

- P1｜静态推演｜`lib/core/cache/cache_manager.dart:148-155` 译文缓存磁盘解析零校验、`int.parse` 未捕获（第 13/14/9 条）
- P1｜静态推演｜`lib/core/cache/resource_gateway.dart:57-61` `onUserChanged()` 只清 L1，L3 永久文件无账号隔离（第 23/16 条）
- P1｜实锤｜`lib/core/resource/cached_api.dart:55-58,69-72` TTL↔scope 双通道，非 90s 一律按 json 键（第 15/23 条）
- P1｜静态推演｜`lib/core/resource/resource_cache.dart:64-88` in-flight 写回不校验失效世代（第 18/19 条）
- P1｜实锤｜`lib/core/resource/resource_cache.dart:104-128` 失效回退仅 `__stale` + verbose 日志，用户不可感知（第 9/16 条）
- P1｜实锤｜`lib/core/resource/resource_cache.dart:176-190,198-231,260-284` 文件读写两套身份 `url|0` / `url|bytes`（第 5/3/23 条）
- P1｜静态推演｜`lib/core/resource/resource_cache.dart:271-275` HEAD 失败即放弃，永久缓存静默失效（第 11/9 条）
- P1｜实锤｜`lib/core/resource/resource_cache.dart:227-229,303-330` 永久文件无体积上限、无删除入口、注释矛盾（第 25/31/32 条）
- P1｜静态推演｜`lib/core/storage/secure_storage.dart:76-86` `saveCredentials` 与 `clearCredentials` 的 dfid 语义矛盾（第 5/23 条）
- P1｜静态推演｜`lib/core/storage/secure_storage.dart:29-40` 五键并发写/删无原子性，部分落盘成混合凭证（第 3/5/21 条）
- P1｜静态推演｜`lib/core/storage/storage_permission.dart:158-171` 写探针失败仍返回不可写路径（第 11/9 条）
- P1｜静态推演｜`lib/core/storage/storage_permission.dart:207-221` 版本名→API 映射算术错误、注释冲突（第 14/13/15 条）
- P1｜静态推演｜`lib/core/storage/storage_permission.dart:305-316` `resolveStrategy/currentStrategy` 不做写探针（第 11/29 条）
- P1｜静态推演｜跨模块 `resource_gateway.dart:20-24` + `net/music_api.dart:41-48` 直连绕过 Dio 拦截器、`_wrap` 不查假 502（第 3/29 条）
- P1｜实锤｜跨模块 `prefetch_engine.dart:160-167,176-178` + `lyric_repository.dart:31,39-45,112` 预热与实播 ns/query/TTL 不命中（第 5/23 条）
- P1｜实锤｜跨模块 `resource_cache.dart:104-128` + `home_repository.dart:36-38` / `lyric_repository.dart:41-44` `__stale` 零消费（第 9/16 条）
- P1｜静态推演｜跨模块 `resource_cache.dart:302-330` + `net/music_api.dart:50-58` 写后 ns 失效覆盖不到旧格式键/在途（第 23/18 条）
- P1｜静态推演｜跨模块 `storage_permission.dart:157-171` + `permission_gate.dart:23-26` Android 10+ `ensureStorageWrite()` 恒 true（第 11/9 条）
- P1｜实锤｜跨模块 `storage_permission.dart:146-171` + `resource_cache.dart:152-159` 外置永久缓存无私有目录降级（第 11 条）
- P1｜实锤｜`lib/features/settings/presentation/settings_page.dart:165-183,207-248` 缓存占用统计不含外置根目录（第 9/30 条）
- P1｜静态推演｜`lib/main.dart:288-296` 登录态变更不清磁盘缓存/不取消在途、`KgClient` 与 `KugouApiClient` 双身份链（第 18/23 条）
- P1｜静态推演｜`resource_gateway.dart:70-73` + `settings_page.dart:218-224` 清缓存后在途请求立即写回（第 18/21 条）

### P2（30）

- P2｜静态推演｜`cache_keys.dart:33-45` query 值未转义、Iterable join 可碰撞（第 23 条）
- P2｜静态推演｜`cache_keys.dart:24-27` userid 默认 '0'、schemaVer 全局单一（第 23 条）
- P2｜静态推演｜`cache_manager.dart:91-108` `_evict` FIFO 淘汰热键（第 25/24 条）
- P2｜静态推演｜`cache_manager.dart:35-41` 损坏缓存静默删、非 Map 分支不清理（第 9/14 条）
- P2｜静态推演｜`resource_gateway.dart:26-30` L1 无 TTL/容量（复核降为 P2，第 25/23 条）
- P2｜静态推演｜`resource_gateway.dart:31-48` `json()` 默认 168h / stale（复核降为 P2，第 3/2 条）
- P2｜静态推演｜`resource_gateway.dart:63-67` L1 失效依赖 `:ns:u=` 子串（第 5/23 条）
- P2｜实锤｜`prefetch_engine.dart:101-113` 「未来 15 首」含当前曲，实为未来 14 首（第 17/30 条）
- P2｜静态推演｜`prefetch_engine.dart:88-94,104-111` Timer 反复重建、首个节拍被推迟（第 19/24 条）
- P2｜静态推演｜`prefetch_engine.dart:36-39,85-86,108-110` `_requested/_pending` 无上限（第 25 条）
- P2｜静态推演｜`prefetch_engine.dart:158-192` 多首预热无并发上限（第 25 条）
- P2｜静态推演｜`cached_api.dart:30-49` `_bodyDigest` 低 8 位截断/不转义（第 14/23 条）
- P2｜静态推演｜`cached_api.dart:22-25` 键不含匿名/普通/VIP 三态（第 23/5 条）
- P2｜静态推演｜`lyric_translation_stream.dart:23-29` broadcast 无缓冲（复核降为 P2，第 20 条）
- P2｜静态推演｜`lyric_translation_stream.dart:32-35` `dispose()` 关闭单例流无重建（第 20 条）
- P2｜实锤｜`resource_cache.dart:234-297` 文件身份四道校验无「完整播放凭据」（复核降为 P2，第 3/14/23 条）
- P2｜静态推演｜`resource_cache.dart:131-149` 损坏删不 await、形态异常分支不清理、时钟无校验（第 6/9/14 条）
- P2｜实锤｜`resource_cache.dart:12-14,64-67,77-80` TTL 三事实源、in-flight 键不含 scope（第 5/15/23 条）
- P2｜静态推演｜`resource_cache.dart:83-86,90-101` `init()` 失败全量回源无状态位（第 9/11 条）
- P2｜实锤｜`secure_storage.dart:96-103` 多账号 token 无批量清理入口（第 20/5 条）
- P2｜静态推演｜`secure_storage.dart:46-62` 空串凭证被判已登录（第 14/16 条）
- P2｜静态推演｜`secure_storage.dart:40,46-62,76-86` 登出/切号对磁盘缓存与在途无世代（复核降为 P2，第 18/23 条）
- P2｜静态推演｜`storage_permission.dart:181-187` 模式名与实际路径可矛盾（第 5/31 条）
- P2｜实锤｜`storage_permission.dart:44-50,155-171` 两套根目录拼写随授权态切换（第 5/16 条）
- P2｜静态推演｜`storage_permission.dart:319-326` `currentStrategy()` 权限状态无异常捕获（第 6/7/9 条）
- P2｜静态推演｜`storage_permission.dart:101,92-99` `lastProbeError` 并发覆盖（第 18/5 条）
- P2｜静态推演｜跨模块 `resource_gateway.dart:57-61` `onUserChanged()` 命名复用/只清内存（复核降为 P2，第 30/23 条）
- P2｜实锤｜跨模块 歌词 168h 口径 vs 实播 30min TTL（第 15/31 条）
- P2｜静态推演｜`settings_page.dart:119-130` + `storage_permission.dart:158-171` 并行 probe 覆盖 `lastProbeError`（第 18/9 条）
- P2｜静态推演｜`resource_cache.dart:234-297` + `player_repository.dart:274-283,409-430` kapi 路径 `hash_offset` 使全曲被判试听，永久缓存静默跳过（第 14/23 条）

### P3（11）

- P3｜实锤｜`cache_keys.dart:30-33` 注释「null 视为空串」与实现相反（第 31 条）
- P3｜静态推演｜`cache_manager.dart:18-21,133-136` 两个单例 `openBox` 无 in-flight 合并（第 18/22 条）
- P3｜实锤｜`cache_manager.dart:125-131` 旧格式 `MemoryCache.keyOf` 并存（复核降为 P3，第 5/31 条）
- P3｜实锤｜`cache_manager.dart:140-143` 译文盒无独立 TTL/条目上限（复核降为 P3，第 25 条）
- P3｜实锤｜`lyric_translation_stream.dart:14-17` 注释宣称「缓存命中也 emit」但本类零缓存（第 31 条）
- P3｜实锤｜`storage_permission.dart:114-140` 探针残留文件（第 20/25 条）
- P3｜实锤｜`prefetch_engine.dart:155-195` 过期 kapi 注释（复核降为 P3，第 31 条）
- P3｜实锤｜`cached_api.dart:63-82` `post()` 公开可缓存仅靠注释（复核降为 P3，第 3/32 条）
- P3｜实锤｜`cached_api.dart:20-27,54-82` 缓存层无成功判定防御（复核降为 P3，第 3 条）
- P3｜实锤｜`resource_cache.dart:96-101,104-112` 成功写入无成功判定防御（复核降为 P3，第 29/3 条）
- P3｜实锤｜`prefetch_engine.dart:23` 未使用 `../net/music_api.dart` import（第 32 条，analyze 告警）

### 被撤销/合并（不计入 64）

- `resource_gateway.dart:70-73` 「未清翻译/歌词盒」→ 设置页 `_clearCache()` 已清，改列复核通过项
- `prefetch_engine.dart:121-134` 「无试听判定」→ `audio_handler.dart:83-96` completed 有 `!_lastIsPreview && bytes>0` 闸门
- 跨模块「试听绝不入库断层 P0」→ 同一闸门证据撤销
- 复核新增「队列变化重置 Timer」→ 并入 `prefetch_engine.dart:88-94` 条目
- 复核新增「歌词 30min TTL」→ 并入跨模块「168h 口径」条目

## 复核通过项（本范围确认到位的设计）

1. **冷启动首页/歌单 90s 语义落地**：`home_repository.dart:36-38` 与 `playlist_repository.dart:52-55,77-88,116-121` 显式传 `kListTtl`；`cached_api.dart:55` 以 `ttl == kListTtl` 标 `CacheScope.list`，`resource_cache.dart:77-80` 加 `list:` 前缀；`invalidateNs('home')` 在 `home_page.dart:35-40` 下拉刷新时先执行，再 `ref.refresh(homeDataProvider.future)`。
2. **写后按 ns 精确失效 + 写防重**：`playlist_repository.dart:365-389` 的 `_inFlight` dedupeKey 与 `maybeSucceeded` 语义，成功后 `ResourceGateway.invalidateNs('playlist')` + `MemoryCache.removeWhere` 双清；`MusicApi.write()`（`net/music_api.dart:41-48`）明确不缓存写请求。
3. **清缓存不动永久文件**：`settings_page.dart:207-248` 只清 `ResourceGateway.clearTransient()`（JSON/列表 Hive）、`api_cache`/`image_cache`/`lyric_translations`/`lyric_cache` 盒与临时目录（显式跳过 `downloads_tmp`），不触碰 `<resolveRoot()>/cache/resource/**`。
4. **试听片段不入库的播放侧闸门**：`audio_handler.dart:83-96` 的 completed 回调校验 `http`、`!_lastIsPreview`、`bytes>0`；`_setLastSource()`（:247-251）原子写三字段；`stop()`（:590-596）清空快照；`player_repository.dart:274-283,409-430` 分别给直连/kapi 结果标注 `isPreview` 与 `expectedBytes`。
5. **永久文件 (URL,bytes) 四道校验**：`resource_cache.dart:234-297` 逐条实现 `declaredBytes<=0` 拒绝、已存在文件长度校验、HEAD Content-Length 校验、下载后实际长度校验并删 `.part`；失败统一返回 null + debugPrint，且 `rename` 前不落正式文件。
6. **B1 `evaluateResponse` 单点**：`response_policy.dart:55-113` 统一 status/err_code/警告码/20028 口径；`kugou_api_client.dart:38-57`、`kg_direct_api_client.dart:76-80`、`kg_play_api.dart:333-336` 三处复用，`errors.dart` 的 `kVerificationRequired` 为唯一常量。
7. **B2 播放响应异常契约**：`kg_play_api.dart:264-365` 的 `PlayUrlResult` 完整解析 `isPreview/hash_offset/failProcess/filesize/ssaCode`，`fromResponse` 先 `evaluateResponse` 再判 HTTP 假 502；`player_repository.dart:261-328` 对 20028 直接上抛、特殊音质不越族降级。
8. **原文/译文三态与秒显**：`translate_api.dart:34-100` 用 `TranslateResult.ok/reason` 区分真译文与原文降级；`lyric_repository.dart:186-252` 对失败批次不写缓存、只缓存成功译文并逐批 `emit`；`lyric_view.dart:105-159` 用 `songHash + lyricId` 双代际校验补丁、订阅在 `dispose()` 对称取消。
9. **歌词持久降级与缓存键版本**：`cache_manager.dart:26-50` 的 `getWithStale` 同时返回 fresh/stale 供失败降级；`lyric_repository.dart:157-160` 把行数+文本哈希与 `AppConfig.translateModel` 并入译文键；`lyric_translation_stream.dart` 的 broadcast 流无监听不抛错。
10. **预加载不下载实际文件、不阻塞首帧**：`prefetch_engine.dart:73-94,155-195` 只做 `CachedApiCall.get` JSON，首帧后由 `main.dart:207-221` 的 `ref.listen(homeDataProvider)` 触发，`enqueueSongs` 同步返回、单次上限 60、100ms 节拍；`updateUpcoming` 默认 window=15 且对 `currentIndex` 越界做边界处理。
11. **in-flight 合并与失效回退留痕**：`resource_cache.dart:64-88` 同 key 并发共用一个 Future 并在 finally 移除；`_doFetch`（:104-128）失败时 `ErrorLogger.log` + `debugPrint` + `__stale` 打标，无旧值则 `rethrow`，不静默吞异常。
12. **缓存键含用户身份与 schemaVer**：`cache_keys.dart:35-45` 输出 `scope:ns:u=userid:path:sortedQuery:vN[:extra]`；`cached_api.dart:20-27` 从 `_api.userid` 取值、POST 追加 body 摘要；`cacheNsPrefix()` 提供统一 ns 前缀。
13. **Hive 开箱与启动降级**：`bootstrap.dart:25-44` 集中打开 `resource_json`/`lyric_cache`/`lyric_translations` 等盒并逐盒容错；`resource_cache.dart:44-53` 的 `init()` 幂等且失败只留痕不抛；`main.dart:66-145` 任一步失败仍 `runApp`，首帧看门狗 15s 留痕。
14. **外置目录授权/降级的探针思路**：`storage_permission.dart:110-171` 每次 `resolveRoot()` 真实写探针（写→读回→删），授权态为真但探针失败会降级 Download 并留 `lastProbeError`；`settings_page.dart:317-323` 把失败原因展示给用户，`resolveRootMode()` 与 UI 的模式名联动。
15. **i18n 与三态**：本批 9 个 .dart 文件无硬编码 UI 文案（仅 debugPrint/注释），`AppConfig.supportedLocales` 十语言；`PLAY` 结果含匿名/非 VIP/VIP 的 `privilege/payType/failProcess` 降级链，`cached_api.dart` 不依赖 VIP 专属字段。
16. **切号/登出装配点存在**：`main.dart:288-326` 监听 `authStateProvider` 并 `ref.invalidate` 首页/库 provider + `ResourceGateway.onUserChanged()`，带 200ms 重试的世代校验；`secure_storage.dart:23-38` 对 null 的 t1/auth/dfid 显式删除旧键防票据串号。
17. **永久缓存文件确定性命名**：`resource_cache.dart:176-190` 以 FNV-1a(`url|bytes`) + URL 长度 + bytes + 短扩展名命名，不同音质/不同声明长度不互相覆盖；`cacheUrlFile` 复用前也校验长度，避免续用中断的半截文件。

## 逐文件 `dart analyze` 结果（9/9 全覆盖）

命令：`export PATH=$PATH:/opt/dart/bin && dart analyze <file>`（逐文件单独执行，未安装 SDK / 未 pub get / 未构建 / 未跑测试）。判定口径：Flutter/三方包符号缺失属预期噪音；项目自有类报错为真错误；未使用 import 记为告警。

| # | 文件 | 原始结论 | 过滤噪音后 |
|---|---|---|---|
| 1 | `lib/core/cache/cache_keys.dart` | `No issues found!`（exit 0） | **通过**：0 错误 0 警告 |
| 2 | `lib/core/cache/cache_manager.dart` | `5 issues found`（exit 3）：`package:hive/hive.dart` URI 不存在 ×1、`Box` 未定义 ×2、`Hive` 未定义 ×2 | **通过**：全部为 hive 包缺失派生的噪音；项目自有类 0 错误 |
| 3 | `lib/core/cache/resource_gateway.dart` | `No issues found!`（exit 0） | **通过**：0 错误 0 警告 |
| 4 | `lib/core/prefetch/prefetch_engine.dart` | `7 issues found`（exit 3）：`package:flutter/foundation.dart` URI 不存在 ×1、`debugPrint` 未定义 ×5、`warning - Unused import: '../net/music_api.dart'` ×1 | **通过（带 1 条真实告警）**：6 条均为 flutter 包缺失派生噪音；项目自有类 0 错误；未使用 import 已记为 P3 问题 |
| 5 | `lib/core/resource/cached_api.dart` | `No issues found!`（exit 0） | **通过**：0 错误 0 警告 |
| 6 | `lib/core/resource/lyric_translation_stream.dart` | `No issues found!`（exit 0） | **通过**：0 错误 0 警告 |
| 7 | `lib/core/resource/resource_cache.dart` | `23 issues found`（exit 3）：dio/flutter/hive URI 不存在 ×3、`Box` 未定义 ×4、`Hive` 未定义 ×3、`debugPrint` 未定义 ×11、`Dio`/`BaseOptions` 未定义 ×2 | **通过**：全部为三方包缺失派生的噪音；项目自有类 0 错误 |
| 8 | `lib/core/storage/secure_storage.dart` | `4 issues found`（exit 3）：`package:flutter_secure_storage/...` URI 不存在 ×1、`FlutterSecureStorage`/`AndroidOptions` 未定义 ×2、`const_initialized_with_non_constant_value` ×1 | **通过（const 噪音需说明）**：`static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(...))` 的 const 报错在三方包符号可解析时由构造函数 const 性决定，本环境因包缺失连带报出；项目自有类 0 错误 |
| 9 | `lib/core/storage/storage_permission.dart` | `34 issues found`（exit 3）：flutter/services/permission_handler URI 不存在 ×3、`Permission`/`PermissionStatus`/`MethodChannel`/`openAppSettings` 未定义 ×10、`debugPrint` 未定义 ×18、`const_initialized_with_non_constant_value` ×2（均指向三方类构造） | **通过**：全部为三方包缺失派生的噪音；项目自有类 0 错误 |

**结论**：9 个范围文件全部单独 analyze，过滤三方包噪音后项目自有类 0 错误；3 个文件（`cache_keys.dart`、`resource_gateway.dart`、`cached_api.dart`、`lyric_translation_stream.dart`）原生零告警，唯一真实告警是 `prefetch_engine.dart:23` 未使用 import（已在 P3 清单列出）。

## 未做项与限制

- 未编译/未构建/未跑测试/未安装任何 SDK 或依赖、未启动服务：任务书硬性规则 5 与 QUALITY_STANDARD 第八章禁止；`dart analyze` 仅使用环境内已有 Dart 3.13.7。
- 未实测真机：断网回退的 UI 表现、CDN HEAD 行为、Android 各版本外置目录可写性、B1/B2 三态响应样本、预热命中率均标注「未实测」或「静态推演」；第 28/29/33 条要求的实测留样不在本次只读审查范围内。
- 未读 `docs/v51_cross_b*_merged.md`、其它批报告及 `docs/batch*`/历史审查报告（防锚定）；B7 账号模块完整源码未读，故 `onUserChanged` 在账号侧的其它调用点与 `clearCredentials(userid:)` 实参形态标注「未实测」。
- 未修改任何代码文件、pubspec.yaml、AndroidManifest.xml、Kotlin、CI yml；唯一写入文件为本报告 `docs/v51_cross_b3_c.md`。
- 源码阅读方式：范围内 9 个 .dart 文件均 `file_read` 从头到尾完整读（331/355 行文件分两段连续读，覆盖率 100%）；未以 grep/正则筛源码作为结论依据，shell 仅用于列目录、行数统计、级别计数与 import 路径核对。

