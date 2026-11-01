# 编译错误修复 + 匿名态/直连接口审查

工作目录：`/var/minis/workspace/TiernanMusic`（commit `8549ef3`）

未 commit。未下载 Flutter/Dart SDK，未安装任何包，未 clone，未执行
flutter build / pub get / dart analyze。所有核对均为人工 + 本地只读脚本。

## 一、编译错误修复（10 项）

### 1. settings_page.dart — `File` 未定义 / int-double 赋值
- 已补 `import 'dart:io';`（第 1 行）。
- `total` 为 `var total = 0;` → int；`entity.length()` 返回 int；
  `_formatBytes(int bytes)` 签名匹配，**不存在** int/double 赋值错误。
- 结论：已确认，无需再改。

### 2. app_theme.dart — `CupertinoPageTransitionsBuilder` 未定义 + const map
- 该类定义在 `packages/flutter/lib/src/cupertino/route.dart`，
  由 `package:flutter/cupertino.dart` 导出；**material.dart 不导出它**。
- 修法：文件头加
  `import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;`
- `pageTransitionsTheme: const PageTransitionsTheme(builders: {...})` 保持不变：
  `PageTransitionsTheme.builders` 在 3.47.9 是普通 `Map` 参数，const 上下文中
  map 字面量合法，两个 builder 均有 const 构造器。

### 3. app_theme.dart — `FilterChipThemeData` 未定义 + `filterChipTheme` 参数不存在
- Flutter 3.47.9 中 **不存在** `FilterChipThemeData` 类；`ThemeData` 也 **没有**
  `filterChipTheme` 参数（`FilterChip` 复用 `ChipThemeData`）。
- 修法：删除 `filterChipTheme: FilterChipThemeData(...)`，把
  `side` / `shape` / `labelStyle` 并入已有的 `chipTheme`。
- 额外：`showCheckmark` 不写死 —— M3 下各 chip 类型的默认值本就为 true，
  写进主题会覆盖各类型自身默认值。
- 额外：`labelStyle` 不设 color —— Flutter 的 chip 默认 labelStyle 带状态色
  （选中 onSecondaryContainer / 未选中 onSurfaceVariant）；主题里给了带 color 的
  labelStyle 会把状态色覆盖掉（chip.dart: `chipTheme.labelStyle ?? chipDefaults.labelStyle`
  后不再回退默认值）。

### 4. app_theme.dart — TextStyle 赋给 WidgetStateProperty<TextStyle?>?
- 位置：`SearchBarThemeData.textStyle`。
- 3.47.9 源码：`final WidgetStateProperty<TextStyle?>? textStyle;`
- 修法：
  ```dart
  textStyle: const WidgetStatePropertyAll<TextStyle?>(
    TextStyle(fontWeight: FontWeight.w400),
  ),
  ```
- `navigationBarTheme.labelTextStyle` / `switchTheme.thumbIcon` 原本就用了
  `WidgetStateProperty.resolveWith(...)`，已确认正确，未改动。

### 5. full_player_page.dart — `IconButton.toggle` 未定义（2 处）
- 第 183 行（shuffle）、第 217 行（loopMode）改为普通 `IconButton` +
  `isSelected` / `selectedIcon`。
- 3.47.9 `IconButton` 构造器确有 `isSelected` / `selectedIcon`；
  `isSelected != null` 时行为等同 toggle button。

## 二、匿名态 / 直连接口审查

### kg_crypto.dart
- `rsaEncryptPkcs1` 默认输出**小写** hex（`uppercase` 默认 false），对齐
  Node `forge.util.bytesToHex`。登录用的 `rsaEncryptRawHex` **未改动**
  （仍输出小写，由调用方 `.toUpperCase()`）。
- `aesDecryptPlaylistB64(base64Str, seed)`：AES-128-CBC + PKCS7，
  key = `md5(seed).substring(0,16)`、iv = `md5(seed).substring(16,32)`
  （16 个 ASCII 字符，直接按字节用，非 hex 解析）→ UTF-8 → JSON，
  非 Map 时抛 `FormatException`。正确完整。

### kg_client.dart — registerDevice()
全部核对通过：
- POST `https://userservice.kugou.com/risk/v3/r_register_dev`
- query：`part=1`、`platid=2`、`p=<RSA 小写 hex>` + dfid/mid/uuid/appid=1005/
  clientver=20489/clienttime/signature
- body：`playlistAesEncrypt(payload)` 的 base64 串
- headers：`application/x-www-form-urlencoded` + dfid/clienttime/mid/kg-rc/
  kg-thash/kg-rec/kg-rf/User-Agent
- `platid` 硬编码 **2**
- RSA 明文 uid 固定字符串 **`"0"`**，token 固定空串（不受登录态污染）
- signature 含 body：`md5(salt + sorted("k=v") + bodyStr + salt)`
- 响应二进制：`responseType: bytes` → `base64(bytes)` → seed派生 key/iv 解密 →
  JSON `{status, error_code, data:{dfid}}`
- `data:[]` 判为未分配 → false → 触发重试
- 失败重试 3 次（400ms / 800ms 退避）
- 成功写回 `device.dfid` 并经 `onDfidRegistered` 持久化 Hive
- payload：24 个传感器字段 + `imei`/`uuid`=guid；
  **无** guid / mid / networktype / mac
- 额外加固：解密失败时回退尝试解析明文 JSON

### kg_direct_api_client.dart
- `_everydayRecommend`：`platform` 在 **query**，默认 `'ios'`，保留
  `x-router: everydayrec.service.kugou.com`
- `_privilege`：过滤空 hash 与字符串 `"null"`；`page_id: 0`；
  `qualities` 为**数组**；`x-router: media.store.kugou.com`
- `_playlistTrackAll`：`collection_...` 才用 `global_collection_id`，
  数字改用 `specialid` 键；`pagesize` 为 int；
  `begin_idx = (page-1)*pagesize`
- `_kmrAudioMv`：body `{'data':[{'album_audio_id':X}],'fields':...}`，
  保留 `KG-TID: 38`
- `_songUrl`：key 用小写 hash + 字符串 userid（匿名 `'0'`）；signature 必填
- `_wrap`：成功判定 `status == 1`；151/152 等警告码在 body 有非空 data 时放行

### kg_play_api.dart
- 新增 `KgSharedParams`，`KgPlayApi.songUrl` / `privilege` 与
  `kg_direct_api_client.dart` 的 `_songUrl` / `_privilege` 共用同一实现，
  不存在两份逻辑漂移。
- privilege：过滤空 hash / `"null"`、`page_id: 0`、`qualities` 数组。

### kg_providers.dart
- `kgClientProvider` 注入 `client.onDfidRegistered` →
  `KgDeviceStore.saveDfidSync(dfid)`。
- `saveDfidSync` 从已 open 的 Hive `'device'` box 读原 JSON，
  **只更新 `dfid`**，不覆盖 guid/mid/dev/mac/webgl，同步写回。
- `main.dart` 已 open `'device'` box 并用 `loadSync` 载入，注册所得 dfid
  下次启动可读回。

## 三、本地只读检查结果
- `bash check_braces.sh` → `brace check done`，无括号不配对。
- 坏 import 扫描 → 仅 `lib/l10n/l10n.dart:3: app_localizations.dart`，
  属 `flutter gen-l10n` 生成产物（`l10n.yaml` output-dir=lib/l10n），非缺陷。
- l10n key 扫描 → 214 个用法 vs `app_en.arb`，**零缺失**。
- Icon 扫描 → 96 个 `Icons.*` vs Flutter 3.47.9，**零缺失**。

## 四、额外 API 人工核对（Flutter 3.47.9 = CI `FLUTTER_VERSION`）
全部通过：ThemeData 全部命名参数、ChipThemeData 字段类型、
NavigationBarThemeData.labelTextStyle、SwitchThemeData.thumbIcon、
WidgetStatePropertyAll/resolveWith、IconButton.isSelected/selectedIcon、
RadioListTile.groupValue（仅 Deprecated，非编译错误）、
SliverAppBar.large、SliverList.separated、SegmentedButton/ButtonSegment、
Badge、FilledButton.tonal/tonalIcon、IconButton.filled、showDragHandle、
TabAlignment.start、Matrix4（经 widgets.dart 导出）、
ThemeExtension.lerp 的协变覆写合法性。

## 五、说明
- 未 commit。
- 未安装 SDK / 未装包 / 未联网安装 / 未 clone。
- 未执行 flutter build / pub get / dart analyze（按要求禁止）。
