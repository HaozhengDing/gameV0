extends RefCounted
## C-EVT v0.1 世界事件总线（M1-01 冻结契约，见 docs/tech/m1-01-contracts-evt-text.md Part 1）。
## 纯数据单向事件总线：连接 sim_core / VM / 玩法层 -> 表现层（粒子、音效、HUD、死因记录）。
## 事件不持有节点引用，便于无界面回归测试与节流聚合。

const MAX_HISTORY := 256

const VALID_TYPES := {
	"reaction_triggered": true,
	"fire_ignited": true,
	"fire_extinguished": true,
	"steam_created": true,
	"smoke_created": true,
	"terrain_dug": true,
	"entity_damaged": true,
	"entity_killed": true,
	"status_applied": true,
	"lantern_extinguished": true,
	"lantern_restored": true,
	"spell_cast": true,
	"spell_fizzle": true,
	"forbidden_cast": true,
	"backlash_triggered": true,
	"sanity_changed": true,
	"possession_entered": true,
	"possession_exited": true,
	"rule_triggered": true,
	"hazard_triggered": true,
	"room_entered": true,
	"run_ended": true,
}

var _seq := 0
var _history: Array[Dictionary] = []
var _listeners: Array[Callable] = []

func reset() -> void:
	_seq = 0
	_history.clear()

func subscribe(callback: Callable) -> void:
	if callback.is_valid() and not _listeners.has(callback):
		_listeners.append(callback)

func unsubscribe(callback: Callable) -> void:
	_listeners.erase(callback)

## 发送一条符合 C-EVT v0.1 信封结构的纯数据事件。
func publish(evt_type: String, tick: int, fields: Dictionary = {}) -> Dictionary:
	if not VALID_TYPES.has(evt_type):
		push_error("C-EVT: 未知事件类型 " + evt_type)
		return {}
	_seq += 1
	var actor_str: String = String(fields.get("actor", fields.get("source_id", "")))
	var target_str: String = String(fields.get("target", fields.get("target_id", "")))
	var dtype_str: String = String(fields.get("damage_type", ""))
	var status_str: String = String(fields.get("status", ""))
	var aux_str: String = String(fields.get("aux", dtype_str if not dtype_str.is_empty() else status_str))
	var env: Dictionary = {
		"seq": _seq,
		"tick": tick,
		"type": evt_type,
		"pos": fields.get("pos", Vector2i(-1, -1)),
		"actor": actor_str,
		"target": target_str,
		"source_id": actor_str,
		"target_id": target_str,
		"damage_type": dtype_str,
		"status": status_str,
		"material": String(fields.get("material", "")),
		"reaction_id": String(fields.get("reaction_id", "")),
		"value": float(fields.get("value", 0.0)),
		"aux": aux_str,
		"text_key": String(fields.get("text_key", "")),
	}
	_history.append(env)
	if _history.size() > MAX_HISTORY:
		_history.pop_front()
	for cb in _listeners:
		if cb.is_valid():
			cb.call(env)
	return env

func recent(limit: int = 16) -> Array[Dictionary]:
	if _history.is_empty():
		return []
	var n := mini(limit, _history.size())
	return _history.slice(_history.size() - n, _history.size())

func count_of(evt_type: String) -> int:
	var n := 0
	for env in _history:
		if String(env.get("type", "")) == evt_type:
			n += 1
	return n

func get_seq() -> int:
	return _seq
