# docs/log — 建议与更新记录

> 规则见 [AGENTS.md](../../AGENTS.md) §2：**每次给出建议或更新仓库，都要在这里落一篇 md**，并与相关改动放在同一个 commit 里。
> 文件名：`YYYY-MM-DD-NN-slug.md`（`NN` 为当天序号）。新条目加在索引表最上方。

## 索引

| 日期 | 文件 | 类型 | 篇幅 | 一句话 |
|---|---|---|---|---|
| 2026-11-20 | [2026-11-20-04-t4b-physics-and-naming.md](2026-11-20-04-t4b-physics-and-naming.md) | 更新 | 详细 | T4b 落地 Noita 式重力/迈步/浮空物理移动、彩色条极简 HUD，并同步道教符语保留+克制单字命名规范 |
| 2026-11-20 | [2026-11-20-03-t4b-playtest-feedback.md](2026-11-20-03-t4b-playtest-feedback.md) | 评审 + 建议 | 详细 | T4b 首次实机试玩反馈：Noita 式重力+浮空移动方案 & 去中二/极简命名与 HUD 方案对比 |
| 2026-11-20 | [2026-11-20-02-t4b-graybox-polish.md](2026-11-20-02-t4b-graybox-polish.md) | 更新 | 详细 | T4b 灰盒打磨：火焰灰盒补丁（1.5%/tick 蔓延 + F 手动点火）、5 项 bugfix、移动/HUD/准星手感调参 |
| 2026-11-20 | [2026-11-20-01-handoff-prompt.md](2026-11-20-01-handoff-prompt.md) | 建议 | 摘要 | 交接提示词（2026-11-20）：状态快照、工作规则、四个可交办工作包 |
| 2026-11-17 | [2026-11-17-01-fire-heat-noita-minecraft.md](2026-11-17-01-fire-heat-noita-minecraft.md) | 建议 | 详细 | 火焰/热：Noita 材料化 vs 我的世界方块老化；借鉴方案与 M1-12 排期（M0 不扩） |
| 2026-11-16 | [2026-11-16-04-t4b-graybox.md](2026-11-16-04-t4b-graybox.md) | 更新 | 详细 | T4b 可玩灰盒：C-SIM v2、正式符卡数据、VM 接入；t4b-smoke 通过（化水→取水→灭火→通关） |
| 2026-11-16 | [2026-11-16-03-t4a-godot-gdextension.md](2026-11-16-03-t4a-godot-gdextension.md) | 更新 | 详细 | T4a：Godot 4.5 + GDExtension 构建链跑通（真 sim_core 接入），一键构建 + headless 自检通过 |
| 2026-11-16 | [2026-11-16-02-vm-spec-decisions-final.md](2026-11-16-02-vm-spec-decisions-final.md) | 决策 | 详细 | T1 六条决策全部按 AI 建议拍板；C-VM/C-ACT v0.1 进入契约冻结候选 |
| 2026-11-16 | [2026-11-16-01-possession-scope-and-vm-decisions.md](2026-11-16-01-possession-scope-and-vm-decisions.md) | 决策 | 详细 | 入魔效果清单后移 M1 计划；不做角色机制分化（表现层先做）；VM 第 3 条定「整句不念」 |
| 2026-11-15 | [2026-11-15-11-noita-vm-reference.md](2026-11-15-11-noita-vm-reference.md) | 建议 | 详细 | Noita 参考：触发预付费/逐符部分施法/递归上限 2/Add Mana 负消耗；6 条拍板的对照建议 |
| 2026-11-15 | [2026-11-15-10-t3-vm-impl.md](2026-11-15-10-t3-vm-impl.md) | 更新 | 详细 | T3 参考符箓 VM：ctest 7/7、契约用例 30/30 + 5 条边界回归；复审修 5 个实现问题 |
| 2026-11-15 | [2026-11-15-09-t1-vm-spec.md](2026-11-15-09-t1-vm-spec.md) | 建议 + 更新 | 详细 | T1 符箓 VM 形式规格草案 + 30 条用例（待用户审定，6 条待拍板） |
| 2026-11-15 | [2026-11-15-08-t2-sim-core.md](2026-11-15-08-t2-sim-core.md) | 更新 | 详细 | T2 sim_core 原型 + 开发机基准（worst p95 2.25ms / typical 0.15ms，非 go-no-go 依据） |
| 2026-11-15 | [2026-11-15-08-scale-narrative-leap-wand.md](2026-11-15-08-scale-narrative-leap-wand.md) | 建议 | 详细 | 方向确认：规模长线做、叙事借 Noita、跃迁魔杖参考；彩蛋暂缓 |
| 2026-11-15 | [2026-11-15-07-integrate-roadmap-bundle.md](2026-11-15-07-integrate-roadmap-bundle.md) | 更新 | 详细 | 整合 7b0ea7e 路线图 03 到当前 main，保留 T0/T6/CI |
| 2026-11-15 | [2026-11-15-06-ci-workflow.md](2026-11-15-06-ci-workflow.md) | 更新 | 详细 | T0 收尾：接入 GitHub Actions 数据校验 workflow |
| 2026-11-15 | [2026-11-15-05-t6-competitors.md](2026-11-15-05-t6-competitors.md) | 建议 | 详细 | T6：竞品检索；直接竞品未见，最近邻 Cave Alchemist，Magicraft 验证需求 |
| 2026-11-15 | [2026-11-15-04-t0-validate-data.md](2026-11-15-04-t0-validate-data.md) | 更新 | 详细 | T0：数据校验脚本；当前数据全过，引用坏则退出码 1；CI 已接入（见 -06） |
| 2026-11-15 | [2026-11-15-03-roadmap-and-dependencies.md](2026-11-15-03-roadmap-and-dependencies.md) | 建议 + 更新 | 详细 | 路线图五步、借鉴流程、依赖四类与七个契约；T4 拆 T4a / T4b |
| 2026-11-15 | [2026-11-15-03-reprioritize-m0.md](2026-11-15-03-reprioritize-m0.md) | 建议 | 详细 | M0 优先级调整：目标机/试玩/T1 审阅后移，T0→T6→T2 先行 |
| 2026-11-15 | [2026-11-15-02-m0-plan-and-log-rule.md](2026-11-15-02-m0-plan-and-log-rule.md) | 建议 + 更新 | 详细 | M0 七项任务；建立 md 落盘规则与 AGENTS.md |
| 2026-11-15 | [2026-11-15-01-design-convergence.md](2026-11-15-01-design-convergence.md) | 更新 | 详细 | 设计收敛：核心 twist 定为元素沙盒，五行出伤害公式，禁符反噬，入魔可逆，经济线性化 |

## 模板

篇幅判断：

- **摘要**（≤ 30 行）：单一小改动、不涉及新决策、不改数值。只写"元信息 / 结论 / 改动 / 下一步"。
- **详细**：满足任一条即用——新决策或推翻旧决策；改动 ≥ 3 个文件；改了数值或公式；给出任务计划或方案对比；新增或修改了 deviations。

```markdown
# YYYY-MM-DD-NN 标题

- 日期：YYYY-MM-DD
- 作者：人名 / agent 名（如 Claude、DeepSeek）
- 类型：建议 / 更新 / 决策 / 评审
- 篇幅：摘要 / 详细
- 触发：谁提出了什么请求（一句话）

## 结论
一到三句话。

## 改动
| 文件 | 改了什么 |
|---|---|

## 决定与理由（详细篇必填）
每条写清 是什么 / 为什么 / 代价。

## 新增或修改的 deviations（详细篇必填，没有就写"无"）

## 未解决 / 待决定

## 下一步
```
