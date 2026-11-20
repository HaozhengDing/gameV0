extends CanvasLayer
## T4b 极简 HUD（对照 Noita，2026-11-20 拍板）：
## - 左上：彩色条 + 数字（7 格血/灯、蓝条法力、黄条浮空、葫芦水/油双条），去掉冗长包装词；
## - 顶中：4 个符槽平铺展示组成（如 斩+爆 / 火+化水），不显示合体名与内部编号；
## - 右上：极简材质提示与出口方向；
## - 左下/下方：最近 3 条短事件日志 + 底部键位条。

const MAX_LOG := 3
const LANTERNS_MAX := 7
const FONT_SIZE_NUM := 20
const FONT_SIZE_SLOT := 22
const FONT_SIZE_COST := 16
const FONT_SIZE_MAT := 22
const FONT_SIZE_LOG := 20
const FONT_SIZE_HELP := 18
const FONT_SIZE_COMPLETE := 56

const PANEL_BG := Color(0.06, 0.06, 0.09, 0.72)
const BAR_TRACK := Color(0.16, 0.16, 0.20, 0.92)
const COL_HP_ON := Color(0.92, 0.36, 0.26)
const COL_HP_OFF := Color(0.24, 0.21, 0.22)
const COL_MANA := Color(0.30, 0.64, 0.98)
const COL_MANA_CD := Color(0.46, 0.44, 0.68)
const COL_LEV := Color(0.96, 0.80, 0.26)
const COL_WATER := Color(0.30, 0.56, 0.88)
const COL_OIL := Color(0.68, 0.48, 0.22)
const COL_SLOT_BG := Color(0.08, 0.08, 0.12, 0.72)
const COL_SLOT_SEL := Color(0.20, 0.18, 0.12, 0.88)
const COL_BORDER_SEL := Color(0.96, 0.84, 0.36)
const COL_BORDER_DIM := Color(0.30, 0.30, 0.36, 0.80)

const HELP_TEXT := "A/D 走 | W/Space 浮空 | 1-4 切符 | 左键 施法 | E 吸 | Q 喷 | Tab 水/油 | F 点火 | R 重开"

# 左上资源条节点
var _hp_cells: Array[ColorRect] = []
var _hp_label: Label
var _mana_fill: ColorRect
var _mana_label: Label
var _lev_fill: ColorRect
var _lev_label: Label
var _water_border: ColorRect
var _water_fill: ColorRect
var _water_label: Label
var _oil_border: ColorRect
var _oil_fill: ColorRect
var _oil_label: Label

# 顶中符槽
var _slot_borders: Array[ColorRect] = []
var _slot_bgs: Array[ColorRect] = []
var _slot_titles: Array[Label] = []
var _slot_costs: Array[Label] = []

# 右上材质与出口
var _info_bg: ColorRect
var _mat_label: Label
var _exit_label: Label

# 事件日志 / 键位 / 通关
var _log_bg: ColorRect
var _log_label: Label
var _complete_bg: ColorRect
var _complete: Label
var _lines: Array = []

const BAR_W := 214.0
const GOURD_W := 142.0

func _ready() -> void:
	layer = 10
	var vs := get_viewport().get_visible_rect().size
	_build_resource_card()
	_build_slots()
	_build_right_info(vs)
	_build_log_and_help(vs)
	_build_complete(vs)

func _build_resource_card() -> void:
	_make_rect(Vector2(14, 12), Vector2(316, 114), PANEL_BG)

	# Row 1：7 格血/灯条 + 数字
	_hp_cells.clear()
	for i in range(LANTERNS_MAX):
		var cell := _make_rect(Vector2(24 + i * 31, 22), Vector2(27, 14), COL_HP_ON)
		_hp_cells.append(cell)
	_hp_label = _make_label(Vector2(248, 16), FONT_SIZE_NUM, Color(0.96, 0.90, 0.86))
	_hp_label.text = "7/7"

	# Row 2：法力蓝条 + 数字
	_make_rect(Vector2(24, 46), Vector2(BAR_W, 12), BAR_TRACK)
	_mana_fill = _make_rect(Vector2(24, 46), Vector2(BAR_W, 12), COL_MANA)
	_mana_label = _make_label(Vector2(248, 39), FONT_SIZE_NUM, Color(0.76, 0.88, 0.98))
	_mana_label.text = "80/80"

	# Row 3：浮空黄条 + 百分比
	_make_rect(Vector2(24, 68), Vector2(BAR_W, 10), BAR_TRACK)
	_lev_fill = _make_rect(Vector2(24, 68), Vector2(BAR_W, 10), COL_LEV)
	_lev_label = _make_label(Vector2(248, 60), 18, Color(0.96, 0.88, 0.56))
	_lev_label.text = "100%"

	# Row 4：葫芦水 / 油双条（选中高亮框）
	_water_border = _make_rect(Vector2(22, 88), Vector2(GOURD_W + 4, 28), COL_BORDER_SEL)
	_make_rect(Vector2(24, 90), Vector2(GOURD_W, 24), BAR_TRACK)
	_water_fill = _make_rect(Vector2(24, 90), Vector2(0, 24), COL_WATER)
	_water_label = _make_label(Vector2(30, 90), 18, Color(0.94, 0.96, 1.0))
	_water_label.text = "水 0/200"

	_oil_border = _make_rect(Vector2(174, 88), Vector2(GOURD_W + 4, 28), COL_BORDER_DIM)
	_make_rect(Vector2(176, 90), Vector2(GOURD_W, 24), BAR_TRACK)
	_oil_fill = _make_rect(Vector2(176, 90), Vector2(0, 24), COL_OIL)
	_oil_label = _make_label(Vector2(182, 90), 18, Color(0.96, 0.92, 0.84))
	_oil_label.text = "油 0/100"

func _build_slots() -> void:
	_slot_borders.clear()
	_slot_bgs.clear()
	_slot_titles.clear()
	_slot_costs.clear()
	var x0 := 346.0
	var slot_w := 148.0
	var slot_h := 62.0
	var gap := 10.0
	for i in range(4):
		var sx := x0 + float(i) * (slot_w + gap)
		var border := _make_rect(Vector2(sx, 12), Vector2(slot_w, slot_h), COL_BORDER_DIM)
		var bg := _make_rect(Vector2(sx + 2, 14), Vector2(slot_w - 4, slot_h - 4), COL_SLOT_BG)
		var title := _make_label(Vector2(sx + 10, 17), FONT_SIZE_SLOT, Color(0.96, 0.94, 0.88))
		title.text = "%d" % (i + 1)
		var cost := _make_label(Vector2(sx + 10, 47), FONT_SIZE_COST, Color(0.68, 0.80, 0.96))
		cost.text = ""
		_slot_borders.append(border)
		_slot_bgs.append(bg)
		_slot_titles.append(title)
		_slot_costs.append(cost)

func _build_right_info(vs: Vector2) -> void:
	var w := 250.0
	_info_bg = _make_rect(Vector2(vs.x - w - 14.0, 12), Vector2(w, 66), PANEL_BG)
	_mat_label = _make_label(Vector2(vs.x - w - 2.0, 16), FONT_SIZE_MAT, Color(0.96, 0.94, 0.86))
	_mat_label.text = "—"
	_exit_label = _make_label(Vector2(vs.x - w - 2.0, 46), 18, Color(0.70, 0.88, 0.74))
	_exit_label.text = "出口 →"

func _build_log_and_help(vs: Vector2) -> void:
	_log_bg = _make_rect(Vector2(14, 134), Vector2(316, 84), Color(0.06, 0.06, 0.09, 0.56))
	_log_bg.visible = false
	_log_label = _make_label(Vector2(22, 138), FONT_SIZE_LOG, Color(0.84, 0.90, 0.80))

	_make_rect(Vector2(0.0, vs.y - 34.0), Vector2(vs.x, 34.0), Color(0.05, 0.05, 0.08, 0.64))
	var help_label := _make_label(Vector2(14, vs.y - 29.0), FONT_SIZE_HELP, Color(0.80, 0.80, 0.76))
	help_label.text = HELP_TEXT

func _build_complete(vs: Vector2) -> void:
	_complete_bg = _make_rect(Vector2(0.0, vs.y * 0.5 - 92.0), Vector2(vs.x, 184.0), Color(0.05, 0.08, 0.06, 0.82))
	_complete_bg.visible = false
	_complete = Label.new()
	_complete.name = "Complete"
	_complete.add_theme_font_size_override("font_size", FONT_SIZE_COMPLETE)
	_complete.add_theme_color_override("font_color", Color(0.98, 0.84, 0.32))
	_complete.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_complete.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_complete.visible = false
	add_child(_complete)
	_complete.position = Vector2(0.0, vs.y * 0.5 - 80.0)
	_complete.size = Vector2(vs.x, 160.0)

func _make_rect(pos: Vector2, sz: Vector2, color: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.position = pos
	rect.size = sz
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	return rect

func _make_label(pos: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

## 设置 4 个符槽的显示名称与灵力耗费（名称来自 data/talismans.json，如 斩 + 爆）。
func set_slots(names: Array, costs: Array) -> void:
	for i in range(_slot_titles.size()):
		if i < names.size():
			_slot_titles[i].text = "%d  %s" % [i + 1, String(names[i])]
			var c: int = int(costs[i]) if i < costs.size() else 0
			_slot_costs[i].text = "耗 %d" % c
		else:
			_slot_titles[i].text = "%d  —" % (i + 1)
			_slot_costs[i].text = ""

## 更新全部彩色状态条、当前槽位高亮与右上材质/出口信息。
func update_state(state: Dictionary) -> void:
	var hp: int = int(state.get("hp", LANTERNS_MAX))
	var hp_max: int = maxi(int(state.get("hp_max", LANTERNS_MAX)), 1)
	for i in range(_hp_cells.size()):
		_hp_cells[i].color = COL_HP_ON if i < hp else COL_HP_OFF
	if _hp_label != null:
		_hp_label.text = "%d/%d" % [hp, hp_max]

	var mana: float = float(state.get("mana", 0.0))
	var mana_max: float = maxf(float(state.get("mana_max", 1.0)), 1.0)
	var recharging: bool = bool(state.get("recharging", false))
	if _mana_fill != null:
		_mana_fill.size.x = BAR_W * clampf(mana / mana_max, 0.0, 1.0)
		_mana_fill.color = COL_MANA_CD if recharging else COL_MANA
	if _mana_label != null:
		_mana_label.text = "%.0f/%.0f" % [mana, mana_max]

	var lev: float = float(state.get("levitate", 100.0))
	var lev_max: float = maxf(float(state.get("levitate_max", 100.0)), 1.0)
	var lev_ratio := clampf(lev / lev_max, 0.0, 1.0)
	if _lev_fill != null:
		_lev_fill.size.x = BAR_W * lev_ratio
	if _lev_label != null:
		_lev_label.text = "%d%%" % roundi(lev_ratio * 100.0)

	var water: int = int(state.get("water", 0))
	var water_cap: int = maxi(int(state.get("water_cap", 200)), 1)
	var oil: int = int(state.get("oil", 0))
	var oil_cap: int = maxi(int(state.get("oil_cap", 100)), 1)
	var active_liq: String = String(state.get("liquid", "water"))
	if _water_fill != null:
		_water_fill.size.x = GOURD_W * clampf(float(water) / float(water_cap), 0.0, 1.0)
		_water_label.text = "水 %d/%d" % [water, water_cap]
		_water_border.color = COL_BORDER_SEL if active_liq == "water" else COL_BORDER_DIM
	if _oil_fill != null:
		_oil_fill.size.x = GOURD_W * clampf(float(oil) / float(oil_cap), 0.0, 1.0)
		_oil_label.text = "油 %d/%d" % [oil, oil_cap]
		_oil_border.color = COL_BORDER_SEL if active_liq == "oil" else COL_BORDER_DIM

	var sel: int = int(state.get("selected", 0))
	for i in range(_slot_borders.size()):
		var is_sel := (i == sel)
		_slot_borders[i].color = COL_BORDER_SEL if is_sel else COL_BORDER_DIM
		_slot_bgs[i].color = COL_SLOT_SEL if is_sel else COL_SLOT_BG

	if _mat_label != null:
		_mat_label.text = String(state.get("cursor_mat", "—"))
	if _exit_label != null:
		_exit_label.text = String(state.get("exit_hint", ""))

func log_event(text: String) -> void:
	_lines.push_front(text)
	while _lines.size() > MAX_LOG:
		_lines.pop_back()
	_refresh_log()

func clear_log() -> void:
	_lines.clear()
	_refresh_log()

func log_contains(fragment: String) -> bool:
	for line in _lines:
		if String(line).find(fragment) >= 0:
			return true
	return false

func show_complete(text: String) -> void:
	if _complete_bg != null:
		_complete_bg.visible = true
	if _complete != null:
		_complete.text = text
		_complete.visible = true

func clear_complete() -> void:
	if _complete_bg != null:
		_complete_bg.visible = false
	if _complete != null:
		_complete.visible = false
		_complete.text = ""

func _refresh_log() -> void:
	if _log_label == null:
		return
	if _lines.is_empty():
		_log_label.text = ""
		if _log_bg != null:
			_log_bg.visible = false
		return
	var text := ""
	for i in range(_lines.size()):
		if i > 0:
			text += "\n"
		text += String(_lines[i])
	_log_label.text = text
	if _log_bg != null:
		var min_sz := _log_label.get_minimum_size()
		_log_bg.size.x = clampf(min_sz.x + 20.0, 180.0, 460.0)
		_log_bg.size.y = maxf(min_sz.y + 10.0, float(_lines.size() * 26 + 8))
		_log_bg.visible = true
