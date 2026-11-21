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
const CombatManagerScript := preload("res://scripts/combat/combat_manager.gd")
const VitalsScript := preload("res://scripts/vitals.gd")
const WandManagerScript := preload("res://scripts/wand_manager.gd")
const WandUIScript := preload("res://scripts/wand_ui.gd")

const REACTION_TEXT_KEYS := {
	"r-black-powder": "$react_black_powder",
	"r-sulfur-toxic-smoke": "$react_sulfur_toxic_smoke",
	"r-bamboo-burn": "$react_bamboo_burn",
	"r-lime-steam": "$react_lime_steam",
	"r-rice-purify": "$react_rice_purify",
	"r-dog-blood-spirit": "$react_dog_blood_spirit",
	"r-quicksilver-ward": "$react_quicksilver_ward",
	"r-cinnabar-talisman": "$react_cinnabar_talisman",
}
const REACTION_LOG_COOLDOWN := 120  # 2s 同类反应 HUD 提示节流（60Hz）

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
var combat
var vitals
var wand_manager
var wand_ui
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
var _reaction_log_tick: Dictionary = {}

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
	_create_wands()
	_create_combat()
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
	_drain_sim_events()
	if combat != null:
		combat.step_tick()
	vm.tick_advance()
	if wand_manager != null:
		wand_manager.in_safe_zone = _is_player_in_safe_zone()
		wand_manager.tick_advance(_is_player_in_quicksilver())
	level.tick_fire_wall()
	if completed:
		return
	if executor.tick_hazards(player.cell_pos()):
		player.set_cell_pos(LevelScript.START_CELL)
		player.reset_motion()
		hud.log_event("回到起点")
		_refresh_hud()
	_check_exit_now()

func _is_player_in_safe_zone() -> bool:
	if player == null:
		return false
	return player.cell_pos().x < LevelScript.START_CORRIDOR_W

func _is_player_in_quicksilver() -> bool:
	if sim == null or not sim.has_world() or player == null:
		return false
	var qs: int = sim.material_id("quicksilver")
	if qs < 0:
		return false
	var c: Vector2i = player.cell_pos()
	return sim.get_cell(c.x, maxi(c.y - 1, 0)) == qs or sim.get_cell(c.x, maxi(c.y - 4, 0)) == qs

## M1-12：每 tick 从 C-SIM v3 拉取模拟事件，按反应/类型聚合后发布至 C-EVT（防止单 tick 刷屏）。
func _drain_sim_events() -> void:
	if sim == null or not sim.has_world() or event_bus == null:
		return
	var raw_events: Array = sim.poll_events(256)
	if raw_events.is_empty():
		return
	var tick: int = sim.get_tick()
	var reactions: Dictionary = {}   # reaction_id -> {count, pos}
	var ignited_count := 0
	var ignited_pos := Vector2i.ZERO
	for item in raw_events:
		if not (item is Dictionary):
			continue
		var ev: Dictionary = item
		var ev_type: int = int(ev.get("type", 0))
		var pos := Vector2i(int(ev.get("x", 0)), int(ev.get("y", 0)))
		if ev_type == 4: # SIM_EVENT_REACTION
			var rid: String = String(ev.get("reaction_id", ""))
			if rid.is_empty():
				continue
			if not reactions.has(rid):
				reactions[rid] = {"count": 1, "pos": pos}
			else:
				var rec: Dictionary = reactions[rid]
				rec["count"] = int(rec["count"]) + 1
		elif ev_type == 1: # SIM_EVENT_FIRE_IGNITED
			ignited_count += 1
			ignited_pos = pos
	if ignited_count > 0:
		event_bus.publish("fire_ignited", tick, {
			"pos": ignited_pos,
			"value": float(ignited_count),
		})
	for rid_raw in reactions.keys():
		var rid: String = String(rid_raw)
		var rec: Dictionary = reactions[rid]
		var pos: Vector2i = rec["pos"]
		var count: int = int(rec["count"])
		var text_key: String = String(REACTION_TEXT_KEYS.get(rid, ""))
		event_bus.publish("reaction_triggered", tick, {
			"pos": pos,
			"reaction_id": rid,
			"value": float(count),
			"text_key": text_key,
		})
		if rid == "r-black-powder" and overlay != null and not smoke_mode:
			overlay.add_ring(pos, 16.0, Color(1.0, 0.45, 0.12, 0.95))
		if hud != null and text_db != null and not text_key.is_empty():
			var last_t: int = int(_reaction_log_tick.get(rid, -99999))
			if tick - last_t >= REACTION_LOG_COOLDOWN:
				_reaction_log_tick[rid] = tick
				hud.log_event(text_db.get_text(text_key))

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
	vitals = VitalsScript.new()
	vitals.load_defaults_from_magic_numbers()
	vitals.reset()

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

func _create_wands() -> void:
	wand_manager = WandManagerScript.new()
	if not wand_manager.load_data(vm):
		push_error("M1-03: data/wands.json 加载失败")
	wand_ui = WandUIScript.new()
	wand_ui.name = "WandUI"
	add_child(wand_ui)
	wand_ui.setup(wand_manager, text_db, hud)
	wand_ui.deck_changed.connect(_refresh_hud)

func _create_combat() -> void:
	combat = CombatManagerScript.new()
	combat.name = "CombatManager"
	combat.z_index = 4
	add_child(combat)
	combat.setup(sim, event_bus, text_db, overlay, hud)
	if vitals != null:
		combat.player_heal_callback = func(amount: float) -> void: vitals.heal_hp(amount)

func _create_executor() -> void:
	executor = ExecutorScript.new()
	executor.setup(sim, vm, level, player, hud, event_bus, text_db, combat, vitals, wand_manager)

func _start_round() -> void:
	completed = false
	selected_group = 0
	_reaction_log_tick.clear()
	if event_bus != null:
		event_bus.reset()
		event_bus.subscribe(_on_combat_event)
	if not level.build():
		push_error("T4B: level.build 失败")
	player.setup(sim)
	player.set_cell_pos(LevelScript.START_CELL)
	player.reset_motion()
	if wand_manager != null:
		wand_manager.reset()
		wand_manager.in_safe_zone = true
	if wand_ui != null:
		wand_ui.set_open(false)
	if combat != null:
		combat.reset_round()
		_spawn_demo_targets()
	executor.reset_round()
	vm.reset()
	_last_view = Vector2i(-999999, -999999)

func _spawn_demo_targets() -> void:
	# M1-02 靶标实体（实机可试射；正式敌人 AI 在 M1-06 接入）
	combat.spawn_entity({
		"id": "mob_ghost_01",
		"name": text_db.get_text("$enemy_coal_ghost") if text_db != null else "矿鬼",
		"faction": "enemy",
		"pos": Vector2(184.0, 355.0),
		"max_hp": 30.0,
		"tags": ["spirit"],
		"weak_to": {"阳": 2.0, "火": 1.2},
		"color": Color(0.54, 0.72, 0.88),
	})
	combat.spawn_entity({
		"id": "mob_eldritch_01",
		"name": text_db.get_text("$enemy_earth_worm") if text_db != null else "土蝼",
		"faction": "enemy",
		"pos": Vector2(740.0, 355.0),
		"max_hp": 45.0,
		"tags": ["eldritch"],
		"weak_to": {"金": 1.5, "雷": 1.5},
		"color": Color(0.72, 0.36, 0.70),
	})

func _on_combat_event(ev: Dictionary) -> void:
	if hud == null or smoke_mode:
		return
	var etype: String = String(ev.get("type", ""))
	if etype == "entity_killed":
		var tid: String = String(ev.get("target_id", ""))
		var ent = combat.get_entity(tid) if combat != null else null
		var label: String = ent.display_name if ent != null else tid
		hud.log_event("击杀 " + label)
	elif etype == "reaction_triggered":
		var rid: String = String(ev.get("reaction_id", ""))
		if rid in ["r-dog-blood-spirit", "r-quicksilver-ward", "r-cinnabar-talisman"]:
			var tk: String = String(ev.get("text_key", ""))
			if text_db != null and not tk.is_empty():
				hud.log_event(text_db.get_text(tk))

# ================================================================== 输入

func _unhandled_input(event: InputEvent) -> void:
	if not _world_ready or smoke_mode:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if wand_ui != null and wand_ui.is_open:
				return
			_do_cast(_aim_cell())
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_B:
				if wand_ui != null:
					wand_manager.in_safe_zone = _is_player_in_safe_zone()
					wand_ui.toggle()
					player.input_enabled = not wand_ui.is_open
			KEY_ESCAPE:
				if wand_ui != null and wand_ui.is_open:
					wand_ui.set_open(false)
					player.input_enabled = true
				else:
					return
			KEY_1:
				_select_wand(0)
			KEY_2:
				_select_wand(1)
			KEY_3:
				_select_wand(2)
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
	if wand_manager != null and wand_manager.wand_count() > 0:
		executor.cast_active_wand(aim)
		if wand_ui != null and wand_ui.is_open:
			wand_ui.refresh()
	elif not group_ids.is_empty():
		var gid := String(group_ids[selected_group])
		executor.cast(gid, aim)
	_refresh_hud()

func _select_wand(index: int) -> void:
	if wand_manager == null or wand_manager.wand_count() == 0:
		return
	wand_manager.select_wand(index)
	selected_group = wand_manager.selected_index
	if wand_ui != null and wand_ui.is_open:
		wand_ui.refresh()

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
	var status_items: Array = []
	for st_id in executor.get_active_statuses():
		var st_key := "$status_" + String(st_id)
		var st_label: String = text_db.get_text(st_key) if (text_db != null and text_db.has_key(st_key)) else String(st_id)
		status_items.append({"id": String(st_id), "label": st_label})
	var vsnap: Dictionary = vitals.snapshot() if vitals != null else {
		"hp": 100.0, "hp_eff_max": 100.0, "hp_base_max": 100.0,
		"lanterns": float(LANTERNS_MAX), "lanterns_max": float(LANTERNS_MAX),
	}
	var mana_val: float = vm.get_spirit()
	var mana_max: float = vm.get_spirit_max()
	var recharging: bool = vm.get_is_recharging()
	var sel_idx: int = selected_group
	if wand_manager != null and wand_manager.wand_count() > 0:
		var aw: Dictionary = wand_manager.active_wand()
		mana_val = float(aw.get("spirit", mana_val))
		mana_max = float(aw.get("spirit_max", mana_max))
		recharging = wand_manager.is_active_recharging(sim.get_tick())
		sel_idx = wand_manager.selected_index
		hud.set_wand_slots(wand_manager.build_hud_slots(text_db))
	hud.update_state({
		"hp": float(vsnap["hp"]),
		"hp_eff_max": float(vsnap["hp_eff_max"]),
		"hp_base_max": float(vsnap["hp_base_max"]),
		"lanterns": float(vsnap["lanterns"]),
		"lanterns_max": float(vsnap["lanterns_max"]),
		"mana": mana_val,
		"mana_max": mana_max,
		"recharging": recharging,
		"levitate": player.levitate,
		"levitate_max": PlayerScript.LEVITATE_MAX,
		"water": executor.gourd_water,
		"water_cap": ExecutorScript.WATER_CAP,
		"oil": executor.gourd_oil,
		"oil_cap": ExecutorScript.OIL_CAP,
		"liquid": executor.current_liquid,
		"selected": sel_idx,
		"cursor_mat": _cursor_material_text(),
		"exit_hint": hint,
		"statuses": status_items,
	})

func _cursor_material_text() -> String:
	if sim == null or not sim.has_world():
		return "—"
	var c: Vector2i = LevelScript.MERCURY_AIM_CELL if shot_mode else _aim_cell()
	var m: int = sim.get_cell(c.x, c.y)
	if m <= 0:
		return "空"
	var id_str: String = sim.get_material_id_str(m)
	var mat_key := "$mat_" + id_str
	var disp: String = ""
	if text_db != null and text_db.has_key(mat_key):
		disp = text_db.get_text(mat_key)
	else:
		disp = sim.get_material_display(m)
	if disp.is_empty():
		disp = id_str
	if sim.get_material_flammable(m):
		if sim.get_cell_aux(c.x, c.y) > 0:
			return disp + " · 燃"
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

	# 1) 化水：站水银池上方用真实投射物 F-0002（火 + 化水）命中水银液面 -> quicksilver 变 water
	var aim := Vector2i(304, 244)  # room-01 水银池顶部液面（row 6 = y 244）
	var quick_before := _count_material(aim, 6, sim.material_id("quicksilver"))
	var water_before := _count_material(aim, 6, sim.material_id("water"))
	var fire_before: int = level.count_fire_near_barrier()
	if fail == "":
		player.set_cell_pos(Vector2i(304, 232))
		var r2: Dictionary = executor.cast("F-0002", Vector2i(304, 250))
		if not bool(r2.get("accepted", false)):
			fail = "F-0002 未受理：%s" % String(r2.get("reject_reason", ""))
		elif int(r2.get("projectiles", 0)) <= 0:
			fail = "F-0002 未发射真实投射物"
		else:
			_fast_forward(10)
			var quick_after := _count_material(aim, 6, sim.material_id("quicksilver"))
			var water_after := _count_material(aim, 6, sim.material_id("water"))
			if quick_after >= quick_before:
				fail = "化水失败：水银 %d 格没有减少（%d -> %d）" % [quick_before, quick_before, quick_after]
			elif water_after <= water_before:
				fail = "化水失败：水没有增加（%d -> %d）" % [water_before, water_after]
			elif not hud.log_contains("化水成功"):
				fail = "HUD 事件日志缺少「化水成功」"
			else:
				print("T4B_SMOKE_STEP 化水(投射物) quicksilver %d->%d water %d->%d" % [
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

	# 5) 4 组符真实投射物飞行 + 命中验证（每发之间快进 35 tick 过回符）
	if fail == "":
		_fast_forward(35)
		var dug_before1: int = int(combat.stats["dug"])
		player.set_cell_pos(Vector2i(200, 350))
		var r1: Dictionary = executor.cast("F-0001", Vector2i(200, 375))
		_fast_forward(12)
		var dug_delta1: int = int(combat.stats["dug"]) - dug_before1
		if not bool(r1.get("accepted", false)):
			fail = "F-0001 未受理"
		elif dug_delta1 <= 0:
			fail = "F-0001 投射物爆炸没有挖开岩层"
		else:
			dug_total += dug_delta1
	if fail == "":
		_fast_forward(35)
		var dug_before4: int = int(combat.stats["dug"])
		var spirit_before: float = vm.get_spirit()
		player.set_cell_pos(Vector2i(500, 270))
		var r4: Dictionary = executor.cast("F-0004", Vector2i(500, 285))
		var spirit_after: float = vm.get_spirit()
		_fast_forward(12)
		var dug_delta4: int = int(combat.stats["dug"]) - dug_before4
		if not bool(r4.get("accepted", false)):
			fail = "F-0004 未受理"
		elif dug_delta4 <= 0:
			fail = "F-0004 土遁投射物没有挖开岩层"
		elif absf((spirit_before - spirit_after) - 2.0) > 0.01:
			fail = "F-0004 净耗不是 2（%.1f -> %.1f，归 应返还 8）" % [spirit_before, spirit_after]
		else:
			dug_total += dug_delta4
	if fail == "":
		_fast_forward(35)
		var ghost = combat.get_entity("mob_ghost_01")
		var ghost_hp0: float = ghost.hp if ghost != null else 0.0
		var spirit_before3: float = vm.get_spirit()
		player.set_cell_pos(Vector2i(215, 355))
		var r3: Dictionary = executor.cast("F-0003", Vector2i(184, 350))
		var spirit_after3: float = vm.get_spirit()
		_fast_forward(15)
		if not bool(r3.get("accepted", false)):
			fail = "F-0003 未受理"
		elif spirit_after3 > spirit_before3 - 19.0:
			fail = "F-0003 没有扣 20 灵力（%.1f -> %.1f，可能灵力不足 fizzle）" % [spirit_before3, spirit_after3]
		elif ghost == null or ghost.hp >= ghost_hp0 or not ghost.is_stunned():
			fail = "F-0003（阴+镇）未命中矿鬼或未施加镇压（hp=%.1f/%.1f stun=%s）" % [
				ghost.hp if ghost != null else -1.0, ghost_hp0, str(ghost.is_stunned() if ghost != null else false)
			]
		else:
			print("T4B_SMOKE_STEP F-0003阴+镇命中矿鬼 hp=%.1f->%.1f stun=true" % [ghost_hp0, ghost.hp])

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
		# C-SIM v3 原生热/火：手动点火竹木 -> 燃料燃烧态(aux>0) -> 120 tick 烧成煤 + 触发 r-bamboo-burn
		var bamboo_mat: int = sim.material_id("bamboo")
		var coal_mat: int = sim.material_id("coal")
		var b_aim: Vector2i = LevelScript.SMOKE_BAMBOO_CELL
		var bamboo_before := _count_material(b_aim, 8, bamboo_mat)
		var coal_before := _count_material(b_aim, 8, coal_mat)
		var init_lit: int = executor.manual_ignite(b_aim)
		if init_lit <= 0:
			fail = "手动点火未点燃竹木"
		elif not executor.is_near_fire(b_aim - Vector2i(ExecutorScript.MANUAL_IGNITE_RADIUS + ExecutorScript.BODY_HALF_W, 0)):
			fail = "身体盒外扩 1 格未检测到燃烧中的竹木"
		else:
			_active_rect = Rect2i(360, 240, 48, 64)
			sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)
			_fast_forward(150)
			var bamboo_after := _count_material(b_aim, 8, bamboo_mat)
			var coal_after := _count_material(b_aim, 8, coal_mat)
			if bamboo_after >= bamboo_before or coal_after <= coal_before:
				fail = "C-SIM v3 竹木燃烧未转为煤（bamboo %d->%d, coal %d->%d）" % [
					bamboo_before, bamboo_after, coal_before, coal_after
				]
			else:
				print("T4B_SMOKE_STEP C-SIMv3竹木燃炭 bamboo %d->%d coal %d->%d" % [
					bamboo_before, bamboo_after, coal_before, coal_after
				])
	if fail == "":
		# 爆炸坑缘热冲击：F-0001 投射物命中 room-02 硫磺块 -> 挖坑后引燃坑缘并产生硫磺毒烟
		var sulfur_aim := Vector2i(612, 228)
		_active_rect = Rect2i(580, 196, 80, 64)
		sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)
		var ign_before: int = int(combat.stats["ignited"])
		player.set_cell_pos(Vector2i(582, 232))
		var r_rim: Dictionary = executor.cast("F-0001", sulfur_aim)
		_fast_forward(28)
		var ign_delta: int = int(combat.stats["ignited"]) - ign_before
		var toxic_cnt := _count_material(sulfur_aim, 28, sim.material_id("toxic_smoke"))
		if not bool(r_rim.get("accepted", false)) or ign_delta <= 0:
			fail = "F-0001 爆炸未引燃坑缘硫磺（ignited=%d）" % ign_delta
		elif toxic_cnt <= 0:
			fail = "硫磺受热未产生毒烟（toxic_smoke=0）"
		else:
			print("T4B_SMOKE_STEP 爆炸坑缘热冲击 sulfur ignited=%d toxic_smoke=%d" % [
				ign_delta, toxic_cnt
			])

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

	# 9) M1-12 回归：C-SIM v3 契约版本 / 黑火药 / 石灰蒸汽 / 糯米净阴 / 实体灼烧与湿润状态
	if fail == "":
		if sim.get_sim_version() != "c-sim/3.0.0":
			fail = "C-SIM 版本不符：%s（预期 c-sim/3.0.0）" % sim.get_sim_version()
	if fail == "":
		# 在西侧干净岩区内开辟 3 处微型沙盒测试反应与 C-EVT 桥接
		event_bus.reset()
		var seen_reactions: Dictionary = {}
		var r_cb := func(e: Dictionary) -> void:
			if String(e.get("type", "")) == "reaction_triggered":
				seen_reactions[String(e.get("reaction_id", ""))] = true
		event_bus.subscribe(r_cb)
		_active_rect = Rect2i(60, 420, 180, 64)
		sim.set_active_rect(_active_rect.position.x, _active_rect.position.y, _active_rect.size.x, _active_rect.size.y)
		# 9a) 黑火药（硝石+硫磺+煤 + 热冲击 -> 爆炸）
		var bp_c := Vector2i(90, 450)
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				sim.set_cell(bp_c.x + dx, bp_c.y + dy, 0)
		sim.set_cell_by_name(bp_c.x - 1, bp_c.y, "saltpeter")
		sim.set_cell_by_name(bp_c.x, bp_c.y, "sulfur")
		sim.set_cell_by_name(bp_c.x + 1, bp_c.y, "coal")
		sim.apply_heat_burst(bp_c.x, bp_c.y, 4, 400.0)
		_drain_sim_events()
		# 9b) 石灰 + 水 -> 蒸汽
		var lm_c := Vector2i(140, 450)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				sim.set_cell(lm_c.x + dx, lm_c.y + dy, 0)
		for dx in range(-2, 3):
			sim.set_cell_by_name(lm_c.x + dx, lm_c.y + 3, "rock")
			sim.set_cell_by_name(lm_c.x + dx, lm_c.y + 2, "water")
			sim.set_cell_by_name(lm_c.x + dx, lm_c.y + 1, "lime")
		# 9c) 糯米 + 阴气 -> 清除阴气且保留糯米
		var rc_c := Vector2i(190, 450)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				sim.set_cell(rc_c.x + dx, rc_c.y + dy, 0)
		for dx in range(-2, 3):
			sim.set_cell_by_name(rc_c.x + dx, rc_c.y + 3, "rock")
			sim.set_cell_by_name(rc_c.x + dx, rc_c.y + 2, "glutinous_rice")
			sim.set_cell_by_name(rc_c.x + dx, rc_c.y + 1, "yin_qi")
		_fast_forward(6)
		event_bus.unsubscribe(r_cb)
		var steam_cnt := _count_material(lm_c, 6, sim.material_id("steam"))
		var rice_cnt := _count_material(rc_c, 5, sim.material_id("glutinous_rice"))
		var yin_cnt := _count_material(rc_c, 5, sim.material_id("yin_qi"))
		if not seen_reactions.has("r-black-powder"):
			fail = "M1-12 桥接未收到 r-black-powder 事件"
		elif not seen_reactions.has("r-lime-steam") or steam_cnt <= 0:
			fail = "M1-12 未触发石灰遇水生蒸汽（steam=%d）" % steam_cnt
		elif not seen_reactions.has("r-rice-purify") or rice_cnt < 5 or yin_cnt != 0:
			fail = "M1-12 糯米净阴异常（rice=%d yin=%d）" % [rice_cnt, yin_cnt]
		else:
			# 9d) 玩家状态机：触火 -> burning，浸水 -> 清除 burning 并获得 wet
			executor.burning_ticks = 0
			executor.wet_ticks = 0
			var st_pos := Vector2i(20, 270)
			sim.set_cell_by_name(st_pos.x, st_pos.y - 2, "fire")
			executor.tick_hazards(st_pos)
			var lit_burn: bool = executor.burning_ticks > 0
			sim.set_cell(st_pos.x, st_pos.y - 2, 0)
			sim.set_cell_by_name(st_pos.x, st_pos.y - 1, "water")
			executor.tick_hazards(st_pos)
			var cleared_by_water: bool = (executor.burning_ticks == 0 and executor.wet_ticks > 0)
			sim.set_cell(st_pos.x, st_pos.y - 1, 0)
			if not lit_burn or not cleared_by_water:
				fail = "M1-12 实体灼烧/湿润状态异常（burn=%s cleared=%s）" % [str(lit_burn), str(cleared_by_water)]
			else:
				print("T4B_SMOKE_STEP M1-12反应与状态 ver=%s react=%d steam=%d rice=%d burn_wet=ok" % [
					sim.get_sim_version(), seen_reactions.size(), steam_cnt, rice_cnt
				])

	# 10) M1-02 战斗与投射物全回归：穿透 pierce / weak_to / on_hit+on_expire 触发树 / drain_life / 3 条实体标签反应
	if fail == "":
		event_bus.reset()
		var m102_reacts: Dictionary = {}
		var m102_cb := func(e: Dictionary) -> void:
			if String(e.get("type", "")) == "reaction_triggered":
				m102_reacts[String(e.get("reaction_id", ""))] = true
		event_bus.subscribe(m102_cb)
		# 清出一块干净战斗试验场（x 280..410, y 420..470）
		for cy in range(420, 470):
			for cx in range(280, 410):
				sim.set_cell(cx, cy, 0)
		# 10a) pierce=1 + weak_to：1 发阳属性穿透弹同时打穿 A(普通) 与 B(弱阳×2.0)
		var ent_a = combat.spawn_entity({
			"id": "smoke_a", "name": "靶A", "faction": "enemy",
			"pos": Vector2(315.0, 455.0), "max_hp": 30.0, "tags": [], "weak_to": {},
		})
		var ent_b = combat.spawn_entity({
			"id": "smoke_b", "name": "靶B", "faction": "enemy",
			"pos": Vector2(345.0, 455.0), "max_hp": 50.0, "tags": ["spirit"], "weak_to": {"阳": 2.0},
		})
		var trig_before: int = int(combat.stats["triggers_fired"])
		var healed_before: float = float(combat.stats["total_healed"])
		combat.execute_actions([{
			"op": "spawn_projectile", "spell": "body-flying-sword", "count": 1,
			"damage": 10, "damage_type": "阳", "element": "金",
			"pierce": 1, "speed": 12, "ttl_ticks": 40,
			"payloads": [{"op": "drain_life", "amount": 4}],
			"trigger": {"kind": "on_hit", "depth": 1, "actions": [
				{"op": "damage", "amount": 5, "damage_type": "火"}
			]},
		}], Vector2(290.0, 450.0), Vector2.RIGHT, "player", "player")
		# 10b) on_expire（奉·时）：空飞 5 tick 后到期生成水
		combat.execute_actions([{
			"op": "spawn_projectile", "spell": "body-tengsheng", "count": 1,
			"damage": 0, "speed": 8, "ttl_ticks": 5,
			"payloads": [],
			"trigger": {"kind": "on_expire", "depth": 1, "actions": [
				{"op": "spawn_material", "material": "water", "radius": 2}
			]},
		}], Vector2(295.0, 432.0), Vector2.RIGHT, "player", "player")
		_fast_forward(20)
		var expire_water := _count_material(Vector2i(310, 432), 8, sim.material_id("water"))
		# A 应受：10(直伤)+4(drain_life)+5(on_hit) = 19 -> hp=11
		# B 应受：10*2(弱阳直伤)+4(drain_life) = 24 -> hp=26（trigger 每发只触发一次）
		var a_ok: bool = absf(ent_a.hp - 11.0) < 0.01
		var b_ok: bool = absf(ent_b.hp - 26.0) < 0.01
		var trig_ok: bool = (int(combat.stats["triggers_fired"]) - trig_before) >= 2
		var heal_ok: bool = (float(combat.stats["total_healed"]) - healed_before) >= 8.0
		if not a_ok or not b_ok:
			fail = "M1-02 穿透/弱点结算异常（A hp=%.1f 期望11, B hp=%.1f 期望26）" % [ent_a.hp, ent_b.hp]
		elif not trig_ok or expire_water <= 0:
			fail = "M1-02 on_hit/on_expire 触发树异常（trigs=%d water=%d）" % [
				int(combat.stats["triggers_fired"]) - trig_before, expire_water
			]
		elif not heal_ok:
			fail = "M1-02 drain_life 吸血未生效（healed=%.1f）" % (float(combat.stats["total_healed"]) - healed_before)
		else:
			# 10c) 剩余 3 条实体标签反应（至此 8/8 反应全通）
			# #6 r-dog-blood-spirit：黑狗血 × spirit -> 消耗血 + 20*2 阳伤
			var ent_sp = combat.spawn_entity({
				"id": "smoke_spirit", "name": "阴灵", "faction": "enemy",
				"pos": Vector2(370.0, 455.0), "max_hp": 60.0, "tags": ["spirit"], "weak_to": {"阳": 2.0},
			})
			sim.set_cell_by_name(370, 452, "black_dog_blood")
			# #7 r-quicksilver-ward：水银 × eldritch -> 阻挡且不消耗水银
			var ent_el = combat.spawn_entity({
				"id": "smoke_eldritch", "name": "旧日", "faction": "enemy",
				"pos": Vector2(388.0, 455.0), "max_hp": 60.0, "tags": ["eldritch"],
			})
			sim.set_cell_by_name(392, 452, "quicksilver")
			var qs_mat: int = sim.material_id("quicksilver")
			var blocked: bool = ent_el.is_blocked_by_quicksilver(sim, Vector2(392.0, 455.0), sim.get_tick(), event_bus, qs_mat)
			# #8 r-cinnabar-talisman：朱砂 × paper -> 消耗朱砂 + 临时符位 60s
			var ent_pa = combat.spawn_entity({
				"id": "smoke_paper", "name": "符纸", "faction": "player",
				"pos": Vector2(400.0, 455.0), "max_hp": 20.0, "tags": ["paper"],
			})
			sim.set_cell_by_name(400, 452, "cinnabar")
			_fast_forward(2)
			event_bus.unsubscribe(m102_cb)
			if not m102_reacts.has("r-dog-blood-spirit") or absf(ent_sp.hp - 20.0) > 0.01 or sim.get_cell(370, 452) != 0:
				fail = "M1-12/02 r-dog-blood-spirit 异常（hp=%.1f cell=%d）" % [ent_sp.hp, sim.get_cell(370, 452)]
			elif not blocked or not m102_reacts.has("r-quicksilver-ward") or sim.get_cell(392, 452) != qs_mat:
				fail = "M1-12/02 r-quicksilver-ward 异常（blocked=%s cell=%d）" % [str(blocked), sim.get_cell(392, 452)]
			elif not m102_reacts.has("r-cinnabar-talisman") or ent_pa.temp_slot_ticks <= 3500 or sim.get_cell(400, 452) != 0:
				fail = "M1-12/02 r-cinnabar-talisman 异常（slot_ticks=%d cell=%d）" % [ent_pa.temp_slot_ticks, sim.get_cell(400, 452)]
			else:
				print("T4B_SMOKE_STEP M1-02战斗+3实体反应 pierce=ok weak_to=2x triggers=%d reacts_8of8=ok" % [
					int(combat.stats["triggers_fired"]) - trig_before
				])

	# 11) M1-05 七星灯双轴回归：100 气血 / 0.2-0.5 小数阴伤熄灯 / 跨整盏上限 -1/7 / 回血受上限约束 / 复灯恢复
	if fail == "":
		vitals.reset()
		event_bus.reset()
		var d1: Dictionary = vitals.take_hp_damage(30.0, "火", "test_fire", sim.get_tick(), event_bus, "$ui_death_fire")
		var y1: Dictionary = vitals.extinguish_lanterns(0.4, "test_yin", sim.get_tick(), event_bus)
		var eff_after_partial: float = vitals.effective_max_hp()
		var y2: Dictionary = vitals.extinguish_lanterns(0.6, "test_yin", sim.get_tick(), event_bus)
		var eff_after_one: float = vitals.effective_max_hp()
		vitals.heal_hp(999.0)
		var hp_capped: float = vitals.hp
		var restored: float = vitals.restore_lanterns(1.0, "hub", sim.get_tick(), event_bus)
		var eff_after_restore: float = vitals.effective_max_hp()
		var expected_6_7: float = 100.0 * 6.0 / 7.0
		if absf(float(d1.get("applied", 0.0)) - 30.0) > 0.01 or absf(eff_after_partial - 100.0) > 0.01:
			fail = "M1-05 普通伤/残烛上限异常（eff_partial=%.2f）" % eff_after_partial
		elif int(y1.get("full_lost", 0)) != 0 or int(y2.get("full_lost", 0)) != 1:
			fail = "M1-05 熄灯整盏门槛判定异常（y1=%s y2=%s）" % [str(y1), str(y2)]
		elif absf(eff_after_one - expected_6_7) > 0.05 or absf(hp_capped - expected_6_7) > 0.05:
			fail = "M1-05 熄1盏后上限或回血钳制异常（eff=%.2f hp=%.2f 期望=%.2f）" % [eff_after_one, hp_capped, expected_6_7]
		elif absf(restored - 1.0) > 0.01 or absf(eff_after_restore - 100.0) > 0.01:
			fail = "M1-05 复灯未恢复上限（restored=%.2f eff=%.2f）" % [restored, eff_after_restore]
		elif event_bus.count_of("lantern_extinguished") != 2 or event_bus.count_of("lantern_restored") != 1:
			fail = "M1-05 C-EVT 熄灯/复灯事件计数异常"
		else:
			vitals.reset()
			print("T4B_SMOKE_STEP M1-05七星灯双轴 hp=100->70 eff_6of7=%.1f restore=100.0" % eff_after_one)

	# 12) M1-03 三段式完整游标 + 3 把法器 + 成文/散符 + 洞天安全区改符锁（D-M1-4）
	if fail == "":
		wand_manager.reset()
		if wand_manager.wand_count() != 3:
			fail = "M1-03 法器数异常：%d（期望 3）" % wand_manager.wand_count()
		else:
			# 12a) 桃木剑（成文 4 位：斩+爆 / 掘+归）：第 1 发 cursor->2，第 2 发 cursor->0 + 回符
			wand_manager.select_wand(0)
			player.set_cell_pos(Vector2i(200, 350))
			var w1a: Dictionary = executor.cast_active_wand(Vector2i(220, 350))
			_fast_forward(14)
			var w1b: Dictionary = executor.cast_active_wand(Vector2i(220, 350))
			var rech_now: bool = wand_manager.is_active_recharging(sim.get_tick())
			if not bool(w1a.get("accepted", false)) or int(w1a.get("cursor_after", -1)) != 2 or bool(w1a.get("round_ended", true)):
				fail = "M1-03 桃木剑第1发游标异常（%s）" % str(w1a)
			elif not bool(w1b.get("accepted", false)) or int(w1b.get("cursor_after", -1)) != 0 or not bool(w1b.get("round_ended", false)) or not rech_now:
				fail = "M1-03 桃木剑第2发未回符（%s rech=%s）" % [str(w1b), str(rech_now)]
			else:
				# 12b) 铜铃（成文 6 位：敕·触 + 斩 + 火 + 化水）：验证静态展开触发深度 depth=1
				wand_manager.select_wand(1)
				var w2: Dictionary = executor.cast_active_wand(Vector2i(240, 350))
				if not bool(w2.get("accepted", false)) or int(w2.get("max_depth", 0)) < 1:
					fail = "M1-03 铜铃敕·触未展开子句（max_depth=%d）" % int(w2.get("max_depth", 0))
				else:
					# 12c) 骨简（散符乱序 + 每次 2 句）
					wand_manager.select_wand(2)
					var w3: Dictionary = executor.cast_active_wand(Vector2i(240, 350))
					if not bool(w3.get("accepted", false)) or int(w3.get("actions", 0)) <= 0:
						fail = "M1-03 骨简散符双句施法失败（%s）" % str(w3)
					else:
						# 12d) D-M1-4 安全区改符锁：矿井内拒绝编辑，安全区内允许装配并生效
						wand_manager.select_wand(0)
						wand_manager.in_safe_zone = false
						var edit_blocked: bool = not wand_manager.equip_from_bag(0, 0, 0)
						wand_manager.in_safe_zone = true
						var bag_first: String = wand_manager.bag[0]
						var edit_ok: bool = wand_manager.equip_from_bag(0, 0, 0)
						var slot0_after: String = String((wand_manager.get_wand(0)["deck"] as Array)[0])
						if not edit_blocked or not edit_ok or slot0_after != bag_first:
							fail = "M1-03 安全区改符锁异常（blocked=%s ok=%s slot0=%s）" % [str(edit_blocked), str(edit_ok), slot0_after]
						else:
							print("T4B_SMOKE_STEP M1-03三法器与游标 wands=3 cursor=0->2->0 trigger_depth=%d safe_edit=ok" % int(w2.get("max_depth", 0)))

	if fail != "":
		push_error("T4B_SMOKE_FAIL: " + fail)
		print("T4B_SMOKE_FAIL " + fail)
		_quit(1)
		return
	print("T4B_SMOKE_OK groups=%d water_gained=%d doused=%d fire_left=%d dug=%d hp=%.0f lanterns=%.1f spirit=%.0f tick=%d completed=%s" % [
		group_ids.size(), water_gained, doused, fire_left, dug_total,
		vitals.hp, vitals.lanterns, vm.get_spirit(), sim.get_tick(), str(completed)
	])
	_quit(0)

func _fast_forward(tick_count: int) -> void:
	for i in range(tick_count):
		sim.step_tick()
		_drain_sim_events()
		if combat != null:
			combat.step_tick()
		vm.tick_advance()
		if wand_manager != null:
			wand_manager.tick_advance(false)
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
