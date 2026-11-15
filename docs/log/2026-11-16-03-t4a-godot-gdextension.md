# 2026-11-16-03 T4a：Godot + GDExtension 构建链跑通（真 sim_core 接入）

- 日期：2026-11-16
- 作者：DeepSeek
- 类型：更新
- 篇幅：详细
- 触发：用户说「本手机 tailscale 连了一个电脑，你看看能不能做」——在用户的 Windows 电脑上做 T4a

## 结论

- **T4a 跑通**：在用户的 Windows 电脑（Tailscale 直连）上完成 Godot 4.5 工程 + GDExtension 构建链 + 角色移动；**GDExtension 直接链接真 sim_core（C-SIM v1）**，没有用桩（C-SIM 已冻结，无桩必要）。
- 一条命令构建：`game/build.bat`（Windows；Linux/macOS 用 `game/build.sh`）→ 产出 `game/bin/gdsim.windows.template_{debug,release}.x86_64.dll`。
- 无界面验证（真实输出）：GDExtension 加载成功；`SMOKE_OK hash=… image=120x80 dig=29 ticks=600`；主场景 120 帧 `MAIN_EXIT=0`，读到了 `data/materials.json`（`T4A_MAIN_READY world=480x270 materials=data/materials.json`）。
- 「桩换成真 sim_core 时 Godot 侧不用改」成立：GDScript 只依赖 `SimWorldNode` 的 C-SIM 方法；`sim_core` 源码改动不影响场景脚本。

## 改动

| 文件 | 改了什么 |
|---|---|
| `game/` 新增 | Godot 4.5 工程：`project.godot`、`main.tscn`、`scripts/main.gd`（建测试关卡/驱动 tick/渲染/挖掘）、`scripts/player.gd`（WASD 移动）、`tests/smoke_sim.gd`（无界面自检） |
| `game/gdextension/` 新增 | `CMakeLists.txt`：add_subdirectory(godot-cpp) + 静态编译 `sim_core/src/*.cpp`；`src/register_types.cpp`（Godot 4.5 入口签名）、`src/sim_node.{h,cpp}`（`SimWorldNode` 包装 C-SIM：世界生命周期/step/cell 读写/dig/脏矩形/渲染/确定性 hash） |
| `game/gdsim.gdextension` | 新增：entry_symbol + windows/linux debug/release 库路径 |
| `game/build.bat` / `game/build.sh` | 新增：一键构建（Windows 自动进 MSVC 环境；Linux/macOS 脚本） |
| `game/README.md` `game/.gitignore` `game/bin/.gitkeep` | 新增：前置/构建/运行/限制/与 T4b 的关系；忽略 `.godot/`、`build/`、`bin/*.dll|so` |
| `docs/02-m0-plan.md` | T4a 进度：构建链 + 可运行项目已验证（环境 = 用户 Windows 电脑） |
| `docs/log/README.md` | 索引加本条目 |

未改 data/、refs/、sim_core/、tests/vm_cases。Godot/godot-cpp 等工具装在用户电脑 `C:\Users\perrychuh\t4a-tools`（非系统安装，未写入 PATH）。

## 环境与证据

| 项 | 值 |
|---|---|
| 电脑 | Windows 11（DESKTOP-I9SEE9S），20 核，Tailscale 直连；MSVC 19.51（VS 18）、Windows SDK 10.0.28000 |
| Godot | 4.5.stable.official.876b29033（win64 便携版） |
| godot-cpp | `godot-4.5-stable`，CMake+Ninja 构建（template_debug / template_release 各一份） |
| CMake / Ninja | 3.31.6 / 1.13.2（便携解压，未装系统） |
| 构建命令 | `set GODOT_CPP_DIR=... && game\build.bat` → `T4A_BUILD_OK`（debug+release 各 0 error） |
| 自检 | `godot --headless --path game --script res://tests/smoke_sim.gd` → `SMOKE_OK ...`，exit 0 |
| 主场景 | `godot --headless --path game --quit-after 120` → `T4A_MAIN_READY ...`，exit 0 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 直接用真 sim_core，不做桩 | C-SIM v1 已冻结，GDExtension 用 C ABI 接入最短路径；T4a 的完成标准是「构建链跑通」，真库比桩更能暴露集成坑 | 构建依赖 sim_core 源码；换桩/换实现必须保持 `SimWorldNode` 方法集（已在 README 写清） |
| 扩展把 sim_core 源码静态编进去 | 不引入 bench/tests/zlib 依赖，构建更小；C-SIM 是稳定 C ABI，边界清晰 | 未来 sim_core 增量更新时，扩展重建即生效（无版本协商问题） |
| T4a 用「每帧 1 tick + 整屏纹理上传」 | 先把构建链/输入/渲染闭环跑通；固定步长累加器与脏矩形部分上传留 T4b | 高刷新率下模拟速度与帧率绑定（灰度原型可接受） |
| 无界面（headless）作为验收 | 远程桌面不弹用户窗口、可脚本化判定；可视化留给用户本机运行 | 没有截图证据；用自检数字与日志替代（T4b 再接可视美术） |
| Godot/godot-cpp 用便携包放用户目录 | 不污染系统、不需要管理员权限；版本可控 | 用户 PATH 里没有它们；README 写明前置与 PATH 处理 |

## 踩到的坑（供后续参考）

1. **MSVC 源文件编码**：sim_core 与脚本含中文注释/字符串，MSVC 默认按系统代码页（GBK）读，报「字符串常量中有换行符」→ CMake 加 `/utf-8`（`add_compile_options`）。
2. **Godot 4.4+ GDExtension 入口签名变了**：第一个参数是 `GDExtensionInterfaceGetProcAddress` 函数指针，不是旧的 `GDExtensionInterface\*` 结构体（按 godot-cpp 4.5 test 示例对齐）。
3. **cmd 批处理**：build.bat 用纯 ASCII + CRLF，避免中文/换行导致 cmd 解析错误；中文说明放 README。
4. godot-cpp 的 CMake 需要在构建目录里再编一遍（约 1000 个文件/配置），首次 debug+release 约 10–12 分钟；之后增量很快。
5. `.gdextension` 库版本必须与 Godot 主版本一致（4.5 ↔ godot-cpp 4.5），否则兼容性检查拒绝加载。

## 新增或修改的 deviations

无（不改设计/数值/契约；T4a 是接入层）。

## 未解决 / 待决定

- 用户本机可视化运行没有做（远程不弹窗）；用户可双击运行：`C:\Users\perrychuh\t4a-tools\godot\Godot_v4.5-stable_win64.exe --path C:\Users\perrychuh\gameV0-t4a\game`。
- `game/bin` 下的 dll 不进仓库（gitignore）；换机器要重新构建（README 有前置与命令）。
- 用户电脑上的 `t4a-tools`（Godot/godot-cpp/CMake/Ninja，约 300MB）与 `gameV0-t4a` 克隆（含构建缓存，数 GB）暂留作 T4b 用；如果要清理需用户确认。
- T4b：`data/rooms/` 房间、固定步长累加器、相机跟随 + 脏矩形上传、符箓 VM（C-ACT）执行。

## 下一步

- T4b 开工前先和用户确认：是否继续用这台电脑构建（推荐），以及 T4b 的灰盒内容范围（矿井 1 层 + 4 组符 + 葫芦）。
- 实验 A 目标机复测仍在等目标机（这台 20 核电脑不是 D4 目标机）。
