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

---

## 三、搜索域

### C-10 搜索建议（suggest）走 kapi，未直连（搜索）
- 阉割点：`search_repository.dart:257` 的 `fetchSuggest` 走 `KugouApiClient.get('/search/suggest')` → **baseUrl 是 `kapi.344977.xyz`**（app_config.dart:15），是全 App 少数仍经 Node 中转的路径；且解析层用 5 个字段名试探（HintInfo/keyword/KeywordName/name/suggest），说明未固化到 `/v2/getSearchTip` 真实结构。错误时 `catch (_) return const []` 静默降级（第 9 条：无日志无反馈）。
- 上游能力：Node `search_suggest.js` = `/v2/getSearchTip`（searchtip.kugou.com），按 AlbumTipCount/MusicTipCount/MVTipCount/CorrectTipCount/radiotip 分组返回，可带出**歌曲/MV/专辑/歌手分类型联想**。我们只取了字符串列表。
- 用户价值：输入时实时联想是搜索第一触点；kapi 不可用时联想整个消失（且按第 33 条其返回形态不保证与原生一致）。
- 成本：M（直连 searchtip.kugou.com 三态实测 + 分类型解析 + 错误留痕）
- 优先级：P1——既是阉割（分类型联想丢失）又是 kapi 债务清理项。

### C-11 综合搜索（search_complex）未实现，无搜索筛选参数（搜索）
- 阉割点：搜索只有 song/album/author/mv/special/lyric 分 tab（`kg_endpoints_search.dart:14`），无聚合「全部」页；song 搜索无任何筛选参数（音质/时长/地域 area_code 之外）。
- 上游能力：Node `search_complex.js` = complexsearch.kugou.com `/v6/search/complex`（一次请求分类型聚合）；Node `search.js` 支持 `category`/`sorttype`（专辑排序 0 全部/1 最新）、`iscorrection`/`privilegefilter`。**complex 未实测**；sorttype/category 可实测。
- 用户价值：搜一次看全类型；按最新专辑筛歌。
- 成本：M（complex 实测+解析）/ S（sorttype 透传）
- 优先级：P2（complex）/ P3（sorttype）——complex 立项前必须先实测。

---

## 四、歌单 / 歌手 / 专辑域

### C-12 歌单分类（广场 category 全表）未暴露（歌单）
- 阉割点：`home_repository.dart:63` fetchTopPlaylists 支持 categoryId 参数，但 UI 无分类选择入口（仅默认 0），且该端点即 v37_feature_gap.md 记录的 special_recommend 直连 200101 债务。
- 上游能力：Node `playlist_categories.js` 不存在，但 `top_playlist.js`/`sheet_tags.js`/`scene_lists_v2.js` 提供分类标签全表——需先实测（同 feature_gap P2-4，本档不重复立项，指向该档）。
- 用户价值：按分类逛歌单是歌单广场的核心体验。
- 成本：M
- 优先级：P2（与 feature_gap P2-4 重叠，合并跟进）。

### C-13 歌手页缺：相似歌手 / 歌手全部作品分页形态 / 关注（歌手）
- 阉割点：`artist_repository.dart` 仅 fetchDetail/fetchSongs/fetchAlbums 三方法。
- 上游能力：Node 有 artist_videos/artist_honour/artist_follow/unfollow/artist_lists；**无 artist_similar、无 artist_fans 模块**（已核对 236 模块清单）——「相似歌手」与「粉丝数」上游 Node 层即不存在，如实记录不硬造。歌手粉丝数可能在 artist_detail（kmr/v3/author）返回体里，需留样核实后再判。
- 用户价值：歌手页内容丰富度（feature_gap P2-3 已立项视频/荣誉/关注，本档不重复）。
- 成本：—
- 优先级：指向 feature_gap P2-3；「相似歌手」标记为上游无端点。

### C-14 专辑详情字段裁剪（专辑）
- 阉割点：`album_repository.fetchDetail` 返回的 AlbumInfo 需核对简介/发行时间/公司字段——AlbumInfo 模型未含 company/publish_time 之外的介绍文本展示（当前 UI 无专辑简介区块）。
- 上游能力：album_detail 同域已实测 ✅（api_verified.md），返回体含 intro/publish_time/company 等字段（Node album_detail.js 同源）——**字段真值需留样核实**，未留样前不判字段级阉割；UI 层未展示是确证的。
- 用户价值：买专辑前看介绍与发行信息。
- 成本：S（模型加 3 字段 + 详情页一节）
- 优先级：P3。

---

## 五、用户域

### C-15 AuthUser 仅 4 字段，用户等级/勋章/听歌排行全缺（用户）
- 阉割点：`auth_repository.dart:12` AuthUser 仅 userid/token/nickname/avatar；`userDetail` 直连已实现（/v3/get_my_info），但返回体仅用于回填 userid——**几十个字段（等级、头像框、粉丝/关注数、vip 信息、听歌时长）全部丢弃**。
- 上游能力：Node `user_detail.js` 同端点（/v3/get_my_info）；另有 `user_grade_info.js`（听歌等级+时长，lite v2 协议）、`user_history.js`（听歌排行 /playhistory/v1/get_songs）——后两者未实测。
- 用户价值：个人页丰富度；听歌排行是登录用户高频回访点。
- 成本：M（get_my_info 字段留样+解析）；等级/排行 S-M（各 1 端点）
- 优先级：P2——get_my_info 已通，扩字段成本低、留样即知。

### C-16 用户歌单操作：排序/重命名/删除曲目排序未实现（用户×歌单）
- 阉割点：playlist_repository 有 detail/tracks/userPlaylists/collect/delete/addTracks/removeTracks；**无排序（playlist_tracks_sort）、无重命名（playlist_update）、无新建后管理（playlist_add/del 有部分）**。注：删除歌单 deletePlaylist 已有。
- 上游能力：Node `playlist_tracks_sort.js`/`playlist_update.js`——与 feature_gap P2-1 重叠，本档确认「重命名」也是缺口（feature_gap 只点了排序/标签/相似/导入/封面）。
- 用户价值：歌单改名是管理基本功。
- 成本：S（playlist_update 单端点）
- 优先级：P2。

### C-17 收藏列表仅 MV 一类（用户）
- 阉割点：library_page 仅收藏 MV 列表；无收藏专辑/收藏歌手列表。
- 上游能力：Node 收藏系有 `mv_collect.js`（已用）+ album/artist 收藏散见 favorite_count/album 系——专辑/歌手收藏列表**无独立 Node 模块**，需留样核实（可能走 user_batch_union 或 playlist 体系），未留样不判字段级阉割。
- 用户价值：「我收藏的专辑」是资料页标配 tab。
- 成本：M（依赖先实测确认端点）
- 优先级：P3——端点不明，先探后立。

---

## 六、补齐优先级排序表

| # | 条目 | 域 | 成本 | 优先级 | 状态 |
|---|---|---|---|---|---|
| 1 | C-1 蝰蛇三音源档暴露 | 音质 | M | **P1** | 实测 ✅ vip 三态 URL 可得 |
| 2 | C-2 魔法音效六档入口（匿名可用） | 音质/音效 | M（与 C-1 共摊） | **P1** | 实测 ✅ 三态全通 |
| 3 | C-10 suggest 直连化+分类型联想 | 搜索 | M | **P1** | 现走 kapi，双重债务 |
| 4 | C-4 下载音质改选 | 音质×下载 | S | P2 | 数据链已通 |
| 5 | C-6 倍速播放 | 播放 | S | P2 | 纯客户端能力 |
| 6 | C-15 用户详情字段扩展 | 用户 | M | P2 | get_my_info 已通 |
| 7 | C-16 歌单重命名/排序 | 歌单 | S | P2 | 与 feature_gap P2-1 合并 |
| 8 | C-7 相似歌续播 | 播放队列 | M | P2 | 端点未实测，先探后立 |
| 9 | C-11 综合搜索 complex | 搜索 | M | P2 | 未实测 |
| 10 | C-14 专辑简介/发行字段 | 专辑 | S | P3 | 需留样 |
| 11 | C-3 multitrack | 音质 | S | P3 | 顺带补 |
| 12 | C-8 音译歌词轨 | 歌词 | S | P3 | 需留样 |
| 13 | C-17 专辑/歌手收藏列表 | 用户 | M | P3 | 端点不明 |

**上游不支持（如实记录，不立项）**：可调音效/均衡器参数端点（C-5）、相似歌手独立端点、歌手粉丝列表模块。

## 七、与 v37_feature_gap.md 的互补说明

- **重叠项**（本档只补充细节不重复立项）：C-12→P2-4、C-16→P2-1、C-13→P2-3。feature_gap 是「没有的功能」，本档相同域只记「阉割面」。
- **本档新发现**（feature_gap 未覆盖）：C-1 蝰蛇音源档、C-2 魔法音效（feature_gap 把 effects_* 归为「运营营销域不做」——那是车载品牌 effects，**不是蝰蛇音源档**，属归类错误，此处更正）、C-4 下载音质改选、C-6 倍速、C-8 音译轨、C-10 suggest 直连化、C-14 专辑字段、C-15 用户字段、C-17 收藏列表。
- **纪律合规**：C-1/C-2/C-3 结论有原生直连三态留样；C-7/C-11/C-17 标注「未实测，先探后立」；未留样字段一律未判阉割（任务书硬规则第 5 条）。
