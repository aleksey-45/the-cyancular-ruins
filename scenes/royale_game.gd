extends PvpMatchClient
# 大乱斗对局客户端(RoyaleServer 分支):Level0(pvp_mode) 世界 + 本地玩家(服务器渲染) + N-1 个远端副本 + 后处理 + 输入上报 + 快照消费 + RoyaleHud(左上角击杀排行榜);对手数量不定,按快照 roles 动态建副本。


# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色);★ 由 _replica_set 单写,本字段保留在宿主是因为 team_match_watcher 直接读它数副本
var _replica_set: ReplicaSet = null    # 副本集合 / 快照消费 / 头顶标签(与 3v3 共用的组合件,已 bind 到上面那份 _replicas)
# ★ _level0(世界/Level0)已上提到基类(两个模式同名同义,子类不重复声明;重连补态那一路要在基类 _on_match_sync 里用它还原可破坏砖)。
var _hud: RoyaleHud = null

# ── C2 客户端预测(与 pvp_client 同一套)── 本地玩家由引擎自步进(读真实 Input,aim/手感 = 单机);本场景每物理帧在它步进前 note_post_step + reconcile,把服务器外部事件(复活瞬移/受击/击杀复位)收敛掉。

# 角色色板(头顶 ID / 小地图点 / 本体染色同一个来源)。★ 取色处一律走 role_color()(内部 % size()):16 色是为大乱斗 16 人上限准备的,色数少于人数就会有两人同色(头顶 ID 与地图点一起撞)。
# ★ 生成口径(可复算):色相 22.5° 等分(360/16),S = 0.45 / V = 1.0 的 pastel;换色/加人时按这个口径重算,别手挑。
const ROLE_COLORS: Array[Color] = [
	Color(1.00, 0.55, 0.55), Color(1.00, 0.72, 0.55), Color(1.00, 0.89, 0.55), Color(0.94, 1.00, 0.55),
	Color(0.78, 1.00, 0.55), Color(0.61, 1.00, 0.55), Color(0.55, 1.00, 0.66), Color(0.55, 1.00, 0.83),
	Color(0.55, 1.00, 1.00), Color(0.55, 0.83, 1.00), Color(0.55, 0.66, 1.00), Color(0.61, 0.55, 1.00),
	Color(0.78, 0.55, 1.00), Color(0.94, 0.55, 1.00), Color(1.00, 0.55, 0.89), Color(1.00, 0.55, 0.72),
]


# 该 role 的统一取色(头顶 ID / 小地图 / 本体染色都问它)。★ 大乱斗没有"自选颜色":按 role 自动分配,玩家改不了。
static func role_color(role: int) -> Color:
	return ROLE_COLORS[(role - 1) % ROLE_COLORS.size()]


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
	# 与对手(层 2)物理碰撞:服务器侧 match_host 已给每个玩家 mask |= 2,客户端本地玩家也必须,否则本地预测直接穿过对手副本、服务器却挡住 ⇒ 每帧分歧回滚(C2 的无限回滚循环)。
	# 对手那一侧由 player_replica 的幽灵碰撞体提供(层 2)。★ 不改 player.tscn:那会让玩家掩码不再是 5,且单机不需要这一位。零守卫(enemy_logic_smoke 已删·2026-10-09)。
	local.collision_mask |= 2
	_local = local
	# C2:本地玩家跑预测(引擎自步进),控制器绑定;权威从本人包的 ack_seq/c2 喂入。★ 这里不再 set_server_rendered —— 服务器渲染那条路径已整体删除,全项目只剩一条联机链路。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。★ 不设 = 静默惰性(不报错,只是修复不生效)。零守卫:rollback_fidelity_probe 的源码守卫只扫 scenes/pvp_game.gd,不覆盖本文件。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 血条(他人,设置开启时;具体 role 的实例随副本在快照里懒建)。
	# 快照拆两条:① 世界包 = 全部玩家的渲染字段(副本/HUD 取它);② 本人包 = 自己的 ack_seq + c2(只有本人需要,C2 rollback 拿它锚定/重放)。
	# 副本集合 / 快照消费 / 头顶标签收进组合件(与 3v3 同一份);取色 Callable = role_color(大乱斗不区分队)。
	_replica_set = ReplicaSet.new()
	_replica_set.bind(self, _replicas, func(r: int) -> Color: return role_color(r))
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)   # 大乱斗非射手端激光视觉副本(与 pvp_client 同款)
	NetBus.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()   # 拆砖的两条(格级 + 子格级)必须成对,见基类注释
	NetBus.local_round_state.connect(_on_round_state)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	_subscribe_ground_weapons()   # 地面武器事件(开局那批走 match_sync,见 _on_match_sync)
	_subscribe_reconnect()        # 断线重连:服务器断开检测 + reclaim 成功后那条 match_start
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		# 四个提供器全部显式传(setup_multi 没有默认值)。★ 最后那个空 Callable() 是故意的:大乱斗没有「队色可与自己撞」的问题,自己那个点保持 SELF_COLOR、白描边不出现 —— 别把它当漏传。
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable())
		add_child(minimap)
	# HUD(左上角击杀排行榜)+ Esc 菜单。★ 必须声明式实例化场景,不能 RoyaleHud.new() —— 那个建出来的 CanvasLayer 没有子节点,HUD 的 @onready 全是 null、_ready 解引用必崩(零守卫:hud_declarative_probe 已删·2026-10-09)。
	_hud = preload("res://ui/hud/royale_hud.tscn").instantiate() as RoyaleHud
	add_child(_hud)
	_setup_beta_time_hud()   # Beta 时间玩法:怀表镜像(普通局内部自短路)
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	# 本地输入锁必须宿主接线:PvP 不暂停树,不锁就是「菜单开着还能边跑边开枪」(这条曾被 set_server_rendered 掩盖,接 C2 后不补就是真的能)。
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 ReconnectDriver._begin_reconnect(S-17 后重连状态机在 scenes/mp_client/reconnect_driver.gd))
	add_child(_pause_menu)
	_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), role_color(PvpSession.role))
	# ★ 进场主动拉一次(昵称/生效选项/出生点):本场景此刻已建好并订阅齐了才开口要,故不存在「推给一个正在切场景的客户端」那个竞态。★ 判活再发(全仓纪律,与 pvp_game 那处逐字同款):定向可靠包,连接可能已经不可用。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])







func _on_snapshot_world(snap: Dictionary) -> void:
	# 公共段(懒建/拆副本、套 apply_snapshot、血条、掉线清理)在 ReplicaSet.apply_world_snapshot,与 3v3 逐字同一份。
	_replica_set.apply_world_snapshot(snap)
# 本人包:只有自己需要的 ack_seq + 权威整态 c2,C2 下喂 rollback 控制器;拆包的好处是它与世界包互不连累 —— c2 丢只少一个回滚锚点(下一个快照补上),世界包丢只让副本插值冻结一帧。


# 服务器权威开火(激光):逐点锚到射手副本当前渲染位置再整条画(与 pvp_client._on_beam_fired 的唯一差别:大乱斗按 shooter_role 取锚点)。★ 必须走 NetBus(不是 NetBusExt):发送端 match_host 用的是 NetBus.rpc_id,收在 NetBusExt 上会静默 no-op。



# 击杀播报:我击杀对手 ⇒ 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)。
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零

# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀)。
func _unhandled_input(event: InputEvent) -> void:
	if _match_ended or _local == null:
		return
	# ★ 判活再发(全仓纪律):按 K 的那一刻连接可能已经不可用,而这是定向可靠包 ⇒ 不判就是那条 channel 0 错误。
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22)。
# 大乱斗只覆写这一处差异:**第二条 MATCH_OVER 不再重复消费**(它把 _match_ended 当幂等闩,
# 门内只做一次挂载;而 1v1/3v3 的第二条载荷必须刷新结算页,故基类默认是"每次都消费")。
func _should_handle_match_over() -> bool:
	return not _match_ended


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_royale(_last_round_state, _names, PvpSession.role)


# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。★ 不要连回 NetBus.local_peer_info —— 那条推送路径在本项目已不存在(worker 不再广播),连上去会让本载荷走两条路。
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
	_replica_set.ensure_label(PvpSession.role)
	_replica_set.refresh_labels()

var _names: Dictionary = {}   # role(int) -> 昵称(peer_info 下发)

# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。★ 不要连回 NetBusExt.local_peer_hues —— 颜色已无推送路径。
func _apply_role_colors() -> void:
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), role_color(int(role)))
	if _local != null:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), role_color(PvpSession.role))


# 服务器下发生效选项:同步禁用武器。应用函数(不是信号回调):唯一入口 = _on_match_sync;★ 不要连回 NetBusExt.local_match_options,同 _apply_peer_names 的告警。

# 头部 ID / 血条的跟随与上图都在 ReplicaSet;本场景只留调用(锚点偏移的单一来源 = WorldLabel)。
func _process(_delta: float) -> void:
	_replica_set.follow(WorldLabel.HEAD_OFFSET)

# 对手副本访问器(大乱斗:按 role 动态)。
func _all_replicas() -> Array:
	return _replicas.values()   # Beta 时间视效:遍历全部对手副本


func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null


# ── 小地图的点位与配色(大乱斗)──
# ★★ 位置与颜色必须共用同一份 entries(纪律来自 3v3,见 team_game._minimap_entries):Minimap 按下标取色,而副本是懒建的、又会 erase ⇒ 各写一份 for r in _replicas 时,「副本已 queue_free、尚未从 _replicas 摘掉」那个窗口会让两个数组错位一格 = 某人的点画成别人的颜色,不报错、只误导人。
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


# 他人点的颜色与头顶 ID 同源:都问 role_color(role)。
# ★ 跟头顶 ID 而不是身体 modulate:色板建点即可用;小地图上认人靠的是对回头顶那个名字。惰性求值(Minimap 每帧调一次),与 team_game 同款理由。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(role_color(int(e[0])))
	return arr
