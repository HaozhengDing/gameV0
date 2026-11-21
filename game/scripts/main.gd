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
const HUD_INTERVAL := 0.05
const HEADLESS_NAME := "headless"
const SHOT_WAIT := 0.6          # --t4b-shot：先跑 ~0.6s 让 sim/纹理就绪再截图
const SHOT_FILE := "../t4b_shot.png"

const LevelScript := preload("res://scripts/level.gd")
const PlayerScript := preload("res://scripts/player.gd")
const ExecutorScript := preload("res://scripts/executor.gd")
const HudScript := preload("res://scripts/hud.gd")
const OverlayScript := preload("res://scripts/overlay.gd")
const EventBusScript := preload("res://scripts/event_bus.gd")
const TextDBScript := preload("res://scripts/text_db.gd")

# 场景节点
var sim: SimWorldNode
var vm: TalismanVMNode
var level
var player
var camera: Camera2D
var hud
var executor
var overlay
var event_bus
var text_db
var exit_marker: ColorRect

# 玩法状态
var group_ids: Array = []
var group_names: Array = []
var group_costs: Array = []
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
var _active_rect := Rect2i()

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
	_create_overlay()
	_create_contracts()
	_create_vm()
	_create_hud()
	hud.set_slots(group_names, group_costs)
	_create_executor()
	_start_round()
	if smoke_mode or shot_mode:
		player.input_enabled = false
		player.physics_enabled = false
		if overlay != null:
			overlay.show_reticle = false
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
	level.tick_flammable_spread(_active_rect)
	if completed:
		return
	if executor.tick_hazards(player.cell_pos()):
		player.set_cell_pos(LevelScript.START_CELL)
		player.reset_motion()
		hud.log_event("回到起点")
		_refresh_hud()
	_check_exit_now()

func _process(delta: float) -> void:
	if not _world_ready:
		return
	_apply_view()
	if overlay != null and overlay.show_reticle and DisplayServer.get_name() != HEADLESS_NAME:
		overlay.set_aim(_aim_cell())
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
## 仅当视口移动时更新 active_rect（避免每帧重复 wake 全屏破坏 chunk 休眠）。
func _apply_view() -> void:
	if sim == null or not sim.has_world() or player == null:
		return
	var pc: Vector2i = player.cell_pos()
	var vx := clampi(pc.x - VIEW_W / 2, 0, maxi(WORLD_W - VIEW_W, 0))
	var vy := clampi(pc.y - VIEW_H / 2, 0, maxi(WORLD_H - VIEW_H, 0))
	if vx != _last_view.x or vy != _last_view.y:
		_last_view = Vector2i(vx, vy)
		var ax := maxi(vx - ACTIVE_MARGIN, 0)
		var ay := maxi(vy - ACTIVE_MARGIN, 0)
		var ax1 := mini(vx + VIEW_W + ACTIVE_MARGIN, WORLD_W)
		var ay1 := mini(vy + VIEW_H + ACTIVE_MARGIN, WORLD_H)
		_active_rect = Rect2i(ax, ay, ax1 - ax, ay1 - ay)
		sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)
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
	# 出口区视觉标记（跨越走廊整高，配「出口」文字标识）；HUD 另有距离提示
	exit_marker = ColorRect.new()
	exit_marker.name = "ExitMarker"
	exit_marker.color = Color(0.22, 0.95, 0.45, 0.48)
	exit_marker.size = Vector2(float(SCALE * 4), float(SCALE * LevelScript.CORRIDOR_HEIGHT))
	exit_marker.position = Vector2(
		float((LevelScript.EXIT_CELL.x - LevelScript.EXIT_RADIUS) * SCALE),
		float(LevelScript.CORRIDOR_TOP * SCALE)
	)
	var exit_label := Label.new()
	exit_label.text = "出口"
	exit_label.add_theme_font_size_override("font_size", 20)
	exit_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.62))
	exit_label.position = Vector2(-10.0, -28.0)
	exit_marker.add_child(exit_label)
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
	var eye := ColorRect.new()
	eye.name = "Eye"
	eye.color = Color(0.14, 0.12, 0.10)
	eye.size = Vector2(float(2 * SCALE), float(2 * SCALE))
	eye.position = Vector2(float(1 * SCALE), float(-8 * SCALE))
	player.add_child(eye)
	var jet := ColorRect.new()
	jet.name = "Jet"
	jet.color = Color(0.98, 0.86, 0.42, 0.85)
	jet.size = Vector2(float(3 * SCALE), float(3 * SCALE))
	jet.position = Vector2(float(-1 * SCALE), 0.0)
	jet.visible = false
	player.add_child(jet)
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

func _create_overlay() -> void:
	overlay = OverlayScript.new()
	overlay.name = "Overlay"
	overlay.z_index = 5
	overlay.show_reticle = DisplayServer.get_name() != HEADLESS_NAME
	add_child(overlay)

func _create_contracts() -> void:
	event_bus = EventBusScript.new()
	text_db = TextDBScript.new()
	if not text_db.load_locale():
		push_error("T4B: C-TEXT 词表加载失败")

func _create_vm() -> void:
	vm = TalismanVMNode.new()
	vm.name = "TalismanVM"
	add_child(vm)
	if not vm.load_cards(_cards_path()):
		push_error("T4B: TalismanVMNode.load_cards 失败：" + _cards_path())
	group_ids = vm.get_group_ids()
	group_names.clear()
	group_costs.clear()
	var groups: Array = vm.get_groups()
	for g in groups:
		if g is Dictionary:
			var gd: Dictionary = g
			group_names.append(String(gd.get("name", String(gd.get("id", "")))))
			group_costs.append(int(gd.get("spirit_cost", 0)))

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
	player.reset_motion()
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
				var aim_e := _aim_cell()
				executor.absorb(aim_e)
				if overlay != null:
					overlay.add_ring(aim_e, float(ExecutorScript.ABSORB_RADIUS), Color(0.38, 0.82, 1.0, 0.85))
			KEY_Q:
				var aim_q := _aim_cell()
				var sp: Dictionary = executor.spray(player.cell_pos(), aim_q)
				if overlay != null and int(sp.get("placed", 0)) > 0:
					var col := Color(0.35, 0.72, 1.0, 0.9) if String(sp.get("liquid", "water")) == "water" else Color(0.75, 0.52, 0.24, 0.9)
					overlay.add_line(sp.get("from", player.cell_pos()), sp.get("to", aim_q), col)
			KEY_F:
				var aim_f := _aim_cell()
				var ignited_f: int = executor.manual_ignite(aim_f)
				if overlay != null and ignited_f > 0:
					overlay.add_ring(aim_f, float(ExecutorScript.MANUAL_IGNITE_RADIUS), Color(1.0, 0.52, 0.18, 0.9))
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
	var gid := String(group_ids[selected_group])
	var summary: Dictionary = executor.cast(gid, aim)
	if overlay != null and bool(summary.get("accepted", false)):
		var r := 4.0
		var col := Color(0.96, 0.86, 0.45, 0.9)
		if gid == "F-0001":
			r = 20.0
			col = Color(1.0, 0.55, 0.22, 0.85)
		elif gid == "F-0002":
			r = 4.0
			col = Color(0.36, 0.84, 1.0, 0.95)
		elif gid == "F-0003":
			r = 5.0
			col = Color(0.68, 0.52, 0.98, 0.85)
		elif gid == "F-0004":
			r = 3.0
			col = Color(0.88, 0.78, 0.52, 0.9)
		overlay.add_ring(aim, r, col)
	_refresh_hud()

func _select_group(index: int) -> void:
	if group_ids.is_empty():
		return
	selected_group = wrapi(index, 0, group_ids.size())

# ================================================================== 重开

func _restart() -> void:
	if not _world_ready:
		return
	if not sim.create_world(WORLD_W, WORLD_H, SEED, _materials_path()):
		push_error("T4B: 重开时 create_world 失败")
		return
	_start_round()
	if overlay != null:
		overlay.clear_pulses()
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
	if hud == null or vm == null or executor == null or player == null:
		return
	var dist_x := maxi(LevelScript.EXIT_CELL.x - player.cell_pos().x, 0)
	var hint: String = "本轮完成 · R 重开" if completed else "出口 → %d" % dist_x
	hud.update_state({
		"hp": executor.lanterns,
		"hp_max": LANTERNS_MAX,
		"mana": vm.get_spirit(),
		"mana_max": vm.get_spirit_max(),
		"recharging": vm.get_is_recharging(),
		"levitate": player.levitate,
		"levitate_max": PlayerScript.LEVITATE_MAX,
		"water": executor.gourd_water,
		"water_cap": ExecutorScript.WATER_CAP,
		"oil": executor.gourd_oil,
		"oil_cap": ExecutorScript.OIL_CAP,
		"liquid": executor.current_liquid,
		"selected": selected_group,
		"cursor_mat": _cursor_material_text(),
		"exit_hint": hint,
	})

func _cursor_material_text() -> String:
	if sim == null or not sim.has_world():
		return "—"
	var c: Vector2i = LevelScript.MERCURY_AIM_CELL if shot_mode else _aim_cell()
	var m: int = sim.get_cell(c.x, c.y)
	if m <= 0:
		return "空"
	var disp: String = sim.get_material_display(m)
	if disp.is_empty():
		disp = sim.get_material_id_str(m)
	if sim.get_material_flammable(m):
		return disp + " · 可燃"
	return disp

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
	_active_rect = Rect2i(430, 240, 80, 60)
	sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)

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

	# 6) T4b 打磨回归：地板高度出口 / 喷油不灭火 / 火伤贴脸判定 / 手动点火 + 可燃材质统一蔓延
	if fail == "":
		if not level.is_at_exit(Vector2i(LevelScript.EXIT_CELL.x, LevelScript.CORRIDOR_TOP + LevelScript.CORRIDOR_HEIGHT - 1)):
			fail = "走廊地板高度无法触发出口"
	if fail == "":
		# 喷油不得熄灭半径内火格（修复原 spray 误调 douse_fire_around）
		var fire_mat: int = sim.material_id("fire")
		var oil_test_fire := Vector2i(250, 268)
		sim.set_cell(oil_test_fire.x, oil_test_fire.y, fire_mat)
		executor.gourd_oil = 12
		executor.current_liquid = "oil"
		var oil_res: Dictionary = executor.spray(Vector2i(242, 274), Vector2i(254, 270))
		if int(oil_res.get("doused", 0)) != 0 or sim.get_cell(oil_test_fire.x, oil_test_fire.y) != fire_mat:
			fail = "喷油错误触发了灭火（doused=%d）" % int(oil_res.get("doused", 0))
		sim.set_cell(oil_test_fire.x, oil_test_fire.y, 0)
		executor.current_liquid = "water"
	if fail == "":
		# 手动点火 + 统一 1.5%/tick 可燃材质蔓延（竹木）+ 身体边界火伤检测
		var bamboo_mat: int = sim.material_id("bamboo")
		var b_aim: Vector2i = LevelScript.SMOKE_BAMBOO_CELL
		var bamboo_before := _count_material(b_aim, 8, bamboo_mat)
		var init_lit: int = executor.manual_ignite(b_aim)
		if init_lit <= 0:
			fail = "手动点火未点燃竹木"
		elif not executor.is_near_fire(b_aim - Vector2i(ExecutorScript.MANUAL_IGNITE_RADIUS + ExecutorScript.BODY_HALF_W + 1, 0)):
			fail = "身体盒外扩 1 格未检测到相邻火焰（火伤贴墙失效）"
		else:
			var bamboo_after_init := _count_material(b_aim, 8, bamboo_mat)
			_active_rect = Rect2i(360, 240, 48, 64)
			sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)
			_fast_forward(90)
			var bamboo_after_spread := _count_material(b_aim, 8, bamboo_mat)
			if bamboo_after_spread >= bamboo_after_init:
				fail = "可燃材质未发生火焰蔓延（竹木 %d -> %d -> %d）" % [bamboo_before, bamboo_after_init, bamboo_after_spread]
			else:
				print("T4B_SMOKE_STEP 灰盒火焰补丁 bamboo %d->%d(手动点火)->%d(蔓延90tick)" % [
					bamboo_before, bamboo_after_init, bamboo_after_spread
				])
	if fail == "":
		# 爆炸坑缘引燃：F-0001 命中 room-02 硫磺块 -> 挖坑后仍引燃坑缘硫磺
		var sulfur_aim := Vector2i(632, 228)
		var r_rim: Dictionary = executor.cast("F-0001", sulfur_aim)
		if not bool(r_rim.get("accepted", false)) or int(r_rim.get("ignited", 0)) <= 0:
			fail = "F-0001 爆炸未引燃坑缘硫磺（ignited=%d）" % int(r_rim.get("ignited", 0))
		else:
			print("T4B_SMOKE_STEP 爆炸坑缘引燃 sulfur ignited=%d" % int(r_rim.get("ignited", 0)))

	# 7) 角色物理移动回归：重力下落 / 浮空上升并消耗浮空条 / 落地快充 / 碎屑迈步
	if fail == "":
		player.set_cell_pos(Vector2i(250, 220))
		player.reset_motion()
		var y0: float = player.position.y
		for i in range(25):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var y_fall: float = player.position.y
		if y_fall <= y0 + 20.0:
			fail = "重力下落未生效（y %.1f -> %.1f）" % [y0, y_fall]
		else:
			for i in range(30):
				player.step_physics(FIXED_DT, 0.0, true, false)
			var y_hover: float = player.position.y
			var lev_after: float = player.levitate
			if y_hover >= y_fall - 10.0:
				fail = "浮空推力未上升（y %.1f -> %.1f）" % [y_fall, y_hover]
			elif lev_after >= PlayerScript.LEVITATE_MAX - 5.0:
				fail = "浮空未消耗浮空条（lev=%.1f）" % lev_after
			else:
				# 放到走廊地板验证接地与浮空条回充
				player.set_cell_pos(Vector2i(16, 275))
				player.velocity = Vector2.ZERO
				for i in range(45):
					player.step_physics(FIXED_DT, 0.0, false, false)
				if not player.on_ground:
					fail = "走廊地板未判定接地"
				elif player.levitate < PlayerScript.LEVITATE_MAX - 1.0:
					fail = "落地未回满浮空条（lev=%.1f）" % player.levitate
				else:
					print("T4B_SMOKE_STEP 角色物理 fall=%.1f->%.1f hover->%.1f lev=%.0f->%.0f" % [
						y0, y_fall, y_hover, lev_after, player.levitate
					])

	# 8) M1-01 契约自检：C-TEXT（正常/低神智 D3 边界/拼句）+ C-EVT（发布与订阅）
	if fail == "":
		if text_db == null or not text_db.is_loaded():
			fail = "C-TEXT 未加载"
		elif text_db.get_text("$mat_water", 10) != "水":
			fail = "C-TEXT 违反 D3：低神智时 $mat_water 发生腐坏"
		elif text_db.get_text("$rule_no_open_flame", 100) == text_db.get_text("$rule_no_open_flame", 50):
			fail = "C-TEXT 未知规矩在 sanity<66 时未切换腐坏文本"
		elif text_db.compose_cards(["body-flying-sword", "foot-sha"]) != "斩 + 爆":
			fail = "C-TEXT 拼句结果不符：%s" % text_db.compose_cards(["body-flying-sword", "foot-sha"])
		else:
			var got_evts := []
			var cb := func(e: Dictionary) -> void: got_evts.append(e)
			event_bus.reset()
			event_bus.subscribe(cb)
			var pub: Dictionary = event_bus.publish("reaction_triggered", sim.get_tick(), {
				"pos": Vector2i(10, 10), "reaction_id": "r-black-powder", "value": 25.0, "text_key": "$react_black_powder"
			})
			event_bus.unsubscribe(cb)
			if pub.is_empty() or got_evts.size() != 1 or event_bus.count_of("reaction_triggered") != 1:
				fail = "C-EVT 发布/订阅自检失败"
			else:
				print("T4B_SMOKE_STEP M1-01契约 texts=%d evt_seq=%d" % [text_db.entry_count(), event_bus.get_seq()])

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
		level.tick_flammable_spread(_active_rect)

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
