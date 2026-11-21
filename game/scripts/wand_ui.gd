extends CanvasLayer
## M1-03 极简符箓组装面板（D-M1-4 已拍板）：
## - 按 B 开关；仅在洞天安全区可编辑法器符位，矿井内打开为只读检视；
## - 无合体名、无中二修饰；符头（青）/ 符胆（金）/ 符脚（朱红）/ 禁符（暗红）按色区分；
## - 左键选槽再点背包符可装配/替换；再点另一槽位可交换顺序；右键槽位卸回背包。

signal deck_changed

const BG_DIM := Color(0.04, 0.04, 0.07, 0.78)
const CARD_BG := Color(0.10, 0.11, 0.15, 0.96)
const COL_HEAD := Color(0.24, 0.56, 0.72)
const COL_BODY := Color(0.76, 0.58, 0.20)
const COL_FOOT := Color(0.72, 0.30, 0.34)
const COL_EMPTY := Color(0.18, 0.19, 0.23)
const COL_SEL := Color(0.98, 0.86, 0.34)

var wand_manager
var text_db
var hud
var is_open: bool = false
var _selected_slot: int = -1

var _root: Control
var _header_label: Label
var _safe_badge: Label
var _stats_label: Label
var _slots_box: HBoxContainer
var _bag_grid: GridContainer
var _hint_label: Label

func setup(p_wand_manager, p_text_db, p_hud = null) -> void:
	wand_manager = p_wand_manager
	text_db = p_text_db
	hud = p_hud
	if is_open:
		refresh()

func _ready() -> void:
	layer = 20
	var vs := get_viewport().get_visible_rect().size
	_root = Control.new()
	_root.size = vs
	_root.visible = false
	add_child(_root)

	var dimmer := ColorRect.new()
	dimmer.size = vs
	dimmer.color = BG_DIM
	_root.add_child(dimmer)

	var panel_w := 860.0
	var panel_h := 460.0
	var px := (vs.x - panel_w) * 0.5
	var py := (vs.y - panel_h) * 0.5

	var panel := ColorRect.new()
	panel.position = Vector2(px, py)
	panel.size = Vector2(panel_w, panel_h)
	panel.color = CARD_BG
	_root.add_child(panel)

	_header_label = _make_label(_root, Vector2(px + 24, py + 18), 26, Color(0.96, 0.94, 0.86))
	_safe_badge = _make_label(_root, Vector2(px + panel_w - 240, py + 22), 20, Color(0.45, 0.92, 0.56))
	_stats_label = _make_label(_root, Vector2(px + 24, py + 54), 18, Color(0.74, 0.82, 0.90))

	var slot_hdr := _make_label(_root, Vector2(px + 24, py + 92), 18, Color(0.86, 0.84, 0.78))
	slot_hdr.text = "法器符位（左键选槽/换位，右键卸回背包）"

	_slots_box = HBoxContainer.new()
	_slots_box.position = Vector2(px + 24, py + 122)
	_slots_box.size = Vector2(panel_w - 48, 86)
	_slots_box.add_theme_constant_override("separation", 10)
	_root.add_child(_slots_box)

	var bag_hdr := _make_label(_root, Vector2(px + 24, py + 226), 18, Color(0.86, 0.84, 0.78))
	bag_hdr.text = "背包符箓（先点上方符位，再点下方符箓装入）"

	_bag_grid = GridContainer.new()
	_bag_grid.columns = 6
	_bag_grid.position = Vector2(px + 24, py + 256)
	_bag_grid.size = Vector2(panel_w - 48, 150)
	_bag_grid.add_theme_constant_override("h_separation", 8)
	_bag_grid.add_theme_constant_override("v_separation", 8)
	_root.add_child(_bag_grid)

	_hint_label = _make_label(_root, Vector2(px + 24, py + panel_h - 36), 16, Color(0.72, 0.72, 0.70))
	_hint_label.text = "青=符头 | 金=符胆 | 朱红=符脚 | 1-3 切换法器 | B / Esc 关闭"

func toggle() -> void:
	set_open(not is_open)

func set_open(open: bool) -> void:
	is_open = open
	_selected_slot = -1
	if _root != null:
		_root.visible = is_open
	if is_open:
		refresh()

func refresh() -> void:
	if wand_manager == null or _root == null:
		return
	var idx: int = wand_manager.selected_index
	var w: Dictionary = wand_manager.active_wand()
	if w.is_empty():
		return
	var mode_txt := "成文" if bool(w["ordered"]) else "散符"
	_header_label.text = "%d · %s（%s）" % [idx + 1, wand_manager.wand_display_name(idx, text_db), mode_txt]
	if wand_manager.can_edit():
		_safe_badge.text = "安全区 · 可改符"
		_safe_badge.add_theme_color_override("font_color", Color(0.45, 0.94, 0.56))
	else:
		_safe_badge.text = "矿井中 · 只读"
		_safe_badge.add_theme_color_override("font_color", Color(0.88, 0.62, 0.42))
	_stats_label.text = "灵 %.0f/%.0f · 回 %.0f/s · 位 %d · 每次 %d 句 · 游标 %d" % [
		float(w["spirit"]), float(w["spirit_max"]), float(w["regen_per_sec"]),
		int(w["slots"]), int(w["sentences_per_cast"]), int(w["cursor"]),
	]

	for c in _slots_box.get_children():
		c.queue_free()
	var deck: Array = w["deck"]
	var cursor: int = int(w["cursor"])
	for s in range(deck.size()):
		var cid := String(deck[s])
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(116, 74)
		var mark := "▶" if s == cursor else ""
		var sel_mark := "[选中]\n" if s == _selected_slot else ""
		var cost_txt := ("耗 %d" % wand_manager.card_cost(cid)) if not cid.is_empty() else "—"
		btn.text = "%s%s%d: %s\n%s" % [sel_mark, mark, s + 1, wand_manager.card_label(cid, text_db), cost_txt]
		btn.modulate = COL_SEL if s == _selected_slot else _segment_tint(cid)
		btn.pressed.connect(_on_slot_left_click.bind(s))
		btn.gui_input.connect(_on_slot_gui_input.bind(s))
		_slots_box.add_child(btn)

	for c in _bag_grid.get_children():
		c.queue_free()
	var bag: Array = wand_manager.bag
	for b in range(bag.size()):
		var cid := String(bag[b])
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(126, 44)
		btn.text = "%s (%d)" % [wand_manager.card_label(cid, text_db), wand_manager.card_cost(cid)]
		btn.modulate = _segment_tint(cid)
		btn.pressed.connect(_on_bag_click.bind(b))
		_bag_grid.add_child(btn)

func _on_slot_left_click(slot_idx: int) -> void:
	if not wand_manager.can_edit():
		_warn_safe_only()
		return
	if _selected_slot < 0:
		_selected_slot = slot_idx
		refresh()
		return
	if _selected_slot == slot_idx:
		_selected_slot = -1
		refresh()
		return
	if wand_manager.swap_slots(wand_manager.selected_index, _selected_slot, slot_idx):
		_selected_slot = -1
		deck_changed.emit()
		refresh()

func _on_slot_gui_input(event: InputEvent, slot_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			if not wand_manager.can_edit():
				_warn_safe_only()
				return
			if wand_manager.remove_slot(wand_manager.selected_index, slot_idx):
				_selected_slot = -1
				deck_changed.emit()
				refresh()

func _on_bag_click(bag_idx: int) -> void:
	if not wand_manager.can_edit():
		_warn_safe_only()
		return
	var target_slot := _selected_slot
	if target_slot < 0:
		# 自动挑第一个空槽，否则默认槽 0
		var w: Dictionary = wand_manager.active_wand()
		var deck: Array = w.get("deck", [])
		target_slot = 0
		for i in range(deck.size()):
			if String(deck[i]).is_empty():
				target_slot = i
				break
	if wand_manager.equip_from_bag(wand_manager.selected_index, target_slot, bag_idx):
		_selected_slot = -1
		deck_changed.emit()
		refresh()

func _warn_safe_only() -> void:
	var msg: String = String(text_db.get_text("$ui_edit_safe_only")) if (text_db != null and text_db.has_key("$ui_edit_safe_only")) else "仅洞天安全区可改符"
	if hud != null:
		hud.log_event(msg)

func _segment_tint(cid: String) -> Color:
	if cid.is_empty():
		return COL_EMPTY.lightened(0.45)
	var seg: String = wand_manager.card_segment(cid)
	match seg:
		"head":
			return COL_HEAD.lightened(0.35)
		"body":
			return COL_BODY.lightened(0.35)
		"foot":
			return COL_FOOT.lightened(0.35)
		_:
			return Color(0.9, 0.9, 0.9)

func _make_label(parent: Node, pos: Vector2, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl
