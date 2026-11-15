# 2026-11-15-07 整合路线图 bundle（7b0ea7e）

- 日期：2026-11-15
- 作者：DeepSeek
- 类型：更新
- 篇幅：详细
- 触发：用户确认方案 A，把 gameV0-2026-11-15-b.bundle 的新 commit 整合进当前 main

## 结论

- 以 cherry-pick 把 7b0ea7e（docs/03-roadmap + M0 依赖表 + T4 拆分）应用到 e4953a4 之上，保留 T0/T6/CI 四个提交。
- 唯一冲突是 docs/log/README.md 的索引行，已合并；另修了一处自动合并后的语义冲突：02 计划里「审 T1 规格 W3 前」与今天的「三项后移」决定冲突，已改为「已后移，草案先写」。
- 结果：main 前进 1 个新 commit（保留原作者 HaozhengDing，committer 为 DeepSeek，hash 改变）。

## 改动

| 文件 | 改了什么 |
|---|---|
| docs/03-roadmap.md | 新增（来自 bundle）：五步路线、借鉴流程、依赖四类与七个契约、M0 依赖图、M1 粗拆 |
| docs/02-m0-plan.md | 自动合并：保留 T0/T6 进度与优先级调整；并入 T4a/T4b 拆分与依赖表；修正 T1 审阅的 W3 期限表述 |
| AGENTS.md / README.md | 自动合并：加入 03 路线图入口 |
| docs/log/2026-11-15-03-roadmap-and-dependencies.md | 新增（来自 bundle） |
| docs/log/README.md | 冲突已解：索引保留双方行，并加入本篇 |
| docs/log/2026-11-15-07-integrate-roadmap-bundle.md | 新增：本篇 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 用 cherry-pick，不用 merge / force | 保留远端 T0/T6/CI 提交；历史线性；不丢工作 | 7b0ea7e 的 hash 改变 |
| 索引冲突保留双方行 | 两边的 log 都是真实历史，不能丢 | 同一天条目变多 |
| 02 里以「用户后移决定」为准 | bundle 生成于后移决定之前，它的 W3 审阅期限已不成立 | 路线图里的 T1 审阅节点需要后续再校准 |

## 新增或修改的 deviations

无。

## 未解决 / 待决定

- CI 对新 commit 的首次运行结果待确认。
- docs/03-roadmap.md 里的 T1 审阅节点与今天的后移决定需要在下次更新时对齐。

## 下一步

确认 CI 绿；然后按 roadmap 的 M0 关键路径 T2 → T4a → T4b（T5 仍后移）。
