# v5.1 B3 合并裁决（三视角交叉·进行中）

基线：B2 修复后主线 `d6229be`。范围：`core/cache`、`core/resource`、`core/prefetch`、`core/storage` 共 9 文件 / 1444 行。
视角报告（**A/C 已到，B 运行中**）：
- `v51_cross_b3_a.md`（缓存层级正确性，**已到**：39 条：P0×1 / P1×13 / P2×24 / P3×1，复核通过 12 项）
- `v51_cross_b3_b.md`（鲁棒与质量，运行中）
- `v51_cross_b3_c.md`（用户路径与一致性，**已到**：64 条：P0×1 / P1×22 / P2×30 / P3×11，复核通过 17 项）

## A+C 双视角共识 / 主代理已修（B 到达后升三视角）
1. **两套读实现**（A 的 P0）→ `CachedApiCall`/`RepositoryReads` 全部收敛到 `ResourceGateway.json`，键/TTL/ns/POST 摘要/失效单一事实源；L1 内存层真正参与；in-flight 按 fullKey 分键；`onUserChanged` 清 L1+异步清 L2。
2. **文件缓存并发损坏**（C 的 P0）→ `cacheUrlFile` 加 `_fileInFlight` 合并（同 `(url,bytes)` 只一个下载），`.part` 不再被两路写；HEAD 405/超时降级为「靠下载后长度校验」不再整体失效；`putFile/file/filePath`（零消费、身份 `(url,0)`）删除，统一 `fileIdentity(url,bytes)`。
3. **试听片段可入库**（C 的 P0 部分误报）→ 调用方 `audio_handler` 已有 `!_lastIsPreview && bytes>0` 三条件闸门，但缓存层无强制点；已加 `allowPreview` 默认 false + URL 形态判定，防御落到最内层。
4. **`__stale` 无消费方**（A P1-8 / C 用户路径）→ `ResourceGateway.json` 已识别 `__stale` 不进 L1；`lyric_repository` 的降级副本消费在 B5 范围复核。
5. **歌词 30min 非 168h**（C）→ 已纠正为 168h（用户 v4.0 口径）。
6. **预热键与实播键不命中**（A P1-13 / C）→ 两套实现统一后 `PrefetchEngine` 仍用 ns=`prefetch`，与业务 ns 不同；**待 B 视角结论**：预热应改投业务 ns 还是保留独立 ns 由 `ResourceGateway` 统一映射（不重复发请求即可）。

## A 视角 P1 待 B/C 交叉后裁决（摘要）

## A 视角 P0 主代理裁决与修复（已执行）
**P0：CachedApiCall 与 RepositoryReads 两套并行读实现，键/TTL/ns/失效全不一致。**
- 裁决：方向成立，但「写后失效只清一侧」需修正——`invalidateNs` 用 `contains(':$ns:u=')` 匹配，M3 已给 7 域 CachedApiCall 传业务 ns，实际能清。**真正成立的**：预加载 ns=`prefetch` 与播放侧键不同 → 预热结果永不命中；POST body 摘要两套算法；TTL 两套数值口径；L1 内存层声明三级实为两级；in-flight 以裸 key 分键（不同 TTL 复用）。
- 修复（**不向复杂度妥协，彻底统一**）：
  1. `CachedApiCall` 重写为 `ResourceGateway.json` 薄包装；`RepositoryReads` 共用同一门面与 `CachedApiCall.bodyIdentity`
  2. 键由 `cache_keys.cacheKey` 唯一生成、TTL 由 `cacheTtl(scope)` 唯一决定、Post 身份摘要统一
  3. `ResourceGateway.json` 接入 L1 内存层（`__stale` 降级副本不进 L1）
  4. `onUserChanged()` 清 L1 + 异步清 L2 旧账号维度，避免箱体膨胀
  5. `ResourceCache.json` 的 in-flight 读写统一用 `fullKey`（含 scope 前缀），不同 TTL 不再互相复用
- 全库 analyze 0 真错、相对 import 0 无效、CI 架构断言双 PASS。

## A 视角 P1 待 B/C 交叉后裁决（摘要）
1. `MemoryCache.keyOf` 第二套键工厂（旧兼容层，消费方已迁 Gateway）→ 待核实残留调用面再定删/留
2. `secure_storage.clearCredentials` 未联动缓存失效 → 注意 B-11/F-2 终审「dfid 属设备不属账号，登出保留」，仅切号需联动
3. `storage_permission.resolveRoot` 三条根分支，权限态变化使永久文件层失联 → **真 P1 候选**（授权前后路径切换，旧永久缓存不可见）
4. `prefetch_engine` 预热 ns=`prefetch` 与业务 ns 不同键 → 已由上述统一部分缓解；预热是否应改投业务 ns 待 C 视角结论
5. `putFile/file/filePath` 固定 `(key,0)` 身份与 `cacheUrlFile` 不兼容 → 待 B 视角核实是否有消费方
6. `__stale` 标记无消费方 → B1 已让 `ResourceGateway` 识别 `__stale`（不进 L1），其余消费方待 C 视角

## 误报 / 降级候选（待 B/C 复核）
- 「`resource_cache.dart` 的 `json:`/`list:` 前缀与键内 scope 重复」→ 设计性冗余（前缀用于 `clearJson/clearLists` 按层级批量清），非缺陷。
- 「`cacheTtl(file)=36500 天」→ 文件层永不淘汰由 `cacheUrlFile` 的「已存在直接返回」保证，TTL 常量只是占位，非缺陷。

## 交叉共识待补
B/C 到达后填：三视角共识 / 双视角 / 单视角、矛盾项裁决、误报清单、P0/P1 最终修复集。
