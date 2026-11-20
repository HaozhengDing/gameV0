extends CanvasLayer
## T4b HUD：灵力/盏/葫芦/符组/指向材质/施法反馈（状态栏）+ 事件日志（最近 4 条）+ 键位提示 + 通关提示。
## 只做显示；数据由 main.gd 每 0.1s 推进来（update_status），事件由 executor/level 推进来（log_event）。

const MAX_LOG := 4
# 1920x1080 下默认 16px 太小；状态 26 / 日志 22 / 键位 20 / 通关提示 56
const FONT_SIZE_STATUS := 26
const FONT_SIZE_LOG := 22
const FONT_SIZE_HELP := 20
const FONT_SIZE_COMPLETE := 56
const PANEL_BG := Color(0.06, 0.06, 0.09, 0.68)
const HELP_TEXT := "WASD 移动 | 1-4 切符 | 左键 施法 | E 吸液 | Q 喷液 | Tab 水/油 | F 手动点火 | R 重开"

var _status_bg: ColorRect
var _log_bg: ColorRect
var _help_bg: ColorRect
var _complete_bg: ColorRect
var _status: Label
var _log_label: Label
var _help_label: Label
var _complete: Label
var _lines: Array = []

func _ready() -> void:
	layer = 10
	var vs := get_viewport().get_visible_rect().size
	_status_bg = _make_panel(Vector2(10, 8), Vector2(1180.0, 84.0), PANEL_BG)
	_status = _make_label(Vector2(20, 12), FONT_SIZE_STATUS, Color(0.96, 0.94, 0.86))
	_status.text = "T4b 灰盒启动中…"

	_log_bg = _make_panel(Vector2(10, 98), Vector2(620.0, 152.0), Color(0.06, 0.06, 0.09, 0.58))
	_log_bg.visible = false
	_log_label = _make_label(Vector2(20, 104), FONT_SIZE_LOG, Color(0.84, 0.90, 0.80))

	_help_bg = _make_panel(Vector2(0.0, vs.y - 38.0), Vector2(vs.x, 38.0), Color(0.05, 0.05, 0.08, 0.66))
	_help_label = _make_label(Vector2(16, vs.y - 33.0), FONT_SIZE_HELP, Color(0.82, 0.82, 0.78))
	_help_label.text = HELP_TEXT

	_complete_bg = _make_panel(Vector2(0.0, vs.y * 0.5 - 92.0), Vector2(vs.x, 184.0), Color(0.05, 0.08, 0.06, 0.80))
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

func _make_panel(pos: Vector2, sz: Vector2, color: Color) -> ColorRect:
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

func update_status(text: String) -> void:
	if _status != null:
		_status.text = text
		if _status_bg != null:
			var vs := get_viewport().get_visible_rect().size
			var min_sz := _status.get_minimum_size()
			if min_sz.x > 0.0:
				_status_bg.size.x = clampf(min_sz.x + 28.0, 520.0, vs.x - 20.0)
				_status_bg.size.y = maxf(min_sz.y + 12.0, 76.0)

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
	var text := "最近事件："
	for i in range(_lines.size()):
		text += "\n  · " + String(_lines[i])
	_log_label.text = text
	if _log_bg != null:
		var vs := get_viewport().get_visible_rect().size
		var min_sz := _log_label.get_minimum_size()
		_log_bg.size.x = clampf(min_sz.x + 28.0, 320.0, vs.x - 20.0)
		_log_bg.size.y = maxf(min_sz.y + 14.0, float(36 + _lines.size() * 28))
		_log_bg.visible = true
