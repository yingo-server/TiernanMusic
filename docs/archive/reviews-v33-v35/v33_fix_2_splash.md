# v33 修复② 报告：启动屏手写渲染动画 + MV 缩略图规范

基线 `defd4a4`。本批以 UI 动画实现为主，严格遵守「禁止拉伸图片 / 禁止装 SDK / 禁止 git」约束。

---

## 一、核心任务：动态手写启动动画

### 动画方案选择（V33-01/02/03/04）
**方案：SVG path 硬路径描摹（首选方案，已落地），非退化方案。**

- 图标源文件确认：`assets/` 仅 `audiomack.svg`（无 PNG、无 `assets/fonts/`），
  是单条波形笔画 + 左侧小圆点，本身就像「字迹」。
- `flutter_svg` 的 `SvgPicture` 不支持按 path 长度分段绘制，无法做真正「写出」效果；
  旧 `animated_svg_logo.dart` 只是 `ClipRect + widthFactor` 整图左→右露出，并非手写。
- 因此把 `audiomack.svg` 的 path 数据（`M43 96 s11 5 19-8 l5 20 19-30 c0 12 8 38 8 38
  l26-53 -1 82 34-98 -3 67 12-14 8-2`）逐段展开为绝对坐标（相对指令 `s` 首段控制点
  按 SVG 规范退化为当前点），用 `PathMetric.extractPath(0, len*t)` 按笔迹长度描摹：
  - 起笔圆点先随进度「落下」（`drawCircle` 半径渐增）；
  - 主笔画用 `Curves.easeInOutSine` 由左到右写出，笔头（`getTangentForOffset`）实时跟随；
  - 写完停顿 ~620ms → 整体渐隐（Opacity 1→0，290ms）→ 清空画布 → 循环（单 `AnimationController.repeat()`）。
  - 一轮 2600ms > 典型冷启动 ~2s，确保首页切走前至少完整书写一次。
- **零拉伸**：绘制前按内容包围盒算一个统一 `scale = min(w/W, h/H)`，宽高同系数，无任何拉伸。
- 文字「汀澜音乐」保留，沿用现有 `letterSpacing:4` 样式，随书写完成在 hold 段淡入、随渐隐退场。
- 性能/生命周期：动画仅在 Splash 存续期运行；`AnimationController` 单实例、`dispose` 对称；
  `CustomPainter` 以 `cycle` 为 `repaint`，每帧只 `paint` 不重建 Widget；`PathMetric` 缓存一次。
- 退出控制（`main.dart` V33-04）：原先 `_appReady` 在首帧 post-frame 回调立刻置 true，
  Splash 实际只活一帧；新增 `_splashMinElapsed` Timer（= `HandwritingCycle.minVisible`，
  写完+停一拍），就绪+最短时长都满足才切走。Timer 在 State.dispose 对称取消，不阻塞 main/首帧。

### 改动
- 新增 `lib/core/widgets/splash_handwriting.dart`（`SplashHandwriting` + `HandwritingCycle` +
  `HandwritingGeometry` + `HandwritingLogoPainter`），含 V33-01/02 注释。
- 改写 `lib/core/widgets/splash_screen.dart`：只做装配，调用 `SplashHandwriting`（V33-03）。
- 删除 `lib/core/widgets/animated_svg_logo.dart`（旧方案，不再被引用）。
- `lib/main.dart`：导入 `HandwritingCycle`；新增最短展示时长逻辑（V33-04）。

---

## 二、次要任务：MV 缩略图与资源缩略图规范

### 1. MV 缩略图尺寸档（V33-10）
`lib/features/mv/data/mv_repository.dart`：
- 新增静态辅助 `MvRepository._mvThumb(raw, {size})`，统一处理 `{size}` 占位 / 裸 `pic`
  文件名拼 `mvthumb/{size}/pic` / http→https 升级。
- `MvInfo.fromJson`（关联列表卡片，约 48px）：`size:320`（等比最小够用档，第 25 条）。
- `MvDetail.fromJson`（详情页，720×设备像素仍清晰）：`size:480`。
- 原 `mv_repository.dart:242` 处 `{size}`→`480` 硬编码已被纳入新辅助，列表/详情按控件选档。

### 2. 全仓图标规范巡检（第 25/26 条）
- **BoxFit.fill 巡检**：`rg` 全仓 0 处 `BoxFit.fill`（基线本就合规，无需改）。
- **memCacheWidth / maxWidth 补齐**（缺省解码上限）：
  - `search_page.dart:654` 歌单网格缺 `memCacheWidth` → 补（V33-11，单卡宽≈(屏宽-44)/2×dpr）。
  - `library_page.dart:372` 账户头像 `CachedNetworkImageProvider` 缺 `maxWidth` → 补（V33-12，52×dpr）。
- **空封面守卫 `cover.isNotEmpty`（R-30 同类）缺失处补齐**：
  - `home_page.dart:183` banner（V33-13）、`home_page.dart:256` 每日推荐（V33-14）、
    `home_page.dart:346` 推荐歌单（V33-15）、`home_page.dart:432` 排行榜（V33-16）；
  - `search_page.dart:654` 歌单网格（V33-17）、`search_page.dart:718` 通用结果（V33-19）；
  - `library_page.dart:553` 我的歌单（V33-18）。
  - 其余 `CachedNetworkImage` 调用点（song_tile / artist / album / settings / player / playlist /
    comment / queue_sheet 等）在巡检前已具备 `memCacheWidth`+空串守卫，未改动。

---

## 三、巡检发现数
- `BoxFit.fill`：0 处（全仓合规）。
- `memCacheWidth`/`maxWidth` 缺失补点：2 处（V33-11、V33-12）。
- 空封面守卫补点：7 处（V33-13~19）。
- MV `{size}` 选档归一：1 处辅助（V33-10）。

## 四、未做项原因
- **退化方案未采用**：SVG path 仅 11 段、可纯 Dart 逐段展开核对，且 `dart` 可用（仅缺 Flutter
  包解析导致 analyze 报 URI 噪音，非语法错误），故走首选「真实路径描摹」而非 Text/ShaderMask 退化。
- **禁止装 SDK/build/test/pub get**：`dart analyze` 因无 Flutter 包而全量报 `uri_does_not_exist`
  级噪音（已过滤）；我以 `dart format --set-exit-if-changed` 验证了自身改动文件括号平衡、无语法错误。
- **未做 git commit/push**：符合约束。
- `MvInfo.thumb` 仅入库未直接渲染，按 320 档取已足够，无需额外 UI 改动。
