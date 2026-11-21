# 2026-11-21-01 M1-05 落地：七星灯双轴（100 气血 + 7 盏魄灯上限折减）与极简 HUD

- **日期**：2026-11-21
- **类型**：更新（核心生存机制 + UI）
- **篇幅**：详细（新增 `vitals.gd`，改动 ≥ 3 文件，替换旧的整数 7 盏占位伤害模型）
- **前置**：`refs/cards/p0/systems.yaml`（S-0004）、`data/magic_numbers.json`、`docs/04-m1-plan.md`

---

## 1. 结论

**M1-05（七星灯双轴）已完成并回归通过**：

1. **双轴解耦落地**：新增 `game/scripts/vitals.gd`，运行时从 `data/magic_numbers.json` 读取 `player.hp = 100` 与 `player.lanterns = 7`。普通伤害（火/灼烧/毒烟/物理/爆炸）只扣气血；阴性伤害（如接触 `yin_qi` 每秒熄 `0.3` 盏）直接熄灭魄灯并支持小数残烛累积。
2. **每熄一盏上限 -1/7**：`lit_lantern_cap = ceil(lanterns)`，有效气血上限 `effective_max_hp = 100 × lit_lantern_cap / 7`。跨过整盏门槛时立即钳制当前气血，且 `heal_hp()`（含 `drain_life` 吸血）严格受有效上限约束，直至复灯（`restore_lanterns()`）恢复上限；气血归零或七盏尽熄均判死亡并发布 `entity_killed` / `lantern_extinguished` C-EVT 事件。
3. **极简双轴 HUD**：`hud.gd` 左上资源卡升级为「7 盏琥珀灯格（支持小数残烛长度填充）+ 气血红条（亮红当前值 / 暗红有效上限 / 深灰锁死上限）+ 法力 + 浮空 + 葫芦水油双条」，严守 `refs/naming.md` §5 极简无冗余标签约定。

---

## 2. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **整盏门槛 `ceil(lanterns)` 折减上限** | `7.0 → 6.6` 仅残灯变暗不扣上限，累积跨过 `6.0`（彻底熄灭 1 盏）后气血上限立减 `1/7`（`85.7`） | 贴合 S-0004「每熄一盏气血上限 -1/7」与 `0.2–0.5` 小数阴伤的直观可读性：玩家看见残灯快灭时有清晰预警窗口 | 单次轻度阴伤（0.2 盏）不会立刻压低上限，但会留下可见的残烛亏损 |
| **环境伤害按单一数据源数值结算** | 直接贴火 12 HP/0.5s；灼烧 2 HP/s（`burning_dps_max_hp_ratio=0.02`）；毒烟 3 HP/s（`r-sulfur-toxic-smoke`）；阴气 0.3 盏/s（`yin_damage_lanterns=[0.2, 0.5]`） | 淘汰 T4b 的「30 tick 掉 1 盏」占位规则，正式对齐 `magic_numbers.json` 与 `materials.json` | 贴火致死时间略长于灰盒（约 4.2s），M1-06/M1-11 可按手感微调 |

---

## 3. 文件改动与验证结果

- 新增 `game/scripts/vitals.gd`：七星灯双轴状态机与 C-EVT 发布。
- 修改 `game/scripts/executor.gd`：接入 `vitals`，拆分普通气血伤与阴气熄灯，挂接死亡复位与死因键。
- 修改 `game/scripts/hud.gd`：实现 7 盏残烛灯格 + 带锁死上限段的气血红条，微调面板宽度（`316 → 332`）避免数字贴边。
- 修改 `game/scripts/main.gd`：初始化 `vitals`、把 `combat.player_heal_callback` 接到 `vitals.heal_hp`，在 `--t4b-smoke` 新增 Step 11（七星灯双轴全断言）。
- 更新 `docs/04-m1-plan.md`：标注 M1-05 已完成。

| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **通过** |
| `Godot --headless -- --t4b-smoke` | **通过**（Step 11 `hp=100->70 eff_6of7=85.7 restore=100.0`） |
| `Godot -- --t4b-shot` | **通过**（新 HUD 7 灯格 + 血条布局目检清晰） |

---

## 4. 下一步

- 立即开工 **M1-03（符箓三段式完整游标 + 3 把法器 + 洞天安全区改符 UI）**，随后推进 **M1-04（矿井一层完整 Wang Tile + 手工房间拼接）**。
