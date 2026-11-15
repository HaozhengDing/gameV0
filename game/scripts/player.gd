extends Node2D
## T4a 角色移动：只看键盘，不做物理碰撞（世界的 solid 判定在 sim_core 里，T4b 再接）。
## Godot 侧不依赖 sim_core 内部实现——即使把 SimWorldNode 换成桩，本脚本不用改。

const SPEED := 260.0
const WORLD_PX := Vector2(480 * 4, 270 * 4)

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir == Vector2.ZERO:
		return
	position += dir.normalized() * SPEED * delta
	position.x = clampf(position.x, 4.0, WORLD_PX.x - 4.0)
	position.y = clampf(position.y, 4.0, WORLD_PX.y - 4.0)
