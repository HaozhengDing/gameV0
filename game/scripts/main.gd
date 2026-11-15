extends Node2D
## 《刍狗》T4a 灰盒：Godot 工程 + GDExtension 构建链 + 角色移动。
## 世界数据全部来自 C-SIM v1（sim_core），本脚本只做建关、驱动 tick、渲染纹理与输入。

const WORLD_W := 480
const WORLD_H := 270
const SCALE := 4
const SEED := 20261115
const TICK_HZ := 60

var sim: SimWorldNode
var player: Node2D
var hud: Label
var _hud_timer := 0

func _ready() -> void:
	# GDExtension 注册的类：SimWorldNode（见 game/gdextension/src/sim_node.cpp）
	sim = SimWorldNode.new()
	sim.name = "SimWorld"
	sim.set_scale(Vector2(SCALE, SCALE))
	sim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sim)

	# data/materials.json 在仓库根（工程目录的上一级）；读不到时 C-SIM 回退 builtin 材质表
	var materials_path := ProjectSettings.globalize_path("res://").path_join("../data/materials.json")
	if not sim.create_world(WORLD_W, WORLD_H, SEED, materials_path):
		push_error("T4A: sim_world_create 失败")
		return

	_build_test_level()
	_spawn_player()
	_spawn_hud()
	print("T4A_MAIN_READY world=%dx%d materials=%s" % [WORLD_W, WORLD_H, sim.get_materials_source()])

func _process(delta: float) -> void:
	if sim == null or not sim.has_world():
		return
	# T4a 用「每帧 1 tick」的简化驱动；T4b 改成固定步长累加器
	sim.step_tick()
	sim.update_texture()
	_hud_timer += delta
	if _hud_timer >= 0.25:
		_hud_timer = 0.0
		_update_hud()

func _unhandled_input(event: InputEvent) -> void:
	if sim == null or not sim.has_world():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var world_pos := get_global_mouse_position()
		var cx := int(world_pos.x) / SCALE
		var cy := int(world_pos.y) / SCALE
		sim.dig(cx, cy, 4)
		sim.update_texture()

# ---------------------------------------------------------------- 测试关卡

func _build_test_level() -> void:
	# 整屏先填岩层，再挖矿道，最后放物质池：这是灰盒，不是正式关卡（正式内容见 T4b）
	for y in range(WORLD_H):
		for x in range(WORLD_W):
			sim.set_cell(x, y, 1)  # SIM_MAT_ROCK

	# 主矿道：正弦起伏的水平走廊
	for x in range(1, WORLD_W - 1):
		var cy := 150 + int(18.0 * sin(float(x) / 26.0))
		for dy in range(-16, 17):
			var y := cy + dy
			if y > 2 and y < WORLD_H - 3:
				sim.set_cell(x, y, 0)

	# 主洞窟（椭圆）
	for y in range(115, 235):
		for x in range(255, 465):
			var dx := float(x - 360) / 95.0
			var dy := float(y - 175) / 52.0
			if dx * dx + dy * dy < 1.0:
				sim.set_cell(x, y, 0)

	# 物质池（沙/水/油/水银/火）——让模拟自己沉降分层
	_fill_rect(292, 205, 120, 14, "water")
	_fill_rect(372, 198, 44, 10, "oil")
	_fill_rect(80, 200, 70, 16, "sand")
	_fill_rect(198, 214, 34, 9, "quicksilver")
	_fill_rect(140, 138, 20, 4, "fire")
	print("T4A_LEVEL_BUILT")

func _fill_rect(p_x: int, p_y: int, p_w: int, p_h: int, p_material: String) -> void:
	for y in range(p_y, min(p_y + p_h, WORLD_H)):
		for x in range(p_x, min(p_x + p_w, WORLD_W)):
			sim.set_cell_by_name(x, y, p_material)

# ---------------------------------------------------------------- 角色 / UI

func _spawn_player() -> void:
	player = Node2D.new()
	player.name = "Player"
	player.set_script(preload("res://scripts/player.gd"))
	var body := ColorRect.new()
	body.name = "Body"
	body.color = Color(0.95, 0.85, 0.35, 1.0)
	body.size = Vector2(8, 10)
	body.position = Vector2(-4, -10)
	player.add_child(body)
	player.position = Vector2(70 * SCALE, 150 * SCALE)
	add_child(player)

func _spawn_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
	layer.add_child(hud)
	_update_hud()

func _update_hud() -> void:
	if hud == null or sim == null or not sim.has_world():
		return
	hud.text = "T4a 灰盒｜WASD 移动｜左键挖掘｜tick=%d｜materials=%s" % [
		sim.get_tick(), sim.get_materials_source()
	]
