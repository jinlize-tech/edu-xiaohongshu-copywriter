# 产品测试报告 v1.1.0

- 产品：小红书招生文案（JLZ-EDU-SK-004）
- 包状态：EDUCATION_1.1.0_PRE_RELEASE_ACCEPTED
- 模型运行状态：MODEL_RUNTIME_NOT_VERIFIED

| 层级 | 状态 | 检查数 | 失败数 |
|---|---|---:|---:|
| T1_FILE_STRUCTURE | PASS | 31 | 0 |
| T2_METADATA_CONTRACT | PASS | 45 | 0 |
| T3_PRODUCT_CONTRACT | PASS | 16 | 0 |
| T4_DETERMINISTIC_FUNCTION | PASS | 2 | 0 |
| T5_SCENARIO_TESTS | PASS | 9 | 0 |
| T6_SECURITY | PASS | 3 | 0 |
| T7_PACKAGE_INTEGRITY | PASS | 11 | 0 |

## 失败明细

- 无

## 运行边界

- T4/T5 包含实际输入校验脚本和场景状态测试；生成式模型输出未在本地运行，标记 MODEL_RUNTIME_NOT_VERIFIED。
- WorkBuddy解析、安装、调用和审核未执行，不在本轮验收中冒充通过。

