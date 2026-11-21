# 2026-11-21-11 M1-06 落地（矿井一层敌人 AI 与旱魃 BOSS 战）+ 跳跃跟手 P0

- 日期：2026-11-21
- 作者：Antigravity
- 类型：更新 + 决策
- 篇幅：详细
- 触发：制作人选定方案 A——开工 M1-06（3 小怪 + 画皮精英 + 旱魃 BOSS）并顺带落地 `m1-jump-feel` P0，推进至 M1-α 检查点

## 结论

1. **M1-06 全部落地，正式抵达 M1-α 检查点**：新增 `data/entities/layer01.json`（含 `validate_data.py` 强引用校验）、`game/scripts/enemies/{enemy_ai,enemy_manager}.gd`、敌方投射物与近战伤玩家链路（含无敌帧/击退/阴弹熄灯）、旱魃两阶段战与顶中 BOSS 血条，以及 `--t4b-smoke` 第 15 步全量自动化回归。
2. **`m1-jump-feel` P0 落地**：`player.gd` 补齐事件驱动跳跃缓冲 `0.10 s`、土狼时间 `0.08 → 0.10 s` 与 `0.10 s` 窗口内松手切断上升（`×0.35`，不增机动上限、不砍浮空惯性），通过第 16 步自动化断言（短按峰高 `6.6` 格 < 满按 `31.0` 格）。
3. **顺手抓出并修补两处高价值隐蔽缺陷**：① `event_bus.gd` 原先未转发 `source_id`/`target_id`/`damage_type`，导致实机 M1-10 反馈导演与击杀掉落拿不到目标/来源；② `room-boss-coalmine.json` 左下水池缺坝壁，流体修好后水会自动蔓延全室淹伤旱魃，现补筑 2 格岩坝（可葫芦取水 `E→Q`，也可挖/炸坝泄洪破甲）。

---

## M1-06 敌人与旱魃 BOSS 实现清单

| 敌人 | 定位 / HP | 标签 & 弱点/抗性 | AI 与攻击 | 环境互动与掉落 |
|---|---|---|---|---|
| **矿鬼** (`enemy-coal-ghost`) | 小怪 / 22 | `spirit`；弱阳 `2×`、火 `1.2×` | 地面巡逻（遇墙/崖折返）→ 追击 + 0.30s 预警挥爪（6 物理伤） | 黑狗血触发 `r-dog-blood-spirit` 阳伤秒杀；掉 15 银 + 煤粉 |
| **土蝼** (`enemy-earth-worm`) | 小怪 / 28 | `beast`；弱金 `1.3×`、火 `1.2×` | 地面巡逻 → 0.37s 预警短距扑咬冲锋（7 物理伤） | 踩水银移速减半；掉 10 银 |
| **硫烟鬼火** (`enemy-gas-wisp`) | 小怪 / 12 | `fire`、`hazard`、`spirit`；弱水 `2.5×`、抗火 `0.2×` | 空中漂浮保持中距 → 0.37s 预警射火弹（4 火伤 + `ignite`） | 火弹可引燃煤/硫/瓦斯囊；沾水嘶鸣吃水伤；掉 10 银 + 硫磺 |
| **画皮** (`enemy-painted-skin`) | 精英 / 100 | `eldritch`、`elite`；弱金/雷/阳 `1.5×` | 地面中距游走 → 0.43s 预警发阴气弹（8 阴伤 + **直接熄灯 `0.35` 盏**） | **严格受水银阻挡（`r-quicksilver-ward`）**；优先刷在水银池房；掉 80 银 + 朱砂 |
| **旱魃** (`enemy-drought-demon`) | 一层 BOSS / 420 | `boss`、`fire`、`drought`；**抗火 `0.25×`、弱水 `2×`、弱阴 `2×`** | P1：3 连扇形火弹 / 炽地猛扑；P2（≤50% HP）：5 连扇形火弹 / 猛扑 / 贴地焦土灼浪（左右滚火波） | **泼水/泄洪入水 → 产蒸汽 + 水灼 + `湿破甲`（非火伤额外 `1.4×`）**；触阴气受阴蚀；掉 150 银 + 朱砂 + `body-bifang-huo`（火）符 |

---

## 改动清单

| 文件 | 改动 |
|---|---|
| `data/entities/layer01.json` | 新增矿井一层 5 种敌人正式配置（含 `v1_deviations`） |
| `data/rooms/room-boss-coalmine.json` | 左下水池补 2 格岩坝 `#`（防止预沉降漫全室自伤旱魃，形成取水/掘坝双解法）；碑文移至 `x=6, y=4` 贴稳竹木平台 |
| `tools/validate_data.py` | 新增 `validate_entities()`，强校验实体配置与 `materials` / `talismans` / `texts` / `biomes` 交叉引用 |
| `game/scripts/event_bus.gd` | `publish()` 同时映射规范键（`actor`/`target`/`aux`）与调用方键（`source_id`/`target_id`/`damage_type`/`status`），修复实机反馈与击杀掉落订阅断链 |
| `game/scripts/player.gd` | 落地 `m1-jump-feel` P0（`COYOTE_TIME 0.10`、`_unhandled_input` 事件驱动 `JUMP_BUFFER 0.10`、`JUMP_CUT_WINDOW 0.10 / JUMP_CUT 0.35`）+ 敌击 24 tick 无敌帧与击退 |
| `game/scripts/combat/projectile.gd` | 增补 `lantern_damage` 字段支持敌方阴气弹直接熄灯 |
| `game/scripts/combat/combat_entity.gd` | 补齐击退/朝向/预警圈/阶段字段、旱魃与鬼火沾水嘶鸣产蒸汽、`wet` 破甲 `1.4×`、旱魃触阴气阴蚀 |
| `game/scripts/combat/combat_manager.gd` | 敌方投射物/范围伤命中玩家回调、玩家击中敌人击退、扩大 `ignite` 热冲击半径至 5、升级灰盒剪影与攻击前摇预警圈绘制 |
| `game/scripts/enemies/enemy_ai.gd` | 新增 5 种敌人状态机、像素地形迈步/悬崖折返、`r-quicksilver-ward` 硬阻挡、旱魃两阶段三招式 |
| `game/scripts/enemies/enemy_manager.gd` | 新增配置加载、Wang 锚点刷怪（保底 1 画皮 + 1 鬼火 + 1 旱魃）、视距活跃驱动、银两/物质/符卡掉落与 BOSS HUD 快照 |
| `game/scripts/hud.gd` | 顶中增设旱魃 BOSS 血条（含 `旱威` / `湿破甲` 状态指示，不遮挡矿底地面） |
| `game/scripts/main.gd` | 接入 `EnemyManager`、统一 `_on_player_hit_by_enemy`、银两与 BOSS HUD 刷新、`--t4b-boss-shot` 截屏、新增 `--t4b-smoke` 第 15 步（M1-06）与第 16 步（`m1-jump-feel` P0） |
| `docs/04-m1-plan.md`、`docs/tech/m1-jump-feel.md` | 同步 M1-06 完工（抵达 M1-α）与跳跃跟手 P0 落地状态 |

---

## 验证记录

| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **OK**（`entities: 5 种敌人` 与 biome/texts/materials/talismans 全引用通过） |
| `--t4b-smoke`（16 步全量回归） | **T4B_SMOKE_OK**（`M1-06敌人与旱魃 defs=5 ghost=ok ward_lantern=ok wisp_ignite=ok boss_wet=28.0 p2=ok drop=150`；`m1-jump-feel_P0 coyote=ok buffer=ok var_jump=6.6<31.0`） |
| `--quit-after 900`（Wang 矿井 15s 空跑） | 退出码 0，0 脚本报错（`M1_WANG_SETTLED ticks=120 ms=617`） |
| `smoke_sim.gd` | **SMOKE_OK** |
| `--t4b-boss-shot` 视觉目检 | 岩坝稳蓄水池、旱魃满血 `420/420` 伴前摇预警圈、顶中 BOSS 血条无遮挡、竹台碑文贴地、右上阴气清晰可见 |

---

## 下一步（M1-α 检查点）

- 请制作人实机试玩 M1-06 矿井战斗与旱魃 BOSS 战，同时标定：
  1. 人物机动性是否仍偏高（2026-11-21-05 反馈 #3），以及跳跃跟手 P0 手感；
  2. 打击感是否需要开 [combat-hit-feedback.md](../../refs/cards/decisions/combat-hit-feedback.md) 的任一 A/B；
- M1-α 自测通过后，进入 **M1-07（洞天三选一 + 商店线性经济）** 或 **M1-08（神智与可逆入魔）**。
