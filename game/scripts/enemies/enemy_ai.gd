extends RefCounted
## M1-06 单体敌人 AI 控制器：
## 驱动矿井一层 5 种敌人（矿鬼 / 土蝼 / 硫烟鬼火 / 画皮 / 旱魃 BOSS）的状态机、
## 像素沙盒物理（重力 + 1–3 格迈步 + 水银界硬阻挡）、可读前摇预警与攻击结算。

const FIXED_DT := 1.0 / 60.0
const GRAVITY := 240.0
const MAX_FALL := 145.0
const STEP_UP_MAX := 3
const MAX_SUBSTEP := 0.75

var ent                                # CombatEntity
var cfg: Dictionary = {}
var state: String = "patrol"           # patrol / chase / telegraph / attack / recover
var state_ticks: int = 0
var cooldown_ticks: int = 0
var patrol_dir: float = -1.0
var patrol_timer: int = 90
var on_ground: bool = false
var lunge_hit_done: bool = false
var attack_pattern: int = 0            # 旱魃招式轮换索引
var phase2_announced: bool = false
var bob_phase: float = 0.0

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
	if ent != null:
		ent.facing = patrol_dir

func step_tick(sim: SimWorldNode, combat, player_pos: Vector2, tick: int, event_bus,
		mat_quicksilver: int, player_hit_cb: Callable, log_cb: Callable) -> void:
	if ent == null or not ent.alive or sim == null or not sim.has_world():
		return

	if cooldown_ticks > 0:
		cooldown_ticks -= 1
	bob_phase += 0.08

	# 旱魃二阶段切换检测（≤ 50% HP）
	if ent.archetype == "drought_demon" and not phase2_announced:
		var p2_ratio: float = float(cfg.get("phase2_hp_ratio", 0.5))
		if ent.hp <= ent.max_hp * p2_ratio:
			phase2_announced = true
			ent.phase = 2
			var c: Vector2i = ent.cell_pos()
			sim.apply_heat_burst(c.x, c.y, 10, 400.0)
			if log_cb.is_valid():
				log_cb.call("旱魃旱威大盛！泼水可破其甲")

	# 镇（眩晕）期间冻结 AI 行为与预警，仅结算击退与重力
	if ent.is_stunned():
		ent.telegraph_ratio = 0.0
		state = "patrol"
		state_ticks = 0
		_step_physics(sim, tick, event_bus, mat_quicksilver)
		return

	var move_mode: String = String(cfg.get("move_mode", "ground"))
	var my_center: Vector2 = ent.center_pos()
	var player_center: Vector2 = Vector2(player_pos.x, player_pos.y - 5.0)
	var to_player: Vector2 = player_center - my_center
	var dist: float = to_player.length()
	var aggro_range: float = float(cfg.get("aggro_range", 140.0))
	var attack_range: float = float(cfg.get("attack_range", 20.0))

	if dist <= aggro_range:
		ent.aggroed = true

	var spd_mult: float = ent.speed_multiplier()
	if move_mode != "fly" and _is_feet_in_quicksilver(sim, mat_quicksilver) and not ent.has_tag("eldritch"):
		spd_mult *= 0.5

	match state:
		"patrol":
			ent.telegraph_ratio = 0.0
			if ent.aggroed and dist <= aggro_range * 1.45:
				state = "chase"
				state_ticks = 0
			else:
				_do_patrol(sim, move_mode, spd_mult)
		"chase":
			ent.telegraph_ratio = 0.0
			if dist > aggro_range * 1.85 and not ent.has_tag("boss"):
				ent.aggroed = false
				state = "patrol"
				state_ticks = 0
			else:
				if absf(to_player.x) > 1.5:
					ent.facing = signf(to_player.x)
				var can_attack: bool = cooldown_ticks <= 0 and dist <= attack_range
				if can_attack and _needs_los():
					can_attack = _has_line_of_sight(sim, my_center, player_center)
				if can_attack:
					_enter_telegraph()
				else:
					_do_chase(sim, move_mode, to_player, dist, spd_mult)
		"telegraph":
			state_ticks += 1
			var total_tel: int = _current_telegraph_ticks()
			ent.telegraph_ratio = clampf(float(state_ticks) / float(maxi(total_tel, 1)), 0.0, 1.0)
			if absf(to_player.x) > 1.5:
				ent.facing = signf(to_player.x)
			# 前摇减速收稳
			ent.vel.x = move_toward(ent.vel.x, 0.0, 320.0 * FIXED_DT)
			if move_mode == "fly":
				ent.vel.y = move_toward(ent.vel.y, 0.0, 200.0 * FIXED_DT)
			if state_ticks >= total_tel:
				ent.telegraph_ratio = 0.0
				_execute_attack(sim, combat, to_player, player_pos, tick, player_hit_cb)
		"attack":
			# 冲锋 / 旱魃猛扑持续阶段
			state_ticks += 1
			if not lunge_hit_done and _overlaps_player(player_pos, 3.0):
				lunge_hit_done = true
				_hit_player_melee(player_pos, tick, player_hit_cb)
			if ent.archetype == "drought_demon" and on_ground and state_ticks > 6:
				_scatter_landing_fire(sim)
				state = "recover"
				state_ticks = 0
				cooldown_ticks = _current_cooldown_ticks()
			elif state_ticks >= 18:
				state = "recover"
				state_ticks = 0
				cooldown_ticks = _current_cooldown_ticks()
		"recover":
			ent.telegraph_ratio = 0.0
			state_ticks += 1
			ent.vel.x = move_toward(ent.vel.x, 0.0, 260.0 * FIXED_DT)
			if move_mode == "fly":
				ent.vel.y = sin(bob_phase) * 10.0
			if state_ticks >= 16:
				state = "chase" if ent.aggroed else "patrol"
				state_ticks = 0

	_step_physics(sim, tick, event_bus, mat_quicksilver)

# ------------------------------------------------------------------ 行为辅助

func _needs_los() -> bool:
	return ent.archetype in ["gas_wisp", "painted_skin"]

func _current_telegraph_ticks() -> int:
	var base: int = maxi(int(cfg.get("telegraph_ticks", 20)), 8)
	if ent.archetype == "drought_demon" and ent.phase >= 2:
		if attack_pattern == 2:
			return 32
		return maxi(base - 6, 14)
	return base

func _current_cooldown_ticks() -> int:
	var base: int = maxi(int(cfg.get("attack_cooldown_ticks", 60)), 24)
	if ent.archetype == "drought_demon" and ent.phase >= 2:
		return roundi(float(base) * 0.8)
	return base

func _enter_telegraph() -> void:
	state = "telegraph"
	state_ticks = 0
	ent.telegraph_ratio = 0.05
	match ent.archetype:
		"painted_skin":
			ent.telegraph_color = Color(0.72, 0.42, 1.0)
		"drought_demon":
			ent.telegraph_color = Color(1.0, 0.34, 0.14) if attack_pattern != 2 else Color(1.0, 0.72, 0.18)
		"gas_wisp":
			ent.telegraph_color = Color(1.0, 0.68, 0.18)
		"earth_worm":
			ent.telegraph_color = Color(0.96, 0.76, 0.32)
		_:
			ent.telegraph_color = Color(0.84, 0.92, 1.0)

func _do_patrol(sim: SimWorldNode, move_mode: String, spd_mult: float) -> void:
	var pspd: float = float(cfg.get("patrol_speed", 20.0)) * spd_mult
	patrol_timer -= 1
	if patrol_timer <= 0:
		patrol_dir = -patrol_dir
		patrol_timer = 90 + (absi(floori(ent.pos.x)) % 60)
	ent.facing = patrol_dir
	if move_mode == "fly":
		ent.vel.x = move_toward(ent.vel.x, patrol_dir * pspd, 140.0 * FIXED_DT)
		ent.vel.y = sin(bob_phase) * 14.0
		if _solid_ahead(sim, patrol_dir, 6):
			patrol_dir = -patrol_dir
	else:
		# 地面巡逻：遇墙或遇悬崖折返
		if _solid_ahead(sim, patrol_dir, 4) or (on_ground and not _floor_ahead(sim, patrol_dir)):
			patrol_dir = -patrol_dir
			ent.facing = patrol_dir
		ent.vel.x = move_toward(ent.vel.x, patrol_dir * pspd, 240.0 * FIXED_DT)

func _do_chase(sim: SimWorldNode, move_mode: String, to_player: Vector2, dist: float, spd_mult: float) -> void:
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
		# 保持在玩家偏上方一点方便抛射火球
		desired.y += clampf((to_player.y - 12.0) * 0.6, -24.0, 24.0)
		ent.vel = ent.vel.move_toward(desired, 180.0 * FIXED_DT)
		return

	# 地面追击：画皮保持中距，近战/旱魃压近
	var dir_x: float = signf(to_player.x) if absf(to_player.x) > 2.0 else float(ent.facing)
	var target_vx: float = dir_x * cspd
	if ent.archetype == "painted_skin":
		var pref: float = float(cfg.get("preferred_range", 74.0))
		if dist < pref - 26.0:
			target_vx = -dir_x * (cspd * 0.75)
		elif dist <= pref + 18.0:
			target_vx = 0.0
	ent.vel.x = move_toward(ent.vel.x, target_vx, 280.0 * FIXED_DT)
	# 追击遇低坎/玩家偏高时小跳跨越
	if on_ground and absf(target_vx) > 5.0 and (_solid_ahead(sim, signf(target_vx), 4) or to_player.y < -18.0):
		if _solid_ahead(sim, signf(target_vx), 6):
			ent.vel.y = -68.0
			on_ground = false

func _execute_attack(sim: SimWorldNode, combat, to_player: Vector2, player_pos: Vector2,
		tick: int, player_hit_cb: Callable) -> void:
	var dir := to_player.normalized() if to_player.length() > 0.1 else Vector2(ent.facing, 0.0)
	match ent.archetype:
		"coal_ghost":
			# 矿鬼近战挥爪
			if to_player.length() <= float(cfg.get("attack_range", 14.0)) + 8.0:
				_hit_player_melee(player_pos, tick, player_hit_cb)
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()
		"earth_worm":
			# 土蝼短距扑咬冲锋
			var lspd: float = float(cfg.get("lunge_speed", 108.0))
			ent.vel.x = (signf(to_player.x) if absf(to_player.x) > 1.0 else ent.facing) * lspd
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
			_execute_boss_attack(sim, combat, to_player, dir)
		_:
			state = "recover"
			state_ticks = 0
			cooldown_ticks = _current_cooldown_ticks()

func _execute_boss_attack(sim: SimWorldNode, combat, to_player: Vector2, dir: Vector2) -> void:
	var p2: bool = ent.phase >= 2
	var pat: int = attack_pattern
	attack_pattern = (attack_pattern + 1) % (3 if p2 else 2)
	if pat == 0:
		# 招式 A：旱火扇弹（P1 3连 / P2 5连，落地可点火）
		var count := 5 if p2 else 3
		var spread := 44.0 if p2 else 28.0
		var bonus_dmg := 2.0 if p2 else 0.0
		_fire_projectile(combat, dir, count, spread, bonus_dmg)
		state = "recover"
		state_ticks = 0
		cooldown_ticks = _current_cooldown_ticks()
	elif pat == 1:
		# 招式 B：炽地猛扑
		var lspd: float = float(cfg.get("lunge_speed", 124.0)) * (1.12 if p2 else 1.0)
		var sx: float = signf(to_player.x) if absf(to_player.x) > 1.0 else float(ent.facing)
		ent.vel.x = sx * lspd
		ent.vel.y = -88.0
		on_ground = false
		lunge_hit_done = false
		state = "attack"
		state_ticks = 0
	else:
		# 招式 C（P2 专属）：焦土灼浪 —— 左右贴地滚火波，可跳躲或泼水浇灭
		if combat != null:
			var origin: Vector2 = Vector2(ent.pos.x, ent.pos.y - 4.0)
			for sx in [-1.0, 1.0]:
				var act := {
					"op": "spawn_projectile",
					"spell": "boss_scorch_wave",
					"count": 1,
					"speed": 7.5,
					"gravity": 0.08,
					"damage": 15.0,
					"damage_type": "火",
					"element": "火",
					"ttl_ticks": 110,
					"payloads": [{"op": "ignite", "duration": 3.0}],
				}
				combat.execute_actions([act], origin, Vector2(sx, -0.10), ent.entity_id, "enemy")
		_scatter_landing_fire(sim)
		state = "recover"
		state_ticks = 0
		cooldown_ticks = _current_cooldown_ticks()

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
	var origin: Vector2 = ent.center_pos() + dir * (ent.half_w + 2.0)
	combat.execute_actions([act], origin, dir, ent.entity_id, "enemy")

func _hit_player_melee(player_pos: Vector2, tick: int, player_hit_cb: Callable) -> void:
	if not player_hit_cb.is_valid():
		return
	var epos: Vector2 = ent.pos
	var dir: Vector2 = (player_pos - epos).normalized() if player_pos.distance_to(epos) > 0.1 else Vector2(float(ent.facing), -0.2)
	player_hit_cb.call({
		"pos": ent.center_pos(),
		"dir": dir,
		"damage": float(cfg.get("damage", 6.0)),
		"damage_type": String(cfg.get("damage_type", "物理")),
		"lantern_damage": float(cfg.get("lantern_damage", 0.0)),
		"source_id": ent.display_name,
		"tick": tick,
	})

func _scatter_landing_fire(sim: SimWorldNode) -> void:
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
	sim.apply_heat_burst(c.x, c.y, 7, 400.0)

# ------------------------------------------------------------------ 像素沙盒物理

func _step_physics(sim: SimWorldNode, tick: int, event_bus, mat_quicksilver: int) -> void:
	var move_mode: String = String(cfg.get("move_mode", "ground"))
	if move_mode != "fly":
		ent.vel.y = minf(ent.vel.y + GRAVITY * FIXED_DT, MAX_FALL)

	# 水平子步（含 1–3 格迈步 + 水银界硬阻挡）
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
			if ent.vel.y > 0.0:
				on_ground = true
			ent.vel.y = 0.0
	if move_mode != "fly" and not on_ground and ent.vel.y >= 0.0:
		if _box_blocked(sim, (ent.pos as Vector2) + Vector2(0.0, 1.0)):
			on_ground = true

func _move_horizontal(sim: SimWorldNode, total_dx: float, tick: int, event_bus, mat_quicksilver: int) -> bool:
	var steps := maxi(ceili(absf(total_dx) / MAX_SUBSTEP), 1)
	var sub_x := total_dx / float(steps)
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
		return false
	return true

func _move_vertical(sim: SimWorldNode, total_dy: float, tick: int, event_bus, mat_quicksilver: int) -> bool:
	var steps := maxi(ceili(absf(total_dy) / MAX_SUBSTEP), 1)
	var sub_y := total_dy / float(steps)
	for _i in range(steps):
		var target: Vector2 = (ent.pos as Vector2) + Vector2(0.0, sub_y)
		if ent.is_blocked_by_quicksilver(sim, target, tick, event_bus, mat_quicksilver):
			return false
		if not _box_blocked(sim, target):
			ent.pos = target
			continue
		return false
	return true

func _box_blocked(sim: SimWorldNode, p: Vector2) -> bool:
	var cx := floori(p.x)
	var cy := floori(p.y)
	var hw := ceili(ent.half_w)
	var hh := ceili(ent.height)
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

func _solid_ahead(sim: SimWorldNode, dir_x: float, look_dist: int) -> bool:
	var sx := 1 if dir_x >= 0.0 else -1
	var cx := floori(ent.pos.x) + sx * (ceili(ent.half_w) + look_dist)
	var cy := floori(ent.pos.y) - 4
	if cx < 1 or cx >= sim.get_world_width() - 1 or cy < 1 or cy >= sim.get_world_height() - 1:
		return true
	return sim.is_solid(cx, cy)

func _floor_ahead(sim: SimWorldNode, dir_x: float) -> bool:
	var sx := 1 if dir_x >= 0.0 else -1
	var cx := floori(ent.pos.x) + sx * (ceili(ent.half_w) + 3)
	var cy := floori(ent.pos.y)
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	if cx < 1 or cx >= w - 1:
		return false
	for dy in range(1, 7):
		if cy + dy < h and sim.is_solid(cx, cy + dy):
			return true
	return false

func _is_feet_in_quicksilver(sim: SimWorldNode, mat_quicksilver: int) -> bool:
	if mat_quicksilver < 0:
		return false
	var c: Vector2i = ent.cell_pos()
	return sim.get_cell(c.x, maxi(c.y - 1, 0)) == mat_quicksilver

func _overlaps_player(player_pos: Vector2, pad: float = 0.0) -> bool:
	return (
		absf(ent.pos.x - player_pos.x) <= ent.half_w + 2.5 + pad
		and ent.pos.y >= player_pos.y - 10.0 - pad
		and ent.pos.y - ent.height <= player_pos.y + pad
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
		if sim.is_solid(gx, gy):
			return false
	return true
