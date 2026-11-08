# Tiernan Music v2.0.0 LTS — 收尾总规划

> 版本：2026-11-05 · 基线 `131fa50` + 工作区 34 文件改动
> 原则：**代码质量和架构优先**；一次 push；子代理单个串行、只报告不修复、实时落盘；修复与验证由主代理亲自做
> 本文细化到**每一个功能和按钮**，按阶段执行，每阶段有明确验收

---

## 〇、现状盘点（截至本文）

### 0.1 已完成的主体

- 66 个 Dart 文件 / 约 25.6k 行；50 个直连端点（原生域名 + 4 种签名与 Node 逐字节一致）
- 三态实测归档（`docs/api_verified.md`，24 端点 × 匿名/VIP）
- 5 批 × 3检3修完成 4 批 + 终审 C 报告；CI 全绿（analyze/test/build-apk）
- 功能：播放/搜索/首页/歌单/评论/MV/歌词(KRC+翻译)/下载/离线播放/登录(短信/密码/二维码+TCaptcha)/多账号/最近播放/设置/10 语言
- 新增未提交：歌手页、专辑页、榜单页、歌单新→旧排序、用户歌单详情、评论分类热词 chips、登录守卫、播放器状态流修复、Hi-Res 协议修复、离线播放 localPath 保持、清缓存保护、最近播放串行化、动态 SVG 启动页、死代码清理

### 0.2 未提交改动风险

工作区 34 个文件改动 + 1 个 stash，**必须先收敛**：本地静态全检 → 单 commit → CI 验证，之后才能进入下一阶段。

### 0.3 子代理事故复盘

| 事故 | 根因 | 对策（本文已固化） |
|------|------|------------------|
| 代理在本机装 Node 跑 kapi | 任务书未禁止"本地起服务" | 禁止清单逐条列全（含 node/npm 起服务） |
| 503 / DNS / 连接重置 17 次 | 模型过载 + resolv.conf 被改 | 单代理串行；每次派发前查 DNS；失败即主代理亲自接手 |
| 读完文件没落盘就超时 | 「最后写报告」模式 | 强制**边读边 append**，超时不丢产出 |
| 报告含大量"建议修法" | 未约束 | 只写「问题+位置+依据+级别」 |
| 代理跑了网络测试 | 未禁止 | 禁止任何网络请求，只做代码比对 |

---

## 一、阶段总览（5 个阶段，严格串行）

```
S0 收敛工作区（主代理）          —— 半天
S1 网络层终审修复（主代理）       —— 半天
S2 功能与按钮逐个过审（主代理+1检查代理） —— 1~2 天
S3 质量与架构收口（主代理）       —— 半天
S4 发布验证（主代理）            —— 半天
```

每阶段出口条件写死；不满足不进入下一阶段。全程**只允许一个子代理**存在（只读检查、实时落盘、不测试不修复）。

---

## S0：收敛工作区（出口：CI 绿 + 干净的 main）

### S0.1 本地静态全检（主代理）
- [ ] 括号配平（check_braces.sh）
- [ ] 坏 import 扫描
- [ ] l10n 完整性（用了 226+ key vs ARB 305）
- [ ] provider 引用完整性（66 个 provider 全有定义）
- [ ] 组件参数匹配（EmptyState/SongTile/SectionHeader）
- [ ] 死代码清零：`proxyMvUrl`、`diskCacheMaxMb/MaxAge`、`refreshDeviceContext`、`KugouApiClient.mid`
- [ ] stash 处置：`stash@{0}` 检查后丢弃或合并

### S0.2 网络层已知问题修复（来源：check_01_network.md，主代理亲自）
- [ ] **N1** `KgResponse.isOk`：`status == 200` 也算成功（歌词实测）；同时 `_wrap` 已加 200 分支，保持一致
- [ ] **N2** `KgResponse.errorCode` 读取 `err_code`（mcomment 业务码），`_wrap` 已读但 `KgResponse` 未读——统一
- [ ] **N3** Dio 加 `sendTimeout: 30s`（设备注册/云歌单/歌词下载较慢）
- [ ] **N4** `_needsVerify` 扩展：任何失败响应**带 ssa-code** 都进入验证流程（对齐 Node request.js:234-246），不只 20028

### S0.3 提交与 CI
- [ ] 单 commit push；CI analyze/test/build-apk 全绿
- [ ] 不打 tag（等 S4）

**出口条件**：CI 绿、工作区干净、0 死代码。

---

## S1：网络层终审（主代理 + 1 个检查代理收尾）

### S1.1 主代理自查清单（每个直连 case 逐条过）

以 `docs/api_verified.md` 为基准，逐 case 核对：

| # | 端点 | 核对点 | 状态 |
|---|------|--------|------|
| 1 | search(song/album/special/author/mv/lyric) | v3 路径、字段、分页 | ⬜ |
| 2 | comment/music | query 形态（非 body）、`_wrap`、err_code | ⬜ |
| 3 | comment/count | 裸 Map、web 签名 | ⬜ |
| 4 | comment/floor | 三套 code + 双端点（song/playlist/album） | ⬜ |
| 5 | comment/send/reply/del | `clearDefaultParams+notSignature`、key=signParamsKey(ct+mid+data) | ⬜ |
| 6 | playlist/detail | body `data:[{gid}]`、数组首项 | ⬜ |
| 7 | playlist/track/all | gid vs specialid 自动切换、begin_idx | ⬜ |
| 8 | user/playlist、track/all/new | 登录态、POST | ⬜ |
| 9 | playlist add/del/tracks | AES+RSA 加密体、二进制响应 | ⬜ |
| 10 | artist/detail,audios,albums | v1 端点（List）、kg-tid 220、clienttime 秒级 | ⬜ |
| 11 | album/detail,songs | 嵌套结构解析 | ⬜ |
| 12 | rank/list,audio | POST、data{total,songlist} | ⬜ |
| 13 | song/url | key 必填、url/backupUrl 数组、IsFreePart | ⬜ |
| 14 | privilege/lite | resource[type=audio]、qualities 数组、relate_goods | ⬜ |
| 15 | video/detail,url | video_id→hash、Range 直连 | ⬜ |
| 16 | kmr/audio/mv | album_audio_id（非 mixsongid）、KG-TID:38 | ⬜ |
| 17 | lyric search/download | status=200 语义、ver=1、charset | ⬜ |
| 18 | login 系列 | v7/v9、web 签名、t1 秒级 | ⬜ |
| 19 | captcha/verify | ssa-code 捕获、v_type 分支 | ⬜ |
| 20 | everyday/yueku/top | platform=ios 必传、缓存策略 | ⬜ |

### S1.2 检查代理（单个，串行）
任务书要点：
- 范围：S1.1 清单中标注 ⬜ 的项，逐条与 Node 源码比对
- 实时落盘：`docs/check_02_endpoint_matrix.md`，**每核完一条立刻 append**
- 只写「一致/不一致 + 位置 + 依据」，不写修法、不发请求、不改文件
- 主代理对其结论逐条复核后修复

### S1.3 回归
- [ ] `test/lyric_test.dart`（真实 KRC 样本）通过
- [ ] 新增 2 个测试：`_wrap` 对 status=200；`AudioQuality.fromString('hires')`

**出口条件**：S1.1 全部 ⬜→✅；检查代理报告复核完毕；修复全部落地。

---

## S2：功能与按钮逐个过审（细化到每个交互点）

### S2.1 页面与交互点清单（23 页 / 146 交互点）

**A. 首页（home_page.dart）**
- [ ] 轮播图：点击跳转目标（当前缺失 → 跳 banner 关联页或禁用）
- [ ] 每日推荐卡：点击播放整组（已接）；**长按 → 下载菜单**（待接）
- [ ] 推荐歌单卡：点击 → `/playlist/{gid}`（已接）
- [ ] 排行榜卡：点击 → `/rank/{rankid}`（已接，需验证参数名）
- [ ] 新歌行：点击播放（已接）；**尾列「更多」按钮**（menuItems 已接）
- [ ] 下拉刷新：清缓存 + refresh（已接）；**刷新时轮播 Timer 复位**（待查）
- [ ] Banner Timer：非当前 Tab 停翻页（已接）；**App 退后台也要停**（WidgetsBindingObserver 已有，验证）

**B. 搜索页（search_page.dart）**
- [ ] SearchBar：清除按钮（ValueListenableBuilder 已接）；提交→搜索
- [ ] 5 个 Tab：歌曲/歌单/专辑/歌手/MV
- [ ] 歌曲 Tab：分页、失败重试按钮（已接）、点击播放
- [ ] **专辑 Tab：点击 → `/album/{albumid}`（已接，需验证 ID 来源字段）**
- [ ] **歌手 Tab：点击 → `/artist/{AuthorId}`（已接，需验证）**
- [ ] MV Tab：点击 → `/mv/{MvHash}`（已接）
- [ ] 热搜词：点击填入搜索框（**待接**——目前只显示）
- [ ] 搜索历史：点击搜索、单删、清空（已接）
- [ ] 空态：无结果 → EmptyState（已接）

**C. 播放器（full_player_page.dart + mini_player.dart）**
- [ ] 播放/暂停大按钮：状态流已修（P0-1），验证
- [ ] 上一首/下一首：队列循环模式行为
- [ ] 随机/循环切换：isSelected 图标回显（P0-1 修复点，验证）
- [ ] 进度条：拖动 seek、缓冲色、时长显示（P0-1 修复点）
- [ ] **音质标签：显示实际播放音质**（actualQualityProvider 已有，UI 需渲染——待接）
- [ ] **试听角标：60s 试听显示「试听」标识**（previewProvider 已有，UI 需渲染——待接）
- [ ] 队列按钮：底部弹层、点击切歌（已接）
- [ ] 歌词按钮：封面/歌词切换（已接）；歌词点击行 seek（已接）
- [ ] 歌词滚动：自动跟随 + 手动 5s 暂停（已接）
- [ ] 下载按钮：→ DownloadSheet（已接）；**音质取默认设置**（P1-4 已修，验证）
- [ ] MV 按钮：有 MV 才显示（已接）；点击 → `/mv/{hash}`（已接）
- [ ] **评论按钮：→ `/comments/song/{albumAudioId}`（已接，需验证 ID 正确性）**
- [ ] 迷你播放器：点击进全屏、长按队列、进度条（已接）

**D. 歌单详情（playlist_detail_page.dart）**
- [ ] 收藏按钮：登录守卫 + collectPlaylist（已接）；**已收藏状态显示**（待接——上游无查询接口，先不做）
- [ ] 播放全部按钮（已接）
- [ ] 歌曲行：点击播放/更多菜单（已接）
- [ ] 评论入口：→ `/comments/playlist/{gid}`（已接）
- [ ] **用户歌单模式：`?user=listid` 时用 fetchUserTracks（已接，需验证路由 query）**
- [ ] 简介展开/收起（已接）

**E. 歌手页（artist_page.dart，新）**
- [ ] 头部：头像/名字/粉丝数/三Tab（歌曲/专辑/简介）
- [ ] 歌曲 Tab：分页、sort=hot/new 切换（**待接切换按钮**）
- [ ] 专辑 Tab：点击 → `/album/{album_id}`（已接）
- [ ] 简介展开（已接）
- [ ] 播放全部（已接）

**F. 专辑页（album_page.dart，新）**
- [ ] 头部：封面/专辑名/歌手/发行日期
- [ ] 歌曲列表：嵌套结构解析（已接）
- [ ] 播放全部（已接）
- [ ] **发行日期/语言/热度展示**（数据已解析，UI 待补）

**G. 榜单页（rank_detail_page.dart，新）**
- [ ] 榜单歌曲列表：`data{total,songlist}`（已接）
- [ ] 播放全部（已接）
- [ ] **榜名标题显示**（已接）

**H. 评论页（comments_page.dart + comment_floor_page.dart）**
- [ ] 分类标签/热词 chips（**本轮新接**，验证渲染）
- [ ] 发送：登录守卫（已接）；20028 → CaptchaPage（已接）
- [ ] 楼中楼入口：replyCount > 0（已接）
- [ ] 删除自己的评论（已接）
- [ ] 分页 + 代次防串（已接）

**I. 下载（download_sheet/download_page）**
- [ ] 四类型下载（音频/封面/歌词/MV）（已接）
- [ ] 音质取默认设置（P1-4 已修）
- [ ] 权限：首次下载申请（已接）；拒绝降级提示（已接）
- [ ] 暂停/继续/重试/删除（已接）
- [ ] 清缓存不删 downloads_tmp（P1-6 已修）

**J. 音乐库（library_page.dart）**
- [ ] 账号卡（watch authState 已接）
- [ ] 我的歌单：**点击 → `/playlist/{gid}?user={listid}`（本轮已接，验证）**
- [ ] 最近播放：串行化写入（P1-7 已修）；点击播放；清空确认
- [ ] 已下载：**点击离线播放**（P1-5 已修）；删除
- [ ] 收藏 MV 列表（**本轮新接**，验证）

**K. 设置页（settings_page.dart）**
- [ ] 账号区：登录/退出/切换（已接）
- [ ] 外观：主题/语言（已接）
- [ ] 播放：默认音质（P0-2 已修 hires→high+super）
- [ ] 下载管理入口（已接）
- [ ] 缓存：统计口径（已修）；**清缓存排除 downloads_tmp（已修）**
- [ ] 诊断：日志位置/权限/最近错误（已接）
- [ ] 关于：检查更新（已接）
- [ ] **死开关处置：wifi/cellular 两个开关**（本轮决策：UI 加「即将推出」徽标并禁用）

**L. 登录页（login_page.dart）**
- [ ] 短信/密码/二维码三 Tab（已接）
- [ ] 多账号选择弹层（已接）
- [ ] 20028 → CaptchaPage → 自动重试（已接）
- [ ] QR 切 Tab 停轮询（已接）

### S2.2 执行方式
1. 主代理按上面清单逐项核代码（每个交互点读实现）
2. 发现问题当场修；**不动网络层**（S1 已收敛）
3. 全部勾完后，派 1 个检查代理（单个串行）：
   - 任务书：按 S2.1 清单逐条验证代码实现存在且正确
   - 实时落盘 `docs/check_03_ui.md`；只写「功能点 + 结论 + 位置」
   - 禁止：修代码、跑构建、发请求、装东西
4. 主代理复核其报告 → 修复遗留 → 进入 S3

**出口条件**：S2.1 清单全部 ✅；检查代理报告复核完毕。

---

## S3：质量与架构收口

### S3.1 架构原则复核（对照现状）
- [ ] 单一事实源：authStateProvider 为登录态唯一源（AccountManager 仅列表）
- [ ] Provider 图无环（自引用除外）
- [ ] 单例纪律：CookieJar / AudioHandler / ImageCache / MemoryCache / DownloadManager
- [ ] 串行队列纪律：AppImageCache / RecentPlayStore / （新增）下载临时文件保护
- [ ] 错误路径：所有 catch 不能静默吞（关键路径必须有日志或 Toast）

### S3.2 代码卫生
- [ ] 无 `print`；`debugPrint` 仅 debug 语义
- [ ] 无 `withOpacity`（全部 withValues）
- [ ] 无未使用 import / 字段 / 方法（含刚删的 mid/proxyMvUrl 等）
- [ ] 注释与实现一致（重点：直连层实测结论注释）
- [ ] `docs/` 归档：删掉过时报告，保留 review_b*、api_verified、PLAN、check_0*、keystore_setup

### S3.3 测试补强
- [ ] `test/lyric_test.dart`：真实 KRC + 三种 language 结构 + status=200 判定
- [ ] 新增：`AudioQuality.fromString` 别名测试
- [ ] 新增：歌单排序函数测试（倒序取页拼接）
- [ ] CI analyze 0 error / 0 warning

**出口条件**：S3 全勾 + CI 绿。

---

## S4：发布验证

### S4.1 发布前
- [ ] `docs/api_verified.md` 重测一遍（上游可能变更；本次已发现 special_recommend 200101）
- [ ] Secret 确认：ANDROID_KEYSTORE_B64 / KS_STORE_PASS / KS_KEY_PASS
- [ ] pubspec version 与 tag 一致性校验（CI 已有 step）

### S4.2 发布
- [ ] 单 commit push → CI 全绿
- [ ] 打 tag `v1.0.0`（LTS 首个正式版；pubspec 已是 1.0.0+1？→ 统一 2.0.0+2 与 tag v2.0.0）
- [ ] Release 资产核对：3 ABI APK + screenshots zip + mapping.txt（365 天）
- [ ] 输出加速下载链接（proxy 前缀）

### S4.3 发布说明
- [ ] 非官方声明 + LICENSE 摘要
- [ ] 已知限制：top/playlist 直连不可用（回退 kapi）、评论分类热词为新渲染、滑块需人工
- [ ] 升级注意：v0.1.0（CI 临时签名）用户需卸载重装；此后固定 keystore 可覆盖升级

**出口条件**：Release 发布成功，资产齐全。

---

## 附：决策记录（本轮明确）

| 决策 | 内容 |
|------|------|
| D1 | 子代理**只允许一个**并行；只读；实时落盘；不发请求；不装东西；不写修法 |
| D2 | 主代理亲自做**全部修复与验证**；CI 只做最终验证 |
| D3 | 网络层事实基准 = `docs/api_verified.md` + Node 源码；**不读 kapi 文档** |
| D4 | 试听拼接：上游无分段续传接口，**不做**；保留 60s 试听 + 明确角标 |
| D5 | top/playlist 直连不可用（200101），保持 kapi 回退；其它 49 端点直连 |
| D6 | 死开关（wifi/cellular）：UI 禁用 + 「即将推出」徽标，不删（未来接线） |
| D7 | 已收藏状态查询：上游无接口，本期不做「取消收藏」，只做单向收藏 |
| D8 | 版本号：统一 2.0.0+2 ↔ tag v2.0.0（若选 1.0.0 则同步改 pubspec，二选一在 S4.2 定） |
| D9 | stash@{0}：S0.1 时 diff 检查，无独有内容则丢弃 |
| D10 | 一次 push：S0 结束 push 一次，S4 结束 push 一次；中途只 commit 不 push |
