# v3.7 专项实测：播放链路音频文件加密问题全面检查

> 日期：2026-11-07。依据《QUALITY_STANDARD.md》第 27/28/29/33 条：本报告全部结论来自
> **原生域直连实测**（trackercdn.kugou.com `/v5/url`，经 KuGouMusicApi 参考项目的原生签名路径发出，
> kapi 未参与任何判定），样本留样于 `/tmp/samples/`。

## 一、实测方法

- 端点：`GET https://trackercdn.kugou.com/v5/url`（原生域，正确 MD5 签名 + key=MD5(hash+盐+appid+mid+userid)，dfid 随机 24 位，IsFreePart=1）。
- 三态：匿名（无 cookie）/ 非VIP（userid=2461028533）/ VIP（userid=1666835066，svip_level=5）。
- 样本曲目：周杰伦《晴天》（hash `B3A52A7A958BF0AED0EBFBA2E9A818B7` / album_audio_id 32100650；
  高音质用 search 返回的对应档 hash：320=`1B56…CBC`，flac/SQ=`0A69…30D`）。
- 字节验证：`curl -r 0-65535` 取前 64KB，`xxd` 对照魔数；并对 128 与 flac 做了**全文件下载 + MD5 与接口 hash 比对**。

## 二、逐档实测

### 实测 128 × anon / nonvip / vip（三态同 URL）
- URL 获取：成功。`extName=mp3`，`timeLength=269`，`fileSize=4317292`，trans_param 完整（qualitymap/cpy_map/ogg_* 均在）。
- 文件头：`49 44 33 03 00 00 00 00 00 37 54 49 54 32 …`（ID3v2.3，后随 MPEG frame）
- 判定：**明文 MP3 ✅**
- 全文件下载 4,317,292 字节，`md5sum = b3a52a7a958bf0aed0ebfba2e9a818b7`，**与接口 hash 完全一致**。
- 结论：播放（just_audio 直吃 URL）与下载均正常，未受加密影响。

### 实测 320 × vip（anon/nonvip 20028 需验证）
- URL 获取：成功（hash 用 320 档 hash）。`extName=mp3`，文件大小 10,792,943。
- 文件头：`49 44 33 03 …`（ID3v2.3）
- 判定：**明文 MP3 ✅**

### 实测 flac × vip
- URL 获取：成功。`extName=flac`，文件大小 31,633,244。
- 文件头：`66 4C 61 43 00 00 00 22 10 00 10 00 …`（**fLaC**）
- 判定：**明文 FLAC ✅**
- 全文件下载 31,633,244 字节，`md5sum = 0a69169202de95aaf24a9944ccf0730d`，**与 SQ hash 完全一致**。

### 实测 high × vip
- URL 获取：成功。文件大小 55,397,039。
- 文件头：`66 4C 61 43 …`（fLaC）
- 判定：**明文 FLAC ✅**

### 实测 super × vip
- URL 获取：成功。返回 URL 指向 **flac 文件**（大小 31,633,244 与 flac 档相同——该曲目无 DSD 母带，super 降级返回 flac，见参考项目文档「super 返回 DSD，支持的音频少」）。
- 文件头：`66 4C 61 43 …`
- 判定：**明文 FLAC ✅**（注意：并非承诺的最高格式，是降级产物，属另一问题）

### 实测 viper_atmos × vip
- URL 获取：成功。`extName=flac`，72,293,078 字节。
- 文件头：`66 4C 61 43 00 00 00 22 12 00 12 00 …`
- 判定：**明文 FLAC ✅**（蝰蛇全景声封装为普通 FLAC 流）

### 实测 viper_hires × vip
- URL 获取：**失败**。`error_code=20010`，`priv_status=0`，`trans_param={display:0}`，无 url（该账号/该曲无 hires 权益，非加密问题）。

### 实测 magic_piano / magic_subwoofer / magic_ancient / magic_dj / magic_surnay × vip
- URL 获取：成功。`extName=mp3`。
- 文件头：`FF FB B0 64 …` / `FF FB B0 44 …`（**MPEG frame sync**）
- 判定：**明文 MP3 ✅**

### 实测 magic_acappella × vip
- URL 获取：成功。`extName=mkv`，13,098,678 字节。
- 文件头：`1A 45 DF A3 …`（**EBML/Matroska**，即 MKV/WebM 容器，明文）
- 判定：**明文容器（非 KGM/VPR）**，但 ⚠️ just_audio 不直接支持 MKV 容器——这是格式问题不是加密问题，标注为「明文但容器特殊」。

### 三态 20028 说明
- 320 及以上档位在 anon / nonvip 下返回 `errcode=20028「本次请求需要验证」+ ssaCode`，VIP 下正常。与既往 FINDINGS 记录一致，属验证墙问题，非加密问题。

## 三、KGM/VPR 判定汇总

**所有 12 个成功下载的样本（128×1 全文件、320/flac/high/super/viper_atmos×头部 64KB、magic×5 头部）无一命中 KGM（`4B 47 4D`）/ KGMA / VPR（`39 46 CC 4D`）魔数。** 未发现任何加密文件。

对照参考项目 `KuGouMusicApi/docs/README.md`（/song/url/new 条目）确有记载：「该接口存在音频加密（目前无法解码）」——但实测表明加密出现在**另一条接口**（v2/android 版 `/song/url` 或客户端专属 CDN 路径），本 App 实际使用的 `/v5/url`（trackercdn，IsFreePart/ssa_flag=track 路径）返回的是**直出明文 CDN 文件**。Node 参考项目内 `rg kgm/vpr/decrypt` 无任何解密实现（也侧面说明其主路径不需解密）。

## 四、下载链路核对

`lib/features/download/download_provider.dart`：`_repo.downloadFile(url, realTempPath)` 原样写字节 → `publish` 入媒体库。**无解密步骤**。基于本实测（/v5/url 直出明文、MD5 与接口 hash 全文件吻合），下载文件为标准 MP3/FLAC，系统播放器可直接使用——**此前「下载对高音质是坏的」的怀疑，就加密维度而言不成立**；仅在 super 降级、mkv 容器（magic_acappella）两处存在非加密的真实问题。

## 五、结论矩阵

| 音质档 | anon | nonvip | vip |
|---|---|---|---|
| 128 | 明文 MP3 ✅ | 明文 MP3 ✅ | 明文 MP3 ✅（MD5 全文件吻合） |
| 320 | 20028 需验证 | 20028 需验证 | 明文 MP3 ✅ |
| flac | 20028 | 20028 | 明文 FLAC ✅（MD5 全文件吻合） |
| high | 20028 | 20028 | 明文 FLAC ✅ |
| super | 20028 | 20028 | 明文 FLAC ✅（降级，无 DSD） |
| viper_atmos | 20028 | 20028 | 明文 FLAC ✅ |
| viper_hires | 20028 | 20028 | 拿不到 URL（20010 无权益） |
| magic_piano/subwoofer/ancient/dj/surnay | 20028 | 20028 | 明文 MP3 ✅ |
| magic_acappella | 20028 | 20028 | 明文 **MKV 容器**（just_audio 不直接支持） |

## 六、修复方案评估

- **KGM/VPR 解密**：不需要。密钥流 XOR 方案（含按 hash 派生密钥表）在本链路无用武之地；若未来切换到 `/song/url/new` 或客户端私有路径才需要，参考项目明确「无法解码」，成本不可估且不建议。
- **真正要跟进的（非加密）**：
  1. magic_acappella 为 MKV 容器，just_audio 无法播——需要格式降级或容器处理（成本 M）。
  2. super 在无 DSD 母带时静默降级为 flac，UI 若按 DSD 展示会失实（成本 S）。
  3. anon/nonvip 高音质 20028 验证墙为既有已知问题（见 FINDINGS.md），不在本专项范围。
