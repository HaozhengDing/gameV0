# data/ 数据层规范 v0.1

> 状态：纯数据 / 文档，**未接引擎**；所有数值为占位，后续用原型调参。

## 1. 目的

按 Noita 的六种数据模式（见 `docs/tech/noita-data-structure.md`），给《刍狗》建一个可读、可改、可校验的数据层。数据与行为分离：`data/` 只放配置，行为脚本以后放 `scripts/`。

## 2. 目录

```text
data/
  README.md                         # 本文件
  magic_numbers.json                # 全局调参
  materials.json                    # 12 种物质 + 8 条反应
  biomes/
    level-01-coalmine.json          # 第 1 层：矿井
  rooms/
    room-01-silver-pit.json         # 手工房间：水银池
    room-02-gas-pocket.json         # 手工房间：瓦斯囊
```

## 3. 通用约定

- JSON UTF-8；id 用 kebab-case；不写注释（说明放 `notes` / `description`）。
- 单位：距离 = tile、时间 = 秒、伤害 = 点、密度以水为 1.0。
- 每个文件带 `schema` / `version` / `updated`。
- 引用必须可解析：material id / room ref / entity id 在同一数据层内能找到。
- 全局数值集中在 `magic_numbers.json`；数据文件只放结构性数值。
- 原型继承：`extends` 浅合并，子项覆盖同名字段，数组整体替换。

## 4. materials.json

物质字段：`id / name / ui_key / state / element / polarity / density / temperature / flammable / ignition_temperature / tags / color / extends / notes`。

反应字段：`id / name / inputs / target_tags / trigger / result / p0_ref / note`。

- `trigger.type`：`contact` / `heat`（带 `min_temperature`）
- `result.type`：`explosion` / `heat_cloud` / `purify` / `damage` / `barrier` / `temporary_talisman_slot` / `toxic_smoke` / `burn`
- `target_tags` 用于实体/物品标签（如 `spirit`、`eldritch`、`paper`），不是物质 id。

v0：12 种物质、8 条反应；与 P0 系统卡 S-0003 对齐。偏离项写在文件内 `v1_deviations`。

## 5. magic_numbers.json

分组：`design / player / sanity / elements / economy / enemy_curve / layers / layer_01`。
用途：全局调参、设计开关；后续可热重载。**所有可调数值先集中在这里**，别散落到代码。

## 6. biomes/*.json

字段：`id / name / layer / status / topology / theme / spawn_table / rooms / hazards / rules / economy / exits / design_notes`。

- `topology`：`wang_tile` + 模板图 + `rooms_mode: spliced`（程序化拓扑 + 手工房间拼接）。
- `spawn_table`：`rolls_per_room`、`mobs`、`elites`、`boss`；`prob` 是相对权重，`min/max/mean/sharpness` 是分布参数（参考 Noita 的概率表格式）。
- `rooms`：`ref / weight / count / stage / aabb`，引用 `data/rooms/` 下的房间。
- `rules`：`id / text / effect / discovery / type`；`type: false` 显式标记**假规矩**（村民骗你）。
- `hazards`：`id / trigger / effect / damage / radius`。

`level-01-coalmine.json` = P0 区域卡 L-0001 的数据化：4–6 小怪、0–1 精英、旱魃 BOSS、约 300 银、15 分钟。

## 7. rooms/*.json

字段：`size / tile_size / grid / legend / entities / hazards / intended_rules / notes`。

- `grid`：字符串数组，每行 `w` 个字符；`legend` 把字符映射到物质 id 或 `empty`。
- `entities`：`id / type / x / y / payload`；坐标必须在非实心格。
- 房间是「数据版手工房间」；以后可以导出成 Godot 场景，格式不变。

## 8. 借用的 Noita 模式与落点

| 模式 | 落点 |
| --- | --- |
| 原型继承 | `materials.extends`；实体数据后续同用 |
| 数据与行为分离 | `data/` 只放配置，行为在 `scripts/`（后续） |
| 概率分布表 | `spawn_table.mobs[].prob/min/max/mean/sharpness` |
| 程序化 + 手工混合 | `topology` + `rooms` 拼接 |
| 全局调参集中 | `magic_numbers.json` |
| 同路径 mod 覆盖 | 以后 `mods/<mod>/data/...`（v2） |

## 9. 与 P0 卡片的对齐

- 12 物质来自 P0 S-0003 材料清单的子集；8 反应对应 P0 反应表 #1–#8。
- v1 替换：尸气 → 阴气；瓦斯 → 硫磺毒烟；阴火+水 → v2；纸/墨 → `paper` tag。
- `level-01-coalmine.json` 对应 L-0001；两个房间对应「矿道分叉 / 水银池 / 瓦斯囊」。

## 10. 校验与后续

- 本批 JSON 已用 Python 校验：引用可解析、网格尺寸、实体落点。
- 后续：加 JSON Schema；Godot 导入器（JSON → Resource）；热重载；mod 覆盖。
- 不做：XML + Lua 双语言；照搬 Noita 数值/资产；过早设计 mod API。

## 11. 参考

- `docs/tech/noita-data-structure.md`（Noita 数据结构分析）
- `refs/cards/p0/`（P0 卡片）
- `docs/design/`（《刍狗》设计文档）
