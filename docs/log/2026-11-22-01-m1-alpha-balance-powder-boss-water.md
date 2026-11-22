# 2026-11-22-01 M1-α 实机复测四项调优：场景刷怪翻倍、土堆禁下沉与防掩埋、旱魃加压改水池与主动畏水避让

- 日期：2026-11-22
- 作者：Antigravity (Gemini)
- 类型：更新 + 决策
- 篇幅：详细
- 触发：用户完成 M1-α 实机试玩复测后反馈 4 项调整需求：场景刷怪翻倍；怪物不加载到土堆下面、人物也不能沉到土堆下面；BOSS 攻击力提高且水源放更偏（仍在 BOSS 房内）以提升难度；旱魃 BOSS 主动怕水并尝试跳开避水。

## 结论

已完成全部 4 项实机复测调优并纳入自动化回归：矿井一层每个非安全区战斗场景刷怪量翻倍至每房 2 只（全层共 21 只 = 20 小怪/精英 + 1 旱魃 BOSS）；全图预沉降增至 240 tick + `has_powder_above` 校验 + 玩家/怪物下落严禁穿粉，彻底杜绝角色与怪物钻进或刷新在土堆下方，同时保留踩粉表面三级密度减速；旱魃全招式伤害上调约 60–75%、水源移至 BOSS 房最偏远的右上高台石槽、并新增 5 处主动畏水避让行为。`validate_data.py`、`--t4b-smoke` 17 步（含 `no_sink=ok` / `under_powder=0` / `boss_fear_water=ok`）、`smoke_sim.gd`、900 帧矿井长跑与 `--t4b-boss-shot` 实机截图校验全部通过。

## 改动

| 文件 | 改了什么 |
|---|---|
| `game/scripts/wang_gen.gd` | 1) `settle_world` 默认预沉降 `120 -> 240` tick；2) `find_safe_stand_pos` 限制在同房间边界内寻位，新增 `has_powder_above` 检测头顶至岩顶无任何粉末（3 轮优先干地无粉），杜绝刷在土堆内部或下方；3) `_build_wang_cavern` 刷怪锚点由 `75% × 1` 改为固定左右分散 `2` 处（翻倍），并避开 `EDGE_S` 竖井口放置楼上水洼防误渗 BOSS 房 |
| `game/scripts/enemies/enemy_manager.gd` | 手工非 BOSS 房（`room-01-silver-pit` / `room-02-gas-pocket`）各追加 1 只错位随行小怪（每战斗场景 2 只，全层固定 `21` 只）；飞行怪 `_lift_flyer_spawn` 同步校验 `has_powder_above`；打印 `M1_ENEMIES_SPAWNED total=21 boss=yes` |
| `game/scripts/powder_physics.gd` | `sample_box` 增加脚底 2 格粉堆表层采样（`0.80× / 0.62× / 0.44×` 三级表层阻力，不沉入土堆也有清晰材质脚感）；新增 `has_solid_at_row`（下落硬止于岩/粉行）与 `is_settled_mound_wall`（防侧面横钻厚土堆底部） |
| `game/scripts/player.gd` | 取消按 `S` 与 `_powder_fill >= 0.28` 导致的向下穿粉下沉；下落遇岩或沉降粉行立刻稳停；水平粉坡自动迈步升至 `STEP_UP_MAX = 4`、禁从外侧横钻厚土堆底、遇塌方落尘包裹时自动上浮回表层 |
| `data/rooms/room-boss-coalmine.json` | 水源从易取水的左下地面迁至最偏远的**右上高台石槽**（`row 3, cols 19..22`，距西/北两入口均最远且跨过旱魃，需经 `row 8` 竹木台二段攀登取水或向上掘壁泄洪）；阴气渗漏区移至左上；双侧竹木平台调至 `row 8` 兼顾玩家单气攀登与旱魃真跃台；右下煤硫堆左移避开 `出口` 标记 |
| `data/entities/layer01.json` | 旱魃攻击力与压迫感全面抬升：`damage 14->22`、`projectile.damage 10->16`、`chase_speed 52->58`、`lunge_speed 136->148`、`dash_speed 155->172`、`telegraph_ticks 24->22`、`attack_cooldown_ticks 62->50`；更新 `v1_deviations` |
| `game/scripts/enemies/enemy_ai.gd` | 1) 同步玩家防下沉/防横钻土堆物理（`STEP_UP_MAX = 4` + `has_solid_at_row` + `is_settled_mound_wall`）；2) 旱魃招式提伤（扇弹 `16/20`、滑步 `18/22`、炽浪 `20/24`、扑台 `22/26`、P2 灼浪 `24`）并按物理抛物线公式修正 `platform_leap` 起跳初速使其真正跃上 `row 8` 竹台；3) 新增旱魃主动畏水 AI（巡逻折返、追击跨洼跳/干边急刹、滑步遇水急刹跃避、脚边/头顶来水向最干燥侧惊跳 `avoid_water`、选招遇水降权滑步、沾水硬直后朝最干燥侧 `escape_leap`） |
| `game/scripts/main.gd` | `_start_round` 与 `--t4b-smoke` 预沉降改用 `240` tick；Step 13 实测 `spawn_from_wang_anchors` 校验 `mobs >= 18` 且 `buried=0 / under_powder=0`；Step 17 升级断言 `no_sink=ok`（按 S 不下沉）、表层三级减速 `surf=17.9>14.2>10.3`、小怪重粉减速且不下沉、旱魃高伤与主动畏水跃避 `boss_fear_water=ok` |

## 决定与理由

1. **沉降土堆承托脚底 + 表层 3 档阻力，而非允许下沉钻堆**
   - **是什么**：角色与怪物永远站在沉降土堆顶部（按 `S` 也不下沉），通过脚底 2 格采样保留煤（`0.80×`）/ 硫磺（`0.62×`）/ 朱砂（`0.44×`）三级移速差异；仅空中落尘与薄粉可水平/向上软穿行，被塌方盖住时自动上浮。
   - **为什么**：上一版允许按 `S` 或 `fill >= 0.28` 下沉后，玩家与小怪会直接沉进或钻到土堆下面，视觉与物理预期均显穿帮；改为「顶面承托 + 表层减速 + 4 格爬坡 + 禁钻底」同时满足不卡脚与不钻底两项体验目标。
   - **代价**：玩家面对 >4 格的陡直人工粉墙不能直接横穿底部，需要起跳/浮空翻越或用 `掘` 挖开（符合自然直觉）。

2. **场景刷怪固定翻倍至每战斗房 2 只（全层 21 只）**
   - **是什么**：8 块 Wang 矿道全部从 `75% × 1` 改为固定左右各 1 只（16 只），`room-01-silver-pit` 与 `room-02-gas-pocket` 各配 1 只随行小怪（4 只），加上旱魃共 21 只；精英画皮仍维持 1 只保底，防止早期过量熄灯。
   - **为什么**：原每房 0–1 只怪在 1536×672 矿井内偏空旷，战斗节奏稀疏；翻倍后每进一个房间基本都有 2 只怪形成交叉压迫。
   - **代价**：无敌帧外受击频率增加，后续若感觉偏难可在 `wang_gen.gd` / `enemy_manager.gd` 按深度行 `mr` 做渐进梯度（例如浅层 1–2 只、深层 2–3 只）。

3. **BOSS 房水源迁至右上远角高台石槽 + 旱魃加伤与主动畏水 AI**
   - **是什么**：水源置于远离西/北两个入口的对侧右上高台（`row 3, cols 19..22`），旱魃招式单次伤害升至 `16–26`（4–5 击致死）并拥有 1.25s 冷却的主动畏水跃避（`WATER_AVOID_COOLDOWN = 75`）。
   - **为什么**：原左下地面水池开局唾手可得，且旱魃伤害偏低、见水不躲，削弱了 BOSS 战紧迫感；新布局逼迫玩家先顶着高压跨过旱魃或借 `row 8` 竹台攀高取水/掘槽泄洪，且泼水需要预判落点或借围堵/泄洪命中，破甲正反馈更强。
   - **代价**：`water_avoid_cd = 75` 刻意留出 1.25s 冷却窗口，避免旱魃因无限连跳彻底无法被水泼中导致设计反锁；若实机觉得太难泼中，只需把 `WATER_AVOID_COOLDOWN` 调高至 `95–110`。

4. **全图预沉降由 120 tick 升至 240 tick**
   - **是什么**：开局光栅化后统一推演 240 帧再校准刷怪位。
   - **为什么**：单房高度 224 格，`room-02-gas-pocket` 悬空煤/硫层与矿道顶矿脉需要约 180–220 帧才能彻底落底堆积，120 帧会导致残留悬空粉在玩家靠近后砸埋敌人。
   - **代价**：开局生成耗时增加约 `0.6–0.7s`（实测 `990–1078 ms` 一次性完成，进图后 0 掉帧）。

## 新增或修改的 deviations

- `data/entities/layer01.json`：`v1_deviations` 追加第 4 条，记录 M1-α 复测难度加压后的旱魃攻击力/移速/冷却与主动畏水避让机制。
- `data/rooms/room-boss-coalmine.json`：`notes` 同步更新右上高台石槽蓄水与 `row 8` 双竹台博弈说明。

## 验证记录

| 检查项 | 结果 | 关键实测指标 |
|---|---|---|
| `python tools/validate_data.py` | PASS | 29 卡 / 18 符 / 3 法器 / 79 词条 / 5 敌人 / 12 材质 / 8 反应 / 3 房间全过 |
| `--t4b-smoke`（17 步全回归） | PASS | `mobs=21 buried=0 under_powder=0`、`no_sink=ok surf=17.9>14.2>10.3 mob_slow=ok climb=99.1 fall_regen=+11.5 boss_fear_water=ok` |
| `smoke_sim.gd` | PASS | `SMOKE_OK ticks=600` |
| `--quit-after 900` 实机矿井跑通 | PASS | `M1_WANG_SETTLED ticks=240 ms=990`、`M1_ENEMIES_SPAWNED total=21 boss=yes`、0 报错 |
| `--t4b-boss-shot` 截图人工目检 | PASS | 右上高台石槽蓄水无泄漏、双 `row 8` 竹台与石碑清晰、旱魃干态 `420/420`、右下出口无遮挡 |

## 未解决 / 待决定

- 刷怪翻倍（21 只）与旱魃新数值（16–26 伤 + 75 tick 畏水冷却）的实机通关体感待用户下一轮试玩确认；若水池位置/旱魃畏水频率需微调，可直接改 `room-boss-coalmine.json` 与 `WATER_AVOID_COOLDOWN`。

## 下一步

- 请用户启动桌面实机复测矿井探索密度、土堆行走手感与新旱魃 BOSS 房；确认满意后推进 M1 剩余收口项（M1-07 洞天选路/出入口闭环、M1-11 性能优化与验收）。
