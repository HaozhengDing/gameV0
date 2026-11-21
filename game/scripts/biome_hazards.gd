extends RefCounted
## M1-04 矿井一层三大 Hazard（对齐 data/biomes/level-01-coalmine.json hazards）：
## 1) gas_explosion：底层由 C-SIM v3 r-black-powder 原生结算（硝+硫+煤遇热 ≥ 120°C 爆炸）；
## 2) quicksilver_no_regen：浸入水银时暂停法器回灵，发布 hazard_triggered；
## 3) collapse：180 tick（3s）内挖掘格数 ≥ 600 时触发矿顶落石塌方（掉落沙+煤碎屑、上方正下受伤 15 HP，发布 hazard_triggered）。

const COLLAPSE_WINDOW_TICKS := 180
const COLLAPSE_DIG_THRESHOLD := 600
const COLLAPSE_COOLDOWN_TICKS := 300
const COLLAPSE_DAMAGE := 15.0
const QUICKSILVER_EVT_COOLDOWN := 180

var sim: SimWorldNode
var event_bus
var vitals
var text_db
var hud

var _dig_samples: Array[Dictionary] = []   # [{tick, amount, pos}]
var _last_collapse_tick: int = -9999
var _last_qs_evt_tick: int = -9999
var collapse_count: int = 0
var quicksilver_block_active: bool = false

func setup(p_sim: SimWorldNode, p_event_bus, p_vitals, p_text_db = null, p_hud = null) -> void:
	sim = p_sim
	event_bus = p_event_bus
	vitals = p_vitals
	text_db = p_text_db
	hud = p_hud
	reset()

func reset() -> void:
	_dig_samples.clear()
	_last_collapse_tick = -9999
	_last_qs_evt_tick = -9999
	collapse_count = 0
	quicksilver_block_active = false

## 订阅 EventBus 回调：记录最近 3 秒内的挖掘量，超阈值立即引发矿顶塌方。
func on_event(ev: Dictionary, player_cell: Vector2i) -> void:
	if String(ev.get("type", "")) != "terrain_dug":
		return
	var tick: int = int(ev.get("tick", 0))
	var amount: int = roundi(float(ev.get("value", 0.0)))
	if amount <= 0:
		return
	var pos: Vector2i = ev.get("pos", player_cell) if ev.get("pos") is Vector2i else player_cell
	_dig_samples.append({"tick": tick, "amount": amount, "pos": pos})
	_prune_dig_window(tick)
	if tick - _last_collapse_tick < COLLAPSE_COOLDOWN_TICKS:
		return
	var total := 0
	for s in _dig_samples:
		total += int(s["amount"])
	if total >= COLLAPSE_DIG_THRESHOLD:
		_trigger_collapse(pos, player_cell, tick)

func _prune_dig_window(tick: int) -> void:
	var kept: Array[Dictionary] = []
	for s in _dig_samples:
		if tick - int(s["tick"]) <= COLLAPSE_WINDOW_TICKS:
			kept.append(s)
	_dig_samples = kept

func _trigger_collapse(dig_pos: Vector2i, player_cell: Vector2i, tick: int) -> void:
	_last_collapse_tick = tick
	_dig_samples.clear()
	collapse_count += 1
	# 在挖掘点上方撒落沙石与煤块碎屑（C-SIM v3 粉末自动下落）
	if sim != null and sim.has_world():
		var sand_id: int = sim.material_id("sand")
		var coal_id: int = sim.material_id("coal")
		var w := sim.get_world_width()
		var h := sim.get_world_height()
		var drop_y := maxi(dig_pos.y - 18, 2)
		for dy in range(0, 5):
			for dx in range(-12, 13):
				var x := dig_pos.x + dx
				var y := drop_y + dy
				if x <= 0 or y <= 0 or x >= w - 1 or y >= h - 1:
					continue
				if sim.get_cell(x, y) == 0 and ((dx + dy) & 1) == 0:
					sim.set_cell(x, y, coal_id if ((dx * 3 + dy) % 5 == 0 and coal_id > 0) else sand_id)
		sim.wake_rect(dig_pos.x - 18, drop_y - 4, 37, 32)
	if event_bus != null:
		event_bus.publish("hazard_triggered", tick, {
			"hazard_id": "collapse",
			"pos": dig_pos,
			"value": COLLAPSE_DAMAGE,
			"text_key": "$ui_hazard_collapse",
		})
	# 若玩家位于塌方正下方 24 格内，受 15 点落石伤害
	if vitals != null and Vector2(player_cell).distance_to(Vector2(dig_pos)) <= 24.0:
		vitals.take_hp_damage(COLLAPSE_DAMAGE, "土", "collapse", tick, event_bus, "$ui_death_enemy")
	if hud != null:
		var msg: String = String(text_db.get_text("$ui_hazard_collapse")) if (text_db != null and text_db.has_key("$ui_hazard_collapse")) else "矿顶塌方"
		hud.log_event(msg)

## 每 tick 检测水银池压制回灵（quicksilver_no_regen）；返回 true 表示本 tick 暂停回灵。
func check_quicksilver_block(player_cell: Vector2i, tick: int) -> bool:
	quicksilver_block_active = false
	if sim == null or not sim.has_world():
		return false
	var qs: int = sim.material_id("quicksilver")
	if qs < 0:
		return false
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-6, 1):
		var y := clampi(player_cell.y + dy, 0, h - 1)
		for dx in range(-2, 3):
			var x := clampi(player_cell.x + dx, 0, w - 1)
			if sim.get_cell(x, y) == qs:
				quicksilver_block_active = true
				break
		if quicksilver_block_active:
			break
	if quicksilver_block_active and tick - _last_qs_evt_tick >= QUICKSILVER_EVT_COOLDOWN:
		_last_qs_evt_tick = tick
		if event_bus != null:
			event_bus.publish("hazard_triggered", tick, {
				"hazard_id": "quicksilver_no_regen",
				"pos": player_cell,
				"value": 1.0,
				"text_key": "$ui_hazard_quicksilver",
			})
		if hud != null:
			var msg: String = String(text_db.get_text("$ui_hazard_quicksilver")) if (text_db != null and text_db.has_key("$ui_hazard_quicksilver")) else "水银滞灵"
			hud.log_event(msg)
	return quicksilver_block_active
