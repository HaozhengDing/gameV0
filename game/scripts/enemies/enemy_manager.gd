extends RefCounted
## M1-06 矿井一层敌人与旱魃 BOSS 总控：
## 1) 加载 data/entities/layer01.json 全部 5 种敌人定义；
## 2) 消费 Wang Tile 刷怪锚点（保证 3 小怪 + 1 画皮精英 + 1 旱魃 BOSS 分布合理且防掩埋）；
## 3) 驱动所有存活敌人的 EnemyAI 状态机（视距内活跃，远端休眠不拖帧）；
## 4) 结算击杀掉落（银两、矿粉物质、旱魃毕方火符）并向 HUD 提供 BOSS 血条快照。

const ENTITIES_PATH := "../data/entities/layer01.json"
const ACTIVE_AI_DIST := 320.0
const BOSS_HUD_DIST := 250.0

const EnemyAIScript := preload("res://scripts/enemies/enemy_ai.gd")
const PowderPhysics := preload("res://scripts/powder_physics.gd")

var sim: SimWorldNode
var combat
var event_bus
var text_db
var hud
var wand_manager
var player_hit_callback: Callable = Callable()

var defs: Dictionary = {}             # entity_def_id -> Dictionary
var ais: Array = []                   # Array of EnemyAIScript
var boss_ent = null                   # 旱魃 CombatEntity 引用
var boss_killed: bool = false
var silver_collected: int = 0
var _mat_quicksilver: int = -1
var _mat_water: int = -1
var _density_by_id: Dictionary = {}
var _dropped_ids: Dictionary = {}     # entity_id -> true，防止重复结算掉落

func setup(p_sim: SimWorldNode, p_combat, p_event_bus, p_text_db, p_hud, p_wand_manager = null) -> void:
	sim = p_sim
	combat = p_combat
	event_bus = p_event_bus
	text_db = p_text_db
	hud = p_hud
	wand_manager = p_wand_manager
	_refresh_material_cache()
	load_definitions()

func _refresh_material_cache() -> void:
	if sim != null and sim.has_world():
		_mat_quicksilver = sim.material_id("quicksilver")
		_mat_water = sim.material_id("water")
		_density_by_id = PowderPhysics.build_density_table(sim)
	else:
		_mat_quicksilver = -1
		_mat_water = -1
		_density_by_id.clear()

func load_definitions() -> bool:
	defs.clear()
	var full_path: String = ProjectSettings.globalize_path("res://").path_join(ENTITIES_PATH)
	if not FileAccess.file_exists(full_path):
		push_error("M1-06: 找不到敌人配置 " + full_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(full_path))
	if not (parsed is Dictionary):
		push_error("M1-06: 解析敌人配置失败")
		return false
	var root: Dictionary = parsed
	for raw in root.get("entities", []):
		if raw is Dictionary:
			var d: Dictionary = raw
			var eid: String = String(d.get("id", ""))
			if not eid.is_empty():
				defs[eid] = d
	return defs.size() >= 5

func reset_round() -> void:
	ais.clear()
	boss_ent = null
	boss_killed = false
	silver_collected = 0
	_dropped_ids.clear()
	_refresh_material_cache()

func spawn_by_id(def_id: String, pos: Vector2i, custom_id: String = "", seed_offset: int = 0):
	if combat == null or not defs.has(def_id):
		return null
	var d: Dictionary = defs[def_id]
	var eid: String = custom_id if not custom_id.is_empty() else ("%s_%d" % [def_id.replace("-", "_"), ais.size()])
	var nk: String = String(d.get("name_key", ""))
	var dname: String = text_db.get_text(nk) if (text_db != null and not nk.is_empty() and text_db.has_key(nk)) else eid
	var ent = combat.spawn_entity({
		"id": eid,
		"name": dname,
		"faction": "enemy",
		"tier": String(d.get("tier", "mob")),
		"archetype": String(d.get("archetype", "")),
		"pos": Vector2(float(pos.x), float(pos.y)),
		"half_w": float(d.get("half_w", 3.0)),
		"height": float(d.get("height", 10.0)),
		"max_hp": float(d.get("hp", 20.0)),
		"color": String(d.get("color", "#D05050")),
		"tags": d.get("tags", []),
		"weak_to": d.get("weak_to", {}),
		"wet_armor_crack_mult": float(d.get("wet_armor_crack_mult", 1.4)),
		"drop": d.get("drop", {}),
		"ai_cfg": d,
	})
	var ai = EnemyAIScript.new()
	ai.setup(ent, d, seed_offset)
	ais.append(ai)
	if def_id == "enemy-drought-demon":
		boss_ent = ent
	return ent

## 按 Wang Tile 矿井锚点生成整层生态：3 小怪权重分配 + 保底 1 画皮精英（优先水银池）+ 1 鬼火（优先瓦斯囊）+ 1 旱魃 BOSS。
func spawn_from_wang_anchors(wang_gen) -> int:
	if wang_gen == null or combat == null or sim == null:
		return 0
	var anchors: Array = wang_gen.spawn_anchors
	var mob_anchors: Array[Dictionary] = []
	var boss_anchor: Dictionary = {}
	for raw_a in anchors:
		if not (raw_a is Dictionary):
			continue
		var a: Dictionary = raw_a
		if String(a.get("boss_id", "")) == "boss-drought-demon":
			boss_anchor = a
		else:
			mob_anchors.append(a)

	# 1) 生成矿底旱魃 BOSS
	if not boss_anchor.is_empty():
		var bpos: Vector2i = wang_gen.find_safe_stand_pos(sim, boss_anchor["pos"], 6, 16)
		spawn_by_id("enemy-drought-demon", bpos, "boss_drought_demon", 0)

	# 2) 为画皮（优先 room-01-silver-pit）与硫烟鬼火（优先 room-02-gas-pocket）挑专属锚点
	var elite_idx := -1
	var wisp_idx := -1
	for i in range(mob_anchors.size()):
		var aid: String = String(mob_anchors[i].get("id", ""))
		if aid == "anchor-mob" and elite_idx < 0:
			elite_idx = i
		elif aid == "anchor-mob-02" and wisp_idx < 0:
			wisp_idx = i
	if elite_idx < 0 and mob_anchors.size() >= 1:
		elite_idx = mob_anchors.size() - 1
	if wisp_idx < 0 and mob_anchors.size() >= 2:
		wisp_idx = 0 if elite_idx != 0 else 1

	# 3) 逐锚点刷怪并贴地/悬空防掩埋校准（手工房同步翻倍配 1 只随行小怪，每场景 2 只怪）
	for i in range(mob_anchors.size()):
		var a: Dictionary = mob_anchors[i]
		var aid: String = String(a.get("id", ""))
		var def_id := "enemy-coal-ghost"
		if i == elite_idx:
			def_id = "enemy-painted-skin"
		elif i == wisp_idx:
			def_id = "enemy-gas-wisp"
		else:
			var roll := absi(wang_gen.seed_used + i * 37) % 100
			if roll < 50:
				def_id = "enemy-coal-ghost"
			elif roll < 80:
				def_id = "enemy-earth-worm"
			else:
				def_id = "enemy-gas-wisp"
		_spawn_calibrated_mob(wang_gen, def_id, a["pos"], "mine_%s_%d" % [String(defs.get(def_id, {}).get("archetype", "mob")), i], i + 1)

		# 手工非 BOSS 房（水银池 / 瓦斯囊）同步翻倍：在同房错开位置追加 1 只随行小怪
		if aid == "anchor-mob" or aid == "anchor-mob-02":
			var comp_id := "enemy-coal-ghost" if aid == "anchor-mob" else "enemy-gas-wisp"
			var base_p: Vector2i = a["pos"]
			var comp_origin := Vector2i(base_p.x - 48, base_p.y)
			_spawn_calibrated_mob(wang_gen, comp_id, comp_origin, "mine_comp_%s_%d" % [String(defs.get(comp_id, {}).get("archetype", "mob")), i], i + 101)

	print("M1_ENEMIES_SPAWNED total=%d boss=%s" % [ais.size(), "yes" if boss_ent != null else "no"])
	return ais.size()

func _spawn_calibrated_mob(wang_gen, def_id: String, origin: Vector2i, eid: String, seed_off: int) -> void:
	var d: Dictionary = defs.get(def_id, {})
	var hw := ceili(float(d.get("half_w", 3.0)))
	var hh := ceili(float(d.get("height", 10.0)))
	var safe_pos: Vector2i = wang_gen.find_safe_stand_pos(sim, origin, hw, hh)
	if String(d.get("move_mode", "ground")) == "fly":
		safe_pos = _lift_flyer_spawn(wang_gen, safe_pos, hw, hh)
	spawn_by_id(def_id, safe_pos, eid, seed_off)

func _lift_flyer_spawn(wang_gen, floor_pos: Vector2i, hw: int, hh: int) -> Vector2i:
	var best := floor_pos
	for lift in [18, 12, 6]:
		var cand := Vector2i(floor_pos.x, maxi(floor_pos.y - lift, hh + 2))
		var ok := true
		for gy in range(cand.y - hh + 1, cand.y + 1):
			for gx in range(cand.x - hw, cand.x + hw + 1):
				if sim.is_solid(gx, gy):
					ok = false
					break
			if not ok:
				break
		if ok and (wang_gen == null or not wang_gen.has_powder_above(sim, cand.x, cand.y - hh + 1, hw, 140)):
			return cand
	return best

func step_tick(player_pos: Vector2, tick: int, player_vel: Vector2 = Vector2.ZERO) -> void:
	if sim == null or not sim.has_world():
		return
	var log_cb := func(msg: String) -> void:
		if hud != null:
			hud.log_event(msg)
	for ai in ais:
		if ai.ent == null or not ai.ent.alive:
			continue
		var dist: float = ai.ent.pos.distance_to(player_pos)
		if dist <= ACTIVE_AI_DIST or ai.ent.aggroed:
			ai.step_tick(sim, combat, player_pos, tick, event_bus, _mat_quicksilver,
					player_hit_callback, log_cb, player_vel, _mat_water, _density_by_id)

func get_ai_for(entity_id: String):
	for ai in ais:
		if ai.ent != null and ai.ent.entity_id == entity_id:
			return ai
	return null

func get_boss_ai():
	if boss_ent == null:
		return null
	return get_ai_for(boss_ent.entity_id)

func on_entity_killed(target_id: String) -> Dictionary:
	var reward := {"silver": 0, "materials": [], "talisman": "", "is_boss": false}
	if combat == null or _dropped_ids.has(target_id):
		return reward
	var ent = combat.get_entity(target_id)
	if ent == null or ent.faction != "enemy":
		return reward
	_dropped_ids[target_id] = true
	var drop: Dictionary = ent.drop
	var silver: int = int(drop.get("silver", 0))
	if silver > 0:
		silver_collected += silver
		reward["silver"] = silver
	var mats: Array = drop.get("materials", []) if drop.get("materials") is Array else []
	var c: Vector2i = ent.cell_pos()
	for raw_m in mats:
		var mname: String = String(raw_m)
		_spawn_drop_material(c, mname)
		(reward["materials"] as Array).append(mname)
	var tali: String = String(drop.get("talisman", ""))
	if not tali.is_empty():
		reward["talisman"] = tali
		if wand_manager != null and not wand_manager.bag.has(tali):
			wand_manager.bag.append(tali)
	if boss_ent != null and target_id == boss_ent.entity_id:
		boss_killed = true
		reward["is_boss"] = true
		if hud != null:
			hud.log_event("击杀 旱魃！获 %d 银与「火」符" % silver)
	return reward

func _spawn_drop_material(center: Vector2i, mat_name: String) -> void:
	if sim == null or not sim.has_world() or mat_name.is_empty():
		return
	var mid: int = sim.material_id(mat_name)
	if mid < 0:
		return
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dy in range(-3, 2):
		for dx in range(-3, 4):
			if dx * dx + dy * dy > 9:
				continue
			var gx := clampi(center.x + dx, 1, w - 2)
			var gy := clampi(center.y + dy, 1, h - 2)
			if sim.get_cell(gx, gy) == 0:
				sim.set_cell(gx, gy, mid)

## 供 HUD 渲染矿底旱魃 BOSS 血条（玩家进入 BOSS 房范围或交战后显示）。
func get_boss_hud_state(player_pos: Vector2) -> Dictionary:
	if boss_ent == null or not boss_ent.alive:
		return {"visible": false}
	var dist: float = boss_ent.pos.distance_to(player_pos)
	if not boss_ent.aggroed and dist > BOSS_HUD_DIST:
		return {"visible": false}
	return {
		"visible": true,
		"name": boss_ent.display_name,
		"hp": boss_ent.hp,
		"max_hp": boss_ent.max_hp,
		"phase": boss_ent.phase,
		"wet": boss_ent.has_status("wet"),
	}
