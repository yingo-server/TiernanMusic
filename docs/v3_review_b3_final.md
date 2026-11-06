# v3.2.0 发布终审报告（第 7 批 · 用户体验路径回归）

- 基线：`722f2bb`（tag `v3.2.0`，`pubspec: 3.2.0+32`）
- 审查对象：第 6 批（`8cc754e` / `53f15d9` / `1e57ed3` / `d8543af` / `7f80784`）5 个修复提交所触碰的 10 个文件
- 方法：逐文件**完整通读**（首行到末行）+ 上游语义核对（Dart SDK / dio 5.x 导出表 / flutter_riverpod 2.5.1 `consumer.dart` 的 `_assertNotDisposed`）
- 未读 `v3_review_b1_*` / `v3_review_b2_*`（防锚定）；未编译、未跑测试
- 视角：**发布终审**——只看用户实际会走的路径，只报「回归 / 新引入缺陷 / 修复不完整」

## 判定：**不建议以当前 commit 发布**

`1 × P0`（构建失败）、`4 × P1`（登出后设备身份漂移 / 验证死循环 / 连播中断 / 收藏永久失效）、`3 × P2`、`5 × P3`，共 13 条。
第 6 批的 5 项修复里，R-26/27、R-01、R-28 三项成立；**B-07 引入编译错误，B-10 的成果被 B-11 反向抵消，R-29 与 V3-14 属修复不完整**。

---

## 一、发布阻断项

### P0-1 `debugPrint` 无符号来源 → 全项目无法编译

**位置**：`lib/core/api/kugou_api_client.dart:1-6`（import 区）、`:131`、`:160`、`:166`

**事实**：第 6 批 `7f80784` 为 B-07「降级留痕」新增了三处 `debugPrint(...)`，但该文件的 import 只有
`package:dio/dio.dart`、`package:dio_cookie_manager/dio_cookie_manager.dart`、`package:cookie_jar/cookie_jar.dart`、
`../config/app_config.dart`，**没有 `package:flutter/foundation.dart`**。

已核上游：`dio 5.7` 的 `pubspec.yaml` 依赖只有 `async / http_parser / meta / path / dio_web_adapter`，`dio.dart` 的
`export` 列表不含任何 Flutter 库；`cookie_jar`、`dio_cookie_manager` 同为纯 Dart 包；`app_config.dart`
本身没有任何 `import`，也没有 `export`。Dart 的 import 不传递，因此 `debugPrint` 在本库**无任何可见声明**。

**违反**：第 28／29 条（「接口/行为必须逐一实测」，此处连静态可判定项都没跑）；同时第 9 条的意图（留痕）与实际
（编译不过）自相矛盾。

**用户可见后果**：`flutter analyze` 报 `undefined_function`，CI `analyze-test` 红 → `build-apk` 的 `needs` 不满足 →
**没有任何 APK 产出**。若走本地构建，错误信息是
`Error: The function 'debugPrint' isn't defined`。这是发布红线，必须先修（三选一：补 import、换 `print`、
或改用项目内 `ErrorLogger`）。

> 说明：沙箱内无 `.dart_tool`（未 `pub get`），`dart analyze` 对该文件的所有包符号一律报 undefined，无法用它复现
> 单点报错；上述结论由「import 集合 + 上游包依赖/导出表」静态推定，属确定性错误而非风格问题。

---

## 二、用户路径逐条复核

### 路径 1：冷启动 → 登录（B-07 CookieJar 时序）

**结论：时序安全，登录态不会因该改动丢失；但「降级留痕」写在错误的位置。**

- 全仓（`rg "KugouApiClient\(" lib`）只有两个构造点：`kugouApiClientProvider → kgDirectApiProvider`（第 6 批前已存在）
  与 `AuthRepository({KugouApiClient? api})` 的 `api ?? KugouApiClient()` 兜底；两者都是 Riverpod provider，
  **首次读取发生在 `runApp` 之后**。
- `main.dart:91` 在 `runApp`（`:141`）之前设置 `KugouApiClient.cookieStoragePath`；其间的
  `AudioServiceBootstrap.start()`（`:113`）只做 `JustAudioBackground.init()`，不构造任何 API 客户端。
  **不存在更早的构造点**，`sharedCookieJar` 第一次被访问时路径必然已就绪 → 直接命中 `PersistCookieJar`。
  故 B-07 的核心诉求（防「进程级内存 jar 导致冷启动被登出」）在现行启动顺序下**成立**。

**P3-1｜`try/catch` 守错位置，真失败点无人兜底（违反第 11 条）**
`_createCookieJar` 的 `try { PersistCookieJar(storage: FileStorage(path)) } catch`：`PersistCookieJar` 与
`FileStorage` 的构造**都不触盘**（cookie_jar 4.x 的目录创建发生在 `saveFromResponse → storage.write`）。
因此该 catch 实际覆盖不到真实故障；路径只读时第一次抛错发生在登录的
`await _cookieJar.saveFromResponse(uri, cookies)`（`kugou_api_client.dart:227`），原始 `FileSystemException`
直接冒到登录页。用户看到的是系统级英文错误文本，而不是「存储不可用，本次登录不持久化」。
同一函数的 `if (jar is! PersistCookieJar)`（`:165`）在 `_createCookieJar` 只有两种返回类型、且
`path.isNotEmpty` 已前置判断的前提下**恒为假**（第 32 条：不可达分支）。

**P3-2｜注释与行为不符（违反第 31 条）**
`:153-156` 注释称「路径未就绪时**不缓存** jar（每次重查，路径就绪后自然切到持久化）」。事实上
`KugouApiClient` 在构造函数里**一次性**取走 `sharedCookieJar` 并存入 `final _cookieJar`，之后不再重查：
已构造的实例永远停留在内存 jar，「自然切换」只对**之后新构造**的客户端成立。另需注意，路径未就绪时每次返回
**新的** `CookieJar()`，多个客户端之间不再共享登录态（改动前是共享同一个内存 jar）——
当前全仓只有一个客户端实例，实际影响接近零，但该注释会误导下一位维护者。

### 路径 2：登录 → 播放（B-10 dfid 双写）

**结论：写法合法，但「双写」的权威源关系马上被 B-11 打破，见路径 3。**

`SecureStorage.instance.saveDfid(dfid).catchError((e) { debugPrint(...); })` 形态正确：
`saveDfid` 返回 `Future<void>`，`catchError` 的回调返回值对 `void` 恒可赋值，fire-and-forget 也不会产生
未捕获异常（异常被 `catchError` 接住）；`debugPrint` 在本文件有 `package:flutter/foundation.dart` 导入
（`kg_providers.dart:4`），可编译。

**P3-3｜双写不是原子的（第 5 条）**
`KgDeviceStore.saveDfidSync(dfid)`（Hive，同步）与 `SecureStorage.saveDfid`（异步）之间没有任何顺序保证；
进程在两者之间被杀就会重新出现「Hive 有新 dfid、SecureStorage 是旧值」的分裂。概率低（两次写入间隔毫秒级），
记为整洁度问题。

### 路径 3：退出登录 → 重新登录（B-11 登出清理）｜**P1**

**P1-1｜登出删掉 dfid，把「设备身份」当成「用户凭证」清掉，用户每次退出后重登都会被判成新设备（违反第 5 条、第 20 条）**

事实链（全部可指到行）：

1. `secure_storage.dart:64-75` `clearCredentials` 现在删除 `token/userid/t1/auth/**dfid**` 与 `acct_token_<userid>`。
2. `main.dart` 的 `authStateProvider` 监听只清 `KgClient` 的 `token/userid/t1`；`KgDirectApiClient.clearCredentials`
   （`kg_direct_api_client.dart:56-61`）也不动 `kg.device.dfid`。**Hive `device` 盒里的 dfid 更从未被删。**
   于是同一个「设备身份」在登出瞬间分裂成：Hive＝旧值、`KgClient.device.dfid`＝旧值、SecureStorage＝不存在。
3. 重新登录：`_handleLoginSuccess`（`auth_repository.dart:305-318`）调 `getDfid()`（`:66-78`）——它**只读 SecureStorage**，
   读不到就改走 `_api.get('/register/dev')` 要一个**新的** dfid，落盘后再 `setCredentials(dfid: 新值)`。
   `KgDirectApiClient.setCredentials` 把这个新值写进 `kg.device.dfid`。
4. 于是每次「退出 → 重登」，服务端看到的是一个**全新设备**；而下次冷启动时 `KgDeviceStore.loadSync` 又把
   **Hive 里的旧 dfid** 装回 `KgClient`，等 `restoreSession` 完成后再被 SecureStorage 的新值覆盖——
   **每次冷启动到登录完成之间设备标识都会跳变一次**，这正是 B-10 声称要消灭的「来回跳变」。

**用户可见后果**：退出登录再登回来（换号、或者只是清理一下）之后，风控把本机当新设备：更容易命中 20028
人机验证、播放降权到 30 秒试听、推荐/播放画像清零；冷启动时先按旧设备、登录后按新设备，风控画像来回切换。

**连带 P1：验证流程会死循环。** `verification_service.dart:34` 的 `buildSidEdt` 用
`SecureStorage.readDfid() ?? '0'` 生成 sid/edt，而业务请求头/参数用的是 `kg.device.dfid`。登出后 dfid 被删，
若此时（未登录态或刚重登）命中 20028，edt 用 `'0'`、请求用旧 dfid，**算法维度不一致 → 验证提交后重试仍被拦截**，
用户看到的是「验证通过 → 再验证 → 再失败」。

**同时引入第 27 条问题**：`getDfid()` 走的是 `_api.get('/register/dev')`，即 **kapi 中转网关**。B-11 之前 dfid
一直存在，这条路径只在首次装机跑一次；B-11 之后，它变成了「每次退出后重登」都会执行的**常规登录路径**——
QUALITY_STANDARD 第 27 条（业务接口只走原生网关）在正常用户路径上被触发。kapi 不可用时 `getDfid` 的
`catch (_) {}`（`:77`，第 6 条空捕获）会返回空串，登录在缺 dfid 的情况下继续，进一步抬高风控命中率。
**修复方向**：登出应只清用户凭证，dfid 保留（或从 Hive 回填 SecureStorage）；`getDfid` 应优先读
`KgDeviceStore`/`kg.device.dfid`，而不是只读 SecureStorage 再打 kapi。

### 路径 4：多账号切换（B-11 删 `acct_token_*`）

**结论：功能不崩，但「账号列表还在、token 没了」的条目会造成一次误导 + 一次数据删除，且安全残留只修了一半。**

- `auth_providers.dart:64-70`：`getAccountToken` 返回空 → `throw StateError('该账号需要重新登录')`。
- `settings_page.dart:365-375` `on StateError` 已经兜住：把该账号从 `AccountManager` 里 `remove()` 并
  toast「需要重新登录」。所以**不会白屏、不会卡死**，点击有反馈。

**P3-4｜刚退出的账号仍显示在网络账号列表里，点一次就被永久删除（违反第 16 条：状态语义要分开）**
退出登录后 `AccountManager.accounts` 仍保留该记录（`logout` 只 `clearCurrent`）。等用户换另一个账号登录，
切换弹层里就会出现这个**必然失败**的条目；点它 → StateError → 被从本地账号表删掉（昵称、头像历史一并丢失），
用户想切回只能重新输密码。既然后端 token 已删，列表就应该同步「标记为需重新登录」，而不是让用户去撞一次墙再删记录。

**P2-1｜安全残留只清当前账号（第 5／11 条，修复不完整）**
B-11 只删 `acct_token_<当前 userid>`。共享/转手设备场景：A 退出后，B 的 `acct_token_B` 仍在；下一个使用者
登录一个新账号 C 后，切换弹层里就能看到 A、B 两条记录，其中 **B 仍可无密码一键登入**。
也就是说「退出后账号仍处于登录态」这一原始风险，只对「最后退出的人」消失了，对其余账号原样存在。

**P3-5｜`removeAccount: true` 分支是死代码（第 32 条）**
`rg` 全仓 `.logout(` 调用点只有 `settings_page.dart:316` 与 `library_page.dart:429`，均为默认参数；`removeAccount:true`
分支内的 `deleteAccountToken` 又与新加的 `clearCredentials(userid:)` 重复删除同一键。

### 路径 5：播放失败 → 自动跳下一首（V3-13 闸门）｜**P1**

**P1-2｜失败分支里的 `pause()` 会作废刚拿到的世代，`canAdvance` 恒为 false，自动跳歌彻底失效（违反第 18／19／11 条）**

- `audio_handler.dart:388`：`catch` 里先 `await _playerOrNull?.pause();`
- `audio_handler.dart:462-464`：`pause()` 的第一句是 `_playToken++;`（V3-02 引入、V3-13 保留）
- `audio_handler.dart:390-395`：
  ```dart
  _failureStreak++;
  final canAdvance = token == _playToken && _songs.length > 1 && _failureStreak < _songs.length;
  if (canAdvance) { await skipToNext(); } else { _failureStreak = 0; }
  ```
  `token` 是本次 `_playAt` 开头拿到的世代号，`_playToken` 刚被上面那次 `pause()` 自增过 →
  **`token == _playToken` 恒为假** → `canAdvance` 恒为假 → 每次都走 `else` 把 `_failureStreak` 清零。
  结果是：既不会跳下一首，也永远不会触发「连续失败达到队列长度才停止」的保护。

**用户可见后果**：只要一首歌解析失败（无版权、地区限制、`/v5/url` 全档 `fail_process`、网络单次 5xx），
播放器就**停在这一首的 error 态**，不再自动播下一首；以前是「失败即静音跳过」的连播体验，现在整张歌单/榜单
从第一个坏曲目起就断了，用户必须手动点「下一首」。`_failureStreak` 恒 0 也让日志里看不到「连续失败」。

附带（非 V3-13 引起、但同属该闸门的残留）：`pause()` 不再开闸是**正确**的（第 19 条，闸门由持有者的 `finally`
释放，`audio_handler.dart:398-410` 确实在 `finally` 统一释放并转交 `_pendingIndex`），这一点本批复核**通过**；
问题只出在「用户主动 pause」与「失败路径内部 pause」复用了同一个会作废世代的入口。

**修复方向**：失败分支不要复用 `pause()`（改 `_player.pause()` 直接调用），或把 `canAdvance` 的判断放到
`pause()` 之前先算好。

### 路径 6：歌单收藏（V3-14 防重锁）｜**P1**

**P1-3｜全局锁 + 在已销毁的 widget 上 `ref.read`，可能导致「收藏按钮永久无反应」（违反第 20／19／21 条）**

- `playlist_detail_page.dart:49`：`_collectingProvider = StateProvider<bool>`，**非 autoDispose、非 family**，
  即进程级单例。
- `:312-313` 取锁、`:334` 在 `finally` 里 `ref.read(_collectingProvider.notifier).state = false;`。
- 页面是 `ConsumerWidget`，`ref` 来自已挂载的 `ConsumerStatefulElement`。用户点收藏后立刻返回（网络请求通常
  1–3 秒，这在本页很常见：从搜索结果点进歌单，随手收藏再返回）→ await 恢复时该 Element 已 unmount →
  `finally` 里的 `ref.read` 命中 flutter_riverpod 2.5.1 的 `_assertNotDisposed`
  （`consumer.dart:548-550`，`throw StateError('Cannot use "ref" after the widget was disposed.')`）。

**用户可见后果**：`finally` 抛异常 → 锁永远不会被复位 → 此后**任何**歌单页点收藏都在 `:312` 静默 `return`，
既不发请求也没有任何提示；页面比改前更糟的是，这个锁是全局的（以前是不可变的 widget 字段，重建即复位），
所以只能重启 App 才恢复。异常本身会被 `runZonedGuarded` 记进 `ErrorLogger`，但用户侧零反馈（第 9 条）。

**P2-2｜`_tracksReloadProvider` 是无人写入的死状态，同时「加载更多/截断提示」整块消失（违反第 32／16 条）**

- `:45` 定义、`:69` `ref.watch`，全文件**没有任何 `.state = ` 或 `read(...notifier)` 写入**（注释「加载更多后
  手动触发 UI 重建」已无对应 UI）。
- `_buildTracksSlivers`（`:281-330`）注释仍写着「歌曲列表 + **截断提示/加载更多**（>100 首的公共歌单不再静默截断）」，
  实际只有一个 `SliverList`，没有 footer、没有「加载更多」按钮。
- 而「我的歌单」走 `fetchUserTracks`（`playlist_repository.dart:133`），`pageSize = 300` 且**只取第 1 页**。

**用户可见后果**：超过 300 首的「我的歌单」只渲染前 300 首，底部既没有提示也没有更多入口——用户以为歌单少了歌；
同时第 69 行的 watch 恒不触发，纯冗余重建依赖。

### 路径 7：搜索（R-26/27/28/29）

**R-28（联想词优先）复核通过。** `_submit`（`search_page.dart:83-103`）在 await 之后做 `mounted` 检查，
再一次性把 `_controller.text = k`、`_showSuggest = false`、`_suggestions = []`、`_submittedKeyword = k` 设好；
提交时 `_debounce?.cancel()` 已清掉在途联想请求，落地页/联想/结果三态的优先级切换是完整的。
`onSubmitted: _submit` 与 `Future<void> Function(String)` → `void Function(String)` 的赋值合法。
**返回路径正常**：作为 tab 时 `canPop == false` 不渲染返回键，push 进来时返回键走 `maybePop`。

**P2-3｜R-29 的 `_pageError` 只清一半，且注释承诺的行为没实现（违反第 9／16／31 条）**

- `:487` 与 `:491`：分页失败时**同时**置 `_error = e` 和 `_pageError = e`。
- `:449` 的滚动监听仍写着「只有首次加载失败（`_error`）才阻断；分页失败（`_pageError`）已由 footer 重试接管，
  滚动不应再被阻断」——但 `_error` 同样被置上了，**分页失败后自动加载依然是永久停用的**，注释与行为相反。
- `:473-483` 成功分支只清 `_error`，**从不清 `_pageError`**。于是「首屏加载失败 → ErrorRetry 重试成功（`:508-513`
  只重置 `_page`/`_error`/`_initialLoading`）→ 列表底部仍然渲染『重试』按钮（`:541`）」；正确的下一页加载态
  （转圈）反而看不到。

**分页序号本身没问题**：`_page` 只在成功分支 `:477` 自增，失败页不会被跳过也不会重复；footer 重试按钮
（`:548`）先清 `_pageError` 再 `_loadMore()`，带 `_loading` 守卫，不会重复请求。
**用户可见后果**：网络抖动一次之后，列表底部会长期显示一个不该出现的「重试」按钮；且后续只能靠手动点它翻页
（滚动自动加载再也不会回来）。属「修复不完整」，不是数据重复。

### 路径 8：播放页 / 歌词（R-01 CurvedAnimation）

**复核通过。** `_fadeCtrl` 与 `_fadeCurve` 都在 State 里 `late final` 创建一次，`dispose` 中按
「先 CurvedAnimation、后 AnimationController」的顺序释放，`AnimatedSwitcher` 的两个分支各带稳定 `ValueKey`
（`'lyric'` / `'cover'`），歌词模式随进度每帧重建时不再新建监听器。无回归。
（`lyric_view.dart` 全文复核：`_pendingRebuild` 一帧只排一次回调、`_scrollTo` 有 `hasClients` 守卫、
`dispose` 释放 `ScrollController`，与 R-01 无关的旧问题不在本报告范围。）

---

## 三、问题清单

| # | 编号 | 级别 | 位置 | 事实 | 违反 | 用户可见后果 |
|---|---|---|---|---|---|---|
| 1 | P0-1 | **P0** | `core/api/kugou_api_client.dart:131/160/166` | 新增 `debugPrint` 但未 import `flutter/foundation.dart`（该文件 4 个 import 全为非 Flutter 库） | 28/29（兼第 9 条自相矛盾） | `flutter analyze` 报 undefined function，CI 红，**无法构建 APK** |
| 2 | P3-1 | P3 | `kugou_api_client.dart:120-133 / 227` | `try/catch` 包住不触盘的构造函数，真实失败点在 `saveFromResponse`；`jar is! PersistCookieJar`（`:165`）恒假 | 11、32 | 只读目录时登录抛原始英文 `FileSystemException` |
| 3 | P3-2 | P3 | `kugou_api_client.dart:146-166` | 注释称「路径就绪后自然切到持久化」，但实例在构造时已固定 jar；未就绪分支每次新建 jar（不再共享） | 31、5 | 当前仅 1 个实例，影响≈0；误导后续维护者 |
| 4 | P3-3 | P3 | `direct/kg_providers.dart:88-97` | Hive 同步写与 `SecureStorage.saveDfid` 异步写无顺序保证 | 5 | 极端情况下重启后两处 dfid 再次分裂 |
| 5 | P1-1 | **P1** | `core/storage/secure_storage.dart:64-75` + `auth_repository.dart:66-78 / 305-318` | 登出删除 dfid，Hive 不删；重登经 kapi `/register/dev` 生成新 dfid | 5、20、27 | 每次退出重登被判新设备：风控验证、试听降权、画像清零；冷启动设备标识来回跳变 |
| 6 | 连带 | **P1** | `auth/data/verification_service.dart:34` | `buildSidEdt` 用 SecureStorage dfid（缺失→'0'），业务请求用 `kg.device.dfid` | 8、5 | 登出后命中 20028 时 edt 用 '0'：验证通过后重试仍被拦，陷入「验证→失败」循环 |
| 7 | P3-4 | P3 | `settings_page.dart:374-376` + `auth_repository.dart:296` | 退出后账号记录仍留在列表；点切换 → StateError → 记录被删除 | 16 | 刚退出的账号以「可用」出现在列表里，点一次即被永久删除（昵称/头像历史丢失） |
| 8 | P2-1 | P2 | `auth_repository.dart:286-302` | 只删当前账号的 `acct_token_*`，其余账号 token 保留 | 5、11 | 共享设备上 A 退出后，他人登录新账号即可看到并一键登入 B（原安全残留半修） |
| 9 | P3-5 | P3 | `auth_repository.dart:288-296` | `removeAccount: true` 无任何调用方；其内 `deleteAccountToken` 与新 `clearCredentials(userid:)` 重复 | 32 | 无直接用户后果 |
| 10 | P1-2 | **P1** | `player/data/audio_handler.dart:388-395` + `:462` | 失败分支先 `pause()`（内部 `_playToken++`），再比较 `token == _playToken` → 恒假 | 18、19、11 | 遇到无版权/解析失败的歌直接停播，不再自动跳下一首；连播断裂 |
| 11 | P1-3 | **P1** | `playlist_detail_page.dart:49 / 312-334` | 全局非 autoDispose 锁；`finally` 在已销毁 Element 上 `ref.read`（riverpod 2.5.1 抛 StateError） | 20、19、21 | 收藏后立刻返回 → 锁永久为 true → 所有歌单收藏静默无反应，直到重启 |
| 12 | P2-2 | P2 | `playlist_detail_page.dart:45/69/281-330` + `playlist_repository.dart:133` | `_tracksReloadProvider` 无人写入；「加载更多/截断提示」整块缺失；我的歌单 `pageSize=300` 单页 | 32、16 | 超过 300 首的「我的歌单」尾部歌曲看不到且无任何提示 |
| 13 | P2-3 | P2 | `search_page.dart:487/491/473-483` | 分页失败同时置 `_error` 与 `_pageError`；成功分支不清 `_pageError` | 9、16、31 | 首屏失败重试成功后底部仍显示「重试」；分页失败后滚动自动加载永久失效 |

## 四、统计

| 维度 | 结果 |
|---|---|
| 审查文件 | 10（全部完整通读，共 3 764 行） |
| 新增提交 | 5（第 6 批） |
| 复核通过项 | B-07 时序本体、B-10 写法、R-26/27、R-28、R-01、V3-13 开闸策略 |
| 回归 / 新引入 | 3（P0-1 编译错误；P1-2 闸门连带回归，源自第 5 批 V3-02/V3-13、终审确认未修复；P1-3 全局锁） |
| 修复不完整 | 4（P1-1／连带／P2-1 属 B-11；P2-2 属 V3-14；P2-3 属 R-29） |
| 级别分布 | **P0 × 1 · P1 × 4 · P2 × 3 · P3 × 5 = 13** |
| 发布判定 | **阻断**（P0 必须先修） |

## 五、放行前最小修复集

1. `kugou_api_client.dart` 补 `import 'package:flutter/foundation.dart';`（或删掉三处 `debugPrint`）——**唯一硬阻断**。
2. B-11 改法：登出**保留 dfid**（它属于设备，不属于账号），并把 `getDfid()` 的首选数据源改为 `KgDeviceStore`／
   `kg.device.dfid`，去掉正常登录路径上的 kapi `/register/dev`；`buildSidEdt` 与 `KgClient` 共用同一权威值。
3. `audio_handler` 失败分支不要走会作废世代的 `pause()`（或先算 `canAdvance` 再 pause）。
4. `_collectingProvider` 改为 `autoDispose` 且 `finally` 里改用 `try/catch` 包裹的 `ref` 访问；或退回页面级
   `StatefulWidget` + `setState` 的锁。
5. R-29：成功分支清 `_pageError`；分页失败不要复用 `_error`（或改为 `_error = _items.isEmpty ? e : null`）。

---

## 附录：审查期间工作区并发改动核对（HEAD `cce8178`，非本报告基线）

> 本报告全部结论基于基线 `722f2bb`（tag v3.2.0）。审查结束时工作区已被并行修复推进到
> `cce8178`（`3.2.1+33`），据此复核这 5 项修复是否真正落地，供放行判断参考。

| 修复 | 落地情况 | 结论 |
|---|---|---|
| F-1 `debugPrint` 导入 | `kugou_api_client.dart:4` 已补 `package:flutter/foundation.dart` | **通过**，P0 解除 |
| F-2 登出保留 dfid | `secure_storage.dart` 已删掉 `_kDfid` 的 delete，凭证四键与 `acct_token_*` 仍清 | **通过**，P1-1 与验证死循环解除（`getDfid` 不再走 kapi 常规路径） |
| F-3 `_pauseEngineOnly` | 失败分支改为不作废世代的 `_pauseEngineOnly()`，`canAdvance` 恢复有效 | **通过**，P1-2 解除 |
| F-5 分页失败态收敛 | 成功清 `_pageError`；失败按 `_items.isEmpty` 分流到 `_error` / `_pageError` | **通过**，P2-3 解除 |
| F-4 收藏锁 | `finally` 改用 notifier 快照复位（不再触 `ref`），卡死路径已消除；但**声明仍是 `StateProvider<bool>((ref) => false)`，没有 `.autoDispose`**，注释却写「**autoDispose**——让锁与页面共存亡」 | **半修**：功能上卡死已解决，但注释与代码不符（第 31 条）；锁仍是进程级单例 → 在 A 收藏请求飞行中切到 B 点收藏，最长 20 秒内仍会被静默忽略。建议把声明改成 `StateProvider.autoDispose<bool>((ref) => false)`（此时 `lock.state = false` 在 provider 已销毁时会抛异常，但已被现有 `try/catch` 吞掉，锁随 provider 销毁即为初始 false，行为正确） |

另：`pubspec` 已 bump 到 `3.2.1+33`，与已发布的 `v3.2.0` tag 不同，release note 与 tag 需重新对齐。
