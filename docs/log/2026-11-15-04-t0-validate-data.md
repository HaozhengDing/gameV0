# 2026-11-15-04 T0 数据校验脚本 + CI 模板

- 日期：2026-11-15
- 作者：DeepSeek
- 类型：更新
- 篇幅：详细
- 触发：用户指令「请做 t0 和 t6」

## 结论

- 新增 tools/validate_data.py：当前仓库全过；故意破坏引用时退出码 1。
- CI workflow 模板放在 tools/ci/validate.yml；因推送凭据没有 workflow scope，尚未放入 .github/workflows/（见「未解决」）。
- 过程中发现并修复一个真实问题：black_dog_blood 以 extends: water 继承 state，校验器必须先解析 extends 链再校验，否则误报。

## 改动

| 文件 | 改了什么 |
|---|---|
| tools/validate_data.py | 新增：材料 / 反应 / magic_numbers / biome / room / 卡片的引用与结构校验；支持传入 root 做破坏性测试 |
| tools/ci/validate.yml | CI workflow 模板（待复制到 .github/workflows/validate.yml） |
| docs/log/README.md | 索引加本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 先做 materials / biome / room 三层引用校验 | 这三层最容易因多 agent 并行改动出现悬空引用（反应 inputs、hazard reaction、房间 rule_id） | 每加一种数据字段，就要同步补校验 |
| 卡片只做最小结构校验（type/id/必填块） | 卡片 schema 还会随设计演进变；先保证可解析与关键字段 | 卡片与数据之间的交叉引用（如符箓元素）暂未校验 |
| 校验器支持传 root 参数 | 破坏性测试不需要改动真实仓库 | 多一个 CLI 约定 |
| CI 只装 pyyaml | 校验器不依赖项目运行时 | 未来若加 JSON Schema 校验需要更新依赖 |
| CI 暂放 tools/ci 模板 | 推送凭据没有 workflow scope，直接推 .github/workflows 会被 GitHub 拒绝 | CI 尚未自动运行，需要一次授权或手动添加 |

## 新增或修改的 deviations

无。

## 未解决 / 待决定

- 把 tools/ci/validate.yml 接入 .github/workflows/validate.yml：需要 workflow scope（用户授权一次 gh auth refresh -s workflow）或网页操作。在此之前，本地/提交前用 python3 tools/validate_data.py 兜底。
- 尚未校验卡片的元素/物质引用与 P0 卡片一致性（留到 T1/T3）。

## 下一步

CI 接入（见上）后看一次成功/失败；然后按计划进入 T2（sim_core）与 T1 草案。
