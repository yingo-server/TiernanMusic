# 批1检3 · 直连 API 与数据模型审查报告（续/补完）

范围：`lib/core/direct/*`（6 文件）、5 个 Repository + `home/data/models.dart`。
对照：`KuGouMusicApi/util/helper.js`、`util/crypto.js`、`util/util.js`、`module/register_dev.js` 及 docs 下 6 份实测报告。
HEAD：`ace9575`。只读审查，未改代码、未跑测试。

严重度排序：**编译阻塞 > 功能失效 > 数据错误 > 代码质量**。

---

## 一、编译阻塞

无。全部文件语法完整，无 `as Map` 未判空崩溃路径、无未定义引用。

---

## 二、功能失效

### F1. `KgClient` 默认参数 `uuid` 传 `'-'` 而非 guid —— kg_client.dart:141
- 问题：Node 版 server.js 对每个请求注入 cookie `uuid = guid`（getGuid 结果），设备注册 module/register_dev.js 里 uuid 也用 guid（Dart `_registerPayload` 的 `uuid: device.guid` 是对的）。但网关请求的默认参数 `'uuid': '-'` 与 kapi 行为不一致。签名自洽所以不会报错，但部分依赖 uuid 的风控/个性化接口可能行为劣化（与 20028 触发率相关）。
- 修法：`'uuid': device.guid`（若实测 kapi 侧上游确实收到 guid）。**若此前匿名态 A/B 是按 `'-'` 实测通过的，保留并加注释说明**——优先维持实测结论，勿盲改。

### F2. `KgSignature.web` 参数拼接方式与 Node 不完全等价 —— kg_crypto.dart:62-73
- Node `signatureWebParams`（helper.js:40-46）是先把每个参数格式化成 `"k=v"` **字符串后整体 sort()**；Dart 是先 sort key 再拼接。仅当某 key 是另一 key 的前缀且下个字符 ASCII < `=`（61），如 `a` 与 `a-b` 时两者顺序不同。当前调用方（`/comment/count`、二维码接口）的参数无此形态，**现网无影响**，属潜在地雷。
- 修法：对齐 Node：`params.keys.map((k) => '$k=${params[k]}').toList()..sort()..join()`。（android 版不受影响：Node 也是先 sort key，helper.js:63-67。）

### F3. 注册签名 `register()` 与 Node 的排序差异 —— kg_crypto.dart:76-81
- Node helper.js:93-98 取值后按 **JS 默认字符串排序**；Dart `values.map((v)=>'$v').toList()..sort()` 同为字符串排序，且 Dart `register()` 当前**无调用方**（注册实际走 `KgSignature.android` 含 body，符合 register_dev.js 实测结论）。通过项，但建议在 `register()` 上加 `// currently unused` 注释防误用。

---

## 三、数据错误

### D1. `home_repository.dart` 多处 `e as Map` 强转残留 —— :69, :83, :93, :104, :118, :137
- `fetchYuekuSongs / fetchYuekuPlaylists / fetchTopPlaylists / fetchRankList / fetchBanners / fetchDailyRecommend` 均为 `.map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e as Map)))`。上游列表混入字符串/数字项（yueku recommend 已实测出现非歌单项）会直接抛异常，尽管外层有 try/catch，但会导致**整个区块清空**而非跳过坏项。
- 修法：统一改 `whereType<Map>()`（search_repository 的 `_maps()` 已是正确范式，抄过来）：
  ```dart
  _asList(info['song']).whereType<Map>().map((e) => HomeSong.fromJson(Map<String, dynamic>.from(e))).toList()
  ```

### D2. `MvInfo.fromJson` 的毫秒判定阈值有边界误伤 —— mv_repository.dart:186-190
- `durationMs > 10000 ? ms ~/ 1000 : ms`：时长 <10 秒的 MV（用户短视频实测存在 8~9 秒项）会被当成"毫秒"原样保留，显示成 `0:08` 变 `2小时+`。`MvDetail.fromJson` 同样写法（:268-272）。
- 修法：kmr/audio/mv 与 video/detail 的 duration **实测恒为毫秒**（docs/api_report_comment_mv_lyric.md），直接 `ms ~/ 1000`，去掉启发式阈值；另 `MvDetail` 备用字段 `duration` 若启用需单独处理。

### D3. `HomeSong.fromJson` 的 `singerinfo` 兜底分支类型混乱 —— models.dart:81-83
- `else if (singerInfo != null && singerInfo is! Map)` 会把 List 之外的一切（含 Map？不会，Map 已被上面处理——不对，上面只判 `is List`，Map 落到这里）`_toStr` 成 `'{name: xxx}'`。
- 修法：`else if (singerInfo is Map)` 时取 `singerInfo['name']`，其余置空。

---

## 四、代码质量 / 健壮性

### Q1. 直连路由表缺口清单（静默回退 kapi 但 Repository 有调用）
逐条核对 Repository 全部调用点与 `kg_direct_api_client.dart` 的 get/post switch 后，以下路径**不在 case 里**，每次都走 kapi 中转（直连失败时同样先试直连→不存在 case→直接 kapi，不算 bug，但失去免服务器能力）：

| 路径 | 调用方 | 影响 |
|---|---|---|
| `/search/hot` | search_repository.fetchHotSearch | 热搜走中转 |
| `/search/suggest` | search_repository.fetchSuggest | 搜索建议走中转 |
| `/yueku/banner` | home_repository.fetchBanners | 首页 banner 走中转 |
| `/video/detail` | mv_repository.fetchDetail | MV 详情走中转（`/video/url` 已直连 ✓） |
| `/user/playlist` | playlist_repository.fetchUserPlaylists | 我的歌单走中转 |
| `/playlist/track/all/new` | playlist_repository.fetchUserTracks | 用户歌单歌曲走中转 |
| `/playlist/add` `/playlist/del` `/playlist/tracks/add` `/playlist/tracks/del` | playlist_repository 收藏/增删 | 全走中转 |
| `/comment/playlist` `/comment/album` | comment_repository.fetchComments | 歌单/专辑评论走中转 |
| `/comment/music/send` `/comment/playlist/send` `/comment/album/send` `/comment/floor/send` `/comment/music/del` | comment_repository 发/删评论 | 全走中转 |

建议：按依赖度优先补 `/video/detail`、`/search/hot`、`/yueku/banner`（读接口、匿名可用）；写接口依赖登录态，可后补。

### Q2. `_directOrFallback` 回退拼接 —— 正确 ✅
- kapi 闭包 `super.get(path, query: query)` 原样透传 path+query，`_norm` 只剥前导 `/` 用于 case 匹配，不影响回退 URL。失败日志进 `lastErrors`（容量 20）✅。唯一注意点：`fallbackToKapi` 是静态开关，默认 true——匿名态修复后如需强制验证直连，记得临时关掉。

### Q3. 设备身份 —— 通过 ✅
- `calculateMid`：Dart BigInt 逐位 `charValue * 16^(len-1-i)` 与 Node util.js:175 `calculateMid` 逐位一致（含 hex 解析失败行为：Dart `int.parse(…,radix:16)` 对合法 md5 hex 恒成功）✅。
- guid 生成 uuidV4（版本位/变体位已置）✅，`toJson/fromJson` 含 guid ✅，`KgDeviceStore.loadSync` 首启生成并落盘 ✅。
- dfid 持久化：注册成功 → `onDfidRegistered` → `KgDeviceStore.saveDfidSync`（合并式写入不覆盖其它字段）✅；box 未打开时 `openBox()` 返回 null、`saveDfidSync` 静默 false，下次启动会重新注册——**降级可接受**，但建议在 `_persistDfid` 的 catch 里至少 debugPrint 一次。
- `dfid.isEmpty` 降级 `'-'`：默认参数、header、注册、登录多处一致处理 ✅。

### Q4. 默认参数注入逐接口核对 —— 通过 ✅
- `_searchLyric`：clearDefaultParams + notSignature，自带 appid/clientver，与实测「不校验签名」一致 ✅。
- `_kmrAudioMv`、`_songUrl`、`_privilege`、`_playlistTrackAll`、`_rankList`、`_topSong`：默认参数正常注入（Node 同名 module 同样依赖 cookie 默认注入）✅，无多传。
- `KgMediaDirect.images`：clearDefaultParams + notSignature + 自算签名（含 jsonEncode(data)）✅，`Uri(queryParameters:).query` 无前导 `?`，path 拼接正确 ✅。

### Q5. `whereType<Map>()` 使用情况
- 用全了：search_repository（`_maps`）、playlist_repository（fetchUserPlaylists / PlaylistTracks / PlaylistSong 外层）、comment_repository（list/classify）、mv_repository（嵌套 groups）、models.dart（singerinfo/authors）。
- 唯一漏网：home_repository（见 D1）。

---

## 五、重点核对项（C 组，全部通过 ✅）

| # | 项 | 结论 |
|---|---|---|
| 10 | `_everydayRecommend` platform 在 query | ✅ kg_direct_api_client.dart:462-467，`params:`（即 query），默认 'ios' |
| 11 | `_privilege` resource 空数组/qualities 字符串 → 20010 | ✅ 经 `KgSharedParams.privilege`（kg_play_api.dart:118-160）：过滤空/"null" hash、page_id=0、`parseQualities` 拆逗号串；两处调用共用同一份参数构造，无拷贝分叉 |
| 12 | `_playlistTrackAll` gid 必须 collection_ 形式 | ✅ :540-560，`startsWith('collection_')` 分流 `global_collection_id` / `specialid` |
| 13 | `_kmrAudioMv` body 用 album_audio_id | ✅ :569-590，`{'data':[{'album_audio_id':s}],'fields':…}`，打 openapi.kugou.com + KG-TID:38 |
| 14 | `_songUrl` key 小写 hash + 字符串 userid | ✅ `KgSharedParams.songUrl`：`hash.toLowerCase()` + `keyOf(userid: client.userid.isEmpty ? '0' : client.userid)`（字符串）；直连与 KgPlayApi 共用 |
| 15 | `_wrap` status==1 判定 + 警告码放行 | ✅ :38-62：status==1 且（errorCode==0 或 `_hasData`）放行；151/152 带数据不误杀；无 status 的裸 Map（如 /comment/count 返回 `{hash:…}`）落到末尾 `return body` 不误抛 |

## 六、4 种签名 vs Node 逐字节比对结论

| 签名 | Node | Dart | 结论 |
|---|---|---|---|
| android | salt + sort("k=v")(对象值 JSON.stringify) + data + salt | 相同（`v is Map\|\|v is List` 才 stringify，数字/布尔 toString 与 JS 一致） | ✅ 一致（lite 盐分支 ✅） |
| web | "k=v" 字符串整体 sort | key sort 后拼接 | ⚠️ 前缀 key 极端情形不等价（F2，现网无影响） |
| register | 值串 sort + "1014" | 相同 | ✅（当前无调用方，注册走 android+body，符合 register_dev.js） |
| signKey | md5(hash+盐+appid+mid+userid\|\|0) | 相同（userid 字符串 '0' 传入，与 JS `userid\|\|0` 对 '0'/'0' 等价——'0' 为 truthy，Node 保留 '0'，Dart 同样保留） | ✅ |

**总结**：核心直连链路（签名/设备/播放/权益/歌单/MV）与实测结论全部对齐，无编译阻塞；需修的是 home_repository 的强转（D1）、MV 毫秒阈值（D2）、web 签名理论差异（F2），以及 15 条未直连路由的补全计划（Q1）。
