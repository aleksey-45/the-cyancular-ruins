extends Node2D

# 可破坏瓦片受击粒子特效：播放一次性碎屑飞散动画并自动销毁。挂载于世界 Viewport 下渲染。

static var _tex: Texture2D = null


static func _texture() -> Texture2D:
	if _tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_tex = ImageTexture.create_from_image(img)
	return _tex


static func _color(texture_id: int) -> Color:
	if texture_id >= 15 and texture_id <= 18:
		return Color(0.413, 0.701, 0.57, 1.0)
	if texture_id >= 19 and texture_id <= 20:
		return Color(0.301, 0.398, 0.43, 1.0)
	return Color(0.6, 0.6, 0.6)

static func spawn(parent: Node, at: Vector2, texture_id: int) -> void:
	var p := _particles(at, 10)
	p.color = _color(texture_id)
	parent.add_child(p)
	p.finished.connect(p.queue_free)

static func spawn_explosion(parent: Node, center: Vector2, radius: float) -> void:
	var cells := Explosion.destructible_subs(center, radius)
	if cells.is_empty():
		return
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	for cell: Dictionary in cells:
		points.append(GridPathfinder.toroidal_delta_px(center, cell["pos"],
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))
		colors.append(_color(cell["tex"]))
	var p := _particles(center, cells.size() * 10)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	p.emission_points = points
	p.emission_colors = colors
	parent.add_child(p)
	p.finished.connect(p.queue_free)

static func _particles(at: Vector2, amount: int) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.texture = _texture()
	p.position = at
	p.amount = amount
	p.lifetime = 0.4
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, 900.0)
	p.initial_velocity_min = -120.0
	p.initial_velocity_max = 120.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	return p
