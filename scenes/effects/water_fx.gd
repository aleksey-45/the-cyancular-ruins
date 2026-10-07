class_name WaterFx
extends Node2D

# 水体粒子特效控制器：实体在水中移动时生成水面水花与水下气泡特效。运行时动态挂载于玩家与敌人实体。
# 在 _process 中读取父级 CharacterBody2D 节点的速度与坐标，将生成的粒子节点添加至其父级视图中。

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
		return  # 静止漂浮状态下不发射粒子
	var surface_y := Water.surface_y_at(parent.global_position)
	# 根据实体中心相对水面的深度切换效果：中心贴近水面（半浸入/漂浮状态）生成水花；深入水下则生成上升气泡
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
	host.call_deferred("add_child", p)
	host.get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)
