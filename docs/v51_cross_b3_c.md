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

