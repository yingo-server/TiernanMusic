# v5.3 第 2 轮（重写批）· P4 播放页布局重排 + P3 存储诊断页

> 范围硬约束：只动 P4（full_player_page / mini_player / 播放页 l10n 键）与 P3（存储诊断页 +
> 设置页存储区入口）。**不碰** P1 状态机 / audio_handler / queue_sheet / P2 网络层。
> 布局代理无 Flutter SDK，验收 = 静态检查三件套 + 手工逐行复读。

## 依据
- docs/PLAN_v53_player_refactor.md P3/P4 两节
- docs/v53_r1_c.md 播放页/设置页病灶实锤（C-18~C-24, C-33~C-38, C-40, C-55~C-58）

## P4 播放页（full_player_page.dart / mini_player.dart）

### 布局重排（PLAN P4 层级定案）
1. 信息层级三层分离：歌名（大，titleLarge，2 行自适应）→ 歌手（中，bodyMedium，
   独立一行）→ 徽标行（小：试听 Badge + 音质 Badge，独立 Row，不与歌手抢宽）。
2. 入口行语义唯一化（质量要求 3）：
   - 顶栏「更多」菜单 = 下载 + 收藏到歌单 + 播放队列（次级操作收纳处）。
   - 入口行 = 评论 / MV（有才显示）/ 歌词切换（新增，与封面右上角切换按钮同语义，
     C-38：按钮 ≥48dp 且有 active 态）。
   - 删除入口行里的「收藏」按钮与「队列」40dp IconButton（与顶栏重复，C-37）。
   - 队列入口唯一化到顶栏菜单；mini_player 队列入口保留（不同面）。
3. 入口行高度 48dp（质量要求 3：≥48dp 触控），按钮 maxLines 1 + ellipsis。
4. 控制区进度条：拖动时左下角时间跟随拖动值（C-44）；duration==0 时禁用滑块。
5. 整页竖排加滚动兜底（C-40）：`_PlayerContent` 固定分区包
   `SingleChildScrollView`（竖屏正常时 Expanded 封面区不变；用 LayoutBuilder
   maxHeight 判断是否进入滚动模式，避免横屏/大字号溢出）。
6. 错误态（C-33/C-34/C-54，范围内的 UI 侧）：
   - playerErrorProvider 最近一条错误 → 顶部错误横幅升级为可操作条
     （错误文案 + 重试按钮），复用 friendly_error 分级；audio_handler 不动，
     engineError 原样展示但加重试按钮（C-35 的数据层硬编码中文归 P1 代理修）。
   - 顶部常驻 NetworkPhaseIndicator（P2 的播放页可见面，>500ms 可见）：
     resolving/buffering 阶段细进度条 + 阶段文案；数据源只读现有 provider
     （isPlaying/duration/position），不新增状态机依赖。
7. mini_player 与全屏页共用状态映射：抽 `_playPauseSemantic(isPlaying)`
   helper 到 shared 文件？——不新建抽象，保持两文件各自 watch 相同 provider
   （PLAYER 契约：mini 不触网、不构造 Repository）。

### 文案键（PLAN P4 审计：≤4 字动词化 + 错误态「发生了什么+下一步」）
- 修复 `app_fr.arb.notPlaying` 语义反转（C-55）→ "Lecture non active"。
- `addToPlaylist` 语义澄清（C-56）：zh 收藏→加歌单？——保持键名与动作一致：
  zh_CN「加到歌单」超 4 字；定案：zh「收藏」保留但按钮语义改为「收藏到歌单」
  长按直达？——最终定案：**入口行删除该按钮后，键只出现在顶栏菜单**，
  文案 zh_CN 改「收藏到歌单」/en 'Add to playlist'（消除 Save 歧义），其余语种对齐。
- 新增键（11 语齐）：`storageDiag`（存储状态）、`storageReprobe`（重新探测）、
  `storageLevel`（生效级别）、`storageProbeLog`（探测历史）、`storageProbeRunning`
  （正在探测…）、`storageProbeFailedShort`（探测失败）、`goGrant`（去授权）、
  `errorRetryHint`（出错了，点重试）、`loadingStream`（正在连接…）、
  `bufferingStream`（缓冲中…）。
- 所有新键 ≤12 字（错误态结构键除外），11 语全部补齐后重跑
  `python3 tool/gen_l10n_min.py`。

## P3 存储诊断页（新文件 lib/features/settings/presentation/storage_diag_page.dart）

满足 PLAN P3 四要素（C-18 的根治），数据源只用 StoragePermissionService 现有公开 API：
1. 五级回退链逐级 ✓/✗：由 `resolveRoot()` 的 probeLog + 生效 level 推导渲染
   （L≤生效级=✓，之后=✗/未执行），C-08 的 probeLog 结构问题不在本批改服务层，
   UI 按 level 前缀推导补足视觉五级。
2. 当前生效级别 + 路径（可复制）+ 模式说明。
3. 一键重新探测：`setState` 重跑 resolveRoot（按钮 loading 态防连点，质量要求 3）。
4. 跳授权：`requestAllFilesAccess()` + 返回后自动重探测；按钮可见性按
   `isAllFilesAccessGranted()` 而非 mode 推导（修 C-23）。
5. 三态渲染（第 16 条）：loading=进度指示 / error=原因+重试 / data=结果，
   禁止空 catch 静默降级（修 C-21 的页面侧）。
6. 路由 `/settings/storage`（router.dart 加 GoRoute），设置页存储区改为
   _navTile 入口（修 C-18 的 subtitle 塞爆），原「存储权限」诊断 ListTile
   （C-24 恒 true 假申请）改为跳转诊断页。

## 验收（无 SDK 静态闸门）
1. `sh check_braces.sh` 全绿
2. `sh check_imports.sh` 无 BAD IMPORT
3. `python3 -c json.load` 11 个 arb 全解析通过；369→新键数 × 11 语全齐
4. `python3 tool/gen_l10n_min.py` 重新生成 accessor
5. `rg '上次括号/analyze'` —— 逐文件人工复读新增/修改段（缩进、括号、未定义引用）
6. 架构红线：storage_diag_page 不 import features/*/data；full_player_page
   不新增 features/*/data import（现有 playlist/download 契约保持）
7. 报告落盘 docs/v53_r2_layout.md（改动清单 + 键审计表 + 自检结果）
