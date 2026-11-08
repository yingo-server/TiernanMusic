# v3.9.9 任务书 B：个人信息页性能 + 权限网关 + 音质音效 + 下载择优（修复代理）

先完整读 `/var/minis/workspace/TiernanMusic/docs/QUALITY_STANDARD.md`（33 条）与 `docs/PROGRESS.md` 末段。

## ⚠️ 硬性规则（违反即失败）
- **绝对禁止**：装 Flutter SDK / flutter 命令 / dart pub get / 下载任何 SDK / 改 pubspec.yaml 一行（ARM64 无 Flutter）
- 只允许 `dart analyze`；Flutter/三方符号报错是预期噪音，**项目自有类报错即真错误**
- **触碰的每个文件收尾前必须 analyze 并逐文件贴报告——缺一即失败**
- 跨文件改动双向核对；禁 git commit/push；只用 file_edit；改动标 `V399-xx`
- i18n 新键 11 语言全补 + 重跑 `python3 tool/gen_l10n_min.py` 贴输出
- 只使用项目内已存在且已读定义确认签名的类/方法
- 报告 `docs/v399_fix_b.md` **实时落盘**

## 工作目录
`/var/minis/workspace/TiernanMusic`，基线 `755dcea`

## 任务一：个人信息页登录大延迟（V399-B1，P1）
用户反馈「登录大延迟，慢」。
- 完整 file_read：`library_page.dart`（账号卡区）、`auth_providers.dart`、`auth_repository.dart`（loginByToken/restoreSession）、`secure_storage.dart`、`account_manager.dart`（若存在）
- 排查：登录后个人信息页是否**串行**做了多个网络请求（用户详情/等级/勋章/听歌排行……）；是否每次 build 重复请求；是否有阻塞首屏的 await 链
- 修复：并行化无依赖请求（Future.wait）、必要时骨架屏/缓存上一次数据先渲染（stale-while-revalidate 模式）、只请求当前页真正展示的字段
- 修复前后请求序列在报告中列出对照

## 任务二：权限管理网关（V399-B2，P0）
用户反馈「权限网关仍问题大：各步骤无回退和检查，全靠上游返回状态，给了权限说没给」。
- 完整 file_read：`storage_permission_service.dart` 全文、`error_logger.dart`（日志落盘分支）、`public_media_store.dart`、`download_provider.dart`、`settings_page.dart`（存储区）
- 修复要点：
  a) `resolveRoot()` 每次调用**重新实测**写入能力（探测文件写入+删除），不信缓存状态——「给了权限说没给」的根治
  b) 每个步骤（isGranted/request/openAppSettings/探测写入/MediaStore 分支）失败必须留痕 ErrorLogger，禁止裸 catch 吞掉
  c) 授权状态变化后所有依赖方刷新（Lifecycle resumed 重查已有，核对覆盖面）
  d) 设置页展示「探测到的实际可写路径」而非「声称的路径」
- 报告中列出修复前后每步骤行为对照表

## 任务三：音质音效补齐（V399-B3，P1）
用户反馈「音质音效支持不完整」。已知实测结论（v37_cripple_report.md）：VIP 态蝰蛇三档（viper_tape/clear/atmos）与魔法音效六档（magic_piano/acappella/dj/surnay/subwoofer/ancient，匿名也可）真实返回 URL；`KgSharedParams.magicQualities` 参数构造已备。
- 完整 file_read：`models.dart`（AudioQuality 枚举）、`kg_play_api.dart`（upstreamQualities/请求构造）、`player_repository.dart`（_qualityFromBitrate/fallback）、设置页音质选择器
- 落地：枚举扩展蝰蛇三档+魔法六档（显式选择，不进通用 fallback——魔法档是特殊音源）；`/v5/url` 请求 quality 参数映射（viper_*/magic_ 前缀）；设置页/播放页音质菜单暴露；非 VIP 选蝰蛇/魔法时的降级链（不可降为普通 fallback，失败明确报因）
- 注意魔法档匿名可用：非 VIP 也可选

## 任务四：非 VIP 下载择优（V399-B4，P1）
用户要求「比对高潮字段和试听字段返回文件的字节数（API 有返回，不用下载比对，选长的）而不是只试听」。
- 依据：`/v5/url` 响应中试听片段与 hash_offset（climax/offset_hash）各有 filesize/byte 信息（此前实测 hash_offset 有 start_byte/end_byte）
- 完整 file_read：`kg_play_api.dart`、`player_repository.dart`（_playAt/试听兜底）、`download_provider.dart`
- 落地：非 VIP 下载时同时请求「试听片段」与「高潮片段（offset_hash）」的元数据，**比较响应中声明的字节数选长的那条**作为下载源；UI 无需变化，下载元信息里记录所选片段类型
- 禁止真的下载两个文件比对——只用 API 返回的字节数

## 完成后
报告末尾 8 行内汇报：V399-B1~B4 各自改动、analyze 逐文件结果、l10n 输出、未做项原因。
