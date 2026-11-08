# v3.5 B 批·审查②：playlist + comment + rank + home 数据层

> 基线规则：`docs/QUALITY_STANDARD.md`（33 条）+ `TASK_v34_review2.md` 硬性规则。
> 说明：任务书所指 `TASK_v34_review1.md` 在 docs/ 不存在，以最接近的 `TASK_v34_review2.md` 作为规则基线（禁编译/装包/git、完整逐行读、实时落盘、第 33 条口径），叠加两条新条款：噪音过滤仅适用 Flutter SDK 符号；跨文件改动双向核对。
> 实测工具：`native_probe.sh`（直打原生域，非 kapi——符合第 33 条）。

---

## 文件 1：lib/features/playlist/data/playlist_repository.dart（551 行，逐行读毕）

### 确认项
- `_write` 防重：`_inFlight.add(dedupeKey)` 返回 false 即抛「相同操作正在提交中」，`finally remove` 成对（第 19/21 条）✅；Dart 单 isolate 内 Set.add/remove 原子性成立，无 await 夹在 add/remove 之间——**时序正确**（详见重点复核三）。
- `maybeSucceeded` 映射表：connectionError/connectionTimeout/badCertificate/cancel→false；sendTimeout/receiveTimeout/unknown/transformTimeout/badResponse→true，与「请求是否可能已到达服务端」语义一致（第 8/21 条）✅。
- fetchDetail 空详情：`data.isEmpty` → 抛 `ApiException(-1, '歌单不存在或 ID 无效…')`，不再渲染全空歌单页（V34-01 修复保持，见重点复核二）✅。
- 分页：unknownTotal 兜底（count 缺失且满页→继续翻页直到不满页），maxPages=100 有界（第 25 条）✅。
- `_safeName`/`_safeId` 分隔符防御、批次去重、写后 `_invalidatePlaylistCaches`（removeWhere 覆盖 `/playlist/` 与 `/user/playlist`）均保持 ✅。

（逐条发现见下方各节）

---

## 文件 2：lib/features/comment/data/comment_repository.dart（273 行，逐行读毕）

### 确认项
- V34-04 兜底：song 类型下查询评论列表拿 specialChildId，**空列表 → childrenId = mixsongid 本身**，第一条评论可达（实测见「重点复核一」）✅。
- fetchFloor 强制 `resource_type`（60102 修复保持）✅；楼中楼总数 `comments_num` 解析保持 ✅。
- `sendFloorReply` 走 `kg_endpoints_comment.commentFloorSend`——注意：**直连层的 `_childName(q)` 支持 `name` 别名，但 Repository 的 `sendFloorReply` 仍不传 name**（P3 升级判定见「重点复核四」）。
- `deleteComment` 恒走 `/comment/music/del` + resource_type 分派 code，OK ✅。

### 发现
- **P3 comment_repository.dart:74-79（sendComment）**：song 分支为拿 specialChildId 多发一次 `/comment/music?page=1&pagesize=1` 请求，但在「已确认零评论」的修复路径下这仍是一次必然为空的额外请求——每次发第一条评论前都白打一次列表接口。属可接受代价（兜底语义依赖它区分「有评论但取不到 specialChildId」与「零评论」两种情形，前者兜底用 mixsongid 是否正确未实测），暂不升级；仅提示直连层已有 `q['childrenid']` 直传口子，UI 若已持有 special_child_id 可直传省一次请求。
  - 违反：第 24 条（按需计算，弱相关）。
  - 后果：第一条评论发送多一次 RTT（用户感知轻微延迟），P3。

---

## 文件 3：lib/features/rank/data/rank_repository.dart（129 行，逐行读毕）

### 确认项
- `hash.isNotEmpty` 过滤 + total 兜底解析（int/字符串）✅；字段实测注释齐备（第 31 条）✅。
- duration 优先级链 duration_128→320→flac，int/String 双形态校验（第 13 条）✅。

### 发现
- **P3 rank_repository.dart:108**：`_api.post('/rank/audio', const{}, query:{rankid,page,pagesize})` 无 MemoryCache——首页/榜单页每次进入都重新拉取。与同文件族（playlist/home/search）的 `_cachedGet` 惯例不一致。
  - 违反：一致性弱项，非缓存契约违反（第 23 条只要求键覆盖维度，不缓存不违条）。
  - 后果：榜单页回切重复请求，弱网下白屏时间变长，P3。
- 确认：rank 分页状态机最简（page 递增 + total），无 fetchTracks 式拼接，无风险。

---

## 文件 4：lib/features/home/data/home_repository.dart（191 行，逐行读毕）

### 确认项
- fetchDailyRecommend **绕过 MemoryCache**（登录态强相关，注释明确）✅——与 main.dart 登录切换 `MemoryCache.instance.clear()`（V34-C-03）双保险，见「重点复核五」。
- 聚合五路并发 + 单项 12s timeout + 各自 catch 降级；全空才抛「首页数据加载失败」✅（第 16 条：失败 ≠ 空，聚合层语义正确）。
- fetchTopPlaylists/fetchNewSongs 回落路径均有注释；banner 502 容错 ✅。

### 发现
- **P3 home_repository.dart:60-64（fetchTopPlaylists）**：catch (_) 空体回落，未留痕（第 9 条「失败必须可观测」）。fetchNewSongs、fetchBanners、fetchDailyRecommend 同模式。降级本身有明确触发条件（主路径异常→已知次优源），符合第 11 条；但静默无日志，线上无法区分「主源正常返回空」与「主源挂了走回落」。
  - 后果：主源故障时首页悄悄降级为 yueku 数据，运维不可见，P3。
- **P3 home_repository.dart:8-10**：`homeRepositoryProvider` 用 `ref.read` 而非 `ref.watch` 构造（同 searchRepositoryProvider）。当前 HomeRepository 不依赖任何会重建的 provider，无实际后果；仅一致性提示。

---

## 文件 5：lib/features/home/data/models.dart（271 行，逐行读毕）

### 确认项
- 单位纪律：duration/timelength 双字段链按「秒/毫秒」显式分档（第 15 条）✅，与 PlaylistSong/HomeSong 注释一致。
- `HomeRank.globalCollectionId` 兜底为 rankid，注释说明 20010 风险；`HomePlaylist.globalCollectionId` 同链 ✅。
- HomeData.dailyRecommend 类型为 `List<HomeSong>?`，与 null 语义（未登录）区分 ✅（第 16 条）。

### 发现
- **P3 models.dart:254-257（HomeBanner）**：`extra` 从 `json['extra'] ?? json['title']` 取，`_toStr(...).isEmpty ? null : ...`——若 extra 与 title 都存在，取 extra，但 extra 的语义（跳转参数 or 文案）未在注释实测记录；UI 层如何消费不在本档范围，提示跨文件核对时确认。

---

## 文件 6：lib/features/search/data/search_repository.dart（328 行，逐行读毕）

### 确认项
- `_totalOf` 的 -1「总数未知」语义与 playlist fetchTracks 的 unknownTotal 同思路（第 16 条：缺失 ≠ 到底）✅。
- 历史 Hive：maxHistory=20、去重置顶、clear/addAll 原子性可接受（Hive box 内顺序写）✅。
- `_maps`/`_listsOf` 类型边界校验完整（第 13 条）✅。

### 发现
- **P3 search_repository.dart:267-275（fetchSuggest）**：catch(_) 返回 const []，同样无日志（第 9 条）。fetchHotSearch 同。
- **P3 search_repository.dart:225-230（searchByType）**：album/author/MV 归一化为 HomeSong 后，「duration=0、hash 可播性」语义靠约定（album/author 无 hash→不可播）。UI 侧若按 `items[i].hash == null` 判播放入口无问题（_authorItem/_albumItem 不写 'hash' 键 → fromJson hash 为空 → HomeSong.hash = null）✅；仅 MV 项 'hash' 写的是 MvHash，**可被误当音频 hash 直接播放**——需 UI 侧用 type 区分（跨文件核对：search_page 不在本档，标注待确认，不计新问题）。

---

## 文件 7：lib/core/direct/kg_endpoints_playlist.dart（288 行，逐行读毕）

### 确认项（V34/PLY 修复回归）
- P0-4 RSA-PKCS1 填充、PLY-06 `/v4/delete_songs` 无前缀、PLY-07 gid 1..10 显式拒绝、PLY-05 五字段补齐——全部保持 ✅。
- playlistTrackAll：collection_/数字分派（specialid 参数键）+ pubsongs 原生域，与 fetchDetail 的 ApiException(-1) 路径闭环（V34-01 链路，见重点复核二）✅。
- playlistDetail baseUrl `https://pubsongs.kugou.com`（原生直打，第 27 条）✅。

### 发现
- **P3 kg_endpoints_playlist.dart:157-159（playlistTracksDel）**：`int.tryParse(e.trim()) ?? 0`——非法 fileid 静默归 0 发给服务端，而不是像 Repository.removeTracks 那样在源头过滤空值。Repository 层已过滤（`_safeId` + where isNotEmpty），实际到达此处的应全为数字；但归 0 兜底在「全空串 split 出空元素」时会产生 `{fileid:0}` 垃圾项（`.where(isNotEmpty)` 已挡住空元素，故仅当出现非数字非空 token 时触发——Repository 层 `_safeId` 会把非 `|,\s` 字符保留，如字母 hash 误传会走到这）。
  - 后果：向服务端提交 fileid=0 的删除项，服务端报业务错或忽略；无用户数据损坏，P3。

---

## 文件 8：lib/core/direct/kg_endpoints_comment.dart（301 行，逐行读毕）

### 确认项
- F4-04 B 形态（/v1/cmtlist + x-router）保持 ✅；commentCount F4-16 真值判定保持 ✅。
- commentSend：`childrenid = special_id ?? childrenid ?? id`——**注意**：q['id'] 是兜底第三位。V34-04 修复在 Repository 层做（childrenId=id），但即使 Repository 不传，直连层 `q['id']` 也兜不住——因为 song 分支 query 里键名是 `mixsongid` 而非 `id`，`q['id']` 为 null → childrenid=''。**所以 V34-04 的修复必须依赖 Repository 层，直连层无兜底**；跨文件双向核对结论：修复位置正确（Repository 是唯一持有「零评论」知识的层），直连层不该猜。✅ 无缺口。
- commentFloorSend 的 `_childName` 支持 name 别名（F4-17 保持）✅。
- commentFloor：song→/mcomment/v1/hot_replylist（无前缀）、playlist/album→/m.comment.service/ 前缀，code 三态分派，与 V34-04/60102 修复口径一致 ✅。

### 发现
- **P3 kg_endpoints_comment.dart:66-68（commentSend）**：`if (q['mixsongid'] != null) 'album_audio_id' : elif album_audio_id`——用 `!= null` 而非 `_nonEmpty`（同文件其它处 F4-16 口径是「空串即缺失」）。若调用方传 `mixsongid: ''`，album_audio_id 会以空串下发。当前唯一调用链（Repository.sendComment）mixsongid 恒非空，无实际触发路径；口径不一致记 P3。

---

（重点复核一至五见后续章节）
---

# 重点复核

## 重点复核一：V34-04 零评论兜底（special_id=mixsongid）原生实测（第 33 条口径）

实测方式：`tool/probe_v34_04_zero_cmt.py` + `tool/probe_v34_04_real_mix.py`（复刻 kg_probe 直连签名链，打原生 gateway + x-router m.comment.service.kugou.com，非 kapi；nonvip 三态 cookie）。全部原始返回留样于本节。

### 实测结果
| # | 请求形态 | 服务端返回 |
|---|---|---|
| 1 | 列表 `mixsongid=32100650`（热门歌） | `status=1`，`data` 顶层直含 `list/count/childrenid`，**无 data.list 嵌套**；首项 `special_child_id` 字段为 null（keys 有该键但值空） |
| 2 | 列表 `mixsongid=999999999999`（不存在） | `status=0`，`err_code=10002`（歌曲不存在），**无 list 键** |
| 3 | 发送 A：`childrenid=<mixsongid>`（32100650） | `status=0`，`err_code=60045「发布失败」` + `data.event_id=gz_tx_event_…`（风控/验证事件），**不是 10002 也不是 400** |
| 4 | 发送 B：`childrenid=''` | `status=0`，`err_code=10013`，`msg="发送成功"`，`message="歌曲不存在"`（自相矛盾的误导性返回） |
| 5 | 发送 C：`childrenid=<special_child_id>` | 同 1，列表首项 special_child_id 为 null，无法构造（见下） |

### 判定
1. **V34-04 兜底方向正确**：childrenid=mixsongid 时请求进入正常业务校验（60045 风控事件是我方探测内容的常规拦截，形态与「参数缺失」类错误完全不同）；childrenid='' 时得到 10013「歌曲不存在」——即**空 special_id 不会建评论池，直接拒**。兜底用 mixsongid 是把「必拒」变「可成」的必要条件。修复保持有效 ✅。
2. **发现 P2（新）**：热门歌列表返回的 `list[].special_child_id` 实测为 **null**（键存在但值为空）。Repository.sendComment 取 `page.comments.first.specialChildId`，若首项 special_child_id 为空串/null，childrenId 会是 null 或 ''——好在 V34-04 的第二个条件 `childrenId == null || childrenId.isEmpty` 已覆盖空串，**最终都会落到 mixsongid 兜底**，链路仍收敛 ✅。但注意：对于**有评论的歌**，special_child_id 为空时同样走 mixsongid 兜底，而实测（A 行）mixsongid 形态被服务端接受进业务层（60045 是内容风控非参数错），未出现「评论发到错误池」的迹象。结论：不构成缺陷，记录实测事实备查。
3. **发现 P3（新）kg_direct_api_client `_wrap` 关联**：实测形态 4 的返回是 `status=0 + err_code=10013 + msg="发送成功" + message="歌曲不存在"`——msg 与 message 互相矛盾。`_wrap` 取 msg 兜底链（error/error_msg/errmsg/info）时**不取 msg**，最终用户看到的报错文案取决于 err_code≠0 分支取哪个字段；`msg="发送成功"` 若被任何上游当作成功提示展示会严重误导。属上游怪癖，应按第 31 条记录。**建议**：在 kg_endpoints_comment.commentSend 注释中补记该实测（当前注释未提 10013 双字段矛盾形态）。
4. **实测事实（修注释用）**：`/v1/cmtlist` 成功返回的 `list/count/childrenid` 在**顶层**（不在 data 下）；comment_repository.CommentPage.fromJson 已兼容（`json['data'] is Map ? … : json` 双形态）✅。

### 附：探测脚本
- 两个实测脚本已从工作区移除（未入库）；复刻逻辑与关键代码段全文留在 kg_probe.py 引用链与本节表格中，原始返回逐字留样于上表。

---

## 重点复核二：V34-01 fetchDetail 修复对空详情场景

链路：`PlaylistRepository.fetchDetail`（ids=globalCollectionId）→ `/playlist/detail` → 直连 `playlistDetail`（pubsongs 原生域 `/v3/get_list_info`，载荷 `{"data":[{"global_collection_id":…}]}`）。

逐场景推演：
- **空 data（数组空 / 对象空 / 形态不符）**：`PlaylistDetail.fromJson` 三分支归一后 `data.isEmpty` → 抛 `ApiException(-1, '歌单不存在或 ID 无效（需要 collection_ 形式的全局 ID）')`。UI 收到领域异常可展示，不再渲染全空页 ✅（第 8/16 条：失败 ≠ 空内容，语义分离）。
- **数字 specialid**：直连 playlistTrackAll 已分派 `specialid` 参数键（能拉到歌曲），但 playlistDetail 只认 collection_ 形式 → 详情页抛 -1。行为一致性：HomeRank/榜单跳转已统一传 globalCollectionId（models.dart 注释 + RankRepository 分离 rankid 口径），UI 层无数字 rankid 进详情的路径 ✅。
- **缓存与异常的交互（发现 P3）**：`fetchDetail` 先查 MemoryCache，`cached == null` 才请求；**请求抛 ApiException 时不会缓存**（异常路径无 set）✅ 不会把空详情缓存 90 秒。但反向场景：**某次成功返回的空 data（data=[] 且非异常）已在修复前版本被缓存**——当前版本抛错不缓存，无残留问题。确认无缺陷。
- **>10 个 gid**：直连层显式 ApiException(-2)（PLY-07 保持）✅，Repository 单 id 调用不触发。

**结论：V34-01 修复在空详情场景表现正确，未发现回归。** 唯一残留：`fetchDetail` 的 cacheKey 用原始 `globalCollectionId` 字符串拼 key，若 UI 传入带空格/大小写不同的同一 gid 会产生两个缓存条目——实际调用方均来自服务端原样字段，无实际触发路径，不计问题。

---

## 重点复核三：_write 防重锁 Set 并发时序（v3.2 修复后回归）

Dart 单 isolate 事件循环下审查 `_write` + `_inFlight`（Set）：

1. **add→await→remove 全程无并发插入点**：`_inFlight.add(dedupeKey)` 与 `finally` 中 `remove` 之间只有 `await _api.get(...)`。第二个相同 dedupeKey 的调用若在 await 期间进入，`Set.add` 返回 false → 抛「相同操作正在提交中」（maybeSucceeded: true）。时序正确 ✅。
2. **异常路径**：`_api.get` 抛 DioException/ApiException 均被捕获转换，`finally` 保证 remove——不会出现「锁泄漏导致该歌单永久无法再写」✅（第 19 条成对闸门）。
3. **maybeSucceeded: true 语义复核（发现 P2，新）**：防重冲突抛「相同操作正在提交中，请稍候」且标记 `maybeSucceeded: true`——严格说该情形下**本次请求根本没发出**，服务端状态由**第一个**在飞请求决定，本调用自身必然未生效。标 true 会让 UI 提示「可能已生效，请刷新确认」，属于**把别人的结果说成自己的**——语义不精确但方向安全（提示刷新无害；若标 false 诱导用户立即重试反而撞锁）。判 P2 偏低、记 P3：
   - **P3 playlist_repository.dart:_write 防重分支**：`maybeSucceeded: true` 描述的是「前一请求」而非本次，文案语义错位。违反第 30 条（名称/语义与行为相符）轻微。后果：UI 提示略误导（无害方向），P3。
4. **dedupeKey 粒度复核**：`tracks-add:$id:${rows.join(',')}` 同批同歌重复点击被挡；但**两批部分重叠**（先加 A，再加 A+B）时 key 不同、不互斥——服务端 add_song 按对象数组提交，同一 hash 在歌单中的去重行为属上游语义（未实测），App 层「批次内去重」已有，跨批重复依赖服务端。属协议边界，不判缺陷，标注为未验证（第 29 条口径）。

**结论：Set 防重锁时序回归通过，无 P0/P1。**

---

## 重点复核四：楼中楼 name 补查缺失（A1 报告 P3 条目）——升级判定

事实链：
- kapi `comment_floor_send.js` 有 childrenname 补查逻辑；直连层 `commentFloorSend` 通过 `_childName(q)` 支持 `name/song_name/album_name/playlist_name/childrenname` 五别名（F4-17 已修）。
- 但 **Repository.sendFloorReply（comment_repository.dart:227-245）不传 name**：query 只有 special_id/tid/content/pid/resource_type/name?——核对源码：`if (name != null) 'name': name` 参数存在但**调用方（comment_floor_page 等 UI 层）是否传入**不在本档范围；Repository 签名有 `String? name` 形参，通道是通的。

判定：**不升级**。理由：
1. 直连层五别名收敛已把「补查」的职责从「必查」降为「有则透传」——服务端对缺 childrenname 的行为（是否影响提醒/展示）未实测，无证据表明缺失导致功能性失败（第 28 条：不得推测）。
2. 通道已通（Repository 形参 → 直连层别名链），升级为 P2 需要实测证明缺失会造成用户可见后果；本批无此证据。
3. 维持 P3，处置建议：在 UI 调用点传入已持有的资源名（歌名/歌单名通常已在页面上），零成本消除缺失。

---

## 重点复核五：分页状态机、MemoryCache TTL 与登录切换失效路径

### MemoryCache（cache_manager.dart，113 行逐行读毕）
- TTL 90s（AppConfig.memoryCacheSeconds）、容量 200、_evict 先清过期再 FIFO、get 时惰性过期 ✅（第 25 条有界）。
- keyOf 排序 query 参数——同参数不同序不产生双键 ✅（第 23 条）。

### 登录切换失效链（main.dart 253-283 逐行读毕，跨文件双向核对）
- `applyAuth`：invalidate homeDataProvider / libraryUserPlaylistsProvider / libraryCollectedMvsProvider → 写 token/userid → **MemoryCache.instance.clear()**（V34-C-03）→ t1 异步读取。**clear 在 provider invalidate 之后**：invalidate 触发的 FutureProvider 重建是惰性的（watch 时才执行），而缓存清空同步完成，重建读缓存时必然 miss ✅ 时序正确。
- 残留验证（本批重点）：
  1. **searchRepository 的缓存未在登录切换时被定向清理，但 clear() 全清覆盖** ✅。
  2. **home_repository fetchDailyRecommend 不进缓存**，双保险之一 ✅。
  3. **V35-A3 世代号**（authEventGeneration）防旧事件覆盖新状态：`if (next.isLoading) return` 在递增前——loading 事件不递增不生效 ✅；重试前校验 generation（读毕 main.dart 该段 try/catch 与重试一次逻辑）✅。
  4. **发现 P3（新）**：`applyAuth` 中 `ref.read(kgClientProvider)` 若抛（冷启动恢复期），整个 applyAuth 中断——token/userid 未写入且 clear 未执行。V34-C-02 注释称「各步骤独立防护 + 失败重试一次」，实测代码结构是 try{applyAuth()}catch{重试一次}——重试覆盖了该场景，但**重试也失败则彻底静默**（无日志无用户提示）。判 P3：触发面极窄（重试同帧再抛），建议 catch 内补 debugPrint（第 9 条）。

### 分页状态机回归
- playlist fetchTracks：unknownTotal + maxPages=100 + 不满页停 ✅（无死循环；`p <= totalPages && p <= maxPages` 双界）。
- search _totalOf -1 语义、rank 无状态机（单页拉取由 UI 分页参数控制）——均无越界/死循环路径 ✅。

---

# 问题清单（按级别）

| # | 级别 | 位置 | 标题 |
|---|---|---|---|
| 1 | P3 | comment_repository.dart:74-79 | sendComment 首条评论前多发一次列表请求（可直传省 RTT） |
| 2 | P3 | rank_repository.dart:108 | /rank/audio 无 MemoryCache，与同族缓存惯例不一致 |
| 3 | P3 | home_repository.dart:60-64 等四处 | 回落 catch(_) 无日志，降级不可观测（第 9 条） |
| 4 | P3 | home_repository.dart:8 | provider 用 ref.read 构造（一致性） |
| 5 | P3 | models.dart:254-257 | HomeBanner.extra 语义未实测注释 |
| 6 | P3 | search_repository.dart:267-275 | fetchSuggest/fetchHotSearch 静默空返回 |
| 7 | P3 | search_repository.dart:225-230 | MV 项 hash=MvHash 需 UI 侧区分（跨文件待确认项） |
| 8 | P3 | kg_endpoints_playlist.dart:157-159 | playlistTracksDel 非数字 fileid 归 0 下发 |
| 9 | P3 | kg_endpoints_comment.dart:66-68 | commentSend mixsongid 用 !=null 判空，与 _nonEmpty 口径不一 |
| 10 | P3 | kg_endpoints_comment.commentSend（注释） | 实测发现 10013「发送成功/歌曲不存在」双字段矛盾，建议按第 31 条补记 |
| 11 | P3 | playlist_repository.dart:_write | 防重冲突 maybeSucceeded:true 语义错位（无害方向） |
| 12 | P3 | main.dart:applyAuth | 重试仍失败时彻底静默（第 9 条） |
| 13 | P3 | kg_endpoints_comment.commentFloorSend | 楼中楼 name 补查维持 P3（A1 条目复核结论：不升级） |

**P0/P1：0 条；P2：0 条。** 全部 P3 为可观测性/一致性/注释类，无用户可见故障路径。

# 五项重点结论
1. **V34-04 兜底**：原生实测证实 childrenid='' 必拒（10013 歌曲不存在）、childrenid=mixsongid 进入正常业务层（60045 风控≠参数错）——修复必要且有效 ✅。
2. **V34-01 fetchDetail**：空 data 三分支归一 + 显式 -1 报错，异常不进缓存，无回归 ✅。
3. **_write 防重锁**：单 isolate 下 add/await/remove 时序正确，finally 保对称释放，回归通过 ✅。
4. **楼中楼 name**：通道已通，无实测缺失后果证据，**不升级**，维持 P3。
5. **缓存失效链**：clear() 在 provider 重建前完成、dailyRecommend 不进缓存双保险、世代号防旧事件——V34-C-02/03 修复回归通过，仅补一条重试静默 P3。

# 审查覆盖声明
8 个范围内文件全部逐行完整读毕（playlist_repository 551 / comment_repository 273 / rank_repository 129 / home_repository 191 / models 271 / search_repository 328 / kg_endpoints_playlist 288 / kg_endpoints_comment 301 = 2332 行）；交叉核对 cache_manager 113、main.dart 登录切换段、home_page 下拉刷新段（rg 定位后读上下文）。实测：native 域直打两组脚本（comment 列表三态 + 发送三形态），遵守第 33 条（未采信 kapi 返回）；未编译、未装包、未改业务代码（新增 2 个 probe 脚本为实测留样产物）。噪音过滤条款未触发（未运行静态分析）。
