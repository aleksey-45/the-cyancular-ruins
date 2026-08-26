class_name WaterFx
extends Node2D

# 水粒子:实体在水里移动时,水面溅水花 / 水体上浮气泡。运行期挂到主角与敌人。
# 自驱动 _process,读父实体(CharacterBody2D)速度+位置;粒子播进父实体所在视图。

static var _tex: Texture2D = null


static func _texture() -> Texture2D:
	if _tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_tex = ImageTexture.create_from_image(img)
	return _tex

var _next_emit: float = 0.0


func _process(delta: float) -> void:
	var parent := get_parent() as CharacterBody2D
	if parent == null:
		return
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var off := Water.feet_offset(parent)
	var feet := Vector2(parent.global_position.x, parent.global_position.y + off)
	if not Water.is_in_water(feet):
		return
	if parent.velocity.length() < GameParameters.water_fx_move_threshold:
		return  # 静止漂着不喷
	var surface_y := Water.surface_y_at(parent.global_position)
	# 按「中心相对水面线」分模式:中心贴水面(半没入/浮着)→ 溅水花;中心没入深 → 上浮气泡
	var depth := parent.global_position.y - surface_y
	_next_emit -= delta
	if _next_emit > 0.0:
		return
	var host := parent.get_parent()
	if host == null:
		return
	if depth <= GameParameters.water_fx_splash_band:
		_next_emit = GameParameters.water_fx_splash_interval
		_spawn(host, Vector2(parent.global_position.x, surface_y), true)
	else:
		_next_emit = GameParameters.water_fx_bubble_interval
		_spawn(host, Vector2(parent.global_position.x, parent.global_position.y + off), false)


func _spawn(host: Node, at: Vector2, splash: bool) -> void:
	var p := CPUParticles2D.new()
	p.texture = _texture()
	p.position = at
	p.amount = 8 if splash else 5
	p.lifetime = 0.4 if splash else 0.7
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 40.0 if splash else 12.0
	p.gravity = Vector2(0, 700.0) if splash else Vector2(0, -30.0)
	p.initial_velocity_min = 60.0 if splash else 40.0
	p.initial_velocity_max = 160.0 if splash else 90.0
	p.scale_amount_min = 1.0 if splash else 0.5
	p.scale_amount_max = 2.5 if splash else 1.0
	p.color = Color(0.75, 0.88, 1.0, 0.9) if splash else Color(0.75, 0.88, 1.0, 0.6)
	host.add_child.call_deferred(p)
	host.get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)
