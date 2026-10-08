extends PlayerInput
# 大乱斗压力测试机器人的模拟输入驱动脚本（继承 PlayerInput，采用与 AiInputSource 相同的注入机制）。
# 用于在无头客户端对局中周期性模拟走动、跳跃、冲刺、下蹲、攀爬、开火与切枪等角色操作。
# 测试探针每物理帧调用 step() 更新状态，并将本实例配置到本地玩家的 input_source 中。
#
# 控制冻结说明：
# 倒计时与结算阶段会触发 set_controls_locked 锁定输入。基类已对底层接口短路，
# 本类仅覆写基础查询钩子并在 step() 中处理冻结时的按键释放。

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


# 探针每物理帧调一次:推进脚本、算边沿。
# 输入源种类:压力探针的脚本手柄,归到 AI 一档(与 AiInputSource 同一套注入机制,
# 同样由脚本每帧写字段、不是真实 Input,也不是网络包)。
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


# ── 覆写钩子(公开输入读取接口由基类持有并对 frozen 短路;本类不再自己认 frozen)──
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

# 机器人不执行拾取与丢弃武器操作，返回 false 避免未实现报错
func _pickup_pressed_raw() -> bool:
	return false

func _drop_pressed_raw() -> bool:
	return false

func get_aim_dir_override() -> Vector2:
	return aim

# 标记为网络/模拟驱动，避免 WeaponBase 在无头模式下回退读取宿主鼠标坐标
func is_network_driven() -> bool:
	return true
