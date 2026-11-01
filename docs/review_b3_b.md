# 批3检2：UI 主题一致性与 Material 3 规范审查（纯读）

基线：commit `db7bafc`，工作目录 `/var/minis/workspace/TiernanMusic`
范围：app_theme.dart、3 个 core/widgets、13 个页面（共 17 个文件，全部从头到尾读完）
结论概览：**无编译阻塞、无功能级 UI 失效**。控件选型（SearchBar / FilterChip / SegmentedButton / PopupMenu / SwitchListTile / ExpansionTile / TabBar）大面积符合 M3 规范；问题集中在「低对比度 alpha 文字」「少量语义误用」「死代码 _GlowShadows」与若干一致性小瑕疵。

---

## 一、问题清单（按严重度排序）

### 【体验瑕疵】

**P1. 收藏歌单误用「危险操作确认框」**
- `lib/features/playlist/presentation/playlist_detail_page.dart:331`（`_collectPlaylist`）
- 问题：「收藏」是**非破坏性**操作，却复用 `showDestructiveConfirm` —— 用户会看到一个 `Icons.warning_amber_rounded` + **error 红色确认按钮**的对话框来"收藏"，语义完全相反，且每次点击都多一步无意义确认。
- 修法：收藏不需要确认，直接执行；若确要确认，用普通 AlertDialog，确认按钮保持默认 primary 色，图标换成 `Icons.favorite_border`：

```dart
Future<void> _collectPlaylist(
    BuildContext context, WidgetRef ref, PlaylistDetail detail) async {
  try {
    await ref.read(_playlistRepoProvider).collectPlaylist(
          name: detail.name,
          listCreateGid: detail.id,
        );
    if (context.mounted) {
      Toast.show(context, context.l10n.collectSuccess);
    }
  } catch (e) {
    if (context.mounted) {
      Toast.show(context, context.l10n.operateFailed('$e'));
    }
  }
}
```

**P2. 楼中楼未登录时发送按钮是「死按钮」**
- `lib/features/comment/presentation/comment_floor_page.dart:280`
- 问题：`onPressed: _isLoggedIn ? _send : () {}` —— 未登录点击发送**无任何反馈**（静默吞掉）。同文件对比：comments_page.dart:388 的同位按钮是 `() => context.push('/login')`，两页行为不一致。
- 修法：

```dart
IconButton.filled(
  tooltip: context.l10n.send,
  onPressed: _isLoggedIn ? _send : () => context.push('/login'),
  icon: const Icon(Icons.send),
),
```

**P3. 登录页 QR 轮询的 `active` 参数从未传入，切 Tab 不暂停轮询**
- `lib/features/auth/presentation/login_page.dart:126-129`（TabBarView children）
- 问题：注释声称"让 QR Tab 通过 active 参数启停轮询"，`didUpdateWidget` 也实现了启停逻辑（:489-500），但构造时**从未传 `active`**，`_QrLoginTab` 恒为默认 `active: true`。切到短信/密码 Tab 后二维码仍每 3 秒轮询一次（`_pollOnce` 只检查 `widget.active`，永远为 true）。
- 修法：在 `_LoginPageState` build 中把当前模式传下去：

```dart
children: [
  _SmsLoginTab(onSuccess: _onLoginSuccess),
  _PasswordLoginTab(onSuccess: _onLoginSuccess),
  _QrLoginTab(
    onSuccess: _onLoginSuccess,
    active: _mode == _LoginMode.qr,
  ),
],
```

**P4. 深色模式低对比度：大量 `onSurface.withValues(alpha: 0.4~0.6)` 次要文字**
- 代表位置（同类约 12 处）：
  - `lib/core/widgets/song_tile.dart:113`（歌手 0.6）、`:157`（时长 0.5）
  - `lib/features/comment/presentation/comments_page.dart:478`（时间 0.4）、`:494-501`（点赞数 0.4）
  - `lib/features/comment/presentation/comments_page.dart:226`（"没有更多" 0.4）
  - `lib/core/widgets/song_tile.dart:614`（技术详情 0.45）
- 问题：深色模式下 onSurface≈白色，0.4 alpha 压在深色 surface 上约为 21% 不透明度，实际对比度明显低于 WCAG 4.5:1（对 bodySmall 这类小字号尤其吃亏）。M3 规范的次要信息应使用 `onSurfaceVariant`（深浅两套主题都已调好）。
- 修法（统一替换模式）：

```dart
// 前
color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
// 后
color: theme.colorScheme.onSurfaceVariant,
```

**P5. GradientChip：白字压浅色渐变，浅色模式对比不足**
- `lib/core/widgets/song_tile.dart:393-411`
- 问题：`HSL fromAHSL(1, hue, 0.65, 0.5)` 生成的中间色调亮度 0.5，白色文字对比度只有约 2.5~3:1（低于 3:1 大文本标准），热搜词条在浅色模式下部分色相（黄/青）几乎看不清。颜色压在装饰性渐变上属于允许的硬编码（见审查点 11），但对比度仍需兜底。
- 修法：压低亮度保证白字可读：

```dart
static HSLColor _hue(int i) =>
    HSLColor.fromAHSL(1, (i * 47.0) % 360, 0.65, 0.42);
```

（或对 label 用 `Colors.white` + 给 Ink 加一层 `Colors.black.withValues(alpha: 0.15)` 叠加。）

**P6. 楼中楼删除按钮缺 error 色，与全局危险操作视觉约定不一致**
- `lib/features/comment/presentation/comment_floor_page.dart:243-252`
- 问题：删除自己回复的 trailing IconButton 用默认色，而 comments_page 的删除菜单项、download_page 的 `_menuItem(destructive: true)` 都是 error 红。M3 危险操作应统一 error 色强调。
- 修法：

```dart
trailing: (_isLoggedIn && c.isMine)
    ? IconButton(
        icon: Icon(Icons.delete_outline,
            size: 20, color: Theme.of(context).colorScheme.error),
        tooltip: context.l10n.delete,
        onPressed: () => _deleteComment(c),
      )
    : null,
```

### 【代码质量】

**Q1. `_GlowShadows` 是死代码，且浅色主题下若被使用会直接抛异常（审查点 15）**
- `lib/core/theme/app_theme.dart:275-277, 284-303`
- 现状：`extensions: [if (isDark) const _GlowShadows()]` 只在深色注册；全仓 `rg` 确认**没有任何调用方**（无 `Theme.of(context).extension<_GlowShadows>()` / `coverGlow` 使用点）。目前安全，但一旦有人按其注释意图使用 `coverGlow`，浅色模式下 `extension<_GlowShadows>()` 返回 **null**，对非空返回值取 getter 会崩溃（`The method 'coverGlow' was called on null` 类似空指针），且 lerp 无法从深色平滑过渡。
- 修法：要么删掉，要么改为两套主题都注册（浅色给空阴影/普通阴影）：

```dart
extensions: <ThemeExtension<dynamic>>[
  _GlowShadows.forBrightness(isDark),
],

class _GlowShadows extends ThemeExtension<_GlowShadows> {
  const _GlowShadows(this.coverGlow);
  final List<BoxShadow> coverGlow;

  factory _GlowShadows.forBrightness(bool isDark) => isDark
      ? const _GlowShadows([BoxShadow(
          color: Color(0x3300D4FF), blurRadius: 24,
          spreadRadius: -4, offset: Offset(0, 8))])
      : const _GlowShadows([]);
  // lerp 保留 this 实现（阴影不做插值也可，浅深切换为瞬时变化）
}
```

**Q2. 图标风格混用（审查点 12）**
- 例：`Icons.search`（home_page.dart:75、search_page.dart:103）vs `Icons.album_outlined`/`Icons.movie_outlined`；`Icons.music_note`（song_tile.dart:163、download_page.dart:146）vs `Icons.music_note_rounded`（full_player_page.dart:500、mini_player.dart:170）；`Icons.person`（comments_page.dart:461）vs `Icons.person_outline`/`person_rounded`。同一语义在不同页面用 outlined / filled / rounded 三种变体，Material 3 建议同一层级统一（导航与正文图标统一 outlined，播放控件统一 rounded）。属一致性打磨项，逐处替换即可，无功能影响。

**Q3. 设置页 API 编辑框绕过了主题的圆角/填充体系**
- `lib/features/settings/presentation/settings_page.dart:593`
- `decoration: const InputDecoration(hintText: 'https://…', border: OutlineInputBorder())` —— 显式 `border` 覆盖了主题的 `radiusInput(16)` + 无边框样式，这个输入框呈现为 4px 默认圆角描边框，与登录页/评论输入框不一致。
- 修法：删掉 `border: OutlineInputBorder()` 一行，交给 `inputDecorationTheme`。

**Q4. `radiusButton = 24` token 从未使用**
- `lib/core/theme/app_theme.dart:25`。按钮实际用 `StadiumBorder()`（全圆角），token 成死定义。建议删除该常量，或把注释改为"按钮统一 StadiumBorder，无固定半径"避免后人误用。

**Q5. 未本地化/未走 theme 的零散样式**
- `lib/features/player/presentation/full_player_page.dart:500`：`Icon(..., color: Colors.grey)`（封面占位）—— 应用 `onSurfaceVariant` 或 alpha 形式的 onSurface；
- `lib/features/comment/presentation/comment_floor_page.dart:173`：AppBar 标题直接放"回复数"，建议 `context.l10n.replies` + 标题内嵌数字的现成 l10n（与 comments_page 标题 `Text(context.l10n.comments)` 风格对齐）；
- `lib/features/mv/presentation/mv_player_page.dart`：`title: widget.title ?? 'MV'` 的 `'MV'` 是硬编码兜底文案（可接受，建议走 l10n）。
- 除此之外：**全部 17 个文件未发现硬编码 fontSize 压在业务代码上**（仅 theme 定义本身有 22/13/12 等规范值），文字全部走 `textTheme.*` token ✅。

---

## 二、通过项（逐条对应审查点）

### A. 控件选择
1. **搜索用 SearchBar ✅** search_page.dart:99-124 用 `SearchBar`（leading 搜索图标 + trailing 清除按钮 + tooltip），未在 AppBar 塞 TextField；`searchBarTheme`（app_theme.dart:90-107）正确使用 `WidgetStatePropertyAll<TextStyle?>`（避免了已知的类型陷阱）。
2. **筛选/切换控件 ✅** 热搜榜切换用 `FilterChip`（search_page.dart:332-352，带 selected 态）；主题模式/歌词模式/登录方式用 `SegmentedButton`（settings_page.dart:244、:336，login_page.dart:107）；搜索结果五分类用 `TabBar` + `TabBarView`（search_page.dart:415-447）。
3. **按钮三级 ✅** 主操作 FilledButton（播放全部 playlist_detail:240、登录 login:362、下载全部 download_sheet:124）；次操作 OutlinedButton.tonal（MV/评论入口 full_player:244-290、加载更多 playlist_detail:318）；辅助操作 TextButton/tonal（发送验证码 login:352）。层级分明。
4. **列表项多操作收 PopupMenu ✅** SongTile 的 `SongTileMenuItem` + `PopupMenuButton`（song_tile.dart:137-176）；下载管理页 `_menuItem(destructive:)` 模式（download_page.dart:83-104）；评论的回复/删除菜单（comments_page.dart:524-548）。无"一排 IconButton"反例。
5. **SwitchListTile ✅** settings_page.dart:358-370，label 左 / 开关右，带 `secondary` 图标。另外 switchTheme 统一了 thumb 的 check/close 图标（app_theme.dart:246-255）。
6. **危险操作 ✅** 统一走 `showDestructiveConfirm`（confirm_dialog.dart）：warning 图标 error 色 + 取消/FilledButton(error 底) 双动作；调用点覆盖清空历史、清空最近播放、清缓存、清空下载、删除评论/下载。设置页"清空缓存" ListTile 也用 error 色文字强调（settings_page.dart:495-505）。
7. **ExpansionTile ✅** 歌单简介 playlist_detail.dart:165-199 用 `ExpansionTile`（subtitle 两行预览 + 展开全文），无自定义展开按钮。

### B. 视觉一致性
8. **圆角体系 ✅（基本）** token 集中定义：卡片 20 / 输入 16 / 小组件 12（radiusSmall）；按钮全圆角 StadiumBorder；SearchBar/SearchView/BottomSheet top 28 符合 M3 大圆角。个别横向卡片用 16（banner、歌单封面）属封面媒体类圆角，可接受但建议后续并入 token（如 `radiusCover = 16`）。
9. **间距 ✅** 16 页边距贯穿（各 ListView/Padding horizontal:16），8/12/16/24 层级在 SizedBox 间距中一致出现；骨架屏尺寸与实际内容逐项对齐（home_page.dart:530-560 注释明确对齐 180/150/56 等）。
10. **文字 token ✅** 见 Q5；业务代码 0 处硬编码 fontSize。
11. **颜色 token ✅（含允许的例外）** 硬编码色仅出现在图片/渐变之上：排行榜卡片白字压 black87 渐变（home_page.dart:455-464）、歌单计数角标白字压 black54（library_page.dart:403-415）、MV 播放器全套白字压黑色视频背景（mv_player_page，合理——视频页独立于主题色系）。渐变色 Hue 生成逻辑与 GradientChip 一致（同一 HSL 模式）。
12. **图标一致性**：tooltip 覆盖率非常高——所有 IconButton / FloatingActionButton / PopupMenuButton 均带 tooltip（含 MV 返回、播放队列、发送、密码可见切换），✅；outlined/filled 混用见 Q2。

### C. 深浅色适配
13. 低对比度问题见 P4（已列出修法）；其余深色场景（surfaceContainer 层级、errorContainer 0.5 alpha 的 ErrorRetry 图标底）对比充足。
14. **浅色"白压白"隐患 ✅ 已排查**：白字只出现在黑渐变（rank 卡、FlexibleSpaceBar 标题带 black54 shadow，playlist_detail:127-131）、black54 角标、白色二维码容器内（login QR 容器固定白底但内容是二维码本身，`Colors.white` 属必要）、MV 全黑背景。无白压白风险。
15. `_GlowShadows` 见 Q1 —— 当前无调用方，浅色下不会崩；但注册机制（仅深色）+ 私有类型使其成为一次性陷阱，建议按 Q1 修法处理。

### D. 动效与交互
16. **页面切换 ✅** app_theme.dart:267-271：Android 用 `FadeForwardsPageTransitionsBuilder`（M3 Expressive 风格）、iOS 用 `CupertinoPageTransitionsBuilder`，且用 `show` 精确 import 避免 cupertino/material 歧义（文件头注释正确指出了 material 不导出该类的问题）。
17. **涟漪/长按/悬停 ✅** 全局 `InkSparkle.splashFactory`；SongTile/MiniPlayer 支持长按次级入口（MiniPlayer 长按开队列，且有显式按钮兜底——hidden gesture 不唯一 ✅）；InkWell 均带 borderRadius 与 Material 包裹。
18. **Hero ✅** `tag: 'album-art'` 仅 mini_player（:63）与 full_player（:404）两处，路由 push 时二者不同时在树上重复（mini 在 shell、full 在被 push 路由，正是 Hero 的标准配对）；FAB 用独立 `heroTag: 'play-pause-fab'` 避免与默认 FAB tag 冲突。无 tag 冲突。
19. **无障碍**：tooltip 全面覆盖（朗读可达）；文本均 `maxLines + TextOverflow.ellipsis`（17 文件无一处无约束长文本）；EmptyState 用 LayoutBuilder 兼容有限/无限高度；Shimmer 支持 `enabled:false` 降级静态（reduced-motion 友好）。可改进项：Banner 轮播/进度类组件未加 `Semantics` 标签，SkeletonText 等装饰元素未 `ExcludeSemantics`，属增强项非缺陷。

---

## 三、总评
主题层（app_theme.dart）设计质量高：形状/动效 token 集中、SearchBar 主题的 WidgetStateProperty 细节、chipTheme 不覆盖 label 状态色的注释都对 M3 有准确理解。页面层控件选型几乎全部命中规范反模式清单的正确答案。需要动手的只有 6 个体验瑕疵（P1-P6，其中 P1/P3 最值得先修）和 5 个代码质量项（Q1-Q5），均为局部小改。
