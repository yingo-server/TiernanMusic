# 审查报告：播放与歌词模块（批1检2续）

- 范围：player（data/provider/helper/presentation）+ lyric（data/presentation）+ core/direct/kg_play_api.dart，共 13 个文件全部从头读毕；另交叉核对了 `kg_client.dart`（20028/ssaCode 处理）、`settings_providers.dart`（defaultQuality 写入）、`cache_manager.dart`（翻译缓存）、`docs/api_report_player.md`（字段对照）。
- 约束：纯读，未改任何文件，未运行 flutter/test。
- 基线 commit：`bcfd024`。

严重度排序：**功能失效 > 体验瑕疵 > 代码质量**（未发现编译阻塞）。

---

## 一、功能失效（P1）

### 1. 歌词从不自动滚动，不会跟随播放
- `lib/features/lyric/presentation/lyric_view.dart:37`（`final ScrollController _scroll`）与 `:92-97`（ListView）
- 问题：`_scroll` 只在 dispose 里出现，全文件没有任何 `animateTo` / `jumpTo`。当前行高亮会更新，但列表永远停在顶部，用户必须手动滑——对歌词视图来说是核心功能缺失。
- 修法（在 `_LyricViewState` 中加）：
```dart
  static const _itemExtentApprox = 64.0; // 行高近似值，或用 GlobalKey 测量

  void _scrollTo(int index, {bool jump = false}) {
    if (!_scroll.hasClients) return;
    final target = (index * _itemExtentApprox)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
  }
```
  在 build 检测到 `index != _currentIndex` 时（现有 postFrameCallback 内）调用 `_scrollTo(index)`；首次 build（initState 后第一帧）用 `jump: true`。更精确做法：给每行套 `GlobalKey` 或按 `mode` 计算行高，逐字 17px 标题 + 可选译文 ≈ 60~90px，建议直接测量。

### 2. kapi 回退路径恒带 `free_part=1`：永远拿 60 秒试听
- `lib/features/player/data/player_repository.dart:222`（`_resolveViaKapi` 内 `'free_part': '1'`）
- 问题：`docs/api_report_player.md` 实测——`free_part=1` 时非 VIP 与 VIP 都返回 `priv_status=0`、路径含 `/p_0_960115/` 的 60s 试听。直连路径 `songUrl(freePart: false)` 不带该参数，能拿到全曲；但只要直连抛非 20028 异常（或 `_directPlay` 未就绪）落到 kapi，就**必然试听**，且 `isPreview` 标记 `priv_status==0` 会让 VIP 用户全库"试听"。
- 修法：与直连对齐，默认不请求试听：
```dart
      final res = await _api.get('/song/url', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
        'quality': q.value,
        // 不带 free_part：需要试听时由调用方显式传入
      });
```
  若产品确实要"非 VIP 自动试听"，先查 `PlayerRepository.canPlay`/`requiresVip` 再决定是否附 `free_part`。

### 3. 直连降级循环把"需购买/无版权"也逐级试完，且与 20028 处理不对称
- `lib/features/player/data/player_repository.dart:158-176`（`_resolveViaDirect` 的 for 循环）
- 问题：循环内只有 `errorCode == 20028` 才 `break`；`fail_process=["pkg","buy"]`（status=2 需购买）和 8 位无版权会以"空 URL"形式返回 errorCode=0，循环会从 super 一路试到 128（5 次无效请求），最后 `lastErrorCode==0` → return null → 又整轮回退 kapi 再试 5 次。API 报告明确"不能按空 URL 连续降级"。虽不致死循环，但一次点播最多 10 个无效请求，延迟明显。
- 修法：直连前先查权益，或至少在拿到带 `fail_process`/权益拒绝标记的响应时提前退出。最小改法——`PlayUrlResult` 已有 `quality`/`ssaCode`，在 `kg_play_api.dart` 的 `PlayUrlResult.fromResponse` 里补 `failProcess` 字段：
```dart
  // PlayUrlResult 增加字段
  final List<String> failProcess; // fromResponse: b['fail_process'] is List ? ...
```
  然后 `_resolveViaDirect` 循环内：
```dart
      if (result.errorCode == 20028) break;
      if (result.failProcess.isNotEmpty) break; // 需购买/权益拒绝，降级无意义
```

### 4. `PlayUrlResult` 丢弃了 `extName` 与 `quality`，直连实际音质判定靠猜
- `lib/core/direct/kg_play_api.dart:226-246`（`PlayUrlResult.fromResponse`）与 `player_repository.dart:141-148`（`_qualityFromBitrate`）
- 问题：kapi 路径的 `_actualQuality` 用 `bitRate` + `extName`；直连路径的 `_qualityFromBitrate` 只按 bitrate 猜，且 `<300` 时直接返回 `requested`——若请求 `super` 而服务端给了 128kbps（bitRate<300 或=0），会**错标为 super/臻品母带**。flac 试听 bitRate=0 的场景（API 报告已注明）也会落到 `requested`。
- 修法：`PlayUrlResult` 补 `extName`：
```dart
  final String extName; // fromResponse: '${b['extName'] ?? ''}'
```
  `player_repository.dart` 改为：
```dart
  static AudioQuality _qualityFromBitrate(PlayUrlResult r, AudioQuality requested) {
    final q = AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality);
    if (q != AudioQuality.q128) return q;           // 服务端给了明确音质
    if (r.bitrate >= 2000) return AudioQuality.flac;
    if (r.bitrate >= 900) return AudioQuality.high;
    if (r.bitrate >= 300) return AudioQuality.q320;
    return AudioQuality.q128;                        // 未知/0 一律按最低，别标 super
  }
```

---

## 二、体验瑕疵（P2）

### 5. 失败跳歌经由 `_pendingIndex` 绕行，且会覆盖用户连点请求
- `lib/features/player/data/audio_handler.dart:196-199`（catch 内 `await skipToNext()`）
- 问题：catch 块里 `_loading` 仍为 true（finally 未执行），`skipToNext → _playAt(next)` 命中 `if (_loading) { _pendingIndex = index; return; }`，把自动跳歌**排在用户可能刚点的 `_pendingIndex` 之上直接覆盖**。行为上最终仍会播某一首，但"用户点的那首"可能被"失败自动跳的下一首"顶掉，且多绕一拍 microtask。
- 修法：catch 里不要走 `skipToNext`，改为记录待跳标记，finally 里处理：
```dart
    } catch (e) {
      ...
      _failureStreak++;
      final canAdvance =
          token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;
      if (canAdvance) {
        _autoAdvance = true;   // 新增字段 bool _autoAdvance = false;
      } else {
        _failureStreak = 0;
      }
    } finally {
      _loading = false;
      final pending = _pendingIndex;
      if (pending != null) {
        _pendingIndex = null;
        Future.microtask(() => _playAt(pending));
      } else if (_autoAdvance) {
        _autoAdvance = false;
        Future.microtask(skipToNext);
      }
    }
```

### 6. 20028 待验证状态不会因新播放请求而清场
- `lib/features/player/data/audio_handler.dart:206`（`_pendingSongIndex`）与 `:79-83`（`playQueue`/`playSong`）
- 问题：命中 20028 后 `_pendingSongIndex = index` 挂起等验证；此时用户点别的歌（playQueue/playSong）成功播放，`_pendingSongIndex` 不清除——之后 `retryPendingPlayback()` 仍会弹出/跳回旧歌（取决于 verification_listener 的调用时机）。
- 修法：`playQueue` 与 `playSong` 开头加 `_pendingSongIndex = null;`。

### 7. `KrcDecoder.decode` 注释承诺"返回空串而非抛异常"，zlib 失败时实际会抛
- `lib/features/lyric/data/krc_decoder.dart:45`（`const ZLibDecoder().decodeBytes(decrypted)`）
- 问题：Base64/头校验都有防护，但 XOR 后的垃圾数据（头对得上、内容损坏）会让 `decodeBytes` 抛 `ArchiveException`。目前唯一调用方 `lyric_repository.dart:79` 恰好包了 try/catch，所以是"靠运气没炸"；文档字符串与实现不符，后续新调用方容易踩坑。
- 修法：
```dart
    // zlib 解压
    try {
      final decompressed = const ZLibDecoder().decodeBytes(decrypted);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (_) {
      return '';
    }
```

### 8. 内嵌翻译（language 行）解析与官方 KRC 结构不符
- `lib/features/lyric/data/krc_parser.dart:151-160`（`_decodeLanguage`）
- 问题：官方 KRC 的 `language` 是 Base64(JSON `{"languageList":[{"language":"中文","lyricContent":[["原","译"],...]}]}`)，逐行翻译在 `lyricContent` 的二维数组里；本实现假设顶层是 `List<Map{content}>`，绝大多数真实 KRC 会解析出全空串，`hasEmbedded` 判定（`any(translation != null)`）反而因空串 isNotEmpty 检查不会误判，但内嵌翻译静默失效，全部走外部翻译 API（多耗配额且行对齐差）。
- 修法：
```dart
  static List<String> _decodeLanguage(String value) {
    try {
      final decoded = utf8.decode(base64.decode(value));
      final jsonValue = jsonDecode(decoded);
      if (jsonValue is Map) {
        final list = jsonValue['languageList'];
        if (list is List && list.isNotEmpty) {
          final content = (list.first as Map)['lyricContent'];
          if (content is List) {
            return content.map((row) {
              if (row is List && row.length >= 2) return '${row[1]}'; // [原, 译]
              if (row is List && row.isNotEmpty) return '${row[0]}';
              return '';
            }).toList();
          }
        }
      }
      if (jsonValue is List) { /* 保留现有降级分支 */ }
    } catch (_) {}
    return value.split(RegExp(r'\r?\n'));
  }
```

### 9. 歌词视图每次 position tick 全量重建所有可见行
- `lib/features/lyric/presentation/full_player_page.dart:300`（`_CoverOrLyricState.build` 里 `ref.watch(positionProvider)`）+ `lyric_view.dart:88-102`
- 问题：注释宣称"只让当前行随位置变化"，但 `position` 流每秒多次 tick 导致 `LyricView.build` 整体重跑，`itemBuilder` 为所有可见行新建 `_LyricLineTile`（非 const、字段全变），Flutter 无法复用——逐字高亮其实只有当前行需要 posMs。另外 `build` 里改 `_currentIndex` 后再 postFrame `setState` 会导致行切换帧额外多一次整树 build。
- 修法（两步）：
  1. `LyricView` 不收 `position`，改为内部 `AnimatedBuilder`/`StreamBuilder` 只包一层，或只把 posMs 传给 `isCurrent` 的那一行：
```dart
  itemBuilder: (context, i) => _LyricLineTile(
    line: line,
    isCurrent: i == index,
    mode: widget.mode,
    // 非 1.0 时给固定值，未唱行/已唱行的颜色只取决于 isPast，用行边界即可
    posMs: i == index ? posMs : line.startMs,
    ...
  ),
```
  并让非当前行 widget 参与 Flutter 的同名同类型复用（现已是 StatelessWidget 且无 state，关键是 `posMs` 恒定后 build 输出稳定，diff 后不重绘）。
  2. 行号变化时不要 postFrame setState 双跑：
```dart
    if (index != _currentIndex) {
      _currentIndex = index;
      // itemBuilder 下方已用新 index 构建，无需再 setState；
      // 只需滚动： WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(index));
    }
```

### 10. 双语模式翻译为空时无任何回退说明；译文模式同样裸原文
- `lib/features/lyric/presentation/lyric_view.dart:160-174`
- 问题：`bilingual` 模式 `translation.isEmpty` 时只显示原文（可接受，但用户无法区分"没翻译"与"加载中"）；`translation` 模式下译文空时同样裸显示原文，用户会以为模式没生效。另外 `ensureTranslation` 翻译失败批次把**原文写进持久缓存**（`lyric_repository.dart:135` catch 分支填 `batch[j]`），下次进入同一首连重试机会都没有。
- 修法：失败批次不要入缓存：
```dart
      } catch (_) {
        for (var j = 0; j < batch.length; j++) {
          translations[i + j] = batch[j];   // 展示用原文可以
        }
        _translationFailed = true;          // 新增局部标记
      }
```
  `set` 前判断：`if (!_translationFailed) await LyricTranslationCache.instance.set(...)`。UI 侧 translation 模式空译文时补一行灰色 `context.l10n` 占位（如"暂无翻译"）。

### 11. kapi 回退路径完全没有降级（与注释/直连行为不一致）
- `lib/features/player/data/player_repository.dart:213-236`（`_resolveViaKapi` for 循环在第一个非 20028 业务错误即 throw）
- 问题：函数注释写"从期望音质起逐级降级"，实现却是任何 `errcode != 0 || status != 1` 直接 throw——包括 status=2（需购买）时 128 音质本可试听也不会尝试。直连路径是降级的，两条路径语义不一致。API 报告的立场是"业务拒绝不降级"，那注释要改；若要降级，只对"空 URL 且 errorCode==0"降、对 fail_process/20028 终止（与直连修法一致）。
- 修法（对齐直连语义）：
```dart
      if (errorCode != 0 || (status != null && status != 1)) {
        // 20028 上抛；其余业务拒绝：记录并继续尝试下一音质（128 免费可试听）
        if (errorCode == 20028) throw ApiException(errorCode, _songFailureMessage(data, q));
        lastError = ApiException(errorCode ?? -1, _songFailureMessage(data, q));
        continue;
      }
```

---

## 三、代码质量（P3）

### 12. `ensureDfid` 的"简单防并发"是轮询 + 递归，无上限
- `lib/features/player/data/player_repository.dart:47-51`
- 问题：`_registering` 时 sleep 300ms 后递归，若并发方注册失败/缓慢，调用方可能长时间自旋（每次都延长等待，无最大重试）。
- 修法：改 `Completer<String>`：
```dart
  Completer<String>? _dfidCompleter;
  Future<String> ensureDfid() {
    final cached /* ... */;
    return _dfidCompleter?.future ?? _doEnsureDfid();
  }
```

### 13. `playSong` 用 `indexOf(song)` 依赖 `==`（仅 hash），队列里同 hash 不同 quality 实例会被误判为已存在
- `lib/features/player/data/audio_handler.dart:113-121`
- 问题：`Song.==` 只比 hash（models.dart:170-172），播放列表中同一首歌的不同音质副本会命中第一个下标。当前场景影响小，但注意这是有意设计，别在其它地方依赖"实例相等"。
- 建议：无需改代码，加注释说明即可。

### 14. `_pendingIndex` 无类型上限说明 & `verificationStreamProvider` 首帧 null 语义
- `player_provider.dart:45-48`：`async* { yield null; ... }` 让 UI 首帧把"无验证"与"事件流"混在一个通道，`verification_listener` 需自行区分。建议改 `StreamProvider<ApiException>` 不 yield null，用 `.value` 判空。纯健壮性建议。

### 15. `MemoryCache` 无容量上限
- `lib/core/cache/cache_manager.dart:8-30`：90s TTL 但无 LRU 上限，长会话听歌会累积条目。建议 `set` 时超过 200 条先清过期项。

---

## 四、通过项（已确认正确）

1. **albumAudioId 传递链**（审查点 A1）：`play_helper.dart` 四个入口 HomeSong/PlaylistSong 单曲与队列均显式传 `albumAudioId`；`models.dart:161` 用 `MixSongID`（正确，`Audioid` 被排除，符合 API 报告）；`fetchDetail` 合并时原值保底；`MediaItem.extras` 也带上了。✓
2. **默认音质 Hive key 一致**（A2）：读 `settings['defaultQuality']`（player_repository.dart:118）与写 `settings_providers.dart:17-22`（同 key、defaultValue '320'）一致；缺省双侧均为 320。✓
3. **音质降级不会死循环/跳过所有音质**（A2）：`fallbackOrder` 固定 super→high→flac→320→128，`startIndex<0` 兜底取最低；直连与 kapi 都是有界 for 循环。✓（问题仅在 3/11 的提前退出时机）
4. **20028 上抛不被吞**（A3）：`resolveUrl` 对 20028 `rethrow`；直连循环遇 20028 break 后以 lastErrorCode 抛出；kapi 直接抛含"本次请求需要验证"；`_playAt` 提取后发 `verificationRequired` 事件并停止跳歌，`verification_listener.dart` 已接入监听。✓
5. **http→代理转换全场景生效**（A4）：直连 `bestUrl` 与 kapi `url` 均过 `_proxyHttp`（https://proxy.344977.xyz/ 前缀），与 API 报告的代理约定一致。✓
6. **URL 空/非法防护**（A4）：kapi `_firstUrl` 校验 scheme+host；`PlayUrlResult.hasUrl` 校验非空；kapi 直连空 URL 继续降级而非硬用。直连 `Uri.parse` 未包 try（若 URL 非法会进 `_playAt` catch 按播放失败处理，不崩溃）。基本通过。
7. **失败恢复无递归/无死循环**（A5）：队列 1 首时 `canAdvance` 因 `_songs.length > 1` 不触发；`_failureStreak < _songs.length` 封顶后归零；`_playAt` 的 pending 用 `Future.microtask` 避免栈上递归。✓（瑕疵见第 5 条）
8. **并发 token**（A6）：`token != _playToken` 在 fetchDetail/resolveUrl/setAudioSource/play 四个 await 后都检查；`_pendingIndex` 保证"点了就有声音"且只保留最后一次。✓（瑕疵见第 5、6 条）
9. **mediaItem 同步**（A7）：`_index` 更新后立刻 `_emitMediaItem`，detail 补全后再 emit 一次（通知栏歌名/封面随详情刷新）；`setAudioSource` 用 `mediaItem.value` 作 tag。✓
10. **KRC 解密边界**（B8）：空串/非 Base64/非 `krc1` 头均返回空串（瑕疵仅 zlib 尾部，见第 7 条）；`utf8.decode(allowMalformed: true)` 防字节炸裂。基本通过。
11. **KRC 解析不丢内容**（B9）：逐字标签行尾残余文本被保留；毫秒/秒 LRC 均支持；无时间戳正文归并上一行；`offset` 语法生效并在 `_posMs` 中应用。✓（内嵌翻译结构问题见第 8 条；空 lines 前的孤立正文会丢，属极端边缘）
12. **翻译语言跟随界面 + 缓存含语言**（B10）：`currentLyricProvider` 用 `localeProvider` 构造 `zh_CN` 式目标语；`LyricTranslationCache._key = '$lyricId:$targetLang'`。✓
13. **Song 字段与 API 报告一致**（C13）：`FileHash/OriSongName/SingerName/MixSongID/AlbumID`、`/privilege/lite` 的 `hash/album_id/album_audio_id/info.duration(毫秒)/info.image`、`trans_param.union_cover`、时长秒/毫秒按字段名区分、`{size}`→400——全部与报告吻合。✓
14. **PlayUrlResult URL 数组/试听判定**（C14）：`url`/`backupUrl` 按数组解析、`bestUrl` 首选主地址；`isPreview` 用 `end_ms<=65000` 或路径 `/p_0_`，规避了 flac 试听 bitRate=0 的坑（bitRate=0 也已容错为 0，不崩）。✓（extName 缺失见第 4 条）
15. **UI 资源**：`_CoverOrLyricState`/`LyricView`/mini player 的 controller 均正确 dispose；mini player 进度条拆分独立组件的意图正确；队列 sheet 用 `ListView.builder`。✓

---

## 五、结论摘要

- 无编译阻塞。
- 必修（功能失效）：#1 歌词不滚动、#2 kapi 恒试听、#3 直连权益拒绝未提前退出、#4 实际音质错标。
- 建议修（体验）：#5 自动跳歌覆盖连点、#6 `_pendingSongIndex` 残留、#7 decoder 抛异常与注释不符、#8 内嵌翻译结构、#9 歌词全量重建、#10 失败翻译被持久缓存、#11 kapi 无降级与注释不符。
- 20028 链路（上抛→事件→listener→重试）与 albumAudioId 链路是本批最大的两个风险点，均确认无恙。
