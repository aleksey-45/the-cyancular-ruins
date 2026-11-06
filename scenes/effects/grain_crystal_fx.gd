class_name GrainCrystalFx
extends Node2D


const SHARD_COUNT := 10
const SCATTER_TIME := 0.28
const ARRIVE_RATE := 16.0
const MAX_FLY_SPEED := 4200.0
const ABSORB_RADIUS := 16.0
const ABSORB_TIMEOUT := 1.6
const ABSORB_TAIL := 0.8
const SHARD_COLOR := Color8(18, 18, 22)
const CORE_COLOR := Color8(70, 70, 78)

static var last_absorb_kind: String = ""
static var last_absorb_t: float = 0.0

var amount: int = TimeParams.ELITE_GRAIN_DROP
var _shards: Array = []
var _t := 0.0
var _absorbed := false


static func spawn(host: Node, world_pos: Vector2, amount_: int) -> void:
	if host == null or not is_instance_valid(host):
		return
	var fx := GrainCrystalFx.new()
	fx.amount = amount_
	fx.global_position = world_pos
	fx.add_to_group("grain_crystal")
	for i in SHARD_COUNT:
		var ang := TAU * float(i) / float(SHARD_COUNT) + randf_range(-0.25, 0.25)
		fx._shards.append({
			"p": Vector2.ZERO,
			"v": Vector2.from_angle(ang) * randf_range(260.0, 720.0),
			"size": randf_range(4.0, 7.5),
		})
	host.add_child(fx)


func _process(delta: float) -> void:
	_t += delta
	if _t < SCATTER_TIME:
		for s in _shards:
			s["v"] = (s["v"] as Vector2) * exp(-4.5 * delta)
			s["p"] = (s["p"] as Vector2) + (s["v"] as Vector2) * delta
	else:
		var target := _watch_world_target()
		var all_done := true
		for s in _shards:
			var prev: Vector2 = global_position + (s["p"] as Vector2)
			var to: Vector2 = target - prev
			var v: Vector2 = to * ARRIVE_RATE
			if v.length() > MAX_FLY_SPEED:
				v = v.normalized() * MAX_FLY_SPEED
			s["v"] = v
			var now: Vector2 = prev + v * delta
			s["p"] = now - global_position
			if (s["p"] as Vector2).length() > 8.0:
				all_done = false
			if not _absorbed and _segment_hits(prev, now, target, ABSORB_RADIUS):
				last_absorb_kind = "fly"
				_absorb()
		if all_done or _t >= SCATTER_TIME + ABSORB_TIMEOUT \
				or (_absorbed and _t >= SCATTER_TIME + ABSORB_TAIL):
			if not _absorbed:
				last_absorb_kind = "fly" if all_done else "timeout"
				_absorb()
			queue_free()
	queue_redraw()


static func _segment_hits(a: Vector2, b: Vector2, p: Vector2, r: float) -> bool:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.0001:
		return a.distance_to(p) <= r
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return (a + ab * t).distance_to(p) <= r


func _watch_world_target() -> Vector2:
	var tree := get_tree()
	if tree == null:
		return global_position
	var watch: Control = tree.get_first_node_in_group("watch_hud") as Control
	var cam := get_viewport().get_camera_2d()
	if watch == null or cam == null:
		return global_position
	var screen_center: Vector2 = watch.get_global_rect().get_center()
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	return cam.get_screen_center_position() + (screen_center - vp_size * 0.5) / cam.zoom


func _absorb() -> void:
	if _absorbed:
		return
	_absorbed = true
	last_absorb_t = _t
	if Level0.grain_account != null:
		Level0.grain_account.deposit(amount)
	var tree := get_tree()
	if tree != null:
		var watch = tree.get_first_node_in_group("watch_hud")
		if watch != null and watch.has_method("tremble"):
			watch.tremble()


func _draw() -> void:
	for s in _shards:
		var p: Vector2 = s["p"]
		var sz: float = s["size"]
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(0, -sz * 2.0), p + Vector2(sz, 0), p + Vector2(0, sz * 2.0), p + Vector2(-sz, 0),
		]), SHARD_COLOR)
		draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), CORE_COLOR)
