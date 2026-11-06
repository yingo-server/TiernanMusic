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
