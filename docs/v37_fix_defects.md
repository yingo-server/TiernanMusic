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
