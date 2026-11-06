# v3.3 修复① 报告：存储外置 + 播放/歌单排查

- 执行代理：修复代理（照任务书逐项改）
- 基线：`defd4a4`；工作目录：`/var/minis/workspace/TiernanMusic`
- 实测纪律：所有「接口是否可用」结论均来自原生网关直连（`/var/minis/workspace/probe_v33.py` + `.test_creds/cj_*.txt`，带 android 签名 / x-router），kapi 返回只作对照、不作判定（第 33 条）。

## 一、实测证据（原生直连，非 kapi）

### E1 歌单 `/v7/get_all_list`（任务二线索验证）
- 直连 `gateway.kugou.com/v7/get_all_list` + `x-router: cloudlist.service.kugou.com`，带正确 android 签名 + 非 VIP cookie（userid=2461028533）。
- **字符串 userid**：`HTTP 200, status=1, data.info[]` 正常返回 3 个歌单（默认收藏/我喜欢/云淡风清喜欢的音乐），`global_collection_id` 齐全。
- **数字 userid**（`Number(userid)`）：同样 `status=1` 正常返回。
- **userid='0'（kg.userid 复位值）**：仍 `status=1` 正常返回（token 携带身份）。
- **结论**：任务书怀疑的「字符串 userid 导致二次调用失败」**被原生实测否定**；`/user/playlist` 端点本身在重复调用下稳定返回 200。

### E2 用户歌单歌曲 `/v4/get_list_all_file_v3`
- 直连 `status=1, data.info=null, count=0`（该账号 listid=1/2 无歌，listid=3 有 347 首），接口行为正常，无风控。

### E3 权益 `/v2/get_res_privilege/lite`（播放链第 1 环 fetchDetail）
- 直连 `x-router: media.store.kugou.com` → `status` 正常，`relate_goods[]` 含 `ogg_128/ogg_320_hash`、`is_original` 等字段，fetchDetail 链路**工作正常**。

### E4 播放地址 `/v5/url`（播放链第 2 环 resolveUrl）—— 核心故障点
- 直连 `trackercdn.kugou.com/v5/url`，用真实 hash（06E9D3B8A29BA901BC2930E69F14F4EE）+ album_id=599046，逐组合实测：
  - **带 android 签名（App 当前路径）** → `{"errcode":"20006","status":0,"errmsg":"err signature"}`
  - **不签名 + key + 随机 24 位 dfid（Node notSign 风格）** → `err clientver or mid or dfid or clienttime`
  - **精确复刻 Node song_url（随机 dfid + key + 签名不含 key）** → 同上 `err clientver or mid or dfid or clienttime`
  - 结论：**trackercdn 对 `/v5/url` 始终拒绝**，签名路径报 `err signature`、未签名路径报 dfid 类错误。App 当前走签名路径 → 歌曲播放 100% 失败。
  - 与 `docs/batch4_fix_1_network.md` M2「签名+原生域可用」**矛盾**：M2 用 kapi 中转结果（经 Node 包装）判定，按第 33 条以原生直连为准 → **M2 结论不可信，App 当前签名实现对 trackercdn 无效**。
  - 根因推断：trackercdn 要求**真实已注册 dfid**（测试 cookie 无 dfid，传 `'-'`/随机均被拒）；且/或签名盐/参与参数与 gateway 不同。需先 `register/dev` 拿到真实 dfid 再复核，本次未盲改签名（避免错修）。

### E5 网络安全配置 `network_security_config.xml`
- 已放行 `fsandroid.kugou.com` / `fsmobile.kugou.com`(tx) / `kugouaudio.com` 等子域 cleartext；播放返回 http CDN 地址可直连（任务三该子项已达标，无需改）。

## 二、逐项改动

### 任务一：文件存储全面外置（部分完成）
- `V33-20 | lib/core/utils/error_logger.dart:330+ | apiLevel 兜底归一：通道返回值 <21（含 Android 9 误报单数字）统一兜底 29，避免 ≤28 旧分支误判 | B-21 / 第 13 条`
- `V33-20 | lib/core/utils/error_logger.dart:currentDirPath | 公共与私有双双失败时返回哨兵「（日志仅进程内）」，不再返回假路径/ null 误导 | B-20 / 第 9 条`
- `V33-22 | lib/core/utils/error_logger.dart:log | 落盘（公共+降级）整段包进串行链 `_writeQueue`，消除并发写互相截断 | B-22 / 第 22 条`
- `V33-28 | lib/core/image/app_image_cache.dart:24 | CacheManager Config 加 `maxCacheSizeBytes: 500MB`，CacheManager 按 LRU 自动淘汰，替代此前无字节上限 | B-28 / 第 25 条；清缓存本就走 `emptyCache()` 未递归删 DB`
- 日志目录 `Download/TiernanMusic/logs/` 外置、下载目录 `Music/TiernanMusic` 外置：**现状已满足**（MediaStore 公共区），`tempDir()` 仍用 App 私有临时目录且 `dimKey` 命名与 `download_provider` 写入一致（D-01 已修，已核对）；未做新改动。

### 任务二：歌单「仅首次登录能加载」(P0) —— 未修（定位为客户端状态，非端点）
- 原生实测（E1/E2）证明 `/user/playlist` 及 `/v4/get_list_all_file_v3` 对字符串/数字/'0' userid 均稳定返回，重复调用无风控。
- 因此「二次失败」不在参数形态，而在 Dart 客户端状态：`kg.userid` 在 `clearCredentials()` 复位为 `'0'`（kg_direct_api_client.dart:58），`setCredentials` 仅在登录/恢复时同步。建议下一批排查：library_page 进入/账号流是否间接触发 `clearCredentials`，或 `_userPlaylistsProvider(loggedIn)` 的 `loggedIn` 在 re-entry 瞬态为 false。本次**未改歌单端点参数**（原生证明无误），仅记录证据。

### 任务三：播放链路排查 (P0) —— 部分完成（定位未改）
- E3 证明 `fetchDetail`（privilege/lite）正常；E4 证明 `resolveUrl`（/v5/url）**原生直连必然失败**，是「歌曲播放有问题」的根因。
- 未盲改签名/dfid（避免按错误假设改动直连参数，违背第 33 条）。修复需：①`register/dev` 拿真实 dfid；②核对 trackercdn 签名盐/参与参数；③带真 dfid 重测 /v5/url 直至返回 `url[]`。
- `network_security_config.xml` 域名覆盖已达标（E5），无改动。

### 任务四：遗留 P1/P2 清理（完成）
- `V33-03 | lib/core/utils/error_logger.dart:_redact | 脱敏正则补全 `dfid/t1/userid/mobile` 键（含双引号与单引号 JSON 形态），修复 B-17「JSON 形态 token 不匹配」 | B-17 / 第 13、14 条`
- `V33-03 | lib/core/direct/kg_endpoints_auth.dart:56 captchaSent | `http://login.user.kugou.com` → `gateway.kugou.com` + `x-router: login.user.kugou.com`（https 通路，避开 Android 9+ cleartext 拦截与 https TLS hostname mismatch，参照 batch4 M7） | 第 27 条`
- `V33-03 | lib/core/direct/kg_endpoints_auth.dart:208 login_by_token | 同上 http→gateway+x-router | 第 27 条`
- `V33-03 | lib/core/api/translate_api.dart:44 | `choices` 空列表/null 显式判定退回原文，消除空 `choices` 误当译文 / RangeError 隐患 | B-36 / 第 13 条`
- `V33-03 | lib/core/router/app_router.dart:/rank/:rankId | rankId 深链解析失败（`?? 0`）改为返回错误页，杜绝 rankId=0 空请求 | B-39 / 第 14 条`
- B-19/B-41 lastErrors 诊断：`KgDirectApiClient.lastErrors` 已存在并被 `_logError` 写入；「网络诊断」卡片的最小实现需在设置页读取并脱敏展示，本次未新建 UI（属独立小需求，留待下批）。

## 三、状态汇总
| 任务 | 状态 | 说明 |
|---|---|---|
| 一 存储外置 | 部分完成 | 日志并发锁/B-20/B-21/B-28 已修；外置目录现状已满足，无新改动 |
| 二 歌单 P0 | 未做（仅定位） | 原生证明端点无误，故障在客户端状态，待下批排查 clearCredentials 触发点 |
| 三 播放 P0 | 部分完成（定位） | 锁定 /v5/url 原生必然失败（err signature），未盲改；需先取真 dfid 重测 |
| 四 遗留清理 | 完成 | B-17/B-36/captcha http/B-39 已修 |

## 四、未提交说明
改动均未 `git commit`（遵守禁止提交）。`dart analyze` 仅报“Flutter 包未解析”类噪音（Dio/riverpod/go_router/material undefined），无真实语法错误（已修 B-17 正则引号转义导致的解析错误）。
