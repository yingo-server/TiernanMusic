## 反馈②：全部播放有问题 —— 链路全走查

### 链路
`play_helper.playSong` → `audio_handler._playAt` → `ensureEngineReady` → `player_repository.fetchDetail`（/privilege/lite）→ `player_repository.resolveUrl` → 直连 `KgPlayApi.songUrl`（trackercdn /v5/url）或回退 `_resolveViaKapi`（/song/url）→ `_applySource` → `player.play`。

### 各环节证据
1. **`ensureEngineReady`**：经 `AudioServiceBootstrap.ensureReady()` 惰性创建 `AudioPlayer`，`_engineReady` 流推送。生成前提与旧批一致，未见回归。**证据等级：静态推导**。
2. **`fetchDetail`（/privilege/lite）**：修复① E3 原生直连 `status` 正常、`relate_goods[]` 含 `ogg_128/320_hash`，链路工作。**证据等级：实测**。
3. **`resolveUrl` 直连分支**：`KgPlayApi.songUrl` → `KgSharedParams.songUrl`（hash 小写、key=`KgSignature.keyOf`、signature 由 `KgClient.request` 自动补）→ `client.requestWithVerify('/v5/url', baseUrl: trackercdn.kugou.com)`。**修复① E4 原生实测：带 android 签名 → `err signature`；未签名 → `err clientver or mid or dfid`；精确复刻 Node → 同样 dfid 类错误。trackercdn 对 /v5/url 原生直连必然失败，根因是缺真实已注册 dfid，非代码错配。** **证据等级：实测（原生直连，第 33 条合规）**。
4. **dfid 注册链路**：`PlayerRepository.ensureDfid` 仅走 **`_resolveViaKapi` 内的 kapi 回退路径**才会被调用（`resolveUrl` 直连成功时压根不 ensureDfid）。直连路径依赖 `KgPlayApi`/`KgClient` 持有的 `device.dfid`：冷启动首次若 `SecureStorage` 无 dfid 且设备注册尚未完成，则 `device.dfid=''`，请求里 `dfid` 用 `'-'` 占位 → 命中 trackercdn `err dfid`。**`device.dfid` 真实注册在 `KgClient.registerDevice`/`onDfidRegistered`（native 注册成功才写）**，但首播直连路径并未"先确保 dfid 再打直连"。**证据等级：静态推导 + 实测（E4 失败形态）**。
5. **签名维度一致性**：歌曲 `/v5/url` 用 `KgSignature.keyOf(hash,mid,userid,appid)` + android 全参签名；MV video url 用 trackermv `/v2/interface/index` 的 `key=keyOf(hash,mid,userid)`（无 signature 字段，仅 key）。两端点 key 盐一致（`KgCrypto.keyOf` 同函数），签名盐不同域名不同，但**歌曲端实测失败点是缺真实 dfid，不是 key 算法错**。**证据等级：静态推导**。
6. **cleartext 域名表**：`network_security_config.xml` 已放行 `*.kugou.com`/`tx/mobile/service/fsandroid/fsmvpc/kugouaudio.com`。`/v5/url` 返回 `http://fsandroid.kugou.com/...` 直连合规。**证据等级：静态推导**（E5 实测已确认放行覆盖）。
7. **试听判定对 VIP 误判**：`PlayUrlResult.isPreview` 判定 `endMs-startMs <=65000` 或 url 含 `/p_0_/`。`_resolveViaKapi` 用 `_int(data['priv_status'])==0 || data['hash_offset'] is Map` 判试听——`priv_status==0`（无权限标识）也被当试听，**属潜在误标（P2 旧债，非本次根因）**。注意直连分支与 kapi 回退分支试听判定逻辑不同源（第 5 条），前者按区间时长、后者按 priv_status，口径不统一。**证据等级：静态推导**。
8. **URL 失效重试通路**：`_resolveViaDirect` 按 `AudioQuality.fallbackOrder` 逐级降级，遇 `fail_process` 走 `freePart` 试听；直连抛非 20028 `ApiException` 时回退 `_resolveViaKapi`。通路完整。但**直连路径每次先打一发注定失败的 /v5/url**（缺 dfid 时），再回退 kapi，耗时+风控计数累加。**证据等级：静态推导**（与修复②定位呼应）。

### MV 正常而歌曲异常 — 差异点清单
| 维度 | 歌曲（/v5/url） | MV（video url） | 差异后果 |
|---|---|---|---|
| 域名 | trackercdn.kugou.com | trackermv.kugou.com | 两域风控/dfid 要求不同 |
| 鉴权 | signature（android 全参）必填 | 仅 key（keyOf），无 signature 字段 | 歌曲多一层签名校验面 |
| dfid 要求 | 实测缺真实 dfid 即 `err dfid` | 实测匿名/VIP 均 200 返回 downurl（api_verified 记录） | **MV 对 dfid 不敏感，歌曲敏感** ← 核心差异 |
| 重试/验证 | `requestWithVerify` 遇 20028 重试 | 同 | 一致 |
| 返回形态 | `url[]/backupUrl[]/hash_offset` | `data[hash].downurl/backupdownurl` | 解析分支不同 |
| 路由 | `KgPlayApi.songUrl` 直连优先 + kapi 回退 | `MvRepository.resolvePlayUrl` → `_api.get('/video/url')` 单路径 | 无"直连必失败→回退"问题 |

**核心差异结论**：MV 走 trackermv 且对 dfid 不敏感（匿名态实测可下）；歌曲走 trackercdn 且**必须有真实已注册 dfid**，而首播直连路径未先 `ensureDfid`，故歌曲 100% 失败、MV 正常。**证据等级：实测 + 静态推导**。

### 修复不完整点（与修复②呼应）
- **P1｜`player_repository.resolveUrl` 直连前未先 `ensureDfid()`**：直连 `KgPlayApi.songUrl` 依赖 `device.dfid`，但 `ensureDfid` 只在 kapi 回退分支被调用。冷启动首播若 device.dfid 为空，直连必以 `err dfid` 失败再回退 kapi（kapi 路径本身能注册 dfid）。修复②仅"定位未改"，代码承接不完整（第 28 条：已知签名维度缺失仍发出必失败请求；第 11 条：降级触发条件未显式）。**建议：直连分支进入前先 `await ensureDfid()`，并把它注册得到的 dfid 同步回 `kg.device.dfid`/`kg.dfid`（已有 PLY-12 setCredentials 同步机制可复用）**。

---

## 反馈③：第一屏动画可用性 —— 真实冷启动时序走查

### 时序
`main()` → `TiernanMusicApp` build → `SplashScreen` 展示 → `_splashTimer = Timer(HandwritingCycle.minVisible)`（=writeEndMs+200 = 1790+200 = **1990ms**）后才允许切走；`_appReady` 由 `addPostFrameCallback` 首帧后置 true。builder 内 `if (!_appReady || !_splashMinElapsed) return const SplashScreen();`。**证据等级：静态推导**。

### 各环节证据
1. **动画未完成就跳转**：`minVisible=1990ms` < 一轮总时长 `totalMs=2600ms`，但 `writeEndMs+holdMs=1790+620=2410ms` 才进入 fade；minVisible 设在"写完+停一拍(200ms)"，保证至少看到完整一次书写（起笔→收笔→停一拍）再切走，不会在起笔就被截。**证据等级：静态推导**。符合 V33-04 修复意图。
2. **首帧阻塞**：`Timer` 在 `initState` 注册、不阻塞 `main()`、不阻塞首帧（`WidgetsBinding.addPostFrameCallback` 仅标记就绪）。动画路径硬编码（`static final Path`）、无 IO/解析，每帧仅 `paint`，`repaint` 传入 `AnimationController` 不重建 Widget。**证据等级：静态推导**。
3. **深色模式可见性**：`HandwritingLogoPainter` 取 `theme.colorScheme.primary`（品牌 #00D4FF 派生），不再固定 SVG 白蓝值；`SplashScreen` 背景取 `theme.colorScheme.surface`。深色模式 `fromSeed(seed, dark)` 主色仍为青蓝，与深背景形成对比 → **可见**。**证据等级：静态推导**。无反例（未找到深色下 ink 落入低对比的情形）。
4. **循环空转（P3，已知）**：`..repeat()` 使渐隐后 tail 段仍逐帧 paint（paint 内 `ms>=fadeEndMs` return，绘制代价低）。用户不可感知。

### 结论
修复②动画在真实冷启动时序下可用：不会被提前掐断、不阻塞首帧、深色模式可见。仅残留 P3 级 repeat 空转（已在前批记录，不重复立条）。**证据等级：静态推导**。

---

## 问题清单汇总

| # | 文件:行 | 级别 | 摘要 | 证据等级 |
|---|---|---|---|---|
| ②-1 | player_repository.dart:171-178（resolveUrl 直连分支） | P1 | 直连 /v5/url 前未先 `ensureDfid()`；device.dfid 空时首播直连必 `err dfid` 失败再回退 kapi（播放 P0 成因残留，修复②只定位未消除） | 实测+静态 |
| ②-2 | player_repository.dart / KgPlayApi.songUrl（dfid 同步） | P1 | 直连路径缺"注册 dfid 后回写 kg.device.dfid/kg.dfid"的承接，与 PLY-12 机制未接上 | 静态推导 |
| ②-3 | player_repository.dart:299-305（kapi isPreview 判定） | P2 | `priv_status==0` 被误判为试听；与直连分支 `isPreview` 口径不单一源（第 5 条） | 静态推导 |
| ①-1 | main.dart authStateProvider 监听 | P2 | 登录态刷新只 invalidate homeDataProvider，未同步 invalidate 库页 `_userPlaylistsProvider`，私有区块刷新不对称（第 5/18 条） | 静态推导 |
| ③-1 | splash_handwriting.dart:160 | P3 | 渐隐后 repeat 空转 repaint（用户不可感知，前批已记） | 静态推导 |

### 统计
- P0：0
- P1：2（②-1、②-2）
- P2：2（②-3、①-1）
- P3：1（③-1）

### 三条反馈闭环判定
- **反馈①（歌单仅首次加载）**：原生实测三态 200 稳定、`_wrap` 无误判、`setCredentials`/`AccountManager` 已对齐登录态，未发现使二次失败的新/回归缺陷；仅存非对称刷新 P2 建议（①-1）。**闭环成立**。
- **反馈②（全部播放）**：根因定位与修复②一致——trackercdn /v5/url 需真实已注册 dfid，而首播直连路径未先 `ensureDfid`、注册结果也未回写 device.dfid。MV 走 trackermv 且对 dfid 不敏感，故 MV 正常、歌曲全败。**差异清单见上表**。修复②代码承接不完整（②-1/②-2 P1），是播放 P0 残留主因。
- **反馈③（第一屏动画）**：冷启动时序下可用（不提前掐断/不阻塞首帧/深色可见），无回归，仅 P3 空转残留。

> 注：全部结论基于完整 file_read 与 QUALITY_STANDARD/PROGRESS/TASK_v33_*/v33_fix_* 及修复①原生实测记录；未读旧批次报告，未编译/装包；dart 未安装，依任务书允许范围以静态推导为主、修复①原生实测为实证锚点（第 33 条合规）。
