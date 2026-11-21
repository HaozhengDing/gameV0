# GitHub 开源项目扫描：与《刍狗》目标契合的参考项目（2026-11）

> 日期：2026-11-21｜类型：技术/竞品邻近扫描｜只读调研（未改代码）
> 方法：GitHub REST API 仓库搜索 + 仓库 README/许可证核对；stars 为 2026-11-21 实时值；未逐仓库运行代码。

## 结论

1. **没有可直接复用的「完整同款」**：同时具备「国风符箓 + 元素沙盒 + Roguelite」的开源项目没有找到。最接近的组合是：技术上 `sand-slide`（Godot + GDExtension + falling sand），题材上 `Night-Patrol`（志怪卡牌 roguelite）/`daofaziran`（符箓·阵法 Minecraft mod）。这侧面印证 D1 理由 6 的差异化空位。
2. **技术栈最贴合**：`kiwijuice56/sand-slide`（MIT，143★）—— Godot 4 + C++ GDExtension + 下落沙游戏，架构和我们的 `game/` + `sim_core/` 几乎同题；`xy200303/CellularFX`（MIT，1★）—— Godot 4 GDExtension 元胞自动机引擎，CPU/GPU 双后端、材质 Resource、反应/温度、基准与编辑器 Dock，但非常新、star 少，只能读不能依赖。
3. **成熟 falling-sand 参考**：`The-Powder-Toy`（GPL-3，5.4k★，C++）元素/反应数据与可读性最成熟；`maxbittker/sandspiel`（MIT，3.2k★，Rust/WASM）与 `R74nCom/sandboxels`（自定义非商用许可，486★，500+ 元素）适合学交互与反应可读性，**但许可证都不允许我们直接拿代码/内容**。
4. **符箓 VM 语义**：`Heipen/noita-wand-sim`（MIT 代码，3★）直接运行 Noita 原版施法 Lua，可作为我们 C-VM 的「差分对照」参考；但其数据包是 Noita 版权素材，**只能本地研究，不能进仓库/发行**。
5. **结构/题材参考**：`statico/godot-roguelike-example`（MIT，50★，Godot 4 视野/背包/BSP/行为树）、`yoruniubi/mo_yu_pai_xia`（MIT，18★，Godot 4.5 卡牌肉鸽）、`op7418/Night-Patrol`（158★，志怪卡牌 roguelite demo，许可证未明示）、`qkl162/daofaziran`（MIT，0★，符箓/阵法/妖丹 mod）。

## 一、技术邻近（Godot / 元胞自动机 / falling sand）

| 项目 | 语言/★/许可 | 是什么 | 可借鉴 | 注意 |
|---|---|---|---|---|
| [kiwijuice56/sand-slide](https://github.com/kiwijuice56/sand-slide) | C++ · 143★ · MIT | Godot 4.6 工程 + C++ GDExtension；完整可下载的 falling sand 游戏；每个元素一个 C++ 类，实现 `process(sim,row,col)` | **与我们最同题**：元素类的组织方式、GDExtension 编译/打包、游戏侧与扩展侧边界；可对比其元素「无逐格数据」设计 vs 我们的 `material+aux` | Godot 4.6（我们 4.5）；SCons 构建（我们 CMake）；若借代码需署名/保留许可 |
| [xy200303/CellularFX](https://github.com/xy200303/CellularFX) | C++ · 1★ · MIT | Godot 4 GDExtension CA/下落沙引擎：CPU/GPU 双后端、材质为 Godot Resource、反应/温度/燃烧/腐蚀/爆炸、1024×1024、基准、编辑器 Dock | 材质 Resource + 编辑器工具/基准测试的做法；GPU 后端是 M2+ 性能兜底候选；反应/温度字段设计可对照我们的 C-SIM v3 | 很新、star 极少，README 功能未必等于稳定性；不要直接当依赖 |
| [bruce965/particles-sandbox](https://github.com/bruce965/particles-sandbox) · [bruce965/godot-gpu-cellular-automata](https://github.com/bruce965/godot-gpu-cellular-automata) | C#/GLSL · 27/21★ · MIT | Godot GPU 元胞自动机模板（自标 OBSOLETE） | 了解 Godot 4 GPU compute 的历史做法与坑 | 作者注明「Godot 4 有更好做法」；不用于生产 |
| [pascal-ballet/CellularAutomataStudio](https://github.com/pascal-ballet/CellularAutomataStudio) | GDScript · 12★ · MIT | Godot 插件：compute shader 做 CA | 计算着色器做网格模拟的插件结构 | 插件而非游戏；性能取决于 GPU/驱动 |
| [VenitStudios/GodotFallingSand](https://github.com/VenitStudios/GodotFallingSand) | GDScript · 15★ · GPL-3.0 | Godot 4.3 falling sand 模拟器 | 读代码/思路 | **GPL-3：不能进闭源项目** |

## 二、成熟 falling-sand 参考实现 / 数据 / UI

| 项目 | 语言/★/许可 | 是什么 | 可借鉴 | 注意 |
|---|---|---|---|---|
| [The-Powder-Toy/The-Powder-Toy](https://github.com/The-Powder-Toy/The-Powder-Toy) | C++ · 5417★ · GPL-3.0 | 桌面 falling sand 沙盒，长期维护；元素/反应/存档/UI/多线程 | 元素/反应数据组织、UI/可读性、性能架构；对照我们的 `materials.json` 反应表设计 | **GPL-3：只读，不能链接/复制进我们的闭源发行版** |
| [maxbittker/sandspiel](https://github.com/maxbittker/sandspiel) | Rust/WASM · 3230★ · MIT | 浏览器 falling sand 游戏；目标是可编程元素/CA API | 元素/反应最小模型、共享/回放设计（对 M4 Mod API 有启发）；MIT 可参考实现 | 技术栈不同（Rust/WASM），不要整体照搬 |
| [R74nCom/sandboxels](https://github.com/R74nCom/sandboxels) | JavaScript · 486★ · **R74n 自定义非商用许可** | 浏览器沙盒：500+ 元素、数千反应 | 反应/元素的「可发现性」与 UI 组织；对照我们 D1 可读性 | **非商用 + 可撤销：不能复用代码/内容，仅读设计** |
| [bananaoomarang/Dust](https://github.com/bananaoomarang/Dust) | JavaScript · 29★ · MIT | 极简 CA 沙盒 | 最小实现/教学 | 规模太小，仅入门参考 |
| [Harry-Skerritt/FallingSand](https://github.com/Harry-Skerritt/FallingSand) | C++/SFML · 少量★ | 简单下落沙 | 不需要 | 与 Godot 栈无关 |

## 三、符箓 VM / Noita 语义

| 项目 | 语言/★/许可 | 是什么 | 可借鉴 | 注意 |
|---|---|---|---|---|
| [Heipen/noita-wand-sim](https://github.com/Heipen/noita-wand-sim) | Lua/JS · 3★ · MIT（代码） | 浏览器内运行 Noita 原版施法 Lua（`gun.lua`/`gun_actions.lua`），完整施法树/牌堆/回绕 | **差分测试思路**：用 Noita 实际逻辑验证我们 C-VM 的抽牌/触发/预算语义；其「施法树可视化」UI 值得参考 | 数据包含 Noita 版权素材（法术名/图标/XML/Lua）；**不能进仓库/发行**，只做本地互操作研究 |
| [salinecitrine/noita-wand-simulator](https://github.com/salinecitrine/noita-wand-simulator) | TypeScript · 7★ · 无许可证 | 把 Noita Lua 转成 TS 函数做魔杖模拟 | 同上的语义验证/可视化参考 | **无许可证 = 默认保留所有权利**，不可复用代码 |

## 四、国风志怪 / Roguelite 结构 / Mod 能力

| 项目 | 语言/★/许可 | 是什么 | 可借鉴 | 注意 |
|---|---|---|---|---|
| [statico/godot-roguelike-example](https://github.com/statico/godot-roguelike-example) | GDScript · 50★ · MIT | Godot 4 半成品 roguelike：视野/背包/BSP 地牢/行为树 | M1-04 地牢生成、M1-06 行为树、M3 前的系统骨架参考 | 未完成；美术/数值不可直接拿 |
| [yoruniubi/mo_yu_pai_xia](https://github.com/yoruniubi/mo_yu_pai_xia) · 摸鱼牌侠 | GDScript · 18★ · MIT | Godot 4.5 卡牌 roguelike（职场题材） | Godot 4.5 的卡牌/回合/UI 工程结构；中文社区工程实践 | 题材/内容不同，只学结构 |
| [op7418/Night-Patrol](https://github.com/op7418/Night-Patrol) · 夜巡录 | TypeScript · 158★ · **NOASSERTION** | 志怪卡牌构筑 roguelite demo（符箓/剑诀/香火/奇物/阴市/城隍印） | **题材与叙事最接近**：符箓/香火资源的命名与 UI、卡牌构筑节奏、志怪氛围；可做外部参照 | 许可证未明示（不能复用代码/资产）；Web/Phaser 技术栈 |
| [qkl162/daofaziran](https://github.com/qkl162/daofaziran) · 道法自然·FuLu | Java · 0★ · MIT | Minecraft Forge 符箓/阵法/妖丹 mod：黄纸朱砂画符、14 阵法、10 妖丹技能轮盘 | 符箓/阵法的玩法翻译与命名；「妖丹匣 = 技能栏」这类 UI 映射可启发我们的符位/法器界面 | Forge mod；无美术资产可借；0★ 偏个人项目 |
| [libriscv/godot-sandbox](https://github.com/libriscv/godot-sandbox) | C++ · 502★ · BSD-3 | Godot 4.4+ 编辑器内 C++ 脚本/沙箱（RISC-V JIT） | M4 Mod/热重载的候选方案（反应规则、符箓脚本可热更） | 现在不需要；会增加运行复杂性与性能开销 |
| [GDExtension C++ 官方示例](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/gdextension_cpp_example.html) | 文档 | 官方 GDExtension + godot-cpp 工程模板 | 我们 T4a 已按此路线；CI/构建可对照 | — |

## 五、许可证红线（重要）

| 许可 | 项目 | 我们能做什么 |
|---|---|---|
| MIT / BSD-3 / Apache | sand-slide、CellularFX、sandspiel、godot-roguelike-example、mo_yu_pai_xia、godot-sandbox、daofaziran、noita-wand-sim（代码） | 可参考/在署名+保留许可前提下复用代码（但项目规则优先：不照搬，重写） |
| GPL-3 / AGPL-3 | The-Powder-Toy、GodotFallingSand、TPTBox | **只读**；不能链接或复制进闭源商业项目 |
| R74n Content License | sandboxels | **非商用 + 可撤销**；只读设计，不可复用 |
| 无许可证 / NOASSERTION | salinecitrine/noita-wand-simulator、Night-Patrol | 默认保留所有权利；只读，不复用 |
| 游戏专有数据 | Noita 本体、wand-sim 内置数据包 | 只做本地互操作研究；不进仓库、不进发行包 |

## 六、对我们下一步的具体用途

| 我们的目标 | 建议读哪个 | 怎么用（不照抄） |
|---|---|---|
| M1-12 反应表/火焰热系统已落地，需校验设计 | The-Powder-Toy、CellularFX、sandboxels | 对照元素/反应字段组织、燃烧/腐蚀/温度的表现与 UI 可发现性；找我们 `materials.json` 的字段缺口 |
| M1 性能风险（目标机未测） | CellularFX 基准、sand-slide 实现 | 只读对比 CPU 网格尺寸/更新策略；GPU 后端作为 M2+ 兜底候选 |
| C-VM 语义再验证 | Heipen/noita-wand-sim | 本地用 Noita 原版 Lua 对同一魔杖/符序列做差分，补我们的 30 条用例；数据不进仓库 |
| M1-04/M1-06 结构 | statico/godot-roguelike-example、mo_yu_pai_xia | BSP 地牢/行为树/Godot 卡牌 UI 结构 |
| 题材/命名/UI 参考 | Night-Patrol、daofaziran | 符箓/香火/阵法/妖丹的玩法翻译与极简命名；只看设计不动资产 |
| M4 Mod/热重载 | libriscv/godot-sandbox、sandspiel 可编程 CA 目标 | 评估「玩家可写反应/符」的沙箱与 API 形态 |

## 七、未覆盖与限制

- 只做了仓库名/描述/README/许可证层核对，没有逐仓库 build/跑分；`CellularFX` 只有 1★、`sand-slide` 用 Godot 4.6 + SCons，实际可用性需本地试。
- GitHub 搜索 API 有速率限制（未登录 10 次/分），本轮只覆盖了主要关键词：falling sand / powder / cellular automata / godot / noita / spell crafting / 符箓 / 克苏鲁 / roguelite；没有覆盖 itch.io、GitLab、Steam 开源项目。
- star 数会变化，本表为 2026-11-21 快照。

## 八、参考链接

- 扫描方法：GitHub REST `/search/repositories` + `/repos/{owner}/{repo}` + README/许可证；检索日期 2026-11-21。
- 相关：`docs/research/competitors-2026-11.md`（商业竞品）、`docs/tech/noita-data-structure.md`（Noita 数据模式）、`docs/tech/sim-fire-heat-design.md`（火焰/热设计）。
