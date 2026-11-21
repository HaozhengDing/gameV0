# 2026-11-21-12 M1-α 试玩三项反馈调研：粉末分级减速、旱魃 BOSS AI 与浮空条收敛方案卡

- 日期：2026-11-21
- 作者：Antigravity（按 `game-decision-research` skill 执行）
- 类型：建议 + 评审（未改玩法代码，仅落方案卡与最小试验设计）
- 篇幅：详细
- 触发：制作人完成 M1-α 实机试玩后给出 3 条改进点（下落固体太硬挡路 / BOSS 逻辑蠢且机动略低 / 人物机动仍偏高、漂浮偏长并提议下落慢充；小怪体验已确认不错）

## 结论

针对 M1-α 试玩 3 条症状完成中英跨平台取证（Game Developer、indienova、Slow Rush 开发日志、Minecraft Parkour Wiki 源码拆解与 Noita 组件参数资料），新增 **3 张独立决策卡**，全部可在 1–2 天内单变量落地并附带自动化防回归断言：

| # | 反馈症状 | 首选方案（锚点） | 关键权衡 | 决策卡 |
|---|---|---|---|---|
| 1 | 下落的固体太硬、能挡路，想按不同程度减速 | **`density-drag-wade`**（静态硬墙与松散粉末解耦：脚底仍可踩立，水平/空中穿行按重叠占比 × `materials.json` 密度分 3 档减速，零散飞粉不减速） | 零改 `sim_core` C++、不破坏守恒且不把硫磺推进火里；若深埋穿粉略显纸片，后期加涉粉扬尘粒子补足，暂不做实时大规模推沙 | [powder-traversal.md](../../refs/cards/decisions/powder-traversal.md) |
| 2 | 旱魃 BOSS 逻辑蠢、机动性略低 | **`utility-spatial-reposition`**（按距离/高度分桶加权选招 + 禁连续复读 + 主动跃上竹台/烈焰滑步/贴脸震退 + 湿破甲 0.55 s 嘶鸣受挫后跃离水洼）+ P2 猛扑引燃竹台（绝不挖岩坝） | 保留清晰 0.32–0.45 s 分色前摇与 0.55 s 喘息窗，避免「加快数值变赖皮」；只读玩家位置/速度不读按键 | [boss-ai-mobility.md](../../refs/cards/decisions/boss-ai-mobility.md) |
| 3 | 人物机动性还是高、漂浮偏长；提议下落时低速回复漂浮条 | **`shorter-hover-plus-fall-regen`**（连续浮空 `1.92 s → ~1.16 s`、`HOVER_MAX_UP -96 → -76`、`MOVE_SPEED 68 → 60`，并参照 Noita `flying_in_air_wait_frames` + `fly_recharge_spd` 加入 `vy > 24` 且停推 `0.28 s` 后 `16/s` 下落慢充） | 严格印证制作人直觉并给足数学防线（`16/86 < 1/5` + 延迟），长坠落末尾可轻刹、绝不产生点按无限飞；同步保证单管气仍能爬升 ~88 格出 80 格水银池 | [player-levitation-tuning.md](../../refs/cards/decisions/player-levitation-tuning.md) |

---

## 改动清单

| 文件 | 改动 |
|---|---|
| `refs/cards/decisions/powder-traversal.md` | 新增决策卡：粉末分级减速（3 候选 + 现版基线 + 密度档位假设 + 5 条来源） |
| `refs/cards/decisions/boss-ai-mobility.md` | 新增决策卡：旱魃 BOSS 空间效用 AI 与机动性（3 候选 + 场地/湿破甲对话机制 + 5 条来源） |
| `refs/cards/decisions/player-levitation-tuning.md` | 新增决策卡：人物机动性与浮空条收敛 + 下落慢充（3 候选 + Noita 双速率印证 + 防无限飞数学核验 + 3 条来源） |
| `refs/cards/decisions/README.md` | 索引表新增上述 3 张决策卡 |
| `docs/log/README.md` | 顶部新增本篇日志索引 |

---

## 若采纳实施：M1-α 体验打磨包（输入 / 输出 / 依赖）

- **输入**：上述 3 张决策卡、`data/materials.json`（密度表）、`data/entities/layer01.json`、`game/scripts/{player.gd,enemies/enemy_ai.gd,main.gd}`。
- **输出**：
  1. `player.gd`：粉末密度分级穿行阻力（含 `powder_wade_enabled` 开关）+ 浮空条收敛与下落慢充（`LEVITATE_AIR_REGEN` 可一键置 `0` 做 A/B）；
  2. `enemy_ai.gd` / `data/entities/layer01.json`：旱魃空间效用选招、跃台/滑步/贴脸震退、湿破甲受挫脱困与 P2 烧竹台；
  3. `--t4b-smoke` 增补 3 条自动断言（轻/重粉速度阶梯、单气爬 ≥80 格 + 180 帧点按防无限飞、旱魃追高台与湿破甲跃离水洼）。
- **依赖类型**：**硬** 依赖 M1-06 现状（已完成）；**软** 依赖 M1-10 反馈层（后续可补涉粉粒子）；**决策** 依赖制作人确认 3 张卡的首选方向与是否一起实施。

---

## 待证与开放问题

1. **粉末穿行是否同步给小怪**：如果小怪也吃重粉（朱砂/石灰）减速，玩家撒粉即可滞敌；或者只让玩家穿粉、小怪保持现版？
2. **浮空条下落慢充**：是否直接把 `shorter-hover-plus-fall-regen`（`1.16 s` + 延迟下落慢充 `16/s`）与三项一起打包实施，试玩时如想对比纯落地回充再把 `LEVITATE_AIR_REGEN` 置 `0`？
3. **验证覆盖说明**：本次检索中 `noita.wiki.gg` / `minecraft.wiki`（HTTP 403）与 Steam 指南（HTTP 429）仅读到搜索摘要，已在对应来源表如实标出「仅搜索摘要 / 待核实」；Slow Rush 开发日志、Game Developer（Mike Stout 两篇）、indienova（黑魂 BOSS 设计与状态机实战）、Minecraft Parkour Wiki（Soulsand 源码拆解）均已直读正文。

## 下一步

待制作人确认三项首选方向（例如「全按首选一起实施」或调整任一细节）后，直接落地 M1-α 打磨包并重跑全量自动化验证与实机复测，随后推进 **M1-07（洞天三选一与商店经济）**。
