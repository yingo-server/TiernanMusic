# v3.7 功能缺失对比档（仅报告，不写代码）

> 基线：v3.6.0（9d687d8）。判定基准 `QUALITY_STANDARD.md` 33 条。
> 方法：全量盘点 Node 参考项目 `KuGouMusicApi/module/`（**236 个模块**）↔ Flutter `lib/features/*/data/` 公开方法 + `kg_endpoints_*.dart` 分派表，做差集后按「用户价值 / 接口已实测 / 架构契合 / UI 入口暗示」筛选。
> 依据第 33 条，kapi 返回仅作对照；依赖未实测端点的功能一律标「需先实测」。

## 一、双面盘点

### Node 功能域 → Flutter 现状

| 功能域 | Node 模块（代表） | Flutter 现状 |
|---|---|---|
| 搜索 | search / search_complex / search_hot / search_suggest / search_lyric / search_mixed | ✅ 全有（search_repository 13 方法，含联想/热词/歌词/多类型） |
| 播放链路 | song_url(_new/_auth/_merge) / privilege_lite / lyric / krm_audio | ✅ 全有（直连 + dfid 注册闭环） |
| 歌单 | playlist_* 15 个（增删歌/排序/收藏/标签/相似/导入/封面/分享） | 🟡 读链路 + 增删歌/收藏/新建有；**排序、标签、相似、导入、封面改、官方分享缺** |
| 榜单 | rank_list / rank_audio / rank_info / rank_top / rank_vol / song_ranking | 🟡 list+audio 有；rank_info/top/vol、全球榜筛选缺 |
| 每日推荐 | everyday_recommend / everyday_history / everyday_friend / everyday_style | 🟡 recommend 已有（实测 ✅）；**听歌日历/好友在听/风格推荐缺** |
| 歌手 | artist_* 12 个 | 🟡 detail/audios/albums 有；**歌手视频、荣誉、关注/取关、新歌速递缺** |
| 专辑 | album_* 5 个 | 🟡 detail/songs 有；**数字专辑商店 album_shop、动态封面缺** |
| 评论 | comment_* 10 个 | 🟡 音乐/歌单评论 + 楼中楼 + 点赞/删除有；专辑/MV 评论缺（低频） |
| MV/视频 | kmr_audio_mv / video_* / mv_collect | 🟡 MV 搜索播放 + 收藏/取收藏 + 收藏列表有；**MV 弹幕、相关视频缺** |
| 电台 FM | personal_fm / fm_class / fm_songs / fm_recommend / pc_diantai / sidedt / yueku_fm | ❌ **全缺**（大块空白） |
| 听书长音频 | longaudio_* 9 个 | ❌ **全缺**（大块空白） |
| 用户 | user_detail/history/follow/fans/cloud/grade/preference/purchased | ❌ 除 user_detail 外几乎全缺；**云盘 user_cloud、已购、听歌排行缺** |
| 一起听 | listen_together_* 8 + team_* 7 | ❌ 全缺（社交重功能，价值存疑） |
| 场景/主题歌单 | scene_* 7 / theme_* 5 / sheet_* 7 | ❌ 全缺（歌单广场只有 special_recommend 一路） |
| 上报/偏好 | playhistory_upload / user_listen_report / lastest_songs_listen | ❌ 缺（不上报则「最近在听」「每日推荐」个性化退化） |
| 其它 | song_climax(高潮试听) / song_barrage(歌曲弹幕) / import_playlist / ai_recommend / top_card | ❌ 全缺 |

### 已实测可用端点（docs/api_verified.md，原生直连）
search 系、rank list+audio、playlist detail/track/all、artist detail/audios/albums、album detail/songs、mv、comment 系、privilege/lite、song/url、video detail/url、lyric、yueku、everyday/recommend、login qr、get/verify_info、top_song。**不可用：top/playlist special_recommend 直连恒 200101（保留 kapi 回退）。**

---

## 二、特别评估项（任务书点名）

### S-1 下载断点续传（Range）——成本 S，收益高，CDN 已实测支持 ✅

**实测（本档 2026-11-07，源 `fsandroid.kugou.com` 真实音频直链，GET /v5/url 带 VIP cookie 经 kapi 取 URL——第 33 条注明：URL 本身是 CDN 原始地址，Range 行为属 CDN 层，不受 kapi 包装影响）：**

| 请求 | 结果 |
|---|---|
| HEAD | 200，`Content-Length: 4317292`，**`Accept-Ranges: bytes`** |
| `Range: bytes=0-999` | **206 Partial Content**，`Content-Range: bytes 0-999/4317292` |
| `Range: bytes=1000-1999`（模拟续传） | **206**，`Content-Range: bytes 1000-1999/4317292` |

结论：**酷狗 CDN（fsandroid/fsmobile.tx.kugou.com 同构）原生支持标准 HTTP Range 断点续传，无需任何额外鉴权参数**（签名在取 URL 一步，已过期 URL 续传需重新取 URL 后带 Range 续打，CDN 直链有效期约 5 分钟——`time=202611070843` 时间戳）。

- 用户价值：弱网/大文件（flac 30MB+）下载中断不再从 0 开始；App 被杀后可续
- 成本：**S（约半天）**。`download_repository.dart` 已有 Dio cancel/resume 生命周期，只需：暂停前记 `received` → 恢复时本地读临时文件长度 → `Options(headers: {'range': 'bytes=$len-'})` → 206 时 append 写、200 时重写。注意已有 D-01 修复的临时文件名音质维度，续传键需覆盖 hash+quality
- 依赖接口：CDN Range 已实测 ✅；URL 过期重取走 `song/url` 已验证 ✅
- 优先级：**P1**（成本最低、主链路收益最直接）
- 备注：坑①URL 过期后 Range 请求会 403/302，需重新 resolve 后用 `Content-Range` 校准偏移；坑②200/206 双分支必须显式处理，200 表示 CDN 不支持断点、须整写（第 11 条：降级触发与退出条件明确）

### S-2 20028 三套验证实现收敛——架构级，M

Node 侧 20028 是单一 `get/verify/info → v_type 分发 → 回填重试` 流水线；Flutter 侧现存**三套平行实现**（auth_repository 内嵌分支 / verification_service / captcha_types+captcha_page），错误码判定、sessionid 回填、重试语义互不一致（v35_review_A3）。播放 URL 链路是 20028 高发区（本档实测又复现一次：同一 ssaCode 对 anon/nonvip/vip 全部返回），收敛后播放失败率直接受益。
- 用户价值：触发验证的歌曲不再「永久播不了」
- 成本：**M（1-3 天）**——纯架构收敛不新增端点；`get/verify/info` 已实测通（假 eventid 正确报 ec=36001，接口可用）
- 依赖接口：get/verify_info 已验证；**v_type=38 的具体验证提交/回填端点需先实测**（sidedt 部署版无路由，回填路径未证）
- 优先级：**P1**（v3.6 已列为遗留决策项；不收敛则任何播放功能增强都建立在三义性状态上）
- 备注：建议以 `verification_service` 为唯一实现，其余两套并入；用第 5 条状态单一来源判定

### S-3 slider_solver 接线或删除——决策项，半天

全文件死代码（唯一引用是自身）。依赖 `package:image`，v_type=38 若为滑块验证且能拿到背景/拼图图（`get/verify/info` 返回 sessionid + 可能有图 URL，**需先实测**），则接线到 captcha_page；若验证图在腾讯跨域 iframe（文件头注释自认 TCaptcha 场景不可注入），则按第 32 条删除，连带 pubspec 依赖减重。
- 优先级：**P2**（与 S-2 同批决策；接线前提未实测前不得接线）

### S-4 「收藏 MV」数据链完整性——✅ 已闭环，无缺口

V34-UI-01 已在 UI 档补入口（搜索页菜单 + MV 页），数据链核实：`mv_collection_repository.setCollected/cancel`（二进制 body，v35 修复）→ `library_page.dart:518 libraryCollectedMvsProvider.fetchCollected()` → main.dart 登录态 invalidate。**数据链完整，本档不再开项**；仅剩 P3：收藏列表无下拉刷新（随 UI 批）。

### S-5 每日推荐 / 电台 / 数字专辑 / 歌手电台 价值排序

| 功能 | 价值 | 接口状态 | 结论 |
|---|---|---|---|
| 每日推荐（深化：听歌日历 everyday_history） | 高——登录用户最常用个性化入口，且 everyday_recommend **已实测+已接 home_repository.fetchDailyRecommend**，只差 history 展示层 | everyday_history 需先实测 | 做，P1（成本 S） |
| 个人 FM / 电台（fm_songs/fm_recommend/fm_class） | 中高——「随便听听」是次高频主链路需求，全 app 目前没有任何「不选歌就开始听」的入口 | fm_songs/fm_recommend **需先实测** | 做，P1（成本 M，先实测后立项） |
| 歌手电台（artist audos_fm / sidedt） | 低 | 需先实测 | 不做（v3.8 再议） |
| 数字专辑（album_shop/user_purchased） | 低-中——付费内容，本项目用户基数小 | 需先实测 | 不做（P3） |
| 听书 longaudio | 中——内容形态不同（章节/倍速），架构改动大 | 9 个端点全需先实测 | v3.8 专项评估 |

---

## 三、推荐功能缺口（按优先级）

### P1-1 下载断点续传
见 S-1。收益高、成本 S、已实测、纯现有架构内改动。**v3.7 首选。**

### P1-2 每日推荐「听歌日历」+ 历史推荐回看
- Node 模块：`everyday_history.js`（GET，query: date/页码；返回历史每日推荐歌单）
- 用户价值：登录用户「今天没听/昨天那份想再听」；现有 fetchDailyRecommend 只有当日
- 成本：S（<1 天）——repository 加 1 方法 + 日历选择 UI
- 依赖接口实测状态：**需先实测** `everyday_song_recommend` 历史日期参数形态（native_probe nonvip 一发即知；everyday_recommend 本体已实测 ✅，参数差异小、风险低）
- 优先级：P1——高频入口的天然延伸，架构零新增

### P1-3 「随便听听」个人 FM
- Node 模块：`fm_songs.js` + `fm_recommend.js` + `fm_class.js`（GET，返回 songs[] 含 hash，可直接复用 player_repository.playSong）
- 用户价值：一键开始听，无需选歌选歌单——主链路（播放）已有、搜索/歌单已有，这是差集中**用户价值最高的次高频需求**；yueku/fm 域是 Flutter 最大功能空白
- 成本：M（1-3 天）——新 feature/fm（repository + provider + 一页 UI，播放/收藏按钮复用现有链）
- 依赖接口实测状态：**需先实测** fm_songs/fm_recommend 原生直连（kapi 对照显示可用但未留原生三态样本，第 28/29 条禁止直接移植）
- 优先级：P1（实测通过即 P1；实测失败降 P3）
- 备注：契合点——返回结构与 yueku（已实测）同构；坑——FM 下一首需要上报收听行为才准，见 P2-3

### P1-4 20028 验证收敛
见 S-2。**v3.7 必做（架构级）**，先于任何依赖播放 URL 的新功能。

### P2-1 歌单排序 / 标签 / 相似歌单
- Node 模块：`playlist_sort.js`（body: listid+sort 序列）/ `playlist_tags.js` / `playlist_similar.js`
- 用户价值：整理歌单（拖动排序）是歌单管理次高频；相似歌单提升探索留存
- 成本：M——排序 M（拖拽 UI + 全量序列提交，幂等需防重）；相似 S
- 依赖接口实测状态：**需先实测** 三端点原生形态（playlist 写端点族已有实测经验：v4/delete_songs、v6/add_song 通，同族风险低）
- 优先级：P2（排序）/ P2（相似）
- 备注：写操作必须走 `_write` 出口（write:true 禁回退，PLY-08 契约）

### P2-2 播放/听歌行为上报
- Node 模块：`playhistory_upload.js` / `user_listen_report.js`（POST，hash+userid+endtime）
- 用户价值：不UP报则「最近在听」「每日推荐」退化为热门兜底；recent_play_store 只有本地
- 成本：S——audio_handler 播放成功回调处一行上报 + repository 方法
- 依赖接口实测状态：**需先实测**（写端点、涉及风控，必须三态实测；不可匿名代发）
- 优先级：P2——是 P1-3 FM 推荐质量的前置，但不阻塞 FM 基础版
- 备注：注意第 21 条幂等：重试/回放不得重复上报，需去重键

### P2-3 歌手视频 / 荣誉 / 关注
- Node 模块：`artist_videos.js` / `artist_honour.js` / `artist_follow.js` + `artist_unfollow.js`
- 用户价值：歌手页内容丰富度；关注歌手后新歌触达
- 成本：M（视频页复用 mv_repository 解析链）
- 依赖接口实测状态：**需先实测**（artist detail/audios/albums 已实测 ✅ 同域直连经验充足，期望风险低）
- 优先级：P2

### P2-4 歌单广场扩展（分类标签歌单）
- Node 模块：`playlist_track_all_new.js` / `top_playlist.js`(分类) / `sheet_tags.js` / `scene_lists_v2.js`
- 用户价值：目前广场只有 special_recommend 一路且直连 200101 不可用（保留 kapi 回退，第 27 条债务）；标签分类歌单是替代主路径
- 成本：M
- 依赖接口实测状态：**需先实测** `top_playlist` 分类参数（已实测版恒 200101，需探明是 category_id 缺失还是签名问题；scene 系是新域全未测）
- 优先级：P2——同时是消除 kapi 回退债务的机会

### P3-1 歌词搜索独立入口 / 歌词墙
- Node 模块：`search_lyric.js`（已实测 ✅ lyric/search）
- 用户价值：低频；成本 S；接口已验证
- 优先级：P3

### P3-2 歌曲高潮试听（song_climax）/ 歌曲弹幕
- 依赖接口需先实测；价值有限（弹幕社交属性强，单机 App 弱）。P3。

### P3-3 数字专辑商店 / 已购（album_shop / user_purchased_*）
- 付费域；需先实测；v3.8 评估。P3。

### 明确不做（本迭代）
- **一起听 listen_together / team_***：社交实时功能，需长连接与房间协议，架构改动 L，单人使用价值≈0
- **云盘 user_cloud_upload/match**：上传涉及风控+分片协议，需先实测且风险高，价值被「下载」部分替代
- **youth_*（会员营销 22 个）/ effects_*(车载品牌) / ip_(IP 专区)**：运营营销域，无用户价值
- **ai_recommend / brush / black_list**：灰色或低价值

---

## 四、推荐实施顺序（路线图）

**v3.7 剩余批次（按依赖序）：**
1. **P1-4 20028 收敛**（架构地基，M）——先行，S-3 slider_solver 同批决策
2. **P1-1 断点续传**（S）——可并行，无依赖
3. **P1-2 每日推荐日历**（S）——先 native_probe 实测 everyday_history
4. **P1-3 FM 基础版**（M）——先实测 fm_songs/fm_recommend；实测不过则砍，不立空中楼阁

**v3.8 路线图：**
1. P2-4 歌单广场扩展（顺带清 special_recommend 的 kapi 回退债务）
2. P2-1 歌单排序 + 相似歌单
3. P2-2 听歌上报（FM 推荐质量前置）
4. P2-3 歌手视频/关注
5. longaudio 听书专项评估（9 端点先实测再立项）

**纪律提醒**：以上所有「需先实测」项，立项前必须 native_probe 三态留样（第 28/29 条）；kapi 对照结果只能标记候选，不得作为实现依据（第 33 条）。

