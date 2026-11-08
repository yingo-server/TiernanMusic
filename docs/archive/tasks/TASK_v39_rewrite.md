# v3.9 任务书：播放页完全重写（三代理交叉检查）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）与 `docs/v37_perm_playback.md`、`docs/v37_playback_blank_diag.md`。

## ⚠️ 绝对禁止（违反即失败）
- **禁止安装 Flutter SDK / flutter build / flutter test / flutter gen-l10n / dart pub get / 下载任何 SDK tarball**。本沙箱 ARM64 无 Flutter SDK，装了也无法构建；**pubspec.yaml 一行都不许动**
- 只允许 `dart analyze`（/opt/dart/bin），Flutter/三方包符号报错是预期噪音，项目自有类报错即真错误
- **禁止 grep/正则筛选源码**——所有业务相关文件必须 file_read 从头到尾完整阅读
- 禁 git commit/push；只用 file_edit；跨文件改动双向核对（调用方↔被调方）
- **触碰的每个文件收尾前必须 dart analyze 并逐文件贴报告——缺一即失败**
- 禁读 batch1~4 / check_* / 前批报告正文（防锚定）；**QUALITY_STANDARD 与两份排查报告除外**

## 最高优先级：调用的工具与 API 引用的文件必须可控可信
- 只使用项目内已声明依赖（见 pubspec.yaml 只读）、`lib/` 下已存在的 provider/ repository/ widget
- 引用的每个类/方法先 file_read 完整读其定义文件确认签名，**禁止凭记忆猜 API**
- 不引入新依赖、不新增原生通道、不改 AndroidManifest / Kotlin（根因已由主代理修复：MainActivity 改继承 AudioServiceActivity）
- 注释里必须标注依据（文件:行 或官方文档口径），禁止无依据的「应该可以」

## 三个代理分工（**三并发同时运行**）

### 代理①：阅读与契约清点（只读，产出基线文档）
报告 `docs/v39_rewrite_contract.md`
完整读（从头到尾，不许正则筛）：
- `lib/features/player/presentation/full_player_page.dart`、`mini_player.dart`、`queue_sheet.dart`
- `lib/features/player/player_provider.dart`、`play_helper.dart`、`data/audio_handler.dart`、`data/player_repository.dart`、`data/models.dart`
- `lib/features/lyric/presentation/lyric_view.dart`、`data/lyric_repository.dart`
- **评论系统全部**：`lib/features/comment/presentation/comments_page.dart`、`comment_floor_page.dart`、`data/comment_repository.dart` 及其 provider 定义
- `lib/core/router/app_router.dart`、`lib/core/widgets/song_tile.dart`、`lib/core/theme/*.dart`
产出：**契约表**——每个页面消费的 provider 名/类型/字段、每个按钮的 onPressed 目标、每个数据模型字段名与单位（毫秒/秒）、路由参数、评论入口可达链路（为什么现在「没了」）。末尾列「重写必须保留的契约」与「可疑断点」清单。**不改任何代码**。

### 代理②：播放页重写（改代码）
报告 `docs/v39_rewrite_player.md`（实时落盘）
基于代理①的契约表（若运行时对方报告未出，自己完整读同样清单），**完全重写 `full_player_page.dart`**：
- 不复制旧文件的结构，重新组织为清晰的分区：封面/歌词切换、歌曲信息与进度、控制区、功能入口（评论/MV/收藏到歌单/下载/音质/队列）、错误与空态
- 状态来源单一：只 watch `player_provider.dart` 里已存在的 provider；不直接构造 Repository
- **评论入口必须可达**：按契约表里的路由/页面调用，确认按钮真能进 `comments_page.dart`；若旧链路断了，重写时接回
- 三态明确分离：加载中 / 未播放（空态含去首页动作）/ 失败（含重试与原因）/ 正常
- 世代与生命周期：所有异步后 `mounted` 检查；Timer/StreamSubscription/AnimationController 对称释放；build 内零副作用零大对象分配
- 大字号/窄屏布局：LayoutBuilder + Flexible，禁止固定高度 Row 溢出
- 全部用户可见文案走 `context.l10n`，新键 11 语言全补并重跑 `python3 tool/gen_l10n_min.py`
- 输出文件替换前先 file_read 旧文件全文；改完贴 dart analyze 结果

### 代理③：辅助页与评论链路重写（改代码）
报告 `docs/v39_rewrite_aux.md`（实时落盘）
完全读同样清单后，重写/修复：
- `mini_player.dart`、`queue_sheet.dart`：空/加载/失败三态、队列点击世代校验、当前行唯一性
- `comments_page.dart` + `comment_floor_page.dart`：评论入口可达、发送/回复/删除/翻页失败可重试、空态与登录引导
- `play_helper.dart`：hash 缺失不得用 id 冒充、单位显式化、三处 Song 转换合并为单一实现
- 若发现评论 provider 定义缺失或路由缺失，补上（只补项目内已有依赖）
- 同样纪律：三态、mounted、l10n、analyze 逐文件贴报告

## 落盘格式（三份报告统一）
```
### <文件>:<行号> 简述
- 级别/编号：
- 依据：<代码片段或契约表条目>
- 影响/改动：
```
末尾「问题清单」按级别排序。

## 完成后
各代理 8 行内汇报：读了哪些文件（行数）、改了什么/契约结论、analyze 逐文件结果、未做项原因。主代理统一复核、跑 analyze、提交发版。
