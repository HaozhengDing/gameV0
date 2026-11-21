# 2026-11-21-13 GitHub 开源项目扫描：与《刍狗》目标契合的参考项目

- 日期：2026-11-21
- 作者：DeepSeek
- 类型：建议（技术参考/竞品邻近）
- 篇幅：详细
- 触发：用户「我好奇 GitHub 有没有游戏制作相关的项目，尤其是比较契合我们的目标的？帮我找一下」

## 结论

1. **没有可直接复用的完整同款**（国风符箓 × 元素沙盒 × Roguelite）；最接近的是技术侧 `sand-slide`（Godot 4 + C++ GDExtension + falling sand，MIT，143★）与题材侧 `Night-Patrol`（志怪卡牌 roguelite，158★）/`daofaziran`（符箓·阵法 Minecraft mod，MIT）。这补充了 D1 理由 6「组合空位存在但护城河不深」的证据。
2. **技术栈最贴合**：`kiwijuice56/sand-slide`（元素类 + `process(sim,row,col)`、无逐格数据）；`xy200303/CellularFX`（Godot 4 GDExtension CA 引擎：CPU/GPU 双后端、材质 Resource、反应/温度、基准 + 编辑器 Dock）——但后者 1★、非常新，只能作设计参考，不作依赖。
3. **成熟 falling-sand 参考**：The Powder Toy（GPL-3，5.4k★）、sandspiel（MIT，3.2k★）、sandboxels（自定义非商用许可，486★，500+ 元素/数千反应）。前两者更适合读数据组织/交互；许可证都不允许把代码/内容搬进我们的商业项目。
4. **C-VM 语义验证**：`Heipen/noita-wand-sim`（MIT 代码）直接跑 Noita 原版施法 Lua，适合做「同一魔杖/符序列」的差分校准；但其内置 Noita 数据有版权，只能本地研究、不可进仓库/发行。
5. **结构/题材**：`statico/godot-roguelike-example`（MIT，BSP/视野/行为树）、`mo_yu_pai_xia`（MIT，Godot 4.5 卡牌肉鸽）、`Night-Patrol`（志怪题材，许可未明示）、`daofaziran`（符箓/阵法/妖丹）。

## 改动

| 文件 | 改了什么 |
|---|---|
| `docs/research/oss-projects-2026-11.md` | 新增：GitHub 开源项目扫描（技术邻近 / falling-sand 参考 / 符箓 VM / 国风结构 / 许可证红线 / 对我们的用途 / 限制） |
| `docs/log/README.md` | 索引加本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 只记录「可借鉴点」与许可证红线，不引入任何第三方代码/数据 | 项目规则：不照搬 Noita 代码/数值/资产；第三方 GPL/非商用/NOASSERTION 不能进闭源商业发行；MIT 代码也应重写而非复制 | 需要我们自己实现，但避免了许可与「AI 照抄」风险 |
| 把 `sand-slide` / `CellularFX` 列为技术对照，而非依赖 | 我们已有 C-SIM v3 与 Godot 4.5 工程；它们可用于对照架构/性能/编辑器工具，不能替换我们已冻结的契约 | 只能读，不能省实现工作量 |
| 把 `noita-wand-sim` 列为「本地差分校准」候选 | 我们的 C-VM 是自研语义（Noita 只是参考）；用原版 Lua 做差分可以补 30 条用例之外的长尾 | 需要本机 Noita 数据；数据不进仓库；只做研究 |
| 国风题材参考只到「命名/资源/UX」层 | Night-Patrol/daofaziran 的资产与代码不可用；我们只需要验证「符箓/香火/阵法」这类词汇与交互是否被玩家接受 | 没有可直接复用的国风素材 |

## 新增或修改的 deviations

无（纯研究/文档，不改实现、数值、契约）。

## 未解决 / 待决定

- 是否要做一次「C-VM vs Noita 原版 Lua」的本地差分校准（需要用户提供/确认本机 Noita 数据，仅本地研究，不进仓库）；
- 是否在 M1-12 性能/反应设计卡住时，深入读 CellularFX / The Powder Toy 的对应实现（只读）；
- GitHub 搜索 API 未登录限速（10 次/分），本轮未覆盖 itch.io / GitLab / Steam 开源项目；star 数为 2026-11-21 快照；未逐仓库构建运行。

## 下一步

- 无需立即行动；M1-α 打磨与 M1-07/M1-08 仍是主线。
- 如果用户想深入某一个项目，我可以只读 clone 后做架构对比（不引入依赖/代码）。
