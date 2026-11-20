# T4b 灰盒规格（Godot 侧）——矿井 10 分钟可玩一轮

> 状态：**已实现（2026-11-16）｜打磨 + 火焰灰盒补丁（2026-11-20）**；本文是实现契约，具体参数以代码常量为准（`game/scripts/level.gd` / `executor.gd` / `player.gd` 顶部常量）。依赖 T4a 构建链 + T1 VM（C-VM/C-ACT v0.1 已拍板）+ C-SIM v2。
> 本文是 GDScript 世界层（`game/scripts/`）的实现契约；C++ 侧 API 见 `game/gdextension/API.md`。

## 1. 目标（02 计划 T4b 完成标准）

1. 角色移动 + 挖掘；
2. P0 的 4 组符（F-0001~F-0004，数据在 `data/talismans.json`，经 `TalismanVMNode.cast_group()` 出 C-ACT 动作）；
3. 葫芦：先支持**水、油**两种液体（吸取 / 喷出）；
4. 矿井灰盒：用 `data/rooms/room-01-silver-pit.json` + `room-02-gas-pocket.json` + 一个出口；
5. 一个设计好的组合时刻：**用「毕方火·化·水」把水银池转成水 → 葫芦取水 → 喷水灭火 → 通过火障到出口**；
6. 玩家自测 10 分钟内能跑完一轮，并至少经历一次组合生效。

不做：神智/入魔/洞天/旱魃战斗/水墨后处理/存档。

## 2. 世界与关卡（level.gd）

- 世界 **960×540 cells**，`SimWorldNode` 缩放 4 → 3840×2160 px；相机跟随玩家。
- 初始：全部填 `rock`，再挖出连通走廊（程序化即可）。
- 房间放置：读 `data/rooms/room-01-silver-pit.json`（水银池，含 quicksilver/water/coal/saltpeter/bamboo）放在**西侧**；`room-02-gas-pocket.json`（硫磺/煤/硝石，含瓦斯囊）放在**东侧**。每个 grid 字符按 room 的 `tile_size=16` 展开为 **16×16 cells**（房间 24×14 字符 = 384×224 cells ≈ 0.8 屏），坐标加偏移；legend 名称直接映射 C-SIM v2 材质（未知材质 push_error，不做替身映射）。
  - 读取：`FileAccess.get_file_as_string("res://../data/rooms/xxx.json")` 不可用（res:// 不能出工程）；用 `ProjectSettings.globalize_path("res://").path_join("../data/rooms/xxx.json")`，与 T4a 读 materials 的方式一致。解析用 Godot `JSON.parse_string`。
  - `legend` 里 `"empty"` → 材质 0；其它用 `sim.material_id(name)`。
- **火障**：在两房间之间的唯一走廊上放一条 3–4 格宽的火墙 + 油带（`oil` 铺地 + `fire` 点燃）；玩家穿过会掉「盏」（见 §4）。
- **出口**：房间 02 东侧再挖一段通道，放出口区（坐标为常量并在 HUD 显示「向东到出口」）；玩家进入 3×3 cells 范围即触发通关。
- 实现常量（level.gd 顶部）：世界 960×540；room01 offset=(40,148)、room02 offset=(536,148)；走廊 y260..275（16 cells 高），连接段 x0..39 / x424..535 / x920..959；门洞 16×16 打在房间墙上；火墙 x480..482 × y260..275 = 48 格，油槽 y276 × x468..494 = 27 格；起点 (16,270)、出口 (940,269)（3×3 zone）。
- 角色：视觉 20×40 px（=5×10 cells @SCALE=4），碰撞 5 宽×10 高。
- 玩家起点：房间 01 西侧走廊。
- 相机：`Camera2D` 挂在玩家上，限制在世界范围内（`limit_left/right/top/bottom`）。
- 每帧只渲染视口：`view = 玩家 cell − (240,135)`，裁到世界内 480×270；`sim.update_texture_region(vx,vy,480,270)`，`sim.position = Vector2(vx,vy)*4`；每帧 `sim.set_active_rect(视口外扩 64 cells)` + 移动时 `sim.wake_rect(...)`。
- `data/materials.json` 路径：`ProjectSettings.globalize_path("res://").path_join("../data/materials.json")`。

## 3. 输入与玩法

| 键 | 作用 |
|---|---|
| A/D / 左右方向键 | 行走（68 cells/s + 1–3 格碎屑自动迈步；火格不可进入；落粉可脱困） |
| W / 上 / Space | 起跳与 Noita 式有限浮空（消耗浮空黄条，落地快速回充；水中阻力、水银轻浮力）；S/下加速下潜 |
| 鼠标 | 瞄准（`get_global_mouse_position() / 4` → cell；右上极简显示材质与可燃标记） |
| 左键 | 施放当前符槽 `vm.cast_group(selected)`，执行返回的 actions 并显示反馈光圈 |
| 1 / 2 / 3 / 4 | 切换符槽（`1 斩 + 爆` / `2 火 + 化水` / `3 阴 + 镇` / `4 掘 + 归`）；顶中 4 槽平铺，不显示合体名与内部编号 |
| E | 葫芦吸取：鼠标周围半径 6 的 `water`/`oil` 格 → 存入葫芦（水容量 200、油容量 100；由初版 3 调至 6 便于吸薄水层） |
| Q | 葫芦喷出（当前液体；Tab 切换水/油）：自胸口沿玩家→鼠标方向铺 12 格（遇实心墙停止），每格耗 1；仅喷水灭火 |
| F | 手动点火（灰盒火焰补丁）：点燃鼠标周围半径 3 内可燃物，或空地放半径 1 火种 |
| R | 重开（重置世界/玩家/葫芦/VM） |

施法反馈：HUD 一行显示 `accepted/reject_reason`（如「灵力不足」「回符中」）；动作执行结果（如爆炸挖开墙）直接体现在世界。

### 3.1 动作执行（executor.gd，C-ACT 子集）

T4b 只执行这些 op（其余 no-op + 打日志）：
- `spawn_projectile`：T4b 做**命中判定简化为即时命中**——在瞄准点执行其 `payloads`，若 `trigger` 存在则再执行 `trigger.actions`；`count/damage/speed` 只用于 HUD/视觉，不做投射物实体。
- `explode`：`sim.dig(aim, radius)`；挖坑后对半径 `radius + 3` 的坑缘可燃物（`sim.get_material_flammable(id)`）点燃并登记蔓延。
- `ignite`：瞄准点周围 radius 2 内可燃物 → `sim.set_cell(i,j, fire_id)`。
- `convert_material`：瞄准点 radius 内，**非静态、非空**的格转为目标材质（液体/粉末；本作 combo 用：水银→水）；静态岩层不动。
- `dig`：`sim.dig`。
- `spawn_material`：在水/油/阴气等合法材质处 set_cell（形状 pool/solid 简化为圆形填充）。
- `refund_spirit`：VM 已内部结算，executor 忽略。
- 其余（damage/apply_status/drain_life/extinguish_lantern/barrier/purify/spawn_cloud/grant_temp_slot/phantom_cast 的 effect 按上面同规则递归）：T4b 无敌人/状态，执行即 no-op + `print`。

### 3.2 火光/伤害（灰盒最小规则）

- 火格（`fire`）= 危险：玩家 5×10 身体盒外扩 1 格接触火时，每 0.5s 掉 1 盏并红色闪烁提示；盏 7 → 0 时**回到起点**并复原盏（世界保留）。
- 喷水灭火：仅在喷水（非喷油）时，喷到的水格周围 **半径 12** 内的火格 → 置空、命中的火墙源格本局不再重燃（记 combo 事件）。半径 12 是 16 格高火墙下的灰盒调参（半径 3 只能开出 7 格缺口，10 格高身体过不去）；使「取水→灭火→通过火障」成为必要路径。
- 到达出口（跨越出口走廊全高 `y 260..276`、`x >= 939`）→ HUD 显示「本轮完成」，可按 R 重开。

> 灰盒说明（2026-11-20 更新）：火/燃烧仍是灰盒占位，不是 M1 反应表；本次在 `game/scripts/` 补齐两个灰盒补丁（见 `docs/tech/sim-fire-heat-design.md` §5）：① `level.tick_flammable_spread` 追踪活跃火格，按统一 **1.5%/tick** 点燃相邻非油可燃材质（煤/硫磺/竹木，`sim_core` 原生 5%/tick 点燃油不变）；② `F` 键手动点火与 `explode` 坑缘引燃。仍不读 `ignition_temperature`，无烟/蒸汽/黑火药爆炸（留 M1-12）。

## 4. 组合时刻（验收用）

1. 玩家在房间 01 用 F-0002（毕方火·化·水）打**水银池**：quicksilver → water（`convert_material` 生效）；
2. 用 E 在水上吸取（葫芦水量 > 0）；
3. 走到火障前，Q 喷水 → 火熄灭（HUD 记录 combo）；
4. 穿过火障 → 出口通关。
事件日志（HUD 最近 3 条）里应出现「化水成功」「取水 N」「灭火」。

## 5. 文件与边界

| 文件 | 内容 |
|---|---|
| `game/scripts/main.gd` | 入口：建世界/关卡、玩家、相机、HUD、输入、固定步长（1/60）主循环、R 重开、combo 日志、`--t4b-smoke` 自检流程 |
| `game/scripts/player.gd` | 移动/碰撞/朝向（Node2D；cell 坐标浮点） |
| `game/scripts/level.gd` | 世界初始化、房间 JSON 读取与放置、走廊/火障/出口、重置 |
| `game/scripts/executor.gd` | C-ACT 动作执行 + 葫芦吸/喷 + 火伤害/灭火规则 |
| `game/scripts/hud.gd` | 灵力/盏/葫芦/符组/指向材质/事件日志/底部键位提示/通关提示 |
| `game/scripts/overlay.gd` | 瞄准准星与施法/吸液/喷液/手动点火的短暂视觉反馈 |
| `game/tests/t4b_smoke.gd` | 可选：独立 SceneTree 自检（或由 main.gd 的 `--t4b-smoke` 承担） |
| 运行方式 | `godot --path game`；无界面：`godot --headless --path game -- --t4b-smoke`；截图：`godot --path game -- --t4b-shot`（存仓库根 t4b_shot.png） |

**不要改** `game/gdextension/`、`data/`、`docs/`、`sim_core/`；构建由 Lead 在电脑上跑（GDScript 改动无需重编 DLL）。

## 6. 验收（Lead 在电脑上跑）

1. `godot --headless --path game -- --t4b-smoke` → 打印 `T4B_SMOKE_OK` 且 exit 0（脚本化走一遍：化水→取水→灭火→通关）。
2. `godot --headless --path game --quit-after 300` → `T4B_WORLD_READY`，无 SCRIPT ERROR。
3. 可视化：玩家能移动、4 组符能施放并影响世界、葫芦能吸/喷、火障必须灭火才能过、到出口提示通关。
