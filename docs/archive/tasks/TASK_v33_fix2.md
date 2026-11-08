# v3.3 迭代任务书·第 2 批（修复②）：启动屏手写渲染动画

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（第九章第 33 条：kapi 返回不可作为原生网关实测依据）。

## 角色
修复代理（本批以 UI 动画实现为主）。

## 绝对禁止
- 禁止装 Flutter SDK / 装包 / clone / flutter build / flutter test / dart pub get
- 允许 `dart analyze`（过滤缺包噪音）；新增 Flutter 符号调用必须显式核对 import 头
- 禁止 git commit/push；禁止改 QUALITY_STANDARD.md
- **禁止拉伸图片**（本批核心要求之一）：任何位图缩放只允许 `BoxFit.contain` / `cover`（cover 需配合对齐），禁止 `fill`

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `defd4a4`

## 输出
`docs/v33_fix_2_splash.md`，逐条：编号/文件:行/实现说明。

---

## 核心任务：动态手写启动动画（替换现有 SplashScreen）

### 需求（用户原话）
1. 第一屏过于粗糙，重新设计
2. 图标本身就是「类似字迹」的手写体 → 把它放到合适尺寸，**用类似手写的方式反复渲染**
3. 写完一次后用**渐隐**方式过渡
4. 反复渲染（可循环）

### 实现方案（可调整，保效果优先）
1. **路径描摹动画**（首选）：
   - 读 `assets/` 里的图标源文件（先 `ls assets/` 确认格式；若是 SVG，用 `vector_graphics` 或解析 path 数据；若是 PNG 字迹，考虑用 `CustomPainter` + 笔画路径手绘近似）
   - 用 `CustomPainter` + `PathMetrics.extractPath(start, end)` 实现「笔迹从无到有按笔画顺序写出」
   - 多笔画时按顺序逐笔写出（每笔之间微小停顿），模拟真实书写节奏（可用 `Curves.easeInOutSine`）
2. **循环**：写完 → 停留 ~600ms → 整体渐隐（Opacity 1→0，300ms）→ 清空画布 → 重新写
3. **文字**：「汀澜音乐」保留但改为随字迹完成后淡入（`letterSpacing: 4` 现有样式沿用）
4. **性能**：第 26 条热路径——动画只在 splash 存续期运行，`AnimationController` 单实例、`dispose` 对称、`didStopTrackingLastPointer` 无关；离开 splash 必须停止 controller
5. **首屏就绪**：splash 在首帧就绪后退出（现有逻辑），动画时长要覆盖典型冷启动（~2s/轮），不能因动画阻塞 `main()` 或首帧
6. **退路**：若 SVG path 提取过于复杂（无 SDK 无法验证解析），允许退化方案——用 `Text` + 书法字体（`assets/fonts/` 若有）+ 逐字 `Opacity`/`TextPosition` 动画模拟手写；或 PNG + `ShaderMask` 扫光模拟笔画推进。**方案必须在报告里说明选择理由**。

### 文件
- 改 `lib/core/widgets/splash_screen.dart`（或新建 `splash_handwriting.dart` 由它调用）
- 动画组件放新文件 `lib/core/widgets/splash_handwriting.dart`， SplashScreen 只做装配
- 资源文件引用要核对 `pubspec.yaml` 的 assets 声明（缺失要补）

## 次要任务：MV 缩略图与资源缩略图规范

1. **MV 缩略图**（`lib/features/mv/`）：
   - 现状 `mv_repository.dart:242` cover 用 `{size}` 占位符替换为 480
   - 目标：列表/卡片用 **320**（等比缩小），详情页用 480/720；**只允许等比**，禁止任何 `BoxFit.fill`
   - 若上游支持多尺寸参数（`{size}` 240/320/480/720），按控件尺寸选最小够用档（第 25 条：解码尺寸上限）
2. **全仓图标规范巡检**（第 26/25 条）：
   - 搜一遍 `BoxFit.fill`（grep 允许，这是巡检不是审查）→ 全部改 contain/cover + 对齐
   - `CachedNetworkImage` 无 `memCacheWidth` 的调用点补上（按控件实际宽度 × devicePixelRatio）
   - 封面为空串的守卫（R-30 同类）缺失处补 `cover.isNotEmpty`
3. 每条标 `V33-10` 起。

## 修复要求
- 改动前 file_read 完整读文件
- 报告写完给 6 行内汇报：动画方案选择、巡检发现数、未做项原因
