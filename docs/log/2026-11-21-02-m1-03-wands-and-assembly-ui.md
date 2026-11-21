# 2026-11-21-02 M1-03 落地：符箓三段式真游标、3 把法器数据与洞天安全区极简改符 UI

- **日期**：2026-11-21
- **类型**：更新（数据层 + GDExtension + 核心玩法 + UI）
- **篇幅**：详细（新增 `data/wands.json`、扩展 `TalismanVMNode` 与 `validate_data.py`、落地真游标与 D-M1-4 安全区改符 UI）
- **前置**：`refs/cards/p0/systems.yaml`（S-0002）、`docs/tech/talisman-vm-spec.md`、`docs/04-m1-plan.md`（D-M1-4）

---

## 1. 结论

**M1-03（符箓三段式完整 + 3 把法器 + 洞天安全区改符 UI）已完成并回归通过**：

1. **三把正式法器入库并纳入 CI 校验**：新增 `data/wands.json`（`gamev0.wands/v0.1`），定义 3 把差异化法器与开局散符背包，并在 `tools/validate_data.py` 新增 `validate_wands()` 交叉核对全部 `default_deck` / `starter_bag` 符卡引用：
   - **`桃木剑`（`wand-peachwood`）**：成文 4 位、灵 80 / 回 10/s、每次 1 句（`斩 爆 掘 归` 游标交替推进）；
   - **`铜铃`（`wand-bronze-bell`）**：成文 6 位、灵 110 / 回 16/s、每次 1 句（默认含 `敕·触 斩 → 火 化水` 链式触发）；
   - **`骨简`（`wand-bone-slip`）**：散符乱序 5 位、灵 130 / 回 14/s、每次连念 2 句（每轮起始在调度层确定性洗牌）。
2. **`TalismanVMNode` 补齐真牌堆接口**：新增 `cast_deck(wand, state, rng)` 与 `get_all_cards()`，完整透传 T3 纯函数 `vm::cast()`（真游标推进、回符、多句、触发静态展开、禁符反噬、幻影符、朱砂临时位），并重建 Windows Debug/Release DLL；保留 `cast_group()` 向后兼容。
3. **极简组装 UI 与 D-M1-4 安全区改符锁**：新增 `game/scripts/wand_manager.gd` 与 `game/scripts/wand_ui.gd`（按 `B` 开关，符头青/符胆金/符脚朱红分色，无合体名）；在安全区内允许左键换位/装配、右键卸回背包，进入矿井后自动锁定只读并提示 `$ui_edit_safe_only`。

---

## 2. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **散符洗牌留在 `wand_manager.gd` 调度层** | `ordered=false` 法器在 `cursor == 0` 轮首做确定性 Fisher-Yates 洗牌后传给 `vm.cast_deck()` | 严守 `talisman-vm-spec.md` §1.2 第 6 条「VM 只记录 `ordered`，洗牌在调度层」，保证 T3 VM 保持 100% 纯函数确定性 | UI 展示固定槽位（`w.deck`），实际出牌顺序为当轮 `draw_deck` |
| **开局起点区暂兼安全区** | 玩家在起点安全走廊（`x < 40`）时 `in_safe_zone=true`，踏入矿井即锁只读；待 M1-04/M1-07 接入洞天后切换为洞天坐标判定 | 让制作人此刻无需等洞天地图即可实机体验并验证 D-M1-4 安全区改符闭环 | 矿井起点前段暂借作临时改符区（M1-04 切换至 Wang Tile 入口安全区） |

---

## 3. 文件改动与验证结果

- 新增 `data/wands.json`：3 把法器与 `starter_bag` 数据。
- 更新 `data/texts/zh-CN.json`：新增 6 条法器/改符 UI 键（共 77 条，均 `corruptible: false`）。
- 更新 `tools/validate_data.py`：新增 `validate_wands()` 校验。
- 更新 `game/gdextension/src/vm_node.{h,cpp}`、`game/gdextension/API.md`：暴露 `cast_deck` 与 `get_all_cards` 并完成增量构建。
- 新增 `game/scripts/wand_manager.gd`、`game/scripts/wand_ui.gd`；更新 `game/scripts/{executor,hud,main}.gd`：接入 3 法器切换、真游标施法、安全区改符 UI 与 `--t4b-smoke` Step 12。
- 更新 `docs/04-m1-plan.md`：标注 M1-03 已完成。

| 检查项 | 结果 |
|---|---|
| `python tools/validate_data.py` | **通过**（含 `wands: 3 把法器`、`texts: 77 条`） |
| `game/build.bat`（GDExtension Debug+Release） | **通过**（`T4A_BUILD_OK`） |
| `Godot --headless -- --t4b-smoke` | **通过**（Step 12 `wands=3 cursor=0->2->0 trigger_depth=1 safe_edit=ok`，0 error） |
| `Godot --headless --quit-after 900` | **通过**（900 帧 0 错误） |
| `Godot -- --t4b-shot` | **通过**（顶部 3 法器极简槽位与左侧双轴资源卡目检整齐） |

---

## 4. 下一步

- 立即开工 **M1-04（矿井一层完整 Wang Tile 程序化拓扑 + 手工房间拼接 + 连通性校验 + 碑文规矩与三大 hazard）**（D-M1-2 已定）。
