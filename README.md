# edu-xiaohongshu-copywriter

- 产品名称：`edu-xiaohongshu-copywriter`
- 产品编号：`JLZ-EDU-SK-004`
- 产品类型：Skill
- 所属业务板块：01 招生营销中心
- 作者/维护方：广州金励泽科技服务有限公司
- 研发版本：1.0.0
- 当前状态：**PACKAGE_READY / WorkBuddy未验证**
- 产品规格书：[PRODUCT_SPEC.md](PRODUCT_SPEC.md)
- 使用说明：[USAGE.md](USAGE.md)
- 安装包：[`dist/edu-xiaohongshu-copywriter-v1.0.0.zip`](dist/edu-xiaohongshu-copywriter-v1.0.0.zip)

## 产品功能

小红书标题、正文、封面、标签及互动内容生成。

- 主要输入：课程卖点、目标家长、城市与平台语气、活动信息、可用素材
- 主要输出：多版标题、正文、封面文案、标签、互动提问和发布检查清单

## 本地验证

- 测试案例：[tests/TEST_CASES.md](tests/TEST_CASES.md)
- 结构测试：[tests/validate_package.ps1](tests/validate_package.ps1)
- 测试结果：[test-results/v1.0.0.json](test-results/v1.0.0.json)

本地通过仅证明文件结构、契约和可自动核验的本地逻辑通过；不代表WorkBuddy平台解析、安装、调用或审核通过。

## 依赖与数据

- 第三方运行依赖：无。
- 默认外部API：无。
- 不要求用户提供API Key。
- 仅处理用户主动提供或明确授权的数据。

## 开源许可证

License: Apache-2.0.

本仓库为免费开放的开源项目。任何人均可依照 Apache License 2.0 使用、修改和分发本项目内容。完整法律条款见 [LICENSE](LICENSE)。
