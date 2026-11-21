extends Node2D
## M1-04 规矩碑文（D2 关卡叙事规则层 + D3 认知污染文本接入）：
## - 在世界像素空间渲染石碑，玩家靠近（28 cells 内）时在碑顶浮显 C-TEXT 规矩文本；
## - sanity < 66 时经 TextDB.get_text(key, sanity) 自动切换腐坏文本（只污染未知规矩，不污染已知 UI）；
## - 首次读碑发布 C-EVT `rule_triggered`。

const SCALE := 4
const READ_RADIUS_CELLS := 28.0

var steles: Array[Dictionary] = []    # [{id, pos: Vector2i, rule_id, text_key, read: bool}]
var text_db
var event_bus
var active_stele_text: String = ""
var active_stele_pos: Vector2i = Vector2i(-1, -1)

var _floating_bg: ColorRect
var _floating_label: Label

func setup(p_text_db, p_event_bus) -> void:
	text_db = p_text_db
	event_bus = p_event_bus

func _ready() -> void:
	z_index = 3
	_floating_bg = ColorRect.new()
	_floating_bg.color = Color(0.06, 0.06, 0.09, 0.86)
	_floating_bg.visible = false
	_floating_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_floating_bg)

	_floating_label = Label.new()
	_floating_label.add_theme_font_size_override("font_size", 18)
	_floating_label.add_theme_color_override("font_color", Color(0.95, 0.90, 0.72))
	_floating_label.visible = false
	_floating_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_floating_label)

func set_steles(list: Array) -> void:
	steles.clear()
	for raw in list:
		if raw is Dictionary:
			var d: Dictionary = (raw as Dictionary).duplicate()
			d["read"] = false
			steles.append(d)
	active_stele_text = ""
	active_stele_pos = Vector2i(-1, -1)
	_hide_banner()
	queue_redraw()

## 每 tick 检查玩家是否靠近任一石碑；返回当前展示的碑文（空串表示未靠近）。
func update_proximity(player_cell: Vector2i, sanity: int, tick: int) -> String:
	var best_idx := -1
	var best_dist := READ_RADIUS_CELLS
	var pvec := Vector2(player_cell)
	for i in range(steles.size()):
		var pos: Vector2i = steles[i]["pos"]
		var d := pvec.distance_to(Vector2(pos))
		if d <= best_dist:
			best_dist = d
			best_idx = i
	if best_idx < 0:
		active_stele_text = ""
		active_stele_pos = Vector2i(-1, -1)
		_hide_banner()
		return ""

	var st: Dictionary = steles[best_idx]
	var tk: String = String(st.get("text_key", ""))
	var txt: String = String(text_db.get_text(tk, sanity)) if (text_db != null and text_db.has_key(tk)) else tk
	active_stele_text = txt
	active_stele_pos = st["pos"]
	if not bool(st.get("read", false)):
		st["read"] = true
		if event_bus != null:
			event_bus.publish("rule_triggered", tick, {
				"rule_id": String(st.get("rule_id", "")),
				"pos": active_stele_pos,
				"text_key": tk,
			})
	_show_banner(active_stele_pos, txt)
	return txt

func _show_banner(cell: Vector2i, text: String) -> void:
	if _floating_label == null or _floating_bg == null:
		return
	_floating_label.text = "碑文：" + text
	var min_sz := _floating_label.get_minimum_size()
	var w := maxf(min_sz.x + 20.0, 140.0)
	var h := maxf(min_sz.y + 10.0, 32.0)
	var px := float(cell.x * SCALE) - w * 0.5
	var py := float((cell.y - 16) * SCALE) - h
	_floating_bg.position = Vector2(px, py)
	_floating_bg.size = Vector2(w, h)
	_floating_bg.visible = true
	_floating_label.position = Vector2(px + 10.0, py + 4.0)
	_floating_label.visible = true

func _hide_banner() -> void:
	if _floating_bg != null:
		_floating_bg.visible = false
	if _floating_label != null:
		_floating_label.visible = false

func _draw() -> void:
	for st in steles:
		var c: Vector2i = st["pos"]
		var bx := float((c.x - 3) * SCALE)
		var by := float((c.y - 10) * SCALE)
		var bw := float(6 * SCALE)
		var bh := float(10 * SCALE)
		draw_rect(Rect2(bx, by, bw, bh), Color(0.46, 0.44, 0.40))
		draw_rect(Rect2(bx + 2.0, by + 2.0, bw - 4.0, bh - 4.0), Color(0.32, 0.30, 0.28))
		# 碑面刻痕金纹
		draw_line(Vector2(bx + 6.0, by + 8.0), Vector2(bx + bw - 6.0, by + 8.0), Color(0.86, 0.78, 0.46, 0.85), 2.0)
		draw_line(Vector2(bx + 6.0, by + 16.0), Vector2(bx + bw - 8.0, by + 16.0), Color(0.86, 0.78, 0.46, 0.75), 2.0)
		draw_line(Vector2(bx + 6.0, by + 24.0), Vector2(bx + bw - 10.0, by + 24.0), Color(0.86, 0.78, 0.46, 0.65), 2.0)
