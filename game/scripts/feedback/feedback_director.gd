extends Node
## M1-10 反馈导演：把 C-EVT 事件翻译成打击感六层
##   1 火光（fx.muzzle）2 后坐力（player.add_recoil）3 定向震屏（Camera2D.offset）
##   4 命中（闪白/火花/顿帧/飘字）5 击杀（更大顿帧/爆散/击飞）6 分层音效（sfx）
## 纯表现层：只读事件，不改玩法数值；参数表见 docs/tech/m1-feedback-juice.md。

const HEADLESS_NAME := "headless"
const HITSTOP_HIT := 0.030
const HITSTOP_KILL := 0.060
const HITSTOP_HURT := 0.045
const HITSTOP_BOOM := 0.055
const HITSTOP_SCALE := 0.06

const SHAKE_FIRE := 2.2
const SHAKE_HIT := 1.3
const SHAKE_KILL := 3.4
const SHAKE_HURT := 3.8

var enabled := true
var headless := false
var event_bus
var camera: Camera2D
var player
var fx
var screen
var sfx

var _hitstop_until_us := 0
var _shake_dir := Vector2.ZERO
var _shake_amp := 0.0
var _shake_dur := 0.001
var _shake_left := 0.0
var _casing_due_us := 0
var _last_us := 0

func setup(p_bus, p_camera: Camera2D, p_player, p_fx, p_screen, p_sfx) -> void:
	event_bus = p_bus
	camera = p_camera
	player = p_player
	fx = p_fx
	screen = p_screen
	sfx = p_sfx
	headless = DisplayServer.get_name() == HEADLESS_NAME
	_last_us = Time.get_ticks_usec()
	if event_bus != null and event_bus.has_method("subscribe"):
		event_bus.subscribe(Callable(self, "on_event"))
	set_process(true)

func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := float(now - _last_us) / 1000000.0
	_last_us = now
	if dt <= 0.0 or dt > 0.5:
		dt = 1.0 / 60.0

	if _hitstop_until_us > 0 and now >= _hitstop_until_us:
		_hitstop_until_us = 0
		Engine.time_scale = 1.0

	if _casing_due_us > 0 and now >= _casing_due_us:
		_casing_due_us = 0
		if sfx != null:
			sfx.play("casing", randf_range(0.95, 1.15), -14.0)

	if camera != null and _shake_left > 0.0:
		_shake_left = maxf(_shake_left - dt, 0.0)
		var k: float = _shake_left / maxf(_shake_dur, 0.001)
		var jitter := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * 0.4
		camera.offset = (_shake_dir + jitter) * _shake_amp * k
		if _shake_left <= 0.0:
			camera.offset = Vector2.ZERO

	if fx != null and fx.has_method("update_fx"):
		fx.update_fx(delta)
	if screen != null and screen.has_method("tick"):
		screen.tick(delta)

# ------------------------------------------------------------------ 输入

## 第 1/2/3 层：施法瞬间 —— 火光、人物后坐、镜头沿反弹方向一记。
func on_cast(origin_cell: Vector2, aim_cell: Vector2, power: float, col: Color) -> void:
	if not enabled:
		return
	var dir := aim_cell - origin_cell
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var hand := origin_cell + Vector2(0.0, -4.0)
	if fx != null and fx.has_method("muzzle"):
		fx.muzzle(hand, dir, power, col)
	_shake(-dir, SHAKE_FIRE * (0.8 + 0.5 * power), 0.10)
	if player != null and player.has_method("add_recoil"):
		player.add_recoil(-dir * (2.0 + 2.5 * power) * 4.0)
	if sfx != null:
		sfx.play("fire", randf_range(0.94, 1.06), -5.0)
		_casing_due_us = Time.get_ticks_usec() + 45000

## 订阅 C-EVT：命中 / 击杀 / 熄灯 / 反噬 / 反应。
func on_event(ev: Dictionary) -> void:
	if not enabled or ev.is_empty():
		return
	var etype := String(ev.get("type", ""))
	var pos := _as_vec2(ev.get("pos", Vector2i(-1, -1)))
	var tid := String(ev.get("target_id", ""))
	var val := float(ev.get("value", 0.0))
	match etype:
		"entity_damaged":
			if tid == "player":
				_player_hurt(val, String(ev.get("source_id", "")))
			else:
				_hit(pos, val, String(ev.get("damage_type", "")))
		"entity_killed":
			if tid == "player":
				_player_death()
			else:
				_kill(pos, String(ev.get("damage_type", "")))
		"lantern_extinguished":
			_lantern_out()
		"backlash_triggered":
			_backlash()
		"reaction_triggered":
			if fx != null and fx.has_method("reaction_ring"):
				fx.reaction_ring(pos, 3.0, _reaction_color(String(ev.get("reaction_id", ""))))
		"spell_fizzle":
			if sfx != null:
				sfx.play("fizzle", randf_range(0.9, 1.05), -12.0)

func _exit_tree() -> void:
	shutdown()

## 断开 event_bus -> Callable -> self 的环形引用并复位 time_scale（退出 / 重开时调用）。
func shutdown() -> void:
	Engine.time_scale = 1.0
	if event_bus != null and event_bus.has_method("unsubscribe"):
		event_bus.unsubscribe(Callable(self, "on_event"))
	event_bus = null
	_shake_left = 0.0
	_casing_due_us = 0

func reset() -> void:
	Engine.time_scale = 1.0
	_hitstop_until_us = 0
	_shake_left = 0.0
	_shake_amp = 0.0
	_casing_due_us = 0
	if camera != null:
		camera.offset = Vector2.ZERO
	if fx != null and fx.has_method("clear_all"):
		fx.clear_all()
	if screen != null and screen.has_method("clear_all"):
		screen.clear_all()

# ------------------------------------------------------------------ 第 4/5 层

func _hit(pos: Vector2, amount: float, dtype: String) -> void:
	var col := _type_color(dtype)
	var dir := _dir_from_player(pos)
	if fx != null and fx.has_method("impact"):
		fx.impact(pos, dir, amount, col, false)
	if screen != null and screen.has_method("flash"):
		screen.flash(col, 0.10 + clampf(amount / 60.0, 0.0, 0.10), 0.05)
	_shake(dir, SHAKE_HIT, 0.07)
	_hitstop(HITSTOP_HIT)
	if sfx != null:
		sfx.play("hit", randf_range(0.92, 1.08), -6.0)

func _kill(pos: Vector2, dtype: String) -> void:
	var col := _type_color(dtype)
	var dir := _dir_from_player(pos)
	if fx != null and fx.has_method("impact"):
		fx.impact(pos, dir, 0.0, col, true)
	if screen != null and screen.has_method("flash"):
		screen.flash(Color(1.0, 0.96, 0.88), 0.16, 0.09)
	_shake(dir, SHAKE_KILL, 0.16)
	_hitstop(HITSTOP_KILL)
	if sfx != null:
		sfx.play("kill", randf_range(0.95, 1.05), -3.0)

func _player_hurt(amount: float, source_id: String = "") -> void:
	# 火/灼烧/毒烟/蒸汽等环境持续伤（DoT）只给轻红晕与微震，不触发全局顿帧（防止在火/毒云中移动卡顿）
	var is_dot := source_id in ["火伤", "灼烧", "burning", "毒烟", "toxic_smoke", "蒸汽", "steam"]
	if is_dot:
		if screen != null and screen.has_method("hurt"):
			screen.hurt(0.16)
		_shake(Vector2.DOWN, SHAKE_HURT * 0.22, 0.08)
		return
	if screen != null and screen.has_method("hurt"):
		screen.hurt(clampf(0.25 + amount / 40.0, 0.25, 0.55))
	_shake(Vector2.DOWN, SHAKE_HURT, 0.20)
	_hitstop(HITSTOP_HURT)
	if sfx != null:
		sfx.play("hit", randf_range(0.7, 0.8), -2.0)

func _player_death() -> void:
	if screen != null:
		if screen.has_method("hurt"):
			screen.hurt(0.55)
		if screen.has_method("flash"):
			screen.flash(Color(0.80, 0.10, 0.10), 0.24, 0.20)
	_shake(Vector2.DOWN, 5.0, 0.35)
	if sfx != null:
		sfx.play("backlash", 0.8, 0.0)

## 阴伤熄灯：冷色一闪 + 低频（与「阴性伤害直接熄灯」的规则一一对应）。
func _lantern_out() -> void:
	if screen != null and screen.has_method("flash"):
		screen.flash(Color(0.55, 0.72, 1.0), 0.18, 0.14)
	_shake(Vector2.DOWN, 2.0, 0.18)
	if sfx != null:
		sfx.play("lantern", randf_range(0.95, 1.05), -4.0)

## 禁符反噬：紫闪 + 强震 + 顿帧（D3 唯一会扣神智的施法，必须最疼）。
func _backlash() -> void:
	if screen != null and screen.has_method("flash"):
		screen.flash(Color(0.66, 0.42, 1.0), 0.26, 0.12)
	_shake(Vector2.UP, 4.6, 0.30)
	_hitstop(HITSTOP_BOOM)
	if sfx != null:
		sfx.play("backlash", 1.0, -1.0)

# ------------------------------------------------------------------ 工具

func _hitstop(seconds: float) -> void:
	# 注意：headless 下也生效，好让 --t4b-smoke 能验证"顿帧能否复位"；镜头震动仍只在有窗口时执行。
	if not enabled or seconds <= 0.0:
		return
	_hitstop_until_us = maxi(_hitstop_until_us, Time.get_ticks_usec() + int(seconds * 1000000.0))
	Engine.time_scale = HITSTOP_SCALE

func _shake(dir: Vector2, amp: float, dur: float) -> void:
	if headless or camera == null or amp <= 0.0:
		return
	_shake_dir = dir.normalized() if dir.length() > 0.001 else Vector2.DOWN
	_shake_amp = maxf(amp, _shake_amp * 0.4)
	_shake_dur = maxf(_shake_left, dur)
	_shake_left = _shake_dur

func _dir_from_player(pos: Vector2) -> Vector2:
	if player == null:
		return Vector2.RIGHT
	var pc: Vector2 = Vector2(player.cell_pos())
	var d := pos - pc
	if d.length() < 0.001:
		return -Vector2.DOWN
	return d.normalized()

func _as_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Vector2i:
		return Vector2(v)
	return Vector2.ZERO

func _type_color(dtype: String) -> Color:
	match dtype:
		"火":
			return Color(1.0, 0.55, 0.18)
		"阴":
			return Color(0.68, 0.48, 1.0)
		"阳":
			return Color(1.0, 0.94, 0.70)
		"水":
			return Color(0.42, 0.78, 1.0)
		"金":
			return Color(1.0, 0.90, 0.52)
		"木":
			return Color(0.60, 0.90, 0.46)
		"土":
			return Color(0.88, 0.74, 0.46)
		"毒":
			return Color(0.70, 0.92, 0.32)
		_:
			return Color(0.98, 0.94, 0.84)

func _reaction_color(rid: String) -> Color:
	match rid:
		"r-black-powder":
			return Color(1.0, 0.62, 0.20)
		"r-sulfur-toxic-smoke":
			return Color(0.72, 0.90, 0.30)
		"r-bamboo-burn":
			return Color(1.0, 0.48, 0.16)
		"r-lime-steam":
			return Color(0.90, 0.94, 1.0)
		"r-rice-purify":
			return Color(0.94, 0.92, 0.80)
		"r-dog-blood-spirit":
			return Color(0.90, 0.28, 0.28)
		"r-quicksilver-ward":
			return Color(0.80, 0.82, 0.92)
		"r-cinnabar-talisman":
			return Color(1.0, 0.36, 0.30)
		_:
			return Color(0.96, 0.90, 0.70)
