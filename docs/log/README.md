# docs/log — 建议与更新记录

> 规则见 [AGENTS.md](../../AGENTS.md) §2：**每次给出建议或更新仓库，都要在这里落一篇 md**，并与相关改动放在同一个 commit 里。
> 文件名：`YYYY-MM-DD-NN-slug.md`（`NN` 为当天序号）。新条目加在索引表最上方。

## 索引

| 日期 | 文件 | 类型 | 篇幅 | 一句话 |
|---|---|---|---|---|
| 2026-11-21 | [2026-11-21-12-playtest-alpha-research-cards.md](2026-11-21-12-playtest-alpha-research-cards.md) | 建议 + 评审 | 详细 | 按 game-decision-research 产出 M1-α 试玩三张决策卡：粉末密度分级减速、旱魃空间效用 AI 与机动性、人物浮空收敛与 Noita 式延迟下落慢充 |
| 2026-11-21 | [2026-11-21-11-m1-06-enemies-boss-and-jump-p0.md](2026-11-21-11-m1-06-enemies-boss-and-jump-p0.md) | 更新 + 决策 | 详细 | M1-06 落地（矿井一层 5 种敌人 AI、旱魃两阶段 BOSS 战与泼水破甲、BOSS 血条与掉落）+ 跳跃跟手 P0 + 修复 event_bus 字段透传与 BOSS 房水坝；抵达 M1-α 检查点 |
| 2026-11-21 | [2026-11-21-10-antigravity-decision-skill.md](2026-11-21-10-antigravity-decision-skill.md) | 更新 | 详细 | Antigravity Gemini 与 DeepSeek Harness 从 `.agents/skills/` 加载同一个游戏开发决策调研技能 |
| 2026-11-21 | [2026-11-21-09-review-new-proposals-and-next-order.md](2026-11-21-09-review-new-proposals-and-next-order.md) | 评审 + 建议 | 摘要 | 评审跳跃跟手/环境表现层/打击感三份新文档：建议主攻 M1-06，仅顺手带跳跃 P0，环境表现留 M1-11/M2、打击感保留现版 |
| 2026-11-21 | [2026-11-21-08-game-decision-research-skill.md](2026-11-21-08-game-decision-research-skill.md) | 建议 + 更新 | 详细 | DeepSeek Harness 项目技能，跨平台取证、方案卡与本作 A/B，首例为 M1-10 打击感 |
| 2026-11-21 | [2026-11-21-07-visual-production.md](2026-11-21-07-visual-production.md) | 调研 + 建议 | 详细 | 视觉与动效生产路线：把"审美复刻"视频拆成决策卡（3 候选 + 5 维比较 + 一周最小验证），推荐程序化最小切片、整屏复刻留 M2 |
| 2026-11-21 | [2026-11-21-06-jump-feel.md](2026-11-21-06-jump-feel.md) | 建议 + 评审 | 详细 | 跳跃跟手：抖音视频（无旁白，逐帧 OCR）6 条"看不见的帮助"对照 player.gd——已有 2 / 半有 1 / 缺 3；另指出轮询吞键是"按了没跳"的第一性来源，并按"机动性偏高"反馈把 6 条拆成增宽容 / 增机动两批 |
| 2026-11-21 | [2026-11-21-05-playtest-physics-fluid-settle-fixes.md](2026-11-21-05-playtest-physics-fluid-settle-fixes.md) | 更新 + 评审 | 详细 | 实机试玩反馈修复：开局 120 tick 全图预沉降与防掩埋校准、液体双向找平与自底向上 chunk 排序、解除火焰实墙与环境 DoT 顿帧阻塞；机动性待 M1-06 实测再定 |
| 2026-11-21 | [2026-11-21-04-m1-10-feedback-juice.md](2026-11-21-04-m1-10-feedback-juice.md) | 更新 + 决策 | 详细 | M1-10 反馈层提前落地：两条抖音参考（射击爽感 / 打击感）并成 8 层，fx + 屏幕 FX + 分层音效 + 反馈导演，含 3 条偏离与 smoke 断言 |
| 2026-11-21 | [2026-11-21-03-m1-04-wang-tile-coalmine.md](2026-11-21-03-m1-04-wang-tile-coalmine.md) | 更新 | 详细 | M1-04 落地：矿井一层 1536×672 完整 Wang Tile 拓扑、3 手工房无缝拼接、旱魃 BOSS 房、5-seed BFS 连通校验、碑文与三大 Hazard |
| 2026-11-21 | [2026-11-21-02-m1-03-wands-and-assembly-ui.md](2026-11-21-02-m1-03-wands-and-assembly-ui.md) | 更新 | 详细 | M1-03 落地：3 把法器数据（桃木剑/铜铃/骨简）、`cast_deck` 真游标/成文与散符接口、洞天安全区极简改符 UI |
| 2026-11-21 | [2026-11-21-01-m1-05-seven-star-lanterns.md](2026-11-21-01-m1-05-seven-star-lanterns.md) | 更新 | 详细 | M1-05 落地：七星灯双轴（100 气血 + 7 盏小数魄灯，每熄 1 盏上限 -1/7）与极简灯格/锁段血条 HUD |
| 2026-11-20 | [2026-11-20-09-m1-02-projectiles-and-combat.md](2026-11-20-09-m1-02-projectiles-and-combat.md) | 更新 | 详细 | M1-02 落地：真实投射物飞行/穿透/触发树、全 16 种 C-ACT 零 NOOP、战斗实体与 8/8 民俗反应全通 |
| 2026-11-20 | [2026-11-20-08-m1-12-csim-v3-reactions.md](2026-11-20-08-m1-12-csim-v3-reactions.md) | 更新 | 详细 | M1-12 落地：C-SIM v3（19 材质/5 格层反应/热火引擎/10k 压测 burn-worst p95 0.82ms）+ GDExtension/EventBus/实体灼烧湿润毒烟状态接入 |
| 2026-11-20 | [2026-11-20-07-m1-plan-final-and-m1-01-frozen.md](2026-11-20-07-m1-plan-final-and-m1-01-frozen.md) | 决策 + 更新 | 详细 | M1 计划 5 项全拍板生效（含完整 Wang Tile）；M1-01（C-EVT/C-TEXT v0.1）冻结并落地词表、CI 机检与运行时骨架 |
| 2026-11-20 | [2026-11-20-06-m1-plan-and-contracts-draft.md](2026-11-20-06-m1-plan-and-contracts-draft.md) | 决策 + 建议 | 详细 | M0 conditional 放行：起草 M1 计划（04-m1-plan）与 M1-01 契约（C-EVT / C-TEXT v0.1 草案） |
| 2026-11-20 | [2026-11-20-05-m0-c-prerun-and-ledger.md](2026-11-20-05-m0-c-prerun-and-ledger.md) | 更新 + 评审 | 详细 | M0 收尾：完成实验 C 7 场景 AI 预演报告骨架（抓出原生水旁路等 4 隐患）与 M0 一页纸评审账本 |
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
