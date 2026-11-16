extends Node2D
## 《刍狗》T4b 灰盒入口（game/T4B.md）：
## 960x540 cells 世界 + data/rooms 两个房间 + 相机跟随（只渲染视口 region）+ 固定步长 1/60 主循环
## + 输入（WASD 移动、左键施法、1-4 选符组、E 吸、Q 喷、Tab 换液体、R 重开）
## + --t4b-smoke 自检（脚本化走一遍：化水 -> 取水 -> 灭火 -> 通关，打印 T4B_SMOKE_OK 后退出 0）。
## 依赖：SimWorldNode / TalismanVMNode（game/gdextension/API.md）。世界层代码只在 scripts/ 下。

const WORLD_W := 960
const WORLD_H := 540
const SCALE := 4
const VIEW_W := 480
const VIEW_H := 270
const SEED := 20261116
const FIXED_DT := 1.0 / 60.0
const LANTERNS_MAX := 7
const ACTIVE_MARGIN := 64       # 活动区 = 视口外扩 64 cells（T4B.md §2）
const HUD_INTERVAL := 0.1
const HEADLESS_NAME := "headless"
const SHOT_WAIT := 0.6          # --t4b-shot：先跑 ~0.6s 让 sim/纹理就绪再截图
const SHOT_FILE := "../t4b_shot.png"

const LevelScript := preload("res://scripts/level.gd")
const PlayerScript := preload("res://scripts/player.gd")
const ExecutorScript := preload("res://scripts/executor.gd")
const HudScript := preload("res://scripts/hud.gd")

# 场景节点
var sim: SimWorldNode
var vm: TalismanVMNode
var level
var player
var camera: Camera2D
var hud
var executor
var exit_marker: ColorRect

# 玩法状态
var group_ids: Array = []
var group_names: Array = []
var selected_group := 0
var completed := false
var smoke_mode := false
var shot_mode := false
var _world_ready := false
var _shot_timer := 0.0
var _shot_done := false
var _accum := 0.0
var _hud_timer := 0.0
var _last_view := Vector2i(-999999, -999999)

# ================================================================== 生命周期

func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	smoke_mode = user_args.has("--t4b-smoke")
	shot_mode = user_args.has("--t4b-shot")
	if smoke_mode:
		set_physics_process(false)
		set_process(false)
	_setup()
	if not _world_ready:
		if smoke_mode:
			push_error("T4B_SMOKE_FAIL: 世界初始化失败")
			_quit(1)
		return
	if smoke_mode:
		call_deferred("_run_smoke")
	elif shot_mode:
		_setup_shot()

func _setup() -> void:
	_create_sim()
	if sim == null or not sim.has_world():
		push_error("T4B: 世界创建失败，无法启动")
		return
	_create_level()
	_create_player()
	_create_vm()
	_create_hud()
	_create_executor()
	_start_round()
	_refresh_hud()
	_apply_view()
	_world_ready = true
	print("T4B_WORLD_READY world=%dx%d scale=%d materials=%s start=%s exit=%s groups=%d" % [
		WORLD_W, WORLD_H, SCALE, sim.get_materials_source(),
		str(LevelScript.START_CELL), str(LevelScript.EXIT_CELL), group_ids.size()
	])

func _quit(code: int) -> void:
	var tree := get_tree()
	if tree != null:
		tree.quit(code)

# ================================================================== 固定步长主循环

func _physics_process(delta: float) -> void:
	if not _world_ready:
		return
	# 固定步长 1/60 累加器：与渲染帧率解耦（physics_ticks_per_second 已设 60）
	_accum += delta
	if _accum > 0.25:
		_accum = 0.25
	while _accum >= FIXED_DT:
		_accum -= FIXED_DT
		_tick_once()

func _tick_once() -> void:
	sim.step_tick()
	vm.tick_advance()
	level.tick_fire_wall()
	if completed:
		return
	if executor.tick_hazards(player.cell_pos()):
		player.set_cell_pos(LevelScript.START_CELL)
		hud.log_event("盏尽，回到起点")
		_refresh_hud()
	_check_exit_now()

func _process(delta: float) -> void:
	if not _world_ready:
		return
	_apply_view()
	_hud_timer += delta
	if _hud_timer >= HUD_INTERVAL:
		_hud_timer = 0.0
		_refresh_hud()
	if shot_mode and not _shot_done:
		_shot_timer += delta
		if _shot_timer >= SHOT_WAIT:
			_shot_done = true
			_take_shot()

## 每帧只渲染视口：view = 玩家 cell − (240,135)，裁到世界内 480x270；
## sim.update_texture_region(vx,vy,480,270)；sim.position = (vx,vy)*4；活动区外扩 64 cells。
func _apply_view() -> void:
	if sim == null or not sim.has_world() or player == null:
		return
	var pc: Vector2i = player.cell_pos()
	var vx := clampi(pc.x - VIEW_W / 2, 0, maxi(WORLD_W - VIEW_W, 0))
	var vy := clampi(pc.y - VIEW_H / 2, 0, maxi(WORLD_H - VIEW_H, 0))
	sim.set_active_rect(vx - ACTIVE_MARGIN, vy - ACTIVE_MARGIN, VIEW_W + ACTIVE_MARGIN * 2, VIEW_H + ACTIVE_MARGIN * 2)
	if vx != _last_view.x or vy != _last_view.y:
		_last_view = Vector2i(vx, vy)
		sim.wake_rect(vx - ACTIVE_MARGIN, vy - ACTIVE_MARGIN, VIEW_W + ACTIVE_MARGIN * 2, VIEW_H + ACTIVE_MARGIN * 2)
	if DisplayServer.get_name() == HEADLESS_NAME:
		return
	sim.update_texture_region(vx, vy, VIEW_W, VIEW_H)
	sim.position = Vector2(float(vx), float(vy)) * float(SCALE)
	if camera != null:
		# 相机中心 = 视口中心（与 region 严格对齐；相机 limit 与上面的 clamp 一致）
		camera.global_position = Vector2(float(vx + VIEW_W / 2), float(vy + VIEW_H / 2)) * float(SCALE)

# ================================================================== 装配

func _create_sim() -> void:
	sim = SimWorldNode.new()
	sim.name = "SimWorld"
	sim.centered = false
	sim.set_scale(Vector2(SCALE, SCALE))
	sim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sim)
	if not sim.create_world(WORLD_W, WORLD_H, SEED, _materials_path()):
		push_error("T4B: SimWorldNode.create_world 失败")
		sim = null

func _materials_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../data/materials.json")

func _cards_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../data/talismans.json")

func _create_level() -> void:
	level = LevelScript.new()
	level.setup(sim)
	# 出口区视觉标记（3x3 cells）；HUD 另有「向东到出口」提示
	exit_marker = ColorRect.new()
	exit_marker.name = "ExitMarker"
	exit_marker.color = Color(0.22, 0.95, 0.45, 0.45)
	exit_marker.size = Vector2(float(SCALE * 3), float(SCALE * 3))
	exit_marker.position = Vector2(
		float((LevelScript.EXIT_CELL.x - 1) * SCALE),
		float((LevelScript.EXIT_CELL.y - 1) * SCALE)
	)
	add_child(exit_marker)

func _create_player() -> void:
	player = PlayerScript.new()
	player.name = "Player"
	# 角色视觉 ~5x10 cells（D4：1 cell = 1 世界像素 @4x 放大 -> 20x40 屏幕像素）
	var body := ColorRect.new()
	body.name = "Body"
	body.color = Color(0.96, 0.86, 0.36)
	body.size = Vector2(float(5 * SCALE), float(10 * SCALE))
	body.position = Vector2(float(-2 * SCALE), float(-10 * SCALE))
	player.add_child(body)
	add_child(player)
	player.setup(sim)
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = WORLD_W * SCALE
	camera.limit_bottom = WORLD_H * SCALE
	camera.position_smoothing_enabled = false
	player.add_child(camera)

func _create_vm() -> void:
	vm = TalismanVMNode.new()
	vm.name = "TalismanVM"
	add_child(vm)
	if not vm.load_cards(_cards_path()):
		push_error("T4B: TalismanVMNode.load_cards 失败：" + _cards_path())
	group_ids = vm.get_group_ids()
	group_names.clear()
	var groups: Array = vm.get_groups()
	for g in groups:
		if g is Dictionary:
			var gd: Dictionary = g
			group_names.append(String(gd.get("name", String(gd.get("id", "")))))

func _create_hud() -> void:
	hud = HudScript.new()
	hud.name = "HUD"
	add_child(hud)

func _create_executor() -> void:
	executor = ExecutorScript.new()
	executor.setup(sim, vm, level, player, hud)

func _start_round() -> void:
	completed = false
	selected_group = 0
	if not level.build():
		push_error("T4B: level.build 失败")
	player.setup(sim)
	player.set_cell_pos(LevelScript.START_CELL)
	executor.reset_round()
	vm.reset()
	_last_view = Vector2i(-999999, -999999)

# ================================================================== 输入

func _unhandled_input(event: InputEvent) -> void:
	if not _world_ready or smoke_mode:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_do_cast(_aim_cell())
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_1:
				_select_group(0)
			KEY_2:
				_select_group(1)
			KEY_3:
				_select_group(2)
			KEY_4:
				_select_group(3)
			KEY_E:
				executor.absorb(_aim_cell())
			KEY_Q:
				executor.spray(player.cell_pos(), _aim_cell())
			KEY_TAB:
				executor.toggle_liquid()
			KEY_R:
				_restart()
			_:
				return
		get_viewport().set_input_as_handled()
		_refresh_hud()

## 鼠标瞄准：屏幕/世界像素 -> cell。headless 无鼠标时退化为「玩家朝向前方 8 格」。
func _aim_cell() -> Vector2i:
	if player == null:
		return Vector2i.ZERO
	if DisplayServer.get_name() == HEADLESS_NAME:
		return player.cell_pos() + Vector2i(roundi(player.facing.x), roundi(player.facing.y)) * 8
	var mp := get_global_mouse_position()
	return Vector2i(
		clampi(floori(mp.x / float(SCALE)), 0, WORLD_W - 1),
		clampi(floori(mp.y / float(SCALE)), 0, WORLD_H - 1)
	)

func _do_cast(aim: Vector2i) -> void:
	if group_ids.is_empty():
		return
	executor.cast(String(group_ids[selected_group]), aim)

func _select_group(index: int) -> void:
	if group_ids.is_empty():
		return
	selected_group = wrapi(index, 0, group_ids.size())
	hud.log_event("切换符组 %d：%s" % [selected_group + 1, String(group_names[selected_group])])

# ================================================================== 重开

func _restart() -> void:
	if not _world_ready:
		return
	if not sim.create_world(WORLD_W, WORLD_H, SEED, _materials_path()):
		push_error("T4B: 重开时 create_world 失败")
		return
	_start_round()
	hud.clear_complete()
	hud.clear_log()
	hud.log_event("重开本轮")
	_refresh_hud()
	_apply_view()

# ================================================================== --t4b-shot 截图

## 窗口模式目检用：把玩家放到房间 01 中部（朝东，画面能同时看到水银池 / 东门走廊 / 火障），
## 先跑 SHOT_WAIT 秒让 sim 跑几帧、纹理上传完成，再截当前 viewport 到 ../t4b_shot.png 后退出 0。
func _setup_shot() -> void:
	player.set_cell_pos(LevelScript.SHOT_PLAYER_CELL)
	player.facing = Vector2.RIGHT
	_apply_view()
	_shot_timer = 0.0
	_shot_done = false
	print("T4B_SHOT_ARMED player_cell=%s wait=%.2fs" % [str(LevelScript.SHOT_PLAYER_CELL), SHOT_WAIT])

func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = ProjectSettings.globalize_path("res://").path_join(SHOT_FILE)
	if image == null:
		push_error("T4B_SHOT_FAIL: viewport get_image() 返回空（headless 模式不能截图）")
		print("T4B_SHOT_FAIL")
		_quit(1)
		return
	var err: int = image.save_png(path)
	if err != OK:
		push_error("T4B_SHOT_FAIL: save_png 失败 err=" + str(err) + " path=" + path)
		print("T4B_SHOT_FAIL")
		_quit(1)
		return
	print("T4B_SHOT_SAVED " + path)
	_quit(0)

# ================================================================== 通关 / HUD

func _check_exit_now() -> bool:
	if completed:
		return true
	if level.is_at_exit(player.cell_pos()):
		completed = true
		hud.show_complete("本轮完成\n按 R 重开")
		hud.log_event("到达出口，本轮完成")
		return true
	return false

func _refresh_hud() -> void:
	if hud == null or vm == null or executor == null:
		return
	var gid := "—"
	var gname := "—"
	if not group_ids.is_empty() and selected_group < group_ids.size():
		gid = String(group_ids[selected_group])
		if selected_group < group_names.size():
			gname = String(group_names[selected_group])
		else:
			gname = gid
	var recharge: String = "回符中" if vm.get_is_recharging() else "可施法"
	var hint: String = "本轮完成（R 重开）" if completed else "向东到出口 x=%d" % LevelScript.EXIT_CELL.x
	var status: String = ("符组 %d/%d %s[%s]  %s | 灵力 %.0f/%.0f | 盏 %d/%d\n"
		+ "葫芦 %s %d/%d | 施法：%s | tick %d | %s") % [
		selected_group + 1, maxi(group_ids.size(), 1), gname, gid, recharge,
		vm.get_spirit(), vm.get_spirit_max(),
		executor.lanterns, LANTERNS_MAX,
		_liquid_cn(), executor.gourd_amount(), executor.gourd_cap(),
		executor.last_cast_status, sim.get_tick(), hint
	]
	hud.update_status(status)

func _liquid_cn() -> String:
	if executor == null:
		return "水"
	return "水" if executor.current_liquid == "water" else "油"

# ================================================================== --t4b-smoke 自检

## 脚本化走一遍 T4B.md §4 的组合时刻：化水 -> 取水 -> 灭火 -> 通关，
## 再验证 4 组符都能受理并影响世界；成功打印 T4B_SMOKE_OK 并退出 0，失败退出 1。
func _run_smoke() -> void:
	set_physics_process(false)
	set_process(false)
	print("T4B_SMOKE_START groups=%d materials=%s tick=%d" % [
		group_ids.size(), sim.get_materials_source(), sim.get_tick()
	])
	# 只让火障附近参与模拟（避免 960x540 全图每 tick 扫描）
	sim.set_active_rect(430, 240, 80, 60)

	var fail := ""
	var water_gained := 0
	var doused := 0
	var fire_left := 0
	var dug_total := 0

	# 0) 符卡
	if group_ids.size() < 4:
		fail = "符组数量 %d < 4（data/talismans.json 没读对？）" % group_ids.size()

	# 1) 化水：F-0002（毕方火·化·水）打 room-01 水银池 -> quicksilver 变 water
	var aim: Vector2i = LevelScript.MERCURY_AIM_CELL
	var quick_before := _count_material(aim, 4, sim.material_id("quicksilver"))
	var water_before := _count_material(aim, 4, sim.material_id("water"))
	var fire_before: int = level.count_fire_near_barrier()
	if fail == "":
		var r2: Dictionary = executor.cast("F-0002", aim)
		if not bool(r2.get("accepted", false)):
			fail = "F-0002 未受理：%s" % String(r2.get("reject_reason", ""))
		else:
			var quick_after := _count_material(aim, 4, sim.material_id("quicksilver"))
			var water_after := _count_material(aim, 4, sim.material_id("water"))
			if quick_after >= quick_before:
				fail = "化水失败：水银 %d 格没有减少（%d -> %d）" % [quick_before, quick_before, quick_after]
			elif water_after <= water_before:
				fail = "化水失败：水没有增加（%d -> %d）" % [water_before, water_after]
			elif not hud.log_contains("化水成功"):
				fail = "HUD 事件日志缺少「化水成功」"
			else:
				print("T4B_SMOKE_STEP 化水 quicksilver %d->%d water %d->%d" % [
					quick_before, quick_after, water_before, water_after
				])

	# 2) 取水：E 在水面吸取
	if fail == "":
		water_gained = int(executor.absorb(aim))
		if executor.gourd_water <= 0:
			fail = "取水失败：葫芦水量 %d" % executor.gourd_water
		elif not hud.log_contains("取水"):
			fail = "HUD 事件日志缺少「取水」"
		else:
			print("T4B_SMOKE_STEP 取水 gourd_water=%d" % executor.gourd_water)

	# 3) 灭火：走到火障前 Q 喷水 -> 火格置空 + 火墙源不再重燃
	if fail == "":
		if fire_before <= 0:
			fail = "火障初始没有火（level 放置失败）"
		else:
			player.set_cell_pos(LevelScript.DOUSE_CELL)
			var spray: Dictionary = executor.spray(player.cell_pos(), LevelScript.FIRE_WALL_AIM_CELL)
			doused = int(spray.get("doused", 0))
			if doused <= 0:
				fail = "喷水灭火失败：doused=0（gourd=%d）" % executor.gourd_water
			elif not hud.log_contains("灭火"):
				fail = "HUD 事件日志缺少「灭火」"
			else:
				print("T4B_SMOKE_STEP 灭火 fire_before=%d doused=%d" % [fire_before, doused])
			_fast_forward(60)
			fire_left = level.count_fire_near_barrier()
			if fail == "" and fire_left > 0:
				fail = "火障复燃：60 tick 后火障附近仍有 %d 个火格" % fire_left

	# 4) 通关：进入出口 3x3
	if fail == "":
		player.set_cell_pos(LevelScript.EXIT_CELL)
		_check_exit_now()
		if not completed:
			fail = "走到出口没有触发通关"
		elif not hud.log_contains("本轮完成"):
			fail = "HUD 缺少通关提示"
		else:
			print("T4B_SMOKE_STEP 通关 completed=%s" % str(completed))

	# 5) 4 组符都能受理并影响世界（每发之间快进 35 tick 过回符）
	if fail == "":
		_fast_forward(35)
		var r1: Dictionary = executor.cast("F-0001", Vector2i(200, 430))
		if not bool(r1.get("accepted", false)):
			fail = "F-0001 未受理"
		else:
			dug_total += int(r1.get("dug", 0))
			if dug_total <= 0:
				fail = "F-0001 爆炸没有挖开岩层"
	if fail == "":
		_fast_forward(35)
		var spirit_before: float = vm.get_spirit()
		var r4: Dictionary = executor.cast("F-0004", Vector2i(500, 430))
		var spirit_after: float = vm.get_spirit()
		if not bool(r4.get("accepted", false)):
			fail = "F-0004 未受理"
		elif int(r4.get("dug", 0)) <= 0:
			fail = "F-0004 土遁没有挖开岩层"
		elif absf((spirit_before - spirit_after) - 2.0) > 0.01:
			fail = "F-0004 净耗不是 2（%.1f -> %.1f，归 应返还 8）" % [spirit_before, spirit_after]
		else:
			dug_total += int(r4.get("dug", 0))
	if fail == "":
		_fast_forward(35)
		var spirit_before3: float = vm.get_spirit()
		var r3: Dictionary = executor.cast("F-0003", Vector2i(700, 430))
		var spirit_after3: float = vm.get_spirit()
		if not bool(r3.get("accepted", false)):
			fail = "F-0003 未受理"
		elif spirit_after3 > spirit_before3 - 19.0:
			fail = "F-0003 没有扣 20 灵力（%.1f -> %.1f，可能灵力不足 fizzle）" % [spirit_before3, spirit_after3]

	if fail != "":
		push_error("T4B_SMOKE_FAIL: " + fail)
		print("T4B_SMOKE_FAIL " + fail)
		_quit(1)
		return
	print("T4B_SMOKE_OK groups=%d water_gained=%d doused=%d fire_left=%d dug=%d lanterns=%d spirit=%.0f tick=%d completed=%s" % [
		group_ids.size(), water_gained, doused, fire_left, dug_total,
		executor.lanterns, vm.get_spirit(), sim.get_tick(), str(completed)
	])
	_quit(0)

func _fast_forward(tick_count: int) -> void:
	for i in range(tick_count):
		sim.step_tick()
		vm.tick_advance()
		level.tick_fire_wall()

func _count_material(center: Vector2i, radius: int, material: int) -> int:
	if material < 0:
		return -1
	var n := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > radius * radius:
				continue
			if sim.get_cell(center.x + dx, center.y + dy) == material:
				n += 1
	return n
