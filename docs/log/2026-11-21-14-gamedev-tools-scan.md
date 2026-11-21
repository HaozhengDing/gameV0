# 2026-11-21-14 GitHub 游戏开发工具扫描：AI×Godot、CI、内容与性能工具

- 日期：2026-11-21
- 作者：DeepSeek
- 类型：建议（工具/生产力）
- 篇幅：详细
- 触发：用户澄清「我的意思是帮助制作游戏的，不是我要抄袭」——需要的是开发辅助/生产力项目，而非参考游戏

## 结论

1. **最贴合我们工作流的是 AI×Godot 工具**：`Coding-Solo/godot-mcp`（MIT，6.7k★，MCP：启动编辑器/跑项目/抓输出/改场景）、`jame581/GodotPrompter`（MIT，981★，面向 AI coding agent 的 Godot skills，明确支持 Antigravity）；`hi-godot/godot-ai`（MIT，3.6k★，46 tools/120+ 操作）功能最强但要求 Godot 4.7+（我们 4.5，暂不兼容）。
2. **CI/导出/测试**：`abarichello/godot-ci`（MIT，1.2k★）、`firebelley/godot-export`（MIT，655★）、GUT（2.8k★）/gdUnit4。注意 deploy key 无 workflow scope，CI 改动需用户本人授权，agent 只能准备 patch。
3. **系统/叙事**：LimboAI（MIT，3.1k★，行为树/状态机）适合 M2+；Dialogue Manager（4.0k★）、Dialogic（6.2k★）、ink（5.0k★）适合剧本量上来后；当前 C-TEXT 够用。
4. **美术/关卡/音频**：LDtk（MIT，5.0k★）与 Tiled（GPL-2 工具，13k★）加速关卡；Pixelorama（MIT，11.2k★）、Material Maker（MIT，6.3k★）、LibreSprite、Blockbench、rFXGen。
5. **C++ 正确性/性能**：Tracy（BSD-3，17.2k★，Godot 官方支持）、google benchmark/nanobench、libFuzzer/AFL++/rapidcheck——直接服务 D4 性能与 C46「AI 生成代码难自证」。
6. 只选 5 个：godot-mcp、GodotPrompter、Tracy+nanobench、LDtk、Pixelorama+Material Maker。

## 改动

| 文件 | 改了什么 |
|---|---|
| `docs/research/oss-gamedev-tools-2026-11.md` | 新增：游戏开发辅助工具清单（AI×Godot / CI / 系统叙事 / 美术关卡 / C++ 性能 / Top5 / 注意事项） |
| `docs/log/README.md` | 索引加本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 优先评估 godot-mcp + GodotPrompter | 我们现在的 AI 协作靠命令行+截图，MCP 能让 agent 直接跑编辑器/抓调试输出/改场景；GodotPrompter 明确支持 Antigravity，补充领域 skills | MCP 权限面较大，要限定项目目录；GodotPrompter 的工作流与我们的契约/目录未必一致，需要裁剪 |
| 暂不引入 hi-godot/godot-ai | 要求 Godot 4.7+，我们 4.5；升级引擎会触发 GDExtension/构建链重验 | 失去「46 tools 直接编辑场景」的能力，先用轻量 MCP |
| CI 工具只记录不直接改 | `.github/workflows` 需 workflow scope，deploy key 没有；由用户本人操作或授权 | CI 自动化延后 |
| LimboAI/对话框架延后 | M1-06 自研 AI 与 C-TEXT 已够用；引入插件增加依赖与版本耦合 | M2 之后再评估 |
| 记录工具许可红线 | 工具 GPL 可正常用来产出资产，但不能把工具代码/自带素材并入游戏 | 需要人工核对每个工具的 LICENSE |

## 新增或修改的 deviations

无（纯研究/文档，不改实现/数值/契约）。

## 未解决 / 待决定

- 是否引入 godot-mcp / Godot-MCP-Native：需要在 Antigravity 或 DSH 的 MCP 配置里加 server；建议先在 T4b/M1-α 场景做一次「AI 启动编辑器→跑游戏→抓错误」的小试验（1–2 小时）。
- 是否申请 workflow scope 以接入 godot-ci/godot-export：需要用户本人操作。
- hi-godot/godot-ai 的 Godot 4.7 要求：等我们有意升级引擎时再评估。
- 部分仓库 star/许可证字段因未登录 API 限速未取到精确值（gdUnit4、GUT 许可证字段），以仓库 LICENSE 为准。

## 下一步

- 若用户同意：我可以写一份 godot-mcp 在本项目的最小接入步骤（MCP 配置 + 只读工具 allowlist + 用 M1-α 场景验证），不动现有代码。
- 主线仍是 M1-α 打磨与 M1-07/M1-08。
