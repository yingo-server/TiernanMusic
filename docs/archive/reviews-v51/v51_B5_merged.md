# v5.1 交叉审查·B5 合并裁决（三视角全齐，收官批）

视角报告（共 175 条，P0 全 0）：
- `v51_cross_B5_a.md`（功能正确性）：45 条，P1×1
- `v51_cross_B5_b.md`（鲁棒与质量）：49 条，P1×5
- `v51_cross_B5_c.md`（用户路径）：878 行，P1×15

## 三视角/双视角共识（修复优先级）

1. **20028 验证契约三形态分裂**（B 视角最重 + C 视角呼应）：`verification_guard` 只接 DioException 包裹形态、裸 ApiException 穿透、`auth_repository` 另抛 CaptchaRequiredException；captcha_page 对七类验证类型只给提示页无法完成 → 验证闭环多条路径必然失败。**修法**：`verification_guard` 收敛接 `requiresVerification()` 单点（B1 已建），裸形态穿透由 `apiExceptionOf` 兜住；CaptchaRequiredException 映射为同判定。
2. **登录成功顺序错位**（C 最重）：`_handleLoginSuccess` 凭证落盘前先 upsert 切号并广播 → 「UI 显示 A、指针 B、凭证 A」横跨收藏/下载/评论。**修法**：落盘先行，再 upsert/广播。
3. **评论写操作数据层无防重闸**（A 最重 + B2 merged 待核实项核实成立）：防重只在 comments_page 单一 UI 入口。**修法**：repository 层加 in-flight 集合（按 resourceKey+type），与 `PlaylistRepository._write` 同构。
4. **error_retry 未解包 DioException 内层 ApiException**（B4-A 最重）：登录过期/人机验证显示通用文案。**修法**：errorClassification 先走 `unwrapApi`。
5. **defaultQuality set() 盒未打开静默丢弃**（C 实锤）：state 已变重启回退。**修法**：失败留痕 + 重试一次。

## 误报/降级

- 「切号缓存失效」A 自纠（main.dart:295 onUserChanged 已清理）✅
- B4-A「setCollected status==200 报成功」：降 P2——解密失败分支已抛「结果未知」，status==200 为解密成功路径的真实成功语义

## P3 与低风险项

归档处理，不阻塞 v5.1.0 发版（共约 60 条，记录在案）。
