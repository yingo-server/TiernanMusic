# 批4检3：发布视角终审（纯读）

- 视角：发布工程师（v2.0.0 LTS 发布前最后一道审查）
- 基线：工作区现状（含批4修1/修2 未提交产出，commit `4ecfdd8` 之后）
- 只读审查：未修改任何文件，未运行 flutter/test
- 严重度：**发布阻塞 > 强烈建议 > 建议**

---

## 一、发布阻塞

### B1. CI 每次 tag 生成全新 keystore —— 用户永远无法覆盖升级
- `.github/workflows/build.yml:78-85`（`Generate keystore` 步骤，`if: github.ref_type == 'tag'`）
- 问题：每次打 tag 都 `keytool -genkeypair` 现场生成一把新 keystore（随机密钥）。发布 v2.0.0 后再发 v2.0.1，签名不同 → Android 拒绝覆盖安装，用户必须卸载重装、丢失全部本地数据（Hive 歌单/下载记录在应用目录，一并清除）。对"LTS"版本是致命伤。
- 修法：
  1. 本地生成一次固定 keystore（`validity 10000`），base64 后存入 GitHub Secrets（如 `ANDROID_KEYSTORE_B64`、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`）；
  2. CI 步骤改为解码还原：
     ```yaml
     - name: Restore keystore
       if: github.ref_type == 'tag'
       env:
         KS_B64: ${{ secrets.ANDROID_KEYSTORE_B64 }}
       run: echo "$KS_B64" | base64 -d > android/app/tiernan.jks
     ```
  3. 密码不要再硬编码在 build.gradle（见 S1）。

### B2. 版本号与发布目标不一致：pubspec 仍是 `1.0.0+1`
- `pubspec.yaml:5`（`version: 1.0.0+1`）
- 问题：本次发布目标是 **v2.0.0 LTS**，pubspec 还是 1.0.0+1。tag `v2.0.0` 打出后：① 应用内「关于 → 版本」显示 1.0.0，与 release 页 / tag 自相矛盾；② 若 v1.x 曾发布过，`buildNumber` 也不递增（见 B3 关联）。CI 没有任何「tag 与 pubspec version 一致性校验」。
- 修法：`pubspec.yaml` 改为 `version: 2.0.0+2`（buildNumber 相对 1.0.0+1 递增）；并在 build.yml 的 release job 前加校验步骤：
  ```yaml
  - name: Verify version matches tag
    run: |
      V="${GITHUB_REF_NAME#v}"
      P="$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml)"
      [ "$V" = "$P" ] || { echo "tag v$V != pubspec $P"; exit 1; }
  ```

### B3. versionCode 不随发布递增（覆盖升级第二杀手）
- `pubspec.yaml:5` + `build.yml:96`（`flutter build apk --release --split-per-abi`）
- 问题：构建命令不传 `--build-number`，versionCode 永远取 pubspec 的 `+1`（本地还有 local.properties 覆盖路径，CI fallback 为 1）。两个不同 tag 构建出的 release APK versionCode 相同 → 覆盖安装被拒（versionCode 不允许降级/相同在部分场景下行为不定）。
- 修法：release 构建加 `--build-number=$GITHUB_RUN_NUMBER`（或发布日手动递增 pubspec 的 `+N` 且保证单调递增）。推荐前者，一劳永逸：
  ```yaml
  run: flutter build apk --release --split-per-abi --build-number="$GITHUB_RUN_NUMBER"
  ```

---

## 二、强烈建议

### S1. keystore 密码硬编码 + .gitignore 白名单会把 jks 连同密码提交进仓库
- `android/app/build.gradle:55-61`（`storePassword 'tiernan123'` / `keyPassword 'tiernan123'`）
- `.gitignore:26-28`（`*.jks` 但 `!android/app/tiernan.jks` 白名单放行）
- 问题：按 B1 修好固定 keystore 后，本地一旦把 `tiernan.jks` 放到 `android/app/`，白名单会让它连同源码里的明文密码一起进 git 历史。源码仓库是公开可见的（README 有 badge 指向 GitHub）。
- 修法：密码改读环境变量/key.properties：
  ```gradle
  tiernan {
      def ks = file('tiernan.jks')
      if (ks.exists()) {
          storeFile ks
          storePassword System.getenv('KS_STORE_PASS') ?: 'tiernan123'
          keyAlias 'tiernan'
          keyPassword System.getenv('KS_KEY_PASS') ?: 'tiernan123'
      }
  }
  ```
  并删除 `.gitignore` 的 `!android/app/tiernan.jks` 白名单行。

### S2. release 构建未上传 mapping.txt / 调试符号 —— 崩溃无法还原
- `build.yml:88-111`（release 构建与上传步骤）
- 问题：proguard 已保留行号（`proguard-rules.pro:63-64` ✅），但 R8 混淆后的 `build/app/outputs/mapping/release/mapping.txt` 没有任何上传步骤；后续用户发来的混淆堆栈（`a.b.c`）无法人工还原，LTS 版本长期维护期内崩溃不可分析。
- 修法：release 构建后追加：
  ```yaml
  - name: Upload mapping
    if: github.ref_type == 'tag'
    uses: actions/upload-artifact@v4
    with:
      name: tiernan-mapping-${{ github.ref_name }}
      path: build/app/outputs/mapping/release/mapping.txt
      retention-days: 365   # LTS 建议长期保留
  ```
  （可选：同样上传 `*.symbols` Flutter 符号。）

### S3. `app_localizations.dart` 是离线生成器产物，CI 会用真 gen-l10n 覆盖 —— 两者输出不保证一致
- `lib/l10n/app_localizations.dart:1`（`// GENERATED CODE ... (offline gen-l10n equivalent)`，来自 `tool/gen_l10n_min.py`）
- 问题：CI 三个 job 都跑 `flutter gen-l10n`（build.yml:37, 68, 130），输出同路径同文件名，会直接覆盖提交的文件——无 git 冲突，但**本地测试/自测用的离线模拟产物与 CI 真产物可能存在行为差异**（占位符类型、复数/性别语法、nullable getter 语义），一旦离线生成器有 bug，本地验过的东西在 release APK 里行为不同，且任何人本地 `flutter gen-l10n` 后都会产生大 diff 噪音。
- 修法（三选一，推荐 ①）：① 删除提交的生成文件，本地也统一用 `flutter gen-l10n`（l10n.yaml 已配置好，`synthetic-package: false` 需显式写上以保证输出到 lib/l10n）；② 保留文件但在 CI analyze 前加 `flutter gen-l10n && git diff --exit-code lib/l10n/app_localizations.dart` 校验一致性；③ 至少在 CI 加 `gen-l10n` 后的 diff 告警。

---

## 三、建议

### R1. 声明了但未使用的权限：READ_MEDIA_VIDEO / READ_MEDIA_IMAGES
- `android/app/src/main/AndroidManifest.xml:63-64`
- 代码全库只申请 `Permission.audio`（permission_gate.dart:55）、`Permission.storage`、`Permission.notification`（storage_permission_service.dart:77-97）。MV/歌词下载走 MediaStore Downloads（无 READ 权限需求），READ_MEDIA_IMAGES/VIDEO 无调用点。Google Play / 国内商店审核会问询用途。
- 修法：删除这两行；若未来 MV 保存到相册再按需加回。

### R2. proguard 存在「死规则」：`org.pointycastle.**`、`com.tencent.tcaptcha.**` 不存在
- `proguard-rules.pro:9-10, 47-48`
- pointycastle 是纯 Dart 包（无原生类、无 Java 反射）；TCaptcha 是 WebView 里的 JS（无 `com.tencent.tcaptcha` 原生类）。这些 keep 规则匹配不到任何类，属无效配置。当前真正起作用的是 `-keep class com.ryanheise.**`、`androidx.media3.**`、`io.flutter.**`（后者 Flutter 插件自带 consumer rules，再 keep 一遍冗余但无害）。
- 修法：删除 org.pointycastle / tencent 两段死规则，防止给后人「这些库有反射」的误导。Dart 侧代码不参与 R8，无需为它 keep。无运行时风险。

### R3. release 发布链被 visual-review 硬依赖
- `build.yml:151`（`release: needs: [build-apk, visual-review]`）
- 截图渲染（`test/screenshots_test.dart`）失败会连带阻塞 release。截图属于内部审查产物，不应有发布一票否决权。
- 修法：给 visual-review job 加 `continue-on-error: true`；或 release 只 `needs: build-apk`。

### R4. 截图会作为 release 资产公开发布
- `build.yml:170-183`（release 下载 `tiernan-screenshots` 并放进 `files:`）
- visual-review 的审查截图会随 release 对外发布。若截图是 QA/审查用途，混在 APK 下载列表里不专业且暴露内部流程；若是作为应用商店宣传图则合理。
- 修法：明确用途。若仅内部审查，从 release `files:` 中移除 `screenshots/screenshots-*.zip`，只保留 artifact。

### R5. 关键路径遗留 TODO 两处（均非阻塞）
- `lib/features/library/presentation/library_page.dart:385`：`// TODO(跳转): 用户歌单详情页待接入`
- `lib/features/search/presentation/search_page.dart:706`：`// TODO(播放模块): 歌手页跳接待补充`
- 影响：点击歌手条目无跳转响应（搜索结果有 `albumPageComingSoon` 文案兜底 ✅）。LTS 可接受，但建议歌手页或至少「敬请期待」Toast 在 v2.0.x 补上。

### R6. 依赖健康度小项
- `pubspec.yaml:31`：`just_audio_background: ^0.0.1-beta.13` 是 beta 版，LTS 版本建议关注 stable 化；锁死 `0.0.1-beta.13` 精确版本而非 `^`，防 beta 间 breaking。
- `app_config.dart:7`：API 域名 `kapi.344977.xyz` 为个人域，无备用地址/健康检查自动切换（设置页有手动测试连通性 ✅）。LTS 期间域名失效 = 全应用不可用，建议至少内置一个备用域名轮询。

### R7. arb 小瑕疵
- `lib/l10n/app_zh_CN.arb:436-443`：`recentErrorsCount` 的 placeholder 声明为 `"type": "String"`（example "12"），语义上应为 int，与其他 count 类 key（int）不一致；能用但不规范。
- `"comment"` 与 `"comments"` 同值重复（:16-17），可合并。

---

## 四、通过项（按审查点编号）

1. **版本号体系结构** ✅（数值见 B2/B3）：version 单一来源 pubspec，Gradle 经 flutter 插件读 `flutter.versionCode/Name`，无第二处硬编码版本。
2. **签名配置结构** ✅（流程见 B1）：debug/release 共用同一 signingConfig，本地有 jks 时 debug 也签名（避免 debug/release 数据互斥）；keystore 文件本身未提交进 git（`git ls-files` 无 .jks）。
3. **权限清单主体正确** ✅：INTERNET / ACCESS_NETWORK_STATE / WAKE_LOCK / FOREGROUND_SERVICE(+MEDIA_PLAYBACK) 与 audio_service 后台播放匹配；POST_NOTIFICATIONS（通知栏播放控制，Android 13+ 必需）✅；WRITE_EXTERNAL_STORAGE maxSdk=28、READ_EXTERNAL_STORAGE maxSdk=32 的版本上限写法规范 ✅；READ_MEDIA_AUDIO 与 permission_gate 的 `Permission.audio` 对应 ✅。无「用了没声明」项。
4. **LICENSE ↔ README ↔ 应用内文案三者一致** ✅：LICENSE（Source-Available，禁止使用/分发/商用）↔ README「源代码可见，但禁止任何使用…」↔ arb `licenseBody`/`unofficialClient`「非官方第三方客户端…与酷狗官方无任何关联」逐条对应；接口来源与免责声明在 licenseBody 中明确 ✅。
5. **崩溃不循环** ✅：main.dart 启动链每一环独立 try/catch（Hive、逐 box、cookie 目录、device、JustAudioBackground 8s timeout），`_startupError` 早退分支渲染可读错误页而非白屏；`ErrorWidget.builder` 覆盖构建异常；最终 `runApp` 必达；15s 看门狗只记日志不递归重启——**没有任何会循环崩溃的路径** ✅。runZonedGuarded 异步异常落盘不崩 ✅。
6. **匿名态首启动** ✅：路由 initialLocation `/home`，无登录门；首页聚合、搜索、播放均为公共资源（批4检2 报告 C 节确认 Provider 图与播放链路不依赖登录态）；「去登录」是引导不是拦截 ✅。
7. **权限申请时机** ✅：启动链零权限请求；存储权限仅在下载/诊断页按需申请（StoragePermissionService），日志写入明确「不主动弹权限框」（error_logger.dart:150-155）✅。
8. **空状态覆盖** ✅：无网（`networkErrorTitle/networkErrorHint/reload`）、搜索无结果（`noSearchResults/hotSearchLoadFailed`）、歌单空（`noPlaylistsYet/noSongsInPlaylist/loginToViewPlaylists`）、下载空（`noDownloads`）、队列空（`queueEmpty`）、最近播放空（`noRecentlyPlayed`）全部有中文文案 ✅。
9. **CI job 结构** ✅：analyze-test → build-apk / visual-review → release 依赖链清晰；PR 不构建 APK（build-apk 的 `if:` 排除 PR）；analyze `--no-fatal-infos` 不阻断；SDK 组件（platforms 36 / build-tools 36 / NDK 28）与 compileSdk flutter.compileSdkVersion 匹配；Java 21 与 build.gradle VERSION_21 / Kotlin jvmTarget 21 三处一致 ✅。
10. **R8 主风险面** ✅：audio_service（com.ryanheise）、media3/ExoPlayer、permission_handler 反射敏感类均已 keep；行号保留（LineNumberTable + renamesourcefileattribute）✅；Flutter 插件规则由 Gradle 插件自动注入（死规则见 R2，无运行时风险）。
11. **错误日志合规** ✅：`_redact` 对 token/authorization/cookie/signature 等凭据打码后才落盘（error_logger.dart:219-241），Bearer/Basic 头单独处理 ✅；日志写公共 Documents 前 `_hasStoragePermission` 只查状态不弹窗 ✅；文件 5MB 轮转 ✅。批4修1 的批量落盘缓冲（2s 聚合）+ apiLevel 进程内缓存已在位（工作区 diff 确认）✅。
12. **network_security_config** ✅：默认禁止 cleartext，仅酷狗音视频域放行，与 README「代理转发 HTTP 流，无需 cleartext」的描述自洽（`fsmvpc.tx.kugou.com` 一行是 `fsmvpc.kugou.com` includeSubdomains 的冗余，无害）。
13. **批4修1/修2 产出核对**（工作区未提交 diff）✅：F1 歌单逐首 cover、F2 onSongStarted 统一记录最近播放（play_helper._record 已删、注释指向 recentPlayRecorderProvider）、F3 peek+先登录后切指针、W4 相关、error_logger 批量落盘、main.dart 并行开箱+惰性 box、search_page ValueListenable 化——与批4检1/检2 报告的修法一致，未发现回归。
14. **analysis_options.yaml** ✅：flutter_lints 基线 + 4 条加固规则，CI `--no-fatal-infos --no-fatal-warnings` 不会因 lint 阻断发布。

---

## 五、结论

**v2.0.0 LTS 当前不可发布。** 三个阻塞项全部集中在发布工程本身（B1 签名、B2/B3 版本号），代码主体（启动链兜底、权限时机、空状态、日志合规、R8 keep 面、i18n 覆盖）已达发布质量。修完 B1–B3 + S1/S2（一次性把签名与版本管线做对）即可出 tag；S3、R1–R4 建议同批处理，合计约半天工作量。
