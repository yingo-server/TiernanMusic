# v4.0.1 任务书 C-2：接线 + 启动用户态（单代理，窄任务）

先完整读 `docs/TASK_v400_arch.md`（**冻结契约**）与 `QUALITY_STANDARD.md`（33 条）。
基线：`dd53d93` + C-1 代理新建的 `lib/core/prefetch/prefetch_engine.dart`（若运行时该文件尚未落盘，按冻结签名写调用即可，不要自己造模块）。

## 只做三件事（文件边界严格）
1. **`lib/main.dart`**：
   - `openSafe` 列表补 `await openSafe('resource_json', stringValues: true);`（B 模块 ResourceCache 的 Hive 箱；init 幂等但开箱避免首启竞态）
   - 首帧后启动预热：从 `homeDataProvider`（先完整读定义）拿首页所有类型歌曲 + 收藏歌单歌曲，调 `PrefetchEngine.instance.enqueueSongs(...)`（100ms/个）
   - 主动触发用户态检查：`authStateProvider` 的 restoreSession 是否首帧就跑（核对，不重复造），用户态落定后账号卡昵称/头像即时显示（三态明确：加载中/未登录/已登录）
2. **`lib/features/player/data/audio_handler.dart`**：
   - 队列变化/切歌时调 `PrefetchEngine.instance.updateUpcoming(_songs, _index, window: 15)`
   - 播放完成（`processingState == completed`）分支调 `PrefetchEngine.instance.onPlaybackCompleted(url, 'audio')` 永久缓存实际文件（URL 从当前播放 source 取；取不到则跳过并留痕）
   - `dispose` 里调 `PrefetchEngine.instance.dispose()`（若属 App 级单例则只取消 pending，不销毁全局——按第 20 条对称）
3. **`lib/core/theme/settings_provider.dart` 或设置页清缓存入口**（先定位实际文件）：
   - `ResourceCache.instance.clearJson()/clearLists()` 接入；实际文件永久缓存**不随清缓存删除**（UI 注明）

## 播放列表暗病核查（只读，产出表，不改超出上述范围）
完整 file_read：`audio_handler.dart`、`player_provider.dart`、`queue_sheet.dart`
逐项核对并报告（发现 P0/P1 才修，且只修上述三个文件内）：
- 队列替换/切歌/自动下一首的世代与闸门
- `retryPendingPlayback` 在队列被换后按旧 idx 播新队列错歌（主代理已标记为 P1 疑点）
- 循环/随机边界、单曲/空队列
- 订阅/Controller 对称释放

## ⚠️ 硬性规则
- **绝对禁止**：装 Flutter SDK / flutter 命令 / dart pub get / 下载 SDK / **改 pubspec.yaml 一行**
- 只改列出的文件；禁 git commit/push；只用 file_edit；标 V401-C2-xx
- 允许 dart analyze；Flutter/三方符号噪音、**项目自有类真错误**；Icons.* 必须验证存在
- 业务文件完整 file_read 禁止 grep 筛；**触碰文件收尾前 analyze 并逐文件贴结果**
- 跨文件双向核对；i18n 新键 11 语言全补 + 重跑 `python3 tool/gen_l10n_min.py` 贴输出
- 报告 `docs/v401_fix_c2.md` 实时落盘

## 完成后
6 行内汇报：三处接线、用户态显示、暗病表条目数、analyze 逐文件结果、l10n 输出、未做项原因。
