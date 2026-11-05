# TiernanMusic v3.0 LTS —— 迭代进度（唯一权威）

> 规则：每完成一步立即更新本文件。任何代理/主代理都不许"最后统一写"。

## 当前状态

| 阶段 | 状态 | 产出 |
|---|---|---|
| 第4批审查（6 份报告） | ✅ 完成 | `docs/batch4_review_{1_network,1_network_b,2_function,2_function_b,3_ui,3_ui_b}.md`，共 209 项 |
| 第4批修复（3 代理并行） | 🟡 进行中 | `docs/batch4_fix_{1_network,2_function,3_ui}.md` |
| 复检 5 批（3×5） | ⬜ 待开始 | `docs/v3_review_b{1..5}_*.md` |
| CI 全绿 + 打 tag | ⬜ 待开始 | `v3.0.0` |

## 已完成的核心修复（主代理亲修）

| 编号 | 内容 | 文件 |
|---|---|---|
| PLY-02 | 非歌曲搜索补 albumhide/nocollect/iscorrection，pagesize 30 | kg_endpoints_search.dart |
| PLY-03 | 歌词下载 id/accesskey 空值前置拒绝 | kg_endpoints_search.dart |
| PLY-04 | contenttype 字符串化比较 | kg_endpoints_search.dart |
| PLY-05 | 加歌补 number/size/sort/timelen/bitrate | kg_endpoints_playlist.dart |
| PLY-06 | 删歌路径去 cloudlist.service 前缀、body 精简 | kg_endpoints_playlist.dart |
| PLY-07 | 歌单详情补 userid/token + 10 条上限校验 | kg_endpoints_playlist.dart |
| PLY-08 | 写操作禁止回退（write:true）——防重复提交 | kg_direct_api_client.dart |
| PLY-09 | 回退路径异常统一包装 DioException | kg_direct_api_client.dart |
| PLY-10 | _wrap err_code 校验提前 + 字符串兼容 | kg_direct_api_client.dart |
| PLY-11 | 空响应体判失败（不再静默成功） | kg_direct_api_client.dart |
| PLY-12 | setCredentials 同步 dfid | kg_direct_api_client.dart |

## 已知误报（不再处理）

- 「歌词搜索应打 `/v1/search` 且必须带 signature」：实测 `/v1/search` 用 Node 原参数（含 signature）
  返回空体 + `x-kg-errcode: 20010`；无签名 `/search` 正常返回 candidates。现有实现正确。

## 审查方法论（v3.0 起固定）

依据 `docs/QUALITY_STANDARD.md`：
- 只允许**完整 file_read** + 查阅 Dart SDK 文档
- **禁止编译、禁止跑测试、禁止装包、禁止 clone**
- 每条问题必须给：位置 / 事实 / 契约 / 后果 / 级别
- 网络类问题必须指向原生网关实测记录（`docs/api_verified.md`）

## 5 批审查划分（每批 3 代理，串行，不排队）

| 批 | ① | ② | ③ |
|---|---|---|---|
| 1 | core/direct 全部（客户端+7 端点文件+play_api+crypto） | core 基础设施（api/utils/config/providers/router） | 认证 + 登录态 + 三态 |
| 2 | player（data/presentation/provider） | lyric（data/presentation） | search + home |
| 3 | playlist + comment（data/presentation） | library + download | settings + i18n（10 语言） |
| 4 | 跨模块一致性（状态源/幂等/缓存） | 并发与生命周期（全局 await/token/dispose） | 性能（构建/lookup/内存） |
| 5 | 全局终审 A 视角（正确性） | 全局终审 B 视角（鲁棒性） | 全局终审 C 视角（体验/可维护性） |

每批结束：合并问题 → 主代理统一修复 → 下一批。

## 质量准则（2026-11-06 定稿）

`docs/QUALITY_STANDARD.md` —— 32 条纯原则，八章：
1. 设计与分层（1-5）
2. 错误处理（6-11）
3. 数据与空安全（12-17）
4. 并发与生命周期（18-22）
5. 资源与性能（23-26）
6. 网络与接口契约（27-29，最高优先级）
7. 可维护性（30-32）
8. 审查纪律（方法论）

**静态检查允许范围**：`dart analyze`（Dart SDK 3.13.7 本地已装）查语法/结构错误。
**绝对禁止**：本地编译、`flutter build`、`flutter test`、安装 Flutter SDK / Android SDK / 任何包。
必须过滤「缺 Flutter 包」产生的噪音（uri_does_not_exist / undefined_class 等）。
