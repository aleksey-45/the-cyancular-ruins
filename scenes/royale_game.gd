extends PvpMatchClient
# 大乱斗对局客户端(RoyaleServer 分支):Level0(pvp_mode) 世界 + 本地玩家(服务器渲染) + N-1 个远端副本 + 后处理 + 输入上报 + 快照消费 + RoyaleHud(左上角击杀排行榜);对手数量不定,按快照 roles 动态建副本。


# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。
# _replicas / _replica_set / _names 也已上提到基类(2026-11-02,与 3v3 逐字同一份);本文件不再声明。
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
	# 三模式同构的引导(世界 / 出生点 / 幽灵碰撞位 / C2 控制器 / 环面尺寸 / 后处理 / 共用订阅 / match_sync 进场拉取)
	# 全在基类 _boot_world();本文件只留大乱斗独有的部分:N 个懒建副本 / 小地图 / RoyaleHud / 暂停菜单 / 按 role 自动染色 / 退场文案。
	_boot_world()
	# 血条(他人,设置开启时;具体 role 的实例随副本在快照里懒建)。
	# 副本集合 / 快照消费 / 头顶标签收进组合件(与 3v3 同一份);取色 Callable = role_color(大乱斗不区分队)。
	_replica_set = ReplicaSet.new()
	_replica_set.bind(self, _replicas, func(r: int) -> Color: return role_color(r))
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
	# ★ 进场拉取的 match_sync 已由基类 _boot_world() 末尾发出(本场景在它返回后建 HUD / 小地图;应答要走网络 poll,最早下一帧)。
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])







# 服务器权威开火(激光):逐点锚到射手副本当前渲染位置再整条画(与 pvp_client._on_beam_fired 的唯一差别:大乱斗按 shooter_role 取锚点)。★ 必须走 NetBus(不是 NetBusExt):发送端 match_host 用的是 NetBus.rpc_id,收在 NetBusExt 上会静默 no-op。



# 击杀播报:我击杀对手 ⇒ 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)。
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零

# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀)。
# ★ 按键处理本身已上提到基类(与 3v3 逐字同一份);这里只声明"本模式开放这条路径"(1v1 不开放)。
func _supports_k_suicide() -> bool:
	return true


# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22)。
# 大乱斗只覆写这一处差异:**第二条 MATCH_OVER 不再重复消费**(它把 _match_ended 当幂等闩,
# 门内只做一次挂载;而 1v1/3v3 的第二条载荷必须刷新结算页,故基类默认是"每次都消费")。
func _should_handle_match_over() -> bool:
	return not _match_ended


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_royale(_last_round_state, _names, PvpSession.role)


# _apply_peer_names() / _names 已上提到基类(2026-11-02,与 3v3 逐字同一份):本文件不再覆写/声明。

# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。★ 不要连回 NetBusExt.local_peer_hues —— 颜色已无推送路径。
func _apply_role_colors() -> void:
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), role_color(int(role)))
	if _local != null:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), role_color(PvpSession.role))


# 服务器下发生效选项:同步禁用武器。应用函数(不是信号回调):唯一入口 = _on_match_sync;★ 不要连回 NetBusExt.local_match_options,同 _apply_peer_names 的告警。
# ★ _process / _all_replicas / _replica_for / _minimap_entries / _minimap_others 已上提到基类(2026-11-02,与 3v3 逐字同一份):
#   本文件只留 _minimap_colors —— 取色是两模式唯一真差异(大乱斗问 role_color,3v3 问 _team_color)。

# 他人点的颜色与头顶 ID 同源:都问 role_color(role)。
# ★ 跟头顶 ID 而不是身体 modulate:色板建点即可用;小地图上认人靠的是对回头顶那个名字。惰性求值(Minimap 每帧调一次),与 team_game 同款理由。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(role_color(int(e[0])))
	return arr
