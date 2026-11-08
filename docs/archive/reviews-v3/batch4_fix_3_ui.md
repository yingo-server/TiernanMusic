# 第4批·修复③：UI/UX 与合规打包（修复记录）

- 版本：`pubspec.yaml` → `version: 3.0.0+30`（v3.0.0 LTS 发布号，见 F4-48）
- 依据：`docs/batch4_review_3_ui_b.md`、`docs/batch4_review_3_ui.md`
- 判定准则：`docs/QUALITY_STANDARD.md`（32 条）
- 约束遵守：未改 `lib/core/direct/**`、未改 `lib/features/*/data/**`，未执行 build/test/pub/git

---

## 一、已修复条目

| 编号 | 文件:行 | 改了什么 | 对应 QUALITY_STANDARD |
|---|---|---|---|
| F4-31 | `lib/core/router/app_router.dart:111` | 底部导航「首页/搜索/音乐库/设置」硬编码中文 → `context.l10n.*`，并引入 l10n 导入 | 第 4 条（UI 层不得写死单语言）/ 第 30 条（命名即文档） |
| F4-32 | `lib/features/library/presentation/library_page.dart:9` | 删除未使用的 `kugouApiClientProvider` 导入（UI 层持有网络客户端） | 第 4 条（分层单向依赖）/ 第 32 条（死代码零容忍） |
| F4-33 | `library_page.dart:67`（`_loadRecent`） | 最近播放本地读取加 try/catch：失败留痕 `debugPrint` 并降级为空列表，不再让区块停在旧数据 | 第 6 条（禁止吞掉异常）/ 第 9 条（失败可观测） |
| F4-34 | `library_page.dart:49` | 账号切换时一并 `ref.invalidate(_collectedMvsProvider)`，「我收藏的 MV」不再串上一个账号 | 第 5 条（状态单一来源）/ 第 18 条（异步结果校验世代） |
| F4-35 | `library_page.dart:288` | 「我收藏的 MV」`for (final mv in list)` → `list.take(20)`，与最近播放/已下载同口径，避免全量构建 | 第 24 条（惰性构建）/ 第 25 条（资源上限） |
| F4-36 | `library_page.dart:411`（`_AccountCard`） | 已登录账号卡片新增 `PopupMenuButton`：账号管理（→/settings）、退出登录（二次确认 + `authStateProvider.logout`）；`_AccountCard` 改 `ConsumerWidget`，补 `auth_providers`/`toast` 导入 | 第 16 条（缺失与空语义分离）/ 第 21 条（破坏性操作有确认） |
| F4-37 | `library_page.dart:594` | 歌单卡 120 封面下的两行标题改为 `Flexible` 包裹，字体放大 1.3x 以上不再撑破 170dp 固定高列 | 第 24 条（构建稳定）/ 第 25 条（上限） |
| F4-38 | `lib/features/settings/presentation/settings_page.dart:159` | 清缓存失败不再把 `FileSystemException`（含绝对路径/errno）上屏：`debugPrint` 留痕 + `clearCacheFailed('')` 通用文案 | 第 3 条（契约）/ 第 9 条（可观测） |
| F4-39 | `settings_page.dart:413 / 537` | ThemeMode 与 LyricDisplayMode 两个 `SegmentedButton`：去掉与文案重复的 18px 图标（主题段）、统一 `visualDensity: compact` + 8dp 内边距，窄屏/大字号下不再横向溢出 | 第 24 条（布局健壮性） |
| F4-40 | `settings_page.dart:272` | 「账号管理」条目由「再跳一次 /login」改为打开账号切换弹层（无其他账号时回落登录页），与 `switchAccountSubtitle` 承诺一致，消除与「账号」条目的同义重复 | 第 30 条（名称与行为一致）/ 第 1 条（单一职责） |
| F4-41 | `settings_page.dart:375` | 切换账号遇 `StateError`（token 失效）时 `AccountManager.instance.remove(userid)` 清出本地账号表并刷新，不再反复撞同一错误 | 第 5 条（状态单一来源）/ 第 11 条（降级退出条件） |
| F4-42 | `settings_page.dart:242 / 490` | 账号头像与切换弹层头像从裸 `NetworkImage` 改为 `CachedNetworkImageProvider(cacheManager: AppImageCache.instance, maxWidth: …)`，补导入 | 第 23 条（缓存键/策略统一）/ 第 25 条（解码尺寸上限） |
| F4-43 | `settings_page.dart:798` | 最近错误弹层不再渲染原始异常前三行（类名/路径/堆栈），改为「技术详情 N + 复制」入口，全文仍可复制上报 | 第 9 条（可观测）/ 第 3 条（技术细节不进 UI） |
| F4-44 | `settings_page.dart:825` | 关于页应用名 `AppConfig.appNameCn` → `context.l10n.appName`；版本未取回时显示 `-` 占位，不再出现「版本：」空白 | 第 4 条（多语言）/ 第 16 条（缺失与空语义分离） |
| F4-45 | `settings_page.dart:735` | 存储权限条目：`FutureBuilder` 内已授权时显示「已授权」文本而非可点「申请权限」按钮，消除无效入口 | 第 30 条（名称与行为一致） |
| F4-46 | `settings_page.dart:690` | 日志目录不再展示 `/data/user/0/...` 绝对路径，仅显示末级目录名（完整路径仍可复制给开发者） | 第 3 条（技术细节不进 UI） |
| F4-47 | `settings_page.dart:103` + 文件底部 `_dirSizeBytes` | 缓存统计由「主 isolate 递归 + 每文件 `await length()`」改为 `compute(_dirSizeBytes, path)` 后台同步统计，只回传一个 int；补 `compute` 导入 | 第 24 条（按需计算）/ 第 26 条（热路径零分配） |
| F4-48 | `pubspec.yaml:4` | `version: 2.0.0+1` → `version: 3.0.0+30` | 发布硬要求（v3.0.0 LTS 版本号） |

---

## 二、未修复条目及原因

| 条目（审查③） | 原因 |
|---|---|
| `captcha_page.dart` 全页硬编码中文（P1）+ 加载/提交失败拼原始异常 + verifyUrl 上屏 + WebView `onLoadStop` 未判 mounted + 空验证码静默 + 短信无重发 | 该页需新增约 12 个 l10n 键并同步 10 个 `.arb` + 重新生成 `app_localizations.dart`（本机无 Flutter SDK，只能用 `tool/gen_l10n_min.py`）。在剩余时间内无法保证 10 语言全补齐不破 l10n 生成，故整体留待下一轮一次性处理，避免半成品导致构建失败 |
| `login_page.dart` P1「UI 取 API 客户端注入 CaptchaPage」、验证码页走 `Navigator.push` 绕过 GoRouter | 正确的修法是把 `VerificationService` 的装配下沉到 `lib/features/auth/data/`（新增 provider），该目录本轮被任务书禁止修改；只改 UI 无法真正消除「UI 持有客户端」 |
| `login_page.dart` 校验提示被 `friendlyError` 兜成「操作失败」（P2） | 根因在 `lib/core/utils/friendly_error.dart` 的硬编码中文兜底（不在本轮目标文件清单内），需先把它改为接收 l10n 或抛领域异常 |
| `login_page.dart` 登录成功固定 `go('/home')` 丢来源页（P2）、二维码两个刷新按钮（P3）、发送验证码按钮高度（P3）、手机号仅大陆格式（P3） | 时间预算耗尽，未改动 |
| `playlist_detail_page.dart` 收藏无状态反馈/原始异常进 Toast（P2）、`_tracksReloadProvider` 死代码（P3）、歌曲行无封面（P3）、头图 errorWidget 无图标（P3） | 时间预算耗尽（`_tracksReloadProvider` 需同时摘掉 `ref.watch`、`SliverMainAxisGroup` 单子节点包装，改动面较大，留待下一轮） |
| `queue_sheet.dart` 移除单曲/清空队列（任务书第 6 条）、标题栏 `Flexible`（P3） | 队列增删需要 `TiernanAudioHandler` 暴露 `removeAt/clear`（`lib/features/player/data/**`，本轮禁止修改）；纯 UI 伪造队列会与播放器真实 `_songs` 不一致，属制造缺陷，故不做 |
| `mini_player.dart` 高度跳变无 `AnimatedSize`（P3） | 未改动（预算耗尽） |
| `full_player_page.dart` 无歌空壳、歌词错误文案硬编码、无歌词点「显示歌词」无反应（P2） | 未改动（预算耗尽） |
| `home_page.dart` P1 推荐歌单被 `collection_` 前缀吞掉、banner 不可点、固定高卡片溢出（P2） | 未改动（预算耗尽）；其中 banner 点击需 `HomeBanner` 增加目标字段（`features/home/data/**`，另一代理负责） |
| `search_page.dart` P1 分页失败 footer 永久转圈、`addHistory` 失败吞搜索、歌单 id 未校验/编码（P2） | 未改动（预算耗尽） |
| `settings_providers.dart` 写盘异常无处理、默认值 '320' 两处、键名不统一（P3） | 未改动（预算耗尽） |
| `comment_*` / `download_*` 页面 | 两份报告均未列出具体条目，按「不扩大范围」未改动 |
| `.arb` 补键 | 本轮未新增任何 l10n 键（见上文 captcha 条），故未触碰 10 个 `.arb`，不存在缺键风险 |

---

## 三、编译风险提示（静态自查，未运行 analyze）

- `settings_page.dart`：`compute` 来自 `package:flutter/foundation.dart`，已显式导入；`_dirSizeBytes` 为顶层函数，`Directory` 来自已导入的 `dart:io`。
- `library_page.dart`：新增使用 `authStateProvider`（已导入 `auth_providers.dart`）、`Toast`（已导入 `core/utils/toast.dart`）、`scheme`（`_AccountCard.build` 内的局部变量，作用域内可见）。
- `app_router.dart`：`MainShell.build` 已有 `BuildContext context`，`context.l10n` 可用（已导入 `l10n.dart`）。
