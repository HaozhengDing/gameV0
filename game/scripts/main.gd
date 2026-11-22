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
const ACTIVE_MARGIN := 128      # 活动区 = 视口外扩 128 cells（提前 2 个 chunk 预唤醒，避免走进才现演化）
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
const WangGenScript := preload("res://scripts/wang_gen.gd")
const SteleScript := preload("res://scripts/stele.gd")
const BiomeHazardsScript := preload("res://scripts/biome_hazards.gd")
const EnemyManagerScript := preload("res://scripts/enemies/enemy_manager.gd")
# M1-10 反馈层（打击感六层）：火光 / 后坐 / 定向震屏 / 命中 / 击杀 / 分层音效
const FxLayerScript := preload("res://scripts/feedback/fx_layer.gd")
const ScreenFxScript := preload("res://scripts/feedback/screen_fx.gd")
const SfxBankScript := preload("res://scripts/feedback/sfx_bank.gd")
const FeedbackDirectorScript := preload("res://scripts/feedback/feedback_director.gd")

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
const CAST_FLASH_COLOR := Color(1.0, 0.86, 0.44)  # 符纸燃起的暖白：施法火光固定色，命中色按伤害类型走

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
var wang_gen
var stele_layer
var biome_hazards
var enemy_manager
var exit_marker: ColorRect
var feedback
var fx_layer
var screen_fx
var sfx_bank

# 玩法状态
var group_ids: Array = []
var group_names: Array = []
var group_costs: Array = []
var selected_group := 0
var completed := false
var smoke_mode := false
var shot_mode := false
var fx_shot_mode := false
var boss_shot_mode := false
var use_wang_mine := true
var world_w := WORLD_W
var world_h := WORLD_H
var _run_seed := 20261121
var current_sanity := 100
var _world_ready := false
var _shot_timer := 0.0
var _shot_done := false
var _shot_wait := SHOT_WAIT
var _accum := 0.0
var _hud_timer := 0.0
var _last_view := Vector2i(-999999, -999999)
var _active_rect := Rect2i()
var _reaction_log_tick: Dictionary = {}

# ================================================================== 生命周期

func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	smoke_mode = user_args.has("--t4b-smoke")
	fx_shot_mode = user_args.has("--t4b-fx-shot")
	boss_shot_mode = user_args.has("--t4b-boss-shot")
	shot_mode = user_args.has("--t4b-shot") or fx_shot_mode or boss_shot_mode
	use_wang_mine = not smoke_mode and not user_args.has("--classic-t4b")
	if use_wang_mine:
		world_w = WangGenScript.WORLD_W
		world_h = WangGenScript.WORLD_H
	else:
		world_w = WORLD_W
		world_h = WORLD_H
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
	_create_feedback()
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
	var start_c: Vector2i = wang_gen.start_cell if (use_wang_mine and wang_gen != null) else LevelScript.START_CELL
	var exit_c: Vector2i = wang_gen.exit_cell if (use_wang_mine and wang_gen != null) else LevelScript.EXIT_CELL
	print("T4B_WORLD_READY world=%dx%d scale=%d materials=%s start=%s exit=%s groups=%d mode=%s" % [
		world_w, world_h, SCALE, sim.get_materials_source(),
		str(start_c), str(exit_c), group_ids.size(), "wang_mine" if use_wang_mine else "classic_t4b"
	])

func _quit(code: int) -> void:
	if feedback != null:
		feedback.shutdown()
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
	var pc: Vector2i = player.cell_pos()
	if player != null and player.has_method("tick_invuln"):
		player.tick_invuln()
	if enemy_manager != null and not completed and not smoke_mode:
		enemy_manager.step_tick(Vector2(pc), sim.get_tick(), player.velocity)
	if combat != null:
		combat.step_tick()
	vm.tick_advance()
	var qs_blocked: bool = biome_hazards.check_quicksilver_block(pc, sim.get_tick()) if biome_hazards != null else _is_player_in_quicksilver()
	if wand_manager != null:
		wand_manager.in_safe_zone = _is_player_in_safe_zone()
		wand_manager.tick_advance(qs_blocked)
	if stele_layer != null:
		stele_layer.update_proximity(pc, current_sanity, sim.get_tick())
	if not use_wang_mine:
		level.tick_fire_wall()
	if completed:
		return
	if executor.tick_hazards(pc):
		player.set_cell_pos(wang_gen.start_cell if (use_wang_mine and wang_gen != null) else LevelScript.START_CELL)
		player.reset_motion()
		hud.log_event("回到起点")
		_refresh_hud()
	_check_exit_now()

func _is_player_in_safe_zone() -> bool:
	if player == null:
		return false
	if use_wang_mine and wang_gen != null:
		return wang_gen.is_in_safe_zone(player.cell_pos())
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
		if _shot_timer >= _shot_wait:
			_shot_done = true
			_take_shot()

## 每帧只渲染视口：view = 玩家 cell − (240,135)，裁到世界内 480x270；
## 仅当视口移动时更新 active_rect（避免每帧重复 wake 全屏破坏 chunk 休眠）。
func _apply_view() -> void:
	if sim == null or not sim.has_world() or player == null:
		return
	var pc: Vector2i = player.cell_pos()
	var vx := clampi(pc.x - VIEW_W / 2, 0, maxi(world_w - VIEW_W, 0))
	var vy := clampi(pc.y - VIEW_H / 2, 0, maxi(world_h - VIEW_H, 0))
	if vx != _last_view.x or vy != _last_view.y:
		_last_view = Vector2i(vx, vy)
		var ax := maxi(vx - ACTIVE_MARGIN, 0)
		var ay := maxi(vy - ACTIVE_MARGIN, 0)
		var ax1 := mini(vx + VIEW_W + ACTIVE_MARGIN, world_w)
		var ay1 := mini(vy + VIEW_H + ACTIVE_MARGIN, world_h)
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
	if not sim.create_world(world_w, world_h, _run_seed if use_wang_mine else SEED, _materials_path()):
		push_error("T4B: SimWorldNode.create_world 失败")
		sim = null

func _materials_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../data/materials.json")

func _cards_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../data/talismans.json")

func _create_level() -> void:
	level = LevelScript.new()
	level.setup(sim)
	wang_gen = WangGenScript.new()
	stele_layer = SteleScript.new()
	stele_layer.name = "SteleLayer"
	add_child(stele_layer)
	biome_hazards = BiomeHazardsScript.new()
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
	camera.limit_right = world_w * SCALE
	camera.limit_bottom = world_h * SCALE
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
	# 反馈层占 CanvasLayer 1，HUD 抬到 2（保证白闪/红晕不盖住血条与灯格）
	hud.layer = 2
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
	combat.player_pos_getter = func() -> Vector2:
		return Vector2(player.cell_pos()) if player != null else Vector2.ZERO
	combat.player_hit_callback = _on_player_hit_by_enemy
	enemy_manager = EnemyManagerScript.new()
	enemy_manager.setup(sim, combat, event_bus, text_db, hud, wand_manager)
	enemy_manager.player_hit_callback = _on_player_hit_by_enemy

## M1-10 反馈层装配：世界空间 FX / 屏幕空间 FX / 分层音效 / 反馈导演（订阅 C-EVT）。
func _create_feedback() -> void:
	fx_layer = FxLayerScript.new()
	fx_layer.name = "FxLayer"
	add_child(fx_layer)
	screen_fx = ScreenFxScript.new()
	screen_fx.name = "ScreenFx"
	add_child(screen_fx)
	sfx_bank = SfxBankScript.new()
	sfx_bank.setup(self)
	feedback = FeedbackDirectorScript.new()
	feedback.name = "FeedbackDirector"
	add_child(feedback)
	feedback.setup(event_bus, camera, player, fx_layer, screen_fx, sfx_bank)

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
	if stele_layer != null:
		stele_layer.setup(text_db, event_bus)
	if biome_hazards != null:
		biome_hazards.setup(sim, event_bus, vitals, text_db, hud)
	if use_wang_mine and wang_gen != null:
		var conn: Dictionary = wang_gen.generate_layout(_run_seed)
		if not bool(conn.get("connected", false)):
			push_error("M1-04: Wang Tile 连通性校验失败：%s" % str(conn))
		wang_gen.rasterize_to_sim(sim)
		# 全图预沉降（240 tick）：让所有房间悬空的液体与矿粉彻底落底摊平并休眠，再放实体/石碑
		wang_gen.settle_world(sim, 240)
		var settled_steles: Array[Dictionary] = []
		for raw_s in wang_gen.steles:
			if raw_s is Dictionary:
				var sd: Dictionary = (raw_s as Dictionary).duplicate()
				sd["pos"] = wang_gen.find_safe_stand_pos(sim, sd["pos"], 3, 10)
				settled_steles.append(sd)
		wang_gen.steles = settled_steles
		if stele_layer != null:
			stele_layer.set_steles(wang_gen.steles)
		if exit_marker != null:
			exit_marker.position = Vector2(
				float((wang_gen.exit_cell.x - 8) * SCALE),
				float((wang_gen.exit_cell.y - 16) * SCALE)
			)
	else:
		if not level.build():
			push_error("T4B: level.build 失败")
		if stele_layer != null:
			stele_layer.set_steles([])
	player.setup(sim)
	player.fire_blocks_movement = not use_wang_mine
	var spawn_c: Vector2i = wang_gen.find_safe_stand_pos(sim, wang_gen.start_cell, 2, 10) if (use_wang_mine and wang_gen != null) else LevelScript.START_CELL
	player.set_cell_pos(spawn_c)
	player.reset_motion()
	if wand_manager != null:
		wand_manager.reset()
		wand_manager.in_safe_zone = true
	if wand_ui != null:
		wand_ui.set_open(false)
	if combat != null:
		combat.reset_round()
	if enemy_manager != null:
		enemy_manager.reset_round()
	if combat != null:
		if use_wang_mine and wang_gen != null:
			_spawn_wang_targets()
		else:
			_spawn_demo_targets()
	executor.reset_round()
	vm.reset()
	_last_view = Vector2i(-999999, -999999)

func _spawn_wang_targets() -> void:
	if enemy_manager != null:
		enemy_manager.spawn_from_wang_anchors(wang_gen)
		return

func _spawn_demo_targets() -> void:
	# M1-02 靶标实体（供 classic T4b 回归使用）
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

## M1-06：敌人近战或投射物命中玩家统一结算（无敌帧 + 击退 + 气血/魄灯扣减 + 死后复位）。
func _on_player_hit_by_enemy(hit: Dictionary) -> void:
	if player == null or vitals == null or vitals.is_dead():
		return
	if not smoke_mode and not player.can_take_enemy_hit():
		return
	player.start_enemy_invuln()
	player.trigger_hurt_flash()
	var dir_v: Variant = hit.get("dir", Vector2.ZERO)
	if dir_v is Vector2:
		var kb: Vector2 = (dir_v as Vector2).normalized() * 52.0 + Vector2(0.0, -24.0)
		player.apply_knockback(kb)
	var tick: int = int(hit.get("tick", sim.get_tick() if (sim != null and sim.has_world()) else 0))
	var src: String = String(hit.get("source_id", "异物"))
	var dmg: float = float(hit.get("damage", 0.0))
	var dtype: String = String(hit.get("damage_type", "物理"))
	var ldmg: float = float(hit.get("lantern_damage", 0.0))
	var dead := false
	if ldmg > 0.0:
		var lres: Dictionary = vitals.extinguish_lanterns(ldmg, src, tick, event_bus)
		if bool(lres.get("dead", false)):
			dead = true
	if not dead and dmg > 0.0:
		var hres: Dictionary = vitals.take_hp_damage(dmg, dtype, src, tick, event_bus, "$ui_death_enemy")
		if bool(hres.get("dead", false)):
			dead = true
	if dead and not smoke_mode:
		if hud != null:
			var death_msg: String = text_db.get_text("$ui_death_enemy") if (text_db != null and text_db.has_key("$ui_death_enemy")) else "死于矿中异物"
			hud.log_event(death_msg + " · 回到起点")
		vitals.reset()
		var start_c: Vector2i = wang_gen.start_cell if (use_wang_mine and wang_gen != null) else LevelScript.START_CELL
		player.set_cell_pos(start_c)
		player.reset_motion()
		_refresh_hud()

func _on_combat_event(ev: Dictionary) -> void:
	var etype: String = String(ev.get("type", ""))
	if etype == "entity_killed" and enemy_manager != null:
		enemy_manager.on_entity_killed(String(ev.get("target_id", "")))
	if biome_hazards != null and player != null and not smoke_mode:
		biome_hazards.on_event(ev, player.cell_pos())
	if hud == null or smoke_mode:
		return
	if etype == "entity_killed":
		var tid: String = String(ev.get("target_id", ""))
		var ent = combat.get_entity(tid) if combat != null else null
		var label: String = ent.display_name if ent != null else tid
		if ent == null or not ent.has_tag("boss"):
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
		clampi(floori(mp.x / float(SCALE)), 0, world_w - 1),
		clampi(floori(mp.y / float(SCALE)), 0, world_h - 1)
	)

func _do_cast(aim: Vector2i) -> void:
	var origin: Vector2 = Vector2(player.cell_pos()) if player != null else Vector2(aim)
	var summary: Dictionary = {}
	if wand_manager != null and wand_manager.wand_count() > 0:
		summary = executor.cast_active_wand(aim)
		if wand_ui != null and wand_ui.is_open:
			wand_ui.refresh()
	elif not group_ids.is_empty():
		var gid := String(group_ids[selected_group])
		summary = executor.cast(gid, aim)
	# 第 1/2/3 层：火光 + 后坐 + 定向震屏；威力按本句实际抛出的投射物数量放大
	if feedback != null:
		var power: float = clampf(0.6 + 0.4 * float(summary.get("projectiles", 1)), 0.6, 2.0)
		feedback.on_cast(origin, Vector2(aim), power, CAST_FLASH_COLOR)
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
	if use_wang_mine:
		_run_seed += 1
	if not sim.create_world(world_w, world_h, _run_seed if use_wang_mine else SEED, _materials_path()):
		push_error("T4B: 重开时 create_world 失败")
		return
	_start_round()
	if overlay != null:
		overlay.clear_pulses()
	if feedback != null:
		feedback.reset()
	hud.clear_complete()
	hud.clear_log()
	hud.log_event("重开本轮（seed %d）" % _run_seed if use_wang_mine else "重开本轮")
	_refresh_hud()
	_apply_view()

# ================================================================== --t4b-shot 截图

## 窗口模式目检用：Wang 模式下站在洞天入口安全区碑文旁；经典模式下站在房间 01 中部。
func _setup_shot() -> void:
	var shot_pos: Vector2i = wang_gen.start_cell if (use_wang_mine and wang_gen != null) else LevelScript.SHOT_PLAYER_CELL
	if boss_shot_mode and enemy_manager != null and enemy_manager.boss_ent != null:
		var bp: Vector2i = enemy_manager.boss_ent.cell_pos()
		shot_pos = wang_gen.find_safe_stand_pos(sim, Vector2i(bp.x - 85, bp.y), 2, 10)
		enemy_manager.boss_ent.aggroed = true
		enemy_manager.boss_ent.telegraph_ratio = 0.72
		enemy_manager.boss_ent.telegraph_color = Color(1.0, 0.34, 0.14)
	elif use_wang_mine and wang_gen != null and not wang_gen.steles.is_empty():
		var st_pos: Vector2i = wang_gen.steles[0]["pos"]
		shot_pos = Vector2i(st_pos.x - 16, st_pos.y)
	player.set_cell_pos(shot_pos)
	player.facing = Vector2.RIGHT
	if stele_layer != null:
		stele_layer.update_proximity(shot_pos, current_sanity, 0)
	_refresh_hud()
	_apply_view()
	_shot_timer = 0.0
	_shot_done = false
	_shot_wait = SHOT_WAIT
	if fx_shot_mode:
		# 反馈层目检：把六层同时点亮并冻结在峰值帧，0.06s 后截图
		_shot_wait = 0.06
		_arm_feedback_demo(shot_pos)
	print("T4B_SHOT_ARMED player_cell=%s wait=%.2fs fx=%s" % [str(shot_pos), _shot_wait, str(fx_shot_mode)])

## 仅用于 --t4b-fx-shot：直接驱动 FX 层，产出可目检的一帧（不经过 time_scale，避免截图被顿帧拖慢）。
func _arm_feedback_demo(at: Vector2i) -> void:
	if fx_layer == null:
		return
	var c := Vector2(float(at.x), float(at.y))
	var dir := Vector2.RIGHT
	fx_layer.muzzle(c + Vector2(0.0, -4.0), dir, 1.6, CAST_FLASH_COLOR)
	fx_layer.impact(c + Vector2(13.0, -4.0), dir, 26.0, Color(1.0, 0.55, 0.18), false)
	fx_layer.impact(c + Vector2(24.0, -6.0), -dir, 0.0, Color(0.68, 0.48, 1.0), true)
	fx_layer.damage_number(c + Vector2(16.0, -10.0), 37.0, Color(1.0, 0.55, 0.18), true)
	fx_layer.reaction_ring(c + Vector2(20.0, -4.0), 7.0, Color(1.0, 0.62, 0.2))
	if screen_fx != null:
		screen_fx.flash(Color(1.0, 0.96, 0.88), 0.16, 0.09)
		screen_fx.hurt(0.32)
	if player != null and player.has_method("add_recoil"):
		player.add_recoil(Vector2(-8.0, 0.0))
	# 冻结衰减，截到六层的峰值帧（只影响目检模式）
	if feedback != null:
		feedback.set_process(false)

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
	var at_exit: bool = wang_gen.is_at_exit(player.cell_pos()) if (use_wang_mine and wang_gen != null) else level.is_at_exit(player.cell_pos())
	if at_exit:
		completed = true
		hud.show_complete("本轮完成\n按 R 重开")
		hud.log_event("到达出口，本轮完成")
		return true
	return false

func _refresh_hud() -> void:
	if hud == null or vm == null or executor == null or player == null:
		return
	var target_exit: Vector2i = wang_gen.exit_cell if (use_wang_mine and wang_gen != null) else LevelScript.EXIT_CELL
	var dist_x := roundi(Vector2(player.cell_pos()).distance_to(Vector2(target_exit))) if use_wang_mine else maxi(target_exit.x - player.cell_pos().x, 0)
	var safe_tag := "安全区 · " if (wand_manager != null and wand_manager.in_safe_zone) else ""
	var silver_tag := (" · 银 %d" % enemy_manager.silver_collected) if (enemy_manager != null and enemy_manager.silver_collected > 0) else ""
	var hint: String = "本轮完成 · R 重开" if completed else "%s出口 %d%s" % [safe_tag, dist_x, silver_tag]
	var boss_hud: Dictionary = enemy_manager.get_boss_hud_state(Vector2(player.cell_pos())) if enemy_manager != null else {"visible": false}
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
		"boss": boss_hud,
	})

func _cursor_material_text() -> String:
	if sim == null or not sim.has_world():
		return "—"
	var c: Vector2i = _aim_cell()
	if shot_mode:
		c = Vector2i(80, 196) if use_wang_mine else LevelScript.MERCURY_AIM_CELL
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

	# 13) M1-04 矿井一层完整 Wang Tile + 手工房间拼接 + 连通性多 seed 校验 + 碑文与三大 Hazard 回归
	if fail == "":
		var wg = WangGenScript.new()
		var seeds_ok := 0
		var last_conn: Dictionary = {}
		for s in [20261121, 20261122, 20261123, 20261124, 20261125]:
			var conn: Dictionary = wg.generate_layout(s)
			last_conn = conn
			if not bool(conn.get("connected", false)) or int(conn.get("edge_mismatches", -1)) != 0:
				fail = "M1-04 Wang Tile seed=%d 连通性/边匹配失败：%s" % [s, str(conn)]
				break
			var rooms_hit: Array = conn.get("reachable_rooms", [])
			for req_room in ["hub_entry", "room-01-silver-pit", "room-02-gas-pocket", "room-boss-coalmine"]:
				if not rooms_hit.has(req_room):
					fail = "M1-04 seed=%d 缺少拼接房 %s" % [s, req_room]
					break
			if fail != "":
				break
			seeds_ok += 1
		if fail == "":
			# 把最后一个 seed 光栅化进真实 1536x672 SimWorld，验证碑文(D3 腐坏) + 水银滞灵 + 挖掘塌方
			var sim_ok: bool = sim.create_world(WangGenScript.WORLD_W, WangGenScript.WORLD_H, 20261125, _materials_path())
			if not sim_ok:
				fail = "M1-04 创建 1536x672 Wang 世界失败"
			else:
				var rast_ms: int = wg.rasterize_to_sim(sim)
				var settle_ms: int = wg.settle_world(sim, 240)
				# 校验刷怪翻倍（>=18）且所有真实生成怪物均不在实心格或土堆/悬空粉末下方
				combat.reset_round()
				enemy_manager.reset_round()
				var wang_spawned: int = enemy_manager.spawn_from_wang_anchors(wg)
				var buried := 0
				var under_powder := 0
				for ai_chk in enemy_manager.ais:
					var e_chk = ai_chk.ent
					var sp: Vector2i = e_chk.cell_pos()
					var hw_c: int = ceili(float(e_chk.half_w))
					var hh_c: int = ceili(float(e_chk.height))
					var hit_solid := false
					for gy in range(sp.y - hh_c + 1, sp.y + 1):
						for gx in range(sp.x - hw_c, sp.x + hw_c + 1):
							if sim.is_solid(gx, gy):
								hit_solid = true
								break
						if hit_solid:
							break
					if hit_solid:
						buried += 1
					if wg.has_powder_above(sim, sp.x, sp.y - hh_c + 1, hw_c, 140):
						under_powder += 1
				combat.reset_round()
				enemy_manager.reset_round()
				# 校验 M1 实机模式火焰/毒烟不阻挡玩家移动
				player.setup(sim)
				player.fire_blocks_movement = false
				var walk_c := wg.find_safe_stand_pos(sim, wg.start_cell, 2, 10)
				sim.set_cell_by_name(walk_c.x, walk_c.y - 2, "fire")
				sim.set_cell_by_name(walk_c.x + 1, walk_c.y - 2, "toxic_smoke")
				var blocked_by_gas: bool = player.blocked_at(Vector2(float(walk_c.x * SCALE) + 2.0, float(walk_c.y * SCALE) + 2.0))
				sim.set_cell(walk_c.x, walk_c.y - 2, 0)
				sim.set_cell(walk_c.x + 1, walk_c.y - 2, 0)
				event_bus.reset()
				stele_layer.setup(text_db, event_bus)
				stele_layer.set_steles(wg.steles)
				var st0: Vector2i = wg.steles[0]["pos"]
				var txt_sane: String = stele_layer.update_proximity(st0, 100, 1)
				var txt_corrupt: String = stele_layer.update_proximity(st0, 50, 2)
				# 水银滞灵 hazard
				biome_hazards.setup(sim, event_bus, vitals, text_db, hud)
				var qs_pos := Vector2i(80, 160)
				sim.set_cell_by_name(qs_pos.x, qs_pos.y - 2, "quicksilver")
				var qs_blocked: bool = biome_hazards.check_quicksilver_block(qs_pos, 10)
				# 挖掘过快塌方 hazard（180 tick 内掘 >= 600 格 -> 落石 + 15 HP 伤害）
				vitals.reset()
				var hp_before_col: float = vitals.hp
				biome_hazards.on_event({"type": "terrain_dug", "tick": 20, "pos": qs_pos, "value": 650.0}, qs_pos)
				var hp_after_col: float = vitals.hp
				if wang_spawned < 18:
					fail = "M1-04 矿井翻倍刷怪数量不足（%d < 18）" % wang_spawned
				elif buried > 0 or under_powder > 0:
					fail = "M1-04 预沉降后仍有怪物被掩埋或压在土堆下方（buried=%d under_powder=%d）" % [buried, under_powder]
				elif blocked_by_gas:
					fail = "M1-04 火焰/毒烟错误阻挡了玩家移动"
				elif txt_sane.is_empty() or txt_sane == txt_corrupt or event_bus.count_of("rule_triggered") < 1:
					fail = "M1-04 碑文读写/D3腐坏异常（sane=%s corrupt=%s）" % [txt_sane, txt_corrupt]
				elif not qs_blocked:
					fail = "M1-04 水银池压制回灵未触发"
				elif biome_hazards.collapse_count < 1 or absf((hp_before_col - hp_after_col) - 15.0) > 0.01:
					fail = "M1-04 矿顶塌方 hazard 异常（cnt=%d hp=%.1f->%.1f）" % [biome_hazards.collapse_count, hp_before_col, hp_after_col]
				elif event_bus.count_of("hazard_triggered") < 2:
					fail = "M1-04 C-EVT hazard_triggered 计数不足（%d）" % event_bus.count_of("hazard_triggered")
				else:
					print("T4B_SMOKE_STEP M1-04Wang矿井 seeds=%d/5 connected=100%% macros=12/12 mobs=%d rast_ms=%d settle_ms=%d buried=0 under_powder=0 gas_pass=ok" % [
						seeds_ok, wang_spawned, rast_ms, settle_ms
					])

	# M1-10 反馈层：走真实路径（施法火光/后坐 → 命中/击杀 → 分层音效 → 顿帧复位）
	if fail == "":
		var fb_fail := ""
		if feedback == null or sfx_bank == null or fx_layer == null or screen_fx == null:
			fb_fail = "M1-10 反馈层未装配"
		elif not sfx_bank.has_stream("fire") or not sfx_bank.has_stream("hit") or not sfx_bank.has_stream("kill"):
			fb_fail = "M1-10 分层音效合成缺失"
		else:
			var pc: Vector2i = player.cell_pos()
			var pcv := Vector2(float(pc.x), float(pc.y))
			feedback.on_cast(pcv, pcv + Vector2(12.0, 0.0), 1.2, CAST_FLASH_COLOR)
			feedback.on_event({
				"type": "entity_damaged", "target_id": "smoke-dummy",
				"pos": pc + Vector2i(6, -3), "value": 24.0, "damage_type": "火",
			})
			var slow_after_hit: bool = Engine.time_scale < 0.5
			feedback.on_event({
				"type": "entity_killed", "target_id": "smoke-dummy",
				"pos": pc + Vector2i(9, -3), "value": 30.0, "damage_type": "阴",
			})
			fx_layer.update_fx(0.016)
			screen_fx.tick(0.016)
			feedback.reset()
			# 校验 DoT（毒烟/火伤/灼烧）不触发全局顿帧
			feedback.on_event({
				"type": "entity_damaged", "source_id": "毒烟", "target_id": "player",
				"pos": pc, "value": 1.5, "damage_type": "毒",
			})
			feedback.on_event({
				"type": "entity_damaged", "source_id": "火伤", "target_id": "player",
				"pos": pc, "value": 4.0, "damage_type": "火",
			})
			var dot_no_hitstop: bool = absf(Engine.time_scale - 1.0) < 0.001
			feedback.reset()
			if not slow_after_hit:
				fb_fail = "M1-10 命中顿帧未生效（time_scale=%.2f）" % Engine.time_scale
			elif not dot_no_hitstop:
				fb_fail = "M1-10 毒烟/灼烧 DoT 错误触发了顿帧"
			elif absf(Engine.time_scale - 1.0) > 0.001:
				fb_fail = "M1-10 顿帧未复位（time_scale=%.2f）" % Engine.time_scale
		if fb_fail != "":
			fail = fb_fail
		else:
			print("T4B_SMOKE_STEP M1-10打击感六层 fx=ok screen=ok sfx=3 hitstop=ok recoil=ok")

	# M1-06 敌人 AI 与旱魃 BOSS 战（5 敌人配置 / 矿鬼追击 / 画皮水银界+熄灯 / 鬼火引硫 / 旱魃火抗+泼水破甲+二阶段+击杀掉落）
	if fail == "":
		var m6_fail := ""
		if enemy_manager == null or enemy_manager.defs.size() < 5:
			m6_fail = "M1-06 敌人定义数量不足（%d）" % (enemy_manager.defs.size() if enemy_manager != null else 0)
		else:
			# 搭建隔离测试室 x=120..260, y=220..272（岩底 y=272..276）
			var mat_rock_6: int = sim.material_id("rock")
			var mat_qs_6: int = sim.material_id("quicksilver")
			var mat_sul_6: int = sim.material_id("sulfur")
			var mat_wat_6: int = sim.material_id("water")
			sim.set_active_rect(110, 210, 170, 80)
			for gy in range(218, 277):
				for gx in range(118, 263):
					var is_border := (gy >= 272 or gy <= 220 or gx <= 120 or gx >= 260)
					sim.set_cell(gx, gy, mat_rock_6 if is_border else 0)
			sim.wake_rect(118, 218, 145, 59)

			# 15a) 矿鬼巡逻追击并挥爪伤害玩家
			combat.reset_round()
			enemy_manager.reset_round()
			vitals.reset()
			player.set_cell_pos(Vector2i(150, 271))
			player.reset_motion()
			var ghost_ent = enemy_manager.spawn_by_id("enemy-coal-ghost", Vector2i(178, 271), "smoke_ghost", 1)
			var ghost_x0: float = ghost_ent.pos.x
			for _t in range(95):
				sim.step_tick()
				enemy_manager.step_tick(Vector2(player.cell_pos()), sim.get_tick())
				combat.step_tick()
			var ghost_moved: bool = ghost_ent.pos.x < ghost_x0 - 8.0
			var ghost_hit_ok: bool = vitals.hp < 100.0

			# 15b) 画皮被水银界阻挡 + 阴气弹熄灯
			combat.reset_round()
			enemy_manager.reset_round()
			vitals.reset()
			player.set_cell_pos(Vector2i(150, 271))
			player.reset_motion()
			for gy in range(264, 272):
				for gx in range(175, 182):
					sim.set_cell(gx, gy, mat_qs_6)
			var ps_ent = enemy_manager.spawn_by_id("enemy-painted-skin", Vector2i(204, 271), "smoke_painted_skin", 2)
			for _t in range(120):
				sim.step_tick()
				enemy_manager.step_tick(Vector2(player.cell_pos()), sim.get_tick())
				combat.step_tick()
			var ps_warded: bool = ps_ent.pos.x >= 180.0
			var ps_lantern_ok: bool = vitals.lanterns < 7.0

			# 15c) 硫烟鬼火火弹引燃硫磺
			combat.reset_round()
			enemy_manager.reset_round()
			vitals.reset()
			for gy in range(262, 272):
				for gx in range(146, 185):
					sim.set_cell(gx, gy, 0)
			for gy in range(260, 272):
				for gx in range(150, 158):
					sim.set_cell(gx, gy, mat_sul_6)
			player.set_cell_pos(Vector2i(144, 271))
			player.reset_motion()
			enemy_manager.spawn_by_id("enemy-gas-wisp", Vector2i(206, 256), "smoke_wisp", 3)
			var fired_proj_before: int = int(combat.stats["projectiles_spawned"])
			for _t in range(105):
				sim.step_tick()
				enemy_manager.step_tick(Vector2(player.cell_pos()), sim.get_tick())
				combat.step_tick()
			var wisp_shot_ok: bool = int(combat.stats["projectiles_spawned"]) > fired_proj_before
			var mat_tox_6: int = sim.material_id("toxic_smoke")
			var mat_fire_6: int = sim.material_id("fire")
			var wisp_ignited := (_count_material(Vector2i(156, 266), 12, mat_tox_6) > 0
					or _count_material(Vector2i(156, 266), 12, mat_fire_6) > 0
					or int(combat.stats["ignited"]) > 0)

			# 15d) 旱魃 BOSS：火抗 0.25x / 泼水嘶鸣+湿润破甲 1.4x / 二阶段 / 击杀掉落
			combat.reset_round()
			enemy_manager.reset_round()
			vitals.reset()
			for gy in range(250, 272):
				for gx in range(140, 230):
					sim.set_cell(gx, gy, 0)
			player.set_cell_pos(Vector2i(150, 271))
			player.reset_motion()
			var boss = enemy_manager.spawn_by_id("enemy-drought-demon", Vector2i(206, 271), "smoke_boss", 4)
			var fire_dealt: float = boss.take_damage(40.0, "火", "smoke", sim.get_tick(), event_bus)
			for gy in range(264, 272):
				for gx in range(200, 214):
					sim.set_cell(gx, gy, mat_wat_6)
			var hp_before_wat: float = boss.hp
			for _t in range(36):
				sim.step_tick()
				enemy_manager.step_tick(Vector2(player.cell_pos()), sim.get_tick())
				combat.step_tick()
			var boss_wet_ok: bool = boss.has_status("wet") and boss.hp < hp_before_wat
			var crack_dealt: float = boss.take_damage(20.0, "金", "smoke", sim.get_tick(), event_bus)
			boss.take_damage(120.0, "水", "smoke", sim.get_tick(), event_bus)
			for _t in range(10):
				sim.step_tick()
				enemy_manager.step_tick(Vector2(player.cell_pos()), sim.get_tick())
				combat.step_tick()
			var boss_p2_ok: bool = boss.phase == 2
			boss.take_damage(500.0, "阴", "smoke", sim.get_tick(), event_bus)
			var boss_drop_ok: bool = (not boss.alive and enemy_manager.boss_killed
					and enemy_manager.silver_collected >= 150
					and wand_manager != null and wand_manager.bag.has("body-bifang-huo"))

			if not ghost_moved or not ghost_hit_ok:
				m6_fail = "M1-06 矿鬼追击/攻击失败（moved=%s hp=%.1f）" % [str(ghost_moved), vitals.hp]
			elif not ps_warded or not ps_lantern_ok:
				m6_fail = "M1-06 画皮水银界或阴弹熄灯失败（x=%.1f lanterns=%.2f）" % [ps_ent.pos.x, vitals.lanterns]
			elif not wisp_shot_ok or not wisp_ignited:
				m6_fail = "M1-06 硫烟鬼火发射/引燃失败（shot=%s ignited=%s）" % [str(wisp_shot_ok), str(wisp_ignited)]
			elif absf(fire_dealt - 10.0) > 0.05:
				m6_fail = "M1-06 旱魃火抗 0.25x 异常（dealt=%.2f）" % fire_dealt
			elif not boss_wet_ok or absf(crack_dealt - 28.0) > 0.05:
				m6_fail = "M1-06 旱魃泼水破甲异常（wet=%s crack=%.2f）" % [str(boss_wet_ok), crack_dealt]
			elif not boss_p2_ok or not boss_drop_ok:
				m6_fail = "M1-06 旱魃二阶段或掉落异常（p2=%s drop=%s silver=%d）" % [str(boss_p2_ok), str(boss_drop_ok), enemy_manager.silver_collected]
			else:
				print("T4B_SMOKE_STEP M1-06敌人与旱魃 defs=5 ghost=ok ward_lantern=ok wisp_ignite=ok boss_wet=%.1f p2=ok drop=%d" % [
					crack_dealt, enemy_manager.silver_collected
				])
		if m6_fail != "":
			fail = m6_fail

	# m1-jump-feel P0 跳跃跟手断言（土狼时间 0.10s / 跳跃缓冲 0.10s / 可变跳高 0.10s 窗口切断）
	if fail == "":
		var jf_fail := ""
		var mat_rock_j: int = sim.material_id("rock")
		# 搭一座隔离跳台：左台 x=300..330, y=272..276；下层全宽地面 x=298..395, y=316..322
		for gy in range(250, 323):
			for gx in range(298, 396):
				var solid_plat := (gy >= 272 and gy <= 276 and gx >= 300 and gx <= 330) or (gy >= 316)
				sim.set_cell(gx, gy, mat_rock_j if solid_plat else 0)
		player.fire_blocks_movement = false
		# 16a) 土狼时间：离台 5 帧(0.083s < 0.10s)应可跳；离台 8 帧(0.133s > 0.10s)不应起跳
		player.set_cell_pos(Vector2i(318, 271))
		player.reset_motion()
		player.levitate = 0.0
		for _s in range(6):
			player.step_physics(FIXED_DT, 0.0, false, false)
		player.set_cell_pos(Vector2i(342, 271))
		for _i in range(5):
			player.step_physics(FIXED_DT, 0.0, false, false)
		player.step_physics(FIXED_DT, 0.0, true, false)
		var coyote_ok: bool = player.velocity.y < -50.0

		player.set_cell_pos(Vector2i(318, 271))
		player.reset_motion()
		player.levitate = 0.0
		for _s in range(6):
			player.step_physics(FIXED_DT, 0.0, false, false)
		player.set_cell_pos(Vector2i(342, 271))
		for _i in range(8):
			player.step_physics(FIXED_DT, 0.0, false, false)
		player.step_physics(FIXED_DT, 0.0, true, false)
		var coyote_expire_ok: bool = player.velocity.y >= 0.0

		# 16b) 跳跃缓冲：落地前 2 帧事件入队（按键不按住），落地当帧自动起跳
		player.set_cell_pos(Vector2i(355, 311))
		player.reset_motion()
		player.levitate = 0.0
		player.velocity.y = 95.0
		player.queue_jump_buffer()
		var buf_jumped := false
		for _i in range(6):
			player.step_physics(FIXED_DT, 0.0, false, false)
			if player.velocity.y < -40.0:
				buf_jumped = true
				break

		# 16c) 可变跳高：起跳后 0.05s(3 帧)松手 vs 满按 0.16s(10 帧)，短按峰高显著更低
		player.set_cell_pos(Vector2i(355, 315))
		player.reset_motion()
		player.levitate = 0.0
		for _s in range(6):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var y0_short: float = player.position.y
		var min_y_short: float = y0_short
		for i in range(28):
			player.step_physics(FIXED_DT, 0.0, i < 3, false)
			min_y_short = minf(min_y_short, player.position.y)
		var rise_short: float = (y0_short - min_y_short) / float(SCALE)

		player.set_cell_pos(Vector2i(355, 315))
		player.reset_motion()
		player.levitate = 0.0
		for _s in range(6):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var y0_full: float = player.position.y
		var min_y_full: float = y0_full
		for i in range(28):
			player.step_physics(FIXED_DT, 0.0, i < 10, false)
			min_y_full = minf(min_y_full, player.position.y)
		var rise_full: float = (y0_full - min_y_full) / float(SCALE)

		if not coyote_ok or not coyote_expire_ok:
			jf_fail = "m1-jump-feel 土狼时间断言失败（in_win=%s expired=%s）" % [str(coyote_ok), str(coyote_expire_ok)]
		elif not buf_jumped:
			jf_fail = "m1-jump-feel 跳跃缓冲落地自动起跳失败"
		elif rise_short >= rise_full * 0.72 or rise_full < 8.0:
			jf_fail = "m1-jump-feel 可变跳高切断不足（short=%.1f full=%.1f）" % [rise_short, rise_full]
		else:
			print("T4B_SMOKE_STEP m1-jump-feel_P0 coyote=ok buffer=ok var_jump=%.1f<%.1f" % [rise_short, rise_full])
		if jf_fail != "":
			fail = jf_fail

	# M1-α 打磨与复测断言：土堆禁下沉+表层三级减速（玩家+小怪）/ 浮空收敛+下落慢充+防无限飞 / 旱魃高伤+空间AI+主动畏水跃避+湿破甲脱困
	if fail == "":
		var a_fail := ""
		var mat_rock_a: int = sim.material_id("rock")
		var mat_coal_a: int = sim.material_id("coal")
		var mat_sul_a: int = sim.material_id("sulfur")
		var mat_cin_a: int = sim.material_id("cinnabar")
		var mat_wat_a: int = sim.material_id("water")

		# 17a) 踩在沉降土堆顶部按 S 绝不下沉 + 表面行走三级密度减速（煤 > 硫磺 > 朱砂）+ 地面小怪同步受重粉减速且不下沉
		for gy in range(290, 323):
			for gx in range(420, 560):
				sim.set_cell(gx, gy, mat_rock_a if gy >= 316 else 0)
		var wades: Array[float] = []
		var player_no_sink := true
		for mat_id_t in [mat_coal_a, mat_sul_a, mat_cin_a]:
			for gy in range(306, 316):
				for gx in range(430, 520):
					sim.set_cell(gx, gy, mat_id_t)
			# 校验按 S（dive=true）仍稳站土堆表面不下沉
			player.set_cell_pos(Vector2i(436, 305))
			player.reset_motion()
			for _d in range(20):
				player.step_physics(FIXED_DT, 0.0, false, true)
			if player.cell_pos().y > 305:
				player_no_sink = false
			# 校验在粉堆表面水平行走产生清晰三级密度减速
			var x0_w: float = player.position.x
			for _i in range(24):
				player.step_physics(FIXED_DT, 1.0, false, false)
			wades.append((player.position.x - x0_w) / float(SCALE))
		# 地面小怪在朱砂堆表面行走：同样显著减速且不下沉到土堆下方
		combat.reset_round()
		enemy_manager.reset_round()
		var cin_ghost = enemy_manager.spawn_by_id("enemy-coal-ghost", Vector2i(452, 305), "smoke_cin_ghost", 5)
		var cin_ai = enemy_manager.get_ai_for("smoke_cin_ghost")
		var cin_x0: float = cin_ghost.pos.x
		for _i in range(24):
			enemy_manager.step_tick(Vector2(500.0, 305.0), sim.get_tick())
		var mob_cin_slow: bool = (cin_ai != null and cin_ai.powder_speed_mult < 0.55
				and cin_ghost.pos.x > cin_x0 + 1.0 and float(cin_ghost.pos.y) <= 306.0)

		# 17b) 浮空收敛（单气爬 80..130 格）+ 延迟下落慢充 + 高频点按防无限滞空
		for gy in range(130, 323):
			for gx in range(340, 375):
				sim.set_cell(gx, gy, mat_rock_a if (gy >= 316 or gy <= 132) else 0)
		player.set_cell_pos(Vector2i(356, 315))
		player.reset_motion()
		for _s in range(4):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var climb_y0: float = player.position.y
		var climb_min_y: float = climb_y0
		for _i in range(110):
			player.step_physics(FIXED_DT, 0.0, player.levitate > 0.5, false)
			climb_min_y = minf(climb_min_y, player.position.y)
		var single_tank_climb: float = (climb_y0 - climb_min_y) / float(SCALE)

		# 下落慢充：前 14 帧(0.23s < 0.28s)不回充，60 帧(1.0s)后明确慢回充
		player.set_cell_pos(Vector2i(356, 160))
		player.reset_motion()
		player.levitate = 40.0
		player.step_physics(FIXED_DT, 0.0, true, false)  # 触发一次推力启动延迟计时
		var lev_after_tap: float = player.levitate
		for _i in range(14):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var lev_at_delay: float = player.levitate
		for _i in range(46):
			player.step_physics(FIXED_DT, 0.0, false, false)
		var lev_after_fall: float = player.levitate
		var fall_regen_ok: bool = absf(lev_at_delay - lev_after_tap) < 0.05 and (lev_after_fall - lev_at_delay) >= 6.0 and (lev_after_fall - lev_at_delay) <= 18.0

		# 防无限飞：空旷高井高频点按循环（推 8 帧 + 落 24 帧 × 10 轮），净高度必下降且气槽耗尽
		player.set_cell_pos(Vector2i(356, 160))
		player.reset_motion()
		var tap_y0: float = player.position.y
		for cycle in range(10):
			for f in range(32):
				player.step_physics(FIXED_DT, 0.0, f < 8, false)
		var tap_drop_cells: float = (player.position.y - tap_y0) / float(SCALE)
		var no_inf_flight: bool = tap_drop_cells > 40.0 and player.levitate < 25.0

		# 17c) 旱魃高伤 + 空间效用 AI + 主动畏水跃避（未沾水即跳开）+ 湿破甲硬直后跃离水洼
		for gy in range(195, 277):
			for gx in range(118, 263):
				var bdr := (gy >= 272 or gy <= 198 or gx <= 120 or gx >= 260)
				sim.set_cell(gx, gy, mat_rock_a if bdr else 0)
		combat.reset_round()
		enemy_manager.reset_round()
		var s_boss = enemy_manager.spawn_by_id("enemy-drought-demon", Vector2i(210, 271), "smoke_smart_boss", 6)
		var s_boss_ai = enemy_manager.get_boss_ai()
		var boss_dmg_raised: bool = float(enemy_manager.defs["enemy-drought-demon"].get("damage", 0.0)) >= 20.0
		s_boss_ai.cooldown_ticks = 0
		var high_counter_ok := false
		for _t in range(45):
			sim.step_tick()
			enemy_manager.step_tick(Vector2(170.0, 224.0), sim.get_tick())
			combat.step_tick()
			if s_boss_ai.active_boss_move in ["platform_leap", "fan_fire"] and s_boss_ai.state in ["telegraph", "attack"]:
				high_counter_ok = true
				break
		# 主动畏水跃避：干燥旱魃脚前放一滩水洼（不直接盖身），应主动触发 avoid_water 跳避而非闷头踩水
		for gy in range(250, 272):
			for gx in range(122, 258):
				sim.set_cell(gx, gy, 0)
		for gy in range(266, 272):
			for gx in range(186, 198):
				sim.set_cell(gx, gy, mat_wat_a)
		s_boss.pos = Vector2(210.0, 271.0)
		s_boss.vel = Vector2.ZERO
		s_boss.statuses.erase("wet")
		s_boss_ai.state = "chase"
		s_boss_ai.on_ground = true
		s_boss_ai.cooldown_ticks = 40
		s_boss_ai.water_avoid_cd = 0
		s_boss_ai.was_wet = false
		var saw_avoid_water := false
		for _t in range(36):
			sim.step_tick()
			combat.step_tick()
			enemy_manager.step_tick(Vector2(150.0, 271.0), sim.get_tick())
			if s_boss_ai.active_boss_move == "avoid_water" and float(s_boss.vel.y) < -30.0:
				saw_avoid_water = true
				break
		# 湿破甲硬直与离水跳
		for gy in range(266, 272):
			for gx in range(198, 222):
				sim.set_cell(gx, gy, mat_wat_a)
		s_boss.pos = Vector2(210.0, 271.0)
		s_boss.vel = Vector2.ZERO
		s_boss_ai.state = "chase"
		s_boss_ai.wet_flinch_cd = 0
		s_boss_ai.water_avoid_cd = 60
		s_boss_ai.was_wet = false
		var saw_flinch := false
		var saw_escape := false
		for _t in range(65):
			sim.step_tick()
			combat.step_tick()
			enemy_manager.step_tick(Vector2(150.0, 271.0), sim.get_tick())
			if s_boss_ai.state == "flinch":
				saw_flinch = true
			if s_boss_ai.active_boss_move == "escape_leap" and float(s_boss.vel.y) < -30.0:
				saw_escape = true

		if not player_no_sink:
			a_fail = "M1-α 人物按 S 仍能下沉进入土堆"
		elif not (wades[0] > wades[1] and wades[1] > wades[2] and wades[2] > 3.0):
			a_fail = "M1-α 粉末分级减速阶梯异常（coal=%.1f sul=%.1f cin=%.1f）" % [wades[0], wades[1], wades[2]]
		elif not mob_cin_slow:
			a_fail = "M1-α 地面小怪重粉减速或防下沉失败"
		elif single_tank_climb < 78.0 or single_tank_climb > 135.0:
			a_fail = "M1-α 单管浮空爬高越界（%.1f 格，目标 78..135）" % single_tank_climb
		elif not fall_regen_ok:
			a_fail = "M1-α 延迟下落慢充异常（tap=%.1f delay=%.1f fall=%.1f）" % [lev_after_tap, lev_at_delay, lev_after_fall]
		elif not no_inf_flight:
			a_fail = "M1-α 防无限飞断言失败（drop=%.1f lev=%.1f）" % [tap_drop_cells, player.levitate]
		elif not boss_dmg_raised or not high_counter_ok or not saw_avoid_water or not saw_flinch or not saw_escape:
			a_fail = "M1-α 旱魃高伤/畏水AI异常（dmg=%s high=%s avoid=%s flinch=%s escape=%s）" % [
				str(boss_dmg_raised), str(high_counter_ok), str(saw_avoid_water), str(saw_flinch), str(saw_escape)
			]
		else:
			print("T4B_SMOKE_STEP M1-α复测打磨 no_sink=ok surf=%.1f>%.1f>%.1f mob_slow=ok climb=%.1f fall_regen=+%.1f boss_fear_water=ok" % [
				wades[0], wades[1], wades[2], single_tank_climb, lev_after_fall - lev_at_delay
			])
		if a_fail != "":
			fail = a_fail

	# 复位 vitals 供末尾统一汇报
	vitals.reset()
	vitals.take_hp_damage(15.0, "土", "smoke_summary", sim.get_tick(), null, "$ui_death_enemy")

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
