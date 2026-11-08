# 第4批·语法与静态检查（只允许 Dart SDK 解析，禁止编译/禁止 Flutter SDK）

## 角色
你是**静态检查代理**。用 Dart SDK 的 `analyze` 做语法与静态诊断，**不编译、不运行、不装 Flutter SDK**。

## 允许的工具（唯一）
```sh
export PATH=$PATH:/opt/dart/bin
dart --version          # 3.13.7 arm64，已安装，不要升级、不要装 Flutter
```

## 绝对禁止
- 禁止安装 Flutter SDK / Android SDK / JDK / 任何包
- 禁止 `flutter build` / `flutter test` / `dart compile` / `dart run` / `dart pub get`
- 禁止修改任何代码（唯一例外：本任务指定的报告文件）
- 禁止 git commit / push

## 工作目录
`/var/minis/workspace/TiernanMusic`

## 方法
1. 先跑一次基线诊断，把结果落盘：
   ```sh
   cd /var/minis/workspace/TiernanMusic
   export PATH=$PATH:/opt/dart/bin
   dart analyze --no-fatal-warnings lib 2>&1 | tee /tmp/analyze.txt | tail -5
   ```
2. **必须过滤噪音**：本地无 Flutter SDK、无 `package_config.json`，所以下面这些是**噪音**，全部忽略：
   - `uri_does_not_exist`（找不到 package:flutter/**、package:riverpod/** 等）
   - `undefined_class` / `undefined_identifier` / `undefined_method` 中，**因为缺少上述包**而产生的
   - `invalid_annotation`（@riverpod 等）
   - `non_type_as_type_argument`、`extends_non_class`、`new_with_non_type` 等衍生的类型解析失败
   - `creation_with_non_type`、`undefined_getter` 中源自缺失包的条目
3. **真正要留的是「语法/结构级」错误**，它们与包缺失无关：
   - `expected_token` / `missing_identifier` / `unexpected_token`（语法错）
   - `not_enough_positional_arguments` / `extra_positional_arguments`（参数个数错）
   - `undefined_named_parameter` / `missing_named_parameter`
   - `invalid_assignment`、`return_of_invalid_type`（**仅当两侧都不是缺失包类型时**）
   - `unused_import` / `unused_local_variable`（真实死代码）
   - `duplicate_definition` / `duplicate_import`
   - `dead_code` / `unnecessary_null_comparison`（真实逻辑问题）
   - `abstract_super_member_reference`
   - `unchecked_use_of_nullable_value`（真实空安全问题）
   - `local_variable_used_before_declaration`
   - `case_expression_type_is_not_switch_expression_subtype`
4. 对每一条保留项：`file_read` 打开对应文件核实（不要只看 analyzer 输出），确认是真错误还是噪音。
5. 结果落盘 `docs/batch4_static_check.md`，格式：
   ```
   ### <文件>:<行> <错误码> <简述>
   - 判定：真错误 / 噪音（说明为何）
   - 依据：<代码原文>
   - 建议修复点：<一句话，不写代码>
   ```

## 额外检查（不依赖 SDK 也能做的结构检查）
- `bash check_braces.sh`（仓库自带括号平衡检查）
- import 存在性：所有 `import 'package:xxx'` 是否在 `pubspec.yaml` 的 dependencies 里声明
- 循环依赖：`core/` 是否 import `features/**`
- 重复定义：同名类/方法是否在多处定义

## 产出
`docs/batch4_static_check.md`：真错误清单（按严重度）+ 噪音说明 + 三项结构检查结论。

完成后 4 行内汇报：真错误 N 条（列文件:行）、噪音占比、结构检查是否通过。
