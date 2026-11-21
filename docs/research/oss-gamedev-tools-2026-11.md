# 游戏开发辅助工具开源清单：能直接帮我们做游戏的 GitHub 项目（2026-11）

> 日期：2026-11-21｜类型：工具/生产力调研（非竞品）｜只读调研
> 方法：GitHub 搜索/仓库 API + README 核对；star 为 2026-11-21 快照（部分因未登录 API 限速未取到精确值，已标注）。
> 目的：回答「哪些开源项目能帮助制作游戏」，按我们当前的 Godot 4.5 + AI 协作工作流挑。
> 状态：**已作为「后续建议」登记到 `docs/04-m1-plan.md` 附录 A（2026-11-21，非 M1 任务、未排期）**。

## 结论

1. **最直接帮到我们的是 AI×Godot 工具链**：`Coding-Solo/godot-mcp`（MIT，6.7k★）让 AI agent 启动 Godot 编辑器/跑项目/抓调试输出/改场景；`jame581/GodotPrompter`（MIT，981★）提供面向 AI coding agent 的 Godot 领域 skills（测试/CI/导出/LimboAI），明确支持 Antigravity。这两类能补上 Antigravity 现在「只能命令行+截图」的反馈闭环。
2. **工程化/CI/测试**：`abarichello/godot-ci`（MIT，1.2k★）、`firebelley/godot-export`（MIT，655★）可把 Godot headless 冒烟与导出接进 CI；GUT（2.8k★）/gdUnit4 可做结构化测试。**注意：我们的 deploy key 没有 workflow scope，改 `.github/workflows` 需要你本人在网页/本机授权，agent 只能准备 patch。**
3. **系统/AI 插件**：`limbonaut/limboai`（MIT，3.1k★，行为树+状态机）适合 M2 之后敌人 AI 复杂度上来时用；M1-06 目前自研 AI 已够用。
4. **叙事/文本**：Dialogue Manager（MIT，4.0k★）、Dialogic（MIT，6.2k★）、ink（MIT，5.0k★）+ godot-ink（MIT，791★）可用于碑文/规矩/叙事；我们当前 C-TEXT/JSON 极简，M2 再评估。
5. **美术/关卡/音频**：Tiled（GPL-2 工具，13k★）、LDtk（MIT，5.0k★）、Pixelorama（MIT，11.2k★）、Material Maker（MIT，6.3k★）、Blockbench（GPL-3，6.2k★）、LibreSprite（GPL-2，8.8k★）、rFXGen（Zlib，525★）。工具 GPL 不影响产出资产，但不能把工具代码/自带素材搬进项目。
6. **C++ 正确性/性能**：Tracy（BSD-3，17.2k★，Godot 自带集成）、google benchmark（Apache-2.0，10.5k★）、nanobench（MIT，1.8k★）、libFuzzer/AFL++/rapidcheck（VM/反应表模糊与属性测试）——直接服务 D4 性能预算与 C46「AI 生成代码难自证」。

## 一、AI × Godot（最贴合我们的 AI 协作流程）

| 项目 | ★/许可 | 它能做什么 | 怎么帮我们 | 注意 |
|---|---|---|---|---|
| [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp) | 6723★ MIT | MCP server：启动 Godot 编辑器/运行项目/抓调试输出/控制执行/建场景/加节点/载入贴图/场景变体/UID | 给 Antigravity 或其它 MCP 客户端一个「能跑、能看输出、能改场景」的闭环，补上纯 CLI 看不到的 UI/场景问题；适合 M1-α 视觉调试 | Node 18+；需要 MCP 客户端配置；权限面较大（能启动引擎/改项目），注意 allowlist |
| [hi-godot/godot-ai](https://github.com/hi-godot/godot-ai) | 3637★ MIT | 生产级 Godot AI 工具：46 tools/120+ 操作，连 Claude Code/Codex/Cursor 等 MCP 客户端，实时编辑场景/脚本/信号/UI/材质/动画/粒子 | 如果以后升级到 Godot 4.7+，可作为「AI 直接编辑场景」的主力；参考其工具设计 | **要求 Godot 4.7+**（我们当前 4.5，不兼容）；Python/uv 依赖 |
| [yurineko73/Godot-MCP-Native](https://github.com/yurineko73/Godot-MCP-Native) | 882★ MIT | 纯 GDScript 的 Godot 原生 MCP 插件，无外部依赖，开箱即用 | 对 Windows/手机端更省事的 MCP 方案；可先试轻量版 | 新、生态小；能力比前两个少 |
| [jame581/GodotPrompter](https://github.com/jame581/GodotPrompter) | 981★ MIT | 「Agentic skills framework for Godot 4.x」：给 Claude Code/Copilot/**Antigravity** 等的 Godot 领域 skills（测试 GUT/gdUnit4、CI/CD、导出、LimboAI 等） | 直接补我们的 `.agents/skills/`，让 Antigravity 懂 Godot 工程惯例；与我们的 `game-decision-research` skill 互补 | 是 skills/提示词库，不是运行时；注意它描述的工作流未必匹配我们的契约与目录 |
| [genex-games/genex-desktop](https://github.com/genex-games/genex-desktop) | 901★ MIT | 开源 AI-native 游戏开发桌面应用（Unreal/Unity/Godot/Roblox/Three.js） | 观察同类产品形态；若它成熟可做 AI 工作台 | 平台型项目，未必适合我们当前小团队流程 |

## 二、CI / 导出 / 测试（把我们的自动化补全）

| 项目 | ★/许可 | 用途 | 注意 |
|---|---|---|---|
| [abarichello/godot-ci](https://github.com/abarichello/godot-ci) | 1158★ MIT | Godot 导出 Docker 镜像 + GitLab/GitHub Actions 模板 | **我们的 deploy key 无 workflow scope**；需用户授权后由人/带 workflow scope 的 agent 改 `.github/workflows` |
| [firebelley/godot-export](https://github.com/firebelley/godot-export) | 655★ MIT | GitHub Action：自动导出 Godot 游戏（多平台） | 同上 workflow 权限 |
| [bitwes/Gut](https://github.com/bitwes/Gut) | 2788★（GitHub API 未识别许可，仓库内 LICENSE 为准） | Godot Unit Test：GDScript 单元测试、CI 报告 | 我们已有 `--t4b-smoke`；引入框架会增加依赖，但回归用例多了更值 |
| gdUnit4（MikeSchulze/gdUnit4，仓库已重定向） | — | GDScript/C# 测试框架（断言/参数化/场景测试） | star 未取到精确值；适合 M2 后回归增多时 |

## 三、系统 / AI / 叙事插件（按需）

| 项目 | ★/许可 | 用途 | 时机 |
|---|---|---|---|
| [limbonaut/limboai](https://github.com/limbonaut/limboai) | 3137★ MIT | Godot 4 行为树 + 状态机（C++ 插件） | M2+ 敌人 AI 复杂后；M1-06 自研 AI 先不动 |
| [nathanhoad/godot_dialogue_manager](https://github.com/nathanhoad/godot_dialogue_manager) | 3996★ MIT | 非线性对话系统 | 规矩碑文/洞天对话多起来后（M2+）；当前 C-TEXT 够用 |
| [Dialogic-Godot/Dialogic](https://github.com/Dialogic-Godot/Dialogic) | 6182★ MIT | 对话/视觉小说框架 | 同上，偏重 |
| [inkle/ink](https://github.com/inkle/ink) + [paulloz/godot-ink](https://github.com/paulloz/godot-ink) | 5028★ MIT / 791★ MIT | 叙事脚本语言 + Godot 集成 | 剧本量上来（多分支规矩/结局）再评估 |

## 四、美术 / 关卡 / 音频（内容生产）

| 项目 | ★/许可 | 用途 | 用法提醒 |
|---|---|---|---|
| [deepnight/ldtk](https://github.com/deepnight/ldtk) | 5000★ MIT | 现代 2D 关卡编辑器（JSON 输出） | 适合导出我们的 `data/rooms/` 或 Wang Tile 关卡；MIT 友好 |
| [mapeditor/tiled](https://github.com/mapeditor/tiled) | 13083★（API NOASSERTION，实为 GPL-2 工具） | 通用 tile 地图编辑器 | 产出地图数据可用；**不要复制其代码/自带素材**；GPL 只约束工具本身 |
| [Orama-Interactive/Pixelorama](https://github.com/Orama-Interactive/Pixelorama) | 11162★ MIT | 像素美术/动画（Godot 写的） | 灰盒→正式像素资产；与 Godot 管线友好 |
| [RodZill4/material-maker](https://github.com/RodZill4/material-maker) | 6283★ MIT | 程序化材质/贴图（Godot 写的） | 水墨/岩石/纸张材质参考（M2 视觉） |
| [LibreSprite/LibreSprite](https://github.com/LibreSprite/LibreSprite) | 8831★ GPL-2 | Aseprite 的 GPL 分支（像素/动画） | 工具 GPL 不影响产出；按需选 Pixelorama 或它 |
| [JannisX11/blockbench](https://github.com/JannisX11/blockbench) | 6230★ GPL-3 | 低多边形 3D 模型 | 我们 2D 像素为主，优先级低 |
| [raysan5/rfxgen](https://github.com/raysan5/rfxgen) | 525★ Zlib | 程序化音效生成 | 打击/施法/环境短音效 |

## 五、C++ 正确性 / 性能（服务 D4 与 C46）

| 项目 | ★/许可 | 用途 |
|---|---|---|
| [wolfpld/tracy](https://github.com/wolfpld/tracy) | 17156★（BSD-3，API NOASSERTION） | 帧/函数级 profiler；Godot 官方支持 Tracy 编译开关，可同时看引擎与扩展 |
| [google/benchmark](https://github.com/google/benchmark) | 10531★ Apache-2.0 | C++ 微基准（可替换/补充我们的自写 bench） |
| [martinus/nanobench](https://github.com/martinus/nanobench) | 1751★ MIT | 单头文件微基准，接入最省事 |
| libFuzzer / [AFLplusplus](https://github.com/AFLplusplus/AFLplusplus) / [emil-e/rapidcheck](https://github.com/emil-e/rapidcheck) | — | 对 C-SIM / C-VM 做模糊测试与属性测试，补「AI 写的语义难自证」（C46） |

## 六、如果只拿 5 个（我的排序）

| 优先级 | 工具 | 理由 |
|---|---|---|
| 1 | **Coding-Solo/godot-mcp** | 让 AI 真正「跑起来看」：启动 Godot、跑 M1 场景、抓错误、改场景；补 Antigravity 现在只能 headless+截图的盲区 |
| 2 | **jame581/GodotPrompter** | 直接给 AI agent 补 Godot 领域 skills（测试/CI/导出/LimboAI），支持 Antigravity，成本低 |
| 3 | **Tracy + nanobench** | D4 目标机没到位前，先在开发机把 C-SIM/VM 热点与微基准固定下来；Tracy 可跟 Godot 一起看 |
| 4 | **LDtk**（或 Tiled） | M1-04 房间/关卡迭代会明显加速；LDtk MIT 且 JSON 输出好接 |
| 5 | **Pixelorama + Material Maker** | M1-α 之后要脱离纯 C-SIM 调试色做灰盒美术 |

## 七、注意事项

- **CI workflow 权限**：`.github/workflows/` 需要 workflow scope；本项目 deploy key 没有，改 CI 必须由用户本人或在用户机器上操作。
- **MCP 安全**：MCP server 能启动引擎/读写项目，配置时限定项目目录与 allowlist；不要把含密钥的目录给它。
- **许可证**：工具 GPL（Tiled/Blockbench/LibreSprite/Krita 等）可以用它产出资产，但不能把工具代码/自带素材并入游戏；移植第三方代码前先核对 LICENSE 并保留署名。
- **版本匹配**：hi-godot/godot-ai 要求 Godot 4.7+；我们当前 4.5，先不要升级/引入，除非另做迁移评估。
- **star 与数据**：2026-11-21 快照；部分仓库因未登录 API 限速未取到精确 star/许可证字段，以仓库 README/LICENSE 为准。

## 八、参考

- GitHub 仓库搜索/API 与 README；相关：[competitors-2026-11.md](competitors-2026-11.md)、[oss-projects-2026-11.md](oss-projects-2026-11.md)、`docs/tech/m1-01-contracts-evt-text.md`、`docs/04-m1-plan.md`。
