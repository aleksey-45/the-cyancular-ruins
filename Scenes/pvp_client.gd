extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。

# ── 自校正参数 ──
# C2 本地玩家领先服务器快照是常态(快照 30Hz + 网络延迟)。硬拉会造成"移动后卡一下又回去"。
# 因此:小分歧不管(预测优先,手感不打断);中等分歧按比例平滑靠拢;只有真性大分歧(传送/卡墙)才硬回。
const SELF_CORRECT_IGNORE := 64.0    # 分歧 ≤ 此值:忽略(预测领先的正常区间)
const SELF_CORRECT_RATE := 0.35      # 每帧向服务器位置靠拢的比例(平滑,不硬跳)
const SELF_CORRECT_SNAP := 3.0 * 64.0  # 分歧 > 3 格:真性大分歧,直接回位(避免越积越歪)
var _last_snap_tick := 0

var _local: Node2D = null
var _remote_replica: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹副本挂这里)

func _ready() -> void:
	MazeGenerator.set_map_file(PvpSession.map_path)
	Level0.pvp_mode = true
	var level0: Node = load("res://Scenes/Level0.tscn").instantiate()
	add_child(level0)
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
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
	# 快照/事件消费
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_hit_event.connect(_on_hit_event)
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
	# 丢弃乱序旧快照(unreliable 通道可能乱序;应用旧快照会把玩家拉回过去位置)
	var snap_tick := int(snap.get("tick", 0))
	if snap_tick < _last_snap_tick:
		return
	_last_snap_tick = snap_tick
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
	# 位置:最短路径增量,分档处理——
	#   小分歧忽略(预测领先正常区间,手感不打断);
	#   中等分歧按比例平滑靠拢(防"卡一下又回去");
	#   大分歧(传送/卡墙)直接回位。
	var d := MazeGenerator.toroidal_delta_px(_local.global_position, data["pos"],
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var dist := d.length()
	if dist > SELF_CORRECT_SNAP:
		_local.global_position += d
	elif dist > SELF_CORRECT_IGNORE:
		_local.global_position += d * SELF_CORRECT_RATE

# 服务器广播的对手子弹 → 本地生成确定性视觉副本(不裁决伤害,只出轨迹/特效)。
func _on_bullet_spawn(data: Dictionary) -> void:
	if _world == null:
		return
	var scene: PackedScene = load(data["scene"])
	if scene == null:
		return
	var b: BulletBase = scene.instantiate()
	b.setup(data["vel"].normalized(), data["speed"], data["range"], data["size"], data["color"], null)
	b.gravity_factor = data["gravity"]
	b.hit_damage = data["hit_damage"]
	b.hit_impact = data["hit_impact"]
	b.apply_damage = false   # 视觉副本:不裁决伤害
	if data["explodes"]:
		b.explodes = true
		b.direct_hit_damage = data["direct_damage"]
		b.fuse_time = data["fuse"]
		b.hit_fuse_time = data["hit_fuse"]
		b.explosion_radius = data["radius"]
		b.explosion_damage = data["expl_damage"]
		b.explosion_knockback = data["expl_knock"]
		if data.has("visual"):
			b.explosion_visual = load(data["visual"])
	b.global_position = data["pos"]
	_world.add_child(b)

# 服务器裁决命中:本地玩家被击中 → 即时反馈(白闪/击退),血量以快照权威为准。
func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
