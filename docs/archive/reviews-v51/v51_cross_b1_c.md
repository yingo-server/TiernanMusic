# v5.1 交叉审查 B1 · 视角 C：用户路径与一致性

- 批次：B1；视角：C（用户可见路径、三态、i18n/单位/命名一致性、生命周期、跨模块契约、v5.0 重构回归）
- 范围：`lib/core/foundation/errors.dart`、`lib/core/domain/{quality,song,response_policy}.dart`、`lib/core/config/app_config.dart`、`lib/core/api/{kugou_api_client,translate_api}.dart`（共 7 个 .dart 文件，719 行；`find` 递归核对 `foundation/**`、`domain/**`、`config/**` 下无其它 .dart 文件）
- 判定依据：`docs/QUALITY_STANDARD.md`（33 条，冲突时优先）；`docs/REVIEW_SPEC.md` 为补充
- 方法：每文件 `file_read` 从头到尾完整读，读完即落盘；仅用 grep 核对 import 路径有效性；只读源码，不修改任何代码文件
- 关注点：冷启动登录态恢复（CookieJar 降级后是否静默匿名）、翻译失败/超时后歌词是否仍可用、音质选择显示与实际请求是否一致、错误文案是否到 Toast、domain 上移后 12 个消费方符号正确性、i18n/单位/命名一致性、v5.0 重构回归风险

---

## 1. `lib/core/foundation/errors.dart`（30 行，完整读）

### errors.dart:26 注释声称「唯一常量见 response_policy.dart」，本行却硬编码 20028
- 级别：P2
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 30 条（命名即文档）
- 依据：文件头注释「20028 判定收敛在 [needsVerification]，其他层不得重复硬编码错误码」，但 getter 本体写作 `errorCode == 20028`，行尾注释又写「唯一常量见 response_policy.dart」；即注释所声明的唯一事实源与实现不一致，判定口径存在两处可独立修改的位置。
- 影响：一旦 response_policy.dart 中的 20028 常量口径调整（或补充「ssaCode/body 联合判定」），`needsVerification` 与响应策略层会对同一响应给出不同结论，验证码弹窗可能不出现，用户看到操作失败却没有任何验证入口，登录/写操作卡死且无解释。
- 证据等级：实锤（本行/注释矛盾）；用户后果为静态推演（消费方未在范围内实测）

### errors.dart:10-23 `message` 为裸 String，无本地化键/错误码→文案映射契约，类内也无任何用户反馈出口
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：失败返回语义/文案形态未定义）、第 9 条（失败必须可观测）
- 依据：构造参数 `this.message` 是自由文本，`toString()` 仅输出 `'ApiException($errorCode): $message'`；全类无 l10n 键、无用户可见通知/Toast 钩子、无回调；注释自称「全仓错误翻译唯一出口」，但类本身不执行任何翻译，只保存上游字符串。
- 影响：错误文案能否到达 Toast 完全取决于每个调用方是否主动读取 `message`；任一 catch 分支只读 `errorCode` 或只打日志时，用户侧没有提示（静默失败）；直接把上游英文/技术错误串送 Toast 时，中文界面出现不可读的原文，多语言下文案语言随服务端漂移。
- 证据等级：静态推演（本文件为纯数据类，无反馈出口为实锤；Toast 链路未实测）

---

## 2. `lib/core/domain/quality.dart`（102 行，完整读）

### quality.dart:77-101 未知音质字符串静默回落 q128，且注释自述为「数据一致性红线」仍无留痕
- 级别：P1
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 11 条（降级必须有明确触发条件与退出条件）
- 依据：`fromString(String? s)` 中 `if (s == null) return q128;`，末尾 `return q128;` 兜底所有未命中字符串；全程无日志、无异常、无返回值内的「解析失败」语义，调用方无法区分「用户选了 128」与「持久化值损坏/新增档位未被识别」。文件自身注释写明「若别名缺失，用户在设置页选了『Hi-Res』而实际只请求 128k（设置页显示已生效但音质没变），属于数据一致性红线」，但实现把这一红线情形做成了默认行为。
- 影响：冷启动恢复设置、或 v5.0 重构后旧版本残留值遇到未覆盖别名时，设置页按已保存档位显示「Hi-Res/臻品母带」，实际播放请求 128k，用户听感变差且界面无任何提示；音质选择显示与实际请求不一致。
- 证据等级：实锤（解析逻辑）；用户可见后果为静态推演（设置页持久化形态未实测）

### quality.dart:8-24, 77-101 `label`（显示文案）与 `value`（wire 名）不对称，中文标签无法被 fromString 解析
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围/往返语义未定义）、第 30 条（命名即文档）
- 依据：枚举标签为 `'标准','高品','无损','Hi-Res','臻品母带'`，`fromString` 仅按 `value`（'128','320','flac','high','super'）匹配，别名表只含 `'hires','hi-res','hiresample','master','母带','臻品'`；`'臻品母带'`、`'高品'`、`'标准'`、魔法/蝰蛇各标签均不在别名表内，全部落到 `q128`。
- 影响：任何把 `AudioQuality.label` 或 UI 文案写进持久化/深链/外部配置的路径，读回后都变成 128k；同时设置页若用 label 做键值，用户看到「无损」而实际请求 128k，属显示与实际请求错配。
- 证据等级：实锤（本文件解析表）；消费方持久化字段形态为未实测（静态推演）

### quality.dart:13, 17-18, 83-99 注释声明「兼容无前缀写法」覆盖蝰蛇/魔法两族，实现只补了魔法族
- 级别：P2
- 违反：QUALITY_STANDARD 第 30 条（命名即文档）、第 3 条（跨模块契约与注释不符）
- 依据：注释「V399-B3：蝰蛇/魔法档显式解析……兼容无前缀写法（旧设置残留）」后，switch 内无任何蝰蛇 case，仅末尾有 `for (final q in magicOrder) { if (q.value == 'magic_$v') return q; }`；`'atmos'`、`'clear'`、`'tape'` 等无前缀旧值均落到 `q128`。
- 影响：升级到 v5.x 后，旧设置里残留的无前缀蝰蛇档用户在设置页看到与升级前不同的档位（被显示为 128k）且播放无声降级，蝰蛇音效消失无提示。
- 证据等级：实锤（注释与 switch 分支差集）；旧值是否真实写入未实测

### quality.dart:17-24, 88-91 魔法档 wire 名前缀归属自相矛盾
- 级别：P2
- 违反：QUALITY_STANDARD 第 15 条（单位/形态必须显式、不得靠注释猜测）、第 3 条（契约先行）
- 依据：枚举定义写 `magicPiano('magic_piano', …)` 即 value 已带 `magic_` 前缀；同段注释却写「`/v5/url` 需 `magic_` 前缀，由 KgSharedParams.songUrl 统一补前缀」；`fromString` 又注明「魔法档 wire 名带 magic_ 前缀（/v5/url 参数用），枚举 value 同名，直接按 value 命中即可」。若下游按注释再补一次前缀，请求参数会是 `magic_magic_piano` 一类形态。
- 影响：用户在设置页选中「魔法钢琴」等六档后，若下游重复补前缀，播放地址请求参数形态错误，可能静默回退到普通音源或返回无 URL；用户听到的是普通音质甚至播放失败，而界面仍显示魔法档已选中。
- 证据等级：静态推演（本文件两处注释与 value 定义互斥；下游拼参未实测）

### quality.dart:1 `import 'package:flutter/foundation.dart';` 未被使用，domain 层引入 Flutter 框架依赖
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 4 条（分层单向依赖：核心层不得依赖界面框架）
- 依据：全文 102 行无任何来自 `foundation.dart` 的符号（`values`/`contains` 均为 Dart SDK Enum/List 自带），该 import 为悬空引用；文件头注释声明「音质属领域概念，core/audio 不应依赖 features/player」，即该文件定位为纯领域模型，却仍绑定 Flutter 框架。
- 影响：v5.0「domain 上移」的回归风险——纯 Dart 侧（isolate / 后台解析 / 无 Flutter 环境的工具）复用该模型时被框架依赖拖住；对终端用户当前无直接可见异常，但使上移目标落空。
- 证据等级：实锤（全文无引用）；跨层复用受阻为静态推演

### quality.dart:8-24 音质显示文案为硬编码中文，无 i18n 键，且中英混排/拼写不一致
- 级别：P2
- 违反：QUALITY_STANDARD 第 30 条（命名即文档）、第 3 条（契约先行：显示文案形态未定义）
- 依据：`label` 是 `final String`，九档与六档魔法文案直接写在枚举里：`'Hi-Res'`、`'魔法DJ'`、`'魔法Surround'`（枚举名却是 `magicSurnay` / value `'magic_surnay'`）、`'魔法钢琴'` 等；无 `AppLocalizations` 键、无按 locale 取文案的入口。
- 影响：切换非中文语言环境时设置页/播放页音质档位仍显示中文，与其余已本地化界面语言不一致；`Surnay`/`Surround` 命名与显示文本互不对齐，用户与客服按名称核对档位时对不上。
- 证据等级：实锤（枚举字面量）；多语言界面表现为未实测

---

## 3. `lib/core/domain/song.dart`（175 行，完整读）

### song.dart:169-174 `operator ==` 只比 hash，忽略 quality/localPath/duration 等；且空 hash 破坏自反性
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 3 条（契约先行：相等语义未定义）、第 17 条（数值与标识符精度）
- 依据：`bool operator ==(Object other) => other is Song && other.hash == hash && other.hash.isNotEmpty;`，`hashCode => hash.hashCode;`。同一 hash 下 `quality`（音质）、`localPath`（离线资源）、`name`/`cover`/`duration` 全部不参与相等判定；`fromJson` 允许 hash 为空串（`str(['hash', …])` 无匹配返回 `''`），此时 `a == a` 为 false。
- 影响：v5.0 domain 上移后的回归风险——任何用 `==` 做「当前歌曲是否变化」判断的播放/UI 层，在用户切换音质（仅 `quality` 变化）或下载完成写入 `localPath` 后都会被判定为「同一首歌」而跳过重新解析 URL/切换离线源，表现为设置页显示「无损」但实际仍按旧档位（或仍走网络）播放，且无提示；空 hash 歌曲被判不等，列表/Set 中出现重复项、重复入队。
- 证据等级：实锤（相等实现）；UI/播放层用 `==` 短路的具体链路为静态推演、未实测

### song.dart:160-161 无 quality 字段时经 `str()` 返回空串并静默解析为 q128
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条（空集合与缺失必须语义分离）
- 依据：`quality: AudioQuality.fromString(str(['quality']))`；`str(List<String> keys)` 在全部 key 缺失时 `return ''`，`AudioQuality.fromString('')` 末尾兜底 `return q128`。文件注释已写明 `/search` 字段清单中不含 `quality`（仅 `/privilege/lite` 有），且「quality_vip 可为 null，best_free_quality 在该部署版中不存在」。
- 影响：从搜索结果进入播放的歌曲，`Song.quality` 恒为 q128，无法区分「上游确实没有音质信息」「用户选了 128」「非 VIP 只返回 128」三种业务事实；若任一界面把 `Song.quality.label` 当作「当前播放音质」展示，用户选了 Hi-Res/无损后界面仍显示「标准」，与设置页和实际请求不一致；匿名/非 VIP/VIP 三态下显示为同一档。
- 证据等级：实锤（字段清单 + 兜底链）；界面是否消费 `Song.quality` 为未实测（静态推演）

### song.dart:76-82 / 90-104 外部字段以 `'$v'`/`'${...}'` 直接字符串化，未逐分支校验类型
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）
- 依据：`str()` 中 `if (v != null && '$v'.isNotEmpty) return '$v';` 对任意 `Map`/`List`/`bool` 均插值；`artist = '$singer';`（singer 非 List 时）；`cover = '${info['image'] ?? ''}'`、`cover = '${transParam['union_cover'] ?? ''}'` 同样直接插值；`json['singer']` 的 List 分支还使用 `e['name']` 对 `e is Map` 直接取键。文件头自述「兼容 /search 和 /privilege/lite 的返回结构」即网络边界。
- 影响：上游把 `Image`/`info.image`/`singer` 改成对象或数组时，界面不崩溃但显示 `{key: value}`、`[…]` 这类原始 Dart 对象文本作为歌手名/封面 URL；封面 URL 非法导致图片加载失败且无降级图，歌手名出现乱码文本，属用户可见的显示污染。
- 证据等级：实锤（字符串化路径）；上游字段形态变化为静态推演、未实测

### song.dart:88-92, 110-120 歌名前缀剥离依赖 artist 精确相等，多歌手场景不生效
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条（命名即文档）、第 14 条（数据边界校验）
- 依据：`final sep = raw.indexOf(' - '); if (sep > 0 && (artist.isEmpty || raw.substring(0, sep) == artist))`；而 artist 在 `singer` 为 List 时用 `'、'` 拼接（`join('、')`），`/privilege/lite` 的 `name` 是「歌手 - 歌名」形式。多歌手时 `raw` 前缀与其拼接结果不等，走 `else { name = raw; }`。
- 影响：合唱歌曲在播放页/列表里显示成「周杰伦、林俊杰 - 稻香」整体作为歌名，与歌手行重复、文案截断，用户看到的曲名与酷狗官方曲名不一致。
- 证据等级：实锤（字符串比对逻辑）；具体上游 name 形态为静态推演、未实测

### song.dart:125-148 时长解析失败静默返回 Duration.zero，进度/总时长显示 0:00
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 15 条（单位必须显式）
- 依据：`setDuration` 对 `num` 之外的值用 `int.tryParse('$raw')`，解析失败直接 `return` 且无日志/异常；三个秒键循环、三个毫秒键循环、以及 `info['duration']` 共 7 个键，以「先命中且 >0 者胜」的隐式优先级混合秒/毫秒两个单位，函数名 `setDuration(dynamic raw, {required bool millis})` 之外的键名单位归属只写在注释里。
- 影响：上游返回 `"3:45"`、`"240.5"` 或新增单位口径字段时，`Song.duration` 为 0，播放页总时长显示 `0:00`、进度条无法拖动/进度百分比异常，且与音频引擎实际时长不一致；用户无法从界面区分「加载中」与「解析失败」。
- 证据等级：实锤（解析分支）；上游实际字段形态未实测

### song.dart:1 `import 'quality.dart';` 为相对路径，与 core 内其余文件的包路径风格不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 4 条（分层单向依赖）、第 30 条（命名即文档）
- 依据：v5.0 M1 把 `Song` 与 `AudioQuality` 一起上移 `core/domain`，本文件使用相对导入 `'quality.dart'`，而同层 `errors.dart` 注释声明「原位置 re-export 兼容」，即上移后存在新旧两套定位方式；`fromJson` 直接调用 `AudioQuality.fromString`，把网络字段解析与 UI 显示文案枚举绑在同一模型内。
- 影响：消费方若继续从旧路径导入 `AudioQuality` 而 `Song` 从新路径导入，会出现「两个同名类型」导致赋值/比较编译不过或运行期类型不匹配（跨模块契约回归）；对终端用户表现为升级后部分页面音质档位空白或选档无效。
- 证据等级：静态推演（相对导入为实锤；旧路径 re-export 是否存在需核对 import 有效性，见后文契约核对节）

---

## 4. `lib/core/domain/response_policy.dart`（66 行，完整读）

### response_policy.dart:64-66 `requiresVerification` 与 `ApiException.needsVerification` 并存，注释宣称「唯一出口」却不复用
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 8 条（异常契约必须单一且稳定）
- 依据：本文件注释「全仓 20028 判定唯一出口。消费方不得再硬编码错误码」，实现为 `e is ApiException && e.errorCode == kVerificationRequired`；而 `errors.dart:25` 的 `ApiException.needsVerification` 又写 `errorCode == 20028`，`ApiOutcome.needsVerification`（本文件第 19 行）走的是第三条路径 `failure?.needsVerification`。三处判定、两个字面量来源（常量 vs 硬编码）、且 `requiresVerification` 按 `errorCode` 比较而 `needsVerification` 只看 20028。
- 影响：v5.0 M4「20028 单点」目标在跨模块契约上落空——风控返回 20028 时，若 UI 层用 `requiresVerification(e)` 而网络层用 `ApiOutcome.needsVerification`，两者对同一异常可能给出不同结论，验证码弹窗不出现；用户在登录/收藏/评论时只看到「请求失败」Toast 或完全无反馈，操作反复失败且无法自助解除风控。
- 证据等级：实锤（三处判定并存）；消费方分别用哪个 API 为静态推演、未实测

### response_policy.dart:28, 34-37 `fail(int code)` 把 `errorCode == 0` 静默改写成 -1，风控码/business code 丢失
- 级别：P1
- 违反：QUALITY_STANDARD 第 17 条（数值与标识符精度不容协商）、第 9 条（失败必须可观测）
- 依据：`ApiOutcome.fail(ApiException(code == 0 ? -1 : code, msgOf(), ...))`；`codeOf(Object? v)` 对非 int/不可解析值 `int.tryParse('$v') ?? 0` 统一归 0。当 `status==0/2` 且 `error_code`/`errcode` 缺失或为字符串形态不可解析时，所有失败都被压成 `ApiException(-1, …)`，原始错误码不可追溯；`body` 虽保留但 `ApiException.errorCode` 已失真。
- 影响：上游真实错误码被抹平后，任何按 `errorCode` 分支的用户提示（VIP 限制、需要登录、区域限制、验证码）都会走默认文案，用户看到与真实原因无关的「请求失败」，且客服/日志按 -1 无法定位；对上层的 20028 判定亦依赖该字段，改写后不会触发验证码流程。
- 证据等级：实锤（改写逻辑）；上层按 code 分支的文案表为静态推演、未实测

### response_policy.dart:31-32, 50-53 错误文案直接取服务端 `error`/`info` 原文，中文兜底固定为 `'请求失败'`，无 i18n
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：失败文案形态未定义）、第 9 条（失败必须可观测）
- 依据：`msgOf()` 依次取 `body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'` 并用 `'${...}'` 插值成裸 String；`ApiException.message` 无本地化键；`body.isEmpty` 分支另写死 `'空响应体（可能被风控拦截）'` 中文。
- 影响：服务端返回英文/技术串（或 Node 层包装的错误聚合文本）时，Toast 显示不可读原文；非中文 locale 下仍显示中文「请求失败」「空响应体（可能被风控拦截）」；`info` 在部分成功响应里是提示语而非错误，被当作错误信息弹给用户，形成假失败提示。
- 证据等级：实锤（文案来源）；Toast 是否直接展示 `message` 为未实测（静态推演）

### response_policy.dart:36 `body['ssaCode'] as String?` 对外部字段裸强转
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）
- 依据：`ssaCode: body['ssaCode'] as String? ?? ssaCode`，无 `is String` 前置判断；文件头声明本文件为网络层响应解析的统一入口（网络边界）。
- 影响：上游把 `ssaCode` 返回为 int/Map（或数字型验证事件 id）时抛未捕获 `CastError`，本应是「业务失败」的请求变成崩溃或落到兜底 catch；用户侧表现为操作中断、页面报错，且 20028 验证流程无法继续。
- 证据等级：实锤（强转语句）；崩溃是否被上层兜住为未实测

### response_policy.dart:43-49 `status == 200` 无条件判成功；与 REVIEW_SPEC「歌词类 status=200 + errcode=200」口径不符
- 级别：P2
- 违反：QUALITY_STANDARD 第 29 条（返回结构必须实测并留样，成功判定口径逐端点确认）、第 3 条（契约先行）
- 依据：注释「歌词类：status=200 + errcode=200 是正常码」，实现 `if (status == 200) return ApiOutcome.ok(body);`，未检查 `errcode` 值、未区分端点；同时 `if (status == 1)` 分支引用 `_hasData` 要求有数据体，而 `status == 200` 分支连空 `data` 也直接 ok。`status == 1` 与 `status == 0/2` 用严格 int 比较，而 `err_code` 兼容字符串形态（`codeOf`），同为状态码的 `status` 却不兼容 `'1'`。
- 影响：歌词/翻译响应里 `status=200` 但 `errcode` 为其他值、或 data 为空时，被判为成功并进入歌词解析，用户看到空白歌词/无翻译且无「加载失败」提示，也无法重试；服务端把 status 以字符串 `"1"` 返回时，`status == 1` 为 false、`errorCode == 0`、`body` 非空，最终落到 `return ApiOutcome.ok(body)` 把失败响应当成功。
- 证据等级：静态推演（实现与注释/规范口径差异为实锤；真机返回形态未实测）

### response_policy.dart:49-53 「空响应体可能被风控拦截」是单一猜测式文案，实际触发条件与文案不符（v5.0 行为逐分支上移带入）
- 级别：P3
- 违反：QUALITY_STANDARD 第 31 条（注释解释「为什么」，须记录上游反常行为）、第 3 条（契约先行：失败语义未定义）
- 依据：注释称本函数「行为逐分支保持」自 `_wrap`，但 `body.isEmpty` 分支把「完全空 Map（通常是传输层解码失败/被网关截断）」直接翻译成 `'空响应体（可能被风控拦截）'`，并以 `ssaCode: ssaCode` 伪装成风控；空 Map 时无 `status`、无 `error_code`，`errorCode` 为 0，最终 `ApiException(-1, 中文文案)`。
- 影响：网络被截断/代理返回空体时，用户 Toast 提示「可能被风控拦截」并可能引导去做验证，反复操作无效；同时没有任何状态码可供客服定位，属误导性提示。非中文 locale 下该串仍为中文。
- 证据等级：实锤（分支与文案字面量）；用户侧 Toast 展示路径为静态推演、未实测

---

## 5. `lib/core/config/app_config.dart`（56 行，完整读）

### app_config.dart:31-45 语言集合存在两份权威源，注释自承「必须保持一致」却无编译期约束
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 3 条（契约先行）
- 依据：注释写明「运行期 UI 解析用 `AppLocalizations.supportedLocales`（由 l10n 工具从 `lib/l10n/*.arb` 生成，含裸 zh 兜底）；本表**只供设置页语言选择器排序与显示名**，二者必须保持一致——新增 arb 文件时同步更新本表，否则会出现『可选语言与实际解析集合不一致』」；实现为硬编码 `static const List<String> supportedLocales = ['zh_CN', … , 'ru']` 与 `localeNames` 映射，二者与生成物之间没有任何断言或生成期校验，且注释另说明 `app_zh.arb`（裸 zh）「不作为独立选项暴露」。
- 影响：v5.0/v5.1 迭代中新增或删除 arb 时，设置页列出的语言与运行期可解析语言不一致：用户选择某语言后界面语言不变（或反向：系统 locale 命中了生成物支持但设置页无法选择的语言，界面变成该语言而设置页无法切回）；用户会认为「语言设置无效」，且无任何错误提示。
- 证据等级：静态推演（双源声明为实锤；arb 实际键集与设置页消费方式未实测）

### app_config.dart:11-16 Cookie 存储域仍绑定 kapi 中转域，与「直连层全部使用原生域名」并存
- 级别：P1
- 违反：QUALITY_STANDARD 第 27 条（接口只走原生网关）、第 5 条（状态单一来源）
- 依据：注释「kapi…运行期绝不调用……该常量仅供 KugouApiClient 的 CookieJar 域名占位使用（Cookie 只存本地，不发包），直连层 KgClient 全部使用酷狗原生域名。清理计划：待 Cookie 存储迁移到原生域后删除本常量」；即登录态持久化的键域与真实请求域不同，`kugouApiBase` 仍留在配置中作为「尚未移植路径」。
- 影响：冷启动恢复登录态时，CookieJar 按 kapi 域装载 cookie，而直连请求发往 `gateway.kugou.com`/`login-user.kugou.com` 等原生域，按域匹配的 cookie 不会随请求发出；用户重启 App 后从「已登录」静默变成匿名态，收藏/歌单/评论/VIP 音质全部按匿名返回，界面若仍显示上次缓存的头像昵称则更不一致。
- 证据等级：静态推演（配置注释明示键域差异为实锤；CookieJar 实际装配与恢复时序需结合 `kugou_api_client.dart` 判定，见该文件节）

### app_config.dart:17-19 `translateApiBase` 为第三方 AI 翻译端点，`proxyBase` 同域系且无清理注释
- 级别：P2
- 违反：QUALITY_STANDARD 第 27 条（第三方中转网关必须写明原因与清理计划）、第 32 条（死代码零容忍）
- 依据：`translateApiBase = 'https://index-translate.bilibili.com/v1/chat/completions'`、`proxyBase = 'https://proxy.344977.xyz'`、`translateModel = 'Index-Translate-35B-A3B'`；仅 `kugouApiBase` 有「参考实现/运行期绝不调用/清理计划」注释，`proxyBase` 与 `translateApiBase` 没有任何来源、契约或清理计划说明；`platform = ''` 为空字符串且注释称「平台：kugou 标准版」，空串作为配置值语义不明。
- 影响：歌词翻译功能依赖外部第三方模型服务，服务变更/限流/下线时用户侧翻译按钮无响应且无本地化说明；`proxyBase` 在本次可读范围内无消费方，属于遗留半成品配置，后续接入易把未声明的中转域引入主路径。
- 证据等级：静态推演（常量字面量与注释缺位为实锤；运行期是否真的请求该域需结合 `translate_api.dart`，见后文）

### app_config.dart:4-6 应用名三套字符串硬编码，无 i18n 键
- 级别：P3
- 违反：QUALITY_STANDARD 第 30 条（命名即文档）、第 5 条（状态单一来源）
- 依据：`appName = 'Tiernan Music'`、`appNameCn = '汀澜音乐'`、`appId = 'com.tiernan.music'` 三个常量并存，无 locale 到名称的映射；`appNameCn` 表明中文名需要单独一份事实。
- 影响：非中文 locale 下的关于页/通知栏/分享文案若使用 `appNameCn`，会出现中文应用名与全英文界面混排；反之中文界面出现英文名，用户可感知品牌不一致。
- 证据等级：未实测（本文件为常量定义，消费方未实测）

---

## 6. `lib/core/api/kugou_api_client.dart`（215 行，完整读）

### kugou_api_client.dart:132-147 共享 CookieJar 降级后缓存内存 jar，且「路径未就绪」分支每次新建独立 jar，冷启动登录态静默丢失
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 11 条（降级必须有明确触发条件与退出条件）、第 9 条（失败必须可观测）
- 依据：`static CookieJar get sharedCookieJar` 中，路径未就绪时 `debugPrint('[cookie] storage path not ready, using in-memory jar (will switch to persistent once path is set)'); return CookieJar();` —— 每次调用都 new 一个不共享、不缓存的 jar；路径就绪分支 `final jar = _createCookieJar(path); if (jar is! PersistCookieJar) { debugPrint('[cookie] WARNING: ... logins will NOT survive restart'); } return _sharedJar = jar;` —— 降级产生的内存 jar 被写进 `_sharedJar` 并因首行 `if (_sharedJar != null) return _sharedJar!;` 永久返回，无退出条件。注释自述两道防线「路径就绪后自然切到持久化」，但实现既不迁移已写入内存 jar 的 cookie，也不在持久化恢复后退出内存态。
- 影响：冷启动或低端机上 path 尚未设置时构造的客户端各自持有不同 jar，`setCredentials` 写入 A 的 token，B 发的请求仍是匿名；随后持久化 jar 建立，内存态 cookie 全部丢弃。用户看到「登录成功/头像仍在」但收藏、歌单、VIP 音质、评论均按匿名返回，下一次冷启动直接被登出，全程只有 debugPrint，没有任何 Toast 或「登录已失效」提示。
- 证据等级：实锤（getter 分支与 `setCredentials` 写入路径）；冷启动 Provider 构造时序为静态推演、未实测

### kugou_api_client.dart:23 `baseUrl` 默认取 kapi 中转域，与 app_config 注释「运行期绝不调用」直接冲突
- 级别：P1
- 违反：QUALITY_STANDARD 第 27 条（接口只走原生网关）、第 31 条（注释必须解释原因、不得与代码相悖）
- 依据：构造函数 `_dio = Dio(BaseOptions(baseUrl: baseUrl ?? AppConfig.kugouApiBase, …))`，而 `AppConfig.kugouApiBase = 'https://kapi.344977.xyz'`；`get(String path, …)` 与 `post(String path, …)` 直接用相对 path 调 `_dio.get(path)` / `_dio.post(path, data…)`。即任何未显式传 `baseUrl` 的 `KugouApiClient()` 实例，其请求真的发往 kapi；而 `app_config.dart:10-14` 明确写「kapi…运行期绝不调用……仅供 CookieJar 域名占位使用」，`_needsTimestamp` 注释（152-154 行）又以「kapi 对全部 200 响应按 URL 做 2 分钟全局缓存」为设计前提。三处陈述互相矛盾。
- 影响：v5.0「原生网关唯一」重构的回归风险——任一新装配点漏传 `baseUrl` 就整体回落到 kapi 中转，成功/失败形态、错误文案、字段结构由 Node 层包装（第 33 条），用户侧表现为部分页面数据正常、部分页面字段缺失或「请求失败」，且排查时无法据 kapi 返回判断直连问题。
- 证据等级：实锤（默认值 + 相对 path 调用）；实际装配是否漏传 baseUrl 为未实测（静态推演）

### kugou_api_client.dart:38-90 与 response_policy.dart 各自实现一套成功/失败/风控判定，主路径与回退路径口径不一致
- 级别：P1
- 违反：QUALITY_STANDARD 第 8 条（异常契约必须单一且稳定，回退路径与主路径的异常形态必须一致）、第 5 条（状态单一来源）、第 29 条（成功判定口径逐端点确认）
- 依据：`response_policy.dart:3-5` 声明「网络层（KgClient / **KugouApiClient**）只负责传输；成功/失败/风控判定**全部收敛于此**」，但 `kugou_api_client.dart` 的 `onResponse` 拦截器自带 `status`/`errorCode`/`warningCodes = {0,151,152,200,201}`/`errorCode == 20028 ? '需要完成人机验证'` 判定并 `handler.reject(DioException(... error: ApiException(...)))`；该文件未 import `response_policy.dart`（import 路径核对已确认），而 `lib/core/direct/kg_direct_api_client.dart:14` 才 import 它。具体分叉：`status == 200` 时本项目 onResponse 会因 `error_code` 非白名单而 reject，`evaluateResponse` 第 48 行却 `return ApiOutcome.ok(body)` 无条件判成功；`status == 1` 时前者用 `int.tryParse('${data['status'] ?? 1}')` 兼容字符串并放行 151/152/200/201，后者 `status == 1` 为严格 int 比较且靠 `_hasData` 决定成败；`msgOf()` 取 `error → error_msg → errmsg → info → '请求失败'`，本文件取 `error_msg → errmsg → error → info → defaultMessage`，优先级相反；`fail(int code)` 把 0 改写为 -1，本文件把不可解析 rawCode 置 -1 而保留 0。
- 影响：同一份上游响应在直连主路径与 kapi 回退路径得到相反的成败结论与不同的 Toast 文案——例如歌词接口 `status=200` 带 `error_code=1`：直连侧判成功进入解析（用户看到空白歌词无报错），回退侧判失败（用户看到「未知错误」）；20028 风控时回退侧显示「需要完成人机验证」，直连侧只有服务端原文或「请求失败」，用户拿不到可操作的指引，反复点击无效。
- 证据等级：实锤（两套判定逐分支对照）；具体端点真机返回形态未实测（静态推演）

### kugou_api_client.dart:71-84 ssaCode 提取口径与 response_policy 不一致，验证码流程在直连侧可能拿不到事件 id
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：跨层字段来源未统一）、第 8 条（异常契约一致）
- 依据：本文件 `final ssaCode = (data['ssaCode'] ?? data['ssa_code'])?.toString().trim() ?? response.headers.value('ssa-code') ?? response.headers.value('ssa_code');`，兼容 body 两个键、响应头两个键、且 `toString()` 兼容非 String；`response_policy.dart:36` 仅 `ssaCode: body['ssaCode'] as String? ?? ssaCode`，只认一个 body 键、依赖调用方传参、且对非 String 直接强转。`ApiException.verifyUrl` 在错误类中被声明为「/get/verify/info 返回的 url」，但两个构造点都未赋值。
- 影响：风控 20028 时，若上游把 ssaCode 放在响应头或 `ssa_code` 键，直连路径构造的 `ApiException.ssaCode` 为 null，验证码页无法拼 `/get/verify/info` 参数，用户看到「需要人机验证」但验证弹窗加载失败或空白，无法解除风控。
- 证据等级：静态推演（字段提取差异为实锤；验证码页实际读取字段未实测）

### kugou_api_client.dart:76-85 错误以 `DioException(error: ApiException(...))` 抛出，`message` 字段与 Dio 自带模板并存，Toast 取错即显示英文技术串
- 级别：P2
- 违反：QUALITY_STANDARD 第 8 条（异常契约单一稳定）、第 3 条（契约先行）
- 依据：`handler.reject(DioException(requestOptions: response.requestOptions, response: response, error: ApiException(errorCode, '${...}', …)))` 未设置 `DioException.message`/`type`；`errors.dart` 的 `toString()` 输出 `ApiException($errorCode): $message` 也不含可本地化键。`lib/core/utils/friendly_error.dart:3` 与 `lib/core/widgets/error_retry.dart:7`（import 路径核对）都通过 `kugou_api_client.dart` 取得 `ApiException`（依赖第 4 行 `export '../foundation/errors.dart';`），即错误文案消费方必须自行从 `DioException.error` 解包。
- 影响：任一 catch 分支直接把 `e.toString()` / `DioException.message` 送 Toast 时，用户看到 Dio 的通用英文模板或 `ApiException(20028): ...` 技术串，而非中文「需要完成人机验证」；多语言环境下文案随调用方是否解包而漂移。
- 证据等级：静态推演（抛出形态为实锤；Toast 取值方式未实测）

### kugou_api_client.dart:168-171, 188-213 登录态存在「CookieJar」与「实例可变字段」两份权威，切号后各 client 不同步
- 级别：P1
- 违反：QUALITY_STANDARD 第 5 条（状态单一来源）、第 2 条（显式优于隐式：隐藏的全局状态）、第 17 条（标识符精度）
- 依据：`String userid = ''; String dfid = ''; String webglHash = '11664606328242161144';` 为**实例字段**；`setCredentials` 写 `_cookieJar.saveFromResponse(...)` 同时 `this.userid = userid; if (dfid != null) this.dfid = dfid;`；`clearCredentials` 调 `_cookieJar.deleteAll()` 并把本实例的 userid/dfid 置空。CookieJar 是进程级共享（第 116-122 行注释自述「登录态必须在所有实例之间共享」），而 userid/dfid 不是；`webglHash` 是硬编码字面量且永不随账号变化。
- 影响：切换账号时只有负责登录的那个 client 更新了 `userid`，其它已构造 client（播放器/评论/榜单）仍携带旧 userid 参与直连签名/权益查询，用户看到新账号头像下混着旧账号的收藏、歌单或 VIP 判定；退出登录时 `deleteAll()` 清空整个共享 jar（含 dfid 等设备态），下次登录需重新走设备注册/验证，表现为「刚退出再登录要验证码」。
- 证据等级：实锤（字段与写入点）；串号在界面上的具体表现为静态推演、未实测

### kugou_api_client.dart:173-185 `get`/`post` 把 `res.data == null` 静默转成 `{}`
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（失败必须可观测）、第 16 条（请求失败与确实为空必须语义分离）
- 依据：两个方法结尾均为 `return res.data ?? {};`；而 `response_policy.dart:50-53` 对 `body.isEmpty` 明确返回失败 `ApiException(-1, '空响应体（可能被风控拦截）')`。同一空体在两条路径上，一条被上层当「成功但无数据」，另一条当「失败」。
- 影响：网络被截断、网关返回 200 空体时，使用 `KugouApiClient.get` 的页面显示「暂无数据」/空白列表而不是「加载失败，点击重试」，用户以为内容确实为空；重试入口不出现，问题长期静默。
- 证据等级：实锤（`?? {}` 与对照分支）；页面空态渲染为静态推演、未实测

### kugou_api_client.dart:4 `export '../foundation/errors.dart';` 使 direct/net/widgets 层通过 api 层取 foundation 符号
- 级别：P3
- 违反：QUALITY_STANDARD 第 4 条（分层单向依赖）、第 32 条（死代码/遗留兼容层）
- 依据：import 路径核对显示 `lib/core/direct/kg_endpoints_playlist.dart:7`、`kg_endpoints_search.dart:7` 用 `import '../api/kugou_api_client.dart' show ApiException;`，`lib/core/utils/friendly_error.dart:3`、`lib/core/widgets/error_retry.dart:7` 同样经 api 层取 `ApiException`；而 `errors.dart:1` 注释声明「上移至 core/foundation，原位置 re-export 兼容」。即 v5.0 上移后仍保留一条「foundation 符号经 api 层再导出」的绕路。
- 影响：v5.1 清理该 re-export 时，直连层与错误展示组件同时编译失败，错误文案/验证码提示整条链路不可用；属重构回归风险，当前运行期无直接异常。
- 证据等级：实锤（export 与消费方 import 路径）；清理动作的后果为静态推演

### kugou_api_client.dart:1, 10-11 文件首行空行、连续 3 个空行、export 夹在 import 中间
- 级别：P3
- 违反：QUALITY_STANDARD 第 32 条（死代码零容忍）、第 30 条（命名即文档）
- 依据：第 1 行为空行，第 10-11 行为连续空行，`import` 序列中第 4 行插入 `export`，`import 'package:flutter/foundation.dart';` 与 `import '../config/app_config.dart';` 被空行拆散。
- 影响：无直接用户可见后果；属整洁度问题，但加大 v5.0 上移后 import/export 契约的人工核对成本。
- 证据等级：实锤

---

## 7. `lib/core/api/translate_api.dart`（75 行，完整读）

### translate_api.dart:31-42 翻译失败/超时（20s 连接 + 60s 接收）直接抛 DioException，未把「保留原文」作为降级出口
- 级别：P1
- 违反：QUALITY_STANDARD 第 11 条（降级必须有明确触发条件、次优行为、恢复条件）、第 9 条（失败必须可观测）、第 6 条（禁止吞掉异常）
- 依据：`translateLines` 内 `final res = await _dio.post<Map<String, dynamic>>(AppConfig.translateApiBase, ...)` 没有 try/catch；`connectTimeout: Duration(seconds: 20)`、`receiveTimeout: Duration(seconds: 60)`（第 8-9 行）。四个「退回原文」出口（第 49、57 行等）全部位于成功拿到 HTTP 响应之后，覆盖的是 `choices` 为空 / `content` 为空这类业务形态，**不覆盖** 412 WAF 拦截、5xx、DNS 失败、连接/接收超时等 DioException。函数签名 `Future<List<String>>` 也不区分「译文」与「原文回退」。
- 影响：翻译服务失败或超时后，`translateLines` 抛异常；歌词页若在 `await` 处未独立兜住，整段歌词加载/切换流程随之中断，用户看不到**原歌词**（本应始终可用），且等待最多 60 秒后才出现无提示的空白；即使上层 catch 住，也没有「翻译暂时不可用，已显示原文」的可观测提示，用户反复点击翻译无反馈。
- 证据等级：静态推演（无 try/catch 与超时常量为实锤；歌词页是否保留原文为未实测，需 B5 视角核对）

### translate_api.dart:48-57 「畸形响应退回原文」全部静默，返回值与真译文不可区分
- 级别：P2
- 违反：QUALITY_STANDARD 第 9 条（静默降级必须留痕）、第 16 条（空集合与缺失必须语义分离）
- 依据：`if (choices is! List || choices.isEmpty) return lines;`、`if (content == null || content.trim().isEmpty) return lines;`、`(i) => i < translated.length ? translated[i].trim() : lines[i]`，三处降级均直接返回 `lines`（原文），无日志、无失败标记、无异常；调用方拿到 `List<String>` 后无法判断这是译文还是原文。
- 影响：模型限流或上游形态变更时，用户点「翻译」后界面毫无变化（歌词仍是原文），没有 Toast、没有状态变化、无法区分「还没翻译完」与「翻译失败」，会反复点击并触发第二次请求；线上也无法统计翻译失败率。
- 证据等级：实锤（返回值路径）；UI 是否展示状态为未实测（静态推演）

### translate_api.dart:55-56 `(first is Map ? first['message'] : null)?['content'] as String?` 仍存在两处未校验的动态取键/强转
- 级别：P2
- 违反：QUALITY_STANDARD 第 13 条（外部数据禁止裸类型强转）、第 14 条（所有数据边界必须校验）
- 依据：注释（50-53 行）自述「显式验证类型，畸形即退回原文（第 13 条）」，但 `first['message']` 的结果未做 `is Map` 校验就被 `?['content']` 动态取下标（当 `message` 是 String/List 时抛 `NoSuchMethodError`），且 `as String?` 对 int/bool 型 content 直接抛 `CastError`。这两类异常发生在「已成功返回响应」之后，不会被前述「畸形即退回原文」分支拦住。
- 影响：上游把 `message` 或 `content` 改成非预期类型时，翻译流程抛运行期异常；若上层未捕获，用户看到歌词区空白或页面报错，原歌词也一并丢失（与注释承诺的「退回原文」相反）。
- 证据等级：实锤（表达式形态）；上层捕获行为未实测（静态推演）

### translate_api.dart:29 目标语言以中文提示词硬编码传入，与 AppConfig 的 10 种语言/i18n 链路无绑定
- 级别：P2
- 违反：QUALITY_STANDARD 第 3 条（契约先行：targetLanguage 取值范围未定义）、第 30 条（命名即文档）
- 依据：`final prompt = '请将以下文本翻译为$targetLanguage，直接输出翻译结果，不要进行任何解释。保持行数和换行不变。\n\n$joined';`；`targetLanguage` 是自由 String，文件内无枚举/常量约束、无与 `AppConfig.supportedLocales` / `AppConfig.localeNames` 的映射、无 l10n 键；提示词本身固定中文，模型输出语言取决于传入字符串。
- 影响：若设置页/歌词页传入 locale 代码（如 `'zh_CN'`、`'en'`）或本地化后的显示名（如 `'简体中文'`/`'English'`），模型可能输出中文解释、保留代码原文或拒绝翻译；非中文界面用户选择「译文语言」后看到中文提示语式译文或仍然原文，翻译结果行数不齐导致逐行歌词错位。
- 证据等级：静态推演（自由 String 与配置表无关联为实锤；消费方实参形态未实测）

### translate_api.dart:58-63 按 `split('\n')` 与原文按行对齐，无行数校验，且 `trim()` 抹掉译文首尾空白
- 级别：P2
- 违反：QUALITY_STANDARD 第 14 条（所有数据边界必须校验）、第 17 条（数值与标识符精度/索引不容协商）
- 依据：`final translated = content.split('\n'); return List.generate(lines.length, (i) => i < translated.length ? translated[i].trim() : lines[i]);`；模型多输出解释行/空行时不做截断或错位检测，仅按位置取前 `lines.length` 行；不足时逐行补原文，形成「前半译文 + 后半原文」混合列表；每行 `trim()` 去掉缩进。注释只写「对齐行数，不足补原文」。
- 影响：用户看到逐字歌词一部分是译文、一部分是原文，或与时间戳错行（翻译行对应到错误的歌词行），长歌词（分批，见 `AppConfig.lyricTranslateMaxLinesPerBatch = 40`）在批次边界处混杂；属翻译结果的可见内容错乱且无提示。
- 证据等级：实锤（对齐逻辑）；模型实际输出形态未实测

### translate_api.dart:66-74 `translateText` 用 `lines.first`，与 `translateLines` 的 `lines.isEmpty` 契约不一致
- 级别：P3
- 违反：QUALITY_STANDARD 第 3 条（契约先行：输入取值范围/失败返回语义）、第 12 条（禁止无依据的非空断言）
- 依据：`translateLines` 首行 `if (lines.isEmpty) return [];` 允许空输入返回空列表；`translateText({required String text, ...})` 以 `lines: [text]` 调用后直接 `return lines.first;`。当 `text` 为空串时上游仍发一次完整请求（第 26 行判空只看列表长度，列表非空），返回译文空串或抛异常；`first` 无前置长度校验。
- 影响：i18n 脚本或界面翻译空文本时产生一次无意义网络请求，等待最长 60 秒；若上游返回 `choices: []` 则退回原文空串，若返回异常形态则可能抛 `StateError`，脚本批量翻译在空键处中断。
- 证据等级：静态推演（`first` 与 `[]` 分支差异为实锤；调用方实参未实测）

### translate_api.dart:8-9 20s/60s 超时常量与歌词 UI 无取消/世代机制，切歌后旧译文可能回填
- 级别：P2
- 违反：QUALITY_STANDARD 第 18 条（异步结果必须校验世代）、第 20 条（生命周期必须双向对称）
- 依据：`TranslateApi()` 自建 Dio 且无 `CancelToken` 参数入口；`translateLines({required List<String> lines, required String targetLanguage})` 签名无 cancel/世代字段；`receiveTimeout: const Duration(seconds: 60)`。类内无 `close()`/`dispose()`，无请求取消。
- 影响：用户在翻译进行中切歌或切换语言，最长 60 秒后旧请求仍返回并把上一首歌的译文交给当前歌词组件（若上层未校验世代），表现为当前歌曲显示上一首歌的译文；同时切歌后仍占用连接与电量，用户可感知卡顿/流量消耗。
- 证据等级：静态推演（无 cancel/世代参数为实锤；上层世代校验未实测，需 B5 视角核对）

---

## 8. 跨模块契约核对（domain 上移后消费方，仅核对 import 路径有效性，不读业务源码）

- 核对方式：仅用 grep 统计/校验 `import`/`export` 路径有效性（通用规范允许的用途），未读范围外业务源码正文。
- 消费方清单（引用 `core/domain/{song,quality,response_policy}.dart` 或 `core/foundation/errors.dart` 的文件共 12+）：
  `lib/core/audio/preferred_quality.dart`(quality+song)、`lib/core/direct/kg_direct_api_client.dart`(response_policy)、`lib/core/direct/kg_endpoints_playlist.dart` / `kg_endpoints_search.dart`(经 api 层 show ApiException)、`lib/core/prefetch/prefetch_engine.dart`(song)、`lib/core/net/music_api.dart`(foundation/errors + response_policy)、`lib/core/utils/friendly_error.dart` / `lib/core/widgets/error_retry.dart`(经 api 层)、`lib/features/player/data/{player_repository,audio_handler}.dart`、`lib/features/player/{player_provider,play_helper}.dart`、`lib/features/player/presentation/{full_player_page,queue_sheet}.dart`、`lib/features/{album,artist,home,library,playlist,rank,search,settings}/presentation/*`、`lib/features/lyric/data/lyric_repository.dart`(translate_api)。
- 结论：全部引用路径指向当前磁盘存在的新位置（`core/domain/*`、`core/foundation/errors.dart`），未发现指向旧 `features/player/domain/...` 或 `core/api/errors.dart` 的悬空 import；`lib/main.dart:25` 亦为 `core/domain/song.dart show Song`。**此项作为复核通过项记入末尾**，不列为问题。
- 但发现一条契约形态风险：全仓 `ApiException` 的 6 个消费方中有 4 个（`kg_endpoints_playlist.dart`、`kg_endpoints_search.dart`、`friendly_error.dart`、`error_retry.dart`）不是从 `core/foundation/errors.dart` 直接取，而是依赖 `kugou_api_client.dart:4` 的 `export`；见第 6 节对应条目（P3，重构回归风险）。

---

## 9. 逐文件 `dart analyze` 结果（收尾，7/7 全跑）

环境：`export PATH=$PATH:/opt/dart/bin && dart analyze <file>`（Dart SDK 3.13.7 stable）；项目根目录无 `.dart_tool/package_config.json`（未执行且禁止执行 `dart pub get`），故 Flutter / dio / cookie_jar / dio_cookie_manager 三方符号缺失属预期噪音。按通用规范过滤噪音后，**项目自有类 0 错误**，7 文件全部通过。工作目录 `/var/minis/workspace/TiernanMusic`。

```
===== dart analyze lib/core/foundation/errors.dart =====
Analyzing errors.dart...
No issues found!
[exit=0]
→ 0 issues；项目自有类 0 错误：通过

===== dart analyze lib/core/domain/quality.dart =====
Analyzing quality.dart...
  error - quality.dart:1:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. - uri_does_not_exist
1 issue found.  [exit=3]
→ 唯一 issue 为 Flutter SDK 缺失噪音（印证第 2 节「未使用的 Flutter import」条目）；过滤后 0 issues；项目自有类 0 错误：通过

===== dart analyze lib/core/domain/song.dart =====
Analyzing song.dart...
No issues found!
[exit=0]
→ 0 issues；项目自有类 0 错误：通过

===== dart analyze lib/core/domain/response_policy.dart =====
Analyzing response_policy.dart...
No issues found!
[exit=0]
→ 0 issues；项目自有类 0 错误：通过

===== dart analyze lib/core/config/app_config.dart =====
Analyzing app_config.dart...
No issues found!
[exit=0]
→ 0 issues；项目自有类 0 错误：通过

===== dart analyze lib/core/api/kugou_api_client.dart =====
Analyzing kugou_api_client.dart...
  error - :2:8 'package:dio/dio.dart' 不存在 - uri_does_not_exist
  error - :5:8 'package:dio_cookie_manager/dio_cookie_manager.dart' 不存在 - uri_does_not_exist
  error - :6:8 'package:cookie_jar/cookie_jar.dart' 不存在 - uri_does_not_exist
  error - :7:8 'package:flutter/foundation.dart' 不存在 - uri_does_not_exist
  error - :22:16 'Dio' 未定义 / :22:20 'BaseOptions' 未定义 / :28:27 'CookieManager' 未定义
  error - :29:27 'InterceptorsWrapper' 未定义 / :76:28 'DioException' 未定义
  error - :94:9 / :99:9 / :101:10 / :122:10 / :132:10 / :165:3 / :166:3 未定义类 Dio / CookieJar
  error - :105:16 'PersistCookieJar' 未定义 / :105:42 'FileStorage' 未定义
  error - :109:9 / :137:7 / :143:7 'debugPrint' 未定义
  error - :113:12 / :139:14 / :197:7 / :198:7 / :200:7 / :201:7 / :202:7 'CookieJar' / 'Cookie' 未定义
  error - :142:17 'PersistCookieJar' 名字未定义，不能用于 is 表达式 - type_test_with_undefined_name
  warning - :142:35 Dead code - dead_code
30 issues found.  [exit=3]
→ 29 error + 1 warning 全部由 4 个缺失三方 URI 级联产生（`Dio`/`CookieJar`/`debugPrint`/`Cookie` 等均为缺失包符号，`dead_code` 亦源于 `PersistCookieJar` 未定义使 `is!` 判定被折叠）；无一条指向项目自有类；过滤后项目自有类 0 错误：通过

===== dart analyze lib/core/api/translate_api.dart =====
Analyzing translate_api.dart...
  error - :1:8 'package:dio/dio.dart' 不存在 - uri_does_not_exist
  error - :7:16 'Dio' 未定义 / :7:20 'BaseOptions' 未定义 / :19:9 未定义类 Dio
  warning - :56:44 Dead code - dead_code
5 issues found.  [exit=3]
→ 4 error 为 dio 缺失噪音；:56:44 `Dead code` 位于表达式 `(first is Map ? first['message'] : null)?['content'] as String?` 中，因三方/动态类型信息缺失被折叠，与第 7 节「未校验的动态取键/强转」条目相邻但属静态分析噪音，不计为项目自有类错误；过滤后项目自有类 0 错误：通过
```

结论：7/7 文件均已逐文件执行 `dart analyze` 并贴出结果；过滤三方包/Flutter SDK 缺失噪音后，项目自有类 0 错误，静态语法检查通过（按通用规范，编译/分析通过不构成正确性证据）。

---

## 10. 问题清单（按级别排序）

共 **40** 条：P0 **0** / P1 **11** / P2 **21** / P3 **8**。

### P0（0 条）
无。

### P1（11 条）

| # | 位置 | 简述 | 违反第 N 条 | 证据等级 |
|---|---|---|---|---|
| 1 | `quality.dart:77-101` | `fromString` 未知值/`null` 静默回落 q128，注释自述「数据一致性红线」却无留痕 | 9、11 | 实锤（后果静态推演） |
| 2 | `song.dart:169-174` | `operator ==` 只比 hash、忽略 quality/localPath，空 hash 破坏自反性 | 5、3、17 | 实锤（消费链路静态推演） |
| 3 | `response_policy.dart:64-66` | `requiresVerification` 与 `ApiException.needsVerification` 并存，「唯一出口」不唯一 | 5、8 | 实锤（消费方用法静态推演） |
| 4 | `response_policy.dart:28,34-37` | `fail()` 把 errorCode 0 改写为 -1，原始业务码/风控码丢失 | 17、9 | 实锤（上层文案表静态推演） |
| 5 | `app_config.dart:31-45` | 语言集合两份权威源（arb 生成物 vs 硬编码表），注释自承须同步但无约束 | 5、3 | 静态推演 |
| 6 | `app_config.dart:11-16` | Cookie 存储键域仍为 kapi 域，与直连原生域不匹配，冷启动登录态无法随请求发出 | 27、5 | 静态推演 |
| 7 | `kugou_api_client.dart:132-147` | 降级内存 jar 被缓存进 `_sharedJar` 且无退出条件；路径未就绪时每次 new 独立 jar | 5、11、9 | 实锤（构造时序静态推演） |
| 8 | `kugou_api_client.dart:23` | `baseUrl` 默认 kapi 中转域，与「运行期绝不调用」注释冲突，`get/post` 用相对 path | 27、31 | 实锤（装配漏传未实测） |
| 9 | `kugou_api_client.dart:38-90` | 与 `response_policy` 各一套成功/失败/风控判定，主路径与回退路径口径分叉 | 8、5、29 | 实锤（真机返回形态未实测） |
| 10 | `kugou_api_client.dart:168-171,188-213` | userid/dfid 实例字段与共享 CookieJar 双权威，切号不同步；`deleteAll()` 清掉设备态 | 5、2、17 | 实锤（界面串号静态推演） |
| 11 | `translate_api.dart:31-42` | 翻译失败/超时（20s/60s）直接抛 DioException，「保留原歌词」降级出口缺失 | 11、9、6 | 静态推演（无 try/catch 为实锤） |

### P2（21 条）

| # | 位置 | 简述 | 违反第 N 条 | 证据等级 |
|---|---|---|---|---|
| 12 | `errors.dart:26` | 注释称「唯一常量见 response_policy」却硬编码 20028 | 5、30 | 实锤（后果静态推演） |
| 13 | `errors.dart:10-23` | `message` 裸 String，无 l10n 键/翻译出口/用户反馈钩子 | 3、9 | 静态推演（类形态实锤） |
| 14 | `quality.dart:8-24, 77-101` | `label` 显示文案与 `value` wire 名不对称，中文标签无法被 fromString 解析 | 3、30 | 实锤（持久化形态未实测） |
| 15 | `quality.dart:13,17-18,83-99` | 注释称兼容蝰蛇/魔法无前缀旧值，实现只补魔法族 | 30、3 | 实锤（旧值未实测） |
| 16 | `quality.dart:17-24,88-91` | 魔法档 wire 名前缀归属两处注释互斥，存在重复补前缀风险 | 15、3 | 静态推演 |
| 17 | `quality.dart:8-24` | 音质 label 硬编码中文、无 i18n 键，`Surnay`/`Surround` 命名不一致 | 30、3 | 实锤（多语言表现未实测） |
| 18 | `song.dart:160-161` | 缺失 quality 经 `str()` 空串静默解析为 q128，三态语义不分 | 9、16 | 实锤（界面消费未实测） |
| 19 | `song.dart:76-82,90-104` | 外部字段 `'$v'` 字符串化，未逐分支校验类型 | 13、14 | 实锤（上游形态静态推演） |
| 20 | `song.dart:125-148` | 时长解析失败静默 `Duration.zero`，秒/毫秒键以隐式优先级混用 | 9、15 | 实锤（上游形态未实测） |
| 21 | `response_policy.dart:31-32,50-53` | 错误文案取服务端原文、中文兜底硬编码，无 i18n；`info` 被当错误 | 3、9 | 实锤（Toast 链路未实测） |
| 22 | `response_policy.dart:36` | `body['ssaCode'] as String?` 对网络字段裸强转 | 13、14 | 实锤（兜住与否未实测） |
| 23 | `response_policy.dart:43-49` | `status == 200` 无条件判成功；`status` 不兼容字符串形态 | 29、3 | 静态推演 |
| 24 | `app_config.dart:17-19` | 第三方翻译端点/`proxyBase` 无来源、契约与清理计划注释；`platform` 空串 | 27、32 | 静态推演 |
| 25 | `kugou_api_client.dart:71-84` | ssaCode 提取口径与 response_policy 不一致，验证码事件 id 可能丢失 | 3、8 | 静态推演 |
| 26 | `kugou_api_client.dart:76-85` | `DioException(error: ApiException)` 未设 message，Toast 易显示英文技术串 | 8、3 | 静态推演 |
| 27 | `kugou_api_client.dart:173-185` | `res.data ?? {}` 把空体变「成功但无数据」，与 response_policy 空体判失败相反 | 9、16 | 实锤（空态渲染静态推演） |
| 28 | `translate_api.dart:48-57` | 畸形响应退回原文全部静默，返回值与真译文不可区分 | 9、16 | 实锤（UI 状态未实测） |
| 29 | `translate_api.dart:55-56` | `first['message']?['content'] as String?` 仍有未校验动态取键/强转 | 13、14 | 实锤（上层捕获未实测） |
| 30 | `translate_api.dart:29` | `targetLanguage` 自由 String + 固定中文提示词，与 10 语言配置/l10n 无绑定 | 3、30 | 静态推演 |
| 31 | `translate_api.dart:58-63` | `split('\n')` 按位置对齐无行数校验，形成译文/原文混杂与错行 | 14、17 | 实锤（模型输出未实测） |
| 32 | `translate_api.dart:8-9` | 20s/60s 超时无 CancelToken/世代/关闭，切歌后旧译文可能回填 | 18、20 | 静态推演 |

### P3（8 条）

| # | 位置 | 简述 | 违反第 N 条 | 证据等级 |
|---|---|---|---|---|
| 33 | `quality.dart:1` | 未使用的 `package:flutter/foundation.dart` import，纯领域模型绑框架 | 32、4 | 实锤（复用受阻静态推演） |
| 34 | `song.dart:88-92,110-120` | 歌名前缀剥离依赖 artist 精确相等，多歌手场景不生效 | 30、14 | 实锤（上游 name 形态静态推演） |
| 35 | `song.dart:1` | 相对路径 `import 'quality.dart'`，与上移后新旧两套定位方式并存 | 4、30 | 静态推演 |
| 36 | `response_policy.dart:49-53` | 「可能被风控拦截」文案与实际触发条件（空 Map）不符，且硬编码中文 | 31、3 | 实锤（Toast 路径静态推演） |
| 37 | `app_config.dart:4-6` | 应用名三套字符串硬编码，无 i18n 键 | 30、5 | 未实测 |
| 38 | `kugou_api_client.dart:4` | `export '../foundation/errors.dart'` 让 direct/utils/widgets 经 api 层取 foundation 符号 | 4、32 | 实锤（清理后果静态推演） |
| 39 | `kugou_api_client.dart:1,10-11` | 首行空行、连续空行、export 夹在 import 中间 | 32、30 | 实锤 |
| 40 | `translate_api.dart:66-74` | `translateText` 用 `lines.first`，空文本仍发请求，与 `lines.isEmpty` 契约不齐 | 3、12 | 静态推演 |

> 说明：所有「用户可见后果」中标注「静态推演 / 未实测」的部分，均因通用规范禁止编译、跑测试、启动服务、安装依赖，且本视角不得读取范围外业务源码正文；Toast 展示链、歌词页保留原文逻辑、设置页持久化字段形态、真机三态返回样本均无法在本任务内实测。按第 29/33 条，未实测结论不得作为「实测依据」，故如实标注。

---

## 11. 复核通过项（本范围确认到位的设计，共 14 项）

1. **domain 上移后 12+ 消费方符号路径正确**：仅用 grep 核对 import 路径有效性，`core/audio/preferred_quality.dart`、`core/direct/*`、`core/net/*`、`core/prefetch/*`、`core/utils/friendly_error.dart`、`core/widgets/error_retry.dart`、`features/{player,album,artist,home,library,playlist,rank,search,settings,lyric}/**`、`main.dart` 全部指向当前磁盘存在的 `core/domain/{song,quality,response_policy}.dart` 与 `core/foundation/errors.dart`；未发现指向旧 `features/player/domain/...` 或 `core/api/errors.dart` 的悬空 import；`find` 递归核对 `foundation/**`、`domain/**`、`config/**` 下无遗漏 .dart 文件（第 4、30 条）。
2. `Song.copyWith` 用 `clearLocalPath` 独立布尔参数表达 nullable 字段清除语义，避免 `null ?? this.localPath` 的 no-op（第 3 条，显式优于隐式）。
3. `Song.fromJson` 的时长解析把 `duration/Duration/time_length`（秒）与 `timelength/timelen/info.duration`（毫秒）分组，并在 `setDuration` 用 `millis` 具名参数显式标记单位（第 15 条）。
4. `Song.fromJson` 明确以 `MixSongID` 为 `album_audio_id`，并注释排除 `Audioid/audio_id`（不同语义），避免标识符混淆（第 17 条）。
5. `AudioQuality.fallbackOrder` 明确排除蝰蛇/魔法特殊音源，另有族内 `viperOrder`，注释写明「普通音质不可降为魔法/蝰蛇」的触发与禁止条件（第 11 条）。
6. `AudioQuality.fromString` 对 `'hires'/'hi-res'/'master'/'母带'/'臻品'` 及魔法档无前缀旧值提供迁移别名，覆盖 v5.0 前设置残留（第 3 条兼容契约）。
7. `quality.dart` 对魔法族标注「匿名可用」，与 REVIEW_SPEC 三态兼容口径一致（第 29 条的状态维度记录）。
8. `KugouApiClient` 三处 CookieJar 降级均带 `debugPrint` 留痕（含「logins will NOT survive restart」明确后果），符合第 9 条「静默降级必须留痕」的日志侧要求（退出条件缺失另列 P1）。
9. `setCredentials` 对 `t1/auth/dfid` 在 null 时显式写空 cookie 清除旧值，注释标明切号防串号（第 5、21 条）。
10. `clearCredentials` 用实例自身 `_cookieJar` 清理，注释说明「清 sharedCookieJar 会清错」，避免误清（第 5 条）。
11. `_needsTimestamp` 对登录/设备/验证/歌单写/评论/导入类接口附加毫秒时间戳，注释记录 kapi 2 分钟 URL 缓存这一上游反常行为（第 31 条）。
12. `onResponse` 用 `warningCodes = {0,151,152,200,201}` 白名单而非放行全部 1-299，注释记录 error_code=1/2 为真实错误；`ssaCode` 兼容 body 两键 + 响应头两键并 `toString()`（第 14、29 条）。
13. `TranslateApi` 对 `choices` 为 null/空 List、`choices[0]` 非 Map 均做显式类型判定并退回原文，注释记录历史 RangeError/NoSuchMethodError 成因；`lines.isEmpty` 直接返回不发请求；请求头带 UA 且注释说明 WAF 412 原因（第 13、31 条）。
14. `response_policy.dart` 把 mcomment 的 `err_code` 优先于 `status`、`codeOf` 兼容字符串形态，`ApiOutcome.ok/fail` 命名构造与 `isOk` 统一语义；`ApiException` 保留 `ssaCode/verifyUrl/body` 三个可选上下文；`app_config.dart` 对 kapi 常量写明「运行期绝不调用 + 清理计划」，10 语言表含 `zh_TW` 且 `localeNames` 用各语言自称（第 29、31、3 条）。

**逐文件 `dart analyze` 结论**：7/7 文件全部执行并贴结果；过滤 Flutter/三方包缺失噪音后，项目自有类 0 错误，静态语法检查通过（详见第 9 节）。

### 附：`kugou_api_client.dart` 原始输出全文（未删减，30 issues）

```
Analyzing kugou_api_client.dart...

  error - kugou_api_client.dart:2:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - kugou_api_client.dart:5:8 - Target of URI doesn't exist: 'package:dio_cookie_manager/dio_cookie_manager.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - kugou_api_client.dart:6:8 - Target of URI doesn't exist: 'package:cookie_jar/cookie_jar.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - kugou_api_client.dart:7:8 - Target of URI doesn't exist: 'package:flutter/foundation.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - kugou_api_client.dart:22:16 - The method 'Dio' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Dio'. - undefined_method
  error - kugou_api_client.dart:22:20 - The method 'BaseOptions' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'BaseOptions'. - undefined_method
  error - kugou_api_client.dart:28:27 - The method 'CookieManager' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'CookieManager'. - undefined_method
  error - kugou_api_client.dart:29:27 - The method 'InterceptorsWrapper' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'InterceptorsWrapper'. - undefined_method
  error - kugou_api_client.dart:76:28 - The method 'DioException' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'DioException'. - undefined_method
  error - kugou_api_client.dart:94:9 - Undefined class 'Dio'. Try changing the name to the name of an existing class, or creating a class with the name 'Dio'. - undefined_class
  error - kugou_api_client.dart:99:9 - Undefined class 'CookieJar'. Try changing the name to the name of an existing class, or creating a class with the name 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:101:10 - Undefined class 'CookieJar'. Try changing the name to the name of an existing class, or creating a class with the name 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:105:16 - The method 'PersistCookieJar' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'PersistCookieJar'. - undefined_method
  error - kugou_api_client.dart:105:42 - The method 'FileStorage' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'FileStorage'. - undefined_method
  error - kugou_api_client.dart:109:9 - The method 'debugPrint' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - kugou_api_client.dart:113:12 - The method 'CookieJar' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'CookieJar'. - undefined_method
  error - kugou_api_client.dart:122:10 - Undefined class 'CookieJar'. Try changing the name to the name of an existing class, or creating a class with the name 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:132:10 - Undefined class 'CookieJar'. Try changing the name to the name of an existing class, or creating a class with the name 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:137:7 - The method 'debugPrint' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - kugou_api_client.dart:139:14 - The method 'CookieJar' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'CookieJar'. - undefined_method
  error - kugou_api_client.dart:142:17 - The name 'PersistCookieJar' isn't defined, so it can't be used in an 'is' expression. Try changing the name to the name of an existing type, or creating a type with the name 'PersistCookieJar'. - type_test_with_undefined_name
  error - kugou_api_client.dart:143:7 - The method 'debugPrint' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'debugPrint'. - undefined_method
  error - kugou_api_client.dart:165:3 - Undefined class 'Dio'. Try changing the name to the name of an existing class, or creating a class with the name 'Dio'. - undefined_class
  error - kugou_api_client.dart:166:3 - Undefined class 'CookieJar'. Try changing the name to the name of an existing class, or creating a class with the name 'CookieJar'. - undefined_class
  error - kugou_api_client.dart:197:7 - The method 'Cookie' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Cookie'. - undefined_method
  error - kugou_api_client.dart:198:7 - The method 'Cookie' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Cookie'. - undefined_method
  error - kugou_api_client.dart:200:7 - The method 'Cookie' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Cookie'. - undefined_method
  error - kugou_api_client.dart:201:7 - The method 'Cookie' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Cookie'. - undefined_method
  error - kugou_api_client.dart:202:7 - The method 'Cookie' isn't defined for the type 'KugouApiClient'. Try correcting the name to the name of an existing method, or defining a method named 'Cookie'. - undefined_method
warning - kugou_api_client.dart:142:35 - Dead code. Try removing the code, or fixing the code before it so that it can be reached. - dead_code

30 issues found.
```

### 附：`translate_api.dart` 原始输出全文（未删减，5 issues）

```
Analyzing translate_api.dart...

  error - translate_api.dart:1:8 - Target of URI doesn't exist: 'package:dio/dio.dart'. Try creating the file referenced by the URI, or try using a URI for a file that does exist. - uri_does_not_exist
  error - translate_api.dart:7:16 - The method 'Dio' isn't defined for the type 'TranslateApi'. Try correcting the name to the name of an existing method, or defining a method named 'Dio'. - undefined_method
  error - translate_api.dart:7:20 - The method 'BaseOptions' isn't defined for the type 'TranslateApi'. Try correcting the name to the name of an existing method, or defining a method named 'BaseOptions'. - undefined_method
  error - translate_api.dart:19:9 - Undefined class 'Dio'. Try changing the name to the name of an existing class, or creating a class with the name 'Dio'. - undefined_class
warning - translate_api.dart:56:44 - Dead code. Try removing the code, or fixing the code before it so that it can be reached. - dead_code

5 issues found.
```

（以上两份原始输出贴于此处，第 9 节中的表格式摘要为同一批结果的噪音归类说明，两者一致。）

