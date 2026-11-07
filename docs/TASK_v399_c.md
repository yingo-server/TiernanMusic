# v3.9.9 任务书 C：歌单顺序异常排查（只读诊断 + 修复）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）与 `docs/PROGRESS.md` 末段。

## ⚠️ 硬性规则
- **绝对禁止**：装 Flutter SDK / flutter 命令 / dart pub get / 下载任何 SDK / 改 pubspec.yaml（ARM64 无 Flutter）
- 只允许 `dart analyze`；Flutter/三方符号报错是预期噪音，**项目自有类报错即真错误**
- **触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**
- 跨文件改动双向核对；禁 git commit/push；只用 file_edit；改动标 `V399-xx`
- 业务相关文件完整 file_read 从头到尾，禁止 grep/正则筛源码
- 只使用项目内已存在且已读定义确认签名的类/方法
- 报告 `docs/v399_fix_c.md` **实时落盘**

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `755dcea`

## 用户反馈（附截图证据）
歌单内歌曲顺序异常：用户截屏显示同一歌单刷新后顺序变化（「In The End」「月宫试云衣」「Cornfield Chase」等在多次截屏中位置漂移）。用户要求：「按截屏顺序，截屏文件修改时间早的在前」——即歌单应保持**服务端给定的稳定顺序**，不随刷新漂移。

## 任务：定位顺序漂移根因并修复（V399-C1，P1）
1. **完整 file_read**：`playlist_repository.dart`（fetchUserTracks/fetchDetail/分页）、`kg_endpoints_playlist.dart`（playlistDetail/playlistTracks 请求参数）、`playlist_detail_page.dart`（列表渲染与排序）、`kg_direct_api_client.dart`（分派表对应 case）、`models.dart`（Song 字段）
2. **对照 Node 源码**（`/var/minis/workspace/KuGouMusicApi/module/playlist_track_all_new.js`、`playlist_detail.js`）：请求参数里是否有 `sort`/`order` 类字段被我们写错或漏传；分页参数 page/pagesize 是否与 Node 一致
3. **假设排查**（逐个验证并在报告记录证据）：
   a) 服务端返回顺序本身稳定，但我们分页合并时乱序（如并发请求 page 2 先回、插入顺序错）
   b) 我们漏传/错传了排序参数，服务端默认排序不稳定
   c) 渲染层用了无序集合（Map/Set）或 keys 不稳定导致 ListView 乱序
   d) 缓存层（MemoryCache）把不同次请求的分页数据混装
4. **修复**：按实证根因处理——保证「同一歌单多次刷新顺序一致且与上游给定顺序一致」；分页合并必须按 page 序拼接
5. **验证**：修复后代码路径上写明「顺序保证」的实现依据（哪个字段/哪段合并逻辑）

## 完成后
报告末尾 8 行内汇报：根因判定（a~d 哪个/其他）、修复内容、analyze 逐文件结果、未做项原因。
