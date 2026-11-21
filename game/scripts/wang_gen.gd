extends RefCounted
## M1-04 矿井一层完整 Wang Tile 程序化拓扑 + 手工房间拼接 + 连通性校验（D-M1-2 已定）。
## 对齐 data/biomes/level-01-coalmine.json 与 data/rooms/*.json：
## - 4×3 宏观网格 × (24×14 coarse tiles × 16 cells) = 1536×672 cells（约 8 屏可探索矿井）；
## - 4-bit 边色 Wang Tile（N=1 / E=2 / S=4 / W=8），相邻块共享边严格匹配；
## - 无缝拼接 3 个手工房间（room-02-gas-pocket / room-01-silver-pit / room-boss-coalmine）+ 入口安全区；
## - 粗格 BFS 自动校验起点 → 全部手工房 → 矿底 BOSS 房 → 出口 100% 连通，杜绝地形软锁。

const MACRO_COLS := 4
const MACRO_ROWS := 3
const ROOM_TILES_W := 24
const ROOM_TILES_H := 14
const TILE_SIZE := 16

const GRID_W := MACRO_COLS * ROOM_TILES_W   # 96 coarse tiles
const GRID_H := MACRO_ROWS * ROOM_TILES_H   # 42 coarse tiles
const WORLD_W := GRID_W * TILE_SIZE         # 1536 cells
const WORLD_H := GRID_H * TILE_SIZE         # 672 cells

const EDGE_N := 1
const EDGE_E := 2
const EDGE_S := 4
const EDGE_W := 8

const BIOME_PATH := "../data/biomes/level-01-coalmine.json"
const ROOM_PATHS := {
	"room-01-silver-pit": "../data/rooms/room-01-silver-pit.json",
	"room-02-gas-pocket": "../data/rooms/room-02-gas-pocket.json",
	"room-boss-coalmine": "../data/rooms/room-boss-coalmine.json",
}

# 生成产物（供 main.gd / stele.gd / combat / smoke 消费）
var seed_used: int = 0
var masks: Array[int] = []                  # MACRO_COLS * MACRO_ROWS 的 4-bit Wang 边掩码
var macro_roles: Array[String] = []         # 每个宏观格的角色（hub_entry / room-xx / wang）
var tile_grid: PackedStringArray = PackedStringArray()  # GRID_W * GRID_H 的材质名
var tile_is_handcrafted: PackedByteArray = PackedByteArray()

var safe_zone_rect: Rect2i = Rect2i(0, 0, 384, 224)
var start_cell: Vector2i = Vector2i(80, 170)
var exit_cell: Vector2i = Vector2i(1480, 620)
var room_anchors: Dictionary = {}           # room_id -> Vector2i (coarse tile center)
var steles: Array[Dictionary] = []          # [{id, pos: Vector2i, rule_id, text_key}]
var spawn_anchors: Array[Dictionary] = []   # [{id, pos: Vector2i, table, boss_id, count}]
var biome_data: Dictionary = {}

var _rng_state: int = 1

# ------------------------------------------------------------------ 对外接口

## 仅在内存中生成 4×3 Wang 拓扑 + 粗格拼接（支持快速多 seed 连通性压测，不依赖写满百万像素）。
func generate_layout(p_seed: int) -> Dictionary:
	seed_used = p_seed
	_rng_state = (p_seed ^ 0x5DEECE66D) & 0x7FFFFFFF
	if _rng_state == 0:
		_rng_state = 1337
	biome_data = _load_json(BIOME_PATH)

	masks.clear()
	masks.resize(MACRO_COLS * MACRO_ROWS)
	masks.fill(0)
	macro_roles.clear()
	macro_roles.resize(MACRO_COLS * MACRO_ROWS)
	macro_roles.fill("wang")

	tile_grid.resize(GRID_W * GRID_H)
	tile_is_handcrafted.resize(GRID_W * GRID_H)
	for i in range(GRID_W * GRID_H):
		tile_grid[i] = "rock"
		tile_is_handcrafted[i] = 0

	room_anchors.clear()
	steles.clear()
	spawn_anchors.clear()

	# 1) 生成严格边匹配的 4-bit Wang 宏观拓扑（生成树 + 环路）
	_build_wang_topology()

	# 2) 分配角色：(0,0)=洞天入口安全区，(3,2)=矿底 BOSS 房，选早/中段两格拼手工房
	macro_roles[_macro_idx(0, 0)] = "hub_entry"
	macro_roles[_macro_idx(MACRO_COLS - 1, MACRO_ROWS - 1)] = "room-boss-coalmine"
	var early_candidates: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1)]
	var early_slot: Vector2i = early_candidates[_rand_int(early_candidates.size())]
	macro_roles[_macro_idx(early_slot.x, early_slot.y)] = "room-02-gas-pocket"
	var mid_candidates: Array[Vector2i] = [Vector2i(2, 0), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
	var mid_slot: Vector2i = mid_candidates[_rand_int(mid_candidates.size())]
	macro_roles[_macro_idx(mid_slot.x, mid_slot.y)] = "room-01-silver-pit"

	# 3) 按角色填充全部 12 块（手工房 1:1 拼接 + 其余 8 块按 Wang mask 生成程序化矿道）
	for mr in range(MACRO_ROWS):
		for mc in range(MACRO_COLS):
			var idx := _macro_idx(mc, mr)
			var role: String = macro_roles[idx]
			var mask: int = masks[idx]
			if role == "hub_entry":
				_build_hub_entry(mc, mr, mask)
			elif ROOM_PATHS.has(role):
				_splice_handcrafted_room(mc, mr, role, String(ROOM_PATHS[role]), mask)
			else:
				_build_wang_cavern(mc, mr, mask, _rand_int(3))

	# 4) 补洞天入口规矩碑文与校验连通性
	return verify_connectivity()

## 把已生成的 96×42 粗格写入 SimWorldNode（1536×672 cells；程序化矿壁带 2 格有机粗糙度）。
func rasterize_to_sim(sim: SimWorldNode) -> int:
	if sim == null or not sim.has_world():
		return 0
	var t0 := Time.get_ticks_msec()
	var mat_cache: Dictionary = {"empty": 0}
	for name_str in ["rock", "water", "coal", "saltpeter", "sulfur", "cinnabar",
			"lime", "glutinous_rice", "bamboo", "yin_qi", "quicksilver", "black_dog_blood", "sand", "oil", "fire"]:
		mat_cache[name_str] = sim.material_id(name_str)
	var rock_id: int = int(mat_cache.get("rock", 1))

	for ty in range(GRID_H):
		var wy0 := ty * TILE_SIZE
		for tx in range(GRID_W):
			var idx := ty * GRID_W + tx
			var mat_name: String = tile_grid[idx]
			var mid: int = int(mat_cache.get(mat_name, 0))
			var wx0 := tx * TILE_SIZE
			if mid == 0:
				continue
			var is_hc: bool = tile_is_handcrafted[idx] == 1
			if is_hc or mat_name != "rock":
				for dy in range(TILE_SIZE):
					for dx in range(TILE_SIZE):
						sim.set_cell(wx0 + dx, wy0 + dy, mid)
			else:
				# 程序化岩壁：与空格接壤的 2 格边缘做确定性微锯齿，去除生硬方块感
				var open_n := ty > 0 and tile_grid[(ty - 1) * GRID_W + tx] == "empty"
				var open_s := ty + 1 < GRID_H and tile_grid[(ty + 1) * GRID_W + tx] == "empty"
				var open_w := tx > 0 and tile_grid[ty * GRID_W + (tx - 1)] == "empty"
				var open_e := tx + 1 < GRID_W and tile_grid[ty * GRID_W + (tx + 1)] == "empty"
				for dy in range(TILE_SIZE):
					for dx in range(TILE_SIZE):
						var wx := wx0 + dx
						var wy := wy0 + dy
						var near_edge := (
							(open_n and dy < 2) or (open_s and dy >= TILE_SIZE - 2)
							or (open_w and dx < 2) or (open_e and dx >= TILE_SIZE - 2)
						)
						if near_edge and (_hash2(wx, wy) & 3) == 0:
							continue
						sim.set_cell(wx, wy, rock_id)

	var ms := Time.get_ticks_msec() - t0
	print("M1_WANG_RASTERIZED seed=%d size=%dx%d ms=%d steles=%d anchors=%d" % [
		seed_used, WORLD_W, WORLD_H, ms, steles.size(), spawn_anchors.size()
	])
	return ms

## 开局全图预沉降：光栅化后一次性让悬空液体与粉末自然落底摊平，避免玩家走近才「现加载」把敌人活埋。
func settle_world(sim: SimWorldNode, ticks: int = 120) -> int:
	if sim == null or not sim.has_world() or ticks <= 0:
		return 0
	var t0 := Time.get_ticks_msec()
	sim.set_active_rect(0, 0, WORLD_W, WORLD_H)
	sim.wake_rect(0, 0, WORLD_W, WORLD_H)
	sim.step_ticks(ticks)
	# 清空预沉降期间产生的零星事件，避免开局首帧刷屏 HUD
	for _i in range(4):
		if sim.poll_events(1024).is_empty():
			break
	var ms := Time.get_ticks_msec() - t0
	print("M1_WANG_SETTLED ticks=%d ms=%d" % [ticks, ms])
	return ms

## 预沉降后校准实体/石碑位置：自动脱出任何沉积粉末或岩壁并贴地站稳，杜绝被埋。
func find_safe_stand_pos(sim: SimWorldNode, origin: Vector2i, half_w: int = 3, height: int = 12) -> Vector2i:
	if sim == null or not sim.has_world():
		return origin
	var w := sim.get_world_width()
	var h := sim.get_world_height()
	for dx_off in [0, -10, 10, -20, 20, -32, 32]:
		var cx := clampi(origin.x + dx_off, half_w + 2, w - half_w - 3)
		var y := clampi(origin.y, height + 2, h - 4)
		for _up in range(80):
			if _box_clear(sim, cx, y, half_w, height):
				break
			y -= 2
			if y <= height + 2:
				break
		if not _box_clear(sim, cx, y, half_w, height):
			continue
		for _dn in range(60):
			if y + 1 >= h - 2 or sim.is_solid(cx, y + 1):
				break
			if not _box_clear(sim, cx, y + 1, half_w, height):
				break
			y += 1
		return Vector2i(cx, y)
	return origin

func _box_clear(sim: SimWorldNode, cx: int, cy: int, half_w: int, height: int) -> bool:
	for gy in range(cy - height + 1, cy + 1):
		for gx in range(cx - half_w, cx + half_w + 1):
			if sim.is_solid(gx, gy):
				return false
	return true

## 粗格 BFS 连通性校验 + Wang 边严格匹配校验。
func verify_connectivity() -> Dictionary:
	# 1) 检查所有相邻宏观块共享边是否严格对称
	var edge_mismatches := 0
	for mr in range(MACRO_ROWS):
		for mc in range(MACRO_COLS):
			var m: int = masks[_macro_idx(mc, mr)]
			if mc + 1 < MACRO_COLS:
				var mr_mask: int = masks[_macro_idx(mc + 1, mr)]
				if ((m & EDGE_E) != 0) != ((mr_mask & EDGE_W) != 0):
					edge_mismatches += 1
			if mr + 1 < MACRO_ROWS:
				var mb_mask: int = masks[_macro_idx(mc, mr + 1)]
				if ((m & EDGE_S) != 0) != ((mb_mask & EDGE_N) != 0):
					edge_mismatches += 1

	# 2) 从起点粗格做 4 邻域 BFS（所有非 rock/bamboo 视为可通行或可涉水）
	var start_t := Vector2i(start_cell.x / TILE_SIZE, start_cell.y / TILE_SIZE)
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(GRID_W * GRID_H)
	visited.fill(0)
	var queue: Array[Vector2i] = []
	if _is_walkable_tile(start_t.x, start_t.y):
		visited[start_t.y * GRID_W + start_t.x] = 1
		queue.append(start_t)
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			if nx < 0 or ny < 0 or nx >= GRID_W or ny >= GRID_H:
				continue
			var nidx := ny * GRID_W + nx
			if visited[nidx] != 0:
				continue
			if _is_walkable_tile(nx, ny):
				visited[nidx] = 1
				queue.append(Vector2i(nx, ny))

	var reachable_rooms: Array[String] = []
	var missing: Array[String] = []
	for key_raw in room_anchors.keys():
		var rid := String(key_raw)
		var anchor: Vector2i = room_anchors[rid]
		var found := false
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var tx := clampi(anchor.x + dx, 0, GRID_W - 1)
				var ty := clampi(anchor.y + dy, 0, GRID_H - 1)
				if visited[ty * GRID_W + tx] != 0:
					found = true
					break
			if found:
				break
		if found:
			reachable_rooms.append(rid)
		else:
			missing.append(rid)

	# 校验出口格可达
	var exit_t := Vector2i(exit_cell.x / TILE_SIZE, exit_cell.y / TILE_SIZE)
	var exit_ok := visited[clampi(exit_t.y, 0, GRID_H - 1) * GRID_W + clampi(exit_t.x, 0, GRID_W - 1)] != 0
	if not exit_ok:
		missing.append("exit")

	# 校验全部 12 块宏观区域均可达
	var reachable_macros := 0
	for mr in range(MACRO_ROWS):
		for mc in range(MACRO_COLS):
			var macro_hit := false
			for ly in range(1, ROOM_TILES_H - 1):
				for lx in range(1, ROOM_TILES_W - 1):
					if visited[(mr * ROOM_TILES_H + ly) * GRID_W + (mc * ROOM_TILES_W + lx)] != 0:
						macro_hit = true
						break
				if macro_hit:
					break
			if macro_hit:
				reachable_macros += 1

	return {
		"connected": edge_mismatches == 0 and missing.is_empty() and reachable_macros == MACRO_COLS * MACRO_ROWS,
		"edge_mismatches": edge_mismatches,
		"visited_tiles": queue.size(),
		"reachable_macros": reachable_macros,
		"total_macros": MACRO_COLS * MACRO_ROWS,
		"reachable_rooms": reachable_rooms,
		"missing": missing,
	}

func is_in_safe_zone(cell: Vector2i) -> bool:
	return safe_zone_rect.has_point(cell)

func is_at_exit(cell: Vector2i) -> bool:
	return abs(cell.x - exit_cell.x) <= 20 and abs(cell.y - exit_cell.y) <= 24

# ------------------------------------------------------------------ 宏观 Wang 拓扑

func _build_wang_topology() -> void:
	# 1) 随机 DFS 生成树，保证全部 12 块单连通
	var visited: Array[bool] = []
	visited.resize(MACRO_COLS * MACRO_ROWS)
	visited.fill(false)
	var stack: Array[Vector2i] = [Vector2i(0, 0)]
	visited[0] = true
	while not stack.is_empty():
		var cur: Vector2i = stack[stack.size() - 1]
		var nbrs: Array[Vector2i] = []
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			if nx >= 0 and ny >= 0 and nx < MACRO_COLS and ny < MACRO_ROWS:
				if not visited[_macro_idx(nx, ny)]:
					nbrs.append(Vector2i(nx, ny))
		if nbrs.is_empty():
			stack.pop_back()
		else:
			var nxt: Vector2i = nbrs[_rand_int(nbrs.size())]
			_connect_macros(cur, nxt)
			visited[_macro_idx(nxt.x, nxt.y)] = true
			stack.append(nxt)

	# 2) 追加 3 条环路边，让矿井有上下竖井 + 平行巷道，不沦为单行线
	for _k in range(3):
		var mc := _rand_int(MACRO_COLS)
		var mr := _rand_int(MACRO_ROWS)
		if _rand_int(2) == 0 and mc + 1 < MACRO_COLS:
			_connect_macros(Vector2i(mc, mr), Vector2i(mc + 1, mr))
		elif mr + 1 < MACRO_ROWS:
			_connect_macros(Vector2i(mc, mr), Vector2i(mc, mr + 1))

func _connect_macros(a: Vector2i, b: Vector2i) -> void:
	var ia := _macro_idx(a.x, a.y)
	var ib := _macro_idx(b.x, b.y)
	if b.x == a.x + 1 and b.y == a.y:
		masks[ia] |= EDGE_E
		masks[ib] |= EDGE_W
	elif b.x == a.x - 1 and b.y == a.y:
		masks[ia] |= EDGE_W
		masks[ib] |= EDGE_E
	elif b.y == a.y + 1 and b.x == a.x:
		masks[ia] |= EDGE_S
		masks[ib] |= EDGE_N
	elif b.y == a.y - 1 and b.x == a.x:
		masks[ia] |= EDGE_N
		masks[ib] |= EDGE_S

# ------------------------------------------------------------------ 洞天入口安全区 (0, 0)

func _build_hub_entry(mc: int, mr: int, mask: int) -> void:
	var ox := mc * ROOM_TILES_W
	var oy := mr * ROOM_TILES_H
	safe_zone_rect = Rect2i(ox * TILE_SIZE, oy * TILE_SIZE, ROOM_TILES_W * TILE_SIZE, ROOM_TILES_H * TILE_SIZE)
	for ly in range(2, ROOM_TILES_H - 2):
		for lx in range(2, ROOM_TILES_W - 2):
			_set_tile(ox + lx, oy + ly, "empty", true)
	# 安全蓄水池（左下角石槽内，便于开局葫芦取水且不外溢）
	for lx in range(3, 7):
		_set_tile(ox + lx, oy + ROOM_TILES_H - 2, "water", true)
	# 竹木台阶
	for lx in range(15, 19):
		_set_tile(ox + lx, oy + 9, "bamboo", true)
	_carve_doorways(ox, oy, mask, true)
	# 起点与开局石碑置于实心岩地板上（避开 cols 10..13 竖井口）
	start_cell = Vector2i((ox + 8) * TILE_SIZE + 8, (oy + ROOM_TILES_H - 3) * TILE_SIZE + 14)
	room_anchors["hub_entry"] = Vector2i(ox + 12, oy + 7)
	steles.append({
		"id": "stele-hub-entry",
		"pos": Vector2i((ox + 9) * TILE_SIZE + 8, (oy + ROOM_TILES_H - 3) * TILE_SIZE + 14),
		"rule_id": "no-open-flame",
		"text_key": "$rule_no_open_flame",
	})

# ------------------------------------------------------------------ 手工房间无缝拼接

func _splice_handcrafted_room(mc: int, mr: int, room_id: String, rel_path: String, mask: int) -> void:
	var data := _load_json(rel_path)
	var ox := mc * ROOM_TILES_W
	var oy := mr * ROOM_TILES_H
	if data.is_empty():
		_build_wang_cavern(mc, mr, mask, 0)
		return
	var grid: Array = data.get("grid", [])
	var legend: Dictionary = data.get("legend", {})
	for row in range(mini(grid.size(), ROOM_TILES_H)):
		var line := String(grid[row])
		for col in range(mini(line.length(), ROOM_TILES_W)):
			var ch := line.substr(col, 1)
			var mat := String(legend.get(ch, "empty"))
			_set_tile(ox + col, oy + row, mat, true)
	# 按 Wang mask 切开精确门洞与 2 格过渡喉道，无缝接入矿道网络
	_carve_doorways(ox, oy, mask, true)
	room_anchors[room_id] = Vector2i(ox + ROOM_TILES_W / 2, oy + ROOM_TILES_H / 2)

	# 翻译房间实体坐标到世界像素（cell）
	for raw_e in data.get("entities", []):
		if not (raw_e is Dictionary):
			continue
		var e: Dictionary = raw_e
		var etype := String(e.get("type", ""))
		var ex: int = ox + int(e.get("x", 12))
		var ey: int = oy + int(e.get("y", 7))
		var world_pos := Vector2i(ex * TILE_SIZE + 8, ey * TILE_SIZE + 14)
		var payload: Dictionary = e.get("payload", {}) if e.get("payload") is Dictionary else {}
		if etype == "rule_stele":
			var rid := String(payload.get("rule_id", "no-open-flame"))
			var tk := "$rule_" + rid.replace("-", "_")
			steles.append({
				"id": String(e.get("id", room_id + "_stele")),
				"pos": world_pos,
				"rule_id": rid,
				"text_key": tk,
			})
		elif etype == "spawn_anchor":
			spawn_anchors.append({
				"id": String(e.get("id", room_id + "_spawn")),
				"pos": world_pos,
				"table": String(payload.get("table", "mobs")),
				"boss_id": String(payload.get("boss_id", "")),
				"count": int(payload.get("count", 1)),
			})
		elif etype == "exit" and room_id == "room-boss-coalmine":
			exit_cell = world_pos

# ------------------------------------------------------------------ 16-Mask 程序化 Wang 矿道

func _build_wang_cavern(mc: int, mr: int, mask: int, variant: int) -> void:
	var ox := mc * ROOM_TILES_W
	var oy := mr * ROOM_TILES_H
	# 1) 按 variant 挖出自然洞室主体
	var cx := 12
	var cy := 7
	var rx := 8.5 if variant == 0 else (9.5 if variant == 1 else 7.5)
	var ry := 4.6 if variant == 0 else (4.0 if variant == 1 else 5.2)
	for ly in range(1, ROOM_TILES_H - 1):
		for lx in range(1, ROOM_TILES_W - 1):
			var dx := float(lx - cx) / rx
			var dy := float(ly - cy) / ry
			var jitter := float((_hash2(ox + lx, oy + ly) & 15) - 7) * 0.028
			if dx * dx + dy * dy + jitter < 1.0:
				_set_tile(ox + lx, oy + ly, "empty", false)

	# 2) 按 4-bit Wang 掩码挖出贯通中心与各开口边的通道
	_carve_doorways(ox, oy, mask, false)

	# 3) 洞内特色结构（矿井竹木支架 / 中央岩柱 / 矿脉 / 小水洼）
	if variant == 1 and (mask & (EDGE_N | EDGE_S)) != 0:
		# 竖井中部架设竹木踏板（可站立、可纵火烧成炭）
		for lx in range(9, 15):
			_set_tile(ox + lx, oy + 7, "bamboo", false)
	elif variant == 2:
		# 洞底小型聚水或煤堆
		for lx in range(8, 12):
			if _get_tile(ox + lx, oy + 11) == "empty":
				_set_tile(ox + lx, oy + 11, "water" if _rand_int(2) == 0 else "coal", false)
	else:
		# 竹木支护横梁
		for lx in range(6, 10):
			if _get_tile(ox + lx, oy + 9) == "empty":
				_set_tile(ox + lx, oy + 9, "bamboo", false)

	# 4) 沿岩壁随机镶嵌生物群系矿脉（严按 level-01-coalmine.json theme.palette 权重）
	for ly in range(1, ROOM_TILES_H - 1):
		for lx in range(1, ROOM_TILES_W - 1):
			var gx := ox + lx
			var gy := oy + ly
			if _get_tile(gx, gy) != "rock":
				continue
			if not _has_empty_neighbor(gx, gy):
				continue
			var roll := _rand_int(100)
			if roll < 14:
				_set_tile(gx, gy, "coal", false)
			elif roll < 21:
				_set_tile(gx, gy, "saltpeter", false)
			elif roll < 25:
				_set_tile(gx, gy, "sulfur", false)
			elif roll < 28:
				_set_tile(gx, gy, "cinnabar", false)
			elif roll < 30:
				_set_tile(gx, gy, "lime", false)

	# 5) 刷怪锚点（每块 0–1 个，给 M1-06 与当前靶标复用）
	if _rand_int(100) < 75:
		var floor_y := _find_open_floor_y(ox + 12, oy + 5, oy + ROOM_TILES_H - 2)
		spawn_anchors.append({
			"id": "wang_spawn_%d_%d" % [mc, mr],
			"pos": Vector2i((ox + 12) * TILE_SIZE + 8, floor_y * TILE_SIZE + 14),
			"table": "mobs",
			"boss_id": "",
			"count": 1,
		})

	# 6) 偶发假规矩碑文（让矿道探索有叙事线索，对应 level-01-coalmine.json rules）
	if mc == 2 and mr == 0:
		var sy := _find_open_floor_y(ox + 10, oy + 5, oy + ROOM_TILES_H - 2)
		steles.append({
			"id": "stele-wang-return",
			"pos": Vector2i((ox + 10) * TILE_SIZE + 8, sy * TILE_SIZE + 14),
			"rule_id": "do-not-call-return",
			"text_key": "$rule_do_not_call_return",
		})

func _carve_doorways(ox: int, oy: int, mask: int, hc: bool) -> void:
	# 中心安全汇合区（确保 4 个方向的通道在房间内部必定彼此汇通）
	if not hc:
		for ly in range(5, 10):
			for lx in range(9, 15):
				_set_tile(ox + lx, oy + ly, "empty", false)
	if (mask & EDGE_W) != 0:
		var span := 4 if hc else 12
		for lx in range(0, span):
			for ly in range(6, 9):
				_set_tile(ox + lx, oy + ly, "empty", hc)
	if (mask & EDGE_E) != 0:
		var start_x := ROOM_TILES_W - 4 if hc else 12
		for lx in range(start_x, ROOM_TILES_W):
			for ly in range(6, 9):
				_set_tile(ox + lx, oy + ly, "empty", hc)
	if (mask & EDGE_N) != 0:
		var span_y := 3 if hc else 7
		for ly in range(0, span_y):
			for lx in range(10, 14):
				_set_tile(ox + lx, oy + ly, "empty", hc)
	if (mask & EDGE_S) != 0:
		var start_y := ROOM_TILES_H - 3 if hc else 7
		for ly in range(start_y, ROOM_TILES_H):
			for lx in range(10, 14):
				_set_tile(ox + lx, oy + ly, "empty", hc)

# ------------------------------------------------------------------ 内部工具

func _macro_idx(mc: int, mr: int) -> int:
	return mr * MACRO_COLS + mc

func _set_tile(gx: int, gy: int, mat: String, hc: bool) -> void:
	if gx < 0 or gy < 0 or gx >= GRID_W or gy >= GRID_H:
		return
	var idx := gy * GRID_W + gx
	tile_grid[idx] = mat
	tile_is_handcrafted[idx] = 1 if hc else 0

func _get_tile(gx: int, gy: int) -> String:
	if gx < 0 or gy < 0 or gx >= GRID_W or gy >= GRID_H:
		return "rock"
	return tile_grid[gy * GRID_W + gx]

func _is_walkable_tile(gx: int, gy: int) -> bool:
	var m := _get_tile(gx, gy)
	return m != "rock" and m != "bamboo"

func _has_empty_neighbor(gx: int, gy: int) -> bool:
	return (
		_get_tile(gx - 1, gy) == "empty" or _get_tile(gx + 1, gy) == "empty"
		or _get_tile(gx, gy - 1) == "empty" or _get_tile(gx, gy + 1) == "empty"
	)

func _find_open_floor_y(gx: int, y_from: int, y_to: int) -> int:
	var best := y_from
	for y in range(y_from, y_to):
		if _get_tile(gx, y) == "empty":
			best = y
	return best

func _rand_int(bound: int) -> int:
	if bound <= 1:
		return 0
	_rng_state = (_rng_state * 1103515245 + 12345) & 0x7FFFFFFF
	return (_rng_state >> 8) % bound

func _hash2(x: int, y: int) -> int:
	var h: int = (x * 73856093) ^ (y * 19349663) ^ (seed_used * 83492791)
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return h

func _load_json(rel_path: String) -> Dictionary:
	var path := ProjectSettings.globalize_path("res://").path_join(rel_path)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		var d: Dictionary = parsed
		return d
	return {}
