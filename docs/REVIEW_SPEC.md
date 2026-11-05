# 审查代理通用规范（v3.0 LTS）

> **本文件是补充说明；判定依据以 `docs/QUALITY_STANDARD.md`（32 条原则）为准。**
> 冲突时以 QUALITY_STANDARD 为准。


> 本文件为第 4/5 批审查代理的强制任务书附件。与主任务书冲突时以主任务书为准。

## 一、绝对禁止（违反任一条 = 任务失败）
- 禁止下载 Flutter/Dart SDK、禁止 apk/pip/npm 装包、禁止 git clone
- 禁止构建、禁止运行测试、禁止启动本地 kapi/Node 服务
- **禁止修改任何文件**（唯一例外：本任务指定的 `docs/batch4_review_*.md`）
- **禁止给修复建议、禁止给出改后代码**——只写：问题 + 位置 + 依据 + 影响
- 禁止 grep/正则筛选代码，必须 `file_read` 从头读到尾
- 禁止读其他批次的报告（`docs/batch1_*` `batch2_*` `batch3_*` `docs/check_*`），防锚定

## 二、工作方式
- 工作目录：`/var/minis/workspace/TiernanMusic`
- **实时落盘**：每读完一个文件立刻 append 到指定报告，禁止"读完全部再统一写"（历史上多次因超时丢全部产出）
- 超时预算 120 分钟，文件多时按域分批推进，宁可少覆盖也要有产出

## 三、本项目既定口径（审查判定必须据此）

### 1. 接口必须优先走酷狗原生域名（最高优先级口径）
**所有接口必须优先使用酷狗原生网关；禁止把 kapi 网关（`kapi.344977.xyz`）当作实现。** kapi 仅允许作为「尚未移植路径」或「上游真实不可用」的兜底。

判定要点：
- `_directOrFallback` 必须确认直连分支真实可用，而不是「必然失败、实际全靠 kapi」的摆设。
- `_wrap` 成功判定若把原生返回误判为失败 → 每次都白跑直连再靠 kapi，等于没用原生网关，属重点问题类型。
- Repository / Provider 不得 new 裸 `KugouApiClient()`（会整体走 kapi）；装配必须注入 `kugouApiClientProvider` / `kgDirectApiProvider`。
- `AppConfig.kugouApiBase` 只允许出现在「回退」与「Cookie 存储」位置。
- 参数形态错误（v1/v2 版本、`signature` 放 header、`clearDefaultParams` 用错端点、字段名不符）导致的直连假失败 = P1 问题，需给出 Node 源码对照依据。

原生域名对照：
| 域 | 用途 |
|---|---|
| `complexsearch.kugou.com` | 歌曲/专辑/歌手/MV/歌单搜索（v3，v2 字段有 40+ 差异） |
| `pubsongs.kugou.com` | 歌单详情 `/playlist/detail` |
| `trackercdn.kugou.com` | 播放地址 `/v5/url` |
| `openapi.kugou.com` | 歌手详情 `/kmr/v3/author`、歌手单曲 `/kmr/v1/audio_group/author`（必须 v1，返回 List）、榜单歌曲 `/v2/rank/audio`（`kg-tid: 369`） |
| `login-user.kugou.com` + `userservice.kugou.com` | 二维码 key、`/risk/v3/r_register_dev` |
| `lyrics.kugou.com` | `/v1/search`（**必须带 signature**）、`/download`（需 `ver:1&charset=utf8`） |
| `gateway.kugou.com` | 多数业务接口；评论走 `x-router: m.comment.service.kugou.com` |
| `ocean.kugou.com` / `musicadservice.kugou.com` | 榜单列表 / 新歌发布 |

判定规则：
- 某 case 若「只走 kapi 回退」或「直连恒失败只能靠 kapi」→ **记为问题**，写明位置与原因。
- 直连因参数形态与 Node 源码不一致而必然回退 → 本身就是问题。
- 已知例外：`top/playlist`（`/v2/special_recommend`）直连恒 `200101`，保留 kapi 回退，可在报告中作为「既知约束」列出但仍需指出依赖事实。

### 2. 签名
- 三种盐：android `OIlwieks28dk2k092lksi2UIkp`、web `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`、register `1014`
- `signParamsKey(data) = md5(appid + salt + clientver + data)`
- **`signature` 必须放 query 参数，不是 header**
- `clearDefaultParams: true` 只允许用于 5 处已验证端点：`/search`（歌词）、`/index.php`×3（评论写）、`/v1/video`
- `signParamsKey` 的 `clienttime` 必须是**秒**（不是 YYYYMMDDHH）

### 3. 加密
- `playlistAesEncrypt`：key = `md5(seed)[:16]`，iv = `md5(key)[:16]`，输出 base64
- `playlist/del` 与 MV 收藏同构：AES body + RSA `p` + 二进制响应
- `edt_generator`：AES-128-CBC（固定 IV `kugousecurity123`）→ RSA-**OAEP SHA-256**（早期误用 SHA-1 已修）

### 4. 成功判定不统一（逐端点核对，不可一律 `status==1`）
- `status == 1`：多数业务接口
- `status == 200`：歌词、搜索
- `err_code == 0`：mcomment
- 裸 Map：comment / comment/count

### 5. 架构分层
- `core/` 禁止 import `features/**`
- 只有 `features/*/data/` 可以发网络请求
- UI 层零直接构造 Repository

### 6. 异常契约
- `_directOrFallback` 必须把底层异常统一包装为 `ApiException` / `DioException`
- 写操作（收藏、删除、评论、上传）**不得因回退而重复提交**

### 7. 三态兼容
匿名 / 非 VIP / VIP 三种登录态都要能正常工作，任何「依赖 VIP 字段」的判定必须有非 VIP 降级路径。

## 四、落盘格式
```
### <文件>:<行号> 简述
- 级别：P0/P1/P2（UI 类用 P1/P2/P3）
- 依据：<代码片段或对照结论>
- 影响：<用户可见后果>
```

末尾追加「问题清单」按级别排序。
