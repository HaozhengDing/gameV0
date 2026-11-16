extends Node2D
## T4b 玩家：cell 级碰撞移动（sim.is_solid），分轴滑动；火格按墙处理（必须喷水灭火后才能过）。
## 位置用世界像素（1 cell = SCALE px，SCALE=4），cell 坐标 = floor(position / SCALE)。
## 视觉/碰撞尺寸按 D4：1 cell = 1 世界像素、480x270 内部分辨率 @4x 放大 -> 角色约 5x10 cells
## （屏幕 20x40 px）。脚在 cell_pos，身体占 cells x [cx-2, cx+2]、y [cy-9, cy]。
## 说明：T4B.md §3 只要求 is_solid 阻挡；火格阻挡是让「火障必须灭火才能过」成立的灰盒规则，
## 关掉 FIRE_BLOCKS_MOVEMENT 就退回「火可以穿过、只掉盏」的行为。

const SCALE := 4
const SPEED_CELLS_PER_SEC := 48.0
const BODY_HALF_W := 2   # cells：身体横向占 [cx-2, cx+2] = 5 cells
const BODY_HEIGHT := 10  # cells：脚在 cell_pos，头顶 = cell_pos.y - 9
const FIRE_BLOCKS_MOVEMENT := true
const WORLD_W := 960
const WORLD_H := 540

var sim: SimWorldNode
var facing := Vector2.RIGHT
var fire_mat := -1
var world_w := WORLD_W
var world_h := WORLD_H

func setup(p_sim: SimWorldNode) -> void:
	sim = p_sim
	if sim != null and sim.has_world():
		fire_mat = sim.material_id("fire")
		world_w = sim.get_world_width()
		world_h = sim.get_world_height()

func cell_pos() -> Vector2i:
	return Vector2i(floori(position.x / float(SCALE)), floori(position.y / float(SCALE)))

## 把玩家放到某个 cell 的中心（smoke / 重开 / 复位用）。
func set_cell_pos(c: Vector2i) -> void:
	position = Vector2(float(c.x * SCALE) + float(SCALE) * 0.5, float(c.y * SCALE) + float(SCALE) * 0.5)

## 是否可以在 px_pos 处站人（越界 / solid / 火格 -> 不可进入）。
func blocked_at(px_pos: Vector2) -> bool:
	if sim == null or not sim.has_world():
		return true
	var cx := floori(px_pos.x / float(SCALE))
	var cy := floori(px_pos.y / float(SCALE))
	for gy in range(cy - BODY_HEIGHT + 1, cy + 1):
		for gx in range(cx - BODY_HALF_W, cx + BODY_HALF_W + 1):
			if gx < 0 or gy < 0 or gx >= world_w or gy >= world_h:
				return true
			if sim.is_solid(gx, gy):
				return true
			if FIRE_BLOCKS_MOVEMENT and fire_mat >= 0 and sim.get_cell(gx, gy) == fire_mat:
				return true
	return false

func _physics_process(delta: float) -> void:
	if sim == null or not sim.has_world():
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir == Vector2.ZERO:
		return
	dir = dir.normalized()
	facing = dir
	var step := dir * SPEED_CELLS_PER_SEC * float(SCALE) * delta
	# 分轴滑动：一轴被挡住时另一轴继续走
	_move_axis(Vector2(step.x, 0.0))
	_move_axis(Vector2(0.0, step.y))

func _move_axis(step: Vector2) -> void:
	if step == Vector2.ZERO:
		return
	var target := position + step
	if not blocked_at(target):
		position = target
