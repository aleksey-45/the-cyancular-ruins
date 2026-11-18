class_name LocalPlayer
extends Player

signal restart_requested

var input_frozen := false
var _drop_hold_t := 0.0
var _drop_latched := false
var _wheel_weapon := 0

func _ready() -> void:
	super()
	if process_mode == Node.PROCESS_MODE_DISABLED:
		return
	add_to_group("player")


func aim_guide(aim: Vector2) -> PackedVector2Array:
	if equipped == null or not equipped.has_aim_guide():
		return PackedVector2Array()
	if equipped.definition.has("arc_time"):
		var dt := ActorStep.DT * time_field.player_speed_mult() \
				if time_field != null and time_field.is_hasting() else ActorStep.DT
		return equipped.preview_arc(self, aim, dt)
	var muzzle := equipped.muzzle_pose(self, aim)
	return PackedVector2Array([muzzle.origin, muzzle.origin + muzzle.x * 600.0 * scale.x])

# 单人先用持续输入推进时间场，再用恢复后的位置和背包补齐这一帧输入。
func complete_input(record: Array, delta: float, aim: Vector2) -> Array:
	record[ActorInput.AIM] = aim
	if _drop_pressed(delta):
		record[ActorInput.PRESSED] |= ActorInput.BIT_DROP
	var key := 0 if input_frozen else LocalInputSource.switch_index()
	var inst := weapons.inst_at_index(key - 1)
	record[ActorInput.WINST] = inst if inst > 0 else _wheel_weapon
	_wheel_weapon = 0
	return record

func _drop_pressed(delta: float) -> bool:
	if input_frozen or not Input.is_action_pressed(&"Q"):
		_drop_hold_t = 0.0
		_drop_latched = false
		return false
	if _drop_latched:
		return false
	_drop_hold_t += delta
	_drop_latched = _drop_hold_t >= PlayerParams.weapon_drop_hold_time
	return _drop_latched


# 获取长按丢弃进度（0.0 ~ 1.0），供 HUD 丢弃进度条渲染显示
func drop_hold_progress() -> float:
	if equipped == null or equipped.reloading:
		return 0.0
	return minf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切换武器：循环选择下一个已启用的武器槽位
	if Settings.wheel_switch and not sim_downed \
			and event is InputEventMouseButton and event.pressed:
		var dir := 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = -1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = 1
		if dir != 0:
			var inst := weapons.cycle_instance(dir)
			if inst > 0:
				_wheel_weapon = inst
			return
	if sim_downed and time_field != null and event.is_action_pressed("R"):
		restart_requested.emit()
