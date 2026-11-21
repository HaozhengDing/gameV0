# GDExtension API（T4b / M1 用）

> 由 `game/gdextension/src/` 提供；GDScript 直接按类名使用（`SimWorldNode`、`TalismanVMNode`）。
> 契约来源：C-SIM v3（`sim_core/include/sim/c_sim.h`）+ C-VM/C-ACT（`docs/tech/talisman-vm-spec.md` §3/§4）。

## SimWorldNode（Sprite2D 子类）

| 方法 | 说明 |
|---|---|
| `create_world(width:int, height:int, seed:int, materials_json_path:String) -> bool` | 建世界；`materials_json_path` 为空则 builtin 材质 |
| `destroy_world()` / `has_world() -> bool` | 生命周期 |
| `step_tick()` / `step_ticks(count:int)` | 推进固定 tick（1/60s） |
| `set_cell(x:int, y:int, material:int)` / `set_cell_by_name(x:int, y:int, name:String)` | 写格（`""` = 空） |
| `get_cell(x:int, y:int) -> int` / `get_cell_aux(x:int, y:int) -> int` / `material_id(name:String) -> int` | 读格 / 读附加字段（气体寿命或燃料燃烧剩余 tick）/ 名字转 id（-1 = 未知） |
| `dig(x:int, y:int, radius:int) -> int` | 挖（只移除 static/powder；返回移除数） |
| `apply_heat_burst(x:int, y:int, radius:int, heat_temp:float=400.0) -> int` | **C-SIM v3**：向圆内施加瞬时热冲击（触发黑火药/硫磺毒烟/可燃物点燃；返回受热反应或点燃的格数） |
| `poll_events(max_count:int=256) -> Array[Dictionary]` | **C-SIM v3**：拉取本 tick 模拟事件（`{type, material, x, y, aux, reaction_id}`；类型见 `sim_event_type` 1..6） |
| `reaction_id_str(reaction_id:int) -> String` / `get_material_ignition_temp(id:int) -> float` / `get_sim_version() -> String` | **C-SIM v3**：反应 id 字符串 / 材质燃点 / 契约版本（`c-sim/3.0.0`） |
| `is_solid(x:int, y:int) -> bool` | 阻挡判定：static 或 powder |
| `get_material_count() -> int` / `get_material_state(id:int) -> int` /`get_material_flammable(id:int) -> bool` | 材质表查询（state：0 空 /1 powder /2 liquid /3 gas /4 static） |
| `get_material_display(id:int) -> String` / `get_material_id_str(id:int) -> String` | 显示名 / 字符串 id |
| `set_active_rect(x,y,w,h)` / `wake_rect(x,y,w,h)` / `get_dirty_rect(clear=true) -> Rect2i` | 模拟调度 |
| `render_image() -> Image` / `update_texture()` | 全图渲染（T4a 用） |
| `render_region(x,y,w,h) -> Image` / `update_texture_region(x,y,w,h)` | 只渲染视口区域（T4b 相机用） |
| `get_world_width/height/tick/materials_source/state_hash` | 只读信息 |

Sprite2D 属性照常用：`position`、`scale`、`texture_filter`。

## TalismanVMNode（Node）

| 方法 | 说明 |
|---|---|
| `load_cards(path:String) -> bool` | 读 `data/talismans.json` |
| `is_loaded() -> bool` | |
| `tick_advance()` | 每 sim tick 调一次：内部 tick+1、回灵 `regen/60` |
| `reset()` | 灵力回满、tick/回符清零 |
| `get_group_ids() -> Array[String]` / `get_groups() -> Array[Dictionary]` | 组列表（`{id,name,spirit_cost,segments}`） |
| `cast_group(group_id:String) -> Dictionary` | 快捷符组施法（T4b 兼容）；返回见下 |
| `cast_deck(wand:Dictionary, state:Dictionary={}, rng:Dictionary={}) -> Dictionary` | **M1-03**：完整 C-VM 真牌堆施法（真游标/成文与散符/多句/禁符反噬/幻影符） |
| `get_all_cards() -> Array[Dictionary]` | **M1-03**：导出全部符卡元数据（`{id,segment,spirit_cost,forbidden,element}`） |
| `get_spirit() -> float` / `get_spirit_max() -> float` | |
| `get_tick() -> int` / `get_ready_at_tick() -> int` / `get_is_recharging() -> bool` | 回符状态 |

`cast_group` 返回字典字段：`accepted:bool`、`reject_reason:String`、`actions:Array[Dictionary]`、`consumed:Array[String]`、`spirit_after:float`、`spirit_max:float`、`sanity_after:int`、`backlash_after:bool`、`cursor_after:int`、`round_ended:bool`、`ready_at_tick_after:int`、`action_count:int`、`spawn_count:int`、`max_depth:int`、`events:Array[String]`。

### 动作（C-ACT）示例

```json
{
  "op": "spawn_projectile",
  "spell": "body-flying-sword",
  "count": 1, "damage": 8, "damage_type": "金", "element": "金",
  "pierce": 1, "speed": 12, "spread_deg": 0, "ttl_ticks": 120,
  "payloads": [ {"op": "explode", "radius": 20, "damage": 15, "damage_type": "火"} ],
  "trigger": {"kind": "on_hit", "depth": 1, "actions": []}
}
```

T4b 只执行 `game/T4B.md` §3.1 列出的 op；数值字段（damage 等）在灰盒里只用于 HUD/日志。
