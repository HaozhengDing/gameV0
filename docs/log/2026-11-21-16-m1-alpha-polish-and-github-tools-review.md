# 2026-11-21-16 M1-α 三项体验打磨落地 + GitHub 开源工具/技能建议评估

- 日期：2026-11-21
- 作者：Antigravity
- 类型：更新 + 评审
- 篇幅：详细
- 触发：制作人拍板一次性落地 M1-α 三张决策卡首选方案（粉末分级减速同步给小怪 / 旱魃空间效用 AI / 浮空收敛与下落慢充），并要求评估远端新增的 GitHub 开源项目与工具链建议

## 结论

1. **M1-α 三项体验打磨一次性落地并通过 17 步全量自动化回归**：粉末三级密度减速（玩家与地面小怪同步）、旱魃空间效用 AI（跃台/烈焰滑步/贴脸震退/湿破甲 0.55s 硬直后跃离水洼/P2 引燃竹台不挖岩坝）、浮空条收敛（`1.92s → ~1.16s`，单气实测爬 `99.1` 格）+ Noita 式 `0.28s` 延迟下落慢充（`16/s`，10 轮点按防无限滞空通过）。
2. **GitHub 开源项目与工具链评估结论**：与 `docs/04-m1-plan.md` 附录 A 一致，**M1 当前阶段暂不引入 `godot-mcp`、`GodotPrompter` 整包、`LimboAI` 或任何 Godot 4.7+ 工具**；最值得提前采纳的是 **M1-11 的 `libFuzzer` 模糊测试（对症 C46）**，以及 **M2 的 `LDtk`（批量做房间）+ `Pixelorama / Material Maker / rFXGen`（替换灰盒美术与合成音效）**。

---

## 一、M1-α 三项打磨改动与实测数据

| 项目 | 改动文件 | 核心变化 | `--t4b-smoke` 第 17 步实测 |
|---|---|---|---|
| **粉末分级减速（玩家 + 地面小怪同步）** | `game/scripts/powder_physics.gd`、`player.gd`、`enemy_ai.gd`、`enemy_manager.gd`、`data/magic_numbers.json` | 共享 `data/materials.json` 密度表；硬碰撞仅认 `SIM_STATE_STATIC`（岩/竹木），脚底保留粉坡承托，水平/空中涉粉按重叠占比与 3 档密度减速（轻 `0.75×` 糯米/煤、中 `0.55×` 沙/硫/硝、重 `0.35×` 石灰/朱砂；零散落粉 `<12%` 不减速）；按 `S` 可主动下沉穿粉 | `wade=16.3>12.3>8.1`（煤 > 硫磺 > 朱砂），`mob_slow=ok`（矿鬼朱砂堆内 `<0.55×` 减速且不卡死） |
| **旱魃 BOSS 空间效用 AI** | `game/scripts/enemies/enemy_ai.gd`、`enemy_manager.gd`、`data/entities/layer01.json` | 取消 0→1→2 死板循环，改为按 `(距离, 高低差, 阶段, 上一招)` 加权选招（禁连续复读 `×0.20`）；新增**腾跃扑台**（反竹台白嫖）、**烈焰滑步 155**（反远程风筝并留火痕）、**贴脸炽浪震退+后跃**、每 2 招**战术重定位**；首次 `wet` 破甲触发 **0.55s 嘶鸣硬直**，脚下有水时自动**跃离水洼**；P2 猛扑引燃竹木台但绝不 `dig` 岩坝 | `boss_smart=ok`（高台反制 + 湿破甲硬直 + 离水跃出全通过） |
| **人物浮空收敛 + 下落慢充** | `game/scripts/player.gd`、`data/magic_numbers.json` | `MOVE_SPEED 68→60`、`HOVER_MAX_UP -96→-76`、`HOVER_ACCEL 480→390`、`LEVITATE_DRAIN 52→86/s`（~1.16s）、`LEVITATE_REGEN 165→145/s`；新增 Noita 式延迟下落慢充（`vy > 24` 且停推满 `0.28s` 后 `16/s` 慢充，不足消耗 `1/5`）；保留 `levitate_air_regen` 开关可一键置 `0` 对比 | `climb=99.1`（单气可稳出 80 格水银池）、`fall_regen=+11.5`（延迟内 0 回充，1s 自由落体慢回 11.5）、`no_inf=ok`（10 轮高频点按净下落 >40 格且气槽耗尽） |

另同步将 3 张决策卡状态更新为 **已试验**（`refs/cards/decisions/{powder-traversal,boss-ai-mobility,player-levitation-tuning}.md`），并将新参数与偏离写回 `data/magic_numbers.json`、`data/entities/layer01.json`。

---

## 二、新增 GitHub 开源项目与工具链建议评估

对照远端新增的 `docs/research/oss-gamedev-tools-2026-11.md`、`docs/research/oss-projects-2026-11.md` 与 `docs/04-m1-plan.md` 附录 A，按**投入产出比（ROI）与与当前架构的契合度**逐项评估：

| 工具 / 技能 | 评估结论 | 理由与适用时机 |
|---|---|---|
| **`Coding-Solo/godot-mcp`**（6.7k★ MIT） | **M1 暂不引入，M2 再开** | 本项目 `game/` 当前是 100% 纯代码建树（无复杂 `.tscn` Inspector 调试需求），已通过 `Godot_v4.5-stable_win64_console.exe` + 17 步 `--t4b-smoke` + `--t4b-shot`/`--t4b-boss-shot` 跑通自动闭环；现阶段接 Node MCP 只增配置与权限面。等 M2 进入场景/Shader/灯光可视化摆放时再接入 ROI 最高 |
| **`jame581/GodotPrompter`**（981★ MIT，支持 Antigravity skills） | **不整包导入；M1-11/M2 按需摘取 3–4 条** | 其通用技能默认 `.tscn` + GUT + LimboAI 工作流，与本项目 C++ GDExtension + 冻结契约（C-SIM/C-VM/C-EVT/C-TEXT）+ `--t4b-smoke` 差异较大，整包塞进 `.agents/skills/` 易误导 agent 套错范式；后续只裁剪吸收 Godot 4.5 导出与 GL Compatibility 避坑清单即可 |
| **`libFuzzer` / `AFL++`** | **推荐进 M1-11 冷却期** | 对 `talisman_vm`（随机符序组合）与 `sim_core` 反应表跑 5 分钟模糊测试，成本极低且直接对症 C46（「AI 写的语义边界难自证」） |
| **`Tracy` / `nanobench`** | **`nanobench` 暂不需要；`Tracy` 留到目标机实测** | 自研 `sim_bench.exe` 已覆盖 6 场景 3000 tick p50/p95/p99；`Tracy` 需重编引擎，待低配目标机复测若出现渲染/GDScript 帧耗瓶颈时再启用 |
| **`LDtk`**（5.0k★ MIT） | **M2 强烈推荐** | M1 仅 3 个手工房，手写 ASCII JSON 最快；M2 扩至 15–30 房与第 2/3 层时，写 ~100 行 Python 转换脚本把 LDtk JSON 导成 `data/rooms/*.json`（零改运行时契约）收益极大 |
| **`Pixelorama` / `Material Maker` / `rFXGen`** | **M2 美术/音效替换首选** | 全 MIT/Zlib，直接承接灰盒转像素资产与 M1-10 `sfx_bank.gd` 合成音替换 |
| **`LimboAI` / `Dialogue Manager` / `hi-godot/godot-ai`** | **明确不引入** | `godot-ai` 需 Godot 4.7+ 不兼容；M1-06 自研空间效用 AI 与 C-TEXT 词表已轻巧够用，M2 视内容量再重估 |
| **`sand-slide` / `noita-wand-sim` / `The-Powder-Toy`** | **仅只读对照** | 严守开源与版权红线（GPL-3 与 Noita 版权数据绝不进仓库） |

---

## 验证记录

- `python tools/validate_data.py`：**OK**（`entities: 5 种敌人` 与 `magic_numbers.json` 全过）
- `--t4b-smoke`（17 步全量）：**`T4B_SMOKE_OK`**（含 `M1-α三项打磨 wade=16.3>12.3>8.1 mob_slow=ok climb=99.1 fall_regen=+11.5 no_inf=ok boss_smart=ok`）
- `--quit-after 900`（Wang 矿井 15s 空跑）与 `smoke_sim.gd`：0 脚本报错，全过

## 下一步

请制作人实机复测 M1-α 打磨后的手感（涉粉减速、浮空收敛+下落慢充、新旱魃 BOSS 战）；通过后即推进 **M1-07（洞天三选一 + 商店线性经济）** 或 **M1-08（神智与可逆入魔）**。
