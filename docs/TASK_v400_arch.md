# v4.0 架构契约（三代理共享，主代理裁定；任何代理不得单方面改这些签名）

## 目标
把「API 调用 → 缓存 → 预加载」聚合到 `lib/core/resource/` 与 `lib/core/prefetch/` 两个模块，repository 只表达业务意图，缓存策略与预加载在模块内完成（用户建议采纳，控制范围：本期接入 6 个高频 repository，其余给迁移清单，不强改 13 个）。

## ⚠️ 所有代理共同纪律
- 本沙箱 ARM64 无 Flutter SDK：**禁装 SDK / flutter 命令 / dart pub get / 下载 tarball**；**pubspec.yaml 一行不许动**；禁改 AndroidManifest/Kotlin
- 只允许 `dart analyze`（/opt/dart/bin）；Flutter/三方符号报错是预期噪音，**项目自有类报错即真错误**；**Icons.* 常量也必须验证存在**（v3.9.10 连错 2 轮图标名）
- 业务相关文件必须 file_read 从头到尾完整阅读，**禁止 grep/正则筛源码**
- **触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**
- 跨文件改动双向核对（调用方↔被调方签名逐一对）；禁 git commit/push；只用 file_edit；改动标 `V400-x-xx`
- 只使用项目内已存在且已读定义确认签名的类/方法；i18n 新键 11 语言全补 + 重跑 `python3 tool/gen_l10n_min.py` 贴输出
- 报告实时落盘（改一条写一条），禁读前批报告正文（QUALITY_STANDARD.md 与本契约除外）
- 定时器 55 分钟（代理预算 60 分钟），到点收尾不让产出丢失

## 模块一：`lib/core/resource/`（**代理 B 独占创建/修改**，A/C 只调用不改）

### 文件
- `resource_cache.dart`：统一缓存（JSON / 文件 / in-flight 合并 / 失效回退）
- `cached_api.dart`：CachedApiCall —— repository 复用的聚合入口
- `lyric_translation_stream.dart`：翻译增量广播

### 冻结签名（B 必须按此实现，A/C 按此调用）
```dart
// TTL 常量
const kJsonTtl = Duration(hours: 168);     // 一切 API 返回的 JSON
const kListTtl = Duration(seconds: 90);    // 本次启动的首页/歌单列表
const kFilePermanent = null;               // 实际资源文件永久

class ResourceCache {
  static final instance = ResourceCache._();

  /// JSON 缓存：命中直接返回；未命中 fetch；fetch 失败时若有旧值返回旧值（失效回退）
  /// 并发：同 key 的 in-flight 请求合并为一个（歌词重复请求的根治）
  Future<Map<String, dynamic>> json(
    String key,
    Future<Map<String, dynamic>> Function() fetch, {
    Duration ttl = kJsonTtl,
    bool staleOnError = true,
  });

  /// 实际资源文件永久缓存（音频/MV/KRC/封面字节），失效回退由调用方走网络
  Future<void> putFile(String key, List<int> bytes);
  Future<List<int>?> file(String key);           // 永久，不淘汰
  Future<String?> filePath(String key);          // 内部缓存目录绝对路径

  /// 从 URL 下载并永久缓存（Dio，4KB 以上大文件流式），已存在直接返回路径
  Future<String?> cacheUrlFile(String url, String kind);

  void clearJson();        // 设置页清缓存
  void clearLists();       // 仅 90s 列表
}

/// repository 聚合入口：代替散落的 _api.get + MemoryCache
class CachedApiCall {
  CachedApiCall(this._api);   // KugouApiClient（只读定义确认）
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query, Duration? ttl});
  Future<Map<String, dynamic>> post(String path, dynamic data, {Map<String, dynamic>? query, Duration? ttl});
}

/// 翻译增量：每批译文完成即广播，UI 实时插入（不等整批）
class LyricTranslationStream {
  static final instance = LyricTranslationStream._();
  Stream<LyricTranslationPatch> get patches;
  void emit(LyricTranslationPatch p);
}
class LyricTranslationPatch {
  const LyricTranslationPatch(this.lyricId, this.startIndex, this.values);
  final String lyricId;
  final int startIndex;
  final List<String> values;
}
```

## 模块二：`lib/core/prefetch/`（**代理 C 独占创建/修改**）

```dart
class PrefetchEngine {
  static final instance = PrefetchEngine._();
  /// 启动预热：首页所有类型歌曲 + 收藏歌单，按 spacing 逐个入队（默认 100ms）
  void enqueueSongs(Iterable<Song> songs, {Duration spacing = const Duration(milliseconds: 100)});
  /// 播放队列未来 window 首（默认 15）：URL/歌词/封面，队列变化时自动补充、去重
  void updateUpcoming(List<Song> queue, int currentIndex, {int window = 15});
  void dispose();
}
```
预加载只走 `ResourceCache.json`（缓存 URL/歌词/封面 JSON），**不下载实际文件**；实际文件永久缓存由「完整播放完成」hook 触发 `ResourceCache.cacheUrlFile`（C 在 audio_handler 播放完成分支调用，B 提供实现）。

## 文件边界（严禁越界）
| 代理 | 独占文件 |
|---|---|
| A | `lib/l10n/app_*.arb`（只改值）、`lib/features/lyric/presentation/lyric_view.dart`、`lib/features/player/presentation/full_player_page.dart`（仅文字引用，不改结构）、`lib/features/mv/presentation/mv_player_page.dart`（仅文字引用） |
| B | `lib/core/resource/**`（新建）、`lib/features/home/data/home_repository.dart`、`lib/features/lyric/data/lyric_repository.dart`、`lib/features/mv/data/mv_repository.dart`、`lib/features/playlist/data/playlist_repository.dart`、`lib/features/search/data/search_repository.dart`、`lib/features/player/data/player_repository.dart`、`lib/core/api/translate_api.dart` |
| C | `lib/core/prefetch/**`（新建）、`lib/main.dart`、`lib/features/home/presentation/home_page.dart`、`lib/features/library/presentation/library_page.dart`、`lib/features/player/player_provider.dart`、`lib/features/player/data/audio_handler.dart`、`lib/features/player/presentation/queue_sheet.dart` |

## 发布目标
v4.0.0+43（**打 tag 前主代理先 bump pubspec**，v3.7.0 试错 6 轮的教训）。tag `v4.0.0`。
