# v3.7 专项实测：付费歌曲音频获取链路对比（标准版直连 vs 概念版通道）

> 日期：2026-11-07 ｜ 性质：探索性实测（第 28/29/33 条纪律），只测不改业务代码。
> 脚本：`/tmp/probe_paid.py`（步骤 1–3）、`/tmp/probe_lite_v5.py`、内联 Node 复刻（`module/song_url.js` + `util/request.js` + `platform=lite`）。
> 测试曲目：周杰伦《晴天》（VIP/付费曲，hash=`b3a52a7a958bf0aed0ebfba2e9a818b7`，MixSongID=32100650，全曲 269s）。
> 全部为原生域直连（trackercdn.kugou.com / trackercdnbj.kugou.com / gateway.kugou.com x-router / userservice.kugou.com / kugouvip.kugou.com），kapi 仅用于读 cookie，不参与任何判定（第 33 条）。

## 0. 本轮核心修正（相对 v37_lite_channel_probe.md 的关键差异）

上一轮 lite 全 31833 的根因**不是「lite 通道被拒」**，而是我们 Python 复刻的 signKey 形态与 Node 库存在差异（Node `helper.js` signKey 为 `md5(hash+盐+appid+mid+userid)`，且 appid 必须与请求内 `appid` 参数一致；lite 化时请求默认参数 appid/clientver 必须与 key 计算同源）。本轮用 **Node 库本体**（`platform=lite` + `createRequest` + `module/song_url.js` 真实参数形态：`pid=411 / page_id=967177915 / ppage_id=lite 三值 / need_ogg=1 / clientver=11430 / version=11430`）**打通了 lite 匿名通道的 /v5/url**：签名被接受，返回 status=2 试听墙 + 60s offset（详见 §3）。

## 1. 付费歌曲样本确认

- `media.store.kugou.com /v2/get_res_privilege/lite`（gateway x-router 直连，非 VIP 标准版 cookie）：
  - 128/320/flac/high/viper 全档：`privilege=10, status=0, pay_type=3, fail_process=12` → 确认付费（VIP）曲目
  - `trans_param.ogg_128_hash=D6E0229D1BCD4453981743F6B53F9D75`（概念版 128 实际播放的 ogg 资源）
- `/privilege/lite`（路由模块名同名端点）直打网关 502（kws 网关层拒绝，无法直连该路径；权益判定改用 mediastore 端点，等效）。

## 2. 标准版直连基线（现状三态实测，appid=1005）

| 状态 | 请求 | 结果 |
|---|---|---|
| 非 VIP，不带 IsFreePart | trackercdnbj /v5/url | `status=2`，`fail_process=["pkg","buy"]`，`hash_offset={start_ms:0,end_ms:60000,end_byte:960115}`，无 URL → **60 秒试听墙** |
| 非 VIP，`IsFreePart=1` | 同上 | `status=1`，2 条 URL（fsandroid.kugou.com，`p_0_960115` 路径段） |
| VIP（上轮审计留样） | 同上 | 三档全 OK，flac 真实 URL |

**IsFreePart=1 实测下载**：960116 字节，2296 个 MP3 帧 → **真实时长 59.98 秒 ≈ 60 秒**。响应里 `timeLength=269`（全曲时长）只是元数据，**不是**实际可播时长；URL 路径段 `p_0_960115` 明确截到 end_byte=960115。

**结论：标准版直连对免费用户拿到的「高潮部分」实为「前 60 秒试听」（start_ms=0 → end_ms=60000），不是高潮片段，也不是全曲。**（注：`/v5/url` 带 `IsFreePart=1` 时 offset 为前 60s；若产品话术称「高潮」，与协议实测不符。）

## 3. 概念版（lite）通道深挖

### 3.1 lite 设备注册（PKCS1-V1_5 修正后）

- 上一轮 20010 `rsa failure` 的疑点定位：Node `register_dev.js` 用 `rsaEncrypt2`（**forge RSAES-PKCS1-V1_5 填充**），我们 probe 用的是裸 RSA（zero-padding）。
- 本轮按 PKCS1-V1_5 重打 `userservice.kugou.com/risk/v3/r_register_dev`：**仍 `20010 rsa failure`**。说明除填充外还存在未复刻差异（可能是密钥版本、设备态签名或请求体形态），dfid 仍未拿到 → 匿名 lite 设备态依然缺失（验证边界保留）。

### 3.2 lite 匿名通道 /v5/url（本轮打通）

用 Node 本体复刻（`platform=lite`），非 VIP **标准版 cookie 的 token/userid 一概不带**（上一轮 20018 已证不通用），纯匿名 + lite 参数组：

| 音质 | IsFreePart=0 | IsFreePart=1 |
|---|---|---|
| 128 | status=2（试听墙），end_ms=60000，无 URL | **status=1，URL 返回** |
| 320 / flac / high / super | status=2，无 URL | **status=1，URL 返回** |

- 返回 URL：`fs.youthandroid2.kugou.com/.../v3/<hash>/yp/p_0_960115/ap3116_mi<mid>_pi411_mo51_..._qu128_....mp3`
- **实测下载：960116 字节 = 2296 帧 = 59.98 秒**——与标准版 IsFreePart=1 完全相同的 60 秒片段（同一个 `p_0_960115` 截断字节段）。
- `timeLength=269` 依然只是元数据全曲时长。

### 3.3 lite 通道 + 标准 cookie 登录态

- lite 参数组 + 标准 token/userid（nonvip）：`31863 no free part info`（该 cookie 与 lite 设备态不匹配，token 不被接受）→ **登录态在 lite 匿名化请求里无效也无害，行为与纯匿名一致**。

## 4. 用户假设判定

**「概念版通道，免费登录用户能获取付费歌曲的完整音频」——不成立。**

实测（Lite 匿名通道，签名被服务端接受，非"打不通"假象）：

1. 概念版通道对付费歌曲同样返回 60 秒试听墙（status=2 / end_ms=60000），`IsFreePart=1` 给的也是**同一份 60 秒片段**（字节级同一文件 960116B）。
2. 概念版不提供任何「免费完整听付费歌」的协议级旁路：320/flac/high/super 全档非 VIP 一律 status=2。
3. Node `privilege_lite.js` 的 `freeListen = isLite && quality === '128' && need_vip` 是**UI 层展示逻辑**（概念版 App 弹窗里对 128 档的提示方式），上游 /v5/url 实测并不因此放行全曲。

**边界声明**：
- 本轮未复刻出 lite 设备注册（20010，PKCS1-V1_5 修正后仍失败），未拿到 lite 通道 dfid；若概念版真实客户端的**登录态设备**（注册过 dfid + 概念版账号登录）走 /v5/url 有额外放行策略，则超出本轮验证能力（需概念版真机抓包）。但**匿名 lite 通道已打通且行为与标准版完全一致**（60s 试听），用户假设所描述的「概念版独有完整音频」在可复刻范围内不存在。
- 概念版账号体系（busi_type=concept 的 svip/dvip/qvip）是付费会员查询体系（上轮已证 is_vip=0），非免费权益（见 v37_lite_channel_probe.md §4，本轮未重复验证）。

## 5. 结论表

| 问题 | 答案 | 证据 |
|---|---|---|
| 标准版直连对付费歌非 VIP 给什么 | 60 秒试听（IsFreePart=1 可取 URL，实际 59.98s，非高潮非全曲） | §2 下载+ffprobe |
| 概念版匿名通道能否拿全曲 | 不能，行为与标准版一致（60s） | §3.2 同字节截断 |
| lite 签名是否能通过 trackercdn | **能**（上轮 31833 为我们侧 signKey 形态 bug，本轮 Node 本体打通） | §3.2 status=1 |
| 上一轮「凭证不通用 20018」结论 | 维持成立（标准 cookie 在 lite 参数下不被用户态端点接受） | 上轮+本轮 31863 |
| lite 设备注册 | 仍 20010（PKCS1-V1_5 修正后），验证边界保留 | §3.1 |
| 用户假设 | **不成立**（在可复刻范围内） | §4 |

## 6. 工程建议（不改业务代码，仅记录）

1. `kg_crypto.dart` 中 lite 常量保留零成本即可；但**不得**因「概念版可完整听付费歌」的传言接入 lite 通道——实测无此能力。
2. TiernanMusic 现有标准版直连（VIP flac / 非VIP IsFreePart=1 60s 试听）已是协议可达最优路径。
3. signKey 形态：若未来需要复刻 lite 通道，直接以 Node `helper.js` signKey + 请求内 appid 同源为基准，勿再自造裸 RSA/PKCS1 形态猜测。

---
*局限：本轮样本一首（晴天）；ffprobe 时长用帧计数法（2296×1152/44100）规避 VBR 头估算误差。所有 URL 均即时过期（签名时效约几分钟），复测需重跑脚本。*
