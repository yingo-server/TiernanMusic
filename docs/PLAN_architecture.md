# Tiernan Music — 工程架构与代码质量规划（S5 专章）

> 原则：**大型开源项目质量**。分层清晰、依赖单向、无上帝文件、无隐藏耦合、
> 改一处不会坏三处。本专章是对 `PLAN_v2_final.md`（功能/网络/发布）之外的
> **系统性修复、检查与重构**规划。
>
> 现状事实（实测）：
> - `kg_direct_api_client.dart` **1634 行**（上帝文件：45 个端点方法 + 路由 switch + wrap 全在一起）
> - `settings_page.dart` 935 行、`login_page.dart` 730 行、`search_page.dart` 724 行（UI 上帝页面）
> - `song_tile.dart` 641 行（公共组件里塞了 EmptyState/ErrorRetry/Skeleton/CopyableText 4 个组件）
> - `core/router` import `features/*`（router 依赖全部页面——可接受的例外，但需收敛）
> - `library_page.dart:434` UI 层直接 `PlaylistRepository(...)` 构造（分层违规）
> - 66 个 provider 散落在 20+ 文件（core/providers.dart 与 feature 内 provider 并存）

---

## 一、目标分层架构（Dart 惯例 + 本项目适配）

```
lib/
├── main.dart                    # 组装根：ProviderScope + App
├── app/                         # 【新增】应用壳
│   ├── app.dart                 #   TiernanMusicApp（WidgetsBindingObserver 在此）
│   ├── router.dart              #   GoRouter 定义（唯一允许 import 全部页面的地方）
│   └── bootstrap.dart           #   main() 的启动序列（openSafe/兜底/看门狗）
├── core/                        # 基础设施层（不 import features/**）
│   ├── config/                  #   常量（app_config）
│   ├── api/                     #   通用 HTTP（dio 封装、translate）
│   ├── direct/                  #   直连协议（拆分，见 §三.1）
│   ├── audio/                   #   音频引导/音质偏好
│   ├── cache/                   #   MemoryCache
│   ├── image/                   #   AppImageCache
│   ├── storage/                 #   SecureStorage
│   ├── utils/                   #   error_logger/permission_gate/toast/update/friendly_error
│   ├── theme/                   #   主题 tokens
│   ├── widgets/                 #   纯 UI 组件（一文件一组件）
│   └── l10n.dart                #   l10n 出口
├── features/<feature>/          # 功能层（可 import core/**，禁止跨 feature import）
│   ├── data/                    #   model + repository（只在此层发起网络）
│   ├── domain/                  #   【新增，仅大型 feature】provider/状态
│   └── presentation/            #   页面 + 组件（一页面一文件，可拆子文件）
└── l10n/                        # 生成物 + arb
```

**铁律**
1. `core/**` **禁止** `import features/**`（现状：只有 router 违规 → 移到 `app/` 即合规）
2. `features/A` **禁止** `import features/B`（跨功能通信只走 core 的 provider/模型）
3. UI 层**禁止**直接构造 Repository —— 一律 `ref.watch(xxxProvider)`
4. Repository **只存在于** `data/`，构造函数只依赖 core 类型
5. 一个文件一个职责；**单文件上限 500 行**（l10n 生成物与直连协议除外，拆分见下）

---

## 二、逐文件重构清单（按收益排序）

### R1 `kg_direct_api_client.dart`（1634 行 → 6 个文件，最高优先）

现状：1 个类同时承担「路由分发 + 45 个端点构造 + `_wrap` + 回退 + 错误记录」。

拆法（每个文件只放一组端点，共同基类持有 `kg`/`_wrap`/`_directOrFallback`）：

```
core/direct/
├── kg_direct_api_client.dart   # 抽象基类：kg、_wrap、_directOrFallback、lastErrors、get/post 分发骨架
├── endpoints/
│   ├── search_endpoints.dart       # search×6 + suggest/hot
│   ├── playlist_endpoints.dart     # playlist 系列 + user/playlist
│   ├── comment_endpoints.dart      # comment 系列（读+写）
│   ├── media_endpoints.dart        # song/url + privilege + kmr/mv + video + rank/audio + top
│   ├── artist_album_endpoints.dart # artist×3 + album×2
│   └── home_endpoints.dart         # yueku + everyday + banner
└── kg_media_direct.dart        # 图片/视频详情 extension（保留）
```

收益：新端点只加一个文件；审查可按域进行；`_wrap` 改动只碰基类。
**约束**：对外 API 不变（`KgDirectApiClient` 的 get/post 签名不动），调用方零改动。

### R2 `song_tile.dart`（641 行 → 4 个文件）

```
core/widgets/
├── song_tile.dart              # 只留 SongTile + SongTileMenuItem
├── empty_state.dart            # EmptyState
├── error_retry.dart            # ErrorRetry + FriendlyError + errorClassification
├── list_skeleton.dart          # ListSkeleton（Shimmer 引用方）
└── copyable_text.dart          # _CopyableText 提为公开 CopyableText
```

### R3 UI 上帝页面拆分（4 个 >700 行页面）

| 文件 | 行数 | 拆法 |
|------|------|------|
| `settings_page.dart` | 935 | `_build*Section` 每个区块 → `sections/` 私有 widget 文件；provider 留 settings_providers |
| `login_page.dart` | 730 | 三个 Tab → `tabs/sms_tab.dart` / `pwd_tab.dart` / `qr_tab.dart`；CaptchaPage 已独立 |
| `search_page.dart` | 724 | 结果 Tab → `tabs/` 各类型；SearchBar+历史+热搜 → `search_bar_area.dart` |
| `comments_page.dart` | 654 | `_CommentTile` → `comment_tile.dart`；`_CommentTags` → `comment_tags.dart`；输入条 → `comment_input.dart` |

拆分纪律：**纯移动代码**，不改逻辑；拆完 brace/import 全检；每拆一个文件本地全检一次。

### R4 Provider 归位

现状：`core/providers.dart`（kugouApiClient/translate/lyric）+ 各 feature 内 provider 并存。
- `core/providers.dart` 只留**跨 feature 共享**的（kugouApiClientProvider、kgDirectApiProvider）
- feature 专属 provider 移到 `features/<f>/data/<f>_providers.dart`（player/auth/download 已是；home/lyric 归位）
- `mv_provider.dart` / `library_page.dart` 内联 provider 归位

### R5 分层违规修复

| 位置 | 问题 | 修法 |
|------|------|------|
| `library_page.dart:434` | UI 直接构造 PlaylistRepository | 抽 `playlistRepositoryProvider`（core/providers） |
| `artist_page` / `album_page` / `rank_detail_page` | 同模式（检查） | 同上，统一 provider |
| `core/router` | import 全部页面 | 移到 `app/router.dart`（新层，唯一例外并写注释） |

### R6 死代码与遗留（已部分清理，收尾）

- [x] `proxyMvUrl` / `diskCacheMax*` / `refreshDeviceContext` / `KugouApiClient.mid`
- [ ] `analysis_options.yaml` 补规则：`avoid_print`、`always_declare_return_types`、`prefer_single_quotes`（已有）+ 新增 `unawaited_futures`、`unnecessary_lambdas`
- [ ] `TODO(跳转)` 类注释全部消除或转为 issue 引用

---

## 三、系统性检查清单（S3/S5 共用，发布前逐条跑）

### 3.1 静态（脚本化，主代理跑）
- [ ] brace/import/l10n/provider 引用（现有 4 个脚本）
- [ ] 组件参数匹配（修误报：只扫顶层调用）
- [ ] 分层违规扫描：`grep "import.*features/" lib/core/`（app/router 除外）= 0；`features/A → features/B` = 0
- [ ] UI 构造 Repository 扫描 = 0
- [ ] 单文件 >500 行扫描（白名单：l10n 生成物、kg_direct 基类+endpoints 各文件、_krc 样本测试）
- [ ] `print(` = 0；`withOpacity(` = 0；空 `catch (_) {}` 清单（允许启动兜底，其余须有日志）

### 3.2 行为（逐条人工推演 + 已有实测）
- [ ] 登录态四处写入/四处清理（终审C 通过项 1-4）
- [ ] 播放态 6 流随 engineReady 重订阅（P0-1 修复验证）
- [ ] 20028：播放（自动重试）/ 评论（手动验证）双链路
- [ ] 离线播放：MediaStore uri + file 路径双形态；队列切回不丢
- [ ] 下载：权限时机 / 清缓存保护 / 暂停恢复竞态 / 进度节流
- [ ] 歌单排序：倒序取页拼接（含单页/多页/超 100 首）

### 3.3 测试（CI 可跑）
- [ ] lyric_test（真实 KRC）
- [ ] audio_quality_test（fromString 别名 + fallbackOrder）
- [ ] playlist_order_test（倒序拼接纯函数化后测）
- [ ] wrap_status_test（`_wrap` 抽纯函数后测 status=1/200/err_code/151）

---

## 四、执行顺序（并入 PLAN_v2_final 的阶段编号）

```
S0 收敛工作区（不变）
S1 网络层终审（不变）
S2 功能与按钮过审（不变）
S3a 现有质量检查（原 S3）
S3b 重构执行（新增，按 R1→R2→R3→R4→R5 顺序，每步本地全检）
S3c 静态检查清单 3.1（新增项全绿）
S4 发布验证（不变，含 3.2 行为清单）
```

**重构纪律**
1. R1~R5 每完成一项：本地静态全检 + 单独 commit（不 push）
2. 重构期间**禁止**改行为逻辑；发现 bug 记录到 `docs/check_refactor.md`，重构完统一修
3. CI 在 S3c 结束后才跑（一次 push 原则不变）

---

## 五、验收标准（大型开源级）

| 维度 | 标准 |
|------|------|
| 分层 | core 零反向依赖；feature 零横向依赖；UI 零直接构造仓库 |
| 文件 | 除白名单外单文件 ≤500 行；一个文件一个职责 |
| 命名 | provider 一律 `xxxProvider`；repository 一律 `XxxRepository`；私有组件 `_` 前缀 |
| 注释 | 直连层每个端点带「实测结论」（来源+日期+样本要点）；公开类带 dartdoc |
| 错误 | 用户可见错误走 `friendlyError`；底层错误走 ErrorLogger；无静默吞 |
| 测试 | 关键纯函数（wrap/quality/sort/krc）100% 覆盖；CI 绿 |
| 文档 | PLAN / api_verified / check_0* / keystore_setup 与代码同步 |
