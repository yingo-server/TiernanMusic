# v3.3 迭代任务书·第 1 批（修复①）：文件存储外置 + 播放/歌单排查修复

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（含第九章第 33 条：**kapi 返回不可作为原生网关实测依据**——kapi 的返回经 Node 层包装，排查接口问题必须用 `/var/minis/workspace/.test_creds/probe.sh` 直打原生域名或真机日志核对，kapi 返回的 AggregateError 等错误与原生无关，不得据此修改直连参数）。

## 角色
修复代理。按任务清单改代码，不重新全面审查。

## 绝对禁止
- 禁止装 Flutter SDK / 装包 / clone / flutter build / flutter test / dart pub get
- 允许 `dart analyze`（`export PATH=$PATH:/opt/dart/bin`），缺 Flutter 包产生的 undefined/uri 噪音要过滤；**给文件新增 Flutter 符号调用时必须显式核对 import 头**（v3.2.1 的 P0 教训）
- 禁止 git commit/push（主代理统一提交）
- 禁止起本地 Node/kapi 服务
- 三态实测用 `/var/minis/workspace/.test_creds/{native_probe.sh,probe.sh}`（native_probe 直打原生域，probe 走 kapi——**只用于对照，不作为判定依据**）

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `defd4a4`

## 输出
修复报告落盘 `docs/v33_fix_1_storage.md`，逐条：编号/文件:行/改了什么/依据条款。

---

## 任务一：文件存储全面外置（P1，用户最高优先级）

**目标**：除凭证外，一切文件放公共存储，文件管理器可直接访问。

1. **日志外置**（`lib/core/utils/error_logger.dart`）：
   - 现状：优先 MediaStore Downloads/Documents，私有目录兜底（B-20：双失败时日志消失）
   - 目标：日志目录统一到 `Download/TiernanMusic/logs/`（MediaStore），私有目录仅作最终兜底且降级时写一条到 `_recent` 标注「日志仅进程内」
   - 顺带修 B-21（apiLevel 通道失败恒 29、Android 9 返回 9 而非 28）与 B-22（并发写无串行：加进程内锁）
2. **封面/图片缓存外置**（`lib/core/image/app_image_cache.dart`）：
   - 现状：B-28 无字节上限；清缓存直接删 CacheManager 目录含 DB
   - 目标：缓存根迁到 `Android/data` 外的 `Download/TiernanMusic/cache/`（或保持 CacheManager 但目录改外置）；加字节上限（如 500MB，LRU 淘汰）；清缓存改走 `emptyCache()` 不再 recursive 删
3. **下载目录核对**（`lib/features/download/data/public_media_store.dart`）：
   - 现状 MediaStore 已在公共 Download/Music，核对 fallback（Android/data）目录是否也能迁到公共区（B-39 策略静默降级问题顺带：降级时 Toast 告知用户文件在哪个目录）
   - 临时目录 `tempDir()` 迁到公共区（或至少确保删除规则与写入规则一致——v3.2.1 已修 D-01 命名，确认 remove/clearAll 路径也用 dimKey 命名）
4. **凭证保持内部**（不改动）：SecureStorage 的 token/dfid/账号 token 不动。

## 任务二：歌单「仅首次登录能加载」（P0，用户实测）

**现象**：歌单页仅首次登录成功加载，后续全失败。

排查线索（已定位到可疑点，需你验证+修复）：
- `lib/core/direct/kg_endpoints_playlist.dart:158-172` `userPlaylist`：对比 Node `user_playlist.js`——**query 里 Node 用 `Number(userid)`，我们传字符串**（kg.userid 是 String）；body 的 `userid` 同样字符串。实测确认字符串 userid 是否导致二次调用失败。
- `lib/core/direct/kg_endpoints_playlist.dart:176-192` `userPlaylistTracks`：与 Node `playlist_track_all_new.js` 对照**字段一致**，但注意它是 `_directOrFallback`，失败会回退 kapi（kapi 不可信，见第 33 条）——直连失败的真实原因要看原生返回。
- **用 native_probe.sh 或构造直连请求实测**：非 VIP cookie（`.test_creds/cj_nonvip.txt`）+ 原生 gateway.kugou.com + x-router cloudlist.service.kugou.com，带正确签名，打 `/v7/get_all_list`，看返回；再试字符串 vs 数字 userid。
- 检查 `kg.userid` 在二次进入页面时是否被清空（`clearCredentials`/登出恢复逻辑），以及 `_userPlaylistsProvider`（library_page.dart:495）的 autoDispose+family(loggedIn) 是否在登录态切换后用旧参数。
- 修复后注释标 `V33-01`（P0）。

## 任务三：播放链路排查（P0，用户实测「全部播放有问题」）

用户反馈 MV 播放已正常，但歌曲播放有问题且环节不明。逐环节核对并实测：
1. `fetchDetail`（player_repository.dart）→ 2. `resolveUrl` 直连 `/v5/url`（trackercdn）→ 3. `_applySource` 装载。
- 用 native_probe.sh 三态打 `/v5/url`（带 album_id/hash/quality），核对返回的 url 是否可用（curl -I 测 Range）。
- 重点疑点：`_qualityFromBitrate` 阈值（v3.2.1 改过，核对 320000 归 q320 是否正确）；`hash_offset` 试听判定（`priv_status==0 || hash_offset is Map` 是否误判 VIP）；URL 是 **http** 明文（Android 9+ 默认 cleartext 禁止——核对 `network_security_config.xml` 的 domain-list 是否覆盖 fsandroid/fsmobile.kugou.com）。
- 每个修复标 `V33-02`。修不完的列出排查结论（环节定位+证据），不要瞎改。

## 任务四：遗留 P1/P2 清理（能修多少修多少）
- B-17 日志脱敏正则失效（对 `"token":"x"` JSON 形态不匹配）→ 重写正则，补 mobile/userid/dfid 键
- B-36 translate_api `choices?[0]` 空列表 RangeError → 防护
- captcha 明文 http → 改 gateway.kugou.com + x-router（修复①代理实测过直连 https TLS 失败，走 gateway 是正解）
- B-19/B-41 lastErrors 诊断：最小实现——设置页「网络诊断」卡片读 `lastErrors`（先脱敏）
- B-39 rankId `?? 0` 深链 → 非法时 Toast + 返回
每条标 `V33-03` 起。

## 修复要求
- 每处改动先 file_read 完整读该文件
- 只用 file_edit，注释标编号+对应 QUALITY_STANDARD 条款
- 报告写完给 8 行内汇报：各任务完成度、实测证据、未修项原因
