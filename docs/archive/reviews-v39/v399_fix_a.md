# v3.9.9 A 档修复报告（V399-A1/A2/A3）

基线 755dcea。仅 dart analyze，未动 pubspec.yaml，未装任何 SDK。

## 实时记录

- 完整读 TASK_v399_a.md / QUALITY_STANDARD.md（33 条）/ PROGRESS.md 末段。
- 已读：add_to_playlist_sheet.dart、full_player_page.dart、playlist_repository.dart(TrackRef:544)、player/data/models.dart(Song 字段)、login_guard.dart(ensureLoggedIn)、lyric_repository.dart、cache_manager.dart、translate_api.dart、krc_parser.dart、settings_page.dart 清缓存段、main.dart box 初始化、settings_provider.dart。
- A1 结论：播放页顶栏「更多」菜单已有 addToPlaylist 入口，但功能入口行 `_EntryButtonsRow` 无可达入口（用户反馈属实）。l10n 复用既有 `addToPlaylist` 键（11 语言已全），无需新增键。
- A2 结论：lyric_repository 仅用 MemoryCache（90s/30min 内存），/search/lyric 与 /lyric 每次都走网络（属实）。翻译结果已有持久缓存（lyric_translations，B-29 已含模型维度），歌词本体无持久缓存。
- A3 结论：ensureTranslation 已满足「缓存命中→内嵌译文→才调 API」链路与 V34-03 条数防御；缺口是 original 模式下仍会调翻译 API（非必要翻译）。

## 改动明细

### V399-A1 播放页收藏入口（full_player_page.dart）
- `_EntryButtonsRow` 在评论按钮后新增「添加到歌单」Expanded OutlinedButton：
  未登录先 `ensureLoggedIn(context, ref, action: l10n.addToPlaylist)`（login_guard.dart 现有签名，已读确认）；
  已登录用当前 Song 构造 `TrackRef(name, hash, albumId, albumAudioId)`（playlist_repository.dart:544 构造签名、player/data/models.dart Song 字段均已读确认）后调 `showAddToPlaylistSheet`。
- 新增 import `../../auth/presentation/login_guard.dart`。
- l10n：复用既有 `addToPlaylist` 键（11 语言齐全），**无新增键**。
- 顶栏「更多」菜单原入口保留（两处入口同一弹层，不重复实现）。

### V399-A2 歌词持久缓存（cache_manager.dart / lyric_repository.dart / settings_page.dart / main.dart）
- cache_manager.dart 新增 `LyricPersistentCache`（Hive `lyric_cache` Box<String>，
  模式复刻 lyric_translations；key=`kind:网络缓存键`，value=JSON{storedAt毫秒,body}），
  提供 `getWithStale(networkKey, kind, ttl)` → `(fresh, staleAny)` 与 `set/clear`。
- lyric_repository.dart：`/search/lyric` 与 `/lyric` 三级读取——MemoryCache →
  LyricPersistentCache（fresh 命中不发网络）→ 网络（成功回写两层缓存）；
  网络失败且存在旧缓存时返回旧值并 `debugPrint` 留痕（降级可观测，第 9/16 条），
  无旧缓存则原样 rethrow（异常契约不变，第 8 条）。TTL 沿用既有 `_lyricCacheTtl`（30 分钟）。
- settings_page.dart 清缓存循环纳入 `LyricPersistentCache.boxName`；main.dart 启动 `openSafe('lyric_cache', stringValues: true)`。

### V399-A3 翻译自动化（full_player_page.dart currentLyricProvider）
- **非必要不翻译**：`LyricDisplayMode.original` 时直接返回原文，不触发 ensureTranslation
  （零 API 调用）。bilingual/translation 模式维持原链路：LyricTranslationCache 持久缓存命中
  → 内嵌 language 译文逐行复用 → 仅缺译行走 API（V34-03 条数防御、F4-31 版本键、
  B-29 模型维度键均已在前序修复就位，本次核对确认保留）。
- 注意：内嵌译文判定在 ensureTranslation 内逐行进行（F4-30），上游自带译文的行本就不调 API。

## analyze 逐文件结果（dart analyze，基线对比后仅列非噪音项）

| 文件 | 结果 |
|---|---|
| lib/core/cache/cache_manager.dart | 除 hive 包 URI/Box/Hive（无 SDK 预期噪音，基线同样存在）外 0 项 |
| lib/features/lyric/data/lyric_repository.dart | 除 flutter/foundation URI 与 debugPrint（预期噪音）外 0 项；此前引入的 4 处 unchecked_use_of_nullable_value 与 unused_local_variable 已修复清零 |
| lib/features/player/presentation/full_player_page.dart | 除 Flutter/Riverpod 符号噪音（ConsumerState/Icon/SafeArea 等，基线同样存在）外 0 项；本次新增代码无自有报错 |
| lib/features/settings/presentation/settings_page.dart | 仅 1 行改动（清缓存数组加常量）；仅 Flutter/三方符号噪音，0 自有新错 |
| lib/main.dart | 仅 1 行改动（openSafe lyric_cache）；仅 Hive/flutter 符号噪音，0 自有新错 |
| lib/features/player/data/models.dart、player_repository.dart | **非本档改动**（B 档 V399-B3 并行代理所改），本档未触碰 |

## l10n
`python3 tool/gen_l10n_min.py` → `wrote lib/l10n/app_localizations.dart: 346 keys, 11 locales`（无新增键，11 语言键数一致）。

## 未做项
- 无任务书内未做项。歌词翻译持久缓存/条数防御/缓存键模型维度为既有实现（B-29、F4-31、V34-03），核对确认无需改动。

## 汇报（8 行内）
1. V399-A1：full_player_page 入口行新增「添加到歌单」按钮，ensureLoggedIn 前置，TrackRef 由 Song 构造，复用 addToPlaylist l10n 键。
2. V399-A2：新增 LyricPersistentCache（Hive lyric_cache），/search/lyric 与 /lyric 三级缓存（内存→持久→网络），失败降级旧值并留痕，清缓存与启动初始化同步接入。
3. V399-A3：original 显示模式不再调翻译 API；bilingual/translation 保持「持久缓存→上游内嵌译文→才调 API」链路，V34-03/F4-31/B-29 防御确认在位。
4. analyze：5 个触碰文件逐文件过滤 Flutter/三方噪音后均为 0 自有错误（明细见上表）。
5. l10n：gen_l10n_min.py 346 keys × 11 locales，无新增键。
6. 未触碰 pubspec.yaml；未装 SDK；未 git commit。
7. models.dart / player_repository.dart 的 diff 来自 B 档并行代理（V399-B3），本档未修改。

