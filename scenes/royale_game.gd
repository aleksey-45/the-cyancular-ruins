extends PvpMatchClient


var _hud: RoyaleHud = null

# ── C2 客户端预测(与 pvp_client 同一套)── 本地玩家由引擎自步进(读真实 Input,aim/手感 = 单机);本场景每物理帧在它步进前 note_post_step + reconcile,把服务器外部事件(复活瞬移/受击/击杀复位)收敛掉。

const ROLE_COLORS: Array[Color] = [
	Color(1.00, 0.55, 0.55), Color(1.00, 0.72, 0.55), Color(1.00, 0.89, 0.55), Color(0.94, 1.00, 0.55),
	Color(0.78, 1.00, 0.55), Color(0.61, 1.00, 0.55), Color(0.55, 1.00, 0.66), Color(0.55, 1.00, 0.83),
	Color(0.55, 1.00, 1.00), Color(0.55, 0.83, 1.00), Color(0.55, 0.66, 1.00), Color(0.61, 0.55, 1.00),
	Color(0.78, 0.55, 1.00), Color(0.94, 0.55, 1.00), Color(1.00, 0.55, 0.89), Color(1.00, 0.55, 0.72),
]


static func role_color(role: int) -> Color:
	return ROLE_COLORS[(role - 1) % ROLE_COLORS.size()]


func _ready() -> void:
	_boot_world()
	# 血条(他人,设置开启时;具体 role 的实例随副本在快照里懒建)。
	# 副本集合 / 快照消费 / 头顶标签收进组合件(与 3v3 同一份);取色 Callable = role_color(大乱斗不区分队)。
	_replica_set = ReplicaSet.new()
	_replica_set.bind(state, ports, func(r: int) -> Color: return role_color(r))
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return state._local.global_position if state._local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable())
		add_child(minimap)
	_hud = preload("res://ui/hud/royale_hud.tscn").instantiate() as RoyaleHud
	add_child(_hud)
	_setup_beta_time_hud()
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	_pause_menu.toggled.connect(func(open: bool) -> void:
		state._menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())
	add_child(_pause_menu)
	_apply_tint(state._local.get_node_or_null("AnimatedSprite2D"), role_color(PvpSession.role))
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])










func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(state._names.get(victim, "玩家%d" % victim)))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()

# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀)。
# ★ 按键处理本身已上提到基类(与 3v3 逐字同一份);这里只声明"本模式开放这条路径"(1v1 不开放)。
func _supports_k_suicide() -> bool:
	return true


func _should_handle_match_over() -> bool:
	return not state._match_ended


# 结算页载荷的唯一来源。★ 只读状态、不碰节点树(适配器是纯函数);_last_round_state 是基类成员,本文件不再声明。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_royale(_last_round_state, state._names, PvpSession.role)



func _apply_role_colors() -> void:
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), role_color(int(role)))
	if state._local != null:
		_apply_tint(state._local.get_node_or_null("AnimatedSprite2D"), role_color(PvpSession.role))



# 他人点的颜色与头顶 ID 同源:都问 role_color(role)。
# ★ 跟头顶 ID 而不是身体 modulate:色板建点即可用;小地图上认人靠的是对回头顶那个名字。惰性求值(Minimap 每帧调一次),与 team_game 同款理由。
func _minimap_colors() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(role_color(int(e[0])))
	return arr
