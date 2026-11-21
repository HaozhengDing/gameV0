# 下落固体（粉末）穿行与分级减速

> 主题：**像素沙盒中松散粉末（煤、硫磺、硝石、沙、石灰、糯米、朱砂）与角色/敌人碰撞时，应按硬固体挡路还是改为可穿行的分级阻力介质**
> 日期：2026-11-21｜状态：**待试验**｜触发：制作人 M1-α 实机试玩反馈 #1（「下落的固体好像太硬了，能挡路，可以找参考做不同程度减速」）
> 关联：`docs/01-decision-twist.md` D1 可读优先 / 物质语义一致；`data/materials.json` 物质密度表；`game/gdextension/src/sim_node.cpp`、`game/scripts/player.gd`、`game/scripts/enemies/enemy_ai.gd`

## 当前选择与理由

**优先试验 `density-drag-wade`（静态硬墙与松散粉末解耦：脚底仍可踩立，水平/空中穿行按粉末重叠占比 × 材质密度分级减速），暂不做实时大规模推沙改写网格。**

理由三条：

1. 本作 `data/materials.json` 的 7 种粉末天然带有清晰的物理密度梯度（糯米 `0.8` → 煤 `1.4` → 硫磺/沙 `2.0` → 硝石 `2.1` → 石灰 `3.3` → 朱砂 `8.1`），直接映射为「轻粉几乎不挡、中粉涉沙减速、重矿粉如陷泥潭」，与现有水/水银液体阻力形成同一套「密度即手感」的 D1 直觉。
2. 现版 `SimWorldNode::is_solid()` 把 `SIM_STATE_POWDER` 与 `SIM_STATE_STATIC` 混为一谈，导致空中零散落粉或超过 3 格的松散煤堆直接像岩壁一样卡死走位，违背松散颗粒的直觉。
3. 相比每帧写网格把沙推开（*Signs of Danger* 式双向物理桥），只读采样阻力零改动 `sim_core` C++、不额外唤醒休眠 chunk、不破坏物质守恒，也不会把硫磺意外推进火源引爆。

---

## 症状

- 矿井里煤/硫磺/硝石坡或塌落下来的零散粉末颗粒经常直接把玩家挡停，触感与岩石墙几乎没有区分。
- 玩家希望下落固体不要这么「硬」，而是像涉过不同厚重度的粉堆一样产生**不同程度减速**。

## 现版基线

| 环节 | 现状 | 位置 |
|---|---|---|
| 固体判定 | `is_solid()` 返回 `state == SIM_STATE_STATIC \|\| state == SIM_STATE_POWDER`，粉末等同岩壁 | `game/gdextension/src/sim_node.cpp:318-331` |
| 玩家阻挡 | `_blocked_count()` 调 `is_solid()`；仅 1–3 格矮坡靠 `STEP_UP_MAX` 自动迈步；仅已被埋时才靠 `_hard_blocked_at()`（只看 `state==4`）放行脱困 | `game/scripts/player.gd:110-144, 265-312` |
| 液体阻力 | `_sample_liquid()` 仅一档 `0.72×` 水平减速 + 水银浮力 | `game/scripts/player.gd:146-165, 208` |
| 敌人碰撞 | `_box_blocked()` 同样直接调 `sim.is_solid()`，易被小粉堆卡住 | `game/scripts/enemies/enemy_ai.gd:432-445` |
| 材质密度 | `glutinous_rice=0.8`、`coal=1.4`、`sand/sulfur=2.0`、`saltpeter=2.1`、`lime=3.3`、`cinnabar=8.1` | `data/materials.json`、`sim_core/src/materials.cpp:144-156` |

## 约束

- **D1 可读优先**：脚底仍需能踩在平缓粉坡上（不让人像踩空气一样漏进粉底）；减速差异要能让玩家一眼/一手感到「朱砂/石灰沉、煤/糯米松」。
- **性能与守恒**：不突破 C-SIM 6 ms/tick 预算，不凭空删格破坏 `sim_conservation` 测试；M1 不引入 Box2D 刚体网格转换（`docs/04-m1-plan.md` §1.1 明确 M2 之前不做像素刚体碎裂）。

---

## 候选比较

### density-drag-wade

**静态硬墙与松散粉末解耦：水平/穿行仅受静态固体（岩/竹木）硬阻挡，粉末改为按「重叠占比 × 材质密度档」分级减速，脚底承托保留可站立。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 玩家移动时：① 硬碰撞只检查 `SIM_STATE_STATIC`（岩、竹木）；② 接地承托（脚下 `y+1` 一行）仍承认静止粉末，保证站在粉堆顶不漏穿（按住 `S` 可主动下沉穿入）；③ 采样身体碰撞盒内重叠粉末的占比 `fill`（0..1）与加权平均密度 `avg_d`：若 `fill < 0.12`（零散飞粉）不减速；否则水平与上升速度乘 `clamp(1.0 - drag_factor(avg_d) * fill, min_mult, 1.0)`。假设试验档位：轻粉 `d ≤ 1.5`（糯米/煤）最低 `0.75×`、中粉 `1.5 < d ≤ 2.5`（沙/硫/硝）最低 `0.55×`、重粉 `d > 2.5`（石灰/朱砂）最低 `0.35×` |
| 证据与边界 | **S1**（Minecraft Parkour Wiki `Soulsand` 代码拆解，已发行实装）：验证了「按体素重叠逐 tick 施加水平速度乘数（`motionX *= 0.4`）+ 轻微沉陷」就能制造清晰可辨的阻力地形，无需复杂刚体解算；**S2**（Minecraft `Powder Snow` 机制线索，搜索摘要，原文待核实）：展示了「松散粉体允许穿入下陷 + 大幅减速」与实心方块的体验差异。两者均为体素方块而非像素自动机，把「单格判定」改为「5×10 盒占比采样 + 密度分档」属于**本作推断**，需实机验证深堆穿行是否显得"穿模" |
| 本作映射 | **部分已有**：`player.gd` 已有 `_hard_blocked_at()`（只判 `state==4`）与 `_sample_liquid()`，且 `SimWorldNode` 已暴露 `get_material_state()`；**缺失**：`SimWorldNode.get_material_density(mat_id)`（1 行胶水或在 GDScript 按材质名缓存 `data/materials.json` 密度表）与粉末占比采样函数。敌人 `enemy_ai.gd` 也可共享同一套软阻挡逻辑 |
| 代价与依赖 | 程序低（约 40–60 行 GDScript，零改 `sim_core` C++，若用 `data/materials.json` 缓存密度连 GDExtension 都无需重编）；美术/音频 0（后续可补涉沙脚步声）；系统影响低，无新契约；风险是玩家可能利用「横向穿厚煤堆」抄近路，但矿井主结构均为静态 `rock`，不破坏连通与关卡边界 |
| 最小验证 | 在固定 seed `20261121` 瓦斯囊（煤+硫+硝）与撒一滩朱砂/糯米的测试室，A 用现版，B 切 `density-drag-wade`：测① 空中落粉不再卡停；② 走过糯米 / 煤 / 硫磺 / 朱砂四堆的通过时间呈明显递增阶梯；③ 站在煤堆顶静止时不漏穿。若出现「像在固体里穿墙」的违和感或踩不住粉坡，退回或叠加轻微拨粉效果 |

### push-displace-sweep

**角色穿行松散粉末时主动将碰撞盒前方的粉末格向左右上方空位排开/抛起，并按排开格数与密度施加反向阻力。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 玩家进入粉堆时，每物理帧扫描碰撞盒内重叠的 `SIM_STATE_POWDER` 格，搜索邻近空位将颗粒搬移（类似铲雪/涉沙拨开颗粒），同时按本帧排开的颗粒总质量削减角色速度；若周围无空位可排（彻底被活埋）才退化为强阻力或硬阻挡 |
| 证据与边界 | **S3**（Slow Rush Games *Signs of Danger* 开发日志《Bridging Physics Worlds》2024-02-02，原文已读）：说明了像素物理与实体碰撞桥接的核心痛点——直接用 AABB 逐像素写回网格会带来性能压力，作者称力与推沙交互留待后续独立解决；**S4**（Noita GDC 2019 笔记，二手笔记）：Noita 采用 Marching Squares + 刚体与 `unstuck` 应急清格，而非每帧把全量沙粒做质量守恒推挤。本方案把推挤限制在玩家 `5×10` 小盒内，在 `sim_core` 层面**技术可行**，但无独立实测帧开销证据 |
| 本作映射 | **缺失**：需在 `sim_core` C++ 或 GDExtension 新增 `displace_powder_box()` 接口（并保证质量守恒、不把粉塞进静态墙）；会频繁调用 `touch()` 唤醒周围 chunk |
| 代价与依赖 | 程序中（需改 `sim_core` + 重编 GDExtension + 补守恒单测）；性能有持续唤醒 chunk 的风险；玩法副作用风险高——玩家走过瓦斯囊可能把硫磺推向火苗意外引爆，或把少量朱砂推散难拾取 |
| 最小验证 | 仅当 `density-drag-wade` 实机被评「视觉上太像穿模、缺乏实体感」时再做：A=`density-drag-wade`，B=只把头顶/脚边最外圈 3–5 粒粉向上轻弹（不重排整堆），同时对比 `sim_bench` 帧耗与手感 |

### keep-hard-with-unstuck

**基线变体：保持粉末为硬固体，仅提高 `STEP_UP_MAX`（3 → 5）并借鉴 Noita 强化连按方向键清格脱困。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 延续 `is_solid()` 把粉末算作硬地形，依靠更高自动迈步翻过小坡，卡死时靠左右+起跳清除重叠颗粒 |
| 证据与边界 | **S4 / S5**（Noita GDC 2019 笔记与玩家社区 `unstuck` 实操记录，已发行实装）：Noita 确实把沙/雪默认当硬固体、靠 `unstuck` 兜底，但社区长期存在「单像素卡脚/被碎沙卡死」的负面吐槽（反例证据） |
| 本作映射 | 现状本身（`player.gd` 已有 `STEP_UP_MAX=3` 与 `_hard_blocked_at()` 脱困） |
| 代价与依赖 | 程序极低，但直接违背制作人「下落固体太硬、想要不同程度减速」的明确手感目标 |
| 最小验证 | 仅作 `density-drag-wade` 的 A/B 对照基线 |

---

## 条件化优先顺序

1. **先试 `density-drag-wade`**（1 天内可落，纯 GDScript，零改 C++，用开关 `powder_wade_enabled` 直接 A/B）。
2. 若实机手感顺畅但视觉觉得「人穿进粉里不够自然」，在表现层加极轻量的**涉粉扬尘粒子**（复用 M1-10 `fx_layer`，按所踩粉末取色），而不是立刻改 C++ 做大规模推沙。
3. 仅当玩家明确要求「能物理推倒粉堆」时，才立项 `push-displace-sweep`。

## 待证项

- 站在松散粉坡顶（脚底承托）与横向穿入粉堆之间的过渡边界：会不会在走下斜坡时偶尔误触发「踩空/卡滞」，需要实机连续走煤堆与硫磺堆验证。
- 敌人（矿鬼/土蝼/旱魃）是否应与玩家共享同套粉末减速：若共享，玩家撒朱砂/石灰粉就能临时滞留追兵（潜在正向玩法），待试验时一并观察。

---

## 来源表

| 编号 | 作品 / 作者 | 平台 | 原链接 | 日期 / 版本 | 实际读取范围 | 成熟度 |
|---|---|---|---|---|---|---|
| S1 | Minecraft Parkour Wiki · `Soulsand` 移动阻力拆解 | mcpk.wiki | https://www.mcpk.wiki/wiki/Soulsand | 持续维护（含 1.15 改动） | 全文正文（约 2.9 k 字符），含 `Entity.doBlockCollisions()` 与 `BlockSoulSand.onEntityCollidedWithBlock()` 简化代码（每 tick `motionX *= 0.4`）与 0.875b 沉陷数据 | 已发行实装（机制拆解） |
| S2 | Minecraft `Powder Snow` 细雪下陷与减速机制 | minecraft.wiki / minecraft.net | https://minecraft.wiki/w/Powder_Snow | 检索于 2026-11-21 | 仅搜索摘要（页面 HTTP 403 未直读正文）：允许实体穿入下陷并大幅减速，皮革靴可踏面行走 | 经验线索（原文待核实） |
| S3 | Slow Rush Games · *Signs of Danger* 开发日志《Bridging Physics Worlds》 | slowrush.dev | https://www.slowrush.dev/news/bridging-physics-worlds/ | 2024-02-02 | 正文核心段（约 5.5 k 字符）：像素网格与刚体互相占位、AABB 逐像素写入开销及 Marching Squares 轮廓导出 | 可复现演示（开发者原文） |
| S4 | Petri Purho（Nolla Games）· GDC 2019《Exploring the Tech and Design of Noita》笔记 | braindump.jethro.dev | https://braindump.jethro.dev/posts/gdc_vault_exploring_the_tech_and_design_of_noita/ | GDC 2019（笔记页） | 全文笔记（529 字符）：64×64 chunk 脏矩形、falling sand 与 Marching Squares 刚体；原视频未逐帧回看 | 二手笔记（已发行作品） |
| S5 | Noita 社区 `unstuck` 脱困机制讨论 | Reddit / Steam 社区 | https://www.gamedeveloper.com/design/exploring-the-tech-and-design-of-noita | 检索于 2026-11-21 | 仅搜索摘要（未逐帖核查源码）：Noita 粉末默认硬阻挡，卡死需反复按左右+浮空触发像素清理脱困，存在卡像素负面反馈 | 经验线索（反例） |
