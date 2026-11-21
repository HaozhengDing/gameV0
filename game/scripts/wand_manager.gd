extends RefCounted
## M1-03 法器与符箓牌堆调度器（对齐 S-0002、talisman-vm-spec.md & D-M1-4）：
## - 管理多把法器（data/wands.json：桃木剑 / 铜铃 / 骨简）与玩家散符背包；
## - 维护每把法器独立的灵力、游标 cursor、回符 ready_at_tick、施法间隔 next_cast_tick；
## - 成文（ordered=true）按槽位顺序推进游标；散符（ordered=false）每轮在调度层确定性洗牌；
## - 严格执行 D-M1-4：仅在洞天安全区（in_safe_zone=true）允许编辑符位，矿井内只读。

const WANDS_REL_PATH := "../data/wands.json"
const MIN_CAST_INTERVAL_TICKS := 2
const URGENT_ORDER_DELTA := -6

var wands: Array[Dictionary] = []
var bag: Array[String] = []
var card_meta: Dictionary = {}      # card_id -> {id, segment, spirit_cost, forbidden, element}
var selected_index: int = 0
var in_safe_zone: bool = false
var _shuffle_counter: int = 1
var _raw_wands_cfg: Dictionary = {}

func load_data(vm: TalismanVMNode, rel_path: String = WANDS_REL_PATH) -> bool:
	card_meta.clear()
	if vm != null and vm.is_loaded():
		for item in vm.get_all_cards():
			if item is Dictionary:
				var d: Dictionary = item
				card_meta[String(d.get("id", ""))] = d
	var path := ProjectSettings.globalize_path("res://").path_join(rel_path)
	if not FileAccess.file_exists(path):
		push_error("M1-03 wand_manager: 找不到 " + path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("M1-03 wand_manager: JSON 解析失败 " + path)
		return false
	_raw_wands_cfg = parsed
	reset()
	return not wands.is_empty()

func reset() -> void:
	wands.clear()
	bag.clear()
	selected_index = 0
	_shuffle_counter = 1
	var raw_list: Variant = _raw_wands_cfg.get("wands", [])
	if raw_list is Array:
		for item in raw_list:
			if item is Dictionary:
				wands.append(_make_wand_runtime(item))
	var raw_bag: Variant = _raw_wands_cfg.get("starter_bag", [])
	if raw_bag is Array:
		for cid in raw_bag:
			bag.append(String(cid))

func _make_wand_runtime(def: Dictionary) -> Dictionary:
	var slots: int = maxi(int(def.get("slots", 4)), 1)
	var deck: Array[String] = []
	var raw_deck: Variant = def.get("default_deck", [])
	if raw_deck is Array:
		for cid in raw_deck:
			if deck.size() < slots:
				deck.append(String(cid))
	while deck.size() < slots:
		deck.append("")
	var smax: float = float(def.get("spirit_max", 80.0))
	return {
		"id": String(def.get("id", "wand")),
		"name": String(def.get("name", "法器")),
		"ui_key": String(def.get("ui_key", "")),
		"ordered": bool(def.get("ordered", true)),
		"slots": slots,
		"spirit": smax,
		"spirit_max": smax,
		"regen_per_sec": float(def.get("regen_per_sec", 10.0)),
		"sentences_per_cast": maxi(int(def.get("sentences_per_cast", 1)), 1),
		"recharge_ticks": maxi(int(def.get("recharge_ticks", 30)), 1),
		"cast_interval_ticks": maxi(int(def.get("cast_interval_ticks", 12)), MIN_CAST_INTERVAL_TICKS),
		"price": int(def.get("price", 250)),
		"deck": deck,
		"draw_deck": deck.duplicate(),
		"cursor": 0,
		"ready_at_tick": 0,
		"next_cast_tick": 0,
	}

func wand_count() -> int:
	return wands.size()

func select_wand(idx: int) -> void:
	if wands.is_empty():
		return
	selected_index = wrapi(idx, 0, wands.size())

func active_wand() -> Dictionary:
	if wands.is_empty():
		return {}
	return wands[clampi(selected_index, 0, wands.size() - 1)]

func get_wand(idx: int) -> Dictionary:
	if idx < 0 or idx >= wands.size():
		return {}
	return wands[idx]

func is_active_recharging(sim_tick: int) -> bool:
	var w := active_wand()
	if w.is_empty():
		return false
	return sim_tick < int(w["ready_at_tick"])

func tick_advance(spirit_regen_blocked: bool = false) -> void:
	if spirit_regen_blocked:
		return
	for w in wands:
		var smax: float = float(w["spirit_max"])
		var regen: float = float(w["regen_per_sec"])
		w["spirit"] = minf(smax, float(w["spirit"]) + regen / 60.0)

## 按当前选中法器的真实游标/牌堆向 T3 VM 发起施法（含散符洗牌与施法间隔）。
func cast_active(vm: TalismanVMNode, sim_tick: int, temp_bonus_slot: bool = false,
		sanity: int = 100, backlash: bool = false, phantom_slots: Array = [],
		rng_cfg: Dictionary = {}) -> Dictionary:
	var w := active_wand()
	if w.is_empty() or vm == null or not vm.is_loaded():
		return {"accepted": false, "reject_reason": "no_cards"}
	if sim_tick < int(w["next_cast_tick"]) and sim_tick >= int(w["ready_at_tick"]):
		return {"accepted": false, "reject_reason": "cast_interval"}

	# 散符（ordered=false）：每轮起始（cursor==0）在调度层洗牌，保持 VM 纯函数
	var cursor: int = int(w["cursor"])
	if bool(w["ordered"]):
		w["draw_deck"] = (w["deck"] as Array).duplicate()
	elif cursor == 0:
		w["draw_deck"] = _shuffle_non_empty(w["deck"] as Array)

	var draw_deck: Array = (w["draw_deck"] as Array).duplicate()
	var eff_slots: int = int(w["slots"]) + (1 if temp_bonus_slot else 0)
	while draw_deck.size() < eff_slots:
		draw_deck.append("")

	var wand_req := {
		"tick": sim_tick,
		"spirit": float(w["spirit"]),
		"spirit_max": float(w["spirit_max"]),
		"regen_per_sec": float(w["regen_per_sec"]),
		"slots": eff_slots,
		"sentences_per_cast": int(w["sentences_per_cast"]),
		"recharge_ticks": int(w["recharge_ticks"]),
		"ready_at_tick": int(w["ready_at_tick"]),
		"ordered": bool(w["ordered"]),
		"deck": draw_deck,
		"cursor": cursor,
	}
	var state_req := {
		"sanity": sanity,
		"backlash": backlash,
		"phantom_slots": phantom_slots,
	}
	var res: Dictionary = vm.cast_deck(wand_req, state_req, rng_cfg)
	if bool(res.get("accepted", false)):
		w["spirit"] = float(res.get("spirit_after", w["spirit"]))
		w["cursor"] = int(res.get("cursor_after", 0))
		w["ready_at_tick"] = int(res.get("ready_at_tick_after", w["ready_at_tick"]))
		# 计算施法间隔（急急如律令 每张 -6 tick，不低于 MIN_CAST_INTERVAL_TICKS）
		var interval: int = int(w["cast_interval_ticks"])
		for cid in res.get("consumed", []):
			if String(cid) == "head-urgent-order":
				interval += URGENT_ORDER_DELTA
		w["next_cast_tick"] = sim_tick + maxi(interval, MIN_CAST_INTERVAL_TICKS)
	return res

func _shuffle_non_empty(deck: Array) -> Array[String]:
	var non_empty: Array[String] = []
	for item in deck:
		var s := String(item)
		if not s.is_empty():
			non_empty.append(s)
	# 确定性 Fisher-Yates 洗牌（同 seed/次序可复现）
	var state: int = (_shuffle_counter * 1103515245 + 12345) & 0x7FFFFFFF
	_shuffle_counter += 1
	for i in range(non_empty.size() - 1, 0, -1):
		state = (state * 1103515245 + 12345) & 0x7FFFFFFF
		var j := state % (i + 1)
		var tmp := non_empty[i]
		non_empty[i] = non_empty[j]
		non_empty[j] = tmp
	while non_empty.size() < deck.size():
		non_empty.append("")
	return non_empty

# ------------------------------------------------------------------ 洞天安全区改符（D-M1-4）

func can_edit() -> bool:
	return in_safe_zone

func set_slot(wand_idx: int, slot_idx: int, card_id: String) -> bool:
	if not in_safe_zone:
		return false
	if wand_idx < 0 or wand_idx >= wands.size():
		return false
	var w: Dictionary = wands[wand_idx]
	var deck: Array = w["deck"]
	if slot_idx < 0 or slot_idx >= deck.size():
		return false
	if not card_id.is_empty() and not card_meta.has(card_id):
		return false
	deck[slot_idx] = card_id
	w["cursor"] = 0
	w["draw_deck"] = deck.duplicate()
	return true

func remove_slot(wand_idx: int, slot_idx: int) -> bool:
	if not in_safe_zone:
		return false
	if wand_idx < 0 or wand_idx >= wands.size():
		return false
	var w: Dictionary = wands[wand_idx]
	var deck: Array = w["deck"]
	if slot_idx < 0 or slot_idx >= deck.size():
		return false
	var prev: String = String(deck[slot_idx])
	if prev.is_empty():
		return false
	deck[slot_idx] = ""
	bag.append(prev)
	w["cursor"] = 0
	w["draw_deck"] = deck.duplicate()
	return true

func equip_from_bag(wand_idx: int, slot_idx: int, bag_idx: int) -> bool:
	if not in_safe_zone:
		return false
	if wand_idx < 0 or wand_idx >= wands.size():
		return false
	if bag_idx < 0 or bag_idx >= bag.size():
		return false
	var w: Dictionary = wands[wand_idx]
	var deck: Array = w["deck"]
	if slot_idx < 0 or slot_idx >= deck.size():
		return false
	var new_card: String = bag[bag_idx]
	var old_card: String = String(deck[slot_idx])
	deck[slot_idx] = new_card
	bag.remove_at(bag_idx)
	if not old_card.is_empty():
		bag.append(old_card)
	w["cursor"] = 0
	w["draw_deck"] = deck.duplicate()
	return true

func swap_slots(wand_idx: int, slot_a: int, slot_b: int) -> bool:
	if not in_safe_zone:
		return false
	if wand_idx < 0 or wand_idx >= wands.size():
		return false
	var w: Dictionary = wands[wand_idx]
	var deck: Array = w["deck"]
	if slot_a < 0 or slot_a >= deck.size() or slot_b < 0 or slot_b >= deck.size():
		return false
	var tmp = deck[slot_a]
	deck[slot_a] = deck[slot_b]
	deck[slot_b] = tmp
	w["cursor"] = 0
	w["draw_deck"] = deck.duplicate()
	return true

# ------------------------------------------------------------------ 极简展示（refs/naming.md §5）

func card_label(card_id: String, text_db) -> String:
	if card_id.is_empty():
		return "空"
	if text_db != null:
		var key := "$card_" + card_id.replace("-", "_")
		if text_db.has_key(key):
			return String(text_db.get_text(key))
	return card_id

func card_segment(card_id: String) -> String:
	if card_meta.has(card_id):
		return String((card_meta[card_id] as Dictionary).get("segment", "body"))
	return "empty"

func card_cost(card_id: String) -> int:
	if card_meta.has(card_id):
		return roundi(float((card_meta[card_id] as Dictionary).get("spirit_cost", 0.0)))
	return 0

func wand_display_name(wand_idx: int, text_db) -> String:
	var w := get_wand(wand_idx)
	if w.is_empty():
		return "—"
	var uk: String = String(w.get("ui_key", ""))
	if text_db != null and not uk.is_empty() and text_db.has_key(uk):
		return text_db.get_text(uk)
	return String(w.get("name", "法器"))

## 极简符位拼句（不造合体名）：如 "斩 + 爆 · 掘 + 归"
func wand_composition_text(wand_idx: int, text_db) -> String:
	var w := get_wand(wand_idx)
	if w.is_empty():
		return "—"
	var parts: Array[String] = []
	for cid in w["deck"]:
		var s := String(cid)
		if not s.is_empty():
			parts.append(card_label(s, text_db))
	if parts.is_empty():
		return "空槽"
	return " ".join(parts)

func build_hud_slots(text_db) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(wands.size()):
		var w: Dictionary = wands[i]
		var mode_txt := "成文" if bool(w["ordered"]) else "散符"
		out.append({
			"name": wand_display_name(i, text_db),
			"subtitle": wand_composition_text(i, text_db),
			"meta": "%s · 游标 %d/%d" % [mode_txt, int(w["cursor"]), int(w["slots"])],
		})
	return out
