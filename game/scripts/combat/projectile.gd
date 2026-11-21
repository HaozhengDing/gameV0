extends RefCounted
## M1-02 真实投射物实体：消费 T3 VM 产出的 C-ACT `spawn_projectile` 动作节点
##（速度、方向、穿透 pierce、存活 ttl_ticks、payloads、以及静态展开的 on_hit / on_expire trigger）。

const SPEED_CELLS_PER_UNIT := 0.375  # VM 默认 speed=12 -> 4.5 cells/tick（270 cells/s，半屏约 0.8s）
const MAX_TRAIL := 5

var spell: String = ""
var owner_id: String = "player"
var faction: String = "player"

var pos: Vector2 = Vector2.ZERO      # 当前位置（cell 坐标）
var vel: Vector2 = Vector2.ZERO      # 速度（cells/tick）
var gravity: float = 0.0             # cells/tick^2
var radius: float = 1.5              # 实体命中半径（cells）

var damage: float = 0.0
var damage_type: String = "none"
var lantern_damage: float = 0.0
var element: String = "none"
var pierce_left: int = 0
var ttl_ticks: int = 120

var payloads: Array = []             # 命中时执行的 C-ACT 列表
var trigger: Dictionary = {}         # {kind: "on_hit"|"on_expire", depth: int, actions: Array}
var trigger_fired: bool = false
var hits_liquid: bool = false        # 携带 convert_material(liquid) 时在液面即刻命中（如 火+化水 打水银池）

var alive: bool = true
var hit_entities: Dictionary = {}    # entity_id -> true，防止穿透时同实体重复命中
var trail: Array[Vector2] = []
var color: Color = Color(0.98, 0.90, 0.48)

func init_from_action(action: Dictionary, origin: Vector2, dir: Vector2, p_owner: String, p_faction: String) -> void:
	spell = String(action.get("spell", ""))
	owner_id = p_owner
	faction = p_faction
	pos = origin
	var unit_dir := dir.normalized() if dir.length() > 0.0001 else Vector2.RIGHT
	var raw_speed: float = maxf(float(action.get("speed", 12.0)), 1.0)
	vel = unit_dir * (raw_speed * SPEED_CELLS_PER_UNIT)
	gravity = float(action.get("gravity", 0.0))
	damage = float(action.get("damage", 0.0))
	damage_type = String(action.get("damage_type", "none"))
	lantern_damage = float(action.get("lantern_damage", 0.0))
	element = String(action.get("element", "none"))
	pierce_left = maxi(int(action.get("pierce", 0)), 0)
	ttl_ticks = maxi(int(action.get("ttl_ticks", 120)), 1)
	payloads = []
	var raw_p: Variant = action.get("payloads", [])
	if raw_p is Array:
		for p in raw_p:
			if p is Dictionary:
				payloads.append(p)
	trigger = {}
	var raw_t: Variant = action.get("trigger")
	if raw_t is Dictionary:
		trigger = raw_t
	trigger_fired = false
	hits_liquid = _check_hits_liquid(payloads)
	alive = true
	hit_entities.clear()
	trail.clear()
	trail.append(pos)
	color = _color_for_element(element, spell)

func cell_pos() -> Vector2i:
	return Vector2i(floori(pos.x), floori(pos.y))

func direction() -> Vector2:
	return vel.normalized() if vel.length() > 0.0001 else Vector2.RIGHT

func record_trail() -> void:
	trail.append(pos)
	while trail.size() > MAX_TRAIL:
		trail.pop_front()

func _check_hits_liquid(p_list: Array) -> bool:
	for item in p_list:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		if String(d.get("op", "")) == "convert_material":
			return true
	return false

func _color_for_element(elem: String, spell_id: String) -> Color:
	if spell_id == "body-forbidden-wulei" or elem == "雷":
		return Color(0.68, 0.88, 1.0)
	match elem:
		"金":
			return Color(1.0, 0.92, 0.56)
		"火":
			return Color(1.0, 0.46, 0.16)
		"阴":
			return Color(0.66, 0.46, 0.98)
		"土":
			return Color(0.86, 0.72, 0.44)
		"木":
			return Color(0.56, 0.88, 0.42)
		"水":
			return Color(0.36, 0.76, 1.0)
		_:
			return Color(0.95, 0.95, 0.92)
