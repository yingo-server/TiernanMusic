# v3.3 迭代任务书·第 3 批（审查②）：用户路径回归复核

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（含第 33 条：kapi 返回不可作原生实测依据）。

## ⚠️ 硬性规则
同 `docs/TASK_v33_review1.md` 的「硬性规则」（只读/完整阅读/禁编译/实时落盘/禁旧报告锚定）。

## 报告文件
`docs/v33_review_2.md`

## 复核范围：用户三条实测反馈路径的全链路
用户报告的三个现象，逐环节走到根（不是泛泛找问题）：
1. **「歌单仅首次登录能加载」**：
   - `library_page.dart` `_userPlaylistsProvider` → `playlist_repository.fetchUserPlaylists` → `kg_endpoints_playlist.userPlaylist` → 签名 → gateway
   - 核对：登录态二次进入时 kg.userid/kg.token 的实际值（restoreSession、logout、账号切换后）；`_wrap` 是否把原生成功误判失败；autoDispose family 参数（loggedIn）切换时的重建时机
2. **「全部播放有问题」**：
   - `_playAt` 全链：ensureEngineReady → fetchDetail → resolveUrl（直连 /v5/url trackercdn）→ _applySource → play
   - 核对：`network_security_config.xml` cleartext 白名单 vs 实际 CDN 域名；`_qualityFromBitrate`/`_actualQuality` 阈值一致性；试听判定（priv_status/hash_offset）对 VIP 的误判；URL 失效重试通路
   - MV 正常而歌曲异常 → 差异点在哪些参数（MV 走 kmr/audio/mv + video/url，歌曲走 /v5/url）——列出差异清单
3. **「第一屏粗糙」**：修复后的手写动画在真实冷启动时序下的可用性（动画未完成就跳转？首帧阻塞？主题深色模式下可见性？）

## 复核重点
- 每个环节给出「证据等级」：实测（native_probe/curl）/ 静态推导 / 推测。推测不得作为问题依据（第 29 条）
- 只报回归/新缺陷/修复不完整/用户路径上的既有缺陷，不重复旧报告
- 违反条款 + 用户可见后果，格式同 v33_review1

## 落盘
`docs/v33_review_2.md`，末尾问题清单+统计。完成后 5 行内汇报。
