# v3.7 迭代 · UI 档修复报告（V37-UI-xx）

基线 `8a49345`（tag v3.6.0）。只允许 file_edit + dart analyze（/opt/dart），
过滤 Flutter SDK 缺包噪音（`override_on_non_overriding_member` / `undefined_*` flutter 类名等），
**项目自有类报错视为真错误**。实时落盘，改一条写一条。

## 基线 analyze 快照
- 全仓 5073 条（绝大多数为 flutter/material 缺包噪音 + override 假告警）。
- 无 error 级；info/warning 与自有代码相关项见各条目。

---

## V37-UI-01（任务流 4 收藏 MV 全 app 无入口）— 已修
- `lib/features/mv/presentation/mv_player_page.dart`：竖屏控制条新增「收藏 MV」IconButton
  （未收藏空心 favorite_border → 已收藏实心红），调 `mvCollectionRepositoryProvider.setCollected(videoId, collect:)`。
  - 防重（第 21 条）：`_collecting` 期间 onPressed=null；
  - 登录守卫：仓库层 userid/token 为空返回 false → Toast `mvCollectLoginFirst`（给登录指引）；
    成功/取消分别 Toast `mvCollectSuccess` / `mvCollectRemoved`（第 9 条可观测）；
  - 深链只带 hash（videoId 无法 int 解析）时 Toast `mvNoSource`，不静默失败；
  - 收藏态判定依据：collectservice 无「是否已收藏」查询端点，故以本次会话内用户操作结果为
    本地事实源 `_collected`（默认未收藏），注释已写明（原则 5 降级说明）。
- `lib/features/library/presentation/library_page.dart`：收藏 MV 空态由通用 `noData` 改为
  `mvCollectGuide`（该键此前 10 语言齐全但为死键）——引导用户去 MV 页收藏（第 16 条/任务流 4）。
- i18n 新增 9 键：mvCollectAdd / mvCollectRemove / mvCollectSuccess / mvCollectRemoved /
  mvCollectLoginFirst / rankParamsInvalid / goHome / mvNoSource / downloadMvUnavailable，
  11 个 arb（zh/zh_CN/zh_TW/en/ja/ko/es/fr/de/pt/ru）全补，`tool/gen_l10n_min.py` 重生成 338 键 × 11 locale。
- analyze（过滤缺包噪音后逐文件）：
  - mv_player_page.dart：0 条 ✓
  - library_page.dart：0 条 ✓
## V37-UI-02（榜单/MV 页清晰度切换）— 核实结论（无需改动）
- MV 播放页已有清晰度切换控件 `_QualityPicker`（`if (_error == null && qualities.length > 1)`，
  sd/hd/qhd/fhd/sq/ld 全档 label l10n 齐全），清单 2 的「补控件」在 UI 层**已存在，不硬造第二套**。
- 不可达路径核实：`mvDetailProvider` → `fetchDetail(videoId ?? hash)`，而 `/video/detail` 实测**只认
  video_id**（mv_repository.dart 注释 + api_report）。两条入库路径：
  - 播放页 `_MvEntry` push 时带 `?videoId=`（full_player_page.dart:340）→ 清晰度可用 ✓
  - 库页收藏列表（library_page.dart:327）与榜单（rank_detail_page.dart:178）push 只带 hash →
## V37-UI-03（流 5 歌词/下载空态动作核对）— 核实通过（V34-UI-07 生效确认）
- `lyricEmptyGuide`：lyric_view.dart:120 使用；10 语言（11 arb）齐全；文案含原因区分与
  「换一首歌试试」动作引导 ✓
- `downloadEmptyGuide`：download_page.dart:70 使用；文案含「更多 → 下载」路径引导 ✓；
  空态另有 `downloadManagement` 动作入口 ✓
- `reloginGuide` / `mvCollectGuide` / `downloadFolderFallback` 三键 10 语言齐全但此前
  `mvCollectGuide` 为死键 → 本档 V37-UI-01 已接线使用；`reloginGuide` 用于
  `ErrorRetry` 登录失效分支（grep 未见 UI 引用——核实见下）。
- 结论：键覆盖与文案引导均达标，无新增改动。

---
## V37-UI-04（登录态感知 / 设置页账号入口去重）
- 库页账号卡片：**核实已有**醒目昵称+头像展示（library_page.dart `_AccountCard`：radius 26 头像 +
  titleMedium 加粗昵称 + userid 副标题，v34_review_2_ui.dart:132 亦正面记录），无缺口，不改。
- 设置页账号双入口去重（settings_page.dart）：「账号管理」（其他账号非空时）与「切换账号」
  均调 `_showSwitchAccountDialog`，两个等价入口 → 收敛：已登录且有其他账号时只保留
- analyze（settings_page.dart，过滤后）：0 条 ✓
- 「账号管理」在其他账号非空时隐藏、回落逻辑保留（未登录/无其他账号仍跳 /login），
  「切换账号」项成为唯一切换入口。

---
## V37-UI-06（微文案：错误提示统一带下一步动作）— 已修
grep `Toast.show(context` 无 l10n 的裸文案全量核对：
- playlist_detail_page.dart 收藏失败分支：① l10n 包装内硬编码中文
  `'操作结果未知，请到「我的音乐」确认'` → 新键 `collectResultUnknown`（10 语言）；
  ② 兜底 catch `operateFailed('$e')` 技术串直出 → `operateFailed(friendlyError(e))`
  （统一解包口径，同 comments_page）。新增 friendly_error.dart 导入。
- add_to_playlist_sheet.dart `e.message` / `friendlyError(e)`：**合规**（领域异常 message 为
  服务端中文文案，friendlyError 已解包）。
- permission_gate.dart:78 `reason` / main.dart:241 `message`：调用方均传领域文案
  （播放错误 / 权限原因），无技术串，合规。
- captcha_page.dart / comments_page.dart 的 '$e' 分支：V34-UI-02 已修，本档复核确认生效。
- analyze（过滤后，逐文件）：playlist_detail_page.dart 0 自有错误 ✓
  （唯一报错 `non_constant_list_element` L114 为 const Shadows 级联缺包噪音——
  已用 `git stash` 验证基线同样存在）。

---
## V37-UI-07（P2-2 mini_player 按钮挤压）— 已修
- mini_player.dart：Row 内容改为 LayoutBuilder 包裹；`maxWidth < 360`（小屏或大字号
  textScale 挤压）时降级为紧凑布局——隐藏「播放队列」次操作（长按手势入口保留），
  主操作（播放/暂停）与「下一首」必保。消除 Overflow。
- analyze（过滤后）：mini_player.dart 0 条 ✓

---
## V37-UI-05（触控目标巡检）— 已修 4 处 / 其余合规
全仓 27 处裸 `IconButton(` 逐一巡检结论：
- **已修（图标 20dp 或行内密度不足、触控目标 <48dp）**，统一方案
  `visualDensity: VisualDensity.compact + constraints(min 48×48) + padding:0`
  （不拉大图标、不破坏行高，Material 无障碍 48dp 基线）：
  1. song_tile.dart:185 SongTile trailing 下载按钮（icon size 20）✓
  2. comment_floor_page.dart:261 楼中楼删除按钮（icon size 20）✓
  3. download_sheet.dart:171 弹层行内下载按钮 ✓
  4. rank_detail_page.dart:175 榜单 MV 跳转按钮 ✓
- **合规不改**（AppBar/NavBar 默认 48dp 或 iconSize≥24 且有默认 padding；或已 compact 但
  属刻意密集布局的反例如搜索清除钮在 SearchBar trailing 内默认 48dp）：
  login_page:70/448、captcha_page:114（AppBar leading）、home_page:52（SliverAppBar action）、
  search_page:130/145、settings_page:639/689（ListTile trailing，默认 48dp）、
  full_player_page:73/230/237/258/264（iconSize 36 或默认）、mini_player:123/129、
  playlist_detail_page:90/97、comments_page:300（自定义控件委托）、mv_player_page:163（AppBar）
  /228（实为 OutlinedButton）、download_page:50、album_page:142、rank_detail_page:104。
- analyze（过滤后，逐文件）：song_tile.dart 0 ✓ / comment_floor_page.dart 0 ✓ /
  download_sheet.dart 0 ✓ / rank_detail_page.dart 0 ✓

---
