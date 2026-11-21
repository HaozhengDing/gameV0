extends RefCounted
## M1-α 粉末穿行物理共享模块（对应决策卡 refs/cards/decisions/powder-traversal.md#density-drag-wade）：
## - 硬阻挡只认 SIM_STATE_STATIC（岩/竹木）；松散粉末（SIM_STATE_POWDER）改为可穿行阻力介质；
## - 脚底踩在粉坡顶仍可承托站立，水平/空中穿行按「重叠占比 × data/materials.json 密度」分 3 档减速；
## - 玩家（player.gd）与地面敌人/BOSS（enemy_ai.gd）共享同一套密度表与公式。

const MATERIALS_PATH := "../data/materials.json"
const MIN_FILL_THRESHOLD := 0.12      # 低于 12%（空中零散飞粉）完全不减速、不卡脚
const LIGHT_DENSITY_MAX := 1.5        # 糯米(0.8) / 煤(1.4)
const MEDIUM_DENSITY_MAX := 2.5       # 沙(2.0) / 硫磺(2.0) / 硝石(2.1)
const MULT_LIGHT_FLOOR := 0.75        # 轻粉深埋最低移速倍率
const MULT_MEDIUM_FLOOR := 0.55       # 中粉深埋最低移速倍率
const MULT_HEAVY_FLOOR := 0.35        # 重矿粉（石灰 3.3 / 朱砂 8.1）深埋最低移速倍率

const STATE_POWDER := 1
const STATE_STATIC := 4

## 从 data/materials.json 读取材质密度，并映射到当前 SimWorldNode 的整型 material_id。
static func build_density_table(sim: SimWorldNode) -> Dictionary:
	var table: Dictionary = {}
	if sim == null or not sim.has_world():
		return table
	# 引擎实验粉末默认值（sand 不在 data/materials.json）
	var sand_id: int = sim.material_id("sand")
	if sand_id >= 0:
		table[sand_id] = 2.0
	var full_path: String = ProjectSettings.globalize_path("res://").path_join(MATERIALS_PATH)
	if not FileAccess.file_exists(full_path):
		return table
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(full_path))
	if not (parsed is Dictionary):
		return table
	var root: Dictionary = parsed
	for raw in root.get("materials", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var mid_str: String = String(d.get("id", ""))
		if mid_str.is_empty():
			continue
		var mid: int = sim.material_id(mid_str)
		if mid >= 0:
			table[mid] = float(d.get("density", 2.0))
	return table

## 采样实体碰撞盒内的松散粉末重叠占比与加权密度，返回分级减速倍率：
## {in_powder: bool, fill: float, avg_density: float, speed_mult: float, tier: int}
static func sample_box(sim: SimWorldNode, cx: int, cy: int, half_w: int, height: int,
		density_by_id: Dictionary) -> Dictionary:
	var out := {
		"in_powder": false,
		"fill": 0.0,
		"avg_density": 0.0,
		"speed_mult": 1.0,
		"tier": 0,
	}
	if sim == null or not sim.has_world():
		return out
	var w: int = sim.get_world_width()
	var h: int = sim.get_world_height()
	var total: int = (half_w * 2 + 1) * maxi(height, 1)
	var powder_cnt := 0
	var density_sum := 0.0
	for gy in range(cy - height + 1, cy + 1):
		if gy < 0 or gy >= h:
			continue
		for gx in range(cx - half_w, cx + half_w + 1):
			if gx < 0 or gx >= w:
				continue
			var m: int = sim.get_cell(gx, gy)
			if m <= 0:
				continue
			if sim.get_material_state(m) == STATE_POWDER:
				powder_cnt += 1
				density_sum += float(density_by_id.get(m, 2.0))
	var fill: float = float(powder_cnt) / float(maxi(total, 1))
	out["fill"] = fill
	if powder_cnt == 0 or fill < MIN_FILL_THRESHOLD:
		return out
	var avg_d: float = density_sum / float(powder_cnt)
	var tier: int = 1
	var floor_mult: float = MULT_LIGHT_FLOOR
	if avg_d > MEDIUM_DENSITY_MAX:
		tier = 3
		floor_mult = MULT_HEAVY_FLOOR
	elif avg_d > LIGHT_DENSITY_MAX:
		tier = 2
		floor_mult = MULT_MEDIUM_FLOOR
	var eff_fill: float = clampf((fill - 0.10) / 0.55, 0.25, 1.0)
	out["in_powder"] = true
	out["avg_density"] = avg_d
	out["tier"] = tier
	out["speed_mult"] = lerpf(1.0, floor_mult, eff_fill)
	return out

## 判断脚下支撑行（y+1）是否踩在静态固体或粉坡表面。
static func has_surface_below(sim: SimWorldNode, cx: int, cy: int, half_w: int,
		allow_powder_surface: bool) -> bool:
	if sim == null or not sim.has_world():
		return false
	var w: int = sim.get_world_width()
	var h: int = sim.get_world_height()
	var fy: int = cy + 1
	if fy >= h:
		return true
	if fy < 0:
		return false
	for gx in range(cx - half_w, cx + half_w + 1):
		if gx < 0 or gx >= w:
			continue
		var m: int = sim.get_cell(gx, fy)
		if m <= 0:
			continue
		var st: int = sim.get_material_state(m)
		if st == STATE_STATIC:
			return true
		if allow_powder_surface and st == STATE_POWDER:
			return true
	return false
