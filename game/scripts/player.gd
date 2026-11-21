extends Node2D
## T4b 玩家：Noita 式轻量物理移动 —— 重力 + 地面摩擦 + 2-3 格碎屑自动迈步 + W/Space 有限浮空条
## + 液体浮力/阻力；火格按墙处理（必须喷水灭火后才能过）。
## 位置用世界像素（1 cell = SCALE px，SCALE=4），cell 坐标 = floor(position / SCALE)。
## 视觉/碰撞尺寸按 D4：5x10 cells（屏幕 20x40 px），脚在 cell_pos，身体占 x [cx-2, cx+2]、y [cy-9, cy]。

const PowderPhysics := preload("res://scripts/powder_physics.gd")

const SCALE := 4
const MOVE_SPEED := 60.0            # cells/s 水平最大速度（M1-α 收敛：68 -> 60）
const ACCEL_GROUND := 700.0         # cells/s^2 地面加速（跟手无滑冰感）
const DECEL_GROUND := 820.0         # cells/s^2 地面刹车
const ACCEL_AIR := 440.0            # cells/s^2 空中控制
const DECEL_AIR := 180.0            # cells/s^2 空中阻力
const GRAVITY := 260.0              # cells/s^2 重力加速度
const MAX_FALL_SPEED := 155.0       # cells/s 下落终端速度
const FAST_FALL_ACCEL := 180.0      # cells/s^2 按 S 加速下潜
const JUMP_IMPULSE := -82.0         # cells/s 地面起跳初速度
const HOVER_ACCEL := 390.0          # cells/s^2 W/Space 上升浮空推力（M1-α 收敛：480 -> 390）
const HOVER_BRAKE_ACCEL := 640.0    # cells/s^2 下落中按浮空的空中急刹（M1-α 收敛：780 -> 640）
const HOVER_MAX_UP := -76.0         # cells/s 向上最大速度（M1-α 收敛：-96 -> -76）
const LEVITATE_MAX := 100.0         # 浮空条上限（约 1.16s 连续推力，单气仍可爬升 ~88 格出 80 格水银池）
const LEVITATE_DRAIN := 86.0        # /s 浮空消耗（M1-α 收敛：52 -> 86）
const LEVITATE_REGEN := 145.0       # /s 落地快速回充（~0.69s 满）
const LEVITATE_REGEN_DELAY := 0.08  # s 落地停推后短延迟再回充
const LEVITATE_AIR_REGEN := 16.0    # /s 下落慢充速率（不足消耗 1/5，数学上杜绝点按无限滞空）
const AIR_REGEN_DELAY := 0.28       # s 停推后空中自由落体等待延迟（对照 Noita flying_in_air_wait_frames）
const AIR_REGEN_MIN_FALL_VY := 24.0 # cells/s 必须明确进入下落态才允许慢充
const COYOTE_TIME := 0.10           # s 离地宽容起跳时间（m1-jump-feel P0：0.08 -> 0.10，6 帧）
const JUMP_BUFFER := 0.10           # s 跳跃缓冲（m1-jump-feel P0：落地前按下不吞键）
const JUMP_CUT_WINDOW := 0.10       # s 可变跳高切断窗口（适配浮空条，过窗后不砍浮空惯性）
const JUMP_CUT := 0.35              # 窗口内松手切断上升倍率
const ENEMY_HURT_INVULN_TICKS := 24 # 0.40s 敌击无敌帧（防止近战贴身连帧秒杀）
const STEP_UP_MAX := 3              # cells 走过碎沙/粉堆自动迈步上限
const MAX_SUBSTEP_PX := 2.0         # 0.5 cell/步，防止穿墙或贴墙留缝

const BODY_HALF_W := 2              # cells：[cx-2, cx+2] = 5 cells
const BODY_HEIGHT := 10             # cells：脚在 cell_pos，头顶 = cell_pos.y - 9
const WORLD_W := 960
const WORLD_H := 540

const BODY_COLOR := Color(0.96, 0.86, 0.36)
const HURT_COLOR := Color(0.98, 0.28, 0.22)
const HURT_FLASH_SEC := 0.22
const RECOIL_RETURN := 70.0          # px/s 后坐力视觉位移的回弹速度（M1-10 第 2 层）

var sim: SimWorldNode
var facing := Vector2.RIGHT
var velocity := Vector2.ZERO        # cells/s
var levitate := LEVITATE_MAX
var on_ground := false
var in_liquid := false
var in_powder := false
var powder_speed_mult := 1.0
var is_thrusting := false
var input_enabled := true
var physics_enabled := true
var fire_blocks_movement := false   # M1 实机火焰/毒气不阻挡移动（仅经典 T4b 火墙模式开启）
var powder_wade_enabled := true     # 决策卡 powder-traversal.md#density-drag-wade 开关
var levitate_air_regen := LEVITATE_AIR_REGEN  # 设为 0.0 可一键对照纯落地回充

var fire_mat := -1
var quicksilver_mat := -1
var world_w := WORLD_W
var world_h := WORLD_H
var _density_by_id: Dictionary = {}

var _coyote_timer := 0.0
var _jump_buffer_timer := 0.0
var _jump_cut_timer := 0.0
var _jump_cut_used := false
var _regen_delay_timer := 0.0
var _air_regen_delay_timer := 0.0
var _powder_fill := 0.0
var _prev_thrust := false
var _hurt_timer := 0.0
var hurt_invuln_ticks := 0
var recoil := Vector2.ZERO           # 世界像素：法器后坐造成的人物视觉位移（不参与碰撞）
var _body_rect: ColorRect
var _eye_rect: ColorRect
var _jet_rect: ColorRect

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or not physics_enabled:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode in [KEY_W, KEY_UP, KEY_SPACE]:
			queue_jump_buffer()

## m1-jump-feel P0：事件驱动写入跳跃缓冲（避免轮询在两物理帧间吞键）。
func queue_jump_buffer() -> void:
	_jump_buffer_timer = JUMP_BUFFER

func setup(p_sim: SimWorldNode) -> void:
	sim = p_sim
	if sim != null and sim.has_world():
		fire_mat = sim.material_id("fire")
		quicksilver_mat = sim.material_id("quicksilver")
		world_w = sim.get_world_width()
		world_h = sim.get_world_height()
		_density_by_id = PowderPhysics.build_density_table(sim)
	_body_rect = get_node_or_null("Body") as ColorRect
	_eye_rect = get_node_or_null("Eye") as ColorRect
	_jet_rect = get_node_or_null("Jet") as ColorRect
	_update_visual()

func reset_motion() -> void:
	velocity = Vector2.ZERO
	levitate = LEVITATE_MAX
	on_ground = false
	in_liquid = false
	in_powder = false
	powder_speed_mult = 1.0
	is_thrusting = false
	_coyote_timer = 0.0
	_jump_buffer_timer = 0.0
	_jump_cut_timer = 0.0
	_jump_cut_used = false
	_regen_delay_timer = 0.0
	_air_regen_delay_timer = 0.0
	_powder_fill = 0.0
	_prev_thrust = false
	_hurt_timer = 0.0
	hurt_invuln_ticks = 0
	_update_visual()

func tick_invuln() -> void:
	if hurt_invuln_ticks > 0:
		hurt_invuln_ticks -= 1

func can_take_enemy_hit() -> bool:
	return hurt_invuln_ticks <= 0

func start_enemy_invuln() -> void:
	hurt_invuln_ticks = ENEMY_HURT_INVULN_TICKS

func apply_knockback(impulse_cells_per_sec: Vector2) -> void:
	velocity += impulse_cells_per_sec
	velocity.x = clampf(velocity.x, -140.0, 140.0)
	velocity.y = clampf(velocity.y, -110.0, MAX_FALL_SPEED)

func cell_pos() -> Vector2i:
	return Vector2i(floori(position.x / float(SCALE)), floori(position.y / float(SCALE)))

## 把玩家放到某个 cell 的中心（smoke / 重开 / 复位用）。
func set_cell_pos(c: Vector2i) -> void:
	position = Vector2(float(c.x * SCALE) + float(SCALE) * 0.5, float(c.y * SCALE) + float(SCALE) * 0.5)

## M1-10 第 2 层：法器后坐力 —— 人物视觉被推一下，随后回弹；不改碰撞与位置。
func add_recoil(v: Vector2) -> void:
	recoil += v
	if recoil.length() > 10.0:
		recoil = recoil.normalized() * 10.0
	_update_visual()

## 火伤视觉闪烁（与 HUD 格数变化形成双通道反馈）。
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
			if fire_blocks_movement and fire_mat >= 0 and sim.get_cell(gx, gy) == fire_mat:
				count += 1
	return count

## 仅静态实体（岩/竹木）或火格/越界：区分硬墙与落下的碎屑粉末，避免粉末锁死移动。
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
			if fire_blocks_movement and fire_mat >= 0 and m == fire_mat:
				return true
	return false

## 检测脚部与下身是否浸在液体中，并返回是否处于重液（水银）中。
func _sample_liquid() -> Dictionary:
	var out := {"liquid": false, "heavy": false}
	if sim == null or not sim.has_world():
		return out
	var c := cell_pos()
	var pts: Array[Vector2i] = [
		Vector2i(c.x, c.y - 1),
		Vector2i(c.x, c.y - 4),
		Vector2i(c.x - 1, c.y - 2),
		Vector2i(c.x + 1, c.y - 2),
	]
	for p in pts:
		if p.x < 0 or p.y < 0 or p.x >= world_w or p.y >= world_h:
			continue
		var m: int = sim.get_cell(p.x, p.y)
		if m > 0 and sim.get_material_state(m) == 2:
			out["liquid"] = true
			if m == quicksilver_mat:
				out["heavy"] = true
	return out

func _physics_process(delta: float) -> void:
	if _hurt_timer > 0.0:
		_hurt_timer = maxf(_hurt_timer - delta, 0.0)
	if recoil.length_squared() > 0.01:
		recoil = recoil.move_toward(Vector2.ZERO, RECOIL_RETURN * delta)
		_update_visual()
	if not physics_enabled or sim == null or not sim.has_world():
		_update_visual()
		return
	var move_x := 0.0
	var thrust := false
	var dive := false
	if input_enabled:
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			move_x -= 1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			move_x += 1.0
		thrust = Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_SPACE)
		dive = Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)
	step_physics(delta, move_x, thrust, dive)

## 独立物理步进（实机 _physics_process 与 --t4b-smoke 回归共用）。
func step_physics(delta: float, move_x: float, thrust: bool, dive: bool) -> void:
	var dt := minf(delta, 0.05)
	var liq := _sample_liquid()
	in_liquid = bool(liq["liquid"])
	var in_heavy := bool(liq["heavy"])
	var pc_now: Vector2i = cell_pos()
	if powder_wade_enabled:
		var psamp: Dictionary = PowderPhysics.sample_box(sim, pc_now.x, pc_now.y, BODY_HALF_W, BODY_HEIGHT, _density_by_id)
		in_powder = bool(psamp["in_powder"])
		_powder_fill = float(psamp["fill"])
		powder_speed_mult = float(psamp["speed_mult"])
	else:
		in_powder = false
		_powder_fill = 0.0
		powder_speed_mult = 1.0

	# 1) 接地判定与土狼时间（静态固体必定支撑；未按 S 且未深埋时粉堆表面也可站立）
	var grounded_now := _is_grounded_at(position, dive) and velocity.y >= -1.0
	on_ground = grounded_now
	if on_ground:
		_coyote_timer = COYOTE_TIME
	else:
		_coyote_timer = maxf(_coyote_timer - dt, 0.0)

	# 2) 水平速度（地面快启快停 / 空中可微调 / 液体与松散粉末分级减速）
	var env_mult := (0.72 if in_liquid else 1.0) * (powder_speed_mult if powder_wade_enabled else 1.0)
	var speed_cap := MOVE_SPEED * env_mult
	if absf(move_x) > 0.01:
		facing = Vector2(signf(move_x), 0.0)
		var accel := ACCEL_GROUND if on_ground else ACCEL_AIR
		velocity.x = move_toward(velocity.x, move_x * speed_cap, accel * dt)
	else:
		var decel := DECEL_GROUND if on_ground else DECEL_AIR
		velocity.x = move_toward(velocity.x, 0.0, decel * dt)

	# 3) 起跳（m1-jump-feel P0：土狼时间 + 跳跃缓冲 + 窗口内松手切断上升）+ 收敛浮空 + 下落延迟慢充
	var thrust_just_pressed := thrust and not _prev_thrust
	_prev_thrust = thrust
	if thrust_just_pressed:
		_jump_buffer_timer = JUMP_BUFFER
	is_thrusting = false
	var jumped_this_step := false

	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0 and not in_liquid:
		velocity.y = minf(velocity.y, JUMP_IMPULSE)
		_coyote_timer = 0.0
		_jump_buffer_timer = 0.0
		on_ground = false
		_jump_cut_timer = JUMP_CUT_WINDOW
		_jump_cut_used = false
		jumped_this_step = true
	elif _jump_buffer_timer > 0.0:
		_jump_buffer_timer = maxf(_jump_buffer_timer - dt, 0.0)

	# 可变跳高（§4-A）：只在起跳后 JUMP_CUT_WINDOW（0.10s）内松手切断上升；过窗后进浮空不砍惯性
	if not jumped_this_step and _jump_cut_timer > 0.0:
		if not thrust and not _jump_cut_used and velocity.y < 0.0:
			velocity.y *= JUMP_CUT
			_jump_cut_used = true
			_jump_cut_timer = 0.0
		else:
			_jump_cut_timer = maxf(_jump_cut_timer - dt, 0.0)

	if thrust and (levitate > 0.5 or in_liquid):
		is_thrusting = true
		_regen_delay_timer = LEVITATE_REGEN_DELAY
		_air_regen_delay_timer = AIR_REGEN_DELAY
		var up_powder_mult := clampf(powder_speed_mult + 0.15, 0.55, 1.0) if in_powder else 1.0
		var up_cap := HOVER_MAX_UP * (0.75 if in_liquid else 1.0) * up_powder_mult
		var thrust_accel := HOVER_BRAKE_ACCEL if velocity.y > 0.0 else HOVER_ACCEL
		velocity.y = maxf(velocity.y - thrust_accel * dt, up_cap)
		var drain_mult := 0.2 if in_liquid else 1.0
		levitate = maxf(levitate - LEVITATE_DRAIN * drain_mult * dt, 0.0)
	else:
		if _regen_delay_timer > 0.0:
			_regen_delay_timer = maxf(_regen_delay_timer - dt, 0.0)
		if on_ground:
			_air_regen_delay_timer = AIR_REGEN_DELAY
			if _regen_delay_timer <= 0.0:
				levitate = minf(levitate + LEVITATE_REGEN * dt, LEVITATE_MAX)
		elif not in_liquid and levitate_air_regen > 0.0:
			# 对照 Noita：停推后等足 AIR_REGEN_DELAY 且处于明确下落态才低速慢充，防点按无限飞
			if _air_regen_delay_timer > 0.0:
				_air_regen_delay_timer = maxf(_air_regen_delay_timer - dt, 0.0)
			elif velocity.y > AIR_REGEN_MIN_FALL_VY:
				levitate = minf(levitate + levitate_air_regen * dt, LEVITATE_MAX)
		# 重力 / 液体浮力 / 粉末阻力缓沉
		if in_heavy:
			# 水银密度 13.6：浸入时给轻浮力，不会沉死在池底
			velocity.y = move_toward(velocity.y, -18.0, 140.0 * dt)
		elif in_liquid:
			velocity.y = minf(velocity.y + GRAVITY * 0.35 * dt, MAX_FALL_SPEED * 0.45)
		elif in_powder:
			velocity.y = minf(velocity.y + GRAVITY * 0.60 * dt, MAX_FALL_SPEED * powder_speed_mult * 0.55)
		else:
			velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL_SPEED)

	if dive and not on_ground:
		var dive_cap := MAX_FALL_SPEED * (powder_speed_mult * 0.70 if in_powder else 1.15)
		velocity.y = minf(velocity.y + FAST_FALL_ACCEL * dt, dive_cap)

	# 4) 分轴子步积分（水平带 1-3 格像素迈步与松散粉末穿行，垂直碰地/顶清零速度）
	var dx_px := velocity.x * float(SCALE) * dt
	var dy_px := velocity.y * float(SCALE) * dt
	if not _move_horizontal(dx_px):
		velocity.x = 0.0
	if not _move_vertical(dy_px, dive):
		if velocity.y > 0.0:
			on_ground = true
		velocity.y = 0.0

	# 5) 落地确认
	if not on_ground and velocity.y >= 0.0 and _is_grounded_at(position, dive):
		on_ground = true

	_update_visual()

func _is_grounded_at(px_pos: Vector2, dive: bool) -> bool:
	if not powder_wade_enabled:
		return _blocked_count(px_pos + Vector2(0.0, 1.0)) > 0
	if _hard_blocked_at(px_pos + Vector2(0.0, 1.0)):
		return true
	if dive or _powder_fill >= 0.28:
		return false
	var c := Vector2i(floori(px_pos.x / float(SCALE)), floori((px_pos.y + 1.0) / float(SCALE)))
	return PowderPhysics.has_surface_below(sim, c.x, c.y, BODY_HALF_W, true)

## 水平子步移动；遇到 1-3 格碎屑/起伏自动向上迈步，遇到更高松散粉堆时减速涉过而非硬卡死。
func _move_horizontal(total_dx: float) -> bool:
	var dist := absf(total_dx)
	if dist < 0.0001:
		return true
	var steps := maxi(ceili(dist / MAX_SUBSTEP_PX), 1)
	var sub_x := total_dx / float(steps)
	for i in range(steps):
		var target := position + Vector2(sub_x, 0.0)
		var target_blocks := _blocked_count(target)
		if target_blocks == 0:
			position = target
			continue
		# 优先尝试向上迈 1..STEP_UP_MAX 格（自然走上平缓煤/硫斜坡）
		var stepped := false
		for lift in range(1, STEP_UP_MAX + 1):
			var lifted := target + Vector2(0.0, -float(lift * SCALE))
			if _blocked_count(lifted) == 0:
				position = lifted
				stepped = true
				break
		if stepped:
			continue
		# 粉末涉过模式：只要未撞静态硬墙（岩/竹木），即可穿过松散粉末（由上层密度倍率减速）
		if powder_wade_enabled and not _hard_blocked_at(target):
			position = target
			continue
		# 经典脱困兜底
		var cur_blocks := _blocked_count(position)
		if cur_blocks > 0 and not _hard_blocked_at(target) and target_blocks <= cur_blocks:
			position = target
			continue
		return false
	return true

func _move_vertical(total_dy: float, dive: bool = false) -> bool:
	var dist := absf(total_dy)
	if dist < 0.0001:
		return true
	var steps := maxi(ceili(dist / MAX_SUBSTEP_PX), 1)
	var sub_y := total_dy / float(steps)
	for i in range(steps):
		var target := position + Vector2(0.0, sub_y)
		if powder_wade_enabled:
			if _hard_blocked_at(target):
				return false
			if sub_y < 0.0:
				# 上升穿行松散粉末与落尘不被挡顶
				position = target
				continue
			# 向下落：未按 S 且未深埋时踩到粉坡顶即平稳站住；按 S 或已涉入粉堆则缓沉穿过
			if not dive and _powder_fill < 0.28 and _blocked_count(target) > _blocked_count(position):
				return false
			position = target
			continue
		var target_blocks := _blocked_count(target)
		if target_blocks == 0:
			position = target
			continue
		var cur_blocks := _blocked_count(position)
		if cur_blocks > 0 and not _hard_blocked_at(target) and target_blocks <= cur_blocks:
			position = target
			continue
		return false
	return true

func _update_visual() -> void:
	if _body_rect != null:
		_body_rect.color = HURT_COLOR if _hurt_timer > 0.0 else BODY_COLOR
		_body_rect.position = Vector2(float(-2 * SCALE), float(-10 * SCALE)) + recoil
	if _eye_rect != null:
		var ox := 1.0 if facing.x >= 0.0 else -2.0
		_eye_rect.position = Vector2(ox * float(SCALE), float(-8 * SCALE)) + recoil
	if _jet_rect != null:
		_jet_rect.position = Vector2(float(-1 * SCALE), 0.0) + recoil
		_jet_rect.visible = is_thrusting
		if is_thrusting:
			var flick := 1.0 + 0.35 * sin(float(Time.get_ticks_msec()) * 0.05)
			_jet_rect.size.y = float(3 * SCALE) * flick
