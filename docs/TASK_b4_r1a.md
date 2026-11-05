# 第4批·审查①-A：直连客户端核心（只读）

先完整读 `/var/minis/workspace/TiernanMusic/docs/REVIEW_SPEC.md`，其「绝对禁止」「工作方式」「本项目既定口径」全部适用，违反任一条即任务失败。

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 commit `6e46611`

## 报告文件
**`docs/batch4_review_1_network.md`**（用 file_write 建首行标题，之后每读完一个文件立刻 append；禁止读完全部再统一写）

## 范围（逐个 file_read 完整读，禁止 grep）
1. `lib/core/direct/kg_direct_api_client.dart`
2. `lib/core/direct/kg_client.dart`
3. `lib/core/api/kugou_api_client.dart`
4. `lib/core/direct/kg_crypto.dart`

## 核对重点
A. `_directOrFallback` 异常契约：底层异常是否统一包装为 ApiException/DioException；写操作回退是否可能重复提交
B. `_wrap` 对成功判定的覆盖：`status==1` / `status==200`（歌词、搜索）/ `err_code==0`（mcomment）/ 裸 Map（comment、comment/count）——是否有端点被统一按 `status==1` 误判
C. 登录态同步：`setCredentials` 是否同步 kg.token / userid / t1 / dfid；切号是否清理旧态
D. 签名：三种盐（android `OIlwieks28dk2k092lksi2UIkp`、web `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`、register `1014`）使用是否正确；`signature` 是否放 query（不是 header）；`signParamsKey` 的 clienttime 是否秒级；`clearDefaultParams:true` 是否只用于 5 处已验证端点
E. 加密：`playlistAesEncrypt` key=`md5(seed)[:16]` iv=`md5(key)[:16]` base64；`edt_generator` AES-128-CBC（IV `kugousecurity123`）→ RSA-OAEP **SHA-256**
F. 分层：`core/` 是否 import 了 `features/**`
G. 超时/重试/并发：Dio 配置、拦截器、日志是否泄露 token
H. 未使用 import、死代码、拆分残留的错误注释（R1 重构遗留）

## 落盘格式
```
### <文件>:<行号> 简述
- 级别：P0/P1/P2
- 依据：<代码片段>
- 影响：<用户可见后果>
```
末尾追加「问题清单」按 P0/P1/P2 排序。不改代码、不跑构建。完成后 3 行内汇报问题数。
