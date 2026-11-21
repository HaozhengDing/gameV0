extends Node2D
## M1-02 战斗与投射物总控：
## 1) 消费 C-ACT 全部 16 种动作（spawn_projectile、explode、damage、ignite、spawn_cloud、purify、
##    barrier、grant_temp_slot、convert_material、spawn_material、dig、apply_status、
##    extinguish_lantern、drain_life、refund_spirit、phantom_cast）；
## 2) 驱动真实投射物飞行、子步地形/液体/实体碰撞、穿透 pierce 与 on_hit/on_expire 触发树；
## 3) 驱动战斗实体状态（burning/wet/stun/slow/poison）、weak_to 结算与 3 条实体标签反应；
## 4) 灰盒可视化绘制（投射物发光轨迹、实体身形、血条与状态点）。

const SCALE := 4
const MAX_ACTION_DEPTH := 6
const EXPLODE_HEAT_MARGIN := 4
const HEAT_BURST_TEMP := 400.0
const MULTI_SPREAD_MIN_DEG := 8.0

const EntityScript := preload("res://scripts/combat/combat_entity.gd")
const ProjectileScript := preload("res://scripts/combat/projectile.gd")

var sim: SimWorldNode
var event_bus
var text_db
var overlay
var hud
var player_heal_callback: Callable = Callable()
var player_pos_getter: Callable = Callable()
var player_hit_callback: Callable = Callable()

var projectiles: Array = []      # Array of ProjectileScript
var entities: Array = []         # Array of EntityScript
var _mat_ids: Dictionary = {}
var _caster_temp_slot_ticks: int = 0

# 本局 / 本轮统计（供 HUD 与 smoke 断言）
var stats: Dictionary = {
	"dug": 0,
	"ignited": 0,
	"converted": 0,
	"converted_to_water": 0,
	"spawned": 0,
	"projectiles_spawned": 0,
	"hits_entity": 0,
	"hits_terrain": 0,
	"triggers_fired": 0,
	"total_damage": 0.0,
	"total_healed": 0.0,
}

func setup(p_sim: SimWorldNode, p_event_bus = null, p_text_db = null, p_overlay = null, p_hud = null) -> void:
	sim = p_sim
	event_bus = p_event_bus
	text_db = p_text_db
	overlay = p_overlay
	hud = p_hud
	_cache_materials()

func _cache_materials() -> void:
	_mat_ids.clear()
	if sim == null or not sim.has_world():
		return
	for name_str in ["empty", "rock", "water", "oil", "fire", "quicksilver", "black_dog_blood",
			"cinnabar", "yin_qi", "smoke", "toxic_smoke", "steam"]:
		_mat_ids[name_str] = sim.material_id(name_str)

func reset_round() -> void:
	projectiles.clear()
	entities.clear()
	_caster_temp_slot_ticks = 0
	reset_stats()
	_cache_materials()
	queue_redraw()

func reset_stats() -> void:
	stats = {
		"dug": 0,
		"ignited": 0,
		"converted": 0,
		"converted_to_water": 0,
		"spawned": 0,
		"projectiles_spawned": 0,
		"hits_entity": 0,
		"hits_terrain": 0,
		"triggers_fired": 0,
		"total_damage": 0.0,
		"total_healed": 0.0,
	}

func get_temp_slot_ticks() -> int:
	return _caster_temp_slot_ticks

# ------------------------------------------------------------------ 实体管理

func spawn_entity(cfg: Dictionary):
	var ent = EntityScript.new()
	ent.init_entity(cfg)
	entities.append(ent)
	queue_redraw()
	return ent

func clear_entities() -> void:
	entities.clear()
	queue_redraw()

func get_entity(entity_id: String):
	for ent in entities:
		if ent.entity_id == entity_id:
			return ent
	return null

func alive_entity_count(faction_filter: String = "") -> int:
	var n := 0
	for ent in entities:
		if not ent.alive:
			continue
		if faction_filter.is_empty() or ent.faction == faction_filter:
			n += 1
	return n

# ------------------------------------------------------------------ C-ACT 动作执行

## 入口：执行 VM 返回的一批 C-ACT 动作。返回本次立即执行的统计（发射投射物数等）。
func execute_actions(actions: Array, origin: Vector2, aim_dir: Vector2, owner_id: String, faction: String) -> Dictionary:
	var summary := {
		"projectiles": 0,
		"dug": 0,
		"ignited": 0,
		"converted": 0,
		"converted_to_water": 0,
		"spawned": 0,
		"damage": 0.0,
	}
	var dir := aim_dir.normalized() if aim_dir.length() > 0.0001 else Vector2.RIGHT
	for item in actions:
		if item is Dictionary:
			var action_dict: Dictionary = item
			_execute_action(action_dict, origin, dir, owner_id, faction, null, summary, 0)
	queue_redraw()
	return summary

func _execute_action(action: Dictionary, pos: Vector2, dir: Vector2, owner_id: String, faction: String,
		hit_entity, summary: Dictionary, depth: int) -> void:
	if depth > MAX_ACTION_DEPTH or sim == null or not sim.has_world():
		return
	var op: String = String(action.get("op", ""))
	var cell := Vector2i(floori(pos.x), floori(pos.y))
	var tick: int = sim.get_tick()
	match op:
		"spawn_projectile":
			var count: int = maxi(int(action.get("count", 1)), 1)
			var spread_deg: float = float(action.get("spread_deg", 0.0))
			if count > 1 and spread_deg < 0.01:
				spread_deg = MULTI_SPREAD_MIN_DEG
			var base_angle := dir.angle()
			for i in range(count):
				var angle := base_angle
				if count > 1:
					var t := (float(i) / float(count - 1)) - 0.5
					angle += deg_to_rad(spread_deg * t)
				var shot_dir := Vector2.from_angle(angle)
				var proj = ProjectileScript.new()
				proj.init_from_action(action, pos, shot_dir, owner_id, faction)
				projectiles.append(proj)
				summary["projectiles"] = int(summary["projectiles"]) + 1
				stats["projectiles_spawned"] = int(stats["projectiles_spawned"]) + 1
			return
		"explode":
			var radius: int = maxi(int(action.get("radius", 20)), 1)
			var dmg: float = float(action.get("damage", 15.0))
			var dtype: String = String(action.get("damage_type", "火"))
			var dug: int = sim.dig(cell.x, cell.y, radius)
			var lit: int = sim.apply_heat_burst(cell.x, cell.y, radius + EXPLODE_HEAT_MARGIN, HEAT_BURST_TEMP)
			summary["dug"] = int(summary["dug"]) + dug
			summary["ignited"] = int(summary["ignited"]) + lit
			stats["dug"] = int(stats["dug"]) + dug
			stats["ignited"] = int(stats["ignited"]) + lit
			if dug > 0 and event_bus != null:
				event_bus.publish("terrain_dug", tick, {"source_id": owner_id, "pos": cell, "value": float(dug)})
			var dealt := _damage_entities_in_radius(pos, float(radius), dmg, dtype, owner_id, faction, tick)
			summary["damage"] = float(summary["damage"]) + dealt
			if overlay != null:
				overlay.add_ring(cell, float(radius), Color(1.0, 0.52, 0.18, 0.90))
			if dug > 0:
				_log("爆破挖开 %d" % dug)
			return
		"damage":
			var amount: float = float(action.get("amount", 0.0))
			var dtype: String = String(action.get("damage_type", "none"))
			var radius: float = float(action.get("radius", 0.0))
			var dealt := 0.0
			if hit_entity != null and radius <= 0.0:
				dealt = hit_entity.take_damage(amount, dtype, owner_id, tick, event_bus)
				stats["total_damage"] = float(stats["total_damage"]) + dealt
			elif radius > 0.0:
				dealt = _damage_entities_in_radius(pos, radius, amount, dtype, owner_id, faction, tick)
			else:
				# 落点无半径也检测近邻敌人（容错 6 格）
				dealt = _damage_entities_in_radius(pos, 6.0, amount, dtype, owner_id, faction, tick)
			summary["damage"] = float(summary["damage"]) + dealt
			return
		"ignite":
			var duration_sec: float = maxf(float(action.get("duration", 3.0)), 0.5)
			var dps: float = float(action.get("damage_per_sec", 0.0))
			var heat_r: int = maxi(int(action.get("radius", 5)), 3)
			var lit: int = sim.apply_heat_burst(cell.x, cell.y, heat_r, HEAT_BURST_TEMP)
			summary["ignited"] = int(summary["ignited"]) + lit
			stats["ignited"] = int(stats["ignited"]) + lit
			var dur_ticks := roundi(duration_sec * 60.0)
			if hit_entity != null:
				hit_entity.apply_status("burning", dur_ticks, tick, event_bus, dps)
			else:
				for ent in _entities_in_radius(pos, 6.0, faction):
					ent.apply_status("burning", dur_ticks, tick, event_bus, dps)
			return
		"spawn_cloud":
			var kind: String = String(action.get("kind", "toxic_smoke"))
			var radius: int = maxi(int(action.get("radius", 6)), 1)
			var dmg: float = float(action.get("damage", 0.0))
			var dtype: String = String(action.get("damage_type", "毒" if kind == "toxic_smoke" else "火"))
			var mat_name := "toxic_smoke" if kind == "toxic_smoke" else "steam"
			var spawned := _spawn_material_circle(cell, mini(radius, 12), mat_name)
			summary["spawned"] = int(summary["spawned"]) + spawned
			stats["spawned"] = int(stats["spawned"]) + spawned
			if dmg > 0.0:
				var dealt := _damage_entities_in_radius(pos, float(radius), dmg, dtype, owner_id, faction, tick)
				summary["damage"] = float(summary["damage"]) + dealt
			return
		"purify":
			var removes: String = String(action.get("removes", "yin_qi"))
			var radius: int = maxi(int(action.get("radius", 3)), 1)
			var removed := _purify_circle(cell, radius, removes)
			if removed > 0 and event_bus != null:
				event_bus.publish("reaction_triggered", tick, {
					"source_id": owner_id, "pos": cell, "reaction_id": "r-rice-purify",
					"value": float(removed), "text_key": "$react_rice_purify",
				})
			return
		"barrier":
			var radius: int = maxi(int(action.get("radius", 2)), 1)
			var spawned := _spawn_material_circle(cell, radius, "quicksilver")
			summary["spawned"] = int(summary["spawned"]) + spawned
			stats["spawned"] = int(stats["spawned"]) + spawned
			return
		"grant_temp_slot":
			var duration_sec: float = maxf(float(action.get("duration", 60.0)), 1.0)
			_caster_temp_slot_ticks = roundi(duration_sec * 60.0)
			if event_bus != null:
				event_bus.publish("reaction_triggered", tick, {
					"source_id": owner_id, "pos": cell, "reaction_id": "r-cinnabar-talisman",
					"value": float(action.get("value", 1)), "text_key": "$react_cinnabar_talisman",
				})
			_log("临时符位 +1")
			return
		"convert_material":
			var radius: int = maxi(int(action.get("radius", 2)), 1)
			var to_name: String = String(action.get("to", ""))
			var conv := _convert_circle(cell, radius, to_name, tick)
			summary["converted"] = int(summary["converted"]) + conv
			stats["converted"] = int(stats["converted"]) + conv
			if to_name == "water" and conv > 0:
				summary["converted_to_water"] = int(summary["converted_to_water"]) + conv
				stats["converted_to_water"] = int(stats["converted_to_water"]) + conv
				_log("化水成功 %d" % conv)
			if overlay != null:
				overlay.add_ring(cell, float(radius + 2), Color(0.36, 0.84, 1.0, 0.92))
			return
		"spawn_material":
			var mat_name: String = String(action.get("material", ""))
			var radius: int = maxi(int(action.get("radius", 2)), 1)
			var spawned := _spawn_material_circle(cell, radius, mat_name)
			summary["spawned"] = int(summary["spawned"]) + spawned
			stats["spawned"] = int(stats["spawned"]) + spawned
			return
		"dig":
			var radius: int = maxi(int(action.get("radius", 2)), 1)
			var dug: int = sim.dig(cell.x, cell.y, radius)
			summary["dug"] = int(summary["dug"]) + dug
			stats["dug"] = int(stats["dug"]) + dug
			if dug > 0 and event_bus != null:
				event_bus.publish("terrain_dug", tick, {"source_id": owner_id, "pos": cell, "value": float(dug)})
			if overlay != null:
				overlay.add_ring(cell, float(radius + 1), Color(0.88, 0.78, 0.52, 0.88))
			if dug > 0:
				_log("挖掘 %d" % dug)
			return
		"apply_status":
			var st: String = String(action.get("status", "stun"))
			var dur_sec: float = maxf(float(action.get("duration", 1.5)), 0.1)
			var dur_ticks := roundi(dur_sec * 60.0)
			if hit_entity != null:
				hit_entity.apply_status(st, dur_ticks, tick, event_bus)
			else:
				for ent in _entities_in_radius(pos, 8.0, faction):
					ent.apply_status(st, dur_ticks, tick, event_bus)
			if overlay != null:
				overlay.add_ring(cell, 5.0, Color(0.68, 0.52, 0.98, 0.88))
			return
		"extinguish_lantern":
			var lanterns_amt: float = maxf(float(action.get("lanterns", 0.3)), 0.0)
			# 对敌人：1 盏阴伤折算 30 点阴性伤害（对玩家本体由七星灯系统直接熄灯）
			var yin_dmg := lanterns_amt * 30.0
			var dealt := 0.0
			if hit_entity != null:
				dealt = hit_entity.take_damage(yin_dmg, "阴", owner_id, tick, event_bus)
				stats["total_damage"] = float(stats["total_damage"]) + dealt
			else:
				dealt = _damage_entities_in_radius(pos, 6.0, yin_dmg, "阴", owner_id, faction, tick)
			summary["damage"] = float(summary["damage"]) + dealt
			return
		"drain_life":
			var amount: float = maxf(float(action.get("amount", 4.0)), 0.0)
			var dealt := 0.0
			if hit_entity != null:
				dealt = hit_entity.take_damage(amount, "阴", owner_id, tick, event_bus)
				stats["total_damage"] = float(stats["total_damage"]) + dealt
			else:
				dealt = _damage_entities_in_radius(pos, 6.0, amount, "阴", owner_id, faction, tick)
			summary["damage"] = float(summary["damage"]) + dealt
			if dealt > 0.0:
				stats["total_healed"] = float(stats["total_healed"]) + dealt
				if player_heal_callback.is_valid():
					player_heal_callback.call(dealt)
			return
		"refund_spirit":
			return
		"phantom_cast":
			var eff: Variant = action.get("effect")
			if eff is Dictionary:
				var eff_dict: Dictionary = eff
				_execute_action(eff_dict, pos, dir, owner_id, faction, hit_entity, summary, depth + 1)
			var raw_p: Variant = action.get("payloads", [])
			if raw_p is Array:
				for p in raw_p:
					if p is Dictionary:
						var pd: Dictionary = p
						_execute_action(pd, pos, dir, owner_id, faction, hit_entity, summary, depth + 1)
			return
		_:
			print("COMBAT_UNKNOWN_OP op=" + op)

# ------------------------------------------------------------------ 固定步进

func step_tick() -> void:
	if sim == null or not sim.has_world():
		return
	var tick: int = sim.get_tick()
	if _caster_temp_slot_ticks > 0:
		_caster_temp_slot_ticks -= 1

	# 1) 步进所有投射物
	var next_projectiles: Array = []
	for proj in projectiles:
		if not proj.alive:
			continue
		_step_projectile(proj, tick)
		if proj.alive:
			next_projectiles.append(proj)
	projectiles = next_projectiles

	# 2) 步进所有实体（状态 DoT + 环境接触 + 3 条实体标签反应）
	for ent in entities:
		if ent.alive:
			ent.step_tick(sim, tick, event_bus, _mat_ids)

	queue_redraw()

func _step_projectile(proj, tick: int) -> void:
	proj.vel.y += proj.gravity
	var step_vec: Vector2 = proj.vel
	var dist := step_vec.length()
	var substeps := maxi(ceili(dist), 1)
	var delta := step_vec / float(substeps)
	var world_w := sim.get_world_width()
	var world_h := sim.get_world_height()
	var dummy_summary := {"projectiles": 0, "dug": 0, "ignited": 0, "converted": 0, "converted_to_water": 0, "spawned": 0, "damage": 0.0}

	for _i in range(substeps):
		proj.pos += delta
		var c: Vector2i = proj.cell_pos()
		if c.x < 0 or c.y < 0 or c.x >= world_w or c.y >= world_h:
			proj.alive = false
			return

		# a0) 敌方投射物命中玩家检测（M1-06）
		if proj.faction == "enemy" and _hits_player(proj.pos, proj.radius):
			stats["hits_entity"] = int(stats["hits_entity"]) + 1
			if player_hit_callback.is_valid():
				player_hit_callback.call({
					"pos": proj.pos,
					"dir": proj.direction(),
					"damage": proj.damage,
					"damage_type": proj.damage_type,
					"lantern_damage": proj.lantern_damage,
					"source_id": proj.owner_id,
					"tick": tick,
				})
			for payload in proj.payloads:
				_execute_action(payload, proj.pos, proj.direction(), proj.owner_id, proj.faction, null, dummy_summary, 1)
			_try_fire_trigger(proj, "on_hit", null, dummy_summary)
			proj.alive = false
			return

		# a) 实体碰撞检测（敌对阵营）
		var hit_ent = _find_entity_hit(proj)
		if hit_ent != null:
			proj.hit_entities[hit_ent.entity_id] = true
			stats["hits_entity"] = int(stats["hits_entity"]) + 1
			if proj.damage > 0.0:
				var dealt: float = hit_ent.take_damage(proj.damage, proj.damage_type, proj.owner_id, tick, event_bus)
				stats["total_damage"] = float(stats["total_damage"]) + dealt
				if dealt > 0.0:
					hit_ent.apply_knockback(proj.direction() * 42.0 + Vector2(0.0, -14.0))
			for payload in proj.payloads:
				_execute_action(payload, proj.pos, proj.direction(), proj.owner_id, proj.faction, hit_ent, dummy_summary, 1)
			_try_fire_trigger(proj, "on_hit", hit_ent, dummy_summary)
			if proj.pierce_left > 0:
				proj.pierce_left -= 1
			else:
				proj.alive = false
				return

		# b) 地形（及化水等液面）碰撞检测
		var m: int = sim.get_cell(c.x, c.y)
		var hit_solid: bool = sim.is_solid(c.x, c.y)
		var hit_liq: bool = proj.hits_liquid and m > 0 and sim.get_material_state(m) == 2
		if hit_solid or hit_liq:
			stats["hits_terrain"] = int(stats["hits_terrain"]) + 1
			for payload in proj.payloads:
				_execute_action(payload, proj.pos, proj.direction(), proj.owner_id, proj.faction, null, dummy_summary, 1)
			_try_fire_trigger(proj, "on_hit", null, dummy_summary)
			proj.alive = false
			return

	proj.record_trail()
	proj.ttl_ticks -= 1
	if proj.ttl_ticks <= 0:
		_try_fire_trigger(proj, "on_expire", null, dummy_summary)
		proj.alive = false

func _try_fire_trigger(proj, kind: String, hit_ent, summary: Dictionary) -> void:
	if proj.trigger_fired or proj.trigger.is_empty():
		return
	if String(proj.trigger.get("kind", "")) != kind:
		return
	proj.trigger_fired = true
	stats["triggers_fired"] = int(stats["triggers_fired"]) + 1
	var trig_actions: Variant = proj.trigger.get("actions", [])
	if trig_actions is Array:
		for act in trig_actions:
			if act is Dictionary:
				var act_dict: Dictionary = act
				_execute_action(act_dict, proj.pos, proj.direction(), proj.owner_id, proj.faction, hit_ent, summary, 1)

func _find_entity_hit(proj):
	for ent in entities:
		if not ent.alive:
			continue
		if ent.faction == proj.faction:
			continue
		if proj.hit_entities.has(ent.entity_id):
			continue
		if ent.contains_point(proj.pos, proj.radius):
			return ent
	return null

# ------------------------------------------------------------------ 几何 / 世界辅助

func _entities_in_radius(center: Vector2, radius: float, attacker_faction: String) -> Array:
	var out: Array = []
	for ent in entities:
		if not ent.alive:
			continue
		if ent.faction == attacker_faction:
			continue
		if ent.distance_to_point(center) <= radius:
			out.append(ent)
	return out

func _hits_player(p: Vector2, pad: float = 0.0) -> bool:
	if not player_pos_getter.is_valid():
		return false
	var pp: Vector2 = player_pos_getter.call()
	return (
		p.x >= pp.x - 2.5 - pad
		and p.x <= pp.x + 2.5 + pad
		and p.y >= pp.y - 10.0 - pad
		and p.y <= pp.y + pad
	)

func _damage_entities_in_radius(center: Vector2, radius: float, amount: float, dtype: String,
		source_id: String, attacker_faction: String, tick: int) -> float:
	if amount <= 0.0:
		return 0.0
	var total := 0.0
	for ent in _entities_in_radius(center, radius, attacker_faction):
		var dealt: float = ent.take_damage(amount, dtype, source_id, tick, event_bus)
		total += dealt
	if attacker_faction == "enemy" and _hits_player(center, radius) and player_hit_callback.is_valid():
		var pp: Vector2 = player_pos_getter.call()
		var kb_dir := (pp - center).normalized() if pp.distance_to(center) > 0.1 else Vector2.UP
		player_hit_callback.call({
			"pos": center,
			"dir": kb_dir,
			"damage": amount,
			"damage_type": dtype,
			"lantern_damage": 0.0,
			"source_id": source_id,
			"tick": tick,
		})
		total += amount
	stats["total_damage"] = float(stats["total_damage"]) + total
	return total

func _convert_circle(center: Vector2i, radius: int, to_name: String, tick: int) -> int:
	var target: int = sim.material_id(to_name)
	if target < 0:
		return 0
	var r := maxi(radius, 0)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var converted := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			var m: int = sim.get_cell(x, y)
			if m == 0 or m == target:
				continue
			var st: int = sim.get_material_state(m)
			if st < 0 or st == 4:
				continue
			sim.set_cell(x, y, target)
			converted += 1
	return converted

func _spawn_material_circle(center: Vector2i, radius: int, mat_name: String) -> int:
	var target: int = sim.material_id(mat_name)
	if target < 0:
		return 0
	var r := maxi(radius, 1)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var spawned := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			if sim.get_cell(x, y) == 0:
				sim.set_cell(x, y, target)
				spawned += 1
	if spawned > 0:
		sim.wake_rect(center.x - r - 2, center.y - r - 2, r * 2 + 5, r * 2 + 5)
	return spawned

func _purify_circle(center: Vector2i, radius: int, mat_name: String) -> int:
	var target: int = sim.material_id(mat_name)
	if target < 0:
		return 0
	var r := maxi(radius, 1)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var removed := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			if sim.get_cell(x, y) == target:
				sim.set_cell(x, y, 0)
				removed += 1
	return removed

func _log(text: String) -> void:
	if hud != null:
		hud.log_event(text)

# ------------------------------------------------------------------ 灰盒绘制

func _draw() -> void:
	# 1) 战斗实体 + 灰盒辨识剪影 + 攻击前摇预警圈 + 极简血条与状态点
	for ent in entities:
		if not ent.alive:
			continue
		var bx: float = (ent.pos.x - ent.half_w) * float(SCALE)
		var by: float = (ent.pos.y - ent.height) * float(SCALE)
		var bw: float = ent.half_w * 2.0 * float(SCALE)
		var bh: float = ent.height * float(SCALE)
		var center_px := Vector2(bx + bw * 0.5, by + bh * 0.5)

		# 攻击前摇可读预警圈（D1 可读优先）
		if ent.telegraph_ratio > 0.01:
			var tc: Color = ent.telegraph_color
			var tr: float = maxf(bw, bh) * (0.62 + 0.35 * (1.0 - ent.telegraph_ratio))
			draw_arc(center_px, tr, 0.0, TAU, 24, Color(tc.r, tc.g, tc.b, 0.35 + 0.55 * ent.telegraph_ratio), 2.5)
			draw_circle(center_px, tr * 0.45, Color(tc.r, tc.g, tc.b, 0.22 * ent.telegraph_ratio))

		# 旱魃二阶段暗红灼热外环
		if ent.archetype == "drought_demon" and ent.phase >= 2:
			draw_arc(center_px, maxf(bw, bh) * 0.68, 0.0, TAU, 24, Color(1.0, 0.36, 0.12, 0.55), 2.0)

		var body_col: Color = Color(1.0, 0.96, 0.92) if ent.hurt_flash_ticks > 0 else ent.color
		if ent.archetype == "gas_wisp":
			# 硫烟鬼火：菱形/双层火核剪影
			draw_circle(center_px, bw * 0.62, Color(body_col.r, body_col.g, body_col.b, 0.35))
			draw_circle(center_px, bw * 0.44, body_col)
			draw_circle(center_px, bw * 0.20, Color(1.0, 0.96, 0.72))
		else:
			draw_rect(Rect2(bx, by, bw, bh), body_col)
			# 旱魃角冠 / 画皮兜帽顶饰
			if ent.archetype == "drought_demon":
				draw_rect(Rect2(bx + 2.0, by - 8.0, 8.0, 8.0), Color(0.98, 0.52, 0.16))
				draw_rect(Rect2(bx + bw - 10.0, by - 8.0, 8.0, 8.0), Color(0.98, 0.52, 0.16))
			elif ent.archetype == "painted_skin":
				draw_rect(Rect2(bx - 2.0, by - 4.0, bw + 4.0, 6.0), Color(0.42, 0.20, 0.54))
			# 朝向眼部像素点（清晰读出敌人面向）
			var eye_x := bx + (bw - 8.0 if ent.facing >= 0.0 else 3.0)
			var eye_y := by + minf(bh * 0.25, 10.0)
			var eye_col := Color(1.0, 0.90, 0.32) if (ent.archetype == "drought_demon" or ent.archetype == "painted_skin") else Color(0.10, 0.10, 0.12)
			draw_rect(Rect2(eye_x, eye_y, 5.0, 5.0), eye_col)

		# 血条（位于实体头顶 6px；BOSS 在顶部仍保留小条+屏幕底中主血条）
		var ratio := clampf(ent.hp / maxf(ent.max_hp, 1.0), 0.0, 1.0)
		var bar_w := maxf(bw, 24.0)
		var bar_x := bx + (bw - bar_w) * 0.5
		var bar_y := by - (14.0 if ent.archetype == "drought_demon" else 8.0)
		draw_rect(Rect2(bar_x, bar_y, bar_w, 4.0), Color(0.10, 0.10, 0.12, 0.85))
		draw_rect(Rect2(bar_x, bar_y, bar_w * ratio, 4.0), Color(0.96, 0.42, 0.20) if ent.archetype == "drought_demon" else Color(0.92, 0.30, 0.24))
		# 状态小色点（燃 / 湿 / 镇 / 毒）
		var dot_x := bar_x
		var dot_y := bar_y - 6.0
		for st_info in [["burning", Color(1.0, 0.45, 0.14)], ["wet", Color(0.28, 0.62, 1.0)],
				["stun", Color(0.96, 0.86, 0.26)], ["poison", Color(0.56, 0.82, 0.22)]]:
			if ent.has_status(String(st_info[0])):
				draw_rect(Rect2(dot_x, dot_y, 5.0, 4.0), st_info[1])
				dot_x += 7.0

	# 2) 飞行投射物 + 拖尾
	for proj in projectiles:
		if not proj.alive:
			continue
		var trail_arr: Array = proj.trail
		var n := trail_arr.size()
		for i in range(1, n):
			var p0: Vector2 = (trail_arr[i - 1] as Vector2) * float(SCALE)
			var p1: Vector2 = (trail_arr[i] as Vector2) * float(SCALE)
			var alpha := float(i) / float(n) * 0.65
			var tc: Color = proj.color
			draw_line(p0, p1, Color(tc.r, tc.g, tc.b, alpha), 3.0)
		var pc: Vector2 = proj.pos * float(SCALE)
		var r_outer := 5.5 if proj.faction == "enemy" else 4.5
		draw_circle(pc, r_outer, proj.color)
		draw_circle(pc, 2.2, Color(1.0, 0.96, 0.88) if proj.faction == "player" else Color(0.18, 0.06, 0.14))
