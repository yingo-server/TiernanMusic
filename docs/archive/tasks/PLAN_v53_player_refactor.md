# v5.3 播放器体系化二次重构规划书（用户 2026-11-09 定调）

> 背景：真机反馈「播放列表跟没有一样、大量网络延迟未捕获、权限网关一坨、布局文案混乱几乎不能直视」。
> 本次不做语法修补，**重构交互逻辑与状态架构**。

## 一、病灶清单（先实测再定案，三代理第一轮产出）

播放器域拆 5 个可审面，每面出「现状病灶 → 根因 → 重写方案」：

| 面 | 范围 | 已知症状 |
|---|---|---|
| P1 队列与播放列表状态机 | audio_handler / queue_sheet / _playAt / 世代/闸门/_pendingIndex | 播放列表「跟没有一样」：切歌链路 7+ 个状态变量分散、QueueHandler mixin 与手写队列双轨、通知栏控制与 UI 状态不同步 |
| P2 网络延迟捕获 | resolveUrl / songUrl / preload /dio timeout | 「大量网络延迟没有捕获」：无统一超时分级、无骨架屏/进度指示、无重试退避、失败静默 |
| P3 权限网关 | storage_permission / permission_gate / bootstrap | 「权限网关一坨」：四重检测+五级回退后 UI 仍不透出状态、探测历史不可见、授权引导断点 |
| P4 播放页布局与文案 | full_player_page / mini_player / 控制区 / 文案键 | 「布局文案混乱」：信息层级不清、按钮语义重叠、长文案溢出、空态/错误态文案不统一 |
| P5 歌词与 preload 一致性 | lyric_repository / lyric_view / prefetch | 缓存键分裂、翻译世代、逐字渲染性能 |

## 二、目标架构（重写而非修补）

### P1 状态机（核心重写）
- `PlayerStateMachine`：单一 sealed class `PlayerState { idle/loading(song)/playing(song)/paused/failure(reason) }`，取代散落的 `_songs/_index/_pendingIndex/_pendingSongHash/_isPreview/_loading/_failureStreak…`
- 队列操作全部经状态机事件（`PlayQueueRequested/Next/Previous/SeekTo/Completed/Failed`），禁止外部直改字段
- audio_handler 只做 just_audio 适配器（平台通道 ↔ 状态机事件），QueueHandler mixin 弃用（手写队列统一）
- UI 只 watch 一个 `playerStateProvider`，三态渲染由状态机保证互斥

### P2 延迟捕获（全链路）
- `NetworkPhase` 枚举：`resolving/detecting/streaming` 各自超时（3s/8s/30s）
- 播放页顶部常驻 `NetworkPhaseIndicator`（细进度条 + 当前阶段文案），任何>500ms 的阶段都可见
- 失败必有重试按钮 + 具体原因（APIException 解包后分级文案）
- dio 全局 `InterceptorsWrapper` 记录每请求耗时入 verbose 日志（已有），新增**慢请求阈值 3s 告警**

### P3 权限网关（状态透出）
- `StorageResolution` 已有 probeLog——UI 侧新增「存储状态」诊断页（设置 → 存储）：五级回退链逐级 ✓/✗ + 当前生效级别 + 一键重新探测 + 跳授权
- bootstrap 启动即探测一次并缓存，授权页返回（resumed）自动重探测

### P4 布局与文案（设计系统化）
- 播放页信息层级重排：歌名(大)/歌手(中)/音质+试听徽标(小)/进度/控制/次级操作入口收进「更多」
- 全部动作按钮语义唯一化（收藏=加歌单，MV/评论/歌词在入口行，下载在菜单）
- 文案键审计：≤4 字动词化（收藏/评论/MV/歌词/全播），错误态文案统一「发生了什么 + 下一步」结构
- mini_player 与全屏页状态渲染共用 `PlayerState` 映射，禁止两套逻辑

### P5 歌词
- 缓存键统一走 `cache_keys`（lyric:hash:lang），翻译 stream 世代已修，复查布局对齐

## 三、质量要求（比 33 条更严，播放器专项）

1. 状态机单点：`grep '_songs\['` 只允许出现在状态机内部文件
2. 每个网络阶段必须有可见 UI 反馈（第 9/16 条强化：>500ms 即可见）
3. 每个按钮必须有：唯一语义、≥48dp 触控、状态（enabled/disabled/loading）三态
4. 文案审计表：每个 l10n 键标注「场景/字数/下一步动作」，超长键必须重写
5. 播放链路任何 catch 必须带世代守卫（现有 P1 回归不得复发）
6. CI 架构断言扩展：`audio_handler` 不得 import presentation 层；`queue_sheet` 不得直接调 `_api`

## 四、执行方式（自主迭代，完成后发 v5.3.0）

1. **三代理并行实测审查**（60 分钟）：P1 状态机 / P2+P5 延迟与歌词 / P3+P4 权限与布局文案——各自产出「病灶实锤表」
2. 合并 → 重写方案定稿（我裁决）
3. **重写批**：P1 状态机（我亲自）+ P4 布局（代理）+ P2/P3（代理）三线并行
4. 全量 analyze + CI → bump 5.3.0+54 → tag → 发布
