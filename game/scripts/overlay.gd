extends Node2D
## T4b 轻量视觉反馈层（纯绘制，不引入玩法系统）：
## 1) 像素对齐瞄准准星（headless / shot_mode 下隐藏）；
## 2) 施法 / 吸液 / 喷液 / 手动点火的短暂光圈或线段反馈（让即时命中可感知）。

const SCALE := 4
const PULSE_DURATION := 0.22

var show_reticle := true
var aim_cell := Vector2i(-1, -1)
var _pulses: Array = []   # {kind, pos, to, radius, color, ttl, max_ttl}

func set_aim(cell: Vector2i) -> void:
	if aim_cell != cell:
		aim_cell = cell
		queue_redraw()

func add_ring(cell: Vector2i, radius_cells: float, color: Color, duration: float = PULSE_DURATION) -> void:
	_pulses.append({
		"kind": "ring",
		"pos": _cell_center(cell),
		"radius": maxf(radius_cells, 1.0) * float(SCALE),
		"color": color,
		"ttl": duration,
		"max_ttl": duration,
	})
	queue_redraw()

func add_line(from_cell: Vector2i, to_cell: Vector2i, color: Color, duration: float = PULSE_DURATION) -> void:
	_pulses.append({
		"kind": "line",
		"pos": _cell_center(from_cell),
		"to": _cell_center(to_cell),
		"color": color,
		"ttl": duration,
		"max_ttl": duration,
	})
	queue_redraw()

func clear_pulses() -> void:
	_pulses.clear()
	queue_redraw()

func _process(delta: float) -> void:
	if _pulses.is_empty():
		return
	var kept: Array = []
	for item in _pulses:
		var d: Dictionary = item
		var ttl: float = float(d["ttl"]) - delta
		if ttl > 0.0:
			d["ttl"] = ttl
			kept.append(d)
	_pulses = kept
	queue_redraw()

func _draw() -> void:
	if show_reticle and aim_cell.x >= 0 and aim_cell.y >= 0:
		var c := _cell_center(aim_cell)
		var col := Color(0.98, 0.94, 0.72, 0.85)
		var half := float(SCALE) * 1.5
		draw_rect(Rect2(c - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), col, false, 1.5)
		draw_line(c + Vector2(-half - 5.0, 0.0), c + Vector2(-half - 1.0, 0.0), col, 1.5)
		draw_line(c + Vector2(half + 1.0, 0.0), c + Vector2(half + 5.0, 0.0), col, 1.5)
		draw_line(c + Vector2(0.0, -half - 5.0), c + Vector2(0.0, -half - 1.0), col, 1.5)
		draw_line(c + Vector2(0.0, half + 1.0), c + Vector2(0.0, half + 5.0), col, 1.5)

	for item in _pulses:
		var d: Dictionary = item
		var ratio: float = clampf(float(d["ttl"]) / maxf(float(d["max_ttl"]), 0.01), 0.0, 1.0)
		var base: Color = d["color"]
		var col := Color(base.r, base.g, base.b, base.a * ratio)
		if String(d["kind"]) == "ring":
			draw_arc(d["pos"], float(d["radius"]), 0.0, TAU, 32, col, 2.0)
		elif String(d["kind"]) == "line":
			draw_line(d["pos"], d["to"], col, 3.0)

func _cell_center(c: Vector2i) -> Vector2:
	return Vector2((float(c.x) + 0.5) * float(SCALE), (float(c.y) + 0.5) * float(SCALE))
