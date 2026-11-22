extends RefCounted
## M1-α 粉末穿行物理共享模块（对应决策卡 refs/cards/decisions/powder-traversal.md#density-drag-wade）：
## - 硬阻挡只认 SIM_STATE_STATIC（岩/竹木）；松散粉末（SIM_STATE_POWDER）改为可穿行阻力介质；
## - 脚底踩在粉坡顶仍可承托站立，水平/空中穿行按「重叠占比 × data/materials.json 密度」分 3 档减速；
## - 玩家（player.gd）与地面敌人/BOSS（enemy_ai.gd）共享同一套密度表与公式。

const MATERIALS_PATH := "../data/materials.json"
const MIN_FILL_THRESHOLD := 0.12      # 低于 12%（空中零散飞粉）完全不减速、不卡脚
const LIGHT_DENSITY_MAX := 1.5        # 糯米(0.8) / 煤(1.4)
const MEDIUM_DENSITY_MAX := 2.5       # 沙(2.0) / 硫磺(2.0) / 硝石(2.1)
const MULT_LIGHT_FLOOR := 0.75        # 轻粉涉入最低移速倍率
const MULT_MEDIUM_FLOOR := 0.55       # 中粉涉入最低移速倍率
const MULT_HEAVY_FLOOR := 0.35        # 重矿粉（石灰 3.3 / 朱砂 8.1）涉入最低移速倍率
const SURFACE_LIGHT_MULT := 0.80      # 踩在轻粉堆表面行走的移速倍率（煤/糯米）
const SURFACE_MEDIUM_MULT := 0.62     # 踩在中粉堆表面行走的移速倍率（沙/硫磺/硝石）
const SURFACE_HEAVY_MULT := 0.44      # 踩在重矿粉堆表面行走的移速倍率（石灰/朱砂）

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

## 采样实体碰撞盒内的松散粉末重叠占比与脚底粉堆表层密度，返回分级减速倍率：
## {in_powder: bool, on_powder_surface: bool, fill: float, avg_density: float, speed_mult: float, tier: int}
static func sample_box(sim: SimWorldNode, cx: int, cy: int, half_w: int, height: int,
		density_by_id: Dictionary, include_foot_surface: bool = true) -> Dictionary:
	var out := {
		"in_powder": false,
		"on_powder_surface": false,
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

	var body_mult := 1.0
	var best_tier := 0
	var best_density := 0.0
	if powder_cnt > 0 and fill >= MIN_FILL_THRESHOLD:
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
		body_mult = lerpf(1.0, floor_mult, eff_fill)
		out["in_powder"] = true
		best_tier = tier
		best_density = avg_d

	# 踩在已沉降粉堆表面（cy+1..cy+2）行走：不沉下去，但按密度给予 3 档表层阻力（魂沙式脚感）
	var surf_mult := 1.0
	if include_foot_surface:
		var surf_cnt := 0
		var surf_density_sum := 0.0
		for gy in range(cy + 1, cy + 3):
			if gy < 0 or gy >= h:
				continue
			for gx in range(cx - half_w, cx + half_w + 1):
				if gx < 0 or gx >= w:
					continue
				var m: int = sim.get_cell(gx, gy)
				if m > 0 and sim.get_material_state(m) == STATE_POWDER:
					surf_cnt += 1
					surf_density_sum += float(density_by_id.get(m, 2.0))
		if surf_cnt >= maxi(half_w + 1, 2):
			var sd: float = surf_density_sum / float(surf_cnt)
			var stier := 1
			surf_mult = SURFACE_LIGHT_MULT
			if sd > MEDIUM_DENSITY_MAX:
				stier = 3
				surf_mult = SURFACE_HEAVY_MULT
			elif sd > LIGHT_DENSITY_MAX:
				stier = 2
				surf_mult = SURFACE_MEDIUM_MULT
			out["on_powder_surface"] = true
			if surf_mult < body_mult:
				best_tier = stier
				best_density = sd

	out["avg_density"] = best_density
	out["tier"] = best_tier
	out["speed_mult"] = minf(body_mult, surf_mult)
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

## 判断指定行（通常为下落目标脚底行）是否存在任何固体或沉降粉末，确保角色/怪物绝不向下沉入土堆。
static func has_solid_at_row(sim: SimWorldNode, cx: int, row_y: int, half_w: int) -> bool:
	if sim == null or not sim.has_world():
		return true
	var w: int = sim.get_world_width()
	var h: int = sim.get_world_height()
	if row_y < 0 or row_y >= h:
		return true
	for gx in range(cx - half_w, cx + half_w + 1):
		if gx < 0 or gx >= w:
			return true
		var m: int = sim.get_cell(gx, row_y)
		if m > 0:
			var st: int = sim.get_material_state(m)
			if st == STATE_STATIC or st == STATE_POWDER:
				return true
	return false

## 判断目标位置是否为厚实落地的陡峭粉堆（防止从侧面横钻进土堆底部；空中落尘/薄层仍可涉过）。
static func is_settled_mound_wall(sim: SimWorldNode, cx: int, cy: int, half_w: int, height: int) -> bool:
	if sim == null or not sim.has_world():
		return false
	if not has_surface_below(sim, cx, cy, half_w, true):
		return false
	var w: int = sim.get_world_width()
	var h: int = sim.get_world_height()
	var total: int = (half_w * 2 + 1) * maxi(height, 1)
	var p_cnt := 0
	var low_total := (half_w * 2 + 1) * mini(height, 5)
	var low_cnt := 0
	var low_y0: int = cy - mini(height, 5) + 1
	for gy in range(cy - height + 1, cy + 1):
		if gy < 0 or gy >= h:
			continue
		for gx in range(cx - half_w, cx + half_w + 1):
			if gx < 0 or gx >= w:
				continue
			var m: int = sim.get_cell(gx, gy)
			if m > 0 and sim.get_material_state(m) == STATE_POWDER:
				p_cnt += 1
				if gy >= low_y0:
					low_cnt += 1
	var fill: float = float(p_cnt) / float(maxi(total, 1))
	var low_fill: float = float(low_cnt) / float(maxi(low_total, 1))
	return fill >= 0.55 and low_fill >= 0.60
