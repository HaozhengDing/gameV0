extends SceneTree
## T4a 无界面自检：验证 GDExtension 加载成功、C-SIM 接口可用、同 seed 确定性、渲染与挖掘可用。
## 运行：<godot> --headless --path game --script res://tests/smoke_sim.gd

func _initialize() -> void:
	if not ClassDB.class_exists("SimWorldNode"):
		push_error("SMOKE_FAIL: SimWorldNode 未注册（GDExtension 没加载）")
		quit(1)
		return

	var sim: SimWorldNode = SimWorldNode.new()
	if not sim.create_world(120, 80, 12345, ""):
		push_error("SMOKE_FAIL: create_world 失败")
		quit(1)
		return
	# 稳定物质：一层沙、一层水
	for x in range(20, 100):
		sim.set_cell_by_name(x, 10, "sand")
		sim.set_cell_by_name(x, 30, "water")
	# 稳定岩块（用于挖掘断言；岩是 static，600 tick 不会动）
	for x in range(2, 26):
		for y in range(60, 72):
			sim.set_cell_by_name(x, y, "rock")
	for i in range(600):
		sim.step_tick()
	var hash1: int = sim.get_state_hash()

	# 确定性：同参数、同操作序列的第二个世界，600 tick 后 hash 必须相同
	var sim2: SimWorldNode = SimWorldNode.new()
	sim2.create_world(120, 80, 12345, "")
	for x in range(20, 100):
		sim2.set_cell_by_name(x, 10, "sand")
		sim2.set_cell_by_name(x, 30, "water")
	for x in range(2, 26):
		for y in range(60, 72):
			sim2.set_cell_by_name(x, y, "rock")
	for i in range(600):
		sim2.step_tick()
	var hash2: int = sim2.get_state_hash()

	var img: Image = sim.render_image()
	var ok_image: bool = img != null and img.get_width() == 120 and img.get_height() == 80
	var dig_count: int = sim.dig(12, 66, 3)
	var tick_ok: bool = sim.get_tick() == 600

	sim.free()
	sim2.free()

	var ok: bool = hash1 == hash2 and ok_image and tick_ok and dig_count > 0
	if not ok:
		push_error("SMOKE_FAIL: hash1=%d hash2=%d image=%s tick_ok=%s dig=%d" % [
			hash1, hash2, str(ok_image), str(tick_ok), dig_count
		])
		quit(1)
		return
	print("SMOKE_OK hash=%d image=%dx%d dig=%d ticks=%d materials=%s" % [
		hash1, img.get_width(), img.get_height(), dig_count, 600, "builtin"
	])
	quit(0)
