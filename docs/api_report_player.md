# 播放 / 权益 / 人机验证接口报告

- Base：`https://kapi.344977.xyz`
- 样本：周杰伦《晴天》，`hash=B3A52A7A958BF0AED0EBFBA2E9A818B7`、`album_id=966846`、`album_audio_id=32100650`
- 证据：前轮 `docs/probe_player/` 采样；本轮 DNS 恢复后复测 `/song/url` 与音频代理。
- 以下结论只代表该部署版与该测试歌曲，不能外推为上游酷狗所有接口的统一规范。

## 四种状态

| 状态 | 识别方式 | 实测表现 / 客户端处理 |
|---|---|---|
| 可播放（完整） | `status=1` 且 `url`/`backupUrl` 非空；通常 `priv_status=1` | VIP 及匿名旧样本可返回 `/full/` 地址；取 `url[0]`，HTTP 经 HTTPS 代理。 |
| 可播放（试听） | `status=1` 且地址非空，`priv_status=0`，`hash_offset.end_ms=60000` | 非 VIP 的 `free_part=1` 返回 `/p_0_960115/`；是 60 秒试听而非完整歌曲。 |
| 需要 VIP / 购买 | `status=2`、`fail_process` 为 `["pkg","buy"]`；权益条目 `pay_type=3`、`fail_process=12` | 不能按“空 URL”连续降级；直接给出会员/购买提示。 |
| 无版权 / 不可播放 | 权益条目 `privilege` 的 8 位，或非 1 的可播放状态 | 区分“暂无版权”与其它不可播放；本次样本没有无版权歌曲，属于防御性解析。 |

补充：接口顶层的 `status`（1/2）与 `/privilege/lite` 条目内的 `status`（样本为 0）不是同一字段语义，不能混用。

## 实际采样

| 账号 / 请求 | 128 | 320 | flac | high |
|---|---|---|---|---|
| 非 VIP，`free_part=1` | 128 kbps 试听 | 实际仍 128 kbps 试听 | 实际仍 128 kbps 试听 | 实际仍 128 kbps 试听 |
| VIP，`free_part=1` | 完整 128 | 旧样本为需购买；高音质可完整 | 完整 flac | 完整 high |
| 不带 `free_part` 的旧样本，非 VIP | `status=2` | `status=2` | `status=2` | `status=2` |

本轮复测非 VIP 和 VIP 的 `quality=128&free_part=1`，均得到非空 URL、`priv_status=0`、`bitRate=128000`，路径含 `p_0_960115`。这说明 `free_part=1` 会请求试听，不能依赖它验证 VIP 全曲能力。

## 错误样本

无全曲权限（`docs/probe_player/nonvip_url_128.json`）：

```json
{"status":2,"priv_status":0,"fail_process":["pkg","buy"],"auth_through":[]}
```

人机验证（`docs/probe_player/anon_free_high.json`，`ssaCode` 截断）：

```json
{"errcode":20028,"status":2,"error":"本次请求需要验证","ssaCode":"gz_tx_event_..."}
```

验证信息（`docs/probe_player/verify_info_real.json`）：

```json
{"status":1,"error_code":0,"data":{"v_type":38,"v_type_list":[38],"business":4029}}
```

空提交得到 `{"data":null,"status":0,"error_code":20010}`；`/sidedt` 部署版不可用。`20028` 是业务拒绝，不能当作空 URL 或网络异常吞掉。

## URL 结构证据

- `url` 与 `backupUrl` 都是**数组**；首选 `url[0]`，缺失时才取 `backupUrl[0]`。
- 原始地址为 `http://fsandroid.kugou.com/...`，备用为 `http://fsmobile.tx.kugou.com/...`。
- 全曲路径含 `/full/`；试听路径含 `/p_0_960115/`，与 `end_byte=960115` 对应。
- 客户端把 HTTP 地址转成 `https://proxy.344977.xyz/<原url>`。
- 本轮对两个账号返回的试听 URL 做 `curl -L -r 0-1023`，代理均最终返回 `200 audio/mpeg`。代理会重定向并规范化双斜线；本次返回 960116 字节，说明该代理对 Range 的支持不能简单假定。
- `/privilege/lite` 的 `data` 是各音质条目列表；样本只有 `quality=128` 主条目。`quality_vip=null`、`best_free_quality` 不存在；时长在 `info.duration`（毫秒），封面在 `info.image`。

## 人机验证结论

1. 将 20028 的 `ssaCode` 原样传给 `/get/verify/info?eventid=<ssaCode>`。
2. `v_type=23`：TCaptcha；`32`：短信；`38`：其它类型，本版本显示不支持自动验证。
3. 本次只实际遇到 38；23、32 的分支是保留/预留流程，未宣称已完成端到端验证。
4. 已删除 `/sidedt` 调用及 sid/edt 提交依赖。验证页成功后支持 `onVerified` 重试原请求；登录页原有“收到 true 后重试登录”流程保持有效。
5. 当前播放仓库会保留 `ApiException(20028)`，不再用其它音质请求覆盖它。播放 UI 尚未接入统一验证弹窗，是后续工作。

## 修复清单

- `lib/features/player/data/player_repository.dart`
  - 修复顶层响应解析、URL 数组首选、HTTP 代理。
  - 区分业务失败与空 URL；20028、VIP/购买、无版权不再被降级吞掉。
  - 仅空 URL 按 `super → high → flac → 320 → 128` 降级。
  - 按 `bitRate`/`extName` 标记实际音质，补充试听标记。
  - 修复 `/privilege/lite` 列表详情合并，不再读取不存在的免费最佳音质字段。
- `lib/features/player/data/models.dart`
  - 只解析真实 `quality`；支持 `info.duration`、`info.image`。
- `lib/features/auth/data/auth_repository.dart`
  - 明确 23/32/38 分支；移除 `/sidedt`，提交只使用 eventid、v_type、verifycode。
- `lib/features/auth/presentation/captcha_page.dart`
  - ssaCode→eventid；38 明确不支持；成功后可执行原请求重试。

## 风险与未验证项

- 未运行 Flutter（按要求），未执行 Dart 编译或运行时测试。
- 20028 的 `ssaCode` 目前没有被 `KugouApiClient` 保存到异常对象，播放页暂时只能显示验证错误，无法自动打开验证页。
- 38 没有自动验证实现；不应静默当作成功。23、32 需要真实事件做端到端确认。
- 试听与全曲 UI 尚未使用 `isPreview` 展示标识。
- 播放降级不适用于业务拒绝；若产品希望“高音质无权限时自动尝试低音质”，应另行定义权益降级策略。
- 代理可能不支持标准 Range，流式 seek、大文件内存占用需真机复测。
