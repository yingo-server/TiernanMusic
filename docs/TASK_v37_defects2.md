# v3.7 缺陷档接续：V37-07~10（修复代理）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）与 `docs/v37_fix_defects.md`（前一轮已完成 V37-01~06，本任务做剩余 4 条）。

## ⚠️ 硬性规则
- 禁装 Flutter SDK/build/test/pub get；允许 dart analyze（`export PATH=$PATH:/opt/dart/bin`）
- **噪音过滤只适用于 Flutter SDK 符号；项目自有类报错即真错误**
- **触碰的每个文件收尾前必须 analyze，结果逐文件贴报告——缺一即任务失败**
- 跨文件改动双向核对（调用方↔被调方）
- 禁 git commit/push；只用 file_edit；改动标 `V37-xx` 编号 + 条款
- i18n 改动必须 10 语言全补（zh_CN/zh_TW/en/ja/ko/es/fr/de/pt/ru），改完 arb 后重跑 `python3 tool/gen_l10n_min.py` 并贴结果

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `31f33d8`

## 报告
追加到 `docs/v37_fix_defects.md` 末尾（实时落盘）

## 任务清单

### V37-07 同名旧歌单竞态（add_to_playlist_sheet.dart `_createAndAdd`）
- 现状：`collectPlaylist(name: trimmed)` 后按 `list.where((p) => p.name == trimmed)` 匹配——若用户已存在同名歌单，`created.first` 可能是**旧歌单**，歌进错歌单
- 修复方向：`fetchUserPlaylists()` 返回后，排除「新建前就已存在」的同名歌单（调用 collectPlaylist **前**先快照已存在的同名 listid 集合，匹配时排除）；若排除后为空，回落为「已收藏到同名歌单」提示（上游不返回新 listid 的既知约束，代码注释标注第 29 条）
- 先 file_read 完整读该文件

### V37-08 comments_page loadMore 永久转圈
- 现状：评论加载更多失败后 footer 永久转圈、无重试（与 search_page 修复前同型）
- 修复：复制 search_page 的 `_pageError` 范式——失败态 footer 渲染「重试」按钮、成功清 `_pageError`、失败按 `_items.isEmpty` 分流 `_error`/`_pageError`
- 先 file_read 完整读 comments_page.dart 与 search_page.dart（对照范式）

### V37-09 arb 死键清理
- `wifiAutoHighQuality` / `cellularLowQuality`（假开关已移除，键残留）：10 语言全删
- `tryListen` / `mvQualitySelect`（语义漂移或无消费方）：先 grep 全仓确认无引用，无则 10 语言全删
- `albumPageComingSoon`（孤立键）：同上
- 删除后重跑 `python3 tool/gen_l10n_min.py`，贴输出与 dart analyze 结果
- 注意：**先 grep 确认无代码引用再删**；有引用的改走正确键

### V37-10 captcha_page 二次核对
- V37-01 声称完成，但 A3 报告的 5 处硬编码需最终核对：file_read 全文，rg 检查残留中文字符串（`rg '[\x{4e00}-\x{9fff}]'` 或逐行读），有则替换为 l10n（新键 10 语言全补）；无则记录「核对通过」

## 完成后
追加到报告末尾，8 行内汇报：每条状态/analyze 逐文件结果/l10n 重跑输出/未修原因。
