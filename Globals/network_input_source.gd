class_name NetworkInputSource
extends InputSource

# 网络注入输入(服务器权威模拟的唯一消费方):从输入包取轴/按键/边沿/切枪/瞄准。
# 服务器 Match 每物理帧 begin_tick()+apply_packet() 后,玩家 _physics_process 读到的就是注入状态。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8

var _axis := 0.0
var _held := 0
var _pressed := 0
var _released := 0
var _weapon := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)

# 清空边沿(每 tick 消费新包前调用,避免上一 tick 边沿残留)。
func begin_tick() -> void:
	_pressed = 0
	_released = 0
	_weapon = 0

func apply_packet(pkt: Dictionary) -> void:
	_axis = pkt.get("ax", 0.0)
	_held = pkt.get("held", 0)
	_pressed = pkt.get("pressed", 0)
	_released = pkt.get("released", 0)
	_weapon = pkt.get("weapon", 0)
	_aim = pkt.get("aim", Vector2.ZERO)

func get_axis(_neg: String, _pos: String) -> float:
	return _axis

func is_action_pressed(action: String) -> bool:
	return _held & _bit(action) != 0

func is_action_just_pressed(action: String) -> bool:
	return _pressed & _bit(action) != 0

func is_action_just_released(action: String) -> bool:
	return _released & _bit(action) != 0

func is_attack_pressed() -> bool:
	return _held & BIT_ATTACK != 0

func is_attack_just_pressed() -> bool:
	return _pressed & BIT_ATTACK != 0

func is_attack_just_released() -> bool:
	return _released & BIT_ATTACK != 0

func get_weapon_slot_pressed() -> int:
	return _weapon

func get_aim_dir_override() -> Vector2:
	return _aim

static func _bit(action: String) -> int:
	match action:
		"up": return BIT_UP
		"down": return BIT_DOWN
		"charge": return BIT_CHARGE
		"attack": return BIT_ATTACK
	return 0
