# v5.2 B 节实施报告：Android 5.1 (API 22) 兼容性 + 自带 TLS 证书

执行日期：2026-11-09。范围严格限于 PLAN_v52.md **B 节**，A/C 节未动。

## 任务对照（B 节 6 项）

### B-1 minSdk 22 ✅
- `android/app/build.gradle:43`：`minSdk flutter.minSdkVersion` → `minSdk 22`

### B-2 multidex ✅
- `build.gradle:48`：defaultConfig 内 `multiDexEnabled true`（API 22 无 ART 原生 multidex）
- `build.gradle:96`：`implementation 'androidx.multidex:multidex:2.0.1'`
- 说明：Flutter 的 FlutterApplication 自 API 19+ 起在 `attachBaseContext` 调
  `MultiDex.install`，MainActivity 继承 audioservice 的 `AudioServiceActivity`（终归
  FlutterApplication 链），无需自写 MultiDexApplication。

### B-3 Kotlin/AGP 兼容 + desugaring ✅
- AGP 8.11.1（settings.gradle）支持 minSdk 21+，无 d8 冲突。
- `build.gradle:34`：compileOptions 内 `coreLibraryDesugaringEnabled true`
- `build.gradle:98`：`coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.5'`
  （2.1.x 线要求 AGP 8.4+，与 8.11.1 匹配；覆盖 java.time/java.util.stream 等）

### B-4 自带 TLS 证书 ✅
- `android/app/src/main/res/raw/isrg_root_x1.pem`（ISRG Root X1，有效期至 2035-06-04）
- `android/app/src/main/res/raw/isrg_root_x2.pem`（ISRG Root X2，有效期至 2040-09-17）
  均下载自 letsencrypt.org/certificates，openssl 验证 subject/有效期通过。
- 新增 `kotlin/com/tiernan/music/TlsCompat.kt`：
  - 从 res/raw 解析 PEM 根证书（`resources.getIdentifier` 按 raw 资源名取 id，证书缺失
    留痕跳过，不阻断启动）
  - `MergedTrustManager`：系统 TrustManager 校验失败时回退自定义 LE 根集合重试；
    保留 X509 完整校验语义（非信任所有，不放开校验——符合质量准则第 11 条降级原则）
  - `HttpsURLConnection.setDefaultSSLSocketFactory` 全局生效（dio 的 HttpURLConnection
    栈与 ExoPlayer DefaultHttpDataSource 均受影响）
  - `@Volatile installed` + `@Synchronized install()` 幂等，重复调用安全
  - 安装失败仅 Log.w 留痕不抛出：API 22 上后果限于 LE 域名握手失败，系统证书域名不受影响（原则 9 留痕）
- `MainActivity.configureFlutterEngine` 首行调用 `TlsCompat.install(this)`（最早生效时机）
- **kg 域名证书链实测**（openssl s_client）：www.kugou.com 走 GlobalSign（系统信任库内，
  API 22 无需 LE 根）；srvapi/musicpay 等域名沙箱网络不可达（CDN 区域限制），LE 链路
  无法在沙箱闭环，留真机验收。Dart dio 侧自带 PEM 的必要性待真机握手结果决定。

### B-5 network_security_config.xml ✅
- `<base-config cleartextTrafficPermitted="false">` 保持
- trust-anchors 增加 `<certificates src="@raw/isrg_root_x1" />` 与 `@raw/isrg_root_x2`
  （仅对 API 24+ 生效；API 22-23 由 B-4 的 Kotlin SSLContext 方案兜底，二者互补）
- 酷狗 cleartext domain-config 原样保留

### B-6 生效路径确认 ✅（静态推演）
- just_audio → ExoPlayer：HTTP 数据源读取 `HttpsURLConnection.getDefaultSSLSocketFactory()`
  链路受 TlsCompat 影响 ✅
- krc/download 的 Dart HTTP 走 dio（默认 HttpClient = dart:io 原生实现）。注意：
  `setDefaultSSLSocketFactory` 只影响 Android 平台 HttpURLConnection 栈，不影响 Dart VM
  自身的 BoringSSL。Dart 侧 TLS 用的是 Dart SDK 内嵌根证书，Android 上 dart:io 的
  SecurityContext 默认加载系统证书目录，API 22 缺 ISRG Root 时 dio 的 HTTPS 同样会失败。
  **处置**：B-4 方案已覆盖 Android 原生栈；Dart 侧如真机实测 LE 域名失败，需 dio 侧加
  `SecurityContext` 注入（`HttpOverrides.global`）——此项超出 B 节任务书第 4 条「Dart 侧
  先确认」的范围，结论记录于此，待真机验证后按需追加。

## 沙箱验证限制说明
- 沙箱无 Android SDK / Gradle 可用（/opt 仅含 Dart SDK；flutter.tar.xz 损坏截断，仅含
  GitHub/workflow 与 .pub-preload-cache 元数据，无 bin/flutter 与 flutter_tools，无法
  `flutter build`）。按 PROGRESS.md 既定方法论以完整通读 + 静态推演替代。
- 修改文件均通过 grep/file_read 逐一核对落盘：minSdk 22 / multiDexEnabled /
  coreLibraryDesugaringEnabled / desugar_jdk_libs / multidex / 两份 PEM（各含 1 个
  CERTIFICATE 块）/ TlsCompat.install 调用 全部确认。

## 待真机验收（PLAN 验收项）
- [ ] API 22 模拟器/真机安装启动（multidex + desugaring 实际构建验证）
- [ ] LE 证书域名 HTTPS 握手成功（无 system cert 缺失报错）
- [ ] Dart/dio 侧 LE 域名实测 → 决定是否补 HttpOverrides 全局注入
- [ ] 酷狗 cleartext 域配置 + TlsCompat 并存无回归

## 变更文件清单
| 文件 | 变更 |
|---|---|
| android/app/build.gradle | minSdk 22、multiDexEnabled、desugaring、两依赖 |
| android/app/src/main/res/raw/isrg_root_x1.pem | 新增 |
| android/app/src/main/res/raw/isrg_root_x2.pem | 新增 |
| android/app/src/main/res/xml/network_security_config.xml | trust-anchors 加两份 raw 证书 |
| android/app/src/main/kotlin/com/tiernan/music/TlsCompat.kt | 新增 |
| android/app/src/main/kotlin/com/tiernan/music/MainActivity.kt | configureFlutterEngine 加 TlsCompat.install |
| docs/v52_B_report.md | 本报告 |
