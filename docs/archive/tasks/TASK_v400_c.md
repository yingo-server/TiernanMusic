# v4.0 代理 C：预加载引擎 + 启动用户态 + 播放队列深度检查

先完整读 `docs/TASK_v400_arch.md`（**冻结契约**）、`QUALITY_STANDARD.md`（33 条）。

## 角色与文件边界（严禁越界）
独占新建/修改：
- `lib/core/prefetch/**`（新建）
- `lib/main.dart`、`home/presentation/home_page.dart`、`library/presentation/library_page.dart`、`player/player_provider.dart`、`player/data/audio_handler.dart`、`player/presentation/queue_sheet.dart`
不改：arb/lyric_view/两个播放页文案（A）、`core/resource/**`/6 repository/translate_api（B）、pubspec/Manifest/Kotlin。

## ⚠️ 共同纪律（见契约）
ARM64 无 Flutter：禁装 SDK/flutter/pub get/下载 tarball；**pubspec 一行不许动**；只允许 dart analyze；Flutter/三方符号噪音、**项目自有类真错误**；业务文件完整 file_read 禁止 grep 筛源码；触碰文件收尾 analyze 逐文件贴报告——缺一即失败；跨文件双向核对；禁 git commit/push；只用 file_edit；标 `V400-C-xx`；报告 `docs/v400_fix_c.md` 实时落盘。

## 任务 C1：`lib/core/prefetch/prefetch_engine.dart`（按冻结契约）
```dart
PrefetchEngine.instance.enqueueSongs(songs, {spacing=100ms});
PrefetchEngine.instance.updateUpcoming(queue, currentIndex, {window=15});
```
- 启动预热：main.dart 首帧后，从 `homeDataProvider`（先读定义）拿首页**所有类型**歌曲 + 收藏歌单歌曲，按 100ms/个入队，请求 `CachedApiCall.get('/v5/url'...)` 与歌词（走 B 的 `ResourceCache.json`，**不下载实际文件**）
- 队列未来 15 首：`updateUpcoming` 在队列变化/切歌时调用，URL+歌词+封面 JSON 预请求，去重（同 hash 不重打）
- **不阻塞首帧、不与缓存冲突**：所有请求走缓存；已命中 168h 缓存的直接跳过
- 完整播放的歌曲：audio_handler 播放完成分支调 `ResourceCache.cacheUrlFile(url, 'audio')` 把实际文件永久缓存（B 提供实现，按冻结签名调用）；MV/KRC/封面同理在各自加载处（若越界则在报告写明由 B 侧补）

## 任务 C2：启动主动检查用户态并显示
用户反馈「打开软件不会主动检查用户态并显示」。
- 完整读 `main.dart`、`auth_providers.dart`、`auth_repository.dart`、`library_page.dart`
- 落地：首帧后主动 `authStateProvider` 恢复（已有 restoreSession，核对是否**主动触发**而非等页面 watch）；状态落定后账号卡/昵称/头像立刻显示（stale-while-revalidate 已在 v3.9.9 B1 做，核对覆盖启动路径）
- 用户态检查失败/未登录/已登录三态在 UI 明确（第 16 条）

## 任务 C3：播放列表深度检查（暴露暗病）
完整 file_read：`audio_handler.dart`、`player_provider.dart`、`queue_sheet.dart`、`play_helper.dart`、`home_page.dart`、`library_page.dart`
逐项核对并修复（每条给证据+修法）：
- 队列替换/切歌/自动下一首的世代与闸门（`_playToken`/`_loading`/`_pendingIndex` 全链）
- 队列点击与自动切歌竞态
- 循环/随机模式边界（单曲、空队列、shuffle 时 upcoming 顺序）
- 播放失败后的队列推进（不跳过、不无限循环）
- 播放队列与预加载去重、与缓存 key 的用户维度一致性
- 生命周期：订阅/Controller 对称释放
- 报告里列「发现的暗病 → 修法 → 证据」表

## 任务 C4：设置页清缓存接入（若属你边界内）
`clearJson()` / `clearLists()`（B 提供）接入清缓存按钮；实际文件永久缓存不随清缓存删（用户要求「资源文件永久缓存」）——在 UI 注明。

## 完成后
8 行内汇报：预热触发链、upcoming 补充逻辑、用户态显示、播放列表暗病数、analyze 逐文件结果、未做项原因。
