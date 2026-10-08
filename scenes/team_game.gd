extends PvpMatchClient
# 3v3 团队对战客户端场景：集成地形世界、本地预测角色、远端队伍副本与网络快照处理
#
# 主要机制：
# 1. 副本管理：支持最多 5 个远端玩家镜像副本，按快照中的角色编号动态创建。
# 2. 阵营染色：统一采用队伍颜色调制，本地玩家、队友与对手均按所属队伍着色。
# 3. 队友穿透：同队玩家间不阻挡物理移动与子弹射击，敌队玩家之间保留碰撞。
# 4. 数据同步：队伍映射表由服务端通过 match_sync 权威下发。

var _last_snap_tick := 0
var _replicas: Dictionary = {}         # 角色编号到远端副本节点的映射
var _hud: TeamHud = null
var _pause_menu: PauseMenu = null

# ── 队伍映射表 ──
# 角色编号映射至队伍编号（1 或 2），由 match_sync 同步
var _teams: Dictionary = {}

# ── 头顶标识与生命条 ──
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
var _id_labels: Dictionary = {}    # 角色编号到头顶文字标签的映射（包含本地玩家）
var _hp_bars: Dictionary = {}      # 角色编号到头顶生命条的映射（仅他人，由设置控制）
var _names: Dictionary = {}        # 角色编号到昵称的映射

func _ready() -> void:
	CombatComponent.pvp_arena = true
	MazeGenerator.set_map_file(PvpSession.map_path)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 初始配置与其它玩家的碰撞掩码，待队伍表同步后由 _apply_team_collision 精确设置
	local.collision_mask |= 2
	_local = local
	# 绑定客户端预测回滚控制器与环面地图尺寸
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 订阅网络总线事件
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBusExt.local_sub_destroyed.connect(_on_remote_sub_destroyed)
	_setup_beta_time_hud()
	NetBus.local_round_state.connect(_on_round_state)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBus.local_match_sync.connect(_on_match_sync)
	_subscribe_ground_weapons()
	_subscribe_reconnect()
	# 初始化小地图多目标显示
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable(self, "_minimap_self_color"))
		add_child(minimap)
	# 初始化团队计分面板与暂停菜单
	_hud = preload("res://ui/hud/team_hud.tscn").instantiate() as TeamHud
	add_child(_hud)
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())
	add_child(_pause_menu)
	# 进入场景后主动请求当前对局的完整同步数据
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入 3v3:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# 处理服务端同步的队伍映射表
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var teams: Dictionary = payload.get("teams", {})
	if teams.is_empty():
		push_warning("match_sync: 3v3 载荷缺少 teams 队伍映射")
		return
	_apply_teams(teams)


# 应用队伍配置：更新 HUD 阵营、刷新各角色队伍染色与碰撞层掩码
func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	if _hud != null and is_instance_valid(_hud):
		_hud.set_my_team(_team_of_role(PvpSession.role))
	_refresh_team_colors()
	_apply_team_collision()


func _team_of_role(role: int) -> int:
	return int(_teams.get(role, 0))


# 根据节点对象反查对应的角色编号
func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	if n == _local:
		return int(PvpSession.role)
	for role in _replicas:
		if _replicas[role] == n:
			return int(role)
	return 0


# 判定子弹是否命中实体：3v3 模式下同队队友之间子弹穿透，不发生阻挡
func _bullet_hits_entity(b: BulletBase, ent: Node2D) -> bool:
	var sr := _role_of_node(b.shooter)
	var er := _role_of_node(ent)
	if sr == 0 or er == 0:
		return true
	return _team_of_role(sr) != _team_of_role(er)


# 获取角色对应的队伍颜色
func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)


# 将队伍颜色应用到本地角色和所有远端副本的精灵图
func _refresh_team_colors() -> void:
	if _local != null and _team_of_role(PvpSession.role) != 0:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(PvpSession.role))
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), 0.0,
					_team_color(role))
	_refresh_names()


# 计算远端副本幽灵碰撞体所在的碰撞层
func _ghost_layer_of(role: int) -> int:
	match _team_of_role(role):
		1:
			return 2
		2:
			return TeamHost.TEAM_ENEMY_LAYER
	return 2


# 队友不互挡碰撞配置：
# 队 1 玩家：layer = 2, mask 包含队 2 层 (16)
# 队 2 玩家：layer = 16, mask 包含队 1 层 (2)
# 远端副本幽灵碰撞体根据所属队伍放置在对应层上
func _apply_team_collision() -> void:
	if _local == null:
		return
	var my_team := _team_of_role(PvpSession.role)
	if my_team == 0:
		return
	if my_team == 1:
		_local.collision_layer = 2
		_local.collision_mask = (_local.collision_mask & ~2) | TeamHost.TEAM_ENEMY_LAYER
	else:
		_local.collision_layer = TeamHost.TEAM_ENEMY_LAYER
		_local.collision_mask |= 2
	for role in _replicas:
		var r = _replicas[role]
		if r != null and is_instance_valid(r) and r.has_method("set_ghost_layer"):
			r.set_ghost_layer(_ghost_layer_of(int(role)))


# 收集小地图远端目标数据
func _minimap_entries() -> Array:
	var arr: Array = []
	for role in _replicas:
		var r = _replicas[role]
		if is_instance_valid(r):
			arr.append([int(role), (r as Node2D).global_position])
	return arr


func _minimap_others() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(e[1])
	return arr


# 获取小地图远端目标对应的队伍颜色
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(_team_color(int(e[0])))
	return arr


# 获取小地图本地玩家标记的队伍颜色
func _minimap_self_color() -> Color:
	return _team_color(PvpSession.role)


# 处理世界快照：更新所有其他玩家的渲染状态并清理已离开的玩家
func _on_snapshot_world(snap: Dictionary) -> void:
	if _local == null:
		return
	var snap_tick := int(snap.get("tick", 0))
	if snap_tick < _last_snap_tick:
		return
	_last_snap_tick = snap_tick
	var players_snap: Dictionary = snap["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role != PvpSession.role:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				r.set_meta("haste", bool(data.get("haste", false)))
				r.set_meta("rewind", bool(data.get("rewind", false)))
				r.set_meta("trail", data.get("trail", []))
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
	# 清理在快照中不再存在的离线玩家
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			_remove_replica(int(role_str))


# 按需实例化远端玩家副本
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "ReplicaP%d" % role
	_world.add_child(replica)
	_replicas[role] = replica
	_ensure_id_label(role)
	_apply_tint(replica.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(role))
	if replica.has_method("set_ghost_layer"):
		replica.set_ghost_layer(_ghost_layer_of(role))
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar
	_refresh_names()


# 移除已离开玩家的副本、头顶文字与生命条
func _remove_replica(role: int) -> void:
	if _replicas.has(role):
		var r: Node2D = _replicas[role]
		if is_instance_valid(r):
			r.queue_free()
		_replicas.erase(role)
	if _id_labels.has(role):
		var l: Node = _id_labels[role]
		if is_instance_valid(l):
			l.queue_free()
		_id_labels.erase(role)
	if _hp_bars.has(role):
		var b: Node = _hp_bars[role]
		if is_instance_valid(b):
			b.queue_free()
		_hp_bars.erase(role)
	_refresh_names()


# 击杀事件播报处理
func _on_kill_event(killer: int, victim: int) -> void:
	if victim == PvpSession.role:
		CombatFeedback.reset_streak()
	elif killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))


# K 键脱困自杀请求处理
func _unhandled_input(event: InputEvent) -> void:
	if _match_ended or _local == null:
		return
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


# 回合状态流转处理：
# - 倒计时与新回合：服务端重置瓦片与清理弹道，客户端同步重置场景并重新拉取同步数据
# - 对局结束：弹出团队结算面板
func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var state := int(data.get("state", 0))
	_round_locked = state == 0
	if state == 0 and int(data.get("round", 1)) > 1:
		for b in get_tree().get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()
		if _level0 != null and _level0.has_method("reset_destructibles"):
			_level0.reset_destructibles()
		if NetBus.can_send_to_server():
			_resync_pull_pending = true
			NetBus.rpc_id(1, "match_sync")
	elif state == 3:   # MATCH_OVER
		_match_ended = true
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
			_pause_menu = null
		_show_result()
	_refresh_input_lock()


# 构建团队结算数据载荷
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_team(_last_round_state, _names, _teams,
			_team_of_role(PvpSession.role))


# 应用各角色昵称
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
	_ensure_id_label(PvpSession.role)
	_refresh_names()


func _ensure_id_label(role: int) -> void:
	if _world == null or _id_labels.has(role):
		return
	var lbl: Node2D = load("res://ui/factory/world_label.gd").new()
	_world.add_child(lbl)
	_id_labels[role] = lbl


# 刷新头顶文字与对应队伍颜色
func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		(_id_labels[role] as Node2D).set_label(nm, _team_color(role))


func _process(_delta: float) -> void:
	# 驱动头顶标识与生命条的世界坐标跟随对应实体
	for role in _id_labels:
		var target: Node2D = _local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + ID_HEAD_OFFSET
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + Vector2(0.0, -116.0)


# 获取所有远端对手副本节点
func _all_replicas() -> Array:
	return _replicas.values()


func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null
