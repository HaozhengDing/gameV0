# game/ —— T4a Godot 灰盒（GDExtension 接入 sim_core）

> 状态：T4a 骨架（2026-11-16）｜依赖 C-SIM v1（`sim_core/include/sim/c_sim.h`，已冻结）
> 计划：`docs/02-m0-plan.md` T4a｜契约：C-SIM（03 §3.3）

## 这是什么

一条命令构建、可运行的 Godot 4.5 工程：

- `gdextension/`：C++ 包装（`SimWorldNode`），把 **真 sim_core** 编译进 GDExtension（静态链接，直接编译 `sim_core/src/*.cpp`，不依赖 bench/tests/zlib）。
- `scripts/`：GDScript 场景/输入（main.gd 建测试关卡、驱动 tick、R 渲染；player.gd 角色移动）。
- `tests/smoke_sim.gd`：无界面自检（GDExtension 是否加载、C-SIM 接口、同 seed 确定性、渲染）。

**桩替换不成立了吗？** 不。Godot 侧只依赖 `SimWorldNode` 暴露的 C-SIM 方法（create_world/step_tick/set_cell/dig/render_image…）；换回桩或换实现只要保持同一组方法，`scripts/` 不用改。

## 前置

| 项 | 版本 |
|---|---|
| Godot | 4.5（`Godot_v4.5-stable_win64.exe` 或对应的 linux 版） |
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
版本号 4.5 与 Godot 4.5 必须一致，否则 `.gdextension` 的兼容性检查会拒绝加载。

## 运行

    godot --path game                 # 可视化：WASD 移动，左键挖掘
    godot --headless --path game --script res://tests/smoke_sim.gd   # 无界面自检，应输出 SMOKE_OK
    godot --headless --path game --quit-after 120                    # 跑 120 帧后退出（CI/回归用）

## 已知限制（T4a 范围）

- 固定每帧 1 tick（简化）；T4b 改固定步长累加器 + 活动区跟随相机。
- 只渲染整屏（480×270 的全量 RGBA 上传）；C-SIM 的 `get_dirty_rect` 已暴露，T4b 再做脏矩形部分上传。
- 角色移动不校验 solid（挖掘/碰撞留给 T4b 接 sim 判定）；无符箓 VM（T4b 接 C-ACT）。
- 工程用 GL Compatibility 渲染（移动端/集显友好）；水墨后处理不在 T4a/T4b 范围内。

## 与后续任务的关系

| 任务 | 怎么接 |
|---|---|
| T4b | 把 `main.gd` 的测试关卡换成 `data/rooms/` 房间；接 `sim_core/vm` 的 C-ACT 动作执行；相机跟随 + 脏矩形上传 |
| T5 试玩 | 用同一工程 + 灰盒美术 |
