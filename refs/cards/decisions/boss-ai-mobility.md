# 2D 动作沙盒 BOSS AI 与机动性（旱魃）

> 主题：**矿底一层 BOSS「旱魃」如何摆脱死板轮换与笨重移动，在不破坏 D1 可读性的前提下形成有空间博弈、机动压迫与元素对话感的 BOSS 战**
> 日期：2026-11-21｜状态：**已试验（M1-α 已落地，待制作人实机定型）**｜触发：制作人 M1-α 实机试玩反馈 #2（「boss 逻辑有点蠢，机动性略低，可以尝试找参考；小怪不错」）
> 实装与试验结果：`game/scripts/enemies/enemy_ai.gd` + `data/entities/layer01.json`（开关 `boss_smart_ai`）；`--t4b-smoke` 第 17c 步通过：`boss_smart=ok`（高台玩家反制 + 湿破甲 0.55s 硬直 + 跃离水洼 + P2 引燃竹台不挖岩坝）。
> 关联：`docs/01-decision-twist.md` D1 可读优先；`data/entities/layer01.json`、`data/rooms/room-boss-coalmine.json`、`game/scripts/enemies/enemy_ai.gd`

## 当前选择与理由

**优先试验 `utility-spatial-reposition`（距离/高度分桶效用选招 + 主动立体位移/跃台 + 泼水破甲状态响应），并在二阶段叠加极轻量的 `sandbox-terrain-breaker` 切片（仅猛扑可引燃接触的竹木平台，绝不破坏岩坝与外墙）。**

理由三条：

1. 旱魃显得「蠢」的根因不是招式太少，而是现版 `_execute_boss_attack` 用固定取模 `(attack_pattern + 1) % N` 无脑循环，完全不看玩家是贴脸、站竹木高台还是躲水坝后，且被泼水破甲后没有任何应对反应。
2. 旱魃「机动性略低」的根因是它只有单一地面平移（`chase_speed = 42`，比玩家 `68` 慢近 40%）和偶发一次直线猛扑；没有**战术后撤/跨场位移/跃上竹木台**的立体追击手段，导致玩家站在竹木高台或风筝拉开即可轻松戏耍。
3. 业界成熟 2D 动作 BOSS（魂系随机模式、*Dead Cells* 反远程风筝、Mike Stout 的「技能检验 + 节奏呼吸」）一致强调：**有限状态机执行 + 空间条件加权选招 + 攻防节奏空窗**，代码量可控（~120 行 GDScript），且完全保留可读前摇。

---

## 症状

- 实机试玩中，普通小怪（矿鬼/土蝼/硫烟鬼火/画皮）节奏与手感得到认可（「小怪不错」），但矿底旱魃显得**逻辑死板、机动偏低**：
  - 玩家站到竹木高台后，旱魃多半在下面傻走或打空地面招；
  - 招式严格 0 → 1 → 2 循环，容易一眼看穿并站桩绕背；
  - 被水泼到（`wet` 破甲）后既无受挫反馈也不懂跃离水洼。

## 现版基线

| 环节 | 现状 | 位置 |
|---|---|---|
| 选招逻辑 | 严格 `attack_pattern = (attack_pattern + 1) % (3 if p2 else 2)` 固定循环，无视距离与高低差 | `game/scripts/enemies/enemy_ai.gd:272-274` |
| 机动能力 | `chase_speed = 42`（玩家 `68`），仅招式 B 有一次跳扑 `lunge_speed = 124, vy = -88`；遇高台不会主动跃上，无贴脸撤步/突进 | `data/entities/layer01.json:134-156`、`enemy_ai.gd:227-231` |
| 场地结构 | `room-boss-coalmine` 宽 384×高 224 cells，含左右两座竹木高台、左下岩坝水池、右上阴气区 | `data/rooms/room-boss-coalmine.json:21-35` |
| 元素互动 | 火抗 `0.25×`、弱水/阴 `2×`、沾水产蒸汽 + `wet` 破甲 `1.4×`；AI 层尚未对 `wet` 做出反应 | `game/scripts/combat/combat_entity.gd:139-142, 326-331` |

## 约束

- **D1 可读优先**：机动性提高绝不等于瞬移乱闪或零前摇偷袭；每次突进、跃台、贴脸震退都必须保留 0.30–0.45 s 差异化色圈前摇，每次强攻后保留 0.50–0.70 s 可惩罚后摇（Mike Stout「问玩家一个清晰的问题，然后给答题时间」）。
- **沙盒防软锁**：BOSS 任何位移/破地形不得撞破左下岩坝（否则自动淹死自己）或穿出房间外墙。
- **范围控制**：M1 灰盒不引入复杂行为树框架，复用现有 `enemy_ai.gd` 有限状态机，只升级旱魃的决策器与位移状态。

---

## 候选比较

### utility-spatial-reposition

**用「距离 + 高度分桶效用打分（禁连续复读）」替换固定循环，新增主动跃台/冲刺重定位状态，并加入「湿破甲受挫 → 跃离水洼」的环境响应。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 保留 FSM 执行骨架，仅在旱魃决策点按 `(dx, dy, wet, last_move)` 计算各招权重并加权随机（上次用过的招权重 ×0.25 避免复读）：<br>① **高台反制（玩家高出 >24 格）**：优先**腾跃上台**（精准抛物线跳向玩家所在竹台/空中位置，落地带小范围炽焰冲击）或**对空斜扇火弹**；<br>② **贴脸反制（距离 <42 格）**：优先**炽浪震退 + 后跃拉距**（0.32 s 亮黄前摇 → 贴身火环击退玩家，同时旱魃向空旷侧大跳拉开），防止贴脸白嫖；<br>③ **中远距压迫（距离 >95 格）**：优先**烈焰滑步突进**（地面高速冲刺 0.35 s 留一路短命火痕，瞬间拉近半屏，随后视距离接火弹或收招喘息）或**带轻微速度提前量的扇形火弹**；<br>④ **战术重定位**：每连放 2 招后插入一次有方向的快速走位/侧跃（绝不原地罚站），再留 0.55 s 喘息窗供玩家反击/取水；<br>⑤ **环境对话（湿破甲反应）**：首次进入 `wet` 时给 **0.55 s 嘶鸣受挫硬直**（明确奖励玩家泼水！），硬直结束若脚下仍有水，立刻触发**脱困大跳**跃向干地或竹台，形成「泼水破甲 → 抓硬直输出 → 旱魃跳台反扑」的动态回合 |
| 证据与边界 | **S1**（Josh Bycer / GWB 译文《不止受苦！〈黑暗之魂〉如何重新定义了 BOSS 战？》，全文已读）：明确指出老式固定模式容易被一眼看穿，现代动作 BOSS 的分水岭是「围绕距离与已用招式动态调用至少 3–5 种模式的随机模式设计」；**S2**（Mike Stout《Boss Battle Design and Structure》与《Enemy Attacks and Telegraphing》，Game Developer 原文核心段已读）：强调 BOSS 是对玩家既有技能（本作即移动、浮空、葫芦取水、符箓切杖）的考试，且每次攻击必须有「明确前摇 → 行动 → 可反击后摇」的节奏呼吸；**S3**（indienova《给猫看的游戏 AI 实战（三）》，全文已读）：印证「有限状态机 + 条件过滤可能性图」足以支撑敏捷的战术决策，无需重型行为树；**S4**（*Dead Cells* 开发访谈摘要，仅搜索摘要）：Motion Twin 在 EA 期间正是因玩家远程风筝过强，才为 BOSS 补强突进拉近与反被动机制。将「湿破甲硬直 + 跃离水洼」融入此架构属于**本作推断**，需实机验证节奏是否过紧 |
| 本作映射 | **已有**：`enemy_ai.gd` 的 FSM、前摇预警色圈、`combat_entity.gd` 的 `wet` 状态与 `phase` 字段；**缺失**：旱魃专用的 4 项加权选招函数、抛物线跃台/滑步突进子状态、以及 `wet` 首次触发受挫计时器 |
| 代价与依赖 | 程序中低（~120 行集中于 `game/scripts/enemies/enemy_ai.gd` + `data/entities/layer01.json` 补少量速度/权重参数）；美术/音频 0（靠现有前摇圈分色 + 现有粒子/音效）；无新契约；风险是若提前量过准或后摇太短会显得"读指令"，必须按 S3 原则只读玩家位置与当前速度（绝不读按键）并保留强制喘息窗 |
| 最小验证 | 用 `--t4b-boss-shot` 同款 `room-boss-coalmine` 实机打 3 局（分别用「站竹台风筝」「贴脸硬拼」「葫芦泼水/掘坝放水」三种打法），A=现版，B=`utility-spatial-reposition`。通过标准：① 站竹台 5 秒内旱魃必追台或封空；② 泼水后能肉眼读出破甲受挫 + 旱魃跳离水洼；③ 无卡墙/出界，制作人体感"像在跟活物过招"且不觉得赖皮。回退：单开关 `boss_smart_ai = false` 退回原版 |

### sandbox-terrain-breaker

**参考 Noita BOSS 的地形破坏光环，赋予旱魃在冲刺/重砸时烧毁竹木平台与撞散粉堆的能力。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 旱魃二阶段（≤50% HP）猛扑落点或滑步路径自动点燃/破坏接触到的 `bamboo` 与松散粉堆，使竹木高台不再是永久安全屋，并把战场改造成燃烧炭坑 |
| 证据与边界 | **S5**（Noita `Kolmisilmä` / `Ylialkemisti` 社区资料，仅搜索摘要，原 wiki HTTP 403 未直读）：Noita 的核心 BOSS 通过自带地形清除光环避免被可破坏地形卡死或被玩家挖坑困死。但在本作 BOSS 房中，水坝与竹台承担教学与立体战术作用，全量清除光环会直接摧毁左下岩坝导致 BOSS 自淹，属于需要强裁剪的反例边界 |
| 本作映射 | **已有**：`sim.apply_heat_burst()` 已能在落地时引燃 `bamboo`（C-SIM v3 `r-bamboo-burn` 自动烧成煤粉与烟！） |
| 代价与依赖 | 程序极低（仅需在猛扑落点放大 `apply_heat_burst` 半径，不调用 `sim.dig` 挖岩，天然保护左下岩坝与外墙！）；风险是二阶段竹台烧光后房间变平，因此应只作为 `utility-spatial-reposition` 的 P2 附属风味，不可单独替代 AI 升级 |
| 最小验证 | 作为 `utility-spatial-reposition` 二阶段的附加观察项：验证竹木台会被旱魃猛扑点燃成炭，但左下 `rock` 岩坝完好无损 |

### speed-numbers-only

**保守方案：保持 0→1→2 固定轮换，仅把 `chase_speed` 从 42 提到 64、冷却从 78 降到 52。**

| 维度 | 内容 |
|---|---|
| 做法与适用场景 | 纯改 `data/entities/layer01.json` 数值加速 |
| 证据与边界 | 反例参考 S1（固定模式即便加快速度仍可被背板套路，且容易因压缩前摇/后摇变"赖皮"而非"聪明"） |
| 本作映射 | 改 2 行 JSON |
| 代价与依赖 | 几乎零成本，但无法解决「不追高台、招式死板、站水里傻站」三大症结 |
| 最小验证 | 仅作对比参考，不推荐单独采纳 |

---

## 条件化优先顺序

1. **先落 `utility-spatial-reposition`**（优先解决「蠢、不会利用高台、不回应泼水、机动偏低」），同步把 `chase_speed` 从 `42` 微调到 `52`（配合滑步突进与跃台，无需靠超高速走路追人）。
2. 在二阶段（≤50% HP）顺带加入**克制版 `sandbox-terrain-breaker`**：猛扑落点用 `apply_heat_burst`（不挖 `rock`）引燃竹木平台，既保留左下岩坝玩法又把二阶段战场打活。
3. 自动化回归同步进 `--t4b-smoke` 第 15 步：断言玩家站高台时旱魃会选择跃台/对空招，泼水触发 `wet` 后能跳离水区。

## 待证项

- 旱魃跃上竹木高台的起跳初速与落点精度：需实机验证不同水平距离下是否能稳定落台而不频繁撞顶回弹。
- 贴脸震退 + 滑步突进上线后，配合下一张卡（人物机动性下调）的整体难度曲线是否过难——两项一起调参时务必预留 0.55 s 以上明确喘息窗。

---

## 来源表

| 编号 | 作品 / 作者 | 平台 | 原链接 | 日期 / 版本 | 实际读取范围 | 成熟度 |
|---|---|---|---|---|---|---|
| S1 | Josh Bycer（GWB 编译）·《不止受苦！〈黑暗之魂〉如何重新定义了 BOSS 战？》 | indienova（首发 Game Developer） | https://indienova.com/indie-game-development/the-impact-of-dark-souls-on-boss-design/ | 原文首发 Game Developer | 全文核心章节（一、二、三节，约 3.7 k 字符）：随机模式设计、按距离与已用招式选招、多招式变化迫使玩家持续适应 | 行业复盘（已发行多作归纳） |
| S2 | Mike Stout（前 Insomniac / Activision 设计师）·《Boss Battle Design and Structure》&《Enemy Attacks and Telegraphing》 | Game Developer | https://www.gamedeveloper.com/design/boss-battle-design-and-structure / https://www.gamedeveloper.com/design/enemy-attacks-and-telegraphing | 2010-09-15 / 2015-09-02 | 两篇核心设计段（各约 4 k 字符）：BOSS 作为玩家技能综合测试与叙事节拍、攻击「前摇告知问题 → 判定 → 可惩罚后摇」结构 | 开发者原文（已发行实装） |
| S3 | indienova ·《给猫看的游戏 AI 实战（三）：基于状态机的 AI 系统》 | indienova | https://indienova.com/indie-game-development/ai-practical-ability-03/ | 专栏正文 | 正文前段（约 2.6 k 字符）：FSM + 可能性图按情境过滤可行行为，避免无效动作 | 工程实践教程 |
| S4 | Motion Twin / Sébastien Bénard · *Dead Cells* BOSS 迭代与反风筝访谈 | Game Developer / Rock Paper Shotgun | https://www.gamedeveloper.com/design/building-the-level-design-of-a-procedurally-generated-metroidvania-a-hybrid-approach- | 检索于 2026-11-21 | 仅搜索摘要（原文正文未完整抓读）：EA 期间针对远程风筝为 BOSS 强化突进拉近与清晰前摇 | 经验线索（原文待核实） |
| S5 | Noita BOSS（`Kolmisilmä` / `Ylialkemisti`）地形破坏与追击机制 | noita.wiki.gg / 社区资料 | https://noita.wiki.gg/wiki/Kolmisilm%C3%A4 | 检索于 2026-11-21 | 仅搜索摘要（wiki 页面 HTTP 403 未直读）：BOSS 通过地形清除光环防像素地形卡死 | 经验线索（原文待核实） |
