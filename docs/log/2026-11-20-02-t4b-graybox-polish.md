# 2026-11-20-02 T4b 灰盒打磨：火焰灰盒补丁、bugfix 与移动/HUD 手感调参

- 日期：2026-11-20
- 作者：Antigravity
- 类型：更新
- 篇幅：详细
- 触发：按 `docs/handoff-2026-11-20.md` 接手默认推荐工作包 **A（T4b 灰盒打磨）**

## 结论

- **完成 T4b 灰盒打磨**（仅改 `game/`，未动 `sim_core/`、`data/`、`refs/` 或任何契约，不新增玩法系统）：
  1. **火焰灰盒补丁**（对齐 `docs/tech/sim-fire-heat-design.md` §5）：在 `game/scripts/level.gd` 新增 `tick_flammable_spread()`，追踪活跃火格（上限 512，按视口 `active_rect` 休眠），对相邻非油可燃材质（煤/硫磺/竹木，读 `sim.get_material_flammable()`）按统一 **1.5%/tick** 点燃；`executor.gd` 新增 `F` 键手动点火，并修复 `explode` 先挖空导致无法点燃坑缘可燃物的问题（坑缘外扩 +3）。
  2. **修复 5 个真实灰盒 bug**：① 喷**油**原会误调 `douse_fire_around` 灭火（现仅喷水灭火，喷油改为登记邻火助燃）；② 出口区原仅判 `y = 268..270`，沿走廊地板 `y = 275` 走会漏掉出口（现覆盖走廊全高 `y 260..276`）；③ 火伤原仅查脚下 3×3，因身体半宽 2 格挡墙导致贴火墙永远不掉盏（现按 5×10 身体盒外扩 1 格判定，并加火伤红闪）；④ 喷液遇实心墙原 `continue` 穿墙喷射（改为 `break` 并上移起点至胸口）；⑤ `main.gd` 每帧重复调 `set_active_rect` 导致每帧全屏唤醒破坏 chunk 休眠（改为仅视口移动时更新）。
  3. **手感与可读性打磨**：移动提速 `48 → 64 cells/s` + 0.5 格分轴子步滑动 + 落粉脱困（避免碎屑落到角色身上锁死移动）；葫芦吸取半径 `3 → 6`；HUD 加半透明底板、自动贴合尺寸、底部键位提示条、符组灵力消耗、**鼠标指向材质与可燃标注**；新增 `overlay.gd` 显示像素准星与施法/吸喷/点火短暂光圈；修正窗口标题 `T4a → T4b`。
- **全部验收通过**：`validate_data.py` 0 error；`--t4b-smoke` 输出 `T4B_SMOKE_OK`（含手动点火/竹木蔓延/爆炸坑缘引燃硫磺/喷油不灭火/地板出口/火伤贴脸检测回归）；headless 900 帧 0 error；T4a `smoke_sim.gd` 通过；窗口模式 `--t4b-shot` 截图目检正常。

## 改动

| 文件 | 改了什么 |
|---|---|
| `game/scripts/level.gd` | 新增 `tick_flammable_spread()`（非油可燃材质 1.5%/tick 统一蔓延，活跃火格上限 512）、`register_fire_cell()`；`douse_fire_around()` 同步移除追踪火格；修复 `is_at_exit()` 覆盖走廊整高 `y 260..276` |
| `game/scripts/executor.gd` | 修复喷油误灭火、喷液穿墙（遇 solid `break`）、喷液起点上移胸口（`-4`）、火伤检测按 5×10 身体盒外扩 1 格 + 触发角色红闪、`explode` 坑缘 `+3` 引燃；新增 `manual_ignite()`（`F` 键）；`ABSORB_RADIUS 3 → 6`；补全施法日志与 `C-SIM v2` 文案 |
| `game/scripts/player.gd` | 移速 `48 → 64 cells/s`；分轴 `0.5 cell` 子步滑动 + 落粉脱困（不穿静墙/火墙）；新增朝向目视点与火伤红闪 `trigger_hurt_flash()`；支持 `input_enabled` |
| `game/scripts/hud.gd` | 状态栏/日志栏半透明底板与自适应宽高、`MAX_LOG 3 → 4`、底部常驻键位提示条、通关横幅底板 |
| `game/scripts/overlay.gd` | 新增：世界空间像素准星（headless / `--t4b-shot` 隐藏）+ 施法/吸液/喷液/点火短暂光圈与线段反馈 |
| `game/scripts/main.gd` | 仅视口变化时调用 `set_active_rect`（修复休眠失效）；接入 `tick_flammable_spread`、`overlay`、`F` 键手动点火；HUD 增显灵力消耗与鼠标指向材质；出口标记扩至走廊整高并加「出口」文字；`--t4b-smoke` 增加灰盒火焰补丁与 4 项 bugfix 回归断言 |
| `game/project.godot` | 窗口名 `刍狗 T4a 灰盒` → `刍狗 T4b 灰盒` |
| `game/README.md` `game/T4B.md` | 同步火焰灰盒补丁、`F` 键、新 HUD/手感参数与脚本清单 |
| `docs/log/README.md` | 索引顶部新增本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| 火焰灰盒补丁放在 `game/scripts/level.gd` 而非 `sim_core/` | 严守工作包 A 边界（只改 `game/`、不碰 `sim_core`/C-SIM v2 契约、不需重编 DLL，且不影响实验 A 基准） | 追踪上限 512 格且走 GDScript；仅作 M0 灰盒演示，M1-12 正式反应表由 C-SIM v3 接管 |
| 统一蔓延概率取 1.5%/tick，且排除油 | 对齐 `docs/tech/sim-fire-heat-design.md` §5 建议的 1–2%/tick；油已由 `sim_core` 原生 5%/tick 处理，排除后不重复掷骰 | 不消费 `ignition_temperature`，煤/硫/竹木烧速一致（M1-12 再区分） |
| 吸取半径 `3 → 6`、移速 `48 → 64 cells/s` | 化水生成的 13 格水浮在水银面会迅速摊成薄层，半径 3 需连按 E 多次；960 格矿道在 48 cells/s 下跑完全程约 19s 偏慢 | 灰盒手感占位值，后续按用户与 T5 试玩反馈再调 |
| HUD 增显「指向材质（含可燃标记）」与施法光圈 | 守 D1「可读」硬约束与 03 §3.4「可读性靠文字先成立」；灰盒纯色块下无提示很难分辨水银/硝石/硫磺/竹木 | HUD 状态栏略长，已用半透明底板自适应宽度避免遮挡 |

## 验证记录（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| 数据与用例校验 | `python tools/validate_data.py` | `OK: 数据与卡片校验通过`（29 卡 / 18 符卡 4 组 / 30 VM 用例 / 12 材质 8 反应 2 房间），exit 0 |
| T4b 组合与补丁自检 | `Godot_v4.5-stable_win64_console.exe --headless --path game -- --t4b-smoke` | `T4B_SMOKE_OK groups=4 water_gained=13 doused=45 fire_left=0 dug=1270 lanterns=7 spirit=34 tick=255 completed=true`（含 `bamboo 196->167->133`、`sulfur ignited=396`、喷油不灭火、地板出口、火伤贴脸判定），exit 0 |
| 长时运行回归 | `Godot_v4.5-stable_win64_console.exe --headless --path game --quit-after 900` | `T4B_WORLD_READY ...`，0 SCRIPT ERROR，exit 0 |
| T4a 扩展自检 | `Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/smoke_sim.gd` | `SMOKE_OK hash=6100502973529163995 image=120x80 dig=29 ticks=600`，exit 0 |
| 窗口模式截图 | `Godot_v4.5-stable_win64_console.exe --path game -- --t4b-shot` | `T4B_SHOT_SAVED`，exit 0；目检 HUD 半透明底板/中文/指向材质/底部键位条/角色朝向/水银池/火障均正常（未提交临时 png） |

## 新增或修改的 deviations

- T4b 灰盒手感占位调参（非正式设计数值，不改 `data/`）：移速 `48 → 64 cells/s`、葫芦吸取半径 `3 → 6`、灰盒非油可燃蔓延 `1.5%/tick`（上限 512 活跃火格）、手动点火半径 `3`、爆炸坑缘引燃外扩 `+3`。复议条件：用户试玩反馈或 T5 外部试玩后调整；M1-12 正式反应表上线时移除灰盒火焰补丁。

## 未解决 / 待决定

- **待用户本机试玩反馈**：可运行 `C:\Users\perrychuh\t4a-tools\godot\Godot_v4.5-stable_win64.exe --path d:\gameV0\game` 亲手试玩一轮（尤其看移速、火障贴脸掉盏、room-02 点燃硫/煤/竹木效果与 HUD 排版）。
- M0 门仍待收尾：实验 A 目标机复测、实验 C 外部 5 人试玩（可选先做工作包 B 预演包或工作包 C 评审账本）、2027-01-10 go/no-go 评审。

## 下一步

- 收集用户对本轮 T4b 灰盒的手感反馈；若无需继续调参，可推进工作包 B（实验 C AI 预演包）或工作包 C（M0 评审账本）。
