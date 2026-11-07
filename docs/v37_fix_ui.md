# v3.7 迭代 · UI 档修复报告（V37-UI-xx）

基线 `8a49345`（tag v3.6.0）。只允许 file_edit + dart analyze（/opt/dart），
过滤 Flutter SDK 缺包噪音（`override_on_non_overriding_member` / `undefined_*` flutter 类名等），
**项目自有类报错视为真错误**。实时落盘，改一条写一条。

## 基线 analyze 快照
- 全仓 5073 条（绝大多数为 flutter/material 缺包噪音 + override 假告警）。
- 无 error 级；info/warning 与自有代码相关项见各条目。

---
