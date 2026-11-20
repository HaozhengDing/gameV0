# 2026-11-20-04 T4b 角色物理移动（Noita 式重力/浮空）与去中二极简命名/HUD 落地

- 日期：2026-11-20
- 作者：Antigravity
- 类型：更新 + 决策落地
- 篇幅：详细
- 触发：用户对 `-03` 方案拍板：「A；急急如律令这种明确的道教的东西可以保留，其他的克制单字，我记得急急如律令好像是符上的。」

## 结论

1. **落地 Noita 式轻量角色物理移动**（仅改 `game/scripts/player.gd` 与 `main.gd`，未碰 `sim_core/`）：重力下落 + 地面摩擦 + **1–3 格像素碎屑自动迈步** + `W/Space` 起跳与**有限浮空条**（含下落急刹，约 1.9s 连续推力、落地 ~0.6s 快充）+ 液体阻力与水银轻浮力 + 脚底浮空光焰指示。
2. **落地极简/克制命名原则并写回正式数据与规范**：
   - 保留明确有出处的正统道教符语（`急急如律令`、`天罡`、`敕·触`、`奉·时`、`五雷`、`镇`、`归`）；
   - 其余单卡改克制单字或直白功能词（`飞剑→斩`、`毕方火→火`、`鬼火→阴`、`土遁→掘`、`藤生→生`、`煞→爆`、`噬→吸`、`化·水→化水`、`分身→分`）；
   - **取消符组合体名**，按组成直接展示（`斩 + 爆` / `火 + 化水` / `阴 + 镇` / `掘 + 归`），同步写回 `data/talismans.json`、`refs/cards/p0/talismans.yaml` 与 `refs/naming.md` §5（所有 id、数值、C-VM/C-ACT 语义均不变）。
3. **重做 T4b HUD 为 Noita 式彩色条 + 平铺符槽**：左上 7 格红条 + 蓝条（法力）+ 黄条（浮空）+ 葫芦水/油双条；顶中 4 个符槽平铺且隐藏 `[F-0001]` 与冗长包装词；右上仅留指向材质与出口距离。
4. **全项验收通过**：`validate_data.py` 通过、`--t4b-smoke` 通过（新增第 7 步角色物理回归：下落/浮空急刹上升/消耗与接地回充）、headless 900 帧 0 error、T4a `smoke_sim.gd` 通过、窗口截图目检清晰。

## 改动

| 文件 | 改了什么 |
|---|---|
| `data/talismans.json` | 保留正统道教符语（`急急如律令`/`天罡`/`敕·触`/`奉·时`/`五雷`/`镇`/`归`），其余单卡精简为克制单字/功能词，符组名改为组成形式（`斩 + 爆` 等），`v1_deviations` 记录理由与复议条件；id 与数值全不变 |
| `refs/cards/p0/talismans.yaml` | 同步 F-0001~F-0004 卡面命名与 `deviations` |
| `refs/naming.md` | 新增 §5「玩法界面与符箓命名克制原则」（2026-11-20 用户拍板） |
| `game/scripts/player.gd` | 重写为 Noita 式轻量物理移动：重力、地面/空中加减速、1–3 格碎屑自动迈步、土狼时间起跳、`W/Space` 有限浮空 + 下落空中急刹（`HOVER_BRAKE_ACCEL=780`）、`S` 加速下潜、水/油阻力与水银轻浮力、脚底浮空光焰；抽离 `step_physics()` 供回归测试 |
| `game/scripts/hud.gd` | 重做为 Noita 式极简 HUD：左上 7 格红条 + 蓝/黄条 + 葫芦水油双条；顶中 4 符槽平铺；右上极简材质与出口距离；左下短事件日志 + 底部键位条 |
| `game/scripts/main.gd` | 接入 `hud.set_slots()` / `hud.update_state()`、角色 `Jet` 浮空指示、重开/复位调用 `player.reset_motion()`、`HUD_INTERVAL 0.1→0.05`；`--t4b-smoke` 新增第 7 步角色物理回归断言 |
| `game/scripts/executor.gd` | 精简事件日志文案（去「盏/灵力/回符中」冗长包装） |
| `game/README.md` `game/T4B.md` | 同步新操作键位（`W/Space` 浮空、`S` 下潜）、极简 HUD 与新符槽名 |
| `docs/log/README.md` | 索引顶部新增本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 采用重力 + 1–3 格迈步 + 有限浮空（含下落急刹） | 解决「像编辑器游标一样自由飘」的问题，又保证掉进 80 格深的水银池/矿坑底能飞回门洞；首次回归暴露下落中反推偏迟钝，补 `HOVER_BRAKE_ACCEL=780` 后空中急刹跟手 | 灰盒物理常量（重力 260 / 浮空 100 / 耗 52/s / 充 165/s）需随用户实机再微调 |
| 水银给轻浮力、液体中浮空耗能降为 20% | 水银密度 13.6，浮在水面符合物理直觉；避免玩家在池里耗尽浮空条卡死 | 仅灰盒级液体阻尼，不做复杂流体推力（M1 再评估） |
| 保留明确道教符语，其余去中二改克制单字、取消组合名 | 落实用户拍板与 `refs/naming.md` 去中二红线；`急急如律令` 等真实符语撑住题材辨识度，单字动作与彩色状态条大幅降低 HUD 认知负荷 | 旧文档/历史 log 中仍保留原名作追溯，不回改历史存档 |

## 验证记录（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| 数据与卡片校验 | `python tools/validate_data.py` | `OK: 数据与卡片校验通过`（29 卡 / 18 符卡 4 组 / 30 VM 用例 / 12 材质 8 反应 2 房间），exit 0 |
| T4b 组合/补丁/物理自检 | `Godot_v4.5-stable_win64_console.exe --headless --path game -- --t4b-smoke` | `T4B_SMOKE_OK groups=4 water_gained=13 doused=45 fire_left=0 dug=1270 lanterns=7 spirit=34 tick=255 completed=true`（含 `角色物理 fall=882.0->975.9 hover->896.4 lev=74->100`），exit 0 |
| 长时运行回归 | `Godot_v4.5-stable_win64_console.exe --headless --path game --quit-after 900` | `T4B_WORLD_READY ...`，0 SCRIPT ERROR，exit 0 |
| T4a 扩展自检 | `Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/smoke_sim.gd` | `SMOKE_OK`，exit 0 |
| 窗口截图目检 | `Godot_v4.5-stable_win64_console.exe --path game -- --t4b-shot` | `T4B_SHOT_SAVED`，目检 7 格红条/蓝条/黄条/葫芦双条/4 个平铺符槽/右上材质与出口/底部键位条布局清晰无遮挡 |

## 新增或修改的 deviations

- `data/talismans.json` `v1_deviations` 与 `refs/cards/p0/talismans.yaml` `deviations`：记录 2026-11-20 命名精简（保留正统道教符语、其余克制单字、取消符组合体名）；数值与 id 未变。
- T4b 角色物理参数（`MOVE_SPEED=68`、`GRAVITY=260`、`HOVER_ACCEL=480`、`HOVER_BRAKE_ACCEL=780`、`LEVITATE_MAX=100`、`LEVITATE_DRAIN=52`、`LEVITATE_REGEN=165`、`STEP_UP_MAX=3`）为灰盒调参占位，待用户实机手感与 T5 试玩复议。

## 未解决 / 待决定

- 等用户再次实机试玩验证：重力轻重、浮空续航/回充速度、碎屑迈步顺滑度、极简 HUD 可读性。
- M0 收尾仍待：实验 A 目标机复测、实验 C 外部 5 人试玩（或先做工作包 B 预演包 / C 评审账本）、2027-01-10 go/no-go 评审。

## 下一步

- 用户再试玩一轮 T4b；若移动与 HUD 手感过关，可按需切入工作包 B（实验 C AI 预演包）或工作包 C（M0 评审账本）。
