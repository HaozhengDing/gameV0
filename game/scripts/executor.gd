extends RefCounted
## T4b 世界层执行器：C-ACT 子集执行（T4B.md §3.1）+ 葫芦吸/喷（§3）+ 火伤害/灭火规则（§3.2）。
## 动作字段契约见 docs/tech/talisman-vm-spec.md §3.2；这里只做灰盒能表现的那部分，
## 其余 op 一律 no-op + print（T4B.md §3.1）。

# 葫芦 / 盏 / 灰盒规则常量
const ABSORB_RADIUS := 6        # E 吸取半径（cells；由 3 调至 6，便于吸取铺开的水面薄层）
const SPRAY_LEN := 12           # Q 喷出长度（T4B.md 给 10-16，灰盒取固定 12）
const SPRAY_ORIGIN_OFFSET_Y := 4 # 喷水起点上移至胸口，避免站地板时撞地并覆盖整面火墙
const WATER_CAP := 200
const OIL_CAP := 100
const LANTERNS_MAX := 7
const HAZARD_INTERVAL_TICKS := 30   # 每 0.5s（60 tick/s）结算直接触火气血伤
const DIRECT_FIRE_DAMAGE := 12.0    # 直接触火每 0.5s 扣 12 气血
const BURN_DOT_INTERVAL := 30       # 离火后灼烧每 0.5s 扣 1.0 气血（2% max HP/s）
const BURN_DOT_DAMAGE := 1.0
const POISON_DOT_INTERVAL := 30     # 毒烟中毒每 0.5s 扣 1.5 气血（3 HP/s）
const POISON_DOT_DAMAGE := 1.5
const YIN_QI_INTERVAL := 60         # 阴气侵蚀每 1.0s 熄 0.3 盏魄灯（S-0004：0.2–0.5 盏）
const YIN_QI_LANTERN_LOSS := 0.3
const BODY_HALF_W := 2              # 与 player.gd 身体碰撞盒一致（x ±2, y -9..0）
const BODY_HEIGHT := 10
const IGNITE_RADIUS := 3            # ignite op 半径（调用 C-SIM v3 apply_heat_burst）
const EXPLODE_IGNITE_MARGIN := 4    # explode 挖坑后额外对坑缘施加 400°C 热冲击
const MANUAL_IGNITE_RADIUS := 3     # F 手动点火热冲击半径
const HEAT_BURST_TEMP := 400.0      # 热冲击温度（触发黑火药/硫磺毒烟/可燃物点燃）
const BURNING_DURATION_TICKS := 300 # 灼烧持续 5s（60Hz，见 data/magic_numbers.json fire_heat）
const WET_DURATION_TICKS := 300     # 湿润持续 5s（免疫点燃且立刻灭灼烧）
const POISON_DURATION_TICKS := 180  # 中毒持续 3s（接触毒烟触发）
const MAX_ACTION_DEPTH := 4

var sim: SimWorldNode
var vm: TalismanVMNode
var level
var player
var hud
var event_bus
var text_db
var combat
var vitals
var wand_manager

# 葫芦 / 实体状态 / 施法反馈（气血与七星灯由 vitals 管理）
var gourd_water := 0
var gourd_oil := 0
var current_liquid := "water"
var damage_ticks := 0
var burning_ticks := 0
var wet_ticks := 0
var poison_ticks := 0
var _burn_dot_ticks := 0
var _poison_dot_ticks := 0
var _yin_ticks := 0
var last_cast_status := "待命"

# 组合统计（HUD/smoke 用）
var combo_water_converted := 0
var combo_fire_doused := 0

var mat_empty := 0
var mat_water := 3
var mat_oil := 4
var mat_fire := 6
var mat_yin_qi := 15
var mat_toxic_smoke := 17

func setup(p_sim: SimWorldNode, p_vm: TalismanVMNode, p_level, p_player, p_hud,
		p_event_bus = null, p_text_db = null, p_combat = null, p_vitals = null, p_wand_manager = null) -> void:
	sim = p_sim
	vm = p_vm
	level = p_level
	player = p_player
	hud = p_hud
	event_bus = p_event_bus
	text_db = p_text_db
	combat = p_combat
	vitals = p_vitals
	wand_manager = p_wand_manager
	_cache_material_ids()

func _cache_material_ids() -> void:
	if sim == null or not sim.has_world():
		return
	mat_empty = 0
	mat_water = sim.material_id("water")
	mat_oil = sim.material_id("oil")
	mat_fire = sim.material_id("fire")
	mat_yin_qi = sim.material_id("yin_qi")
	mat_toxic_smoke = sim.material_id("toxic_smoke")
	if mat_water < 0 or mat_oil < 0 or mat_fire < 0:
		push_error("T4B executor: C-SIM 材质表缺少 water/oil/fire（需要 C-SIM v3）")

func reset_round() -> void:
	gourd_water = 0
	gourd_oil = 0
	current_liquid = "water"
	damage_ticks = 0
	burning_ticks = 0
	wet_ticks = 0
	poison_ticks = 0
	_burn_dot_ticks = 0
	_poison_dot_ticks = 0
	_yin_ticks = 0
	last_cast_status = "待命"
	combo_water_converted = 0
	combo_fire_doused = 0
	if vitals != null:
		vitals.reset()

# ------------------------------------------------------------------ 葫芦

func gourd_amount() -> int:
	return gourd_water if current_liquid == "water" else gourd_oil

func gourd_cap() -> int:
	return WATER_CAP if current_liquid == "water" else OIL_CAP

func toggle_liquid() -> void:
	current_liquid = "oil" if current_liquid == "water" else "water"
	_log("切至%s %d/%d" % [_liquid_cn(), gourd_amount(), gourd_cap()])

## E：吸取鼠标周围半径 3 的 water / oil，分别存进葫芦（水 200、油 100）。
func absorb(center: Vector2i) -> int:
	var got_water := 0
	var got_oil := 0
	var r := ABSORB_RADIUS
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			var m: int = sim.get_cell(x, y)
			if m == mat_water and gourd_water < WATER_CAP:
				sim.set_cell(x, y, mat_empty)
				gourd_water += 1
				got_water += 1
			elif m == mat_oil and gourd_oil < OIL_CAP:
				sim.set_cell(x, y, mat_empty)
				gourd_oil += 1
				got_oil += 1
	if got_water > 0:
		_log("取水 %d" % got_water)
	if got_oil > 0:
		_log("取油 %d" % got_oil)
	if got_water == 0 and got_oil == 0:
		_log("附近没有水/油")
	return got_water + got_oil

## Q：从玩家胸口沿 玩家->鼠标 方向铺 10-16 格（灰盒固定 12 格，遇实心墙停止），每格耗 1；
## 仅喷水时交给 level.douse_fire_around() 灭火（喷油不灭火，反而可借邻火助燃）。
func spray(player_cell: Vector2i, aim_cell: Vector2i) -> Dictionary:
	var origin_cell := Vector2i(player_cell.x, maxi(player_cell.y - SPRAY_ORIGIN_OFFSET_Y, 0))
	var out := {"placed": 0, "doused": 0, "from": origin_cell, "to": origin_cell, "liquid": current_liquid}
	var amount := gourd_amount()
	if amount <= 0:
		_log("葫芦里没有%s（Tab 切换水/油）" % _liquid_cn())
		return out
	var dir := Vector2(float(aim_cell.x - origin_cell.x), float(aim_cell.y - origin_cell.y))
	if dir.length() < 0.01:
		dir = _player_facing()
	dir = dir.normalized()
	var liquid_id := mat_water if current_liquid == "water" else mat_oil
	var length := mini(SPRAY_LEN, amount)
	var cells: Array = []
	var placed := 0
	var last_cell := origin_cell
	for i in range(1, length + 1):
		var p: Vector2 = Vector2(origin_cell) + dir * float(i)
		var c := Vector2i(roundi(p.x), roundi(p.y))
		if c.x < 0 or c.y < 0 or c.x >= sim.get_world_width() or c.y >= sim.get_world_height():
			break
		if cells.has(c):
			continue
		if sim.is_solid(c.x, c.y):
			break
		var m: int = sim.get_cell(c.x, c.y)
		if m != liquid_id:
			sim.set_cell(c.x, c.y, liquid_id)
			placed += 1
			if current_liquid == "water":
				gourd_water -= 1
			else:
				gourd_oil -= 1
		cells.append(c)
		last_cell = c
	out["placed"] = placed
	out["to"] = last_cell
	_log("喷%s %d 格" % [_liquid_cn(), placed])
	if not cells.is_empty():
		if current_liquid == "water":
			var doused: int = level.douse_fire_around(cells)
			if doused > 0:
				combo_fire_doused += doused
				out["doused"] = doused
				_log("灭火 %d 格" % doused)
	return out

## F：手动点火（M1-12 接真 C-SIM v3 apply_heat_burst）：
## 优先向瞄准点施加 400°C 热冲击（触发黑火药/硫磺毒烟/可燃物点燃）；若无受热材质则在空地放下小火种。
func manual_ignite(aim: Vector2i) -> int:
	if sim == null or not sim.has_world():
		return 0
	var summary := {"ignited": 0}
	_ignite_around(aim, MANUAL_IGNITE_RADIUS, summary)
	var count: int = int(summary["ignited"])
	if count == 0:
		var w := sim.get_world_width()
		var h := sim.get_world_height()
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx * dx + dy * dy > 1:
					continue
				var x := aim.x + dx
				var y := aim.y + dy
				if x < 0 or y < 0 or x >= w or y >= h:
					continue
				if sim.get_cell(x, y) == mat_empty:
					sim.set_cell(x, y, mat_fire)
					count += 1
	if count > 0:
		sim.wake_rect(aim.x - 6, aim.y - 6, 13, 13)
		_log("点火 %d" % count)
	else:
		_log("此处无法点火")
	return count

func _liquid_cn() -> String:
	return "水" if current_liquid == "water" else "油"

func _player_facing() -> Vector2:
	if player != null:
		var f: Vector2 = player.facing
		return f
	return Vector2.RIGHT

# ------------------------------------------------------------------ 实体状态与环境伤害（M1-12）

## 返回当前激活的状态列表（HUD 状态徽章用），按显示优先级排序。
func get_active_statuses() -> Array[String]:
	var list: Array[String] = []
	if burning_ticks > 0:
		list.append("burning")
	if wet_ticks > 0:
		list.append("wet")
	if poison_ticks > 0:
		list.append("poison")
	return list

## 每 tick 调用：结算 湿润 / 灼烧 / 中毒 状态，及直接触火/持续伤盏。
## 返回 true 表示盏尽（main.gd 负责把玩家送回起点并复原盏）。
func tick_hazards(player_cell: Vector2i) -> bool:
	var tick: int = sim.get_tick() if (sim != null and sim.has_world()) else 0

	# 1) 浸水：立即熄灭灼烧并赋予 5s 湿润保护
	if is_in_water(player_cell):
		if burning_ticks > 0:
			burning_ticks = 0
			_burn_dot_ticks = 0
			_log("沾水灭火")
		if wet_ticks == 0 and event_bus != null:
			event_bus.publish("status_applied", tick, {
				"target_id": "player", "pos": player_cell, "status": "wet",
				"value": float(WET_DURATION_TICKS), "text_key": "$status_wet",
			})
		wet_ticks = WET_DURATION_TICKS
	elif wet_ticks > 0:
		wet_ticks -= 1

	# 2) 毒烟接触：赋予 3s 中毒状态
	if is_in_toxic_smoke(player_cell):
		if poison_ticks == 0 and event_bus != null:
			event_bus.publish("status_applied", tick, {
				"target_id": "player", "pos": player_cell, "status": "poison",
				"value": float(POISON_DURATION_TICKS), "text_key": "$status_poison",
			})
		poison_ticks = POISON_DURATION_TICKS
	elif poison_ticks > 0:
		poison_ticks -= 1

	# 3) 接触明火 / 燃烧中的煤、硫、竹木（扣气血，不直接熄灯）
	var near_fire := is_near_fire(player_cell)
	if near_fire:
		if wet_ticks <= 0:
			if burning_ticks == 0 and event_bus != null:
				event_bus.publish("status_applied", tick, {
					"target_id": "player", "pos": player_cell, "status": "burning",
					"value": float(BURNING_DURATION_TICKS), "text_key": "$status_burning",
				})
			burning_ticks = BURNING_DURATION_TICKS
		damage_ticks += 1
		if damage_ticks >= HAZARD_INTERVAL_TICKS:
			damage_ticks = 0
			if _apply_hp_loss(DIRECT_FIRE_DAMAGE, "火", "火伤", "$ui_death_fire", tick):
				return true
	else:
		damage_ticks = 0
		if burning_ticks > 0:
			burning_ticks -= 1
			_burn_dot_ticks += 1
			if _burn_dot_ticks >= BURN_DOT_INTERVAL:
				_burn_dot_ticks = 0
				if _apply_hp_loss(BURN_DOT_DAMAGE, "火", "灼烧", "$ui_death_fire", tick):
					return true
		else:
			_burn_dot_ticks = 0

	# 4) 毒烟持续伤气血
	if poison_ticks > 0:
		_poison_dot_ticks += 1
		if _poison_dot_ticks >= POISON_DOT_INTERVAL:
			_poison_dot_ticks = 0
			if _apply_hp_loss(POISON_DOT_DAMAGE, "毒", "毒烟", "$ui_death_poison", tick):
				return true
	else:
		_poison_dot_ticks = 0

	# 5) 接触阴气：阴性伤害直接熄魄灯（每 1s 熄 0.3 盏，跨整盏压低气血上限）
	if is_in_yin_qi(player_cell):
		_yin_ticks += 1
		if _yin_ticks >= YIN_QI_INTERVAL:
			_yin_ticks = 0
			if _apply_yin_lantern_loss(YIN_QI_LANTERN_LOSS, "阴气", tick):
				return true
	else:
		_yin_ticks = 0

	return false

func _apply_hp_loss(amount: float, damage_type: String, source_label: String, death_key: String, tick: int) -> bool:
	if vitals == null:
		return false
	var res: Dictionary = vitals.take_hp_damage(amount, damage_type, source_label, tick, event_bus, death_key)
	if player != null and player.has_method("trigger_hurt_flash"):
		player.trigger_hurt_flash()
	if bool(res.get("dead", false)):
		var cause: String = text_db.get_text(death_key) if (text_db != null and text_db.has_key(death_key)) else source_label
		_log(cause)
		_reset_on_death()
		return true
	return false

func _apply_yin_lantern_loss(amount: float, source_label: String, tick: int) -> bool:
	if vitals == null:
		return false
	var res: Dictionary = vitals.extinguish_lanterns(amount, source_label, tick, event_bus)
	if player != null and player.has_method("trigger_hurt_flash"):
		player.trigger_hurt_flash()
	if int(res.get("full_lost", 0)) > 0:
		_log("魄灯熄灭（%.1f/7）" % vitals.lanterns)
	if bool(res.get("dead", false)):
		_log("七灯尽熄")
		_reset_on_death()
		return true
	return false

func _reset_on_death() -> void:
	if vitals != null:
		vitals.reset()
	burning_ticks = 0
	wet_ticks = 0
	poison_ticks = 0
	_burn_dot_ticks = 0
	_poison_dot_ticks = 0
	_yin_ticks = 0

func is_in_yin_qi(center: Vector2i) -> bool:
	if mat_yin_qi < 0:
		return false
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-BODY_HEIGHT + 1, 1):
		var y := center.y + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-BODY_HALF_W, BODY_HALF_W + 1):
			var x := center.x + dx
			if x < 0 or x >= w:
				continue
			if sim.get_cell(x, y) == mat_yin_qi:
				return true
	return false

func is_near_fire(center: Vector2i) -> bool:
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-BODY_HEIGHT, 2):
		var y := center.y + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-BODY_HALF_W - 1, BODY_HALF_W + 2):
			var x := center.x + dx
			if x < 0 or x >= w:
				continue
			var m: int = sim.get_cell(x, y)
			if m == mat_fire:
				return true
			if m > 0 and sim.get_material_flammable(m) and sim.get_cell_aux(x, y) > 0:
				return true
	return false

func is_in_water(center: Vector2i) -> bool:
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-BODY_HEIGHT + 1, 1):
		var y := center.y + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-BODY_HALF_W, BODY_HALF_W + 1):
			var x := center.x + dx
			if x < 0 or x >= w:
				continue
			if sim.get_cell(x, y) == mat_water:
				return true
	return false

func is_in_toxic_smoke(center: Vector2i) -> bool:
	if mat_toxic_smoke < 0:
		return false
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-BODY_HEIGHT + 1, 1):
		var y := center.y + dy
		if y < 0 or y >= h:
			continue
		for dx in range(-BODY_HALF_W, BODY_HALF_W + 1):
			var x := center.x + dx
			if x < 0 or x >= w:
				continue
			if sim.get_cell(x, y) == mat_toxic_smoke:
				return true
	return false

# ------------------------------------------------------------------ C-ACT 执行（M1-02 真实投射物与战斗）

## 施放符组并通过 CombatManager 发射真实投射物或执行即时动作；返回发射统计。
func cast(group_id: String, aim: Vector2i) -> Dictionary:
	var summary := {
		"accepted": false,
		"reject_reason": "",
		"actions": 0,
		"projectiles": 0,
		"dug": 0,
		"converted": 0,
		"converted_to_water": 0,
		"ignited": 0,
		"spawned": 0,
	}
	if sim == null or vm == null or combat == null:
		return summary
	var result: Dictionary = vm.cast_group(group_id)
	var accepted: bool = bool(result.get("accepted", false))
	summary["accepted"] = accepted
	var reason: String = String(result.get("reject_reason", ""))
	summary["reject_reason"] = reason
	if not accepted:
		last_cast_status = _reason_cn(reason)
		if reason != "recharging":
			_log(last_cast_status)
		return summary
	var events: Array = result.get("events", [])
	var tick: int = sim.get_tick() if sim.has_world() else 0
	if events.has("fizzle_no_spirit"):
		last_cast_status = "法力不足"
		if event_bus != null:
			event_bus.publish("spell_fizzle", tick, {"source_id": "player", "group_id": group_id, "reason": "no_spirit"})
		_log(last_cast_status)
		return summary
	var actions: Array = result.get("actions", [])
	summary["actions"] = actions.size()
	var origin := Vector2(float(aim.x), float(aim.y))
	var dir := _player_facing()
	if player != null:
		var pc: Vector2i = player.cell_pos()
		origin = Vector2(float(pc.x), float(maxi(pc.y - SPRAY_ORIGIN_OFFSET_Y, 0)))
		var delta := Vector2(float(aim.x) - origin.x, float(aim.y) - origin.y)
		if delta.length() > 0.01:
			dir = delta.normalized()
	if event_bus != null:
		event_bus.publish("spell_cast", tick, {
			"source_id": "player", "group_id": group_id,
			"pos": Vector2i(floori(origin.x), floori(origin.y)),
			"value": float(actions.size()),
		})
	var exec_res: Dictionary = combat.execute_actions(actions, origin, dir, "player", "player")
	summary["projectiles"] = int(exec_res.get("projectiles", 0))
	summary["dug"] = int(exec_res.get("dug", 0))
	summary["converted"] = int(exec_res.get("converted", 0))
	summary["converted_to_water"] = int(exec_res.get("converted_to_water", 0))
	summary["ignited"] = int(exec_res.get("ignited", 0))
	summary["spawned"] = int(exec_res.get("spawned", 0))
	last_cast_status = "ok"
	return summary

func _reason_cn(reason: String) -> String:
	match reason:
		"recharging":
			return "回符中"
		"cast_interval":
			return "冷却中"
		"empty_deck":
			return "空槽"
		"no_cards":
			return "符卡未加载"
		"unknown_group":
			return "未知符槽"
		_:
			return reason

## M1-03：按当前法器真游标与真牌堆施法（成文/散符/多句/禁符反噬/朱砂临时位）。
func cast_active_wand(aim: Vector2i, sanity: int = 100, backlash: bool = false,
		phantom_slots: Array = [], rng_cfg: Dictionary = {}) -> Dictionary:
	var summary := {
		"accepted": false,
		"reject_reason": "",
		"actions": 0,
		"projectiles": 0,
		"consumed": [],
		"cursor_after": 0,
		"round_ended": false,
		"max_depth": 0,
		"events": [],
	}
	if sim == null or vm == null or combat == null or wand_manager == null:
		return summary
	var tick: int = sim.get_tick() if sim.has_world() else 0
	var temp_slot: bool = combat.get_temp_slot_ticks() > 0
	var result: Dictionary = wand_manager.cast_active(vm, tick, temp_slot, sanity, backlash, phantom_slots, rng_cfg)
	var accepted: bool = bool(result.get("accepted", false))
	summary["accepted"] = accepted
	var reason: String = String(result.get("reject_reason", ""))
	summary["reject_reason"] = reason
	if not accepted:
		last_cast_status = _reason_cn(reason)
		if reason != "recharging" and reason != "cast_interval":
			_log(last_cast_status)
		return summary
	var events: Array = result.get("events", [])
	summary["events"] = events
	summary["consumed"] = result.get("consumed", [])
	summary["cursor_after"] = int(result.get("cursor_after", 0))
	summary["round_ended"] = bool(result.get("round_ended", false))
	summary["max_depth"] = int(result.get("max_depth", 0))
	if events.has("fizzle_no_spirit"):
		last_cast_status = "法力不足"
		if event_bus != null:
			event_bus.publish("spell_fizzle", tick, {"source_id": "player", "reason": "no_spirit"})
		_log(last_cast_status)
		return summary
	var actions: Array = result.get("actions", [])
	summary["actions"] = actions.size()
	var origin := Vector2(float(aim.x), float(aim.y))
	var dir := _player_facing()
	if player != null:
		var pc: Vector2i = player.cell_pos()
		origin = Vector2(float(pc.x), float(maxi(pc.y - SPRAY_ORIGIN_OFFSET_Y, 0)))
		var delta := Vector2(float(aim.x) - origin.x, float(aim.y) - origin.y)
		if delta.length() > 0.01:
			dir = delta.normalized()
	if event_bus != null:
		var w: Dictionary = wand_manager.active_wand()
		event_bus.publish("spell_cast", tick, {
			"source_id": "player", "wand_id": String(w.get("id", "")),
			"pos": Vector2i(floori(origin.x), floori(origin.y)),
			"value": float(actions.size()),
		})
	var exec_res: Dictionary = combat.execute_actions(actions, origin, dir, "player", "player")
	summary["projectiles"] = int(exec_res.get("projectiles", 0))
	last_cast_status = "ok"
	return summary

func _ignite_around(center: Vector2i, radius: int, summary: Dictionary) -> void:
	var r := maxi(radius, 0)
	var affected: int = sim.apply_heat_burst(center.x, center.y, r, HEAT_BURST_TEMP)
	if affected > 0:
		summary["ignited"] = int(summary["ignited"]) + affected

func _log(text: String) -> void:
	if hud != null:
		hud.log_event(text)
