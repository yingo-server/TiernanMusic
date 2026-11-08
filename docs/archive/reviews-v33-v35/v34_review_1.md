# v3.4 审查①（v3.3.0 发布后功能正确性专项）

- 基线：`ac188b2`（tag v3.3.0）
- 范围：播放/歌词/搜索/歌单/评论/下载/MV 数据层功能正确性
- 依据：QUALITY_STANDARD（含第九章第 33 条）
- 方法：逐文件完整 file_read；native_probe.sh 直打原生域实测；kapi 返回不作判定依据

---

### audio_handler.dart:131 processingState.completed 无条件 skipToNext，与单曲循环/试听交互未区分
- 级别：P2
- 事实：`p.processingStateStream.listen((state) { if (state == ProcessingState.completed) skipToNext(); });`
- 违反：QUALITY_STANDARD 第 11 条（降级/推进无明确触发与退出条件）
- 后果：60 秒试听文件播完同样触发自动跳下一首；试听曲目无法在结尾处停留/重试完整版，用户听到的是「试听一结束就切歌」，与 VIP 曲预期不一致。另:preview 状态下静默换曲，`_isPreview` 由 `_playAt` 重置，行为可接受但跳歌本身未经用户确认。

### audio_handler.dart:372 离线回退在线分支缺少「同曲成功后 _failureStreak 语义」与外层 catch 一致性
- 级别：P3
- 事实：离线分支 catch (Exception) 内直接做在线解析，若 `resolveUrl` 抛 ApiException(needsVerification)，异常会穿透到外层 catch，被当作普通播放失败 `_failureStreak++` 并自动 skipToNext
- 违反：QUALITY_STANDARD 第 8 条（回退路径与主路径异常形态必须一致——主路径 20028 停止跳歌，回退路径却跳歌）
- 后果：本地文件失效的 VIP 曲命中 20028 时不会弹人机验证，而是静默跳下一首，用户无法完成验证后重听该曲。

### audio_handler.dart:365 localUsable 判定使用 existsSync 同步 IO
- 级别：P3
- 事实：`(local.startsWith('content://') || File(local).existsSync())`
- 违反：QUALITY_STANDARD 第 26 条（热路径内同步磁盘 IO）
- 后果：每次切歌在 UI isolate 上做一次同步 stat，低端机/网络盘挂载时切歌可感知卡顿（轻微）。

### audio_handler.dart:575 onNotificationDeleted 直接 `_playerOrNull?.stop()`，未与 stop() 完全对称
- 级别：P3
- 事实：stop() 会 `_currentSongController.add(null)` + `super.stop()`，onNotificationDeleted 只 `p.stop()`
- 违反：QUALITY_STANDARD 第 20 条（生命周期双向对称）
- 后果：划掉通知后 currentSongStream 仍持有旧歌，UI「当前播放」卡片显示已停止的歌，点击播放行为依赖残留 _index（轻微不一致）。

---
### player_repository.dart:93-110 ensureDfid 并发等待者在注册失败后走 `return ensureDfid()` 可能无限递归
- 级别：P2
- 事实：
```dart
if (_registering) {
  final pending = _registeringFuture;
  if (pending != null) {
    try { await pending; } catch (_) {}
    return ensureDfid(); // 重读一次缓存（成功则拿到；失败则再试一轮，有界）
  }
```
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发与退出条件）——注释称「有界」，但 `ensureDfid()` 重入时若 dfid 仍为空且 `_registerRetries < 3`，会再次发起注册；若注册持续失败且每次都有并发等待者挂在 `_registeringFuture` 上，每次重入只消耗一次 retry，3 次后靠 `_registerRetries >= 3` 截断。但**成功路径**不重置 `_registeringFuture` 前的等待者若在 completer.complete() 之后重入，此时 `_registering == false`，直接重新注册一次（重复网络请求）。
- 后果：注册接口偶发失败时，多个并发播放请求各触发一轮注册重试（最多 3 轮 × 请求数），首播延迟放大到数秒；无用户可见错误前的长时间转圈。

### player_repository.dart:138-155 fetchDetail 对 `data is List` 且 hash 不匹配时取 `entries.first` 兜底——可能把别的歌的详情合并进来
- 级别：P1
- 事实：
```dart
final matching = entries.where((entry) =>
    '${entry['hash']}'.toUpperCase() == song.hash.toUpperCase());
final detail = matching.isNotEmpty ? matching.first : entries.first;
final merged = Song.fromJson(Map<String, dynamic>.from(detail));
```
- 违反：QUALITY_STANDARD 第 14 条（边界数据必须校验）/ 第 16 条（缺失与命中语义分离）——hash 未命中是「详情不可用」这一事实，却用**任意另一条目**（可能是同专辑另一首歌，甚至不同歌）的 name/artist/cover/albumAudioId 覆盖。
- 后果：详情接口返回列表不带目标 hash 时（多 quality 条目 hash 前缀不同的场景实测存在），播放卡片显示**错歌的封面/歌名**，且 albumAudioId 被换成错歌的，后续 /v5/url 解析用错 album_audio_id 可能拿错文件或失败——「点了 A 歌放出 B 歌的封面甚至 B 的音频元数据」。

### player_repository.dart:193-207 resolveUrl 直连失败回退 kapi 但 20028 之外的网络异常不回退
- 级别：P1
- 事实：
```dart
try {
  final direct = await _resolveViaDirect(song, preferred: preferred);
  if (direct != null) return direct;
} on ApiException catch (e) {
  if (e.errorCode == 20028) rethrow;
}
return _resolveViaKapi(song, preferred: preferred);
```
`_resolveViaDirect` 末尾：`if (lastErrorCode != null && lastErrorCode != 0) throw ...; return null;`——若无 URL 且无错误码（网络超时抛 DioException 等），DioException **不被捕获**，直接冒泡，kapi 回退永不执行。
- 违反：QUALITY_STANDARD 第 8 条（回退路径异常形态不一致）/ 第 11 条（回退触发条件缺失）
- 后果：直连域名瞬时网络故障（超时/DNS 失败）时整首播放失败报错，而 kapi 路径本可成功——「有网但播不了」，用户重试也大概率同样失败（直连先挂）。

### player_repository.dart:210-268 _resolveViaDirect 中 `final play = _directPlay!` 非空断言跨异步边界
- 级别：P3
- 事实：`final play = _directPlay!;`——`_directPlay` 是 getter 读取 provider，resolveUrl 检查过非空但 `ensureDfid()` await 之后理论上仍用入口处捕获的引用，此断言在同一函数体内、入口已判空，可接受；但 getter 每次读取可能返回不同实例，若 provider 在异步期间被 dispose 会抛 null check 崩溃
- 违反：QUALITY_STANDARD 第 12 条（严格说是同一函数体已证明，低风险）
- 后果：极小概率 null check 失败崩溃（P3，仅 provider 重建窗口）。

### player_repository.dart:299-330 _resolveViaKapi 的 isPreview 判定把「priv_status==0 或有 hash_offset」当试听
- 级别：P2
- 事实：`isPreview: _int(data['priv_status']) == 0 || data['hash_offset'] is Map`
- 违反：QUALITY_STANDARD 第 29 条（返回结构必须实测留样）——priv_status 语义未实测留样，0 若表示「全曲免费」则免费曲被误标试听；hash_offset 非试听场景（如无损截断下发）也会误判
- 后果：完整播放的免费曲 UI 挂「60 秒试听」角标，用户误以为只播一半，看到进度超过 60 秒后对角标失去信任。

### player_repository.dart:357 _songFailureMessage 检查 `data['privilege']` 与 canPlay(data)——canPlay 期望的是 privilege 条目本身而非外层 data
- 级别：P2
- 事实：`if (data['privilege'] != null && !canPlay(data))` —— canPlay(Map) 读 `privilege['status']`/`privilege['privilege']`，传入的却是含 privilege 字段的**外层响应**；应传 `data['privilege']`。仅当外层恰好也有 status/privilege 数字字段时碰巧工作
- 违反：QUALITY_STANDARD 第 14 条 / 第 3 条（契约先行）
- 后果：无版权/需 VIP 的失败被降级为兜底文案「音质 xx 暂不可播放」，用户得不到「无版权/需会员」的准确原因（错误提示误导）。

---
### models.dart:150-158 Song.fromJson 歌名剥离：artist 为空时对含 " - " 的歌名盲剥前缀
- 级别：P3
- 事实：
```dart
final sep = raw.indexOf(' - ');
if (sep > 0 && (artist.isEmpty || raw.substring(0, sep) == artist)) {
  name = raw.substring(sep + 3).trim();
}
```
- 违反：QUALITY_STANDARD 第 14 条（边界数据假设过强）
- 后果：详情接口 singername 为空且歌名本身含 " - "（如 "Left - Right"）时，歌名被截为 "Right"——搜索结果/播放卡片显示错名（边界态，少见）。

### models.dart:197 `AudioQuality.fromString(str(['quality']))` 与上游 'quality' 字段形态未对照
- 级别：P3
- 事实：注释自述「quality_vip 可为 null，best_free_quality 在该部署版中不存在」，但 /privilege/lite 顶层 quality 若为 Map/List（条目列表），`'$v'` 拼接成非空乱串 → fromString 落 q128，song.quality 恒为标准音质
- 违反：QUALITY_STANDARD 第 29 条（返回结构需实测留样）
- 后果：列表页/播放器「期望音质」恒显示标准音质；实际解析仍按用户设置走，属展示层失真（P3）。

---
### play_helper.dart:14-92 PlayHelper 丢弃 Song.localPath 之外的转换风险——PlaylistSong 无 localPath 概念本身使离线播放入口依赖 audio_handler 的覆盖逻辑
- 级别：P3
- 事实：PlayHelper 构造的 Song 均无 localPath；下载页入口走 playSong(Song) 时若 hash 命中队列则覆盖 localPath（audio_handler.playSong），未命中则插入带 localPath 的 Song——两条路径行为一致，无缺陷。唯 `hash: s.hash ?? s.id` 在 hash 缺失时用 id 充当 hash，若 id 不是真 hash（如 mixsongid），/v5/url 直连解析必失败
- 违反：QUALITY_STANDARD 第 14 条（把非 hash 标识符当 hash 传入边界）
- 后果：首页推荐某些条目无 FileHash 只有 id 时点击播放失败报「直连获取播放地址失败」（取决于上游是否总是下发 hash，未实测，列为待验证）。

---
### krc_parser.dart:118-126 KRC 行内嵌 translation 未解析：KRC 原生翻译对齐依赖 language 行单一来源
- 级别：P2
- 事实：KRC 的翻译有两条来源：1) `[language:...]` 行（已处理）；2) 部分部署版 KRC 把翻译放在 `translation` 键或另一下发行（非 language 结构）。解析器只支持 language 行，且对齐条件 `embeddedTranslations.length == lines.length` 在 LRC 回填/合并行改变行数后基本不成立
- 违反：QUALITY_STANDARD 第 29 条（返回结构需实测留样；language 结构「不同版本不一致」已在注释承认但仅覆盖 A/B/C 三形态）
- 后果：多数带翻译的 KRC 文件用户看不到中文/英文翻译行（歌词页翻译开关无效），属功能静默缺失。

### krc_parser.dart:60 offset 语义方向未实测留样
- 级别：P2
- 事实：`startMs: line.startMs - offset`，注释断言「正值 = 歌词提前显示」
- 违反：QUALITY_STANDARD 第 29 条（该断言无实测证据标注；LRC 生态中 offset 正值通常表示歌词**延后**显示的约定亦存在，两种约定并存）
- 后果：若上游 offset 约定相反，全部带 offset 的歌词整体提前/延后数秒，逐字高亮与演唱错位（用户可见「歌词抢拍/慢拍」）。

### krc_parser.dart:126-136（LRC 行）duration 回填对多时间戳重复行未压缩
- 级别：P3
- 事实：`for (final startMs in times)` 为副歌复用处同一正文生成多条 KrcLine；回填用「下一条 startMs」，排序后重复行的 duration 由相邻重复行分割——行为合理。但 `leadingText` 在 lines 非空时被永久丢弃（`leadingText.write(line)` 只在 lines 空时最终采用）
- 违反：QUALITY_STANDARD 第 16 条（头部提示文本「丢弃」与「保留」无语义区分）
- 后果：文件头部版权/译者注在正文非空时消失（低影响）。

### krc_parser.dart:262-267 _decodeLanguage 失败降级为 value 按行分割——Base64 串单行 split 结果是整串原文密文
- 级别：P3
- 事实：`return value.split(RegExp(r'\r?\n'));`——catch 到的 Base64 串本身是一行，返回 `[整个Base64串]`；若随后长度恰好等于行数，会把密文当译文贴到歌词上
- 违反：QUALITY_STANDARD 第 6 条（降级值无语义）
- 后果：损坏的 language 行可能让第一行歌词的「翻译」显示为一长串 Base64 乱码（罕见但用户可见）。

---
### krc_decoder.dart:78-95 「跳过 4 字节长度前缀」重试改变了 XOR key 相位但复用同一 _key[(i+4)%16] 假设
- 级别：P2
- 事实：
```dart
final shifted = Uint8List(body.length - 4);
for (var i = 0; i < shifted.length; i++) {
  shifted[i] = body[i + 4] ^ _key[(i + 4) % 16];
}
```
该重试假设：长度前缀**参与了**第一轮 XOR（即 key 相位从整个 body 起算），跳过前 4 字节后 key 相位是 (i+4)%16。若实际形态是「前缀不参与 XOR」（相位应从 0 起算），第二次尝试同样失败并归类 corruptPayload——两种形态只覆盖了一种
- 违反：QUALITY_STANDARD 第 28 条（调用方式/数据形态必须实测，不得推测）——注释未标注该形态是否实测留样
- 后果：特定服务端形态的 KRC 全量解密失败 → 歌词页显示「暂无歌词」，用户看不到歌词且无重试路径（降级 LRC 可部分挽救）。

### krc_decoder.dart:98-101 decode() 兼容入口丢弃 error 分类返回空串
- 级别：P3
- 事实：`static String decode(...) => decodeDetailed(base64Content).text;` 注释明确「新代码请用 decodeDetailed」——但旧入口仍导出，属过渡期允许的兼容层；若 lyric_repository 是唯一调用方且已迁移，此入口为死代码
- 违反：QUALITY_STANDARD 第 32 条（若已无调用点）
- 后果：无直接用户后果（整洁度）；待核对调用点后定级。

### lyric_repository.dart:60-90 findCandidate 候选挑选只取**第一个**合法候选，未用 durationSec 匹配
- 级别：P2
- 事实：循环内命中第一个 id/accessKey 完整的候选即 `return LyricCandidate(...)`，`duration` 与入参 `durationSec` 从未比对；durationSec 只进了搜索 query
- 违反：QUALITY_STANDARD 第 14 条（搜索结果与目标曲一致性校验缺失）/ 第 3 条（durationSec 参数契约未兑现）
- 后果：同名歌曲（翻唱/Live/错时长版本）搜索命中靠前但非目标版本时，播放页显示**另一版本**的歌词（对不上拍、词不同）——用户可见「词不对曲」。

### lyric_repository.dart:174-181 翻译批次错位：batch 是 missing 的连续切片，但 `translations[missing[i + j]]` 索引含义依赖 i 是 missing 的下标而非 texts 的偏移
- 级别：P1
- 事实：
```dart
final texts = [for (final i in missing) lyric.lines[i].text];
...
for (var i = 0; i < texts.length; i += batchSize) {
  final batch = texts.sublist(i, ...);
  ...
  translations[missing[i + j]] = value;
```
此处 `i` 是 texts 的偏移，`missing[i + j]` 恰好也是正确的（texts 与 missing 一一同序同长），**索引是对的**。但 F4-32 修复后 `n = min(translated.length, batch.length)`，若翻译服务返回条数多于请求（部分实现返回整段合并文本），多余的条目被静默忽略，前 n 条对位假设「translateLines 逐行一一对应」——若服务端返回的是合并后的整行（条数=1），则所有行译文丢失
- 违反：QUALITY_STANDARD 第 29 条（translateLines 返回形态需实测留样）
- 后果：翻译服务按段落合并返回时，整批译文被丢弃且不缓存，用户歌词永远无翻译（与旧缺陷同表现，但触发条件不同）。

### lyric_repository.dart:23-28 歌词缓存 30 分钟 TTL 但 MemoryCache 键含 accesskey——candidate 每次搜索返回的 accesskey 可能轮换，导致缓存永不命中
- 级别：P3
- 事实：`MemoryCache.keyOf('/lyric', query)` 的 query 含 accesskey；若上游每次 /search/lyric 返回新 accesskey，缓存形同虚设（只是多打请求，无错误）
- 违反：QUALITY_STANDARD 第 23 条（缓存键维度过多导致命中率归零也是一种失效）
- 后果：同一首歌每轮播放重新请求歌词接口，流量与延迟浪费（轻微）。

---
### search_repository.dart:174-178 _mvItem 封面 URL 硬编码 http:// 且 {size} 占位符不回填
- 级别：P2
- 事实：`cover = 'http://imge.kugou.com/mvthumb/{size}/$pic';`——models.Song.fromJson 会做 `cover.replaceAll('{size}', '400')`，但 HomeSong.fromJson（home/data/models.dart）是否处理 {size} 未在此证明；且 http 明文在 Android 9+ 默认禁 cleartext（network_security_config 只放行 kugou.com 的话 imge.kugou.com 属子域可放行）
- 违反：QUALITY_STANDARD 第 28 条（URL 形态需实测）
- 后果：MV 搜索结果封面加载失败显示灰块（若 HomeSong 不回填 {size} 或 http 被禁）。列为待实测项。

### search_repository.dart:45-52 _cachedGet 无 TTL 调用默认值——搜索结果缓存时长由 MemoryCache 默认值决定（90s），热搜/建议同键空间混存无问题；但 addHistory 用 box.clear()+addAll 重写整箱
- 级别：P2
- 事实：
```dart
await box.clear();
await box.addAll(list);
```
clear 与 addAll 非原子：进程在两步之间被杀（或 addAll 抛异常），历史**全部丢失**而非仅少一条
- 违反：QUALITY_STANDARD 第 21 条（写操作应幂等/可恢复；数据丢失风险）
- 后果：极小概率用户搜索历史整箱清空（数据丢失边界态，P2 边缘）。

### search_repository.dart:226-235 fetchHotSearch 吞掉一切异常返回空列表且无留痕
- 级别：P2
- 事实：`catch (_) { return const []; }`——网络失败与「确实无热搜」都映射为空列表（第 16 条语义分离失效），且无日志（第 9 条失败不可观测）
- 违反：QUALITY_STANDARD 第 6/9/16 条
- 后果：热搜接口故障时页面静默空白，用户以为没有热搜，线上无日志可查。fetchSuggest 同病（:276-278）。

---
### playlist_repository.dart:397-401 _inFlight 防重键含动态内容且跨实例失效——Provider 每次重建新仓库时防重集合归零
- 级别：P2
- 事实：`final Set<String> _inFlight = <String>{};` 挂在 PlaylistRepository 实例上，而 `playlistRepositoryProvider = Provider((ref) => PlaylistRepository(ref.watch(kugouApiClientProvider)))` 使用 **watch**——kugouApiClientProvider 因登录态/dfid 变化重建时，新 PlaylistRepository 的 _inFlight 为空，飞行中的旧写操作防重失效
- 违反：QUALITY_STANDARD 第 21/22 条（防重机制必须独立于可重建实例）
- 后果：登录切换瞬间正在提交的加歌操作可被 UI 重试按钮再次触发，重复提交（第 21 条红线，低概率）。

### playlist_repository.dart:135-166 fetchTracks(allPages) 循环中每页失败无 catch——第 2 页超时让整个「拉全量」失败，连第 1 页成功数据也丢弃
- 级别：P2
- 事实：`final t = await fetch(p); songs.addAll(t.songs);`——fetch 内 `_api.get` 抛异常直接冒泡，已拉取的 songs 全部丢弃
- 违反：QUALITY_STANDARD 第 11 条（部分成功的降级语义未定义）
- 后果：大歌单（>100 首）网络抖动时「播放全部」整体失败，用户看到报错而非至少播放第一页——可用性损失明显。

### playlist_repository.dart:73-77 fetchDetail 缓存键只含 globalCollectionId，写操作后失效列表 `startsWith('/playlist/')` 覆盖该键——正确；但 fetchTracks 的缓存键 '/playlist/track/all' 前缀同样覆盖——无缺陷。真正的缺口：**添加歌曲到「我的歌单」用的 '/playlist/track/all/new' 前缀也匹配**——确认无缺陷。改报：UserPlaylist.isMine 判定逻辑可疑
- 级别：P2
- 事实：`isMine: _toInt(json['list_create_type'], fallback: 1) == 0 || '${json['is_create'] ?? ''}' == '1'`——注释自述 `list_create_type` 实测存在于用户歌单项；若「收藏的歌单」list_create_type 也为 0（或字段缺失走 fallback=1 但 is_create=1 来自收藏标记），收藏歌单会被误标为「我创建的」，UI 上不可删除判断/分组错乱
- 违反：QUALITY_STANDARD 第 29 条（list_create_type 语义未留样佐证「0=自建」）
- 后果：「我的歌单」页把收藏歌单显示成自建歌单，删除入口行为与预期不符（列待实测）。

### playlist_repository.dart:214-230 addTracks 的 rows.join(',') 与 dedupeKey 超长——大批次（数百首）data 参数与 dedupeKey 巨大
- 级别：P3
- 事实：`dedupeKey: 'tracks-add:$id:${rows.join(',')}'`——dedupeKey 仅用于进程内 Set，把整包数据复制一份作键，纯浪费内存
- 违反：QUALITY_STANDARD 第 26 条（热路径外但无意义分配）
- 后果：无直接用户可见后果（整洁度，P3）；建议用 hash 摘要。

---
### comment_repository.dart:88-101 sendComment(歌曲) 在歌曲无评论时 childrenid 为空 → 服务端 400（Node 语义：childrenid 必须来自 specialChildId 查询）
- 级别：P1
- 事实：
```dart
childrenId = page.comments.isNotEmpty
    ? page.comments.first.specialChildId : null;
...
if (childrenId != null && childrenId.isNotEmpty) 'special_id': childrenId,
```
直连层（kg_endpoints_comment.dart:88）：`'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}'`——song 分支只传 mixsongid（无 'id' 键），special_id 缺失时 childrenid=''。
- 违反：QUALITY_STANDARD 第 28 条（Node 参考实现 comment_music_send.js 明确：mixsongid 查不到 specialChildId 返回 400，即 childrenid 是必填；Dart 层「交给直连层兜底」但直连层没有查询逻辑，只有空串兜底）
- 后果：**零评论的歌曲永远发不出第一条评论**（服务端 400/参数错误），用户看到发送失败；热门歌曲可用，冷门歌曲必失败——典型静默边缘态缺陷。
- 注：直连实测需 native_probe 验证（childrenid='' 的服务端行为），本条为代码级推断 + Node 对照。

### comment_repository.dart:175-180 isMine 判定：currentUserId 为空字符串时短路为 false——未登录用户不能删除任何评论（正确），但 userid 数字化改造后 `'$id'` 与 json userid 的类型形态需一致
- 级别：P3
- 事实：`'${json['userid'] ?? json['user_id'] ?? ''}' == (currentUserId ?? '')`——若一侧是 `1234567` 另一侧是 `"1234567.0"` 或带空格则永不匹配
- 违反：QUALITY_STANDARD 第 17 条（标识符表示形式跨层转换需显式）
- 后果：自己的评论不显示「删除」按钮（低概率，取决于 userid 存储形态）。

### comment_repository.dart:138 sendFloorReply 对 playlist/album 资源的 tid 特殊化不足（与 Node 对照），resource_type 默认 song 但调用方可传 playlist
- 级别：P3
- 事实：reply/del 的 code 由 resource_type 选择（_commentCodeOf 已覆盖），但 childrenid 回退链 `q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''`——playlist 场景调用方传的是 specialId（special_child_id），语义正确。无缺陷，撤销本条候选。

### comment_repository.dart:62-67 fetchCount 顶层取值 `data[hash]`——kapi 形态与直连 _wrap 形态不同时（直连返回 {data:{...}} 包装），hash 键查不到恒返回 0
- 级别：P2
- 事实：`final value = data[hash] ?? data[hash.toUpperCase()] ?? ...`——直连 commentCount 返回经 _wrap 的完整 body；若数值在 `body['data']` 下层而非顶层 hash 键，此处恒 0
- 违反：QUALITY_STANDARD 第 29 条（返回结构需按直连实测留样；此处按 kapi 形态编写）
- 后果：歌曲详情页评论数恒显示 0（点击进去评论正常）——显示层失真。列为待实测（kapi 包装 vs 原生 body 对照）。

### kg_direct_api_client.dart:347-351 post 分派 comment send 三件套但 get 分派表 :242-254 同样存在——重复分派，get 路径 write:true 语义正确；但 CommentRepository 已改走 post，get 分派成为死代码候选
- 级别：P3
- 事实：get 分派表中 `case 'comment/music/send'` 等三例（:250-254）与 post 分派重复；代码注释自述「CommentRepository 走 post → 恒抛 -404」已修复，get 分支的 send 三件套不再有调用方
- 违反：QUALITY_STANDARD 第 32 条（死代码）
- 后果：无直接用户后果；双份分派未来改签名只改一处会静默分叉（维护风险）。

---
### download_provider.dart:292-301 remove() 的临时文件名与 _run 的 realTempPath 维度键**不一致**（audio 真实扩展名 + dimKey 相同但 remove 重建 raw 串时依赖 task.quality/albumAudioId 持久化字段）
- 级别：P1
- 事实：`_run` 中 `realTempPath = tempPath.replaceAll(RegExp(r'\.mp3$'), ext)`；`remove()` 中重建 `f = File('${tmpDir.path}/${task.hash}_${task.type.name}_$h${task.type.fileExtension}')`——**audio 任务 fileExtension 恒 .mp3，而 _run 实际写的是服务端 extName（.flac 等）**。audio 下载失败/暂停后删除任务时，磁盘上的 `.flac` 临时文件永远删不掉
- 违反：QUALITY_STANDARD 第 23 条（键维度一致）+ 第 25 条（资源必须有上限——临时目录无清理机制）
- 后果：无损音质任务每次失败/取消/删除都残留一个数 MB 的 .flac/.tmp 临时文件，临时目录无限增长耗尽磁盘；remove 注释自称「D-01 配套：文件名规则与 _run 的 tempPath（dimKey）保持一致」，但扩展名分支被遗漏。

### download_provider.dart:268-273 remove() 删除条件：`raw = hash_type_quality_albumAudioId` 中 quality/albumAudioId 为 null 时拼 "null" 字符串——与 _run 的 dimKey 计算需逐字段核对
- 级别：P2
- 事实：dimKey 与 remove 的 raw 均为 `'${task.hash}_${task.type.name}_${task.quality ?? ''}_${task.albumAudioId ?? ''}'`——两处**独立重复实现**同一键规则（第 5 条单一来源违反），任一处将来改字段即静默失配，删除路径永远删不到文件
- 违反：QUALITY_STANDARD 第 5 条（同一事实两处维护）
- 后果：当前一致（无即时缺陷），但属结构性地雷；结合上条扩展名问题，删除路径对 audio 实际已失配。

### download_provider.dart:全文无断点续传：downloadFile 无 Range/断点参数，pause 后 resume 从 0 重新下载
- 级别：P2
- 事实：pause→resume 走 `resume(id)` → 重新排队 → `_run` 从头 `received: 0, total: 0` 重新 downloadFile；临时文件不删除也不复用
- 违反：QUALITY_STANDARD 第 25 条（大文件传输无断点机制，流量/时间浪费无上限）；注释亦未声明不支持
- 后果：MV（数百 MB）下载到 90% 后暂停/切后台（进程被杀）再续，从头下载；用户流量与时间成倍消耗，弱网环境大文件几乎不可能完成。

### download_provider.dart:378-385 publish 成功后 size 读取用 `File(realTempPath)`——但 MediaStore publish 成功后临时文件仍在（DL-05 已删）；时序：先 delete 再取 size？实际代码：先取 size？——核实：`final size = await File(realTempPath).exists() ? ... : 0;` 在 delete **之前**，正确。改报：DL-05 删除临时文件失败时静默吞掉
- 级别：P3
- 事实：`try { final f = File(realTempPath); if (f.existsSync()) f.deleteSync(); } catch (_) {}`
- 违反：QUALITY_STANDARD 第 9 条（失败不留痕）
- 后果：结合 P1 临时文件失配条目，临时目录增长无从察觉。

### download_provider.dart:230-241 add() 对 exists 且 running 的任务 cancel 后**立即覆盖状态为 queued**，但旧 _run 的 finally 可能晚于新 _run 启动——槽位判定 `tokenChanged = _tokens[task.id] != null && _tokens[task.id] != token` 依赖新 _run 已把 token 放入 _tokens
- 级别：P2
- 事实：新任务 add → _schedule → _run（异步）尚未执行到 `_tokens[task.id] = token` 时，旧 _run 的 finally 先到：`_tokens[task.id]` 为 null → tokenChanged=false → `_running.remove(task.id)`；随后新 _run 启动再 add 自己的槽——顺序 OK。但若**新 _run 先放 token，旧 finally 后到**：tokenChanged=true，不动槽——正确。真正的窗口：旧 finally 与新 _schedule 之间 `_running` 中仍含该 id（旧未 remove），`_schedule` 的 `!_running.contains(t.id)` 判定跳过新任务，而新任务 queued 状态无人启动，直到下一次任意 _schedule 触发
- 违反：QUALITY_STANDARD 第 19/22 条（闸门与并发假设）
- 后果：极小概率「重新下载同一首歌」后任务卡在「排队中」不动，需再触发任意下载事件才恢复（调度竞态窗口）。

### public_media_store.dart:96-127 publish MediaStore 失败回退 _publishDirect——跨设备 rename 边界（D-02）
- 级别：P1
- 事实：`await partFile.rename(target.path);`——`.part` 写在 `service.publicDir()`（公共存储）与 target 同目录，rename 同一文件系统成立。但 **fallbackDir 分支**：若 publish 开始时 publicBase 非空（part 写在公共目录）不存在跨设备问题；真正跨设备风险在 tempFilePath（App 私有）→ partFile（公共）之间是**流拷贝**，不是 rename——正确。重新核实：rename 是 part→target 同目录，无跨设备。改报：**写流失败回退 _publishDirect 二次失败时，MediaStore 已插入的 pending 条目已被 delete，但 fallback 目录可能已写入半份旧 target**——不成立。最终改报 MimeType：audio 恒标 audio/mpeg
- 级别：P2
- 事实：`mimeOf(type): audio => 'audio/mpeg'`——无损 flac/Hi-Res 下载后 MediaStore 记录的 MIME 是 audio/mpeg，扩展名却是 .flac；部分播放器/文件管理器按 MIME 分拣，flac 文件归类错乱
- 违反：QUALITY_STANDARD 第 28 条（MIME 与真实内容一致性）
- 后果：无损歌曲在系统媒体库里类型显示 mp3/被部分应用拒开（体验缺陷）。

### public_media_store.dart:237-247 delete() 对 MediaStore uri 删除失败（无权限/条目已失效）返回 false 且吞异常
- 级别：P2
- 事实：`catch (_) {} return false;` 调用方 remove() 不检查返回值
- 违反：QUALITY_STANDARD 第 9 条
- 后果：删除任务后文件实际残留在「Tiernan Music」目录，用户以为已删，磁盘空间泄漏且文件管理器可见（隐私面：以为删掉的音频仍在公共目录）。

---
### mv_collection_repository.dart:124-140 setCollected 成功判定：解密成功即返回 true，不解密体里的业务错误码
- 级别：P1
- 事实：
```dart
final decrypted = KgCrypto.aesDecryptPlaylistB64(base64Encode(bytes), aes.key);
// 丢弃解密结果但至少校验存在
return decrypted != null;
```
Node mv_collect.js 把 `playlistAesDecrypt(...)` 的 body 交给调用方判 status/errcode；酷狗该响应体形如 `{status:..., error_code:..., ...}`——解密成功 ≠ 业务成功（重复收藏、风控拒绝、token 失效都会返回可解密的错误 JSON）
- 违反：QUALITY_STANDARD 第 29 条（成功判定口径需按响应体实测；解密体内容被丢弃无法区分成功/失败）
- 后果：MV 收藏失败（风控/登录失效）时 UI 显示「已收藏」，实际服务端未生效——收藏态失真，用户以为收藏成功后歌找不到。

### mv_collection_repository.dart:117-122 与 Node 对照缺 KG-THash 头，且 dfid 空时下发空串而非 '-'
- 级别：P2
- 事实：Node `headers: {'KG-THash': Math.floor(Math.random()*0xfffffff), 'User-Agent':..., 'Content-Type':'json'}`；Dart headers 无 KG-THash；`'dfid': api.device.dfid` 而 Node `dfid = params?.dfid || '-'`
- 违反：QUALITY_STANDARD 第 28 条（请求头集合需逐一实测；两处差异未标注实测依据）
- 后果：KG-THash 缺失/dfid 空串可能被服务端风控拒绝 → 收藏/取消收藏在未注册 dfid 的设备上恒失败（失败还被上一条误报为成功，双重掩盖）。

### mv_collection_repository.dart:74-79 fetchCollected 用 KgClient.request 直连 collectservice——userid/token 为空（未登录）时请求照发，服务端返回错误形态由 fromJson 吞成空列表
- 级别：P3
- 事实：fetchCollected 未像 setCollected 一样做 `userid.isEmpty` 守卫；未登录时返回空列表，与「已登录但无收藏」不可区分（第 16 条）
- 违反：QUALITY_STANDARD 第 16 条
- 后果：「我的收藏 MV」页在未登录时静默空白而非引导登录。

### mv_repository.dart:104-112 resolvePlayUrl 的 `d.values.first` 兜底可能取到非目标 hash 的条目
- 级别：P3
- 事实：`d[hash.toLowerCase()] ?? d[hash.toUpperCase()] ?? (d.isEmpty ? null : d.values.first)`——/video/url 的 data 按请求 hash 为键；键大小写不匹配时取「任意第一个条目」，若多 hash 返回可能错配画质
- 违反：QUALITY_STANDARD 第 14 条
- 后果：低概率播放错画质的 MV（P3）。

### mv_repository.dart:300-311 MvDetail.fromJson 的 `${key}_hash_265` 循环覆盖判定：put 只在 `!hashes.containsKey(key)` 时写入，但该循环在顶层平铺之后运行，`data['${key}_hash']` 与前面 put 相同字段重复（无害）；真正问题：265 hash 永远进不了表（顶层已有同名键时）
- 级别：P3
- 事实：`final v = data['${key}_hash_265'] ?? data['${key}_hash'];`——h265 设备优先级未体现，bestHash 恒取 h264 hash；对 h265-only 视频_hashes 表可能为空 → bestHash null → 「MV 暂无播放地址」
- 违反：QUALITY_STANDARD 第 14 条（265 专属键形态未实测）
- 后果：仅 h265 编码的 MV 无法播放（取决于上游是否总下发 h264，列待实测）。

### mv_repository.dart:147-153 MvInfo.bestHash 序位 sqHash → qhd → hd → sd，但 sq_hash 注释自述「实测不存在」——死代码字段
- 级别：P3
- 事实：`sqHash: pick('sq_hash')` 且注释「sq（Super Quality）实测不存在」
- 违反：QUALITY_STANDARD 第 32 条
- 后果：无（整洁度）。

---

---

## 问题清单（v3.4 审查①）

| # | 位置 | 级别 | 标题 |
|---|---|---|---|
| 1 | audio_handler.dart:131 | P2 | completed 无条件跳下一首，与试听交互未区分 |
| 2 | audio_handler.dart:372 | P3 | 离线回退分支 20028 被当普通失败跳歌 |
| 3 | audio_handler.dart:365 | P3 | existsSync 同步 IO 在切歌路径 |
| 4 | audio_handler.dart:575 | P3 | onNotificationDeleted 与 stop() 不对称 |
| 5 | player_repository.dart:93 | P2 | ensureDfid 等待者重入逻辑放大注册延迟 |
| 6 | player_repository.dart:144 | P1 | fetchDetail hash 未命中取 entries.first → 错歌详情污染 |
| 7 | player_repository.dart:193 | P1 | 直连非 ApiException 网络异常不回退 kapi |
| 8 | player_repository.dart:210 | P3 | _directPlay! 跨异步窗口断言 |
| 9 | player_repository.dart:299 | P2 | kapi isPreview 判定口径未实测 |
| 10 | player_repository.dart:357 | P2 | _songFailureMessage 把外层 data 传给 canPlay |
| 11 | models.dart:150 | P3 | 歌名含 " - " 且歌手空时盲剥前缀 |
| 12 | models.dart:197 | P3 | quality 字段非字符串时落 q128 |
| 13 | play_helper.dart:17 | P3 | hash 缺失用 id 充当 hash（待实测） |
| 14 | krc_parser.dart:118 | P2 | KRC 原生翻译第二来源缺失 / language 行数对齐脆弱 |
| 15 | krc_parser.dart:60 | P2 | offset 正负语义未实测留样 |
| 16 | krc_parser.dart:126 | P3 | 头部提示文本在正文非空时丢弃 |
| 17 | krc_parser.dart:266 | P3 | 翻译降级返回 Base64 密文可当译文 |
| 18 | krc_decoder.dart:78 | P2 | 长度前缀重试只覆盖一种 key 相位假设 |
| 19 | krc_decoder.dart:98 | P3 | decode() 兼容入口疑似死代码 |
| 20 | lyric_repository.dart:60 | P2 | findCandidate 不用 duration 校验候选 → 词不对曲 |
| 21 | lyric_repository.dart:174 | P1 | translateLines 返回形态未实测，合并返回时译文全丢 |
| 22 | lyric_repository.dart:23 | P3 | accesskey 入键致缓存命中率归零 |
| 23 | search_repository.dart:174 | P2 | MV 封面 http+{size} 依赖下游处理（待实测） |
| 24 | search_repository.dart:290 | P2 | addHistory clear+addAll 非原子，崩溃即整箱丢失 |
| 25 | search_repository.dart:226 | P2 | 热搜/建议 catch(_) 吞异常无留痕、语义不分 |
| 26 | playlist_repository.dart:397 | P2 | _inFlight 防重随 Provider 重建归零 |
| 27 | playlist_repository.dart:135 | P2 | fetchTracks(allPages) 单页失败丢弃全部已取数据 |
| 28 | playlist_repository.dart:539 | P2 | isMine 判定 list_create_type 语义未留样 |
| 29 | playlist_repository.dart:292 | P3 | dedupeKey 复制整包数据 |
| 30 | comment_repository.dart:88 | P1 | 零评论歌曲 childrenid 空 → 发不出第一条评论 |
| 31 | comment_repository.dart:175 | P3 | isMine userid 字符串形态跨层比对 |
| 32 | comment_repository.dart:62 | P2 | fetchCount 按 kapi 形态取值，直连包装下恒 0（待实测） |
| 33 | kg_direct_api_client.dart:250 | P3 | comment send 三件套 get/post 双分派，get 侧成死代码 |
| 34 | download_provider.dart:292 | P1 | remove 临时文件扩展名恒 .mp3，非 mp3 残留泄漏 |
| 35 | download_provider.dart:268 | P2 | dimKey 键规则两处重复实现（第 5 条） |
| 36 | download_provider.dart:全文 | P2 | 无断点续传，暂停/被杀后从头下载 |
| 37 | download_provider.dart:378 | P3 | 临时文件删除失败静默 |
| 38 | download_provider.dart:230 | P2 | 重新下载同任务的调度竞态窗口 |
| 39 | public_media_store.dart:66 | P2 | audio MIME 恒 audio/mpeg，flac 类型错标 |
| 40 | public_media_store.dart:237 | P2 | delete 失败吞掉，以为删除实际残留 |
| 41 | mv_collection_repository.dart:124 | P1 | 解密成功即算收藏成功，业务错误码被丢弃 |
| 42 | mv_collection_repository.dart:117 | P2 | 缺 KG-THash、dfid 空不落 '-'，与 Node 不一致 |
| 43 | mv_collection_repository.dart:74 | P3 | fetchCollected 无登录守卫，未登录与空收藏不可分 |
| 44 | mv_repository.dart:104 | P3 | /video/url 键不匹配时取任意条目 |
| 45 | mv_repository.dart:300 | P3 | h265-only 视频 hash 表可能为空（待实测） |
| 46 | mv_repository.dart:147 | P3 | sq_hash 实测不存在仍保留（死代码） |

## 统计

| 级别 | 数量 |
|---|---|
| P0 | 0 |
| P1 | 6 |
| P2 | 21 |
| P3 | 19 |
| 合计 | 46 |

## 待实测项汇总（native_probe 直打原生域方可定案）
1. #13 首页推荐是否恒下发 FileHash
2. #23 imge.kugou.com http/{size} 在 HomeSong 渲染链路的实际形态
3. #28 list_create_type 「0=自建」语义三态留样
4. #30 childrenid='' 时 commentsv3/add 的真实服务端返回
5. #32 /index.php comments/getcommentsnum 原生返回 body 层级
6. #41 collectservice /v1/collect 解密体的 status/err_code 字段实测
7. #45 h265-only MV 是否真实存在

## 审查结论（5 行内）
- 全部 14 个范围文件逐行完整读毕；P1 共 6 条，最重为下载临时文件扩展名失配（磁盘泄漏）、MV 收藏「解密即成功」、fetchDetail 错歌污染、直连网络异常不回退、零评论发不出评论、翻译返回形态失配。
- dfid 前置修复本身闭环（ensureDfid + 回写 kgClientProvider），但直连→kapi 回退只拦 ApiException，DioException 直穿，属修复不完整。
- D-01 维度键方向正确但 remove() 与 _run() 两处独立实现且扩展名分支失配；D-02 原子发布（.part→rename 同目录）无跨设备问题，边界成立。
- MV cancel_collect 双 UA/二进制 body 对齐 Node 正确，唯成功判定丢弃解密体业务码（P1）。
- 评论 post 分派补齐生效（write:true 不回退），遗留 get 分派死代码与 childrenid 必填缺口。
