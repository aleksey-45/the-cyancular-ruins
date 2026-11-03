extends PlayerInput

# 3v3 真链路探针(tests/probe/team_match_probe.*)的脚本手柄:一根哑手柄 —— 它自己不做任何决策,只把观察者(team_match_watcher.gd)每物理帧写进来的 axis / aim / attack / 一次性边沿(jump / switch_index / F)报给输入读口。

var axis := 0.0              # 水平轴(-1 左 / +1 右)
var aim := Vector2.RIGHT     # 瞄准方向(世界向量;观察者按环面最短向量算)
var attack := false          # 持续开火(按住左键同理)
var _edges: Dictionary = {}  # 边沿名 -> 该边沿所属的物理帧号(整帧内有效)

func _set_edge(name: String) -> void:
	_edges[name] = Engine.get_physics_frames()


func _edge_now(name: String) -> bool:
	return int(_edges.get(name, -1)) == Engine.get_physics_frames()

# ★ 垂直轴要按住态(不是边沿):ClimbComponent 的上爬速度读 get_axis("up","down"),而「抓梯」读的是同一动作的按下边沿(is_action_just_pressed("up"),由 jump 提供)⇒ 两半都得有(只给边沿 = 抓上了却不动;只给按住 = 永远抓不上)。
var hold_up := false
var hold_down := false

var _switch_index := 0       # 背包位置(1-based)的按下边沿;'0 = 无'(整帧有效,见 _switch_index_raw)


func source_kind() -> int:
	return Kind.AI



func press_jump() -> void:
	_set_edge("jump")


func press_switch_index(i: int) -> void:
	_switch_index = i
	_set_edge("switch_index")


func press_f() -> void:
	_set_edge("pickup")



func _axis_raw(neg: String, _pos: String) -> float:
	if neg == "left":
		return axis
	return (1.0 if hold_down else 0.0) - (1.0 if hold_up else 0.0)


# ★★★ 带参钩子必须真实现(本手柄最要命的一处):上行包问的是带参的 is_action_pressed("attack"/"up"/…)(packet_input_source.gd),而本类原先三个带参钩子全是恒 false 的桩 ⇒ BIT_ATTACK/BIT_UP 的 held/pressed/relea。
func _action_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return attack
		"up":
			return hold_up
		"down":
			return hold_down
	return false


func _action_just_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return _edge_now("atk")
		"up":
			return _edge_now("jump")
	return false


func _action_just_released_raw(action: String) -> bool:
	if action == "attack":
		return _edge_now("atk_rel")
	return false


func _attack_pressed_raw() -> bool:
	return attack


# ★★ 开火的三个边沿都得给:WeaponBase 按枪种选边沿 —— full_auto → _attack_pressed();半自动 → _attack_just_pressed();heavy_aim(m82a1 与榴弹发射器)→ _attack_just_released()(按住预瞄、松开发射)。
func _attack_just_pressed_raw() -> bool:
	return _edge_now("atk")


func _attack_just_released_raw() -> bool:
	return _edge_now("atk_rel")


func press_attack_edge() -> void:
	_set_edge("atk")


func release_attack_edge() -> void:
	_set_edge("atk_rel")


func _switch_index_raw() -> int:
	return _switch_index if _edge_now("switch_index") else 0


func _pickup_pressed_raw() -> bool:
	return _edge_now("pickup")


func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


# 用观察者写的方向,不读宿主 OS 鼠标(headless 下是 (0,0) 之类的垃圾值,开火方向会乱);同样整帧有效(理由见文件头)。
func get_aim_dir_override() -> Vector2:
	return aim


func is_network_driven() -> bool:
	return true
