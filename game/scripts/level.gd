extends RefCounted
## T4b 世界层：960x540 cells 灰盒关卡 —— 全岩层 + 程序化走廊 + data/rooms 两个房间
## + 唯一走廊上的火障（火墙 + 油槽）+ 出口；负责火障重燃与「喷水灭火」状态。
## 契约：game/T4B.md §2；C-SIM v2（16 种材质，见 game/gdextension/API.md）。
##
## 视觉比例（Lead 2026-11-16 复审）：data/rooms 的 grid 是 tile 网格，tile_size=16，
## 即 1 个字符 = 16x16 world cells（1 cell = 1 世界像素，4 倍放大后 384x224 cells ≈ 0.8 屏）。
## 房间 legend 名称直接映射 C-SIM v2 材质，不做替身；'#'（rock）跳过（世界底已是 rock）。

# ------------------------------------------------------------------ 常量
const WORLD_W := 960
const WORLD_H := 540
const SCALE := 4

# 房间：24x14 字符，每字符 16x16 cells -> 384x224 cells
const TILE := 16
const ROOM_CHARS_W := 24
const ROOM_CHARS_H := 14
const ROOM_W := ROOM_CHARS_W * TILE   # 384
const ROOM_H := ROOM_CHARS_H * TILE   # 224
const ROOM01_OFFSET := Vector2i(40, 148)   # 西侧：room-01-silver-pit（水银池）
const ROOM02_OFFSET := Vector2i(536, 148)  # 东侧：room-02-gas-pocket（瓦斯囊）

# 走廊 / 门洞：16 cells 高（y 260..275），能容纳 5x10 cells 的角色身体
const CORRIDOR_TOP := 260
const CORRIDOR_HEIGHT := 16
const START_CORRIDOR_X := 0
const START_CORRIDOR_W := 40    # 0..39（玩家起点走廊）
const MID_CORRIDOR_X := 424
const MID_CORRIDOR_W := 112     # 424..535（房间 01 东门 -> 房间 02 西门，火障在这里）
const EXIT_CORRIDOR_X := 920
const EXIT_CORRIDOR_W := 40     # 920..959（房间 02 东门 -> 出口）
const START_CELL := Vector2i(16, 270)
const EXIT_CELL := Vector2i(940, 269)
const EXIT_RADIUS := 1          # 3x3 cells 触发通关

# 火障：3 格宽火墙贯穿走廊截面（3 x 16 = 48 格火）+ 地板下 1 格深油槽（含火墙正下方，
# 火焰按 sim 的 ignite 规则点燃油槽；油槽两侧/底部是岩层，油不会沿走廊流走）
const FIRE_WALL_X0 := 480
const FIRE_WALL_X1 := 482
const FIRE_WALL_Y0 := 260
const FIRE_WALL_Y1 := 275
const OIL_TRENCH_Y := 276
const OIL_TRENCH_X0 := 468
const OIL_TRENCH_X1 := 494
# 喷水灭火半径：T4B §3.2 写 3 cells 是 1:1 旧尺度；房间/走廊按 16x tile 放大后
# 火墙高 16 cells，半径 3 喷一次只能盖 7 行、无法开出 10 格高的通道，故取 12（见汇报）
const DOUSE_RADIUS := 12

# 灰盒火焰补丁（docs/tech/sim-fire-heat-design.md §5）：
# sim_core 仅对油有自燃概率（5%/tick），煤/硫磺/竹木在 C-SIM v2 只有 flammable 标志、点燃概率 0。
# 灰盒世界层只追踪活跃火种，对相邻非油可燃材质按统一概率点燃（不改 sim_core/data 契约）。
const FLAMMABLE_IGNITE_CHANCE := 0.015  # 1.5%/tick（1-2%/tick 区间）
const MAX_TRACKED_FIRES := 512
const IGNITE_THRESHOLD := 983           # round(0.015 * 65536)

# 组合时刻 / --t4b-smoke / --t4b-shot 用坐标
const MERCURY_AIM_CELL := Vector2i(304, 276)    # room-01 水银池中心（tile 展开后的池内）
const FIRE_WALL_AIM_CELL := Vector2i(484, 270)  # 火障东缘方向（喷水瞄准点）
const DOUSE_CELL := Vector2i(470, 270)          # 喷水站位：火墙西侧 10 格
const SHOT_PLAYER_CELL := Vector2i(250, 270)    # --t4b-shot：房间 01 中部，朝东
const SMOKE_BAMBOO_CELL := Vector2i(384, 276)   # --t4b-smoke：room-01 东侧竹木柱（可燃测试用）

# 数据文件（res:// 不能出工程目录，按 T4B.md §2 用 globalize_path 拼 ../data）
const ROOM01_PATH := "../data/rooms/room-01-silver-pit.json"
const ROOM02_PATH := "../data/rooms/room-02-gas-pocket.json"

# ------------------------------------------------------------------ 状态
var sim: SimWorldNode
var built := false

var mat_empty := 0
var mat_rock := 1
var mat_water := 3
var mat_oil := 4
var mat_fire := 6
var _mat_flammable: Array[bool] = []        # 按材质 id 缓存「非油可燃」（煤/硫磺/竹木）

var fire_wall_cells: Array[Vector2i] = []   # 火墙源格（会被持续重燃，直到被水浇灭）
var _fire_wall_set: Dictionary = {}         # Vector2i -> true，快速判定「是不是火墙源格」
var _doused: Dictionary = {}                # Vector2i -> true，被喷水浇灭、本局不再重燃
var _tracked_fires: Dictionary = {}         # Vector2i -> true，灰盒火焰补丁追踪的活跃火格

# ------------------------------------------------------------------ 对外接口

func setup(p_sim: SimWorldNode) -> void:
	sim = p_sim
	_cache_material_ids()

## 重建整张世界（R 重开时 main.gd 会先重新 create_world，再调用本函数）。
func build() -> bool:
	if sim == null or not sim.has_world():
		push_error("T4B level: build() 之前必须先 create_world()")
		return false
	_cache_material_ids()
	fire_wall_cells.clear()
	_fire_wall_set.clear()
	_doused.clear()
	_tracked_fires.clear()

	var t0 := Time.get_ticks_msec()
	# 1) 全部填 rock，再挖出连通走廊（程序化）、放房间、放火障/出口
	for y in range(WORLD_H):
		for x in range(WORLD_W):
			sim.set_cell(x, y, mat_rock)
	# 2) 两个房间按 tile_size 展开（1 字符 = 16x16 cells），坐标加偏移
	_place_room(ROOM01_PATH, ROOM01_OFFSET)
	_place_room(ROOM02_PATH, ROOM02_OFFSET)
	# 3) 走廊 + 16 cells 高的门洞（门洞打在房间 16 格厚的墙上）
	_carve_rect(START_CORRIDOR_X, CORRIDOR_TOP, START_CORRIDOR_W, CORRIDOR_HEIGHT)
	_carve_rect(ROOM01_OFFSET.x, CORRIDOR_TOP, TILE, CORRIDOR_HEIGHT)                        # 房间 01 西门
	_carve_rect(ROOM01_OFFSET.x + ROOM_W - TILE, CORRIDOR_TOP, TILE, CORRIDOR_HEIGHT)        # 房间 01 东门
	_carve_rect(MID_CORRIDOR_X, CORRIDOR_TOP, MID_CORRIDOR_W, CORRIDOR_HEIGHT)
	_carve_rect(ROOM02_OFFSET.x, CORRIDOR_TOP, TILE, CORRIDOR_HEIGHT)                        # 房间 02 西门
	_carve_rect(ROOM02_OFFSET.x + ROOM_W - TILE, CORRIDOR_TOP, TILE, CORRIDOR_HEIGHT)        # 房间 02 东门
	_carve_rect(EXIT_CORRIDOR_X, CORRIDOR_TOP, EXIT_CORRIDOR_W, CORRIDOR_HEIGHT)
	# 4) 火障：走廊中段 3 格宽 x 16 格高火墙 + 地板下油槽
	_build_fire_wall()

	built = true
	print("T4B_LEVEL_BUILT ms=%d rooms=2 room_cells=%dx%d fire_wall=%d oil=%d start=%s exit=%s" % [
		Time.get_ticks_msec() - t0, ROOM_W, ROOM_H, fire_wall_cells.size(),
		OIL_TRENCH_X1 - OIL_TRENCH_X0 + 1, str(START_CELL), str(EXIT_CELL)
	])
	return true

## 每个 sim tick 调一次：火墙源格被烧掉后立刻重燃（火是带寿命的气体，不重燃会自己灭）。
## 已被喷水浇灭（_doused）的源格不再重燃 —— 这是「必须灭火才能过」的关键。
func tick_fire_wall() -> void:
	if not built:
		return
	for cell in fire_wall_cells:
		if _doused.has(cell):
			continue
		var m: int = sim.get_cell(cell.x, cell.y)
		if m == mat_fire:
			continue
		if m == mat_water:
			continue
		sim.set_cell(cell.x, cell.y, mat_fire)

## 登记活跃火格（由 executor 点火/爆炸/手动点火/喷油邻火触发）。
func register_fire_cell(x: int, y: int) -> void:
	if x < 0 or y < 0 or x >= WORLD_W or y >= WORLD_H:
		return
	if _tracked_fires.size() >= MAX_TRACKED_FIRES:
		return
	_tracked_fires[Vector2i(x, y)] = true

func active_fire_count() -> int:
	return _tracked_fires.size()

## 灰盒火焰补丁：追踪活跃火格（含上升 1 格跟随），以统一 1.5%/tick 点燃相邻非油可燃材质（煤/硫磺/竹木）。
## 仅在 active_rect 内演化（与 sim_core 休眠区语义一致）；返回本 tick 新点燃格数。
func tick_flammable_spread(active_rect: Rect2i) -> int:
	if not built or _tracked_fires.is_empty():
		return 0
	var tick: int = sim.get_tick()
	var has_bounds := active_rect.has_area()
	var mat_cap := _mat_flammable.size()
	var ignited := 0
	var next_tracked: Dictionary = {}
	var keys: Array = _tracked_fires.keys()
	for raw_cell in keys:
		var p: Vector2i = raw_cell
		if has_bounds and not active_rect.has_point(p):
			if next_tracked.size() < MAX_TRACKED_FIRES:
				next_tracked[p] = true
			continue
		var fp := _follow_fire_cell(p)
		if fp.x < 0:
			continue
		if next_tracked.size() < MAX_TRACKED_FIRES:
			next_tracked[fp] = true
		# 检查 4 邻域：跟随邻火（如油燃火锋）并按概率点燃非油可燃材质
		var nbs: Array[Vector2i] = [
			Vector2i(fp.x - 1, fp.y),
			Vector2i(fp.x + 1, fp.y),
			Vector2i(fp.x, fp.y - 1),
			Vector2i(fp.x, fp.y + 1),
		]
		for nb in nbs:
			if nb.x < 0 or nb.y < 0 or nb.x >= WORLD_W or nb.y >= WORLD_H:
				continue
			var nm: int = sim.get_cell(nb.x, nb.y)
			if nm == mat_fire:
				if not _fire_wall_set.has(nb) and next_tracked.size() < MAX_TRACKED_FIRES:
					next_tracked[nb] = true
				continue
			if nm > 0 and nm < mat_cap and _mat_flammable[nm]:
				if _spread_roll(nb.x, nb.y, tick):
					sim.set_cell(nb.x, nb.y, mat_fire)
					ignited += 1
					if next_tracked.size() < MAX_TRACKED_FIRES:
						next_tracked[nb] = true
	_tracked_fires = next_tracked
	return ignited

func _follow_fire_cell(p: Vector2i) -> Vector2i:
	if sim.get_cell(p.x, p.y) == mat_fire:
		return p
	# 火在 sim_core 中优先向上/左上/右上移动 1 格
	var ny := p.y - 1
	if ny >= 0:
		if sim.get_cell(p.x, ny) == mat_fire:
			return Vector2i(p.x, ny)
		if p.x > 0 and sim.get_cell(p.x - 1, ny) == mat_fire:
			return Vector2i(p.x - 1, ny)
		if p.x + 1 < WORLD_W and sim.get_cell(p.x + 1, ny) == mat_fire:
			return Vector2i(p.x + 1, ny)
	return Vector2i(-1, -1)

func _spread_roll(x: int, y: int, tick: int) -> bool:
	var h: int = ((x * 73856093) ^ (y * 19349663) ^ (tick * 83492791)) & 0xFFFFFF
	h = ((h * 2654435761) >> 12) & 0xFFFF
	return h < IGNITE_THRESHOLD

## 喷水灭火：对每个水格周围 DOUSE_RADIUS 的格子，火 -> 空；命中火墙源格则标记本局不再重燃。
## 返回被熄掉的火格数（HUD 的「灭火 N 格」）。
func douse_fire_around(water_cells: Array) -> int:
	var doused := 0
	var seen: Dictionary = {}
	var r := DOUSE_RADIUS
	var r2 := r * r
	for wc in water_cells:
		var c: Vector2i = wc
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dy * dy > r2:
					continue
				var cell := Vector2i(c.x + dx, c.y + dy)
				if seen.has(cell):
					continue
				seen[cell] = true
				if _fire_wall_set.has(cell):
					_doused[cell] = true
				_tracked_fires.erase(cell)
				var m: int = sim.get_cell(cell.x, cell.y)
				if m == mat_fire:
					sim.set_cell(cell.x, cell.y, mat_empty)
					doused += 1
	return doused

## 出口区：跨越出口走廊整个高度（y 260..276），玩家沿地板或天花板走到 x >= EXIT_CELL.x - EXIT_RADIUS 均通关。
func is_at_exit(cell: Vector2i) -> bool:
	return cell.x >= EXIT_CELL.x - EXIT_RADIUS and cell.y >= CORRIDOR_TOP and cell.y <= CORRIDOR_TOP + CORRIDOR_HEIGHT

## 火障附近（含被点燃的油槽）还有几个火格（smoke 用）。
func count_fire_near_barrier() -> int:
	var n := 0
	for y in range(FIRE_WALL_Y0 - 8, FIRE_WALL_Y1 + 12):
		for x in range(OIL_TRENCH_X0 - 8, OIL_TRENCH_X1 + 9):
			var m: int = sim.get_cell(x, y)
			if m == mat_fire:
				n += 1
	return n

## 火墙源格中当前是火的有几个（调试/自检用）。
func count_fire_wall() -> int:
	var n := 0
	for cell in fire_wall_cells:
		var m: int = sim.get_cell(cell.x, cell.y)
		if m == mat_fire:
			n += 1
	return n

# ------------------------------------------------------------------ 内部：材质 / 数据

func _cache_material_ids() -> void:
	if sim == null or not sim.has_world():
		return
	mat_empty = 0
	mat_rock = sim.material_id("rock")
	mat_water = sim.material_id("water")
	mat_oil = sim.material_id("oil")
	mat_fire = sim.material_id("fire")
	if mat_rock < 0 or mat_water < 0 or mat_oil < 0 or mat_fire < 0:
		push_error("T4B level: C-SIM 材质表缺少基础材质（需要 C-SIM v2）")
	_mat_flammable.clear()
	var count: int = sim.get_material_count()
	_mat_flammable.resize(count)
	for i in range(count):
		# 油已由 sim_core 以 5%/tick 点燃，这里只标记非油可燃材质（煤/硫磺/竹木）
		_mat_flammable[i] = (i != mat_oil) and sim.get_material_flammable(i)

func _data_path(rel_path: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(rel_path)

func _load_json(rel_path: String) -> Dictionary:
	var path := _data_path(rel_path)
	if not FileAccess.file_exists(path):
		push_error("T4B level: 找不到数据文件 " + path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("T4B level: 读不到 " + path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("T4B level: JSON 解析失败 " + path)
		return {}
	var parsed_dict: Dictionary = parsed
	return parsed_dict

# ------------------------------------------------------------------ 内部：摆放

## 房间 1:1 按 tile_size 展开：1 个 grid 字符 -> TILE x TILE 个 world cells。
## '#'(rock) 跳过（世界底已经是 rock，省 ~518k 次写）；empty 字符写 0（挖空）。
func _place_room(rel_path: String, offset: Vector2i) -> void:
	var data := _load_json(rel_path)
	if data.is_empty():
		return
	var grid: Array = data.get("grid", [])
	var legend: Dictionary = data.get("legend", {})
	for row in range(grid.size()):
		var line := String(grid[row])
		for col in range(line.length()):
			var ch := line.substr(col, 1)
			var mat_name := "empty"
			if legend.has(ch):
				mat_name = String(legend[ch])
			var id := mat_empty
			if not mat_name.is_empty() and mat_name != "empty":
				id = sim.material_id(mat_name)
				if id < 0:
					push_error("T4B level: 房间材质 %s 不在 C-SIM v2 材质表（%s 行 %d 列 %d），跳过该 tile" % [
						mat_name, rel_path, row, col
					])
					continue
				if id == mat_rock:
					continue
			var wx0 := offset.x + col * TILE
			var wy0 := offset.y + row * TILE
			for dy in range(TILE):
				for dx in range(TILE):
					sim.set_cell(wx0 + dx, wy0 + dy, id)

func _carve_rect(x0: int, y0: int, w: int, h: int) -> void:
	for y in range(y0, y0 + h):
		if y < 0 or y >= WORLD_H:
			continue
		for x in range(x0, x0 + w):
			if x < 0 or x >= WORLD_W:
				continue
			sim.set_cell(x, y, mat_empty)

func _build_fire_wall() -> void:
	for x in range(FIRE_WALL_X0, FIRE_WALL_X1 + 1):
		for y in range(FIRE_WALL_Y0, FIRE_WALL_Y1 + 1):
			var cell := Vector2i(x, y)
			sim.set_cell(x, y, mat_fire)
			fire_wall_cells.append(cell)
			_fire_wall_set[cell] = true
	# 油槽：走廊地板下 1 格深（两侧 x-1/x+1、底部 y+1 仍是岩层），含火墙正下方
	_carve_rect(OIL_TRENCH_X0, OIL_TRENCH_Y, OIL_TRENCH_X1 - OIL_TRENCH_X0 + 1, 1)
	for x in range(OIL_TRENCH_X0, OIL_TRENCH_X1 + 1):
		sim.set_cell(x, OIL_TRENCH_Y, mat_oil)
