extends PvpMatchClient
# 3v3 团队对局客户端(第三个对局场景,与 pvp_game / royale_game 同基类):Level0(pvp_mode) 世界 + 本地玩家(C2 客户端预测) + 5 个远端副本(懒建) + 后处理 + 输入上报 + 快照消费 + TeamHud(记分条按队号,不是 role)。
# 与另外两个客户端的差异只有三处:① 副本 5 个(结构与大乱斗逐字同款);② 队色覆盖个人色相 —— 本体染色(含自己那具)/ 头顶 ID / 小地图点位一律问 _team_color(role),peer_hues 在本模式是无效输入(基类钩子被覆写成只消费 teams,不是「染完再盖」);③ 队友不互挡的客户端一半(服务端那一半在 TeamHost._apply_team_layers)。★ ②③ 漏了的后果与「幽灵碰撞体缺失」同款:C2 每帧回滚。
# ★ 队伍表只从 match_sync 进来(与昵称/色相/生效选项同一条投递路径)。不要从 roles 推导:role 号由大厅「最小空闲号」分配、有人退出后会留空洞(3 人房里中间那位退掉 ⇒ 房里是 {1,3})。


# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色)
# ★ _level0(世界/Level0)已上提到基类(子类 _ready 里赋值;重连补态那一路要用它还原可破坏砖)。
var _hud: TeamHud = null

var _teams: Dictionary = {}

const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
var _id_labels: Dictionary = {}    # role(int) -> WorldLabel(含自己)
var _hp_bars: Dictionary = {}      # role(int) -> EnemyHpBar(仅他人,设置开启时)
var _names: Dictionary = {}        # role(int) -> 昵称(match_sync 下发)


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
	# 与其它玩家(层 2)物理碰撞 —— 这只是队伍表到达之前的临时态:服务器侧 TeamHost._apply_team_layers 按队配层,客户端在 _apply_teams 里用 _apply_team_collision() 跟上同一条契约(不同步 = 每帧分歧回滚),时间窗只有开局倒计时那几秒。★ 不要因为下面有 _apply_team_collision() 就把这一行删掉:队伍表到达前它是唯一的碰撞来源。
	local.collision_mask |= 2
	_local = local
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。★ 不设 = 静默惰性。零守卫:rollback_fidelity_probe 的源码守卫只扫 scenes/pvp_game.gd,不覆盖本文件。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()   # 拆砖的两条(格级 + 子格级)必须成对,见基类注释
	_setup_beta_time_hud()   # Beta 时间玩法:怀表镜像(普通局内部自短路)
	NetBus.local_round_state.connect(_on_round_state)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	_subscribe_ground_weapons()   # 地面武器事件(开局那批走 match_sync,见 _on_match_sync)
	_subscribe_reconnect()        # 断线重连:服务器断开检测 + reclaim 成功后那条 match_start
	# 小地图(多目标 + 队色):四个提供器同序一一对应(错位 = 队友点画成敌人色,不报错只误导人)。★ 后三个用具名方法而不是内联 lambda —— lambda 要以 return arr, 结尾才能带出数组,那是本仓没写过的形状。
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable(self, "_minimap_self_color"))
		add_child(minimap)
	# HUD(记分条按队号)+ Esc 菜单。★ 必须声明式实例化场景,不能 TeamHud.new() —— 那个建出来的 CanvasLayer 没有子节点,HUD 的 @onready 全是 null、_ready 解引用必崩(零守卫:hud_declarative_probe 已删·2026-10-09)。
	_hud = preload("res://ui/hud/team_hud.tscn").instantiate() as TeamHud
	add_child(_hud)
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 PvpMatchClient._begin_reconnect)
	add_child(_pause_menu)
	# ★ 自己那具的染色不在这里做,等队伍表(见 _refresh_team_colors):3v3 下自己是队色,与「看别人」同一份来源(个人色相在本模式整体停用)。此前这里传的是 Settings.pvp_color_hue,默认值 0 = 不改色 ⇒ 身体恒为本体蓝(= 队 1 的颜色,青队玩家因此看见自己与队 1 同色)。
	# ★ 别在这里补一句「表到达前先用 pvp_color_hue 兜一下」:那是给同一个语义开第二个来源,且会在倒计时里闪一次颜色;表真缺了则整局保持本体蓝,那条路已有 push_warning、不是静默。★ 进场主动拉一次(昵称/队伍/生效选项/出生点/地面武器/destroyed):本场景已建好并订阅齐了才开口要,故没有「推给一个正在切场景的客户端」那个竞态;★ 判活再发(全仓纪律)。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入 3v3:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# ── 队伍表:唯一入口 = 基类钩子 _apply_peer_hues_or_team(由 _on_match_sync 调)── ★ 落成钩子覆写而不是自己覆写整个 _on_match_sync:基类那份把「名字/颜色/选项/出生点校正/地面武器先清后灌/destroyed 补态」六件事写在一起,3v3 的差异只有颜色那一段换个来源;整段抄一遍 = 把两条纪律复制成两份,将来只改一处。
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var teams: Dictionary = payload.get("teams", {})
	if teams.is_empty():
		# 3v3 worker 的 team_map() 恒非空(队伍表由 --teams 显式传入),故这里到不了;真到这儿的话 _my_team 恒 0 ⇒ 赢的局会被 HUD 报成输的,故留一条痕而不是静默。
		push_warning("match_sync: 3v3 载荷里没有 teams(队伍表没到 → HUD 判不出我方胜负)")
		return
	_apply_teams(teams)


# 应用函数(不是信号回调)。★ 幂等:每次 match_sync(进场 / 换局重拉 / 重连补态)都会走一遍。
func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	if _hud != null and is_instance_valid(_hud):
		# ★★ 这一行漏了不报错,后果是赢的局报成输的:_my_team 恒 0 ⇒ TeamHud 的 mwinner == _my_team and _my_team != 0 恒假 ⇒ 「本局胜利!」/「胜利!」两条文案一次都不会出现。(★ 平局那一支不受影响:它走 else,_my_team 取什么值都念「平局」—— 别把这条契约写成「平局分支不可达」。)队号只能从队伍表读,不是 role。
		_hud.set_my_team(_team_of_role(PvpSession.role))
	_refresh_team_colors()
	_apply_team_collision()


func _team_of_role(role: int) -> int:
	return int(_teams.get(role, 0))


func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	if n == _local:
		return int(PvpSession.role)
	for role in _replicas:
		if _replicas[role] == n:
			return int(role)
	return 0


# 覆写基类:3v3 里队友副本不挡自己的子弹(规则:子弹穿透队友)。★ 基类默认「除射手外谁都能挡」对 1v1/大乱斗是对的;不覆写的话队友副本会把子弹吃掉,而服务器那边是穿过去的 ⇒ 客户端凭空少一颗子弹,且一条报错都没有。
func _bullet_hits_entity(b: BulletBase, ent: Node2D) -> bool:
	var sr := _role_of_node(b.shooter)
	var er := _role_of_node(ent)
	if sr == 0 or er == 0:
		return true        # 认不出队:退回基类语义(能挡),不静默改成"全穿透"
	return _team_of_role(sr) != _team_of_role(er)


# 队色统一收在这里:自己的染色、副本染色、头顶 ID、小地图点位都问它。★ 3v3 下个人色相不生效(peer_hues 被队色覆盖)—— 这是规则不是审美:6 个人里认不出队友,这个模式就没法玩;故 _apply_peer_hues_or_team 里不要再调 _apply_peer_hues。
func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)   # 无队伍(理论上到不了)→ 中性亮白


# 把队色刷到身体上。★ 机制收在 PvpMatchClient._apply_tint 的第三参(modulate 比值,不是直接乘队色 —— 那样蓝身体乘橙会变灰紫),这里的第三参就是「染成这个颜色」。
# ★★ 自己那具与副本走逐字同一条路:队色的单一来源只有 _team_color(_team_of_role(role)) 一处(此前自己那具传的是 Settings.pvp_color_hue,于是青队玩家看见自己是蓝色);个人色相在 3v3 整体停用(大乱斗那侧不受影响)。
# ★ 队号 0(队伍表还没到)时不染自己:_team_color(0) 返回中性亮白,糊在自己身上比保持本体蓝更糟;表一个 RTT 就到。
func _refresh_team_colors() -> void:
	if _local != null and _team_of_role(PvpSession.role) != 0:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(PvpSession.role))
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), 0.0,
					_team_color(role))
	_refresh_names()


# 副本幽灵体代表的那名玩家,其队号 → 幽灵体该放的碰撞层。★ 未知队号(0 / 表外 role / 表还没到)一律返回 2 —— 与服务端 _apply_team_layers 的「什么都不配 = 保持 _ready 的层 2」逐值对齐。
# 旧实现是 return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER —— 它把「未知」当成了队 2,于是两端对同一具身体放不同的层,两队掩码不同 ⇒ 队 2 玩家在服务端会被挡住、在客户端不会 ⇒ C2 每帧分歧。今天生产路径到不了这里(worker 的 team_map() 恒非空),修它是消除一个静默不对称。
func _ghost_layer_of(role: int) -> int:
	match _team_of_role(role):
		1:
			return 2
		2:
			return TeamHost.TEAM_ENEMY_LAYER
	return 2   # 表外 / 表未到:与服务端"什么都不配"(保持层 2)对齐,不再落到队 2 的层


# ── 队友不互挡:客户端那一半(服务端那一半在 TeamHost._apply_team_layers)── 契约(两边逐值对齐):1 队玩家 layer = 2、mask = 21(地形 1 | 敌人层 4 | 队 B 层 16);2 队玩家 layer = 16(TeamHost.TEAM_ENEMY_LAYER)、mask = 7(地形 1 | 敌人层 4 | 玩家层 2);副本幽灵体 mask 恒 0,layer 按它代表那名玩家的队。
# ★ 为什么必须分队位而不是改掩码:Godot 的碰撞按节点配,没有「按对」的开关。★ 两边 layer/mask 必须逐值相同:服务器是权威模拟、客户端是 C2 预测,掩码不同 = 同一帧两边可走空间不同 = 每帧分歧回滚(不是调参能缓解的)。★ 用常量不用字面量 16:层位是全局资源,将来可能挪。
func _apply_team_collision() -> void:
	if _local == null:
		return
	var my_team := _team_of_role(PvpSession.role)
	if my_team == 0:
		return   # 队伍表还没到 → 保持 `_ready` 里那句 `|= 2` 的临时态
	if my_team == 1:
		_local.collision_layer = 2
		_local.collision_mask = (_local.collision_mask & ~2) | TeamHost.TEAM_ENEMY_LAYER
	else:
		_local.collision_layer = TeamHost.TEAM_ENEMY_LAYER
		_local.collision_mask |= 2
	for role in _replicas:
		var r = _replicas[role]
		if r != null and is_instance_valid(r) and r.has_method("set_ghost_layer"):
			# ★ 副本的幽灵体按它代表那名玩家的队设:队友副本不挡我、敌人副本挡我。
			r.set_ghost_layer(_ghost_layer_of(int(role)))


# 小地图:两个提供器的共同遍历 —— 一次过滤、一份顺序来源。
# ★ 为什么必须共用而不是各写一份 for:ui/minimap.gd 是按下标对应的,两个数组错位一格就是「队友点画成敌人色」—— 不报错、只误导人;而错位最容易发生在「某个副本已 queue_free、尚未从 _replicas 抹掉」那个窗口里。★ 顺序:_replicas 是 Dictionary(保插入序),两次调用之间没有任何写入 ⇒ 两边逐项同序。
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


# 与 _minimap_others() 一一对应的颜色:队友点画队色,敌人点画对方队色(3v3 下「这是谁」比「是不是敌人」更需要一眼看出)。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(_team_color(int(e[0])))
	return arr


# 「我」那个点的颜色与身体 / 头顶 ID 同源 —— 三处都问 _team_color(role)。★ 惰性求值(每帧被 Minimap 调一次),不是建点时定色:队色由 match_sync 下发,比小地图建立晚。★ 自己那具的身体自 2026-09-21 起也走队色,本条让这个点跟上同一口径(此前它是恒定的 SELF_COLOR,与队色只差 Δ=(25,2,0),青队玩家分不清自己与队友)。
func _minimap_self_color() -> Color:
	return _team_color(PvpSession.role)


# 进场拉取的应答。★ 本文件不覆写 _on_match_sync(六件事全在基类),只覆写颜色那一段的钩子。


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
		# ★ 自己那一份刻意不消费:C2 下本地玩家由引擎自步进,权威整态走本人包(见 _on_snapshot_own);把世界包里自己那份写进玩家 = 每帧强写 = 橡皮筋。清理已离开玩家(掉线者从快照消失):副本/头顶 ID/血条一并移除。
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			_remove_replica(int(role_str))


# 懒建远端副本(按快照里出现的 role)—— 5 名对手数量固定但 role 号可能不连续(大厅按最小空闲号分配、有人退出后留空洞),故快照里出现才建。
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "ReplicaP%d" % role
	_world.add_child(replica)
	_replicas[role] = replica
	_ensure_id_label(role)
	# ★ 队色与幽灵体层必须在这里也补一次:副本是懒建的,而队伍表早在 match_sync 就到了 —— _apply_teams() 那一刻 _replicas 还是空的,只在那时刷的话,晚建的副本会停在无人色(默认蓝)且幽灵体恒在层 2(= 队友也挡我)⇒ 每帧回滚,两处都不报错。
	_apply_tint(replica.get_node_or_null("AnimatedSprite2D"), 0.0, _team_color(role))
	if replica.has_method("set_ghost_layer"):
		replica.set_ghost_layer(_ghost_layer_of(role))
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


# 击杀播报:我击杀对手 ⇒ 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)。★ 载荷仍是 role 粒度(射手 = 归因得到,0 = 无归因),协议不为团队改字段。
# ★★ 队号不在这一条链上:播报只把被击杀者的显示名交给 CombatFeedback.kill(名字),既没有队号也没有队色(队号在 TeamHud 记分条与头顶 ID 上)。播报规则与 1v1 / 大乱斗逐字同规则;★ killer == 0 的倒地在 3v3 也不播(队友误炸 / 溺水 / K 自杀这些无归因档)—— 别拿「计分不分死因」去反推播报,计分归属与「屏幕上要不要弹字」是两件事。
func _on_kill_event(killer: int, victim: int) -> void:
	if victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零
	elif killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))


# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀,但按「不分死因」给对方队 +1);★ worker 侧闸门认 _team_mode。
func _unhandled_input(event: InputEvent) -> void:
	if _match_ended or _local == null:
		return
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22):
# 清子弹 / 复位砖 / 输入锁 / 结算页挂载与刷新都是公共段;3v3 只多一件"换边后重拉 match_sync"。
# ★ MATCH_OVER 刻意**不**覆写"首次才消费"的闸(与大乱斗相反,别照抄):本模式终局之后还会再死人,
#   第二条终局载荷必须刷新结算页(见 TeamHost._finish_match 的既有注释)。
func _on_countdown_round() -> void:
	super._on_countdown_round()
	# ★★ 重拉 match_sync:3v3 每局整队换边,而 TeamHost.role_spawns() 返回的是当下那一份,
	#   客户端只在进场/重连拉过一次 ⇒ 换边后六端手里那份是旧侧的。不补发 second path 进 round_state
	#   (那是给同一份数据开第二条投递路径),改在这里拉 —— 本来就站在「清子弹 + 还原砖」这一拍上,
	#   且顺带把 ground_weapons 与 destroyed 一并对齐。
	if NetBus.can_send_to_server():
		# ★ 先置位再发:这条应答是补态口径(不是进场建态)—— 换边后 spawns 是新一侧而 PvpSession.spawn
		#   手里是旧一侧,两者必然不一致,照进场口径硬拉 = 每局边界刷一条假告警 + 一次多余瞬移。
		#   闸门与「重连补态」共用(_resync_pull_pending,读一次即清),不要新立一个标志。
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	# ★ my_team 取自 _team_of_role(PvpSession.role) —— 队伍表从 match_sync 来;队号 0(表还没到)时 _verdict_team 念「失败」而不是谎报胜利。
	return MatchResultPayload.for_team(_last_round_state, _names, _teams,
			_team_of_role(PvpSession.role))


# ── 名字 / 颜色 ── 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
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


# 头顶名按队色上色(大乱斗那份按 role 的 8 色板;1v1 那份中性亮白);★ 自己那颗也按队色 —— 六个名字里「我在哪一队」要一眼看出。
func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		(_id_labels[role] as Node2D).set_label(nm, _team_color(role))


func _process(_delta: float) -> void:
	for role in _id_labels:
		var target: Node2D = _local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + ID_HEAD_OFFSET
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + Vector2(0.0, -116.0)


func _all_replicas() -> Array:
	return _replicas.values()   # Beta 时间视效:遍历全部对手副本


func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null
