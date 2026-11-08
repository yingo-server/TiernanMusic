# v4.0.2 复核③：歌单反反顺序 + UI 细节 + 启动用户态（只读复核）

- 基线：`/var/minis/workspace/TiernanMusic` 当前工作区；未改动任何代码文件，唯一写入本报告。
- 规则依据（只读）：`docs/QUALITY_STANDARD.md`（32 条 + 第 33 条 + 第八章审查纪律）、`docs/v400_order.md`（反反规则与留样）。未读同期其它报告，避免锚定。
- 手段：对指定 6 个源码文件**完整 file_read**（不用 grep/正则抽样下结论）；为使 authStateProvider / 缓存键 / 写后刷新 / deep link / 文案键闭环，对必要关联源码同样完整 file_read。未装 SDK、未 flutter pub get、未改 pubspec；`dart analyze` 仅用于判断，结论不依赖构建产物。
- 证据等级：
  - **A 源码实锤**：当前基线源码逐行可读、无需运行时即可判定（引用「文件::函数/片段」）。
  - **B 文档一致**：与 `docs/v400_order.md` 的规则/留样数学一致；留样本体在 `/tmp/*`（仓库内不存在，文档自述 `like_485_all.json 未生成`），不可复算，不等同实测。
  - **C 静态推断**：依赖 Riverpod/框架语义或跨文件时序，需运行时复核。
  - **D 未验证**：需真机/原生接口三态实测（第 28/29/33 条），仅登记风险，不计入实锤。
  - **通过**：该核对项满足（附证据等级）。

## 汇报（8 行内）
（待全量汇总后回填）

---

## 一、分文件实时结论（按完整阅读顺序追加）

### 1) `docs/v400_order.md`（规则依据，37 行全文）
- 反反定义：页序倒 49→48→…→1 + 页内倒 10→1，等价「原 485 首完整反转」；485 首 / pageSize=10 → 49 页、末页 5 首；概念版分享页前 8 首与反反逐位吻合（四拼法对照 `/tmp/v4_paging_8.txt`，仓库内无此文件）。【B】
- 实现契约 8 条：①可信 total（`>0 && >=本页条数`）；②`ceil(total/pageSize).clamp(1,100)` + 末页余数按实长全取不补位；③页号降序 + 每页 `reversed`；④未知总数向前探测至不满/空页、起始页≠1 回填 `1..page-1`；⑤单页失败留痕并跳过、不吞成空不中断；⑥单页模式也页内倒转；⑦上界 100、total 不可信以实取条数为 total；⑧缓存走 `CachedApiCall`（90s + 失效回退 + in-flight 合并）。【B】
- 485 首/49 页/末页 5 首是 `pageSize=10` 探针留样；476 vs 485 差异为版权过滤（非缺陷）；`/tmp/like_485_all.json 未生成`，文档明确「数学上无需证明」。【B/D】

### 2) `docs/QUALITY_STANDARD.md`（167 行全文）
- 本报告引用的条款：3 契约先行、5 状态单一来源、6/9 禁止吞异常与失败可观测、11 降级触发/退出条件、14 数据边界校验、16 空集合与缺失语义分离、18 异步世代、20 生命周期对称、21 写操作幂等、23 缓存键覆盖全部影响维度、24 惰性构建、25 资源上限、28/29 接口实测、30/31 命名与注释、32 死代码、第八章（完整阅读/禁编译测试/禁读同期报告/实时落盘）、附 P0–P3 定义、33 kapi 包装结果不可作原生实测依据。【A】
- 分级口径：P0 崩溃/数据损坏/重复提交/安全泄露/用户数据丢失；P1 核心功能失效或长时间静默错误；P2 次要功能异常/边界态错误/性能退化；「只有能写出用户可见后果的才可定 P1 及以上」。【A】

### 3) `lib/features/playlist/data/playlist_repository.dart`（637 行全文）
- `fetchTracks`：`_cached.get('/playlist/track/all', {'id','page','pagesize'}, ttl:kListTtl)` → `_fetchAllReversed(...)`；`upstreamOrder` 历史参数确已删除。【A】
- `fetchUserTracks`：`_cached.get('/playlist/track/all/new', {'listid','page','pagesize','type':0}, ttl:kListTtl)` → 同一 `_fetchAllReversed`，默认 `allPages:true`、默认 `pageSize=300`。【A】→ **核对 2「两条路径都反反」：通过【A】**。
- `fetchUserPlaylists` 直连 `_api.get('/user/playlist')`（歌单列表，非歌曲列表，不属反反范围）；`PlaylistTracks.fromJson` 优先 `data.info` 兼容 `data.songs`，`total=_toInt(data['count'] ?? data['total'], fallback: songs.length)`，外部列表 `whereType<Map>` 校验。【A】
- `_fetchAllReversed` 逐条：
  - 单页模式 `!allPages` → `PlaylistTracks(songs: first.songs.reversed.toList(), total: first.total)`。**「单页模式页内倒转」：通过【A】**。
  - 可信判定 `trustedTotal = first.total > 0 && first.total >= first.songs.length ? first.total : 0`，与文档①逐字一致。【A/B】弱点：`count` 若是「本页条数」而非总数，此式仍判可信 → `totalPages=1` 静默只出一页（需原生实测 `data.count` 口径，登记为【D】）。
  - `size = pageSize > 0 ? pageSize : 100`；`totalPages = (trustedTotal / size).ceil().clamp(1, 100)`；各页 `pages[p] = t.songs` 原样全取，拼接时 `pages[p]!.reversed`，无补位。**「ceil 余数页按实际长度」：通过【A】**；485/10→49 页末页 5 首数学一致【B】，但运行默认 pageSize=100/300 时实际为 5 页末页 85 首 / 2 页末页 185 首，留样数字 49/5 只在 pageSize=10 下成立【B/D】。
  - 未知总数：`else` 从 `page+1` 起 `while (p <= 100)` 探测，`t.songs.isEmpty || t.songs.length < size` 则 break；`catch → debugPrint → break`；随后 `for (q=1; q<page && q<=100; q++)` 回填。**「未知总数探测 + 起始页≠1 回填」：通过【A/B】**；但探测分支单页失败是 **break（中断）**，与文档⑤「跳过、不中断」冲突 → 实锤缺陷（见问题清单）【A】。另：越界页若返回满页重复数据，探测会一直跑到 100 页（文档未留越界页样本，第 29 条；【D】）。
  - 已知总页数分支单页失败：`catch → debugPrint('[playlist] page $p failed: $e')`，不塞空页、继续 `for` → **「单页失败跳过」：通过【A】**（第 9 条「日志」二选一成立；用户侧无提示，顺序因缺页而不连续）。
  - 上界：`const maxPages = 100`，`clamp(1,100)` / `while(p<=100)` / `q<=100`。**「循环上界 100」：通过【A】**。副作用：`trustedTotal > 100*size` 时 clamp 后 `for p=1..100` 取的是**原列表最旧 100 页**，而反反要求末页优先 → 超大歌单顶部显示旧歌、返回 `total` 仍为 `trustedTotal`（虚高）→ 实锤缺陷（见问题清单）【A】。注释「pageSize=100 时 1 万首」与用户路径默认 300 不符（第 30/31 条，P3 不计入清单）。
  - 起始页≠1：total 可信时 `for 1..totalPages` 天然含 `1..page-1`；未知时显式回填 → **通过【A】**。边界：`page > totalPages` 时越界起始页仍以最大键排在结果最前（【C】，P2 观察）。
  - 结果 `total: trustedTotal > 0 ? trustedTotal : songs.length`，与文档⑦一致。【A/B】
- 写操作：`collectPlaylist` / `deletePlaylist` / `addTracks` / `removeTracks` 统一 `_write()`（飞行去重 `_inFlight`、DioException 分类 `maybeSucceeded` 语义），成功后 `_invalidatePlaylistCaches()` = `ResourceCache.instance.clearLists()` + `MemoryCache.removeWhere('/playlist/' | '/user/playlist')`。**HTTP 层失效存在【A】；但 Riverpod provider 未 invalidate** → 核对 2「写后列表刷新覆盖」不通过（见调用方文件结论与问题清单）【A】。
- `playlistRepositoryProvider` 是普通 `Provider<PlaylistRepository>`（非 autoDispose），自身不持有账号态。【A】
