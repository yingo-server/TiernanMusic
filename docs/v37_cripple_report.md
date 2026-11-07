# v3.7 功能对比档：已实现功能的「阉割」专项（仅报告，不写代码）

> 基线：v3.6.0。判定基准 `QUALITY_STANDARD.md`（33 条，第 33 条：kapi 返回不可作判定依据）。
> 方法：Node 参考 `KuGouMusicApi/module/`（236 模块）逐域对照 Flutter `lib/` 实现；
> 实测一律 `/var/minis/workspace/.test_creds/native_probe.sh` 直打原生域三态（anon/nonvip/vip），
> kapi 仅对照、不作判定依据。
> 实测执行环境说明：本档在无真机网络受限环境完成，凡实测项均已标注三态结果来源；
> 未留样字段一律不判「阉割」（任务书硬性规则第 5 条）。

---
