# 第4批·审查②-续 功能审查（歌词 / 搜索 / 歌单 / 评论 / 首页 / MV）

- 基线：`6e46611`
- 范围：`lib/features/lyric`、`search`、`playlist`、`comment`、`home`、`mv` 的 data 层与歌词视图
- 口径：见 `docs/REVIEW_SPEC.md`（接口必须走酷狗原生域名，kapi 仅兜底）
- 说明：本轮不覆盖播放链路（见 `docs/batch4_review_2_function.md`）

## 逐文件审查

### lib/features/lyric/data/krc_parser.dart:117-140 LRC 同行多时间戳被当成正文
- 级别：P1
- 依据：`_lrcLineRe` 为 `^\[(\d+):(\d+(?:\.\d+)?)\](.*)$`，对 `[00:12.00][00:45.00]歌词` 只匹配第一个时间戳，`group(3)` 得到 `[00:45.00]歌词`；随后该行被加入 `lines`，`text` 里残留第二个时间戳，且第二个时间点永远不会生成独立歌词行。
- 影响：LRC 格式（尤其双语对照、副歌复用行）会把方括号时间戳直接显示在歌词里，且该句在后半段时间不再高亮/滚动，用户看到错位歌词。

### lib/features/lyric/data/krc_parser.dart:78-79,150-152 offset 元数据只保存不生效
- 级别：P2
- 依据：`case 'offset': offset = int.tryParse(value) ?? 0;`，最终仅放入 `KrcLyric.offsetMs`；`startMs`、`KrcWord.startMs` 均未叠加 offset，解析后也没有统一平移。
- 影响：带 offset 的歌词整体提前/延后，逐字高亮与音频不同步；若上层也没有消费 `offsetMs`（本仓库内未见），该字段实际是死数据。

### lib/features/lyric/data/krc_parser.dart:143-148 翻译按行下标硬对齐
- 级别：P2
- 依据：`for (var i = 0; i < lines.length && i < embeddedTranslations.length; i++) { lines[i].translation = ... }`；而 `lines` 可能包含 LRC 行、被 `removeLast` 合并的行；`_decodeLanguage` 在 `languageList` 有多个条目（多语种/多段）时会把各段 `lyricContent` 顺序拼接成一个扁平数组。
- 影响：一旦行结构与翻译数组长度/顺序不一致（多语种、首行无时间被丢弃、合并行），译文整体错行，显示为“上一句的翻译配下一句歌词”。

### lib/features/lyric/data/krc_parser.dart:121-126 LRC 行 duration 固定为 0
- 级别：P2
- 依据：`durationMs: 0`，`KrcLine.endMs => startMs + durationMs` 退化为 `startMs`。
- 影响：任何按 `endMs` 计算高亮区间/滚动目标（含对下一行 `startMs` 的兜底缺失）的逻辑会得到零长度区间，LRC（非逐字）歌词可能整首不高亮或高亮跳变。

### lib/features/lyric/data/krc_parser.dart:130-139 无时间行合并保留旧 words
- 级别：P2
- 依据：合并时 `words: last.words`，但 `text` 变为 `'${last.text}$line'`（且无分隔符）。
- 影响：`words` 拼接文本与 `text` 不一致，逐字高亮的下标/长度对不上，出现高亮偏移或尾字缺失；纯文本渲染则两行粘连成一句。

### lib/features/lyric/data/krc_parser.dart:56-153 解析后未排序、未校验单调递增
- 级别：P2
- 依据：`lines` 按文件出现顺序 `add`，`parse` 返回前无 `sort`；后续视图依赖有序数组做二分查找（见 lyric_view）。
- 影响：KRC 若存在乱序行（或 offset 平移后跨界），二分查找会漏行/跳行，表现为歌词不跟唱或瞬间跳到末尾。

### lib/features/lyric/data/krc_parser.dart:62-65 首行无时间标签时静默丢弃
- 级别：P2
- 依据：无时间标签且 `lines.isEmpty` 时，`if (lines.isNotEmpty)` 不成立，直接进入下一轮循环，内容不进入任何 `KrcLine`。
- 影响：文件头部的无时间提示文本（版权、译者注）消失；若整份歌词无时间标签则返回空 `lines`，用户看到“无歌词”而非原文。

### lib/features/lyric/data/krc_decoder.dart:22-52 解密失败与“非 KRC（明文 LRC）”不可区分
- 级别：P2
- 依据：`decode` 对「空 / 非法 Base64 / 非 krc1 头 / 解压失败」四种情况统一 `return ''`，无状态码、无异常。
- 影响：调用方无法判断是「密文损坏」还是「本来就是明文歌词」，密文损坏时被当成“无歌词”静默吞掉，界面只剩空白，问题不可观测。

### lib/features/lyric/data/krc_decoder.dart:36-37 仅跳过 4 字节头，未处理头后长度字段
- 级别：P2
- 依据：`final body = bytes.sublist(4);`，注释称“跳过 4 字节 'krc1' 头”，未读取随后可能存在的 4 字节长度前缀；XOR 与 zlib 直接作用在剩余全部字节上。
- 影响：若服务端返回的头结构为 `krc1 + 4 字节长度 + 数据`，XOR 相位仍正确但 zlib 流前多 4 字节，解压失败 → 返回空串 → 全曲无歌词且无提示。

### lib/features/lyric/data/lyric_repository.dart:30 歌词搜索直连必然落 kapi（直连实现不带 signature、且改用无版本 `/search`）
- 级别：P1
- 依据：本方法 `_api.get('/search/lyric', query: query)` 在 `KgDirectApiClient.get` 中分派到 `KgEndpointSearch.searchLyric`，其实现为 `kg.request('/search', baseUrl: 'https://lyrics.kugou.com', clearDefaultParams: true, notSignature: true, ...)`；既未走规范要求的 `/v1/search`，也没有 `signature`。`KgClient.request` 只有在 `notSignature == false` 时才计算 `allParams['signature']`，此处被显式关闭，请求落地为无签名请求。
- 影响：违反「歌词 `/v1/search` 必须带 signature」口径；直连返回空体/风控错误时由 `_directOrFallback` 静默切到 kapi，用户侧“能出歌词”但整条链路实际依赖 kapi 中转，网络诊断里只能看到 `lastErrors` 的直连失败记录。

### lib/features/lyric/data/lyric_repository.dart:37-39 候选字段缺失被字符串化成 "null"
- 级别：P1
- 依据：`id: '${c['id']}'`、`accessKey: '${c['accesskey']}'`——字段为 null 时得到字面量 `"null"`，随后 `fetchLyric` 以 `id=null&accesskey=null` 请求 `/lyric`。
- 影响：`candidates` 中少量残缺条目（或字段名与真实响应不一致，如 `accessKey` 大小写）会生成非法请求，最终表现为“该首歌永远没有歌词”，且缓存把失败前的候选对象当成功返回，重试也无用。

### lib/features/lyric/data/lyric_repository.dart:35 `as Map<String, dynamic>` 强转无保护
- 级别：P2
- 依据：`final c = candidates.first as Map<String, dynamic>;`；`data['candidates'] as List?` 在字段类型异常时同样直接抛 `TypeError`。
- 影响：上游返回结构变动或 kapi/直连结构差异（如 candidates 为对象/元素为 `Map<dynamic,dynamic>`）时抛类型错误；`_directOrFallback` 对 `TypeError` 明确 `rethrow` 不回退，播放页歌词加载直接异常中断。

### lib/features/lyric/data/lyric_repository.dart:29-31 缓存按值引用返回同一可变 Map
- 级别：P2
- 依据：`MemoryCache.instance.get<Map<String, dynamic>>(cacheKey)` 返回缓存内的同一实例；`set` 存的是 `data` 本身（非深拷贝），TTL 仅 `AppConfig.memoryCacheSeconds = 90` 秒。
- 影响：任何调用方对返回 Map 的就地修改会污染其他调用方/其他页面；且 90 秒后同一首歌歌词会重复走网络（含可能的 kapi 回退），离线/弱网时表现为歌词“时有时无”。

### lib/features/lyric/data/lyric_repository.dart:64-73 `contenttype` 字符串比较导致 KRC 被误当明文解
- 级别：P2
- 依据：直连 `lyric()` 中 `if (fmt == 'lrc' || contenttype != 0)` 决定是否写入 `decodeContent`；当 `contenttype` 为字符串 `"0"` 时 `'0' != 0` 成立，KRC 密文会被 `base64.decode` 后写进 `decodeContent`。本方法优先取 `decodeContent`，不再走 `KrcDecoder.decode`。
- 影响：一旦字段类型为字符串，KRC 密文被当明文返回，解析出乱码/空行，用户看到空白或乱码歌词，且因 `decodeContent` 非空不会触发任何降级。

### lib/features/lyric/data/lyric_repository.dart:80-100 KRC 解不出时不尝试 LRC
- 级别：P2
- 依据：`fetchLyric` 只有单一 `format`（默认 `krc`），`KrcDecoder.decode` 返回空串即 `return null`；全仓库无“krc 失败改取 lrc”的二次请求。
- 影响：KRC 解密/解析失败（老歌、版权方只给 LRC、字段变更）时整首无歌词，而同一 `id/accesskey` 的 `fmt=lrc` 本可出词；用户侧只能看到“暂无歌词”。

### lib/features/lyric/data/lyric_repository.dart:89-91 部分内嵌翻译即整体跳过翻译
- 级别：P2
- 依据：`final hasEmbedded = lyric.lines.any((l) => l.translation != null); if (hasEmbedded) return lyric;`
- 影响：只要有一行带翻译（哪怕只有副歌或只有一行），其余行永远不翻译，界面出现“零星几句译文 + 大量原文”的半成品状态。

### lib/features/lyric/data/lyric_repository.dart:128-133 翻译缺失行被写成原文
- 级别：P1
- 依据：`lyric.lines[i].translation = failed.contains(i) ? null : (translations[i] ?? lyric.lines[i].text);`——批次成功但返回条数少于请求行数时，缺的行用 `text` 填充；另外失败批次同时把 `failed` 行写 null。
- 影响：译文区会出现与原文完全相同的整行（用户看到上下两行一模一样），且被当作“已翻译”持久化进 `LyricTranslationCache`（`translations` 非空即 `set`），之后即使翻译服务恢复也不会重试这些行。

### lib/features/lyric/data/lyric_repository.dart:135-139 翻译结果按行号持久化，无歌词版本校验
- 级别：P2
- 依据：`LyricTranslationCache.instance.set(lyricId, targetLanguage, translations)`，key 只有 `lyricId:targetLang`，`Map<int,String>` 以行下标为键。
- 影响：同一 `lyricId` 歌词内容/行数更新（官方改词、KRC 版本变化）后仍命中旧缓存，译文整体错行；用户看到“张冠李戴”的翻译且无法自愈（只能清缓存）。

### lib/features/lyric/data/lyric_repository.dart:115-120 翻译请求发往第三方且不区分登录态
- 级别：P2
- 依据：`_translate.translateLines(lines: batch, targetLanguage: targetLanguage)` 的端点为 `AppConfig.translateApiBase = https://index-translate.bilibili.com/v1/chat/completions`，无鉴权、无用户开关判断。
- 影响：整首歌词明文外发第三方服务；离线或该服务不可用时每批都失败并静默置 null，用户看到“翻译功能坏了”而无任何提示。

### lib/features/lyric/presentation/lyric_view.dart:107-131 当前行号在 build 中赋值 + postFrame 里 setState
- 级别：P2
- 依据：`if (index != _currentIndex) { _currentIndex = index; WidgetsBinding.instance.addPostFrameCallback((_) { setState(() {}); ... }); }`——在 build 期间直接改状态字段，并靠逐帧回调触发重建。
- 影响：快速拖动进度条时一次 build 只排入一个回调、多次 seek 叠加多个 `setState`，出现“跳帧/迟滞”；且状态在 build 中被改写，属易失步写法，后续任何重建顺序变化都会导致高亮行不刷新。

### lib/features/lyric/presentation/lyric_view.dart:90-99 滚动定位用固定行高常量、忽略垂直 padding
- 级别：P1
- 依据：`final target = (index * _itemExtentApprox).clamp(0.0, _scroll.position.maxScrollExtent);`，`_itemExtentApprox = 64.0`；而 ListView 的 `padding: EdgeInsets.symmetric(horizontal: 24, vertical: 120)`，且每行高度随「原文 + 可选译文」在 ~40~90px 之间浮动（双语模式恒多一行）。
- 影响：目标位置与真实行位置偏差随行号线性累积，越到后面越偏；双语模式下每行都超估/低估，表现为唱到后半段时当前行跑到屏幕外或不在可视区，自动跟随等于失效。

### lib/features/lyric/presentation/lyric_view.dart:118-128 无歌词时无空态
- 级别：P2
- 依据：`itemCount: widget.lyric.lines.length`，`lines` 为空时直接渲染 0 项的 ListView，无 `EmptyState`/提示文案。
- 影响：纯音乐、解密失败、歌词接口降级失败时，歌词区是一片空白（含 120px padding 的空白），用户无法区分“没歌词”和“加载中/出错”。

### lib/features/lyric/presentation/lyric_view.dart:73 `_posMs` 对 offset 取正号，与 LRC 惯例相反
- 级别：P2
- 依据：`int get _posMs => widget.position.inMilliseconds + widget.lyric.offsetMs;`
- 影响：LRC/KRC 的 `offset` 正值语义是“歌词提前显示”（应为 `position - offset`），此处取加号导致方向相反，带 offset 的歌词被推得更晚，出现整首人声先于高亮的错位；同时叠加 `krc_parser` 不生效/只存不用的现状，行为不可预期。

### lib/features/lyric/presentation/lyric_view.dart:151-166 二分查找假定有序，但解析器不排序
- 级别：P1
- 依据：`while (lo <= hi) { ... if (lines[mid].startMs <= posMs) ... }` 完全依赖 `lines` 按 `startMs` 升序；`KrcParser.parse` 仅按文件顺序 `add`，`KrcLyric.lines` 无排序、无断言。
- 影响：行序异常（含 offset 平移后跨界、KRC 尾部附加的 LRC 行）时二分命中错误行，歌词整段错位/跳段，且现象随机、难以复现。

### lib/features/lyric/presentation/lyric_view.dart:181-192 words 非空时丢弃解析器保留的尾部文本
- 级别：P2
- 依据：`_buildOriginal` 在 `line.words.isEmpty` 时渲染 `line.text`，否则只遍历 `line.words` 生成 spans；`KrcParser` 特意把“无时间标签的尾部”拼进了 `line.text`（见 krc_parser.dart:102-107），但这里从未渲染 `line.text`。
- 影响：逐字行尾部的非标签文本（如行末标点、合唱标记 `(合)`、异常 `]`）在逐字模式下永久丢失，歌词显示被截断。

### lib/features/lyric/presentation/lyric_view.dart:58-60 didUpdateWidget 用引用相等判断歌词变化
- 级别：P2
- 依据：`if (oldWidget.lyric != widget.lyric) { _currentIndex = _findCurrentLine(_posMs); }`
- 影响：`LyricRepository.ensureTranslation` 是**就地**给 `lyric.lines[i].translation` 赋值（同一 `KrcLyric` 实例），引用不变 → 不重算行号/不重建；翻译到达后界面可能仍停留在旧的估算位置，也可能整块不刷新，需等待下一次行号变化。

### lib/features/lyric/presentation/lyric_view.dart:120-127 每帧传入 posMs 使整表重建
- 级别：P2
- 依据：`_LyricLineTile(... posMs: posMs ...)`，`posMs` 每次 build 变化，`_LyricLineTile` 无 `const` 构造缓存，`ListView.builder` 中所有已构建项都会因 `posMs` 变化而重建（注释称“只让当前行变化”与实现不符）。
- 影响：长歌词滚动时每 tick 重建全部可视行 + 每行重建全部 `TextSpan`（逐字 span 数量随行长增长），低端机出现掉帧/发热。

### lib/features/lyric/presentation/lyric_view.dart:170-174 行首前的空白区间被算作第 0 行
- 级别：P2
- 依据：`var lo = 0, hi = lines.length - 1, result = 0;`——`posMs` 小于 `lines[0].startMs` 时返回 0，`isCurrent` 为 true。
- 影响：前奏段（常见 10~30 秒）第一句歌词一直高亮并加粗放大，用户以为已经开唱；切歌瞬间也会先闪一下首行。

### lib/features/search/data/search_repository.dart:252-257 搜索建议只走 kapi（无直连端点）
- 级别：P1
- 依据：`fetchSuggest` 调 `/search/suggest`，而 `KgDirectApiClient.get` 的 `switch (n)` 中没有任何 `search/suggest` 分支（只有 `search`、`search/hot`），未命中即 `return super.get(...)` → 直接打到 `AppConfig.kugouApiBase = https://kapi.344977.xyz`。
- 影响：搜索联想整体依赖 kapi 中转，属于「只能靠 kapi 跑通」的功能路径；直连层没有任何原生实现，kapi 不可用时输入框联想恒为空（且被 `catch` 吞成 `const []`，用户只看到“没有建议”）。

### lib/features/search/data/search_repository.dart:180-185,196-200 搜索无空关键词与空白关键词防护
- 级别：P2
- 依据：`searchSongs` / `searchPlaylists` / `searchByType` 均直接 `_cachedGet('/search', query: {'keywords': keywords, ...})`，没有 `keywords.trim().isEmpty` 早退（对比 `fetchSuggest` 有）。
- 影响：空串会打一次线上搜索（v3 空关键词返回热门/空列表），既浪费请求又可能把“热门推荐”误当成搜索结果展示；输入法连续触发时还会刷多次同样的请求。

### lib/features/search/data/search_repository.dart:68-76 所有搜索响应 90 秒缓存且无强制刷新参数
- 级别：P2
- 依据：`_cachedGet` 统一 `_cache.set(key, data)`，TTL 取 `AppConfig.memoryCacheSeconds = 90`；key 为 `path?page=..&pagesize=..&type=..&keywords=..`，无 `refresh`/`nocache` 入口。
- 影响：用户下拉刷新或改词后改回同一关键词，90 秒内拿到的都是旧结果；榜单类搜索（新歌上架）也会延迟，用户感知为“搜索结果不更新”。

### lib/features/search/data/search_repository.dart:100-107 `total<=0` 用 -1 当“未知”
- 级别：P2
- 依据：`if (total <= 0 && returned >= pageSize) return -1; return total;`
- 影响：`-1` 会原样流到 UI 的分页判定/“共 N 条”文案；界面若按 `items.length < total` 判 `hasMore`，`-1` 会让“是否还有更多”判断与真实情况相反（有更多时显示已到底，或反之），分页边界不可预期。

### lib/features/search/data/search_repository.dart:89-91 `_maps` 丢弃非 Map 元素且无告警
- 级别：P2
- 依据：`raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e))`——`Map<dynamic,dynamic>` 可以转，但元素为字符串/数组时被静默丢弃。
- 影响：接口结构变动（如 `lists` 变成字符串数组）时搜索结果整体为空，界面显示“无结果”，无任何日志可定位。

### lib/features/search/data/search_repository.dart:242-246 热搜解析 `e as Map` 强转
- 级别：P2
- 依据：`HotSearchBoard.fromJson(Map<String, dynamic>.from(e as Map))`；`e` 非 Map 时抛 `TypeError`，被外层 `catch (_) { return const []; }` 吞掉。
- 影响：热搜整块消失（首页/搜索页热搜区空白），且无错误提示；结合 `fetchHotSearch` 的全捕获，任何字段异常都表现为“热搜暂时没有”。

### lib/features/search/data/search_repository.dart:291-330 搜索历史非用户维度、写入非原子
- 级别：P2
- 依据：`historyBoxName = 'search_history'` 固定 box 名，无 userid 前缀；`addHistory` 为 `box.clear(); box.addAll(list);` 两步，`removeHistory` 同样先清后写。
- 影响：切换账号后 A 的搜索历史直接出现在 B 的搜索框（隐私/串号）；清空+重写在并发点击（连续搜索）时可能丢条目或残留旧列表。

### lib/features/search/data/search_repository.dart:296-300 `getHistory` 返回 Box 值快照，无序保证
- 级别：P2
- 依据：`box.values.toList()`，依赖 Hive 插入顺序；`addHistory` 用 `clear()+addAll()` 重建顺序。
- 影响：历史顺序在应用重启/并发写后可能错乱（最近搜索不在最前），用户点第一条却不是刚搜的词。

### lib/features/search/data/search_repository.dart:237-249 热搜失败静默为空、无重试
- 级别：P2
- 依据：`try { ... } catch (_) { return const []; }`，直连失败时 `_directOrFallback` 已回退 kapi，此处再把一切异常吞成空表。
- 影响：热搜区永远显示“暂无”，无法区分网络错误与确实无数据；用户没有重试入口。

### lib/features/playlist/data/playlist_repository.dart:109-115 收藏歌单走 GET + 可回退，存在重复提交
- 级别：P0
- 依据：`collectPlaylist` → `_api.get('/playlist/add', query: {...})`；直连路径 `KgDirectApiClient.get` → `_directOrFallback(() => _playlistAdd(q), kapi, '/playlist/add')`。`_directOrFallback` 的第二个 `catch (e)`（含超时、`status:0` 的 502 包装、JSON 解析失败）会**无条件**再打一次 kapi。
- 影响：直连请求已被服务端执行但响应超时/解析失败时，回退会再执行一次收藏，用户「我歌单」里出现两条同名歌单；且写操作没有任何幂等键，重复无法自愈。

### lib/features/playlist/data/playlist_repository.dart:119-120 取消收藏同样可回退重复执行
- 级别：P0
- 依据：`deletePlaylist(String listid) => _api.get('/playlist/del', query: {'listid': listid}).then((_) {})`；`KgEndpointPlaylist.playlistDel` 本身是 AES body + RSA `p` 的 POST，失败即回退 kapi。
- 影响：取消收藏重复提交；若第一次已删成功而回退请求失败，UI 会拿到失败提示但歌单已消失，用户重试时报“歌单不存在”。

### lib/features/playlist/data/playlist_repository.dart:123-136 加歌/删歌写操作同样可回退重复
- 级别：P0
- 依据：`addTracks` → `_api.get('/playlist/tracks/add', query: {'listid': listid, 'data': data})`；`removeTracks` → `_api.get('/playlist/tracks/del', query: {...})`。两者都经 `_directOrFallback`。
- 影响：批量加歌时超时回退 → 同一批歌被加两遍；批量删除回退后第二次拿到“文件不存在”错误，用户看到红色报错但操作实际已生效。

### lib/features/playlist/data/playlist_repository.dart:126-129 `|`/`,` 拼接曲目数据，歌名含分隔符必然错位
- 级别：P1
- 依据：`[t.name, t.hash, t.albumId ?? '', t.albumAudioId ?? ''].join('|')`，多首用 `,` 连接；直连层 `_parseTracksResource` 再做 `split(',')` + `e.split('|')`（kg_endpoints_playlist.dart:245-270）。
- 影响：歌名带逗号（如「Hello, World」）或竖线时字段整体右移，`hash` 变成歌名片段、`album_id` 变成非数字 0，加入歌单后出现错歌/无效条目；且无任何校验或转义。

### lib/features/playlist/data/playlist_repository.dart:126-130 大批量走 GET query，超长必失败
- 级别：P1
- 依据：`data` 拼串后作为 **query 参数** 传（`_api.get('/playlist/tracks/add', query: {'listid': ..., 'data': data})`）；直连层再把它当 body 发出，但 kapi 回退路径仍是 GET query。
- 影响：一次添加几十首（每首约 60~100 字符）即触发 URL 长度上限，返回 414/400；用户「全选加入歌单」在大歌单上必失败且错误信息不可读。

### lib/features/playlist/data/playlist_repository.dart:57-73 `newestFirst && allPages` 的排序结果自相矛盾
- 级别：P1
- 依据：`if (!newestFirst || !allPages) return firstTracks;` 之后 `for (var p = totalPages; p >= 2; p--) { older.insertAll(0, t.songs.reversed); }` 再 `[...firstTracks.songs, ...older]`。第 1 页保持上游原序（页内从新到旧，倒序），其余页被 `reversed` 成从旧到新后整段插到最前。
- 影响：最终顺序为「最旧页→较旧页…→第 1 页（新的在前）」，前后两段方向相反；用户看到歌单前半段按时间正序、最后一段倒序，滚动时明显“跳年份”。

### lib/features/playlist/data/playlist_repository.dart:61-62 分页总数用 `songs.length` 兜底，页数被低估
- 级别：P1
- 依据：`final totalPages = (firstTracks.total / pageSize).ceil();`，而 `PlaylistTracks.fromJson` 中 `final total = _toInt(data['count'] ?? data['total'], fallback: songs.length);`
- 影响：`count` 缺失（用户歌单 `/v4/get_list_all_file_v3` 常见无 count）时 `total` 退化为当前页条数（如 100），`totalPages` 恒为 1，`allPages=true` 实际只返回一页；调用方以为已取全量，歌单显示“只有 100 首”。

### lib/features/playlist/data/playlist_repository.dart:64-69 allPages 串行全量拉取，无上限无并发控制
- 级别：P2
- 依据：`for (var p = totalPages; p >= 2; p--) { ... await fetch(p); }`，`pageSize=100`，`total` 可达数千（收藏歌单）。
- 影响：打开一个 3000 首的歌单会串行发 30 次请求、耗时数十秒且无法取消；期间页面空白/卡在 loading，弱网下极易超时只拿到部分页，得到残缺列表。

### lib/features/playlist/data/playlist_repository.dart:20-26 / 34-40 详情与曲目缓存无写操作失效
- 级别：P2
- 依据：`fetchDetail`、`fetchTracks` 均 `MemoryCache.instance.set(...)`，而 `collectPlaylist`/`deletePlaylist`/`addTracks`/`removeTracks` 成功后**不清任何 key**（`MemoryCache` 虽有 `removeWhere`，此处未调用）。
- 影响：加歌/删歌/取消收藏后 90 秒内再次进入歌单页仍显示旧歌曲列表与旧的 `trackCount`，用户以为操作没生效而重复点击，进一步放大重复提交风险。

### lib/features/playlist/data/playlist_repository.dart:177-182 `data` 为空时直接抛业务异常
- 级别：P2
- 依据：`if (data.isEmpty) { throw ApiException(-1, '歌单不存在或 ID 无效（需要 collection_ 形式的全局 ID）'); }`
- 影响：自造错误码 `-1` 不在后端错误码表内，`friendly_error` 映射不到会显示原始文案；更关键的是「新建但尚未同步的空歌单」「私有歌单无权限」也会走到 `data.isEmpty`，被统一说成“ID 无效”，用户按提示改 ID 也无效。

### lib/features/playlist/data/playlist_repository.dart:163-194 详情取首项、无多 ID 处理
- 级别：P2
- 依据：`raw is List ? Map.from(raw.first as Map)`；`fetchDetail` 只传一个 id，`playlistDetail` 却支持 `ids.split(',')` 最多 10 项。
- 影响：接口支持批量但仓库只用单条，`raw` 为数组时静默只取第一项；若上游顺序变化（多 ID 时按非请求序返回），会显示别人的歌单信息（名称/封面/创建者错配）。

### lib/features/playlist/data/playlist_repository.dart:109-110 `collectPlaylist` 用 `listCreateUserid` 是否为空推断 type
- 级别：P2
- 依据：`'type': listCreateUserid != null ? 1 : 0`，同时 `if (listCreateGid != null) 'list_create_gid': listCreateGid`。
- 影响：收藏公共歌单缺 `list_create_gid` 时仍以 type=1 发送，直连层 `list_create_gid: ''`，服务端返回错误码；反过来「新建歌单」若误传 userid 会被当成收藏，用户以为新建成功实际收藏了一个空 gid 歌单。

### lib/features/playlist/data/playlist_repository.dart:80-91 我的歌单无登录态判断、无缓存、无分页
- 级别：P2
- 依据：`fetchUserPlaylists({page = 1, pageSize = 30})` 直接 `_api.get('/user/playlist', ...)`，未检查 `_api.userid` 是否为 `''/'0'`；返回值只有 `List<UserPlaylist>`，丢弃了分页信息。
- 影响：匿名态下请求照发，直连 `userPlaylist` 以 `userid=0` + 空 token 提交，返回空或错误码，用户看到空白“我的歌单”而非“请先登录”；歌单超过 30 个时无法翻页（调用方拿不到 total）。

### lib/features/playlist/data/playlist_repository.dart:95-100 用户歌单曲目固定 pageSize=300、无分页
- 级别：P2
- 依据：`fetchUserTracks(String listid, {int page = 1, int pageSize = 300})`，返回 `PlaylistTracks` 但调用方无 total 语义说明；直连 `userPlaylistTracks` 默认 pagesize 300。
- 影响：超过 300 首的自建歌单只显示前 300 首且无“加载更多”，末尾歌曲永久不可见。

### lib/features/playlist/data/playlist_repository.dart:278-286 时长单位混用无校验
- 级别：P2
- 依据：`json['timelen']`/`timelength` 按毫秒 `~/ 1000`，`duration`/`Duration` 按秒直接用；`PlaylistSong.duration` 注释写“秒”。
- 影响：若某接口把 `duration` 也返回毫秒（搜索/榜单混用场景），时长会显示成 1000 倍（如 04:29 变 74:52:00），进度条与总时长错乱。

### lib/features/playlist/data/playlist_repository.dart:264-276 「歌手 - 歌名」前缀剥离依赖空格分隔
- 级别：P2
- 依据：`final sep = rawName.indexOf(' - ');`，随后 `if (explicitSinger.isNotEmpty && prefix != explicitSinger) name = rawName;`
- 影响：歌名本身含 " - "（如「Live - Remastered」）且无 singerinfo 时，前半段被误当歌手、歌名被截断；反之歌手名与前缀写法不同（「周杰伦」vs「Jay Chou」）时整串保留，列表出现「周杰伦 - 稻香 - 周杰伦」。 

### lib/features/playlist/data/playlist_repository.dart:88-91 `whereType<Map>()` 静默丢弃异常项
- 级别：P2
- 依据：`list.whereType<Map>().map((e) => UserPlaylist.fromJson(Map<String,dynamic>.from(e)))`
- 影响：上游把某项返回为非对象（或 `data.info` 结构变化）时该歌单直接消失，用户少看到歌单且无任何提示/日志。

### lib/features/comment/data/comment_repository.dart:31 评论列表未校验 `err_code`（裸 Map 语义），业务失败被当成功
- 级别：P1
- 依据：`final data = await _api.get(path, query: query); return CommentPage.fromJson(data, ...)`——不看 `err_code == 0`。直连层 `_wrap` 对 `status == 1` 分支虽检查 `err_code`，但 kapi 拦截器（`KugouApiClient.onResponse`）只看 `status`/`error_code`/`errcode`，`err_code=60102` + `status=1` 会被放行。
- 影响：歌单/专辑评论用错端点或资源码时返回 `status=1, err_code=60102, list:[]`，仓库层判成功、`comments` 为空，界面恒显示“暂无评论”且不回退 kapi，用户永远看不到已有评论。

### lib/features/comment/data/comment_repository.dart:36-40 评论数字段名靠猜、读取失败静默为 0
- 级别：P2
- 依据：`final value = data[hash] ?? data[hash.toUpperCase()] ?? data[hash.toLowerCase()];`，未命中则 `0`；直连 `/comment/count` 的 `_commentCount` 只在 `q['hash']==null` 时才传 `childrenid`。
- 影响：返回体若为 `{data:{count:N}}` 或 `{hash:{"count":N}}`，这里取不到 → 一律显示“0 条评论”，用户以为无人评论（该数与详情页评论页实际数量不符）。

### lib/features/comment/data/comment_repository.dart:76-87 发评前多打一次评论列表请求，且失败仍继续发送
- 级别：P1
- 依据：`if (type == song) { try { final page = await fetchComments(..., pageSize: 1); ... } catch (_) {} }`——为拿 `specialChildId` 额外请求 `/comment/music`，异常被完全吞掉；`childrenId` 为 null 时 query 里不传 `special_id`。
- 影响：①每发一条评论多一次网络往返，弱网下发送延迟明显；②`childrenId` 缺失时直连 `commentSend` 的 `childrenid` 回退成 `q['id']`（即 mixsongid），而 Node 语义要求 `special_child_id`，服务端判为无效 → 评论发不出去，界面只报通用错误；③该次列表请求失败不阻断，错误被静默。

### lib/features/comment/data/comment_repository.dart:128-143 删除评论写操作可回退，且 cid 缺失无校验
- 级别：P1
- 依据：`_api.post('/comment/music/del', query: {...})` 经 `_directOrFallback`；`'cid': cid` 无空值校验，`specialId`/`mixsongid` 均为可选。
- 影响：超时或 JSON 解析失败时回退 kapi 再删一次，第二次返回“评论不存在”并把异常抛给 UI，用户看到删除失败但评论已消失；若只传 `cid` 不传 `special_id`，直连 `childrenid` 落到空串，服务端返回错误码，评论无法删除。

### lib/features/comment/data/comment_repository.dart:117-124 回复写操作同样可回退重复提交
- 级别：P1
- 依据：`_api.post('/comment/floor/send', {}, query: {...})` 经 `_directOrFallback`，无幂等键、无防重入标记。
- 影响：网络抖动时同一条回复被提交两次，楼层里出现重复内容；用户重复点击“发送”同样会产生重复（仓库层无 in-flight 保护）。

### lib/features/comment/data/comment_repository.dart:105 发评论 `post(path, {}, query:)` 把业务参数全塞 query
- 级别：P2
- 依据：`await _api.post(path, {}, query: query)`，body 恒为空 Map；直连 `commentSend` 才把 content 组装进 JSON body。
- 影响：kapi 回退路径的请求体为空、参数在 query 里，与直连层形态不一致；一旦回退，中文评论内容会走 URL 编码，长评论（数百字）易触发 414 或长度截断，用户看到“发送失败”或评论内容被截短。

### lib/features/comment/data/comment_repository.dart:155-170 总数取 `count` 优先，但分类/热词与总数来源不同层
- 级别：P2
- 依据：`final data = json['data'] is Map ? Map.from(json['data']) : json;` 之后 `data['count'] ?? data['total'] ?? data['comments_num'] ?? data['str_count']`；`fallback: comments.length`。
- 影响：`count` 缺失时总数退化为当前页条数（30），分页控件认为已到底，用户无法加载第 2 页之后；`str_count`（字符串如 "1.2万"）经 `int.tryParse` 得 0，被当作“0 条评论”。

### lib/features/comment/data/comment_repository.dart:161-165 `whereType<Map>()` 静默丢评论
- 级别：P2
- 依据：`list.whereType<Map>().map((e) => Comment.fromJson(...))`
- 影响：上游 `list` 中混有非对象项（广告位、占位符）时被丢弃，页面评论数少于接口声明；若 `list` 结构变化（如 `list` 变成 Map）则整页空白。

### lib/features/comment/data/comment_repository.dart:246-247 `isMine` 依赖 userid 字符串精确相等
- 级别：P2
- 依据：`'${json['userid'] ?? json['user_id'] ?? ''}' == (currentUserId ?? '')`，`currentUserId` 来自 `_api.userid`；而 `_api.userid` 在 `KgDirectApiClient` 中由 `kg.userid` 同步（`clearCredentials` 置 `'0'`）。
- 影响：未登录时 `userid` 为 `'0'`/`''`，任何 `userid=0` 的评论（匿名评论）会被标成“我的”，出现“删除”按钮但删除必失败；多端登录 userid 为数字/字符串混用时判定失效，本人评论没有删除入口。

### lib/features/comment/data/comment_repository.dart:235-240 点赞数/回复数读取无空值兜底
- 级别：P2
- 依据：`likeCount: _asInt(like is Map ? (like['count'] ?? like['likenum']) : (like ?? json['likecount']))`；`replyCount: _asInt(json['reply_num'] ?? json['replycount'])`。
- 影响：`like` 为 Map 但两个键都不存在时 `_asInt(null)` → 0（看似正常）；若 `like` 为字符串 `"12"` 则走 else 分支得 12，同一字段类型不稳定；`reply_num` 缺失时楼中楼回复数恒 0，用户看不到“还有 3 条回复”入口（配合 `replyCount==0` 的展示逻辑会隐藏展开）。

### lib/features/home/data/home_repository.dart:65 推荐歌单直连恒失败，实际依赖 kapi
- 级别：P1
- 依据：`_cachedGet('/top/playlist', query: {'category_id': ..., 'withsong': '1'})` → 直连 `KgEndpointHome.topPlaylist` 打 `gateway + x-router specialrec` 的 `/v2/special_recommend`，其注释自述「直连恒 ec=200101（匿名/VIP、多组参数均复现）」。`_wrap` 抛出后 `_directOrFallback` 回退 kapi。
- 影响：这是规范列出的「既知约束」，但实现上它使首页“推荐歌单”整块常态依赖 kapi 中转；kapi 不可达时该区块只能靠 `fetchYuekuPlaylists()` 兜底，而兜底内容是「乐库推荐」不是榜单歌单，标题与内容语义不一致。

### lib/features/home/data/home_repository.dart:62-77 失败回落到不同语义的数据源且无提示
- 级别：P2
- 依据：`catch (_) {}` 后 `return fetchYuekuPlaylists();`；而 `fetchNewSongs` 同样 `catch` 后 `return fetchYuekuSongs();`。
- 影响：“推荐歌单”/“新歌”在接口失败时静默变成乐库数据，用户看到的歌单分类与编辑推荐完全对不上；且无任何“数据可能不是最新”的提示，问题不可观测。

### lib/features/home/data/home_repository.dart:93-104 Banner 失败静默为空、且直连恒 31136
- 级别：P2
- 依据：`fetchBanners` 全捕获 `return const [];`；直连 `yuekuBanner` 注释明确「匿名态恒返回 error_code=31136」→ 回退 kapi 同样 31136。
- 影响：banner 区在匿名/未开通状态下永久空白（连占位也没有），首页顶部出现一块突兀的留白；用户无法判断是没运营位还是加载失败。

### lib/features/home/data/home_repository.dart:133 `fetchNewSongs` 无参数缓存 key 固定
- 级别：P2
- 依据：`_cachedGet('/top/song')` 不带任何 query；直连 `topSong` 的 `rank_id` 固定回退 `21608`，`page/pagesize` 也取默认。
- 影响：新歌只有“默认榜单”一份数据，无法按语种/分类切换；不同入口（首页新歌、更多新歌）共用同一 90 秒缓存与同一 `rank_id`，用户在不同分类页看到完全相同的新歌列表。

### lib/features/home/data/home_repository.dart:107-127 每日推荐把“未登录”和“网络失败”合并为 null
- 级别：P2
- 依据：`catch (_) { return null; }`，且 `if (raw.isEmpty) return null;`；调用方仅能通过 null 隐藏入口。
- 影响：登录用户遇到网络错误时，每日推荐入口直接消失（而非显示错误/重试），用户以为该功能被下线；反之未登录时也没有“登录后查看”的引导。

### lib/features/home/data/home_repository.dart:38-40,48-50 `json['data']?['info']` 无类型保护
- 级别：P2
- 依据：`final info = (json['data']?['info'] as Map?) ?? {};`——若 `data` 是 `List`，`['info']` 会在 List 上按字符串下标取值抛 `TypeError`；`as Map?` 对 `Map<dynamic,dynamic>` 也会抛。
- 影响：`/yueku` 结构变动时首页“新歌/推荐歌单”整体异常（`fetchHomeData` 里被 catch 成空列表），首页只剩榜单，且没有任何日志。

### lib/features/home/data/home_repository.dart:149-181 首页聚合超时不下沉、空数据判定漏掉每日推荐
- 级别：P2
- 依据：`fetchNewSongs().timeout(t)` 等 5 路并发，`t = 12s`；末判定 `if (songs.isEmpty && playlists.isEmpty && ranks.isEmpty && banners.isEmpty) throw`。
- 影响：①`.timeout` 不会取消底层请求，超时后请求仍会完成并写入 `MemoryCache`，下次进入首页可能读到“上一轮超时但已完成”的旧响应；②四个区块全空但 `dailyRecommend` 有数据时仍抛“加载失败”，用户看到整页错误而非仅部分区块为空。

### lib/features/home/data/home_repository.dart:179-181 全空即抛异常，无分区降级
- 级别：P2
- 依据：`throw Exception('首页数据加载失败，请检查网络后重试')`
- 影响：四个区块任一有数据就不报错，但榜单有数据、新歌/歌单全失败时页面看起来“正常”，用户不知道两个模块已经挂了；反之全空时整页替换为错误页，banner/每日推荐等本可单独展示的内容也一起消失。

### lib/features/home/data/home_repository.dart:28-36 首页缓存无登录维度、无手动失效
- 级别：P1
- 依据：`_cachedGet` 的 key 为 `path?query`，`/yueku`、`/rank/list`、`/top/playlist`、`/top/song` 均无 userid 参与；`fetchDailyRecommend` 特意绕开缓存，说明作者已知登录态相关，但其余接口未做区分。
- 影响：匿名态进入首页（缓存 90 秒）→ 立即登录 → 首页仍显示匿名态的推荐/榜单（`homeDataProvider` 重新拉取也命中同一 key），用户以为登录没生效；切换账号同理。

### lib/features/home/data/models.dart:62-64 `trans_param` 强转 `Map<String, dynamic>`
- 级别：P2
- 依据：`final transParam = json['trans_param'] is Map ? json['trans_param'] as Map<String, dynamic> : const <String, dynamic>{};`
- 影响：当 `trans_param` 是 `Map<dynamic,dynamic>`（Hive 反序列化、手工构造、kapi/直连结构差异）时 `as Map<String,dynamic>` 抛 `TypeError`；该异常在 `search_repository._maps` 之外无保护，`HomeSong.fromJson` 抛错会让整页列表构建失败（首页/搜索页空白）。

### lib/features/home/data/models.dart:105-119 时长单位靠字段名推断，无交叉校验
- 级别：P1
- 依据：优先 `duration` / `Duration` / `time_length` 当**秒**，否则 `timelength` / `timelen` / `timeLength` 当**毫秒** `~/ 1000`；一旦某接口把秒字段命名为 `timelength`（或反之），结果差 1000 倍。
- 影响：`/top/song`（timelength 毫秒）与 `/search`（Duration 秒）混用同一模型时，若上游改字段名或返回 `"269792"` 字符串被 `_toInt` 正确解析但单位判断错，列表显示 `74:52:32` 这类明显错误的时长；`durationText` 只在 `<=0` 时兜底，无法拦截超大值。

### lib/features/home/data/models.dart:120-131 `albumAudioId` 只认三个键，缺失即 null 且无降级
- 级别：P1
- 依据：`final albumAudioId = _toStr(json['album_audio_id'] ?? json['MixSongID'] ?? json['mixsongid'] ?? json['albumAudioId']);`，`hash` 缺失时 `id` 退化为 `mixsongid`/`audio_id`/`id`。
- 影响：v3 搜索/榜单部分条目只带加密 id（如 `EMixSongID`）或字段名变体时 `albumAudioId` 为 null，后续歌曲评论（`mixsongid`）、歌词（`album_audio_id`）、MV 关联全部拿不到参数——表现为这些歌“点进详情没有评论/没有歌词”，而列表本身正常，问题极难定位。

### lib/features/home/data/models.dart:95-100 FileName 拆分仅按 `-` 且无空格容错
- 级别：P2
- 依据：`final parts = fileName.split('-'); displayName = parts.sublist(1).join('-').trim();`
- 影响：文件名形如 `歌手-歌名` 时可用，但 `周杰伦 - 稻香` 会得到 `歌名` 前带空格的正确结果、而 `A-B-C` 场景会把多余段并入歌名；反过来 `歌手 - 歌名 - Live` 时 `displaySinger` 取到 `歌手 `（带空格未 trim 后用于对比）导致歌手名带尾空格，UI 与搜索匹配（按歌手名查歌）都可能失配。

### lib/features/home/data/models.dart:181-188 `globalCollectionId` 在缺失时回落为数字 id
- 级别：P1
- 依据：`globalCollectionId: globalId.isNotEmpty ? globalId : numericId`，而 `PlaylistDetail`/`playlistDetail` 明确「数字 listid 不被接受，只认 collection_ 形式」（kg_endpoints_playlist.dart:169-180，`data:{}` → 抛 `ApiException(-1, '歌单不存在或 ID 无效')`）。
- 影响：搜索结果 `type=special` 若只给 `gid` 之外的 `specialid`，`globalCollectionId` 变成纯数字，点击歌单直接进错误态；`HomeRank` 直接用 `rankid` 顶替 global 同理，排行榜卡片可能全部打不开。

### lib/features/home/data/models.dart:190-195 歌单封面字段白名单过窄
- 级别：P2
- 依据：`json['imgurl'] ?? json['img'] ?? json['flexible_cover'] ?? json['pic'] ?? json['cover']`
- 影响：榜单/推荐歌单常见 `sizable_cover`、`cover_url`、`banner` 等字段，未覆盖时封面为空串，卡片显示灰块（`kugouImageUrl` 对空串返回 `''`，无占位图逻辑在模型层）。

### lib/features/home/data/models.dart:229-230 榜单封面只取 `banner_9`
- 级别：P2
- 依据：`kugouImageUrl(_toStr(json['banner_9'] ?? json['imgurl'] ?? json['banner']))`
- 影响：缺少 `banner_9` 的榜单（新榜、地区榜）退到 `imgurl`/`banner`，两者皆无时封面空；且 `banner_9` 是竖版 9 图资源，用作方形卡片会被裁切。

### lib/features/home/data/models.dart:6-13 `kugouImageUrl` 强制 http→https，无失败兜底
- 级别：P2
- 依据：`if (u.startsWith('http://')) u = 'https://${u.substring(7)}';`
- 影响：部分酷狗老图床域名不支持 HTTPS（`imge.kugou.com` 以外的 CDN），强制升级后图片 404/握手失败，用户看到整片空白封面而无回退到原 http 地址。

### lib/features/home/data/models.dart:171-176 `playCountText` 只在 ≥10000 时缩写
- 级别：P2
- 依据：`if (playCount >= 10000) return '${(playCount / 10000).toStringAsFixed(1)}万'; return '$playCount';`
- 影响：`playCount` 为 0（字段缺失）时显示“0”，与真实“未知”无法区分；亿级播放量显示成“12345.7万”，与酷狗客户端的“1.2亿”不一致。

### lib/features/home/data/models.dart:255-271 `HomeData.dailyRecommend` 默认 `const []` 与“未登录为 null”语义冲突
- 级别：P2
- 依据：构造器 `this.dailyRecommend = const []`，而字段注释写明「未登录为 null，区分于空列表」，`fetchHomeData` 也确实传 null。
- 影响：任何用默认构造 `const HomeData()` 的场景（测试、骨架屏、错误占位）会得到空列表而非 null，UI 按 `!= null` 判断“已登录有推荐”时误判为已登录，出现“每日推荐 0 首”的空区块。
