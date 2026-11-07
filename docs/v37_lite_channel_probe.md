# v3.7 专项实测：概念版（lite）API 通道验证

> 日期：2026-11-07 ｜ 性质：探索性实测（第 28/29/33 条纪律），只测不改。
> 脚本：`/tmp/probe_lite.py`、`/tmp/probe_lite2.py`（monkeypatch kg_probe.py 常量为 lite 组）。
> lite 参数组：appid=3116 / clientver=11440 / androidSaltLite / signKeySaltLite / 概念版 RSA 公钥
> （模数自 Node crypto.js:5 `publicLiteRasKey` 经 Node crypto 导出，e=010001）。
> 全部为原生域直连，无 kapi 参与结论。

## 1. 设备注册（lite 通道）

- 端点：`POST https://userservice.kugou.com/risk/v3/r_register_dev?part=1&platid=1&p=<rsa>`
- 请求体：设备信息 JSON → AES-CBC(base64, 随机 seed)（对齐 register_dev.js），`p` = 裸 RSA(lite 公钥) 加密 `{"aes":seed,"uid":0,"token":""}`
- **响应：`{"data":"rsa failure","status":0,"error_code":20010}`**
- 判定：**失败**。lite RSA 公钥本身可达服务器（返回的是明确的 20010 而非网关拒绝），说明端点在线、参数路径正确；`rsa failure` 表明服务端用标准版私钥解不开概念版公钥密文——该端点（或我们的加密形态：裸 RSA vs PKCS1、hex 大小写）与概念版真实客户端存在未复刻的差异。未拿到 dfid。

## 2. 登录/凭证（lite 语义）

- 端点：`POST gateway.kugou.com/v3/get_my_info`（x-router=usercenter.kugou.com），标准版 cookie 的 token/userid + **lite appid/clientver**（RSA `p` 也用 lite 公钥）
- nonvip (userid=2461028533)：`error_code=20018`（无效凭证/参数），未返回昵称
- vip (userid=1666835066)：同上 `20018`
- 判定：**标准版凭证在 lite 参数下不被用户态端点接受**。「凭证双轨通用」假设不成立——概念版通道需要概念版自己申请的凭证，标准 token 无法跨通道复用。

## 3. 核心验证：lite 通道拿音频（/v5/url，trackercdn 直连）

- 曲目：周杰伦《晴天》hash=b3a52a7a958bf0aed0ebfba2e9a818b7（search 实测取 AlbumID=966846 / MixSongID=32100650）
- lite 签名组（key = md5(hash + signKeySaltLite + 3116 + mid + userid)）：

| 状态 | 128 | 320 | flac | high/super/hires | 错误码 |
|---|---|---|---|---|---|
| anon | ✗ | ✗ | ✗ | ✗ | 31833 illegal key |
| nonvip | ✗ | ✗ | ✗ | ✗ | 31833 illegal key |
| vip | ✗ | ✗ | ✗ | ✗ | 31833 illegal key |

- 标准版对照组（同 hash、appid=1005，同轮实测）：vip 三档全 OK（含 flac，拿到 `fsandroid.kugou.com/...quflac...` 真实 URL）；anon/nonvip 也拿不到 URL。
- 判定：**trackercdn /v5/url 拒绝 lite 签名 key（31833），三态全拒**。概念版通道不能直接复用该播放端点 + lite 盐值组合——要么概念版走的是别的播放端点/网关，要么 key 需配合概念版通道注册的 dfid/设备态。**未观察到任何绕开 20028/免费墙的迹象**（连 vip 都被拒，说明墙没被绕开，而是签名体系不被接受）。

## 4. 每日 VIP 假设验证

- `kugouvip.kugou.com/v1/get_union_vip`（busi_type=concept, opt_product_types=dvip,qvip, product_type=svip，直连原生域）：`status=1`，返回 `is_vip=0, vip_type=0, vip_begin_time=""` —— **该免费用户在 concept 通道下无任何 VIP 权益**。
- `kugouvip.kugou.com/v2/batch_union_vipinfo`（POST，get_type=2, busi_type=concept）：`status=1`，该用户 `is_vip=0, is_paid_vip=0, purchased_type=0, y_type=0`（vip_limit_quota.total=500 是配额定义，不是权益）。
- `receive_vip_listen_song`（youth/v1/recharge，source_id=90139）：直连 kugouvip 404；经 gateway x-router `params invalid`（20017）——未找到可用领取路径。
- 判定：**Node 库存在这三个「概念版会员查询/领取」模块 ≠ 存在免费每日领 VIP**。实测显示 concept 通道会员态为全 0，且无一条可成功触发的领取端点。「免费用户自动通过概念版 API 申请每日 VIP」在协议层无实证支撑（若真实概念版 App 有看广告领一天 VIP 的活动，也需要完整的设备态/广告上报链路，本脚本未复现成功）。

## 5. 结论

**用户假设：不成立。**

| 子假设 | 结果 | 证据 |
|---|---|---|
| 标准凭证可在 lite 通道通用 | ✗ | get_my_info + lite 参数 = 20018（两态） |
| lite 签名可在播放端点换 URL | ✗ | /v5/url 三态 × 全档位 = 31833 illegal key |
| lite 通道避开 20028/免费墙 | ✗ | 连已付费 vip cookie 用 lite 签名也被拒；无任何 URL 返回 |
| 免费用户 lite 通道有每日 VIP 权益 | ✗ | get_union_vip / batch_union_vipinfo 均回 is_vip=0；领取端点 404/20017 |
| lite 设备注册可用 | △ 未验证成功 | 20010 "rsa failure"，加密形态存在未复刻差异 |

**lite 通道的真实差异（实测所见）**：独立的 appid/clientver/双盐值/RSA 公钥是真实存在的配置，kugouvip.kugou.com 上确实有 busi_type=concept 的会员体系端点（batch_union_vipinfo 正常应答），但该体系是**付费会员查询体系**（svip/dvip/qvip 产品类型），不是免费每日 VIP；且播放网关 trackercdn 不认 lite 签名 key。概念版 App 大概率走的是另一条播放链路（非本脚本能复刻的 /v5/url 组合），或需要概念版通道注册的完整设备态。

**接入成本评估**：不涉及——无接入价值。现有标准版直连链路（vip 三态可拿 flac）已是可达的最优路径；为接 lite 通道需要攻克设备注册加密差异 + 未知的播放端点，投入产出比为负。建议：kg_crypto.dart 中已内置的 lite 常量保留即可（零成本），不为 lite 通道新增任何业务代码。

---
*局限声明：anon 态标准版 /v5/url 本轮也拿不到 URL（错误体为空），与历史轮次差异可能来自风控节奏；不影响 lite 对照结论（lite 全态有明确 31833 拒绝签名）。*
