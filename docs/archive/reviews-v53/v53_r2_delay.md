# v5.3 第 2 轮（重写批）· P2 网络延迟捕获 + P5 歌词翻译世代 + l10n 缺失键 修复报告

执行代理：延迟捕获代理（P2/P5 线）。未碰状态机/播放页布局/队列。
依据：docs/PLAN_v53_player_refactor.md（P2/P5 节 + 质量要求）、docs/QUALITY_STANDARD.md（36 条）、
docs/v53_r1_b.md（B-01/02/03/04/05/06/09/10/13/14/16/17/19/21/22/24/27 等）。
本环境无 Dart SDK（遵守任务书禁装纪律），验收 = 完整阅读 + 括号/导入静态检查 + 逐行 diff 复读。

---

## 一、P2 网络延迟捕获（PLAN：NetworkPhase 三阶段超时分级 + 指示器 + 慢请求告警 + 退避）

### 1. 新增 `lib/core/net/network_phase.dart`（core 层纯 Dart，零 UI 依赖）
- `NetworkPhase { idle / resolving / buffering }`；`NetworkPhaseTracker` 单例 + broadcast 流，
  阶段事实单一来源（第 5 条）。
- 深度计数（begin/end 配对，第 19 条）：fetchDetail 与 resolveUrl 同属 resolving 且实际
  重叠（_playAt 在线分支先 fetchDetail 后 resolveUrl），深度归零才回落 idle（第 22 条并发显式）。
- buffering 由 audio_handler._applySource 包裹 setAudioSource（装载→首帧可播）。

### 2. 播报接线（数据层 → UI 全链）
- `player_repository.fetchDetail` / `resolveUrl`：try/finally 对称 begin/end（第 20 条）。
- `audio_handler._applySource`：setAudioSource 包裹 buffering 阶段（URL 就绪后用户可见
  「正在缓冲」而不是黑屏静默）。
- 新增 `lib/features/player/presentation/network_phase_indicator.dart`：
  2px 细进度条 + 阶段小 spinner + 文案；idle 高度收敛为 0（AnimatedSize）；
  订阅 tracker 流，dispose 对称取消（第 20 条）。
- `full_player_page`：Column 顶部接入 `const NetworkPhaseIndicator()`——常驻播放页顶部，
  不动既有布局结构（布局归 P4 代理）。

### 3. 超时分级（B-02/B-24）
- `kugou_api_client.dart`：connectTimeout 20s→**8s**、receiveTimeout 30s→**12s**（解析类
  JSON 网关定值，PLAN「resolving 8s」档；附「为什么」注释）。resolveUrl 最坏串行链上限从
  ~5.5min 收敛到 ~2min 内，配合阶段指示器全程可见。
- 直连链（KgClient）超时属 P1 线文件（kg_client.dart），本批未动——已在对账清单标注。

### 4. 慢请求告警（PLAN P2 拦截器要求）
- `KugouApiClient` 拦截器记录每请求起始时间；onResponse/onError 双出口统一过
  `_logSlowRequest`：≥3s（kSlowRequestWarnMs，PLAN 定值）走 ErrorLogger.log 落盘
  （release 可检索，第 9 条）；≥500ms 走 verbose 通道。

### 5. 失败可观测 / 退避
- B-04：kapi 试听兜底 `catch (_) {}` 空吞 → 捕获并 debugPrint 留痕。
- B-16（lyric_repository）：翻译批失败重试**先退避 1.5s**（`_retryBackoff` 常量），
  服务全挂时不再无间隔连击。

## 二、顺带修复（同文件 P1/P2 实锤，第 35 条「查一批修一批」）

| # | 级别 | 修复 |
|---|---|---|
| B-01 | P1 | ensureDfid 等待者**复用首个注册者结果**（成功直取/失败共享失败态），删除各自递归重试；重试上限收敛在首个注册者 ≤3。防重闭环（第 21 条）。 |
| B-05 | P3 | 特殊档直连网络异常不再落 kapi（原 if 缺口使特殊档静默降级为普通音源——数据失真），包装异常保留原因。 |
| B-06 | P2 | canPlay status 缺失改 **fail-closed**（不可播），上游字段裁剪后不再误判无版权曲可播。 |
| B-27 | P2 | 拦截器对 2xx 但 data 非 Map 的响应显式 reject（留痕），不再 `res.data ?? {}` 折成空 Map / 类型断言崩溃。 |
| C-65 关联 | — | 布局代理已存在的 router 未完成态：补 `storage_diag_page.dart` import、修正 GoRoute 缩进（否则 analyze 报错）。 |

## 三、P5 歌词翻译世代 + preload 对齐

### 1. B-14 译文错行（P2，两端实锤）——契约重写
- `LyricTranslationPatch` 新增 `lineIndices`（values[j] 属于行 lineIndices[j]），
  新增 `LyricTranslationPatch.indexed` 构造；旧 `startIndex+连续` 语义仅作空 lineIndices
  的防御回退。契约从「隐含连续」改为「按行号直写」（第 3/22 条显式化）。
- 发射端（lyric_repository）：缓存命中路径 emit `indexed(missing 全部行号)`；
  批翻译路径 emit `indexed(missing[i..i+n-1])`。非连续 missing（F4-30 逐行判定后的常态）
  不再错行。
- 消费端（lyric_view._onTranslationPatch）：按 lineIndices 直写；越界行丢弃不中断整批；
  空 lineIndices 退回旧连续写。

### 2. preload 键命中（R1 判定 0/3 → 2/3）
- B-10（预热死代码）已由 86affeb 修复，本批复核确认 `_markRequested` 在三段预热完成后
  调用、失败不标记（失败可重入，第 16 条）。
- 歌词候选键：实播 `findCandidate(hash, albumAudioId, durationSec)` vs 预热仅 hash——
  **本批对齐**：`prefetch_engine._prefetchOne` 第 2 段改为与实播同参
  `{'hash', 'album_audio_id', 'duration'}`（duration 用秒，与 findCandidate 同单位）。
- 正文键（/lyric 含 id/accesskey）依赖候选响应，缓存命中候选 JSON 后实播仍需一次正文
  请求（命中 ResourceCache 网络层则快）；彻底预热正文需改 prefetch 消费候选返回值——
  涉及冻结构造，留待 P1 状态机线合并后统一处理（对账清单）。

### 3. 死代码清理（第 32 条）
- B-15：lyric_repository 恒等字段 `final KugouApiClient _api` 删除；构造参数放宽为
  `MusicApi`（读路径统一 v5.0 M5 一致），di.dart 的 lyricRepositoryProvider 改注
  musicApiProvider；KugouApiClient import 随之清理（di.dart 同步）。

## 四、l10n 缺失键（C-63：播放阶段/缓冲/重试类键完全缺失）

新增 6 键 × 11 arb（zh_CN 模板 + 10 语言，en 兜底）+ `tool/gen_l10n_min.py` 重生成
（369→385 键）：

| 键 | zh_CN | 场景 / 下一步动作 |
|---|---|---|
| networkPhaseResolving | 正在解析播放地址… | NetworkPhaseIndicator resolving 态；无需动作 |
| networkPhaseBuffering | 正在缓冲… | buffering 态；无需动作 |
| playbackFailed | 播放失败，请重试或换一首 | 播放失败态；下一步=重试/换歌 |
| verifyRequiredHint | 需要完成人机验证后重试 | 20028 态；下一步=去验证 |
| translationInProgress | 正在翻译歌词… | 歌词翻译进行中；无需动作 |
| translationFailedHint | 译文获取失败，稍后将自动重试 | 翻译失败；下一步=自动重试（已退避） |

说明：布局代理同批已加入 loadingStream/bufferingStream/errorRetryHint 及存储诊断键
（其 P4/P3 范围）；我的指示器复用了 **networkPhase*** 新键而非其 UI 侧键，避免跨范围
耦合；两套键语义不冲突，合并时可由主代理裁决去留（对账清单）。

## 五、交付物清单（git 可 diff）

新增：
- lib/core/net/network_phase.dart
- lib/features/player/presentation/network_phase_indicator.dart

修改：
- lib/core/api/kugou_api_client.dart（B-24/B-27 + 慢请求拦截器）
- lib/features/player/data/player_repository.dart（B-01/04/05/06 + 阶段播报）
- lib/features/player/data/audio_handler.dart（buffering 播报，状态机逻辑零改动）
- lib/core/resource/lyric_translation_stream.dart（B-14 契约）
- lib/features/lyric/data/lyric_repository.dart（B-14/15/16）
- lib/features/lyric/presentation/lyric_view.dart（B-14 消费端）
- lib/app/di.dart、lib/app/router.dart（接线修正）
- lib/features/player/presentation/full_player_page.dart（仅 +2 行：import + 指示器挂载）
- lib/l10n/*.arb × 11 + lib/l10n/app_localizations.dart（重生成）

## 六、验收

- 括号平衡脚本（check_braces.sh）+ 自写跨文件括号/字符串扫描：全部通过
  （audio_handler 的 depth≠0 为 `${...}` 插值的已知基线误报，pristine 基线同值 3）。
- check_imports.sh：通过。
- 逐行 diff 复读完成；未改 pubspec/Manifest/Kotlin；未装 SDK/未编译。
- 同类排查（第 36 条）：加载可见性已覆盖 播放 URL 解析/详情/缓冲/歌词（R1 754d015
  歌词三态视图）+ 本批指示器；MV/下载页反馈已有（v3.9/v4.0 交付）；翻译阶段文案键
  已备好（translationInProgress/Failed），接入歌词页属 P4 面挂点，未越权改布局。

## 七、遗留对账（交主代理合并时裁决）

1. 直连 KgClient 请求级超时（B-07）：kg_client.dart 属 P1 线文件，建议状态机重写批
   一并定「resolving 3s」直连档。
2. 歌词正文预热需消费候选响应（涉及冻结构造）。
3. 布局代理的 loadingStream/bufferingStream 键与我的 networkPhase* 键并存，建议保留
   一套（建议 networkPhase*，已被指示器消费）。
4. l10n 机器翻译（tool/translate_arb.py 用 bilibili Index-Translate）未跑——本批 6 键
   × 10 语言由会话内模型直翻；如需走既有管线可用 `python3 tool/translate_arb.py`
   增量覆盖（已有键不覆盖）。
