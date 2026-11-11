extends PvpMatchClient


var _hud: TeamHud = null

var _teams: Dictionary = {}


func _ready() -> void:
	_boot_world()
	# 副本集合 / 快照消费 / 头顶标签收进组合件(与大乱斗同一份);取色 Callable = _team_color(玩家之间不互挡,不再需要按队配碰撞层)。
	_replica_set = ReplicaSet.new()
	_replica_set.bind(state, ports,
			func(r: int) -> Color: return _team_color(r))
	_setup_beta_time_hud()
	# 小地图(多目标 + 队色):四个提供器同序一一对应(错位 = 队友点画成敌人色,不报错只误导人)。★ 后三个用具名方法而不是内联 lambda —— lambda 要以 return arr, 结尾才能带出数组,那是本仓没写过的形状。
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return state._local.global_position if state._local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable(self, "_minimap_self_color"))
		add_child(minimap)
	_hud = preload("res://ui/hud/team_hud.tscn").instantiate() as TeamHud
	add_child(_hud)
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	_pause_menu.toggled.connect(func(open: bool) -> void:
		state._menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())
	add_child(_pause_menu)
	print("进入对抗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var teams: Dictionary = payload.get("teams", {})
	if teams.is_empty():
		# 3v3 worker 的 team_map() 恒非空(队伍表由 --teams 显式传入),故这里到不了;真到这儿的话 _my_team 恒 0 ⇒ 赢的局会被 HUD 报成输的,故留一条痕而不是静默。
		push_warning("match_sync: 对抗载荷里没有 teams(队伍表没到 → HUD 判不出我方胜负)")
		return
	_apply_teams(teams)


func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	if _hud != null and is_instance_valid(_hud):
		# ★★ 这一行漏了不报错,后果是赢的局报成输的:_my_team 恒 0 ⇒ TeamHud 的 mwinner == _my_team and _my_team != 0 恒假 ⇒ 「本局胜利!」/「胜利!」两条文案一次都不会出现。
		_hud.set_my_team(_team_of_role(PvpSession.role))
	_refresh_team_colors()
	_apply_team_health_subsidy(teams)


func _apply_team_health_subsidy(teams: Dictionary) -> void:
	if state._local == null or not is_instance_valid(state._local):
		return
	var rules := TeamRules.subsidy(teams)
	var my_team := _team_of_role(PvpSession.role)
	var want := PlayerParams.player_max_hp
	if int(rules["hp_bonus"]) > 0 and int(rules["smaller_team"]) == my_team:
		want = PlayerParams.player_max_hp + int(rules["hp_bonus"])
	var c := state._local.get("combat") as CombatComponent
	if c == null or c.max_hp == want:
		return
	c.max_hp = want
	c.hp_changed.emit(c.hp, c.max_hp)


func _team_of_role(role: int) -> int:
	return int(_teams.get(role, 0))


func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	if n == state._local:
		return int(PvpSession.role)
	for role in _replicas:
		if _replicas[role] == n:
			return int(role)
	return 0


func _bullet_hits_entity(b: BulletBase, ent: Node2D) -> bool:
	var sr := _role_of_node(b.shooter)
	var er := _role_of_node(ent)
	if sr == 0 or er == 0:
		return true
	return _team_of_role(sr) != _team_of_role(er)


func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)


func _refresh_team_colors() -> void:
	if state._local != null and _team_of_role(PvpSession.role) != 0:
		_apply_tint(state._local.get_node_or_null("AnimatedSprite2D"), _team_color(PvpSession.role))
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"),
					_team_color(role))
	_replica_set.refresh_labels()


func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(_team_color(int(e[0])))
	return arr


# 「我」那个点的颜色与身体 / 头顶 ID 同源 —— 三处都问 _team_color(role)。
func _minimap_self_color() -> Color:
	return _team_color(PvpSession.role)




func _on_kill_event(killer: int, victim: int) -> void:
	if victim == PvpSession.role:
		CombatFeedback.reset_streak()
	elif killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(state._names.get(victim, "玩家%d" % victim)))


# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀,但按「不分死因」给对方队 +1);★ worker 侧闸门认 _team_mode。
# ★ 按键处理本身已上提到基类(与大乱斗逐字同一份);这里只声明"本模式开放这条路径"(1v1 不开放)。
func _supports_k_suicide() -> bool:
	return true


func _on_countdown_round() -> void:
	super._on_countdown_round()
	if NetBus.can_send_to_server():
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_team(_last_round_state, state._names, _teams,
			_team_of_role(PvpSession.role))
