extends PlayerInput

# Bot 的哑手柄:只把 watcher 每物理帧写进来的意图报给输入读口,自身不做任何决策。
# ★ 全部钩子都要实现(含带参 is_action_pressed("attack"/"up"/"down") 与三个开火边沿):
#   漏一个的后果是"本地能动、服务器侧不动且 C2 每帧回滚"(见 team_bot_input.gd 文件头)。
# ★ 边沿按物理帧打标、整帧有效:同一物理帧里组上行包与本地判定各读一次,读一次即清必有一处拿到 false。

var axis := 0.0              # 水平轴(-1 左 / +1 右)
var aim := Vector2.RIGHT     # 世界单位向量
var attack := false          # 按住开火
var hold_up := false         # 攀爬 / 梯子按住
var hold_down := false
var switch_index := 0        # 背包位置(1-based);'0 = 无'

var _edges: Dictionary = {}  # 边沿名 -> 所属物理帧号


func source_kind() -> int:
	return Kind.AI


func press_jump() -> void:
	_set_edge("jump")


func press_attack_edge() -> void:
	_set_edge("atk")


func release_attack_edge() -> void:
	_set_edge("atk_rel")


func press_switch_index(i: int) -> void:
	switch_index = i
	_set_edge("switch_index")


func press_pickup() -> void:
	_set_edge("pickup")


func _set_edge(name: String) -> void:
	_edges[name] = Engine.get_physics_frames()


func _edge_now(name: String) -> bool:
	return int(_edges.get(name, -1)) == Engine.get_physics_frames()


func _axis_raw(neg: String, _pos: String) -> float:
	if neg == "left":
		return axis
	return (1.0 if hold_down else 0.0) - (1.0 if hold_up else 0.0)


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
	return _edge_now("atk_rel") if action == "attack" else false


func _attack_pressed_raw() -> bool:
	return attack


func _attack_just_pressed_raw() -> bool:
	return _edge_now("atk")


func _attack_just_released_raw() -> bool:
	return _edge_now("atk_rel")


func _switch_index_raw() -> int:
	return switch_index if _edge_now("switch_index") else 0


func _pickup_pressed_raw() -> bool:
	return _edge_now("pickup")


func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


# 不读宿主 OS 鼠标(headless 下是垃圾值),只用注入方向。
func get_aim_dir_override() -> Vector2:
	return aim


func is_network_driven() -> bool:
	return true
