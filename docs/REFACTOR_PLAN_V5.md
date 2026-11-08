# TiernanMusic v5.0 完全重构规划书

> 版本基线：v4.0.2+45（tag 6526566，main）。目标：v5.0.0+50。
> 原则：行为保持（v4.0.2 的全部修复语义不丢），结构重写。33 条 QUALITY_STANDARD 继续有效，本文件是**结构与架构**层面的补充契约。

---

## 一、为什么要重构（现状病灶，全部有据）

### 1.1 分层越界（core ↔ features 双向依赖，8 处实锤）
| 越界文件 | 依赖了 features 的什么 | 正确归属 |
|---|---|---|
| core/providers.dart | lyric_repository | core 只该有抽象，具体在 features |
| core/utils/permission_gate.dart、error_logger.dart、resource_cache.dart | download 的 StoragePermissionService | 下沉为 core/storage 权限服务 |
| core/direct/kg_client.dart | auth 的 edt_generator | 下沉为 core/direct 自身模块 |
| core/audio/preferred_quality.dart | player 的 models | 音质枚举下沉 core/domain |
| core/prefetch/prefetch_engine.dart | player 的 models.Song | 预加载吃领域模型 Song；Song 应上移 core/domain |
| core/router/app_router.dart | 14 个页面（可接受但需显式分层） | router 属 app 层，不属 core |

### 1.2 缓存系统四套并存、职责重叠、键规则各异
- `MemoryCache`（90s 内存，键=path+query，**无用户维度**）
- `ResourceCache`（Hive resource_json，168h/90s，键=path+query+|userid）
- `LyricTranslationCache` / `LyricPersistentCache`（Hive，键=id:lang@model）
- `AppImageCache`（sqflite，600 条/30 天，无字节上限）
四处 TTL 硬编码散落（20s/30s/60s/90s/30min/168h），无统一策略表；写操作后失效靠各 repository 手工调用 `MemoryCache.removeWhere` 字符串前缀匹配——**漏一处就是脏数据**。

### 1.3 预加载是补丁不是模块
PrefetchEngine 引擎有了，但触发点散在 main（首页预热）、audio_handler（队列 upcoming）两处手工接线；收藏歌单未纳入；无统一「预取策略」声明。

### 1.4 API 调用未聚合
13 个 repository 各自直接调 `KugouApiClient.get/post` + 各自拼参数 + 各自判 `_wrap`；缓存/脱敏/日志/重试在部分链路有、部分链路无——同一首歌的歌词、播放 URL、详情走三种代码路径。

### 1.5 启动编排耦合
main.dart 348 行：初始化顺序、splash、权限、预热、登录监听、router 全在一个 WidgetState 里。

---

## 二、目标架构（五层 + 两桥）

```
┌─────────────────────────────────────────────────┐
│  L5  app/          main.dart, router, shell     │  只做装配与导航
├─────────────────────────────────────────────────┤
│  L4  features/     presentation + data          │  页面 UI 与各自仓库
│                    （data 只准依赖 L3 门面）      │
├─────────────────────────────────────────────────┤
│  ══ Bridge-S ══ StorageBridge（存储桥）          ║  §四
├─────────────────────────────────────────────────┤
│  L3  core/domain  纯 Dart 领域模型与服务接口      │  Song/Quality/Paging/Credential
│      core/policy  缓存策略表/预取策略/权限策略     │  （纯声明，无 IO）
├─────────────────────────────────────────────────┤
│  ══ Bridge-N ══ NetworkBridge（网络桥）          ║  §五
├─────────────────────────────────────────────────┤
│  L2  core/net     dio 客户端/签名/端点表/直连     │  现有 direct 层收敛于此
│      core/storage 权限/安全存储/Hive 开箱         │
│      core/cache   三级缓存引擎（唯一实现）        │
│      core/media   音频引擎/MV 播放/图片缓存       │
├─────────────────────────────────────────────────┤
│  L1  core/foundation  日志/错误/常量/工具         │  零依赖（只依赖 Flutter SDK）
└─────────────────────────────────────────────────┘
```

**依赖铁律（编译期可检查）**：
- L1 不依赖任何层
- L2 只依赖 L1
- L3 只依赖 L1（**禁止 IO**：无 dio/File/Hive import）
- Bridge 只被 L3 接口引用实现、被 L4 调用；Bridge 实现允许依赖 L2
- L4 只依赖 L3（接口）与 Bridge 门面；**禁止 L4→L2 直连**（现 13 个 repository 全部改为经 Bridge-N 的模块化 API）
- L5 只依赖 L4 与各层门面
- **core/ 内禁止出现 `import features/`**（CI grep 断言，违者构建失败）

---

## 三、目标目录结构

```
lib/
  main.dart
  app/                        # L5
    router.dart
    shell.dart
    bootstrap.dart            # 启动编排（从 main.dart 拆出）
  core/
    foundation/               # L1：logger, errors, constants, result.dart
    domain/                   # L3 模型：song.dart, quality.dart, paging.dart,
                              #        credential.dart, mv_models.dart, lyric_models.dart
    policy/                   # L3 策略表：cache_policy.dart（唯一 TTL 表）,
                              #        prefetch_policy.dart, permission_policy.dart
    interfaces/               # L3 接口：i_music_api.dart, i_storage.dart, ...
    net/                      # L2：dio_client.dart, signer.dart, endpoints/,
                              #      kg_client.dart, kg_play_api.dart
    storage/                  # L2：secure_store.dart, hive_boxes.dart,
                              #      storage_permission.dart（自 features 下沉）
    cache/                    # L2 三级引擎：memory_level.dart, disk_level.dart,
                              #      resource_cache.dart, cache_keys.dart
    media/                    # L2：audio_engine.dart(现 audio_handler 拆分),
                              #      mv_player.dart, image_cache.dart
    prefetch/                 # L2：prefetch_engine.dart（依赖 domain+cache）
    widgets/                  # 通用 UI 组件（SongTile/ErrorRetry/...）
    theme/
    l10n 桥（gen 生成物原位）
  features/                   # L4，域不变（13 域）
    <domain>/
      data/<domain>_repository.dart   # 只调 IMusicApi 门面
      presentation/...
  bridges/                    # 两桥的实现注册（薄）
    network_bridge.dart
    storage_bridge.dart
```

---

## 四、存储桥（Bridge-S）与缓存层级

### 4.1 三级缓存统一引擎（唯一实现，删四套旧类）
```
Level-0  MemoryLevel     进程内 LRU（条数+字节双上限），TTL 由策略表注入
Level-1  DiskJsonLevel   Hive resource_json（168h JSON / 90s 列表，键规则统一）
Level-2  DiskFileLevel   永久文件（audio/mv/krc/cover），按 (url,bytes) 身份
```
**唯一入口** `ResourceGateway`（L2 实现 L3 的 `IResourceStore`）：
```dart
// L3 声明（policy + interfaces）
class CachePolicy { final Duration jsonTtl, listTtl; final bool filePermanent; ... }
abstract class IResourceStore {
  Future<Map<String,dynamic>> json(String key, Future<Map<String,dynamic>> Function() fetch, {CachePolicy policy});
  Future<List<T>> list<T>(String key, Future<List<T>> Function() fetch);
  Future<String?> cacheFile(String url, String kind, {required int declaredBytes});
  void invalidateNamespace(String ns);          // 写后失效：按命名空间，不再前缀猜
  void invalidateUser(String userid);           // 登出/切号：一键清用户维度
}
```
**键规则（唯一事实源 cache_keys.dart）**：
```
json:<ns>:<u=userid>:<path>:<sorted(query)>:v<schemaVer>
list:<ns>:<u=userid>:<path>:<sorted(query)>
file:<kind>:<fnv1a(url)|bytes>
lyric:<lyricId>:<lang|kind>:m<modelHash>
```
- `ns` = 调用域（home/playlist/player/...），写后失效按 ns 精确清除，**删除字符串前缀猜谜**
- `schemaVer`：响应结构变更时 +1，旧版本键自动过期
- userid 缺失（匿名）用 `u=0`；登录/切号 `invalidateUser` 全清

### 4.2 层级质量要求
| 要求 | 判定 |
|---|---|
| L0 命中 | 同步返回（<1ms），不触 L1 |
| L1 命中未过期 | 异步返回，不发网络；命中计数进日志（verbose） |
| L1 过期但有值 | 返回旧值 + 后台静默刷新（stale-while-revalidate，替换 v4.0 的 `__stale` 假降级） |
| 全部未命中 | 走 Bridge-N；**写操作成功后按 ns 失效**由 Bridge-N 自动完成（repository 不再手工失效） |
| 文件缓存 | 只在 `(url, declaredBytes>0)` 且下载字节数==声明时入库；HEAD 预检；复用前长度复核（v4.0.2 规则原样保留） |
| 容量 | L0 双上限（条数/字节）；L2 永久但设置页可见体积+一键清（保留用户语义：清 JSON 列表不清文件） |
| 失效可观测 | 每次降级/过期/失效都有 verbose 日志（v4.0.2 R3 落实到新引擎） |

---

## 五、网络桥（Bridge-N）

### 5.1 现状 → 目标
现在：13 repository → `KugouApiClient.get/post`（裸）→ direct 分派 → 手工 `_wrap`。
目标：**每个业务域一个模块化 API 类**（聚合该域全部端点 + 参数构造 + 响应解包 + 缓存声明 + 错误翻译），repository 只做「领域编排」：

```
bridges/network_bridge.dart
  class NetworkBridge {
    IMusicApi get music;      // 聚合门面
  }
  class MusicApi implements IMusicApi {          // L2 实现 L3 接口
    // —— 每个方法 = 一个端点 + 缓存声明 + 解包 ——
    Future<Page<Song>> playlistTracks({required String gid, int page, int pageSize});
    Future<MvDetail> mvDetail(String videoId);
    Future<PlayDecision> playUrl({required String hash, ..., Quality q});
    Future<LyricBundle> lyric(String hash);
    ...
  }
```
- `PlayDecision` 取代裸 `PlayableResult`：内含 url/quality/isPreview/**declaredBytes**/segment（v4.0.2 语义保留）
- 缓存声明在方法内（`@cached(list: 90s)` 语义，实际由 Bridge-N 调 ResourceGateway），repository 无感知
- 写操作（评论/歌单写/MV 收藏）统一走 `write:` 通道：不缓存、失败分类 maybeSucceeded、成功自动 `invalidateNamespace`
- 20028 验证：Bridge-N 统一识别并抛 `NeedsVerification`，上层（verification_listener）唯一处理——删除三处分散判定

### 5.2 网络层质量要求
| 要求 | 判定 |
|---|---|
| 端点表唯一 | `endpoints/` 内声明式表（path/host/x-router/签名类型/默认参数），direct 分派表消失 |
| 签名唯一 | signer.dart 三签名+signKey+lite 变体，带单测样例（黄金值） |
| 错误翻译唯一 | 所有非 2xx/业务错 → `ApiException(code, kind)`，kind ∈ {auth, verify, paid, noCopyright, server, network}；**全仓只允许这一处判 20028** |
| 日志/脱敏 | dio 拦截器统一（4KB 截断+脱敏），verbose 开关下逐请求落盘（现状保留） |
| 直连优先 | 语义不变：原生网关优先，kapi 仅作未移植路径兜底且带 `stale` 警示日志 |

---

## 六、存储桥（Bridge-S）

- `StoragePermissionService` 从 features/download 下沉 `core/storage/`（resolveRoot/实测写探针/降级语义原样保留）
- `SecureStorage`（凭证五键+多账号）原样，接口化 `ICredentialStore` 供 auth 用
- Hive 开箱表集中 `hive_boxes.dart`（main 的 openSafe 列表消失）
- 路径解析唯一：`resolveRoot()` + 子目录常量（audio/mv/logs/cover/lyrics/cache）——core 内任何写盘都经它

---

## 七、预加载策略（policy 声明 + 引擎实现分离）

```
prefetch_policy.dart（L3 声明）
  启动预热：首页所有类型歌曲 + 收藏歌单，spacing=100ms，只 JSON 不文件
  队列预取：未来 15 首（含当前），去重按 hash，shuffle 按当前序
  触发点：main 首帧（首页数据落定）、_emitQueue（队列变化）、登录态变化
  上限：单批 60；失败留痕； disposed 全停
prefetch_engine.dart（L2 实现）
  依赖：IResourceStore + IMusicApi + domain.Song
  不再 import features/player（吃 domain.Song）
```

---

## 八、迁移计划（七步，每步可独立发布）

| 步 | 内容 | 风险 | 验证 |
|---|---|---|---|
| M1 | 建 `core/foundation`、`core/domain`（Song 等模型上移，全仓改 import） | 低（纯移动） | analyze 零真错 |
| M2 | `core/storage` 下沉（权限/安全存储/Hive 表）+ Bridge-S 接口；features/download 改引新路径 | 中 | 下载真机回归 |
| M3 | `core/cache` 三级引擎替换四套旧类；`cache_keys.dart` 统一键；repository 改 `ResourceGateway`；写后 ns 失效 | **高** | 三歌单分页留样回归（/tmp/three_playlists.json、like_5x10、v4_paging_8） |
| M4 | `core/net` 收敛 direct + 端点表 + 错误翻译唯一；MusicApi 聚合（先 4 域：player/lyric/playlist/mv） | **高** | 播放/歌词/歌单/MV 全链真机 |
| M5 | 其余 9 域 repository 迁 MusicApi；删 direct 分派表与四套旧缓存类 | 中 | 全功能回归 |
| M6 | app/ 层拆 main.dart（bootstrap/shell/router），预加载策略声明化 | 低 | 冷启动/登录/切号 |
| M7 | CI 断言：`rg "import.*features/" lib/core → 必须空`；删除死代码；文档同步 | 低 | CI 绿 |

**节奏**：M1-M2 一批（v4.1），M3-M4 一批（v4.2，核心风险），M5-M6 一批（v4.3），M7+清债 → **v5.0.0 LTS**。每批完成即发布，不憋大版本。

---

## 九、质量门槛（每批发布前必须全绿）

1. `dart analyze lib/` 项目自有类错误 = 0（Flutter/三方符号噪音除外，逐文件贴结果）
2. 括号平衡脚本通过
3. 依赖铁律断言：core 无 features import
4. 三歌单分页留样回归（拼接顺序=反反）
5. 播放链五层验证（URL→魔数→frame→解码→PCM MD5 抽查）
6. 真机清单：播放/歌词/下载/MV/评论/登录/切号/清缓存
7. **打 tag 前 pubspec 版本必须与 tag 同名**（v3.7.0 六轮教训）
8. 代理产出必须逐文件 analyze 贴报告；Icons.* 必须验证存在（v3.9.10 教训）

---

## 十、明确不做（本重构范围外）
- 换状态管理框架（Riverpod 保留）
- 换 Hive（保留，仅收敛开箱与键规则）
- UI 视觉重设计（表现层仅随重写顺带修缺陷）
- 20028 三套验证收敛（独立专项，架构预留 NeedsVerification 单点）
- keystore 轮换（用户手动操作）
