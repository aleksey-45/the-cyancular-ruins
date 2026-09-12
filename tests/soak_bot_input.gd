extends InputSource
# 大乱斗压力探针的脚本"手柄"(extends InputSource,与 AIInputSource 同一套注入机制)。
# 目的:让 headless 客户端在真 `royale_game` 场景里把**局内行为真的踩一遍** ——
# 走动 / 跳 / 冲刺 / 下蹲 / 上下爬 / 各武器开火 / 切枪 / 静默,而不是只连上收快照。
# 探针每物理帧调 step();探针直接把本对象塞进本地玩家的 input_source。
#
# 无 class_name(新建全局类要刷 --import 全局类缓存,本仓踩过这个坑),由探针 preload 引用。
#
# frozen:PvP 的 COUNTDOWN/结算冻结会置它(set_controls_locked)。基类靠它把各读口短路成中性值,
# 但本类**覆写了全部读口**,所以必须自己认 —— 否则探针机器人会在倒计时里乱动,
# 与"服务器权威冻结"打架(这条也算顺手把冻结路径压了一遍)。

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


# ── 读口(全部覆写:基类读真实 Input,headless 下没有输入设备)──
func get_axis(neg: String, _pos: String) -> float:
	if frozen:
		return 0.0
	if neg == "left":
		return axis
	# 垂直轴:climb/swim 走 get_axis("up","down")
	return (1.0 if bool(_held.get("down", false)) else 0.0) \
			- (1.0 if bool(_held.get("up", false)) else 0.0)

func is_action_pressed(action: String) -> bool:
	return not frozen and bool(_held.get(action, false))

func is_action_just_pressed(action: String) -> bool:
	return not frozen and bool(_pressed.get(action, false))

func is_action_just_released(action: String) -> bool:
	return not frozen and bool(_released.get(action, false))

func is_attack_pressed() -> bool:
	return not frozen and bool(_held.get("attack", false))

func is_attack_just_pressed() -> bool:
	return not frozen and bool(_pressed.get("attack", false))

func is_attack_just_released() -> bool:
	return not frozen and bool(_released.get("attack", false))

func get_weapon_slot_pressed() -> int:
	if frozen:
		return 0
	var s := _slot
	_slot = 0        # 读一次即清,与真实 Input 的"本轮刚按下"语义一致
	return s

func get_aim_dir_override() -> Vector2:
	return aim

# 必须 true:否则 WeaponBase 的瞄准会回落到读宿主 OS 鼠标(headless 下是 0,0 之类的垃圾值),
# 开火方向会乱。与 AIInputSource 覆写它的理由同款(那条注释里还记着 reload_active 的第二个判据)。
func is_network_driven() -> bool:
	return true
