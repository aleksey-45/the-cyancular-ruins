class_name EnemyBullet
extends BulletBase

var damage: int = 2
var water_mult: float = 1.0


func launch(vel: Vector2, rng: float, dmg: int, grav: float, siz: float = 1.0) -> void:
	velocity_vec = vel
	speed = vel.length()
	max_range = rng
	damage = dmg
	gravity_factor = grav
	size = siz
	rotation = vel.angle()
	scale = Vector2(size, size)
	_apply_pixel_scale()


func rewind_state() -> Dictionary:
	var d := super()
	d["emd"] = damage
	d["ewm"] = water_mult
	return d


func apply_rewind_state(d: Dictionary) -> void:
	super(d)
	if d.is_empty():
		return
	damage = int(d.get("emd", damage))
	water_mult = float(d.get("ewm", water_mult))


func _physics_process(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	prev_pos = global_position
	velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
	rotation = velocity_vec.angle()
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var from := global_position
	var col := move_and_collide(step)
	var to := global_position
	var t_wall := 1.0
	if col != null:
		to = from + col.get_travel()
		var lens := step.length()
		t_wall = (col.get_travel().length() / lens) if lens > 0.0 else 0.0
	var hit := first_hurt_on_segment(from, to, ["player"])
	if not hit.is_empty() and float(hit["t"]) <= t_wall:
		global_position = from + (to - from) * float(hit["t"])
		if apply_damage:
			var victim := hit["node"] as Node
			var victim2 := victim as Node2D
			if victim != null and victim.has_method("take_hit"):
				var dmg: int = damage
				if water_mult > 1.0 and victim2 != null and Water.sample_body(victim2, false).in_water:
					dmg = roundi(damage * water_mult)
				victim.take_hit(global_position, dmg)
		queue_free()
		return
	if col != null:
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()
	prev_pos = from + (global_position - to)

func _wrap() -> void:
	if get_tree().get_nodes_in_group("player").size() >= 2:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	super._wrap()
