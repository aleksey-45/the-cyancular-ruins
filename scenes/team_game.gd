extends PvpMatchClient
# 3v3 团队对局客户端(第三个对局场景,与 pvp_game / royale_game 同基类):Level0(pvp_mode) 世界 + 本地玩家(C2 客户端预测) + 5 个远端副本(懒建) + 后处理 + 输入上报 + 快照消费 + TeamHud(记分条按队号,不是 role)。
# 与另外两个客户端的差异只有三处:① 副本 5 个(结构与大乱斗逐字同款);② 队色覆盖个人色 —— 本体染色(含自己那具)/ 头顶 ID / 小地图点位一律问 _team_color(role)(颜色不可自选,3v3 固定队色);③ 队友不互挡的客户端一半(服务端那一半在 TeamHost._apply_team_layers)。★ ②③ 漏了的后果与「幽灵碰撞体缺失」同款:C2 每帧回滚。
# ★ 队伍表只从 match_sync 进来(与昵称/色相/生效选项同一条投递路径)。不要从 roles 推导:role 号由大厅「最小空闲号」分配、有人退出后会留空洞(3 人房里中间那位退掉 ⇒ 房里是 {1,3})。


# _last_snap_tick 已上提到基类 PvpMatchClient(输入包的 st 字段读它;2026-10-24)。
# _replicas / _replica_set / _names 也已上提到基类(2026-11-02,与大乱斗逐字同一份);本文件不再声明。
# ★ _level0(世界/Level0)已上提到基类(重连补态那一路要用它还原可破坏砖)。
var _hud: TeamHud = null

var _teams: Dictionary = {}


func _ready() -> void:
	# 三模式同构的引导(世界 / 出生点 / 幽灵碰撞位 / C2 控制器 / 环面尺寸 / 后处理 / 共用订阅 / match_sync 进场拉取)
	# 全在基类 _boot_world();本文件只留 3v3 独有的部分:N 个懒建副本 / 队色 / 排位 HUD / 暂停菜单 / 换边重拉。
	_boot_world()
	# 副本集合 / 快照消费 / 头顶标签收进组合件(与大乱斗同一份);取色 Callable = _team_color,新建后按队补配幽灵层。
	_replica_set = ReplicaSet.new()
	_replica_set.bind(self, _replicas,
			func(r: int) -> Color: return _team_color(r), Callable(self, "_on_replica_created"))
	_setup_beta_time_hud()   # Beta 时间玩法:怀表镜像(普通局内部自短路)
	# 小地图(多目标 + 队色):四个提供器同序一一对应(错位 = 队友点画成敌人色,不报错只误导人)。★ 后三个用具名方法而不是内联 lambda —— lambda 要以 return arr, 结尾才能带出数组,那是本仓没写过的形状。
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable(self, "_minimap_self_color"))
		add_child(minimap)
	# HUD(记分条按队号)+ Esc 菜单。
	_hud = preload("res://ui/hud/team_hud.tscn").instantiate() as TeamHud
	add_child(_hud)
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())   # 菜单开着时收到的"服务器断开"在这里补(见 ReconnectDriver._begin_reconnect(S-17 后重连状态机在 scenes/mp_client/reconnect_driver.gd))
	add_child(_pause_menu)
	# ★ 自己那具的染色不在这里做,等队伍表(见 _refresh_team_colors):3v3 下自己是队色,与「看别人」同一份来源(颜色不可自选)。
	# ★ 别在这里补一句「表到达前先用某个默认色兜一下」:那是给同一个语义开第二个来源,且会在倒计时里闪一次颜色;表真缺了则整局保持本体蓝,那条路已有 push_warning、不是静默。
	# ★ 进场拉取的 match_sync 已由基类 _boot_world() 末尾发出(本场景在它返回后建 HUD / 小地图;应答要走网络 poll,最早下一帧)。
	print("进入对抗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# ── 队伍表:唯一入口 = 基类钩子 _apply_peer_hues_or_team(由 _on_match_sync 调)── ★ 落成钩子覆写而不是自己覆写整个 _on_match_sync:基类那份把「名字/颜色/选项/出生点校正/地面武器先清后灌/destroyed 补态」六件事写在一起,3v3 的差异只有颜色那一段换个来源;整段抄一遍 = 把两条纪律复制成两份,将来只改一处。
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var teams: Dictionary = payload.get("teams", {})
	if teams.is_empty():
		# 3v3 worker 的 team_map() 恒非空(队伍表由 --teams 显式传入),故这里到不了;真到这儿的话 _my_team 恒 0 ⇒ 赢的局会被 HUD 报成输的,故留一条痕而不是静默。
		push_warning("match_sync: 对抗载荷里没有 teams(队伍表没到 → HUD 判不出我方胜负)")
		return
	_apply_teams(teams)


# 应用函数(不是信号回调)。★ 幂等:每次 match_sync(进场 / 换局重拉 / 重连补态)都会走一遍。
func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	if _hud != null and is_instance_valid(_hud):
		# ★★ 这一行漏了不报错,后果是赢的局报成输的:_my_team 恒 0 ⇒ TeamHud 的 mwinner == _my_team and _my_team != 0 恒假 ⇒ 「本局胜利!」/「胜利!」两条文案一次都不会出现。
		_hud.set_my_team(_team_of_role(PvpSession.role))
	_refresh_team_colors()
	_apply_team_collision()
	_apply_team_health_subsidy(teams)


# 血量补贴的**客户端镜像**:服务端给少人方抬 max_hp(TeamHost._apply_health_subsidy),客户端必须算出同一个数 ——
func _apply_team_health_subsidy(teams: Dictionary) -> void:
	if _local == null or not is_instance_valid(_local):
		return
	var rules := TeamRules.subsidy(teams)
	var my_team := _team_of_role(PvpSession.role)
	var want := PlayerParams.player_max_hp
	if int(rules["hp_bonus"]) > 0 and int(rules["smaller_team"]) == my_team:
		want = PlayerParams.player_max_hp + int(rules["hp_bonus"])
	var c := _local.get("combat") as CombatComponent
	if c == null or c.max_hp == want:
		return
	c.max_hp = want
	# 只抬上限、不改当前血:当前血由下一份本人包(c2)带来,这里改了反而会被立刻覆盖。
	c.hp_changed.emit(c.hp, c.max_hp)


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


# 队色统一收在这里:自己的染色、副本染色、头顶 ID、小地图点位都问它。★ 3v3 下没有个人色(颜色不可自选);这是规则不是审美:6 个人里认不出队友,这个模式就没法玩。
func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)   # 无队伍(理论上到不了)→ 中性亮白


# 把队色刷到身体上。★ 机制收在 PvpMatchClient._apply_tint(modulate 比值,不是直接乘队色 —— 那样蓝身体乘橙会变灰紫)。
# ★★ 自己那具与副本走逐字同一条路:队色的单一来源只有 _team_color(_team_of_role(role)) 一处(颜色不可自选;3v3 固定蓝/青队色)。
# ★ 队号 0(队伍表还没到)时不染自己:_team_color(0) 返回中性亮白,糊在自己身上比保持本体蓝更糟;表一个 RTT 就到。
func _refresh_team_colors() -> void:
	if _local != null and _team_of_role(PvpSession.role) != 0:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), _team_color(PvpSession.role))
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"),
					_team_color(role))
	_replica_set.refresh_labels()


# 副本幽灵体代表的那名玩家,其队号 → 幽灵体该放的碰撞层。
# 旧实现是 return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER —— 它把「未知」当成了队 2,于是两端对同一具身体放不同的层,两队掩码不同 ⇒ 队 2 玩家在服务端会被挡住、在客户端不会 ⇒ C2 每帧分歧。今天生产路径到不了这里(worker 的 team_map() 恒非空),修它是消除一个静默不对称。
func _ghost_layer_of(role: int) -> int:
	match _team_of_role(role):
		1:
			return 2
		2:
			return TeamHost.TEAM_ENEMY_LAYER
	return 2   # 表外 / 表未到:与服务端"什么都不配"(保持层 2)对齐,不再落到队 2 的层


# ── 队友不互挡:客户端那一半(服务端那一半在 TeamHost._apply_team_layers)── 契约(两边逐值对齐):1 队玩家 layer = 2、mask = 21(地形 1 | 敌人层 4 | 队 B 层 16);2 队玩家 layer = 16(TeamHost.TEAM_ENEMY_LAYE。
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


# ── 小地图:本模式只留两处取色(点位遍历 _minimap_entries / _minimap_others 已上提到基类:与大乱斗逐字同一份)──
# ★ 位置与颜色必须共用同一份 entries 的纪律随基类走(见 PvpMatchClient._minimap_entries 的注释)。
# 与 _minimap_others() 一一对应的颜色:队友点画队色,敌人点画对方队色(3v3 下「这是谁」比「是不是敌人」更需要一眼看出)。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(_team_color(int(e[0])))
	return arr


# 「我」那个点的颜色与身体 / 头顶 ID 同源 —— 三处都问 _team_color(role)。
func _minimap_self_color() -> Color:
	return _team_color(PvpSession.role)


# 进场拉取的应答。★ 本文件不覆写 _on_match_sync(六件事全在基类),只覆写颜色那一段的钩子。
# ★ 世界快照 _on_snapshot_world() 已上提到基类「副本模式」段(2026-11-02,与大乱斗逐字同一份)。


# 副本新建后的 3v3 专属补配:幽灵体层必须在这里也补一次 —— 副本是懒建的,而队伍表早在 match_sync 就到了;_apply_teams() 那一刻 _replicas 还是空的,只在那时刷的话,晚建的副本幽灵体恒在层 2(= 队友也挡我)⇒ 每帧回滚,不报错。
func _on_replica_created(replica: Node, role: int) -> void:
	if replica.has_method("set_ghost_layer"):
		replica.set_ghost_layer(_ghost_layer_of(role))


# 击杀播报:我击杀对手 ⇒ 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)。★ 载荷仍是 role 粒度(射手 = 归因得到,0 = 无归因),协议不为团队改字段。
# ★★ 队号不在这一条链上:播报只把被击杀者的显示名交给 CombatFeedback.kill(名字),既没有队号也没有队色(队号在 TeamHud 记分条与头顶 ID 上)。播报规则与 1v1 / 大乱斗逐字同规则;★ killer == 0 的倒地在 3v3 也不播(队友误炸 / 溺水 / K 自杀这些无归因档)—— 别拿「计分不分死因」去反推播报,计分归属与「屏幕上要不要弹字」是两件事。
func _on_kill_event(killer: int, victim: int) -> void:
	if victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零
	elif killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))


# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀,但按「不分死因」给对方队 +1);★ worker 侧闸门认 _team_mode。
# ★ 按键处理本身已上提到基类(与大乱斗逐字同一份);这里只声明"本模式开放这条路径"(1v1 不开放)。
func _supports_k_suicide() -> bool:
	return true


# 回合状态的四态编排已收进基类 PvpMatchClient._on_round_state(2026-10-22):
func _on_countdown_round() -> void:
	super._on_countdown_round()
	# ★★ 重拉 match_sync:3v3 每局整队换边,而 TeamHost.role_spawns() 返回的是当下那一份,
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


# ── 名字 / 颜色 ──
