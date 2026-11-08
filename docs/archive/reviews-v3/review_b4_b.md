# 批4检2：跨模块一致性与集成审查（纯读）

基线：commit `3d74378`。只读审查，未修改任何业务文件，未运行 flutter/test。

严重度排序：**功能失效 > 体验瑕疵 > 代码质量**。每条：文件:行 → 问题 → 精确修法。

---

## 一、问题清单

### 【功能失效】

#### F1. 歌单队列播放：每首歌的封面被统一覆盖为同一个值
- `lib/features/player/play_helper.dart:73-86`（playPlaylistQueue，playPlaylistSong 同理 55-66）
- 问题：`PlaylistSong` 自带 `cover` 字段（playlist_repository.dart:225 已解析 `cover`/`trans_param.union_cover`），但 `playPlaylistQueue` 把队列里**所有**歌的 cover 都写成方法参数 `cover`（默认 `''`）。歌单页不传 cover 时，整条队列的 MediaItem 封面为空 → mini player / 通知栏 / 全屏播放器封面丢失。
- 缓解因素：`audio_handler._playAt` 的 `fetchDetail` 会补回 cover（player_repository.dart:68-80），但详情接口失败时封面永久缺失。
- 修法（逐首取自身 cover）：

```dart
Future<void> playPlaylistQueue(List<PlaylistSong> list, int index,
    {String cover = ''}) async {
  final songs = list
      .map((s) => Song(
            hash: s.hash,
            albumId: s.albumId,
            albumAudioId: s.albumAudioId,
            name: s.name,
            artist: s.artist,
            cover: s.cover.isNotEmpty ? s.cover : cover, // ← 改这里
            duration: Duration(seconds: s.duration),
          ))
      .toList();
  await _controller.playQueue(songs, index);
  if (index >= 0 && index < songs.length) await _record(songs[index]);
}
```

`playPlaylistSong` 中 `cover: cover` 同样改为 `cover: s.cover.isNotEmpty ? s.cover : cover`。

#### F2. 自动切歌/手动上一首下一首不写最近播放
- `lib/features/player/data/audio_handler.dart:264-296`（skipToNext/skipToPrevious）、`lib/features/player/play_helper.dart:24-37`
- 问题：最近播放只在 `PlayHelper.playSong/playQueue` 入口写入（且是**发起播放时**写，不是完成时）。`_playAt` 完成后由 `processingStateStream → completed → skipToNext` 自动切歌、用户点下一首、播放失败自动跳歌，全部绕过 PlayHelper → 这些歌永远不会进入最近播放。此外 `_record` 在 `resolveUrl` 之前执行，播放失败（非 20028 自动跳下一首）的歌也被记为"最近播放"。
- 修法（把写入时机移到播放真正出声之后）：在 `TiernanAudioHandler` 增加成功回调，PlayHelper 注册：

```dart
// audio_handler.dart 字段区
final _playedController = StreamController<Song>.broadcast();
Stream<Song> get onSongStarted => _playedController.stream;

// _playAt 中 `await _player.play();` 之后、`_failureStreak = 0;` 之前：
_playedController.add(_songs[index]);
```

```dart
// player_provider.dart 末尾（或 play_helper.dart）：
final recentPlayRecorderProvider = Provider<void>((ref) {
  final sub = ref.watch(audioHandlerProvider).onSongStarted.listen((song) {
    // 沿用 PlayHelper._record 的实现：hash 去重置顶、最多 50 条、notifyListeners
  });
  ref.onDispose(sub.cancel);
});
```

PlayHelper 里原 `_record` 调用删除（或保留队列入口的首曲由流覆盖）。若不想动 handler，**最低限度**也应把 `_record` 挪到 `resolveUrl` 成功之后——但 PlayHelper 拿不到该信号，推荐流方案。

#### F3. 切换账号中途失败：AccountManager 当前指针已切换但登录态未切换，两处 UI 不一致
- `lib/features/auth/data/auth_providers.dart:47-64`（switchAccount）+ `lib/features/auth/data/account_manager.dart:100-108`（switchTo）
- 问题：`switchTo(userid)` 先把 `_kCurrent` 写为新账号并广播（音乐库立即刷新显示新账号），随后 `loginByToken` 若因网络失败抛 DioException，`authStateProvider` 仍是旧账号（设置页显示旧账号），且 SecureStorage 凭证还是旧账号 → 下次启动 `restoreSession` 恢复旧账号，但 current 指针指向新账号。数据一致性与 UI 均错位。
- 修法（成功后再切指针）：把 `AccountManager.switchTo` 拆成"只查记录"与"提交指针"两步：

```dart
// account_manager.dart 新增
AccountRecord? peek(String userid) {
  for (final a in accounts) {
    if (a.userid == userid) return a;
  }
  return null;
}

// auth_providers.dart switchAccount：
Future<void> switchAccount(String userid) async {
  final record = AccountManager.instance.peek(userid);
  if (record == null) return;
  final token = await ref.read(authRepositoryProvider).getAccountToken(userid);
  if (token == null || token.isEmpty) {
    throw StateError('该账号需要重新登录');
  }
  final repo = ref.read(authRepositoryProvider);
  final user = await repo.loginByToken(token: token, userid: userid); // 先登录
  await AccountManager.instance.switchTo(userid); // 成功后才切指针+广播
  state = AsyncData(user);
}
```

（`loginByToken → _handleLoginSuccess → upsert` 内部也会把 `_kCurrent` 设为该 userid 并广播，所以 `switchTo` 甚至可以整行删掉，行为由 upsert 兜底；上面写法保留显式切换语义。）

#### F4. 已下载歌曲"播放"仍走网络解析，未使用本地文件
- `lib/features/library/presentation/library_page.dart:170-190`（_playDownloaded）
- 问题：注释写"本地文件路径优先"，实现却只构造 `Song(hash...)` 走 `playSong` → `resolveUrl` 全网链路。已下载歌在断网时无法播放（下载功能的核心价值失效），且 VIP 歌离线也播不了。`DownloadTask` 有 `filePath`/`mediaUri` 可用。
- 修法：`Song` 增加本地源支持或 handler 增加 `playLocal` 入口。最小改动：给 `Song` 加 `localPath` 字段，`_playAt` 中：

```dart
// audio_handler.dart _playAt，替换 resolveUrl 分支
String url;
if (song.localPath != null && song.localPath!.isNotEmpty &&
    File(song.localPath!).existsSync()) {
  url = song.localPath!;
} else {
  final result = await _repository.resolveUrl(detailed);
  url = result.url;
}
await _player.setAudioSource(AudioSource.uri(Uri.parse(url), tag: mediaItem.value));
```

```dart
// library_page.dart _playDownloaded：
final song = Song(
  hash: task.hash,
  albumAudioId: task.albumAudioId,
  name: task.title.isEmpty ? task.hash : task.title,
  artist: task.artist,
  cover: task.coverUrl,
  localPath: task.filePath.isNotEmpty ? task.filePath : null,
);
```

### 【体验瑕疵】

#### W1. 评论/歌单/收藏等非播放场景命中 20028 没有验证入口，直接抛原始错误
- `lib/features/auth/presentation/verification_listener.dart:31-38`、`lib/features/comment/data/comment_repository.dart`（sendComment 等）
- 问题：全局 `VerificationListener` 只订阅 `verificationStreamProvider`（播放器事件流）。评论发送、歌单增删等 kapi/直连请求抛 `ApiException(20028)` 时没有统一拦截——用户看到的是 E2 描述的原始异常文案，而不是 CaptchaPage。两条验证路径（KgClient.requestWithVerify 自动指纹提交 vs CaptchaPage 人工）只在播放链路汇合。
- 修法：在 `VerificationListener._handle` 之外，为评论/歌单写操作提供同一入口。最小方案：`CommentRepository.sendComment/sendFloorReply` 捕获 `ApiException.needsVerification` 后向上抛出，UI 层（comments_page 发送按钮）复用现有 `CaptchaPage`：

```dart
Future<void> _send(WidgetRef ref) async {
  try {
    await repo.sendComment(...);
  } on ApiException catch (e) {
    if (e.needsVerification && (e.ssaCode?.isNotEmpty ?? false)) {
      final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CaptchaPage(
            ssaCode: e.ssaCode!, api: ref.read(kugouApiClientProvider)),
      ));
      if (ok == true) return _send(ref); // 验证通过重试一次
    }
    rethrow;
  }
}
```

#### W2. ApiException 原始异常文案直接展示给用户
- `lib/features/settings/presentation/settings_page.dart:349`（`switchAccountFailed('$e')`）、`lib/features/download/download_provider.dart:380`（`error: '$e'`）等
- 问题：`ApiException.toString()` = `ApiException(20028): xxx`，`StateError('该账号需要重新登录')` 也是原始文本风格。UI 各处用 `'$e'` 拼文案，用户看到的是英文异常类名。
- 修法：加统一映射函数（放 `core/utils/`）：

```dart
String friendlyError(Object e) {
  if (e is ApiException) {
    if (e.needsVerification) return '需要完成人机验证后重试';
    return switch (e.errorCode) {
      1011 || 20010 || 30791 || 401 => '登录已过期，请重新登录',
      _ => e.message,
    };
  }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
}
```

各 Toast 处改为 `friendlyError(e)`。

#### W3. 登录/恢复成功时不同步 kg.t1（依赖直连路径副作用）
- `lib/main.dart:233-247`（authStateProvider listener）
- 问题：listener 只在 `user == null` 时清 `client.t1`，登录/恢复分支不设 t1，注释假设"由 loginByToken → cookie 刷新"，但 `KgClient` 不用 cookie，t1 只在 `KgDirectApiClient._afterLogin`（kg_direct_api_client.dart:1078-1082）直连成功时被写入。若登录走 kapi 回退（直连抛非 20028 异常），`kg.t1` 保持空/旧值 → edt 指纹验证签名（kg_client.dart:391-397 submitFingerprintVerification）用错账号上下文。
- 修法：listener 补上 t1 同步（AuthUser 不带 t1，可从 credentials 读）：

```dart
ref.listen(authStateProvider, (_, next) {
  if (next.isLoading) return;
  try {
    final client = ref.read(kgClientProvider);
    final user = next.value;
    client.token = user?.token ?? '';
    client.userid = user?.userid ?? '0';
    if (user == null) {
      client.t1 = '';
    } else {
      // 异步补 t1，失败不阻塞
      SecureStorage.instance.readCredentials().then((c) {
        client.t1 = (c?.t1 != null && user.userid == c!.userId) ? (c.t1 ?? '') : '';
      });
    }
  } catch (e) {
    debugPrint('[auth-sync] $e');
  }
});
```

#### W4. `kgDeviceProvider` 未 override 时整条客户端链路崩溃（无降级）
- `lib/core/direct/kg_providers.dart:65-67`
- 问题：`throw UnimplementedError(...)` 是单点故障——`kgClientProvider → kgDirectApiProvider → kugouApiClientProvider → auth/player/playlist/comment/lyric/download 全部 Repository`。main() 已有三重兜底使 device 几乎不为 null，但一旦走到（如 Hive 全异常且 `KgDevice.generate()` 抛错），错误页之外任何恢复都无路可走；且未来新增入口（测试、后台 isolate）忘记 override 就是全局崩。
- 修法：默认实现改为生成临时设备（不持久化，可被 override 覆盖）：

```dart
final kgDeviceProvider = Provider<KgDevice>((ref) {
  // 兜底：main() 正常时永远会被 override；此处仅为防崩（内存设备，不持久化）
  return KgDevice.generate();
});
```

### 【代码质量】

#### Q1. `playPlaylistQueue` 的 `cover` 参数语义混乱（与 F1 同源）
- 修掉 F1 后该参数仅作 fallback，建议注释明确"仅当歌单项无 cover 时兜底"。

#### Q2. `DownloadManager._run` 捕获普通异常后错误文案 `'$e'`
- `lib/features/download/download_provider.dart:381`：`error: '$e'` 会把 `StateError('缺少封面地址')` 之类原样上屏。配合 W2 的 `friendlyError` 改为 `error: friendlyError(e)`。

#### Q3. `_playDownloaded` 构造的 `Song.albumId` 未填（''）
- `lib/features/library/presentation/library_page.dart:173-180`：`fetchDetail` 以 `album_id` 作查询参数，为空可能降低 `/privilege/lite` 命中率。`DownloadTask` 若存有 albumId 应带上（字段未确认，修 F4 时顺带检查 `DownloadTask` 是否有该字段）。

---

## 二、通过项（按审查点编号）

**A. 登录态一致性**
1. ✅ 登录 → 四处同步链路完整：`_handleLoginSuccess`（auth_repository.dart:296-351）依次写 SecureStorage 凭证、`KugouApiClient.setCredentials`（cookie，单例共享 CookieJar，kugou_api_client.dart:126-147 注释明确）、AccountManager.upsert（广播）、Hive settings；main.dart listener（main.dart:233-247）再把 token/userid 同步到 KgClient。退出时 `logout()` 清凭证 + `clearCurrent()`（广播）+ listener 清 KgClient（含 t1）。
2. ✅ 退出响应：设置页 watch `authStateProvider` 即时刷新；音乐库订阅 `AccountManager.onCurrentAccountChanged` 刷新账号卡与我的歌单；评论 `isMine` 用 `_api.userid`（clearCredentials 后为空 → 不再显示删除按钮）。播放器/下载不因退出停止——歌单/评论为公共资源，行为正确。
3. ✅ 切换账号：正在播放的歌继续播（audioHandler 与 authState 无任何订阅关系），符合"歌是公共的"预期。⚠️ 但见 F3 的一致性问题。
4. ✅ 设置页账号区块（批3修3）：`_logout` 调 `ref.read(authStateProvider.notifier).logout()`，`_showSwitchAccountDialog` 调 `switchAccount(selected.userid)`——与 `AuthStateNotifier` 的方法签名 `logout({bool removeAccount = false})` / `switchAccount(String userid)` 完全匹配；StateError（需重登）单独捕获（settings_page.dart:344-347）；刷新靠 `ref.watch(authStateProvider)`（F5 修复在位）+ `_loadAccount()` 双保险。
5. ✅ 音乐库账号区块（批2修1）订阅在位：library_page.dart:44-49 `_authSub = AccountManager.instance.onCurrentAccountChanged.listen(...)` → setState + `ref.invalidate(_userPlaylistsProvider)`，且 dispose 正确 cancel（57-60）。

**B. 播放 ↔ 其它模块**
6. ✅ 播放中下载同一首无文件冲突：播放是 just_audio 网络流（不落临时文件）；下载临时文件名 `${hash}_${type.name}.ext`（download_provider.dart:305-306）只由下载写，且同 id 任务重 add 时 `_running` 防重入。唯一代价是播放与下载各解析一次 URL（两次风控暴露，可接受）。
7. ⚠️→F4：删除已下载文件不会崩播放器（播放本就不用本地文件），但反过来说明离线播放未实现。
8. ❌→F2：切歌不写最近播放；发起播放即写（失败也写）。
9. ✅（播放链路）：`_playAt` 捕获 `needsVerification` → `_pendingSongIndex` + `verificationController` → MainShell 外层 `VerificationListener` → `CaptchaPage` → 成功后 `retryPendingPlayback()`（audio_handler.dart:196-208, 312-317；verification_listener.dart:31-59）。挂起状态在新播放请求时正确清除（playQueue/playSong 置 `_pendingSongIndex = null`）。⚠️ 非播放场景见 W1。

**C. Provider 依赖图（无环）**
10. ✅ 依赖图（单向，无环）：
```
kgDeviceProvider(override)
  └─ kgClientProvider ─┬─ kgPlayApiProvider ──> playerRepositoryProvider / downloadRepositoryProvider
                       └─ kgDirectApiProvider ─> kugouApiClientProvider
                                                  ├─ authRepositoryProvider
                                                  ├─ lyricRepositoryProvider ─┐
                                                  ├─ PlaylistRepository(UI 内自建) │
                                                  ├─ CommentRepository(UI 内自建)  │
                                                  │            MvRepository <──────┴─ downloadRepositoryProvider
                                                  └─ _apiClientProvider ─> playerRepositoryProvider
audioHandlerProvider ─> playerRepositoryProvider
downloadManagerProvider ─> downloadRepositoryProvider
authStateProvider(build 时) 读 authRepositoryProvider（方法内 ref.read，非 watch，无环）
main.dart listener 读 kgClientProvider（监听方，无环）
```
11. ⚠️ 链路失败传导：`kgDeviceProvider` 抛 UnimplementedError → `kgClientProvider` → `kgDirectApiProvider` → `kugouApiClientProvider` 全部抛 → 所有 Repository 构造失败 → 全应用页面崩溃。main() 有 device 兜底（KgDeviceStore.loadSync 失败 → generate → 再失败写 `_startupError` 显示错误页），实际风险低，但默认实现建议改为 generate 兜底（W4）。
12. ✅ `playerRepositoryProvider` 是普通 `Provider`（非 autoDispose/family），全局单例；home/search/playlist/library 通过 `playerControllerProvider → audioHandlerProvider → playerRepositoryProvider` 拿到同一实例，共享同一 CookieJar（`_apiClientProvider = kugouApiClientProvider`，player_provider.dart:20-31 注释明确）。

**D. 路由与导航**
13. ✅ 全部注册：`/login`、`/player`、`/playlist/:id`、`/comments/:type/:id`、`/downloads`、`/mv/:hash`（app_router.dart:24-63）与各页 `context.push` 一一对应；`/comments/:type/:id` 的 type 直接透传给 `CommentsPage.resourceType`（与 `CommentResourceType.name` 的 song/playlist/album 对齐）。参数传法正确。
14. ✅ 深层返回刷新：设置页 push('/login') 后 `_loadAccount()` + watch authState 双刷新；音乐库靠 Stream 订阅（登录、最近播放均有）；播放器各页全部是 StreamProvider（currentSong/queue/isPlaying），返回即最新。⚠️ 评论返回歌单的评论数刷新未在本次阅读范围内确认（comments_page/playlist_detail_page 未列入清单）。
15. ✅ `/player` 是根级 GoRoute（覆盖 Tab，app_router.dart:34），从队列 sheet/mini player 点歌后 pop 回原位置正确；MiniPlayer 挂在 MainShell 内（app_router.dart:84-97），根级 push 全屏播放器时 Tab 栏被覆盖，符合预期。

**E. 数据契约**
16. ✅（除 F1）字段转换链完整：`HomeSong→Song` 保留 hash/albumId/albumAudioId/cover/duration（play_helper.dart:40-52）；`PlaylistSong→Song` 保留 hash/albumId/mixsongid/duration（cover 见 F1）；`fetchDetail` 的 merge 保留原 song 的 hash/albumId/name/artist/cover/duration/quality（player_repository.dart:66-100，copyWith 显式回填）。⚠️ `hash: s.hash ?? s.id`（play_helper.dart:43）依赖 HomeSong.id 为 hash 的约定，未在本次范围内验证 HomeSong.fromJson。
17. ⚠️→W2：错误传播链正确（KugouApiClient onResponse 拦截器统一抛 `ApiException`，KgDirectApiClient `_wrap` 保持同一类型，`needsVerification` 判定贯穿），但 UI 层展示多为 `'$e'` 原始文案。

---

## 三、结论

跨模块集成的**架构面是健康的**：登录态四处同步链路完整且此前两轮修复（F5/批3修3、批2修1）均在位且正确；Provider 图无环、客户端单例共享正确；20028 播放验证闭环正确；路由全部注册。

需修复的 4 个功能项按优先级：**F1（歌单封面丢失）→ F3（切号状态错位）→ F2（最近播放漏记）→ F4（离线播放未实现）**；体验项 W1（评论 20028 无验证入口）建议随 F4 一起排入下一批。
