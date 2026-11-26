class_name LocalInputSource
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const CHARGE_TAP_MS := 250

var frozen := false:
	set(value):
		frozen = value
		if frozen:
			_last_move_press = 0
			_charge_pressed = 0
var _last_move_press := 0
var _last_move_press_at := 0
var _charge_pressed := 0
var _drop_hold_t := 0.0
var _drop_latched := false
var _wheel_direction := 0

static func aim_direction(origin: Vector2, facing: int, map_size: Vector2, base: Vector2,
		zoom: float, mouse_offset: Vector2) -> Vector2:
	var center := ToroidalGrid.anchor_to_nearest(base, origin + Vector2(0, CFG.cam_y_bias), map_size)
	var direction := center + mouse_offset / zoom - origin
	return Vector2(facing, 0.0) if direction.length_squared() < 0.0001 else direction.normalized()

const ACTIONS := [
	[&"up", ActorInput.BIT_UP],
	[&"down", ActorInput.BIT_DOWN],
	[&"attack", ActorInput.BIT_ATTACK],
	[&"R", ActorInput.BIT_RELOAD],
]

func sample(player: Player, delta: float, aim: Vector2) -> Array:
	var held := 0
	var pressed := _charge_pressed
	_charge_pressed = 0
	var released := 0
	var axis := 0.0
	var inst := 0
	if not frozen:
		axis = Input.get_axis(&"left", &"right")
		for entry in ACTIONS:
			var action: StringName = entry[0]
			var bit: int = entry[1]
			if Input.is_action_pressed(action):
				held |= bit
			if Input.is_action_just_pressed(action):
				pressed |= bit
			if Input.is_action_just_released(action):
				released |= bit
		if Input.is_action_pressed(&"haste"):
			held |= ActorInput.BIT_HASTE
		if Input.is_action_pressed(&"rewind"):
			held |= ActorInput.BIT_REWIND
		if Input.is_action_just_pressed(&"F"):
			pressed |= ActorInput.BIT_PICKUP
		inst = player.weapons.inst_at_index(_switch_index() - 1)
		if inst == 0 and _wheel_direction != 0:
			inst = player.weapons.cycle_instance(_wheel_direction)
	if _drop_pressed(delta):
		pressed |= ActorInput.BIT_DROP
	_wheel_direction = 0
	return [axis, held, pressed, released, inst, aim]

static func _switch_index() -> int:
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

func _drop_pressed(delta: float) -> bool:
	if frozen or not Input.is_action_pressed(&"Q"):
		_drop_hold_t = 0.0
		_drop_latched = false
		return false
	if _drop_latched:
		return false
	_drop_hold_t += delta
	_drop_latched = _drop_hold_t >= CFG.weapon_drop_hold_time
	return _drop_latched


func drop_hold_progress() -> float:
	return minf(_drop_hold_t / CFG.weapon_drop_hold_time, 1.0)


func handle_event(event: InputEvent) -> void:
	if not frozen:
		var left := event.is_action_pressed(&"left")
		var right := event.is_action_pressed(&"right")
		if left != right:
			var direction := ActorInput.BIT_CHARGE_LEFT if left else ActorInput.BIT_CHARGE_RIGHT
			var now := Time.get_ticks_msec()
			if direction == _last_move_press and now - _last_move_press_at <= CHARGE_TAP_MS:
				_charge_pressed = direction
				_last_move_press = 0
			else:
				_last_move_press = direction
				_last_move_press_at = now
	if Settings.wheel_switch and event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: _wheel_direction = -1
			MOUSE_BUTTON_WHEEL_DOWN: _wheel_direction = 1
