extends RefCounted
## M1-06 / M1-α 单体敌人 AI 控制器：
## 1) 驱动矿井一层 5 种敌人（矿鬼 / 土蝼 / 硫烟鬼火 / 画皮 / 旱魃 BOSS）的状态机与像素沙盒物理；
## 2) 同步粉末密度分级减速（refs/cards/decisions/powder-traversal.md#density-drag-wade）：
##    地面敌人与 BOSS 不再被松散煤/硫/沙堆卡死，穿行按密度分 3 档减速（朱砂/石灰可有效滞敌）；
## 3) 旱魃 BOSS 空间效用 AI（refs/cards/decisions/boss-ai-mobility.md#utility-spatial-reposition）：
##    按距离与高低差加权选招（禁连续复读）+ 跃上竹木高台 / 烈焰滑步 / 贴脸炽浪震退 + 战术重定位 +
##    湿破甲 0.55s 受挫硬直后跃离水洼 + 二阶段猛扑引燃竹台（绝不挖岩坝）。

const PowderPhysics := preload("res://scripts/powder_physics.gd")

const FIXED_DT := 1.0 / 60.0
const GRAVITY := 240.0
const MAX_FALL := 145.0
const STEP_UP_MAX := 4
const MAX_SUBSTEP := 0.75
const WET_FLINCH_TICKS := 33           # 0.55s 湿破甲受挫窗口
const WET_FLINCH_COOLDOWN := 180       # 3.0s 防连续泼水无限硬直锁死
const WATER_AVOID_COOLDOWN := 75       # 1.25s 旱魃主动畏水跃避冷却（保留围堵/高台泼水破甲窗口）
const WATER_LOG_COOLDOWN := 180        # 3.0s 畏水跃避 HUD 提示节流

var ent                                # CombatEntity
var cfg: Dictionary = {}
var state: String = "patrol"           # patrol / chase / telegraph / attack / recover / reposition / flinch
var state_ticks: int = 0
var cooldown_ticks: int = 0
var patrol_dir: float = -1.0
var patrol_timer: int = 90
var on_ground: bool = false
var lunge_hit_done: bool = false
var attack_pattern: int = 0            # 经典回退轮换索引
var phase2_announced: bool = false
var bob_phase: float = 0.0

# M1-α 旱魃空间效用与状态字段
var boss_smart_ai: bool = true         # 决策卡开关：false 退回旧 0-1-2 轮换
var powder_wade_enabled: bool = true   # 决策卡开关：与玩家同步启用粉末分级减速
var active_boss_move: String = "fan_fire"
var last_boss_move: String = ""
var boss_moves_since_reposition: int = 0
var reposition_dir: float = 1.0
var dash_dir: float = -1.0
var was_wet: bool = false
var wet_flinch_cd: int = 0
var water_avoid_cd: int = 0
var _water_log_cd: int = 0
var powder_speed_mult: float = 1.0
var _powder_fill: float = 0.0
var _rng_state: int = 1337

func setup(p_ent, p_cfg: Dictionary, seed_offset: int = 0) -> void:
	ent = p_ent
	cfg = p_cfg
	state = "patrol"
	state_ticks = 0
	cooldown_ticks = 18 + (seed_offset % 24)
	patrol_dir = 1.0 if (seed_offset % 2 == 0) else -1.0
	patrol_timer = 90 + (seed_offset % 60)
	on_ground = false
	lunge_hit_done = false
	attack_pattern = 0
	phase2_announced = false
	bob_phase = float(seed_offset) * 0.7
	active_boss_move = "fan_fire"
	last_boss_move = ""
	boss_moves_since_reposition = 0
	reposition_dir = patrol_dir
	dash_dir = patrol_dir
	was_wet = false
	wet_flinch_cd = 0
	water_avoid_cd = 0
	_water_log_cd = 0
	powder_speed_mult = 1.0
	_powder_fill = 0.0
	_rng_state = (seed_offset * 1103515245 + 12345) & 0x7FFFFFFF
	if ent != null:
		ent.facing = patrol_dir

func step_tick(sim: SimWorldNode, combat, player_pos: Vector2, tick: int, event_bus,
		mat_quicksilver: int, player_hit_cb: Callable, log_cb: Callable,
		player_vel: Vector2 = Vector2.ZERO, mat_water: int = -1, density_by_id: Dictionary = {}) -> void:
	if ent == null or not ent.alive or sim == null or not sim.has_world():
		return

	if cooldown_ticks > 0:
		cooldown_ticks -= 1
	if wet_flinch_cd > 0:
		wet_flinch_cd -= 1
	if water_avoid_cd > 0:
		water_avoid_cd -= 1
	if _water_log_cd > 0:
		_water_log_cd -= 1
	bob_phase += 0.08

	var move_mode: String = String(cfg.get("move_mode", "ground"))

	# 粉末密度采样（与玩家共用 PowderPhysics：地面小怪与 BOSS 涉粉分级减速，不卡死）
	if powder_wade_enabled and move_mode != "fly":
		var ec: Vector2i = ent.cell_pos()
		var psamp: Dictionary = PowderPhysics.sample_box(
			sim, ec.x, ec.y, ceili(float(ent.half_w)), ceili(float(ent.height)), density_by_id
		)
		_powder_fill = float(psamp["fill"])
		powder_speed_mult = float(psamp["speed_mult"])
	else:
		_powder_fill = 0.0
		powder_speed_mult = 1.0

	# 旱魃二阶段切换检测（≤ 50% HP）
	if ent.archetype == "drought_demon" and not phase2_announced:
		var p2_ratio: float = float(cfg.get("phase2_hp_ratio", 0.5))
		if float(ent.hp) <= float(ent.max_hp) * p2_ratio:
			phase2_announced = true
			ent.phase = 2
			var c: Vector2i = ent.cell_pos()
			sim.apply_heat_burst(c.x, c.y, 10, 400.0)
			if log_cb.is_valid():
				log_cb.call("旱魃旱威大盛！泼水可破其甲")

	# 旱魃湿破甲环境对话：首次沾水触发 0.55s 嘶鸣受挫硬直，随后若脚下有水则跃离水洼
	if ent.archetype == "drought_demon" and boss_smart_ai:
		var is_wet_now: bool = ent.has_status("wet")
		if is_wet_now and not was_wet and wet_flinch_cd <= 0 and not ent.is_stunned():
			wet_flinch_cd = WET_FLINCH_COOLDOWN
			state = "flinch"
			state_ticks = 0
			ent.telegraph_ratio = 0.0
			ent.hurt_flash_ticks = 18
			ent.vel.x = float(ent.vel.x) * 0.25
			if log_cb.is_valid():
				log_cb.call("旱魃旱甲遇水受挫！")
		was_wet = is_wet_now

	# 镇（眩晕）期间冻结 AI 行为与预警，仅结算击退与重力
	if ent.is_stunned():
		ent.telegraph_ratio = 0.0
		state = "patrol"
		state_ticks = 0
		_step_physics(sim, tick, event_bus, mat_quicksilver)
		return

	var my_center: Vector2 = ent.center_pos()
	var player_center: Vector2 = Vector2(player_pos.x, player_pos.y - 5.0)
	var to_player: Vector2 = player_center - my_center
	var dist: float = to_player.length()
	var aggro_range: float = float(cfg.get("aggro_range", 140.0))
	var attack_range: float = float(cfg.get("attack_range", 20.0))

	if dist <= aggro_range:
		ent.aggroed = true

	var spd_mult: float = float(ent.speed_multiplier()) * powder_speed_mult
	if move_mode != "fly" and _is_feet_in_mat(sim, mat_quicksilver) and not ent.has_tag("eldritch"):
		spd_mult *= 0.5

	# 旱魃主动畏水感知：脚边出现水洼或头顶有水泼落时，未沾水前即向干燥侧惊跳闪避
	if ent.archetype == "drought_demon" and boss_smart_ai and mat_water >= 0:
		if state in ["patrol", "chase", "recover", "reposition"] and on_ground and water_avoid_cd <= 0 and not ent.has_status("wet"):
			var ws: Dictionary = _sense_water_near(sim, mat_water)
			if int(ws["near"]) >= 5 or int(ws["overhead"]) >= 4:
				_launch_boss_water_avoid(sim, mat_water, to_player, log_cb)

	match state:
		"flinch":
			# 旱魃湿破甲硬直窗口（明确奖励玩家泼水/放水）
			state_ticks += 1
			ent.telegraph_ratio = 0.0
			ent.vel.x = move_toward(float(ent.vel.x), 0.0, 320.0 * FIXED_DT)
			if state_ticks >= WET_FLINCH_TICKS:
				if _is_feet_in_mat(sim, mat_water):
					_launch_boss_water_escape(sim, mat_water, to_player)
				else:
					state = "chase"
					state_ticks = 0
					cooldown_ticks = maxi(cooldown_ticks, 12)
		"patrol":
			ent.telegraph_ratio = 0.0
			if ent.aggroed and dist <= aggro_range * 1.45:
				state = "chase"
				state_ticks = 0
			else:
				_do_patrol(sim, move_mode, spd_mult, mat_water)
		"chase":
			ent.telegraph_ratio = 0.0
			if dist > aggro_range * 1.85 and not ent.has_tag("boss"):
				ent.aggroed = false
				state = "patrol"
				state_ticks = 0
			else:
				if absf(to_player.x) > 1.5:
					ent.facing = signf(to_player.x)
				# 旱魃脚下泡水且无硬直时优先主动脱困跳向最干燥一侧
				if ent.archetype == "drought_demon" and boss_smart_ai and on_ground and _is_feet_in_mat(sim, mat_water) and cooldown_ticks <= 10:
					_launch_boss_water_escape(sim, mat_water, to_player)
				else:
					var can_attack: bool = cooldown_ticks <= 0 and dist <= attack_range
					if can_attack and _needs_los():
						can_attack = _has_line_of_sight(sim, my_center, player_center)
					if can_attack:
						if ent.archetype == "drought_demon" and boss_smart_ai:
							var dir_to_p: float = signf(to_player.x) if absf(to_player.x) > 1.0 else float(ent.facing)
							var water_path: bool = mat_water >= 0 and _water_ahead(sim, dir_to_p, 38, mat_water) >= 4
							active_boss_move = _pick_boss_move(to_player, dist, int(ent.phase) >= 2, water_path)
						_enter_telegraph()
					else:
						_do_chase(sim, move_mode, to_player, dist, spd_mult, mat_water, log_cb)
		"telegraph":
			state_ticks += 1
			var total_tel: int = _current_telegraph_ticks()
			ent.telegraph_ratio = clampf(float(state_ticks) / float(maxi(total_tel, 1)), 0.0, 1.0)
			if absf(to_player.x) > 1.5:
				ent.facing = signf(to_player.x)
			ent.vel.x = move_toward(float(ent.vel.x), 0.0, 320.0 * FIXED_DT)
			if move_mode == "fly":
				ent.vel.y = move_toward(float(ent.vel.y), 0.0, 200.0 * FIXED_DT)
			if state_ticks >= total_tel:
				ent.telegraph_ratio = 0.0
				_execute_attack(sim, combat, to_player, player_pos, player_vel, tick, player_hit_cb, mat_water)
		"attack":
			state_ticks += 1
			if ent.archetype == "drought_demon" and active_boss_move == "flame_dash":
				# 烈焰滑步：高速水平冲刺并留下短命火迹；前方遇水立刻急刹避让
				if boss_smart_ai and mat_water >= 0 and (_water_ahead(sim, dash_dir, 14, mat_water) >= 3 or _is_feet_in_mat(sim, mat_water)):
					if on_ground and water_avoid_cd <= 0:
						_launch_boss_water_avoid(sim, mat_water, to_player, log_cb)
					else:
						ent.vel.x = -dash_dir * 42.0
						_finish_boss_attack()
				else:
					var dspd: float = float(cfg.get("dash_speed", 172.0)) * (1.10 if int(ent.phase) >= 2 else 1.0) * powder_speed_mult
					ent.vel.x = dash_dir * dspd
					if state_ticks % 4 == 0:
						_spawn_trail_fire(sim)
					if not lunge_hit_done and _overlaps_player(player_pos, 3.5):
						lunge_hit_done = true
						var dash_dmg: float = 22.0 if int(ent.phase) >= 2 else 18.0
						_hit_player_melee(player_pos, tick, player_hit_cb, dash_dmg, "火")
					if state_ticks >= 20 or _hard_solid_ahead(sim, dash_dir, 4):
						_finish_boss_attack()
			elif ent.archetype == "drought_demon" and (active_boss_move == "escape_leap" or active_boss_move == "avoid_water"):
				# 畏水跃避 / 跃离水洼：落地即恢复追击与反击
				var rec_cd: int = 14 if active_boss_move == "avoid_water" else 18
				if on_ground and state_ticks > 8:
					_scatter_landing_fire(sim, false)
					state = "recover"
					state_ticks = 0
					cooldown_ticks = rec_cd
				elif state_ticks >= 48:
					state = "recover"
					state_ticks = 0
					cooldown_ticks = rec_cd
			else:
				# 常规冲锋 / 旱魃跃台猛扑
				if not lunge_hit_done and _overlaps_player(player_pos, 3.5):
					lunge_hit_done = true
					if ent.archetype == "drought_demon":
						var leap_dmg: float = 26.0 if int(ent.phase) >= 2 else 22.0
						_hit_player_melee(player_pos, tick, player_hit_cb, leap_dmg, "火")
					else:
						_hit_player_melee(player_pos, tick, player_hit_cb)
				if ent.archetype == "drought_demon" and on_ground and state_ticks > 8:
					_scatter_landing_fire(sim, int(ent.phase) >= 2)
					_finish_boss_attack()
				elif state_ticks >= (52 if ent.archetype == "drought_demon" else 18):
					if ent.archetype == "drought_demon":
						_finish_boss_attack()
					else:
						state = "recover"
						state_ticks = 0
						cooldown_ticks = _current_cooldown_ticks()
		"reposition":
			# 旱魃主动战术重定位：大步换位或小跳拉角度，遇水主动折返
			state_ticks += 1
			var rspd: float = float(cfg.get("chase_speed", 58.0)) * 1.45 * spd_mult
			if _hard_solid_ahead(sim, reposition_dir, 6) or (ent.archetype == "drought_demon" and mat_water >= 0 and _water_ahead(sim, reposition_dir, 16, mat_water) >= 3):
				reposition_dir = -reposition_dir
			ent.facing = signf(to_player.x) if absf(to_player.x) > 2.0 else reposition_dir
			ent.vel.x = move_toward(float(ent.vel.x), reposition_dir * rspd, 360.0 * FIXED_DT)
			if state_ticks >= 20:
				state = "recover"
				state_ticks = 0
				cooldown_ticks = maxi(_current_cooldown_ticks() - 16, 22)
		"recover":
			ent.telegraph_ratio = 0.0
			state_ticks += 1
			ent.vel.x = move_toward(float(ent.vel.x), 0.0, 260.0 * FIXED_DT)
			if move_mode == "fly":
				ent.vel.y = sin(bob_phase) * 10.0
			var rec_dur: int = 20 if ent.archetype == "drought_demon" else 16
			if state_ticks >= rec_dur:
				state = "chase" if ent.aggroed else "patrol"
				state_ticks = 0

	_step_physics(sim, tick, event_bus, mat_quicksilver)

# ------------------------------------------------------------------ 旱魃空间效用选招与畏水避让（M1-α）

func _pick_boss_move(to_player: Vector2, dist: float, p2: bool, water_in_path: bool = false) -> String:
	# 候选招式效用打分（只读玩家当前位置，不读输入；上一招权重 ×0.20 禁复读）
	var dy: float = to_player.y        # < 0 表示玩家在高处/竹木台
	var weights: Dictionary = {
		"fan_fire": 1.2,
		"platform_leap": 1.1,
		"flame_dash": 0.9,
		"close_nova": 0.3,
	}
	if p2:
		weights["scorch_wave"] = 1.15

	# 1) 玩家在高台/空中（比旱魃高出 >22 格）：强反制跃台与对空扇弹，不给站台白嫖
	if dy < -22.0:
		weights["platform_leap"] = 4.6
		weights["fan_fire"] = 2.6
		weights["flame_dash"] = 0.25
		weights["close_nova"] = 0.2
		if p2:
			weights["scorch_wave"] = 0.4
	# 2) 玩家贴脸（<44 格）：强反制贴脸炽浪震退+后跃
	elif dist < 44.0:
		weights["close_nova"] = 4.2
		weights["platform_leap"] = 1.2
		weights["fan_fire"] = 0.7
		weights["flame_dash"] = 0.2
		if p2:
			weights["scorch_wave"] = 1.8
	# 3) 玩家中远距（>92 格且高度差不大）：强反制烈焰滑步拉近与扇形火弹
	elif dist > 92.0 and absf(dy) < 34.0:
		weights["flame_dash"] = 3.8
		weights["fan_fire"] = 2.8
		weights["platform_leap"] = 1.6
		weights["close_nova"] = 0.1
		if p2:
			weights["scorch_wave"] = 2.4
	# 4) 中距对峙（44..92 格）：全面博弈
	else:
		weights["platform_leap"] = 2.4
		weights["fan_fire"] = 2.3
		weights["flame_dash"] = 1.6
		weights["close_nova"] = 0.6
		if p2:
			weights["scorch_wave"] = 2.2

	# 路径上有水洼时：禁滑步趟水，转而远程压制或高跃飞越
	if water_in_path:
		weights["flame_dash"] = float(weights["flame_dash"]) * 0.10
		weights["fan_fire"] = float(weights["fan_fire"]) * 1.60
		weights["platform_leap"] = float(weights["platform_leap"]) * 1.35
		if p2 and weights.has("scorch_wave"):
			weights["scorch_wave"] = float(weights["scorch_wave"]) * 1.50

	if not last_boss_move.is_empty() and weights.has(last_boss_move):
		weights[last_boss_move] = float(weights[last_boss_move]) * 0.20

	var total_w: float = 0.0
	for k in weights.keys():
		total_w += maxf(float(weights[k]), 0.0)
	var pick_val: float = _rand01() * total_w
	var accum: float = 0.0
	for k in weights.keys():
		accum += maxf(float(weights[k]), 0.0)
		if pick_val <= accum:
			return String(k)
	return "fan_fire"

func _launch_boss_water_avoid(sim: SimWorldNode, mat_water: int, to_player: Vector2, log_cb: Callable,
		forced_dir: float = 0.0) -> void:
	# 旱魃主动畏水跃避：未沾水前抢先跃向干燥一侧（或跨过脚前浅水洼）
	var avoid_dir: float = forced_dir if absf(forced_dir) > 0.5 else _driest_escape_dir(sim, mat_water, to_player)
	active_boss_move = "avoid_water"
	water_avoid_cd = WATER_AVOID_COOLDOWN
	ent.facing = avoid_dir
	ent.vel.x = avoid_dir * 124.0
	ent.vel.y = -126.0
	on_ground = false
	lunge_hit_done = true
	state = "attack"
	state_ticks = 0
	if _water_log_cd <= 0 and log_cb.is_valid():
		_water_log_cd = WATER_LOG_COOLDOWN
		log_cb.call("旱魃畏水跃避！")

func _launch_boss_water_escape(sim: SimWorldNode, mat_water: int, to_player: Vector2) -> void:
	# 沾水硬直后跳离水洼：优先朝最干燥一侧高跳脱困
	var escape_dir: float = _driest_escape_dir(sim, mat_water, to_player)
	active_boss_move = "escape_leap"
	water_avoid_cd = WATER_AVOID_COOLDOWN
	ent.facing = escape_dir
	ent.vel.x = escape_dir * 118.0
	ent.vel.y = -126.0
	on_ground = false
	lunge_hit_done = true
	state = "attack"
	state_ticks = 0

func _driest_escape_dir(sim: SimWorldNode, mat_water: int, to_player: Vector2) -> float:
	var c: Vector2i = ent.cell_pos()
	var hw: int = ceili(float(ent.half_w))
	var left_blocked: bool = _hard_solid_ahead(sim, -1.0, 14)
	var right_blocked: bool = _hard_solid_ahead(sim, 1.0, 14)
	if left_blocked and not right_blocked:
		return 1.0
	if right_blocked and not left_blocked:
		return -1.0
	var left_w: int = _count_mat_rect(sim, c.x - hw - 36, c.y - 12, c.x - hw - 1, c.y + 3, mat_water)
	var right_w: int = _count_mat_rect(sim, c.x + hw + 1, c.y - 12, c.x + hw + 36, c.y + 3, mat_water)
	if left_w != right_w:
		return -1.0 if left_w < right_w else 1.0
	# 两侧同样干燥时，背离脚边水源/玩家泼水方向跳开
	var ws: Dictionary = _sense_water_near(sim, mat_water)
	if int(ws["left"]) != int(ws["right"]):
		return 1.0 if int(ws["left"]) > int(ws["right"]) else -1.0
	if absf(to_player.x) > 4.0:
		return -signf(to_player.x)
	return 1.0

func _count_mat_rect(sim: SimWorldNode, x0: int, y0: int, x1: int, y1: int, mat_id: int) -> int:
	if mat_id < 0 or sim == null or not sim.has_world():
		return 0
	var w: int = sim.get_world_width()
	var h: int = sim.get_world_height()
	var ax: int = clampi(x0, 0, w - 1)
	var bx: int = clampi(x1, 0, w - 1)
	var ay: int = clampi(y0, 0, h - 1)
	var by: int = clampi(y1, 0, h - 1)
	var cnt := 0
	for gy in range(ay, by + 1):
		for gx in range(ax, bx + 1):
			if sim.get_cell(gx, gy) == mat_id:
				cnt += 1
	return cnt

func _water_ahead(sim: SimWorldNode, dir_x: float, look_dist: int, mat_water: int) -> int:
	if mat_water < 0:
		return 0
	var c: Vector2i = ent.cell_pos()
	var hw: int = ceili(float(ent.half_w))
	if dir_x >= 0.0:
		return _count_mat_rect(sim, c.x + hw + 1, c.y - 6, c.x + hw + look_dist, c.y + 3, mat_water)
	return _count_mat_rect(sim, c.x - hw - look_dist, c.y - 6, c.x - hw - 1, c.y + 3, mat_water)

func _sense_water_near(sim: SimWorldNode, mat_water: int) -> Dictionary:
	var c: Vector2i = ent.cell_pos()
	var hw: int = ceili(float(ent.half_w))
	var hh: int = ceili(float(ent.height))
	var left_c: int = _count_mat_rect(sim, c.x - hw - 14, c.y - 10, c.x - 1, c.y + 3, mat_water)
	var right_c: int = _count_mat_rect(sim, c.x + 1, c.y - 10, c.x + hw + 14, c.y + 3, mat_water)
	var over_c: int = _count_mat_rect(sim, c.x - hw - 4, c.y - hh - 26, c.x + hw + 4, c.y - hh, mat_water)
	return {
		"near": left_c + right_c,
		"left": left_c,
		"right": right_c,
		"overhead": over_c,
	}

func _finish_boss_attack() -> void:
	last_boss_move = active_boss_move
	boss_moves_since_reposition += 1
	if boss_smart_ai and boss_moves_since_reposition >= 2:
		boss_moves_since_reposition = 0
		reposition_dir = -float(ent.facing) if (_rand01() < 0.55) else float(ent.facing)
		if on_ground:
			ent.vel.y = -52.0
			on_ground = false
		state = "reposition"
		state_ticks = 0
	else:
		state = "recover"
		state_ticks = 0
		cooldown_ticks = _current_cooldown_ticks()

func _rand01() -> float:
	_rng_state = (_rng_state * 1103515245 + 12345) & 0x7FFFFFFF
	return float(_rng_state & 0xFFFF) / 65536.0

# ------------------------------------------------------------------ 行为辅助

func _needs_los() -> bool:
	return ent.archetype in ["gas_wisp", "painted_skin"]

func _current_telegraph_ticks() -> int:
	var base: int = maxi(int(cfg.get("telegraph_ticks", 20)), 8)
	if ent.archetype == "drought_demon":
		if boss_smart_ai:
			match active_boss_move:
				"close_nova":
					return 19
				"flame_dash":
					return 17 if int(ent.phase) >= 2 else 21
				"platform_leap":
					return 18 if int(ent.phase) >= 2 else 22
				"scorch_wave":
					return 29
				_:
					return 20 if int(ent.phase) >= 2 else 25
		if int(ent.phase) >= 2:
			return 32 if attack_pattern == 2 else maxi(base - 6, 14)
	return base

func _current_cooldown_ticks() -> int:
	var base: int = maxi(int(cfg.get("attack_cooldown_ticks", 60)), 24)
	if ent.archetype == "drought_demon" and int(ent.phase) >= 2:
		return roundi(float(base) * 0.82)
	return base

func _enter_telegraph() -> void:
	state = "telegraph"
	state_ticks = 0
	ent.telegraph_ratio = 0.05
	match ent.archetype:
		"painted_skin":
			ent.telegraph_color = Color(0.72, 0.42, 1.0)
		"drought_demon":
			if boss_smart_ai:
				match active_boss_move:
					"close_nova":
						ent.telegraph_color = Color(1.0, 0.86, 0.24)
					"flame_dash":
						ent.telegraph_color = Color(1.0, 0.48, 0.14)
					"platform_leap":
						ent.telegraph_color = Color(0.98, 0.22, 0.20)
					"scorch_wave":
						ent.telegraph_color = Color(1.0, 0.72, 0.18)
					_:
						ent.telegraph_color = Color(1.0, 0.38, 0.14)
			else:
				ent.telegraph_color = Color(1.0, 0.34, 0.14) if attack_pattern != 2 else Color(1.0, 0.72, 0.18)
		"gas_wisp":
			ent.telegraph_color = Color(1.0, 0.68, 0.18)
		"earth_worm":
			ent.telegraph_color = Color(0.96, 0.76, 0.32)
		_:
			ent.telegraph_color = Color(0.84, 0.92, 1.0)

func _do_patrol(sim: SimWorldNode, move_mode: String, spd_mult: float, mat_water: int = -1) -> void:
	var pspd: float = float(cfg.get("patrol_speed", 20.0)) * spd_mult
	patrol_timer -= 1
	if patrol_timer <= 0:
		patrol_dir = -patrol_dir
		patrol_timer = 90 + (absi(floori(float(ent.pos.x))) % 60)
	ent.facing = patrol_dir
	if move_mode == "fly":
		ent.vel.x = move_toward(float(ent.vel.x), patrol_dir * pspd, 140.0 * FIXED_DT)
		ent.vel.y = sin(bob_phase) * 14.0
		if _hard_solid_ahead(sim, patrol_dir, 6):
			patrol_dir = -patrol_dir
	else:
		var fear_water: bool = (ent.archetype == "drought_demon" and boss_smart_ai
				and mat_water >= 0 and _water_ahead(sim, patrol_dir, 16, mat_water) >= 3)
		if fear_water or _hard_solid_ahead(sim, patrol_dir, 4) or (on_ground and not _floor_ahead(sim, patrol_dir)):
			patrol_dir = -patrol_dir
			ent.facing = patrol_dir
		ent.vel.x = move_toward(float(ent.vel.x), patrol_dir * pspd, 240.0 * FIXED_DT)

func _do_chase(sim: SimWorldNode, move_mode: String, to_player: Vector2, dist: float, spd_mult: float,
		mat_water: int = -1, log_cb: Callable = Callable()) -> void:
	var cspd: float = float(cfg.get("chase_speed", 40.0)) * spd_mult
	if move_mode == "fly":
		var pref: float = float(cfg.get("preferred_range", 56.0))
		var desired := Vector2.ZERO
		if dist > pref + 10.0:
			desired = to_player.normalized() * cspd
		elif dist < pref - 14.0:
			desired = -to_player.normalized() * (cspd * 0.75)
		else:
			desired = Vector2(signf(to_player.x) * cspd * 0.2, sin(bob_phase) * 18.0)
		desired.y += clampf((to_player.y - 12.0) * 0.6, -24.0, 24.0)
		ent.vel = (ent.vel as Vector2).move_toward(desired, 180.0 * FIXED_DT)
		return

	var dir_x: float = signf(to_player.x) if absf(to_player.x) > 2.0 else float(ent.facing)
	var target_vx: float = dir_x * cspd
	if ent.archetype == "painted_skin":
		var pref: float = float(cfg.get("preferred_range", 74.0))
		if dist < pref - 26.0:
			target_vx = -dir_x * (cspd * 0.75)
		elif dist <= pref + 18.0:
			target_vx = 0.0

	# 旱魃追击遇前方水洼：优先高跃跨洼/向干侧跳开，冷却中则急刹在干地边缘绝不傻站踩水
	if ent.archetype == "drought_demon" and boss_smart_ai and mat_water >= 0 and absf(target_vx) > 5.0:
		var move_dir: float = signf(target_vx)
		if _water_ahead(sim, move_dir, 22, mat_water) >= 3:
			if on_ground and water_avoid_cd <= 0:
				var c: Vector2i = ent.cell_pos()
				var hw: int = ceili(float(ent.half_w))
				var beyond_x0: int = c.x + hw + 28 if move_dir > 0.0 else c.x - hw - 52
				var beyond_x1: int = c.x + hw + 52 if move_dir > 0.0 else c.x - hw - 28
				var beyond_dry: bool = _count_mat_rect(sim, beyond_x0, c.y - 6, beyond_x1, c.y + 3, mat_water) < 3
				if beyond_dry and not _hard_solid_ahead(sim, move_dir, 24):
					_launch_boss_water_avoid(sim, mat_water, to_player, log_cb, move_dir)
				else:
					_launch_boss_water_avoid(sim, mat_water, to_player, log_cb)
				return
			ent.vel.x = move_toward(float(ent.vel.x), 0.0, 420.0 * FIXED_DT)
			return

	ent.vel.x = move_toward(float(ent.vel.x), target_vx, 300.0 * FIXED_DT)
	# 追击遇低坎或玩家高处时起跳跨越（旱魃可一跃登上 8 行竹木台）
	if on_ground and absf(target_vx) > 5.0:
		if _hard_solid_ahead(sim, signf(target_vx), 6):
			ent.vel.y = -112.0 if ent.archetype == "drought_demon" else -68.0
			on_ground = false
		elif ent.archetype == "drought_demon" and to_player.y < -28.0 and absf(to_player.x) < 88.0:
			var need_rise: float = clampf(-to_player.y + 14.0, 32.0, 88.0)
			ent.vel.y = -sqrt(2.0 * GRAVITY * need_rise)
			on_ground = false

func _execute_attack(sim: SimWorldNode, combat, to_player: Vector2, player_pos: Vector2,
		player_vel: Vector2, tick: int, player_hit_cb: Callable, mat_water: int = -1) -> void:
	var dir: Vector2 = to_player.normalized() if to_player.length() > 0.1 else Vector2(float(ent.facing), 0.0)
	match ent.archetype:
		"coal_ghost":
			if to_player.length() <= float(cfg.get("attack_range", 14.0)) + 8.0:
				_hit_player_melee(player_pos, tick, player_hit_cb)
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()
		"earth_worm":
			var lspd: float = float(cfg.get("lunge_speed", 108.0)) * powder_speed_mult
			ent.vel.x = (signf(to_player.x) if absf(to_player.x) > 1.0 else float(ent.facing)) * lspd
			ent.vel.y = -34.0
			on_ground = false
			lunge_hit_done = false
			state = "attack"
			state_ticks = 0
		"gas_wisp":
			_fire_projectile(combat, dir, 1, 0.0, 0.0)
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()
		"painted_skin":
			_fire_projectile(combat, dir, 1, 0.0, 0.0)
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()
		"drought_demon":
			_execute_boss_attack(sim, combat, to_player, player_pos, player_vel, dir, tick, player_hit_cb, mat_water)
		_:
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()

func _execute_boss_attack(sim: SimWorldNode, combat, to_player: Vector2, player_pos: Vector2,
		player_vel: Vector2, dir: Vector2, tick: int, player_hit_cb: Callable, mat_water: int = -1) -> void:
	var p2: bool = int(ent.phase) >= 2
	var move_id: String = active_boss_move
	if not boss_smart_ai:
		var pat: int = attack_pattern
		attack_pattern = (attack_pattern + 1) % (3 if p2 else 2)
		move_id = "fan_fire" if pat == 0 else ("platform_leap" if pat == 1 else "scorch_wave")
		active_boss_move = move_id

	match move_id:
		"fan_fire":
			# 旱火扇弹：16 伤（二阶段 20 伤），带 0.18s 轻度速度提前量
			var lead_target: Vector2 = to_player + player_vel * 0.18
			var aim_dir: Vector2 = lead_target.normalized() if lead_target.length() > 1.0 else dir
			var count := 5 if p2 else 3
			var spread := 44.0 if p2 else 28.0
			var bonus_dmg := 4.0 if p2 else 0.0
			_fire_projectile(combat, aim_dir, count, spread, bonus_dmg)
			_finish_boss_attack()
		"platform_leap":
			# 腾跃扑台 / 截击跳扑：按物理抛物线计算起跳初速，确保能真正跃上 8 行竹木台追击
			var lspd: float = float(cfg.get("lunge_speed", 148.0)) * (1.10 if p2 else 1.0) * powder_speed_mult
			var sx: float = signf(to_player.x) if absf(to_player.x) > 1.0 else float(ent.facing)
			var climb_need: float = maxf(-to_player.y, 0.0)
			var target_rise: float = clampf(climb_need + 18.0, 26.0, 92.0)
			var jump_vy: float = -sqrt(2.0 * GRAVITY * target_rise)
			var horiz_scale: float = clampf(absf(to_player.x) / 92.0, 0.45, 1.15)
			ent.vel.x = sx * lspd * horiz_scale
			ent.vel.y = jump_vy
			on_ground = false
			lunge_hit_done = false
			state = "attack"
			state_ticks = 0
		"flame_dash":
			# 烈焰滑步突进：高速贴地拉近距离并留火痕（遇水时在 attack 状态急刹跃避）
			dash_dir = signf(to_player.x) if absf(to_player.x) > 1.0 else float(ent.facing)
			ent.facing = dash_dir
			lunge_hit_done = false
			state = "attack"
			state_ticks = 0
		"close_nova":
			# 贴脸炽浪震退（20/24 伤）+ 向干燥侧后跃拉开空间
			var nova_r: float = 38.0
			if to_player.length() <= nova_r and player_hit_cb.is_valid():
				var push_dir: Vector2 = to_player.normalized() if to_player.length() > 0.1 else Vector2(float(ent.facing), -0.3)
				player_hit_cb.call({
					"pos": ent.center_pos(),
					"dir": push_dir * 1.55,
					"damage": 24.0 if p2 else 20.0,
					"damage_type": "火",
					"lantern_damage": 0.0,
					"source_id": ent.display_name,
					"tick": tick,
				})
			if combat != null and combat.overlay != null:
				combat.overlay.add_ring(ent.cell_pos(), nova_r * 0.85, Color(1.0, 0.56, 0.18, 0.92))
			_scatter_landing_fire(sim, false)
			var back_dir: float = -signf(to_player.x) if absf(to_player.x) > 1.0 else -float(ent.facing)
			if _hard_solid_ahead(sim, back_dir, 14) or (mat_water >= 0 and _water_ahead(sim, back_dir, 18, mat_water) >= 3):
				back_dir = -back_dir
			ent.vel.x = back_dir * 102.0 * powder_speed_mult
			ent.vel.y = -78.0
			on_ground = false
			_finish_boss_attack()
		_:
			# P2 专属：焦土灼浪 —— 左右贴地滚火波（24 伤）
			if combat != null:
				var origin: Vector2 = Vector2(float(ent.pos.x), float(ent.pos.y) - 4.0)
				for sx in [-1.0, 1.0]:
					var act := {
						"op": "spawn_projectile",
						"spell": "boss_scorch_wave",
						"count": 1,
						"speed": 8.6,
						"gravity": 0.08,
						"damage": 24.0,
						"damage_type": "火",
						"element": "火",
						"ttl_ticks": 115,
						"payloads": [{"op": "ignite", "duration": 3.0}],
					}
					combat.execute_actions([act], origin, Vector2(sx, -0.10), ent.entity_id, "enemy")
			_scatter_landing_fire(sim, p2)
			_finish_boss_attack()

func _fire_projectile(combat, dir: Vector2, count: int, spread_deg: float, bonus_dmg: float) -> void:
	if combat == null:
		return
	var pcfg: Dictionary = cfg.get("projectile", {}) if cfg.get("projectile") is Dictionary else {}
	var payloads: Array = []
	if bool(pcfg.get("ignite", false)):
		payloads.append({"op": "ignite", "duration": 3.0})
	var act := {
		"op": "spawn_projectile",
		"spell": "enemy_" + ent.archetype,
		"count": count,
		"spread_deg": spread_deg,
		"speed": float(pcfg.get("speed", 7.0)),
		"gravity": float(pcfg.get("gravity", 0.0)),
		"damage": float(pcfg.get("damage", cfg.get("damage", 6.0))) + bonus_dmg,
		"damage_type": String(pcfg.get("damage_type", cfg.get("damage_type", "火"))),
		"lantern_damage": float(pcfg.get("lantern_damage", cfg.get("lantern_damage", 0.0))),
		"element": String(pcfg.get("element", "火")),
		"ttl_ticks": int(pcfg.get("ttl_ticks", 96)),
		"payloads": payloads,
	}
	var origin: Vector2 = ent.center_pos() + dir * (float(ent.half_w) + 2.0)
	combat.execute_actions([act], origin, dir, ent.entity_id, "enemy")

func _hit_player_melee(player_pos: Vector2, tick: int, player_hit_cb: Callable,
		dmg_override: float = -1.0, dtype_override: String = "") -> void:
	if not player_hit_cb.is_valid():
		return
	var epos: Vector2 = ent.pos
	var dir: Vector2 = (player_pos - epos).normalized() if player_pos.distance_to(epos) > 0.1 else Vector2(float(ent.facing), -0.2)
	player_hit_cb.call({
		"pos": ent.center_pos(),
		"dir": dir,
		"damage": dmg_override if dmg_override > 0.0 else float(cfg.get("damage", 6.0)),
		"damage_type": dtype_override if not dtype_override.is_empty() else String(cfg.get("damage_type", "物理")),
		"lantern_damage": float(cfg.get("lantern_damage", 0.0)),
		"source_id": ent.display_name,
		"tick": tick,
	})

func _spawn_trail_fire(sim: SimWorldNode) -> void:
	var mat_fire: int = sim.material_id("fire")
	if mat_fire < 0:
		return
	var c: Vector2i = ent.cell_pos()
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	var gx := clampi(c.x - roundi(dash_dir * 4.0), 1, w - 2)
	var gy := clampi(c.y - 1, 1, h - 2)
	if sim.get_cell(gx, gy) == 0:
		sim.set_cell(gx, gy, mat_fire)
	sim.apply_heat_burst(gx, gy, 4, 380.0)

## P2 轻切片 sandbox-terrain-breaker：只用 apply_heat_burst 点燃接触的竹木台，绝不 dig 岩坝与外墙。
func _scatter_landing_fire(sim: SimWorldNode, ignite_bamboo_wide: bool = false) -> void:
	var mat_fire: int = sim.material_id("fire")
	if mat_fire < 0:
		return
	var c: Vector2i = ent.cell_pos()
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dx in range(-8, 9, 2):
		var gx := c.x + dx
		var gy := c.y - 1
		if gx >= 1 and gx < w - 1 and gy >= 1 and gy < h - 1 and sim.get_cell(gx, gy) == 0:
			sim.set_cell(gx, gy, mat_fire)
	var heat_r: int = 10 if ignite_bamboo_wide else 7
	var heat_t: float = 450.0 if ignite_bamboo_wide else 400.0
	sim.apply_heat_burst(c.x, c.y, heat_r, heat_t)

# ------------------------------------------------------------------ 像素沙盒物理（含粉末软穿行）

func _step_physics(sim: SimWorldNode, tick: int, event_bus, mat_quicksilver: int) -> void:
	var move_mode: String = String(cfg.get("move_mode", "ground"))
	if move_mode != "fly":
		ent.vel.y = minf(float(ent.vel.y) + GRAVITY * FIXED_DT, MAX_FALL)

	# 水平子步（优先迈上 1–3 格斜坡；更高松散粉堆可减速涉过；水银界仍硬阻挡 eldritch）
	var dx: float = float(ent.vel.x) * FIXED_DT
	if absf(dx) > 0.0001:
		if not _move_horizontal(sim, dx, tick, event_bus, mat_quicksilver):
			ent.vel.x = 0.0
			if state == "patrol":
				patrol_dir = -patrol_dir
				ent.facing = patrol_dir

	# 垂直子步
	var dy: float = float(ent.vel.y) * FIXED_DT
	on_ground = false
	if absf(dy) > 0.0001:
		if not _move_vertical(sim, dy, tick, event_bus, mat_quicksilver):
			if float(ent.vel.y) > 0.0:
				on_ground = true
			ent.vel.y = 0.0
	if move_mode != "fly" and not on_ground and float(ent.vel.y) >= 0.0:
		var ec: Vector2i = ent.cell_pos()
		var hw: int = ceili(float(ent.half_w))
		if _hard_box_blocked(sim, (ent.pos as Vector2) + Vector2(0.0, 1.0)):
			on_ground = true
		elif PowderPhysics.has_surface_below(sim, ec.x, ec.y, hw, true):
			on_ground = true

func _move_horizontal(sim: SimWorldNode, total_dx: float, tick: int, event_bus, mat_quicksilver: int) -> bool:
	var steps := maxi(ceili(absf(total_dx) / MAX_SUBSTEP), 1)
	var sub_x := total_dx / float(steps)
	var hw: int = ceili(float(ent.half_w))
	var hh: int = ceili(float(ent.height))
	for _i in range(steps):
		var target: Vector2 = (ent.pos as Vector2) + Vector2(sub_x, 0.0)
		if ent.is_blocked_by_quicksilver(sim, target, tick, event_bus, mat_quicksilver):
			return false
		if not _box_blocked(sim, target):
			ent.pos = target
			continue
		var stepped := false
		for lift in range(1, STEP_UP_MAX + 1):
			var lifted: Vector2 = target + Vector2(0.0, -float(lift))
			if not ent.is_blocked_by_quicksilver(sim, lifted, tick, event_bus, mat_quicksilver) and not _box_blocked(sim, lifted):
				ent.pos = lifted
				stepped = true
				break
		if stepped:
			continue
		# 粉末涉过：允许穿过空中落尘/薄粉，但禁止从侧面钻入厚沉降土堆底部；若被落尘裹住则自动上浮回表层
		if powder_wade_enabled and not _hard_box_blocked(sim, target):
			var tcx: int = floori(target.x)
			var tcy: int = floori(target.y)
			if _powder_fill < 0.25 and PowderPhysics.is_settled_mound_wall(sim, tcx, tcy, hw, hh):
				return false
			if _powder_fill >= 0.25:
				var buoy: Vector2 = target + Vector2(0.0, -1.0)
				if not _hard_box_blocked(sim, buoy) and not ent.is_blocked_by_quicksilver(sim, buoy, tick, event_bus, mat_quicksilver):
					ent.pos = buoy
					continue
			ent.pos = target
			continue
		return false
	return true

func _move_vertical(sim: SimWorldNode, total_dy: float, tick: int, event_bus, mat_quicksilver: int) -> bool:
	var steps := maxi(ceili(absf(total_dy) / MAX_SUBSTEP), 1)
	var sub_y := total_dy / float(steps)
	var hw: int = ceili(float(ent.half_w))
	for _i in range(steps):
		var target: Vector2 = (ent.pos as Vector2) + Vector2(0.0, sub_y)
		if ent.is_blocked_by_quicksilver(sim, target, tick, event_bus, mat_quicksilver):
			return false
		if powder_wade_enabled:
			if _hard_box_blocked(sim, target):
				return false
			if sub_y < 0.0:
				ent.pos = target
				continue
			# 向下落：脚底触及岩石或沉降粉末行立刻稳停，怪物绝不能沉到土堆下面
			var cur_cy: int = floori(float(ent.pos.y))
			var tgt_cx: int = floori(target.x)
			var tgt_cy: int = floori(target.y)
			if tgt_cy > cur_cy and PowderPhysics.has_solid_at_row(sim, tgt_cx, tgt_cy, hw):
				return false
			ent.pos = target
			continue
		if not _box_blocked(sim, target):
			ent.pos = target
			continue
		return false
	return true

func _box_blocked(sim: SimWorldNode, p: Vector2) -> bool:
	var cx := floori(p.x)
	var cy := floori(p.y)
	var hw := ceili(float(ent.half_w))
	var hh := ceili(float(ent.height))
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for gy in range(cy - hh + 1, cy + 1):
		if gy < 0 or gy >= h:
			return true
		for gx in range(cx - hw, cx + hw + 1):
			if gx < 0 or gx >= w:
				return true
			if sim.is_solid(gx, gy):
				return true
	return false

## 仅静态固体（SIM_STATE_STATIC：岩/竹木）或越界，用于松散粉末软穿行。
func _hard_box_blocked(sim: SimWorldNode, p: Vector2) -> bool:
	var cx := floori(p.x)
	var cy := floori(p.y)
	var hw := ceili(float(ent.half_w))
	var hh := ceili(float(ent.height))
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for gy in range(cy - hh + 1, cy + 1):
		if gy < 0 or gy >= h:
			return true
		for gx in range(cx - hw, cx + hw + 1):
			if gx < 0 or gx >= w:
				return true
			var m: int = sim.get_cell(gx, gy)
			if m > 0 and sim.get_material_state(m) == PowderPhysics.STATE_STATIC:
				return true
	return false

func _hard_solid_ahead(sim: SimWorldNode, dir_x: float, look_dist: int) -> bool:
	var sx := 1 if dir_x >= 0.0 else -1
	var cx := floori(float(ent.pos.x)) + sx * (ceili(float(ent.half_w)) + look_dist)
	var cy := floori(float(ent.pos.y)) - 4
	if cx < 1 or cx >= sim.get_world_width() - 1 or cy < 1 or cy >= sim.get_world_height() - 1:
		return true
	var m: int = sim.get_cell(cx, cy)
	return m > 0 and sim.get_material_state(m) == PowderPhysics.STATE_STATIC

func _floor_ahead(sim: SimWorldNode, dir_x: float) -> bool:
	var sx := 1 if dir_x >= 0.0 else -1
	var cx := floori(float(ent.pos.x)) + sx * (ceili(float(ent.half_w)) + 3)
	var cy := floori(float(ent.pos.y))
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	if cx < 1 or cx >= w - 1:
		return false
	for dy in range(1, 7):
		if cy + dy < h and sim.is_solid(cx, cy + dy):
			return true
	return false

func _is_feet_in_mat(sim: SimWorldNode, mat_id: int) -> bool:
	if mat_id < 0:
		return false
	var c: Vector2i = ent.cell_pos()
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dx in [-2, 0, 2]:
		var gx := clampi(c.x + dx, 0, w - 1)
		var gy := clampi(c.y - 1, 0, h - 1)
		if sim.get_cell(gx, gy) == mat_id:
			return true
	return false

func _overlaps_player(player_pos: Vector2, pad: float = 0.0) -> bool:
	return (
		absf(float(ent.pos.x) - player_pos.x) <= float(ent.half_w) + 2.5 + pad
		and float(ent.pos.y) >= player_pos.y - 10.0 - pad
		and float(ent.pos.y) - float(ent.height) <= player_pos.y + pad
	)

func _has_line_of_sight(sim: SimWorldNode, a: Vector2, b: Vector2) -> bool:
	var diff := b - a
	var dist := diff.length()
	var steps := maxi(ceili(dist / 3.0), 1)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for i in range(1, steps):
		var p := a.lerp(b, float(i) / float(steps))
		var gx := floori(p.x)
		var gy := floori(p.y)
		if gx < 0 or gy < 0 or gx >= w or gy >= h:
			return false
		var m: int = sim.get_cell(gx, gy)
		if m > 0 and sim.get_material_state(m) == PowderPhysics.STATE_STATIC:
			return false
	return true
