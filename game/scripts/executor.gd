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
const HAZARD_INTERVAL_TICKS := 30   # 每 0.5s（60 tick/s）掉 1 盏
const BODY_HALF_W := 2              # 与 player.gd 身体碰撞盒一致（x ±2, y -9..0）
const BODY_HEIGHT := 10
const IGNITE_RADIUS := 2            # ignite op 固定半径（T4B.md §3.1）
const EXPLODE_IGNITE_MARGIN := 3    # explode 挖坑后额外引燃坑缘可燃物
const MANUAL_IGNITE_RADIUS := 3     # F 手动点火半径（灰盒火焰补丁）
const MAX_ACTION_DEPTH := 4

var sim: SimWorldNode
var vm: TalismanVMNode
var level
var player
var hud

# 葫芦 / 盏 / 施法反馈
var gourd_water := 0
var gourd_oil := 0
var current_liquid := "water"
var lanterns := LANTERNS_MAX
var damage_ticks := 0
var last_cast_status := "待命"

# 组合统计（HUD/smoke 用）
var combo_water_converted := 0
var combo_fire_doused := 0

var mat_empty := 0
var mat_water := 3
var mat_oil := 4
var mat_fire := 6

func setup(p_sim: SimWorldNode, p_vm: TalismanVMNode, p_level, p_player, p_hud) -> void:
	sim = p_sim
	vm = p_vm
	level = p_level
	player = p_player
	hud = p_hud
	_cache_material_ids()

func _cache_material_ids() -> void:
	if sim == null or not sim.has_world():
		return
	mat_empty = 0
	mat_water = sim.material_id("water")
	mat_oil = sim.material_id("oil")
	mat_fire = sim.material_id("fire")
	if mat_water < 0 or mat_oil < 0 or mat_fire < 0:
		push_error("T4B executor: C-SIM 材质表缺少 water/oil/fire（需要 C-SIM v2）")

func reset_round() -> void:
	gourd_water = 0
	gourd_oil = 0
	current_liquid = "water"
	lanterns = LANTERNS_MAX
	damage_ticks = 0
	last_cast_status = "待命"
	combo_water_converted = 0
	combo_fire_doused = 0

# ------------------------------------------------------------------ 葫芦

func gourd_amount() -> int:
	return gourd_water if current_liquid == "water" else gourd_oil

func gourd_cap() -> int:
	return WATER_CAP if current_liquid == "water" else OIL_CAP

func toggle_liquid() -> void:
	current_liquid = "oil" if current_liquid == "water" else "water"
	_log("切换液体：%s（%d/%d）" % [_liquid_cn(), gourd_amount(), gourd_cap()])

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
		else:
			_track_adjacent_fire(cells)
	return out

## 喷油时若油线接触既有火焰，登记该火格，使油引信燃到煤/硫/竹木时灰盒补丁能继续蔓延。
func _track_adjacent_fire(cells: Array) -> void:
	if level == null:
		return
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for raw_c in cells:
		var c: Vector2i = raw_c
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nx := c.x + dx
				var ny := c.y + dy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if sim.get_cell(nx, ny) == mat_fire:
					level.register_fire_cell(nx, ny)

## F：手动点火（灰盒火焰补丁 ②，docs/tech/sim-fire-heat-design.md §5）：
## 优先点燃瞄准点周围可燃物（油/煤/硫磺/竹木）；若无直接可燃物则在空地放下小火种（半径 1）。
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
					if level != null:
						level.register_fire_cell(x, y)
					count += 1
	if count > 0:
		sim.wake_rect(aim.x - 4, aim.y - 4, 9, 9)
		_log("手动点火 %d 格" % count)
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

# ------------------------------------------------------------------ 火伤害（§3.2）

## 每 tick 调用：玩家身体盒（5x10）或其外扩 1 格边界接触火 -> 每 30 tick（0.5s）掉 1 盏。
## 返回 true 表示盏尽（main.gd 负责把玩家送回起点并复原盏）。
func tick_hazards(player_cell: Vector2i) -> bool:
	if not is_near_fire(player_cell):
		damage_ticks = 0
		return false
	damage_ticks += 1
	if damage_ticks < HAZARD_INTERVAL_TICKS:
		return false
	damage_ticks = 0
	lanterns -= 1
	if player != null and player.has_method("trigger_hurt_flash"):
		player.trigger_hurt_flash()
	_log("火伤 −1 盏（余 %d/%d）" % [lanterns, LANTERNS_MAX])
	if lanterns <= 0:
		lanterns = LANTERNS_MAX
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
			if sim.get_cell(x, y) == mat_fire:
				return true
	return false

# ------------------------------------------------------------------ C-ACT 执行（§3.1）

## 施放符组并执行返回的 C-ACT 动作；返回本发动作对世界的影响统计（smoke 断言用）。
func cast(group_id: String, aim: Vector2i) -> Dictionary:
	var summary := {
		"accepted": false,
		"reject_reason": "",
		"actions": 0,
		"dug": 0,
		"converted": 0,
		"converted_to_water": 0,
		"ignited": 0,
		"spawned": 0,
		"noop": [],
	}
	if sim == null or vm == null:
		return summary
	var result: Dictionary = vm.cast_group(group_id)
	var accepted: bool = bool(result.get("accepted", false))
	summary["accepted"] = accepted
	var reason: String = String(result.get("reject_reason", ""))
	summary["reject_reason"] = reason
	if not accepted:
		last_cast_status = "施法失败：%s" % _reason_cn(reason)
		_log(last_cast_status)
		return summary
	var events: Array = result.get("events", [])
	if events.has("fizzle_no_spirit"):
		last_cast_status = "灵力不足（本句不念）"
		_log(last_cast_status)
		return summary
	var actions: Array = result.get("actions", [])
	summary["actions"] = actions.size()
	for action in actions:
		if action is Dictionary:
			var action_dict: Dictionary = action
			_execute_action(action_dict, aim, summary, 0)
	var converted_water: int = int(summary["converted_to_water"])
	var ignited: int = int(summary["ignited"])
	var dug: int = int(summary["dug"])
	var noops: Array = summary["noop"]
	if ignited > 0:
		_log("点燃 %d 格" % ignited)
	if dug > 0:
		_log("挖掘 %d 格" % dug)
	if converted_water > 0:
		combo_water_converted += converted_water
		_log("化水成功 %d 格" % converted_water)
	if converted_water == 0 and ignited == 0 and dug == 0 and int(summary["spawned"]) == 0 and not noops.is_empty():
		_log("施放 %s（灰盒无敌人，仅验证接口）" % group_id)
	last_cast_status = "施放 %s（灵力 %.0f/%.0f）" % [group_id, vm.get_spirit(), vm.get_spirit_max()]
	return summary

func _reason_cn(reason: String) -> String:
	match reason:
		"recharging":
			return "回符中"
		"empty_deck":
			return "无牌可念"
		"no_cards":
			return "符卡未加载"
		"unknown_group":
			return "未知符组"
		_:
			return reason

func _execute_action(action: Dictionary, aim: Vector2i, summary: Dictionary, depth: int) -> void:
	if depth > MAX_ACTION_DEPTH:
		return
	var op: String = String(action.get("op", ""))
	match op:
		"spawn_projectile":
			# T4b：不做投射物实体，在瞄准点即时命中 —— 先 payloads，再 trigger.actions
			for payload in _as_array(action.get("payloads", [])):
				if payload is Dictionary:
					var payload_dict: Dictionary = payload
					_execute_action(payload_dict, aim, summary, depth + 1)
			var trigger: Variant = action.get("trigger")
			if trigger is Dictionary:
				var trigger_dict: Dictionary = trigger
				for payload in _as_array(trigger_dict.get("actions", [])):
					if payload is Dictionary:
						var trigger_payload: Dictionary = payload
						_execute_action(trigger_payload, aim, summary, depth + 1)
			return
		"explode":
			var radius: int = int(action.get("radius", 20))
			summary["dug"] = int(summary["dug"]) + sim.dig(aim.x, aim.y, radius)
			# 挖坑后可燃固体/粉末已被清出半径内，外扩 EXPLODE_IGNITE_MARGIN 以点燃坑缘煤/硫/竹木
			_ignite_around(aim, radius + EXPLODE_IGNITE_MARGIN, summary)
			return
		"ignite":
			_ignite_around(aim, IGNITE_RADIUS, summary)
			return
		"convert_material":
			_convert_around(aim, int(action.get("radius", 1)), String(action.get("to", "")), summary)
			return
		"dig":
			summary["dug"] = int(summary["dug"]) + sim.dig(aim.x, aim.y, int(action.get("radius", 2)))
			return
		"spawn_material":
			_spawn_material_around(aim, int(action.get("radius", 1)), String(action.get("material", "")), summary)
			return
		"refund_spirit":
			# VM 已内部结算（talisman-vm-spec §3.2），世界层忽略
			return
		"phantom_cast":
			# 幻符动作按同一规则递归：先 effect，再 payloads
			var effect: Variant = action.get("effect")
			if effect is Dictionary:
				var effect_dict: Dictionary = effect
				_execute_action(effect_dict, aim, summary, depth + 1)
			for payload in _as_array(action.get("payloads", [])):
				if payload is Dictionary:
					var phantom_payload: Dictionary = payload
					_execute_action(phantom_payload, aim, summary, depth + 1)
			return
		_:
			# T4b 无敌人/状态：damage/apply_status/drain_life/extinguish_lantern/barrier/
			# purify/spawn_cloud/grant_temp_slot 一律 no-op + print（T4B.md §3.1）
			_noop(op, summary)

func _ignite_around(center: Vector2i, radius: int, summary: Dictionary) -> void:
	var r := maxi(radius, 0)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			var m: int = sim.get_cell(x, y)
			if m == mat_empty:
				continue
			if sim.get_material_flammable(m):
				sim.set_cell(x, y, mat_fire)
				if level != null:
					level.register_fire_cell(x, y)
				summary["ignited"] = int(summary["ignited"]) + 1

## convert_material：瞄准点 radius 内「非静态、非空」的格转为目标材质（静态岩层不动）。
func _convert_around(center: Vector2i, radius: int, to_name: String, summary: Dictionary) -> void:
	var target: int = sim.material_id(to_name)
	if target < 0:
		_noop("convert_material(to=%s 不在 C-SIM v2)" % to_name, summary)
		return
	var r := maxi(radius, 0)
	var converted := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			var m: int = sim.get_cell(x, y)
			if m == mat_empty or m == target:
				continue
			var state: int = sim.get_material_state(m)
			if state < 0 or state == 4:   # 4 = SIM_STATE_STATIC
				continue
			sim.set_cell(x, y, target)
			converted += 1
	if converted > 0:
		summary["converted"] = int(summary["converted"]) + converted
		if target == mat_water:
			summary["converted_to_water"] = int(summary["converted_to_water"]) + converted

## spawn_material：形状 pool/solid 简化为圆形填充；只接受 C-SIM v2 有的材质。
func _spawn_material_around(center: Vector2i, radius: int, mat_name: String, summary: Dictionary) -> void:
	var target: int = sim.material_id(mat_name)
	if target < 0:
		_noop("spawn_material(%s 不在 C-SIM v2)" % mat_name, summary)
		return
	var r := maxi(radius, 1)
	var spawned := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= sim.get_world_width() or y >= sim.get_world_height():
				continue
			if sim.get_cell(x, y) == mat_empty:
				sim.set_cell(x, y, target)
				spawned += 1
	summary["spawned"] = int(summary["spawned"]) + spawned

func _noop(op: String, summary: Dictionary) -> void:
	print("T4B_ACTION_NOOP op=" + op)
	var list: Array = summary["noop"]
	list.append(op)

func _as_array(value: Variant) -> Array:
	if value is Array:
		var array_value: Array = value
		return array_value
	return []

func _log(text: String) -> void:
	if hud != null:
		hud.log_event(text)
