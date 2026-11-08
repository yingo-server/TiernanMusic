# v3.7 专项实测：FLAC 明文判定的深度复核

> 日期：2026-11-07（第二轮）。针对用户质疑「你确定是明文 FLAC？有时只是扩展名」——
> 上一轮 `v37_audio_encryption_audit.md` 仅凭文件头 `fLaC` 魔数 + 扩展名判定「明文」，
> 本轮用**结构级（STREAMINFO / frame 遍历 / 尾部 END）+ 解码级（ffmpeg 全量解码）+ MD5 交叉**三重验证复核。
> 实测均直打原生域（`/v5/url` trackercdn，kg_probe.py 原生签名，VIP 态 cookie），kapi 未参与任何判定。
> 实测工具：本轮新装 `ffmpeg/ffprobe`（apk add，属实测工具，未触碰业务代码）。
> 实时落盘：每个环节测完立即 append 本文件。

## 环节 1：STREAMINFO 解析（结构级）

| 档 | meta blocks（type,len 顺序） | rate/ch/bps | totalSamples | STREAMINFO MD5 |
|---|---|---|---|---|
| flac | STREAMINFO(34)→SEEKTABLE(486)→VORBIS_COMMENT(95)→PADDING(8137) | 44100 / 2 / 16 | 11,895,828 | `89036f70d326d3f557bb46c7cef053c2` |
| high | STREAMINFO(34)→SEEKTABLE(486)→VORBIS_COMMENT(95)→PADDING(8181) | 44100 / 2 / **24bit** | 11,895,828 | `33de209bed371d2fd522f860a3161ee5` |
| super | 同 flac（逐字节同一文件） | 44100 / 2 / 16 | 11,895,828 | `89036f70…` |

- 128：ID3v2.3 + MPEG frame，ffprobe duration=269.792s，接口 timeLength=269 ✅。

## 环节 2：frame 遍历 + 尾部 + 大小核对

- 三档 FLAC：audio data 起点后扫描 `0xFF F8~FB` frame 同步码——flac/super 3,947 个合法同步、high 5,008 个，**同步码序列连续未被打断**。⚠️ 注：朴素扫描中出现的「非法 rate code」（flac 363 / high 700）全部落在 frame 数据区（0xFF 可能出现在压缩码流内部），属扫描方法固有噪声，非加密迹象——终极判定以环节 3 全量解码为准。
- 尾部：`END` 标记未以裸文本出现在末 140 字节——因为三档 Vorbis comment 之后紧跟大量 frame 数据，**尾部本身就是音频 frame**，这恰是正常 FLAC 结构（END 标记并不在文件末尾——FLAC 无文件级 EOF 标记，STREAMINFO 之后直接到文件尾都是 frame；`45 4E 44` 存在于 Vorbis comment 块内部字符串中）。任务书第 2 步对尾部结构的描述本身有误，以 ffmpeg 全量解码为铁证。
- 大小核对：flac 压缩比 0.665（66.5%，合理区间 30%-70% ✅）；high 为 24bit 母带，0.776（24bit FLAC 压缩比天然低于 16bit，合理 ✅）。

## 环节 3：ffmpeg 全量解码（终极判定）

| 档 | ffmpeg -f null - | ffprobe codec | duration | bitrate |
|---|---|---|---|---|
| flac | **exit=0，零错误完整解码** | flac | 269.746667 | 938 kbps |
| high | **exit=0，零错误完整解码** | flac (24bit) | 269.746667 | 1643 kbps |
| super | **exit=0，零错误完整解码** | flac | 269.746667 | 938 kbps |
| 128 | exit=0 | mp3 | 269.792653 | 128 kbps |

duration 269.7467s = 11,895,828 samples / 44100Hz，与 STREAMINFO **精确一致**。加密/损坏文件不可能通过 ffmpeg 全量解码。

## 环节 4：MD5 交叉验证（PCM 级）

- flac：`ffmpeg -i flac -f s16le - | md5sum` = `89036f70d326d3f557bb46c7cef053c2` = **STREAMINFO 内嵌 MD5，完全一致** ✅
- high（24bit）：`ffmpeg -f s24le -` = `33de209bed371d2fd522f860a3161ee5` = **STREAMINFO MD5 完全一致** ✅

STREAMINFO 的 MD5 校验的是原始 PCM——若任何字节被加密/篡改，解码后 MD5 必不匹配。**两档独立命中，加密在数学上被排除。**

## 环节 5：扩展名 / Content-Type / 真实格式 三方对照

| 档 | URL 后缀 | Content-Type | ffprobe 真实格式 | 一致？ |
|---|---|---|---|---|
| flac | `.flac`（CDN 路径） | audio/x-flac | flac | ✅ |
| high | `.flac` | audio/flac | flac 24bit | ✅ |
| super | `.flac` | audio/x-flac | flac（同 flac 档文件） | ✅（但非 DSD，降级） |
| 128 | `.mp3` | audio/mpeg | mp3 128kbps | ✅ |

### 补：环境与方法说明

- 实时落盘：每个环节测完立即 append 本文件。
- 本轮 URL host 为 `fsandroid.kugou.com`（trackercdn `/v5/url` 返回的 CDN 直链，仍为原生域直连，kapi 未参与）。
- 样本重取：VIP 态全量下载 128 / flac / high / super，字节数与接口 fileSize 完全一致，全文件 md5 与接口 hash 一致（128=`b3a5…8b7`、flac/super=`0a69…30d`、high=`d667…009`）。
- super 再次确认为与 flac 逐字节相同的同一文件（降级）。
- 样本留样：`/tmp/v37d/`（128、flac、high、super 四个全量文件）。

## 三档对照表（深度复核汇总）

| 项目 | flac × VIP | high × VIP | super × VIP |
|---|---|---|---|
| 文件大小 | 31,633,244 B | 55,397,039 B | 31,633,244 B（=flac，降级） |
| STREAMINFO | MD5=`89036f70…`，11,895,828 samples，44100/2ch/16bit | MD5=`33de209b…`，11,895,828 samples，44100/2ch/24bit | 同 flac |
| frame 遍历 | 3,947 个连续合法同步码，未打断 | 5,008 个连续合法同步码，未打断 | 同 flac |
| 尾部 | 音频 frame 直至 EOF（正常 FLAC 结构） | 同左 | 同左 |
| ffmpeg 解码 | 成功，duration=269.7467，零错误 | 成功，duration=269.7467，零错误 | 成功 |
| PCM MD5 交叉 | 与 STREAMINFO MD5 **一致** | 与 STREAMINFO MD5 **一致**（s24le） | 同 flac |
| 扩展名三方对照 | .flac / audio/x-flac / 真flac ✅ | .flac / audio/flac / 真flac24 ✅ | .flac / audio/x-flac / 真flac ✅ |
| **结论** | **真明文 FLAC** | **真明文 FLAC（24bit 母带）** | **真明文 FLAC（降级产物）** |

## 对上一轮结论的声明

**维持**：上一轮「flac / high / super 为明文 FLAC」的结论正确——但判定依据从「仅文件头」升级为三重铁证：
1. ffmpeg 全量零错误解码（加密文件必失败）；
2. duration 与 STREAMINFO totalSamples/44100 精确吻合；
3. 解码后 PCM 的 MD5 与 STREAMINFO 内嵌 MD5 完全一致（flac 用 s16le、high 用 s24le 独立命中）——加密会破坏 MD5，此为数学级排除。

**对用户质疑的回答**：不是「只是扩展名」。扩展名、Content-Type、真实格式三方一致；文件是完整、可解码、MD5 自洽的标准 FLAC（flac/super 16bit/938kbps，high 24bit/1643kbps 母带）。

**无需修复方案**（结论维持）。既有非加密问题维持原判：super 静默降级为 flac（无 DSD 母带时）。

**方法学注记**：任务书第 2 步称「文件末尾应有 END 标记 + 128 字节 Vorbis comment」与 FLAC 规范不符——FLAC 无文件级 EOF 标记，元数据块（含 Vorbis comment）在文件**头部**，其后直至文件尾全部是音频 frame。本轮实测尾部为合法 frame 数据，属正常结构。



