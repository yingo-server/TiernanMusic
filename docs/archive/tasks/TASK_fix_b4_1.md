# 第4批·修复①：网络层（端点域 + 播放 + 认证）

## 角色
你是**修复代理**。按报告逐条改代码，不要重新审查全部代码、不要扩大范围。

## 绝对禁止
- 禁止下载 Flutter/Dart SDK、禁止装包、禁止 git clone、禁止构建、禁止跑测试、禁止起 Node/kapi
- 禁止 git commit / git push（由主代理统一提交）
- 禁止修改 `lib/core/direct/kg_direct_api_client.dart`（主代理已改完 `_wrap` / `_directOrFallback` / `setCredentials`，你再改会冲突）
- 禁止改动与本任务无关的文件

## 工作目录
`/var/minis/workspace/TiernanMusic`

## 规范（必须遵守）
`docs/REVIEW_SPEC.md` 第 1 条最高优先级：**所有接口必须优先使用酷狗原生域名，禁止以 kapi 网关作为实现**。

## 输入报告（先完整读这两份）
1. `docs/batch4_review_1_network_b.md`（74 项，端点域 8 文件，含域名合规表）
2. `docs/batch4_review_1_network.md`（kg_client / kg_crypto / kugou_api_client 的问题）

## 目标文件（只改这些）
- `lib/core/direct/kg_endpoints_media.dart`
- `lib/core/direct/kg_endpoints_artist_album.dart`
- `lib/core/direct/kg_endpoints_home.dart`
- `lib/core/direct/kg_endpoints_auth.dart`
- `lib/core/direct/kg_endpoints_comment.dart`
- `lib/core/direct/kg_play_api.dart`
- `lib/core/direct/kg_crypto.dart`
- `lib/core/direct/kg_client.dart`
- `lib/core/api/kugou_api_client.dart`

（`kg_endpoints_search.dart` 和 `kg_endpoints_playlist.dart` 主代理已修，不要动。）

## 已知误报 —— 不要改
报告中「歌词搜索应打 `/v1/search` 且必须带 signature」是**误报**。已实测：`/v1/search` 用 Node 原参数（含 signature）依旧返回空体 + `x-kg-errcode: 20010`；无签名的 `/search` 正常返回 candidates。现有实现正确，跳过该条。

## 优先修的 P1（20 项，其余 P2 尽力而为）
1. `media.dart:96` + `play_api.dart:46`：`/v5/url` 端点 **撤掉 signature**（Node `notSign: true`，只带 key）
2. `play_api.dart:44`：播放主路径 `/v5/url` 改用原生域 `trackercdn.kugou.com`（不要 gateway + x-router）
3. `artist_album.dart:36`：artistAudios 补 `baseUrl: 'https://openapi.kugou.com'`（Node 有 baseURL）
4. `comment.dart:24`：歌曲评论补 `x-router: m.comment.service.kugou.com`
5. `comment.dart:126`：楼中楼回复补 `is_t`、`pid` 默认 0、`//@user:content` 拼接、`extdata`
6. `comment.dart:161`：删除评论改 **GET**（Node buildCommentDelConfig）
7. `play_api.dart:96`：privilege 恒发完整 UPSTREAM_QUALITIES 全表（不要用调用方传入的 qualities）
8. `play_api.dart:148`：PrivilegeItem 按 QUALITY_LEVEL 逐档挑选（不要只取 relate_goods.first）
9. `play_api.dart:255`：`hash_offset` 处理 `start_ms` 与 `clip_hash`
10. `media.dart:110`：privilege 空 hash / 空 resource 前置拦截（Node reject 502）
11. `home.dart:74`：`special_recommend` 补 `sort/ugc/is_selected/withrecommend/area_code` 五字段
12. `home.dart:117`：yuekuBanner `vip_type` 不要硬编码 0（取真实用户 vip_type）
13. `auth.dart:56`：验证码接口改 https（禁止明文 http）
14. `auth.dart:70`：登录保存 `vip_type` / `vip_token`，供三态（匿名/非VIP/VIP）判定
15. `auth.dart:310` vs `kg_client`：getVerifyInfo 与 verifyservice 前缀路径统一为一套

## 修复要求
- 每处改动前先 `file_read` 完整读该文件
- 每处改动加注释编号：`// F4-01（审查①-B，P1）：<一句话>`
- 改动必须可直接编译（`ApiException` 用 `import '../api/kugou_api_client.dart' show ApiException;`）
- 只用 `file_edit` 工具改，不要用 sed/python 改代码
- 不要改 Dart 逻辑之外的格式

## 报告
改完写 `docs/batch4_fix_1_network.md`：逐条列出「编号 / 文件:行 / 改了什么 / 是否按 Node 对齐」。未修的项写明原因。

完成后 5 行内汇报：修了几条 P1 / 几条 P2 / 哪些没修及原因。
