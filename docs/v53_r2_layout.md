# v5.3 第 2 轮（重写批）· P4 播放页布局重排 + P3 存储诊断页 · 交付报告

> 执行：布局重排代理（无 Flutter SDK，验收 = 静态闸门 + 逐行复读）。
> 范围遵守：**未碰** 状态机 / audio_handler / queue_sheet / P2 网络层逻辑；
> 所有新 UI 只读现有 provider 与 `StoragePermissionService` 公开 API。

## 一、关键事实（先读这个）

HEAD `939d774`（R3 提交）已包含本任务大部分产物的等价实现：
`storage_diag_page.dart`（373 行）、路由 `/settings/storage`、设置页存储区收敛、
`lyricVisibleProvider`、三层 `_SongInfoHeader`、48dp entryButton、
进度条 disabled/拖动跟随、NetworkPhaseIndicator 接线、playerError 横幅、
l10n 新键与 fr.notPlaying 修复均在 HEAD 中已存在（提交时间 04:12:26，
与本代理工作区写入交叠，属「重复施工已合并」而非冲突）。

本代理对工作树的**净增量**（git diff vs 939d774，共 3 个文件 +21/−16 行）：

| 修复 | 文件 | 改动 |
|---|---|---|
| C-45 空态队列可点 | full_player_page.dart | PopupMenuItem `enabled: song != null` + onSelected 分支 `&& s != null` |
| C-43 MV 按钮三态 | full_player_page.dart | `if (mvAsync != null \|\| hasMv)` + `onPressed: !hasMv ? null : …`——loading 时禁用占位，入口行 3↔4 列不再跳变 |
| 文案键修剪（第 32 条死代码） | 11×arb + app_localizations.dart | 删除 6 个全项目零引用键：`storageRootPath / storageModeRoot / storageModeDownload / storageProbeFailed / grantAllFilesAccess / requestPermission`（385→379 键 ×11 语，key set 逐语比对相等） |
| 诊断页卡片标题 | storage_diag_page.dart | 授权卡 title `storageDiag→permissionDenied`（卡内语义=权限态，AppBar 已是 storageDiag） |

期间发生 3 处工作区字节损坏（并发写入交叠），均已逐字节修复并验证：
括号配平、UTF-8 完整性、`git diff` 净增量复核三重通过；HEAD 中同区域内容
与修复后语义一致，未丢失任何 HEAD 既有逻辑。

## 二、P4 布局重排（对照 PLAN P4，主体在 HEAD 939d774）

1. **信息层级三层**（修 C-36）：`_SongInfoHeader` 歌名(titleLarge,2行) →
   歌手(独立行 bodyMedium) → 徽标行(试听+音质，无徽标不占高)。
2. **语义唯一化**（修 C-37/C-45）：收藏/下载/队列收敛顶栏「更多」；入口行=
   评论/歌词切换/MV(三态)；空态队列不可点。
3. **歌词入口**（修 C-38）：`lyricVisibleProvider` 共享状态，入口行 48dp
   按钮（selected 高亮），封面右下 40dp 悬浮按钮删除。
4. **进度条**（修 C-44/C-41 部分）：`duration==0` → 滑块 disabled（不再假
   上界 1ms seek）；拖动时左下角时间跟随拇指。
5. **滚动兜底**（修 C-40）：`_PlayerContent` LayoutBuilder——maxHeight>500
   走 Column+Expanded；否则 SingleChildScrollView+260dp 封面区。
6. **错误可见面**（修 C-34 UI 侧）：`playerErrorProvider` 最近一条接入顶部
   横幅（engineError 优先）；横幅带 48dp「重试」按钮（togglePlay 内部自会
   ensureEngineReady）。C-35 的 audio_handler 硬编码中文归 P1 代理，未动。
7. **阶段指示**：`NetworkPhaseIndicator` 常驻顶部（R3 产物），resolving/
   buffering >500ms 可见。
8. mini_player 与全屏页 watch 同一 provider 集（现契约保持），未引入第二套
   状态映射。

## 三、P3 存储诊断页（对照 PLAN P3，主体在 HEAD 939d774）

- 新页 `lib/features/settings/presentation/storage_diag_page.dart`：
  五级回退链逐级 ✓/○（按生效 level 推导）+ 生效级别/路径(可复制) +
  一键重新探测（loading 禁点）+ 跳授权（resumed 自动重探测）+ probeLog
  等宽 SelectableText。三态：Loading/Refreshing(保留旧数据)/Error(原因+重试)/Data，
  无空 catch（C-21 页面侧根治）。
- 授权卡按钮可见性按 `isAllFilesAccessGranted()` 推导（修 C-23）。
- 设置页：存储区=verbose 开关+诊断页 `_navTile` 入口；「存储权限」条改跳
  诊断页（恒真假申请按钮删除，修 C-24）；`_storageGranted` 改真实授权查询
  （修 C-22 假刷新）；initState 双探测/双 Future 副本删除（修 C-19）。
- 路由 `/settings/storage` 已在 HEAD 接线。

## 四、文案键审计（PLAN 质量要求 4）

| 键 | 场景 | zh 字数 | 动作 | 状态 |
|---|---|---|---|---|
| errorRetryHint | 播放页错误横幅 | 8 | 点重试 | 新增(HEAD) |
| loadingStream / bufferingStream | 阶段条 | 5/4 | 等待 | 新增(HEAD) |
| storageDiag/storageLevel/storageProbeLog/storageReprobe/storageProbeRunning/storageProbeFailedShort/goGrant | 诊断页 | ≤4-5 | 导航/重试/授权 | 新增(HEAD) |
| notPlaying(fr) | 空态 | — | — | 语义反转修复(HEAD) |
| addToPlaylist | 顶栏菜单 | 收藏到歌单 | 弹歌单 | 语义澄清(HEAD) |
| storageRootPath 等 6 键 | 已无 UI | — | — | **本代理删除**（零引用死键） |

379 键 × 11 语全齐（脚本逐语 key set 断言相等），`gen_l10n_min.py` 已重生成。

## 五、自检结果（无 SDK 静态闸门）

| 闸门 | 结果 |
|---|---|
| `check_braces.sh`（全 lib 括号配平） | ✅ 全绿 |
| `check_imports.sh`（坏/重复 import） | ✅ 无 BAD IMPORT |
| 11×arb JSON 解析 | ✅ 全通过，key set 逐语相等 |
| `gen_l10n_min.py` | ✅ 379 keys × 11 locales |
| UTF-8 完整性（U+FFFD 扫描 + 字节级复核） | ✅ 0 替换符 |
| 架构红线 | ✅ diag 页 0 个 features/*/data import；播放页未新增 data 层依赖；`grep '_songs\['` 未触碰 |
| git diff 净增量复核 | ✅ 与 HEAD 语义差异 = 上表 4 项 |

## 六、遗留（不在本批范围，移交裁决）

- C-01/C-03/C-04/C-06（服务层：L5 无探针/四重检测短路/lastProbeError 并发/
  resolveStrategy 分叉）→ 服务层属 P3 服务端重写，需主代理裁决是否随
  v5.3.0 亲修；诊断页 UI 已按现 API 渲染，服务层修复后自动受益。
- C-11/C-15（permission_gate 恒真）→ 已通过「设置页不再消费其判定」缓解
  展示面；根修在服务层。
- C-41 完整三态（按钮 loading 锁）依赖 P1 状态机的 PlayerState，本批只做了
  duration==0 disabled 与错误横幅重试。
- C-55~C-58 其余文案长度失衡（de 100 字 hint 等）→ 11 语翻译批统一处理。
