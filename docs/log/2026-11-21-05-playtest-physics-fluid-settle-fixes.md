# 2026-11-21-05 实机试玩反馈修复：开局预沉降防掩埋、液体双向找平与火/毒气阻塞解除

- 日期：2026-11-21
- 作者：Antigravity（协同制作人实机试玩反馈）
- 类型：更新 + 评审
- 篇幅：详细
- 触发：制作人实机试玩 M1-04 矿井一层与 M1-10 反馈层后提出 4 条体验反馈（敌人未攻移 / 区域现加载掩埋与液体像固体 / 人物机动性偏高待定 / 火焰毒气无法移动）

## 结论

1. **反馈 #2（现加载埋人 + 液体像固体）与 #4（火焰/毒气卡死移动）已全部定位根因并落地修复**，C++ 引擎、`gdsim` GDExtension、Godot 脚本与 `docs/tech/m1-feedback-juice.md` 同步更新，全套单测 / 压测 / 冒烟 / 截屏目检通过。
2. **反馈 #1（敌人攻击与移动）**：正对应下一步里程碑 **M1-06（敌人 AI 与旱魃 BOSS 战）**，所有前置阻塞项已清完，待确认即可开工。
3. **反馈 #3（人物机动性偏高）**：按制作人意见保留**待定**，等 M1-06 敌人追击、近战与弹幕实装后再结合真实战斗压力统一调参（避免在无对抗环境下过早削弱手感）。

---

## 4 条试玩反馈处理对照

| # | 制作人反馈 | 根因定位 | 本次处理 | 状态 |
|---|---|---|---|---|
| 1 | 敌人不会攻击和移动，当前阶段是否需要设计？ | M1-04 阶段仅放置了静态标靶与锚点 | 归入下一里程碑 **M1-06（3 小怪 + 画皮精英 + 旱魃 BOSS）** | 待确认开工 |
| 2a | 每到区域现加载，敌人被埋在落下的东西下面 | 矿井悬空池/粉末在 `ACTIVE_MARGIN` 外休眠，走近才下落并覆盖 `spawn_anchors` | 光栅化后一次性全图预沉降 `settle_world(120 ticks)` + `find_safe_stand_pos` 贴地校准 + `ACTIVE_MARGIN 64→128`（2 chunk 预唤醒缓冲） | **已修复** |
| 2b | 液体流动性差，有时像固体 | ① `process_liquid` 用了与 tick 无关的 `cell_random`，遇障永远向同侧死锁；② 无 `-dir` 反向回退；③ 缺自底向上 chunk 排序致跨 chunk 水平斑马纹；④ `spread` 偏小（水银仅 1） | 改 `tick_random` + 双向探索回退 + 允许横向置换轻液/气体 + chunk 自底向上排序 + 提高 `spread`（水/黑狗血 3→6、油 3→4、水银 1→4） | **已修复** |
| 3 | 人物太灵活、机动性很高，可能降低难度，待定 | 当前无主动追击与弹幕压力，尚无法准确标定难度曲线 | 保留当前物理参数，纳入 M1-06 / M1-α 实战调参项 | **待定** |
| 4 | 火焰 / 毒气阻力太大，人物进去无法移动 | 双重叠加：① `player.gd` 遗留 T4b 硬常量 `FIRE_BLOCKS_MOVEMENT := true` 把每格火焰当实墙；② M1-10 `feedback_director._player_hurt` 对每 0.5s 环境 DoT 触发 45ms 全局 `Engine.time_scale = 0.06` 顿帧 | ① 改为实例开关 `fire_blocks_movement`，M1 矿井关闭（仅经典 T4b 火墙冒烟保留）；② 环境 DoT（`火伤`/`灼烧`/`毒烟`/`蒸汽`）豁免全局顿帧，仅保留轻边缘红晕与微震 | **已修复** |

---

## 改动清单

| 文件 | 改动 |
|---|---|
| `sim_core/src/materials.cpp` | 提高液体 `spread`：`water`/`black_dog_blood` `3→6`、`oil` `3→4`、`quicksilver` `1→4` |
| `sim_core/src/world.cpp` | `process_liquid` 改用 `tick_random`、补 `-dir` 反向回退与横向轻液/气体置换；`step()` 增加 `awake_cur` 降序（自底向上）排序消除跨 chunk 断层条纹 |
| `sim_core/tests/test_main.cpp` | 新增 `6g` 液体自由找平回归测试（10×10 水柱与水银柱 120 tick 内均摊平 `min_y >= 52`、高度差 ≤ 4） |
| `game/bin/gdsim.windows.template_{debug,release}.x86_64.dll` | 重新编译更新 GDExtension 动态库（`T4A_BUILD_OK`） |
| `game/scripts/wang_gen.gd` | 新增 `settle_world(sim, 120)` 全图开局预沉降与 `find_safe_stand_pos()` 防掩埋贴地校准 |
| `game/scripts/player.gd` | `const FIRE_BLOCKS_MOVEMENT` 改为实例变量 `var fire_blocks_movement := false` |
| `game/scripts/feedback/feedback_director.gd` | `_player_hurt(amount, source_id)` 对环境持续伤（`火伤`/`灼烧`/`burning`/`毒烟`/`toxic_smoke`/`蒸汽`/`steam`）豁免全局顿帧，仅触发 0.16 α 边缘红晕与轻量微震 |
| `game/scripts/main.gd` | `ACTIVE_MARGIN` `64→128`；`_start_round` / `_spawn_wang_targets` 接入预沉降与安全站位校准；M1 模式关闭 `fire_blocks_movement`；`--t4b-smoke` 增补 `settle_ms`、`buried=0`、`gas_pass=ok` 与 `毒烟`/`火伤` 不顿帧断言 |
| `docs/tech/m1-feedback-juice.md` | §4 偏离 2 补记环境 DoT 豁免全局顿帧的正式规则 |

---

## 决策记录（是什么 / 为什么 / 代价）

1. **开局 120 tick 全图预沉降 + 128 cell 视口唤醒缓冲**
   - **是什么**：矿井光栅化后立刻全图跑 120 tick 让悬空液体/粉末自然落底休眠，再用 `find_safe_stand_pos` 放置玩家、石碑与敌人；运行时 `ACTIVE_MARGIN` 从 64（1 chunk）扩至 128（2 chunks）。
   - **为什么**：彻底消除「走近才现加载把敌人活埋」的观感割裂，同时避免把整张 `1536×672` 永久保持唤醒拖垮帧率。
   - **代价**：开局增加约 0.66–0.71s 一次性加载耗时（可接受；若后续扩图可按需降到 90 tick 或放入切层过场）。
2. **环境持续伤（DoT）豁免全局 `Engine.time_scale` 顿帧**
   - **是什么**：仅敌方单次命中、塌方重击、反噬、熄灯触发全局顿帧；火/灼烧/毒烟/蒸汽周期性 DoT 只播边缘红晕与轻量微震。
   - **为什么**：在元素沙盒里玩家频繁穿越烟火，每 0.5s 冻结世界 45ms 会直接破坏位移手感。
   - **代价**：火/毒持续伤的「卡顿存在感」略弱，靠红晕、HUD 灼烧/中毒状态与持续扣血条补足。

---

## 验证记录

| 检查项 | 命令 / 场景 | 结果 |
|---|---|---|
| C++ 单元回归 | `ctest --test-dir sim_core/build --output-on-failure` | **8/8 PASSED**（含新增 `6g` 液体自由找平） |
| GDExtension 构建 | `game/build.bat` | **T4A_BUILD_OK**（Debug & Release DLL 更新） |
| C-SIM 性能压测（3000 tick） | `sim_bench.exe --ticks 3000 --no-frames` | `worst-wake` p95 **3.212 ms**（≤6ms）、`typical-sleep` p95 **0.822 ms**（≤2ms）、`burn-worst` p95 **1.925 ms**（≤6ms）、`typical-pan` p95 **0.703 ms**（全部达标） |
| 全量冒烟回归 | `godot --headless --path game -- --t4b-smoke` | **T4B_SMOKE_OK**（`rast_ms=90 settle_ms=661 buried=0 gas_pass=ok`，DoT 不顿帧断言全过） |
| M1 主循环空跑 | `godot --headless --path game --quit-after 900` | 退出码 0，0 脚本报错（`M1_WANG_SETTLED ticks=120 ms=670`） |
| 基础 sim 冒烟 | `godot --headless --path game --script res://tests/smoke_sim.gd` | **SMOKE_OK** |
| 截屏目检 | `godot --path game -- --t4b-shot` | 起始水池完全平顺无条纹，右侧煤/硫自然坡度沉降，玩家与碑文贴地站稳 |
| 数据校验 | `python tools/validate_data.py` | **OK** |

---

## 下一步

- 请制作人重跑本地实机验证流体、预沉降与穿火手感；
- 若方向确认，立即开工 **M1-06（矿井一层敌人 AI + 旱魃 BOSS 战）**，并同步用实战压力评估人物机动性参数（反馈 #3）。
