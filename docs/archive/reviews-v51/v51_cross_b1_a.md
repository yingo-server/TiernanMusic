# v5.1 交叉审查 B1 视角 A：功能正确性

- 范围：`lib/core/foundation/errors.dart`、`lib/core/domain/quality.dart`、`song.dart`、`response_policy.dart`、`lib/core/config/app_config.dart`、`lib/core/api/kugou_api_client.dart`、`lib/core/api/translate_api.dart`（7 个文件，719 行）
- 视角：A 功能正确性（链路闭环、参数/返回契约、状态机、单位、字段形态）
- 依据：`docs/QUALITY_STANDARD.md`（33 条）、`docs/REVIEW_SPEC.md`；冲突以 QUALITY_STANDARD 为准
- 约束：只读源码；唯一写入本报告；每读完一个文件立即追加结论；只报问题，不给修复建议

---

## 1. `lib/core/foundation/errors.dart`（30 行，已完整读）

### `lib/core/foundation/errors.dart`:27 20028 并未收敛为「唯一常量」，判定与注释自相矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 2 条、第 5 条
- 依据：文件头声明「20028 判定收敛在 [needsVerification]，其他层不得重复硬编码错误码」；`needsVerification` 本身又写 `errorCode == 20028; // 唯一常量见 response_policy.dart`。本文件没有引用 `response_policy.dart` 中任何具名常量，而是直接写字面量 `20028`；本文件的上移位置即「唯一判定出口」却仍保留一份字面量。稍后读取 `response_policy.dart` 全文后再核定重复常量是否存在。
- 影响：若验证错误码在未来变更，判定点与 `response_policy.dart` 的常量可能不同步；上层依据 `needsVerification` 的分支会放过/误判风控验证请求，用户遇到风控时不再弹出验证入口。
- 证据等级：实锤（本文件字面量与注释/文件头冲突；与 `response_policy.dart` 是否重复常量待全文核对）

### `lib/core/foundation/errors.dart`:3 注释宣称的「原位置 re-export 兼容」与本目录文件布局待核实
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条、第 31 条
- 依据：文件头写明「原位置 re-export 兼容」，但本文件未提供任何 `export`；原位置是否存在兼容层需按 import 路径有效性核对，不能以注释作为事实。
- 影响：兼容性说明误导维护者；若旧路径导入失效，依赖旧路径的调用方在迁移后出现编译错误，用户侧表现为相关构建/功能不可用；该结论仅为静态风险，需核对路径后裁定。
- 证据等级：静态推演（待 import 路径核对）

---

## 2. `lib/core/domain/quality.dart`（102 行，已完整读）

### `lib/core/domain/quality.dart`:1 上移后残留未使用的 Flutter foundation 导入
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条
- 依据：首行 `import 'package:flutter/foundation.dart';`，全文件 102 行内没有任何来自该库的符号（无 `@immutable`、`debugPrint`、`kDebugMode` 等）；本文件只定义纯 Dart 枚举与字符串解析。
- 影响：领域层对 Flutter 框架产生无意义的编译依赖，`dart analyze` 产生未使用导入告警；在纯 Dart 工具/测试环境中引入不必要的框架依赖。
- 证据等级：实锤

### `lib/core/domain/quality.dart`:80 未知音质字符串静默归一为 `q128`，与「设置页显示已生效但音质没变」红线同型
- 级别：P2
- 违反：QUALITY_STANDARD 第 11 条、第 16 条
- 依据：`fromString` 对 `null` 直接 `return q128`，遍历 `values` / 别名 switch / `magic_` 前缀补全全部未命中后，末尾无条件 `return q128`；无日志、无「无法识别」返回值或异常，也没有触发条件/退出条件声明。文件注释自己写明「若别名缺失，用户选了 Hi-Res 而实际只请求 128k，属于数据一致性红线」，但解析失败与「用户明确选择标准」被压成同一个 `q128`。
- 影响：持久化值一旦是未收录的新 wire 名/大小写以外的脏值，用户设置的 Hi-Res/无损/蝰蛇档在重启后被静默重置为标准音质且无任何反馈，播放地址按 128k 请求；排查时无法区分「用户选标准」与「解析失败」。
- 证据等级：实锤（解析行为）；具体持久化值形态待调用方逐文件核对

### `lib/core/domain/quality.dart`:6 注释声明的「排序」与 `values`/`index` 顺序相反，上移后易被上层当作优先级使用
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条、第 15 条（单位/序关系须显式）
- 依据：注释写「排序：super > high > flac > 320 > 128」，而增强枚举的声明顺序为 `q128, q320, flac, high, superQuality, viperTape, viperClear, viperAtmos, magicPiano, ...`，即 `values`/`index` 从小到大排列且特殊档混排；文件只提供 `fallbackOrder` / `viperOrder` / `magicOrder` 三个显式列表，未对 `index` 的语义作任何约束。
- 影响：若上层按 `index` 或 `values` 比较/排序音质（M1 上移后新调用方容易这么做），得到与文档相反的优先级，出现「降级反而升档」或设置页排序错乱；是否已有此类调用方待逐文件核对。
- 证据等级：静态推演

---

## 3. `lib/core/domain/song.dart`（175 行，已完整读）

### `lib/core/domain/song.dart`:126 单位判定只按字段名白名单，且首轮循环以「非零」为唯一优先级，跨结构同源字段可差 1000 倍
- 级别：P1
- 违反：QUALITY_STANDARD 第 15 条、第 14 条、第 17 条
- 依据：`setDuration` 的 `millis` 参数由调用点硬编码：`['duration','Duration','time_length']` → 秒，`['timelength','timelen','timeLength']` → 毫秒，`info['duration']` → 毫秒；`if (duration > Duration.zero) return;` 使先被扫到的秒组字段一旦非零就永久胜出，后扫到的毫秒组即使来自同一响应也不再参与。文件注释也自述两种结构混用（`Duration` 秒 / `info.duration` 毫秒），但 `fromJson` 没有按响应来源分支，而是把 `info` 与顶层字段混在同一个 Map 上按 key 名猜测。
- 影响：任何同时携带顶层 `duration`（秒）与 `info.duration`（毫秒）或 `time_length` 与 `timelength` 且单位口径不同的响应，歌曲时长被解析为 1000 倍或 1/1000 倍；播放器进度条、剩余时间、歌词时间轴、列表展示时长全部错误，长曲目可能表现为进度瞬间走完。
- 证据等级：静态推演（字段名/优先级/单位映射为实锤；实际响应是否同时携带两类字段未实测，需调用方与样本核对）

### `lib/core/domain/song.dart`:64 `artist` 拼成「A、B」后，歌名前缀剥离条件不再成立
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条
- 依据：当 `singer` 是 List 且含多名歌手时，`artist` 被 `join('、')`；剥离 `/privilege/lite` 的 `"歌手 - 歌名"` 前缀要求 `raw.substring(0, sep) == artist` 严格相等，或 `artist.isEmpty`，多歌手、异名别名、空白差异都会使条件为假，于是 `name` 保留整串 `"歌手 - 歌名"`。
- 影响：合唱/合作曲目的歌名在列表、播放器、通知栏显示为「歌手A、歌手B - 歌曲名 - 歌名」式重复文本，且搜索/去重/缓存键基于的 name 不一致。
- 证据等级：实锤（字符串处理逻辑）；真实响应形态未实测

### `lib/core/domain/song.dart`:91 外部字段直接 `'${info['image'] ?? ''}'` / `'${transParam['union_cover'] ?? ''}'`，无类型校验
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条、第 14 条
- 依据：`info` 仅校验 `is Map`；`transParam` 仅校验 `is Map`；随后把任意类型的值用字符串插值赋给 `cover`（Map/List/数字都会变成 `{...}`、`[...]`、`123`），并继续 `replaceAll('{size}', '400')`，未走 `str()` 的键遍历/类型分支。
- 影响：上游把封面字段从 String 改为对象/数组时，封面 URL 变成无意义字符串，图片加载请求失败或落到错误地址，列表/播放页封面空白。
- 证据等级：实锤（代码事实）；上游形态未实测

### `lib/core/domain/song.dart`:167 `==` / `hashCode` 只认 hash，忽略 `quality`、`duration`、`localPath` 等全部可变字段
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 5 条
- 依据：`operator ==` 仅 `other is Song && other.hash == hash && other.hash.isNotEmpty`，`hashCode => hash.hashCode`；`quality`、`localPath`、`duration` 参与播放/缓存/离线决策却不影响相等性，`copyWith(quality: ...)`、`clearLocalPath: true` 产生的新对象与原对象判等。
- 影响：依赖 `==`/Set/Map 去重或状态比较的调用方（如播放器队列、已下载列表、Provider 状态更新）无法察觉音质切换/离线源清除，界面不刷新、仍按旧音质或失效本地路径播放。
- 证据等级：静态推演（本文件语义实锤；具体调用方依赖待逐文件核对）

### `lib/core/domain/song.dart`:148 `quality` 只从 `quality` 单字段解析，且空值经 `fromString('')` 静默落为 `q128`
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 16 条
- 依据：`quality: AudioQuality.fromString(str(['quality']))`；`/search` 结构按本文件注释提供 `FileHash`/`Duration`/`AlbumID` 等，不含 `quality`，`str` 返回空串，`AudioQuality.fromString('')` 末尾返回 `q128`。「响应未提供音质」与「响应明确为标准音质」被压成同一值。
- 影响：从搜索结果构造的歌曲对象恒定携带 `q128`，若调用方以 `Song.quality` 作为「当前可用/已选音质」参与播放地址请求或 UI 显示，会在用户已选无损/Hi-Res 时仍显示/请求标准档；具体调用方待核对。
- 证据等级：静态推演（契约与调用方一致性待逐文件核对）

---

## 4. `lib/core/domain/response_policy.dart`（66 行，已完整读）

### `lib/core/domain/response_policy.dart`:9 / `lib/core/foundation/errors.dart`:27 20028 判定并非单点，且两处数值来源不同
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 3 条、第 8 条
- 依据：`response_policy.dart` 定义 `const int kVerificationRequired = 20028;` 并在 `requiresVerification` 中直接比较 `e.errorCode == kVerificationRequired`；`ApiOutcome.needsVerification` 又走 `failure?.needsVerification`，而 `errors.dart:27` 的 `needsVerification => errorCode == 20028` 使用字面量、没有引用 `kVerificationRequired`，`errors.dart` 也未 `import 'response_policy.dart'`。文件头声称「全仓 20028 判定唯一出口」「消费方不得再硬编码错误码」，实际存在 `errors.dart` 字面量判定与 `response_policy.dart` 常量判定两条独立路径；`requiresVerification(Object? e)` 也不经过 `ApiException.needsVerification`，若 `ApiException` 被子类化并覆写 `needsVerification`，两条路径结果可不同。
- 影响：风控 20028 的识别可被两条路径中的任一条差异放大——例如统一改用 `requiresVerification` 的上层能识别，而走 `ApiOutcome.needsVerification` 的上层在字面量/常量漂移后漏识别；用户遇到风控时不再弹出验证入口，所有依赖该状态的接口持续以普通失败呈现。
- 证据等级：实锤（两处代码事实）；是否已有子类覆写未实测

### `lib/core/domain/response_policy.dart`:36 对响应体 `ssaCode` 直接 `as String?`，非字符串值触发未包装的 TypeError
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条、第 10 条、第 8 条
- 依据：`fail(int code)` 构造 `ApiException` 时写 `ssaCode: body['ssaCode'] as String? ?? ssaCode`；`body` 来自网络响应的 `Map<String, dynamic>`，只经 `codeOf`/`status` 等局部校验，没有对 `body['ssaCode']` 做 `is String` 判定。Dart 中 `as String?` 对 `int`、`Map`、`List` 等非空非 String 值会抛 `TypeError`；该异常既不是 `ApiException` 也不进入 `ApiOutcome.fail`，直接越过「异常契约单一」的包装层。
- 影响：上游只要把 `ssaCode` 返回为数字或对象（风控/验证场景常见 ID 形态），业务调用方收到的是未捕获类型错误而非可枚举的 `ApiException`，请求链路中断且错误翻译/用户提示失效，验证流程无法进入。
- 证据等级：实锤（强制转换语义）；上游真实字段形态未实测

### `lib/core/domain/response_policy.dart`:43 `status == 1` 分支把非零 `error_code` 与「存在任意其他键」判为成功
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条、第 8 条、第 11 条
- 依据：分支为 `if (errorCode == 0 || _hasData(body)) return ApiOutcome.ok(body);`，而 `_hasData` 在 `data` 非空或 `body.keys.any(k != 'status' && k != 'error_code' && k != 'errcode')` 时即为 true。典型 body 带 `error`/`errmsg`/`data`/`info` 等键时，`status == 1` 且 `error_code = 20028` 或 `error_code = 30011` 仍返回 `ApiOutcome.ok(body)`，只有 body 仅剩 `status`/`error_code`/`errcode` 三个键且无 `data` 时才落到 `fail(errorCode)`。本文件注释宣称「唯一成功判定入口」，但 `error_code` 的成功/失败语义被 `_hasData` 覆盖。
- 影响：网关以 `status=1` + 非零 `error_code` 表达业务失败或风控时，调用方拿到 `isOk == true` 并继续解析 `body`，把错误消息当数据渲染、或跳过 20028 验证入口；用户看到空列表/错误内容且无重试提示。
- 证据等级：实锤（分支与 `_hasData` 逻辑）；网关是否使用此组合未实测

### `lib/core/domain/response_policy.dart`:48 `status == 200` 无条件成功，忽略同响应中的 `error_code` / `err_code` 之外的失败码
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 29 条
- 依据：注释写「歌词类：status=200 + errcode=200 是正常码」，但实现是 `if (status == 200) return ApiOutcome.ok(body);`，在 `err_code` 分支之后、`errorCode != 0` 分支之前返回；`status=200` 且 `error_code=20028`、`errcode` 非零、或 `status=200` + `error_code` 为错误码时都不会 `fail`。注释与实现对 `errcode=200` 的数值也矛盾（`errorCode` 为 200 时本应在后续分支 `errorCode != 0` 判失败）。
- 影响：歌词/翻译类端点若用 `status=200` 表示 HTTP 层成功、另带业务错误码，失败响应被当作成功，歌词/翻译显示为空或乱码且无错误反馈；对 20028 风控同样漏判。
- 证据等级：实锤（分支事实）；端点真实返回形态未实测

### `lib/core/domain/response_policy.dart`:49 `status=0/2` 且 `errorCode=0` 时把错误码改写为 `-1`
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 8 条、第 17 条
- 依据：`if (status == 0 || status == 2 || errorCode != 0) return fail(errorCode);` 中 `fail(int code)` 定义为 `ApiException(code == 0 ? -1 : code, ...)`。当业务用 `status=0`/`2` 表达失败且未提供 `error_code`，或错误码本身是 `0` 时，异常携带 `errorCode = -1`，`status` 原值未写入 `ApiException`，但 `body` 保留。上层按 `errorCode` 分流的逻辑（含 `requiresVerification`、`friendly_error` 一类按码翻译）无法还原真实 `status`。
- 影响：用户看到的错误提示退化为通用「请求失败」，特定失败态（如需登录、需 VIP、需验证）无法被正确引导；若验证码藏在 `status`，`requiresVerification` 也无法命中。
- 证据等级：实锤（改写逻辑）；具体调用方分流待核对

### `lib/core/domain/response_policy.dart`:29 `status` 未做类型归一，字符串状态绕过所有失败分支
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条、第 14 条、第 29 条
- 依据：`final status = body['status'];` 之后用 `status == 1` / `== 200` / `== 0` / `== 2` 与 int 字面量比较；`codeOf` 只对 `error_code`/`errcode`/`err_code` 做 `int.tryParse('$v')` 兼容字符串，`status` 没有同等处理。字符串 `'0'`、`'2'`、`'200'` 全部不匹配，随后只要 `errorCode == 0` 且 `body` 非空就落到末尾 `return ApiOutcome.ok(body)`。
- 影响：上游把 `status` 序列化为字符串（或经中转网关做字段归一）时，明确失败的状态被判成功，界面按空数据渲染且无错误提示；成功判定口径与「逐端点实测」要求不一致。
- 证据等级：静态推演（Dart `==` 类型语义实锤；上游字符串形态未实测）

### `lib/core/domain/response_policy.dart`:40 `err_code` 非数值形态被 `codeOf` 静默归一为 0，等同成功
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条、第 14 条
- 依据：`int codeOf(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);`，`err_code` 分支只在 `codeOf(errCode) != 0` 时 `fail`；若 `err_code` 是 `Map`/`List`/`'error'`/`true` 等无法解析的值，`codeOf` 返回 0，分支判定为「无错误」，后续只要 `errorCode == 0` 且 body 非空就成功。
- 影响：评论类接口的错误结构变更时，写操作/读取失败被吞成成功，用户看到「评论已提交」但实际未提交，或评论列表空白无报错。
- 证据等级：实锤（归一逻辑）；上游非数值形态未实测

---

## 5. `lib/core/config/app_config.dart`（56 行，已完整读）

### `lib/core/config/app_config.dart`:15 kapi 常量的「运行期绝不调用 / 仅供 CookieJar 域名占位」与注释清理计划共存，且 `proxyBase` 无用途说明
- 级别：P2
- 违反：QUALITY_STANDARD 第 27 条、第 2 条、第 31 条
- 依据：注释声明 `kugouApiBase = 'https://kapi.344977.xyz'` 运行期绝不调用、仅作 CookieJar 域名占位并附清理计划；同文件另有 `proxyBase = 'https://proxy.344977.xyz'` 却没有任何用途/兜底/清理说明。`translateApiBase` 指向第三方 `index-translate.bilibili.com`。本文件只有常量，是否真被用于请求需按 `KugouApiClient` / `TranslateApi` 全文核定；本条仅记录配置层事实，避免把「注释声明」当作「运行期不会发包」的证据。
- 影响：若运行期仍有请求落到 kapi/proxy，则违反「接口只走原生网关」且中转包装会改变成功/错误形态，用户侧出现与原生不一致的静默失败；若确无请求，残留常量仍会被后续代码误用。
- 证据等级：静态推演（配置事实实锤；调用方待 `KugouApiClient` / `TranslateApi` 全文核对）

### `lib/core/config/app_config.dart`:34 语言单一事实源靠人工同步，配置表与 `AppLocalizations.supportedLocales` 无编译期约束
- 级别：P3
- 违反：QUALITY_STANDARD 第 5 条
- 依据：注释自述「本表只供设置页语言选择器排序与显示名，二者必须保持一致——新增 arb 文件时同步更新本表，否则会出现「可选语言与实际解析集合不一致」」；本文件 `supportedLocales` 与 `localeNames` 均为手写 `const List/Map`，没有引用 `lib/l10n/app_localizations.dart` 的 `supportedLocales`。
- 影响：新增或移除界面语言时，设置页可选项与实际生效语言集合不一致，用户选择某语言后界面仍回落默认语言；或选项缺失导致该语言不可选。
- 证据等级：静态推演（配置事实实锤；生成物集合未逐行核对）

---

## 6. `lib/core/api/kugou_api_client.dart`（215 行，已完整读）

### `lib/core/api/kugou_api_client.dart`:33 旧 `_wrap` 的成功/失败判定仍完整复制在 `onResponse` 里，M4「判定全部收敛于 ResponsePolicy」未闭环
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 3 条、第 8 条
- 依据：`response_policy.dart:4-5` 声明「成功/失败/风控判定全部收敛于此」「此前 `_wrap` 散在 kg_direct_api_client」；但本文件 `onResponse` 自行实现一套 `status` 解析（`int.tryParse('${data['status'] ?? 1}') ?? 1`）、`error_code`/`errcode` 解析、`warningCodes = {0,151,152,200,201}`、`okStatus`/`failedStatus`、`data.containsKey` 判定和 `ApiException` 构造，且本文件没有 `import '../domain/response_policy.dart'`。两套口径并不等价：`status=200 + errcode=200` 在本文件因 `isWarning` 放行、在 `evaluateResponse` 因 `status == 200` 无条件放行；`status=1 + error_code=151/152` 本文件放行、`evaluateResponse` 只要 `_hasData` 为真也放行；`status=1 + err_code!=0` 只被 `evaluateResponse` 判失败，本文件完全不读 `err_code`；`errorCode=0` 时 `evaluateResponse.fail` 会改写为 `-1`，本文件保留 `0`；`ssaCode` 本文件读 `ssaCode`/`ssa_code` 及两个响应头并 `toString().trim()`，`evaluateResponse` 只读 `body['ssaCode'] as String?` 与入参 `ssaCode`。
- 影响：同一份响应经 KugouApiClient 与经 ResponsePolicy 的调用方（直连层/回退层）会得出相反的 `ok/fail`、不同的 `errorCode`、不同的 `ssaCode`，导致风控验证入口、错误提示、重试逻辑在一半链路上失效；M4 上移后仍存在两个事实源。
- 证据等级：实锤（两文件逐分支对照）

### `lib/core/api/kugou_api_client.dart`:76 `errorCode == 20028` 字面量判定，破坏「20028 判定单点」
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 8 条
- 依据：`final defaultMessage = errorCode == 20028 ? '需要完成人机验证' : ...`；`response_policy.dart` 定义 `kVerificationRequired = 20028` 且声明「全仓 20028 判定唯一出口。消费方不得再硬编码错误码」，`ApiException.needsVerification` 亦为唯一判定点，但本文件既未 import `response_policy.dart`，也未使用 `kVerificationRequired` 或 `needsVerification`。加上 `errors.dart:27` 的字面量，全仓至少三处独立 20028 数值。
- 影响：错误码口径变更时，验证提示文案与 `requiresVerification`/`needsVerification` 分支不同步：用户可能看到「需要完成人机验证」却不弹验证页，或弹了验证页但显示通用错误；风控场景无法完成。
- 证据等级：实锤

### `lib/core/api/kugou_api_client.dart`:13 默认 `baseUrl` 仍是 kapi 中转域名，与「运行期绝不调用」注释冲突
- 级别：P0
- 违反：QUALITY_STANDARD 第 27 条、REVIEW_SPEC 第 1 节（原生网关唯一）
- 依据：构造函数 `_dio = Dio(BaseOptions(baseUrl: baseUrl ?? AppConfig.kugouApiBase, ...))`，`AppConfig.kugouApiBase = 'https://kapi.344977.xyz'`；`get`/`post` 直接用 `_dio.get(path)` / `_dio.post(path)`，路径为空/相对时会由 Dio 拼接 `baseUrl`；而 `app_config.dart:10-13` 明确写「kapi 运行期绝不调用，仅供 CookieJar 域名占位使用」。本文件还把 `export '../foundation/errors.dart'` 后的 `ApiException` 用于旧 `_wrap` 判定，说明该类仍在实际请求链路上。
- 影响：任何未显式注入原生 `baseUrl` 而使用相对路径的 `KugouApiClient` 请求都会发往 kapi 中转；kapi 的 Node 层包装会归一状态/裁剪字段/聚合错误，成功判定与原生直连不一致，用户侧出现静默失败、错误提示失真、Cookie/登录态与原生域不匹配（QUALITY_STANDARD 第 33 条明确禁止以 kapi 返回作为直连实测依据）。
- 证据等级：实锤（默认构造与默认常量；是否已有裸构造调用方待核对）

### `lib/core/api/kugou_api_client.dart`:18 显式传入 `cookieStoragePath` 的实例绕过共享 jar，登录 Cookie 与其它 client 互不可见
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 2 条
- 依据：`_cookieJar = cookieStoragePath == null ? sharedCookieJar : _createCookieJar(cookieStoragePath)`；只要调用方传了非 null 路径（包括与全局 `cookieStoragePath` 相同的路径），就 `new PersistCookieJar(storage: FileStorage(path))` 并赋值 `_sharedJar` 之外的实例，既不读写 `_sharedJar`，也不相互共享内存 `hostCookies`。文件注释自述「各实例各建一个 PersistCookieJar 时，内存里的 hostCookies 互不可见，而 FileStorage 又指向同一目录互相覆盖 —— 结果就是登录写入的 token，播放器/评论等其它 client 完全读不到」。`setCredentials`/`clearCredentials` 均只操作实例自己的 `_cookieJar`。
- 影响：登录态写入 A 实例后，B 实例（含 `sharedCookieJar` 客户端）的请求仍为匿名，用户已登录却看到需登录/VIP 不可用/收藏评论失败；切号时 `clearCredentials` 只清一个 jar，另一个 jar 保留旧账号 token，产生跨账号串号。
- 证据等级：实锤（构造分支与注释自述）；具体装配时序待调用方核对

### `lib/core/api/kugou_api_client.dart`:136 路径未就绪时返回的「不缓存内存 jar」与 `_cookieJar` 字段绑定，路径就绪后该实例永不切换
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 11 条
- 依据：`sharedCookieJar` 在 `cookieStoragePath == null` 时 `return CookieJar();` 且不写 `_sharedJar`，注释称「路径未设置时不缓存 jar（每次重查，路径就绪后自然切到持久化）」；但构造函数把 getter 的**返回值**一次性存入 `final CookieJar _cookieJar`，并把同一个实例注册到 `_dio.interceptors.add(CookieManager(_cookieJar))`。该实例此后没有任何重新查询 `sharedCookieJar` 的代码；`setCredentials` 写的是这个内存 jar，`saveFromResponse` 的 Cookie 在进程重启后丢失。注释中「路径就绪后自然切到持久化」只对**之后新建**的 `KugouApiClient` 生效，已存在的 client 永远停在内存态，且没有退出条件/恢复条件。另外每次调用 getter 在未就绪时都新建 jar，先于路径就绪的多个 client 各自持有不同 jar。
- 影响：冷启动时若在 `main()` 设置 `cookieStoragePath` 之前构造了客户端（注释自述「冷启动/低端机」会发生），该进程内登录态不落盘，用户下次冷启动被登出；同进程多个早构造的 client 之间登录态不共享。降级虽有 `debugPrint`，但注释承诺的「自动切换」不成立。
- 证据等级：实锤（时序与字段绑定）；装配是否早于路径设置待调用方核对

### `lib/core/api/kugou_api_client.dart`:136 `sharedCookieJar` 的「will switch to persistent once path is set」日志与实际行为不符，降级无用户可见留痕
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条、第 11 条
- 依据：未就绪分支打印 `'[cookie] storage path not ready, using in-memory jar (will switch to persistent once path is set)'`；如上条所述，已构造实例不会切换。`_createCookieJar` 的 catch 与 `sharedCookieJar` 的 `jar is! PersistCookieJar` 分支只用 `debugPrint`，`setCredentials` 对 `saveFromResponse` 的返回/失败不做任何可观测处理；`debugPrint` 在 release 构建下不进入用户可见渠道，也没有状态字段供上层查询当前是否持久化。
- 影响：持久化降级只在调试输出可见，用户界面仍显示「已登录」并在重启后丢失登录态，线上无法从用户反馈/界面区分「持久化失败」与「用户主动登出」。
- 证据等级：实锤（日志/行为事实）；release 下 debugPrint 可见性未实测

### `lib/core/api/kugou_api_client.dart`:186 `setCredentials` 把登录 Cookie 写到 kapi 域名，与酷狗原生域请求不共享
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条、第 27 条、第 29 条
- 依据：`final uri = Uri.parse(AppConfig.kugouApiBase);` → `https://kapi.344977.xyz`，随后 `_cookieJar.saveFromResponse(uri, cookies)` 写入 `token/userid/t1/auth/dfid`；`app_config.dart` 注释称该常量「仅供 KugouApiClient 的 CookieJar 域名占位使用（Cookie 只存本地，不发包）」。但 CookieJar 的 `saveFromResponse`/`loadForRequest` 按 host/domain 匹配；写到 kapi host 的 Cookie 不会随发往酷狗原生域（如 `gateway.kugou.com`、`trackercdn.kugou.com`）的请求自动携带。`clearCredentials` 用 `deleteAll()` 清空整个 jar。
- 影响：即使 KugouApiClient 显式注入原生 baseUrl，通过 `setCredentials` 保存的登录凭证仍绑定在 kapi 域；原生域直连请求按匿名态发送，用户看到已登录但权益/收藏/评论/高音质全部按匿名处理；切号时 `deleteAll` 清掉所有域 Cookie 而非仅登录凭证。
- 证据等级：实锤（uri 与 jar 语义）；实际请求是否注入原生 baseUrl 待调用方核对

### `lib/core/api/kugou_api_client.dart`:167 `get`/`post` 声明返回 `Map<String, dynamic>`，但业务接口存在裸 List / 二进制 / 非 JSON 响应
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 13 条、REVIEW_SPEC 第 1 节（返回结构逐端点确认）
- 依据：`_dio.get<Map<String, dynamic>>(path, ...)` / `_dio.post<Map<String, dynamic>>(path, ...)` 把泛型写死为 `Map<String, dynamic>`，返回 `res.data ?? {}`；文件没有 `responseType`/`transformer` 配置，也没有对 `res.data` 做 `is Map<String, dynamic>` 校验。REVIEW_SPEC 明确「裸 Map：comment / comment/count」及歌手单曲 `/kmr/v1/audio_group/author` 必须返回 List；B2 范围还涉及二进制响应。非 Map 响应在 Dio 的解码/泛型传递路径上要么触发类型错误，要么让 `res.data` 实际类型与签名不符。
- 影响：任何返回 List 或二进制的端点经本类调用时，上层拿到的 `Map<String, dynamic>` 契约被破坏（类型错误或空 Map），歌手单曲列表/评论计数等显示为空或请求链路异常中断。
- 证据等级：静态推演（签名与端点形态来自 REVIEW_SPEC；本类是否被用于这些端点待调用方核对）

### `lib/core/api/kugou_api_client.dart`:5 Flutter `foundation.dart` 导入与 CookieJar 创建的注释「绝不写只读路径」缺少校验
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条、第 2 条
- 依据：文件注释声明「cookieStoragePath 必须是**可写**的 App 私有目录」「绝不会写只读路径」，但 `_createCookieJar` 只做 `path != null && path.isNotEmpty` 判断后就 `PersistCookieJar(storage: FileStorage(path))`，没有可写性探测；`_createCookieJar` 的 try/catch 只能捕获构造期同步抛出的异常，`FileStorage` 的写入发生在后续 `saveFromResponse` 且是异步。本条记录注释与实现之间的契约缺口。
- 影响：传入只读路径时 `debugPrint` 的「creation failed」可能根本不触发，登录 Cookie 持久化在首次写入时才失败，用户界面无提示，重启后登录态丢失。
- 证据等级：静态推演（第三方 FileStorage 的延迟写入语义未实测）

---

## 7. `lib/core/api/translate_api.dart`（75 行，已完整读）

### `lib/core/api/translate_api.dart`:47 `first['message']` 与 `content` 仍存在裸动态下标/裸 `as String?` 强转，「畸形即退回原文」只覆盖 `choices[0]` 一层
- 级别：P1
- 违反：QUALITY_STANDARD 第 13 条、第 10 条、第 8 条
- 依据：`final first = choices[0]; final content = (first is Map ? first['message'] : null)?['content'] as String?;`。`choices` 只校验 `is List && !isEmpty`，`first` 只校验 `is Map`；`first['message']` 的运行时类型完全未校验，直接对其使用 `?['content']`：`?.` 只保护 null 接收者，若 `message` 是 String/List/num，动态下标调用会抛 `NoSuchMethodError`；即便取到 `content` 是数字、Map 或 content-part 数组，`as String?` 会抛 `TypeError`。注释宣称「显式验证类型，畸形即退回原文」，但仅对 `choices`/`choices[0]` 做了验证，未对响应形态的中间层与叶子做类型分支；本方法内没有 try/catch，异常不会转成 `return lines` 的降级值。
- 影响：上游返回 `{"choices":[{"message":"..."}]}` 或 `content` 为分块数组时，歌词翻译抛未捕获类型错误而非回退原文，翻译链路中断；调用方若按业务失败处理，用户看到整批译文消失或报错提示，而不是原文歌词。
- 证据等级：实锤（Dart 动态下标/`as` 语义与代码路径）；上游畸形形态未实测

### `lib/core/api/translate_api.dart`:29 504 / 412 / 429 等非 2xx 响应没有任何防御，`return lines` 降级只在 200 + 畸形体时生效
- 级别：P1
- 违反：QUALITY_STANDARD 第 3 条、第 8 条、第 11 条、第 9 条
- 依据：`_dio.post` 未设置 `validateStatus`、未设置 `Options(responseType: ...)`、方法内无 try/catch、无 `on DioException` 分支、无状态码判定、无重试上限；`connectTimeout: 20s` / `receiveTimeout: 60s` 只是超时。Dio 默认 `validateStatus` 只接受 2xx，故上游 504 网关超时、WAF 412（文件注释自述「B 站 WAF 拦截无 UA 请求（412）」）、限流 429 都会在 `res.data` 之前抛 `DioException`；`translateLines` 的所有 `return lines` 分支都位于 `await` 之后，异常直接越过它们传播给调用方，且异常形态（`DioException`）与业务降级（`List<String>`）完全不同。降级既无「已知触发条件」的判定，也无恢复/退出条件与日志。
- 影响：翻译服务短暂不可用时，用户看到的不是「原文歌词照常显示」，而是整批歌词翻译失败/报错/重复刷屏；错误以未经领域包装的 `DioException` 上抛，上层若只按 `List<String>` 契约处理会进一步中断歌词页。
- 证据等级：静态推演（Dio 默认 `validateStatus` 语义按官方文档；未构建、未实测，调用方未在本文件内核对）

### `lib/core/api/translate_api.dart`:60 译文按位置截断/补齐，行数不吻合时把译文错配到原文行
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 14 条、第 17 条
- 依据：`final translated = content.split('\n'); return List.generate(lines.length, (i) => i < translated.length ? translated[i].trim() : lines[i]);`。方法只保证「输出行数 = 输入行数」，没有校验 `translated.length == lines.length`、没有校验 `finish_reason`、没有把行数不符当作失败；prompt 里只有自然语言要求「保持行数和换行不变」，属于对外部模型输出的未验证假设。译文多出的行被丢弃，少出的行用原文补齐；若模型合并/拆分/插入空行，后续译文整体错位。
- 影响：逐行翻译与 KRC 时间轴按索引绑定时，第 N 行显示的是另一句歌词的译文，或部分行是原文、部分行是译文；用户看到错译/ mixed 内容且无提示。
- 证据等级：静态推演（对齐逻辑实锤；调用方按索引绑定待核对）

### `lib/core/api/translate_api.dart`:32 `AppConfig.lyricTranslateMaxLinesPerBatch`（40 行）在 API 边界完全未生效
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条、第 25 条、第 14 条
- 依据：`app_config.dart:29` 定义 `lyricTranslateMaxLinesPerBatch = 40` 与 `lyricTranslateMaxTokens = 4096`；`translateLines` 只用 `if (lines.isEmpty) return []`，随后 `lines.join('\n')` 一次性提交全部行，`max_tokens` 固定 4096，没有按 40 行切批、没有 `lines.length` 上限校验、没有按 token 估算拆批。接口契约未声明「调用方必须已分批」。
- 影响：长歌词一次性提交时输出被 `max_tokens` 截断，后半段被「不足补原文」静默填成中文原文，用户以为已翻译但不完整；单次请求体过大也更容易触发上游 504/限流。
- 证据等级：实锤（常量与本文件未引用）；调用方是否已分批待核对

### `lib/core/api/translate_api.dart`:26 `targetLanguage` / 歌词文本未经任何转义直接拼进单条 user prompt，且无请求/响应标识
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条、第 14 条
- 依据：`final prompt = '请将以下文本翻译为$targetLanguage，直接输出翻译结果，不要进行任何解释。保持行数和换行不变。\n\n$joined';`；`joined = lines.join('\n')`，歌词行本身可能含 ` - `、空行、类指令文本；请求体只含 `model/messages/temperature/max_tokens/chat_template_kwargs`，没有批次 id、行数或目标语言的独立字段，响应也没有回显可供校验。
- 影响：含提示词样文本的歌词或含换行的目标语言值会让模型忽略「保持行数」约束，返回解释文本或合并行，被本方法当作译文 `trim()` 后逐行写回界面，用户看到非译文内容。
- 证据等级：静态推演（prompt 拼接事实实锤；模型行为未实测）

---

## 逐文件复核补充（为闭环契约读取的调用方，非本批必审范围；仅用于确认/修正上述结论的证据等级）

### 补充核对：M4「evaluateResponse 五分支与旧 _wrap 逐分支等价」不成立（实锤）
- `lib/core/direct/kg_direct_api_client.dart:78-90` 的 `_wrap` 已改为 `evaluateResponse(r.body, ssaCode: r.ssaCode)` + `throw outcome.failure!`，同时残留 `static bool _hasData`（第 92-98 行）和「成功判定看 status == 1、151/152 警告码需有数据」的旧注释（第 69-77 行）；`evaluateResponse` 的 `_hasData`（`response_policy.dart:55-61`）与旧 `_hasData` 语义不等价：旧版 `d == null → false`，且只认 `data` 字段；新版 `data` 为 null/空时还要检查「除 status/error_code/errcode 之外的任意键」，因此含 `error`/`info`/`errmsg` 的错误体也可能被判为有数据。
- `lib/core/api/kugou_api_client.dart:37-100` 的拦截器仍保留第三套判定（含 `warningCodes`、`hasErrorCode`、响应头 `ssa-code`/`ssa_code`、字符串 status 归一），`lib/core/net/music_api.dart:47-49` 的 `MusicApi.evaluate` 只是 `evaluateResponse` 的转发，并不参与 `CachedApiCall.get`（`lib/core/resource/cached_api.dart:58-61` 直接 `_api.get`）。即 `ResourceCache` 缓存的是未经 `evaluateResponse` 归一、却已被 `KugouApiClient` 拦截器判过的 body，两条链路对同一响应的成功/错误码/`ssaCode` 口径不同。
- `lib/core/direct/kg_client.dart:349-355` 的 `KgResponse.ssaCode` 用 `toString()` 兼容 `ssaCode`/`ssa_code`/`ssa-code` 头并传给 `_wrap`；`evaluateResponse` 的 `fail()` 却用 `body['ssaCode'] as String? ?? ssaCode`，body 中若存在非 String 的 `ssaCode` 会先抛 TypeError，`kg_direct_api_client.dart:154-156` 的 `catch (e)` 明确对 `TypeError` 执行 `rethrow`，不会包装成 `DioException`；该异常形态绕过 `lib/features/auth/presentation/verification_guard.dart:30-34` 的 `on DioException` 验证入口。证据等级：实锤。

### 补充核对：默认构造 `KugouApiClient()` 与 20028 常量散落（实锤）
- `lib/features/auth/data/auth_repository.dart:59-62` 的 `AuthRepository({KugouApiClient? api}) : _api = api ?? KugouApiClient()`；`lib/app/di.dart:10-13` 的 `kugouApiClientProvider` 注入 `kgDirectApiProvider`，`lib/features/auth/data/auth_providers.dart:10-12` 走注入，因此正常 Riverpod 路径不命中默认构造；但默认构造一旦被任何未注入路径使用即按 `baseUrl ?? AppConfig.kugouApiBase` 落到 kapi。故前述 `kugou_api_client.dart:13` P0 的证据等级由「实锤（默认构造与默认常量；调用方待核对）」修正为「实锤（潜在默认路径，正常 Provider 路径未触发）」，级别由 P0 下调为 P1：用户可见后果需以「未注入的调用方存在」为前提，当前已核对的正常装配路径未发现该前提。禁止给修复建议，仅记录事实。
- `lib/features/auth/data/auth_repository.dart:66` 定义 `static const captchaErrorCode = 20028;`，第 137 行 `err.errorCode == captchaErrorCode`；`lib/core/direct/kg_direct_api_client.dart:134` 使用字面量 `e.errorCode == 20034`，`kugou_api_client.dart:76` 使用字面量 `20028`，`friendly_error.dart`/`verification_guard.dart` 使用 `api.needsVerification`。全仓 20028 数值至少 4 处（`response_policy.kVerificationRequired`、`errors.dart` 字面量、`kugou_api_client.dart` 字面量、`auth_repository.captchaErrorCode`），判定出口至少 3 条（`requiresVerification`、`ApiException.needsVerification`、`AuthRepository.captchaErrorCode` 直接比较）。证据等级：实锤。

### 补充核对：CookieJar 时序与登录态写入（实锤）
- `lib/main.dart:82-90` 在 `runApp` 之前 `await getApplicationDocumentsDirectory()` 并设置 `KugouApiClient.cookieStoragePath`；`lib/app/di.dart` 的 Provider 为惰性创建，正常路径下 `sharedCookieJar` 首次调用晚于路径设置，前述「早构造」风险在当前装配中未发现实际触发路径，故 `kugou_api_client.dart:136` 时序问题的证据等级维持「实锤（代码行为）/ 静态推演（冷启动触发前提）」，用户可见后果限于 `cookieStoragePath` 初始化失败或异常早构造场景。
- `lib/features/auth/data/auth_repository.dart:230-235`（`restoreSession`）、`351-359`（`_handleLoginSuccess`）均调用 `_api.setCredentials(...)`；注入的是 `KgDirectApiClient`，其覆写先同步 `kg.token/kg.userid/kg.t1/kg.dfid/device.dfid` 再 `super.setCredentials` 写 kapi 域 CookieJar。因此原生直连请求的登录态实际依赖 `KgClient` 内存字段（`SecureStorage` 负责跨重启），`setCredentials` 的 kapi 域 Cookie 对原生请求不生效；前述「Cookie 写到 kapi 域」的契约错配为实锤，但在当前注入链路上用户可见后果由 `KgClient` 字段补偿，应降级为 P2 的隐蔽契约错配，而非「已登录功能失效」。证据等级：实锤（链路）。
- `lib/features/auth/data/auth_repository.dart:59` 的默认 `KugouApiClient()` 无覆写，若该路径被使用则登录态只有 kapi 域 CookieJar + `userid` 字段，没有 `KgClient` 字段同步；与注入路径的登录态事实源不同。证据等级：静态推演。

### 补充核对：翻译 API 504 防御与分批（实锤，降级结论需下调）
- `lib/features/lyric/data/lyric_repository.dart:176-185` 以 `const batchSize = 40` 切批（与 `AppConfig.lyricTranslateMaxLinesPerBatch` 数值相同但为独立字面量），并对 `translateLines` 外层 try/catch、失败重试一次、二次失败按单批失败处理且 `debugPrint` 留痕、不入缓存。因此前述 `translate_api.dart:29` 「504 无防御、异常越过所有 return lines」的单元事实成立，但「用户看到整批翻译失败/报错」的链路后果已被 `ensureTranslation` 的 catch 兜住；级别应由 P1 下调为 P2，用户可见后果修正为「504 时该批保留原文、重试一次后仍失败则本批无译文且只有调试日志，需下次进入歌词才重试」。`translate_api.dart:32` 的「40 行常量未生效」同样应下调为 P3：调用方硬编码 40 达到相同分批效果，但配置常量与实现无关联，属于单一事实源/整洁度问题，不再构成「长歌词一次性提交被截断」的用户可见后果。证据等级：实锤。
- `lyric_repository.dart:201-215` 注释与代码要求 `translated.length == batch.length`，否则本批不落缓存；因此 `translate_api.dart:60` 的「按位置截断/补齐」在**正常 200 响应且行数不符**时仍会把 `trim()` 后的原文/错位译文经 `emit` 广播给 UI，只是不写持久缓存；用户可见后果为当次显示错行/原文，级别维持 P2。证据等级：实锤。

### 补充核对：Song/AudioQuality 字段单位与调用方（实锤）
- `lib/core/audio/preferred_quality.dart:11-17` 从 Hive `settings/defaultQuality` 读 String 后 `AudioQuality.fromString(v)`，异常/未开箱返回 `q320`；`Song.fromJson` 注释列明 `/search` 的 `Duration` 为秒、`/privilege/lite` 的 `info.duration` 为毫秒，`lib/features/home/data/models.dart:20-27` 列明 `timelength`/`timelen` 毫秒与 `duration`/`time_length`/`Duration` 秒，并在 `models.dart:101-113` 用 `~/ 1000` 归一到秒；而 `Song.duration` 是 `Duration`，`setDuration` 分别用 `Duration(seconds:)` / `Duration(milliseconds:)`。两套解析单位口径一致，前述 `song.dart:126` 的「差 1000 倍」风险仅在**同一响应同时携带两类字段且优先级错误**时才出现，已核对的 `HomeSong.fromJson` 用「秒字段优先、仅当秒 <= 0 才读毫秒」的同类假设，未发现同时携带反例样本，故该条证据维持「静态推演」，级别由 P1 下调为 P2（边界态/未实测），用户可见后果限于混合字段响应。
- `lib/main.dart:26` 直接 `import 'core/domain/song.dart' show Song;`，`lib/core/audio/preferred_quality.dart` 直接 `import '../domain/quality.dart'`，`lib/core/api/kugou_api_client.dart:2-3` `import`/`export '../foundation/errors.dart'`，`lib/core/utils/friendly_error.dart:3`/`lib/features/auth/data/auth_repository.dart:5`/`verification_guard.dart:5` 均从 `core/api/kugou_api_client.dart` 取得 `ApiException`；M1 上移后旧路径通过 `kugou_api_client.dart` 的 re-export 保持兼容，`errors.dart:3` 注释所称「原位置 re-export 兼容」与旧**导出位置**不符但**导入链可用**。前述 `errors.dart:3` P3 修正为：注释指向不精确（实际兼容层在 `kugou_api_client.dart:3`），无用户可见功能后果。证据等级：实锤。

---


## 终裁说明（对上述逐文件条目的级别/后果修正，以本节为准）

- `errors.dart:27`：P2 → P1（与本批 `response_policy.dart` / `kugou_api_client.dart` 的重复判定合并为「20028 判定非单点」主问题）。全仓 20028 数值至少 4 处、判定出口至少 3 条，已由 `auth_repository.dart:66/137`、`kugou_api_client.dart:76`、`response_policy.dart:9/65`、`errors.dart:27` 实锤。
- `errors.dart:3`：P3 保留，但依据修正为「注释指向不精确」；`kugou_api_client.dart:3` 的 re-export 使旧导入链可用，且 `REFACTOR_PLAN_V5.md` 执行记录 M1 明确「re-export 兼容层判定为负资产，已放弃」，注释与执行记录冲突。无功能后果。
- `song.dart:126`：P1 → P2（边界态，需混合字段响应才会触发；已核对 `models.dart` 采用同类单位口径）。
- `kugou_api_client.dart:13`：P0 → P1（正常 Provider 装配注入 `KgDirectApiClient`，未发现默认构造被实际使用；潜在默认路径仍指向 kapi）。
- `kugou_api_client.dart:186`：P1 → P2（当前注入链路的登录态由 `KgDirectApiClient.setCredentials` 同步到 `KgClient` 字段补偿；kapi 域 Cookie 错配仍为契约事实）。
- `kugou_api_client.dart:18` / `:136`（两个条目）：维持 P1，但「用户已登录却匿名」后果以「显式传 `cookieStoragePath`」或「路径初始化失败/早构造」为前提；`main.dart:82-90` 正常路径先设路径再 `runApp`，已标注触发条件。
- `translate_api.dart:29`：P1 → P2（504 由 `lyric_repository.dart:180-185` 重试一次 + catch 兜住，用户可见后果收敛为「该批保留原文、调试日志留痕、下次进入歌词才重试」；`DioException` 越出 `translateLines` 契约仍是单元事实）。
- `translate_api.dart:32`：P2 → P3（调用方硬编码 `batchSize = 40` 达到分批效果；配置常量与实现无关联属第 5/32 条整洁度问题）。
- `translate_api.dart:60`：维持 P2；`lyric_repository.dart` 只在条数不等时不落持久缓存，`emit` 仍会把当次补齐/错位内容广播给 UI。
- `app_config.dart:15`：维持 P2；`KugouApiClient` 默认 baseUrl 与 `setCredentials` 的 URI 均引用该常量，「仅供 CookieJar 域名占位」的注释与代码用途不一致。
- 其余条目维持原级别；所有条目均不给修复建议、不改代码。

## 问题清单（按级别排序；合并重复根因后共 28 条）

### P0（0 条）
- 无。原 `kugou_api_client.dart:13` 已按「正常 Provider 路径未触发」下调 P1。

### P1（8 条）
1. `lib/core/domain/response_policy.dart`:9 / `:65`、`lib/core/foundation/errors.dart`:27、`lib/core/api/kugou_api_client.dart`:76、`lib/features/auth/data/auth_repository.dart`:66/137 —— 20028 判定与数值散落 4 处/3 条出口，M4「全仓唯一出口」不成立；验证提示、验证弹窗、错误码分流可不同步。证据：实锤。违反第 5/3/8 条。
2. `lib/core/api/kugou_api_client.dart`:33-100 vs `lib/core/domain/response_policy.dart`:24-52 + `lib/core/direct/kg_direct_api_client.dart`:69-98 —— evaluateResponse 五分支与旧 `_wrap` 不逐分支等价，且拦截器保留第三套 `warningCodes`/`hasErrorCode`/响应头 `ssa-code` 判定；`_hasData` 新旧语义不等价。同一响应在不同链路 ok/fail、errorCode、ssaCode 不一致。证据：实锤。违反第 5/3/8 条。
3. `lib/core/domain/response_policy.dart`:36 —— `body['ssaCode'] as String?` 对非字符串外部字段抛未包装 TypeError；`kg_direct_api_client.dart:154-156` 对 TypeError `rethrow`，绕过 `verification_guard.dart` 的 `on DioException` 验证入口。证据：实锤。违反第 13/10/8 条。
4. `lib/core/domain/response_policy.dart`:43 + `:55-61` —— `status == 1` 且非零 `error_code`（含 20028）只要存在任意非状态码键即判 `ApiOutcome.ok`，业务失败/风控被当成功。证据：实锤。违反第 3/8/11 条。
5. `lib/core/api/translate_api.dart`:47 —— `first['message']` 动态下标与 `content as String?` 未逐层校验，`[null]/["str"]` 之外的畸形（message 为 String/List、content 为数组/数字）抛 NoSuchMethodError/TypeError，不退回原文。证据：实锤。违反第 13/10/8 条。
6. `lib/core/api/kugou_api_client.dart`:18 —— 显式 `cookieStoragePath` 构造绕过 `sharedCookieJar`，`setCredentials`/`clearCredentials` 只操作实例 jar；登录态与切号清理在实例间不可见（注释自述该风险）。证据：实锤。违反第 5/2 条。
7. `lib/core/api/kugou_api_client.dart`:136-145 —— 路径未就绪时返回不缓存内存 jar 被 `final _cookieJar` 一次性绑定，已构造 client 永不切换到持久化，注释承诺的自动切换不成立；多早构造实例各持不同 jar。证据：实锤（行为）/静态推演（触发前提）。违反第 5/11 条。
8. `lib/core/api/kugou_api_client.dart`:13 + `lib/core/config/app_config.dart`:15 —— 默认 `baseUrl` 仍为 kapi 中转域名，`AuthRepository` 默认构造 `KugouApiClient()` 存在；与「运行期绝不调用」注释冲突，未注入路径会走中转包装。证据：实锤（潜在路径）/静态推演（正常 Provider 未触发）。违反第 27 条。

### P2（15 条）
1. `lib/core/domain/quality.dart`:80 —— 未知/空音质字符串静默归一 `q128`，解析失败与「用户选标准」不可区分。违反第 11/16 条。实锤。
2. `lib/core/domain/song.dart`:126 —— 单位按字段名白名单且首轮非零值优先，混合秒/毫秒字段响应可差 1000 倍。违反第 15/14/17 条。静态推演。
3. `lib/core/domain/song.dart`:64 —— 多歌手 join('、') 后歌名前缀严格相等条件失效，合唱曲名带歌手前缀。违反第 14 条。实锤（逻辑）/未实测（响应形态）。
4. `lib/core/domain/song.dart`:91 —— `info.image`/`trans_param.union_cover` 无类型校验直接插值成 cover。违反第 13/14 条。实锤。
5. `lib/core/domain/song.dart`:167 —— `==`/`hashCode` 只认 hash，`copyWith(quality/localPath/clearLocalPath)` 结果判等，依赖集合去重的调用方无法察觉音质/离线源变化。违反第 3/5 条。静态推演。
6. `lib/core/domain/song.dart`:148 —— `quality` 仅从 `quality` 单字段解析，搜索结构缺失时经 `fromString('')` 静默落 `q128`。违反第 3/16 条。静态推演。
7. `lib/core/domain/response_policy.dart`:48 —— `status == 200` 无条件成功，忽略业务错误码，与注释「errcode=200 正常」矛盾。违反第 3/29 条。实锤（分支）/未实测（端点样本）。
8. `lib/core/domain/response_policy.dart`:49 + `:33-36` —— `status=0/2` 且 `errorCode=0` 改写为 `-1`，丢失原 status，按码分流/提示退化。违反第 3/8/17 条。实锤。
9. `lib/core/domain/response_policy.dart`:29 —— `status` 未做字符串归一，`'0'`/`'2'`/`'200'` 绕过失败分支。违反第 13/14/29 条。静态推演。
10. `lib/core/domain/response_policy.dart`:40 —— `err_code` 非数值被 `codeOf` 归零为「无错误」，评论类失败被当成功。违反第 13/14 条。实锤（归一逻辑）/未实测（上游形态）。
11. `lib/core/config/app_config.dart`:15 —— kapi/proxy/第三方翻译基址常量与清理计划/用途说明不齐；配置层与「原生网关唯一」口径不一致。违反第 27/2/31 条。静态推演。
12. `lib/core/api/kugou_api_client.dart`:136-143 —— 降级日志宣称「will switch to persistent」但实际不切换，`debugPrint` 无用户可见留痕、无状态供上层查询。违反第 9/11 条。实锤。
13. `lib/core/api/kugou_api_client.dart`:186 + `lib/features/auth/data/auth_repository.dart`:230/351 —— 登录 Cookie 写 kapi 域，对原生域请求不匹配；当前由 `KgClient` 字段补偿，属隐蔽契约错配与切号 `deleteAll` 范围过大。违反第 5/27/29 条。实锤（链路）。
14. `lib/core/api/translate_api.dart`:29 / `:60` —— 504/412/429 抛 `DioException` 越出 `Future<List<String>>` 契约（调用方重试一次兜住后该批保留原文）；译文行数不符时按位置补齐/截断并经 `emit` 当次显示错行。违反第 3/8/11/9 条与第 14/17 条。静态推演（Dio 默认语义）/实锤（对齐逻辑）。
15. `lib/core/api/kugou_api_client.dart`:167 —— `get`/`post` 泛型写死 `Map<String, dynamic>`，与 REVIEW_SPEC 列出的 List/二进制端点形态及「逐端点实测」要求不一致。违反第 3/13 条。静态推演。

### P3（5 条）
1. `lib/core/foundation/errors.dart`:3 —— 注释称「原位置 re-export 兼容」，实际兼容层在 `kugou_api_client.dart:3`，且 `REFACTOR_PLAN_V5.md` 执行记录称已放弃兼容层。违反第 30/31 条。实锤。
2. `lib/core/domain/quality.dart`:1 —— 未使用 `package:flutter/foundation.dart` 导入（dart analyze 在无依赖环境下报 `uri_does_not_exist`）。违反第 32 条。实锤。
3. `lib/core/domain/quality.dart`:6 —— 注释「super > high > flac > 320 > 128」与 `values`/`index` 声明顺序相反，特殊档混排；`index` 语义无约束。违反第 30/15 条。静态推演。
4. `lib/core/config/app_config.dart`:34 —— `supportedLocales`/`localeNames` 手写表与 `AppLocalizations.supportedLocales` 靠人工同步，无编译期约束。违反第 5 条。静态推演。
5. `lib/core/api/kugou_api_client.dart`:5 / `:101-113` / `lib/core/api/translate_api.dart`:32 / `:26` —— 「绝不写只读路径」注释无可写性探测；`lyricTranslateMaxLinesPerBatch` 常量与调用方硬编码 40 无关联；`targetLanguage`/歌词文本无转义直接拼 prompt 且无批次标识。违反第 31/2/5/32/3/14 条。静态推演。

## 复核通过项（本范围确认到位的设计）

1. M1 上移后 `ApiException` 唯一定义位于 `lib/core/foundation/errors.dart`，`kugou_api_client.dart:3` re-export 使 `friendly_error.dart`/`auth_repository.dart`/`verification_guard.dart` 的旧导入链仍可解析；7 个范围文件中无 `core → features` 反向 import（REFACTOR_PLAN §一/§二铁律）。
2. `AudioQuality` 的 wire 名与设置页 `:46-69` 的 key 一致（`'high'`、`viper_*`、`magic_*` 等 14 档），`fromString` 覆盖 `hires`/`hi-res`/`hiresample`/`master`/`母带`/`臻品` 与无前缀魔法档，设置页旧值不会漏解析为 128。
3. `AudioQuality.fallbackOrder`/`viperOrder`/`magicOrder` 与 `isSpecial` 在 `player_repository.dart:250-257` 按族隔离降级，`_resolveViaKapi` 只用通用 `fallbackOrder`；特殊音源不落普通档，族边界契约闭环。
4. `Song.duration` 用 `Duration` 类型显式单位，`setDuration` 对秒字段用 `Duration(seconds:)`、毫秒字段用 `Duration(milliseconds:)`；`main.dart:429` 的 `Duration(seconds: s.duration)`、`models.dart:50/101-113` 的秒单位与 `~/1000` 归一同向，未发现跨层隐式截断。
5. `Song.copyWith(clearLocalPath: true)` 显式表达 nullable 字段清除语义；`player_repository.dart:145/170` 详情合并时回填 `song.localPath` 与 `song.quality`，未把详情响应的 `quality` 反写覆盖用户选择。
6. `evaluateResponse` 对 `status=1/200/0/2`、`err_code` 优先、空响应体和「其余非空体 ok」给出 5 类可穷尽分支，`ApiOutcome.ok/fail` 返回类型统一；`kg_direct_api_client.dart:78-82` 的 `_wrap` 已改为只做适配+`throw outcome.failure!`，不再重写业务语义。
7. `ApiException` 携带 `ssaCode`/`verifyUrl`/`body`，`KgResponse.ssaCode` 兼容 `ssaCode`/`ssa_code`/响应头 `ssa-code` 并 `toString()`；`_wrap(r.body, ssaCode: r.ssaCode)` 把响应头形态传入策略层，20028 验证事件在 `verification_guard.dart`/`auth_repository.dart` 有消费点。
8. `KugouApiClient._needsTimestamp` 对登录/设备/验证/写操作/评论/import 路径附加毫秒时间戳，避免 kapi 的 2 分钟 URL 缓存导致二维码串号与 dfid 复用；`setCredentials` 对 `t1/auth/dfid` 为 null 时写空 Cookie 清除旧值，防止切号票据串号。
9. `KgDirectApiClient.fallbackToKapi = false` 且 `get`/`post` 未移植路径抛 `ApiException(-404)` 包装成 `DioException`，写端点全部 `write: true` 禁回退；正常装配 `kugouApiClientProvider → kgDirectApiProvider` 不发 kapi 请求。
10. `main.dart:82-90` 在 `runApp` 前 `await` 设置 `cookieStoragePath`，`app/di.dart` Provider 惰性创建，正常冷启动路径 `sharedCookieJar` 首次调用时路径已就绪；`_createCookieJar` 捕获构造异常并 `debugPrint` 留痕，不阻塞登录。
11. `TranslateApi` 对 `choices` 非 List/空列表、`choices[0]` 非 Map、`content` 为 null/空白显式 `return lines`；`lyric_repository.dart:176-215` 按 40 行切批、失败重试一次、失败批不写持久缓存、`translated.length != batch.length` 不落缓存并留痕，504/限流不会永久污染译文缓存。
12. `AppConfig.supportedLocales`/`localeNames` 10 种语言一一对应；`translateApiBase` 与 `translateModel`、`lyricTranslateMaxTokens` 集中配置，`TranslateApi` 带浏览器 UA 规避已记录的 412 WAF 拦截。
13. `errors.dart`/`song.dart`/`response_policy.dart`/`app_config.dart` 逐文件 `dart analyze` 项目自有类 0 错误；`quality.dart`/`kugou_api_client.dart`/`translate_api.dart` 除 Flutter/三方包符号缺失噪音外无项目自有类错误（逐文件输出见下）。

## 逐文件 `dart analyze` 结果（过滤噪音后）

执行环境：`export PATH=$PATH:/opt/dart/bin && dart --version` → Dart SDK 3.13.7；工作目录 `/var/minis/workspace/TiernanMusic`；未执行 `flutter`/`dart pub get`/构建/测试；无 `.dart_tool/package_config.json`，故 `package:flutter/*`、`package:dio/*`、`package:dio_cookie_manager/*`、`package:cookie_jar/*` 均报 URI 不存在，属预期噪音。

1. `lib/core/foundation/errors.dart`
   ```
   Analyzing errors.dart...
   No issues found!
   exit=0
   ```
   噪音：无。项目自有类错误：0。结论：通过。

2. `lib/core/domain/quality.dart`
   ```
   Analyzing quality.dart...
     error - quality.dart:1:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. - uri_does_not_exist
   1 issue found.
   exit=3
   ```
   噪音：1 条 Flutter SDK 缺失（该 import 同时为 P3 未使用导入）。项目自有类错误：0。结论：通过（自有类 0 错误）。

3. `lib/core/domain/song.dart`
   ```
   Analyzing song.dart...
   No issues found!
   exit=0
   ```
   噪音：无（仅相对 import `quality.dart`）。项目自有类错误：0。结论：通过。

4. `lib/core/domain/response_policy.dart`
   ```
   Analyzing response_policy.dart...
   No issues found!
   exit=0
   ```
   噪音：无（仅相对 import `../foundation/errors.dart`）。项目自有类错误：0。结论：通过。

5. `lib/core/config/app_config.dart`
   ```
   Analyzing app_config.dart...
   No issues found!
   exit=0
   ```
   噪音：无。项目自有类错误：0。结论：通过。

6. `lib/core/api/kugou_api_client.dart`
   ```
   Analyzing kugou_api_client.dart...
     error - 4× uri_does_not_exist (dio / dio_cookie_manager / cookie_jar / flutter foundation)
     error - 25× undefined_method / undefined_class / type_test_with_undefined_name
             （Dio / BaseOptions / CookieManager / InterceptorsWrapper / DioException /
               CookieJar / PersistCookieJar / FileStorage / Cookie / debugPrint 等三方符号）
     warning - kugou_api_client.dart:142:35 - Dead code - dead_code
   30 issues found.
   exit=3
   ```
   噪音：4 条 URI + 25 条三方符号未定义 + 1 条因 `PersistCookieJar` 未定义导致的死代码告警，均由无 package_config 引起。项目自有类错误：0。结论：通过（自有类 0 错误）。

7. `lib/core/api/translate_api.dart`
   ```
   Analyzing translate_api.dart...
     error - translate_api.dart:1:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. - uri_does_not_exist
     error - 3× undefined_method / undefined_class（Dio / BaseOptions）
     warning - translate_api.dart:56:44 - Dead code - dead_code
   5 issues found.
   exit=3
   ```
   噪音：1 条 URI + 3 条三方符号未定义；`56:44` 死代码告警对应 `(first is Map ? first['message'] : null)?['content']` 中 `?:` 的 null 分支静态不可达（与分析器在缺失 Dio 类型下的推断有关），非项目自有类错误。项目自有类错误：0。结论：通过（自有类 0 错误）。

**analyze 总结**：7/7 文件已逐文件执行并贴结果；过滤 Flutter/三方包符号缺失噪音后，项目自有类错误 0，全部通过。未做项：未安装/下载 SDK、未 `dart pub get`、未构建、未跑测试、未启动服务、未真机实测上游响应形态（任务书第 5 条与 QUALITY_STANDARD 第八章禁止）；因此所有「上游返回形态」相关结论均按静态推演/未实测标注，未以 kapi 返回作为原生网关实测依据（第 33 条）。
