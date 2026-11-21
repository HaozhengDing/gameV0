extends Node2D
## M1-10 反馈层·世界空间（打击感六层之 1 / 4 / 5）：枪口火光、命中火花与冲击环、击杀爆散、命中飘字。
## 纯表现：不读写玩法状态，输入全部来自 FeedbackDirector；正式美术阶段可整层替换为粒子资源。

const SCALE := 4
const MAX_SPARKS := 400

var _sparks: Array = []
var _rings: Array = []
var _glows: Array = []
var _flames: Array = []
var _texts: Array = []
var _font: Font
var _glow_tex: GradientTexture2D
var _num_seq := 0

func _ready() -> void:
	z_index = 6
	_font = ThemeDB.fallback_font
	if ResourceLoader.exists("res://ui_font.tres"):
		var f: Resource = load("res://ui_font.tres")
		if f is Font:
			_font = f
	_glow_tex = _make_glow_texture()
	set_process(true)

## 平滑径向光晕贴图（避免用同心圆叠出来的一圈圈硬边）。
func _make_glow_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	g.add_point(0.45, Color(1.0, 1.0, 1.0, 0.45))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 128
	t.height = 128
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t

func clear_all() -> void:
	_sparks.clear()
	_rings.clear()
	_glows.clear()
	_flames.clear()
	_texts.clear()
	queue_redraw()

func is_active() -> bool:
	return not (_sparks.is_empty() and _rings.is_empty() and _glows.is_empty() and _flames.is_empty() and _texts.is_empty())

## 第 1 层：枪口火光 —— 光晕 + 前向火星 + 短光柱（"枪口亮一下，人和墙被照亮"）。
func muzzle(origin_cell: Vector2, dir: Vector2, power: float, col: Color) -> void:
	var d := dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var base := origin_cell * float(SCALE)
	var tip := base + d * 2.0 * float(SCALE)
	_glows.append({"c": tip, "r": 34.0 + 16.0 * power, "life": 0.14, "max": 0.14, "col": col})
	_rings.append({"c": tip, "r0": 3.0, "r1": 26.0 + 14.0 * power, "life": 0.11, "max": 0.11, "col": col, "w": 2.5})
	_flames.append({
		"c": tip,
		"d": d,
		"len": 16.0 + 12.0 * power,
		"half_w": 4.0 + 3.0 * power,
		"life": 0.09,
		"max": 0.09,
		"col": col,
	})
	var n := int(round(8.0 + 6.0 * power))
	for i in range(n):
		var ang := randf_range(-0.45, 0.45)
		var spd := randf_range(150.0, 380.0) * (0.7 + 0.3 * power)
		var life := randf_range(0.08, 0.20)
		_sparks.append({
			"p": tip,
			"v": d.rotated(ang) * spd,
			"life": life,
			"max": life,
			"col": col,
			"size": randf_range(1.5, 3.0),
			"g": 220.0,
		})

## 第 4 / 5 层：命中（big=false）与击杀（big=true）—— 反向火星、冲击环、飘字。
func impact(pos_cell: Vector2, dir: Vector2, amount: float, col: Color, big: bool) -> void:
	var d := dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var base := pos_cell * float(SCALE)
	var n := 34 if big else 12
	for i in range(n):
		var vdir: Vector2
		if big:
			vdir = Vector2.RIGHT.rotated(randf() * TAU)
		else:
			vdir = (-d).rotated(randf_range(-0.6, 0.6))
		var spd := randf_range(120.0, 380.0) if big else randf_range(90.0, 260.0)
		var life := randf_range(0.18, 0.42) if big else randf_range(0.09, 0.20)
		_sparks.append({
			"p": base,
			"v": vdir * spd,
			"life": life,
			"max": life,
			"col": col,
			"size": randf_range(1.5, 4.0) if big else randf_range(1.0, 2.5),
			"g": 340.0,
		})
	var ring_life := 0.28 if big else 0.15
	_rings.append({
		"c": base,
		"r0": 4.0,
		"r1": 118.0 if big else 34.0,
		"life": ring_life,
		"max": ring_life,
		"col": col,
		"w": 3.0 if big else 2.0,
	})
	if big:
		_glows.append({"c": base, "r": 90.0, "life": 0.24, "max": 0.24, "col": col})
	if amount >= 0.5:
		damage_number(pos_cell, amount, col, big)

func damage_number(pos_cell: Vector2, amount: float, col: Color, big: bool) -> void:
	var txt := ("%d!" % int(round(amount))) if big else ("%d" % int(round(amount)))
	_num_seq = (_num_seq + 1) % 3
	_texts.append({
		"c": pos_cell * float(SCALE) + Vector2(randf_range(-6.0, 6.0), -10.0 - float(_num_seq) * 12.0),
		"v": Vector2(randf_range(-8.0, 8.0), -34.0),
		"s": txt,
		"life": 0.55,
		"max": 0.55,
		"col": col,
		"size": 30 if big else 22,
	})

## 反应触发：一圈彩色扩散环（与 C-EVT reaction_triggered 一一对应，强化"看得见因果"）。
func reaction_ring(pos_cell: Vector2, radius_cells: float, col: Color) -> void:
	_rings.append({
		"c": pos_cell * float(SCALE),
		"r0": 2.0,
		"r1": maxf(radius_cells, 1.0) * float(SCALE),
		"life": 0.35,
		"max": 0.35,
		"col": col,
		"w": 2.0,
	})

func update_fx(delta: float) -> void:
	if not is_active():
		return
	var keep: Array = []
	for s in _sparks:
		var d: Dictionary = s
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) <= 0.0:
			continue
		d["v"] = Vector2(d["v"]) + Vector2(0.0, float(d["g"])) * delta
		d["p"] = Vector2(d["p"]) + Vector2(d["v"]) * delta
		keep.append(d)
	_sparks = keep

	keep = []
	for r in _rings:
		var d: Dictionary = r
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			keep.append(d)
	_rings = keep

	keep = []
	for g in _glows:
		var d: Dictionary = g
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			keep.append(d)
	_glows = keep

	keep = []
	for fl in _flames:
		var d: Dictionary = fl
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			keep.append(d)
	_flames = keep

	keep = []
	for t in _texts:
		var d: Dictionary = t
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			d["c"] = Vector2(d["c"]) + Vector2(d["v"]) * delta
			d["v"] = Vector2(d["v"]) * 0.92
			keep.append(d)
	_texts = keep
	queue_redraw()

func _draw() -> void:
	if _glow_tex == null:
		_glow_tex = _make_glow_texture()
	for g in _glows:
		var d: Dictionary = g
		var k: float = clampf(float(d["life"]) / maxf(float(d["max"]), 0.001), 0.0, 1.0)
		var c: Color = d["col"]
		# 光晕随时间向外扩散（视频第 1 层："光晕向外扩散"）
		var r: float = float(d["r"]) * lerpf(1.25, 0.55, k)
		var rect := Rect2(Vector2(d["c"]) - Vector2(r, r), Vector2(r, r) * 2.0)
		draw_texture_rect(_glow_tex, rect, false, Color(c.r, c.g, c.b, 0.85 * k))

	for fl in _flames:
		var d: Dictionary = fl
		var k: float = clampf(float(d["life"]) / maxf(float(d["max"]), 0.001), 0.0, 1.0)
		var c: Color = d["col"]
		var dir: Vector2 = d["d"]
		var tip: Vector2 = Vector2(d["c"]) + dir * float(d["len"]) * (1.4 - 0.4 * k)
		var side := dir.orthogonal() * float(d["half_w"]) * k
		var pts := PackedVector2Array([Vector2(d["c"]) + side, tip, Vector2(d["c"]) - side])
		draw_colored_polygon(pts, Color(c.r, c.g, c.b, 0.85 * k))
		draw_circle(Vector2(d["c"]), float(d["half_w"]) * 1.6 * k, Color(1.0, 0.96, 0.88, 0.9 * k))

	for r in _rings:
		var d: Dictionary = r
		var t: float = 1.0 - clampf(float(d["life"]) / maxf(float(d["max"]), 0.001), 0.0, 1.0)
		var rad: float = lerpf(float(d["r0"]), float(d["r1"]), t)
		var c: Color = d["col"]
		draw_arc(d["c"], rad, 0.0, TAU, 28, Color(c.r, c.g, c.b, c.a * (1.0 - t)), float(d["w"]))

	for s in _sparks:
		var d: Dictionary = s
		var k: float = clampf(float(d["life"]) / maxf(float(d["max"]), 0.001), 0.0, 1.0)
		var c: Color = d["col"]
		var sz: float = float(d["size"])
		draw_rect(Rect2(Vector2(d["p"]) - Vector2(sz, sz), Vector2(sz, sz) * 2.0), Color(c.r, c.g, c.b, c.a * k))

	for t in _texts:
		var d: Dictionary = t
		var k: float = clampf(float(d["life"]) / maxf(float(d["max"]), 0.001), 0.0, 1.0)
		var c: Color = d["col"]
		var pos: Vector2 = Vector2(d["c"]) - Vector2(float(d["size"]) * 0.6, 0.0)
		draw_string(_font, pos, String(d["s"]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(d["size"]),
			Color(c.r, c.g, c.b, c.a * k))
