extends PvpMatchClient
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。


# ── C2 客户端预测 ── 本地玩家跑全量本地 sim 预测 + PredictionRollback 权威锚定重放;引擎照常自步进(读真实 Input,aim/手感 = 单机),本客户端每帧在玩家步进前 reconcile,并把每 tick 的预测整态/输入记录喂给控制器。
# ★ 原 LOCAL_PREDICTION_ENABLED 开关与 server_rendered 保底分支已整体删除 —— 全项目只剩这一条联机链路,大乱斗客户端走同一套。
# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。

var _remote_replica: Node2D = null
# ★ _level0(世界/Level0)已上提到基类(两个模式同名同义,子类不重复声明):换局复位砖与重连补态复位砖共用同一个字段。
var _hud: PvpHud = null

const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)   # 头顶 ID 的锚点偏移在 WorldLabel(HEAD_OFFSET / HP_BAR_OFFSET),本文件不再声明
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null    # 对手头顶血条(设置开启时创建)
var _minimap: Minimap = null      # 小地图(设置开启时创建)
# _names(role -> 昵称)已上提到基类:1v1 与两个 N-副本模式同名同义,本文件不再声明。

func _ready() -> void:
	# 三模式同构的引导(世界 / 出生点 / 幽灵碰撞位 / C2 控制器 / 环面尺寸 / 后处理 / 共用订阅 / match_sync 进场拉取)
	# 全在基类 _boot_world();本文件只留 1v1 独有的部分:单副本 / 对手血条 / 小地图 / HUD / 染色 / 暂停菜单。
	_boot_world()
	# 1v1 只有一个固定副本(大乱斗 / 3v3 是 N 个按 role 懒建,见 ReplicaSet)。
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	_world.add_child(replica)
	_remote_replica = replica
	if Settings.pvp_show_enemy_hp:
		_hp_bar = EnemyHpBar.new()
		_world.add_child(_hp_bar)
		_attach_opp_overheads()
	# 1v1 独有:对手离开这条终局信号(大乱斗 / 3v3 走 round_state 的「走光即弃权」,没有这条)。
	NetBus.local_opponent_left.connect(_on_opponent_left)
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
	# 打击反馈层(命中 X 标记/击杀播报)由 Level0 统一挂载,PvP 继承它。
	# P2 本体固定为青(UiFactory.C_TEAM_B),只染角色 AnimatedSprite2D 本体,武器/预瞄不染。
	_apply_p2_tint()
	# Esc 暂停菜单:PvP 不暂停树 ⇒ 对手实时;回主菜单先 NetBus.stop() 断连(worker 检测任一方断线即拆局)。
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 ReconnectDriver._begin_reconnect(S-17 后重连状态机在 scenes/mp_client/reconnect_driver.gd))
	add_child(_pause_menu)
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])




# 把本地玩家摆到权威出生点,只在开局倒计时里做 —— 已经打起来还硬拉等于把玩家从对局里拽走;正常路径下两者本就相同。


func _on_snapshot_world(world: Dictionary) -> void:
	if _local == null:
		return
	# 丢弃乱序旧快照(unreliable 通道可能乱序;应用旧快照会把玩家拉回过去位置)。
	var tier := int(world.get("tick", 0))
	if tier < _last_snap_tick:
		return
	_last_snap_tick = tier   # P1.5:DELTA 已在 NetBus 解码边界合并成完整 players(形状与增量前一致)
	var players_snap: Dictionary = world["players"]
	# ★ 自己那一份刻意不消费:C2 下本地玩家自步进,权威整态走本人包(见 _on_snapshot_own);把世界包里自己那份写进玩家 = 每帧把权威位置强写进正在预测的玩家 = 橡皮筋。
	var opp_role := 3 - PvpSession.role
	if _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
		var opp: Dictionary = players_snap.get(str(opp_role), {})
		if not opp.is_empty():
			_remote_replica.apply_snapshot(opp, _local.global_position, tier)
			if _hp_bar != null:
				_hp_bar.ratio = float(opp.get("hp", PlayerParams.player_max_hp)) 						/ float(PlayerParams.player_max_hp)
				# 倒地尸体不显示血条(线上 hp 已钳到 0,见 NetCodec;否则会读成"还活着")。
				_hp_bar.visible = not bool(opp.get("downed", false))

# 本人包:只有自己需要的 ack_seq + 权威整态 c2,C2 下喂 rollback 控制器;拆包的好处是它与世界包互不连累 —— c2 丢只少一个回滚锚点(下一个快照补上),世界包丢只让副本插值冻结一个快照间隔(16.7ms)。


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
	# ★ 与到达顺序无关的收口:若「服务器断开」先到(worker 收场两条消息同拍),重连循环已经在跑 —— 这里把它停掉,否则它会继续跑满 60 秒。
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

# P2(role 2)的本体颜色 —— 1v1 里唯一的染色规则:自己控 P2 ⇒ 染本地玩家,自己控 P1 ⇒ 染对手副本(只染角色 AnimatedSprite2D,武器不染)。
# ★ 颜色不可自选(2026-10-24 用户裁定):大厅不再有改色控件;1v1 固定蓝/青,3v3 固定队色,大乱斗按 role 自动取色。
func _apply_p2_tint() -> void:
	var body: Node = null
	if PvpSession.role == 2 and _local != null:
		body = _local.get_node_or_null("AnimatedSprite2D")
	elif PvpSession.role == 1 and _remote_replica != null:
		body = _remote_replica.get_node_or_null("AnimatedSprite2D")
	if body == null:
		return
	_apply_tint(body, UiFactory.C_TEAM_B)

# ── 1v1 颜色固定 ── 1v1 的染色只有「P2 = 青」这一条固定规则(P1 = 本体蓝即默认色);这里幂等重铺一次(重连补态也走同一入口)。
# ★ 唯一入口 = _on_match_sync 的基类钩子;不要连回任何推送路径(颜色推送已随大厅改色控件一起删除)。
func _apply_role_colors() -> void:
	_apply_p2_tint()

# 服务器下发的生效选项:同步禁用武器。

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
		_id_self = WorldLabel.new()
		_world.add_child(_id_self)
	if _id_opp == null:
		_id_opp = WorldLabel.new()
		_world.add_child(_id_opp)
	_attach_opp_overheads()

# 对手的头顶 ID / 血条交给副本自己每帧贴位(player_replica.attach_overhead):跟随逻辑属副本,不属对局场景根。
# 幂等(同一节点重复 attach 只更新偏移)—— ID 与血条建出来的时机不同,两条都走这一口。
func _attach_opp_overheads() -> void:
	if _remote_replica == null or not is_instance_valid(_remote_replica):
		return
	if _id_opp != null:
		_remote_replica.attach_overhead(_id_opp, WorldLabel.HEAD_OFFSET)
	if _hp_bar != null:
		_remote_replica.attach_overhead(_hp_bar, WorldLabel.HP_BAR_OFFSET)

func _process(_delta: float) -> void:
	# 自己那颗头顶 ID 跟本地玩家;对手的 ID / 血条由副本自己贴(见 _attach_opp_overheads)。
	WorldLabel.follow(_id_self, _local, WorldLabel.HEAD_OFFSET)

func _replica_for(role: int) -> Node2D:
	return _remote_replica if int(role) != int(PvpSession.role) else null
