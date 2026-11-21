extends CanvasLayer
## M1-10 反馈层·屏幕空间（打击感六层之 3 的视觉部分）：命中白闪 + 受击边缘红晕。
## 可读性约束（D1/D3）：全屏闪白强度 <= 0.28、时长 <= 0.09s，只做"一下"的冲击，不遮蔽已知信息。

var _flash: ColorRect
var _edges: Array = []
var _flash_life := 0.0
var _flash_max := 0.001
var _flash_peak := 0.0
var _hurt_life := 0.0
var _hurt_max := 0.001
var _hurt_peak := 0.0

func _ready() -> void:
	layer = 1
	var root := Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_flash = ColorRect.new()
	_flash.name = "Flash"
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_flash)

	_edges.append(_make_edge(root, true, false, 64.0))
	_edges.append(_make_edge(root, true, true, 64.0))
	_edges.append(_make_edge(root, false, false, 76.0))
	_edges.append(_make_edge(root, false, true, 76.0))
	set_process(true)

func _make_edge(root: Control, horizontal: bool, tail: bool, thickness: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(0.62, 0.05, 0.06, 0.0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if horizontal:
		r.anchor_top = 1.0 if tail else 0.0
		r.anchor_bottom = r.anchor_top
		r.offset_top = -thickness if tail else 0.0
		r.offset_bottom = 0.0 if tail else thickness
		r.anchor_right = 1.0
	else:
		r.anchor_right = 1.0 if tail else 0.0
		r.anchor_left = r.anchor_right
		r.offset_right = 0.0 if tail else thickness
		r.offset_left = -thickness if tail else 0.0
		r.anchor_bottom = 1.0
	root.add_child(r)
	return r

## 命中/击杀白闪：强度按可读性上限钳制。
func flash(col: Color, strength: float, duration: float = 0.08) -> void:
	var s: float = clampf(strength, 0.0, 0.28)
	if s <= 0.001:
		return
	_flash.color = Color(col.r, col.g, col.b, s)
	_flash_peak = s
	_flash_max = maxf(duration, 0.01)
	_flash_life = _flash_max

## 受击：屏幕边缘红晕（不铺满全屏，保留对场地的读取）。
func hurt(strength: float) -> void:
	var s: float = clampf(strength, 0.0, 0.55)
	_hurt_peak = s
	_hurt_max = 0.34
	_hurt_life = _hurt_max
	for e in _edges:
		var r: ColorRect = e
		r.color = Color(0.62, 0.05, 0.06, s)

func clear_all() -> void:
	_flash_life = 0.0
	_hurt_life = 0.0
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	for e in _edges:
		var r: ColorRect = e
		r.color = Color(0.62, 0.05, 0.06, 0.0)

func tick(delta: float) -> void:
	if _flash_life > 0.0:
		_flash_life = maxf(_flash_life - delta, 0.0)
		var k: float = _flash_life / _flash_max
		_flash.color.a = _flash_peak * k * k
		if _flash_life <= 0.0:
			_flash.color.a = 0.0
	if _hurt_life > 0.0:
		_hurt_life = maxf(_hurt_life - delta, 0.0)
		var k: float = _hurt_life / _hurt_max
		for e in _edges:
			var r: ColorRect = e
			r.color.a = _hurt_peak * k
		if _hurt_life <= 0.0:
			for e in _edges:
				var r2: ColorRect = e
				r2.color.a = 0.0
