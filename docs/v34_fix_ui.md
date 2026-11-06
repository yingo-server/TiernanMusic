# v3.4 修复②：UI 专档 P2 条目修复（代理产出 + 主代理补验）

基线 ac188b2。纪律：每处改动前完整 file_read；只 file_edit；analyze 过滤缺包噪音。

## 修复记录

### V34-UI-01 收藏任务流断点（P2，最高价值）
- 新建 `add_to_playlist_sheet.dart`：歌单选择弹层（用户歌单+新建），失败文案区分
  「确定失败/可能已生效」（第 9/21 条）；未登录给登录引导（第 16 条）
- `full_player_page.dart`：「更多」菜单新增 addToPlaylist（激活死键）
- `search_page.dart`：SongTile menuItems 新增项——**代理 stash 回退后丢失，
  主代理补验发现并补回**（含分支与弹层调用）

### V34-UI-02 captcha_page i18n（P2）
- 全页硬编码中文改 context.l10n（17 新键），'$e' 直出改友好文案+debugPrint（第 30/9 条）

### V34-UI-03 arb 未翻译键（P2）
- 12 个 arb：previewOnly/loginRequired* 等 4 键补全 10 语言

### V34-UI-04 假开关移除（P2）
- settings_page 两个「（预留）」SwitchListTile + settings_providers 两 Notifier 删除
  （第 32 条死代码零容忍，grep 确认无消费方）

### V34-UI-05 登录成功返回来源页（P3）
- context.go('/home') → Navigator.pop()（pop 不可行回落 /home）

### V34-UI-06 cookie 过期引导（P3）
- 库页 error 分支传 ErrorRetry(error:)，错误分类给出重新登录出口（第 16 条）

### V34-UI-07 空态动作（P3）
- 歌词空态 lyricEmptyGuide（纯音乐/未收录说明）；下载空态 downloadEmptyGuide（第 30 条）

### V34-UI-08 库页 MV 收藏空态（P3）
- mvCollectGuide 引导 + hash 空 MV 点击 Toast mvUnavailable（第 9 条）

### 清单 9（P3 尽力而为）
- download_page：viewFolder 失败兜底 Toast；行点击打开失败 Toast

## dart analyze
每个触碰文件均跑过（报告见代理输出）：修复 2 处编辑残留语法错误（captcha/search），
无新增真实错误；settings_page invalid_assignment 为基线遗留非本次引入。

## i18n 齐全性
主代理程序化校验：app_zh_CN.arb 328 键 × 10 语言逐键比对——**全部齐全无缺失**。

## 未修项（时间预算耗尽，留 v3.5 批次消化）
mini_player 按钮挤压、queue_sheet 自动滚动、search 静默跳转、playlist_detail
播放全部/收藏态、comments Chip、comment_floor 死按钮、download_sheet MV 预判、
l10n 单复数语义迁移。
