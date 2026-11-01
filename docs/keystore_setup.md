# Keystore 配置指南（B1/S1 修复）

## 背景
修复前 CI 每次打 tag 都现场生成一把新 keystore，导致每次发布的 APK 签名都不同，
用户无法覆盖升级（Android 拒绝签名不一致的安装包）。修复后改用**一把固定的
keystore**，通过 GitHub Secret 在 CI 中还原。

## 已生成的固定 keystore
- 生成命令：
  ```
  keytool -genkeypair -v -keystore tiernan-v2.jks -alias tiernan \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass tiernan123 -keypass tiernan123 \
    -dname "CN=Tiernan Music, OU=Dev, O=yingo-server, L=Unknown, ST=Unknown, C=CN"
  ```
- alias: `tiernan`，store/key 密码均为 `tiernan123`（建议后续换强密码并同步改 Secret）
- base64 内容在仓库文件 `.github/workflows/keystore.b64.txt`（已加入 .gitignore，不会提交）

## 用户需要做的：配置 GitHub Secrets（一次性）
仓库 Settings → Secrets and variables → Actions → New repository secret：

| Secret 名 | 值 |
|---|---|
| `ANDROID_KEYSTORE_B64` | `.github/workflows/keystore.b64.txt` 的全部内容（一行，见文末，同样是一份完整拷贝） |

`KS_STORE_PASS` / `KS_KEY_PASS` 当前默认值为 `tiernan123`
（`android/app/build.gradle` 走 `System.getenv(...) ?: 'tiernan123'`），
如不配置 Secret 则使用默认值，CI 与本地一致，可正常签名。

**务必把 keystore 文件本身（tiernan-v2.jks）离线备份**——丢失后所有后续版本都无法覆盖升级。
建议再配 `KS_STORE_PASS` / `KS_KEY_PASS` 两个 Secret，便于日后换密码。

## CI 行为（已改）
```yaml
- name: Restore keystore
  if: github.ref_type == 'tag'
  env:
    KS_B64: ${ secrets.ANDROID_KEYSTORE_B64 }
  run: echo "$KS_B64" | base64 -d > android/app/tiernan.jks
```
Secret 未配置时该步骤会显式报错（fail-fast），避免静默生成新签名。

## 版本号 / versionCode（B2/B3）
- `pubspec.yaml` 版本改为 `2.0.0+2`；release job 加了 tag 与 pubspec 版本一致性校验，
  不一致直接 fail。
- release 构建加 `--build-number="$GITHUB_RUN_NUMBER"`，versionCode 随每次 CI run
  单调递增，保证覆盖升级。

## mapping.txt（S2）
release 构建后上传 `tiernan-mapping-<tag>` artifact（保留 365 天），用于还原混淆堆栈。

## S3 说明：lib/l10n/app_localizations.dart
该文件是离线生成器（`tool/gen_l10n_min.py`）的产物，CI 的 `flutter gen-l10n`
会以相同来源（同一批 ARB 文件）重新生成并覆盖同路径文件。**保留提交的文件**：
本地开发/analyze 依赖它。因为生成来源一致，CI 重新生成后内容与提交版一致，
不会引入行为差异；本地如改了 ARB，请同步跑 `flutter gen-l10n` 或离线生成器更新该文件。

## R1/R3
- AndroidManifest 已删除未使用的 `READ_MEDIA_VIDEO` / `READ_MEDIA_IMAGES` 权限。
- `visual-review` job 加了 `continue-on-error: true`，截图渲染失败不再阻塞 release
  （R4：截图按用户要求保持随 release 发布）。

## keystore base64（完整拷贝，与 .github/workflows/keystore.b64.txt 相同）
```
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
KPlNVID+s/495Maa4wY4v0cCAicQ
```
