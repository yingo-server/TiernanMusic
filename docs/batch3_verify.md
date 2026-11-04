# 第3批 · 复查（只读）：修复验证 + 全局交叉

- 复查基线：`96cd0b8`（工作区干净，`git status` 无改动）
- 对照材料：`docs/batch1_review_2_core.md`、`docs/batch1_review_3_player.md`、`docs/batch2_review_1_auth.md`、`docs/batch2_review_2_ui.md`、`docs/batch2_review_3_download.md`
- 被验证提交：`6efeff7`（认证 5 项）、`b64ab3f`（UI 5 项）、`8f9c7c9`（下载 8 项）、`96cd0b8`（openWrite 收尾）
- 方式：逐行静态阅读 + 交叉引用；**未构建、未运行测试、未安装任何依赖、未修改任何源文件**。仅使用环境中已存在的 Dart 3.13 执行 `dart format --output=none` 做纯解析（不落盘，事后 `git status` 为空）；重复 `catch` 的可达性用同版本 `dart analyze` 在临时片段上确认。
- 本文只记录问题与判定依据，不含修复方案。

---

## 一、结论总表

| 编号 | 声称的修复 | 判定 | 一句话结论 |
|---|---|---|---|
| A2-01 | 20028 的 ssaCode 兜底 | **通过（有残留）** | 直连包装异常可取出 ssaCode，密码登录可进验证页；`status=1+data` 的 20028 变体仍未覆盖 |
| A2-02 | “部分修复”验证提交参数 | **未修复** | 提交说明与代码不符：`_verifyUserInfo(d)` 仍只吃 body，`query` 仍被丢弃 |
| A2-03 | SID OAEP SHA-1 → SHA-256 | **通过（依赖 API 无法离线复核）** | 代码已用 `OAEPEncoding.withSHA256`；pointycastle 源码不在环境内，未能编译验证签名 |
| A2-07 | `unwrapApi` 统一解包 | **部分** | 登录页/评论页已解包；评论页留下不可达的第二个 `catch`；仍有 `'$e'` 直出与私有解包副本 |
| A2-09 | 20010 移出 token 失效名单 | **通过** | 名单已改为 `{1011,30791,401}`，降级路径保持会话 |
| UI-01 | 骨架屏三处 Row → 横向 ListView | **通过** | 三处均已替换，360dp 溢出消除 |
| UI-02 | 榜单错误态 + 重试 | **部分** | 请求抛错可重试；**空结果成功**仍永久转圈 |
| UI-03 | 我的歌单“播放全部”数据源对齐 | **部分** | 播放源已对齐；同页错误重试仍 invalidate 另一个 provider，用户歌单重试无效 |
| UI-04 | 评论入口不再被 MV 连带隐藏 | **通过（有前提）** | MV 条件已解耦；`albumAudioId` 为空时整块仍 early return |
| UI-05 | 进度条拖动本地值 | **部分** | 逐帧 seek 已停；`_dragMs` 未夹取上界，时间文本不跟随拖动值 |
| UI-08 | 轮播后台停翻页 | **部分** | 仅接入 App 生命周期；Tab 可见性仍只靠 `ModalRoute.isCurrent`，IndexedStack 下无效 |
| DL-01 | 试听片段拒载 | **通过（有误杀）** | `isPreview` 抛错；`end_ms<=65000` 会把 <65s 的正片当试听 |
| DL-02 | 扩展名/MIME 按服务端 | **未生效** | 只改临时文件名；发布名与 MIME 仍硬编码 `.mp3`/`audio/mpeg`；且把音质 token 当后缀用 |
| DL-03 | 重复下载取消旧任务 | **部分** | 网络阶段可取消；发布阶段无归属校验，仍可改写新任务 |
| DL-04 | 旧请求异常/槽位归属校验 | **回归（P0）** | 归属判断写反：正常情况下槽位永不释放，两次下载后队列彻底停摆 |
| DL-05 | 发布成功/删除时清临时文件 | **部分** | 发布成功路径可清；`remove()` 清理路径与实际临时文件不一致，易留孤儿 |
| DL-12 | `createdAt` 恒用 now | **通过** | 已改为 `createdAt: now` |
| PB-01 | 降级发布改流式复制 | **部分** | 不再整文件读入，但 `IOSink.add` 无背压，异常时残留半文件 |
| 96cd0b8 | `openWrite` 去 flush 参数 | **通过** | Dart SDK 确认 `openWrite` 无 `flush` 形参；显式 `flush()` 在 close 前 |

**本批新发现的阻断级问题：V3-01（下载并发槽泄漏，P0）。其余 15 项见第三节。**

---

## 二、逐项验证详情

### A2-01 直连 20028 的 ssaCode 兜底 —— 通过（有残留）

- 现状：`auth_repository.dart:366-382` 的 `_errorResponseData` 新增 `e.error is ApiException → {'ssaCode': err.ssaCode}`；`loginByPassword`（`:134-137`）据此抛 `CaptchaRequiredException`，登录页 `login_page.dart:396-406` 在 `ssaCode` 非空时打开 `CaptchaPage`。
- 链路闭合：`kg_client.dart:60-61` 有 `ssaCode` 取值（body `ssaCode`/`ssa_code`、响应头 `ssa-code`），`:249-251` 已将 header 名统一小写；`kg_direct_api_client.dart:71-115` 的 `_wrap` 把它塞进 `ApiException`，`:152-160` 再包成 `DioException(error:)`。
- 残留问题：
  1. `_wrap`（`kg_direct_api_client.dart:78-84`）在 `status == 1` 且 `data` 非空时**直接返回 body、不抛异常**。若登录风控以 `status=1 + data{ssaCode}` 形态返回，`loginByPassword` 不会进入 20028 分支，转而由 `_handleLoginSuccess` 抛 `ApiException(-1, '登录响应缺少 token 或 userid')`，验证页仍不弹（与 A2-02 报告里“status=1 假成功”同一语义）。
  2. `_errorResponseData` 的兜底只映射 `ssaCode` 一个键，未携带 body；因此同一 helper 的另一个调用点（20034 多账号）仍旧拿不到 `data.users`（见 V3-13）。
  3. `login_page.dart:397` 的 `e.ssaCode.isEmpty` 分支仍只 toast；`_showError` 对 `CaptchaRequiredException` 走 `friendlyError` → 最终是 `'$e'`（`CaptchaRequiredException(...)` 技术串）。

### A2-02 验证提交参数 —— 未修复（提交说明不实）

- `6efeff7` 的提交说明写“A2-02 部分修复：验证提交参数经 _api.post 命中直连层”，但该提交只改了 5 个文件（`friendly_error`/`auth_repository`/`edt_generator`/`login_page`/`comments_page`），`verification_service.dart`、`kg_direct_api_client.dart`、`kg_endpoints_auth.dart` 均未在 diff 内；`git log` 显示这三个文件自 `5409ec3` 起无改动。
- 现状仍是原缺陷：`verification_service.dart:57-80` 把 `eventid/v_type/sid/edt/verifycode` 全放 `query`、body 传 `{}`；`kg_direct_api_client.dart:341-343` 的 `case 'verify/user/info'` 仍调用 `_verifyUserInfo(d)`（`d` 恒为 `{}`）；`kg_endpoints_auth.dart:331-345` 仍只读 `d`。
- 结论：直连分支仍以空 eventid 发一次无效请求，验证实际依赖 kapi 回退；且若上游对空参返回 `status=1 + data`，`verification_service.dart:68-74` 的 `submit` 会误判通过。

### A2-03 SID OAEP 摘要 —— 通过（依赖 API 无法离线复核）

- `edt_generator.dart:271` 已为 `OAEPEncoding.withSHA256(RSAEngine())`，注释与上游 `generate_simulate.js` 口径一致；文件内无其它 SHA-1 OAEP 残留。
- 限制：环境中无 pub 缓存、无 `pointycastle` 源码，`pubspec.yaml` 也未提交 lock，无法验证 3.9.1 是否确有该工厂名与 MGF1 摘要联动；本次只能确认代码形态正确。

### A2-07 unwrapApi 统一解包 —— 部分

- 已生效：`friendly_error.dart:10-20` 新增 `unwrapApi`；`friendlyError` 改为先解包（`:23-31`）；`login_page.dart:160-165`、`comments_page.dart:378` 已使用。
- 问题：
  1. `comments_page.dart:375-410` 出现**两个连续的 `catch (e)`**（第二处 `:406`），Dart 允许该语法但第二段不可达；等价的 analyzer 诊断是 `dead_code_catch_following_catch`（已在 SDK 3.13 片段上复现）。CI 用 `--no-fatal-warnings`，不会拦下，但这使“统一解包”的注释与代码结构都对不上。
  2. 同一个 catch 里失败提示仍是 `context.l10n.commentFailed('$e')`（`:399`、`:404`、`:408`），直连异常会显示 `DioException [bad response]...` 技术文本；`e0` 解包结果只用于 20028 判定，未用于文案。
  3. 其它页面仍在裸出异常或自带解包：`playlist_detail_page.dart:311`（`operateFailed('$e')`）、`audio_handler.dart:366-372`（自写 `_extractApiException`，与 `unwrapApi` 重复）、`verification_guard.dart:27-28`（只接 `on DioException`，裸 `ApiException` 不处理）。
  4. `friendlyError` 的 `switch` 同时删掉了 `20010` 的“登录已过期”映射——本身与 A2-09 一致，但意味着 20010 的文案完全取决于服务端 message；直连端点多数 20010 响应无 `error` 字段时，上屏为“未知错误”。

### A2-09 20010 不再清会话 —— 通过

- `auth_repository.dart:262-269` 名单为 `{1011, 30791, 401}`，并保留 `code == -1 && message.contains('token')` 的旧判定（该判定仍可能把 `-1/token` 类参数错误当失效，属残留但非本项范围）。
- `restoreSession`（`:219-245`）在非网络错误且 `confirmedInvalid` 为假时走 `_degradedUser`，凭证保留，逻辑自洽。

### UI-01 首页骨架横向溢出 —— 通过

- `home_page.dart:561-604` 三处 `Row` 均已换成 `ListView.separated(scrollDirection: Axis.horizontal)`，外层 `SizedBox(height:)` 提供有界高度，位于 `CustomScrollView → SliverToBoxAdapter → Column` 内，无高度/宽度约束冲突。

### UI-02 榜单错误态 + 重试 —— 部分

- 已生效：`rank_detail_page.dart:50-54` 记录 `_error`，`:108-126` 渲染“加载失败 + 重新加载”，按钮清空 `_error` 后重调 `_load()`。
- 问题：`_load()` 成功但返回空列表时（`total=0` 或服务端空页），`_songs.isEmpty && _error == null` 仍命中 `CircularProgressIndicator`（`:127`），即“空结果成功”依旧是永久转圈；`_load()` 成功分支也未清 `_error`（`:36-47`）。
- 分页失败仍静默（`:60-66`），与本项无关，但同一页面仍存在“尾部无重试”的旧问题。

### UI-03 “播放全部”数据源 —— 部分

- 已生效：`playlist_detail_page.dart:192-206` 按 `userListId` 选择 `userPlaylistTracksProvider` / `playlistTracksProvider`，与页面顶部 `:60-63` 一致。
- 问题：同页列表错误态的 `onRetry: () => ref.invalidate(playlistTracksProvider(id))`（`:224`）没有跟随数据源切换。用户歌单（`userListId` 非空）加载失败后点“重试”，invalidate 的是从未被监听的 `playlistTracksProvider(id)`，用户歌单 provider 仍是 error，界面停在错误态——修复只覆盖了播放按钮，没覆盖重试。

### UI-04 评论入口 —— 通过（有前提）

- `full_player_page.dart:276-321`：评论按钮在 MV 判定之前，MV 仅 `hasMv` 时追加；不再因为“无 MV”而整块消失。
- 前提：`:278-279` 仍保留 `albumAudioId.isEmpty → SizedBox.shrink()`。无 `album_audio_id`/`MixSongID` 的曲目（部分搜索/本地条目）播放页依旧没有评论入口，与“评论始终显示”的提交描述不完全一致；另外 `songMvProvider` 仍会为每首歌发一次 MV 查询（与旧实现相同）。

### UI-05 进度条拖动 —— 部分

- 已生效：`full_player_page.dart:461-515` 改 `ConsumerStatefulWidget`，`onChanged` 只改 `_dragMs`，`onChangeEnd` 才 `seekTo`，逐帧 seek 已消除。
- 问题：
  1. `value: _dragMs ?? posMs`（`:503`）未对 `_dragMs` 做 `clamp(0, maxMs)`；`maxMs` 来自 `durationProvider`，切歌/时长回填时可变。拖动中若曲目结束自动切到更短的歌，`_dragMs > maxMs` 触发 Slider 断言（`value` 必须 ≤ `max`）。
  2. 下方时间文本仍是 `_fmt(position)`（`:520`），拖动过程中不跟随滑块，用户拖动时看到的秒数不变化。
  3. `_dragMs` 没有在歌曲变化时重置（无 `didUpdateWidget`），只靠 `onChangeEnd` 清理。

### UI-08 轮播后台/切 Tab 停翻页 —— 部分（Tab 部分未实现）

- 已生效：`home_page.dart:123-166` 混入 `WidgetsBindingObserver`，`_visible` 由 `didChangeAppLifecycleState` 维护，定时器回调据此跳过（`:147`），dispose 时移除 observer。
- 未生效：注释自己写明“IndexedStack 下 isCurrent 无法表达 Tab 可见性”（`:128-129`），但 `:148-150` 仍把 `ModalRoute.of(context)?.isCurrent` 当作 Tab 可见性判据；`StatefulShellRoute.indexedStack` 的非活动分支仍保留自己的 Navigator 栈，其 page route 仍是栈顶，`isCurrent` 为 true。`_visible` 只覆盖 App 前后台，不覆盖 Tab 切换，所以“首页切走后停止翻页”没有实现（静态推断，未真机验证）。
- 另：`didChangeAppLifecycleState` 不 `setState` 也不重建定时器，恢复后最多空转 4s，属可接受范围。

### DL-01 试听片段拒载 —— 通过（有误杀）

- `download_repository.dart:59-70`：`result.isPreview` 时抛 `StateError`，`isPreview` 定义见 `kg_play_api.dart:265-266`（`end_ms<=65000` 或 URL 含 `/p_0_`）。
- 问题：`end_ms <= 65000` 对时长本就短于 65 秒的正片（intro/skit/短曲）同样成立，会给出“仅获取到试听片段/需要会员”的错误文案，且 `failProcess` 为空时文案与真实原因不符。
- 另：`resolveAudioUrl` 先判 `bestUrl` 是否为空、后判 `isPreview`，试听 URL 非空时正常走到拒载，顺序无问题。

### DL-02 扩展名与 MIME —— 未生效

- 只改临时文件：`download_provider.dart:298-316` 用 `resolveAudioExt` 算出 `ext` 并替换临时路径后缀；`download_repository.dart:75-96` 的实现把 `result.extName` 原样当扩展名，仅在为空/`mp3` 时从 URL 兜底。
- 发布端未改：`DownloadRepository.displayNameOf`（`:217-228`）仍拼 `task.type.fileExtension`（audio 恒 `.mp3`，`download_task.dart:21-26`）；`PublicMediaStore.mimeOf`（`public_media_store.dart:41-47`）audio 恒 `audio/mpeg`；MediaStore insert 用的就是这两者（`:80-92`）；`_publishDirect` 目标文件名同样是 `displayName`（`:168-170`）。**公共目录里的最终文件仍是 `xxx.mp3` + `audio/mpeg`**，报告要求的“无损落 .flac / 正确 MIME”没有达成。
- 另：`extName` 在本仓库一直被当音质 token 用（`player_repository.dart:210-212` 直接喂 `AudioQuality.fromString`，取值 `128/320/flac/high/super`，见 `models.dart:5-11`），而 `resolveAudioExt` 无白名单地拼成 `'.' + ext`。一旦 `extName='320'`（320k 档常见）临时文件就是 `hash_audio.320`；`'super'` 会得到 `.super`。这既不是音频后缀，也让临时文件与清理逻辑脱节（V3-04）。

### DL-03 同 id 重复下载取消旧任务 —— 部分

- 已生效：`download_provider.dart:103-112` 对正在运行的同 id 任务 `cancel('re-added')`、移除 token 与 `_running`；`createdAt` 改为 `now`（`:113-118`）。
- 问题：
  1. 只取消网络请求。旧 `_run` 若已进入“发布”阶段（`:338-370`，`publish` 不接收 token），取消无效；发布完成后 `_find(task.id)` 拿到的是**新任务**，`:353-369` 无 token 归属校验，直接把新任务标 `completed` 并写入旧文件信息——原缺陷在发布窗口内仍成立。
  2. `:109` 立刻 `_running.remove(task.id)` 后 `_schedule()` 会启动新任务，而旧任务仍在运行/发布；该 id 的并发占用从 1 变成 2，实际并发可超过 `maxConcurrent=2`。
  3. 新旧 `_run` 共用 `_tokens[task.id]`，旧任务的 `onProgress`（`:277-288`）只检查 `status == running`，不校验 token；新任务进入 running 后，旧任务迟到的进度回调会覆盖新任务进度。

### DL-04 取消异常与槽位归属 —— 回归（P0）

- 目标部分生效：`DioException` 分支新增 `if (_tokens[task.id] != token) return;`（`:373-375`），旧 `_run` 的取消异常不再污染新任务。
- **回归**：`finally`（`:400-409`）先执行 `if (_tokens[task.id] == token) _tokens.remove(task.id);`，随后判断 `if (_running.contains(task.id) && _tokens[task.id] != token)`。正常完成时 token 已被移除，`_tokens[task.id]` 为 null，条件恒真，于是走“新 _run 已接管”的空分支，**`_running.remove(task.id)` 永不执行**。
- 后果：每完成一个任务就泄漏一个并发槽。`_schedule()` 以 `_running.length < 2` 为门槛（`:253`），两次下载后 `_running.length == 2`，此后任何 `queued` 任务都不会启动；同时 `_schedule` 的 `! _running.contains(t.id)` 也阻止同 id 重下。用户侧表现为“下载完两首后，队列全部停在等待、进度不动”。只有 `pause/remove/clearAll/add(同 id 运行中)` 才会清槽。

### DL-05 临时文件清理 —— 部分

- 已生效：发布成功且任务仍在列表时 `realTempPath` 被删（`download_provider.dart:355-362`）。
- 问题：
  1. `remove()` 的清理路径是 `'${task.hash}_${task.type.name}${task.type.fileExtension}'`（`:180-186`），即恒为 `.mp3`；而 DL-02 之后实际临时文件可能是 `.flac`/`.320`（`:309-316`），删除任务的清理对这类文件完全落空。
  2. 删除/清空按 `task.hash` 命名而非任务 id，同 hash 不同音质（DL-10）会互删；这一条在 DL-02 改动后更容易触发。
  3. 发布成功但 `_find(task.id) == null`（下载中被删除）时，临时文件与刚发布的公共文件都无人管理：`:353-369` 的清理在 `if (cur != null)` 内。

### DL-12 createdAt —— 通过

- `download_provider.dart:113-118` 恒用 `now`，不再出现 `createdAt: 0`。

### PB-01 降级发布流式复制 —— 部分

- 已生效：`public_media_store.dart:148-162` 由 `readAsBytes` 改为 `openRead` + `openWrite` 分块写，不再一次性把整个文件读入内存。
- 问题：
  1. `outRaf.add(chunk)` 在 `await for` 内没有等待下游消费，`IOSink` 的写缓冲没有背压；输入读取与磁盘写入速率不匹配时，块会堆在 sink 内部缓冲区，理论上仍可累积到与整文件同量级，OOM 风险只是被削弱而非消除；`IOSink.add` 与 `addStream` 的背压语义差异在本实现中未被利用。
  2. 复制中途抛异常时，`finally` 只 `close()`，已写入公共目录的半文件不会删除；调用方（`publish`）也没有兜底清理，会在公共目录留下不可见/损坏文件。
  3. 未校验源文件存在：源临时文件缺失时 `openRead` 直到流监听才抛错，错误点从“明确前置检查”变为写入中途。

### 96cd0b8 openWrite flush —— 通过

- 现行代码 `public_media_store.dart:151` 为 `openWrite(mode: FileMode.write)`，`flush()` 在 `close()` 前显式 await（`:155-157`）；Dart SDK 3.13 的 `File.openWrite({FileMode mode, Encoding encoding})` 确无 `flush` 形参，该收尾提交方向正确，编译面无问题。

---

## 三、新发现问题（按严重度）

### V3-01（P0）下载并发槽永不释放，两次下载后队列停摆
- 位置：`lib/features/download/download_provider.dart:400-409`（`_run` 的 `finally`），配合 `:253-261`（`_schedule`）与 `:59`（`_running`）。
- 证据链：正常完成 → `:401` 删除 token → `:404` 的条件用 `null != token` 恒真 → 空分支 → 不删 `_running`。`_running` 仅由 `pause`（`:136`）、`remove`（`:171`）、`clearAll`（`:207`）、`add` 重下（`:109`）移除。
- 影响：单进程内最多成功调度 2 个任务；第 3 个起永远停在 `queued`，下载页只有“等待”无进度；`resume/retry` 也无效。属于本批修复引入的功能性阻断。

### V3-02（P1）DL-02 未改变发布结果，且把音质 token 当文件后缀
- 位置：`download_repository.dart:75-96`、`:217-228`；`public_media_store.dart:41-47`、`:80-92`、`:160-172`；`download_provider.dart:298-316`。
- 问题：临时文件名按 `extName` 变化，发布名与 MIME 完全未变；`extName` 在本仓库语义是音质（`128/320/flac/high/super`），无白名单拼接会产出 `.320`/`.super` 之类的临时文件。
- 影响：无损下载仍是 `xxx.mp3`+`audio/mpeg`（原缺陷原样保留）；临时文件出现非法后缀；清理、重下、按 hash 的互删逻辑随之错位。

### V3-03（P1）重复下载的“发布阶段”仍会改写新任务，并突破并发上限
- 位置：`download_provider.dart:103-112`、`:338-370`。
- 问题：`publish` 不吃 token，完成后无 `_tokens[task.id] == token` 校验；`add` 提前释放槽位。
- 影响：旧任务完成会把新任务标记 completed 并写入旧文件；同 id 新旧任务并行，实际并发可 >2。

### V3-04（P1）删除任务的临时文件清理路径与实际文件不一致
- 位置：`download_provider.dart:179-186`（恒 `.mp3`）对照 `:309-316`（`realTempPath` 可为 `.flac/.320`）。
- 影响：删除/清空后临时文件残留，长期占用双份空间（原 DL-05 想解决的问题在非 mp3 场景下反而更严重）。

### V3-05（P1）A2-02 声称的“部分修复”在代码中不存在
- 位置：`verification_service.dart:57-80`、`kg_direct_api_client.dart:341-343`、`kg_endpoints_auth.dart:331-345`；`git log` 证明三文件自 `5409ec3` 未变。
- 影响：验证链路仍依赖 kapi 回退；提交记录与真实状态不一致，后续复查会误判“已验证”。

### V3-06（P2）我的歌单错误态重试指向错误 provider
- 位置：`playlist_detail_page.dart:60-63`（watch `userPlaylistTracksProvider`）、`:224`（invalidate `playlistTracksProvider`）。
- 影响：用户歌单加载失败后“重试”无效，只能退出页面重进。

### V3-07（P2）UI-08 的 Tab 可见性判断仍是无效判据
- 位置：`home_page.dart:128-129`（注释）、`:148-150`（`isCurrent`）。
- 影响：首页切到其它 Tab 后轮播继续 4s 一次 `animateToPage`/`setState`，与“Tab 切走停止”的声称不符（静态推断）。

### V3-08（P2）拖动值未夹取、时间文本不跟随
- 位置：`full_player_page.dart:461-515`、`:520`。
- 影响：切歌/时长变化时可触发 Slider 断言；拖动时显示的仍是播放位置，不是落点时间。

### V3-09（P2）评论页重复 `catch` 为死代码，错误文案仍裸出异常
- 位置：`comments_page.dart:375-410`（第二个 `catch` 在 `:406`）。
- 影响：analyzer `dead_code_catch_following_catch`；失败提示仍是 `DioException...` 技术串，与 A2-07 的目标“表现层不得 `'$e'` 上屏”相悖。

### V3-10（P2）流式复制的写入端无背压、失败留半文件
- 位置：`public_media_store.dart:148-162`。
- 影响：大文件（MV/无损）仍可能因 sink 缓冲堆积而内存走高；磁盘满/中断时公共目录残留半文件，且无清理。

### V3-11（P2）每个音频下载多一次 `songUrl` 解析
- 位置：`download_provider.dart:301-316`（先 `resolveAudioUrl` 再 `resolveAudioExt`，后者内部再次 `api.songUrl`）。
- 影响：请求量翻倍；两次解析可能命中不同 CDN/风控结果，扩展名与实际 URL 可能不符；首次解析成功、第二次失败会让本可完成的下载直接失败。

### V3-12（P2）榜单“空结果成功”仍永久转圈
- 位置：`rank_detail_page.dart:37-47`、`:108-127`。
- 影响：接口正常返回空列表时，`_error == null && _songs.isEmpty` 永远落在 `CircularProgressIndicator`，用户无法区分“加载中”和“没有数据”。

### V3-13（P2）A2-04 多账号弹层仍不可达（与本次改动的 helper 同源）
- 位置：`auth_repository.dart:103-113`（读 `data['data']['users']`）、`:366-382`（兜底只造 `{'ssaCode': ...}`）、`kg_direct_api_client.dart:152-160`（20034 不回退）。
- 影响：直连路径下 20034 仍被 `rethrow`，账号选择框永不出现；本次改动触及了同一 helper，但没有改变该分支的取值。

### V3-14（P2）解包/文案统一仍有漏网
- 位置：`verification_guard.dart:27-28`（只接 `DioException`）、`audio_handler.dart:366-372`（私有 `_extractApiException`）、`playlist_detail_page.dart:311`、`comments_page.dart:399/404/408`。
- 影响：同一异常在不同入口有不同表现；裸 `ApiException` 在 `runWithVerification` 中直接穿出，20028 不会弹验证页（当前该方法无调用点，属潜伏问题）。

### V3-15（P3）试听判定误伤 65 秒以内的正片
- 位置：`kg_play_api.dart:265-266`、`download_repository.dart:60-70`。
- 影响：短曲/纯音乐被拒载，提示“需要会员”，与真实原因不符。

### V3-16（P3）20028 在 `status=1 + data` 形态下绕过验证
- 位置：`kg_direct_api_client.dart:78-84`、`auth_repository.dart:132-138`。
- 影响：验证页仍可能不弹，且 `_handleLoginSuccess` 会以“登录响应缺少 token”收场，用户看不到验证入口。

---

## 四、交叉影响（与本批改动交界、仍未闭合的既有 P1）

| 既有编号 | 与本批的关系 | 现状证据 |
|---|---|---|
| A2-02（P1） | 被 `6efeff7` 声称部分修复 | `verification_service.dart:57-80` + `kg_direct_api_client.dart:341-343` 未变（V3-05） |
| A2-04（P1） | 与 A2-01 共用 `_errorResponseData` | 兜底只带 `ssaCode`，`users` 仍取不到（V3-13） |
| A2-11（P1） | A2-07 解包后短信 20028 文案可读，但仍无验证入口 | `login_page.dart:229-252` 只 `_showError`，无 `CaptchaPage` 分支 |
| PL-01（P1） | 与 DL-02/05 同属下载产物可用性 | `audio_handler.dart:276-293` 只判 `File.existsSync()`；`content://` 不做存在性校验，失效后 `setAudioSource` 抛错直接跳下一首，不回退在线解析 |
| UI-32（P2） | 与 UI-02 同页 | `rank_detail_page.dart:60-66` 分页失败静默，无尾部重试 |
| DL-10（P2） | 与 DL-02/05 叠加 | 任务 id 与临时文件名都不含音质，重下同 hash 会覆盖 |
| C-19（P1，依赖单向） | 本批新增 `friendly_error` 依赖 `kugou_api_client` 属 core 内部，未恶化 | — |

---

## 五、复查覆盖与限制

- 逐行阅读：`download_provider.dart`（全 430 行）、`download_repository.dart`、`public_media_store.dart`、`download_task.dart`、`auth_repository.dart`（登录/恢复段）、`verification_service.dart`、`kg_direct_api_client.dart`（get/post/异常包装/verify 分派）、`kg_client.dart`（请求与响应头）、`kg_endpoints_auth.dart`（login/verifyUserInfo）、`edt_generator.dart`（SID 段）、`login_page.dart`、`comments_page.dart`（发送段）、`full_player_page.dart`（入口/进度条）、`home_page.dart`（Banner/骨架）、`rank_detail_page.dart`、`playlist_detail_page.dart`、`public_media_store.dart`、`verification_guard.dart`、`verification_listener.dart`、`audio_handler.dart`（离线/失败分支）。
- 未执行：任何构建、`flutter analyze`、单元/Widget 测试、真机运行；`pointycastle` 与其余第三方包未安装，无法做类型级验证（A2-03、`openWrite` 之外的 SDK 面）。
- 解析级验证：`dart format --output=none` 全量扫描 `lib/`（99 文件）无语法错误；`dart format` 报告的 87 个“会重排”文件属历史格式差异，不是本批引入。未写盘，`git status` 保持干净。
