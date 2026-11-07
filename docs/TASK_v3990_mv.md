# v3.9.10 任务书 MV：根因修复 + MV 页重写（修复代理，单代理串行）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）、`docs/v399_log_audit.md`（用户日志审计：MV 20010 实锤）、`docs/v39_rewrite_contract.md`（契约方法论）。

## ⚠️ 硬性规则（违反即失败）
- **绝对禁止**：装 Flutter SDK / flutter 命令 / dart pub get / 下载任何 SDK / **改 pubspec.yaml 一行**（ARM64 无 Flutter）
- 只允许 `dart analyze`；Flutter/三方符号报错是预期噪音，**项目自有类报错即真错误**
- **触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**
- **禁止 grep/正则筛源码**：业务相关文件必须 file_read 从头到尾完整阅读
- 跨文件改动双向核对（调用方↔被调方签名逐一对）；禁 git commit/push；只用 file_edit；改动标 `V3990-xx`
- 只使用项目内已存在且已读定义确认签名的类/方法，禁止猜 API、禁新依赖、禁改 Manifest/Kotlin
- i18n 新键 11 语言全补 + 重跑 `python3 tool/gen_l10n_min.py` 贴输出
- 报告 `docs/v3990_mv.md` **实时落盘**

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `d36415d`

## P0 根因修复（用户日志实锤，先做）

### V3990-1 `/v1/video` 传 hash → 20010 invalid param
用户日志：`data: [{"video_id": "6720737C4564B3DE24BEBE0483DE0633"}]` → 20010。
链路：`mv_provider.dart:27-30 mvDetailProvider(hash)` → `mv_repository.dart:46-54 fetchDetail(videoId)`（注释自己写了「只认 video_id，传 hash 返回 invalid param」）→ `kg_direct_api_client.dart:589 data:[{video_id: id}]`。
调用方（搜索 MV 结果/榜单 MV）传的是 hash（`MvHash`/`video_hash`），从未做 hash→video_id 转换。
修复：`fetchDetail` 入口先判入参形态（纯数字=video_id 直用；hash 形态=先经 video/hash 互转通道换 video_id，参考 `resolvePlayUrl` 里已有的互转兜底逻辑与 `/search/mv` 响应的 `MvID` 字段），**在 repository 层统一收口**，调用方不用改。互转失败明确报因（第 9 条）。

## MV 页完全重写（V3990-2，先 file_read 旧文件全文再动手）

现状 441 行，缺陷自析（先自己完整读一遍验证/补充此清单）：
- 无 MV 时（`/kmr/v1/audio/mv` 返回 `data:[{}]`）页面表现不明（空态？错误？）
- 详情 20010 失败后无重试入口
- 清晰度选择无当前档指示、无档位可用性区分（fhd/qhd/hd/sd/mkv 是不同容器）
- 无加载态/缓冲态视觉（转圈？黑屏？）
- 播放错误无用户可读反馈（音频焦点被抢/解码失败/网络断）
- 生命周期：video_player 控制器 dispose、orientation 恢复、后台切换暂停是否齐全——逐项核对
- 布局：控制条遮挡、小屏溢出、亮度/音量手势（如做需对称释放）
- 文案：硬编码中文检查（l10n 全覆盖）
重写要求：
- 三态明确分离（加载/失败含重试与原因/正常），MV 不存在给明确文案与返回动作
- 清晰度切换带当前档指示 + mkv 容器档标注
- 控制器/手势/方向锁全部对称释放；异步后 mounted
- 全 l10n
- **与音频播放互斥**：进入 MV 播放时暂停音频队列（读 audio_handler 暂停接口，先读定义），返回时是否恢复由用户决定（不做自动恢复，避免暗病）

## 完成后
报告末尾 8 行内汇报：V3990-1 修复细节（互转通道实现）、重写分区结构、analyze 逐文件结果、l10n 输出、未做项原因。
