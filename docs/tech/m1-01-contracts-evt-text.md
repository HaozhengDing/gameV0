# M1-01 契约草案：C-EVT（世界事件）与 C-TEXT（文本键）v0.1

> **状态：草案 v0.1（待用户审定后冻结）**｜制定：2026-11-20｜下游：M1 全部任务（M1-02 ~ M1-12）
> **依据**：`docs/01-decision-twist.md`（D1 可读性、D2 规矩、D3 污染边界）、`docs/03-roadmap.md` §3.3、`refs/naming.md` §5（克制单字/去中二原则）、`data/materials.json`（已有 `$mat_*` 键）。
> **修改规矩**：冻结后破坏性变更须版本号 +1、写 log 列出受影响下游，并同步更新 `tools/validate_data.py`。

---

## Part 1｜C-EVT v0.1（世界事件契约）

### 1.1 目标与边界

- **是什么**：连接「模拟器（`sim_core`）/ 符箓 VM / 玩法逻辑」与「可读性表现层（粒子、音效、HUD 短提示、死因记录）」的**单向事件总线协议**。
- **原则**：
  1. 事件是**纯数据**（只含 id/坐标/数值/字符串键，不传递引擎节点引用），可被 C++、GDScript、无界面回归测试统一序列化和断言；
  2. **D1 可读性硬约束**：凡是「玩家可见/可感知」的事件，表现层必须实现 `visual / audio / text` 中**至少 2 个通道**；
  3. **D2 规矩硬约束**：规矩触发只产出世界物质/实体事件（`rule_triggered` 必伴随 `reaction_triggered` 或实体生成），**禁止**通过 `rule_triggered` 直接扣神智或血量。

### 1.2 通用事件信封（Envelope）

```json
{
  "seq": 1042,
  "tick": 3600,
  "type": "reaction_triggered",
  "pos": [632, 228],
  "actor": "player",
  "target": "",
  "material": "sulfur",
  "reaction_id": "r-black-powder",
  "value": 25.0,
  "aux": "radius=40",
  "text_key": "$react_black_powder"
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `seq` | int | 是 | 本局单调递增序号（便于去重、录播与测试断言） |
| `tick` | int | 是 | 发生时的 `sim_world_tick`（固定 60 Hz） |
| `type` | string | 是 | 见 §1.3 受控枚举（18 种） |
| `pos` | `[int, int]` | 否 | 世界 cell 坐标（空间事件必填，全局状态事件可省略） |
| `actor` | string | 否 | 发起者 id（`"player"` / `"world"` / 实体 id） |
| `target` | string | 否 | 受影响实体 id |
| `material` | string | 否 | 涉及的物质 id（必须在 `data/materials.json` 或 C-SIM 材质表中） |
| `reaction_id` | string | 否 | 反应 id（必须在 `data/materials.json` `reactions` 中） |
| `value` | float | 否 | 主数值（伤害、半径、神智变化、熄灯数等） |
| `aux` | string | 否 | 补充标签（如伤害类型 `火`/`阴`/`毒`、状态名 `burning`/`wet`/`stun`、拒因） |
| `text_key` | string | 否 | 指向 C-TEXT 的 `$key`（用于短提示/死因记录；代码不拼写死中文） |

### 1.3 受控事件目录与可读性通道（18 种）

| 组 | `type` | 触发来源 | 关键字段 | 必填可读性通道（至少 2 项） |
|---|---|---|---|---|
| **物质与反应** | `reaction_triggered` | C-SIM v3 反应表 | `pos`, `reaction_id`, `value`, `text_key` | 视觉（爆/光/烟色）+ 音效 + 短提示（三选二） |
| | `fire_ignited` | C-SIM v3 / 施法 | `pos`, `material` | 火焰色块闪烁 + 点火短音效 |
| | `fire_extinguished` | C-SIM v3 / 喷水 | `pos`, `value`(格数) | 蒸汽白雾 + 嘶嘶灭火音效 |
| | `steam_created` | 水+火 / `r-lime-steam` | `pos`, `value` | 白灰上升气体 + 蒸汽音效 |
| | `smoke_created` | 硫烟 / 竹木燃烧 | `pos`, `material` | 黄绿/深灰气体 + 警报音效（毒烟另出短提示） |
| | `terrain_dug` | `sim_world_dig` | `pos`, `material`, `value` | 碎屑沙粒子 + 碎石音效 |
| **战斗与状态** | `entity_damaged` | M1-02 战斗 | `pos`, `actor`, `target`, `value`, `aux`(伤类) | 受击闪烁 + 命中音效 + 跳字（可选） |
| | `entity_killed` | M1-02 战斗 | `pos`, `actor`, `target` | 消散效果 + 击杀音效 |
| | `status_applied` | M1-12 / M1-02 | `pos`, `target`, `aux`(`burning`/`wet`/`stun`/`poison`), `value`(秒) | 角色/敌人状态色标（火/水滴/定）+ 状态音效 |
| | `lantern_extinguished` | M1-05 阴伤/禁符代付 | `target`, `value`(盏), `aux`(原因) | HUD 灯格熄灭闪烁 + 熄灯低沉音效 |
| | `lantern_restored` | 洞天/道具 | `target`, `value` | HUD 灯格点亮 + 点灯音效 |
| **符箓与神智** | `spell_cast` | T3 VM 受理 | `pos`, `actor`, `aux`(card ids) | 施法光圈/投射物 + 施法音效 |
| | `spell_fizzle` | T3 VM 灵力不足/冷却 | `actor`, `aux`(reason) | 蓝条短闪 + 哑火音效 |
| | `forbidden_cast` | T3 VM 禁符 | `pos`, `actor`, `value`(-20) | 屏幕边缘暗闪 + 裂响音效 + 挂「污」印 |
| | `backlash_triggered` | T3 VM 反噬幻符 | `pos`, `actor`, `aux`(phantom id) | 紫暗光圈 + 异响音效 + 清「污」印 |
| | `sanity_changed` | M1-08 四来源/恢复 | `actor`, `value`(delta), `aux`(source) | 神智条波动 + 阈值音效（跨越 66/33/0） |
| | `possession_entered` | M1-08 归零入魔 | `actor`, `text_key` | 画面边缘暗晕 + 心跳/低鸣音效 + 极简短字 |
| | `possession_exited` | M1-08 回到 ≥20 | `actor`, `value`(魔痕数) | 视野恢复清亮 + 钟磬清音 + 魔痕标记 |
| **规矩与进程** | `rule_triggered` | M1-04 硬规矩 | `pos`, `aux`(rule_id), `text_key` | 必伴随真实物质/实体事件 + 提示音效 |
| | `hazard_triggered` | 塌方/水银禁回灵 | `pos`, `aux`(hazard_id) | 落石/蓝条锁色 + 警告音效 |
| | `room_entered` | M1-04 进新房/洞天 | `pos`, `aux`(room_id), `text_key` | 顶部极简淡入地名（可无声，与环境音切换配对） |
| | `run_ended` | M1-09 死亡/通关 | `aux`(`death`/`victory`), `text_key`(死因) | 结算界面（展示死因与已触发反应列表）+ 结算音效 |

> 说明：列表共 22 条细项（覆盖 M1 全部 4 组）；同帧同格的高频同类 `sim_core` 底层事件（如 1 tick 点燃 30 格火）在桥接进 GDScript `EventBus` 时做**按帧/按区域节流聚合**（如合并为 1 条带 `value=30` 的事件），避免刷爆音效与日志。

### 1.4 C-SIM v3 底层事件桥接约定

`sim_core/include/sim/c_sim.h` 已有 `sim_event` 环形缓冲（4096 槽）和 3 个枚举值（`SIM_EVENT_FIRE_IGNITED=1`, `SIM_EVENT_FIRE_EXTINGUISHED=2`, `SIM_EVENT_DIG=3`）。M1-12 升级 **C-SIM v3** 时，仅在末尾 append-only 追加：
- `SIM_EVENT_REACTION = 4`（`aux` 存 reaction 表下标）
- `SIM_EVENT_STEAM = 5`
- `SIM_EVENT_SMOKE = 6`
并在 `SimWorldNode` 新增 `poll_events(max_count: int) -> Array[Dictionary]`，每 tick 由 `main.gd` 消费并转入 `EventBus`。

---

## Part 2｜C-TEXT v0.1（文本键契约）

### 2.1 目标与三条硬规则

1. **零硬编码可见文本**：M1 起所有玩家可见文本必须通过 `TextDB.get_text(key, sanity)` 查询，禁止在脚本里散落写死中文；方便后续本地化与版号词表替换（设计原文风险 1）。
2. **极简克制命名红线（`refs/naming.md` §5）**：
   - 基础 HUD 状态优先彩色条/图标 + 数字，能不写字就不写字；
   - 保留明确有出处的正统道教符语（`急急如律令`、`天罡`、`敕·触`、`奉·时`、`五雷`、`镇`、`归`），其余动作一律克制单字或 1–2 字直白功能词；
   - 符组不另起合体名，由 `TextDB` 按 `segments` 拼接单卡名（如 `斩 + 爆`）。
3. **D3 认知污染可机检边界（`corruptible` 硬字段）**：
   - 每条文本条目必须显式声明 `"corruptible": true | false`；
   - **已学会 / 规则已知类域**（`$mat_*`、`$card_*`、`$react_*`、`$ui_*`）强制 `"corruptible": false`——**永不乱码**；
   - **未知 / 叙事探索类域**（`$rule_*`、`$lore_*`、`$item_unid_*`）允许 `"corruptible": true`——当 `sanity < 66` 时，可切换到同条目的 `corrupted` 变体（手工撰写的错字/假信息，而非破坏 UTF-8 的随机乱码，保证仍然可读且有诡异感）。

### 2.2 命名空间与格式规范

统一格式：**`$<domain>_<snake_id>`**（直接兼容 `data/materials.json` 已有的 `$mat_water`、`$mat_quicksilver` 等 12 个键）。

| 前缀 | 域 | 示例键 | `zh-CN` 示例 | `corruptible` 强制规则 |
|---|---|---|---|---|
| `$mat_` | 物质名 | `$mat_water` / `$mat_quicksilver` | `水` / `水银` | **必须 `false`** |
| `$card_` | 单张符卡名 | `$card_head_urgent_order` / `$card_body_flying_sword` | `急急如律令` / `斩` | **必须 `false`** |
| `$react_` | 反应短提示（≤6 字） | `$react_black_powder` / `$react_sulfur_toxic_smoke` | `黑火药爆` / `硫磺毒烟` | **必须 `false`** |
| `$status_` | 实体状态短词（≤3 字） | `$status_burning` / `$status_wet` / `$status_stun` | `燃` / `湿` / `镇` | **必须 `false`** |
| `$ui_` | 界面/结算极简词 | `$ui_complete` / `$ui_death_fire` | `本轮完成` / `死于火伤` | **必须 `false`** |
| `$enemy_` | 敌人与 BOSS 名 | `$enemy_coal_ghost` / `$enemy_drought_demon` | `矿鬼` / `旱魃` | **必须 `false`** |
| `$room_` | 区域/房间名 | `$room_silver_pit` / `$room_hub_cave` | `水银池` / `洞天` | 允许 `true`（未探索标记）或 `false` |
| `$rule_` | 碑文/口述规矩 | `$rule_no_open_flame` | `矿里不能用明火` | **允许 `true`**（需配 `corrupted` 文本） |
| `$lore_` | 残页/线索 | `$lore_xu_jiu_01` | `……` | **允许 `true`** |
| `$item_unid_` | 未鉴定物品描述 | `$item_unid_vial` | `盛着暗红液体的瓷瓶` | **允许 `true`** |

### 2.3 词表文件格式（`data/texts/zh-CN.json`，冻结后创建）

```json
{
  "schema": "gamev0.texts/v0.1",
  "version": "0.1",
  "locale": "zh-CN",
  "entries": {
    "$mat_water": { "text": "水", "corruptible": false },
    "$card_head_urgent_order": { "text": "急急如律令", "corruptible": false },
    "$card_body_flying_sword": { "text": "斩", "corruptible": false },
    "$react_black_powder": { "text": "黑火药爆", "corruptible": false },
    "$rule_no_open_flame": {
      "text": "矿里不能用明火。",
      "corruptible": true,
      "corrupted": "矿里必须多点火，才看得见路。"
    }
  }
}
```

### 2.4 接入 `tools/validate_data.py` 的校验规则（M1-01 冻结时落地）

1. 所有 `$key` 格式符合 `^\$[a-z]+_[a-z0-9_]+$`，无重复键，无空文本；
2. 强制域校验：`$mat_` / `$card_` / `$react_` / `$status_` / `$ui_` / `$enemy_` 项的 `corruptible` **必须为 `false`**（机器守护 D3 铁律）；
3. `corruptible: true` 的条目必须提供非空 `corrupted` 变体；
4. 引用完整性：`data/materials.json` 的全部 `ui_key`、以及后续 `data/biomes/` / `data/entities/` 中声明的 `text_key` 都必须在 `data/texts/zh-CN.json` 中存在。
