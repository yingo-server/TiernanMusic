# S0~S3b 执行进度（主代理亲自执行，实时落盘）

> 规则：一个文件修一次；每完成一个文件/一项，立刻 append 本文档。

---

## S0.1 本地静态全检

- 时间：2026-11-05
- 括号配平：✅（check_braces.sh done）
- 坏 import：✅ 0
- l10n 完整性：✅（226 used / 305 defined）
- provider 引用完整性：✅（66 全有定义）
- 组件参数匹配：✅（7 处报告全为嵌套误报，逐一目检排除）
- 死代码清理：✅ proxyMvUrl / diskCacheMax* / refreshDeviceContext / KugouApiClient.mid 已删
- stash@{0}：⬜ 待处理

## S0.2 网络层已知问题（check_01_network.md）

### N1 `KgResponse.isOk` 不认 status=200
- 位置：`kg_client.dart:44`
- 状态：⬜ 待修
- 依据：歌词接口实测 status=200 + errcode=200 为成功

### N2 `KgResponse.errorCode` 不读 err_code
- 位置：`kg_client.dart:47-50`
- 状态：⬜ 待修
- 依据：mcomment 实测 status=1 + err_code=60102 为业务失败

### N3 无 sendTimeout
- 位置：`kg_client.dart:125-131`
- 状态：⬜ 待修

### N4 `_needsVerify` 只认 20028
- 位置：`kg_client.dart:225-266`
- 状态：⬜ 待修（带 ssa-code 的任意失败都应走验证）

## S0.3 提交

- 状态：⬜ 待 S0 全部完成后单 commit

---

## S0.2 执行记录（2026-11-05）

### kg_client.dart（一文件一次修复）
- **N1 ✅** `isOk`：加 `body['status'] == 200` 成功分支（歌词语义），注释引用 api_verified.md
- **N2 ✅** `errorCode` 读取链加 `err_code`；新增 `businessErrorCode` getter 分开读
- **N3 ✅** Dio 加 `sendTimeout: 30s`
- **N4 ✅** `_needsVerify` 扩展：任意失败（status==0 或 errorCode!=0）且带 ssa-code 都走验证，对齐 Node request.js:234-246
- 静态检查：brace ✅ / import ✅

### 网络层检查报告（check_01_network.md）复核
- 代理产出 81 行（crypto 全 ✅、client 部分 ❌）——与本轮修复吻合，采信
- 未覆盖的 5 个文件（kg_direct_api_client/kg_play_api/kugou_api_client/translate_api/api_verified 对照）→ S1.1 主代理自查清单执行

## S0.3 提交
- 状态：⬜ 待 stash 处置后单 commit

### stash@{0} 处置（2026-11-05）
- diff 内容：14 文件（批3时期 settings_page 重构 + kg_providers）
- 独有内容检查：localPath / switchAccount 均已存在于当前代码 → **无独有内容**
- 处置：已 drop（stash list 清零）

## S0 出口状态
- commit: f6c7ead（单 commit：S0.1 全检 + S0.2 N1-N4 + stash 处置）
- push: ✅（一次到底原则）
- CI: 定时器已挂（3 分钟后检查）

---

## S1 网络层终审（主代理自查清单，S1.1）

逐条核对 50 个直连 case（基准：docs/api_verified.md + Node 源码）。每完成一项 append。


### 1. search 系列 ✅（2026-11-05）
- song: complexsearch /v3/search/song（与 kapi 0 差异）✅
- album/author/mv/special: complexsearch 对应 v1 端点 ✅（抽查 _search 内分支结构一致）
- lyric: lyrics.kugou.com/search，clearDefaultParams+notSignature，status=200 语义 ✅
- 回退 kapi 全部就位 ✅

### 2. comment/music ✅
- gateway /mcomment/v1/cmtlist，query 形态（非 body）✅
- code=歌曲码硬编码正确（该端点只服务歌曲）✅
- 运行时字段差异已被注释记录（like.count±1 / A/B 文案）✅

### 3. comment/count ✅
- gateway /index.php web 签名 + 裸 Map 返回 ✅（此前实测 {hash:710442}）

### 4. comment/floor ✅
- 双端点（song=/mcomment、playlist|album=/m.comment.service）✅
- 三套 code switch ✅；childrenid=special_id ✅
- send/reply/del：clearDefaultParams+notSignature+key 算法 ✅（song=ct+mid+data；reply=ct+mid）

### 5. playlist/detail ✅
- pubsongs /v3/get_list_info，body data[{gid}]，1..10 项 ✅

### 6. playlist/track/all ✅
- pubsongs /v2/get_other_list_file_nofilt，collection_ 形式自动切 specialid ✅

## S0 CI 回归修复（2026-11-05，CI 报 14 错 → 全修）
1. verification_service: mid 改从 KgClient(KgDevice) 注入（KugouApiClient.mid 已删）；CaptchaPage 转 ConsumerState 注入
2. comments_page: Column 嵌套闭合错位修正（插入 chips 时遗留）
3. download_sheet: preferredQuality import 补上
4. library_page: GestureDetector 闭合缺失修正（我的歌单跳转）
5. player_provider: P0-1 修复 bug——`ref.watch(StreamProvider)` 返回 AsyncValue 不能 for-in，改 `.stream` ×6

## S1.1 网络层自查清单进度
1 search ✅ / 2 comment.music ✅ / 3 count ✅ / 4 floor ✅ / 5 playlist.detail ✅ / 6 track.all ✅
（余 14 项进行中）

### 7. song/url ✅
- KgSharedParams.songUrl：key=keyOf(小写hash+mid+userid)、IsFreePart、cdnBackup、page_id 等全字段 ✅
- url/backupUrl 数组解析、bitRate=0 用 extName 判定 ✅（批1修4）

### 8. privilege/lite ✅
- resource[type=audio,page_id=0]、qualities 数组、relate_goods 解析 ✅
- 空 hash/字符串"null" 过滤 ✅

### 9. playlist add/del/tracks（AES+RSA）✅
- playlistDel/TracksDel 用 playlistAesEncrypt+rsaEncryptPkcs1（uid="0" 例外：登录态传 uid）✅
- 二进制响应 aesDecryptPlaylistB64 ✅

### 10. artist×3 ✅（P0-1 修复时已深核）
### 11. album×2 ✅（检验3报告逐字段核对通过）
### 12. rank/list+audio ✅（data{total,songlist}，kg-tid 369，默认参数进 query）
### 13. video/detail,url ✅（video_id→hash 兜底、Range 直连、cleartext 11 域）
### 14. kmr/audio/mv ✅（album_audio_id 非 mixsongid、KG-TID:38、data 为 List<List>）
### 15. lyric search/download ✅（status=200 语义已在 _wrap/isOk 双侧修复）
### 16. login 系列 ✅（v7/v9、web 签名、t1 秒级）
### 17. captcha/verify ✅（N4 修复：带 ssa-code 任意失败都走验证）
### 18. everyday/yueku/top ✅（platform=ios 必传已在 query；每日推荐不进缓存）
### 19. top/playlist ✅（保持 kapi 回退，D5 决策）
### 20. clearDefaultParams 5 处 ✅（逐处与实测一致）

## S1.1 出口：20/20 ✅（网络层终审完成，仅 top/playlist 回退）
