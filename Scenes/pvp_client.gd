extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报。

var _local: Node2D = null

func _ready() -> void:
	MazeGenerator.set_map_file(PvpSession.map_path)
	Level0.pvp_mode = true
	var level0: Node = load("res://Scenes/Level0.tscn").instantiate()
	add_child(level0)
	var local: Node2D = level0.get_node("WorldViewport/Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	_local = local
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	var src: InputSource = _local.input_source
	# 位映射:NetworkInputSource 的常量(输入包协议与服务器共用)
	const UP := NetworkInputSource.BIT_UP
	const DOWN := NetworkInputSource.BIT_DOWN
	const CHARGE := NetworkInputSource.BIT_CHARGE
	const ATTACK := NetworkInputSource.BIT_ATTACK
	var held := 0
	var pressed := 0
	var released := 0
	if src.is_action_pressed("up"):
		held |= UP
	if src.is_action_pressed("down"):
		held |= DOWN
	if src.is_action_pressed("charge"):
		held |= CHARGE
	if src.is_action_pressed("attack"):
		held |= ATTACK
	if src.is_action_just_pressed("up"):
		pressed |= UP
	if src.is_action_just_pressed("down"):
		pressed |= DOWN
	if src.is_action_just_pressed("charge"):
		pressed |= CHARGE
	if src.is_action_just_pressed("attack"):
		pressed |= ATTACK
	if src.is_action_just_released("up"):
		released |= UP
	if src.is_action_just_released("down"):
		released |= DOWN
	if src.is_action_just_released("attack"):
		released |= ATTACK
	var aim: Vector2 = _local.get_current_aim_dir()
	var pkt := {
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
		"weapon": src.get_weapon_slot_pressed(),
		"aim": aim,
	}
	NetBus.rpc_id(1, "send_input", pkt)
