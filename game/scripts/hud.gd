extends CanvasLayer
## T4b HUD：灵力/盏/葫芦/符组/施法反馈（一行状态）+ 事件日志（最近 3 条）+ 通关提示。
## 只做显示；数据由 main.gd 每 0.1s 推进来（update_status），事件由 executor/level 推进来（log_event）。

const MAX_LOG := 3
# 1920x1080 下默认 16px 太小；状态 28 / 日志 24 / 通关提示 56
const FONT_SIZE_STATUS := 28
const FONT_SIZE_LOG := 24
const FONT_SIZE_COMPLETE := 56

var _status: Label
var _log_label: Label
var _complete: Label
var _lines: Array = []

func _ready() -> void:
	layer = 10
	_status = _make_label(Vector2(16, 10), FONT_SIZE_STATUS, Color(0.96, 0.94, 0.86))
	_status.text = "T4b 灰盒启动中…"
	_log_label = _make_label(Vector2(16, 96), FONT_SIZE_LOG, Color(0.82, 0.86, 0.78))
	_complete = Label.new()
	_complete.name = "Complete"
	_complete.add_theme_font_size_override("font_size", FONT_SIZE_COMPLETE)
	_complete.add_theme_color_override("font_color", Color(0.98, 0.84, 0.32))
	_complete.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_complete.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_complete.visible = false
	add_child(_complete)
	var vs := get_viewport().get_visible_rect().size
	_complete.position = Vector2(0.0, vs.y * 0.5 - 80.0)
	_complete.size = Vector2(vs.x, 160.0)

func _make_label(pos: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	add_child(label)
	return label

func update_status(text: String) -> void:
	if _status != null:
		_status.text = text

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
	if _complete != null:
		_complete.text = text
		_complete.visible = true

func clear_complete() -> void:
	if _complete != null:
		_complete.visible = false
		_complete.text = ""

func _refresh_log() -> void:
	if _log_label == null:
		return
	if _lines.is_empty():
		_log_label.text = ""
		return
	var text := "最近事件："
	for i in range(_lines.size()):
		text += "\n  · " + String(_lines[i])
	_log_label.text = text
