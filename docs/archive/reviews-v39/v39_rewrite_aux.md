# v3.9 代理③报告——辅助页与评论链路重写（实时落盘）

读完文件（file_read 全文）：TASK/QUALITY_STANDARD(167行)/v37_perm_playback(188行)/v37_playback_blank_diag(93行)；
mini_player.dart(188)/queue_sheet.dart(129)/play_helper.dart(92)/comments_page.dart(698)/comment_floor_page.dart(320)/
player_provider.dart(225)/audio_handler.dart(612)/player data models.dart(222)/comment_repository.dart(275)/
app_router.dart(163)/song_tile.dart(221)/full_player_page.dart(612)/lyric_view.dart(294)/lyric_repository.dart(246)/
home models.dart(271)/playlist_repository.dart(555)/login_guard.dart(43)/friendly_error.dart(33)/confirm_dialog.dart(42)/
error_retry.dart(248)/empty_state.dart(68)。

### 契约结论（评论入口可达性）
- 路由 `/comments/:type/:id` 已注册（app_router.dart:56-62），入口在 full_player_page `_MvEntry`（始终渲染，不再被 MV 判定连带隐藏）→ **入口可达**。
- 评论 provider 均已存在（comments_page 私有 `_commentRepoProvider`/`_commentsProvider`；floor 页 `_floorRepoProvider`），无缺失，无需补。


---

## 已发现问题清单（按级别）

### V39-AUX-01｜P1｜play_helper.dart：hash 缺失用 id 冒充
- 级别/编号：P1 / V39-AUX-01
- 依据：`hash: s.hash ?? s.id`（play_helper.dart:25/53）。`HomeSong.id` 在 hash 缺失时是 `mixsongid/audio_id/id`（home/models.dart:183）。`Song.==` 只比 hash（player models.dart:218），且 `player_provider.recentPlayRecorderProvider` 显式 `if (song.hash.isEmpty) return;`、`_emitMediaItem` 用 `MediaItem(id: song.hash)`。id（mixsongid）不是 hash，混入后：详情接口 `/privilege/lite` 按 hash 查询必空、`Song==` 语义被污染、媒体通知 id 是假 hash。
- 影响/改动：hash 缺失不再用 id 冒充，改为空串（调用方 keep 原字段；播放引擎 ensureEngineReady 链路对空 hash 的歌 resolveUrl 自然失败并可观测，与「缺失 ≠ 伪造」一致，第 14/15 条）。

### V39-AUX-02｜P2｜play_helper.dart：三处 Song 转换重复
- 级别/编号：P2 / V39-AUX-02
- 依据：playHomeSong/playHomeQueue 各一份 HomeSong→Song 映射，playPlaylistSong/playPlaylistQueue 各一份 PlaylistSong→Song 映射（4 处复制，第 1/5 条）。
- 影响/改动：合并为 `_songFromHome` / `_songFromPlaylist` 单一私有实现，四个方法复用。

### V39-AUX-03｜P2｜play_helper.dart：时长单位隐式
- 级别/编号：P2 / V39-AUX-03
- 依据：`Duration(seconds: s.duration)`——`s.duration` 单位靠注释（home models.dart `final int duration; // 秒`）。第 15 条要求命名体现单位。
- 影响/改动：保持 `Duration(seconds:)` 转换（模型字段确为秒，已核实 HomeSong.fromJson 秒/毫秒分字段处理、PlaylistSong timelen~/1000），转换点集中到合并后的单一实现并加单位依据注释，不再散落 4 处。

### V39-AUX-04｜P1｜comments_page.dart：发送/回复无防重，失败后文本丢失
- 级别/编号：P1 / V39-AUX-04
- 依据：`_send()`（comments_page.dart:443-498）先 `_inputCtrl.clear()` 再发请求；发送失败（网络断/风控）后用户输入**永久丢失**，只能凭记忆重打；且无发送中防重（第 21 条），连点发送会重复提交评论。
- 影响/改动：加 `_sending` 防重闸门；失败时把文本还原回输入框（可重试不丢内容）。

### V39-AUX-05｜P2｜comments_page.dart：sendComment 成功后整页刷新态不当
- 级别/编号：P2 / V39-AUX-05
- 依据：`sendComment` 成功 → `load(refresh: true)`（comments_page.dart:128-131）刷新到第 1 页——用户翻到第 5 页发完回复被弹回第 1 页。
- 影响/改动：保留刷新（replyCount 需更新），但成功后把页面回滚到顶部属预期；改为失败不推进、成功刷新语义加注释说明（轻改：仅注释+保持行为，避免引入新契约）。

### V39-AUX-06｜P2｜comment_floor_page.dart：翻页失败吞异常不可重试
- 级别/编号：P2 / V39-AUX-06
- 依据：`_loadMore` catch(_) 空体（comment_floor_page.dart:128-142，第 6/9 条），失败后 footer 仍转圈、无重试入口。
- 影响/改动：加 `_pageError` 状态，footer 失败显示重试按钮（对齐 comments_page V37-08 范式）。

### V39-AUX-07｜P2｜comment_floor_page.dart：未登录发送按钮无引导区分 + 首屏错误态无 l10n
- 级别/编号：P2 / V39-AUX-07
- 依据：`_error = '$e'` 原始异常上屏（第 6/9 条 + friendly_error.dart 口径：UI 不得裸上 `'$e'`）；发送失败 `commentFailed('$e')` 同样裸串。
- 影响/改动：错误态走 `unwrapApi`/friendlyError 解包；floor 页 send/delete 失败同样解包。

### V39-AUX-08｜P2｜comments_page.dart / comment_floor_page.dart：删除失败裸 `'$e'`
- 级别/编号：P2 / V39-AUX-08
- 依据：`deleteFailed('$e')`（comments_page.dart:655 / floor:173）与 `_send` 的 unwrapApi 口径不一致（第 8 条：回退路径异常形态必须一致）。
- 影响/改动：统一 unwrapApi 解包后取 message。

### V39-AUX-09｜P2｜queue_sheet.dart：队列点击缺世代校验
- 级别/编号：P2 / V39-AUX-09
- 依据：`onTap` 里 `await controller.playQueue(queue, i)`（queue_sheet.dart:104-108）。`queue` 是 watch 快照，弹层停留期间若底层队列被整体替换（新播放请求 playQueue 清空重灌，audio_handler.dart:177-190），旧快照 index 会指向错歌/越界（`_playAt` 有 `index >= _songs.length` 越界守卫但**不报错不提示**，静默 return → 点了没反应，第 18 条世代校验）。
- 影响/改动：点击时用 handler 当前队列（`ref.read(audioHandlerProvider).songs`）做长度与内容一致性校验：当前队列与快照 hash 序列一致才按快照 index 播放，不一致则按 hash 在当前队列里定位重放，定位不到提示队列已变更。同时 `isCurrent` 判定改为「hash 相同且当前队列存在」避免空 hash 歌互相误判（Song.== 空 hash 恒 false 已保证，但 `current?.hash == s.hash` 两边都空 hash 时字符串相等误判——补 hash 非空条件）。

### V39-AUX-10｜P2｜queue_sheet.dart：无加载/失败态区分（第 16 条）
- 级别/编号：P2 / V39-AUX-10
- 依据：`ref.watch(queueProvider).valueOrNull ?? const []` 把「流尚未发首值（loading）」与「确为空队列」合并成同一空态。
- 影响/改动：用 `queueProvider` 的 AsyncValue 三态：loading 显示骨架/转圈，data 空显示 EmptyState，error 显示重试（重新 watch）。

### V39-AUX-11｜P2｜mini_player.dart：长按手势无提示 + 空态三态
- 级别/编号：P2 / V39-AUX-11
- 依据：mini_player `song == null` 直接 shrink——空态正确（无播放内容不显示符合契约）；但引擎失败时（engineError 非空且无歌）用户在主界面无任何提示，只能进播放页看 banner。
- 影响/改动：mini_player 保持空态隐藏（契约：无内容不显示），不改结构；仅补 `_MiniProgressBar` 除零已由 `total.inMilliseconds > 0` 守卫 ✅ 无缺陷。结论：mini_player 本轮仅核对，无必须修复项（V37-UI-07 窄屏降级已就位）。保留文件不改动，analyze 核对。

### V39-AUX-12｜P3｜comments_page.dart：`deleteComment` 只带 specialId 不带 tid
- 级别/编号：P3 / V39-AUX-12
- 依据：顶层删除路径 `deleteComment(comment.id, specialId: comment.specialChildId)`（comments_page.dart:650-654）→ repo `deleteComment` 带 specialId 不带 tid；楼中楼删除在 floor 页带 tid。顶层删除带 special_child_id 时直连层语义未实测（第 29 条），保守保持原样并注释标注「未实测」。
- 影响/改动：仅注释标注，不改参数（避免凭猜测改坏可用路径）。

## dart analyze 逐文件结果

环境：Dart SDK（/opt/dart/bin），无 Flutter SDK / pub-cache，Flutter/riverpod/cached_network_image
符号报错按任务书口径属噪音；项目自有类报错即真错误。逐文件（过滤噪音后）：

| 文件 | 结果 |
|---|---|
| lib/features/player/play_helper.dart（V39-AUX-01/02/03 重写） | ✅ 无自有类错误（残留 3 条均为 riverpod Ref/Provider 未解析噪音） |
| lib/features/player/presentation/queue_sheet.dart（V39-AUX-09/10 重写） | ✅ 无自有类错误（残留全部为 Widget/Material/riverpod 符号噪音 + super.key 噪音；`ErrorRetry`/`EmptyState`/`PlayerController`/`Song`/`audioHandlerProvider`/`queueChangedHint` 全部解析无误） |
| lib/features/player/presentation/mini_player.dart（未改动，核对） | ✅ 无自有类错误（全部框架符号噪音） |
| lib/features/comment/presentation/comments_page.dart（V39-AUX-04/05/08/12） | ✅ 无自有类错误（残留均为 AsyncValue/super/initState 等未解析超类噪音） |
| lib/features/comment/presentation/comment_floor_page.dart（V39-AUX-04/06/07/08） | ✅ 无自有类错误（残留同上） |
| lib/l10n/app_localizations.dart（gen_l10n_min.py 重新生成，346 键×11 语言） | ✅ 生成物，`queueChangedHint` getter 已生成 |

## 改动清单

| 标记 | 文件 | 内容 |
|---|---|---|
| V39-AUX-01 | play_helper.dart | hash 缺失不再用 id 冒充（`s.hash ?? s.id` → `s.hash ?? ''`），依据 Song.==/MediaItem.id/最近播放守卫均以 hash 为准 |
| V39-AUX-02 | play_helper.dart | 三处 Song 转换合并为 `_songFromHome`/`_songFromPlaylist` 单一实现 |
| V39-AUX-03 | play_helper.dart | 时长单位显式化（`Duration(seconds:)` 集中到单一实现并注明契约来源） |
| V39-AUX-04 | comments_page.dart / comment_floor_page.dart | 发送/回复防重（`_sending` 闸门成对释放）+ 失败还原输入文本（不丢内容） |
| V39-AUX-05 | comments_page.dart | sendComment 成功刷新语义注释化（保持行为，避免引入新契约） |
| V39-AUX-06 | comment_floor_page.dart | 翻页失败置 `_pageError`，footer 重试按钮（原 catch(_){} 静默） |
| V39-AUX-07 | comment_floor_page.dart | 首屏错误态 `_error = friendlyError(e)`，不裸上 '$e' |
| V39-AUX-08 | comments_page.dart / comment_floor_page.dart | 删除失败统一 unwrapApi/friendlyError 口径 |
| V39-AUX-09 | queue_sheet.dart | 队列点击世代校验：以 handler 当前队列定位 hash，队列变更且无此歌时 SnackBar 反馈；isCurrent 补 hash 非空条件 |
| V39-AUX-10 | queue_sheet.dart | queueProvider 三态分离：loading 转圈 / error ErrorRetry+invalidate / data 空态 EmptyState |
| V39-AUX-11 | mini_player.dart | 核对结论：空态隐藏符合契约、除零有守卫、窄屏降级已就位——无缺陷，不改 |
| V39-AUX-12 | comments_page.dart | 删除带 specialId 不带 tid 的直连语义标注「未实测」（第 29 条），不改参数 |
| l10n | 12 个 ARB + gen_l10n_min.py | 新键 `queueChangedHint` 11 语言全补，重跑生成（346 键×11 locale） |

## 8 行内汇报

1. 读完 22 个文件全文（含任务书/质检标准/两份 v37 报告，及 player/comment/lyric/router/playlist/home/auth 全链路源码，共约 5000 行）。
2. 评论链路结论：路由 `/comments/:type/:id` 与全部 provider 均已存在，播放页入口可达——无需补定义。
3. 改 play_helper：hash 不再用 id 冒充、三处转换合并为单一实现、单位显式化（V39-AUX-01/02/03）。
4. 改 queue_sheet：三态分离 + 点击世代校验（当前队列 hash 定位，变更可感知）（V39-AUX-09/10）。
5. 改 comments_page/floor：发送防重+失败还原文本、翻页失败可重试、错误文案统一解包（V39-AUX-04~08）。
6. mini_player 核对无缺陷（V39-AUX-11），未改动；未做项原因均已在报告标注。
7. analyze 逐文件：5 个触碰文件均无项目自有类错误（噪音为 Flutter/riverpod 未解析符号）。
8. 新 l10n 键 queueChangedHint 补齐 11 语言并重跑 gen_l10n_min.py；未 commit。

