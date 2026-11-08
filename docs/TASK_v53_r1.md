# v5.3 第 1 轮·审查任务书（三代理并行，覆盖全部 5 面）

通用纪律（每个代理都适用）：
- 先完整 file_read docs/PLAN_v53_player_refactor.md 与 docs/QUALITY_STANDARD.md（33 条）。
- 只实锤、只报问题、不改代码；逐文件实时 append 落盘自己的报告。
- 业务文件必须从头读到尾，禁止 grep/正则筛源码；交叉核对用 file_read 读定义。
- 每条：级别(P0-P3)/代码事实(文件:行)/违反第 N 条/用户可见后果/证据等级。
- 逐文件 dart analyze 贴结果；禁装 SDK/编译/改 pubspec/Manifest/Kotlin；禁读历史报告防锚定。
- 重点：审交互逻辑而不只语法——状态语义、时序、可见性、可恢复性、文案下一步动作。

## 代理 A：P1 队列与播放列表状态机（只读）
报告：docs/v53_r1_a.md
完整读：lib/features/player/data/audio_handler.dart、lib/features/player/player_provider.dart、lib/features/player/presentation/queue_sheet.dart、lib/features/player/presentation/mini_player.dart、lib/features/player/play_helper.dart、lib/features/player/data/models.dart、lib/core/domain/song.dart
判定：队列是否真有单一事实源、切歌/自动下一首/随机/循环/seek 各路径的状态转移是否自洽、7+ 状态变量是否互相矛盾、通知栏控制与 UI 是否同步、20028 挂起/世代闸门/失败重试是否闭环。
产出：现有状态变量全表 + 冲突时序 5 例 + 状态机事件表建议。

## 代理 B：P2 延迟捕获 + P5 歌词/preload（只读）
报告：docs/v53_r1_b.md
完整读：lib/features/player/data/player_repository.dart、lib/core/direct/kg_play_api.dart、lib/core/prefetch/prefetch_engine.dart、lib/features/lyric/data/lyric_repository.dart、lib/features/lyric/presentation/lyric_view.dart、lib/core/resource/resource_cache.dart（相关段）、lib/core/api/kugou_api_client.dart
判定：每个网络阶段的超时/重试/可见反馈是否存在、resolveUrl 失败是否有具体原因与重试入口、preload 键与实播键是否命中、歌词翻译世代/逐字性能/缓存 168h 是否真生效。
产出：延迟链路阶段表（每阶段：耗时上限/UI 反馈/失败出口）+ 缓存键命中实测对照。

## 代理 C：P3 权限网关 + P4 布局文案（只读）
报告：docs/v53_r1_c.md
完整读：lib/core/storage/storage_permission.dart、lib/core/utils/permission_gate.dart、lib/features/settings/presentation/settings_page.dart（外观/存储区）、lib/features/player/presentation/full_player_page.dart、lib/core/widgets/error_retry.dart、抽查 11 个 arb 的按钮/错误键。
判定：四重检测五级回退的状态是否真透出 UI、授权返回是否重探测、probeLog 可见性；播放页信息层级/按钮语义/长文案/空态错误态三态；每个按钮的三态与 48dp；文案「发生了什么+下一步」结构。
产出：布局重排建议图（文字版）+ 文案审计表（键/场景/字数/动作）。
