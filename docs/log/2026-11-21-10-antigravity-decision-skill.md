# 2026-11-21-10 Antigravity 接入游戏开发决策调研技能

- 日期：2026-11-21
- 作者：Codex
- 类型：更新
- 篇幅：详细
- 触发：制作人希望在 Antigravity 的 Gemini 会话中调用已有的 `game-decision-research`。

## 结论

把技能迁到 `.agents/skills/game-decision-research/`。在 Antigravity 或 DeepSeek Harness 中打开 gameV0，都可以输入 `/game-decision-research <问题>`。当前会话可用的搜索、读取和媒体工具由各端提供。

## 改动

| 文件 | 改了什么 |
|---|---|
| [技能入口](../../.agents/skills/game-decision-research/SKILL.md) | 迁入两端共同识别的项目目录，更新调用说明 |
| [平台与证据指南](../../.agents/skills/game-decision-research/references/source-guide.md) | 按当前会话可用工具检索，保留 Harness 的工具示例 |
| [参考目录](../../refs/README.md) | 补 Antigravity 的调用方式与共享技能入口 |
| [原接入日志](2026-11-21-08-game-decision-research-skill.md) | 更新指向技能入口和证据指南的链接 |

## 决定与理由

| 是什么 | 为什么 | 代价 |
|---|---|---|
| 两个客户端从 `.agents/skills/` 发现同一个项目技能 | 两端都支持该目录，今后的证据规则与卡片工作流只需改一份 | 旧 `.dsh/skills/` 文件路径已迁移，调用名称继续使用 `game-decision-research` |

## 新增或修改的 deviations

无。

## 验证

- 本机 Antigravity App 的 gameV0 项目设置中，`Customizations → Skills` 列出一条 `game-decision-research`，描述与仓库技能一致。[Google Antigravity 项目发现说明](https://antigravity.google/docs/customization-discovery/)
- 本机 DeepSeek Harness 从仓库子目录重新发现技能，来源为 `project-agents`，可正常加载且三个资源链接都可读取。

## 下一步

遇到具体设计抉择时，在任一端的 gameV0 会话中调用技能，产物继续写入同一方案卡目录。
