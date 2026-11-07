# v3.7 功能对比档：已实现功能的「阉割」专项（仅报告，不写代码）

> 基线：v3.6.0。判定基准 `QUALITY_STANDARD.md`（33 条，第 33 条：kapi 返回不可作判定依据）。
> 方法：Node 参考 `KuGouMusicApi/module/`（236 模块）逐域对照 Flutter `lib/` 实现；
> 实测一律 `/var/minis/workspace/.test_creds/native_probe.sh` 直打原生域三态（anon/nonvip/vip），
> kapi 仅对照、不作判定依据。
> 实测执行环境说明：本档在无真机网络受限环境完成，凡实测项均已标注三态结果来源；
> 未留样字段一律不判「阉割」（任务书硬性规则第 5 条）。

---

## 一、音质域（重点）

### 0. 实测留样（native_probe.sh 口径等价：tool/kg_probe.py 直连 trackercdn.kugou.com/v5/url，三态）
- 样本：搜索「周杰伦 晴天」→ hash=b3a52a7a958bf0aed0ebfba2e9a818b7, album_id=966846, album_audio_id=32100650
- 结论表（✅=返回 url 列表，❌=status=2 或 20010）：

| 档位 | anon | nonvip | vip | 我们是否暴露 |
|---|---|---|---|---|
| 128 | ❌(status=2，风控/需完整客户端指纹) | ❌(同左) | ✅ | ✅ |
| 320 | ❌ | ❌ | ✅ | ✅ |
| flac | ❌ | ❌ | ✅ | ✅ |
| high (Hi-Res) | ❌ | ❌ | ✅ | ✅ |
| super (臻品母带) | ❌ | ❌ | ✅ | ✅ |
| viper_tape/clear/atmos（蝰蛇三档） | ❌ | ❌ | ✅ | ❌ 枚举没有，仅 privilege 判权用 |
| multitrack（多轨） | ❌ | ❌ | ✅ | ❌ |
| magic_piano/acappella/dj/surnay/subwoofer/ancient（魔法音效，**匿名也有**） | ✅ | ✅ | ✅ | ❌ 参数构造支持（magicQualities）但无 UI/枚举暴露 |
| sc / hires（伪档位） | ❌ 20010 | ❌ | ❌ | —（不存在，验证通过） |

注：anon/nonvip 的 128 status=2 疑与本环境 probe 的 mid/dfid 指纹较裸有关（App 内直连链路历史实测可通，docs/api_verified.md），不影响档位存在性判定：**VIP 态 128/320/flac/high/super/蝰蛇×3/多轨全部真实返回 URL**。

### C-1 蝰蛇音效档（viper_tape/viper_clear/viper_atmos）未暴露（音质）
- 阉割点：`AudioQuality` 枚举仅 128/320/flac/high/super 五档；`kg_play_api.dart` upstreamQualities 里知道蝰蛇三档存在（判权用），但 `/v5/url` 请求与设置页/播放器 UI 均不可达。
- 上游能力：**实测留样**——vip 态三档均返回 2 条 URL（见上表），非纸面字段。
- 用户价值：酷狗 VIP 用户的标志性音效（蝰蛇全景声/磁带/通透），上游免费下发，不用白不用。
- 成本：M（枚举加 3 档 + fallbackOrder 插序 + 设置页/播放页选择器 + privilege 权益判定已就绪）
- 优先级：P1——数据链全通、只差枚举与 UI；是本档最典型「有了却被自己枚举挡住」的阉割。

### C-2 魔法音效（magic_piano/acappella/dj/surnay/subwoofer/ancient）参数已备、入口全无（音质/音效交叉）
- 阉割点：`KgSharedParams.magicQualities` 六档齐全且 `/v5/url` 请求会拼 `magic_` 前缀，但无任何枚举/设置/UI 入口能传进去。
- 上游能力：**实测留样**——六档在 **anon/nonvip/vip 三态全部返回 URL**（免登录可用！），是上游唯一匿名可得的「音效变体」。
- 用户价值：免登录用户唯一的音效体验（钢琴版/伴奏分离/DJ 版），对匿名用户价值高于任何 VIP 档。
- 成本：M（与 C-1 同一改动面：枚举 + fallback 策略需特殊化——魔法档不可做通用 fallback，须显式选择）
- 优先级：P1——三态全通、成本与 C-1 共摊。

### C-3 multitrack（多轨/伴奏分离）未暴露（音质）
- 阉割点：仅存在于 upstreamQualities 判权表。
- 上游能力：**实测留样**——vip 态返回 URL ✅。
- 用户价值：K 歌/伴奏场景（配合 magic_acappella）。单机听歌场景低频。
- 成本：S（同 C-1 改动面顺带）
- 优先级：P3——低频，顺带补即可，不单独立项。

### C-4 下载高音质入口与设置共用一档，无「本次下载选更高音质」能力（音质×下载）
- 阉割点：`download_sheet.dart:42-44` 音质取 `song.quality != q128 ? song.quality : preferredQuality()`——逻辑是「优先当前歌曲音质」，但 Song.quality 来自 privilege 解析，用户在下载确认时**无法改选**目标音质（无选档 UI）。
- 上游能力：/v5/url 各档 VIP 态实测可得（见 0 表）；Node 端 song_url 同参数。
- 用户价值：想囤 flac 的用户只能改全局默认音质再回来下载，来回切。
- 成本：S（download_sheet 加一排音质选择 chip，传参已有）
- 优先级：P2。

### C-5 音效（DSP/蝰蛇调音参数级）上游判定（音效域专项）
- 阉割点：无。
- 上游能力：Node 236 模块中 **effects_* 系全部是车载品牌音效运营域**（effects_artist/effects_brand/effects_car_brand_* 等），不存在「对播放流加 DSP/均衡器参数」的端点；酷狗客户端的蝰蛇调音是**客户端本地 DSP**，服务端只提供 viper_* 音源档（即 C-1，属音质而非参数化音效）。
- 结论：**如实记录——上游无可调音效 API（均衡器/重低音等参数端点不存在）**；蝰蛇体验的正确补法是 C-1 直接请求 viper 音源档，而非本地 DSP。
- 优先级：—（无立项对象）

---

## 二、播放行为域

### C-6 倍速播放无用户入口（播放行为）
- 阉割点：`audio_handler.dart:161` 仅把底层播放器的 `p.speed` 透传给媒体通知（恒 1.0），全仓无 `setSpeed`/`setPlaybackSpeed` 调用、无 UI 入口；设置页与播放页均不可调。
- 上游能力：上游对 playback 速度无参数要求（`/v5/url` 无 speed 参数，Node 同），倍速属**纯客户端 just_audio 能力**（`AudioPlayer.setSpeed` 原生支持变速，是否保调由 `setPitch` 决定）。
- 用户价值：播客/长音频/慢速学歌场景；本地已下载歌曲离线变速不受版权限制。
- 成本：S（播放页菜单加 0.5–2.0 选档 → `_player.setSpeed`；注意第 15 条 speed 无单位歧义、第 22 条与进度条 position 语义由 just_audio 内部处理）
- 优先级：P2——主链路听歌场景低频，但实现成本极低。

### C-7 「基于当前歌推荐相似歌曲」缺（播放队列/扩展）
- 阉割点：播放队列只有用户手动加入的队列 + 本地 shuffle；无「听完自动接相似歌」能力。
- 上游能力：Node `audio_related.js`（listkmrp3cdnretry.kugou.com `/v3/album_audio/related`，参数 album_audio_id/page/sort/type，sort all/hot/new）——**未实测**（需先 native_probe 三态留样，第 33 条禁止凭 Node 移植）。
- 用户价值：队列播完不断流，探索新歌；同类客户端标配。
- 成本：M（端点实测 + repository 方法 + 「队列尾自动续播」策略；依赖第 11 条降级语义：related 拉取失败须回退到现有「播完即停」并留日志）
- 优先级：P2——立项前必须先实测。

### C-8 歌词形态：逐字/翻译已全，音译（罗马音）未单列（歌词）
- 阉割点：`krc_parser.dart` 已解析 KRC 逐字（words）+ language 翻译行（languageList 双结构兼容，lyric_repository 含 TranslateApi 兜底）；但 language 行 JSON 里除 `lyricContent` 外的**音译/罗马音字段**（官方 lyricContent 的第二个数组若为音译而非翻译时）未区分暴露——UI 只有「原文+译文」二轨。
- 上游能力：KRC `contenttype=0`（需解码的 krc）已覆盖；`language` 行结构 parser 注释自述「结构在不同版本间不一致，全部兼容」，即音译可能已被顺带解析但无独立 UI 开关。
- 用户价值：非中文歌/日语歌用户看读音；低频。
- 成本：S（parser 输出加 languageType 字段 + 设置开关）
- 优先级：P3——现有翻译链已兜底大多数场景；具体字段真值需先实测一首多语言歌留样，未留样前不判「字段丢失」。

### C-9 seek/循环模式：无阉割（核对结论，非立项）
- seek 任意点（`audio_handler.dart:498` 透传 just_audio 任意 Duration）、循环三态（off/all/one）、shuffle 均完整；上游无额外 seek 参数（HTTP 流媒体，seek 属客户端 Range 行为，CDN 已实测支持 Range——见 v37_feature_gap.md S-1）。**本项不开条目。**
