extends RefCounted
## M1-02 战斗实体组件：承载生命、阵营、标签（spirit/eldritch/paper 等）、weak_to 弱点倍率、
## 状态（burning/wet/stun/slow/poison）以及 3 条「材质 × 实体标签」民俗反应
##（r-dog-blood-spirit / r-quicksilver-ward / r-cinnabar-talisman）。

const BURN_DEFAULT_DPS_RATIO := 0.02   # data/magic_numbers.json fire_heat.burning_dps_max_hp_ratio
const BURN_TICK_INTERVAL := 30         # 每 0.5s 结算一次持续伤（60Hz）
const POISON_TICK_INTERVAL := 30
const DOG_BLOOD_COOLDOWN := 18         # 防止单帧重复连吃多格黑狗血瞬间蒸发
const WARD_EVENT_COOLDOWN := 60        # 水银界阻挡事件节流（1s）

var entity_id: String = ""
var display_name: String = ""
var faction: String = "enemy"          # "player" / "enemy" / "neutral"
var pos: Vector2 = Vector2.ZERO        # 脚底中心 cell 坐标（与 player.gd 一致）
var half_w: float = 3.0                # 碰撞盒宽 = 2*half_w
var height: float = 10.0               # 碰撞盒高 = [pos.y - height + 1, pos.y]

var max_hp: float = 30.0
var hp: float = 30.0
var alive: bool = true
var color: Color = Color(0.82, 0.34, 0.34)

var tags: Array[String] = []           # spirit / eldritch / paper / undead 等
var weak_to: Dictionary = {}           # damage_type -> float 倍率（无全局五行乘数）
var statuses: Dictionary = {}          # status_name -> {ticks, dps, accum}

var temp_slot_ticks: int = 0           # r-cinnabar-talisman 临时符位剩余 tick（60s = 3600）
var hurt_flash_ticks: int = 0
var _blood_cd: int = 0
var _ward_cd: int = 0

func init_entity(cfg: Dictionary) -> void:
	entity_id = String(cfg.get("id", "entity"))
	display_name = String(cfg.get("name", entity_id))
	faction = String(cfg.get("faction", "enemy"))
	pos = cfg.get("pos", Vector2.ZERO)
	half_w = float(cfg.get("half_w", 3.0))
	height = float(cfg.get("height", 10.0))
	max_hp = maxf(float(cfg.get("max_hp", 30.0)), 1.0)
	hp = float(cfg.get("hp", max_hp))
	alive = hp > 0.0
	color = cfg.get("color", Color(0.82, 0.34, 0.34))
	tags.clear()
	for t in cfg.get("tags", []):
		tags.append(String(t))
	weak_to = {}
	var wt: Variant = cfg.get("weak_to", {})
	if wt is Dictionary:
		var wtd: Dictionary = wt
		for k in wtd.keys():
			weak_to[String(k)] = float(wtd[k])
	statuses.clear()
	temp_slot_ticks = 0
	hurt_flash_ticks = 0
	_blood_cd = 0
	_ward_cd = 0

func center_pos() -> Vector2:
	return Vector2(pos.x, pos.y - height * 0.5)

func cell_pos() -> Vector2i:
	return Vector2i(floori(pos.x), floori(pos.y))

func has_tag(tag: String) -> bool:
	return tags.has(tag)

func has_status(st: String) -> bool:
	return statuses.has(st) and int((statuses[st] as Dictionary).get("ticks", 0)) > 0

func is_stunned() -> bool:
	return has_status("stun")

func speed_multiplier() -> float:
	if is_stunned():
		return 0.0
	if has_status("slow"):
		return 0.5
	return 1.0

func contains_point(p: Vector2, pad: float = 0.0) -> bool:
	if not alive:
		return false
	return (
		p.x >= pos.x - half_w - pad
		and p.x <= pos.x + half_w + pad
		and p.y >= pos.y - height - pad
		and p.y <= pos.y + pad
	)

func distance_to_point(p: Vector2) -> float:
	var cx := clampf(p.x, pos.x - half_w, pos.x + half_w)
	var cy := clampf(p.y, pos.y - height, pos.y)
	return Vector2(p.x - cx, p.y - cy).length()

## 仅按实体自身 weak_to（含抗性 <1.0）计算最终伤害；遵循 data/magic_numbers.json elements.in_damage_formula=false。
func compute_damage(base_amount: float, damage_type: String) -> float:
	if base_amount <= 0.0:
		return 0.0
	var mult: float = float(weak_to.get(damage_type, 1.0))
	return maxf(base_amount * mult, 0.0)

func take_damage(base_amount: float, damage_type: String, source_id: String, tick: int, event_bus) -> float:
	if not alive or base_amount <= 0.0:
		return 0.0
	var final_dmg := compute_damage(base_amount, damage_type)
	if final_dmg <= 0.0:
		return 0.0
	hp = maxf(hp - final_dmg, 0.0)
	hurt_flash_ticks = 12
	if event_bus != null:
		event_bus.publish("entity_damaged", tick, {
			"source_id": source_id,
			"target_id": entity_id,
			"pos": cell_pos(),
			"value": final_dmg,
			"damage_type": damage_type,
		})
	if hp <= 0.0 and alive:
		alive = false
		if event_bus != null:
			event_bus.publish("entity_killed", tick, {
				"source_id": source_id,
				"target_id": entity_id,
				"pos": cell_pos(),
				"value": max_hp,
				"damage_type": damage_type,
			})
	return final_dmg

func heal(amount: float) -> float:
	if not alive or amount <= 0.0:
		return 0.0
	var before := hp
	hp = minf(hp + amount, max_hp)
	return hp - before

func apply_status(status: String, duration_ticks: int, tick: int, event_bus, dps: float = 0.0) -> bool:
	if not alive or duration_ticks <= 0:
		return false
	if status == "wet":
		statuses.erase("burning")
	elif status == "burning" and has_status("wet"):
		return false
	var was_active := has_status(status)
	var eff_dps := dps
	if status == "burning" and eff_dps <= 0.0:
		eff_dps = maxf(max_hp * BURN_DEFAULT_DPS_RATIO, 1.0)
	elif status == "poison" and eff_dps <= 0.0:
		eff_dps = 3.0
	var accum := 0
	if was_active:
		accum = int((statuses[status] as Dictionary).get("accum", 0))
	statuses[status] = {"ticks": duration_ticks, "dps": eff_dps, "accum": accum}
	if not was_active and event_bus != null:
		event_bus.publish("status_applied", tick, {
			"target_id": entity_id,
			"pos": cell_pos(),
			"status": status,
			"value": float(duration_ticks),
			"text_key": "$status_" + status,
		})
	return true

## M1-12 反应 #7（r-quicksilver-ward）：eldritch 标签实体无法越过水银格（不消耗水银）。
func is_blocked_by_quicksilver(sim: SimWorldNode, target_pos: Vector2, tick: int, event_bus, mat_quicksilver: int) -> bool:
	if not alive or not has_tag("eldritch") or sim == null or not sim.has_world() or mat_quicksilver < 0:
		return false
	var cx := floori(target_pos.x)
	var cy := floori(target_pos.y)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var hw := ceili(half_w)
	var hh := ceili(height)
	for gy in range(cy - hh + 1, cy + 1):
		if gy < 0 or gy >= h:
			continue
		for gx in range(cx - hw, cx + hw + 1):
			if gx < 0 or gx >= w:
				continue
			if sim.get_cell(gx, gy) == mat_quicksilver:
				if _ward_cd <= 0 and event_bus != null:
					_ward_cd = WARD_EVENT_COOLDOWN
					event_bus.publish("reaction_triggered", tick, {
						"source_id": "quicksilver",
						"target_id": entity_id,
						"pos": Vector2i(gx, gy),
						"reaction_id": "r-quicksilver-ward",
						"value": 1.0,
						"text_key": "$react_quicksilver_ward",
					})
				return true
	return false

## 每 sim tick 推进：状态持续伤、材质接触状态、以及 r-dog-blood-spirit / r-cinnabar-talisman。
func step_tick(sim: SimWorldNode, tick: int, event_bus, mat_ids: Dictionary) -> void:
	if not alive:
		return
	if hurt_flash_ticks > 0:
		hurt_flash_ticks -= 1
	if _blood_cd > 0:
		_blood_cd -= 1
	if _ward_cd > 0:
		_ward_cd -= 1
	if temp_slot_ticks > 0:
		temp_slot_ticks -= 1

	# 1) 环境格子接触检测
	if sim != null and sim.has_world():
		_sample_environment(sim, tick, event_bus, mat_ids)

	# 2) 状态递减与持续伤结算
	var expired: Array[String] = []
	for k_raw in statuses.keys():
		var st_name: String = String(k_raw)
		var rec: Dictionary = statuses[st_name]
		var rem: int = int(rec.get("ticks", 0)) - 1
		rec["ticks"] = rem
		if st_name == "burning" or st_name == "poison":
			var accum: int = int(rec.get("accum", 0)) + 1
			var interval := BURN_TICK_INTERVAL if st_name == "burning" else POISON_TICK_INTERVAL
			if accum >= interval:
				accum = 0
				var dps: float = float(rec.get("dps", 2.0))
				var dt_sec := float(interval) / 60.0
				var dtype := "火" if st_name == "burning" else "毒"
				take_damage(dps * dt_sec, dtype, st_name, tick, event_bus)
			rec["accum"] = accum
		if rem <= 0:
			expired.append(st_name)
	for st_name in expired:
		statuses.erase(st_name)

func _sample_environment(sim: SimWorldNode, tick: int, event_bus, mat_ids: Dictionary) -> void:
	var cx := floori(pos.x)
	var cy := floori(pos.y)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var hw := ceili(half_w)
	var hh := ceili(height)
	var mat_water: int = int(mat_ids.get("water", -1))
	var mat_fire: int = int(mat_ids.get("fire", -1))
	var mat_toxic: int = int(mat_ids.get("toxic_smoke", -1))
	var mat_blood: int = int(mat_ids.get("black_dog_blood", -1))
	var mat_cinnabar: int = int(mat_ids.get("cinnabar", -1))

	var saw_water := false
	var saw_fire := false
	var saw_toxic := false
	var blood_cell := Vector2i(-1, -1)
	var cinnabar_cell := Vector2i(-1, -1)

	for gy in range(cy - hh + 1, cy + 1):
		if gy < 0 or gy >= h:
			continue
		for gx in range(cx - hw, cx + hw + 1):
			if gx < 0 or gx >= w:
				continue
			var m: int = sim.get_cell(gx, gy)
			if m <= 0:
				continue
			if m == mat_water:
				saw_water = true
			elif m == mat_fire or (sim.get_material_flammable(m) and sim.get_cell_aux(gx, gy) > 0):
				saw_fire = true
			elif m == mat_toxic:
				saw_toxic = true
			elif m == mat_blood and blood_cell.x < 0:
				blood_cell = Vector2i(gx, gy)
			elif m == mat_cinnabar and cinnabar_cell.x < 0:
				cinnabar_cell = Vector2i(gx, gy)

	if saw_water:
		apply_status("wet", 300, tick, event_bus)
	if saw_fire:
		apply_status("burning", 300, tick, event_bus)
	if saw_toxic:
		apply_status("poison", 180, tick, event_bus, 3.0)

	# M1-12 反应 #6：r-dog-blood-spirit（黑狗血 × spirit -> 消耗血，20 阳伤）
	if blood_cell.x >= 0 and has_tag("spirit") and _blood_cd <= 0:
		sim.set_cell(blood_cell.x, blood_cell.y, 0)
		_blood_cd = DOG_BLOOD_COOLDOWN
		var dealt := take_damage(20.0, "阳", "r-dog-blood-spirit", tick, event_bus)
		if event_bus != null:
			event_bus.publish("reaction_triggered", tick, {
				"source_id": "black_dog_blood",
				"target_id": entity_id,
				"pos": blood_cell,
				"reaction_id": "r-dog-blood-spirit",
				"value": dealt,
				"text_key": "$react_dog_blood_spirit",
			})

	# M1-12 反应 #8：r-cinnabar-talisman（朱砂 × paper -> 消耗朱砂，赋予 60s 临时符位 +1）
	if cinnabar_cell.x >= 0 and has_tag("paper"):
		sim.set_cell(cinnabar_cell.x, cinnabar_cell.y, 0)
		temp_slot_ticks = 3600
		if event_bus != null:
			event_bus.publish("reaction_triggered", tick, {
				"source_id": "cinnabar",
				"target_id": entity_id,
				"pos": cinnabar_cell,
				"reaction_id": "r-cinnabar-talisman",
				"value": 1.0,
				"text_key": "$react_cinnabar_talisman",
			})
