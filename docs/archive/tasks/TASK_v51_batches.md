# v5.1 交叉审查·8 批范围划分（每批 3 代理同范围不同视角）

| 批 | 范围（全部 .dart 文件，逐行完整读） | 特别关注 |
|---|---|---|
| B1 | `lib/core/foundation/**`、`lib/core/domain/**`、`lib/core/config/**`、`lib/core/api/kugou_api_client.dart`、`lib/core/api/translate_api.dart` | M1/M4 上移后的契约、20028 单点、CookieJar 时序、翻译 504 |
| B2 | `lib/core/direct/**`（kg_client / kg_direct_api_client / kg_crypto / kg_play_api / kg_shared_params / kg_endpoints_7 / kg_providers / edt_generator） | 原生网关唯一、签名形态、写操作防重、dfid 三写、二进制 body、`_wrap`→ResponsePolicy 迁移 |
| B3 | `lib/core/cache/**`、`lib/core/resource/**`、`lib/core/prefetch/**`、`lib/core/storage/**` | 三级缓存键唯一事实源、in-flight、失效回退、永久文件 (URL,bytes) 四道校验、预加载不下载文件、StoragePermission 下沉 |
| B4 | `lib/app/**`（bootstrap/di/router/main.dart 的启动编排段）、`lib/core/audio/**`、`lib/core/router/**`（若存在）、`lib/core/utils/error_logger.dart`/`friendly_error.dart`/`permission_gate.dart` | 启动顺序、Hive 开箱、音频引擎、日志捕获、权限网关回退、main 委托 bootstrap |
| B5 | `lib/features/player/**`、`lib/features/lyric/**` | 播放世代/闸门/自动跳歌、completed 永久缓存、KRC 逐字、翻译 stream 实时插入、切歌世代 |
| B6 | `lib/features/playlist/**`、`lib/features/comment/**`、`lib/features/rank/**`、`lib/features/home/**` | 反反顺序余数健壮、写后 ns 失效、评论写防重、分页状态机、首页预加载触发 |
| B7 | `lib/features/auth/**`、`lib/features/library/**`、`lib/features/download/**`、`lib/features/mv/**` | 登录态保存/恢复/切号、权限网关、下载择优、(URL,bytes) 文件缓存、MV hash→video_id、账号三态 |
| B8 | `lib/features/search/**`、`lib/features/artist/**`、`lib/features/album/**`、`lib/features/settings/**`、`lib/core/widgets/**`、`lib/core/theme/**`、`lib/l10n/app_localizations.dart`（生成物只读核对） | 搜索联想/分页、歌手页世代、设置页音质九档、按钮文案精简、arb 键集、生成物同步、触控目标 |

每批三代理的报告文件：`docs/v51_cross_b<N>_a.md` / `_b.md` / `_c.md`。
主代理合并结果：`docs/v51_cross_b<N>_merged.md`。

**执行节奏**：批与批串行（3 代理一批并行），一批三份齐 → 主代理合并裁决 → P0/P1 亲自修复 → 提交 → 下一批。8 批全部完成后统一发布 v5.1.0。
