# v5.1 交叉审查 B2–B8 任务书（同批三代理同范围不同视角）

先完整读 `docs/TASK_v51_cross_common.md`（硬性规则）与 `docs/TASK_v51_batches.md`（范围表）。

三视角固定：A 功能正确性 / B 鲁棒与代码质量 / C 用户路径与一致性。
报告文件：`docs/v51_cross_b<N>_{a,b,c}.md`；每份末尾问题清单 + 复核通过项 + 逐文件 analyze 结果。

## B2：lib/core/direct（14 文件 / 4315 行）

**特别关注**：M2 下沉后的 edt_generator、kg_client 二进制 body、签名形态、写操作防重、dfid 三写、_wrap→ResponsePolicy。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/core/direct/edt_generator.dart`
- `lib/core/direct/kg_client.dart`
- `lib/core/direct/kg_crypto.dart`
- `lib/core/direct/kg_direct_api_client.dart`
- `lib/core/direct/kg_endpoints_artist_album.dart`
- `lib/core/direct/kg_endpoints_auth.dart`
- `lib/core/direct/kg_endpoints_comment.dart`
- `lib/core/direct/kg_endpoints_home.dart`
- `lib/core/direct/kg_endpoints_media.dart`
- `lib/core/direct/kg_endpoints_playlist.dart`
- `lib/core/direct/kg_endpoints_search.dart`
- `lib/core/direct/kg_media_direct.dart`
- `lib/core/direct/kg_play_api.dart`
- `lib/core/direct/kg_providers.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `M2 下沉后的 edt_generator、kg_client 二进制 body、签名形态、写操作防重、dfid 三写、_wrap→ResponsePolicy` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B3：lib/core/cache（9 文件 / 1444 行）

**特别关注**：cache_keys 唯一键、ResourceGateway 三级门面、in-flight/失效回退、永久文件身份(URL,bytes)四道校验。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/core/cache/cache_keys.dart`
- `lib/core/cache/cache_manager.dart`
- `lib/core/cache/resource_gateway.dart`
- `lib/core/prefetch/prefetch_engine.dart`
- `lib/core/resource/cached_api.dart`
- `lib/core/resource/lyric_translation_stream.dart`
- `lib/core/resource/resource_cache.dart`
- `lib/core/storage/secure_storage.dart`
- `lib/core/storage/storage_permission.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `cache_keys 唯一键、ResourceGateway 三级门面、in-flight/失效回退、永久文件身份(URL,bytes)四道校验` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B4：lib/app（8 文件 / 1010 行）

**特别关注**：启动顺序/Hive 开箱表/音频引擎初始化/日志捕获/权限网关回退。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/app/bootstrap.dart`
- `lib/app/di.dart`
- `lib/app/router.dart`
- `lib/core/audio/audio_service_bootstrap.dart`
- `lib/core/audio/preferred_quality.dart`
- `lib/core/utils/error_logger.dart`
- `lib/core/utils/friendly_error.dart`
- `lib/core/utils/permission_gate.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `启动顺序/Hive 开箱表/音频引擎初始化/日志捕获/权限网关回退` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B5：lib/features/player（11 文件 / 3804 行）

**特别关注**：播放世代闸门、completed 缓存、KRC 逐字、翻译 stream 实时插入、切歌世代。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/features/lyric/data/krc_decoder.dart`
- `lib/features/lyric/data/krc_parser.dart`
- `lib/features/lyric/data/lyric_repository.dart`
- `lib/features/lyric/presentation/lyric_view.dart`
- `lib/features/player/data/audio_handler.dart`
- `lib/features/player/data/player_repository.dart`
- `lib/features/player/play_helper.dart`
- `lib/features/player/player_provider.dart`
- `lib/features/player/presentation/full_player_page.dart`
- `lib/features/player/presentation/mini_player.dart`
- `lib/features/player/presentation/queue_sheet.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `播放世代闸门、completed 缓存、KRC 逐字、翻译 stream 实时插入、切歌世代` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B6：lib/features/playlist（11 文件 / 4179 行）

**特别关注**：反反顺序余数健壮、写后 ns 失效、评论写防重、分页状态机、首页预加载触发。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/features/comment/data/comment_repository.dart`
- `lib/features/comment/presentation/comment_floor_page.dart`
- `lib/features/comment/presentation/comments_page.dart`
- `lib/features/home/data/home_repository.dart`
- `lib/features/home/data/models.dart`
- `lib/features/home/presentation/home_page.dart`
- `lib/features/playlist/data/playlist_repository.dart`
- `lib/features/playlist/presentation/add_to_playlist_sheet.dart`
- `lib/features/playlist/presentation/playlist_detail_page.dart`
- `lib/features/rank/data/rank_repository.dart`
- `lib/features/rank/presentation/rank_detail_page.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `反反顺序余数健壮、写后 ns 失效、评论写防重、分页状态机、首页预加载触发` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B7：lib/features/auth（24 文件 / 6523 行）

**特别关注**：登录态保存/恢复/切号、权限网关、下载择优、MV hash→video_id、账号三态。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/features/auth/data/account_manager.dart`
- `lib/features/auth/data/auth_providers.dart`
- `lib/features/auth/data/auth_repository.dart`
- `lib/features/auth/data/captcha_types.dart`
- `lib/features/auth/data/slider_solver.dart`
- `lib/features/auth/data/verification_service.dart`
- `lib/features/auth/presentation/captcha_page.dart`
- `lib/features/auth/presentation/login_guard.dart`
- `lib/features/auth/presentation/login_page.dart`
- `lib/features/auth/presentation/verification_guard.dart`
- `lib/features/auth/presentation/verification_listener.dart`
- `lib/features/download/data/download_repository.dart`
- `lib/features/download/data/download_store.dart`
- `lib/features/download/data/download_task.dart`
- `lib/features/download/data/public_media_store.dart`
- `lib/features/download/download_provider.dart`
- `lib/features/download/presentation/download_page.dart`
- `lib/features/download/presentation/download_sheet.dart`
- `lib/features/library/data/recent_play_store.dart`
- `lib/features/library/presentation/library_page.dart`
- `lib/features/mv/data/mv_collection_repository.dart`
- `lib/features/mv/data/mv_repository.dart`
- `lib/features/mv/mv_provider.dart`
- `lib/features/mv/presentation/mv_player_page.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `登录态保存/恢复/切号、权限网关、下载择优、MV hash→video_id、账号三态` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。

## B8：lib/features/search（20 文件 / 5148 行）

**特别关注**：搜索联想/分页、歌手页世代、音质九档、按钮文案精简、arb 键集、触控目标。

**范围文件（必须逐个 file_read 完整读，禁止 grep/正则筛源码）**：

- `lib/core/theme/app_theme.dart`
- `lib/core/theme/settings_provider.dart`
- `lib/core/widgets/confirm_dialog.dart`
- `lib/core/widgets/empty_state.dart`
- `lib/core/widgets/error_retry.dart`
- `lib/core/widgets/gradient_chip.dart`
- `lib/core/widgets/list_skeleton.dart`
- `lib/core/widgets/section_header.dart`
- `lib/core/widgets/shimmer.dart`
- `lib/core/widgets/song_tile.dart`
- `lib/core/widgets/splash_handwriting.dart`
- `lib/core/widgets/splash_screen.dart`
- `lib/features/album/data/album_repository.dart`
- `lib/features/album/presentation/album_page.dart`
- `lib/features/artist/data/artist_repository.dart`
- `lib/features/artist/presentation/artist_page.dart`
- `lib/features/search/data/search_repository.dart`
- `lib/features/search/presentation/search_page.dart`
- `lib/features/settings/presentation/settings_page.dart`
- `lib/features/settings/presentation/settings_providers.dart`

**A 视角**：链路闭环、参数/返回契约、状态机、单位与字段形态；把 `搜索联想/分页、歌手页世代、音质九档、按钮文案精简、arb 键集、触控目标` 作为主判据。
**B 视角**：异常/边界/并发/资源对称/缓存维度/死代码/注释一致（第 1/6/9/11/13/14/18/19/20/21/23/25/28/29/31/32 条）。
**C 视角**：用户可见后果、三态、i18n、生命周期、跨模块契约、v5.0 重构后的回归风险。
