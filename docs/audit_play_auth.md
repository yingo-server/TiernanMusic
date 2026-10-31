# 播放链路 + 登录态 窄范围逻辑审查

> 范围：仅 `play_helper / player_provider / audio_handler / player_repository / models /
> kg_client / kg_play_api / kg_providers / main / auth_providers / auth_repository`
> （另为核对 Q2、Q6 只读查看了 `home/data/models.dart`、`playlist_repository.dart`、
> `download_repository.dart` 的相关片段）。**只读审查，未改动任何代码。**

标记：✓ 正常 ｜ ⚠️ 隐患 ｜ ✗ 缺陷

---

## A. 播放链路

### Q1. 点击歌曲 → … → 声音输出，每一环参数是否对得上？有无断点？

结论：**⚠️ 主链路参数一致，但存在并发断点（`_playAt` 的 `_loading` 提前返回）。**

证据（逐环）：
- PlayHelper 构造 `Song` → `_controller.playSong(song)`：`play_helper.dart:39`。
- `PlayerController.playSong` → `_handler.playSong`：`player_provider.dart:92-93`。
- `TiernanAudioHandler.playSong` 入队并 `_playAt`：`audio_handler.dart:159-171`。
- `_playAt` → `fetchDetail` → `resolveUrl` → `setAudioSource` → `play()`：`audio_handler.dart:173-204`。
- `PlayerRepository.resolveUrl` → `_resolveViaDirect`/`_resolveViaKapi`：`player_repository.dart:114-127`。
- `KgPlayApi.songUrl` 接收 `hash/albumId/albumAudioId/quality`：`kg_play_api.dart:22-72`；`KgClient.request` 依 `token/userid` 注入默认参数：`kg_client.dart:141-146`。

参数对应关系整体闭合，无字段类型错配。

**断点（并发）**：`_playAt` 中 `final token = ++_playToken;`（`audio_handler.dart:178`）在 `if (_loading) return;`（`:181`）**之前**执行。若在一次播放进行中（`_loading==true`）再次进入 `_playAt`（例如 `processingStateStream` 触发 `skipToNext`，或用户快速连点多首）：
- 新调用把 `_playToken` 自增后直接 `return`，**不会真正播放**；
- 正在进行的旧调用在下个 `token != _playToken` 处（`:188/193/203`）返回，`finally` 置 `_loading=false`；
- 结果：`_index`/`mediaItem` 已指向新歌，但没有任何音频被 `setAudioSource/play`，表现为“点了没声音”。

修复建议（`audio_handler.dart:181`）：删除 `if (_loading) return;`，完全依赖 `_playToken` 做“最后一次请求生效”的作废旧流程（`_loading` 仅用于状态展示）。这样新请求抢占、旧请求在下一个 `token != _playToken` 处自然作废。

---

### Q2. 从 HomeSong/PlaylistSong 转 Song 时是否真的带上 `albumAudioId`？

结论：**✗ 首页路径丢失 `albumAudioId`；歌单路径正确。**

证据：
- `HomeSong` 有 `albumAudioId` 字段并在 `fromJson` 填充：`home/data/models.dart:52`、`:140`。
- 但 `playHomeSong` 构造 `Song` 时**未传** `albumAudioId`：`play_helper.dart:31-38`。
- `playHomeQueue` 同样**未传**：`play_helper.dart:46-55`。
- 对照歌单路径**正确传入**：`playPlaylistSong` `play_helper.dart:64`、`playPlaylistQueue` `play_helper.dart:81`。
- 连带影响：`_record()` 用 `song.albumAudioId` 写最近播放（`play_helper.dart:24`），首页歌曲最近播放该字段也为空。

后果：首页进入的歌曲，`_resolveViaDirect` 收到 `albumAudioId=0`（`player_repository.dart:150`），kapi 回退发送 `album_audio_id=''`（`player_repository.dart:191`）。部分歌曲（尤其需权益/会员判定的）会因缺 `album_audio_id` 拿不到 URL 或降级；而歌单同一首歌正常——正是 Q6“某些歌能播某些不能”的来源之一。

修复建议（`play_helper.dart`）：
- `:31-38` 的 `Song(...)` 内新增一行：`albumAudioId: s.albumAudioId ?? '',`
- `:46-55` 的 `Song(...)` 内新增一行：`albumAudioId: s.albumAudioId ?? '',`

---

### Q3. `AudioQuality.fallbackOrder` vs `_resolveViaDirect` 循环，会死循环或跳过所有音质吗？

结论：**✓ 无死循环、不会跳过所有音质；但 ⚠️ 起点默认是 q128，导致基本只请求 128k，永远拿不到更高音质。**

证据：
- 顺序常量：`models.dart:20-26` = `[super, high, flac, q320, q128]`（高→低）。
- 直连循环：`player_repository.dart:134-176`，单向前进，`hasUrl` 即返回，`errorCode==20028 break`。一次遍历，不会死循环。
- `startIndex<0` 时置 `order.length-1`（`:137`）→ 未知音质落到 **q128（最低）**，跳过全部高音质（隐性降级）。

**实质问题（⚠️）**：`Song.quality` 默认 `q128`（`models.dart:47,79`），`play_helper.dart` 所有 `Song(...)` 都未设置 `quality`，`fetchDetail` 原样保留（`player_repository.dart:87,103`），`_playAt` 调 `resolveUrl(detailed)` 未传 `preferred`（`audio_handler.dart:192`）。故 `start = preferred ?? song.quality = q128`，`startIndex = 4`，循环**只尝试 q128**，有会员也永远只拿 128k。

修复建议：`audio_handler.dart:192` 改为 `await _repository.resolveUrl(detailed, preferred: _preferredQuality())`，由设置读取用户音质（默认可 `q320`）；或把 `models.dart:47` 的默认 `quality` 改成偏好默认值。

---

### Q4. 单曲队列播放失败会不会 `skipToNext → _playAt → 失败 → skipToNext` 无限递归？

结论：**✓ 单曲队列被 `_songs.length > 1` 显式保护，不会无限递归；但 ⚠️/✗ 多首 + 列表循环（LoopMode.all）+ 全部失败时会无限循环。**

证据：
- catch：`audio_handler.dart:222-223` `if (token == _playToken && _songs.length > 1) { await skipToNext(); }`。单曲（length==1）→ false → 不跳，**无递归** ✓。20028 走验证流 `:207-217`，也不跳。
- 但 `_songs.length > 1` 且全失败 + `loopMode == LoopMode.all` 时：`skipToNext` 回绕 `audio_handler.dart:284-291`（`next>=length && LoopMode.all → next=0`）→ `_playAt(next)` 再失败 → 再 `skipToNext` → 回绕 0 → …**无限循环**，每轮发起网络解析（请求风暴/耗电）。await 串行不会爆栈，但外层永不结束。

修复建议（`audio_handler.dart:222`）：加“本轮已尝试计数”，遍历满一圈即停：
```dart
// 字段： int _autoSkipCount = 0;
if (token == _playToken && _songs.length > 1) {
  if (_autoSkipCount >= _songs.length - 1) {
    _autoSkipCount = 0;
    playbackState.add(playbackState.value.copyWith(errorMessage: '队列内无可播放歌曲'));
  } else {
    _autoSkipCount++;
    await skipToNext();
  }
}
```
并在成功处（`audio_handler.dart:204` 后）与 `playQueue/playSong` 入口把 `_autoSkipCount = 0`。

---

### Q5. `ensureInitialized()` 之后 `playbackEventStream.listen` 是否会被注册多次（状态风暴）？

结论：**✓ 不会。** `_initialized` 布尔做幂等保护，`listen` 只注册一次。

证据：
- `ensureInitialized()` 首行即 `if (_initialized) return; _initialized = true;`，随后才 `p.playbackEventStream.listen(_broadcastState)` 与 `p.processingStateStream.listen(...)`：`audio_handler.dart:30-36`。
- `_initialized=true` 在同步段内先于 listen 完成，任何重入调用直接返回；所有 `play/pause/skip/seek` 等都先走 `ensureInitialized()`（`:57,151,161,251,257,...`）。
- 边界情况（可忽略）：若 `listen` 本身抛异常，`_initialized` 已为 true，后续不再补注册——但 `StreamController.broadcast` 的 `listen` 实际不会抛，风险极低。

---

### Q6. 下载（`download_repository.resolveAudioUrl`）与播放链路是否共用同一套 URL 解析？若一能一不能，原因？

结论：**⚠️ 不共用同一套逻辑：底层都调 `KgPlayApi.songUrl`，但播放侧多了「多音质降级 + privilege/lite 详情补全 + kapi 回退」，下载侧是「单次单音质直调」。二者不对称会导致“播放能下、下载不能”或反之。**

证据：
- 下载：`download_repository.dart:39-60` `resolveAudioUrl` **直接** `api.songUrl(quality: quality)` 单次调用，`bestUrl` 为空即 `throw`；**无降级循环**、**无 `fetchDetail` 补全**、**无 kapi 回退**。`quality` 来自 `task.quality`（`download_provider.dart:260-265`）。
- 播放：`player_repository.dart:114-176` 先 `fetchDetail`（`privilege/lite` 合并 `albumAudioId/duration`，`:56-110`）→ `_resolveViaDirect` 从 `start` 起逐级降级 → 失败再 `_resolveViaKapi`。`audio_handler.dart:186` 先 fetch 再 resolve。
- 二者共用**同一个** `kgPlayApiProvider`→ 同一 `KgClient`（同 token/device）：`kg_providers.dart:48-49`、`download_provider.dart:337`。

“播放能拿 URL 但下载拿不到”的典型原因：
1. **albumAudioId 补全差异**：播放经 `fetchDetail` 从 `privilege/lite` 合并出 `albumAudioId`，即使 UI 层 Song 缺该字段也能补回；下载直接用 `task.albumAudioId`，若任务存的为空则 `albumAudioId=0` 解析失败。（叠加 Q2 更易触发。）
2. **无降级**：下载请求 `flac/high` 但该音质无权益时直接抛；播放会自动降到 128 成功。
3. **代理不同**：播放走 `_proxyHttp`（`player_repository.dart:260` → `proxy.344977.xyz`），下载走 `AppConfig.proxyMvUrl`（`download_repository.dart:59`）。若两者代理端口/域名不一致或其中一个失效，会出现一侧可下、一侧不可下。

修复建议（仅建议，不改）：让下载复用 `PlayerRepository.resolveUrl`（带降级与 `fetchDetail`），或在 `resolveAudioUrl` 内也做多音质循环 + 缺失 `albumAudioId` 时补一次 `privilege/lite`；并统一 http→https 代理函数。

---

## B. 登录态

### Q7. `main.dart` `ref.listen(authStateProvider)` 同步 token 时机是否正确？登录完成前就点播放（匿名态）能播吗？登录后旧匿名请求会怎样？

结论：**⚠️ 时机基本正确（依赖 authStateProvider 从 loading→data 的变更触发），但存在启动窗口的匿名态，且监听对象是“变更”而非“当前值”。**

证据：
- 监听：`main.dart:156-166`，`next.value` 非空才 `client.token = user.token; client.userid = user.userid;`。
- `authStateProvider.build()` 需 `await AccountManager.init()` + `restoreSession()`：`auth_providers.dart:20-23`，首帧时通常仍 `AsyncLoading`。
- `kgClientProvider` 是纯 `Provider`（`kg_providers.dart:43-45`），单例稳定；`playerRepositoryProvider` 仅 `ref.watch(kgClientProvider)` 预热（`player_provider.dart:16-20`）。
- `KgClient.request` 仅在 `token.isNotEmpty` 才带 token/userid（`kg_client.dart:141-146`）。

分析：
- **登录完成前**（startup 恢复 session 尚未 resolve）：`KgClient.token=''`、`userid='0'` → 请求以**匿名态**发出。免费歌能播（128/低权益），会员/高音质/受风控歌会失败或 20028。可播，但按匿名权限。
- **登录后**：`authStateProvider` 变为 `AsyncData(user)` → 监听器把 token 写到**同一个** `KgClient` 实例 → 之后请求带 token。✓
- **旧的匿名请求**：已按无 token 发出，不会被取消，按其匿名结果返回（可能低音质/失败）；不会“自动升级”。属预期，无内存错误，但用户可能看到登录后仍有歌不可播（需重试/重播）。

补充风险：`ref.listen` 默认**不为当前已存在的值回调**（无 `fireImmediately`）。若某次 `TiernanMusicApp.build` 时 `authStateProvider` 已是 `AsyncData`（例如热重载、或首次 build 前已同步恢复），监听器**不会**被触发一次，token 可能没被写入 `KgClient`（见 Q10）。当前实现里 restoreSession 是异步，正常路径会触发；但这是脆弱点。

修复建议（`main.dart:156-158`）：给监听加 `fireImmediately: true`，并在 provider 已就绪时立即同步：
```dart
ref.listen(authStateProvider, (_, next) {
  final user = next.value;              // null 见 Q9
  try {
    final client = ref.read(kgClientProvider);
    client.token = user?.token ?? '';   // 同时修 Q9
    client.userid = user?.userid ?? '0';
  } catch (e) { debugPrint('[auth-sync] $e'); }
}, fireImmediately: true);
```

---

### Q8. 切换账号（`switchAccount`）后 `KgClient.token/userid` 是否立即更新？

结论：**✓ 会更新，但**不是** `switchAccount` 内部直接改 `KgClient`，而是靠 `main.dart` 的监听器（state 变 `AsyncData(newUser)` 时触发）。**

证据：
- `switchAccount`：`auth_providers.dart:39-48`，最终 `state = AsyncData(user)`（新账号）。**未直接触碰 `KgClient`。**
- 旧 state 是 `AsyncData(oldUser)`、新是 `AsyncData(newUser)`（不同对象）→ Riverpod 判定变化 → `main.dart:156` 监听器触发 → 写入新 `token/userid`。
- 若 old 与 new 的 `AuthUser` 是同一实例则不会触发；实际 `loginByToken` 返回新对象，故会触发。

隐患：更新**依赖 main.dart 一处监听**、且是异步一帧后生效；若监听器因异常被 catch（`main.dart:163`）则静默漏同步。此外 `switchAccount` 成功后 `_api.setCredentials`（kapi）已更新（`auth_repository.dart:300-307`），而 `KgClient` 要等监听——存在极短不一致窗口。

修复建议：在 `switchAccount` 内 `state = AsyncData(user)` 后，直接同步写入直连客户端，减少对 UI 监听的依赖（需能拿到 `kgClientProvider`，可用 `ref.read`）。

---

### Q9. 退出登录后 `KgClient` 里的 token 是否被清空？不清会怎样？

结论：**✗ 未被清空。** `logout` 只清 `SecureStorage` 与 kapi 客户端，`KgClient.token` 残留旧值。

证据：
- `logout`：`auth_providers.dart:28-35` 调 `repo.logout()` 并 `state = const AsyncData(null)`。`repo.logout`（`auth_repository.dart:290-298`）只 `clearCredentials()` + `_api.clearCredentials()`，**不涉及 `KgClient`**。
- `main.dart:158` `if (user == null) return;` —— 状态变 `AsyncData(null)` 时监听器**直接 return**，所以 `client.token` **不会被清零**。
- `KgClient.request` 只要 `token.isNotEmpty` 就继续带旧 token（`kg_client.dart:141-146`）。

后果：退出后所有直连请求（播放、下载、内容）仍以**旧账号 token/userid** 发出：逻辑上“已退出但仍以旧身份访问”，可能读到旧账号私有数据、触发风控、或 token 已失效时持续 20031/权益错误。属登录态安全/一致性缺陷。

修复建议（`main.dart:157-162`）：把 `if (user == null) return;` 改为在 null 时清空：
```dart
final client = ref.read(kgClientProvider);
client.token = user?.token ?? '';
client.userid = user?.userid ?? '0';
```
（与 Q7 的 `fireImmediately` 一并用 `user?.` 写法即可同时覆盖登出。）

---

### Q10. `SecureStorage` 凭证与 `KgClient` 内存 token 是否可能不一致？

结论：**✗/⚠️ 会不一致，且有多条路径。**

证据与成因：
1. **恢复期窗口**：`restoreSession` 把凭证写入 **kapi** 客户端（`auth_repository.dart:275-282` `_api.setCredentials`），**不写 `KgClient`**；`KgClient.token` 只能等 `main.dart` 监听器在 `authStateProvider` resolve 后写入。这中间 `SecureStorage` 有 token、`KgClient.token` 为空。
2. **登出残留**：`logout` 清 `SecureStorage`（`auth_repository.dart:296`），但 `KgClient.token` 不清（Q9）→ 存储空、内存有旧 token。
3. **监听失败静默**：`main.dart:163` catch 后 `KgClient` 漏同步，与存储长期不一致。
4. **切换账号**：`loginByToken→_handleLoginSuccess` 先 `saveCredentials`（`auth_repository.dart:300-307`）再写 kapi；`KgClient` 要等监听，存在瞬时不一致。

后果：`KgClient` 是播放/下载实际使用的客户端（`kg_providers.dart:43`、`player_repository.dart:31`、`download_provider.dart:337`），它和存储不一致 → 表现为“已登录却按匿名/旧号取不到权益”、或“登出后仍带旧号”。

修复建议（根治）：把“写 token 到 `KgClient`”从 UI 监听里收口到 auth 层——在 `_handleLoginSuccess` / `restoreSession` / `logout` 三处，同时 `SecureStorage`、kapi、`KgClient` 一起更新，做一个统一的 `_syncClients(token,userid)`。这样无论 UI 是否重建，三处恒一致；`main.dart` 的监听可保留作兜底（配合 Q7 `fireImmediately`）。

---

## 严重度排序（✗ / ⚠️ 汇总）

| 序号 | 级别 | 问题 | 位置 | 影响 |
|---|---|---|---|---|
| 1 | ✗ | 登出后 `KgClient.token` 未清空，仍以旧账号身份请求 | `main.dart:158` + `auth_providers.dart:28-35` | 登录态安全/一致性，Q9 |
| 2 | ✗ | 首页路径转换 `Song` 丢失 `albumAudioId` | `play_helper.dart:31-38` / `:46-55` | 首页歌曲解析失败/降级，Q2/Q6 |
| 3 | ⚠️/✗ | 多首+LoopMode.all+全失败时 `skipToNext↔_playAt` 无限循环 | `audio_handler.dart:222` + `:284-291` | 请求风暴/耗电，Q4 |
| 4 | ⚠️ | `_playAt` 的 `_loading` 提前返回 + 先自增 token → 并发时“点了没声音” | `audio_handler.dart:178,181` | 播放断点，Q1 |
| 5 | ⚠️ | 降级起点默认 q128，永远只请求 128k，拿不到高音质 | `audio_handler.dart:192` + `models.dart:47` | 音质受限，Q3 |
| 6 | ✗/⚠️ | `SecureStorage` 与 `KgClient` 内存 token 多路径不一致 | `auth_repository.dart:275-282,296-307` + `main.dart:156` | 登录态漂移，Q10 |
| 7 | ⚠️ | 下载与播放 URL 解析不对称（单音质/无 fetchDetail/无降级/代理不同） | `download_repository.dart:39-59` | 一能一不能，Q6 |
| 8 | ⚠️ | 监听非 `fireImmediately`，已就绪态可能漏首同步 | `main.dart:156` | 登录态脆弱点，Q7 |
| 9 | ⚠️ | `switchAccount` 不直接更新 `KgClient`，依赖 UI 监听 | `auth_providers.dart:39-48` | 短暂不一致，Q8 |

（Q1 主链路参数对应、Q3 无死循环、Q4 单曲保护、Q5 单次监听 = ✓，未列入上表。）
