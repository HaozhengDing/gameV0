# game/ —— Godot 灰盒（T4a 构建链 + T4b 可玩灰盒）

> 状态：T4a 完成（2026-11-16）｜T4b 灰盒完成（2026-11-16）｜T4b 打磨 + 火焰灰盒补丁（2026-11-20）｜契约：C-SIM v2（`sim_core/include/sim/c_sim.h`）、C-VM/C-ACT v0.1（`docs/tech/talisman-vm-spec.md`）
> 计划：`docs/02-m0-plan.md` T4a/T4b｜规格：`game/T4B.md`｜API：`game/gdextension/API.md`

## 这是什么

一条命令构建、可玩的 Godot 4.5 灰盒：

- `gdextension/`：C++ 包装（GDExtension）
  - `SimWorldNode`：C-SIM v2（`sim_core`）的 Sprite2D 包装——世界创建/step/cell 读写/挖掘/**视口区域渲染**/材质查询/碰撞判定；sim_core 源码直接编译进扩展（不依赖 bench/tests/zlib）。
  - `TalismanVMNode`：T3 参考符箓 VM（C-VM/C-ACT）的包装——读 `data/talismans.json`，按符组 `cast_group()` 返回 C-ACT 动作列表与灵力/回符状态。
- `scripts/`：GDScript 世界层（规格见 `game/T4B.md`）
  - `main.gd`：装配、固定步长 1/60、相机跟随 + 视口渲染、输入、HUD、重开、`--t4b-smoke` / `--t4b-shot`
  - `level.gd`：960×540 cells 矿井关卡；`data/rooms/` 两个房间按 `tile_size=16` 展开（384×224 cells/间）、走廊、火障 + 油槽、出口、灰盒可燃材质统一蔓延（1.5%/tick）
  - `executor.gd`：C-ACT 子集执行（spawn/explode/ignite/convert/dig/spawn_material…）+ 葫芦吸/喷 + 手动点火 + 火伤与灭火
  - `scripts/feedback/`：M1-10 反馈层（打击感六层）——`fx_layer.gd` 世界空间符火/火星/爆散/飘字、`screen_fx.gd` 白闪与受击红晕、`sfx_bank.gd` 程序化分层音效、`feedback_director.gd` 消费 C-EVT 的顿帧/震屏/后坐（规范见 `docs/tech/m1-feedback-juice.md`）
  - `player.gd`：Noita 式轻量物理移动（重力 + 碎屑 3 格自动迈步 + W/Space 有限浮空条 + 液体浮力/阻力 + 火伤闪烁）；`hud.gd`：极简彩色状态条 + 4 符槽平铺 + 材质提示 + 键位条；`overlay.gd`：瞄准准星与施法/喷液反馈圈
- `tests/`：`smoke_sim.gd`（T4a 扩展自检）、`t4b_smoke` 由 main.gd 承担

**桩替换**：Godot 侧只依赖 `SimWorldNode` / `TalismanVMNode` 的方法；换桩或换实现保持同一组方法即可，`scripts/` 不用改。

## 前置

| 项 | 版本 |
|---|---|
| Godot | 4.5（`Godot_v4.5-stable_win64.exe` 或对应 linux 版） |
| godot-cpp | 4.5 分支/tag（`godot-4.5-stable`） |
| CMake | ≥ 3.22 |
| Ninja | 任意近版 |
| 编译器 | Windows：VS 2022+ C++ 桌面工作负载；Linux：GCC/Clang C++17 |

## 构建（一条命令）

Windows（cmd/PowerShell）：

    set GODOT_CPP_DIR=C:\path\to\godot-cpp
    game\build.bat

Linux / macOS：

    GODOT_CPP_DIR=/path/to/godot-cpp ./game/build.sh

产物：`game/bin/gdsim.windows.template_{debug,release}.x86_64.dll`（Linux 为 `libgdsim.*.so`）。
Godot 与 godot-cpp 的大版本必须一致（4.5 ↔ godot-cpp 4.5），否则 `.gdextension` 兼容性检查会拒绝加载。

## 运行

    godot --path game                     # 可视化试玩
    godot --headless --path game --quit-after 300                  # 无界面跑 300 帧（回归用）
    godot --headless --path game -- --t4b-smoke                    # T4b 组合时刻自检（T4B_SMOKE_OK + exit 0）
    godot --headless --path game --script res://tests/smoke_sim.gd # T4a 扩展自检（SMOKE_OK）
    godot --path game -- --t4b-shot                                # 窗口模式截一张 t4b_shot.png 后退出
    godot --path game -- --t4b-fx-shot                             # 同上，但先点亮反馈层六层并冻结在峰值帧（目检用）

## 操作

| 键 | 作用 |
|---|---|
| A/D / 左右方向键 | 水平行走（自动迈过 1–3 格碎屑；火格不可进入） |
| W / 上 / Space | 起跳与有限浮空（消耗黄条，落地快速回充；液体中轻耗可游起）；S/下加速下潜 |
| 鼠标 / 左键 | 瞄准（右上显示指向材质）/ 施放当前符槽 |
| 1 / 2 / 3 / 4 | 切换符槽：`1 斩 + 爆` / `2 火 + 化水` / `3 阴 + 镇` / `4 掘 + 归` |
| E | 葫芦吸取（瞄准点半径 6 的水/油） |
| Q | 葫芦喷出（自胸口沿玩家→鼠标方向 12 格，遇实心墙停止；仅喷水灭火） |
| Tab | 切换葫芦液体（水/油） |
| F | 手动点火（灰盒演示：点燃瞄准点半径 3 内可燃物或空地放火种） |
| R | 重开本轮 |

## 10 分钟可玩循环（T4b 验收）

1. 从西侧走廊出发，进房间 01（水银池）：用 `[2] 火 + 化水`（F-0002）打水银池 → 水银变水；
2. E 在新增的水上吸取（葫芦水量 +）；
3. 走到走廊火障西侧，Q 喷水灭火（火格清除、火焰不再重燃）；
4. 穿过火障 → 房间 02（瓦斯囊：硫磺/煤/硝石，可燃）→ 东侧出口，进入出口即「本轮完成」。
   符槽 `[1] 斩 + 爆`（爆炸挖岩）/ `[4] 掘 + 归`（挖掘 + 返还法力）可用于开路；`[3] 阴 + 镇` 在 T4b 无敌人，仅验证 VM 接口（动作 no-op）。

## 已知限制（T4b 范围）

- 施法命中简化为**即时命中**（不做投射物实体/飞行/穿透）：`spawn_projectile` 的 payload/trigger 在瞄准点立即执行；damage/apply_status 等无敌人系统，no-op。
- 无神智/入魔/洞天/旱魃/存档；火伤用「7 盏」灰盒占位，盏尽回起点；**火/燃烧是灰盒规则**：`sim_core` 仅原生点燃油（5%/tick），T4b 灰盒世界层额外对煤/硫/竹木（`flammable=true`）提供统一 1.5%/tick 蔓延 + `F` 手动点火演示（不消费 `ignition_temperature`，无烟/蒸汽/黑火药反应；正式反应表留 M1-12，见 `docs/tech/sim-fire-heat-design.md`）。
- 房间按 `tile_size=16` 展开；正式关卡拓扑/拼接（wangi tile + spliced rooms）留到 M1-04。
- 渲染为 C-SIM 调试色（材质颜色 + 坐标抖动），不是美术；相机视口 480×270 cells（内部 1920×1080、4 倍像素）。
- 中文 HUD 依赖 `ui_font.tres`（SystemFont，Windows 回退 Microsoft YaHei）；无字体环境会退化为方块。

## 与后续任务的关系

| 任务 | 怎么接 |
|---|---|
| M1-03 符箓组装 UI | 用 `TalismanVMNode` 已有 `cast_group` 换成「符位牌堆 + 抽牌游标」即可，VM 不用改 |
| M1-04 关卡组装 | 用 biome 的 `rooms`/aabb + `tile_size` 生成完整一层；level.gd 的房间加载可复用 |
| T5 试玩 | 用本工程，灰盒美术；观察「化水→取水→灭火」是否被玩家自发发现 |
| 实验 A 目标机 | 与本工程无关（sim_core 基准见 `docs/tech/m0-a-report.md`） |
