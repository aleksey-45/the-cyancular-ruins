class_name ProjectileTrack
extends RefCounted

var type_id: int
var authority_tick := -1
var predicted: bool:
	get: return authority_tick < 0
var position := Vector2.ZERO
var rotation := 0.0
var _tick := -1
var _from := Vector2.ZERO
var _target := Vector2.ZERO
var _shown := Vector2.ZERO
var _velocity := Vector2.ZERO
var _interval := 0.0
var _age := 0.0
var _rewinding := false
var _map_size: Vector2

func _init(type: int, size: Vector2) -> void:
	type_id = type
	_map_size = size

func sample(tick: int, at: Vector2, velocity: Vector2, rewinding: bool) -> void:
	if tick == _tick and at == _target and velocity == _velocity and rewinding == _rewinding:
		return
	if _tick < 0:
		_shown = at
	var movement := GridPathfinder.toroidal_delta_px(_shown, at, _map_size)
	_from = at - movement if rewinding or _rewinding or movement.length_squared() <= 256.0 * 256.0 else at
	_interval = clampf(tick - _tick, 1.0, 3.0) * ActorStep.DT
	_target = at
	_velocity = velocity
	_tick = tick
	_age = 0.0
	_rewinding = rewinding
	if velocity != Vector2.ZERO:
		rotation = velocity.angle()

func present(delta: float, anchor: Vector2) -> void:
	_age += delta
	_shown = _from.lerp(_target, minf(_age / _interval, 1.0))
	if not _rewinding:
		_shown += _velocity * clampf(_age - _interval, 0.0, 2.0 * ActorStep.DT)
	_shown = GridPathfinder.wrap_to_range(_shown, _map_size)
	position = GridPathfinder.anchor_to_nearest(_shown, anchor, _map_size)

func update_rewind(rewinding: bool) -> void:
	sample(_tick, _target, _velocity, rewinding)
