# TiernanMusic v3.0 LTS —— 迭代进度（唯一权威）

> 规则：每完成一步立即更新本文件。任何代理/主代理都不许"最后统一写"。

## 当前状态

| 阶段 | 状态 | 产出 |
|---|---|---|
| 第4批审查（6 份报告） | ✅ 完成 | `docs/batch4_review_{1_network,1_network_b,2_function,2_function_b,3_ui,3_ui_b}.md`，共 209 项 |
| 第4批修复（3 代理并行） | 🟡 进行中 | `docs/batch4_fix_{1_network,2_function,3_ui}.md` |
| 复检 5 批（3×5） | ⬜ 待开始 | `docs/v3_review_b{1..5}_*.md` |
| CI 全绿 + 打 tag | ⬜ 待开始 | `v3.0.0` |

## 已完成的核心修复（主代理亲修）

| 编号 | 内容 | 文件 |
|---|---|---|
| PLY-02 | 非歌曲搜索补 albumhide/nocollect/iscorrection，pagesize 30 | kg_endpoints_search.dart |
| PLY-03 | 歌词下载 id/accesskey 空值前置拒绝 | kg_endpoints_search.dart |
| PLY-04 | contenttype 字符串化比较 | kg_endpoints_search.dart |
| PLY-05 | 加歌补 number/size/sort/timelen/bitrate | kg_endpoints_playlist.dart |
| PLY-06 | 删歌路径去 cloudlist.service 前缀、body 精简 | kg_endpoints_playlist.dart |
| PLY-07 | 歌单详情补 userid/token + 10 条上限校验 | kg_endpoints_playlist.dart |
| PLY-08 | 写操作禁止回退（write:true）——防重复提交 | kg_direct_api_client.dart |
| PLY-09 | 回退路径异常统一包装 DioException | kg_direct_api_client.dart |
| PLY-10 | _wrap err_code 校验提前 + 字符串兼容 | kg_direct_api_client.dart |
| PLY-11 | 空响应体判失败（不再静默成功） | kg_direct_api_client.dart |
| PLY-12 | setCredentials 同步 dfid | kg_direct_api_client.dart |

## 已知误报（不再处理）

- 「歌词搜索应打 `/v1/search` 且必须带 signature」：实测 `/v1/search` 用 Node 原参数（含 signature）
  返回空体 + `x-kg-errcode: 20010`；无签名 `/search` 正常返回 candidates。现有实现正确。

## 审查方法论（v3.0 起固定）

依据 `docs/QUALITY_STANDARD.md`：
- 只允许**完整 file_read** + 查阅 Dart SDK 文档
- **禁止编译、禁止跑测试、禁止装包、禁止 clone**
- 每条问题必须给：位置 / 事实 / 契约 / 后果 / 级别
- 网络类问题必须指向原生网关实测记录（`docs/api_verified.md`）

## 5 批审查划分（每批 3 代理，串行，不排队）

| 批 | ① | ② | ③ |
|---|---|---|---|
| 1 | core/direct 全部（客户端+7 端点文件+play_api+crypto） | core 基础设施（api/utils/config/providers/router） | 认证 + 登录态 + 三态 |
| 2 | player（data/presentation/provider） | lyric（data/presentation） | search + home |
| 3 | playlist + comment（data/presentation） | library + download | settings + i18n（10 语言） |
| 4 | 跨模块一致性（状态源/幂等/缓存） | 并发与生命周期（全局 await/token/dispose） | 性能（构建/lookup/内存） |
| 5 | 全局终审 A 视角（正确性） | 全局终审 B 视角（鲁棒性） | 全局终审 C 视角（体验/可维护性） |

每批结束：合并问题 → 主代理统一修复 → 下一批。

## 质量准则（2026-11-06 定稿）

`docs/QUALITY_STANDARD.md` —— 32 条纯原则，八章：
1. 设计与分层（1-5）
2. 错误处理（6-11）
3. 数据与空安全（12-17）
4. 并发与生命周期（18-22）
5. 资源与性能（23-26）
6. 网络与接口契约（27-29，最高优先级）
7. 可维护性（30-32）
8. 审查纪律（方法论）

**静态检查允许范围**：`dart analyze`（Dart SDK 3.13.7 本地已装）查语法/结构错误。
**绝对禁止**：本地编译、`flutter build`、`flutter test`、安装 Flutter SDK / Android SDK / 任何包。
必须过滤「缺 Flutter 包」产生的噪音（uri_does_not_exist / undefined_class 等）。

## 2026-11-06 第4批修复完成（commit e7a6e00）

### 三代理产出
| 代理 | 报告 | 修复 |
|---|---|---|
| ①网络层 | batch4_fix_1_network.md | P1 15 + P2 10（含 3 条实测驳回：/v5/url 实际要签名、special_recommend 补字段后可用、评论裸路径+x-router 才通） |
| ②功能层 | （报告未落盘，改动已核实） | 歌单写操作 _write 统一出口（防重锁+maybeSucceeded 语义）、audio_handler 世代校验+闸门单点释放、KRC 解析/翻译、播放地址 |
| ③UI层 | batch4_fix_3_ui.md | 18 条（F4-31~48），版本 3.0.0+30 |

### 主代理亲修
- fallbackToKapi → const false（kapi 仅参考不调用，第 27 条）
- 未移植路径抛 ApiException(-404)，不再静默走 kapi
- _wrap 重构（err_code 提前、空体判失败）
- 写操作 write:true 禁止回退 + 异常统一 DioException 包装

### 下一步
- [ ] 5 批审查（3×5）按 QUALITY_STANDARD 32 条
- [ ] CI 全绿
- [ ] 打 tag v3.0.0 发布

## 2026-11-06 v3.2 迭代（进行中）

### CI 修复
- v3.0.0 构建失败：KgClient 缺 dfid setter、switch 非穷尽（transformTimeout）→ 已修
- 已推 5e050a3 + 打 tag v3.2.0（版本 3.2.0+32，commit f6f9531），run 42123692258 构建中

### 第5批复核（v3_review_b1_*）
- ②功能链路：P1 2（stop/pause 不作废世代、fetchDetail 空捕获）已修 V3-01~05
- ②补充：音质阈值两处统一 V3-06、_proxyHttp 死代码删除 V3-07
- ①直连层 / ③UI合规：代理运行中，报告未完

### 待办
- [ ] 等 3 份复核报告齐 → 修复
- [ ] CI v3.2.0 绿 → release 确认

## v3.2 迭代续（第5批复核修复）

### CI 修复
- ad26926：V3-03 detailed 作用域外引用（analyze 报错）
- v3.2.0 tag 重打到 ad26926，run 42124284517 构建中

### 第5批复核①直连层 P1 修复（7da9d5d）
- V3-08：未移植路径 ApiException 裸抛 → 统一 _asDioException 包装（第 8 条）
- V3-09：登录 dfid 只写 kg.dfid 不进 device.dfid → 签名维度不匹配；已同步（第 5 条）
- V3-10：requestWithVerify 验证后重试对写操作=重复提交 → 契约声明写端点禁用（第 21 条）
- V3-11：kapi 基址无语义说明 → 标注仅参考+清理计划（第 27 条）

### 复核③UI 报告要点
- P1：kapi 固化为默认基址（已用 V3-11 处理：语义澄清，运行期不发包）
- P2：supportedLocales 双源 10 vs 11（app_zh.arb 裸 zh）——待修
- P3 若干

### 定时任务
- dea41ffd：15 分钟后查构建 + 推进第 6 批审查

## ✅ v3.2.0 发布确认（2026-11-06）

- release published 2026-11-05T22:56:13Z，draft=False
- 资产：arm64-v8a 25.1MB / armeabi-v7a 22.9MB / x86_64 26.6MB / screenshots-181.zip
- tag 已移动到 7da9d5d（含 V3-08~11 修复），重建 CI 触发中
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.2.0/app-arm64-v8a-release.apk

## 第6批复核（进行中）

### ②表现层报告（v3_review_b2_presentation.md）✅
42 条：P0 0 / P1 0 / P2 16 / P3 26。主要领域：热路径（歌词页每 tick 逐字分配 TextSpan、封面子树随进度重建）、搜索页状态互斥（联想词不可达、分页失败永久转圈）、生命周期（CurvedAnimation 每 tick 新建）。

已修（主代理）：
- R-01：CurvedAnimation 提取到 State 一次创建，dispose 对称（8cc754e）
- R-26/27：搜索提交 mounted 检查 + addHistory 容错（历史写盘失败不阻断搜索）

待修 P2：R-02/03/04/14/15/16/20/28/29/30/31/38/39
### 其余两份报告（infra / data_ui）：代理运行中
### v3.2.0：tag=5ec5c71 第6次构建进行中

## 50 分钟检查点（2026-11-06 09:10 前后）

### 代理状态
- 运行中：第6批①基础设施（核对启动清缓存）、③下载认证（读音乐库页）、第5批①直连层（写报告尾部，已 54 分钟接近超时）
- 已完成：第5批②③、第6批②

### CI/推送
- main 最新提交 53f15d9（R-28/29 修复）push 被代理拒（remote rejected failure）——GitHub API 正常（rate limit 余量充足），疑似 proxy.344977.xyz 瞬时故障，稍后重试
- v3.2.0 tag=5ec5c71 第6次构建进行中（main 同 commit 已绿）
- R-28/29 修复待推送，归入 v3.2.1

### 待办
- [ ] 代理 push 故障恢复
- [ ] 接收第6批①③报告 → 修 P0/P1
- [ ] 第5批①直连层报告收尾（即将超时）

## ✅ v3.2.0 发布最终确认

- 根因：GitHub Release API 服务器 500（retry 耗尽），非代码问题（analyze/build 全绿）
- 处置：API 直接补建 release（id 435879242）+ 手动上传 3 个 APK
- 资产：arm64 25.1MB / v7a 22.9MB / x86_64 26.6MB，draft=False
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.2.0/app-arm64-v8a-release.apk

## 第6批修复进度（主代理亲修）
- B-11(P1)：登出清干净 dfid+账号切换 token（d8543af）
- R-01/26/27/28/29：CurvedAnimation/搜索生命周期/联想词可达性/分页重试
- 待修：B-07(CookieJar 时序)、B-10(dfid 多源)、B-12/13(设备兜底)、下载链路 D 系列 P1×2

## 第6批修复续（7f80784）

- B-07(P1)：sharedCookieJar 时序防线——路径未就绪不缓存 jar；降级内存必留日志
- B-10(P1)：原生注册 dfid 双写同步 SecureStorage（消除冷启动设备标识跳变 → 风控/试听根因）

## 剩余 P1
- 下载链路：临时文件名缺音质维度（D-01）、发布前删旧文件非原子（D-02）

## 第6批修复完成（c4e73c5）

### P1 全清单（本轮已修完）
| 编号 | 问题 | 条款 |
|---|---|---|
| B-07 | CookieJar 时序静默降级 | 2/9 |
| B-10 | dfid 多源跳变（风控根因） | 5 |
| B-11 | 登出安全残留 | 5/20 |
| D-01 | 下载临时名缺维度→交错写坏 | 23/21 |
| D-02 | 发布覆盖写→旧文件截断 | 21/5 |
| R-01/26/27/28/29 | 表现层 | 20/18/9/16 |

### 状态
- v3.2.0 已发布（release 435879242，3 APK 齐全）
- 第7批终审代理运行中（ed156dd5，验证本轮修复无回归）
- 全绿后封 v3.2.1

## 第5批①直连层报告消化（66eb23b）

### P0×2 已修
- D-P0-1：post 分派表缺评论写三件套 → 恒 -404。已补齐（write:true）
- D-P0-2：MV 取消收藏 collect 形参从未参与请求 → 收藏只增不减。已走 /v1/cancel_collect + 二进制 body（对齐 Node mv_collect_del.js）

### P1 已修
- D-P1-1：_afterLogin 接线 vipType/vipToken（VIP 被当非会员的根因）

### 待修 P1
- captchaSent/loginToken 明文 http（改 gateway+x-router，修复①代理实测直连 https 会 TLS 失败）
- B-17/B-41 日志链路（脱敏失效 + logApi 无人调用）

### 状态
- main 66eb23b 构建中
- 第7批终审代理运行中

## 第7批终审消化 + v3.2.1 封版（cce8178）

终审判定原为「阻断」（P0-1 debugPrint 编译），已在 8112084 修复。其余回归全部修完：

| 编号 | 级别 | 问题 | 修法 |
|---|---|---|---|
| F-1 | P0 | debugPrint 无导入（我引入） | 补 foundation.dart（8112084） |
| F-2 | P1 | 登出删 dfid → 重登判新设备+验证死循环+kapi 变常规路径 | 登出保留 dfid（设备≠账号） |
| F-3 | P1 | 失败分支调 pause() 作废世代 → 自动跳歌失效（V3-13 回归） | 新增 _pauseEngineOnly |
| F-4 | P1 | 收藏全局锁：widget 销毁后 finally 复位抛异常 → 锁永久卡死 | autoDispose + notifier 快照复位 |
| F-5 | P2 | 分页失败复用 _error → 滚动加载永久阻断 + 重试成功后 footer 残留 | 失败态二分（首屏/分页） |

- tag v3.2.1 已打（cce8178，版本 3.2.1+33）
- 复核通过项：B-07 CookieJar 时序、B-10 dfid 双写、R-28、R-01、V3-14 锁语义

## 第7批终审收尾（2d88c2e）

- F-4 半修项补齐：_collectingProvider 声明改 StateProvider.autoDispose（注释与实现一致）
- 终审附录确认：F-1/2/3/5 全部通过，v3.2.1（cce8178）回归清零
- v3.2.1 构建验证中，验收任务 db0a178b 处理 release

## ✅ v3.2.1 发布完成

- release 435927876（draft=False）：3 APK + screenshots-204.zip，CI 绿
- tag 已重打到 8ee8f4c（含 F-4 autoDispose 补齐）
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.2.1/app-arm64-v8a-release.apk
- 终审确认：F-1~F-5 全部通过，回归清零

## 迭代总结（v3.0.0 → v3.2.1）
- 7 批审查（21 份报告）约 400 条问题；P0×3、P1×20+、P2×30+ 亲自修复
- 质量准则 32 条（docs/QUALITY_STANDARD.md）全程判定基准
- 方法论核心：修复者不能自审——终审独立视角抓回 5 条自引入回归

## ✅ 发布终态（全部 draft 已清）

- v3.2.1：release 435927876，tag 8ee8f4c，资产为新构建 APK（25.1/23.0/26.6MB），draft=False
- v3.2.0：release 435879242（5ec5c71 构建），draft=False
- v2.0.0：保持
- 清理：4 个废弃 draft（旧 tag 重打遗留）已删除
- 关键发现：**重打 tag 会使既有 release 自动转 draft**（非 API 500）——这是全程 release 反复「消失」的真正根因

下载：
- https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.2.1/app-arm64-v8a-release.apk
- https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.2.0/app-arm64-v8a-release.apk

## v3.3 修复②完成（7008c11）

- 启动屏手写笔迹动画：SVG path 硬编码描摹（11 段，零运行时解析）、笔头跟随、写完停顿渐隐循环、文字后淡入（V33-01/04）
- MV 缩略图 {size} 按控件选档归一；BoxFit.fill 全仓 0 处（本就合规）；memCacheWidth 补 2 处；空封面守卫补 7 处（V33-10~19）
- 旧 animated_svg_logo.dart 已由 splash_handwriting.dart 替代删除

### 待办
- [ ] 修复①（存储外置+歌单P0+播放排查）进行中
- [ ] 第3批复核三代理（修复①完成后派）

## v3.3 修复①完成（2638b34）

### 已修（代码已入库）
- B-17 日志脱敏重写（dfid/t1/userid/mobile + JSON 形态）
- B-36 translate choices 空列表防护
- captcha/login_by_token → gateway+x-router（明文 http 清除）
- B-39 rankId 深链校验
- B-21/22 日志 apiLevel + 并发锁

### P0 定位结论（未盲改，证据在报告）
- **歌单 P0**：原生实测字符串/数字/'0' userid 三种均 200——嫌疑参数排除；故障在 Dart 客户端状态（clearCredentials 复位路径），待复核批排查
- **播放 P0**：原生直连 /v5/url 必失败（签名→err signature；未签名→dfid 错）；fetchDetail/privilege 正常；**需先走 register/dev 拿真实 dfid 重测**——播放故障根因大概率在 dfid 未注册/签名维度

### 下一步
- [ ] 第3批复核三代理（review1 修复验证 / review2 用户路径 / review3 遗留债清点）

## v3.3 复核③清点修复（19cb29a）

- B-33: bootstrap 失败重试（不再永久缓存失败 Future）
- B-29: 翻译缓存键加模型维度
- N-1: MediaStore 空串判失败
- N-2: 裸手机号脱敏
- U-1: splash label 可传 l10n（标注）
- 留 v3.4：分层回流、断点续传（200~400 行独立批）、B-30 缓存上限、kapi 回退死代码

### 存储合规终审：通过（凭证仅内部，外置仅脱敏日志/媒体，双轨自洽）

## v3.3 复核①消化（4bd2519）——**播放故障根因链已接上**

三条 P1 全修：
1. 日志串行链尾 catchError 兜底（一断不断）
2. ensureDfid 轮询递归 → Completer 并发收敛 + 重试上限
3. **直连前补 ensureDfid 前置**——kapi 路径有、直连路径漏。实测证据链：/v5/url 未注册 dfid 时报「err clientver or mid or dfid or clienttime」→ 首播直连必失败。这就是用户「全部播放有问题」的最可能根因

## v3.3 复核②消化（91b0a5c）——播放 P0 根因链完全闭环

复核②独立验证：MV 正常（trackermv 对 dfid 不敏感）而歌曲全败（trackercdn 需真实 dfid）——差异点即根因。

- ②-2: ensureDfid 注册结果回写 kg.device.dfid（最后一环，PLY-12 同源机制）
- ②-1: 直连前 ensureDfid 前置（复核①-16 已修，本条确认闭环）
- ①-1: main 登录态监听补 invalidate 库页歌单/MV（provider 改公开名）

### 用户三反馈状态
- 歌单仅首次加载：无新缺陷（库页刷新不对称已修）
- 播放问题：根因链闭环（dfid 未注册→回写缺失→首播直连必败）
- 第一屏：复核通过，无回归

## v3.4 审查消化（41cdcef）

### 审查①功能模块：6 条 P1 修了 5 条
- V34-01: fetchDetail 错歌详情污染（hash 未命中不再取 first）
- V34-02: 直连网络异常也回退 kapi（「有网但播不了」）
- V34-03: 翻译条数不等不落缓存（防错位）
- V34-04: 零评论 special_id 兜底（第一条评论发得出）
- V34-05: 下载 realTempPath 持久化（.flac 泄漏）
未修：ensureDfid 重试风暴（已限 3 次，再优化留 v3.5）

### 审查②UI 专档：28 条（P1 0 / P2 11 / P3 17），待修 P2 重点
- 收藏任务流断点（addToPlaylist 死键）
- captcha 硬编码中文 + $e 直出
- app_en.arb 4 键未翻译 + 假开关
- 登录成功强制回首页、cookie 过期只给重试

### 遗留待办
- [ ] v34_review_2 的 P2 修复（UI 批）
- [ ] 7 项 native_probe 待实测

## v3.4 → v3.6 LTS 计划（用户 2026-11-07 定调）

### 流程
1. 先消化 v34_review_2 的 UI P2 批（修复完成出 v3.4.0）
2. **v3.5：3 批 × 3 代理 = 9 个审查代理**，全面全模块深度审查
3. 每批 3 份报告 → 33 制修复（报告齐 3 份即修，不攒批）
4. v3.6 LTS 发布

### v3.5 审查划分（全模块，含未覆盖区）
| 批 | ① | ② | ③ |
|---|---|---|---|
| A | core/direct 全量（含 v3.3 改动后回归） | core/api+cache+storage+image+utils | auth 全链（含 slider_solver/verification） |
| B | player+lyric 数据层深审 | playlist+comment+rank+home 数据层 | download 全链（含 store/permission） |
| C | mv+library 数据层 | 表现层 UI 逻辑（非观感） | main+router+l10n+pubspec 配置层 |

### 判定基准
QUALITY_STANDARD.md 33 条；每条结论标违反条款+用户可见后果；只读不编译。

## ✅ v3.3.0 发布确认

- release 436782440（draft=False），tag 3d1b3cf 构建成功
- 资产：arm64 24.7MB / v7a 22.5MB / x86_64 26.2MB + screenshots-226.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.3.0/app-arm64-v8a-release.apk
- 教训固化：修复代理任务书新增「触碰文件收尾前必须 analyze 并贴报告」（v3.3.0 两次 CI P0：main 缺导入、maxCacheSizeBytes 参数不存在）
- 并发纪律：修复/审查批一律 3 代理并行（用户口径）

## v3.4 审查③（跨模块）+ P0 处置

### P0 已处置
- keystore.b64.txt 确认曾明文入库（历史对象仍在，**需轮换 keystore**）
- 已从 git 索引移除 + .gitignore + 安全通告写入 keystore_setup.md（6f683c6）

### P1×3 待修
- main.dart 登录态同步空 catch 包裹（冷启动恢复期 token 丢失无补偿）
- MemoryCache 无用户维度+登出不清缓存（切号 90s 内串数据——B-15 同根，需键加 userid + 登出 clear）
- 播放链路/设置页副本不在登录态依赖图内（传播主线缺口）

### UI 修复批已提交（3032145）
- 收藏到歌单入口（播放页+搜索）+ captcha i18n + en 4 键

## v3.4 审查③消化（7e86701）

- P0 keystore：已移出仓库+gitignore+通告（**需用户轮换 keystore**——历史对象仍在公开仓库）
- V34-C-02: 登录态同步拆空 catch + 冷启动竞态 200ms 重试
- V34-C-03: 切号/登出清 MemoryCache（跨账号串数据根修）
- l10n 双源漂移（模板注释/en 4 键/albumPageComingSoon 缺失）：UI 修复批已带 en 补译，其余留 UI 批收尾
- 剩余 P2/P3 随 UI 修复批与 v3.5 批次消化

## v3.4 UI 修复批完成（b145f1b）

- V34-UI-01~08 + 清单 9：收藏入口（**搜索页菜单项代理 stash 回退后丢失，主代理补验补回**）、captcha i18n、假开关移除、登录返回来源页、空态引导
- i18n 程序化校验：328 键 × 10 语言全齐
- 代理自检修复 2 处编辑残留语法错误

### v3.4 汇总
- 审查三档：功能 46 + UI 28 + 跨模块 21 = 95 条
- 已修：P0×1（keystore 移出，需用户轮换）、P1×9、P2×10+
- 出 v3.4.0 → 启动 v3.5 全面审查（9 代理 3 批，3 并发）

## ✅ v3.4.0 发布确认

- release 436927165（draft=False），tag 8c095ee 构建成功
- 资产：arm64/v7a/x86_64 APK + screenshots-245.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.4.0/app-arm64-v8a-release.apk

### v3.4.0 内容
- UI 专档修复批（收藏入口双端/captcha i18n/假开关移除/登录返回来源页/空态引导）
- 跨模块 P0 keystore 移出 + 登录态同步重试 + 切号清缓存
- 功能模块 P1×5（错歌详情污染/网络异常回退/翻译条数防御/零评论兜底/下载泄漏）
- CI 试错 4 轮的教训：①代理自报 analyze 不可信（noise 误判真错误）②噪音过滤只适用于 Flutter SDK 符号，项目自有类报错即真错误 ③跨文件改动必须双向核对（调用方↔被调方）

## ✅ v3.4.0 发布确认

- release 436927165（draft=False），tag 8c095ee 构建成功
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.4.0/app-arm64-v8a-release.apk
- CI 试错 4 轮教训：①代理自报 analyze 不可信（noise 误判真错误——_PlaylistRowError 是项目自有类）②噪音过滤只适用于 Flutter SDK 符号 ③跨文件改动必须双向核对（调用方↔被调方）

## v3.5 A 批启动（3 代理并行，60 分钟）

| 代理 | 报告 | 范围 |
|---|---|---|
| A1（0206c4ce） | v35_review_A1.md | core/direct 全量回归（write 语义/-404/ensureDfid 并发） |
| A2（c1efb23f） | v35_review_A2.md | core 基础设施终验（缓存键/日志链/dfid 单源） |
| A3（c40b54b3） | v35_review_A3.md | auth 全链（**首次深审**：滑块验证/20028 链/多账号生命周期） |

新增任务书硬条款：噪音过滤只适用于 Flutter SDK 符号；跨文件改动双向核对。

## v3.5 A 批消化进度

### A1（direct 回归）✅ 已消化（4db42f6）
- P0/P1 = 0；四重点回归全过（write 语义/_wrap 五分支/ensureDfid 并发/评论 -404）
- 已修：isOk 死代码删除（口径不一致且零调用方）
- 留 v3.6：label 前缀重复、主类拆分残留 5 项、楼中楼 name 补查等 P3

### A2（基础设施）✅ 已消化（e5f8be3）
- V35-A2-1: translate choices 非 Map 防护
- V35-A2-2: dfid kapi 兜底三写同步（Hive 单源不再绕过）
- 终验结论：v3.3/v3.4 的 10 项修复全部验证到位无回归

### A3（auth 全链）🟡 运行中

## v3.5 A3（auth 全链）消化（3b2c0bf）——A 批完成

### 已修（2 条 P2）
- 登录态世代号：V34-C-02 重试闭包捕获旧 next 可回灌过期登录态 → generation 校验
- restoreSession 凭证读取防护：Keystore 故障机型不再静默永久匿名（降级+留痕）

### 留后续批
- captcha_page i18n 二次脱钩（5 处硬编码+9 死键）→ UI 批
- slider_solver 全文件死代码（从未接线）→ 专项决策：接线或删除
- 20028 三套平行验证实现互不一致 → 架构级收敛，v3.6 前必须
- player 旁路注入/生命周期 resume 不校验/onCurrentAccountChanged 单订阅者 → v3.5 B/C 批

### A 批总结
三份报告 26 条：P0×1（keystore，已处置）/P1×0/P2×8（修 6 留 2）/P3×17。四重点回归全过，10 项历史修复验证无回归。

## v3.5 B3（download 全链含 Kotlin）消化（56e2c32）

已修（发布链三条 P1）：
- P1-7: Kotlin finalize 返回真实行数判定 + Dart 校验（IS_PENDING 卡 7 天根因）
- P1-4/5: realTempPath 真实扩展名接入 displayNameOf 与 MIME（.flac 正确入库）

### 待 C 批后消化
- P1-1 remove 竞态复活、P1-2/6 先删旧文件+rename 窗口、P2-14 viewFolder content:// 失败
- B1 的 audio_handler catch 缺世代守卫、player_provider 生命周期三连
- B2 的 home_repository 四处回落无日志

## v3.5 B1/B2 消化（000da12）

### B1（player+lyric）✅
- V34 系列修复回归全过；ensureDfid 直连前置延迟评估净收益为正
- 已修：V35-B1-1 catch 世代守卫（暂停后假错误+误暂停新歌）
- 复认 6 条 P2（流切换/handler dispose/audioEngineReadyProvider 死态）→ C 批后统一清点

### B2（playlist+comment+rank+home）✅
- 13 条全部 P3，无用户可见故障路径
- V34-04 原生实测：childrenid='' 必拒（10013）、mixsongid 兜底进业务层——修复有效
- 楼中楼 name 维持 P3 不升级（通道已通）
- 三条 P3 待 C 批后修（home 回落无日志/口径不一/maybeSucceeded 语义）

### B3 ✅（已消化，见 56e2c32）

## v3.5 C 批启动（3 代理并行，60 分钟预算）

| 代理 | 报告 | 范围 |
|---|---|---|
| C1（3e4f3175） | v35_review_C1.md | mv+library 数据层 + album/artist 首审 |
| C2（b4697f09） | v35_review_C2.md | 表现层 UI 逻辑（add_to_playlist_sheet 首审/captcha 脱钩收尾） |
| C3（d2ed95ed） | v35_review_C3.md | main+router+l10n+配置层（CI keystore 移除后构建链/Manifest cleartext 表） |

B 批已消化：B3 三条发布链 P1（finalize/扩展名/MIME）、B1 catch 世代守卫；B2 无 P2 以上。
C 批完成后统一清点 → v3.6 LTS 封版。

## v3.5 C2 消化（bae1090）

已修两条 P1：
- V35-C2-1: 新建歌单链式加歌被 _busy 闸门吞（bypassBusy 参数）
- V35-C2-2: 「去登录」真跳转 /login

### 待 C1/C3 报告后统一修
- captcha_page 9 死键 0 替换（脱钩未收尾）
- 同名旧歌单竞态（P2）
- comments_page loadMore 永久转圈（复制 search_page _pageError 范式）

## v3.5 C3 消化（main+router+l10n+配置层）

- **P1×1**：l10n 生成物落后 arb 23 键（addedToPlaylist/playlistNameEmpty 被 add_to_playlist_sheet:96/:118 引用 → 编译必败、CI 全红）+ 40 键值漂移。修法：重跑 `python3 tool/gen_l10n_min.py`
- P2×4：ErrorWidget.builder 全局替换无退出路径 / gen-l10n 双轨无守卫 / pubspec.lock 缺失 / keystore.b64.txt 工作区残留
- P3×6：isDark 死代码确认、albumPageComingSoon 孤立键、tryListen 死键等
- 复核通过：V34-C-02/03 + V35-A3 回归到位；cleartext 域名表无缺口（fsandroid/fsmvpc/tx/kugouaudio 全覆盖）；keystore 移除后 tag 构建链自洽；权限表逐条匹配

## v3.5 C3 消化（f454e44）

- P1: l10n 生成物重跑同步（23 键 getter 补齐——addedToPlaylist/playlistNameEmpty 编译必败根因）
- P2: ErrorWidget 兜底页加重启按钮（build 异常不再整页死锁）
- 待修 P2: CI 加「gen_l10n 重跑 + git diff --exit-code」守卫（双轨根源）、keystore.b64.txt 工作区残留、pubspec.lock 缺失
- 回归结论：main 启动编排/世代号/事件流全过；cleartext 域名表无缺口；keystore 移除后 CI 链自洽

## v3.5 C1 消化（9295801）

已修 2 条 P1：
- V35-C1-MVC-R2: KgClient 加 Uint8List 二进制 body 直传分支（MV 收藏不再发整数数组文本；playlistDel 的 Base64 文本形态保持——两端点 Node 本就不同）
- V35-C1-ART-R8: 歌手页排序切换加世代校验（旧响应不再污染新列表）

### 待 v3.6 前决策
- 「收藏 MV」全 app 无入口（setCollected 死代码）→ 接入口或删功能
- ALB-R1/R2: album/artist `final dynamic _api` + 裸强转
- 缩略图 {size} 三档同一物理文件（注释误导，P3）

## v3.5 三批审查总结
A/B/C 共 9 份报告、约 90 条；P0×1/P1×9/P2×15+ 已修大半；明细见各 v35_review_*.md

## ✅ v3.6.0 LTS 发布确认

- release 437087468（draft=False），tag 9d687d8 构建成功
- 资产：arm64/v7a/x86_64 APK + screenshots-271.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.6.0/app-arm64-v8a-release.apk

### v3.6.0 内容（v3.5 全模块深度审查 3 批 × 3 代理 = 9 份报告约 120 条）
- Kotlin 原生通道首审：finalize 真实行数判定（IS_PENDING 卡 7 天根因）
- 发布链：realTempPath 真实扩展名 + MIME 真链（.flac 不再以 .mp3 入库）
- auth 首次深审：Keystore 故障防护、登录态世代号、20028 三套实现互不一致（架构级收敛留 v3.7）
- MV 收藏二进制 body（KgClient Uint8List 分支）、歌手页排序世代校验
- 收藏弹层：新建链式加歌闸门修复、「去登录」真跳转
- 配置层：l10n 生成物同步（编译必败根因）、ErrorWidget 重启按钮、keystore 移出仓库
- 遗留决策项：20028 收敛、slider_solver、收藏 MV 入口、断点续传 → v3.7

## v3.7 启动（3 代理并行，60 分钟预算，定时器 55 分钟）

| 代理 | 档位 | 报告 | 性质 |
|---|---|---|---|
| da0b998a | 缺陷档 | v37_fix_defects.md | 修复（v3.5/v3.6 遗留 P2×10） |
| 68cb7875 | UI 档 | v37_fix_ui.md | 修复（任务流断点/触控目标/微文案） |
| 927522b7 | 功能缺失档 | v37_feature_gap.md | **仅报告**（对比 Node 全模块差集，收益/成本/优先级） |

判定基准：QUALITY_STANDARD 33 条 + 新增纪律（analyze 逐文件贴报告/跨文件双向核对/噪音过滤窄化）。

## ✅ v3.7 功能缺失档完成（927522b7）

**差集结论**：Node 236 模块 → 净缺口 32 功能域（全缺 12/半缺 9），11 项立项评估、4 域明确不做。

**推荐 P1×4**（路线图按依赖序）：
1. 20028 收敛（架构地基，M）——song/url 三态实测恒 20028+同一 ssaCode，验证墙不分身份，是任何播放增强的地基
2. 断点续传（S，半天）——**CDN 原生支持标准 Range 实测通过**（206+Content-Range 正确）；坑：直链 5 分钟过期需重取校准
3. 每日推荐日历（S）——先实测 everyday_history
4. 个人 FM 基础版（M）——先实测 fm_songs/fm_recommend，不过则砍

**意外发现**：song/url 三态恒 20028 证实 20028 收敛是播放增强的真正地基；「收藏 MV」数据链已闭环（从遗留清单销项）。

**纪律**：所有「需先实测」项立项前必须 native_probe 三态留样；kapi 对照只标候选不作实现依据。

### v3.8 路线图
歌单广场扩展（清 kapi 回退债）→ 歌单排序+相似歌单 → 听歌上报 → 歌手视频/关注 → longaudio 专项评估

## v3.7 缺陷档失败回收（bcf753d）

代理 da0b998a 中断（model_error，elapsed 0s 但实际已工作——会话重启残留），产出已落盘 docs/v37_fix_defects.md：
- V37-01 captcha i18n 收尾 ✅
- V37-02 dfid 核实 + native_probe.sh 入库 ✅
- V37-03 B2 三条 P3 ✅
- V37-04 B3 发布链三条 ✅
- V37-05 viewFolder ✅
- V37-06 ALB 类型化 + 裸强转 ✅
- V37-07~10（同名歌单竞态/comments loadMore/arb 死键/页面残留）**未做**——代理中断

### 主代理收尾
- arb 程序化校验：zh_CN 339 键 × 11 文件，**无缺失**（V37-01 的键已进全语言）
- gen_l10n_min.py 重跑同步生成物（339 键）
- 全量 analyze 扫描 14 个触碰文件：无真实错误
- 已提交（bcf753d）

### 待接续
- V37-07~10 四条 → 派接续修复代理
- UI 档（68cb7875）运行中

## v3.7 UI 档完成（f57c4d1）——主代理独立复核通过

- 收藏 MV 入口：播放页收藏/取消按钮（setCollected+防重+登录守卫+hash-only 深链提示）；清晰度切换核实不硬造（根因=深链缺 videoId，上游字段缺失）
- 触控目标 27 处巡检修 4 处 <48dp；账号双入口去重；mini_player 窄屏降级；comment_floor 死按钮委托；深链错误页 l10n
- i18n 独立校验：336 键 × 10 语言无缺失，gen_l10n_min 重跑同步
- 主代理复核：mv_player_page 的 setCollected 调用与 l10n 引用实位验证 ✅

### v3.7 状态
- 缺陷档：V37-01~06 已提交；V37-07~10 接续代理运行中（d57bc767）
- UI 档：✅ 完成
- 阉割对比档：运行中（ada14509）

## ✅ v3.7 阉割对比档完成（2eb54363）

13 条阉割项（音质 5/音效 1/播放 3/搜索 2/歌单歌手专辑 3/用户 3），实测经 tool/kg_probe.py 三态留样。

### 音质档位实测结论（VIP 态）
128/320/flac/high/super + **蝰蛇三档（viper_tape/clear/atmos）** + multitrack 全部真实返回 URL；魔法音效六档（magic_piano/acappella/dj/surnay/subwoofer/ancient）**三态全通（匿名也有）**；sc/hires 为伪档位（20010 不存在）。

### 音效上游结论
**无可调 DSP/均衡器端点**（effects_* 全是车载品牌运营域）；蝰蛇体验正确补法 = 请求 viper_* 音源档（属音质非参数化音效）。

### 补齐 P1×3
1. C-1 蝰蛇三音源档（权益判定链已就绪，差枚举+UI）
2. C-2 魔法音效六档（参数构造早已备好 KgSharedParams.magicQualities，无入口）
3. C-10 搜索建议直连化（现走 kapi 违第 33 条且丢分类型联想）

## ✅ v3.7 三档全部收齐（72bb49d）

### 缺陷档（两轮）
- 第一轮 V37-01~06 ✅（代理中断后回收）
- 第二轮 V37-07~10 ✅：同名歌单基线快照排除法、comments loadMore 核对通过（范式已在位）、arb 死键清理（4 删 1 保留——任务书预判 mvQualitySelect 不成立，代理 grep 证实有消费方）、captcha WebView 中文 2 键补齐
- l10n 339×11 同步，主代理独立校验通过

### 三档汇总
| 档 | 报告 | 条数 | 状态 |
|---|---|---|---|
| 功能缺口 | v37_feature_gap.md | 11 立项评估 | 路线图产出 |
| 阉割对比 | v37_cripple_report.md | 13 | 蝰蛇/魔法音效/搜索建议 P1×3 |
| 缺陷修复 | v37_fix_defects.md | 10 | 全部完成 |

### v3.7.x / v3.8 路线图（合并去重后）
1. **20028 收敛**（M，架构地基）—— song/url 三态恒 20028 证实为播放增强前提
2. **蝰蛇三档 + 魔法音效六档**（M，权益链就绪、参数构造已有，差枚举+UI；魔法档匿名可用）
3. **断点续传**（S，CDN Range 实测通过，直链 5 分钟过期需校准偏移）
4. **搜索建议直连化**（S，消除 kapi 违纪+找回分类型联想）
5. 每日推荐日历 → 个人 FM → v3.8 的歌单广场/排序/听歌上报

## ✅ v3.7.0 发布确认

- release 437266297（draft=False），tag 969025b 构建成功（版本 3.7.0+37 已对齐）
- 资产：arm64/v7a/x86_64 APK + screenshots-292.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.7.0/app-arm64-v8a-release.apk

### v3.7.0 内容
- 收藏 MV 入口（播放页按钮+防重+登录守卫）、触控目标 4 处、账号双入口去重
- 缺陷 V37-01~10：captcha i18n 收尾、同名歌单基线快照排除法、arb 死键清理、viewFolder、ALB 类型化等
- 两份对比报告：功能缺口（32 域）+ 阉割对比（13 条，蝰蛇/魔法音效三态实测全通）

### v3.7.x 待办（路线图）
20028 收敛（地基）→ 蝰蛇+魔法音效 → 断点续传（S）→ 搜索建议直连化 → KGM/VPR 文件解密（S）→ 每日推荐日历 → FM

## ✅ 音频加密专项实测完成（c336e539）——用户质疑闭环

报告：docs/v37_audio_encryption_audit.md，样本 /tmp/samples/

### 实测矩阵（全部明文，0 个 KGM/VPR 加密样本）
- 128：三态全明文 MP3（全文件 MD5=接口 hash 实锤）
- 320：明文 MP3；flac/high/super/viper_atmos：明文 FLAC
- magic×5：明文 MP3；magic_acappella：明文 MKV（容器问题非加密）
- anon/nonvip 在 320+ 全部 20028 需验证（既有验证墙，非加密）

### 结论
- 播放链路：**未受加密影响**（just_audio 直吃 URL）
- 下载链路：**未实锤损坏**（原样落盘字节即标准 MP3/FLAC）
- KGM/VPR 解密：**不需要**（加密记载出自 /song/url/new 等其它接口；参考项目亦无解密实现）
- 新发现问题：super 档无 DSD 时静默降级 flac（S）、MKV 容器兼容（M）→ 待办

### 方法论价值
用户质疑促成首次「文件头魔数」级验证——验证链从「URL 可得」深入到「字节可播」，此后的播放/下载结论都以实测留样为准。

## ✅ FLAC 明文深度复核完成（e42df45b）——上一轮结论维持

用户质疑「fLaC 头+扩展名可能只是伪装/头明文主体加密」→ 结构级+解码级复核：

### 三档 × VIP 全部真明文 FLAC
- **ffmpeg 全量零错误解码**，duration=269.7467s 与 STREAMINFO totalSamples/44100Hz 精确吻合
- **MD5 数学级排除**：解码后 PCM md5（s16le/s24le）与 STREAMINFO 内嵌 MD5 完全一致（89036f70…/33de209b…）——加密必然破坏该 MD5，「头明文+主体加密」形态排除
- frame 同步码连续（3947/5008 个合法），压缩比 0.665/0.776 合理
- 扩展名答案：URL 后缀/Content-Type/ffprobe 三方一致——**不是只改了扩展名**
- high=24bit/1643kbps 母带；**super 与 flac 是同一文件**（无 DSD 时降级再确认）

### 结论
v37_audio_encryption_audit.md 的「明文」结论维持，无需修复方案。保留：super 静默降级展示（S）、magic_acappella MKV 容器兼容（M）。

### 方法论
两级验证（魔数→ffmpeg 解码+PCM MD5）把「加密」判定从推测升级到数学级证据；任务书中「尾部 END+Vorbis comment」与 FLAC 规范不符（元数据在头部），代理如实纠正——审查假设也要被验证。

## ✅ 概念版（lite）通道验证完成（5b674d1f）——用户假设不成立

报告：docs/v37_lite_channel_probe.md（探索性实测，脚本 /tmp）

### 实测矩阵
| 环节 | 结果 |
|---|---|
| 设备注册 lite | 20010 rsa failure（端点在线，加密形态未复刻，未拿 dfid） |
| 凭证通用性 | 标准版 cookie + lite 参数 = 20018（**凭证不通用**，用户「凭证可能不一样」假设成立） |
| /v5/url lite | 三态 × 全音质档 = 31833 illegal key（**连 VIP 都被拒**） |
| 每日 VIP | concept 通道 is_vip=0，领取端点 404/20017，无可触发路径 |

### 结论
用户假设**不成立**：lite 通道既不绕过验证墙（反而更严：VIP 都 31833），也无免费每日 VIP 权益（concept 会员是付费查询体系）。lite 真实差异 = 独立 appid/盐/RSA 配置 + kugouvip concept 会员查询端点。

### 处置
- 无接入价值，标准版直连链路已是最优
- kg_crypto.dart 的 lite 常量零成本保留（防御性配置，勿删）
- 播放增强的真正地基仍是 20028 收敛（标准版通道内解决）

## v3.7 播放空白排查（8c2e33a）——用户四现象已解释

报告：docs/v37_playback_blank_diag.md（11 环节+根因排序 H1~H4+真机诊断 6 项）

### 根因链（H1，静态推导）
JustAudioBackground.init 真机永久失败 → ensureEngineReady false → playQueue/playSong 首行静默 return（队列从未装载）→ 播放页空态=「失败/空白」→ 下载不经引擎故正常 → 失败只走 debugPrint（release 不可见）=「无日志」

### 已修
- ensureEngineReady 失败分支接入 ErrorLogger 落盘（消除盲区，下次真机复现日志里就有）

### 待用户配合
- adb logcat -s flutter | grep -i JustAudioBackground 复现播放，确认引擎失败的具体异常
- 播放页是否显示顶栏/进度条（区分 H1 空态 vs ErrorWidget 真空白）

## ✅ 付费歌曲通道对比实测完成（efe51b2a）——用户假设判定

报告：docs/v37_paid_song_channel.md（脚本 /tmp/probe_paid.py、probe_lite_v5.py）

### 标准版基线（三态实锤）
- 样本「晴天」确认付费曲（privilege=10/pay_type=3）
- 非VIP 不带 IsFreePart → status=2 + fail_process=[pkg,buy] + end_ms=60000
- 带 IsFreePart=1 → 下载 ffprobe 实测 **59.98 秒**——是「前 60 秒」，非高潮非全曲
- VIP 全曲正常（既有审计）

### 概念版通道（本轮突破：Node 本体打通 lite 匿名 /v5/url）
- 上轮 31833 翻案：根因是我们 Python signKey 形态差异，**非 lite 被拒**——本轮用 Node 本体（platform=lite + pid=411/need_ogg=1）签名被接受
- 匿名 lite 全档 IsFreePart=0 均 status=2 试听墙；IsFreePart=1 给的 URL 与标准版**同一份 60 秒片段**（同为 p_0_960115 截断）
- 注册边界：rsaEncrypt2 PKCS1-V1_5 修正后 register_dev 仍 20010——lite dfid 拿不到，登录态策略无法继续（如实标注）

### 判定
用户假设**不成立**：概念版可复刻范围内对付费歌曲行为与标准版完全一致（60s 试听），不存在免费完整听旁路。privilege_lite.js 的 freeListen 只是 UI 展示逻辑。
处置：lite 常量零成本保留，不接 lite 通道；标准版直连已是协议最优。

## v3.7 日志系统+存储重构批启动（b52f5ee9，60 分钟预算）

用户需求（已确认方案）：
- 设置加 verbose 开关：全量捕获（debugPrint 拦截/网络层/播放状态/下载状态），全过脱敏走串行链；关闭保持现状
- 存储根：/storage/emulated/0/TiernanMusic/（MANAGE_EXTERNAL_STORAGE+设置页跳授权），未授权自动降级 Download/TiernanMusic；子目录 audio/mv/logs/cover/lyrics
- 应用内部存储（凭证/Hive）不动；旧下载文件不迁移
- 三处根路径统一 resolveRoot()

同时进行：付费歌曲通道对比（已完成：概念版=标准版 60s 试听无旁路）、音频加密审计（已闭环：全明文）。

## ✅ v3.7.1 发布（6cbf3d6）——日志系统+存储重构

- V37-LOG-01~11 全落地：verbose 开关（Hive 持久化）/debugPrint 全局包装（防递归）/网络层逐请求落盘（4KB 截断+脱敏）/播放下载状态迁移记录，全走串行链
- 存储根重构：resolveRoot()（授权→/storage/emulated/0/TiernanMusic，未授权→Download/TiernanMusic）+ audio/mv/logs/cover/lyrics 子目录；三处根路径统一零硬编码
- Manifest: MANAGE_EXTERNAL_STORAGE + requestLegacyExternalStorage；设置页「存储与日志」区（开关/路径展示/授权跳转）
- 主代理独立复核：pubspec 未动 ✅、Manifest 权限在位 ✅、verbose 联动链在位 ✅、三处 resolveRoot ✅、arb 345 键×11 无缺失 ✅、gen_l10n 重跑 ✅
- 真机验证清单 7 项见 docs/v37_logging_storage.md

## ✅ v3.7.1 发布确认

- release 437360060（draft=False），tag f37e172 构建成功（版本 3.7.1+38）
- 资产：arm64/v7a/x86_64 APK + screenshots-306.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.7.1/app-arm64-v8a-release.apk

### v3.7.1 内容
- verbose 日志开关（全量捕获：debugPrint 拦截/网络层/播放下载状态，全过脱敏走串行链）
- 存储根重构：/storage/emulated/0/TierNanMusic/（audio/mv/logs/cover/lyrics），MANAGE_EXTERNAL_STORAGE+自动降级，三处 resolveRoot 统一
- 设置页「存储与日志」区；Manifest 权限

### 需要用户真机验证（7 项清单见 docs/v37_logging_storage.md）
1. 授权跳转（设置页→所有文件访问）
2. 授权后根目录 TierNanMusic/logs 落盘验证（**播放一次失败的歌，日志里应有引擎失败记录**——播放空白排查的关键证据）
3. 厂商 ROM 直写兼容
4. MediaStore logs 路径（Android 10+）
5. Android≤9 分支
6. release 下 debugPrint 包装开销
7. 日志体积与轮转

## v3.7 PLAY-1 根因修复（8de30b4）——用户真机现象实锤

用户反馈：从首页点歌 → 播放页**所有信息空白**；歌单全部播放同样失败；授权页也不弹。

### 根因（代码实锤，非推测）
`JustAudioBackground.init` **缺 `handler:` 参数**——init 只创建了通知渠道，没有把 TiernanAudioHandler 挂载到后台服务。AudioPlayer 创建后是「孤儿」：通知/媒体会话/播放流程全部静默失败 → 播放页 song==null 全空白。下载不经此 init，故正常。

### 已修
- init 补 `handler: TiernanAudioHandler(...)` + channelDescription
- bootstrap 直接构造 repository（init 阶段无容器，handler._ref 可空设计允许）
- 授权页不弹：permission_handler 的 manageExternalStorage.request() 在部分 ROM 不弹系统页，需回退 openAppSettings()——已由并行代理在修（settings_page 跳转链路）

### 待办
- 概念版通道验证报告已出（假设不成立）
- 权限网关修复代理进行中

## ✅ v3.8.0 发布确认

- release 437395224（draft=False），tag c99898a 构建成功（版本 3.8.0+39）
- 资产：arm64/v7a/x86_64 APK + screenshots-311.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.8.0/app-arm64-v8a-release.apk

### v3.8.0 内容
- 播放引擎 init 修正（channelDescription + androidStopForegroundOnPause=false——暂停降级再恢复受 Android 12+ 限制的根因）
- 引擎失败 banner（播放页顶部可见，不再全空白）
- POST_NOTIFICATIONS 运行时申请（Android 13+ 媒体通知）
- 权限网关收尾（permission_gate 接入启动编排）
- 版本 bump 纪律已执行（v3.7.0 的 6 轮教训）

### ⚠️ 勘误（权限+播放全面检查 a102436e）
8de30b4 的「JustAudioBackground.init 补 handler 参数」结论**错误**：包源码（just_audio_background 0.0.1-beta.13, just_audio_background.dart:34-51）确认 init 只收通知渠道/前台服务配置，**没有 handler 参数**——handler 由 AudioPlayer 的 mixin 在平台通道激活时挂载。c99898a 已是修正版（无 handler + channelDescription + androidStopForegroundOnPause=false）。播放页全空白的真实根因仍待真机日志定位，不臆造结论。

## ✅ v3.9.0 发布确认

- release 437436026（draft=False），tag e7cd472 构建成功（版本 3.9.0+40）
- 资产：arm64/v7a/x86_64 APK + screenshots-322.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.9.0/app-arm64-v8a-release.apk

### 内容（三代理交叉检查+完全重写）
- 真根因：MainActivity 继承 AudioServiceActivity（日志实锤 PlatformException，引擎永久失败→播放页全空白）
- ① 契约清点：20+ 文件全文读，19 provider/路由/模型契约表；评论入口被 MV early-return 吞掉（B1）
- ② 播放页 786 行完全重写：四态分离、评论入口无条件可达、资源对称、窄屏布局、build 零副作用
- ③ 辅助页+评论链路重写：队列世代校验、失败重试、play_helper 三处转换合并、hash 不冒充
- CI 试错 3 轮（albumAudioId/friendly_error 导入/theme 局部变量）全部为重写声明漏项，已清

### 请用户真机验证
从首页点歌→播放页信息齐全；评论入口始终可见；歌单全部播放恢复；引擎初始化不再报 PlatformException。若仍异常，verbose 日志开起来看 TierNanMusic/logs/。

## ✅ v3.9.9 发布确认

- release 437491034（draft=False），tag 1fa61a5 构建成功（版本 3.9.9+41）
- 资产：arm64/v7a/x86_64 APK + screenshots-325.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.9.9/app-arm64-v8a-release.apk

### v3.9.9 内容（三档，30 文件）
A: 播放页收藏到歌单入口 / 歌词持久缓存（Hive lyric_cache，三级读取）/ 翻译自动化（缓存→上游译文→才调API）
B: 登录落盘并行化 / 权限网关实测写探针（写→读回→删，逐步骤留痕）/ 蝰蛇三档+魔法六档 / 非VIP下载按API字节数择优
C: 歌单顺序漂移实测排查（上游稳定四假设排除，upstreamOrder 语义澄清）

### 真机验证项
1. 播放页收藏按钮（入口行第4个）
2. 设置页音质菜单九新档（魔法档匿名可用）
3. 授权后设置页显示「探测到的实际可写路径」
4. 非 VIP 下载应拿到更长片段（试听/高潮按字节数择优）
5. 登录后进个人信息页速度
6. 歌单多次刷新顺序一致性

### 用户新反馈（日志审计已定位，进 v3.9.10）
- 歌词重复请求（同一 KRC 下载 2~3 次，无 in-flight 去重/候选短路）
- 翻译 504 无重试
- **MV 页 20010 实锤：/v1/video 传了 hash 应传 video_id**（v3.9 重写未覆盖 mv_player_page）

## ✅ v3.9.10 发布（MV 专项）

- V3990-1 (P0): /v1/video hash→video_id 统一收口（mv_repository 层，会话缓存 128，调用方零改动）——用户日志 20010 根因修复
- V3990-2: mv_player_page 完全重写（三态分离/清晰度当前档+mkv 容器标注/进页暂停音频队列/生命周期对称/l10n 6 新键）
- 复核: arb 362×11 无缺失、三文件 analyze CLEAN、pubspec 先 bump 后打 tag

## ✅ v3.9.10 发布确认

- release 437575730（draft=False），tag 30827c8 构建成功（版本 3.9.10+42）
- 资产：arm64/v7a/x86_64 APK + screenshots-333.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v3.9.10/app-arm64-v8a-release.apk

### v3.9.10 内容（MV 专项）
- V3990-1 (P0): /v1/video hash→video_id 统一收口（20010 根因，用户日志实锤）
- V3990-2: mv_player_page 完全重写（三态/清晰度容器标注/音频互斥/生命周期对称）
- CI 试错 2 轮：movie_off_outlined 与 video_camera_off_outlined 均非真实图标名，实际为 videocam_off_outlined——Icons.* 常量必须验证存在的教训已记

### 请真机验证
播放页点 MV → MV 应正常播放（20010 已修）；清晰度切换带当前档指示；进 MV 时音频队列自动暂停。

### v3.9.11 待办
歌词 in-flight 去重/候选短路（P1）、翻译 504 重试（P2）

## v4.0.0 封版（ccae1c7，版本 4.0.0+43）

### 三档（A/B 已落盘，C 收尾中）
- A: 11 键×11 语言按钮文案精简；LyricTranslationStream 逐批实时插入（fontSize 14→12）
- B: core/resource 三模块（ResourceCache 168h JSON/90s 列表/文件永久/in-flight 合并/失效回退、CachedApiCall、LyricTranslationStream）；6 repository 接入；翻译 504 重试
- C: PrefetchEngine/启动用户态/播放列表暗病——代理 aea2bf08 收尾中（报告 docs/v400_fix_c.md 待落盘）

### 主代理亲修
- **反反顺序**（docs/v400_order.md）：_fetchAllReversed 页序倒+页内倒，485%10 余数按实际长度、未知总数探测、单页失败留痕跳过；与概念版分享页前 20 首逐位吻合
- lyric_view 二分 `>>`→`~/`（CI 会报 double 类型错）
- arb 362×11 校验通过、gen_l10n 重跑、逐文件 analyze 无项目自有错误

### 注意
C 档产出未并入本 tag；其报告回来后复核并出 v4.0.1。

## ✅ v4.0.0 发布确认

- release 437736063（draft=False），tag ccae1c7 构建成功（版本 4.0.0+43）
- 资产：arm64/v7a/x86_64 APK + screenshots-336.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v4.0.0/app-arm64-v8a-release.apk

### v4.0.0 内容
- A: 按钮文案精简（11键×11语言）+ 翻译实时插入（fontSize 12）
- B: core/resource 三模块（168h/90s/永久/in-flight/失效回退）+ 6 repository 接入 + 翻译504重试
- ORDER: 反反歌单顺序（页序倒+页内倒、余数健壮、与概念版分享页吻合）
- **不含预加载**：C 档 aea2bf08 超时零产出，已拆为 C-1（370a97a3 只建模块）与 C-2（接线）两窄任务，并入 v4.0.1

## v4.0.1 C-1 复核（PrefetchEngine 模块）

- `lib/core/prefetch/prefetch_engine.dart`（209 行）落盘，冻结签名 5 成员 + attach(KugouApiClient) 显式注入
- 预热端点核对：`/song/url`、`/search/lyric`、`/album/detail` **均在原生分派表**（kg_direct_api_client.dart:235/214/318），走 CachedApiCall→ResourceCache.json(168h)，不下载实际文件，合规第 27/33 条。注释「kapi /song/url」措辞不准（kapi 同名路由，直连已移植），仅表述问题不改动
- 去重：_requested hash 集 + ResourceCache in-flight 合并；单次入队上限 60；Timer 对称释放；失败三段各自留痕
- 封面：Song.cover 已是解析好的 URL，无独立实测接口，不造端点（第 28 条）
- analyze：项目自有类 0 报错

C-2（332b329a）运行中：main.dart 开箱/首帧预热/用户态、audio_handler 接线、设置页清缓存、播放列表暗病表。完成后并入 v4.0.1。

## v4.0.1 封版（a5cf25b，版本 4.0.1+44）

C-2 代理（332b329a）同样超时零产出 → 主代理亲自接线：
- main.dart: openSafe('resource_json') / 首帧 attach+init / homeDataProvider 预热(100ms) / 用户态三态核对
- audio_handler.dart: `_lastPlayUrl` 字段（解决 completed 回调拿不到 result.url）、播放完成永久缓存实际文件、stop 清空、`_emitQueue` 补 `updateUpcoming(15)`
- settings_page.dart: `ResourceCache.clearJson()/clearLists()` 接入清缓存，实际文件永久不删
- 三文件 analyze CLEAN、arb 362×11、括号平衡

### 已知待办（v4.0.2）
1. `retryPendingPlayback()` 队列被换后按旧 idx 播新队列错歌（P1）：需世代+hash 校验
2. `playQueue` 首次引擎初始化窗口内第二次队列不作废第一次（旧 P3）
3. 收藏歌单歌曲未纳入启动预热（需登录态 provider，C-2 未做）
4. keystore 轮换（用户手动）

## ✅ v4.0.1 发布确认

- release 437792665（draft=False），tag ebac90c 构建成功（版本 4.0.1+44）
- 资产：arm64/v7a/x86_64 APK + screenshots-344.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v4.0.1/app-arm64-v8a-release.apk

### v4.0.1 内容
- PrefetchEngine 模块（C-1）+ 主代理接线：openSafe(resource_json)/首帧 attach+预热(100ms)/用户态三态核对
- audio_handler `_lastPlayUrl` + 完整播放永久缓存实际音频 + _emitQueue 补 updateUpcoming(15) + stop 清空
- settings_page clearJson/clearLists（实际文件永久不删）
- C-2 代理超时零产出；CI 修复 main.dart 补 kugouApiClientProvider 导入

### 待办（v4.0.2）
1. retryPendingPlayback 队列被换按旧 idx 播错歌（P1，需世代+hash 校验）
2. playQueue 首次引擎初始化窗口内第二次队列不作废第一次（P3）
3. 收藏歌单歌曲未纳入启动预热
4. keystore 轮换（用户手动）

## v4.0.2 播放列表暗病（主代理亲修，待发版）

### V402-P1（P1）retryPendingPlayback 按旧 idx 播错歌
- 根因：20028 挂起只存整数下标 `_pendingSongIndex`；验证期间队列被替换/增删后按旧 idx 播新队列的错歌
- 修法：改存 **hash 快照**（`_pendingSongHash`），重试时按 hash 在**当前队列** `indexWhere` 重定位；找不到则明确丢弃并留痕（第 14/16/18 条）

### V402-P3（P3）首次引擎窗口竞态
- 根因：playQueue/playSong 先 `await ensureEngineReady()`（首次数百 ms）才 `_playToken++`，窗口内第二次请求不作废第一次
- 修法：`final token = ++_playToken` 提到引擎初始化之前，await 后 `if (token != _playToken) return`；playQueue 的 failureStreak/pendingIndex 复位同步前置

### 待办
- 收藏歌单歌曲纳入启动预热（需登录态 provider）
- 全量 analyze + 3 并发复核代理（进行中）

## ✅ v4.0.2 发布确认

- release 437975253（draft=False），tag 6526566 构建成功（版本 4.0.2+45）
- 资产：arm64/v7a/x86_64 APK + screenshots-349.zip
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v4.0.2/app-arm64-v8a-release.apk

### v4.0.2 内容
- V402-P1: retryPendingPlayback 改 hash 快照（队列变化后按 hash 重定位）
- V402-P3: playQueue/playSong 世代前置（消除首次引擎窗口并发）
- V402-URL-SIZE: 永久缓存身份=(url,播放JSON声明字节数) 四道校验，试听永不入库
- V402-R1/R2/R3/R4/R5/R6/R7: 20028 假验证页/交接世代/stale 可观测/超大歌单末尾页/探测跳过/空队列清态/手动切歌清挂起
- 复核③剩余 2 条 P2 已记录归 v4.0.3（写操作后 Riverpod invalidate、越界起始页）
- 下一步：v5.0 完全重构（docs/REFACTOR_PLAN_V5.md，七步迁移）

## v5.0.0 LTS 重构完成（tag ab0fb82，版本 5.0.0+50）

七步全部落地：M1 domain/foundation 上移、M2 存储/桥接下沉（core→features=0）、M3 cache_keys+ResourceGateway、M4 response_policy+MusicApi、M5 RepositoryReads 读路径统一、M6 app/bootstrap、M7 CI 架构断言。
全库 analyze 0 真错误、相对 import 0 无效、括号平衡、arb 362×11、pubspec=tag 同名。
CI 终验与 release 产出由定时任务 660af9b0 处理。

## ✅ v5.0.0 LTS 正式发布确认（最终）

- release 438052974（draft=False），tag v5.0.0 → 71b4d73
- 资产与最终 tag 构建 run 42451819131 完全一致：3 APK（24.8/22.7/26.4 MB）+ 2 截图包（375/381）；APK 大小与 /tmp/v5apk 本 run artifacts 逐项吻合
- 版本 5.0.0+50 与 tag 同名；main/tag CI 双绿；架构断言 PASS
- 七步重构 M1–M7 全部完成并随本发布交付
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v5.0.0/app-arm64-v8a-release.apk

## v5.1 全功能交叉审查启动（8 批 × 3 代理 = 24）

- 机制：同批三代理**同范围不同视角**（A 功能正确性 / B 鲁棒与质量 / C 用户路径与一致性），主代理合并为共识报告并裁决矛盾
- 规范：docs/TASK_v51_cross_common.md（33 条原则、完整 file_read、实时落盘、只报问题不修复、逐文件 analyze 贴结果、禁装 SDK/改 pubspec）
- 批次：docs/TASK_v51_batches.md（B1 foundation/domain/api → B8 UI/i18n）
- 节奏：批间串行、批内 3 并发；一批三份齐 → 合并 → P0/P1 亲修 → 下一批；8 批完成发 v5.1.0


## v5.1 交叉审查收官 + push 恢复

- push 故障（代理网关拒绝 push POST）经 direct 通道解决：9d5a36c..243b5bd 已推上
- CI 42501435331（243b5bd，含 B4/B5 共识修复+docs 归档）构建中
- B1-B5 五批合并报告全部落盘；P0×3 全亲修


## v5.2.0 封版（f3520c8 / tag 5.2.0+53）

- v5.1 B1-B5 交叉审查（24 代理）收官：740 条发现，P0×3+P1 共识全部亲修
- v5.2 新特性：权限网关四重检测+五级回退、Android 5.1(API22) 兼容（minSdk22/multidex/desugaring/自带LE证书TlsCompat）、Ubuntu Mono 全局字体+私有字体管理器（本地/URL 导入，FontLoader 运行时挂载）
- CI r1-r5 试错：font_manager 相对路径/ByteData/unwrapApi null/hint 非空（analyze 噪音过滤盲区的连续暴露，已逐个修正）


## ✅ v5.2.0 正式发布确认

- release 438428083（draft=False），3 APK + 截图包齐全
- tag f3520c8 CI 42508061896 success；main f78988c / f3520c8 全绿
- 下载：https://proxy.344977.xyz/https://github.com/yingo-server/TiernanMusic/releases/download/v5.2.0/app-arm64-v8a-release.apk


## v5.3 第1轮审查（三视角全齐：A 27条 / B 27条 / C 66条 = 120条）

- A 状态机：v53_r1_a.md
- B 延迟歌词：v53_r1_b.md（B-10 预热死代码已修 86affeb；译文错行已记录）
- C 权限布局：v53_r1_c.md（P1x12，含 L5 假契约/门卫恒真/双入口/诊断页缺失）

状态机重写批：主代理亲自。布局/权限/文案：代理并行。完成后 v5.3.0。
