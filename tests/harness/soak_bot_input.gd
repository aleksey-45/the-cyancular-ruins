extends PlayerInput
# 大乱斗压力探针的脚本「手柄」(extends PlayerInput,与 AiInputSource 同一套注入机制)。

const PHASE_TICKS := 75      # 每段行为持续 tick(≈1.25s)
const ACTIONS: Array[String] = [
	"walk_right", "shoot", "jump", "walk_left", "dash", "crouch", "shoot", "switch",
	"climb", "walk_right", "shoot", "idle",
]

var axis := 0.0
var aim := Vector2.RIGHT

var _held: Dictionary = {}      # action -> bool(持续按住)
var _prev_held: Dictionary = {} # 上一帧的 _held(边沿由差分得到)
var _pressed: Dictionary = {}
var _released: Dictionary = {}
var _slot := 0                  # 下一帧要切的槽位(读一次即清)
var _tick := 0
var _phase := 0


# 探针每物理帧调一次:推进脚本、算边沿。输入源种类:压力探针的脚本手柄,归到 AI 一档(与 AiInputSource 同一套注入机制,同样由脚本每帧写字段、不是真实 Input,也不是网络包)。
func source_kind() -> int:
	return Kind.AI


func step() -> void:
	if frozen:
		axis = 0.0
		_held = {}
		_prev_held = {}
		_pressed = {}
		_released = {}
		return
	_tick += 1
	if _tick % PHASE_TICKS == 1:
		_phase = (_phase + 1) % ACTIONS.size()
		_apply_phase(ACTIONS[_phase])
	# 边沿 = held 的差分(与真实 Input 的 just_pressed/just_released 同语义)
	_pressed = {}
	_released = {}
	for k in _held:
		var now: bool = _held[k]
		var was: bool = bool(_prev_held.get(k, false))
		if now and not was:
			_pressed[k] = true
		elif not now and was:
			_released[k] = true
	_prev_held = _held.duplicate()


func _apply_phase(a: String) -> void:
	_held = {}
	axis = 0.0
	match a:
		"walk_right":
			axis = 1.0
		"walk_left":
			axis = -1.0
		"jump":
			_held["up"] = true          # 上 = 跳 + 攀爬(在梯/链格上按上会抓住)
		"dash":
			_held["charge"] = true      # 冲刺
		"crouch":
			_held["down"] = true        # 下蹲 / 空中下冲
		"climb":
			_held["up"] = true
			axis = 0.5                  # 边爬边横移
		"shoot":
			_held["attack"] = true
		"switch":
			_slot = (_slot % 6) + 1     # 1..6 轮着切(每段只切一次)
		"idle":
			pass


# ── 覆写钩子(公开读口由基类持有并对 frozen 短路;本类不再自己认 frozen)──
func _axis_raw(neg: String, _pos: String) -> float:
	if neg == "left":
		return axis
	# 垂直轴:climb/swim 走 get_axis("up","down")
	return (1.0 if bool(_held.get("down", false)) else 0.0) \
			- (1.0 if bool(_held.get("up", false)) else 0.0)

func _action_pressed_raw(action: String) -> bool:
	return bool(_held.get(action, false))

func _action_just_pressed_raw(action: String) -> bool:
	return bool(_pressed.get(action, false))

func _action_just_released_raw(action: String) -> bool:
	return bool(_released.get(action, false))

func _attack_pressed_raw() -> bool:
	return bool(_held.get("attack", false))

func _attack_just_pressed_raw() -> bool:
	return bool(_pressed.get("attack", false))

func _attack_just_released_raw() -> bool:
	return bool(_released.get("attack", false))

func _switch_index_raw() -> int:
	var s := _slot
	_slot = 0        # 读一次即清,与真实 Input 的"本轮刚按下"语义一致
	return s

# 压力机器人不捡也不丢枪(与 AiInputSource 同口径);基类对这两个钩子有 push_error 兜底,不覆写的话每个 tick 都会刷一屏假报错,把真断言淹掉。
func _pickup_pressed_raw() -> bool:
	return false

func _drop_pressed_raw() -> bool:
	return false

func get_aim_dir_override() -> Vector2:
	return aim

# 必须 true:否则 WeaponBase 的瞄准会回落到读宿主 OS 鼠标(headless 下是 (0,0) 之类的垃圾值),开火方向会乱(与 AiInputSource 覆写它的理由同款)。
func is_network_driven() -> bool:
	return true
