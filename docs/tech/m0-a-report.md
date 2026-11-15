# M0 实验 A 报告：sim_core 最小原型 + 基准测试（开发机先行）

> **开发机数据，非 go/no-go 依据。**
> D4 规定实验 A 必须在**目标机**（4 核、单核 i5-8400 / Ryzen 5 2600 级、8 GB、1080p）上测：开发机比目标机强时结果不算数。本报告的作用只有三个：① 证明原型可构建、可运行、契约可用；② 给出开发机数字，作为目标机结果的对照基线；③ 写清局限与目标机复测方法。**是否通过实验 A，以目标机复测为准。**
>
> - 产出：<code>sim_core/</code>（C++17 + CMake，无引擎依赖）、基准程序、5 个 ctest、本报告、4 张代表帧
> - 日期：2026-11-15｜执行：DeepSeek（team task-1）｜计划依据：<code>docs/02-m0-plan.md</code> T2、<code>docs/01-decision-twist.md</code> D4

## 结论

| 判定项 | 开发机结果 | D4 目标 | 结论 |
|---|---|---|---|
| 构建（cmake + ninja，Release） | 0 error / 0 warning | 必须通过 | ✅ |
| ctest | **5/5 通过** | ≥3 | ✅ |
| worst 场景 p95（480×270 全屏混合，每 tick 强制唤醒全部 40 chunk） | **2.245 ms/tick** | ≤ 6 ms | ✅ 余量约 2.7×（仅开发机） |
| worst 场景 p95（默认 chunk 休眠） | 1.459 ms/tick | ≤ 6 ms | ✅（开发机） |
| typical 场景 p95（1440×810 矿井灰盒，活跃视口 480×270，默认休眠） | **0.145 ms/tick** | ≤ 2 ms | ✅ 余量约 13.8×（仅开发机） |
| typical 场景 p95（每 tick 强制唤醒视口全部 40 chunk，敏感性上界） | 0.478 ms/tick | ≤ 2 ms | ✅ 余量约 4.2×（仅开发机） |
| 确定性（同 seed 两次 10,000 tick） | 30 张过程帧逐字节相同（md5 全同）、世界 hash 相同 | 必须确定 | ✅ |
| 能否据此判定实验 A 通过 | **不能** | 目标机复测 | ⚠️ 开发机是 2023 旗舰手机 SoC，单核性能可能不低于目标机，数字可能偏乐观 |

**一句话**：单线程原型在这台开发机上的最坏 tick 开销是 **~2.2 ms**，离 6 ms 预算还有 2.7 倍余量；典型场景更宽松。但开发机 ≠ 目标机，且 typical 场景有较大休眠折扣、worst 场景的火在稳态下占比低（见 §6），所以这张表只能作为"实现可行、值得上目标机复测"的证据，不能当作 go/no-go 结论。

## 1. 开发机配置与测试方法

| 项 | 值 |
|---|---|
| 机器 | Android 手机（Cortex-X3 一代旗舰 SoC 级），proot 内 Ubuntu 24.04.5 LTS |
| CPU | 8 逻辑核：1×Cortex-X3（max 3.19 GHz）+ 2×A715 + 2×A710 + 3×A510；实测在线 7 核（cpu6 offline），<code>nproc=8</code>。任务简报写 6 核，以实测为准 |
| CPU 调频 | Android 默认 <code>walt</code> governor，**未固定频率**（采样时 scaling 25%–75%），跑基准时由系统动态升频 |
| 内存 | 11.2 GB（MemTotal 11,465,852 kB） |
| 内核 / 架构 | Linux 5.15.123-android13，aarch64，64 位 |
| 编译器 | g++ 13.3.0，CMake 3.28.3，Ninja 1.11.1，zlib 1.3 |
| 构建 | <code>-DCMAKE_BUILD_TYPE=Release</code>（-O3 -DNDEBUG），静态库 <code>libsim_core.a</code>，单线程 |
| 计时 | <code>std::chrono::steady_clock</code>，只包住 <code>sim_world_step()</code>；注入、唤醒、统计、PNG 全在计时区外 |
| 统计 | 10,000 个 tick 的逐 tick 毫秒样本；p50/p95/p99 用 nearest-rank（ceil(p/100*n)），总耗时 = 样本和 |
| 同机干扰 | 该手机同时被多个协作 agent 共用；已用两次独立完整运行验证稳定性：worst-wake p95 2.245 vs 2.242 ms、typical p95 0.145 vs 0.145 ms |

> 局限提示：开发机是**旗舰手机**（Cortex-X3 @3.19 GHz），单核性能不一定弱于 2018 年桌面 i5-8400；proot / Android 调度 / 未锁频会抵消一部分优势。**方向不确定，不能假设开发机数字偏保守。**

## 2. 交付物与验证

### 2.1 文件清单（只新增，未改 data/、refs/、docs/ 其它文件）

| 路径 | 内容 |
|---|---|
| <code>sim_core/include/sim/c_sim.h</code> | **契约 C-SIM v1**（C ABI，GDExtension 可直接用）：世界生命周期、chunk 载入/卸载、活动区、step、cell 读写、dig、脏矩形、RGBA8 渲染、确定性 hash、材质表、事件队列；文件头写清单位与语义 |
| <code>sim_core/src/world.cpp</code> | 世界/chunk/5 物质运动/挖掘/脏矩形/休眠调度/事件/渲染/hash 实现 |
| <code>sim_core/src/materials.{h,cpp}</code> | 材质表：编译期默认值 + data/materials.json 覆盖（water / quicksilver / rock）；沙/油/火为 sim 内实验物质 |
| <code>sim_core/src/json_lite.{h,cpp}</code> | 无第三方依赖的最小 JSON 读取器（只读） |
| <code>sim_core/bench/bench_main.cpp</code> | 基准程序：worst / typical 场景、固定 seed、逐 tick 计时、p50/p95/p99、每 1000 tick 出帧 |
| <code>sim_core/bench/png_writer.{h,cpp}</code> | 用 zlib 写 8bit RGBA PNG，无第三方 PNG 库 |
| <code>sim_core/tests/test_main.cpp</code> | 5 个 ctest：确定性 / 挖掘 / 守恒与边界 / C-SIM API 契约 / materials.json 参数 |
| <code>sim_core/CMakeLists.txt</code> | 构建：库 + 基准 + 测试；预留 <code>add_subdirectory(vm)</code> hook（T3 用） |
| <code>sim_core/.gitignore</code> | 忽略 build/、bench-frames/、*.png（未改仓库根 .gitignore） |
| <code>sim_core/README.md</code> | 构建 / 跑基准 / 跑测试命令 |
| <code>docs/tech/m0-a-frames/*.png</code> | 4 张代表帧（见 §5） |

### 2.2 测试（ctest 5/5）

构建目录里执行 <code>ctest --output-on-failure</code>（命令见 §8）：

| # | 测试 | 断言 | 结果 |
|---|---|---|---|
| 1 | sim_determinism | 同 seed 两世界同操作序列：初始 hash 相同、每 37 tick 及第 400 tick 的 hash 相同；不同 seed 同图案 50 tick 后 hash 不同（防 hash 退化） | PASS |
| 2 | sim_dig | 半径 12 圆形挖掉实心格：返回值 = 圆内格数；圆内无岩石；碎屑沙 >0 且沙+空 = 圆内总数；圆外 2 格环仍为岩石；产生 DIG 事件 | PASS |
| 3 | sim_conservation | 四周石墙封闭，内部沙/水/油/水银随机填充，跑 500 tick 后四种物质数量逐一不变；边界墙不被写入；越界 get/set 安全 | PASS |
| 4 | sim_api_contract | 宽高/seed/tick/chunk 数；材质表（水 1.0、水银 13.6、沙 experimental）；set/get；chunk 卸载后读空、写失败、重载清空；脏矩形取值/清零；活动区裁剪；RGBA8 渲染；事件；hash；destroy(NULL) 安全 | PASS |
| 5 | sim_materials_json | 从 data/materials.json 读参数：source = data/materials.json、水 1.0/#4A78C8、水银 13.6、岩 2.6/static；沙/油/火 experimental；油 flammable | PASS |

### 2.3 确定性证据（可复现）

同一 seed 连续跑两次完整基准（各 10,000 tick × 4 种跑法），**30 张过程帧（每 1000 tick 一帧）逐字节相同**：

    md5 对比：same=30 diff=0
    两次运行 p95：worst-wake 2.245 / 2.242 ms，worst-sleep 1.459 / 1.451 ms，
                  typical-sleep 0.145 / 0.145 ms，typical-wake 0.478 / 0.479 ms

## 3. 场景参数

| 项 | worst | typical |
|---|---|---|
| 世界尺寸 | 480×270 = 1 屏（129,600 cell） | 1440×810 = 3×3 屏（1,166,400 cell） |
| chunk | 40 个（8×5），全部载入 | 299 个（23×13），全部载入（"载入 3×3 屏"） |
| 活跃区 | 整屏 480×270 | 正中间一屏 480×270（视口） |
| 初始物质 | 78% 填充：沙 24% / 水 26% / 油 12% / 水银 8% / 火 8%，其余空 | 程序化矿井灰盒：岩层 + 主平巷（y≈430±）/上层平巷（y≈220）/竖井（x≈700）/主洞窟（椭圆 720,430，180×90）/火室（520,330）；主洞窟里水在下、油浮上、水银沉底、上层平巷堆沙；岩台火种 + 油面点火的火源 |
| 场景维持（计时区外） | 每 150 tick：顶部（4 行）注入 1920 格混合物质 + 全屏随机置换 400 格 + 30 处重新点火，防止 10k tick 内完全沉降 | 每 200 tick 重燃岩台火种；每 250 tick 顶部滴 1 格水入洞窟 |
| 跑法 | wake：每 tick 前 <code>sim_world_wake_rect(整屏)</code>，强制 40 chunk 全处理（**保守上界**）<br>sleep：默认 chunk 休眠调度 | sleep：默认（真实开销）<br>wake：每 tick 强制唤醒视口 40 chunk（敏感性上界） |
| seed / tick 数 | 20261115 / 10,000（= 166.7 s 模拟时间，1 tick = 1/60 s） | 同左 |
| 出帧 | 每 1000 tick 一张 480×270 RGBA PNG | 同左（只截活跃视口） |

## 4. 基准结果（开发机，10,000 tick）

命令：<code>./sim_bench --ticks 10000 --seed 20261115 --out bench-frames</code>（构建见 §8）。单位 ms/tick；"扫描 cell / 唤醒 chunk"是逐 tick 统计的均值。

| 场景 | 跑法 | 总耗时 | mean | **p50** | **p95** | **p99** | min | max | 平均扫描 cell | 平均唤醒 chunk |
|---|---|---|---|---|---|---|---|---|---|---|
| worst | wake（保守上界） | 20.13 s | 2.013 | **2.068** | **2.245** | **2.407** | 1.499 | 3.940 | 129,600 | 40.0 |
| worst | sleep（默认） | 11.08 s | 1.108 | 1.098 | 1.459 | 2.338 | 0.365 | 3.082 | 82,146 | 21.4 |
| typical | sleep（默认） | 1.13 s | 0.113 | 0.107 | **0.145** | 0.228 | 0.096 | 0.626 | 26,736 | 6.9 |
| typical | wake（敏感性上界） | 4.67 s | 0.467 | 0.468 | 0.478 | 0.502 | 0.316 | 0.624 | 129,600 | 40.0 |

对照 D4：**worst p95 ≤ 6 ms / typical p95 ≤ 2 ms**。开发机上四个跑法的 p95、p99 全部低于目标线（worst 最坏 2.407 ms，typical 最坏 0.502 ms）。

### 与 D4 的差距说明

| 项 | 开发机实测 | D4 目标 | 差距 / 说明 |
|---|---|---|---|
| worst p95（上界） | 2.245 ms | ≤ 6 ms | 余量 2.7×。p99 2.407、max 3.94（单次调度抖动），仍在预算内 |
| typical p95 | 0.145 ms（默认）/ 0.478 ms（强制唤醒） | ≤ 2 ms | 默认休眠下余量 13.8×；把视口 40 chunk 全强制唤醒后仍有 4.2× 余量 |
| 16.7 ms 帧预算 | sim 占 ~13%（worst 上界） | sim ≤ 6 ms | 只剩渲染/玩法/音频 ≈ 14.4 ms，本原型未测这些（见 §6） |

**这些数字不能外推到目标机**：① ISA/微架构不同、编译器不同；② 开发机是 2023 旗舰 SoC（Cortex-X3 3.19 GHz），单核不一定弱于 i5-8400；③ 未锁频、受 Android WALT governor 与手机散热影响；④ typical 场景大部分 chunk 在休眠（见 §6.3）。

## 5. 代表帧（docs/tech/m0-a-frames/）

每 1000 tick 一帧共 30 张（build 目录，gitignore 忽略）；提交 4 张代表帧：

| 文件 | 内容 |
|---|---|
| <code>worst-480x270-tick1000.png</code> | worst 第 1000 tick：油（深褐）浮在水（蓝）上、沙（黄）沉底、水银呈灰白颗粒混在水/沙界面；顶部仍有注入物质在下落 |
| <code>worst-480x270-tick10000.png</code> | worst 第 10000 tick：最新一轮顶部注入正在混入；水/沙界面保持起伏，5 种物质都在画面里 |
| <code>typical-1440x810-viewport-tick1000.png</code> | typical 视口第 1000 tick：矿井剖面——灰褐岩、黑色空腔、蓝色水潭、水面上油层、水银（浅灰）沉在水底局部凹坑；左上岩台上有火种（小白/橙色条） |
| <code>typical-1440x810-viewport-tick10000.png</code> | typical 视口第 10000 tick：与 1000 tick 结构稳定（典型场景大部分时间在休眠/静止），仅火种与水面有局部变化 |

目检结论：沙/水/油/水银/火 5 种材质与岩均能正确渲染与分层；油浮于水、水银沉底、沙堆积符合预期。**注意这是调试渲染**（颜色来自材质表 + 坐标 hash 明暗抖动），不是正式美术效果。

## 6. 局限（按重要性排序，目标机复测前请先读）

1. **开发机 ≠ 目标机**：见 §1/§4。开发机是旗舰手机，单核性能方向不确定；proot 与 Android 调度也带来额外噪声。**本报告数字不能用于 go/no-go 判定。**
2. **只测 sim tick，没有渲染/玩法/音频竞争**：60 Hz 帧预算 16.7 ms 中，本报告只覆盖模拟部分；T4a/T4b 接入 Godot 后需要整帧测量。
3. **typical 场景负载偏低**：默认休眠下平均只有 6.9/40 个 chunk 被唤醒、26,736/129,600 cell 被扫描。真实游戏里相机移动、大范围扰动会让 active 区持续工作 → 报告同时给了 typical wake 强制唤醒上界 0.478 ms，目标机复测请两个数都报。
4. **worst 场景的火在稳态占比低**：初始 8% 的火约 150 tick 内烧完（火寿命 40–110 tick），之后每 150 tick 只补 30 处 + 油被点燃的局部火。火每 cell 的开销比沙/水高（邻域检查 + 点火判定），所以 worst 数字对"全屏持续燃烧"偏乐观。**目标机复测建议加一个持续火焰压力场景**（当前 bench 未实现，见 §7）。
5. **场景维持是压力 harness，不是真实玩法**：顶部注入、随机置换、定点滴水/复点火都在计时区外执行，只为让 10k tick 内场景不彻底沉降；注入逻辑固定、可复现，但不代表游戏中会出现同样事件频率。
6. **模拟规则是 v1 简化**（与 Noita 不同，按 T2/D4 范围）：
   - 无速度/加速度：每 tick 最多移动 1 格（垂直方向），液体横向找平 1–3 格/tick；
   - 液体/粉末不能互相穿过（水银会停在沙层上方，等沙被挖走才继续下沉）；
   - 无温度、相变、反应表：只有"油被火点燃（5%/tick/接触）"和"水浇灭相邻火"两条交互；火不产生烟/热；
   - 挖掘只移除 static/powder 格，约 1/3 变成沙碎屑，无刚体碎裂（D4 明确不做）；不挖液体/气体；
   - 未做多线程（D4 明确不做）。
7. **休眠调度的语义**：chunk 只在上 tick 有写入后的下一 tick 被处理；边界写入会唤醒 8 邻居。活动区边界按墙处理（物质不流出），所以把活动区切到视口时，视口外物质会原地冻结。真实游戏若需要"视口外继续缓慢演化"，需要扩展（流式载入/卸载 + 分区 tick）。
8. **chunk unload 会丢数据**：v1 只用于内存/流式演示与测试，无持久化；真实游戏要么不卸载，要么补持久化。
9. **事件队列有上限**（4096 条环形缓冲）：不 poll 会丢事件；只用于音效/粒子/玩法回调，不是审计日志。
10. **PNG 编码在模拟路径外**：渲染 480×270 + zlib 压缩每帧约几 ms，未计入 tick 耗时；不代表实际渲染成本。

## 7. 目标机复测计划（未执行，待用户/目标机）

**前置**：`sim_core/` 与本报告在同一个 commit 提交（复测时以该 commit 为准，可用 `git log --oneline -- docs/tech/m0-a-report.md` 查）；在目标机上复跑同一命令。

    # 目标机（x86-64，4 核，8GB，Linux；Windows 用 WSL 或 MSYS2 亦可）
    sudo cpupower frequency-set -g performance   # 或 BIOS/电源计划点高性能；避免省电降频
    cd sim_core
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build
    cd build
    ctest --output-on-failure                    # 期望 5/5
    taskset -c 0-3 ./sim_bench --ticks 10000 --seed 20261115 --out bench-frames-target

- **跑 3 次取中位数**；每次记录 p50/p95/p99 与总耗时，同时记录 CPU 型号/频率/内存/OS/编译器版本。
- **判定线**：D4 = worst p95 ≤ 6 ms、typical p95 ≤ 2 ms。建议同时看 p99：p99 > 6 ms 视为卡顿风险，即使 p95 过线也要写进报告。
- **两个数字都要报**：typical 的 sleep（默认）与 wake（强制唤醒上界）。只靠休眠过线会高估真实余量。
- **如果不通过**：按 D4 先把格子加粗到 2×2 重测（代价：像素物理卖点打折）。当前契约是 1 cell = 1 世界像素；2×2 需要在 sim_config 增加 cell_scale 并同步改渲染/输入映射（T4a 前做，改动集中在 C-SIM 边界与 bench 场景尺寸）。
- **可选补充压力**（当前未实现，建议在目标机复测前由开发侧补上）：
  a) 相机平移场景：每 500 tick 把活动视口平移一段，让 3×3 屏的 chunk 轮流活跃；
  b) 持续火焰场景：提高油量/点火频率，构造全屏持续燃烧的 worst-case。
- **判定注意事项**：目标机是 4 核 i5-8400/Ryzen 5 2600 级；本基准是单线程，多核数量不影响结果，但**频率/散热/后台程序**会影响，务必锁高性能并关后台。

## 8. 复现命令（开发机已验证）

    cd /tmp/gameV0/sim_core
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build
    cd build
    ctest --output-on-failure
    ./sim_bench --ticks 10000 --seed 20261115 --out bench-frames
    # 输出：stdout 汇总表；bench-frames/summary.txt；bench-frames/{worst-wake,worst-sleep,typical-sleep,typical-wake}-tickNNNNN.png

本次运行的原始 stdout（节选）：

    worst-wake       wake   ticks=10000  total=   20.13s mean=  2.013ms p50=  2.068 p95=  2.245 p99=  2.407 min= 1.499 max=   3.940 avg_active= 129600 avg_awake= 40.0
    worst-sleep      sleep  ticks=10000  total=   11.08s mean=  1.108ms p50=  1.098 p95=  1.459 p99=  2.338 min= 0.365 max=   3.082 avg_active=  82146 avg_awake= 21.4
    typical-sleep    sleep  ticks=10000  total=    1.13s mean=  0.113ms p50=  0.107 p95=  0.145 p99=  0.228 min= 0.096 max=   0.626 avg_active=  26736 avg_awake=  6.9
    typical-wake     wake   ticks=10000  total=    4.67s mean=  0.467ms p50=  0.468 p95=  0.478 p99=  0.502 min= 0.316 max=   0.624 avg_active= 129600 avg_awake= 40.0

## 9. 材质参数来源（只读 data/materials.json，未改 data/）

| 材质 | 状态 | 密度 | 颜色 | 来源 |
|---|---|---|---|---|
| 岩 rock | static | 2.6 | #6B6258 | data/materials.json |
| 水 water | liquid | 1.0 | #4A78C8 | data/materials.json |
| 水银 quicksilver | liquid | 13.6 | #B8C0C8 | data/materials.json |
| 沙 sand | powder | 2.0 | #C9A85C | **sim 实验物质**（data/ 无此物质，按 T2 要求内定义） |
| 油 oil | liquid | 0.9 | #6B4A22 | **sim 实验物质**；可燃：被相邻火以 5%/tick 点燃（sim 参数） |
| 火 fire | gas | 0.2 | 按寿命渐变（暗红→亮黄） | **sim 实验物质**；寿命 40–110 tick（sim 参数） |

读取方式：<code>sim_core/src/json_lite.cpp</code>（无第三方依赖）运行时读 data/materials.json，按 extends 浅合并解析 water / quicksilver / rock 的 density/state/color/name；路径从当前工作目录与可执行文件目录逐级向上找 data/materials.json（环境变量 SIM_CORE_MATERIALS 优先）。**找不到或解析失败时回退编译期默认值并在材质来源里标 builtin**（材质来源可用 <code>sim_world_materials_source()</code> 查询；基准输出会打印实际路径）。

## 10. 遗留 / 下一步

| 项 | 说明 | 谁 |
|---|---|---|
| 目标机复测 | §7；填回 p50/p95/p99 后本报告才能作为实验 A 的 go/no-go 依据 | 用户/目标机 |
| 报告结论升级 | 目标机数据回来后，把本文件"开发机先行"部分替换为正式结论，并提交评审 | Lead |
| 相机平移 / 持续火焰压力场景 | 见 §7 可选补充；属于 bench 增强，不改 C-SIM | 开发侧（T4a 前） |
| 2×2 粗格开关 | 仅当目标机不达标时按 D4 启用；需要扩 C-SIM（cell_scale） | 开发侧 |
| GDExtension 接入 | c_sim.h 可直接被 godot-cpp 调用；渲染侧用 <code>sim_world_dirty_rect</code> + <code>sim_world_render_rgba8</code>（或读 <code>sim_world_copy_rect_materials</code> 自绘） | T4a |
| VM 模块 | <code>sim_core/CMakeLists.txt</code> 已留 <code>add_subdirectory(vm)</code> hook；vm/CMakeLists.txt 存在即自动并入 | T3 |
| docs/log 条目 | 本任务未写 docs/log/（不在写权限内）；按 AGENTS.md 需由 Lead 在统一提交时补一条 | Lead |

---

### 附：C-SIM v1 契约摘要（完整注释见 sim_core/include/sim/c_sim.h）

| 类别 | 接口 |
|---|---|
| 生命周期 | sim_world_create(config) / sim_world_destroy / sim_version |
| 基本 | sim_world_width/height/seed/tick、sim_world_materials_source |
| chunk | sim_world_chunks_x/y、sim_world_load_chunk/unload_chunk/chunk_loaded |
| 活动区 | sim_world_set_active_rect / get_active_rect / wake_rect |
| 步进 | sim_world_step（严格 1 tick = 1/60 s）、sim_world_last_tick_stats |
| cell | sim_world_get_cell/set_cell/copy_rect_materials |
| 挖掘 | sim_world_dig(x, y, radius)（移除 powder/static + 碎屑沙 + DIG 事件） |
| 脏矩形 | sim_world_dirty_rect(clear) |
| 渲染 | sim_world_render_rgba8(rect, out, bytes) |
| 确定性 | sim_world_hash |
| 材质 | sim_world_material_count/info/id_by_str |
| 事件 | sim_world_poll_events（FIRE_IGNITED / FIRE_EXTINGUISHED / DIG） |

约定：1 cell = 1 世界像素；密度以水 = 1.0；坐标 (0,0) 左上、x 向右 y 向下；单线程；同一 seed + 同一 API 调用序列 = 同一结果（不保证跨编译器逐字节一致）。
