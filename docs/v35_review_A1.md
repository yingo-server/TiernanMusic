---

## 重点复核四：_wrap 各端点误判复核（V34-02 修复后回归）

**范围**：kg_direct_api_client.dart `_wrap`/`_hasData`（已完整读）× 各端点成功语义注释 × kapi 参数对照

### 判定：V34-02 修复形态保持正确，未发现新的误判 ✅（附两条 P3）

逐分支核对 `_wrap`：
1. **`err_code`（mcomment 业务码）前置**：在 status 判定之前统一校验，兼容字符串 "60102"（PLY-10）——评论列表/楼中楼 status=1+err_code≠0 不再误判成功 ✅
2. **status==1 + 警告码 151/152**：`_hasData`（data 非空 List/Map）放行，无数据则抛——「errcode!=0 即失败」误杀已消除 ✅
3. **status==200 歌词族**：直接放行不做 error_code 判定（errcode=200 是正常码）；err_code 已前置校验 ✅（kapi search_lyric.js 对照：其 `/v1/search` 路径与 Dart 的实测结论不同——Dart 注释记录了 10 组合实测恒空体 + x-kg-errcode 20010，改打 `/search`。属**有实测依据的与 kapi 偏离**，符合第 28 条「实测优先于源码照搬」✅）
4. **status 0/2 或 errorCode!=0**：抛 ApiException，msg 取 error/error_msg/errmsg/info 兜底链 ✅
5. **无 status 且空 body**：抛 -1 风控空包（PLY-11）——不回退（kapi 已停用）、页面有错误可显 ✅
6. **与 KgResponse.isOk 的口径差**（见 kg_client 节 P2）：`isOk` 不接受「无 status 非空 body」形态；rg 全库确认 `isOk` **无任何调用点**（仅定义）——实为死代码 + 口径漂移隐患，合并计入下条。

### 发现
- **P3 kg_client.dart:43 `KgResponse.isOk` 无调用点的死代码 + 与 _wrap 口径不一致**
  - 事实：rg 全库 `isOk` 仅此一处定义，零调用；且其判定（status==1||200）比 `_wrap` 窄（缺「无 status 非空 body」分支）。
  - 违反：第 32 条；若未来被启用会引入口径漂移（第 8 条）。
  - 后果：暂无用户可见后果（未使用），P3；删除或对齐二选一。
- **P3 kg_direct_api_client.dart:~230/:342（承前）`'/comment/${n}/send'` label 拼接重复前缀**（已在 kg_direct 节记录，此处归档为 _wrap/分派复核关联项）

---

## 重点复核五：kapi 参数对照汇总（第 33 条口径）

本轮对照的 kapi module（仅参数口径，未采信其返回）：
`_comment.js`、`comment_music/playlist/album/floor/floor_send/count.js`、`playlist_del/add/tracks_add/tracks_del/track_all/track_all_new.js`、`user_playlist.js`、`playlist_detail.js`、`artist_detail/artist_audios/artist_albums.js`、`album_detail/album_songs.js`、`rank_audio.js`、`top_song/top_playlist/search_hot/yueku_banner.js`、`search_lyric.js`。

结论：**30 个端点参数集合全部对齐**；3 处有意偏离均有实测注释支撑（commentMusic 走 B 形态、searchLyric 改 `/search`、playlistTrackAll specialid 分派），符合第 28 条「实测优先」。2 处与 kapi 的功能性差异（楼中楼 name 补查缺失、is_pri 写死）已记 P3。

---

## 问题清单（按级别）

| # | 级别 | 位置 | 标题 |
|---|---|---|---|
| 1 | P2 | kugou_api_client.dart:~75 | status 非法形态时 `?? 1` 默认成功（kapi 父类路径，暴露面小） |
| 2 | P2 | kg_client.dart:43 | `isOk` 死代码 + 与 `_wrap` 成功口径不一致（合并 #6 视角） |
| 3 | P3 | kg_direct_api_client.dart:230/342 | `/comment/${n}/send` label 重复前缀（诊断页路径失真） |
| 4 | P3 | kg_direct_api_client.dart 末尾 | `_afterLogin/_qrPngBase64/_maskMobile/_commentCodeOf/_qrSrcappid` 拆分残留死代码 |
| 5 | P3 | kg_client.dart:60 + kg_direct_api_client.dart:48 | `KgClient.dfid` 镜像字段无读点 |
| 6 | P3 | kg_endpoints_playlist.dart:playlistAdd | is_pri 写死 0，无法新建私密歌单 |
| 7 | P3 | kg_endpoints_comment.dart:commentFloorSend | 楼中楼缺 childrenname 补查（kapi comment_floor_send.js 有） |
| 8 | P3 | kg_endpoints_search.dart:88-90 | duration 秒/毫秒双入口（duration_ms 命名已显式，低风险） |

**P0/P1：0 条**。全部 P2 为低暴露面/死代码性质，无用户可见故障路径。

## 四项重点结论
1. **write:true / kapi const false**：自洽 ✅；write 标记是面向「回退开关重开」的正确防御，超链接注释齐备。
2. **_wrap 误判**：V34-02 修复保持，err_code 前置 + 151/152 有数据放行 + status==200 歌词族 + 空 body 风控，五分支全部回归通过 ✅。
3. **ensureDfid Completer 收敛**：闸门成对、等待者一次性唤醒、重试有界（3 次）、异常契约稳定、device.dfid 回写链完整——复核①-15 修复回归通过 ✅。
4. **未移植 -404 × Repository**：评论写三件套 post 分派补齐生效，无静默吞 -404 的调用面 ✅。

## 审查覆盖声明
11 个范围内文件全部逐行完整读毕（kg_direct_api_client 695 / kg_client 547 / endpoints×7 共 1963 / kg_play_api 460 / kg_providers 109 / kugou_api_client 238 = 4012 行）；交叉核对 player_repository ensureDfid/播放降级段与 comment_repository 写路径段；kapi 对照 20+ module。禁编译遵守（未运行 dart analyze/build）；噪音过滤规则：本项目有类报错一律按真错误处理（本轮未触发该规则——未做静态分析，全部结论来自阅读）。

