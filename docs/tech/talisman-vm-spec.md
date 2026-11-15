# T1 符箓 VM 形式规格（契约 C-VM / C-ACT / C-CASE）

> **状态：v0.1 已拍板｜契约冻结候选**（2026-11-16 用户拍板：§7.3 全部 6 条按 AI 建议落定，见 §7.3 与附录 B；此前 2026-11-15 补丁为澄清实现边界，语义未改）
> 制定：2026-11-15（AI 起草，DeepSeek）｜审定：用户（T1 审阅后移，见 `docs/02-m0-plan.md` 2026-11-15 优先级调整）
> 依据：`docs/01-decision-twist.md` D3 / D4（实验 B）｜`docs/02-m0-plan.md` T1（8 个必须回答的问题，批注 C06/C09/C46）｜`refs/cards/p0/talismans.yaml` F-0001~F-0004｜`refs/cards/p0/systems.yaml` S-0002 / S-0004（phantom_rules）｜`data/materials.json`｜`data/magic_numbers.json` sanity 段
> 输入给：T3 参考 VM 实现（`sim_core/vm/`）、T4b 世界层执行动作；产出用例 `tests/vm_cases/`（30 条，本文件 §6 定义 schema）
> 不覆盖：神智阈值腐坏的 UI 表现、入魔状态机（M1）、法器程序化生成、洗牌 RNG 算法（调度层，§7.4）

## 0. 结论先行：8 个问题的答案

| # | 问题（批注） | 结论（一行） | 类型 |
|---|---|---|---|
| 1 | 符/句/轮/回符是什么（C06） | 符=卡；句=`[符头*] 符胆 [符脚*]`（**一句只有一个符胆**）；轮=一次 cast 请求，读 `sentences_per_cast` 句；回符=牌堆读尽后 `recharge_ticks` 的锁定期 | 冻结 |
| 2 | 抽牌游标怎么走；乱序作用层级（C09） | 游标**逐符**推进，句边界由牌堆顺序决定；乱序=**回符时对符级洗牌**一次，一轮内冻结；触发子句共享同一游标，**不回绕** | 冻结 |
| 3 | 连续符脚归属；多符胆共享（C09） | 符脚只归**最近一个符胆**且必须连续；多符胆=多句，**符头状态不跨句共享** | 冻结 |
| 4 | 触发递归：深度/动作/投射物上限（C46） | **静态展开**（施法时展开，命中时执行）；深度 ≤ **3**、动作**执行次数** ≤ **64**、投射物 ≤ **32**，预算按**一次 cast 请求**共享；超限即**钳制 count** | 已定（2026-11-16；试玩后可调） |
| 5 | 灵力不足：整句还是念到哪算哪；何时扣（C09） | **按句原子**：句首判费，不足则**整句不念**、本轮结束；灵力在句首一次性扣；触发子句单独原子判费 | 冻结（细节建议） |
| 6 | 无效句（有符脚没符胆）（C09） | **扣灵力、无动作、游标推进、记事件、继续下一句** | 冻结 |
| 7 | 禁符反噬/幻符替换/幻影符时序（S-0004） | 施法 8 步状态机（§2.7）：反噬优先 → 解析 → 15% 掷骰 → 执行 → 回符 → 幻影符放置；**禁符与幻符永不同次** | 已定决策（S-0004） |
| 8 | 动作列表格式（C-ACT）（C09） | 16 种动作、字段与默认值表（§3.2）；物质 id 只能取 `data/materials.json`；覆盖 data 现有 8 种 `result.type` | 冻结 |

**读这份文档的最短路径**：要写 T3 → 读 §2（执行模型）+ §3（动作）+ §4（输入输出）+ §6.2（用例 schema）+ 附录 A（伪代码）。要审语义 → 读 §0 + §7.3（#2 / #3 已定，剩 4 个待你拍板的取舍点）。

---

## 1. 术语与基本单位（问题 1、2、3）

### 1.1 五个基本概念

| 术语 | 定义 | 存在形式 |
|---|---|---|
| **符**（card） | 符位上的一张牌，必属 `符头` / `符胆` / `符脚` 三类之一；带 `spirit_cost` 与 `effect` | 数据：`tests/vm_cases/cards.yaml`（测试替身）、`refs/cards/p0/talismans.yaml`（正式卡） |
| **符位**（slot） | 法器上的插槽，共 `slots` 个（设计 §3.3：clamp(2,24)，原型 4） | 法器属性 |
| **牌堆**（deck） | 所有**可读**符位上的符按槽位**升序**排成的列表。空符位、被幻影符占据的符位**不进入牌堆**；`deck_len` = 可读符位数 ≤ slots | 派生（§1.2） |
| **游标**（cursor） | 牌堆下标，`0 ≤ cursor ≤ deck_len`；指向"下一张要读的符" | 法器属性（跨轮保留，回符归零） |
| **句**（sentence） | 一次游标扫描出的可执行单元：`[符头*] 符胆 [符脚*]`。**一句恰好一个符胆**；无符胆 = 无效句（§2.6）。句是**灵力扣除与无效判定的原子单位** | 解析产物 |
| **轮**（cast） | 玩家扣一次扳机 = 一次 cast 请求。本轮最多读 `sentences_per_cast` 句；是**动作列表、预算、反噬判定**的原子单位 | 输入一条 `CastRequest` |
| **回符**（recharge） | 牌堆被读尽（`cursor == deck_len`）后进入的锁定期：`ready_at_tick = tick + recharge_ticks`，`cursor := 0` | 法器调度层 |

> **术语修正（批注 C06）**：设计文档把"每念几符"当句子数用，与"符位"混淆。本规格把法器属性改名为 **`sentences_per_cast`（每念几**句**）**，保留别名 `spells_per_cast` 只作兼容。**单位是句，不是符**——已拍板 #1（§7.3，2026-11-16）。

### 1.2 牌堆与游标（问题 2）

```
slots = [null, 飞剑, 幻影符位(视为空), 煞]      ← 槽位数组，长度 = slots
牌堆  = [飞剑, 煞]                            ← 剔除 null 与幻影符位后的卡序列
cursor: 0 → 1 → 2(=deck_len)                  ← 逐符推进
```

规则：

1. **游标逐符推进**，不是逐句、不按槽位固定分组。句边界完全由牌堆顺序决定：`[飞剑, 煞, 急急如律令, 飞剑]` 在 `sentences_per_cast=1` 下只读"飞剑+煞"，游标停在 2。
2. **符脚 peek 也推进游标**：附着符脚时逐张 `draw`（见 §2）。
3. **一轮内多句共享同一游标**；**触发子句也共享同一游标**（静态展开时继续读）。
4. **游标不回绕**：读到 `deck_len` 即本轮结束并触发回符，不 wrap 到 0 继续读。理由：预算与"一轮读多少符"可预测；代价：长触发链会很快吃光牌堆，单轮爆发上限变低。
5. **乱序（散符法器）作用在符级，且只发生在回符时**：调度层用 `shuffle_seed` 洗一次牌堆，一轮内顺序冻结。因此乱序影响"哪张符落进哪句"，但不改变句法规则、不重排句内读法。
6. **RNG 与洗牌算法不在 VM 内**：VM 只接收已排好的 `deck`；用例通过显式 deck 顺序覆盖乱序语义（§6）。洗牌算法列为待定（§7.4）。

### 1.3 符脚归属与多符胆（问题 3）

| 规则 | 内容 |
|---|---|
| 归属 | 符脚只归**最近一个尚未结束的符胆**，且必须**连续**（中间夹符头或下一个符胆即停止） |
| 一句一胆 | 第二个符胆必然开启**下一句**（若本轮句子预算还有）；"一句多符胆"在语法上不存在 |
| 符头状态 | 符胆生成动作后 `CastState` **立即重置**；下一句从空状态累积，**不共享** |
| 多符胆 | 多符胆 = 多句。共享只发生在"同一句内多个符头累积给该句唯一符胆"，以及"触发子句的符头不影响父句" |
| 符脚优先级 | 同一符胆可挂多张符脚，按牌堆顺序**依次**执行；`timing: sentence_end` 的符脚（归）挂在**顶层**、句末立即执行，不作为命中载荷 |

---

## 2. 执行模型

### 2.1 两阶段：解析（parse）→ 执行（execute）

**为什么两阶段**：批注 C46 要求"限制递归深度、单次动作数、投射物数、延迟触发生命周期，并定义失败时的原子性与资源扣除时点"。若像设计原文 §4.5 伪代码那样"命中时再递归 cast_sub"，则成本、预算、禁符判定都发生在不同 tick，不可测、不可预测。本规格改为：

- **阶段 A 解析**：从游标起解析主句 + 深度内全部触发子句，得到**只读的句法树**（符序列 / 成本 / 是否含禁符）。不扣灵力、不改状态。
- **阶段 B 执行**：逐句判费扣费、生成动作树；触发子句在**展开时**扣费（因为静态展开），命中时只执行已生成的动作。
- **阶段 C 收尾**：回符判定、幻影符放置。

**代价（写清）**：延迟触发的子句在施法时就付灵力与神智（"预付费"）；好处是确定性、可测试、预算可控。已拍板 #2（2026-11-16：保留预付费）。

### 2.2 cast 主流程（伪代码）

```text
cast(req):
  # 0 准入（不消费反噬）
  if req.tick < wand.ready_at_tick: return reject("recharging")     # 反噬不消费

  # 1 幻影符清理（必须在牌堆构建与空牌判定之前）
  if state.sanity >= 33 and state.phantom_slots != []:
      state.phantom_slots = []; event(phantom_slot_cleared)

  # 1.5 空牌判定（清理后再判）
  if deck_len(wand) == 0: return reject("empty_deck")

  # 2 反噬（优先于一切符法逻辑）
  if state.backlash:
      plan = parse_round(wand, state)          # 只解析，不执行
      cost = min(wand.spirit, plan.total_cost) # 不做灵力检查，clamp
      wand.spirit -= cost
      state.backlash = false; event(backlash_consumed)   # 不记 depth_limit/empty_trigger
      actions = [phantom_cast(spell=rng.phantom_card, reason="backlash")]
      advance_cursor(plan); return finish(actions)   # 仍判回符/幻影符

  # 3 解析
  plan = parse_round(wand, state)              # 主句 + 深度内触发子句

  # 4 <33 的 15% 幻符替换（本次含禁符 / 已反噬 → 不掷骰）
  if state.sanity < 33 and not plan.has_forbidden:
      if rng.phantom_roll < 0.15:              # 0.15 来自 magic_numbers.sanity.phantom_cast_chance
          plan.substitute_first_body(rng.phantom_card); event(phantom_substitute)

  # 5 执行主句 + 展开子句
  for sent in plan.main_sentences:             # 按牌堆顺序
      if wand.spirit < sent.cost:              # 句原子判费
          event(fizzle_no_spirit); return finish(actions, round_end=false)
      wand.spirit -= sent.cost
      if sent.invalid:
          event(invalid_sentence); continue    # 无效句：已扣费、无动作、游标已推进
      actions += expand(sent, depth=0, budget) # 生成动作树（§2.3/2.4）
      if sent.has_forbidden:                   # 禁符本次生效，代价落在神智+下一次
          state.sanity = max(0, state.sanity - 20)
          event(forbidden_read); state.backlash = true; event(backlash_armed)
  return finish(actions)
```

`finish(actions)`：`if cursor == deck_len: cursor=0; ready_at_tick = tick + recharge_ticks; event(round_end)`；然后**幻影符放置**（§2.7 第 8 步）。

### 2.3 触发类符头的静态展开（问题 4）

| 符头 | 触发时机 | VM 语义 |
|---|---|---|
| `敕·触`（`head-chu-touch`） | 投射物**命中** | `trigger.kind = "on_hit"` |
| `奉·时`（`head-feng-shi`） | 投射物 **ttl 到期** | `trigger.kind = "on_expire"` |

展开规则：

1. 解析到带触发效果的符头时，**立即解析下一句**（从当前游标继续），作为 `trigger.actions`。
2. 子句本身也可以带触发符头 → 继续展开，直到 `depth > max_trigger_depth`。
3. **深度超限**：不解析、不扣费、不消耗牌，`trigger = null`，记 `depth_limit`。
4. **子句无符可读**（牌堆尽）：`trigger = null`，记 `empty_trigger`。
5. 子句的灵力在**执行阶段展开到该子句时**扣（顺序：父句先扣 → 父句动作生成 → 子句扣费/展开）；不足 → 该子句不展开（`trigger = null`），父动作保留，记 `sub_fizzle_no_spirit`（此时子句卡片的 `consumed` 与游标口径见 §7.4.1 ①）。
6. 每个符胆**最多挂 1 个触发子句**（多个触发符头累积时，深度只 +1，后一个触发符头的语义 = 追加 payload 而不是再嵌套——本草案简化为"每句只取第一个触发符头"）。

> 第 6 条为**本草案的简化**：设计原文没有定义"多个触发符头"的语义，本草案取"只认第一个"以免嵌套数爆炸。列待定（§7.4）。

### 2.4 预算与上限（问题 4，**已定 2026-11-16；试玩后可调**）

| 预算 | 值 | 作用范围 | 超限行为 |
|---|---|---|---|
| `max_trigger_depth` | **3** | 一次 cast 请求 | 不展开子句，`trigger=null`，`depth_limit` |
| `max_actions` | **64** | 一次 cast 请求（含 payload、子句动作、命中后才执行的延迟动作） | **钳制 `count`**（能放几发放几发），`budget_exhausted_action`；`count` 被钳到 0 则不发，停止剩余展开 |
| `max_projectiles` | **32** | 一次 cast 请求（`Σ spawn_projectile.count`） | 同 actions：钳制 `count` + `budget_exhausted_projectile` |

**计数定义**（T3 必须一致，**"执行次数"不是"对象个数"**）：

- `action_count` = 动作树在**执行时产生的动作次数**，按 `count` 展开后计：
  ```text
  exec(spawn)  = spawn.count × (1 + Σ exec(p) for p in payloads + exec(trigger.actions))
  exec(其他 op) = 1        # 含 refund_spirit；计入 action_count 与「已用执行次数」，见 §7.4.1 ④
  exec(null)    = 0
  ```
  例：`spawn(count=16, payloads=[explode, stun, drain])` → `16 × (1+3) = 64`。
- `spawn_count` = `Σ spawn_projectile.count`（不是动作对象个数）。
- `max_depth` = 动作树里 `trigger.depth` 的最大值（主句动作 depth=0）。
- **钳制算法**：单个 spawn 的 `per = 1 + Σ exec(payload) + exec(trigger.actions)`；`count = min(请求 count, floor((64 − 已用执行次数) / per), 32 − 已用投射物)`；被钳制时记对应事件。被钳制到 0 → 该 spawn 不生成并停止展开。动作/投射物**同时超限**时先动作后投射物（§7.4.1 ⑤）。
- **截断不退灵力**（符已念出）；"截断"只影响动作，不影响"已扣费"。

**代价**：极端组合（5 张分身 + 多符脚）会被截断而"看起来没放满"，玩家需要可读的 UI 提示（`budget_exhausted_*` 事件 → UI 提示音/文字，D1 的"可读"硬约束）。

### 2.5 灵力：按句原子扣费（问题 5）

| 情形 | 规则 |
|---|---|
| 主句判费 | 句首判费（`句成本 = Σ 本句直接符的 spirit_cost`，含符头+符胆+符脚）；不足 → **整句不念**：不扣、无动作、不扣神智、游标不动、**结束本次施法且不触发回符**，记 `fizzle_no_spirit`。下一 tick 可重试 |
| 扣费时点 | 句首**一次性**扣，不是逐符扣；神智扣除（禁符）与灵力扣除**同一时刻**（"念出"的原子时刻） |
| 触发子句 | 在展开到该子句时**单独**判费（子句原子）；不足 → 子句不展开、父动作保留，记 `sub_fizzle_no_spirit` |
| 反噬施法 | **不做灵力检查**、必发；扣 `min(spirit, 正常成本)`（clamp 0）——防止"空灵逃避反噬"；已拍板 #4（2026-11-16） |
| 无效句 | 照常扣费（§2.6） |
| `归` 返还 | `timing: sentence_end`，句末立即 `refund_spirit`（clamp ≤ spirit_max），是唯一能从动作里改灵力的操作 |
| 回灵 | 不在 VM 内（调度层按 `regen_per_sec` 每 tick 回）；VM 只接收当前 `spirit` |
| fizzle 的收尾 | 灵力不足导致整次施法结束时：**不做幻影符放置**（神智未变），不触发回符，游标停原处；下一次 cast 从原处重试。多主句中途 fizzle 的游标口径见 §7.4.1 ② |

**为什么不用"念到哪算哪"**：主句原子让"这一发放不放得出来"成为玩家可预判的二元事件（法器可读性）；代价是"差 1 点灵力就整发哑火"，手感更硬。已拍板 #3（2026-11-16：整句不念）。

### 2.6 无效句（问题 6）

| 情形 | 处理 |
|---|---|
| 有符脚、无符胆（`[煞, 飞剑]` 的"煞"段） | **扣灵力**（设计 §4.5 注释："无效，消耗灵力，鼓励玩家读懂结构"）、**无动作**、游标推进到句末、记 `invalid_sentence`、**继续读下一句**（若句子预算还有） |
| 只有符头（牌堆末尾悬挂） | 同上；随后牌堆读尽 → 回符 |
| 无效句灵力不足 | 按 §2.5 处理：`fizzle_no_spirit`，整次施法结束 |
| 无效句里的符头 | 效果丢弃，**不带到下一句**（句边界清空 `CastState`） |

### 2.7 禁符 / 反噬 / 幻符 / 幻影符的确切时序（问题 7）

**已定决策依据（不得改）**：S-0004 `phantom_rules`、`data/magic_numbers.json` → `sanity.forbidden_cast_cost=20`、`forbidden_backlash=next_cast_phantom`、`phantom_never_with_forbidden=true`、`phantom_cast_chance=0.15`、`phantom_slots=1`。

施法内状态机（编号即执行顺序）：

| 步 | 时刻 | 动作 | 事件 |
|---|---|---|---|
| 0 | 施法前 | `tick < ready_at_tick` → 拒绝；**不消费反噬**（反噬只被真正的施法消费） | `rejected_recharging` |
| 1 | 施法开始 | `sanity ≥ 33` 且 `phantom_slots ≠ []` → 清空幻影符（在牌堆构建前） | `phantom_slot_cleared` |
| 2 | 施法开始 | `backlash` → 本次**整次**替换为 **1 个幻符**：灵力扣 `min(spirit, 正常全树成本)`，`backlash := false`，**不生成正常动作**，**不掷 15% 骰**，本次读到的禁符**不生效、不扣神智**；仍推进游标/判回符/判幻影符放置 | `backlash_consumed` |
| 3 | 解析 | 解析主句 + 深度内触发子句，得符序列/成本/`has_forbidden`；不改任何状态 | — |
| 4 | 15% 替换 | `sanity < 33` 且 **`!has_forbidden`** → `rng.phantom_roll < 0.15` 时把**主句第一个符胆**替换为幻符（`phantom_cast.reason="substitute"`，其符脚保留为 `payloads`，**成本不变**）；否则不替换（含禁符/已反噬时**不掷骰**）。替换句带触发符头时的细则见下表后的补写 | `phantom_substitute` |
| 5 | 执行 | 逐句判费扣费、生成动作；禁符：`sanity = max(0, sanity - 20)`、`backlash := true`、**本次仍照常生效**（D3：代价落在下一次） | `forbidden_read`、`backlash_armed` |
| 6 | 执行（子句） | 触发子句展开：扣子句灵力；子句里的禁符同样 −20 神智、置反噬（静态展开=预付费，见 §2.1） | `sub_fizzle_no_spirit` 等 |
| 7 | 收尾 | `cursor == deck_len` → 回符：`cursor := 0`、`ready_at_tick = tick + recharge_ticks` | `round_end` |
| 8 | 收尾 | `sanity < 33` 且 `phantom_slots == []` → 从**不含禁符的符位**中按 `rng.phantom_slot` 选 1 格放置幻影符（读牌时视为空位，不可移除） | `phantom_slot_added` |

**第 4 步的补写：替换句带触发符头时（2026-11-15 T3 复审后补；语义未改，只补空白）**

15% 替换只替换**符胆**。若被替换的那一句带触发符头（`敕·触` / `奉·时`）：

- **触发子句不展开、不扣灵力、不计 `consumed`**：`phantom_cast`（§3.2）没有 `trigger` 字段，幻符不携带触发子句。
- **游标停在子句首（不越过）**：子句的牌留待后续施法再读；因此若尚未读尽牌堆，**不回符**。
- **本次成本 = 主句直接符（符头/符胆/符脚）成本之和**，维持"成本不变"；`consumed` 只含主句直接符（未回符时 `cursor_after = cursor + len(consumed)`，与 §6.3 口径一致）。
- 该组合的**多句施法**（`sentences_per_cast > 1`）读法未定义，列 §7.4 待定；30 条用例不覆盖（VM-020 是替换句不带触发的成功路径）。

**备选 A（#6 已拍板取 Option B，2026-11-16；此备选仅留档）**：保留触发子句，给 `phantom_cast` 增加 `trigger` 字段。代价：改 C-ACT 契约（§3.2 第 16 项）+ T4b 世界层要执行"幻符的延迟触发"；收益：`敕·触 + 幻符` 组合不被吞掉。

**不变量（用例必须断言，T3 必须成立）**：

| 编号 | 不变量 |
|---|---|
| I1 | 禁符与幻符永不同一次施法：反噬施法的动作列表只有 `phantom_cast(reason="backlash")`；`reason="substitute"` 的施法解析树内不含禁符 |
| I2 | 施法结束时 `sanity < 33 ⇔ phantom_slots 非空`（(`sanity ≥ 33 ⇒ 空`，(sanity < 33) ⇒ 恰好 1 格） |
| I3 | 反噬不会被"灵力不足"或"回符中"逃掉：回符中被拒 → 反噬**保留**；真正施法时必发 |
| I4 | 反噬消费后 `backlash_after = false` |
| I5 | 15% 替换时 `sanity` 不变（替换不额外扣神智） |
| I6 | `spirit_after ∈ [0, spirit_max]`；`sanity_after ∈ [0, 100]` |

**未覆盖项（诚实声明）**：神智 = 0 的入魔（可逆状态机）不在本 VM（M1 才做，S-0004）；M0 的 T3 只实现到 `sanity = 0` 为止，不触发入魔。

---

## 3. 契约 C-ACT：动作列表格式（问题 8）

### 3.1 约定

- 动作列表 = **有序数组**，顺序即同一 tick 内的执行顺序。
- 每个动作对象带 `op`（必填，动作类型）；`from`（可选，来源卡 id，**不参与比较**）。
- **规范化（T3 必做）**：按 §3.2 的默认值补齐字段后再比较；用例里的期望动作可省略取默认值的字段。
- **比较规则**：期望与实际逐项深度相等（数组长度相同、顺序相同、规范化后字段集合相同）。`from` 不比较。
- **物质 id**：所有 `material / produces / removes / to` 字段只能取 `data/materials.json` 的 12 个 id：`water, black_dog_blood, quicksilver, coal, saltpeter, sulfur, cinnabar, lime, glutinous_rice, rock, bamboo, yin_qi`。
- **执行者**：VM 只产出动作，不直接改世界。`refund_spirit` 由 VM 自己执行；其余交世界层/实体层（下表）。**T3 不实现世界执行**，只对动作做断言。

### 3.2 动作类型表（16 种）

| # | op | 字段（默认值） | 执行者 | 对应 design/data |
|---|---|---|---|---|
| 1 | `spawn_projectile` | `spell`(必填卡 id)、`count`=1、`damage`=0、`damage_type`="none"、`element`="none"、`pierce`=0、`speed`=12、`spread_deg`=0、`ttl_ticks`=120、`payloads`=[]、`trigger`=null | 实体层（T4） | 符胆 |
| 2 | `explode` | `radius`(必填)、`damage`(必填)、`damage_type`(必填) | 世界层 | `result.type=explosion`（煞、r-black-powder） |
| 3 | `damage` | `amount`(必填)、`damage_type`(必填)、`radius`=0 | 世界层 | `result.type=damage` |
| 4 | `ignite` | `duration`(必填)、`spread`=false、`damage_per_sec`=0、`produces`=null、`target_tags`=[] | 世界层 | `result.type=burn`（r-bamboo-burn） |
| 5 | `spawn_cloud` | `kind`(必填: "heat_cloud"/"toxic_smoke")、`radius`(必填)、`duration`(必填)、`damage`=0、`damage_per_sec`=0、`damage_type`="none"、`tags`=[] | 世界层 | `result.type=heat_cloud` / `toxic_smoke` |
| 6 | `purify` | `removes`(必填物质 id)、`radius`=3 | 世界层 | `result.type=purify`（r-rice-purify） |
| 7 | `barrier` | `effect`(必填)、`radius`=1、`duration`=0 | 世界层 | `result.type=barrier`（r-quicksilver-ward） |
| 8 | `grant_temp_slot` | `value`=1、`duration`=60 | 法器层（T4） | `result.type=temporary_talisman_slot` |
| 9 | `convert_material` | `source`(必填: `{material?}` 或 `{tags?}`)、`to`(必填物质 id)、`radius`=1 | 世界层 | 符脚 化·水/化·金 |
| 10 | `spawn_material` | `material`(必填物质 id)、`shape`(必填: "pool"/"cloud"/"solid")、`count`=1、`radius`=1、`duration`=0 | 世界层 | 符胆 藤生 / 幻符 |
| 11 | `dig` | `radius`(必填)、`mode`="remove_solid" | 世界层 | 符胆 土遁 |
| 12 | `apply_status` | `status`(必填: "stun"/"slow")、`duration`(必填) | 实体层 | 符脚 镇 |
| 13 | `extinguish_lantern` | `lanterns`(必填, 可小数) | 世界层 | 符胆 鬼火（阴性伤害，S-0004 七魄） |
| 14 | `drain_life` | `amount`(必填) | 世界层 | 符脚 噬 |
| 15 | `refund_spirit` | `amount`(必填) | **VM** | 符脚 归 |
| 16 | `phantom_cast` | `spell`(必填幻符 id)、`reason`(必填: "backlash"/"substitute")、`effect`(必填: 幻符表里的动作对象)、`payloads`=[]。**无 `trigger` 字段**（替换句带触发符头时按 §2.7 第 4 步补写处理） | 世界层 | S-0004 幻符 |

嵌套结构：

```yaml
# trigger（触发子句，静态展开后挂在投射物上）
trigger:
  kind: on_hit | on_expire
  depth: 1..3
  actions: [Action]
```

**payload 顺序（T3 必须一致）**：`spawn_projectile.payloads` = **符胆自带 payloads（按卡表顺序）** + **附着的符脚动作（按牌堆顺序）**。例：毕方火自带 `ignite`，其后接煞 → `payloads: [ignite, explode]`（VM-011）。`phantom_cast.payloads` 只含符脚动作（幻符无自带载荷，VM-020）。

**符头效果的 VM 规则**：`天罡 damage_mult` 乘到本句所有伤害类动作（§3.2 末）；`分身 projectile_mult` 乘到该句 spawn 的 `count`（可叠加，2 张 = ×4）；`急急如律令` 只改 `cast_interval`（调度层字段），不进动作、不影响期望；`敕·触/奉·时` 生成 `trigger`。

**8 种 `result.type` 的覆盖**（映射自 `data/materials.json`，全部可被 C-ACT 表达）：`explosion→explode`、`heat_cloud/spawn_cloud(kind=heat_cloud)`、`purify→purify`、`damage→damage`、`barrier→barrier`、`temporary_talisman_slot→grant_temp_slot`、`toxic_smoke→spawn_cloud(kind=toxic_smoke)`、`burn→ignite`。

**伤害加成规则（`天罡`）**：`damage_mult` 只乘**符伤**：`spawn.damage`、`explode.damage`、`damage.amount`、`drain_life.amount`；**不乘** `ignite.damage_per_sec`（燃烧是物质反应，归 `data/materials.json` 管，S-0003）、不乘 `extinguish_lantern.lanterns`（熄灯不是伤害，S-0004 七魄）。乘法在规范化前应用，结果保留浮点。

### 3.3 完整动作列表示例

输入：法器 8 符位、`sentences_per_cast=1`、`spirit=80`；牌堆 =
`[head-chu-touch(敕·触), body-flying-sword(飞剑), foot-sha(煞), head-tiangang(天罡), body-bifang-huo(毕方火), foot-hua-water(化·水), null, null]`

解析：句 1 = 敕·触 + 飞剑 + [煞]（成本 5+5+8=18）；敕·触预读子句 2 = 天罡 + 毕方火 + [化·水]（成本 3+10+30=43）。总成本 61 → `spirit_after = 19`；游标读尽 6 张 → 回符。

```json
[
  {
    "op": "spawn_projectile",
    "spell": "body-flying-sword",
    "from": "body-flying-sword",
    "count": 1, "damage": 8, "damage_type": "金", "element": "金",
    "pierce": 1, "speed": 12, "spread_deg": 0, "ttl_ticks": 120,
    "payloads": [
      {"op": "explode", "radius": 20, "damage": 15, "damage_type": "火"}
    ],
    "trigger": {
      "kind": "on_hit", "depth": 1,
      "actions": [
        {
          "op": "spawn_projectile",
          "spell": "body-bifang-huo",
          "count": 1, "damage": 12, "damage_type": "火", "element": "火",
          "pierce": 0, "speed": 12, "spread_deg": 0, "ttl_ticks": 120,
          "payloads": [
            {"op": "ignite", "duration": 3, "spread": true, "damage_per_sec": 3},
            {"op": "convert_material", "source": {"tags": ["liquid", "solid", "powder"]}, "to": "water", "radius": 2}
          ],
          "trigger": null
        }
      ]
    }
  }
]
```

说明：`天罡` 在子句内，只作用于子句的毕方火（`damage 10 × 1.2 = 12`）；父句飞剑无加成。`化·水` 目标物质 `water` 存在于 `data/materials.json`。

---

## 4. 契约 C-VM：输入、输出、状态

### 4.1 输入 `CastRequest`

| 字段 | 类型 | 说明 |
|---|---|---|
| `op` | "cast" | 本草案只定义 cast（回灵/回符由调度层处理，不进 VM） |
| `tick` | int | 当前 tick（60 Hz；只用于回符判定） |
| `rng.phantom_roll` | float 0–1 | <33 的 15% 骰；**所有用例都必须给**（不掷骰给 1.0） |
| `rng.phantom_slot` | int\|null | 幻影符放置的目标槽位（注入，避免 VM 内置 RNG） |
| `rng.phantom_card` | string\|null | 本次幻符使用的卡 id（反噬/替换） |
| `state.sanity` | int 0–100 | 当前神智 |
| `state.backlash` | bool | 是否"下一次施法反噬"中 |
| `state.phantom_slots` | [int] | 被幻影符占据的槽位 |
| `wand.spirit / spirit_max` | number | 灵力 |
| `wand.regen_per_sec` | number | 回灵（本草案不使用，仅记录，供调度层） |
| `wand.slots` | int 2–24 | 符位数（原型 4；用例可用更大值构造极限场景） |
| `wand.sentences_per_cast` | int ≥1 | 每念几**句** |
| `wand.recharge_ticks` | int | 回符时间（tick） |
| `wand.ready_at_tick` | int | 下次可施法 tick |
| `wand.ordered` | bool | 成文（true）/ 散符（false）；VM 只记录，洗牌在调度层 |
| `wand.deck` | [card_id\|null] | 长度 = `slots`，槽位顺序 |
| `wand.cursor` | int | 牌堆下标（不含空位/幻影位） |

### 4.2 输出 `CastResult`

| 字段 | 类型 | 说明 |
|---|---|---|
| `accepted` | bool | 是否受理 |
| `reject_reason` | "recharging"\|"empty_deck"\|null | 拒绝原因 |
| `actions` | [Action] | C-ACT 动作列表 |
| `consumed` | [card_id] | 读出的符（按读出顺序，含触发子句；反噬施法也返回，作为成本依据）。**例外**：15% 替换句的触发子句不计入（§2.7 第 4 步补写） |
| `spirit_after` / `sanity_after` / `backlash_after` / `phantom_slots_after` / `cursor_after` | — | 施法后状态 |
| `round_ended` | bool | 是否触发回符 |
| `ready_at_tick_after` | int | 回符后 = `tick + recharge_ticks`；否则不变 |
| `events` | [{code, ...}] | 事件流（§4.3）；用例只比较 `event_codes` 的顺序 |
| `action_count` / `spawn_count` / `max_depth` | int | 派生计数（§2.4 定义），供 `summary` 期望使用 |

### 4.3 事件码表

| code | 触发条件 | 附加字段 |
|---|---|---|
| `rejected_recharging` | 回符中拒绝施法 | — |
| `rejected_empty_deck` | 无牌可读 | — |
| `fizzle_no_spirit` | 主句灵力不足，整句不念 | `sentence` |
| `invalid_sentence` | 无效句（无符胆） | `sentence` |
| `forbidden_read` | 念出禁符，−20 神智 | `card` |
| `backlash_armed` | 置"下一次施法反噬" | — |
| `backlash_consumed` | 反噬被本次施法消费 | — |
| `phantom_substitute` | <33 的 15% 幻符替换 | `card`（被替换的符胆） |
| `phantom_slot_added` | 幻影符占位 | `slot` |
| `phantom_slot_cleared` | 神智恢复，幻影符清除 | `slot` |
| `depth_limit` | 触发深度超限，子句不展开 | `depth` |
| `empty_trigger` | 触发子句无符可读 | `card`（触发符头） |
| `sub_fizzle_no_spirit` | 子句灵力不足，不展开 | — |
| `budget_exhausted_action` | 动作树节点超 64 | `limit` |
| `budget_exhausted_projectile` | 投射物超 32 | `limit` |
| `round_end` | 牌堆读尽，进入回符 | `ready_at_tick` |

### 4.4 边界条件

1. `deck` 全空/全被幻影符占据 → `rejected_empty_deck`（不消费反噬）。
2. `spirit` 扣费后 `< 0` 不可能（句首判费保证）；`refund_spirit` clamp 到 `spirit_max`。
3. `sanity` 下限 0（入魔不在本 VM，§2.7 末）。
4. 同一 tick 内多次 cast 的调度（施法间隔 `cast_interval`）不在 VM：VM 只认 `ready_at_tick`。
5. 投射物的飞行、命中判定、ttl 计时由 T4 实体层做；VM 只提供动作树。命中时 T4 按 `payloads` → `trigger.actions` 的顺序执行。

---

## 5. 卡表与数值来源

### 5.1 测试替身卡表

30 条用例只使用 `tests/vm_cases/cards.yaml` 里的卡（机器可校验）。数值按设计 §3.3 与 P0 卡反推：

| 段 | 卡 | id | 灵力 | 效果 |
|---|---|---|---|---|
| 符头 | 急急如律令 | `head-urgent-order` | +3 | 施法间隔 −0.1s（6 tick），不改动作 |
| 符头 | 天罡 | `head-tiangang` | +3 | 本句伤害 ×1.2 |
| 符头 | 敕·触 | `head-chu-touch` | +5 | 命中触发下一句 |
| 符头 | 奉·时 | `head-feng-shi` | +5 | ttl 到期触发下一句 |
| 符头 | 分身 | `head-fenshen` | +5 | 投射物 count ×2（可叠加） |
| 符胆 | 飞剑 | `body-flying-sword` | 5 | 金，伤害 8，穿透 1 |
| 符胆 | 毕方火 | `body-bifang-huo` | 10 | 火，伤害 10，命中点燃 |
| 符胆 | 鬼火 | `body-gui-huo` | 8 | 阴，熄灯 0.3 盏/次，不伤气血 |
| 符胆 | 土遁 | `body-tudun` | 10 | 土，挖掘 radius 2 |
| 符胆 | 藤生 | `body-tengsheng` | 12 | 木，生成竹木（bamboo） |
| 符胆 | **禁符·五雷** | `body-forbidden-wulei` | 40 | 雷，伤害 60；`forbidden: true`（S-0004） |
| 符脚 | 煞 | `foot-sha` | +8 | 爆炸 15，半径 20（火） |
| 符脚 | 镇 | `foot-zhen` | +12 | 定身 1.5s |
| 符脚 | 噬 | `foot-shi` | +12 | 吸血 4 |
| 符脚 | 化·水 | `foot-hua-water` | +30 | 命中物质 → 水 |
| 符脚 | 归 | `foot-hui` | 0 | 句末返还 8 灵力（例外，见 §5.2） |
| 幻符 | 幻符·阴噬 | `phantom-001` | — | 占位：伤害 6（阴） |
| 幻符 | 幻符·阴气涌 | `phantom-002` | — | 占位：生成阴气云 |

### 5.2 数值来源与冲突处理（**重要**：所有偏差都在这里说清）

| 项 | 来源 | 处理 |
|---|---|---|
| 符头 +3 / +5 | S-0002 `head_cost`、设计 §3.3 | 直接采用：急急/天罡 +3；敕·触/奉·时/分身 +5 |
| 符脚 +8 ~ +30 | S-0002 `foot_cost`、设计 §3.3 | 煞 8 / 镇 12 / 噬 12 / 化·水 30，均在区间内 |
| 符组成本可加和 | F-0001 `spirit_cost: 13` | 13 = 飞剑 5 + 煞 8 ✓（反推出"卡面成本 = 各段之和"） |
| 符组成本可加和 | F-0002 `spirit_cost: 40` | 40 = 毕方火 10 + 化·水 30 ✓（化·水 = +30） |
| 符组成本可加和 | F-0003 `spirit_cost: 20` | 20 = 鬼火 8 + 镇 12 ✓ |
| **归 的灵力** | F-0004 `spirit_cost: 10, refund: 8, net: 2` | **三者只能同时成立**当且仅当"土遁 10 + 归 0，归返还 8"。故归 `spirit_cost: 0`，**突破 S-0002 的符脚 +8~+30**（已拍板 #4，2026-11-16；例外已记入 S-0002 deviations） |
| 天罡 ×1.2 / +3 | F-0001 `combo_ideas: 天罡 + 飞剑·煞：伤害 ×1.2，灵力 +3` | 采用：`damage_mult 1.2`、成本 +3 |
| 禁符数值 | `magic_numbers.sanity`：`forbidden_cast_cost 20`、`phantom_cast_chance 0.15`、`phantom_slots 1` | 直接采用，不新增数值 |
| 幻影符"只占不含禁符的符位" | S-0004 `phantom_rules` 第 4 条 | 放置候选过滤：槽内有禁符 → 不可选 |

---

## 6. 用例规范（tests/vm_cases，T3 按此跑 30/30）

### 6.1 文件布局

```text
tests/vm_cases/
  manifest.yaml                  # 索引：30 条、文件、类别计数、版本
  cards.yaml                     # 测试替身卡表（§5.1）
  01-basic-syntax.yaml           # VM-001 ~ VM-008（8 条）
  02-spirit-invalid.yaml         # VM-009 ~ VM-015（7 条）
  03-forbidden-phantom.yaml      # VM-016 ~ VM-023（8 条）
  04-trigger-budget.yaml         # VM-024 ~ VM-030（7 条）
  validate_cases.py              # 结构自检（仅依赖 pyyaml）
```

**用例版本：v0.1（2026-11-16 已拍板）**。T3 已按本版实现并回归（30/30）。若后续语义有变，先改 §6.2 与 30 条用例，再改实现（不允许"实现改、用例不改"）。

用例文件统一结构：

```yaml
schema: gamev0.vm_cases/v0.1
version: 0.1
updated: "2026-11-15"
spec: docs/tech/talisman-vm-spec.md
cases:
  - <一条用例，见 §6.2>
```

### 6.2 单条用例 schema（**写死**，T3 与 `validate_cases.py` 都以本节为准）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | ✓ | `VM-001`…全仓库唯一 |
| `title` | string | ✓ | 一句话说清测什么 |
| `category` | [string] | ✓ | 覆盖类别，取值见 §6.4 |
| `spec` | string | ✓ | 对应本文件章节，如 `"§2.5"` |
| `initial.tick` | int | ✓ | 初始 tick |
| `initial.sanity` | int 0–100 | ✓ | 初始神智 |
| `initial.backlash` | bool | ✓ | 初始是否反噬中 |
| `initial.phantom_slots` | [int] | ✓ | 初始幻影符槽位 |
| `initial.wand` | object | ✓ | §4.1 法器字段：`spirit / spirit_max / regen_per_sec / slots / sentences_per_cast / recharge_ticks / ready_at_tick / ordered / deck / cursor` |
| `input.op` | "cast" | ✓ | 本草案只有 cast |
| `input.rng` | object | ✓ | `phantom_roll: 0–1`、`phantom_slot: int\|null`、`phantom_card: string\|null`。**所有用例必须给**（不掷骰写 1.0） |
| `expect.accepted` | bool | ✓ | |
| `expect.reject_reason` | string\|null | ✓ | `"recharging"` / `"empty_deck"` / null |
| `expect.actions` | [Action] | ✓\* | 与 `summary` 二选一（\*大动作树用例用 summary） |
| `expect.summary` | object | ✓\* | `{action_count, spawn_count, max_depth}` |
| `expect.consumed` | [card_id] | ✓ | 读出的符（按读出顺序，含触发子句） |
| `expect.spirit_after` | number | ✓ | |
| `expect.sanity_after` | int | ✓ | |
| `expect.backlash_after` | bool | ✓ | |
| `expect.phantom_slots_after` | [int] | ✓ | |
| `expect.cursor_after` | int | ✓ | |
| `expect.round_ended` | bool | ✓ | |
| `expect.ready_at_tick_after` | int | ✓ | 回符后 = tick+recharge_ticks；否则不变 |
| `expect.event_codes` | [string] | ✓ | 按顺序比较（§4.3 的 code） |
| `expect.invariants` | [string] | ✓ | 断言表达式，见 §6.3；每例 ≥ 3 条 |

示例（VM-001 的真实内容）：

```yaml
- id: VM-001
  title: 单符胆最小施法：飞剑一发，牌堆读尽触发回符
  category: [basic, cursor]
  spec: "§2.2"
  initial:
    tick: 0
    sanity: 100
    backlash: false
    phantom_slots: []
    wand:
      spirit: 50
      spirit_max: 80
      regen_per_sec: 10
      slots: 2
      sentences_per_cast: 1
      recharge_ticks: 30
      ready_at_tick: 0
      ordered: true
      deck: [body-flying-sword, null]
      cursor: 0
  input:
    op: cast
    rng: {phantom_roll: 1.0, phantom_slot: null, phantom_card: null}
  expect:
    accepted: true
    reject_reason: null
    actions:
      - op: spawn_projectile
        spell: body-flying-sword
        damage: 8
        damage_type: 金
        element: 金
        pierce: 1
    consumed: [body-flying-sword]
    spirit_after: 45
    sanity_after: 100
    backlash_after: false
    phantom_slots_after: []
    cursor_after: 0
    round_ended: true
    ready_at_tick_after: 30
    event_codes: [round_end]
    invariants:
      - action_count <= 64
      - spawn_count <= 32
      - max_depth <= 3
      - spirit_after >= 0
      - spawn_count == 1
```

### 6.3 比较与断言规则

1. **动作**：期望动作可省略默认值字段（§3.2）；T3 规范化后与实际**逐项深度相等**（长度、顺序、字段集合）。`from` 不比较。
2. **事件**：`event_codes` 是**有序**比较，且**必须完全相等**（不多不少）。
3. **consumed**：严格有序相等。
4. **不变量**：字符串三元式 `<lhs> <op> <rhs>`；`op ∈ {==, !=, <, <=, >, >=}`；`lhs` 取 `accepted / action_count / spawn_count / max_depth / spirit_after / sanity_after / cursor_after / ready_at_tick_after / round_ended / backlash_after / phantom_slots_after / consumed_count`；`rhs` 用 YAML 字面量（如 `64`、`true`、`[]`）。T3 必须全部求值为真，否则该用例失败。
5. **全局不变量**（每条用例都由 T3 隐式检查，不依赖 `invariants` 字段）：§2.7 的 I1–I6。

### 6.4 覆盖矩阵（30 条）

| id | 标题（简） | 主类别 | 覆盖点 |
|---|---|---|---|
| VM-001 | 单符胆最小施法：飞剑 | basic | 一轮一句、回符、动作默认值 |
| VM-002 | 符头+符胆：急急如律令 | basic | 符头成本进句成本、非伤害符头不改动作 |
| VM-003 | 连续符脚归属：两张煞都挂飞剑 | foot_attach | 符脚 peek 循环、多符脚顺序 |
| VM-004 | 符脚遇符头停止 | foot_attach / cursor | 符脚只吃连续、游标停在下一句首（不回符） |
| VM-005 | 多符胆：符头状态不跨句 | multi_body | 天罡只在句 1 生效、句 2 重新累积 |
| VM-006 | 多符头累积：天罡+分身 | multi_body | 同句多符头累积、跨句隔离、count |
| VM-007 | 游标从指定位置开始 | cursor | 抽牌游标续读 |
| VM-008 | 散符（乱序）牌堆：句边界由顺序决定 | cursor / shuffle | 乱序只重排符、不改句法；符脚归属 |
| VM-009 | 空符位与幻影符位被跳过 | cursor / phantom_slot | 牌堆构建剔除 null 与幻影位 |
| VM-010 | 灵力不足：整句不念 | no_spirit | 句原子判费、游标不动、不回符 |
| VM-011 | 灵力恰好够：边界扣到 0 | no_spirit | 判费边界（== 成本仍可念） |
| VM-012 | 无效句：有符脚没符胆 | invalid_sentence | 扣费无动作、继续下一句 |
| VM-013 | 悬挂符头：牌堆末尾无效句 + 回符 | invalid_sentence / cursor | 悬挂符头、无效句后回符 |
| VM-014 | 回符中拒绝施法：反噬不消费 | forbidden_phantom / round | 准入优先于反噬（I3） |
| VM-015 | 归：句末返还 8 灵力 | refund | `timing: sentence_end`、clamp spirit_max |
| VM-016 | 禁符：本次生效、−20 神智、置反噬 | forbidden_phantom | S-0004 念禁符三件事 |
| VM-017 | 反噬：下一发整次变幻符 | forbidden_phantom | 反噬消费、成本照扣、I4 |
| VM-018 | 反噬中念禁符：不生效不扣神智 | forbidden_phantom | S-0004 phantom_rules 第 1 条后半、I1 |
| VM-019 | 反噬施法灵力不足仍必发 | forbidden_phantom / no_spirit | 反噬优先于灵力检查（clamp） |
| VM-020 | <33 的 15% 幻符替换：符脚保留 | forbidden_phantom | phantom_cast.reason=substitute、符脚作 payload、I5 |
| VM-021 | <33 且含禁符：不掷 15% 骰 | forbidden_phantom | S-0004 "本次含禁符时不掷骰" |
| VM-022 | 幻影符填充：禁符使神智跌破 33 | forbidden_phantom | 放置时序（施法收尾）、目标槽位注入 |
| VM-023 | 幻影符清除：神智 ≥33 时清除 | forbidden_phantom | 清理时序（牌堆构建前）、对牌堆的影响 |
| VM-024 | 敕·触：静态展开子句、共享游标 | trigger | 触发深度 1、子句成本、消耗顺序 |
| VM-025 | 奉·时：ttl 到期触发 | trigger | `on_expire` 语义 |
| VM-026 | 触发子句无符：空触发 | trigger | `empty_trigger`、trigger=null |
| VM-027 | 深度上限 3：第 4 层不展开 | limits | `depth_limit`、深度 4 不扣费不读牌 |
| VM-028 | 动作上限 64：恰好 64 不截断 | limits | 执行次数计数（count 展开）、边界 == 64 |
| VM-029 | 动作上限超限：count 被截断 | limits | `budget_exhausted_action`、count 钳制 |
| VM-030 | 投射物上限 32：超限截断 | limits | `budget_exhausted_projectile`、count 钳制 |

类别计数（`validate_cases.py` 校验，含多标签）：

| 类别 | 条数 | 要求 |
|---|---|---|
| `forbidden_phantom`（禁符/幻符/幻影符） | 10（VM-009、014、016–023） | ≥5 ✓ |
| `trigger`（触发递归） | 7（VM-024–030） | ≥5 ✓ |
| `limits`（深度/动作/投射物上限） | 4（VM-027–030） | 覆盖全 3 个上限 ✓ |
| `no_spirit`（灵力不足） | 3（VM-010、011、019） | ✓ |
| `invalid_sentence`（无效句） | 2（VM-012、013） | ✓ |
| `multi_body`（多符胆） | 2（VM-005、006） | ✓ |
| `cursor` / `shuffle`（抽牌游标/乱序） | 6（VM-001、004、007、008、009、013） | ✓ |
| `foot_attach`（符脚归属） | 5（VM-003、004、008、009、020） | ✓ |

### 6.5 自检

```bash
cd /tmp/gameV0 && python3 tests/vm_cases/validate_cases.py
```

**2026-11-15 自检结果**：

1. 结构自检：`python3 tests/vm_cases/validate_cases.py` → `OK: 30 条用例结构自检通过`（`cards: 16 | phantom: 2 | materials: 12`；类别计数见 `manifest.yaml`）。
2. 语义自检：另用一份**按本规格写的临时参考实现**（Python，未提交、不进仓库）跑全部 30 条期望 → **30/30 一致**。这只证明「规格 + 用例 + 一份实现」自洽，**不证明**规格本身符合你对玩法的期望；T3 仍需用 C++ 按本规格重写并在 ctest 里跑 30/30。

检查项：YAML 可解析；30 条且 id 唯一；必填字段齐全；card id 在 `cards.yaml`；动作 op/字段/默认值合法；物质 id 在 `data/materials.json`；deck 长度 = slots、cursor 合法、幻影槽位合法；`consumed` 与 `deck` 顺序一致（可推导时）；**灵力算术自洽**（`spirit_after == clamp(spirit − Σcost + Σrefund)`）；**神智算术自洽**（禁符 −20，反噬施法不扣）；I2（`sanity_after < 33` ⇔ `phantom_slots_after` 非空）；I5；不变量语法；manifest 计数一致。退出码 0 = 通过。

---

## 7. 决策状态

### 7.1 已定决策（**不得在本轮改动**，仅引用）

| 决策 | 来源 | 在本规格的落点 |
|---|---|---|
| 符头 +3 或 +5、符脚 +8~+30 | S-0002 `numbers` | §5.2（归 为例外，已拍板 #4，2026-11-16） |
| 禁符任何时候可念；念出 −20 神智；下一次施法整次反噬为幻符 | D3、S-0004 `rules` / `numbers.forbidden_cast` | §2.7 第 2、5 步 |
| 反噬那次施法若含禁符：禁符不生效、不扣神智 | S-0004 `phantom_rules` 第 1 条 | §2.7 第 2 步 |
| 反噬期间显示「污」印（UI） | S-0004 | 只在 `backlash_after` 状态里体现，不在动作里 |
| <33：每次施法 15% 把符胆替换为幻符（仍消耗灵力） | S-0004 `numbers.phantom_cast_chance` | §2.7 第 4 步 |
| <33 的 15% 替换：本次含禁符 / 已是反噬幻符时不掷骰 | S-0004 `phantom_rules` | §2.7 第 4 步 |
| <33：符位随机 1 格被幻影符占据（读时视为空位，不可移除，≥33 恢复） | S-0004 | §2.7 第 1、8 步 |
| 幻影符只占据不含禁符的符位 | S-0004 | §2.7 第 8 步 |
| 五行不进伤害公式 | S-0003 / `elements.in_damage_formula=false` | 动作只带 `element` 做视听主题，不参与数值 |
| 普通施法不扣神智 | D3 / S-0002 | §2.7（只有禁符扣） |
| 实验 B 通过标准 = 30 条用例全过 + 触发递归有深度与动作上限 | D4 | §6、§7.5 |

### 7.2 建议值（**2026-11-16 用户已拍板按此执行**；试用后按 T5 调）

| 项 | 建议值 | 理由 | 改动代价 |
|---|---|---|---|
| 触发递归深度上限 | 3（层，主句不计） | C46 要求上限；实测 3 层足够表达"陷阱/连锁"，再多玩家读不懂 | 改 1 处常量 + 相关用例 |
| 单次施法动作上限 | 64（执行次数，含 count 展开） | 5 张分身 × 3 符脚 ≈ 64，是"一眼能看完"的上限 | 同上 |
| 单次施法投射物上限 | 32 | 性能与画面可读性（480×270 下 32 发已满屏） | 同上 |
| 每张触发符头只挂 1 个子句 | 是 | 防止"多触发符头"嵌套爆炸；设计原文未定义 | 若改需重定深度语义 |
| 游标不回绕 | 是 | 单轮读符量可预测；代价是长触发链吃牌堆快 | 改 1 条规则 + 相关用例 |
| 触发子句静态展开（预付费） | 是 | 确定性与可测性（C46） | 要加 tick 级运行时用例，成本高 |
| 子句预读消耗共享游标 | 是 | 与设计伪代码 `cast_sub(wand, deck)` 一致 | — |

### 7.3 六条取舍（2026-11-16 已全部拍板）

| # | 取舍 | 现状（草案选择） | 替代方案 | 代价 / 争议 |
|---|---|---|---|---|
| 1 | **"每念几符"的单位** | 句（`sentences_per_cast`） | 符数（更贴 Noita 的 spells-per-cast） | 选句：语义清晰、触发链易控；选符：法器手感更像 Noita，但"句"概念失去载体，C06 的歧义仍在 |
| 2 | **触发子句什么时候付费** | 施法时静态展开即扣（灵力+神智） | 命中时再结算（延迟付费） | 选前者：可测、预算可控；选后者：更符合"延迟触发"直觉，但 VM 需要 tick 级运行时接口，30 条用例要重写，C46 要求更难满足 |
| 3 | **灵力不足的粒度** | 整句不念 + 本轮结束 | 念到哪算哪（逐符扣，能放几张放几张） | 选前者：玩家可预判"这发放不放得出"；选后者：手感更连续，但"差 1 点灵力"会变成部分生效，动作列表不可预测 |
| 4 | **归 的灵力成本** | 0（返还 8），与 S-0002 符脚 +8~+30 冲突；反噬施法灵力不足时扣 `min(spirit, 成本)` | 归 +8 且返还 16（净 −8，卡面 net 2 不成立）；反噬不足时不发（可被空灵逃避） | 涉及 F-0004 的"探索自循环"是否成立：归 若真收 8，土遁·归 净耗 10，探索循环成本高 5 倍。**这条影响玩法；已拍板取现草案（2026-11-16）** |
| 5 | **三个上限的具体数值** | 深度 3 / 动作 64 / 投射物 32 | 深度 2 或 4；动作 32；投射物 16 | 影响"组合爆炸"的乐趣上限与性能；建议先按 3/64/32 实现，试玩（T5）后调 |
| 6 | **15% 替换句带触发符头** | 替换只换符胆；触发子句**不展开、不扣灵力、不计 consumed**，游标停在子句首（不越过）；本次成本 = 主句直接符成本（§2.7 第 4 步补写） | 备选 A：保留触发子句，给 `phantom_cast` 增加 `trigger` 字段 | 现状：不改 C-ACT、确定性强；代价是替换会吞掉这一句的触发（`敕·触 + 幻符` 组合失效）。备选 A 要改 C-ACT（§3.2 第 16 项）+ T4b 世界层执行"幻符的延迟触发" |

**2026-11-16 用户拍板（「剩下的按你的建议来」）：6 条全部按本草案/AI 建议落定。**

| # | 拍板结果 | 说明 |
|---|---|---|
| 1 | **单位取「句」**（sentences_per_cast） | 三段式里一句=一次施法块；不改符数，C06 不再混淆 |
| 2 | **触发子句施法时预付费** | 与 Noita 一致；用例 VM-024~030 不变 |
| 3 | **灵力不足整句不念 + 本轮结束** | 不采用 Noita 式逐符部分施法；VM-010/011/019 不变 |
| 4 | **归 cost 0 / 返还 8** | 维持 F-0004 的 net 2；S-0002 符脚 +8~+30 的例外已记入 S-0002 deviations |
| 5 | **上限深度 3 / 动作 64 / 投射物 32** | 先按此实现，T5 试玩后调 |
| 6 | **替换句带触发取 Option B** | 不改 C-ACT；备选 A 仅留档 |

spec 由此进入 **v0.1 契约冻结候选**；后续若改语义，先改 tests/vm_cases（30 条）再改实现并回归。

**Noita 参考（2026-11-15 查证；细节与来源见 docs/log/2026-11-15-11-noita-vm-reference.md）**

| # | Noita 怎么做 | 对拍板的含义 |
|---|---|---|
| 1 | 按**符**计数：法杖属性 Spells/Cast（1–26），抽牌逐符推进 | 我们按**句**（三段式的一次施法块）；改符数会重定义符头/符胆/符脚归属，建议保持句 |
| 2 | 触发载荷**施法时预付费**（即使永不触发也会扣） | 与草案一致；本条可视为「有 Noita 先例支持」 |
| 3 | **逐符部分施法**：付不起的修正不附加、抽到付不起的符丢弃后继续抽，不整轮中止 | 草案「整句不念+本轮结束」更硬；要贴 Noita 可改成「跳过本句、继续读下一句」（需先改 VM-010/011/019 期望） |
| 4 | 无回符；Add Mana 是**蓝耗 −30 的负消耗修正**，预载时可暂超上限、结束后削回 | 「归」用负灵力语言与 Noita 一致；具体数值仍是设计选择 |
| 5 | 唯一明确数值上限是**递归等级 ≤ 2**（递归/复制类法术）；触发链无查到硬深度上限；无 per-cast 动作/投射物上限 | 深度 3 比 Noita 松一档、可解释；64/32 是自定确定性护栏，非照抄 |
| 6 | **无**神智/禁符/幻符系统 | 原创系统，不必对齐 Noita；按可读性/成本选 Option A/B |

> 附带：Noita 乱序是「每次施法从可用池随机抽」而非「回符时洗一次」（草案保留后者，可读性优先）；施放延迟与充能时间是两个独立计时器（与 cast_interval / recharge_ticks 一致）。

### 7.4 待定与数据缺口（不阻塞 T3，但 T3/T4 要知道）

| 项 | 状态 | 影响 |
|---|---|---|
| 洗牌 RNG 算法（散符法器） | 待定（调度层） | VM 只接收已排好的 deck；用例用显式顺序覆盖语义。T4 需要 `shuffle_seed` 的确定性算法（建议 splitmix64 + Fisher-Yates） |
| 化·金（设计 §3.3 符脚 +30） | **数据缺口**：`data/materials.json` 无"金/金属"物质 | 本卡表不提供化·金；用例不覆盖；补数据后加 1 条用例 |
| 墨弹（留墨液） | **数据缺口**：无 `ink` 物质 | 同上 |
| `heat_cloud` 的蒸汽材质 | **数据缺口**：materials.json 的 `r-lime-steam` 备注"蒸汽材质 v2 补" | `spawn_cloud` 用 `kind`+`tags` 表达，不写材质 id |
| 幻符池（"同层敌人符池"） | **数据缺口**：M0 无敌人符池数据 | 用例用 `rng.phantom_card` 注入占位幻符（`phantom-001/002`） |
| 五雷"导电物质传导" | 反应表缺"施法触发"类型（S-0005 open_questions） | 本草案五雷只做伤害动作，不传导 |
| 多个触发符头叠加语义 | 未定义 | 本草案取"每句只认第一个触发符头" |
| 投射物 `on_hit` 未命中（ttl 到期） | 由 T4 运行时决定 | VM 只生成动作；T4 记运行时事件 |
| 多句施法 + 15% 替换 + 触发符头 | 未定义（§2.7 第 4 步补写只固定 `sentences_per_cast=1`）；**T3 取最保守读法：替换句后不再读后续主句** | 30 条用例不覆盖；T4b 若需要不同口径，先补规则和用例再改实现 |
| 预算钳到 0 停止展开后的收尾 | 未定义；**T3 取 `cursor = 起始 + 已 consumed`，且仍走 §2.7 步骤 7/8（回符判定 / 幻影符放置）**——与 §2.5 fizzle「不做幻影符放置」不同 | 截断是「已念出、扣费、动作被钳」，fizzle 是「整句没念出」，本草案倾向保留两者不同、不统一成 fizzle（统一需 vm-impl 再改并补用例） |
| 替换句带 `归`（sentence_end 符脚） | 未定义；**T3 取 `归` 仍挂顶层、句末执行 `refund_spirit`**（§1.3 / §2.5）；§2.7 补写的「符脚保留为 `payloads`」只指载荷类符脚 | 30 条用例不覆盖；若 T4b 要据此做 combo（土遁·归 + 幻符），先补用例 |
| 神智 = 0 入魔 | M1 才做（S-0004） | T3 只需 clamp 到 0，不触发入魔 |

#### 7.4.1 2026-11-15 补写的边界口径（T3 复审后补；实现已固定，语义未改）

以下 6 条原先只存在于实现选择里、规格没写清；现写回规格。每条都不改已冻结的语义，也不改 30 条用例的期望（补丁后 `validate_cases.py` 仍 30/30 通过）。

1. **`sub_fizzle_no_spirit` 的 `consumed` / 游标**（§2.3 第 5 条）：子句灵力不足时，子句的符按"解析已读出"处理——计入 `consumed`、游标按解析推进到子句末，但子句**不扣费、不展开**（`trigger = null`），记 `sub_fizzle_no_spirit`。
2. **多主句中途 fizzle 的游标**（§2.5）：`cursor_after = 起始游标 + 已 consumed 数`（已念的句符已消耗，fizzle 句停在句首），与 §6.3 的游标口径及 T1 `validate_cases.py` 的自洽检查一致。
3. **`rng.phantom_slot` / `rng.phantom_card` 为 null 的兜底**（§2.7 第 2/4/8 步）：`phantom_slot = null` → **不放置**幻影符（不自造候选回退）；`phantom_card = null` → 反噬施法的 `phantom_cast.effect = null`，15% 替换**不掷骰**（不伪造幻符）。
4. **`refund_spirit` 的执行次数**（§2.4）：它是"其他 op"，`exec = 1`：计入 `action_count`，**也计入「已用执行次数」预算**（会挤占后续 spawn 的额度）；它自身不参与 spawn 的 `count` 钳制、也不单独截断。
5. **动作/投射物同时超限的事件顺序**（§2.4）：先按 64 钳动作（`budget_exhausted_action`），再按 32 钳投射物（`budget_exhausted_projectile`），两个事件按此顺序入列。
6. **一次施法读到多张禁符**（§2.7 第 5 步）：逐张按卡片顺序 −20 神智，各记一条 `forbidden_read` 与 `backlash_armed`（`backlash` 状态位幂等；卡表只有 1 张禁符，30 条用例不覆盖）。

> **T3 实现取最保守读法**：§7.4 表中标「未定义」的边界项，T3 统一按最保守 / 可复现读法实现（与 §7.4.1 同）。T4b 若需要不同口径，**先补规则 + 用例再改实现**，不要只改代码；本文件已于 2026-11-16 拍板 v0.1（见 §7.3），新增的行不改变已冻结语义。

### 7.5 T3 实现清单与验收

| 项 | 要求 |
|---|---|
| 源码位置 | `sim_core/vm/`（与 `sim_core` 同库不同模块；T2 已在 `sim_core/CMakeLists.txt` 预留 `add_subdirectory(vm)` hook） |
| 接口 | 一个纯函数 `CastResult cast(const CastRequest&)`，不碰世界、不碰引擎、无全局状态 |
| 输入 | §4.1；卡表从 `tests/vm_cases/cards.yaml` 读（测试模式；正式卡表后续从 `data/` 读） |
| 输出 | §4.2；动作结构体按 §3.2；事件按 §4.3 |
| 不做 | 投射物飞行/命中判定/世界执行/神智入魔/洗牌 RNG/回灵 tick 推进 |
| 验收 | `ctest` 里加一个用例读取 `tests/vm_cases/*.yaml` 跑 30/30；**30/30 全过才算实验 B 通过**（D4） |
| 失败处理 | 任一条失败 → 不砍触发符头，先对齐本规格；规格有歧义 → 回来改规格（并告知用户） |

---

## 附录 A：解析与展开伪代码（T3 参考）

```text
# ---------- 牌堆 ----------
deck(state, wand):
  return [c for i, c in enumerate(wand.deck)
          if c != null and i not in state.phantom_slots]

# ---------- 解析一句 ----------
parse_sentence(wand, state):
  d = deck(state, wand); i = wand.cursor
  heads = []; feet = []
  while i < len(d) and kind(d[i]) == head: heads.append(d[i]); i += 1
  if i < len(d) and kind(d[i]) == body:            # 正常句：符头* + 符胆 + 连续符脚*
      body = d[i]; i += 1
      while i < len(d) and kind(d[i]) == foot: feet.append(d[i]); i += 1
      return Sentence(invalid=false, heads, body, feet, end=i,
                      cost=Σ(heads)+cost(body)+Σ(feet))
  # 无符胆 → 无效句：吞掉"符头串 + 紧随其后的连续符脚串"这一段
  while i < len(d) and kind(d[i]) == foot: feet.append(d[i]); i += 1
  return Sentence(invalid=true, heads, feet, end=i, cost=Σ(heads)+Σ(feet))

> 无效句的吞牌口径（VM-012/VM-013 固定）：只吞"当前段"——符头串 + 紧随的连续符脚串；
> 不吞后面的符。所以 `[煞, 飞剑]` 的第一句只吞"煞"（cost 8），第二句从飞剑开始；
> `[飞剑, 敕·触]` 的第一句是正常句（飞剑），第二句吞"敕"（cost 5）后牌堆尽。

# ---------- 解析一轮（含触发子句，静态展开） ----------
parse_round(wand, state):
  plan = Plan(sentences=[], has_forbidden=false, total_cost=0)
  cursor = wand.cursor
  for n in 1..wand.sentences_per_cast:
      if cursor >= len(deck): break
      s = parse_sentence_at(cursor); cursor = s.end
      s.triggers = []
      for head in s.heads where head.effect.trigger exists:      # 每句只认第一个触发符头
          if depth_of(s) >= max_trigger_depth: event(depth_limit); break
          if cursor >= len(deck): event(empty_trigger); break
          sub = parse_sentence_at(cursor)                        # 子句本身也可带触发 → 递归
          sub = parse_with_nested(sub, cursor, depth+1)          # 递归展开
          s.triggers.append(sub); cursor = sub.end
          break
      plan.sentences.append(s); plan.total_cost += s.cost + Σ子句成本
      plan.has_forbidden |= any_forbidden(s)
  plan.end_cursor = cursor
  return plan

# ---------- 执行展开（预算钳制） ----------
expand(sentence, depth, budget):
  if sentence.invalid: return []
  head_effects = fold(sentence.heads)          # damage_mult 乘法、projectile_mult 乘法、trigger
  count = head_effects.projectile_mult (默认 1)
  per = 1 + Σ executions(p) for p in [body.payloads..., feet...] + trigger 子树 executions
  # 动作上限：执行次数
  affordable = floor((max_actions - budget.used_actions) / per)
  if count > affordable: count = affordable; event(budget_exhausted_action); budget.stopped = true
  # 投射物上限
  if budget.used_projectiles + count > max_projectiles:
      count = max_projectiles - budget.used_projectiles; event(budget_exhausted_projectile); budget.stopped = true
  if count <= 0: budget.stopped = true; return []
  budget.used_actions += count * per; budget.used_projectiles += count
  action = spawn_projectile(spell=body.id, count=count, damage=body.damage*damage_mult,
                            payloads=map(apply_mult, body.payloads+feet_actions),
                            trigger=trigger_from(sentence, depth))
  return [action] + ([] if count == 0 else [])   # trigger.actions 在生成期已计入 budget
```

（上面的 `parse_with_nested` / `apply_mult` / `executions` 为描述性伪代码；T3 实现时可改写法，但**必须复现 §6.4 的 30 条期望值**。）

---

## 附录 B：变更记录

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-11-15 | 0.1（草案） | 首版：回答 T1 的 8 个问题；定义 C-VM / C-ACT / C-CASE；30 条用例；标待用户审定 |
| 2026-11-16 | 0.1（拍板，**不计版本变更**） | 用户对 §7.3 全部 6 条按 AI 建议拍板（句 / 预付费 / 整句不念 / 归 cost 0 / 3-64-32 / Option B）；状态改为「v0.1 已拍板｜契约冻结候选」。语义未改 |
| 2026-11-15 | 0.1（澄清，**不计版本变更**） | T3 复审补丁：§2.7 第 4 步补「替换句带触发符头」的规则（只换符胆；子句不展开/不扣灵力/不计 consumed；游标停子句首；成本=主句直接符成本）；§7.3 新增待拍板 #6（备选 A 保留触发需给 `phantom_cast` 加 `trigger`）；§7.4 新增 §7.4.1 六条边界口径（①sub_fizzle 的 consumed/游标 ②多主句 fizzle 游标 ③rng null 兜底 ④refund 执行次数 ⑤上限事件顺序 ⑥多张禁符）与一条待定。**语义未改，只补空白**；仍为草案 v0.1｜待用户审定 |

## 附录 C：与其它文档的关系

| 文档 | 关系 |
|---|---|
| `docs/02-m0-plan.md` T1/T3 | 本文件是 T1 产出；T3 按本文件实现并跑 `tests/vm_cases/` |
| `refs/cards/p0/systems.yaml` S-0002/S-0004 | 数值与禁符/幻符规则的**上级**依据；冲突时以卡片为准（本文件 §5.2/§7.3 记录例外） |
| `data/materials.json` | 动作里物质 id 的唯一来源；8 种 `result.type` 是 C-ACT 的设计上限 |
| `data/magic_numbers.json` sanity 段 | 禁符/幻符/幻影符数值的**唯一来源**，本文件不新增数值 |
| `docs/design/刍狗_概念设计v0.1_原文.md` §4.5 | 伪代码起点；本文件改为静态展开 + 预算化（批注 C46） |
| `docs/log/` | 本任务的记录由 Lead 统一落盘（分工边界：本 agent 不写 docs/log/） |

