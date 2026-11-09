# v5.2 需求单（2026-11-08 用户定调）

## A. 权限网关深化多重检测 + 多回退（延续 v3.9.10 用户反馈）

现状：`storage_permission.dart` 已有授权态查询 + 写探针 + 降级链。
用户要求「多重检测 + 多回退」，升级为**四重检测矩阵 + 五级回退链**：

### 检测矩阵（每次 resolveRoot 全跑，任何一环失败即降级并留痕）
1. `Permission.manageExternalStorage.isGranted`（permission_handler）
2. 原生通道 `canWrite('/storage/emulated/0')`（新增 Kotlin `canWrite` 方法，用 java.io.File.canWrite()，排除 permission_handler ROM 怪癖）
3. 目录实际写探针（写→读回→删，现有 `_probeWritable`）
4. `Environment.isExternalStorageManager()` 原生复验（API 30+，反射调用，防 permission_handler 框架偏差）

### 回退链（五级，顺序不可变，逐级留痕原因）
L1 根目录 `/storage/emulated/0/TierNanMusic`（四重全过才用）
L2 `/storage/emulated/0/Download/TierNanMusic`（MediaStore 免权限）
L3 `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)/TierNanMusic`（原生直取，防 channel 路径差异）
L4 `context.getExternalFilesDir(null)/TierNanMusic`（App 外部私有，免权限必可写）
L5 `getApplicationSupportDirectory()`（内部私有，最后兜底）
→ 每级结果与失败原因写入 `lastProbeError` + debugPrint；设置页显示「生效级别 + 全链探测历史」。

### 附带修复
- `resolveRootMode()` 与 `resolveRoot()` 各自独立探测（两次探针）→ 改为 resolveRoot 返回 `StorageResolution{path, level, probeLog}` 单对象，mode 由 level 推导（消除双探针不一致）。
- `_apiLevelFromOsVersion`：Android 13(API 33)/14(API 34) 偏移核对（13+19=32，**应为 33**）。公式改 `name + 20`（10→30 基准）。

## B. Android 5.1 级兼容性（minSdk 22）

1. `android/app/build.gradle:41` `minSdk flutter.minSdkVersion` → `minSdk 22`
2. `multiDexEnabled true`（API 22 无 ART 原生 multidex）
3. Kotlin/AGP 兼容：AGP 8.x 支持 minSdk 21+，确认无 d8 desugaring 冲突；`coreLibraryDesugaringEnabled true` + `desugar_jdk_libs` 依赖补上（java.time 等在 API 22 需要）
4. TLS：API 22 的系统证书库不含 Let's Encrypt ISRG Root X1（2021 后签发）→ **自带证书**：
   - `android/app/src/main/res/raw/isrg_root_x1.pem` + `isrg_root_x2.pem`（下载自 letsencrypt.org/certificates）
   - Kotlin `TlsCompat`：自定义 `SSLContext` 加载 raw 证书合并系统信任库；Dio/just_audio 网络层经 `HttpsURLConnection.setDefaultSSLSocketFactory` 全局生效
   - Flutter Dart 侧 dio 已有自己的 PEM（若需）——先确认 kg 域名证书链（openssl s_client 实测）
5. `network_security_config.xml`：`<base-config cleartextTrafficPermitted="false">` + 信任锚加 raw 证书（API 22 起 network_security_config 支持自 API 24，**API 22-23 需走 Kotlin SSLContext 方案**，config 只对 24+ 生效）
6. 验证：just_audio/video_player 的原生播放器走 ExoPlayer（自带 TLS 栈受 SSLContext 影响）；krc/download 的 Dart HTTP 走 dio（SocketException 链路受 setDefaultSSLSocketFactory 影响）

## C. 字体改 Ubuntu Mono

1. 下载 Ubuntu Mono（Ubuntu Font Family，OFL 许可）：Regular/Bold（.ttf）
2. `assets/fonts/UbuntuMono-Regular.ttf` + `UbuntuMono-Bold.ttf`，pubspec fonts 注册
3. `app_theme.dart`：`fontFamily: 'Ubuntu Mono'`（全局）；中文回退链 `fontFamilyFallback: ['UbuntuMono', 'NotoSansSC']`（等宽拉丁 + 系统中文字体）
4. 歌词页保持独立字体决策（KRC 逐字渲染可继承全局）
5. 验证：Arb 11 语言的拉丁文本全部等宽渲染；CJK 由回退链处理不变形

## 验收
- minSdk 22 模拟器/真机安装可用、TLS 全域名握手成功（无 system cert 缺失报错）
- 字体全 UI 生效、CJK 不变形
- 权限网关：授权/未授权/ROM 怪癖三种状态下 resolveRoot 落到正确级别且设置页显示探测历史
