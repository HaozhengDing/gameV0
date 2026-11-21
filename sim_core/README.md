# sim_core

无引擎依赖的格子物质模拟库（C++17 + CMake），服务于《刍狗》M0 实验 A / T2 及 M1-12 反应与热/火引擎。
公开头文件 <code>include/sim/c_sim.h</code> 即对外契约 **C-SIM v3**（C ABI，供 Godot GDExtension
直接调用）；基准程序无界面，有 zlib 时可写 PNG、无 zlib 时自动降级 `--no-frames`。

当前范围（按 D4 / M1-12 定）：

- 1 cell = 1 世界像素；固定 tick 1/60 s；单线程、确定性（同 seed 同操作序列 = 同结果）；每格严格 4 字节（`static_assert` 守护）
- chunk 64×64 + 脏矩形 + 活动区（只模拟视口附近）+ chunk 休眠调度
- 物质状态：powder / liquid / gas / static
- 5 种基础实验物质 + 岩（v1）：沙 sand、水 water、油 oil、火 fire、水银 quicksilver（密度 13.6）、岩 rock
- C-SIM v2（T4b）追加 9 种 data 物质：black_dog_blood / coal / saltpeter / sulfur / cinnabar / lime / glutinous_rice / bamboo / yin_qi
- **C-SIM v3（M1-12）**末尾追加 3 种二级气体材质（`smoke` / `toxic_smoke` / `steam`，共 19 材质，已有 id/语义不变）：
  - 复用 `Cell.aux` 承载固体/粉末燃料（竹木/煤/硫磺）的燃烧计时与热源邻域传导（零内存增长、休眠区零开销）
  - 5 条格层反应按 priority 落地：`r-black-powder`（priority 10，硝+硫+煤遇热 ≥ 120°C 引爆）、`r-sulfur-toxic-smoke`（priority 1，不耗硫磺）、`r-bamboo-burn`（竹木燃成煤）、`r-lime-steam`（石灰+水→蒸汽，25% 凝回水）、`r-rice-purify`（糯米净阴气且不消耗糯米）
  - 新增 `sim_world_apply_heat_burst`、`sim_world_material_ignition_temp`、`sim_reaction_id_str` 与 `SIM_EVENT_REACTION` / `SIM_EVENT_STEAM` / `SIM_EVENT_SMOKE`
- 挖掘 dig（移除实心/粉末格，部分变沙碎屑）
- 13 种 data 物质参数（含 `ignition_temperature`、`burn_time`、`burn_product`）运行时读 <code>data/materials.json</code>；读不到 JSON 时回退编译期默认值并提示
- **不做**：刚体碎裂、多线程、全屏连续温度扩散场、持久化（按 D4 / `sim-fire-heat-design.md` 排除）

## 构建

依赖：CMake ≥ 3.20、C++17 编译器（g++ 13 / MSVC VS2022+ 已验证）、Ninja（可选）、zlib 开发包（可选，基准 PNG 用）。

    cd sim_core
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build

产物：<code>build/libsim_core.a</code>（或 `sim_core.lib`）、<code>build/sim_bench</code>、<code>build/sim_core_tests</code>、<code>build/vm/vm_cases_runner</code>。

## 测试（ctest，8 个）

    cd sim_core/build
    ctest --output-on-failure

| 测试 | 覆盖 |
|---|---|
| sim_determinism | 同 seed 两世界逐段 hash 相同；不同 seed 发散 |
| sim_dig | 圆形挖掘移除实心格、碎屑沙、圆外不受影响、DIG 事件 |
| sim_conservation | 封闭石墙内沙/水/油/水银 500 tick 数量守恒；边界不被写出 |
| sim_api_contract | chunk 载入/卸载、脏矩形、活动区、渲染、事件、材质表、越界安全 |
| sim_materials_json | 从 data/materials.json 读取全部 data 物质参数（含 C-SIM v3 燃点/燃烧产物与 3 种二级气体） |
| sim_reactions | **M1-12**：黑火药 priority 10 优先于硫磺毒烟、纯硫不消耗冒毒烟、竹木燃炭、石灰遇水生蒸汽与凝水、糯米净阴、水灭火生蒸汽 |
| vm_edge_cases | 符箓 VM 5 条边界回归 |
| vm_cases | 符箓 VM 30 条契约用例全过 |

测试程序也可单独跑：<code>./build/sim_core_tests all --materials ../data/materials.json</code>
（不传 <code>--materials</code> 时用编译期默认材质）。

## 跑基准（10,000 tick，四类场景）

    cd sim_core/build
    ./sim_bench --ticks 10000 --seed 20261115 --out bench-frames

- **worst**：480×270 = 1 屏，78% 填充沙/水/油/水银/火混合（`worst-wake` 保守上界 / `worst-sleep` 默认）。
- **typical**：1440×810 = 3×3 屏矿井灰盒，299 个 chunk 全载入，只模拟中间 480×270 视口（`typical-sleep` / `typical-wake`）。
- **burn-worst（M1-12 新增）**：480×270 全屏混填竹木/煤/硫磺/油/水/硝石/火 + 周期热冲击，压测燃烧与反应表热点（`burn-worst` / `burn-wake`）。
- **typical-pan（M1-12 新增）**：1440×810 矿井内活跃视口每 200 tick 平移切换，验证平移唤醒 chunk 无性能尖刺。
- 只计 <code>sim_world_step()</code> 的时间（逐 tick 计时），场景维持注入/唤醒/出帧都在计时外。
- 输出：stdout 表格（总耗时、mean、p50/p95/p99、min/max、平均扫描 cell/chunk）、
  <code>bench-frames/summary.txt</code>、每 1000 tick 一张 480×270 PNG。

可选参数：<code>--out DIR</code>、<code>--seed N</code>、<code>--materials PATH</code>、<code>--no-frames</code>、<code>--ticks N</code>。
材质路径默认从 cwd / 可执行文件目录向上找 <code>data/materials.json</code>，也可用环境变量
<code>SIM_CORE_MATERIALS</code> 覆盖。

**当前开发机基准数字与 D4 目标对照见 <code>docs/tech/m0-a-report.md</code>**
（标注「开发机数据，非 go/no-go 依据」；目标机复测方法见该报告 §7）。

## 目录结构

    sim_core/
      include/sim/c_sim.h      # 契约 C-SIM v2（公开头文件，含单位/语义注释）
      src/world.cpp            # 世界/chunk/物质运动/挖掘/脏矩形/休眠/事件/渲染/hash
      src/materials.{h,cpp}    # 材质表 + data/materials.json 覆盖 + 路径查找
      src/json_lite.{h,cpp}    # 无依赖最小 JSON 读取器
      bench/bench_main.cpp     # 两个基准场景
      bench/png_writer.{h,cpp} # zlib 写 PNG
      tests/test_main.cpp      # 5 个 ctest
      vm/                      # （预留）T3 的符箓 VM 模块，存在 vm/CMakeLists.txt 即自动并入
      CMakeLists.txt
      .gitignore               # 忽略 build/、bench-frames/、*.png

## 作为库接入（T4 GDExtension）

<code>include/sim/c_sim.h</code> 是 C ABI，godot-cpp 可直接 include 并链接 <code>libsim_core.a</code>。
最小用法：

    sim_config cfg = {480, 270, 12345, 64, 1.0f/60.0f, "data/materials.json"};
    sim_world* w = sim_world_create(&cfg);
    sim_world_set_active_rect(w, (sim_rect){0, 0, 480, 270});
    for (;;) {
      sim_world_step(w);                       // 1 tick = 1/60 s
      sim_rect dirty = sim_world_dirty_rect(w, 1);
      // 渲染：把 dirty 区域用 sim_world_render_rgba8() 或 sim_world_copy_rect_materials() 取出来
    }
    sim_world_destroy(w);

约定：同一 world 单线程调用；1 cell = 1 世界像素；活动区边界按墙处理；chunk 可载入/卸载
（v1 卸载会丢内容，无持久化）。

## 已知限制

见 <code>docs/tech/m0-a-report.md</code> §6。最重要的三条：① 单线程、无渲染/玩法竞争，只测 sim tick；
② typical 场景大量 chunk 休眠，真实相机移动会更贵；③ 模拟规则是 v1 简化（无速度/温度/反应表）。

## 与其它任务的关系

- T3（符箓 VM）：在 <code>sim_core/vm/</code> 下加模块；CMakeLists.txt 已留 hook：
  <code>if(EXISTS .../vm/CMakeLists.txt) add_subdirectory(vm) endif()</code>（见 CMakeLists.txt 末尾）。
- T4a（Godot GDExtension）：用本头文件接入；<code>sim_core</code> target 已导出 include 目录。
