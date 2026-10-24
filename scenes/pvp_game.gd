extends PvpMatchClient
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。


# ── C2 客户端预测 ── 本地玩家跑全量本地 sim 预测 + PredictionRollback 权威锚定重放;引擎照常自步进(读真实 Input,aim/手感 = 单机),本客户端每帧在玩家步进前 reconcile,并把每 tick 的预测整态/输入记录喂给控制器。
# ★ 原 LOCAL_PREDICTION_ENABLED 开关与 server_rendered 保底分支已整体删除 —— 全项目只剩这一条联机链路,大乱斗客户端走同一套。
var _last_snap_tick := 0

var _remote_replica: Node2D = null
# ★ _level0(世界/Level0)已上提到基类(两个模式同名同义,子类不重复声明):换局复位砖与重连补态复位砖共用同一个字段。
var _hud: PvpHud = null

const ID_HEAD_OFFSET := Vector2(0.0, -78.0)   # 头顶文字位置(-100 略高,现往下压一点)
const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null    # 对手头顶血条(设置开启时创建)
var _minimap: Minimap = null      # 小地图(设置开启时创建)
var _names: Dictionary = {}       # role(int) -> 昵称(peer_info 下发;击杀播报取名字用)

func _ready() -> void:
	CombatComponent.pvp_arena = true   # PvP:取消命中无敌帧(每发结算一次)
	MazeGenerator.set_map_file(PvpSession.map_path)
	# 重算世界尺寸:_ready 启动时算的是随机 demo 图(8000 宽),PvP 固定图是 9600 宽;不重算则本地插值/回绕按错边界 ⇒ 玩家在图中间被空气墙弹走。
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 与对手(层 2)物理碰撞:服务器侧已给每个玩家 mask |= 2,客户端本地玩家也必须,否则本地预测直接穿过对手副本、服务器却挡住 ⇒ 每帧分歧回滚(C2 的无限回滚循环);对手那侧由 player_replica 的幽灵碰撞体提供。★ 不改 player.tscn(玩家掩码要保持 5,单机不需要这一位)。零守卫(enemy_logic_smoke 已删·2026-10-09)。
	local.collision_mask |= 2
	_local = local
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。★ 不设 = 静默惰性(不报错,只是修复不生效),故 tests/probe/rollback_fidelity_probe 有源码守卫钉这一行。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)。
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	level0.get_node("WorldViewport").add_child(replica)
	_remote_replica = replica
	if Settings.pvp_show_enemy_hp:
		_hp_bar = EnemyHpBar.new()
		_world.add_child(_hp_bar)
	# 快照拆两条:① 世界包 = 全部玩家的渲染字段(副本/血条);② 本人包 = 自己的 ack_seq + c2(只有本人需要,C2 rollback 拿它锚定/重放)。
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()   # 拆砖的两条(格级 + 子格级)必须成对,见基类注释
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_opponent_left.connect(_on_opponent_left)
	NetBus.local_kill_event.connect(_on_kill_event)
	# 扩展节点(NetBusExt)三载荷:生效选项/角色色相/命中确认。与 beam_fired 不同节点是有意的(发送端 match_host 的 beam_fired 走 NetBus),别顺手统一。
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	_subscribe_ground_weapons()   # 地面武器事件(开局那批走 match_sync,见 _on_match_sync)
	_subscribe_reconnect()        # 断线重连:服务器断开检测 + reclaim 成功后那条 match_start
	if Settings.pvp_show_minimap:
		_minimap = Minimap.new()
		_minimap.setup(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			func() -> Vector2:
				if _remote_replica != null and is_instance_valid(_remote_replica):
					return (_remote_replica as Node2D).global_position
				return Vector2.INF)
		add_child(_minimap)
	_hud = preload("res://ui/hud/pvp_hud.tscn").instantiate() as PvpHud
	add_child(_hud)
	# 打击反馈层(命中 X 标记/击杀播报)由 Level0 统一挂载,PvP 继承它。★ 本行有意不写第二次挂载(不是漏写):CombatFeedback 的早退要求 current 已非空,而同帧第二次调用看到的还是 null,真会建出第二份 —— 后来者不要照别的分支把这一行补回来。
	# P2 本体固定为青(UiFactory.C_TEAM_B),只染角色 AnimatedSprite2D 本体,武器/预瞄不染。
	_apply_p2_tint()
	# Esc 暂停菜单:PvP 不暂停树 ⇒ 对手实时;回主菜单先 NetBus.stop() 断连(worker 检测任一方断线即拆局)。开关/退出由 PauseMenu 自理,但本地输入锁必须宿主接线 —— 不锁就是「菜单开着还能边跑边开枪」。
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 PvpMatchClient._begin_reconnect)
	add_child(_pause_menu)
	# ★ 进场主动拉一次(昵称/色相/生效选项/出生点):本场景已经建好、订阅齐了才开口要,故没有「推给一个正在切场景的客户端」那个竞态。★ 判活再发(全仓纪律):这是定向可靠包,连接可能已不可用 ⇒ 往已拆的 peer 发就是那条 Unable to send packet on channel 0;判据 can_send_to_server()。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])




# 把本地玩家摆到权威出生点,只在开局倒计时里做 —— 已经打起来还硬拉等于把玩家从对局里拽走;正常路径下两者本就相同。


func _on_snapshot_world(world: Dictionary) -> void:
	if _local == null:
		return
	# 丢弃乱序旧快照(unreliable 通道可能乱序;应用旧快照会把玩家拉回过去位置)。
	var tier := int(world.get("tick", 0))
	if tier < _last_snap_tick:
		return
	_last_snap_tick = tier
	var players_snap: Dictionary = world["players"]
	# ★ 自己那一份刻意不消费:C2 下本地玩家自步进,权威整态走本人包(见 _on_snapshot_own);把世界包里自己那份写进玩家 = 每帧把权威位置强写进正在预测的玩家 = 橡皮筋。
	var opp_role := 3 - PvpSession.role
	if _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
		var opp: Dictionary = players_snap.get(str(opp_role), {})
		if not opp.is_empty():
			_remote_replica.apply_snapshot(opp, _local.global_position, tier)
			if _hp_bar != null:
				_hp_bar.ratio = float(opp.get("hp", PlayerParams.player_max_hp)) 						/ float(PlayerParams.player_max_hp)

# 本人包:只有自己需要的 ack_seq + 权威整态 c2,C2 下喂 rollback 控制器;拆包的好处是它与世界包互不连累 —— c2 丢只少一个回滚锚点(下一个快照补上),世界包丢只让副本插值冻结一个快照间隔(下行 30Hz ⇒ 33ms)。


# 服务器权威开火(激光):原始 pts 在射手 canonical 系(可能隔整幅地图跨接缝),逐点锚到射手副本当前渲染位置再整条画(滞后约 1 tick 无碍);只画对手那发 —— 自己那发已由本地预测自画,再收服务器版会双光束。


func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "对手")))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零


# 服务器拆墙事件:客户端子弹是视觉副本不判伤害,用大伤害触发 damage_tile 走 Level0 拆墙渲染。

# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22):
# 1v1 不需要任何钩子 —— 默认行为就是「新一局清子弹 + 复位砖」+「每次 MATCH_OVER 都刷新结算页」。

func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_duel(_last_round_state, _names, PvpSession.role)


func _on_opponent_left() -> void:
	if _match_ended or _local == null:
		return
	_match_ended = true
	# ★ 与到达顺序无关的收口:若「服务器断开」先到(worker 收场两条消息同拍),重连循环已经在飞 —— 这里把它停掉,否则它会继续跑满 60 秒。
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

# P2(role 2)的本体颜色 —— 1v1 里唯一的染色规则:自己控 P2 ⇒ 染本地玩家,自己控 P1 ⇒ 染对手副本(只染角色 AnimatedSprite2D,武器不染)。★ 口径:P1 恒蓝、P2 恒青,用的是 3v3 队 2 那个 token(UiFactory.C_TEAM_B),机制在 PvpMatchClient._apply_tint 第三参(modulate 比值 = 目标色 / 本体主色)。
# ★ 不用色相旋转是数学上做不到(它保持 S/V,本体主色 S61 ⇒ 产不出目标色 S50);player_p2_hue.gdshader 没删,现在是个人色相那条路(大乱斗),本文件不引用。零守卫(hue_tint_probe 已删·2026-10-09)。

func _apply_p2_tint() -> void:
	var body: Node = null
	if PvpSession.role == 2 and _local != null:
		body = _local.get_node_or_null("AnimatedSprite2D")
	elif PvpSession.role == 1 and _remote_replica != null:
		body = _remote_replica.get_node_or_null("AnimatedSprite2D")
	if body == null:
		return
	_apply_tint(body, 0.0, UiFactory.C_TEAM_B)

# ── 个人色相在 1v1 整体停用 ── 载荷照旧到达(match_sync 的 hues),但本模式不消费:这里只把「P2 = 青」那条固定规则重铺一次。
# ★ 为什么停用:双方都用默认 Settings.pvp_color_hue = 0.0 时两个身体同为默认蓝,1v1 就没有「谁是谁」,而「分得出」是硬需求;该设置在大乱斗照旧消费(4~8 人靠颜色区分才有意义)。★ 唯一入口 = _on_match_sync,不要连回 NetBusExt.local_peer_hues(那条推送路径已不存在,连上去会让本载荷走两条路)。零守卫(hue_tint_probe 已删·2026-10-09)。
func _apply_peer_hues(_hues: Dictionary) -> void:
	_apply_p2_tint()   # 幂等:重铺 P2 那道固定染色(载荷内容一律忽略)

# 服务器下发的生效选项:同步禁用武器。★ 两端必须同表:本端 equip 对禁用槽会当场拒绝,而输入包里的切枪请求是无条件上行的 —— 服务器若无同一张表就会 equip 成功,两端槽位永久错位且静默;唯一入口 = _on_match_sync,不要连回 NetBusExt.local_match_options。

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
	if _id_self != null and _local != null:
		_id_self.global_position = _local.global_position + ID_HEAD_OFFSET
	if _id_opp != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_id_opp.global_position = (_remote_replica as Node2D).global_position + ID_HEAD_OFFSET
	if _hp_bar != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_hp_bar.global_position = (_remote_replica as Node2D).global_position + Vector2(0.0, -116.0)

func _replica_for(role: int) -> Node2D:
	return _remote_replica if int(role) != int(PvpSession.role) else null
