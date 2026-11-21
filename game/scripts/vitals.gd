extends RefCounted
## M1-05 七星灯双轴（气血 100 + 7 盏魄灯，契约见 refs/cards/p0/systems.yaml S-0004 & data/magic_numbers.json）：
## - 普通/物理/火/毒/雷伤扣气血（hp）；
## - 阴性伤害直接熄灯（支持 0.2–0.5 盏小数累积），每彻底熄灭 1 盏，气血上限永久 -1/7（直至复灯）；
## - 气血归零或七盏尽熄均判定死亡；回血不得超过当前有效气血上限。

const DEFAULT_BASE_HP := 100.0
const DEFAULT_LANTERNS_MAX := 7.0
const EPS := 0.0001

var base_max_hp: float = DEFAULT_BASE_HP
var lanterns_max: float = DEFAULT_LANTERNS_MAX
var lanterns: float = DEFAULT_LANTERNS_MAX
var hp: float = DEFAULT_BASE_HP
var last_death_key: String = "$ui_death_enemy"
var last_damage_source: String = ""

func load_defaults_from_magic_numbers(rel_path: String = "../data/magic_numbers.json") -> void:
	var path := ProjectSettings.globalize_path("res://").path_join(rel_path)
	if not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	var root: Dictionary = parsed
	var player_cfg: Variant = root.get("player")
	if player_cfg is Dictionary:
		var pc: Dictionary = player_cfg
		base_max_hp = maxf(float(pc.get("hp", DEFAULT_BASE_HP)), 1.0)
		lanterns_max = maxf(float(pc.get("lanterns", DEFAULT_LANTERNS_MAX)), 1.0)

func reset() -> void:
	lanterns = lanterns_max
	hp = base_max_hp
	last_death_key = "$ui_death_enemy"
	last_damage_source = ""

## 当前尚存亮光（含残烛未尽）的灯盏数：7.0 -> 7, 6.6 -> 7, 6.0 -> 6, 0.0 -> 0。
func lit_lantern_cap() -> int:
	if lanterns <= EPS:
		return 0
	return clampi(ceili(lanterns - EPS), 0, int(roundi(lanterns_max)))

## 已彻底熄灭的整灯盏数。
func extinguished_count() -> int:
	return maxi(int(roundi(lanterns_max)) - lit_lantern_cap(), 0)

## 当前有效气血上限：每彻底熄灭 1 盏，上限 -1/7。
func effective_max_hp() -> float:
	if lanterns_max <= 0.0:
		return 0.0
	return base_max_hp * (float(lit_lantern_cap()) / lanterns_max)

func is_dead() -> bool:
	return hp <= EPS or lanterns <= EPS

## 普通伤害（火/毒/金/雷/爆炸/物理）：只扣气血，不熄魄灯。
func take_hp_damage(amount: float, damage_type: String, source_id: String, tick: int,
		event_bus = null, death_key: String = "$ui_death_enemy") -> Dictionary:
	var out := {"applied": 0.0, "dead": false}
	if amount <= 0.0 or is_dead():
		return out
	var before := hp
	hp = maxf(hp - amount, 0.0)
	out["applied"] = before - hp
	last_damage_source = source_id
	last_death_key = death_key
	if event_bus != null:
		event_bus.publish("entity_damaged", tick, {
			"source_id": source_id, "target_id": "player",
			"value": float(out["applied"]), "damage_type": damage_type,
		})
	if is_dead():
		out["dead"] = true
		if event_bus != null:
			event_bus.publish("entity_killed", tick, {
				"source_id": source_id, "target_id": "player",
				"value": base_max_hp, "damage_type": damage_type, "text_key": death_key,
			})
	return out

## 阴性伤害：直接熄灯（支持 0.2–0.5 小数），若跨过整盏门槛立即压低有效气血上限并钳制当前气血。
func extinguish_lanterns(amount: float, source_id: String, tick: int, event_bus = null) -> Dictionary:
	var out := {"extinguished": 0.0, "full_lost": 0, "dead": false}
	if amount <= 0.0 or is_dead():
		return out
	var cap_before := lit_lantern_cap()
	var before := lanterns
	lanterns = maxf(lanterns - amount, 0.0)
	out["extinguished"] = before - lanterns
	var cap_after := lit_lantern_cap()
	out["full_lost"] = maxi(cap_before - cap_after, 0)
	var eff_max := effective_max_hp()
	if hp > eff_max:
		hp = eff_max
	last_damage_source = source_id
	last_death_key = "$ui_death_enemy"
	if event_bus != null:
		event_bus.publish("lantern_extinguished", tick, {
			"source_id": source_id, "target_id": "player",
			"value": float(out["extinguished"]), "lanterns_after": lanterns,
		})
	if is_dead():
		hp = 0.0
		out["dead"] = true
		if event_bus != null:
			event_bus.publish("entity_killed", tick, {
				"source_id": source_id, "target_id": "player",
				"value": base_max_hp, "damage_type": "阴", "text_key": last_death_key,
			})
	return out

## 复灯（洞天或特定仪轨）：恢复魄灯数并同步恢复气血上限。
func restore_lanterns(amount: float, source_id: String, tick: int, event_bus = null) -> float:
	if amount <= 0.0:
		return 0.0
	var before := lanterns
	lanterns = minf(lanterns + amount, lanterns_max)
	var gained := lanterns - before
	if gained > EPS and event_bus != null:
		event_bus.publish("lantern_restored", tick, {
			"source_id": source_id, "target_id": "player",
			"value": gained, "lanterns_after": lanterns,
		})
	return gained

## 回血：严格受当前有效气血上限（亮灯数/7 * 100）约束。
func heal_hp(amount: float) -> float:
	if amount <= 0.0 or is_dead():
		return 0.0
	var before := hp
	hp = minf(hp + amount, effective_max_hp())
	return hp - before

func snapshot() -> Dictionary:
	return {
		"hp": hp,
		"hp_eff_max": effective_max_hp(),
		"hp_base_max": base_max_hp,
		"lanterns": lanterns,
		"lanterns_max": lanterns_max,
		"lit_cap": lit_lantern_cap(),
		"extinguished": extinguished_count(),
	}
