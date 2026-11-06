extends RefCounted


const BEAM_SCENE := preload("res://scenes/weapons/laser_beam.tscn")

static func spawn_beam(parent: Node, points: PackedVector2Array, half_width: float,
		color: Color, lifetime: float, _style: int = 0) -> void:
	if parent == null or points.size() < 2:
		return
	var beam := BEAM_SCENE.instantiate()
	parent.add_child(beam)
	beam.global_position = Vector2.ZERO
	beam.lifetime = lifetime
	if beam.has_method("setup"):
		beam.setup(points, half_width, color)

static func spawn_muzzle_orb(parent: Node, at: Vector2, color: Color, half_width: float, lifetime: float) -> void:
	if parent == null:
		return
	var holder := Node2D.new()
	holder.global_position = at
	var core_r := maxf(half_width * 0.7, 5.0)
	var glow_r := core_r * 2.6
	var glow := Sprite2D.new()
	glow.texture = Explosion.make_circle_texture(32)
	glow.modulate = Color(color.r, color.g, color.b, 0.30 * color.a)
	glow.scale = Vector2.ONE * (glow_r / 16.0)
	var core := Sprite2D.new()
	core.texture = Explosion.make_circle_texture(16)
	core.modulate = Color(1.0, 1.0, 1.0, 0.95)
	core.scale = Vector2.ONE * (core_r / 8.0)
	holder.add_child(glow)
	holder.add_child(core)
	parent.add_child(holder)
	var tw := holder.create_tween()
	tw.tween_interval(maxf(lifetime - 0.12, 0.0))
	tw.tween_property(holder, "modulate:a", 0.0, minf(lifetime, 0.12))
	tw.tween_callback(holder.queue_free)
