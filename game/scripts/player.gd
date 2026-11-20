extends Node2D
## T4b 玩家：cell 级碰撞移动（sim.is_solid），分轴滑动；火格按墙处理（必须喷水灭火后才能过）。
## 位置用世界像素（1 cell = SCALE px，SCALE=4），cell 坐标 = floor(position / SCALE)。
## 视觉/碰撞尺寸按 D4：1 cell = 1 世界像素、480x270 内部分辨率 @4x 放大 -> 角色约 5x10 cells
## （屏幕 20x40 px）。脚在 cell_pos，身体占 cells x [cx-2, cx+2]、y [cy-9, cy]。
## 说明：T4B.md §3 只要求 is_solid 阻挡；火格阻挡是让「火障必须灭火才能过」成立的灰盒规则，
## 关掉 FIRE_BLOCKS_MOVEMENT 就退回「火可以穿过、只掉盏」的行为。

const SCALE := 4
const SPEED_CELLS_PER_SEC := 64.0
const MAX_SUBSTEP_PX := 2.0   # 0.5 cell/步，防止帧率波动穿墙或贴墙留缝
const BODY_HALF_W := 2        # cells：身体横向占 [cx-2, cx+2] = 5 cells
const BODY_HEIGHT := 10       # cells：脚在 cell_pos，头顶 = cell_pos.y - 9
const FIRE_BLOCKS_MOVEMENT := true
const WORLD_W := 960
const WORLD_H := 540
const BODY_COLOR := Color(0.96, 0.86, 0.36)
const HURT_COLOR := Color(0.98, 0.28, 0.22)
const HURT_FLASH_SEC := 0.22

var sim: SimWorldNode
var facing := Vector2.RIGHT
var fire_mat := -1
var world_w := WORLD_W
var world_h := WORLD_H
var input_enabled := true
var _hurt_timer := 0.0
var _body_rect: ColorRect
var _eye_rect: ColorRect

func setup(p_sim: SimWorldNode) -> void:
	sim = p_sim
	if sim != null and sim.has_world():
		fire_mat = sim.material_id("fire")
		world_w = sim.get_world_width()
		world_h = sim.get_world_height()
	_body_rect = get_node_or_null("Body") as ColorRect
	_eye_rect = get_node_or_null("Eye") as ColorRect
	_update_visual()

func cell_pos() -> Vector2i:
	return Vector2i(floori(position.x / float(SCALE)), floori(position.y / float(SCALE)))

## 把玩家放到某个 cell 的中心（smoke / 重开 / 复位用）。
func set_cell_pos(c: Vector2i) -> void:
	position = Vector2(float(c.x * SCALE) + float(SCALE) * 0.5, float(c.y * SCALE) + float(SCALE) * 0.5)

## 火伤视觉闪烁（与 HUD 文字形成双通道反馈）。
func trigger_hurt_flash() -> void:
	_hurt_timer = HURT_FLASH_SEC
	_update_visual()

## 是否可以在 px_pos 处站人（越界 / solid / 火格 -> 不可进入）。
func blocked_at(px_pos: Vector2) -> bool:
	return _blocked_count(px_pos) > 0

func _blocked_count(px_pos: Vector2) -> int:
	if sim == null or not sim.has_world():
		return 1
	var cx := floori(px_pos.x / float(SCALE))
	var cy := floori(px_pos.y / float(SCALE))
	var count := 0
	for gy in range(cy - BODY_HEIGHT + 1, cy + 1):
		for gx in range(cx - BODY_HALF_W, cx + BODY_HALF_W + 1):
			if gx < 0 or gy < 0 or gx >= world_w or gy >= world_h:
				count += 1
				continue
			if sim.is_solid(gx, gy):
				count += 1
				continue
			if FIRE_BLOCKS_MOVEMENT and fire_mat >= 0 and sim.get_cell(gx, gy) == fire_mat:
				count += 1
	return count

## 仅静态实体（岩/竹木）或火格/越界：用于区分「墙/火」与「落下的碎屑粉末」，避免粉末把玩家锁死。
func _hard_blocked_at(px_pos: Vector2) -> bool:
	if sim == null or not sim.has_world():
		return true
	var cx := floori(px_pos.x / float(SCALE))
	var cy := floori(px_pos.y / float(SCALE))
	for gy in range(cy - BODY_HEIGHT + 1, cy + 1):
		for gx in range(cx - BODY_HALF_W, cx + BODY_HALF_W + 1):
			if gx < 0 or gy < 0 or gx >= world_w or gy >= world_h:
				return true
			var m: int = sim.get_cell(gx, gy)
			if m > 0 and sim.get_material_state(m) == 4:
				return true
			if FIRE_BLOCKS_MOVEMENT and fire_mat >= 0 and m == fire_mat:
				return true
	return false

func _physics_process(delta: float) -> void:
	if _hurt_timer > 0.0:
		_hurt_timer = maxf(_hurt_timer - delta, 0.0)
		_update_visual()
	if not input_enabled or sim == null or not sim.has_world():
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
	_update_visual()
	var step := dir * SPEED_CELLS_PER_SEC * float(SCALE) * delta
	# 分轴子步滑动：一轴被挡住时另一轴继续走，贴墙无间隙
	_move_axis(Vector2(step.x, 0.0))
	_move_axis(Vector2(0.0, step.y))

func _move_axis(total_step: Vector2) -> void:
	var dist := total_step.length()
	if dist < 0.0001:
		return
	var steps := maxi(ceili(dist / MAX_SUBSTEP_PX), 1)
	var sub := total_step / float(steps)
	for i in range(steps):
		var target := position + sub
		var target_blocks := _blocked_count(target)
		if target_blocks == 0:
			position = target
			continue
		# 脱困：若落下粉末（沙/煤/硫）叠进身体，允许在不撞硬墙/火的前提下向外移动
		var cur_blocks := _blocked_count(position)
		if cur_blocks > 0 and not _hard_blocked_at(target) and target_blocks <= cur_blocks:
			position = target
			continue
		break

func _update_visual() -> void:
	if _body_rect != null:
		_body_rect.color = HURT_COLOR if _hurt_timer > 0.0 else BODY_COLOR
	if _eye_rect != null:
		var ox := 1.0 if facing.x >= 0.0 else -2.0
		_eye_rect.position = Vector2(ox * float(SCALE), float(-8 * SCALE))
