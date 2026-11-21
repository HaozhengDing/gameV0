# 2026-11-21-04 M1-10 反馈层落地（打击感 / 射击爽感六层）：把两条参考视频翻译成 C-EVT 消费层

- **日期**：2026-11-21
- **类型**：更新（新增表现层模块 + 决策：3 条偏离）
- **篇幅**：详细（新增 4 个脚本、动 2 个既有脚本、新增目检模式与 smoke 断言；涉及 3 条偏离）
- **前置**：用户 2026-11-21 提供的两条抖音参考视频；`docs/01-decision-twist.md`（D1 可读优先 / D3 污染只遮蔽未知）；`docs/tech/m1-01-contracts-evt-text.md`（C-EVT v0.1）；`docs/04-m1-plan.md` M1-10

---

## 1. 结论

用户给了两条**讲同一件事的两面**的参考视频，本作把它们的 12 条建议并成 **8 层反馈**，作为 `game/scripts/feedback/` 全部落地（正好是 M1-10 计划里的产物目录），**提前于 W10 排期**：

1. **视频 1《2d游戏射击爽感教学》**（64s，1727 赞）：枪口火光 → 后坐力 → 屏幕震动 → 命中反馈 → 击杀反馈 → 音效分层。
2. **视频 2《如何让你的游戏具有打击感》**（68s）：命中停顿 → 镜头震动 → 屏幕闪白 → 受击反应 → 命中粒子 → 攻击音效。
3. **并成 8 层**：符火 / 后坐 / 定向震屏 / 命中 / 击杀 / 分层音效 + 本作专属的 **反应环**（`reaction_triggered`）与 **熄灯·反噬**（`lantern_extinguished` / `backlash_triggered`）。
4. **纯表现层**：只订阅 C-EVT，不改任何玩法数值、不新增玩法状态，`sim_core` / VM / 战斗层零改动（唯一跨层改动是给 `player.gd` 加了纯视觉的后坐位移，不参与碰撞）。
5. **验证**：`--t4b-smoke` 新增 `M1-10打击感六层` 步骤（含"顿帧生效 + 复位"断言）；`--t4b-fx-shot` 目检截图；两者均通过，exit 0。

规范文档见 [`docs/tech/m1-feedback-juice.md`](../tech/m1-feedback-juice.md)。

---

## 2. 为什么采信这两条视频

| 视频要点 | 与本作的关系 |
|---|---|
| 反馈是"一层层加回来"的，不是一次堆满 | 与本作 `C-EVT` 单向事件总线的分层设计同向：每层只消费自己关心的事件，可单独开关、单独调参 |
| 命中信号要"最直接"，击杀要"更重" | 对应 M1 的战斗节奏：一次 `spell_cast` 抛出 1–3 个投射物，必须让玩家一眼看出打中了没有 |
| 音效占打击感的一半 | 本作目前音效为零；分层音效是**最便宜的一档可读性**（D1 要求"颜色 / 声音 / 文字至少两种通道"） |
| "屏幕闪白"是最直接的命中信号 | **不照抄**：与 D1 可读优先冲突，见 §3 偏离 1 |

---

## 3. 关键设计决策（是什么 / 为什么 / 代价）

| 决策 | 是什么 | 为什么 | 代价 |
|---|---|---|---|
| **偏离 1：全屏闪白降级为「目标闪白 + 边缘红晕」** | `screen_fx` 把全屏补光钳到 α ≤ 0.28、时长 ≤ 0.09 s；受击改为屏幕四边红晕（不铺满） | 全屏白闪会短暂遮蔽地形、火势、敌人位置，等于拿 D1 的核心卖点换冲击力 | 单帧"炸裂感"弱于参考视频；复议条件 = 自测觉得击杀不够爽时把击杀 α 上限提到 0.40、时长 ≤ 0.12 s |
| **偏离 2：顿帧用全局 `Engine.time_scale`** | 命中 30 ms / 击杀 60 ms / 受击 45 ms / 反噬 55 ms，压到 0.06 后用**真实时钟**复位 | 只有冻结整个世界（含 `sim_core` tick）才有"卡住一下"的顿感；只停表现层会变成"画面停了、火还在烧" | 全局时间缩放在多人 / 回放 / 暂停菜单下会出问题；M1 单机单线程，代价暂为零。复位写进 `reset()` / `shutdown()` / `_exit_tree()` 三处 + smoke 断言 |
| **偏离 3：音效运行时合成** | `sfx_bank.gd` 用白噪声 + 正弦扫频 + 指数包络合成 6 条 22.05 kHz PCM（fire / casing / hit / kill / lantern / backlash / fizzle） | M1 是灰盒，美术资源未进排期；先验证"分层"这件事本身（四层声音各司其职），而不是音色 | 音色单薄、无空间感；M2 美术阶段按同一组事件键替换为采样，调用方不改 |
| **反馈导演放在 `_create_feedback()`，订阅 `event_bus`** | `main.gd` 在 `_create_combat()` 之后装配 fx / screen / sfx / director | 与现有 `_on_combat_event` 的 HUD 消费互不干扰；事件单向、可 shutdown 解绑 | `main.gd` 多一个装配函数与 4 个成员变量 |
| **HUD 的 CanvasLayer 从 1 抬到 2** | 反馈层占 layer 1 | 白闪 / 红晕必须压在 HUD 之下，否则血条与灯格被遮 | 若将来还有别的 CanvasLayer 依赖默认 1，需要显式指定层级 |

---

## 4. 文件改动与验证结果

**新增**

- `game/scripts/feedback/fx_layer.gd`：世界空间 FX —— 符火光锥 + 径向光晕（`GradientTexture2D` 平滑衰减，避免同心圆硬边）、命中/击杀火星与冲击环、反应环、伤害飘字（三次错位防重叠）。
- `game/scripts/feedback/screen_fx.gd`：屏幕空间 —— 命中白闪（可读性钳制）+ 受击四边红晕。
- `game/scripts/feedback/sfx_bank.gd`：程序化分层音效（6 条音源 + 10 个播放器轮转）。
- `game/scripts/feedback/feedback_director.gd`：消费 C-EVT 的反馈导演（顿帧 / 定向震屏 / 后坐 / 施法手脚 / 重置）。
- `docs/tech/m1-feedback-juice.md`：规范文档（层 ↔ 事件 ↔ 代码 ↔ 参数表 + 3 条偏离 + 验收）。

**修改**

- `game/scripts/main.gd`：新增 4 个 preload 与成员、`_create_feedback()`、`_do_cast()` 接入施法反馈（威力按投射物数量）、`_restart()` 与 `_quit()` 调 `feedback.reset()` / `shutdown()`、HUD 抬层、新增 `--t4b-fx-shot` 目检模式、smoke 新增 M1-10 步骤。
- `game/scripts/player.gd`：新增纯视觉后坐力 `add_recoil()` + 70 px/s 回弹（`_update_visual` 里叠加到 Body/Eye/Jet，不参与碰撞）。
- `docs/04-m1-plan.md`：M1-10 行标注反馈骨架已提前落地（W10 只剩 8 条反应的专属表现）+ deviations 补一条。
- `game/README.md`：目录说明加 `scripts/feedback/`，运行命令加 `--t4b-fx-shot`。

| 检查项 | 结果 |
|---|---|
| `Godot --headless -- --t4b-smoke` | **通过，exit 0**；新增 `T4B_SMOKE_STEP M1-10打击感六层 fx=ok screen=ok sfx=3 hitstop=ok recoil=ok`，其余 14 步全绿（含 5-seed Wang 连通性） |
| `Godot -- --t4b-fx-shot` | **通过**，生成 `t4b_shot.png`：暖色符火光晕 + 橙色 `37!` 击杀飘字 + 紫色爆散光环 + 边缘红晕同帧可见 |
| `python tools/validate_data.py` | 未改任何 `data/` 文件，数据校验不受影响（本任务不新增数值） |

---

## 5. 已知问题

- **退出时 `ObjectDB instances leaked at exit` 警告**：在非 `--verbose` 的 headless smoke 中稳定出现 1 条，`--verbose` 下不出现，退出码仍为 0。已排查并排除 `event_bus` ↔ `Callable` ↔ director 的环形引用（`_exit_tree` / `_quit` 均已 unsubscribe）。剩余怀疑方向：`AudioStreamPlayer` 持有的 `AudioStreamWAV` 在 teardown 顺序下的资源释放。**不影响运行与退出码**，留 M1-11 冷却期排查。
- 目检模式下 FX 被 `feedback.set_process(false)` 冻结在峰值帧，属于**截图专用**行为（`--t4b-fx-shot` 独占）。

---

## 6. 下一步

1. **W10 的 M1-10 剩余范围**：把 8 条民俗反应各自的专属表现（黑火药爆炸、硫烟、石灰蒸汽、糯米净化、狗血、水银界、朱砂）从"通用反应环"升级为独立音色 + 专属粒子形态；D1 可读性核对表逐条打勾。
2. **参数进 data**：等反馈手感稳定后，把 `HITSTOP_*` / `SHAKE_*` 从脚本常量迁到 `data/magic_numbers.json` 的 `feedback` 段（届时需要 validator 放行 + deviations 记录）。
3. **M2 美术阶段**：`sfx_bank` 按事件键替换为采样；FX 层可整层替换为 GPUParticles2D 资源，调用方不变。
