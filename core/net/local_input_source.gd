class_name LocalInputSource
extends RefCounted

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
var _wheel_weapon := 0

static func aim_direction(origin: Vector2, facing: int, map_size: Vector2, base: Vector2,
		zoom: float, mouse_offset: Vector2) -> Vector2:
	var center := GridPathfinder.anchor_to_nearest(base, origin + Vector2(0, PlayerParams.cam_y_bias), map_size)
	var direction := center + mouse_offset / zoom - origin
	return Vector2(facing, 0.0) if direction.length_squared() < 0.0001 else direction.normalized()

const ACTIONS := [
	[&"up", ActorInput.BIT_UP],
	[&"down", ActorInput.BIT_DOWN],
	[&"attack", ActorInput.BIT_ATTACK],
	[&"R", ActorInput.BIT_RELOAD],
]

func sample() -> Array:
	var held := 0
	var pressed := _charge_pressed
	_charge_pressed = 0
	var released := 0
	var axis := 0.0
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
	return [axis, held, pressed, released, 0, Vector2.ZERO]

static func switch_index() -> int:
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

# 这一步补齐瞄准、丢弃和切换武器的输入。单人模式先处理时间技能，确保这里使用的是更新后的角色和背包状态。
func complete(player: Player, record: Array, delta: float, aim: Vector2) -> Array:
	record[ActorInput.AIM] = aim
	if _drop_pressed(delta):
		record[ActorInput.PRESSED] |= ActorInput.BIT_DROP
	var key := 0 if frozen else switch_index()
	var inst := player.weapons.inst_at_index(key - 1)
	record[ActorInput.WINST] = inst if inst > 0 else _wheel_weapon
	_wheel_weapon = 0
	return record

func _drop_pressed(delta: float) -> bool:
	if frozen or not Input.is_action_pressed(&"Q"):
		_drop_hold_t = 0.0
		_drop_latched = false
		return false
	if _drop_latched:
		return false
	_drop_hold_t += delta
	_drop_latched = _drop_hold_t >= PlayerParams.weapon_drop_hold_time
	return _drop_latched


# 丢弃进度是已按住的时长占所需时长的比例。未装备武器或正在装填时，不显示进度。
func drop_hold_progress(player: Player) -> float:
	if player.equipped == null or player.equipped.reloading:
		return 0.0
	return minf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 1.0)


func handle_event(player: Player, event: InputEvent) -> void:
	if player.sim_downed:
		_last_move_press = 0
		return
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
	# 鼠标滚轮选中的武器留到下一次采集输入时提交。
	if Settings.wheel_switch and event is InputEventMouseButton and event.pressed:
		var dir := 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = -1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = 1
		if dir != 0:
			var inst := player.weapons.cycle_instance(dir)
			if inst > 0:
				_wheel_weapon = inst
