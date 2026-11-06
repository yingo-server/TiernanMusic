# v3.5 A 批·审查①：core/direct 全量回归报告

基线：v3.4 后（`TASK_v34_review1.md` 变体，原文件缺失，以差异指令为准）
范围：kg_direct_api_client / kg_client / 7 个 endpoints / kg_play_api / kg_providers / kugou_api_client（B-07 CookieJar 后）
重点：_directOrFallback write:true 语义与 kapi 停用（const false）自洽；_wrap 误判复核；ensureDfid Completer 并发收敛；未移植路径 -404 与 Repository 交互；kapi 对照仅作参数参考（第 33 条）。
硬性规则：完整 file_read；禁编译；实时落盘；禁旧报告正文；噪音过滤仅适用于 Flutter SDK 符号，项目自有类报错即真错误。

---
