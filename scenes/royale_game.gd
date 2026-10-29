extends PvpMatchClient
# 大乱斗对局客户端(RoyaleServer 分支):Level0(pvp_mode) 世界 + 本地玩家(服务器渲染) + N-1 个远端副本 + 后处理 + 输入上报 + 快照消费 + RoyaleHud(左上角击杀排行榜);对手数量不定,按快照 roles 动态建副本。


# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色)
# ★ _level0(世界/Level0)已上提到基类(两个模式同名同义,子类不重复声明;重连补态那一路要在基类 _on_match_sync 里用它还原可破坏砖)。
var _hud: RoyaleHud = null

# ── C2 客户端预测(与 pvp_client 同一套)── 本地玩家由引擎自步进(读真实 Input,aim/手感 = 单机);本场景每物理帧在它步进前 note_post_step + reconcile,把服务器外部事件(复活瞬移/受击/击杀复位)收敛掉。

const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
# 角色色板(头顶 ID / 小地图点;本体染色仍走色相设置/peer_hues)。★ 取色处一律写 % ROLE_COLORS.size():16 色是为大乱斗 16 人上限准备的,色数少于人数就会有两人同色(头顶 ID 与地图点一起撞)。
# ★ 生成口径(可复算):色相 22.5° 等分(360/16),S = 0.45 / V = 1.0 的 pastel;换色/加人时按这个口径重算,别手挑。
const ROLE_COLORS: Array[Color] = [
	Color(1.00, 0.55, 0.55), Color(1.00, 0.72, 0.55), Color(1.00, 0.89, 0.55), Color(0.94, 1.00, 0.55),
	Color(0.78, 1.00, 0.55), Color(0.61, 1.00, 0.55), Color(0.55, 1.00, 0.66), Color(0.55, 1.00, 0.83),
	Color(0.55, 1.00, 1.00), Color(0.55, 0.83, 1.00), Color(0.55, 0.66, 1.00), Color(0.61, 0.55, 1.00),
	Color(0.78, 0.55, 1.00), Color(0.94, 0.55, 1.00), Color(1.00, 0.55, 0.89), Color(1.00, 0.55, 0.72),
]
var _id_labels: Dictionary = {}    # role(int) -> WorldLabel(含自己)
var _hp_bars: Dictionary = {}      # role(int) -> EnemyHpBar(仅他人,设置开启时)
var _hues: Dictionary = {}         # role(int) -> 色相(peer_hues 下发)

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
	Wire.local_snapshot_world.connect(_on_snapshot_world)
	Wire.local_snapshot_own.connect(_on_snapshot_own)
	Wire.local_bullet_spawn.connect(_on_bullet_spawn)
	Wire.local_beam_fired.connect(_on_beam_fired)   # 大乱斗非射手端激光视觉副本(与 pvp_client 同款)
	Wire.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()   # 拆砖的两条(格级 + 子格级)必须成对,见基类注释
	Wire.local_round_state.connect(_on_round_state)
	Wire.local_hit_confirm.connect(_on_hit_confirm)
	Wire.local_kill_event.connect(_on_kill_event)
	Wire.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
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
	_pause_menu = PauseMenu.new(true)
	# 本地输入锁必须宿主接线:PvP 不暂停树,不锁就是「菜单开着还能边跑边开枪」(这条曾被 set_server_rendered 掩盖,接 C2 后不补就是真的能)。
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 PvpMatchClient._begin_reconnect)
	add_child(_pause_menu)
	_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), Settings.pvp_color_hue)
	# ★ 进场主动拉一次(昵称/色相/生效选项/出生点):本场景此刻已建好并订阅齐了才开口要,故不存在「推给一个正在切场景的客户端」那个竞态。★ 判活再发(全仓纪律,与 pvp_game 那处逐字同款):定向可靠包,连接可能已经不可用。
	if Wire.can_send_to_server():
		Wire.send(WireKind.MATCH_SYNC, [])
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])







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
				r.set_meta("haste", bool(data.get("haste", false)))   # Beta:他人加速视效
				r.set_meta("rewind", bool(data.get("rewind", false)))   # Beta:他人回溯视效
				r.set_meta("trail", data.get("trail", []))
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
		# ★ 自己那一份刻意不消费:C2 下本地玩家由引擎自步进,权威整态走本人包(见 _on_snapshot_own);把世界包里自己那份写进玩家 = 每帧把权威位置强写进正在预测的玩家 = 橡皮筋,别顺手补回来。
		# 清理已离开玩家(掉线者从快照消失):副本/头顶 ID/血条一并移除。
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			_remove_replica(int(role_str))
# 本人包:只有自己需要的 ack_seq + 权威整态 c2,C2 下喂 rollback 控制器;拆包的好处是它与世界包互不连累 —— c2 丢只少一个回滚锚点(下一个快照补上),世界包丢只让副本插值冻结一帧。


# 懒建远端副本(按快照里出现的 role)—— 大乱斗对手数量不定。
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "ReplicaP%d" % role
	_world.add_child(replica)
	_replicas[role] = replica
	_ensure_id_label(role)
	_apply_tint(replica.get_node_or_null("AnimatedSprite2D"), float(_hues.get(role, 0.0)))
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar
	_refresh_names()


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


# 服务器权威开火(激光):逐点锚到射手副本当前渲染位置再整条画(与 pvp_client._on_beam_fired 的唯一差别:大乱斗按 shooter_role 取锚点)。★ 必须走 NetBus(不是 NetBusExt):发送端 match_host 用的是 Wire.rpc_id,收在 NetBusExt 上会静默 no-op。



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
	if not Wire.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		Wire.send(WireKind.SUICIDE_REQUEST, [])


# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22)。
# 大乱斗只覆写这一处差异:**第二条 MATCH_OVER 不再重复消费**(它把 _match_ended 当幂等闩,
# 门内只做一次挂载;而 1v1/3v3 的第二条载荷必须刷新结算页,故基类默认是"每次都消费")。
func _should_handle_match_over() -> bool:
	return not _match_ended


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_royale(_last_round_state, _names, PvpSession.role)


# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。★ 不要连回 Wire.local_peer_info —— 那条推送路径在本项目已不存在(worker 不再广播),连上去会让本载荷走两条路。
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
	_ensure_id_label(PvpSession.role)
	_refresh_names()

var _names: Dictionary = {}   # role(int) -> 昵称(peer_info 下发)

# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取);★ 不要连回 Wire.local_peer_hues,同 _apply_peer_names 的告警。
func _apply_peer_hues(hues: Dictionary) -> void:
	_hues = hues
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"),
					float(_hues.get(role, 0.0)))

func _ensure_id_label(role: int) -> void:
	if _world == null or _id_labels.has(role):
		return
	var lbl: Node2D = load("res://ui/factory/world_label.gd").new()
	_world.add_child(lbl)
	_id_labels[role] = lbl

func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		var col: Color = ROLE_COLORS[(role - 1) % ROLE_COLORS.size()]
		(_id_labels[role] as Node2D).set_label(nm, col)


# 服务器下发生效选项:同步禁用武器。应用函数(不是信号回调):唯一入口 = _on_match_sync;★ 不要连回 Wire.local_match_options,同 _apply_peer_names 的告警。

func _process(_delta: float) -> void:
	for role in _id_labels:
		var target: Node2D = _local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + ID_HEAD_OFFSET
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + Vector2(0.0, -116.0)

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


# 他人点的颜色与头顶 ID 同源:都问 ROLE_COLORS[(role - 1) % ROLE_COLORS.size()]。
# ★ 跟头顶 ID 而不是跟身体:身体颜色是各人自设的色相(可能撞色、到达比小地图建立晚),而色板建点即可用;小地图上认人靠的是对回头顶那个名字。惰性求值(Minimap 每帧调一次),与 team_game 同款理由。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(ROLE_COLORS[(int(e[0]) - 1) % ROLE_COLORS.size()])
	return arr
