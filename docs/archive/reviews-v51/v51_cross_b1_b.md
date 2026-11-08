# v5.1 交叉审查 B1 · 视角 B（鲁棒与代码质量）

- 报告：`docs/v51_cross_b1_b.md`
- 范围（逐文件 `file_read` 从头到尾完整读，7 个 .dart / 719 行）：
  1. `lib/core/foundation/errors.dart`
  2. `lib/core/domain/quality.dart`
  3. `lib/core/domain/song.dart`
  4. `lib/core/domain/response_policy.dart`
  5. `lib/core/config/app_config.dart`
  6. `lib/core/api/kugou_api_client.dart`
  7. `lib/core/api/translate_api.dart`
- 判定依据：`docs/QUALITY_STANDARD.md`（33 条，优先）+ `docs/REVIEW_SPEC.md`。
- 视角：异常契约（6/8/9）、边界与空值（13/14）、并发/资源对称（18/19/20/22）、缓存/凭证维度（23/25）、实测依据（28/29）、死代码（32）、注释与行为一致（31）。
- 特别核对：`evaluateResponse` 的 `err_code` 字符串/数值形态、空响应体、`ApiException` re-export 删除后的引用方 import 完整性。
- 约束：只读代码；唯一写入本报告；不编译/不跑测试/不装 SDK；仅允许 `dart analyze <file>` 静态检查。
- 证据等级：实锤 / 静态推演 / 未实测（如实标注）。

---

## 1. `lib/core/foundation/errors.dart`（30 行，完整读）

### lib/core/foundation/errors.dart:1 文件头注释声称「原位置 re-export 兼容」与当前磁盘状态不符
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 32 条（死注释/遗留兼容声明）
- 依据：第 1 行文档注释写「v5.0 M1：上移至 core/foundation，**原位置 re-export 兼容**」，第 2–3 行同时声称「全仓错误翻译唯一出口」。本文件本身只有 `ApiException` 类定义，无任何 `export` 语句；「原位置」是否还存在兼容 re-export 属跨文件事实，已在下文「补充核对：ApiException re-export 删除后的引用方 import」中逐一核对。
- 影响：维护者按注释认为可以沿用旧 import 路径，实际会编译失败或在后续重构中误删/误留兼容层；注释描述的是历史状态而非现状。
- 证据等级：实锤（注释与文件内事实）／跨文件部分见补充核对

### lib/core/foundation/errors.dart:24 `// 唯一常量见 response_policy.dart` 与紧邻硬编码 20028 自相矛盾
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释不复述/不误导）、第 2 条（魔法值必须有具名常量）
- 依据：第 24 行 `bool get needsVerification => errorCode == 20028; // 唯一常量见 response_policy.dart`。本行把 20028 写成字面量，注释却指向别处的「唯一常量」；若 `response_policy.dart` 中存在具名常量，则此处构成第二处硬编码（与文件头「其他层不得重复硬编码错误码」的口径冲突），「唯一」表述不成立。见第 4 节对 `response_policy.dart` 的核对结论。
- 影响：错误码口径分散，后续改动 20028 的判定条件时容易只改一处，导致风控验证分支一半生效；对用户表现为 20028 场景时而弹验证、时而当作普通错误。
- 证据等级：静态推演（本文件事实为实锤，跨文件事实见第 4 节）

### lib/core/foundation/errors.dart:29 `toString()` 丢弃 ssaCode / verifyUrl / body
- 级别：P3
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）
- 依据：第 27–29 行 `toString() => 'ApiException($errorCode): $message'`；类中另有 `ssaCode`、`verifyUrl`、`body` 三个字段（第 17/20/23 行），其中 `ssaCode` 的文档注释（第 16 行）明确是「20028 时携带的验证事件 id… 便于上层判断 fail_process」。任何以 `toString()` 输出异常的日志都无法记录这三项。
- 影响：20028 风控验证失败时，日志中只剩错误码与消息，缺少 ssaCode/verifyUrl，线上无法区分是验证码类型判断失败还是获取验证信息失败。
- 证据等级：静态推演（未实测日志调用点，未读 B4 范围文件）

### lib/core/foundation/errors.dart:10 `errorCode` 声明为 `int`，无外部形态归一化入口
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 3 条（契约先行：输入取值范围）
- 依据：第 10–11 行构造函数 `ApiException(this.errorCode, this.message, …)`，字段 `final int errorCode`；类内没有任何把 `String`/`num`/`null` 形态的 `err_code` 归一为 int 的工厂或校验，构造契约要求调用方自行保证 `int`。跨层唯一「创建点」的形态核对见第 4/6 节 `evaluateResponse` 与 `kugou_api_client.dart`。
- 影响：若上游 `err_code` 为字符串或 null，创建点要么崩溃要么静默传 0，20028 判定与错误信息都会失真。
- 证据等级：静态推演（本文件事实实锤；上游形态见第 4/6 节）

## 2. `lib/core/domain/quality.dart`（102 行，完整读）

### lib/core/domain/quality.dart:1 未使用的 Flutter 框架 import 留在纯领域枚举文件
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（未使用的导入）、第 4 条（核心层不得依赖界面框架）
- 依据：第 1 行 `import 'package:flutter/foundation.dart';`；全文 102 行内没有出现 `foundation.dart` 导出的任何符号（无 `@visibleForTesting`、`kDebugMode`、`debugPrint`、`ChangeNotifier`、`ValueNotifier` 等），文件只有一个 `enum AudioQuality` 及其常量/静态方法。`core/domain` 属核心领域层，该文件把界面框架包作为唯一外部依赖。
- 影响：无运行时用户可见后果；使纯领域模型携带对 Flutter 的依赖，任何非 Flutter 宿主（测试/工具脚本）无法直接复用该枚举，且误导后续维护者以为可在此使用框架能力。
- 证据等级：实锤（全文符号核对 + 逐文件 `dart analyze` 的 unused_import 见文末）

### lib/core/domain/quality.dart:17 与 :92 对「magic_ 前缀由谁补齐」的注释互相矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 31 条（注释与行为一致）、第 28 条（请求参数形态必须有实测依据，不得推测）
- 依据：第 17–18 行注释写「/v5/url 需 `magic_` 前缀，**由 KgSharedParams.songUrl 统一补前缀**」，而第 92–93 行注释写「魔法档 wire 名带 magic_ 前缀（/v5/url 参数用），**枚举 value 同名，直接按 value 命中即可**」。同一文件内枚举 value 已是 `'magic_piano'` 等带前缀字符串（第 19–24 行），两处注释对「value 是否已含前缀」给出相反口径：若 `KgSharedParams.songUrl` 再补一次前缀，实际下发参数会是 `magic_magic_*`。该文件内无任何实测记录或参数样例可裁决，`KgSharedParams` 属 B2 范围，本视角未读。
- 影响：魔法音效档请求参数形态一旦为双前缀或漏前缀，`/v5/url` 不会报错而是静默给出空/降级地址，用户点选「魔法钢琴」等档位时无声音或播到普通音质，且由于不报错难以定位。
- 证据等级：静态推演（文件内两处注释矛盾为实锤；下游补前缀行为未实测，标注未实测）

### lib/core/domain/quality.dart:92 switch 内注释声称「蝰蛇/魔法档显式解析」，但无任何 case
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释不复述代码、不得复述不存在的行为）、第 32 条（遗留半成品注释）
- 依据：第 92–94 行注释位于 `switch (v)` 的 case 列表末尾：「V399-B3：蝰蛇/魔法档显式解析…兼容无前缀写法（旧设置残留）」，但该 switch 只有 `hires`/`hi-res`/`hiresample` 与 `master`/`母带`/`臻品` 两组 case（第 84–91 行），没有任何蝰蛇或魔法档 case；紧随其后的第 96–99 行循环只对 `magicOrder` 做 `'magic_$v'` 匹配，`viperOrder` 完全没有无前缀兼容。蝰蛇档只能靠第 80–82 行的精确 `q.value == v` 命中。另第 5 行「排序：super > high > flac > 320 > 128」与实际枚举声明顺序（q128→q320→flac→high→superQuality，即升序）相反，容易让调用方误判 `AudioQuality.values` 的顺序语义。
- 影响：注释误导维护者以为旧设置残留的无前缀蝰蛇值（如 `'tape'`）能被解析；实际会落到第 100 行默认 `q128`，用户升级后音质设置被静默降为标准档且设置页无提示。
- 证据等级：实锤

### lib/core/domain/quality.dart:100 未识别的音质字符串静默降级为 q128，无任何留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 11 条（降级必须有明确触发条件与退出条件）、第 14 条（磁盘读取属数据边界必须校验）
- 依据：`fromString` 对 `null`（第 78 行）与所有未命中值（第 100 行）一律 `return q128`，函数不抛异常、不返回可区分的失败语义、不记录日志；兼容别名仅覆盖 `'hires'/'hi-res'/'hiresample'`、`'master'/'母带'/'臻品'`（第 84–91 行），连本枚举自身的 label `'臻品母带'`、`'无损'`、`'高品'`、`'标准'` 都未纳入。文件第 75–76 行文档注释自己把「设置页显示已生效但音质没变」定性为「数据一致性红线」，而实现正是把任何未知持久化值映射到该结果。
- 影响：设置/持久化里出现新档位值、旧版残留值或轻微拼写差异时，用户看到的仍是上次选择的高音质项，实际播放静默降到 128k，无提示、无日志，线上无法统计与定位。
- 证据等级：实锤（降级路径）；磁盘实际取值集合未实测

### lib/core/domain/quality.dart:43 注释声称「VIP 态实测」但无可追溯的返回样本
- 级别：P3
- 违反：QUALITY_STANDARD 第 29 条（返回结构必须实测并留样，三种登录态）、第 28 条（调用方式必须逐一实测）、第 33 条（kapi 包装结果不得作为原生依据）
- 依据：第 43 行「蝰蛇族降级顺序（只在族内降， VIP 态实测真实返回 URL）」、第 50 行「魔法族展示顺序（匿名可用；不自动降级到普通档）」、第 17 行「概念版特殊音源，匿名可用」均为对上游 `/v5/url` 行为与登录态差异的断言，本文件及本批范围内没有指向任何实测记录/返回样本/三态留样的引用，也没有注明数据来源是否为 kapi 包装结果。
- 影响：`viperOrder`/`magicOrder` 的降级与展示纪律建立在这类断言上；若 VIP/匿名态返回结构不同，蝰蛇族族内降级会请求到不存在的档位而静默失败，且后续维护者无法回溯原始样本验证。
- 证据等级：未实测（本范围无样本；未读 B2 直连实现，标注未实测）

## 3. `lib/core/domain/song.dart`（175 行，完整读）

### lib/core/domain/song.dart:76 `str()` 对任意外部对象用 `'$v'` 字符串化，未做类型分支校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转，必须逐一分支验证类型）、第 14 条（网络响应属数据边界必须校验）
- 依据：第 76–82 行 `str(List<String> keys)` 内 `if (v != null && '$v'.isNotEmpty) return '$v';`，对 `hash`、`albumId`、`albumAudioId`、`name`、`artist`、`cover` 等全部字段一视同仁地把任意 `dynamic`（Map/List/num/bool）转成 `toString()` 文本。第 90 行 `'${e['name'] ?? ''}'`、第 94 行 `'$singer'`、第 100 行 `'${info['image'] ?? ''}'`、第 104 行 `'${transParam['union_cover'] ?? ''}'` 同理。第 98 行 `json['info'] is Map ? json['info'] as Map` 用的是无类型参数的裸 `Map`，随后第 100/148 行直接以字符串键取值。
- 影响：上游某字段改成对象/数组时不会报错，而是把 `null`、`{a: b}`、`[x, y]` 之类的文本写进 hash、封面 URL、歌名；播放解析会用错误 hash 请求地址、封面组件拿到非 URL 文本，界面出现「歌名是一串花括号」或长期加载失败，且无异常可捕获。
- 证据等级：实锤（代码事实）；具体上游字段形态未实测

### lib/core/domain/song.dart:79 空值与非空判定被 `'$v'.isNotEmpty` 混淆，「无值」被当作「有值」
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（空集合与缺失必须语义分离）、第 14 条（边界校验）
- 依据：`str()` 只排除 `null` 与空字符串文本，`false`、`0`、`[]`、`{}` 均会被字符串化为 `'false'`/`'0'`/`'[]'`/`'{}'` 并视为有效值；第 90 行 `'${e['name'] ?? ''}'`、第 94 行 `'$singer'`、第 100 行 `'${info['image'] ?? ''}'`、第 104 行 `'${transParam['union_cover'] ?? ''}'` 同样把任意对象转文本。更直接的一处：第 99 行 cover 取到 `'{}'` 之类非空脏值、或第 100 行 `info['image']` 为 Map 被写成 `'{...}'` 后，`cover` 已非空，第 102 行 `if (cover.isEmpty)` 判定的 `trans_param.union_cover` 回退被直接跳过。缺失字段与「上游给了空占位对象」被统一折叠成同一个非空字符串。
- 影响：搜索结果里出现 `hash='0'`、`name='false'` 之类的脏 Song 对象，进入列表与播放队列后表现为无法播放却看不出原因；「无封面」与「封面字段异常」在 UI 上无法区分。
- 证据等级：实锤（代码事实）；上游是否返回过此类值未实测

### lib/core/domain/song.dart:126 `setDuration` 用 `duration > Duration.zero` 作「已赋值」哨兵，负值与零值可覆盖已解析结果
- 级别：P2
- 违反：QUALITY_STANDARD 第 17 条（数值精度/单位不容隐式混淆）、第 14 条（边界校验）、第 31 条（注释与行为一致）
- 依据：第 126–127 行 `if (duration > Duration.zero) return;`——「已解析」的判据是数值大于零而非显式布尔标志。第 142–148 行按顺序对三组键调用：秒制键 `'duration','Duration','time_length'` 先跑（millis:false），毫秒制键随后（millis:true）。若第一个键给出 `0` 或负数，`duration` 保持 `Duration.zero`/负值，哨兵不成立，后续毫秒键会覆盖它且单位不同；`int.tryParse('$raw')` 对 `'240.5'`、`'3min'` 等返回 null 静默置零；`raw.round()` 对浮点毫秒做隐式四舍五入。此外第 67–72 行「实测字段真值」注释把 `Duration` 列为秒、`info.duration` 列为毫秒，但第 142 行把小写的 `'duration'` 也归入秒组，与 `/privilege/lite` 的 `info.duration` 毫秒口径为不同层级键，靠 `json.containsKey` 而非字段来源区分，同名键出现在同一层时单位必然错。
- 影响：歌曲时长显示为 0 或差 1000 倍（例如 4 分钟歌显示 240000 秒或 0:00），进度条与歌词时间轴失准；且因不抛异常，属于静默错误。
- 证据等级：实锤（单位/哨兵逻辑）；上游同层是否出现同名键未实测

### lib/core/domain/song.dart:161 `AudioQuality.fromString(str(['quality']))` 把「无 quality 字段」伪装成「标准音质」
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（缺失与确实为空语义分离）、第 9 条（静默降级必须留痕）、第 23 条（缓存键必须覆盖全部影响结果的维度）
- 依据：第 160–161 行注释「quality_vip 可为 null，best_free_quality 在该部署版中不存在」，实现仅取单一键 `quality`，`str()` 在字段缺失时返回 `''`，`AudioQuality.fromString('')` 在第 100 行返回 `q128`。即 `/privilege/lite` 返回的 quality 为 null 或缺失时，Song 被标记为 `AudioQuality.q128` 这一确定的音质事实，而不是「未知」。Song 的 `quality` 会参与播放地址请求与缓存键维度（第 25 行 `final AudioQuality quality`），未知被固化成最低档。
- 影响：用户在 VIP/Hi-Res 曲目上看到或缓存到「标准」音质，若该字段参与缓存键则同一首歌在不同登录态下复用 128k 缓存，登录升级后仍播低音质；无日志无提示。
- 证据等级：静态推演（本文件 + quality.dart 事实为实锤；缓存键用途在 B3 范围，未实测）

### lib/core/domain/song.dart:170 `operator ==` 仅按 hash 比较且空 hash 永不相等，与 `hashCode` 不对称
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：相等语义必须明确）、第 14 条（边界：外部数据可能无 hash）、第 30 条（命名/契约与行为一致）
- 依据：第 170–171 行 `other is Song && other.hash == hash && other.hash.isNotEmpty`；第 174 行 `hashCode => hash.hashCode`。后果有三：① hash 为 `''` 的两个 Song 即使所有字段完全相同也互不相等，但 `hashCode` 相同（哈希碰撞合法但相等关系非自反，`s == s` 对空 hash 为 false，违反 `==` 自反性契约）；② 两首 hash 相同但 `localPath`、`quality`、`duration`、`name` 不同的 Song 判为相等，而 `copyWith` 明确用于改 `localPath`/`quality`（第 38–62 行），这些字段变化在 Set/Map/去重/`==` 比较中全部不可见；③ 含 `localPath`（离线源）与不含的 Song 被视作同一对象。
- 影响：播放队列去重或缓存查找（`Set<Song>`/`Map<Song,...>`）会把「已下载可离线播放」和「需联网解析」的同一首歌合并，用户切歌/离线时可能走错路径；空 hash 的脏数据在列表中无法被正确判定为同一项，出现重复项或刷新后状态错乱。
- 证据等级：实锤（相等契约的代码事实）；具体调用点未实测（属 B3/B5 范围）

### lib/core/domain/song.dart:67 「实测字段真值」注释无可追溯样本，且暗含 kapi 口径风险
- 级别：P3
- 违反：QUALITY_STANDARD 第 29 条（返回结构必须实测并留样，匿名/普通/付费三态）、第 28 条（调用方式必须逐一实测）、第 33 条（kapi 包装结果需标注并原生复核）
- 依据：第 67–72 行列出 `/search?type=song` 与 `/privilege/lite` 的字段名、单位与语义断言（`MixSongID` = album_audio_id、`Audioid` ≠ album_audio_id、`Duration` 秒 / `info.duration` 毫秒），第 160 行还有「best_free_quality 在该部署版中不存在」的部署相关断言，全文未给出任何样本路径、probe 记录编号或三态留样引用，也未标注数据来源是原生域名还是 kapi 包装结果。
- 影响：`fromJson` 的多键兼容表与单位换算完全建立在这组断言上；若上游字段形态变更或来自 kapi 裁剪后的结构，解析会静默产出错误 Song（hash/时长/封面错），且维护者无法回溯原始样本核对。
- 证据等级：未实测（本范围无样本；未读 B2 直连实现）

### lib/core/domain/song.dart:3 游离的文档注释 `/// 播放器数据模型。` 未附着于任何声明
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死注释/遗留残留）、第 31 条（注释应解释「为什么」）
- 依据：第 3 行 `/// 播放器数据模型。` 之后紧跟一个空行，第 5 行才是 `/// 单曲信息。` + 第 6 行 `class Song`。第 3 行的 doc comment 因此不附着于任何类/库声明，且与第 5 行重复描述同一模型。
- 影响：无用户可见后果；生成的 API 文档中该说明缺失/悬空，属整洁度问题。
- 证据等级：实锤

## 4. `lib/core/domain/response_policy.dart`（66 行，完整读）

### lib/core/domain/response_policy.dart:36 `body['ssaCode'] as String?` 裸强转使错误处理路径本身抛出 TypeError
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 8 条（异常契约必须单一且稳定）、第 10 条（编程错误不得伪装业务降级，此处反向：业务错误伪装成编程崩溃）
- 依据：第 34–37 行 `fail(int code)` 内 `ApiException(code == 0 ? -1 : code, msgOf(), ssaCode: body['ssaCode'] as String? ?? ssaCode, body: body)`。`body` 是网络响应（外部数据），`body['ssaCode']` 未经 `is String` 分支校验直接 `as String?`；当该字段是 int/Map/List 时，Dart 在**构造 ApiException 的过程中**抛出 TypeError。此 `fail()` 是第 41、45、49 行三条主要失败路径的公共出口，抛出的不是 `ApiException`，消费方 `on ApiException` / `requiresVerification()` 分支全部落空。注意 `errors.dart:16` 注释称该值来自 `body.ssaCode` 或响应头 `ssa-code`，本函数只读 camelCase 的 `body['ssaCode']`，无 `ssa_code` 兼容分支。
- 影响：任何带非字符串 `ssaCode` 的错误响应（含 20028 风控响应）会让请求以未捕获的类型错误崩溃，而非进入验证流程；用户看到闪退/页面异常中断，日志里也没有可检索的 ApiException。
- 证据等级：静态推演（`as String?` 的类型失败语义为实锤；上游是否真的下发数值型 ssaCode 未实测）

### lib/core/domain/response_policy.dart:28 `codeOf` 把不可解析的 err_code / error_code 一律折叠为 0（=成功）
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据必须逐一分支验证类型后再使用）、第 14 条（网络响应边界必须校验）、第 9 条（失败必须可观测）
- 依据：`int codeOf(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);`。第 40–41 行 `err_code` 判定「兼容字符串形态」实际只兼容纯整数字符串：`'20028'` 可解析，但 `20028.0`（JSON 数值为 double）、`' 20028 '`（带空白）、`'20028\n'`、`'E20028'`、`true`、`{}` 全部落到 `?? 0` → `codeOf(errCode) != 0` 为假 → 不判失败；这些响应随后若无 status 且非空，会在第 54 行 `return ApiOutcome.ok(body)` 被判成功。第 30 行 `error_code`/`errcode` 同样经 `codeOf` 折叠，double 形态的 20028 连第 49 行 `errorCode != 0` 也触发不了。
- 影响：风控 20028 或一般业务错误码只要换成浮点/带空白字符串形态，就被静默当作成功返回，验证流程不触发、错误数据进入上层解析，用户看到空列表/空白内容且无任何错误提示与日志。
- 证据等级：实锤（`int.tryParse` 语义与分支顺序）；上游具体形态未实测

### lib/core/domain/response_policy.dart:44 `errorCode != 0` 时 `_hasData()` 几乎恒真，错误响应被判成功
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条（成功/失败契约必须明确）、第 8 条（异常契约稳定）、第 29 条（成功判定口径必须逐端点实测确认）
- 依据：第 43–45 行 `if (status == 1) { if (errorCode == 0 || _hasData(body)) return ApiOutcome.ok(body); return fail(errorCode); }`，而第 57–62 行 `_hasData` 的兜底是 `body.keys.any((k) => k != 'status' && k != 'error_code' && k != 'errcode')`——只排除 3 个键，**不排除** `'error'`、`'errmsg'`、`'info'`、`'err_code'`、`'ssaCode'`、`'data'` 等。因此任何形如 `{'status': 1, 'error_code': 20028, 'error': '需要验证'}` 的响应：errorCode=20028，但 `'error'` 键使 `_hasData` 为真 → 返回 `ApiOutcome.ok(body)`。第 45 行 `fail(errorCode)` 仅在响应恰好只有 status + error_code/errcode 两三个键时才可达。同样 `{'status': 1, 'data': {}, 'other': ...}` 因 `d is Map` 提前 return `d.isNotEmpty` 而忽略其它键，走向相反。
- 影响：`status==1` 且带错误码的真实失败响应被当作成功交给业务层，20028 验证被绕过；上层拿到的是错误体而非数据，可能解析出空歌单/空列表或脏对象，且因 `isOk == true` 不会触发任何错误提示。
- 证据等级：实锤（分支可达性代码事实）；真实响应是否含该键组合未实测

### lib/core/domain/response_policy.dart:50 「空响应体」判定只覆盖字面 `{}`，无 status 的错误/风控体被当成功
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（网络响应边界必须校验）、第 16 条（请求失败与确实为空必须语义分离）、第 9 条（静默降级必须留痕）
- 依据：`if (body.isEmpty)` 位于第 50 行，排在第 41/43/48/49 行之后。逐分支：字面 `{}` → status=null、errorCode=0、第 49 行不成立 → 第 50 行命中，返回 `ApiException(-1, '空响应体（可能被风控拦截）')`（此路径本身正确）。但非空且无 status 的响应，例如 `{'error': '风控拦截'}`、`{'errmsg': '...'}`、`{'data': null}`、`{'info': {...}}`，以及 `status` 为字符串形态 `{'status': '0'}` / `{'status': '1'}`（第 29 行 `status` 是 dynamic，第 43/48/49 行都用 `== 1/200/0/2` 与 int 比较，字符串永不相等），都会绕过第 49 行、绕过第 50 行，落到第 54 行 `return ApiOutcome.ok(body)`。第 48 行 `if (status == 200) return ApiOutcome.ok(body)` 也完全不检查 `error_code`/`errcode` 是否为错误码，与 `status==1` 分支的双条件判定口径不一致。
- 影响：风控拦截或服务端返回的「有错误文案但无 status」响应被判为业务成功，上层按数据解析后展示空内容或错误文案的残余数据；用户既看不到错误提示也看不到重试入口，线上无法与「确实为空」区分。
- 证据等级：实锤（分支顺序与 `==` 比较语义）；上游空响应形态未实测

### lib/core/domain/response_policy.dart:39 `err_code` 判定无条件覆盖全部端点，与注释「mcomment」限定不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：逐端点成功口径）、第 29 条（成功判定口径不统一必须逐端点实测确认）、第 31 条（注释与行为一致）
- 依据：第 39 行注释「**mcomment**：err_code 优先，与 status 无关（兼容字符串形态）」，但实现第 40–41 行位于函数最前、对传入的任何 `Map<String,dynamic>` 生效，函数签名为唯一成功判定入口（第 23 行），没有端点参数可区分 mcomment 与其它端点。第 47–48 行注释「歌词类：status=200 + errcode=200 是正常码」——若某 status=200 的响应同时带非零 `err_code`，第 41 行会先返回 fail，第 48 行不可达。REVIEW_SPEC 第三节第 4 条明确列出四种成功口径（status==1 / status==200 / err_code==0 / 裸 Map），本函数用一套固定优先级合并处理且无端点标识。
- 影响：非 mcomment 端点若返回带非零 `err_code` 的正常响应，会被判失败并弹出无意义错误；反之依赖 `status` 判失败的端点若 `err_code` 恰好为 0，则被放行。表现为个别接口「明明成功却报错」或「明明失败却显示空成功」。
- 证据等级：静态推演（本文件事实实锤；其它端点返回结构属 B2 范围，未实测）

### lib/core/domain/response_policy.dart:31 `msgOf()` 取空字符串或任意对象作用户可见错误文案
- 级别：P3
- 违反：QUALITY_STANDARD 第 14 条（边界校验）、第 9 条（失败必须可观测）、第 13 条（外部数据不得裸用）
- 依据：第 31–32 行 `'${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}'` 用 `??` 链只排除 null：`error` 为 `''` 时后续 `error_msg`/`errmsg` 全被短路，错误消息为空串；`info` 为 Map/List 时（对照 `song.dart:72` `/privilege/lite` 的 `info.duration`/`info.image` 结构）会把整个 Map 的 toString 文本塞进 `ApiException.message`。`msgOf()` 在 `fail()` 中无条件调用，即所有失败路径共用。
- 影响：错误提示框可能显示空白或 `{duration: 240000, image: ...}` 之类的原始结构文本，用户无法理解失败原因。
- 证据等级：实锤（`??`/插值语义）；上游字段形态未实测

### lib/core/domain/response_policy.dart:24 注释「全仓 20028 判定唯一出口」与 errors.dart 的硬编码判定并存
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 2 条（魔法值必须有具名常量）、第 31 条（注释与行为一致）
- 依据：本文件第 10 行定义 `const int kVerificationRequired = 20028`，第 64–66 行 `requiresVerification()` 注释「全仓 20028 判定唯一出口。消费方不得再硬编码错误码」并用该常量；但 `errors.dart:24` 的 `needsVerification` getter 直接写 `errorCode == 20028`，且本文件第 20 行 `ApiOutcome.needsVerification => failure?.needsVerification ?? false` 走的正是那个硬编码 getter。即实际存在两条 20028 判定路径、两个真相来源（常量 + 字面量），且 `errors.dart:24` 的注释反过来指向本文件。文件头第 3–5 行「成功/失败/风控判定全部收敛于此」同样不成立。
- 影响：若常量值变更或新增验证类错误码，两条路径结果分叉：一处弹验证、一处按普通错误提示；用户在同一风控场景下得到不一致的处理。
- 证据等级：实锤（两文件代码事实）

### lib/core/domain/response_policy.dart:15 `ApiOutcome.fail(null)` 合法且产生 `isOk == true` 的「失败」
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约必须明确、状态可穷尽）、第 16 条（失败与空成功语义分离）
- 依据：第 15 行 `const ApiOutcome.fail(this.failure) : body = const {};` 的 `failure` 类型为 `ApiException?`（第 18 行），构造函数不校验非空；第 19 行 `bool get isOk => failure == null` 使 `ApiOutcome.fail(null)` 同时是「失败」和「isOk」。第 15 行还把 `body` 置为不可变的 `const {}`。本范围内两处 `fail()` 调用（第 34、51 行）都传入非空 ApiException，无现成触发点。
- 影响：本范围无实际触发，属契约洞；一旦有调用方以 null 构造失败结果，错误会被 `isOk` 判为成功，用户看到空内容且无提示，且对 `body` 写入会抛 UnsupportedError。
- 证据等级：实锤（类型与构造器事实，无现成调用点）

### lib/core/domain/response_policy.dart:23 「行为逐分支保持」「唯一成功判定入口」无实测/对照依据
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（调用方式必须逐一实测）、第 29 条（返回结构必须实测并留样，匿名/普通/付费三态）、第 33 条（kapi 包装结果不得作原生依据）
- 依据：第 23–24 行声称「从 `_wrap` 上移，行为逐分支保持」，第 47 行「歌词类：status=200 + errcode=200 是正常码」，第 50–52 行「空响应体（可能被风控拦截）」均为上游返回结构的结论；本文件与本批其余文件内没有任何 probe 记录、三态返回样本或原生域名实测留样的引用，也没有标注是否来自 kapi 包装结果。第 5 行称 20028 判定曾散在 `player_repository`/`friendly_error`，本视角范围（B1）不含这些文件，无法核对是否已清除。
- 影响：成功/失败判定的每个分支都建立在这组未留样的断言上；形态判断错一处即造成整条链路静默落到回退或把失败当成功，且后续无法回溯验证。
- 证据等级：未实测（本范围无样本；未读 B2/B4 文件）

## 5. `lib/core/config/app_config.dart`（56 行，完整读）

### lib/core/config/app_config.dart:10 kapi 常量注释「运行期绝不调用 / 仅供 CookieJar 域名占位」与第 6 节 KugouApiClient 实际请求行为冲突
- 级别：P1
- 违反：QUALITY_STANDARD 第 27 条（接口只走原生网关）、第 31 条（注释与行为一致）、第 33 条（kapi 包装结果不得作原生依据）
- 依据：第 10–15 行注释断言「kapi **只是原生接口的参考实现，运行期绝不调用**…该常量仅供 `KugouApiClient` 的 CookieJar 域名占位使用（Cookie 只存本地，不发包），直连层 KgClient 全部使用酷狗原生域名」；但下文完整读到的 `lib/core/api/kugou_api_client.dart` 第 43 行以 `baseUrl: AppConfig.kugouApiBase` 初始化 `Dio`，并在 `get()/post()` 中用它发起真实 HTTP 请求（详见第 6 节逐行结论）。即该常量并非只作存储占位，`Dio.baseUrl` 就是请求目标。第 18 行 `proxyBase = 'https://proxy.344977.xyz'` 同样没有注释说明用途、是否运行期调用，本范围内无引用可核对。
- 影响：注释把运行期仍存在的 kapi 主路径描述为已废弃，审查/维护者据此认为无需再核对直连覆盖；实际部分业务接口仍走中转网关，返回经 Node 层包装（字段裁剪/状态归一），成功判定与原生不一致时表现为静默失败或错误数据，且注释中的「清理计划」因此长期不执行。
- 证据等级：静态推演（注释与 `kugou_api_client.dart` 构造事实为实锤；是否已无业务调用方属 B2–B8 范围，未实测）

### lib/core/config/app_config.dart:33 「语言单一事实源」注释承认两套集合需手工同步
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条（同一份事实只能有一处权威存储）、第 31 条（注释解释「为什么」而非靠纪律声明）
- 依据：第 33–39 行注释自述「运行期 UI 解析用 `AppLocalizations.supportedLocales`（由 l10n 工具生成）」而本表 `supportedLocales`（第 40–42 行）与 `localeNames`（第 44–55 行）「只供设置页语言选择器排序与显示名，二者必须保持一致——新增 arb 文件时同步更新本表，否则会出现『可选语言与实际解析集合不一致』」。三个语言集合（生成物、本表列表、本表 Map 的键）没有代码级约束或断言，纯靠人工同步。
- 影响：新增或漏配语言时，设置页可选语言与实际生效语言不一致，用户选了某语言后界面仍显示另一语言；属已知纪律风险而非当前已发生的错（本范围未核对 l10n 生成物）。
- 证据等级：静态推演（本文件事实实锤；生成物属 B8 范围，未实测）

### lib/core/config/app_config.dart:16 翻译端点与模型名硬编码为第三方服务，无任何实测依据/降级口径
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（每个端点的请求方法、地址、参数集合、请求头必须逐一实测）、第 29 条（返回结构必须实测并留样）、第 2 条（魔法值必须有具名常量且依赖显式注入）
- 依据：第 16–19 行把 `https://index-translate.bilibili.com/v1/chat/completions` 与 `Index-Translate-35B-A3B` 写成全局静态常量，无来源注释、无 probe 记录、无三态样本引用；第 28–29 行 `lyricTranslateMaxLinesPerBatch = 40`、`lyricTranslateMaxTokens = 4096` 同样无取值依据注释（与模型上下文窗口/限流的关系不可追溯）。第 21–22 行「API 实测使用标准版接口」的 `platform = ''` 也是无留样的实测断言。
- 影响：翻译服务地址或模型名变更时，全量歌词翻译请求 404/401，用户看到翻译一直转圈或报错，且代码内无可回溯的实测记录帮助定位。
- 证据等级：未实测（本范围无样本；`translate_api.dart` 的请求/响应处理见第 7 节）

### lib/core/config/app_config.dart:25 `memoryCacheSeconds = 90` 无单位说明与容量上限配套
- 级别：P3
- 违反：QUALITY_STANDARD 第 15 条（单位必须显式，不得靠注释或字段名白名单猜测）、第 25 条（所有资源必须有上限）
- 依据：第 25 行 `static const int memoryCacheSeconds = 90;` 靠名称后缀表达秒（符合第 15 条的命名要求，此项仅记录其取值无依据）；本文件除时间窗外没有任何内存缓存条目数、磁盘体积、并发请求数、重试次数的上限常量，全仓配置里只有这一个数字。缓存条数/体积上限的保护是否落在 B3 范围未读。
- 影响：若消费方只按时间窗淘汰而不限条目数，长时间浏览会在低端设备上持续累积内存；本文件层面无法确认是否已有上限。属配置层可追溯性不足，未确认用户可见后果。
- 证据等级：未实测（B3 缓存实现未读）

## 6. `lib/core/api/kugou_api_client.dart`（215 行，完整读）

### lib/core/api/kugou_api_client.dart:76 失败以 DioException 包装 ApiException，而 response_policy 侧抛出裸 ApiException——异常契约双形态
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（同一层异常类型可枚举、回退路径与主路径异常形态必须一致）、第 3 条（契约先行）
- 依据：本文件第 76–85 行 `handler.reject(DioException(..., error: ApiException(errorCode, ...)))`,业务失败对外是 `DioException`（`type` 未指定，默认 unknown）；`response_policy.dart:34–37` 的 `fail()` 与第 51 行空响应体分支产出的是**裸 `ApiException`**（`ApiOutcome.failure`）。`errors.dart` 的 `ApiException implements Exception`，不是 `DioException`。同一 B1 范围、同一批请求的两条路径（本客户端回退 / 直连策略）对上层给出两种不同异常形态；`on DioException` 抓不到裸 ApiException，`on ApiException` 抓不到 DioException。
- 影响：上游只在一半路径上生效，另一半落入通用错误提示或无人处理；用户看到「未知错误」而不是具体原因，或直接超时转圈。
- 证据等级：实锤（两处构造代码事实）；上层 catch 形态未实测（属 B2/B4 范围）

### lib/core/api/kugou_api_client.dart:65 与 response_policy.dart:65 组合：DioException 形态的 20028 使 `requiresVerification` 恒为 false
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）、第 9 条（失败必须可观测）
- 依据：本文件第 65 行 `errorCode == 20028 ? '需要完成人机验证' : ...` 与第 79–84 行构造 `ApiException(errorCode, ...)` 后塞进 `DioException.error`；而 `response_policy.dart:64–66` 的全仓判定出口 `requiresVerification(Object? e) => e is ApiException && e.errorCode == kVerificationRequired` 要求**实参本身**是 ApiException。把本拦截器 reject 出的 DioException 传给该出口时结果为 false；`ApiException.needsVerification`（`errors.dart:24`）同样不会被触发，因为异常对象不是 ApiException。文件头 `response_policy.dart:3–5` 声称「20028 判定全部收敛于此」，但本文件第 65 行仍硬编码 20028 生成文案。
- 影响：kapi 回退路径返回的 20028 风控错误不会进入人机验证流程，用户被提示「需要完成人机验证」却没有验证入口，登录/评论/播放等接口持续失败。
- 证据等级：静态推演（两个函数的类型与判定为实锤；调用方传入的实参类型未实测）

### lib/core/api/kugou_api_client.dart:79 `status` 类失败以 `ApiException(0, ...)` 抛出，errorCode=0 与「无错误」语义冲突
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约稳定、同一错误码语义一致）、第 3 条（失败时返回语义明确）
- 依据：第 42–45 行 `errorCode` 在响应无 `error_code`/`errcode` 时为 `0`；第 63 行 `failedStatus` 命中（`status==0||status==2`）时无条件 reject，`ApiException(errorCode, ...)` 即 `ApiException(0, '请求失败')`。对照 `response_policy.dart:34–37` 的 `fail()` 显式做了 `code == 0 ? -1 : code` 归一化，并另有空响应体分支用 `-1`；本拦截器没有这层归一化。于是「code 0」在两个创建点分别代表「没解析出错误码的失败」与「放行」；第 44 行不可解析的错误码文本会得 `-1`，与 `-1` 表示空响应体的语义再次冲突。
- 影响：上游按 `errorCode == 0` 判「无错误」或按 `-1` 判「空响应体」时，业务失败被误判为成功/另一类错误；用户看到空白内容且无重试。
- 证据等级：实锤

### lib/core/api/kugou_api_client.dart:46 拦截器完全不读 `err_code`，与 evaluateResponse 的 mcomment 优先口径相反
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一）、第 14 条（网络响应边界必须校验）、第 29 条（逐端点成功口径必须实测确认）
- 依据：第 42 行 `data['error_code'] ?? data['errcode'] ?? 0`、第 46–47 行 `hasErrorCode` 只检查 `'error_code'`/`'errcode'` 两个键；全文 215 行没有出现 `err_code`。而 `response_policy.dart:39–41` 把 `err_code` 作为**最高优先级**、与 status 无关的失败判定（明确「兼容字符串形态」）。因此 `{'status': 1, 'err_code': '20028'}` 或 `{'err_code': '1234', 'data': {...}}` 在本拦截器里：`status` 解析为 1 → `okStatus=true`、`hasErrorCode=false` → 第 89 行 `handler.next(response)` 放行；`get()`（第 173–178 行）直接把该错误体当成功 `Map` 返回给调用方。REVIEW_SPEC 第三节第 4 条明确列出 `err_code == 0` 是 mcomment 的成功口径。
- 影响：评论类接口的失败响应（含 20028 风控）被静默当作成功数据：评论列表空白、发送评论显示成功但实际未提交、验证流程不触发，且无任何异常/日志。
- 证据等级：实锤（分支事实）；具体端点返回结构未实测（B2/B6 范围）

### lib/core/api/kugou_api_client.dart:38 与 response_policy.dart:24 两套独立成功判定，文件头「全部收敛于此」不成立
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（同一份事实只能有一处权威存储）、第 3 条（契约先行）、第 31 条（注释与行为一致）
- 依据：本文件第 38–90 行 `onResponse` 拦截器内实现了完整成功判定：`int.tryParse('${data['status'] ?? 1}') ?? 1`（第 41 行，不可解析→默认 1=成功）、`warningCodes = {0,151,152,200,201}`（第 60 行）、`okStatus = status==1||status==200`（第 55 行）；`response_policy.dart:23–24` 声称自己是「唯一成功判定入口」，用的却是 `status == 1` 严格相等、`error_code`/`errcode`（第 30 行）、`err_code` 优先（第 40 行）、`_hasData()`（第 57 行）与 `status==0||status==2`（第 49 行）。同一响应在两处可得到相反结论，例如 `{'status': 1, 'error_code': 151, 'data': {...}}`：拦截器 `isWarning=true` 放行（正确），`evaluateResponse` 因 `errorCode=151 != 0 && _hasData(body)` 也放行；但 `{'status': 1, 'error_code': 151}`（无其它键）：拦截器放行、`evaluateResponse` 第 44 行 `_hasData` 为 false → 判失败。错误消息取值顺序也相反：本文件第 81 行 `error_msg→errmsg→error→info`，`response_policy.dart:32` `error→error_msg→errmsg→info`。
- 影响：同一份响应走直连 / 走回退时成功与错误结论、错误文案都可能不同；用户在不同网络条件下对同一操作得到「成功」或「未知错误」两种结果，线上排障无法复现。
- 证据等级：实锤（两套代码事实与差异推演）

### lib/core/api/kugou_api_client.dart:173 `get()/post()` 把 null / 空响应体静默变成 `{}` 成功
- 级别：P2
- 违反：QUALITY_STANDARD 第 16 条（请求失败与确实为空必须语义分离）、第 9 条（静默降级必须留痕）、第 14 条（网络响应边界必须校验）
- 依据：第 175–178 行与第 182–185 行 `return res.data ?? {};`，无任何空体判定、无日志、无异常。第 40 行 `if (data is Map<String, dynamic>)` 更是只校验 Map 形态：`null`、List、String、二进制 body 全部直接落到第 89 行 `handler.next(response)` 不检查；`_dio.get<Map<String,dynamic>>` 遇到非 Map 的 JSON 会抛类型错误（第 13 条）。对照 `response_policy.dart:50–52` 对 `{}` 有专门的 `ApiException(-1, '空响应体（可能被风控拦截）')`，但走 `get()` 的调用方拿到的只是空 Map，除非再主动调用 `evaluateResponse`（本文件从未调用该文件，全文无 `response_policy` import）。
- 影响：风控拦截返回空体、网络受沿途设备返回空串、或上游返回 List/二进制时，调用方拿到 `{}` 并当作「成功但无数据」渲染空列表/空播放页；用户看不到错误提示与重试入口，甚至遇到未捕获类型崩溃。
- 证据等级：实锤（`?? {}` 与类型守卫）；上游空体形态未实测

### lib/core/api/kugou_api_client.dart:18 构造早于 `cookieStoragePath` 设置时，实例永久绑定私有内存 jar，注释声称的「自然切换」不成立
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 18 条（异步/时序结果必须校验有效性）、第 31 条（注释与行为一致）、第 23 条（凭证维度）
- 依据：第 18–21 行构造函数把 `_cookieJar` 一次性绑定到 `sharedCookieJar`（final 字段，第 99 行）；第 132–139 行 `sharedCookieJar` 在 `path == null || path.isEmpty` 时**每次 `return CookieJar()` 新建一个内存 jar 且不缓存**。第 126–131 行注释却写「路径未设置时不缓存 jar（每次重查，**路径就绪后自然切到持久化**）」——对已构造的实例不成立：其 `_cookieJar` 已是私有的内存 jar，路径就绪后只有**新构造**的客户端会拿到 PersistCookieJar，旧实例既不共享也不持久化。多个提前构造的实例各自持有不同 jar。第 149–150 行 `cookieStoragePath` 是可任意改写的静态字段，`_sharedJar`（第 122 行）一旦赋值就没有任何失效逻辑，后写路径被静默忽略。
- 影响：冷启动/低端机上有 Provider 提前构造客户端时，登录 token 只写进那一个实例的内存 jar：其它客户端读不到（评论/播放仍显示未登录），进程退出即丢失（下次冷启动被登出）；日志只有 `debugPrint`，用户侧表现为「刚登录就掉登录 / 登录了但部分功能说未登录」。
- 证据等级：实锤（字段 final + getter 分支 + 无失效逻辑）；启动构造顺序属 B4 范围，未实测

### lib/core/api/kugou_api_client.dart:188 凭证写共享 jar，但 `userid`/`dfid` 只更新本实例；`clearCredentials` 同样只清本实例字段
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存/凭证必须覆盖全部维度、登录身份为权威事实）、第 5 条（同一份事实多处存储且不一致）、第 8 条（契约）
- 依据：第 169–171 行 `userid`/`dfid`/`webglHash` 是**每个实例**各自的可变公开字段；第 204–206 行 `setCredentials` 只写 `await _cookieJar.saveFromResponse(...)` 与 `this.userid = userid`，`if (dfid != null) this.dfid = dfid`。而默认构造的客户端共享同一个 `_sharedJar`（第 132–146 行）。第 209–214 行 `clearCredentials` 只 `await _cookieJar.deleteAll()` 并置本实例 `userid=''`/`dfid=''`。因此：(a) 登录/切号后其它实例的 `userid` 仍是旧值（旧账号签名/匿名混用）；(b) 登出后其它实例 `userid` 仍是已登出账号，cookie 却已清空；(c) `setCredentials(dfid: null)` 时 cookie 被显式写成空值（第 202 行 `Cookie('dfid', dfid ?? '')`）而实例字段 `this.dfid` **保留上一个账号的 dfid**，两者立即分叉。第 210 行注释「用实例自己的 jar」也说明存在多 jar 场景，字段并未随之同步。
- 影响：切号后部分请求仍用旧账号 userid/dfid 签名，出现「显示 A 账号却拿到 B 账号的歌单/权益」串号，或登出后仍能读到旧账号内容（凭证维度缺失导致的越权展示），且难以复现。
- 证据等级：实锤（字段与 setter 代码事实）；直连签名读取哪个实例字段属 B2 范围，未实测

### lib/core/api/kugou_api_client.dart:195 `setCredentials` 把 cookie 固定保存到 `kapi.344977.xyz`，与实际 `baseUrl`（可注入）不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 23 条（凭证维度：域/主机必须进入键）、第 2 条（依赖显式，不得隐藏使用全局常量）、第 14 条（边界）
- 依据：第 195 行 `final uri = Uri.parse(AppConfig.kugouApiBase);`（值见 `app_config.dart:15`），第 204 行 `saveFromResponse(uri, cookies)`；而构造函数第 18/23 行允许 `baseUrl` 注入并成为 `Dio.baseUrl`，两者没有关联。Cookie 未显式设置 `domain`/`path`/`secure`/`expires`（第 196–203 行），完全依赖 `saveFromResponse` 的 uri 推导。若以原生域名或代理域名构造客户端，登录 cookie 绑在 kapi 主机上，请求其它主机时不会携带。
- 影响：注入了非 kapi baseUrl 的客户端登录后所有请求仍是匿名态，用户反复登录成功却持续看到「未登录」或 VIP 权益不生效。
- 证据等级：实锤（uri 与 baseUrl 无关联）；cookie_jar 的 domain 推导行为未实测

### lib/core/api/kugou_api_client.dart:146 `_createCookieJar` 构造失败时把内存 jar 缓存进 `_sharedJar`，降级无退出条件
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发条件、次优行为与恢复条件）、第 5 条（状态单一来源）
- 依据：第 141–146 行 `final jar = _createCookieJar(path); if (jar is! PersistCookieJar) { debugPrint(...WARNING...); } return _sharedJar = jar;`——即使 `_createCookieJar` 在第 106–111 行 catch 后返回普通 `CookieJar()`，第 146 行仍把它赋给静态 `_sharedJar` 并永久复用，之后 `sharedCookieJar` 第 133 行 `if (_sharedJar != null) return _sharedJar!` 直接返回，不再重试创建。第 130 行注释的「降级留痕」有 debugPrint（第 9 条满足），但无恢复/退出条件；`cookieStoragePath` 后续变更也没有使 `_sharedJar` 失效的路径。
- 影响：一次瞬时目录/权限异常就让整个进程生命周期内所有登录都不持久化，用户每次冷启动都被登出，且后续路径恢复也不会自愈。
- 证据等级：实锤（静态字段赋值与早返回）

### lib/core/api/kugou_api_client.dart:101 `catch (e)` 捕获一切对象且 `FileStorage` 的 I/O 失败不在保护范围内
- 级别：P2
- 违反：QUALITY_STANDARD 第 7 条（捕获必须精确到可处理的类型）、第 10 条（编程错误不得进入业务降级）、第 14 条（磁盘读写属数据边界必须校验）、第 6 条（禁止吞掉异常）
- 依据：第 104–111 行 `try { return PersistCookieJar(storage: FileStorage(path)); } catch (e) { ... debugPrint ... }` 用无类型 `catch (e)`，会把 TypeError/AssertionError 等编程错误也降级成内存 jar；该 try 只包住**构造**，而 `setCredentials`（第 204 行 `saveFromResponse`）与 `clearCredentials`（第 211 行 `deleteAll()`）的真实磁盘 I/O 均无任何 try/catch、无返回值校验、无异常转译，属于第 14 条要求校验的边界却完全裸调用。`get()/post()` 的 `_dio` 网络异常同样未包装为领域异常（第 8 条）。
- 影响：磁盘写失败（只读/满/权限变更）时登录写入直接抛未捕获异常，用户看到登录崩溃或点击无响应；捕获过宽又会让真正的实现 bug 被伪装成「cookie 降级」，难以定位。
- 证据等级：实锤（代码事实）；具体 I/O 失败场景未实测

### lib/core/api/kugou_api_client.dart:94 `_dio` 无对称释放点，`Dio get dio` 直接暴露可变资源
- 级别：P2
- 违反：QUALITY_STANDARD 第 20 条（申请资源必须在同一作用域存在对称释放点）、第 25 条（并发/连接资源需有上限）
- 依据：第 22–27 行构造 `Dio(BaseOptions(...))`，第 28–29 行挂两个拦截器；全文 215 行没有 `close()`/`dispose()`/取消订阅，第 165 行 `Dio get dio => _dio;` 把实例直接交给外部。`BaseOptions` 只设了 connect/receive 超时（第 24–25 行），没有 sendTimeout、最大并发连接数、重定向数、响应体积或重试次数上限（第 25 条）。`CookieJar` 与 `PersistCookieJar` 同样无释放。
- 影响：Provider 重建/热重载反复创建客户端时 HTTP 连接池与文件句柄不释放，低端机上长时间使用后请求变慢甚至失败；无限重试/大响应体可能耗尽内存。
- 证据等级：静态推演（生命周期代码事实为实锤；Provider 重建频率属 B4 范围，未实测）

### lib/core/api/kugou_api_client.dart:152 注释把「kapi 按 URL 全局缓存 2 分钟」记为事实，但只对固定写接口加时间戳——登录身份未进缓存键
- 级别：P1
- 违反：QUALITY_STANDARD 第 23 条（缓存键必须覆盖全部影响结果的维度：用户身份）、第 31 条（注释与行为一致）、第 33 条（kapi 包装行为不得作为原生依据）
- 依据：第 153–154 行注释「kapi 对全部 200 响应按 URL 做 2 分钟全局缓存。登录/设备/验证类接口若命中缓存：二维码串号、dfid 复用、短信不下发」明确缓存键**只有 URL**；第 155–162 行 `_needsTimestamp` 只对 12 个固定前缀（登录/注册/验证/写操作/评论/导入）追加 `timestamp` 打散缓存，其余全部读接口（含按 userid/权益/音质/语言返回结果者）URL 相同即复用同一份缓存，`get()`（第 173 行）与 `post()` 也没有任何用户身份维度的键或 Vary 处理。第 33 行 `timestamp` 用毫秒字符串且名称不含单位（第 15 条），同一毫秒内的两次请求仍同键。第 153 行的缓存结论本身没有任何 probe/原生实测留样，且描述的是 kapi Node 层行为（第 33 条）。
- 影响：A 账号与 B 账号在 2 分钟内请求同一 URL 会拿到对方缓存的响应（歌单、权益、评论数、二维码串号），用户看到「串号」数据；写接口仅靠毫秒时间戳也不构成第 21 条要求的去重键。
- 证据等级：静态推演（注释与代码事实实锤；kapi 缓存行为与串号后果未实测，标注未实测）

### lib/core/api/kugou_api_client.dart:49 「实测口径」注释列 3 个端点但无可追溯样本，且 `warningCodes` 靠硬编码集合
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（调用方式必须逐一实测）、第 29 条（返回结构必须实测并留样，匿名/普通/付费三态）、第 33 条（kapi 包装结果需标注原生复核）、第 2 条（魔法值需具名常量）
- 依据：第 49–54 行声称「实测口径：`/search` status=1、`/search/lyric` status=200+errcode=200 是成功、`/comment/music` status=1+errcode=151/152 是警告但有数据」，第 57–60 行 `warningCodes = {0,151,152,200,201}` 与第 65 行 `errorCode == 20028` 均为字面量集合；本文件与 B1 其余文件没有任何样本路径、probe 记录或三态留样引用，也未标注数据来源是否 kapi 包装结果。第 171 行 `webglHash = '11664606328242161144'` 是无来源注释的可变公开魔法常量。第 1 行空行、第 10–12 行连续 3 个空行属遗留空白（第 32 条）。
- 影响：上游错误码口径一变（新增警告码或 20028 换形态），这套集合会把成功判失败或把风控当警告放行，用户看到无歌词/刷屏报错/验证不弹；维护者无法回溯实测依据。
- 证据等级：未实测（本范围无样本）

### 补充核对：ApiException re-export 删除后的引用方 import（仅统计/核对 import 路径有效性，未读范围外源码）
- **磁盘现状**：`lib/core/api/kugou_api_client.dart:4` 仍是 `export '../foundation/errors.dart';`，**re-export 并未删除**；`errors.dart:1` 注释「原位置 re-export 兼容」与之一致。全仓仅此一处 `export errors.dart`。
- **一旦删除该 re-export 会失效的引用方**（依据：各文件 `import` 行 + `ApiException` 标识符出现次数统计，未读其源码内容）：
  - `lib/core/direct/kg_endpoints_playlist.dart:7` 与 `kg_endpoints_search.dart:7` 为 `import '../api/kugou_api_client.dart' show ApiException;` —— 显式依赖被删除的导出名，属硬错误。
  - `lib/core/direct/kg_direct_api_client.dart:24`、`lib/core/utils/friendly_error.dart:3`、`lib/core/widgets/error_retry.dart:7`、`lib/features/auth/data/auth_repository.dart:7`、`lib/features/auth/data/verification_service.dart:3`、`lib/features/auth/presentation/login_page.dart:8`、`lib/features/auth/presentation/verification_guard.dart:5`、`lib/features/comment/presentation/comments_page.dart:7`、`lib/features/mv/data/mv_repository.dart:1`、`lib/features/mv/presentation/mv_player_page.dart:8`、`lib/features/player/data/audio_handler.dart:13`、`lib/features/player/player_provider.dart:5`、`lib/features/playlist/data/playlist_repository.dart:7` 共 13 个文件 import `kugou_api_client.dart` 且文件内出现 `ApiException`，但没有直接 import `foundation/errors.dart`（也没有其它可见 export 链）→ 未定义名。
  - 已直接 import `foundation/errors.dart` 的只有 4 个文件：`kugou_api_client.dart:3`、`response_policy.dart:8`、`lib/core/net/music_api.dart:10`、`lib/features/player/data/player_repository.dart:18`（后两者另有 `show KugouApiClient` 的窄导入或双导入，删除 re-export 后仍可解析）。
- 结论：**「删除 re-export 后是否有引用方漏 import」= 是，15 个文件**（2 个 `show ApiException` + 13 个隐式依赖），当前靠第 4 行 re-export 掩盖；`core/direct`、`core/utils`、`core/widgets` 与 `features/**` 均未在 M1 上移时补上直接 import。
- 级别：P1（若按 v5.1 计划删除该 re-export，编译/分析即大面积失败，功能不可用）；当前磁盘状态下为潜伏项。
- 违反：QUALITY_STANDARD 第 4 条（分层单向依赖：领域异常经 api 层反向导出给 features）、第 8 条（异常契约跨层传播路径不稳定）、第 32 条（兼容层长期不清理）、第 31 条（errors.dart:1 注释把「上移」描述为已完成）
- 影响：当前用户无可见后果；一旦按注释执行清理，登录、评论、MV、播放、歌单等页面全部编译不过，或更隐蔽地因 `show` 名消失而改为捕获其它类型导致错误处理失效。
- 证据等级：实锤（import/export 行与标识符统计）；未对每个范围外文件做 `dart analyze` 验证（不属本批范围，标注未实测）

## 7. `lib/core/api/translate_api.dart`（75 行，完整读）

### lib/core/api/translate_api.dart:56 `first['message']` 未校验 Map 形态即取 `['content']`，且用裸 `as String?`——注释声称的畸形防护未覆盖
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转，必须逐一分支验证类型）、第 14 条（网络响应边界必须校验）、第 31 条（注释与行为一致）
- 依据：第 50–53 行注释自称「`choices[0]` 可能是非 Map…显式验证类型，畸形即退回原文（第 13 条）」，但第 55–56 行 `(first is Map ? first['message'] : null)?['content'] as String?` 只校验了 `first` 是 Map，**没有校验 `first['message']`**：当 `message` 是 String/List/num 时，`?['content']` 对非 Map 的动态下标访问会抛 NoSuchMethodError；当 `content` 是 Map/List/num（例如返回 `{'content': [{'type':'text','text':'...'}]}` 这类多模态格式）时，`as String?` 抛 TypeError。两处异常都不是返回原文，而是从「畸形响应」路径直接抛出。此外第 48 行 `res.data?['choices']` 中 `res.data` 若不是 `Map<String,dynamic>`（Dio 的泛型不校验运行时形态），`?['choices']` 同样会抛。
- 影响：翻译服务返回与采样不同的结构或限流错误体时，歌词翻译不是回退原文而是抛未捕获异常，用户看到歌词页面报错/翻译开关自动关闭，翻译 stream 中断；注释让维护者误以为该分支已防护。
- 证据等级：静态推演（Dart 动态下标/`as` 语义为实锤；上游畸形形态未实测）

### lib/core/api/translate_api.dart:49 与 :57 所有失败/限流一律静默回退原文，无日志、无失败语义
- 级别：P1
- 违反：QUALITY_STANDARD 第 6 条（禁止吞掉异常：转译/日志/明确降级值至少其一）、第 9 条（静默降级必须留痕）、第 11 条（降级必须有明确触发条件、次优行为、恢复条件）、第 16 条（请求失败与确实为空必须语义分离）
- 依据：`translateLines` 有三处 `return lines`（第 49 行 choices 非 List/空、第 57 行 content 为 null 或空串、第 62 行译文行数不足时逐行补原文），全部返回**与输入原文不可区分**的 `List<String>`；调用方无法判断是「翻译成功但译文恰好相同」还是「限流/截断/畸形」；无任何 `debugPrint`/日志，返回类型也不是结果对象。第 31–42 行 `_dio.post` 未包 try/catch，DioException（含 504 网关超时、412 WAF、429 限流）直接抛出，与上述「静默回退」是两条形态完全不同的失败路径（第 8 条）。第 12 行注释明确记录过 412，第 44 行注释明确记录过「模型限流」，说明这两类失败是已知且发生过的。
- 影响：504/限流时歌词翻译大面积失败：要么整页歌词保持原文且无任何提示/重试入口，要么由上层收到 DioException 显示通用错误；用户以为「翻译功能坏了」但线上无日志可定位是超时、限流还是响应畸形。任务书特别点名的「翻译 504」在本文件没有专门分支或可观测性。
- 证据等级：实锤（三处静默 return + 无 catch）；504 实际返回体未实测

### lib/core/api/translate_api.dart:60 译文被 `trim()` 且超出行数被丢弃，行数/内容无损性契约未校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 17 条（数值/索引精度不容隐式截断）、第 14 条（边界校验）、第 21 条（幂等：同一输入应得同一结果）
- 依据：第 58 行 `content.split('\n')`，第 60–63 行 `List.generate(lines.length, (i) => i < translated.length ? translated[i].trim() : lines[i])`：① 译文行数**多于** `lines.length` 时被静默丢弃（无校验、无日志）；② 每行 `.trim()` 会抹掉歌词行首/行尾的空白（对含时间轴 KRC 或缩进格式的歌词破坏对齐）；③ 译文行数不足时混入原文（第 62 行），结果成为「部分译文 + 部分原文」的混合数组，调用方看到的仍是 `List<String>` 成功态；④ prompt 第 28–29 行把歌词原文直接插入提示词，原文含 `\n\n` 或提示词注入文本时同样无转义校验。
- 影响：逐字歌词/带缩进歌词翻译后错位或丢行，用户看到译文与音频不同步、部分行仍是原文；混合结果无法从返回值识别，重试也不会改变。
- 证据等级：实锤（生成逻辑）；模型实际输出格式未实测

### lib/core/api/translate_api.dart:73 `translateText` 对 `lines.first` 无空集合守卫
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（边界必须校验）、第 12 条（禁止无依据的非空断言）、第 3 条（契约：失败时返回语义）
- 依据：第 71–73 行 `final lines = await translateLines(lines: [text], ...); return lines.first;`。`translateLines` 第 26 行在输入为空时返回 `[]`，且所有分支都返回 `lines.length` 长度的数组（第 49/57 行返回入参、第 60 行 `List.generate(lines.length, ...)`），所以当前传入 `[text]` 时不会为空——但 `text` 为 `''` 时第 49/57 行会返回 `['']`，`lines.first` 给出空串成功值而非失败语义；该 getter 对「外部传入空文本」及未来 `translateLines` 返回空集合的改动没有守卫，`first` 会抛 StateError。第 66 行注释「用于 i18n 脚本」说明调用方可能是离线工具，异常形态更不可控。
- 影响：空文本翻译静默返回空串（脚本可能把空串写进语言资源），或在返回集合变空时崩溃；i18n 脚本/单条翻译调用方拿到无提示的失败结果。
- 证据等级：静态推演（`first` 契约与当前数组长度事实为实锤）

### lib/core/api/translate_api.dart:21 `max_tokens=4096` 与 40 行批次上限无约束关系，且本文件没有按 `lyricTranslateMaxLinesPerBatch` 切批
- 级别：P2
- 违反：QUALITY_STANDARD 第 25 条（所有资源必须有上限）、第 2 条（魔法值/配置应显式注入）、第 15 条（单位必须显式）
- 依据：`app_config.dart:28` 定义 `lyricTranslateMaxLinesPerBatch = 40`，但本文件 75 行内**从未引用该常量**（唯一 import 是 `app_config.dart`，使用到第 32/34/39 行的三个常量）；`translateLines` 第 26 行只判 `lines.isEmpty`，随后第 27 行把整个 `lines` 一次性 `join('\n')` 发单个请求，没有按 40 行切分。第 39 行 `max_tokens: AppConfig.lyricTranslateMaxTokens` 固定 4096，与入参行数/文本长度无关联；单次请求体大小、并发翻译请求数、重试次数均无上限。`_dio` 只设 connect 20 秒、receive 60 秒（第 8–9 行），无 sendTimeout、无取消机制。任务书点名的「翻译 504」与「60 秒接收超时」叠加时没有退避/切批/重试上限。
- 影响：长歌词一次性提交超长 prompt，触发上游 504/截断后整批翻译失败或只译出前半段；用户看到大量歌词行仍是原文；60 秒等待期间界面转圈且无法取消，低端机/弱网下尤其明显。
- 证据等级：实锤（常量未引用 + 无切批）；504 触发阈值未实测

### lib/core/api/translate_api.dart:5 无并发世代/请求互斥，`TranslateApi` 也无资源释放点
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 19 条（互斥闸门成对且归属同一所有者）、第 20 条（Dio 资源无对称释放）、第 22 条（并发假设必须写明）
- 依据：类只有 `final Dio _dio`（第 19 行）与两个方法，没有请求序号/generation、没有 `CancelToken`、没有 in-flight 去重、没有 `close()`；`translateLines` 第 31 行 `await _dio.post` 之后直接解析并返回（第 43–63 行），没有任何「我是否仍是当前有效请求」的校验，也没有任何注释声明「本类假设单调用者」（第 22 条）。多个歌词翻译请求可并行发出，结果由调用方自行按到达顺序覆盖。
- 影响：用户快速切歌或切换目标语言时，先发的大批次翻译后返回，把旧歌/旧语言的译文写入当前歌词（B5 范围的 stream 插入若未另做世代校验则串译文）；取消页面后请求仍占用连接，60 秒内不释放。
- 证据等级：静态推演（本文件代码事实实锤；调用方是否做世代校验属 B5 范围，未实测）

### lib/core/api/translate_api.dart:12 「B 站 WAF 拦截无 UA 请求（412）」等注释无可追溯实测记录
- 级别：P3
- 违反：QUALITY_STANDARD 第 28 条（请求方法/地址/参数集合/请求头必须逐一实测）、第 29 条（返回结构必须实测并留样）、第 31 条（注释应记录来源与原因）
- 依据：第 12 行 WAF/412 结论、第 44–47 行「上游返回 `{"choices":[]}`」、第 50–53 行「`[null]` / `["str"]` 畸形形态」均为对第三方端点的行为断言，但本文件与本批范围内没有样本路径、probe 记录编号或三态留样引用；请求体第 33–41 行的 `model`/`messages`/`temperature`/`max_tokens`/`chat_template_kwargs`（含 `enable_thinking: false` 这一模型专属开关）也无来源说明。`app_config.dart:16–19` 的模型名与端点同样无留样（见第 5 节）。
- 影响：第三方接口一旦变更（字段名、choices 结构、WAF 规则），现有 UA/请求体/解析分支无法据留样快速核对，翻译功能静默失效或抛异常（见本节前两条）。
- 证据等级：未实测（本范围无样本）

### lib/core/api/translate_api.dart:66 「用于 i18n 脚本」的运行时方法留在 App 的 core/api 内，且与运行时歌词翻译共用同一凭据/端点
- 级别：P3
- 违反：QUALITY_STANDARD 第 1 条（单一职责）、第 32 条（仅供「以后可能用」的抽象/离线工具代码混入运行时）
- 依据：第 66–74 行 `translateText` 文档注释写明「翻译单条文本（**用于 i18n 脚本**）」，该方法只是 `translateLines(lines:[text])` 的薄包装，与歌词翻译共用第 7–17 行的 Dio 实例、UA 与端点；本文件内无其它调用方，脚本侧不在本批范围。
- 影响：无直接用户可见后果；离线工具用途与运行时功能耦合，端点/UA 变更会同时影响两者，且运行时包体携带一个不被 App 使用的入口。
- 证据等级：静态推演（本范围无调用点；脚本目录未读，标注未实测）

---

## 8. 逐文件 `dart analyze` 结果（收尾静态检查）

命令：`export PATH=$PATH:/opt/dart/bin && dart analyze <file>`，工作目录 `/var/minis/workspace/TiernanMusic`；Dart SDK 3.13.7 stable。项目无 `.dart_tool/package_config.json`（未执行 `pub get`，按任务书禁止），因此所有 `package:flutter/*`、`package:dio/*`、`package:cookie_jar/*` 的 `uri_does_not_exist` 及其级联的 `undefined_method` / `undefined_class` 均为**预期噪音**（任务书明示「Flutter/三方包符号缺失是预期噪音，项目自有类报错才是真错误」）。两个 `dead_code` 警告的成因同为包缺失后的类型推断退化（`translate_api.dart:56:44` 的 `?['content']`、`kugou_api_client.dart:142:35` 的 `is! PersistCookieJar`），亦归入噪音；但其所指代码本身的边界缺陷已在第 7/6 节按阅读事实单独记录。

### 8.1 `lib/core/foundation/errors.dart`（原文）
```
Analyzing errors.dart...
No issues found!
[exit=0]
```
- 噪音 0 / 项目自有类错误 0 → **通过**

### 8.2 `lib/core/domain/quality.dart`（原文）
```
Analyzing quality.dart...

  error - quality.dart:1:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist

1 issue found.
[exit=3]
```
- 噪音 1（三方包 URI）/ 项目自有类错误 0 → **通过（过滤噪音后）**
- 注：因该 URI 解析失败，analyzer 不会报 `unused_import`；第 1 行未使用 import 的结论来自全文逐行阅读（第 2 节第 1 条，实锤）。

### 8.3 `lib/core/domain/song.dart`（原文）
```
Analyzing song.dart...
No issues found!
[exit=0]
```
- 噪音 0 / 项目自有类错误 0（`import 'quality.dart';` 与 `AudioQuality` 解析正常）→ **通过**

### 8.4 `lib/core/domain/response_policy.dart`（原文）
```
Analyzing response_policy.dart...
No issues found!
[exit=0]
```
- 噪音 0 / 项目自有类错误 0（`import '../foundation/errors.dart';` 与 `ApiException` 解析正常）→ **通过**

### 8.5 `lib/core/config/app_config.dart`（原文）
```
Analyzing app_config.dart...
No issues found!
[exit=0]
```
- 噪音 0 / 项目自有类错误 0 → **通过**

### 8.6 `lib/core/api/kugou_api_client.dart`（原文，30 issues）
```
Analyzing kugou_api_client.dart...

  error - kugou_api_client.dart:2:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. - uri_does_not_exist
  error - kugou_api_client.dart:5:8 - Target of URI doesn't exist: 'package:dio_cookie_manager/dio_cookie_manager.dart'. - uri_does_not_exist
  error - kugou_api_client.dart:6:8 - Target of URI doesn't exist: 'package:cookie_jar/cookie_jar.dart'. - uri_does_not_exist
  error - kugou_api_client.dart:7:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. - uri_does_not_exist
  error - kugou_api_client.dart:22:16 - The method 'Dio' isn't defined for the type 'KugouApiClient'. - undefined_method
  error - kugou_api_client.dart:22:20 - The method 'BaseOptions' isn't defined ... - undefined_method
  error - kugou_api_client.dart:28:27 - The method 'CookieManager' isn't defined ... - undefined_method
  error - kugou_api_client.dart:29:27 - The method 'InterceptorsWrapper' isn't defined ... - undefined_method
  error - kugou_api_client.dart:76:28 - The method 'DioException' isn't defined ... - undefined_method
  error - kugou_api_client.dart:94:9 - Undefined class 'Dio'. - undefined_class
  error - kugou_api_client.dart:99:9 - Undefined class 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:101:10 - Undefined class 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:105:16 - The method 'PersistCookieJar' isn't defined ... - undefined_method
  error - kugou_api_client.dart:105:42 - The method 'FileStorage' isn't defined ... - undefined_method
  error - kugou_api_client.dart:109:9 - The method 'debugPrint' isn't defined ... - undefined_method
  error - kugou_api_client.dart:113:12 - The method 'CookieJar' isn't defined ... - undefined_method
  error - kugou_api_client.dart:122:10 - Undefined class 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:132:10 - Undefined class 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:137:7 - The method 'debugPrint' isn't defined ... - undefined_method
  error - kugou_api_client.dart:139:14 - The method 'CookieJar' isn't defined ... - undefined_method
  error - kugou_api_client.dart:142:17 - The name 'PersistCookieJar' isn't defined, so it can't be used in an 'is' expression. - type_test_with_undefined_name
  error - kugou_api_client.dart:143:7 - The method 'debugPrint' isn't defined ... - undefined_method
  error - kugou_api_client.dart:165:3 - Undefined class 'Dio'. - undefined_class
  error - kugou_api_client.dart:166:3 - Undefined class 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:197:7 - The method 'Cookie' isn't defined ... - undefined_method
  error - kugou_api_client.dart:198:7 - The method 'Cookie' isn't defined ... - undefined_method
  error - kugou_api_client.dart:200:7 - The method 'Cookie' isn't defined ... - undefined_method
  error - kugou_api_client.dart:201:7 - The method 'Cookie' isn't defined ... - undefined_method
  error - kugou_api_client.dart:202:7 - The method 'Cookie' isn't defined ... - undefined_method
warning - kugou_api_client.dart:142:35 - Dead code. - dead_code

30 issues found.
[exit=3]
```
- 噪音 29 error + 1 warning（全部来自 4 个缺失三方包及其级联）／项目自有类错误 0：`AppConfig`（第 9 行）、`ApiException`（第 3 行）、`export '../foundation/errors.dart'`（第 4 行）均解析正常，无任何项目自有类/相对 import 报错 → **通过（过滤噪音后）**

### 8.7 `lib/core/api/translate_api.dart`（原文，5 issues）
```
Analyzing translate_api.dart...

  error - translate_api.dart:1:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. - uri_does_not_exist
  error - translate_api.dart:7:16 - The method 'Dio' isn't defined for the type 'TranslateApi'. - undefined_method
  error - translate_api.dart:7:20 - The method 'BaseOptions' isn't defined ... - undefined_method
  error - translate_api.dart:19:9 - Undefined class 'Dio'. - undefined_class
warning - translate_api.dart:56:44 - Dead code. - dead_code

5 issues found.
[exit=3]
```
- 噪音 4 error + 1 warning（缺失 dio 及级联）／项目自有类错误 0：`AppConfig`（第 3 行）解析正常 → **通过（过滤噪音后）**

### 8.8 汇总
| 文件 | 原始 issues | 过滤后项目自有类错误 | 结论 |
|---|---|---|---|
| `lib/core/foundation/errors.dart` | 0 | 0 | 通过 |
| `lib/core/domain/quality.dart` | 1 error | 0 | 通过（噪音：flutter URI） |
| `lib/core/domain/song.dart` | 0 | 0 | 通过 |
| `lib/core/domain/response_policy.dart` | 0 | 0 | 通过 |
| `lib/core/config/app_config.dart` | 0 | 0 | 通过 |
| `lib/core/api/kugou_api_client.dart` | 29 error + 1 warning | 0 | 通过（噪音：dio/cookie_jar/flutter URI 级联） |
| `lib/core/api/translate_api.dart` | 4 error + 1 warning | 0 | 通过（噪音：dio URI 级联） |

7/7 文件均已逐文件执行 `dart analyze`；过滤噪音后项目自有类 0 错误，**7 文件全通过**。此结论仅为静态解析结果，按 QUALITY_STANDARD 第八章「编译通过不构成正确性证据」，不作为本报告任何问题的否定依据。

---

## 9. 问题清单（按级别排序）

共 **52 条**：P0 = 0，P1 = 15，P2 = 19，P3 = 18。

### P1（15 条）
| # | 位置 | 简述 | 违反条 | 证据等级 |
|---|---|---|---|---|
| 1 | `response_policy.dart:36` | `body['ssaCode'] as String?` 裸强转，错误分支自身抛 TypeError，绕过 ApiException 契约 | 13/8/10 | 静态推演 |
| 2 | `response_policy.dart:28` | `codeOf` 把浮点/带空白/非数字 err_code 折叠为 0，错误码被判成功 | 13/14/9 | 实锤 |
| 3 | `response_policy.dart:44` | `_hasData` 兜底只排除 3 个键，status=1 + error_code 的失败响应几乎恒判成功 | 3/8/29 | 实锤 |
| 4 | `app_config.dart:10` | kapi「运行期绝不调用/仅供 CookieJar 占位」注释与 `Dio.baseUrl` 真实请求冲突 | 27/31/33 | 静态推演 |
| 5 | `kugou_api_client.dart:76` | 回退路径抛 DioException(包装 ApiException)、策略路径抛裸 ApiException，异常双形态 | 8/3 | 实锤 |
| 6 | `kugou_api_client.dart:65` | DioException 形态的 20028 使 `requiresVerification` 恒 false，验证流程不触发 | 8/9 | 静态推演 |
| 7 | `kugou_api_client.dart:79` | status 类失败造出 `ApiException(0)`，与「0=无错」及 `-1=空响应体` 语义冲突 | 8/3 | 实锤 |
| 8 | `kugou_api_client.dart:46` | 拦截器不读 `err_code`，mcomment/20028 错误体被 `get()` 当成功数据返回 | 8/14/29 | 实锤 |
| 9 | `kugou_api_client.dart:38` | 与 `evaluateResponse` 两套独立成功判定，同一响应可得相反结论 | 5/3/31 | 实锤 |
| 10 | `kugou_api_client.dart:18` | 构造早于路径设置时实例永久绑定私有内存 jar，注释「自然切换」不成立 | 5/18/31/23 | 实锤 |
| 11 | `kugou_api_client.dart:188` | 凭证写共享 jar 但 `userid`/`dfid` 只更新本实例，切号/登出后实例间分叉 | 23/5/8 | 实锤 |
| 12 | `kugou_api_client.dart:152` | kapi 按 URL 全局缓存 2 分钟，仅固定写接口加时间戳，用户身份未进缓存键 | 23/31/33 | 静态推演（缓存行为未实测） |
| 13 | `kugou_api_client.dart` 补充核对 | re-export 删除后 15 个引用方漏 import（2 个 `show ApiException` + 13 个隐式依赖）；磁盘上 re-export 仍在 | 4/8/32/31 | 实锤（import 统计） |
| 14 | `translate_api.dart:56` | `message` 未校验形态即 `['content'] as String?`，注释声称的畸形防护不完整 | 13/14/31 | 静态推演 |
| 15 | `translate_api.dart:49`/`:57` | 限流/畸形/空译文一律静默回退原文无留痕，504 直接抛 DioException，两条完全不同失败路径 | 6/9/11/16 | 实锤（504 未实测） |

### P2（19 条）
| # | 位置 | 简述 | 违反条 | 证据等级 |
|---|---|---|---|---|
| 16 | `errors.dart:10` | `errorCode` 为 int 且无外部形态归一化入口，创建点需自行保证 | 13/3 | 静态推演 |
| 17 | `quality.dart:17`/`:92` | magic_ 前缀「由谁补」两处注释互相矛盾，可致双前缀静默失败 | 31/28 | 静态推演（未实测） |
| 18 | `quality.dart:100` | 未知/缺失音质值静默降 q128，文件自身注释称此为红线 | 9/11/14 | 实锤 |
| 19 | `song.dart:76` | `str()` 对任意外部对象 `'$v'` 字符串化，Map/List 写进 hash/封面/歌名 | 13/14 | 实锤 |
| 20 | `song.dart:79` | `'$v'.isNotEmpty` 把 0/false/[]/{} 当有效值，缺失与脏值不分、封面回退被跳过 | 16/14 | 实锤 |
| 21 | `song.dart:126` | `duration > Duration.zero` 作已赋值哨兵，零/负值可被后续毫秒键覆盖 | 17/14/31 | 实锤 |
| 22 | `song.dart:161` | 无 quality 字段被固化为 q128（未知变已知），可污染音质缓存维度 | 16/9/23 | 静态推演 |
| 23 | `song.dart:170` | `==` 仅按 hash 且空 hash 非自反，`localPath`/`quality` 变化在集合去重中不可见 | 3/14/30 | 实锤 |
| 24 | `response_policy.dart:50` | 空响应体仅覆盖字面 `{}`；无 status / 字符串 status 的错误体落第 54 行成功 | 14/16/9 | 实锤 |
| 25 | `response_policy.dart:39` | `err_code` 无条件覆盖全端点，与注释「mcomment」限定及歌词 status=200 口径冲突 | 3/29/31 | 静态推演 |
| 26 | `kugou_api_client.dart:173` | `get()/post()` 把 null/空体静默变 `{}` 成功；非 Map body 直接放行 | 16/9/14 | 实锤 |
| 27 | `kugou_api_client.dart:195` | 凭证 cookie 固定保存到 kapi 域，与可注入 `baseUrl` 无关 | 23/2/14 | 实锤 |
| 28 | `kugou_api_client.dart:146` | 构造失败的内存 jar 被永久缓存进 `_sharedJar`，降级无恢复/退出条件 | 11/5 | 实锤 |
| 29 | `kugou_api_client.dart:101` | `catch (e)` 无类型过滤；真实磁盘 I/O 与网络异常反而裸调用无包装 | 7/10/14/6 | 实锤 |
| 30 | `kugou_api_client.dart:94` | Dio/CookieJar 无对称释放，且无并发/体积/重试上限 | 20/25 | 静态推演 |
| 31 | `translate_api.dart:60` | 译文 trim + 超行丢弃 + 不足补原文，产生不可识别的混合结果 | 17/14/21 | 实锤 |
| 32 | `translate_api.dart:73` | `translateText` 用 `lines.first` 无空集合守卫，空文本静默返回空串 | 14/12/3 | 静态推演 |
| 33 | `translate_api.dart:21` | 未引用 40 行批次常量、无切批/请求体/并发/重试上限，504 场景 60s 不可取消 | 25/2/15 | 实锤（504 未实测） |
| 34 | `translate_api.dart:5` | 无世代校验/互斥/CancelToken/close，并行翻译结果可乱序覆盖 | 18/19/20/22 | 静态推演 |

### P3（18 条）
| # | 位置 | 简述 | 违反条 | 证据等级 |
|---|---|---|---|---|
| 35 | `errors.dart:1` | 「原位置 re-export 兼容」注释描述历史状态（当前 re-export 在 kugou_api_client.dart:4） | 31/32 | 实锤 |
| 36 | `errors.dart:24` | 硬编码 20028 却注释「唯一常量见 response_policy.dart」，自相矛盾 | 31/2 | 静态推演 |
| 37 | `errors.dart:29` | `toString()` 丢弃 ssaCode/verifyUrl/body，20028 日志不可定位 | 9 | 静态推演 |
| 38 | `quality.dart:1` | 未使用的 `package:flutter/foundation.dart` import 留在纯领域枚举 | 32/4 | 实锤 |
| 39 | `quality.dart:92` | switch 内声称「蝰蛇/魔法档显式解析」却无 case；:5 排序注释与声明顺序相反 | 31/32 | 实锤 |
| 40 | `quality.dart:43` | 「VIP 态实测」「匿名可用」无三态留样/来源标注 | 29/28/33 | 未实测 |
| 41 | `song.dart:67` | 「实测字段真值」注释无可追溯样本，未标注是否 kapi 包装结果 | 29/28/33 | 未实测 |
| 42 | `song.dart:3` | 游离 doc comment 未附着任何声明 | 32/31 | 实锤 |
| 43 | `response_policy.dart:31` | `msgOf()` 空串短路、Map 型 info 被整段塞进错误文案 | 14/9/13 | 实锤 |
| 44 | `response_policy.dart:24` | 「全仓 20028 唯一出口」与 errors.dart 硬编码判定并存，两处真相来源 | 5/2/31 | 实锤 |
| 45 | `response_policy.dart:15` | `ApiOutcome.fail(null)` 合法且 `isOk==true`，失败/成功契约可混同（本范围无触发点） | 3/16 | 实锤 |
| 46 | `response_policy.dart:23` | 「行为逐分支保持」等上游断言无实测/三态留样 | 28/29/33 | 未实测 |
| 47 | `app_config.dart:33` | 三套语言集合纯靠人工同步，注释自述不一致风险 | 5/31 | 静态推演 |
| 48 | `app_config.dart:16` | 翻译端点/模型名/批次/token 上限硬编码无实测依据 | 28/29/2 | 未实测 |
| 49 | `app_config.dart:25` | 缓存配置只有 90 秒时间窗，无任何条目数/体积/并发上限常量 | 15/25 | 未实测 |
| 50 | `kugou_api_client.dart:49` | 「实测口径」+ warningCodes + 20028 + webglHash 字面量无留样；文件首/中遗留空行 | 28/29/33/2/32 | 未实测 |
| 51 | `translate_api.dart:12` | WAF 412 / choices 空 / 畸形形态等注释无可追溯实测记录 | 28/29/31 | 未实测 |
| 52 | `translate_api.dart:66` | 「用于 i18n 脚本」的 `translateText` 混入运行时 core/api，本范围无调用方 | 1/32 | 静态推演 |

### 特别核对项小结（任务书点名）
- **`evaluateResponse` 的 err_code 字符串/数值形态**：仅支持 int 与纯整数字符串；double、`' 20028 '`、`'20028\n'`、非数字一律折叠为 0（放行）。`kugou_api_client.dart` 的拦截器完全不读 `err_code`，两处口径相反。见 P1 #2/#8、P2 #25。
- **空响应体**：`response_policy.dart:50` 仅对字面 `{}` 给出 `ApiException(-1, '空响应体（可能被风控拦截）')`；`kugou_api_client.dart:173–185` 的 `res.data ?? {}` 把空体变成成功空 Map，且本文件从未调用 `evaluateResponse`。见 P2 #24/#26。
- **ApiException re-export 删除后漏 import**：磁盘上 `kugou_api_client.dart:4` 的 `export '../foundation/errors.dart';` **未删除**；若删除，15 个引用方（2 个 `show ApiException`、13 个隐式依赖）失效，仅 4 个文件有直接 `foundation/errors.dart` import。见 P1 #13。
- **P0 = 0**：本范围未发现可直接导致崩溃/数据损坏/重复提交且证据为实锤的项；最接近崩溃的 `as String?` / 动态下标 / `first` 均为静态推演且需特定上游形态，按分级纪律列为 P1/P2。

---

## 10. 复核通过项（本范围确认到位的设计）

以下 12 项为逐行完整阅读后**确认到位**、且不构成第 9 节问题的设计（凡已有对应问题的部分，在该条末尾注明「不含」的范围，避免与问题清单冲突）。

1. **`song.dart:38–62` `copyWith` 用独立布尔参数 `clearLocalPath` 表达「清除 nullable 字段」语义。** 明确区分「不传」与「传 null」两种意图，编译器可检查，避免 `null ?? this.localPath` 使「清理失效本地源」变成 no-op；符合第 3 条（契约显式）、第 16 条（缺失与清除语义分离）。
2. **`song.dart:162–165` `localPath` 在使用前做了 `is String` + `isNotEmpty` 双条件校验。** 是本文件对外来字段少数按类型分支验证后再取值的地方，符合第 13/14 条（不含第 9 节 #19/#20 所指的 `str()` 路径）。
3. **`song.dart:87`、`:98`、`:103` 对 `singer`/`info`/`trans_param` 的容器形态做了 `is List` / `is Map` 守卫后才取下标。** 避免了上游字段为标量时的直接下标崩溃，符合第 13 条（不含裸 `Map` 无类型参数与字符串化问题）。
4. **`errors.dart:5–23` `ApiException` 以 `implements Exception` 定义，字段 `errorCode`/`message` 必需、验证上下文 `ssaCode`/`verifyUrl`/`body` 可选且带来源注释。** 类型边界清晰，20028 场景所需上下文有专门字段承载，符合第 3/8 条（不含 #36/#37 的硬编码与 `toString` 覆盖度）。
5. **`response_policy.dart:10` + `:64–66` 把 20028 定义为具名常量 `kVerificationRequired` 并在 `requiresVerification(Object? e)` 中先做 `is ApiException` 类型判断再比较。** 提供了可枚举的验证判定出口，符合第 2/7 条（不含 #44 所指的 `errors.dart:24` 第二处硬编码）。
6. **`response_policy.dart:50–52` 对字面空响应体 `{}` 给出专门 `ApiException(-1, '空响应体（可能被风控拦截）')`，并携带 `ssaCode` 与原始 `body`。** 失败可观测、上下文可追溯，符合第 9/16 条（不含 #24 所指「仅覆盖字面 `{}`」的范围限制）。
7. **`response_policy.dart:13–21` `ApiOutcome` 用 `ok`/`fail` 两个命名构造子与 `isOk`/`needsVerification` 派生 getter 表达结果，失败侧不返回数据体。** 成功/失败二态在类型上是可穷尽的，符合第 3/16 条的设计意图（不含 #45 所指 `fail(null)` 的类型洞）。
8. **`app_config.dart:1–2` `AppConfig` 私有构造 + 全 `static const` 字段，无实例状态、无隐藏依赖。** 配置作为单一常量容器，符合第 1/5 条（不含 #48/#49 的取值依据与上限配套问题）。
9. **`kugou_api_client.dart:199–203` `setCredentials` 对 `t1`/`auth`/`dfid` 为 null 时显式写空 Cookie 清除旧值。** 切号时不会残留上一账号的凭证，符合第 23 条（不含 #11 所指实例字段 `userid`/`dfid` 未跨实例同步）。
10. **`kugou_api_client.dart:135–139` 路径未就绪时返回内存 jar 但**不写入**静态 `_sharedJar`，并输出 `debugPrint` 留痕；`:108–110` 构造失败降级也有带 path 与异常对象的日志；`:209–211` `clearCredentials` 使用实例自己的 jar 而非全局共享 jar。** 三处都体现了「降级留痕 / 不误清他人状态」的显式设计，符合第 9 条（不含 #10/#28 所指的实例绑定与无恢复条件）。
11. **`kugou_api_client.dart:23–26` 显式设置 `connectTimeout: Duration(seconds: 20)` 与 `receiveTimeout: Duration(seconds: 30)`；`:152–162` 对登录/验证/写操作/评论等固定前缀追加毫秒时间戳以打散上游 URL 缓存。** 单位用 `Duration` 表达而非裸整数，写操作防缓存有明确清单，符合第 15/21 条意图（不含 #12/#30 所指身份维度缺失与其它上限缺失）。
12. **`translate_api.dart:26`、`:48–57`、`:60–63` 分层校验：空输入早返回、`choices is! List || choices.isEmpty` 显式判型与判空、`first is Map` 守卫、`content == null || trim().isEmpty` 回退原文、按 `lines.length` 生成并以原文补齐。** 对第三方返回的多层畸形都有对应分支且始终返回与入参等长的数组，符合第 13/14/17 条（不含 #14/#15/#31 所指 `message` 形态、静默无留痕与 trim/超行截断问题）。

补充确认（不计入 12 项）：`kugou_api_client.dart:4` 的 `export '../foundation/errors.dart';` **当前仍存在**，故磁盘现状下所有引用 `ApiException` 的文件都能解析，不存在即时编译失败；7/7 文件 `dart analyze` 过滤三方包噪音后项目自有类 0 错误（第 8 节）。

---

## 11. 未做项与边界说明

- 未读 B2–B8 范围文件（任务书仅授权本批 B1 范围业务代码）：因此 `KgSharedParams.songUrl` 是否补 `magic_` 前缀、直连 `_wrap`→ResponsePolicy 的实际调用链、`GetApplicationDocumentsDirectory` 与 `cookieStoragePath` 的真实设置时序、缓存键实现、歌词翻译 stream 的世代校验、各上游端点真实返回形态，均按「静态推演 / 未实测」标注，未作为实锤依据。
- 未执行 `dart pub get` / `flutter` / 构建 / 测试 / 启动服务 / 安装 SDK（任务书绝对禁止），故无 `.dart_tool/package_config.json`，`dart analyze` 的三方包噪音按任务书口径过滤；未对范围外 15 个 re-export 引用方逐个跑 analyze（仅统计 import 行与标识符出现，标注未实测）。
- 未运行任何 probe 脚本、未联网请求任何原生域名或 kapi、未采集匿名/普通/付费三态返回样本；凡涉及「上游返回什么」的结论一律标注「未实测」，并按第 33 条指出 kapi 包装结果不得作为原生依据。
- 未读 `docs/v51_cross_b*_merged.md`、其它批报告及任务书禁止的历史审查报告（防锚定）；未修改任何代码文件、pubspec.yaml、AndroidManifest.xml、Kotlin、CI yml；唯一写入文件为本报告。
- 报告只列问题与影响，未给出修复建议、未给出代码片段。

