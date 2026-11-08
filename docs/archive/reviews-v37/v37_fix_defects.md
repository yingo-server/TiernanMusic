# v3.7 修复档（修复代理 · 基线 8a49345 / v3.6.0）

依据 `docs/QUALITY_STANDARD.md`（33 条）。逐条实时落盘。

## V37-01 captcha_page i18n 脱钩收尾（A3/C2 双报告）

文件：`lib/features/auth/presentation/captcha_page.dart` · 条款：第 9 条（失败可观测）/第 31 条

5 处硬编码中文全部替换为既有 arb 键（键名 → 用途）：

| # | 原文 | 替换键 |
|---|---|---|
| 1 | `'获取验证信息失败：$e'` | `captchaLoadFailed`（`$e` 不再直出，完整异常转 `debugPrint('[captcha] getVerifyInfo failed: …')` 留日志） |
| 2 | `'短信验证'` | `captchaSmsTitle` |
| 3 | `'请输入接收到的验证码完成验证'` | `captchaSmsHint` |
| 4 | `'验证码'` / `'6 位数字'` | `captchaSmsCodeLabel` / `captchaSmsCodeHint` |
| 5 | `'该验证类型需要在酷狗官方 App 内完成…'` | `captchaExternalHint` |
| 6 | `'未知验证类型（v_type=…）'` | `captchaUnknownType('${s.vType}')`（占位符版） |
| 7 | `'服务端未返回验证 url'` | `captchaNoVerifyUrl` |

死键处置：`captchaHint` 全仓 0 处 `l10n.captchaHint` 引用（grep 确认），确认真死，随第 10 条统一删除。

状态：✅ 代码替换完成

## V37-03 B2 三条 P3

文件：`lib/features/home/data/home_repository.dart`、`lib/features/comment/data/comment_repository.dart`、`lib/features/playlist/data/playlist_repository.dart`

1. **home_repository 四处回落补日志**（第 9 条）：`fetchTopPlaylists` / `fetchBanners` / `fetchDailyRecommend` / `fetchNewSongs` 的 `catch (_)` 全部改为 `catch (e)` + `debugPrint('[home] …')`，静默降级留痕。补 `foundation.dart` 导入（debugPrint）。
2. **deleteComment `mixsongid != null` → 空串不发**（口径统一，对齐 `kg_endpoints_comment.dart` 的 `_nonEmpty` 口径）：空串与缺失语义相同，下发空串可能被服务端 400。
3. **_write 防重冲突 `maybeSucceeded:true` → `false`**（第 21/3 条）：防重拒绝发生在请求发出之前，本次操作必然未生效；`true` 会误导调用方把「重复点击被拒」当「可能已成功」。

状态：✅ 三条完成

## V37-02 dfid kapi 兜底三写同步核实 + native_probe.sh 入库

文件：`tool/native_probe.sh`（新增） · 条款：第 28/29/33 条

核实结论（V35-A2-2 遗留项）：`kg_direct_api_client.dart` 的 setCredentials → dfid 同步链完整——dfid 经 `setDfid` 单点写入 KgClient，Hive 单源（`_dfidBox`）在 `setCredentials` 内同步刷新，kapi 兜底三写（SecureStorage/Hive/KgClient 内存）无旁路。✅ 无需代码改动。

新增 `tool/native_probe.sh`：直打原生域名（`gateway.kugou.com`/`userservice.kugou.com` 等）的三态 cookie probe 骨架，与 `tool/kg_probe.py`（python 版）同口径。设计要点：
- 凭证从环境变量读取（`KG_DEVICEID`/`KG_TOKEN`/`KG_MID`/`KG_USERID`），不再依赖 `.test_creds/` 下的本地文件（不入库的敏感物）
- 匿名/普通/付费三态由 `KG_PROFILE` 选择，输出带 `x-kg-errcode` 头与响应体留样（第 29 条）
- 明确标注：kapi 返回不可作为实测依据（第 33 条）

状态：✅ 完成

## V37-04 B3 发布链三条 P1

文件：`lib/features/download/download_provider.dart`、`lib/features/download/data/public_media_store.dart`

1. **P1-1 remove 竞态复活**（第 18/21 条）：remove 的多步 await 期间，被取消的旧 `_run` 回调可能通过 `_update` 把任务写回 state/Hive。修法：remove 内用**哨兵 token**（新 CancelToken 已 cancel）占住 `_tokens[id]`，使迟到回调的世代 guard `_tokens[task.id] == token` 恒假；Hive 删除后收尾移除哨兵。
2. **P1-2 先删旧文件+rename 非原子窗口**（第 21 条）：`_publishDirect` 原实现 `if (await target.exists()) await target.delete(); await partFile.rename(...)` 存在「既无旧文件也无新文件」窗口。修法：直接 `rename`——POSIX/Linux rename 目标存在时**原子覆盖**，无需预先 delete。
3. **P1-6 .part 残留清扫**（第 20 条）：进程被杀时 .part 永久残留。修法：`_publishDirect` 每次发布前对同前缀 `<target>.part` 做清扫（失败不阻断）。

状态：✅ 完成

## V37-05 B3 P2-14 viewFolder content:// 恒失败

文件：`lib/features/download/data/public_media_store.dart`、`presentation/download_page.dart`、`lib/l10n/*.arb`（11 文件）

修法（提前判定降级 Toast，不引入路径方案改动）：`viewFolder` 本身已有 `path` 空守卫，本次把失败语义补全——
- `download_page.dart` 失败分支新增 `Toast.show(…downloadFolderOpenFailed)` 明确告知「未能打开（文件在系统媒体库）」+ 原有复制路径兜底，不再静默。
- 新 arb 键 `downloadFolderOpenFailed`，11 个语言文件全部同步（zh_CN 模板 + zh/zh_TW/en/ja/ko/de/fr/es/pt/ru）。

状态：✅ 完成（l10n 生成物重跑见收尾节）

## V37-06 C1 ALB-R1/R2

文件：`lib/features/album/data/album_repository.dart`、`lib/features/artist/data/artist_repository.dart`

1. `final dynamic _api` → `final KugouApiClient _api`（第 10/2 条）：两文件均补 `core/api/kugou_api_client.dart` 导入；`kugouApiClientProvider` 注入的即 KugouApiClient（有 `get` 方法），双向核对通过。
2. 入口裸强转 `as Map<String, dynamic>` → `is Map<String, dynamic>` 分支校验（第 13 条）：album fetchDetail/fetchSongs、artist fetchDetail/fetchSongs/fetchAlbums 共 5 处，非 Map 上游给空 Map 走空数据路径，不再 TypeError 上抛。

状态：✅ 完成

## V37-07 同名旧歌单竞态（C2 P2 · 第 3/29 条）

文件：`lib/features/playlist/presentation/add_to_playlist_sheet.dart`

`_createAndAdd` 重写：collectPlaylist **前**先快照已存在同名 listid 集合（existedIds），创建后仅匹配「同名且基线没有」的歌单；排除后为空不再盲匹配旧歌单（原实现 `created.first` 会命中旧歌单——歌进错歌单），回落为 `addedToSameNamePlaylist` 提示并关闭弹层。上游 `/playlist/add` 不返回新 listid（第 29 条未实测约束）已在注释标注。新增 arb 键 `addedToSameNamePlaylist`，11 个语言文件全部同步。

状态：✅ 完成

## V37-08 comments_page loadMore 永久转圈（C2 P2 · 第 16/9 条）

文件：`lib/features/comment/presentation/comments_page.dart`

核对结论：该修复已随前轮提交（bcf753d，V37-01~06）落盘且在基线 31f33d8 中可见——controller 侧 `_pageError`/`retryLoadMore`/失败不推进页码/失败重建 state 触发通知均在位；UI 侧 footer 依序渲染 pageError→重试按钮、hasMore→转圈、否则 noMore。与 search_page `_pageError` 范式逐点对照一致（`retryLoadMore` 清空后重拉；成功路径 `_pageError` 保持 null；`load(refresh:true)` 推进 generation 丢弃旧 loadMore，页码语义自洽）。**无需新代码改动，核对通过。**

状态：✅ 已在位（核对通过）

## V37-09 arb 死键清理（第 32 条）

grep 全仓确认引用后处置：
- `wifiAutoHighQuality` / `cellularLowQuality` / `tryListen` / `albumPageComingSoon`：无任何 `l10n.*` 代码引用（settings_providers.dart 仅注释提及 Hive 遗留键名），11 个 arb 文件全删。
- `mvQualitySelect`：mv_player_page.dart:396/434 有消费方，**保留不删**（任务书预判「无消费方」不成立）。

gen_l10n_min.py 重跑输出：
```
wrote lib/l10n/app_localizations.dart: 336 keys, 11 locales
```
状态：✅ 完成

## V37-10 captcha_page 二次核对（第 9/31 条）

A3 的 5 处硬编码逐条核对：`captchaLoadFailed`/`captchaSmsTitle`/`captchaSmsHint`/`captchaSmsCodeLabel+Hint`/`captchaExternalHint`/`captchaUnknownType`/`captchaNoVerifyUrl` 全部在位。rg 全文仅剩注释中文 + WebView HTML 内 2 处用户可见中文（`开始验证`/`完成滑块后自动继续`）——本次补齐：新增 `captchaTencentStartButton`/`captchaTencentAutoHint` 两键（11 语言全补），HTML 内以 jsonEncode 字面量注入（防注入）。复检 rg 字符串级中文残留：0 处。

gen_l10n_min.py 重跑输出：
```
wrote lib/l10n/app_localizations.dart: 336 keys → 337 keys → 339 keys, 11 locales（三步：删死键 / 增 addedToSameNamePlaylist / 增 captcha 2 键）
```
状态：✅ 完成

## dart analyze 逐文件结果（环境无 Flutter SDK，Flutter/riverpod 符号缺失报错属噪音，已按规则过滤）

| 文件 | 原始 issues | 过滤后 |
|---|---|---|
| add_to_playlist_sheet.dart | 126 | 0（无项目自有错误） |
| comments_page.dart | 226 | 0（未改动，仅 analyze 核对） |
| captcha_page.dart | 162 | 0 |
| app_localizations.dart（生成物） | 62 | 0 |
| 11×app_*.arb | 数据文件，不适用 dart analyze | — |

## l10n 汇总
- 删键：wifiAutoHighQuality / cellularLowQuality / tryListen / albumPageComingSoon（11 文件）
- 增键：addedToSameNamePlaylist、captchaTencentStartButton、captchaTencentAutoHint（11 文件）
- 最终 `python3 tool/gen_l10n_min.py` 输出：`wrote lib/l10n/app_localizations.dart: 339 keys, 11 locales`

## 汇报（8 行内）
1. V37-07 ✅ 已修：同名旧歌单竞态，基线快照排除法 + addedToSameNamePlaylist 回落
2. V37-08 ✅ 核对通过：_pageError 范式已随 bcf753d 落盘于基线，无需改动
3. V37-09 ✅ 已删 4 死键（mvQualitySelect 有消费方保留），gen_l10n_min 重跑通过
4. V37-10 ✅ A3 五处核对在位；补 HTML 内 2 处中文为 l10n 新键，字符串级残留 0
5. analyze：4 个 dart 文件逐文件跑，过滤 Flutter SDK 噪音后均 0 错误
6. arb 变更全部 11 语言同步（zh/zh_TW/zh_CN/en/ja/ko/es/fr/de/pt/ru）
7. 未修原因：无
8. 禁令遵守：未 build/test/pub get/commit/push，仅 file_edit + dart analyze
