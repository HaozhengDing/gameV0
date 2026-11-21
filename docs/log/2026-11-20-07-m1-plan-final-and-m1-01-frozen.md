# 2026-11-20-07 M1 计划 5 项拍板定稿 & M1-01 契约（C-EVT / C-TEXT v0.1）冻结落地

- 日期：2026-11-20
- 作者：Antigravity
- 类型：决策 + 更新
- 篇幅：详细
- 触发：用户对 M1 计划 §5 全部 5 项决策拍板（D-M1-1 精简 4 条 / D-M1-2 完整 Wang Tile / D-M1-3 燃烧占位数值 / D-M1-4 洞天安全区改符 / D-M1-5 制作人自测+自动化冒烟）

## 结论

1. **M1 开发计划正式生效**（`docs/04-m1-plan.md`）：同步用户全部 5 项拍板——因 D-M1-2 选定「M1 直接做完整 Wang Tile + 手工房间拼接」，M1 占位周期调整为 **11 周**（10 周开发 + 1 周冷却）；退出门按 D-M1-5 定为制作人自测 + 自动化冒烟（外部试玩移至 M2 Demo）。
2. **M1-01 契约冻结并工程落地（W1 完成）**：
   - 冻结 `docs/tech/m1-01-contracts-evt-text.md`（C-EVT v0.1 + C-TEXT v0.1）；
   - 新增正式词表 `data/texts/zh-CN.json`（71 条：覆盖全部材质、18 张符卡、8 条反应、4 状态、5 敌人、4 房间、2 条规矩与腐坏变体、UI/死因短词）；
   - 扩展 `tools/validate_data.py` 新增 `validate_texts()` 与 `fire_heat`/`burn_time`/`burn_product` 校验，**机器强制守护 D3 红线**（已知域 `corruptible` 必须为 `false`，经变异测试故意改坏 `$mat_water` 实测退出码 1）；
   - 落地 `game/scripts/event_bus.gd`（C-EVT 纯数据总线）与 `game/scripts/text_db.gd`（C-TEXT 读取 + D3 腐坏判定 + 拼句），接入 `--t4b-smoke` 第 8 步自动回归。
3. **数值与开关落入正式数据层**：`data/magic_numbers.json` 写入 D-M1-1（`lose_control_enabled=false`, `yan_jin_enabled=false`）与 D-M1-3（`fire_heat` 块）；`data/materials.json` 为煤/硫磺/竹木写入占位 `burn_time` / `burn_product` 并全部登记 `v1_deviations`。

## 改动

| 文件 | 改了什么 |
|---|---|
| `docs/04-m1-plan.md` | 状态升级为「生效（2026-11-20 已拍板）」；落实 D-M1-1~5（含完整 Wang Tile 11 周排期与制作人自测退出门）及 deviations |
| `docs/03-roadmap.md` | 同步 M0 conditional 放行、M1 11 周与退出门、C-EVT / C-TEXT v0.1 已冻结状态 |
| `docs/tech/m1-01-contracts-evt-text.md` | 状态升级为「v0.1 已冻结」，指向落地实现文件 |
| `data/texts/zh-CN.json` | 新增：C-TEXT v0.1 正式中文词表（71 条，遵循 `refs/naming.md` §5 极简命名与 D3 `corruptible` 边界） |
| `data/magic_numbers.json` | `sanity.possession` 增 `lose_control_enabled: false` / `yan_jin_enabled: false`（D-M1-1）；新增 `fire_heat` 占位块（D-M1-3）；登记 `v1_deviations` |
| `data/materials.json` | 为 `coal`/`sulfur`/`bamboo` 补占位 `burn_time`（180/90/120 tick）与 `burn_product`（`smoke`/`toxic_smoke`/`coal`）（D-M1-3）；登记 `v1_deviations` |
| `data/README.md` | 新增 §4c `texts/*.json`（C-TEXT v0.1）规范与 `burn_time`/`burn_product` 说明 |
| `tools/validate_data.py` | 新增 `validate_texts()`（格式、D3 `corruptible` 强制机检、`corrupted` 非空、与材质/反应/符卡交叉核对）、`burn_time`/`burn_product` 与 `fire_heat` 校验 |
| `game/scripts/event_bus.gd` | 新增：C-EVT v0.1 纯数据事件总线（22 种受控事件、单调 seq、订阅/历史统计） |
| `game/scripts/text_db.gd` | 新增：C-TEXT v0.1 词表读取器（`get_text(key, sanity)` 执行 D3 腐坏门控、`compose_cards()` 无合体名拼句） |
| `game/scripts/main.gd` | 装配 `event_bus`/`text_db`，`--t4b-smoke` 新增第 8 步 M1-01 契约回归断言 |
| `docs/log/README.md` | 索引顶部新增本条目 |

## 决定与理由

| 决定 | 为什么 | 代价 |
|---|---|---|
| M1-04 采用完整 Wang Tile + 手工房间拼接（D-M1-2） | 用户拍板直接做齐正式地形骨架，避免 M1 临时拼室代码到 M2 推倒重来 | M1-04 工期增至 2.5–3 周、总周期 11 周，需增加自动化连通性检查防止程序化堵路 |
| M1 退出门定为制作人自测 + 自动化冒烟（D-M1-5） | 符合个人制作人当前时间约束，减少找外人协调阻塞；外部盲测集中到 M2 垂直切片 Demo | 缺乏陌生玩家在 M1 期的早期盲测纠偏，需靠 M1-α 自测严格把关 |
| M1-01 一次性落齐词表 + 校验器 + 运行时骨架 | 让紧随其后的 M1-12（C-SIM v3）与 M1-02（战斗/投射物）直接消费真实 `EventBus`/`TextDB` 与 `data/materials.json` 燃烧字段，避免返工 | 新增 3 个文件并扩大 CI 校验面（已通过正反向测试验证） |

## 验证记录（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| 数据与 C-TEXT 校验 | `python tools/validate_data.py` | `OK: 数据与卡片校验通过`（29 卡 / 18 符卡 4 组 / **71 条 texts** / 30 VM 用例 / 12 材质 8 反应 2 房间），exit 0 |
| D3 红线变异测试 | 临时副本改 `$mat_water.corruptible=true` 后跑 `validate_data.py` | **如期变红**（`FAIL: 1 个错误 - $mat_water 违反 D3 红线`，exit 1） |
| T4b + M1-01 冒烟 | `Godot_v4.5-stable_win64_console.exe --headless --path game -- --t4b-smoke` | `T4B_SMOKE_STEP M1-01契约 texts=71 evt_seq=1`；`T4B_SMOKE_OK ...`，exit 0 |
| 长时运行回归 | `Godot_v4.5-stable_win64_console.exe --headless --path game --quit-after 900` | `T4B_WORLD_READY ...`，0 SCRIPT ERROR，exit 0 |

## 新增或修改的 deviations

- `docs/04-m1-plan.md` §6：M0 conditional 放行、D-M1-5 制作人自测退出门、D-M1-1 入魔精简 4 条；
- `data/magic_numbers.json` `v1_deviations`：D-M1-1（`lose_control_enabled=false`, `yan_jin_enabled=false`）与 D-M1-3（`fire_heat` 占位）；
- `data/materials.json` `v1_deviations`：D-M1-3（煤/硫磺/竹木 `burn_time` 与 `burn_product` 占位）。

## 未解决 / 待决定

无阻塞拍板项——M1-01 已冻结完成，可直接开工下一批任务。

## 下一步

- 立即并行/先后推进 M1 首批生产任务：
  1. **M1-12（反应表 + 热/火，C-SIM v3）**：升级 `sim_core/` 支持热源 + 邻域阈值 + 8 条反应 + `smoke`/`toxic_smoke`/`steam` + `sim_bench` 全屏燃烧压测 + 更新 GDExtension；
  2. **M1-02（投射物与战斗框架）**：把 T4b 即时命中升级为真实投射物实体（飞行/穿透/碰撞/触发 `on_hit`·`on_expire`）+ 伤害类型 + `weak_to`。
