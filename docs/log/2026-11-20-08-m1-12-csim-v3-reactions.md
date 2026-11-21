# 2026-11-20-08 M1-12 落地：C-SIM v3 反应表 + 热/火引擎 + Godot 事件与状态接入

- **日期**：2026-11-20
- **类型**：更新（契约升级 + 核心模拟 + 引擎接入 + 压测）
- **篇幅**：详细（C-SIM v2 → v3 版本号 +1，改动 ≥ 3 文件，含 10k tick 开发机压测数字）
- **前置**：`docs/04-m1-plan.md`（M1 计划生效）、`docs/tech/sim-fire-heat-design.md`、`docs/tech/m1-01-contracts-evt-text.md`

---

## 1. 结论

**M1-12 格层核心已全部完成并通过全套自动化验证**：

1. **C-SIM 升级至 v3（`c-sim/3.0.0`）**：保持每格 **4 字节**零内存增长、v1/v2 全部材质 id 与语义向后兼容；末尾追加 3 种二级气体（`smoke` / `toxic_smoke` / `steam`，共 19 种材质），复用 `Cell.aux` 承载固体/粉末燃料燃烧计时与邻域传热，并按 priority 落地 5 条格层反应。
2. **开发机 10,000 tick 性能远优于预算（开发机数据，非目标机 go/no-go）**：新增 `burn-worst`（全屏燃烧+反应压测）p95 **0.818 ms**（预算 ≤ 6.000 ms），`typical-pan`（3×3 屏相机平移）p95 **0.151 ms** / p99 **0.265 ms**（无唤醒尖刺），原有 `worst-wake` p95 **2.466 ms**、`typical-sleep` p95 **0.161 ms**。
3. **移除临时 GDScript 火焰补丁，全面切真 C-SIM v3 + C-EVT + C-TEXT**：`SimWorldNode` 新增 `apply_heat_burst` / `poll_events` / `get_cell_aux` / `reaction_id_str` / `get_sim_version`；`main.gd` 每 tick 聚合桥接至 `EventBus` 并以 C-TEXT 词表输出反应提示；`executor.gd` 与 `hud.gd` 落地实体 `burning` / `wet` / `poison` 状态及徽章。
4. **遗留说明**：8 条反应中剩余 3 条属于「材质 × 实体标签」反应（`r-dog-blood-spirit`、`r-quicksilver-ward`、`r-cinnabar-talisman`），依赖战斗实体与标签系统，将在紧接着启动的 **M1-02（战斗与投射物框架）** 内接入。

---

## 2. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **Cell.aux 复用燃料燃烧态** | 静态/粉末可燃材质（`bamboo`/`coal`/`sulfur`）用 `Cell.aux` 存剩余燃烧 tick（`0` = 未燃，`>0` = 燃烧中），替代新建逐格温度场 | 保持 `sizeof(Cell) == 4`；休眠区与未燃区 0 额外内存/CPU 开销；修复「平铺煤/硫堆表面火苗飘走后 2 tick 断燃」的物理缺陷 | 燃烧计时上限受 `uint8_t` 限制为 255 tick（约 4.25s；当前 `coal` 180 / `bamboo` 120 / `sulfur` 90 均在范围内，若未来需要更长燃烧可改为步进分频） |
| **热源 + 邻域阈值 + priority 排序** | 火（`400°C`）、燃中燃料（`350°C`）与 `apply_heat_burst` 按 `priority 10 r-black-powder` → `priority 1 r-sulfur-toxic-smoke` → `priority 0 可燃点燃` 判定 | 满足 `data/materials.json` 明确优先级（硝+硫+煤先爆、纯硫先冒毒烟不消耗硫磺），且热计算仅发生在活跃火源 4 邻域 | 无远距离热传导（符合 `sim-fire-heat-design.md` §3.1 结论，不做连续热场） |
| **C-SIM 事件按 tick 聚合再入 C-EVT** | `main.gd` 每 tick `poll_events(256)` 后按 `reaction_id` / `fire_ignited` 聚合，每类每 tick 最多发 1 条 `EventBus` 事件，HUD 提示按反应类型 120 tick 节流 | 防止大片燃烧或爆炸单 tick 淹没事件总线与 HUD 日志（守 `m1-01-contracts-evt-text.md` §2.5） | 丢失同 tick 内多点同类反应的逐格坐标细节（仅保留首/末代表点），对 UI/音效反馈无影响 |

---

## 3. 契约变更与受影响下游（C-SIM v2 → v3）

- **契约文件**：`sim_core/include/sim/c_sim.h`（`SIM_C_SIM_VERSION` `2u → 3u`，`sim_version()` → `"c-sim/3.0.0"`）。
- **兼容性**：严格 append-only——v1/v2 全部材质 id（0..15）、枚举值与原有 C 函数签名完全不变；仅在末尾追加：
  - 材质 id：`SIM_MAT_SMOKE=16`、`SIM_MAT_TOXIC_SMOKE=17`、`SIM_MAT_STEAM=18`（`SIM_MAT_COUNT_=19`）
  - 反应枚举：`sim_reaction_id`（`1..5` 对应 5 条格层反应）
  - 事件类型：`SIM_EVENT_REACTION=4`、`SIM_EVENT_STEAM=5`、`SIM_EVENT_SMOKE=6`
  - C 函数：`sim_world_material_ignition_temp`、`sim_reaction_id_str`、`sim_world_apply_heat_burst`
- **受影响下游**：`game/gdextension/src/sim_node.{h,cpp}`（已同步重建 Debug+Release DLL）、`game/scripts/{level,executor,main,hud}.gd`（已同步切换）、`docs/03-roadmap.md` / `docs/04-m1-plan.md` / `sim_core/README.md` / `game/gdextension/API.md`（均已同步）。

---

## 4. 10,000 tick 性能基准（开发机数据，非目标机 go/no-go）

环境：Windows 11 + MSVC 19.51 Release（`/O2`，单线程），`sim_bench --ticks 10000 --seed 20261115 --no-frames --materials data/materials.json`，契约 `c-sim/3.0.0`：

| 场景 | 模式 | mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | max (ms) | 预算对照 |
|---|---|---:|---:|---:|---:|---:|---|
| `worst-wake` | wake（保守上界） | 2.196 | 2.260 | **2.466** | 2.602 | 3.904 | D4 ≤ 6.000 ms |
| `worst-sleep` | sleep（默认） | 1.250 | 1.244 | **1.649** | 2.515 | 3.445 | D4 ≤ 6.000 ms |
| `typical-sleep` | sleep（默认） | 0.121 | 0.113 | **0.161** | 0.241 | 0.600 | D4 ≤ 2.000 ms |
| `typical-wake` | wake（敏感性） | 0.498 | 0.494 | **0.522** | 0.567 | 0.940 | D4 ≤ 2.000 ms |
| **`burn-worst`** | sleep（全屏燃烧） | 0.749 | 0.722 | **0.818** | 2.012 | 4.234 | M1-12 ≤ 6.000 ms |
| **`burn-wake`** | wake（全屏燃烧上界） | 0.756 | 0.726 | **0.828** | 2.010 | 4.241 | M1-12 ≤ 6.000 ms |
| **`typical-pan`** | sleep（视口平移） | 0.023 | 0.000 | **0.151** | **0.265** | 0.627 | 无平移尖刺 |

> 注：以上为开发机数据，不替代目标机复测（见 `docs/tech/m0-a-report.md` §7 与 `docs/04-m1-plan.md` §1.2）。

---

## 5. 文件改动与验证结果

### 改动清单
- `sim_core/include/sim/c_sim.h`、`sim_core/src/materials.{h,cpp}`、`sim_core/src/world.cpp`：C-SIM v3 核心实现。
- `sim_core/tests/test_main.cpp`、`sim_core/bench/{bench_main,png_writer}.cpp`、`sim_core/CMakeLists.txt`、`sim_core/vm/CMakeLists.txt`：`sim_reactions` 6 组反应测试、`burn-worst`/`typical-pan` 压测、MSVC + 可选 ZLIB 构建兼容。
- `game/gdextension/src/sim_node.{h,cpp}`、`game/gdextension/API.md`：暴露 C-SIM v3 新接口并重建 Windows Debug/Release DLL。
- `game/scripts/{level,executor,hud,main}.gd`：移除旧 GDScript 火焰补丁，接入 `apply_heat_burst`、`poll_events → EventBus → C-TEXT`、玩家 `burning`/`wet`/`poison` 状态与 HUD 徽章，升级 `--t4b-smoke` 回归。
- `sim_core/README.md`、`docs/03-roadmap.md`、`docs/04-m1-plan.md`：同步契约版本与进度。

### 验证结果
| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **通过**（29 卡 / 18 符卡 / 71 C-TEXT / 30 VM 用例 / 12 材质 / 8 反应 / 2 房间） |
| `sim_core` ctest（MSVC Release） | **8/8 全过**（含 `sim_reactions` 6 子项 + `vm_cases` 30/30 + `vm_edge_cases` 5/5，0 编译警告） |
| `game/build.bat`（GDExtension Debug + Release） | **通过**（`T4A_BUILD_OK`） |
| `Godot --headless -- --t4b-smoke` | **通过**（`T4B_SMOKE_OK`，含竹木燃炭、硫磺毒烟、黑火药、石灰蒸汽、糯米净阴、灼烧/湿润状态） |
| `Godot --headless --script res://tests/smoke_sim.gd` | **通过**（`SMOKE_OK`） |
| `Godot --headless --quit-after 900` | **通过**（900 帧 0 错误） |
| `Godot -- --t4b-shot` | **通过**（窗口渲染与 HUD 目检正常） |

---

## 6. 下一步

- 立即开工 **M1-02（战斗与投射物框架）**：把 `executor.gd` 的即时命中替换为真实投射物实体（飞行/重力/地形与实体碰撞/穿透/消费 T3 VM `payloads` 与 `on_hit`·`on_expire` 动作树），落地伤害类型与 `weak_to` 克制、实体受击组件，并顺带挂接 M1-12 剩余 3 条实体标签反应（`r-dog-blood-spirit`、`r-quicksilver-ward`、`r-cinnabar-talisman`）。
