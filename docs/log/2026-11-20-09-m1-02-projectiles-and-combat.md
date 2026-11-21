# 2026-11-20-09 M1-02 落地：真实投射物、全 16 种 C-ACT 战斗框架与 8/8 民俗反应闭环

- **日期**：2026-11-20
- **类型**：更新（核心玩法系统 + 自动化战斗回归）
- **篇幅**：详细（新增 3 个战斗模块 + 替换 T4b 即时命中 + 补齐全部 8/8 反应）
- **前置**：`docs/log/2026-11-20-08-m1-12-csim-v3-reactions.md`（C-SIM v3）、`docs/tech/talisman-vm-spec.md` §3（C-ACT 16 op）、`docs/04-m1-plan.md`

---

## 1. 结论

**M1-02（战斗与投射物框架）已完成，且 M1-12 剩余 3 条「材质 × 实体标签」反应全部贯通——`data/materials.json` 全部 8 条民俗反应与 C-ACT 全部 16 种动作现已 100% 实机可运行并经 headless 自动化回归通过**：

1. **移除 T4b 即时命中，切换真实投射物飞行**：`game/scripts/combat/projectile.gd` 与 `combat_manager.gd` 消费 T3 VM 产出的 `spawn_projectile`（速度、扇形散射 `spread_deg`、子步 1 cell 射线步进防穿墙、穿透 `pierce`、存活 `ttl_ticks`、`payloads` 与静态展开的 `on_hit`/`on_expire` 触发树）。
2. **全 16 种 C-ACT op 零 NOOP**：`spawn_projectile` / `explode` / `damage` / `ignite` / `spawn_cloud` / `purify` / `barrier` / `grant_temp_slot` / `convert_material` / `spawn_material` / `dig` / `apply_status` / `extinguish_lantern` / `drain_life` / `refund_spirit` / `phantom_cast` 全部落地，且严格遵循冻结契约 `C-EVT v0.1`（发布 `spell_cast` / `spell_fizzle` / `terrain_dug` / `entity_damaged` / `entity_killed` / `status_applied` / `reaction_triggered`）。
3. **战斗实体与 `weak_to`**：`game/scripts/combat/combat_entity.gd` 落地阵营、生命、实体标签（`spirit`/`eldritch`/`paper`）、仅按实体 `weak_to` 乘算（严守 `elements.in_damage_formula=false`）、状态机（`burning`/`wet`/`stun`/`slow`/`poison`）、血条与受击闪白绘制；矿井内放入 2 个灰盒靶标（`矿鬼`/`土蝼`）供即刻实机试射。
4. **8/8 民俗反应全通**：补齐 `r-dog-blood-spirit`（黑狗血 × `spirit` 消耗血并造 20 阳伤）、`r-quicksilver-ward`（水银 × `eldritch` 阻挡且不消耗水银）、`r-cinnabar-talisman`（朱砂 × `paper` 消耗朱砂并赋 60s 临时符位 +1）。

---

## 2. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **`convert_material` 投射物在液面即刻触发** | 当投射物携带 `convert_material` payload（如 `F-0002 火+化水`）时，碰撞除 `is_solid` 外也在液体表面触发 | 解决「向水银池射化水符，投射物沉到深池底才转化、玩家吸不到表面水」的手感问题 | 若需在液面下深处转化，须从池边斜射（对矿井池水构图反而更直觉） |
| **投射物速度系数 `0.375 cells/tick`** | VM 默认 `speed=12` 映射为 `4.5 cells/tick`（`270 cells/s`），子步按 `1 cell` 步进 | 半屏飞行约 0.8s，清晰可见弹道与拖尾且不卡顿；子步保证永不穿透 1 格墙或 5×10 实体 | 极高速弹（`speed>40`）每 tick 子步数增加，若未来加高射速弹幕需关注单 tick 预算 |
| **`extinguish_lantern` 对敌人折算阴伤** | 对普通敌人按 `lanterns × 30` 结算 `"阴"` 属性伤害；对玩家由七星灯（M1-05）直接熄灯 | 敌人无七星灯双轴，让 `F-0003（阴+镇）` 在矿井战斗中即刻具备清晰伤害与定身价值 | 未来若出现拥有魄灯机制的特殊 Boss，需为该实体单独分支处理 |

---

## 3. 文件改动与验证结果

### 改动清单
- 新增 `game/scripts/combat/combat_entity.gd`：战斗实体、状态机、`weak_to` 伤害结算与 3 条实体标签反应。
- 新增 `game/scripts/combat/projectile.gd`：真实投射物实体、拖尾、元素配色与液面判定标志。
- 新增 `game/scripts/combat/combat_manager.gd`：全 16 种 C-ACT 执行器、子步碰撞、穿透、`on_hit`/`on_expire` 触发树与灰盒可视化绘制。
- 修改 `game/scripts/executor.gd`：`cast()` 委托 `CombatManager` 发射真实投射物，删除 137 行旧 T4b 即时命中与 NOOP 代码，补齐 `spell_cast` / `spell_fizzle` 事件。
- 修改 `game/scripts/main.gd`：挂接 `CombatManager`、放置 2 个靶标实体（`矿鬼`/`土蝼`）、接入击杀与实体反应 HUD 反馈，并将 `--t4b-smoke` 升级至 10 步回归（真实弹道化水/爆破/土遁/阴镇定身 + 穿透/弱点/触发树/吸血/全部 8 条民俗反应）。
- 更新 `docs/04-m1-plan.md`：标注 M1-12 与 M1-02 已完成。

### 验证结果
| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **通过** |
| `sim_core` ctest（MSVC Release） | **8/8 通过** |
| `Godot --headless -- --t4b-smoke` | **通过**（`T4B_SMOKE_OK`，0 ERROR / 0 NOOP；含 `pierce=ok weak_to=2x triggers=2 reacts_8of8=ok`） |
| `Godot --headless --quit-after 900` | **通过**（900 帧 0 错误） |
| `Godot -- --t4b-shot` | **通过**（窗口渲染正常，室 1 矿鬼靶标与血条清晰可见） |

---

## 4. 下一步

- 按 `docs/04-m1-plan.md` 依赖顺序推进下一批核心任务：
  1. **M1-05（七星灯双轴：100 气血 + 7 盏魄灯上限折减）**——硬依赖 M1-02 已解锁，周期 0.5 周；
  2. **M1-03（符箓三段式完整 + 3 种法器 + 洞天极简组装 UI）**；
  3. **M1-04（矿井一层完整 Wang Tile 程序化拓扑 + 手工房间拼接 + 连通性校验）**（关键路径）。
