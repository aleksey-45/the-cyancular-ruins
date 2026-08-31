extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。

const SELF_CORRECT_DIST := 96.0  # 位置校正阈值(px)

var _local: Node2D = null
var _remote_replica: Node2D = null

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
	# 远端副本(角色 = 3 - 自己的 role,1v1)
	var replica := preload("res://Scenes/Player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	level0.get_node("WorldViewport").add_child(replica)
	_remote_replica = replica
	# 快照消费
	NetBus.local_snapshot.connect(_on_snapshot)
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

func _on_snapshot(snap: Dictionary) -> void:
	if _local == null:
		return
	var players_snap: Dictionary = snap["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role == PvpSession.role:
			_self_correct(data)
		elif _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
			_remote_replica.apply_snapshot(data, _local.global_position)

func _self_correct(data: Dictionary) -> void:
	if _local == null:
		return
	# 血量/防水/倒地:服务器权威,直接采纳
	var hp := int(data["hp"])
	var wp := int(data["waterproof"])
	var downed := bool(data["downed"])
	if _local.hp != hp or _local.waterproof != wp or _local.is_downed() != downed:
		_local.apply_authoritative_state(hp, wp, downed)
	# 位置:差异超阈值才校正(最短路径增量,不 set 绝对位置)
	var d := MazeGenerator.toroidal_delta_px(_local.global_position, data["pos"],
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if d.length() > SELF_CORRECT_DIST:
		_local.global_position += d
