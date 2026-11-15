# sim_core/vm —— T3 参考符箓 VM（契约 C-VM / C-ACT）

实现 `docs/tech/talisman-vm-spec.md` 的参考符箓 VM，并在 ctest 中跑通 T1 冻结的
30 条用例（`tests/vm_cases/`，VM-001 ~ VM-030）**外加 5 条 C++ 边界测试**。
**30/30 才算实验 B 通过**（spec §7.5）。

- 唯一入口：纯函数 `vm::CastResult vm::cast(const vm::CastRequest&, const vm::CardCatalog&)`。
  不碰世界、不碰引擎、无全局状态、无随机源（RNG 由 `CastRequest.rng` 注入，§4.1）。
- 覆盖：16 种 C-ACT 动作的规范化比较、C-VM 输入输出、§4.3 事件码、§2.4 三个上限、
  §2.7 八步状态机与 I1–I6 不变量、§6.2/§6.3 用例 schema 与比较规则、
  §7.4.1 六条边界口径、§2.7 第 4 步补写（替换句带触发符头）。
- 约束：不修改 `docs/tech/talisman-vm-spec.md`、`tests/vm_cases/`（契约与期望结果）；
  不修改 `sim_core/src`、`include`、`bench`、`tests`（T2 的范围）。本目录可独立删除：
  `sim_core/CMakeLists.txt` 的 `add_subdirectory(vm)` hook 在目录不存在时静默跳过。

## 模块结构

```text
sim_core/vm/
  CMakeLists.txt              # sim_vm 静态库 + vm_cases_runner + vm_edge_cases + 2 条 add_test
  README.md                   # 本文件
  include/vm/talisman_vm.h    # C-VM/C-ACT 数据结构：Value/Card/CardCatalog/CastRequest/CastResult
  src/cast.cpp                # cast() 实现：牌堆 → 解析(阶段 A) → 执行(阶段 B) → 收尾
  harness/
    run_cases.py              # pyyaml：tests/vm_cases/*.yaml → JSON（构建目录临时产物），再驱动 runner
    json_util.h/.cpp          # JSON → VM 类型（读 cards.yaml + 每条用例的 initial/input）
    compare.h/.cpp            # §6.3 比较：动作规范化+深度相等、不变量表达式、I1–I6
    runner_main.cpp           # 逐条跑 30 条契约用例，PASS/FAIL + 失败差异详情
    edge_cases_main.cpp       # 5 条 C++ 边界测试（§2.4 / §2.7 / §7.4.1 复审修复口径）
```

依赖方向：`vm_cases_runner -> sim_vm + sim_core`（只借用仓库内 `sim_core/src/json_lite.h`
读 JSON），VM 核心库 `sim_vm` 只依赖 C++17 标准库；不引入任何第三方 C++ 库。
`src/json_lite.h` 只读复用，未做任何修改。

## 构建与运行

```bash
# 干净构建（在 sim_core 下，5 条旧测试 + vm_edge_cases + vm_cases 自动并入）
cd /tmp/gameV0/sim_core
cmake -S . -B build-vm -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-vm

# 全部 ctest：期望 7/7（5 旧 + vm_edge_cases + vm_cases），vm_cases 内部 30/30
cd build-vm && ctest --output-on-failure

# 只看契约用例 / 边界测试，并看逐条 PASS 行
ctest -V -R vm_cases
ctest -V -R vm_edge_cases

# 手工调试：保留转换出的 JSON（构建目录内，不提交），runner 会打印差异路径
python3 ../vm/harness/run_cases.py --runner ./vm/vm_cases_runner \
    --repo-root /tmp/gameV0 --work-dir ./vm
```

- `vm_cases`：Python 驱动（pyyaml 转 JSON）→ C++ runner（json_lite 解析）。30 条中任一条
  失败、或用例数不是 30，测试都返回非 0；runner 输出每条的差异（动作路径、事件码序列、
  状态字段、不变量等）。
- `vm_edge_cases`：纯 C++ 单测，不依赖 JSON/YAML；只构造边界输入并断言 spec 语义，
  与 30 条契约用例分开（契约用例文件不改）。

## 与 spec 的对应关系

| 规格章节 | 实现位置 | 说明 |
|---|---|---|
| §1.2 牌堆/游标 | `src/cast.cpp` `build_deck()` / `Parser` | 剔除 null 与幻影符位；游标逐句推进、句间共享、不回绕 |
| §1.3 符脚归属/多符胆 | `Parser::parse_sentence()` | 符脚只吃连续的；`sentence_end` 的 归 挂顶层 |
| §2.1 两阶段 | `Parser`（阶段 A）+ 主循环/expand（阶段 B） | 解析只读、不扣灵力不改状态 |
| §2.2 cast 主流程 | `cast()` | 八步顺序与伪代码一致（见下） |
| §2.3 触发静态展开 | `Parser` 触发递归 + `expand_sentence()` | 每句只认第一个触发符头；深度 3；子句单独判费 |
| §2.4 预算/计数 | `expand_sentence()` + `action_exec_count()` 等 | per/affordable 钳制算法；count 展开计数；钳到 0 停止展开 |
| §2.5 灵力 | 主循环句首判费 + `apply_sentence_end_effects()` | 句原子扣费；归 句末 refund；fizzle 收尾 |
| §2.6 无效句 | `Parser::parse_sentence()` / 主循环 | 扣费、无动作、游标推进、继续下一句 |
| §2.7 八步状态机 | `cast()` 顺序注释「步骤 0..8」 | 步骤 1 清理事件先于步骤 2 反噬；反噬/替换/禁符/回符/幻影符放置 |
| §2.7 第 4 步补写 | 主循环 `substitute_index` 分支 | 替换句带触发符头：Option B（游标停子句首，见下） |
| §3 C-ACT 16 动作 | `include/vm/talisman_vm.h` + `compare.cpp` 默认值表 | 输出动作按 §3.2 字段/默认值；比较前补齐 |
| §4 C-VM 输入输出 | `CastRequest` / `CastResult` | 字段与 §4.1/§4.2 一一对应 |
| §4.3 事件码 | `push_event()` 16 个 code | 附加字段按表；用例只比较 code 顺序（§4.2） |
| §6.2/§6.3 用例比较 | `harness/compare.cpp` + `runner_main.cpp` | 动作深度相等（忽略 from）、事件有序全等、consumed、状态、summary、不变量 |
| §7.3 #6 替换+触发 | 主循环 `substitute_index` 分支 | 备选 A（保留触发）未采用，未改 C-ACT |
| §7.4.1 六条边界口径 | `cast()` / `expand_sentence()` / `apply_forbidden()` | 见「边界测试」与「补写口径」两节 |
| §7.5 实现清单 | 本目录 | 纯函数；不做投射物飞行/命中/世界执行/入魔/洗牌/回灵 tick |

### 30/30 用例与实现要点的对应（摘）

| 用例 | 验证的实现点 |
|---|---|
| VM-001~VM-004 | 单句/多符脚/符脚遇符头停止；游标停在下一句首不回符 |
| VM-005~VM-008 | 多符胆状态不跨句；天罡 ×1.2、分身 ×2 可叠加；cursor 起点；散符只影响顺序 |
| VM-009/VM-014/VM-023 | 幻影符位剔除牌堆；回符中拒绝不消费反噬（I3）；≥33 先清幻影符 |
| VM-010/VM-011 | 句原子判费：不足整句不念、游标不动、不回符；恰好够仍念 |
| VM-012/VM-013 | 无效句（有符脚没符胆 / 悬挂符头）扣费无动作、继续、回符 |
| VM-015 | 归 `timing: sentence_end`：顶层动作 + 句末立即 refund（clamp ≤ spirit_max） |
| VM-016~VM-019 | 禁符 −20 神智并置反噬；反噬整次幻符 + clamp 成本；反噬中禁符不生效（I1/I4） |
| VM-020~VM-022 | 15% 替换（条件、符脚 payload、I5）；含禁符不掷骰；收尾放幻影符 |
| VM-024~VM-027 | 触发静态展开、on_hit/on_expire、empty_trigger、深度 3 截断且第 4 层不读牌不扣费 |
| VM-028~VM-030 | 动作 64 = count 展开计数、边界不截断、超出钳 count、投射物 32 钳制 |

## 边界测试（`vm_edge_cases`，T3 复审修复）

独立 ctest 项，5 条纯 C++ 单测（`harness/edge_cases_main.cpp`），输出逐条标注 spec 章节：

| 测试 | 覆盖的 spec 口径 | 断言要点 |
|---|---|---|
| E1 | §2.7 步骤 1→2 | `sanity ≥ 33` 且反噬时，`phantom_slot_cleared` 先于 `backlash_consumed` 入事件流（不再丢失） |
| E2 | §2.4 exec 计数 | 触发子句执行次数只通过父 spawn 的 `per = 1+Σpayload+Σtrigger` 计一次；`per=7` 时 count=9、action_count=63（非 8/56） |
| E3 | §2.4 钳到 0 | count 被钳到 0 → 停止剩余展开：后续主句不读牌、不扣灵力；只产生一条 `budget_exhausted_action` |
| E4 | §2.4 + §7.4.1 ④ | `refund_spirit` 计入「已用执行次数」预算：已用 2 时剩余 62，count=floor(62/3)=20（非 21） |
| E5 | §2.7 第 4 步补写 + §7.3 #6 | 替换句带触发符头：子句不展开/不扣灵力/不计 consumed，游标停在子句首（own_end），未读尽不回符 |

## 实现选择与出处

以下选择都能在规格原文找到依据（逐条引用）。用例期望本身也是契约的一部分。

1. **卡表是只读输入，不是全局状态**：§7.5「输入：卡表从 `tests/vm_cases/cards.yaml` 读
   （测试模式）」「一个纯函数 `cast()`，不碰世界、不碰引擎、无全局状态」。
   → 签名 `cast(request, catalog)`；VM 核心库不解析 JSON。
2. **两阶段执行**：§2.1「阶段 A 解析……不扣灵力、不改状态」「阶段 B 执行：逐句判费扣费」。
   → `Parser` 产出只读句法树（`ParsedSentence`），执行阶段才扣费/生成动作。
3. **解析事件先于执行事件**：§2.2 步骤 3 解析在前；VM-026 期望 `[empty_trigger, round_end]`、
   VM-027 期望 `[depth_limit, round_end]`。
4. **反噬分支不记 depth_limit/empty_trigger**：§2.2 反噬伪代码注释
   「不记 depth_limit/empty_trigger」。→ `Parser(record_events=false)` 丢弃解析事件。
5. **反噬成本 clamp**：§2.2「cost = min(wand.spirit, plan.total_cost) # 不做灵力检查，clamp」；
   按句成本之和（含触发子句）算 `plan.total_cost`。
6. **反噬动作列表**：I1「反噬施法的动作列表只有 phantom_cast(reason="backlash")」；
   §2.7 第 2 步「本次整次替换为 1 个幻符……仍推进游标/判回符/判幻影符放置」。
7. **施法顺序**：§2.7 状态机「编号即执行顺序」：步骤 0 准入（回符拒绝不消费反噬）→ 步骤 1
   幻影符清理（`phantom_slot_cleared` 事件产生后**并入事件流**，即使本次走步骤 2 反噬）→
   步骤 1.5 空牌判定 → 步骤 2 反噬 → 步骤 3 解析 → 步骤 4 15% 替换 → 步骤 5/6 执行 →
   步骤 7/8 回符与幻影符放置。VM-014（回符拒绝）、VM-022（`round_end` 在
   `phantom_slot_added` 前）、VM-023（`phantom_slot_cleared` 在 `round_end` 前）均按此顺序期望；
   E1 覆盖"步骤 1 事件 + 步骤 2 反噬"同时发生。
8. **牌堆剔除空位与幻影位**：§1.2「空符位、被幻影符占据的符位不进入牌堆」、附录 A `deck()`。
9. **游标口径**：§1.2 规则 1「游标逐符推进」、规则 3「一轮内多句共享同一游标；触发子句也
   共享同一游标」、规则 4「游标不回绕」；VM-004/VM-007/VM-008 期望。
10. **无效句吞牌口径**：附录 A「只吞『当前段』——符头串 + 紧随的连续符脚串；不吞后面的符」；
    §2.6「扣灵力、无动作、游标推进、记事件、继续下一句」；VM-012/VM-013 期望。
11. **无效句不展开触发**：§2.6「无效句里的符头：效果丢弃，不带到下一句」；VM-013 期望
    `event_codes` 只有 `[invalid_sentence, round_end]`（无 `empty_trigger`）。
12. **每句只认第一个触发符头**：§2.3 第 6 条与 §7.2「每张触发符头只挂 1 个子句」。
13. **深度超限判定**：§2.3 第 2/3 条「子句本身也可以带触发符头 → 继续展开，直到 depth >
    max_trigger_depth」「深度超限：不解析、不扣费、不消耗牌，trigger = null，记 depth_limit」；
    VM-027 期望第 4 层（depth=4）不展开、`max_depth == 3`、8 张牌都读。
14. **触发子句单独判费**：§2.3 第 5 条「子句的灵力在执行阶段展开到该子句时扣……不足 →
    该子句不展开（trigger = null），父动作保留，记 sub_fizzle_no_spirit」；§2.1「静态展开=
    预付费」。子句灵力不足时的 consumed/游标按 §7.4.1 ① 处理（见下）。
15. **payload 顺序**：§3.2「`payloads` = 符胆自带 payloads（按卡表顺序）+ 附着的符脚动作
    （按牌堆顺序）」；VM-011 期望 `[ignite, explode]`。
16. **归 挂顶层**：§1.3「`timing: sentence_end` 的符脚（归）挂在顶层、句末立即执行，不作为
    命中载荷」；§2.5「归 返还：句末立即 `refund_spirit`（clamp ≤ spirit_max），是唯一能从
    动作里改灵力的操作」；VM-015 期望 `[spawn_projectile, refund_spirit]`。
17. **伤害加成只乘四类字段**：§3.2「`damage_mult` 只乘符伤：`spawn.damage`、
    `explode.damage`、`damage.amount`、`drain_life.amount`；不乘 `ignite.damage_per_sec`
    （S-0003）、不乘 `extinguish_lantern.lanterns`（S-0004 七魄）」。→ `scale_damage()`；
    VM-005 期望 8×1.2=9.6、15×1.2=18。
18. **分身乘 count**：§3.2「分身 `projectile_mult` 乘到该句 spawn 的 `count`（可叠加，
    2 张 = ×4）」；VM-006/VM-028~VM-030 期望 2/16/32。
19. **预算钳制算法**：§2.4「单个 spawn 的 per = 1 + Σ exec(payload) + exec(trigger.actions)；
    count = min(请求 count, floor((64 − 已用执行次数) / per), 32 − 已用投射物)」；
    `exec(spawn) = count × (1 + Σ exec(p) + exec(trigger.actions))`、`exec(其他 op)=1`
    （§2.4 计数定义；refund_spirit 属"其他 op"，见 §7.4.1 ④）；VM-028（恰好 64 不截断）、
    VM-029（动作 64 钳）、VM-030（投射物 32 钳）期望。E2/E3/E4 覆盖复审修复后的边界。
20. **子句执行次数只计一次**：§2.4 `exec(spawn)=count×(1+Σpayload+Σtrigger)`。实现上
    触发子句展开只返回执行次数、不单独累加 `used_actions/used_projectiles`；父 spawn 的
    `per` 已包含子句执行次数，于是整棵树只计一次（E2：per=7 → count=9、action_count=63）。
21. **钳到 0 停止剩余展开**：§2.4「被钳制到 0 → 该 spawn 不生成并停止展开」。实现：主循环
    在该句后停止读/扣后续主句，游标停在已 consumed 处（E3）。
22. **refund 计入预算**：§7.4.1 ④「`refund_spirit`……计入 `action_count`，也计入
    『已用执行次数』预算（会挤占后续 spawn 的额度）；它自身不参与 spawn 的 `count` 钳制、
    也不单独截断」；E4 覆盖。
23. **钳制事件**：§4.3 `budget_exhausted_action`/`budget_exhausted_projectile`（附加字段
    `limit`）；同时超限时先动作后投射物（§2.4 与 §7.4.1 ⑤）。
24. **禁符扣除时点**：§2.5「神智扣除（禁符）与灵力扣除同一时刻（『念出』的原子时刻）」
    → 句首扣费后立即处理本句禁符；多张禁符逐张 −20、各记事件（§7.4.1 ⑥）。
25. **禁符事件顺序**：§2.7 第 5 步「`forbidden_read`、`backlash_armed`」；VM-016 期望
    `[forbidden_read, backlash_armed, round_end]`。
26. **反噬中禁符不生效**：§2.7 第 2 步「本次读到的禁符不生效、不扣神智」；S-0004
    `phantom_rules` 第 1 条；VM-018 期望 `sanity_after == 100`、无 `forbidden_read`。
27. **15% 替换条件**：§2.7 第 4 步「`sanity < 33` 且 `!has_forbidden` → `rng.phantom_roll < 0.15`
    时把主句第一个符胆替换为幻符……否则不替换（含禁符/已反噬时不掷骰）」；§4.1 `rng` 注入。
    VM-020（替换）、VM-021（含禁符不掷骰，roll=0.01 也不替换）期望。
28. **替换的载荷与成本**：§2.7 第 4 步「其符脚保留为 `payloads`，成本不变」；
    §3.2「`phantom_cast.payloads` 只含符脚动作（幻符无自带载荷）」；VM-020 期望。
29. **替换句带触发符头（选择 Option B）**：§2.7 第 4 步补写「触发子句不展开、不扣灵力、
    不计 `consumed`」「游标停在子句首（不越过）」「本次成本 = 主句直接符成本之和」
    「若尚未读尽牌堆，不回符」；§7.3 #6 记录该取舍与备选 A。实现：被替换句的
    `triggers` 不展开，`cursor_after = sentence.own_end`（不是 plan.end_cursor），
    子句卡不扣费/不计 consumed（E5）。多句施法该组合 spec §7.4 列为未定义（见下）。
30. **替换不扣神智**：I5；VM-020 期望 `sanity_after == 20`。
31. **幻影符放置**：§2.7 第 8 步「`sanity < 33` 且 `phantom_slots == []` → 从**不含禁符的符位**
    中按 `rng.phantom_slot` 选 1 格放置」；§4.1「`rng.phantom_slot`（注入，避免 VM 内置 RNG）」；
    §5.2/S-0004「放置候选过滤：槽内有禁符 → 不可选」。VM-022 注入空槽位 2 → 空槽位不含
    禁符，可放（期望 `phantom_slots_after: [2]`）。
32. **幻影符清除**：§2.7 第 1 步与 I2；VM-023 期望「被占的符恢复可读」。
33. **事件附加字段**：§4.3 表（`sentence`/`card`/`slot`/`depth`/`limit`/`ready_at_tick`）；
    用例只比较 `event_codes` 顺序（§4.2），附加字段不参与比较。
34. **动作比较**：§3.1「按 §3.2 的默认值补齐字段后再比较；用例里的期望动作可省略取默认值的
    字段」「期望与实际逐项深度相等（数组长度相同、顺序相同、规范化后字段集合相同）。`from`
    不比较」；§6.3 第 1 条。
35. **数值相等**：§6.3「逐项深度相等」按数值相等实现；浮点比较用 1e-9 相对误差，只为吸收
    double 表示误差（如 15×1.2 与 YAML 十进制 18 的 1 ulp 差），不放宽任何语义差异。
    整数与浮点字面量（`8` 与 `8.0`）等价。
36. **事件有序全等、consumed 有序**：§6.3 第 2/3 条。
37. **不变量表达式**：§6.3 第 4 条（左值集 `accepted/action_count/spawn_count/max_depth/
    spirit_after/sanity_after/cursor_after/ready_at_tick_after/round_ended/backlash_after/
    phantom_slots_after/consumed_count`，运算符 `== != < <= > >=`，右值 YAML 字面量）。
38. **I1–I6**：§2.7 不变量表，逐条在 `harness/compare.cpp` 的 `check_global_invariants()` 实现
    （每条用例隐式检查，§6.3 第 5 条）。
39. **派生计数**：§2.4 计数定义；VM 的 `CastResult.action_count/spawn_count/max_depth` 与
    runner 检查（invariants）使用同一式；T1 `validate_cases.py` 的 `action_stats()` 同式。
40. **卡表 phantom_pool 的 effect 内联**：`tests/vm_cases/cards.yaml` 注释「phantom_cast
    动作内联其 effect，T4 可直接执行」；§3.2 `phantom_cast.effect`（必填：幻符表里的动作对象）。
41. **spawn 默认字段**：§3.2 表（`count=1, damage=0, damage_type="none", element="none",
    pierce=0, speed=12, spread_deg=0, ttl_ticks=120, payloads=[], trigger=null`）；
    卡表没有 speed/ttl 覆盖字段，使用表内默认值。
42. **`damage_type`/`element` 缺省**：卡表未给 `damage_type` 的符胆（土遁/藤生等）输出
    `"none"`，按 §3.2 spawn 字段默认值；`element` 同理。

## 规格补写口径（2026-11-15 复审补丁）与仍未定义的边界

### 已补写并被本实现+边界测试覆盖

- **§2.7 第 4 步补写（Option B，§7.3 #6）**：替换句带触发符头时只换符胆；触发子句不展开、
  不扣灵力、不计 `consumed`；游标停在子句首（`own_end`）；未读尽不回符；成本 = 主句直接符成本。
  → 实现见主循环 `substitute_index` 分支；E5 覆盖。
- **§7.4.1 ①** `sub_fizzle_no_spirit`：子句符按「解析已读出」计入 `consumed`、游标按解析
  推进到子句末，但不扣费、不展开。→ `expand_sentence()` 子句判费分支用
  `collect_sentence_ids()`（含嵌套子句）计入 consumed。
- **§7.4.1 ②** 多主句中途 fizzle：`cursor_after = 起始游标 + 已 consumed 数`。
- **§7.4.1 ③** rng null 兜底：`phantom_slot = null` → 不放置；`phantom_card = null` →
  反噬 `phantom_cast.effect = null`、15% 替换不掷骰。
- **§7.4.1 ④** `refund_spirit` 计入 `action_count` 与「已用执行次数」预算；不参与 spawn 的
  `count` 钳制、不单独截断。→ `expand_sentence()` 与替换分支都累加 refund 的执行次数；E4 覆盖。
- **§7.4.1 ⑤** 动作/投射物同时超限：先动作（`budget_exhausted_action`）后投射物
  （`budget_exhausted_projectile`）。→ `expand_sentence()` 钳制顺序。
- **§7.4.1 ⑥** 多张禁符：逐张按卡片顺序 −20、各记 `forbidden_read`+`backlash_armed`。
  → `apply_forbidden()` 遍历本句 heads/body/feet。

### 仍未定义（实现选择，不改变契约，30 条用例不覆盖）

1. **多句施法 + 15% 替换 + 触发符头**：spec §7.4 明确「未定义」（补写只固定
   `sentences_per_cast=1`）。本实现对 `sentences_per_cast>1` 取「替换句后不再继续读后续主句」
   （与"游标停在子句首"一致）；若 T4b 需要该组合，先补规则与用例再改实现。
2. **幻影符注入槽位本身含禁符**：§2.7 第 8 步只说候选「不含禁符」，未定义注入非法值时行为。
   本实现不放置（不自造候选回退）。
3. **被替换句带 归（`timing: sentence_end` 符脚）**：§2.7 第 4 步「其符脚保留为 payloads」
   与 §1.3「`sentence_end` 的符脚挂顶层」的组合未定义。本实现：非 `sentence_end` 符脚进
   payloads，归 仍按 §1.3 作为句末顶层动作并执行 refund。
4. **`sub_fizzle_no_spirit` 之后语句否继续**：§2.3 第 5 条只说父动作保留；本实现按"照常继续
   执行后续主句/动作"（子句卡已 consumed、游标已推进，§7.4.1 ①）。

## 不做（§7.5「不做」清单，不是遗漏）

投射物飞行/命中判定/ttl 计时、世界执行、神智 = 0 入魔、洗牌 RNG（散符只接收已排好的
`deck`）、回灵 tick 推进、施法间隔 `cast_interval` 调度、UI 表现。VM 只产出 C-ACT 动作树。
