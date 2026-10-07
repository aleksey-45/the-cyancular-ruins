extends PvpMatchClient
# 1v1 对战客户端场景：集成地形世界、本地预测角色、远端对手副本与网络快照处理

# ── 客户端预测与回滚 ──
# 本地玩家执行完整的本地物理与输入预测，结合 PredictionRollback 进行权威状态锚定与重放。
# 引擎每帧读取本地输入驱动角色逻辑，并在物理步进前校验权威快照执行回滚校正。
var _last_snap_tick := 0

var _remote_replica: Node2D = null
var _hud: PvpHud = null
var _pause_menu: PauseMenu = null

# ── 头顶标识 ──
# 显示玩家与对手昵称，在世界空间中每帧吸附于角色头顶
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null
var _minimap: Minimap = null
var _names: Dictionary = {}

func _ready() -> void:
	CombatComponent.pvp_arena = true   # 对战模式取消命中无敌帧
	MazeGenerator.set_map_file(PvpSession.map_path)
	# 刷新地图尺寸：根据当前联机地图的实际规格重设世界边界，确保环面坐标回绕与插值计算正确
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 开启对手物理层的碰撞检测掩码，避免本地预测穿透对手而在服务端发生阻挡导致回滚
	local.collision_mask |= 2
	_local = local
	# 绑定回滚控制器并初始化环面尺寸，用于计算跨边界最短位移并避免误判位置分歧
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 联机模式下单独补充后处理节点，以支持视口渲染
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 生成远端对手的镜像副本（1v1 模式下对方编号为 3 - 本地角色编号）
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	level0.get_node("WorldViewport").add_child(replica)
	_remote_replica = replica
	# 初始化对手头顶生命条
	if Settings.pvp_show_enemy_hp:
		_hp_bar = EnemyHpBar.new()
		_world.add_child(_hp_bar)
	# 订阅网络总线事件
	# 快照分为世界快照（包含远端对手外观与渲染状态）与本地快照（包含本地确认序号与权威状态）
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_opponent_left.connect(_on_opponent_left)
	NetBus.local_kill_event.connect(_on_kill_event)
	# 订阅扩展网络总线事件
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_match_sync.connect(_on_match_sync)
	_subscribe_ground_weapons()
	_subscribe_reconnect()
	# 初始化小地图
	if Settings.pvp_show_minimap:
		_minimap = Minimap.new()
		_minimap.setup(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			func() -> Vector2:
				if _remote_replica != null and is_instance_valid(_remote_replica):
					return (_remote_replica as Node2D).global_position
				return Vector2.INF)
		add_child(_minimap)
	# 挂载对局计分界面
	_hud = preload("res://ui/hud/pvp_hud.tscn").instantiate() as PvpHud
	add_child(_hud)
	# 染色设置：P2 固定染为青色，用于区分双方实体
	_apply_p2_tint()
	# 暂停菜单：联机模式下不冻结游戏世界，仅拦截本地输入
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())
	add_child(_pause_menu)
	# 进入场景后主动请求当前对局的完整同步数据
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# 处理世界快照：更新远端对手镜像的渲染状态与生命条，本地角色由客户端预测独立模拟
func _on_snapshot_world(world: Dictionary) -> void:
	if _local == null:
		return
	# 丢弃乱序到达的过时快照
	var tier := int(world.get("tick", 0))
	if tier < _last_snap_tick:
		return
	_last_snap_tick = tier
	var players_snap: Dictionary = world["players"]
	var opp_role := 3 - PvpSession.role
	if _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
		var opp: Dictionary = players_snap.get(str(opp_role), {})
		if not opp.is_empty():
			_remote_replica.apply_snapshot(opp, _local.global_position, tier)
			if _hp_bar != null:
				_hp_bar.ratio = float(opp.get("hp", PlayerParams.player_max_hp)) \
						/ float(PlayerParams.player_max_hp)


# 处理击杀事件：显示击杀提示与音效，自身死亡时重置连杀计数
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "对手")))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()


# 处理回合状态流转：
# - 倒计时与新回合：服务端重置瓦片与清理弹道，客户端同步重置场景与清理本地子弹
# - 对局结束：弹出结算面板并关闭暂停菜单
func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var state := int(data.get("state", 0))
	# 倒计时阶段锁定本地开火操作
	_round_locked = state == 0
	_refresh_input_lock()
	if state == 0 and int(data.get("round", 1)) > 1:
		for b in get_tree().get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()
		if _level0 != null and _level0.has_method("reset_destructibles"):
			_level0.reset_destructibles()
	elif state == 3:   # MATCH_OVER
		_match_ended = true
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
			_pause_menu = null
		_menu_open = false
		_refresh_input_lock()
		_show_result()

# 构建结算界面所需的数据载荷
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_duel(_last_round_state, _names, PvpSession.role)


# 对手中途断线处理：提示对手离开并在短暂延迟后返回主菜单
func _on_opponent_left() -> void:
	if _match_ended or _local == null:
		return
	_match_ended = true
	_cancel_reconnect()
	print("[pvp] 对手已离开(2.5s 后回主菜单)")
	if _hud != null:
		_hud.show_notice("对手已离开", "对局结束")
	var tree := get_tree()
	var netbus := NetBus
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		netbus.stop()
		if not is_inside_tree():
			return
		Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))

# 1v1 模式阵营染色规则：P1 保持蓝色基础色，P2 固定应用青色调制
# 仅对角色精灵图本体进行色调调整，不影响受击闪白与武器外观
func _apply_p2_tint() -> void:
	var body: Node = null
	if PvpSession.role == 2 and _local != null:
		body = _local.get_node_or_null("AnimatedSprite2D")
	elif PvpSession.role == 1 and _remote_replica != null:
		body = _remote_replica.get_node_or_null("AnimatedSprite2D")
	if body == null:
		return
	_apply_tint(body, 0.0, UiFactory.C_TEAM_B)

# 1v1 模式统一采用固定阵营染色，忽略自定义个性化色相配置
func _apply_peer_hues(_hues: Dictionary) -> void:
	_apply_p2_tint()

# 根据服务端同步的玩家信息设置头顶昵称
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
	_ensure_id_labels()
	if _id_self == null or _id_opp == null:
		return
	var me := PvpSession.role
	var opp := 3 - me
	var nm_self := str(names.get(me, PvpSession.player_name))
	var nm_opp := str(names.get(opp, "对手"))
	_id_self.set_label(nm_self, NAME_COLOR)
	_id_opp.set_label(nm_opp, NAME_COLOR)

func _ensure_id_labels() -> void:
	if _world == null:
		return
	if _id_self == null:
		_id_self = load("res://ui/factory/world_label.gd").new()
		_world.add_child(_id_self)
	if _id_opp == null:
		_id_opp = load("res://ui/factory/world_label.gd").new()
		_world.add_child(_id_opp)

func _process(_delta: float) -> void:
	# 头顶文字吸附角色坐标，保持不受角色旋转影响
	if _id_self != null and _local != null:
		_id_self.global_position = _local.global_position + ID_HEAD_OFFSET
	if _id_opp != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_id_opp.global_position = (_remote_replica as Node2D).global_position + ID_HEAD_OFFSET
	# 对手生命条吸附在头顶文字上方
	if _hp_bar != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_hp_bar.global_position = (_remote_replica as Node2D).global_position + Vector2(0.0, -116.0)

# 获取对手镜像节点的引用（1v1 模式下排除本地角色）
func _replica_for(role: int) -> Node2D:
	return _remote_replica if int(role) != int(PvpSession.role) else null
