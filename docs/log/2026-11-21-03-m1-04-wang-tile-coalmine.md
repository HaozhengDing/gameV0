# 2026-11-21-03 M1-04 落地：矿井一层完整 Wang Tile 程序化拓扑、手工房间无缝拼接、BOSS 房与三大 Hazard

- **日期**：2026-11-21
- **类型**：更新（关卡生成引擎 + 数据 + 叙事碑文 + 生物群系 Hazard）
- **篇幅**：详细（D-M1-2 核心关键路径交付，新增 4 文件、扩展数据校验与多 seed 连通性回归）
- **前置**：`docs/04-m1-plan.md`（D-M1-2 已拍板完整 Wang Tile）、`data/biomes/level-01-coalmine.json`、`data/rooms/*.json`

---

## 1. 结论

**M1-04（矿井一层完整 Wang Tile + 手工房间拼接 + 连通性校验 + 碑文与三大 Hazard）已完成并成为默认实机玩法世界**：

1. **完整 4-bit Wang Tile 程序化矿井（`1536×672` cells，约 8 屏可探索空间）**：新增 `game/scripts/wang_gen.gd`，按 `4×3` 宏观格 × `24×14` 粗格（`tile_size=16`，与手工房间 `384×224` cells 严格同尺度）生成边色完全对称的 Wang 拓扑（生成树 + 3 条环路），其余 8 格按 4-bit 边掩码（`N/E/S/W`）与 3 套变体生成带 2 格有机粗糙岩壁、竹木支护与生物群系矿脉（煤/硝石/硫磺/朱砂/石灰）的程序化矿道，整张百万格世界光栅化仅需 **~90 ms**。
2. **三大手工房间 1:1 无缝拼接**：新增旱魃 BOSS 房 `data/rooms/room-boss-coalmine.json`（含左下蓄水池、右上阴气渗漏区与双侧竹木台，已纳入 `validate_data.py` 对 `boss.arena` 的交叉校验）；将入口安全区（`0,0`，可按 `B` 改符）、`room-02-gas-pocket`（早段）、`room-01-silver-pit`（中段）与 `room-boss-coalmine`（`3,2` 矿底）按宏观 Wang 边掩码切开门洞无缝拼入矿道网络；按 `R` 重开自动递增 seed 生成全新矿井。
3. **粗格 BFS 连通性自动化兜底**：`wang_gen.verify_connectivity()` 对全图 `96×42` 粗格做边匹配 + BFS 可达校验；headless 回归连测 **5 个不同 seed（`20261121–20261125`）**，100% 边零错配、12/12 宏观区与 4 处关键房及出口全可达。
4. **规矩碑文（D2 + D3）与三大 Hazard 全落地**：
   - `game/scripts/stele.gd`：世界空间绘制石碑并在 28 格内浮显 C-TEXT 碑文（`sanity < 66` 自动切腐坏文本，首次读碑发 `rule_triggered`）；
   - `game/scripts/biome_hazards.gd`：落地 `quicksilver_no_regen`（浸水银暂停法器回灵 + `hazard_triggered`）与 `collapse`（3 秒内挖掘 ≥ 600 格引发矿顶落石碎屑 + 15 HP 伤 + `hazard_triggered`），与 C-SIM v3 原生 `gas_explosion` 构成矿井一层完整三大 hazard。

---

## 2. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **宏观网格与手工房间严格同尺度（`384×224`）** | 4×3 宏观 Wang 格每块恰为 `24×14 × 16 = 384×224` cells，直接复用 `data/rooms/*.json` 原始网格 | 手工房间可零缩放、零裁剪无缝嵌入任意宏观格，且 12 块拼出 `1536×672`（约 103 万格、4 MB RAM、90 ms 生成），兼顾探索纵深与瞬间重开 | 宏观门洞位置标准化在每边中段（水平行 6..8、竖直列 10..13），手工房边界对应位置在拼接时会被切开 |
| **保留经典 `960×540` 供 `--t4b-smoke` 历史步回归，实机默认进 Wang 矿井** | 默认启动与 `--t4b-shot` 进入 `1536×672` Wang 矿井（可用 `--classic-t4b` 回退）；`--t4b-smoke` 先跑完步骤 0–12 再在 Step 13 测 5-seed Wang 矿井 + 碑文 + Hazard | 既不破坏此前 M0/M1 任何回归用例，又让制作人直接打开游戏就能体验最新完整矿井一层 | `main.gd` 保留双路径分支，待 M1-09 整局闭环后可退休经典灰盒分支 |

---

## 3. 文件改动与验证结果

- 新增 `data/rooms/room-boss-coalmine.json`：旱魃 BOSS 房数据（3 个手工房全部就位）。
- 更新 `data/texts/zh-CN.json`：新增 `$ui_hazard_collapse` / `$ui_hazard_quicksilver`（共 79 条）。
- 更新 `tools/validate_data.py`：`validate_biomes()` 新增 `boss.arena` 存在性校验。
- 新增 `game/scripts/wang_gen.gd`、`game/scripts/stele.gd`、`game/scripts/biome_hazards.gd`。
- 更新 `game/scripts/main.gd`：默认启用 Wang 矿井、动态世界/相机边界、安全区与出口切换、按 `R` 换新 seed、接入碑文与三大 Hazard，并新增 `--t4b-smoke` Step 13。
- 更新 `docs/04-m1-plan.md`：标注 M1-04 已完成。

| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **通过**（`rooms: 3`，含 `room-boss-coalmine` 与 `boss.arena` 核验） |
| `Godot --headless -- --t4b-smoke` | **通过**（13 步全过；Step 13 `seeds=5/5 connected=100% macros=12/12 rast_ms=89 steles=5 hazards=ok`） |
| `Godot --headless --quit-after 900`（Wang 矿井模式） | **通过**（`1536×672` 跑满 900 帧 0 错误） |
| `Godot -- --t4b-shot`（Wang 矿井模式） | **通过**（入口安全区石槽蓄水池、石碑浮字「矿里不能用明火」、正下方无缝拼接瓦斯囊与右侧 Wang 矿道目检清晰） |

---

## 4. 下一步

- M1 前半程关键基础设施已全部就位（M1-01 / M1-12 / M1-02 / M1-05 / M1-03 / M1-04 全绿），下一阶段即刻进入 **M1-α 玩法闭环冲刺**：
  1. **M1-06（敌人 AI 与旱魃 BOSS 战）**：3 小怪（矿鬼/土蝼/硫烟鬼火）+ 1 精英（画皮）+ 旱魃 BOSS 机制化战斗（火抗、弱水/阴气）；
  2. **M1-07（洞天：传法三选一 + 线性银两商店 + 复灯回血 + 改符安全区）**；
  3. **M1-08（神智与可逆入魔精简 4 条）** → **M1-09（整局闭环与死因回顾）** → **M1-10（可读性表达收尾）**。
