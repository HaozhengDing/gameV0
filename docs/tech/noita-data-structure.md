# Noita 数据结构笔记（只读分析）

> 目的：学习 Noita 的**数据组织方式**，用于《刍狗》的 Godot 数据驱动架构；不复制任何资产或代码。
> 来源：用户电脑上的 Noita 安装（D:/steam/steamapps/common/Noita，2025-02-25 版本），只读分析。
> 合规：官方 modding 工具/协议；未反编译引擎、未修改游戏；临时解包文件分析完已删除。

## 1. 怎么拿到的

- 游戏自带 `tools_modding/`：`data_wak_unpack.bat`、`component_documentation.txt`（357 KB 组件文档）、`lua_api_documentation.txt`（API v12）。
- 官方解包命令是 `noita.exe -wizard_unpak`（需要交互式桌面会话；在 SSH 服务会话里跑不出文件，未采用）。
- 改用社区公开的 `data.wak` 格式说明写 Python 解析（格式简单：16 字节头 + 索引 + 无压缩数据块），只解出文本文件（XML/Lua/TXT），共 5,566 个、11.2 MB，用于结构分析。

## 2. 数据规模与目录地图

`data.wak`：42.4 MB，14,745 个文件；其中 PNG 9,030、XML 4,325、Lua 1,077、TXT 162。

| 目录 | 文件数 | 作用 |
|---|---|---|
| `data/entities/` | 3,432 | 实体 = XML 组件组合：animals 832、misc 583、projectiles 490、props 265、items 249、buildings 188、verlet_chains 379 |
| `data/scripts/` | 1,032 | 行为脚本：projectiles 200、biomes 122、buildings 103、animals 94、perks 78、items 61、gun/procedural 60、magic 19、status_effects 18、lib 3 |
| `data/biome/` | 173 | 群系（关卡）定义 XML：拓扑、材质、生成参数 |
| `data/biome_impl/` | 2,232 | 手工房间/拼接块（spliced XML + 图片），caves 1,014 |
| `materials.xml` | 418 KB | 全部物质的属性表 |
| `magic_numbers.xml` | 8 KB | 全局设计参数/开关（集中调参） |
| `items_gfx/wands` | 1,026 | 法杖外观 |
| `ui_gfx/gun_actions` | 638 | 法术图标 |
| `generated/` | 628 | 预生成数据（材质图标、UV 图等） |
| `particles/`、`ragdolls/`、`vegetation/`、`weather_gfx/` | — | 表现层资源 |

## 3. 五种核心数据模式

### 3.1 物质表：`materials.xml` 的 `<CellData>`
每个物质一个节点，字段即玩法：`name / ui_name / tags / density / cell_type / burnable / requires_oxygen / temperature_of_fire / liquid_gravity / wang_color / gfx_glow`；带 `<Graphics color>`；派生物质用 `<CellDataChild _parent="fire">` 继承。
→ 启示：物质不是硬编码，是**一张可扩展的表**，反应/渲染/音效都挂在表项上。

### 3.2 实体：`<Entity>` + `<Base file>` + 组件覆盖
`data/entities/animals/zombie_weak.xml` 只声明：`<Base file=".../zombie.xml">`，然后覆盖 `DamageModelComponent.hp` 和 `SpriteComponent.image_file`。
投射物 `all_spells_base.xml`：`<Base file="base_projectile.xml">` + `VelocityComponent` + `ProjectileComponent` + `LuaComponent script_source_file=...` + `AudioComponent`。
→ 启示：**原型继承 + 组件覆盖**；同类敌人/法术从一个 base 派生，只写差异；行为用 LuaComponent 挂脚本。

### 3.3 群系：XML 拓扑 + Lua 生成脚本 + 手工房间
`data/biome/coalmine.xml`：`<Topology type="BIOME_WANG_TILE" wang_template_file=... lua_script=...>` + `<BitmapCaves>`（洞窟数量/强度）+ `<CaveStructure image_file=... aabb=... count=...>`（把手工房间塞进程序化地图）。
`data/scripts/biomes/coalmine.lua`：`RegisterSpawnFunction(0xff0000ff, "spawn_nest")` 把 wang 颜色映射到生成函数；`g_small_enemies` 用 `prob/min_count/max_count/entity` 表做概率刷怪；`dofile` 引入通用 helpers。
→ 启示：**程序化 + 手工块混合**；颜色/瓦片即"生成指令"，概率表即刷怪配置。

### 3.4 全局调参：`magic_numbers.xml`
大量 `DESIGN_*` 开关 + 数值（掉落、开局位置、昼夜速度等）集中在一个文件。
→ 启示：**所有可调数值集中一处**，方便平衡/热更/做实验；区分"设计开关"和"数值"。

### 3.5 法术/法杖：实体 + Lua + 概率分布表
法术是 `data/entities/projectiles/deck/*.xml`（实体 + `LuaComponent` 脚本）；法杖由 `data/scripts/gun/procedural/*.lua` 生成：`gun_probs["deck_capacity"]` 用 `prob / min / max / mean / sharpness / extra` 的概率分布表，而不是硬编码。
→ 启示：**随机生成 = 数据表 + 分布函数**；同一个生成器加新分布就能扩展。

### 3.6 Mod：同名路径覆盖
`mods/<mod>/data/...` 与游戏 `data/...` 同路径即覆盖；官方示例 mod 只动少量文件。
→ 启示：**按路径覆盖**是最简单的 mod/热更方案，前提是数据文件全部走相对路径、可索引。

## 4. 架构总结（六条）
1. 数据（XML/表）与行为（Lua）分离；数据可读、可改、可 mod。
2. 实体是组件组合，且用 `Base` 做原型继承（只写差异）。
3. 群系 = 拓扑 XML + Lua 生成脚本 + 手工房间块，程序化与手搓混合。
4. 随机性用概率分布表描述，而不是代码里写死。
5. 全局参数集中在 `magic_numbers`，设计开关与数值分开。
6. Mod 通过同路径覆盖实现，数据层天然支持扩展。

## 5. 对《刍狗》的落地映射（Godot 4）

建议我们的 `data/` 目录（先 JSON，稳定后再考虑 .tres）：

```text
data/
  materials/           # 五行物质：id, 五行, 密度, 相态, 反应, 伤害
  entities/            # 敌人/NPC/符器：组件列表 + 数值
  talismans/           # 符头/符胆/符脚 与组合规则
  fates/               # 命格：明面/暗面/变异/谶语
  biomes/              # 每层：拓扑参数 + 刷怪概率表 + 房间引用
  rooms/               # 手工房间（Godot 场景或 tile 数据）
  magic_numbers.json   # 全局调参（区分 design_* 与数值）
  scripts/             # GDScript 行为（不写进数据里）
mods/                  # 以后：同路径覆盖
```

- 用 **Resource/JSON + GDScript** 即可，**不要**照搬 XML+Lua 双语言（Noita 是 C++ 引擎 + Lua，我们是 Godot，双语言只会增加成本）。
- 组件化用 Node + Resource 实现（如 HealthNode、SpriteNode、HurtboxNode、Lua 等价的 GDScript 行为脚本）。
- 物质表/反应表先做 12 种物质 + 8 条反应（与 P0 卡片一致）。
- 群系先做"矿井"一层：概率表刷怪 + 2–3 个手工房间 + 1 个 BOSS 房。

## 6. 借鉴清单
**值得借**：原型继承式实体配置；概率分布表刷怪/生成；程序化与手工房间混合；全局参数集中调参；同路径 mod 覆盖。
**不要照搬**：C++ 逐像素模拟核心；XML+Lua 双语言；Noita 的具体数值/资产/专名；为 mod 支持过早设计 API。

## 7. 临时文件清理
桌面临时目录 `D:/noita_unpack_tmp`（复制体 + 解包文本）已删除；手机端未保存任何解包文件。
