extends PvpMatchClient



var _remote_replica: Node2D = null
var _hud: PvpHud = null

const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null
var _minimap: Minimap = null

func _ready() -> void:
	_boot_world()
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	state._world.add_child(replica)
	_remote_replica = replica
	if Settings.pvp_show_enemy_hp:
		_hp_bar = EnemyHpBar.new()
		state._world.add_child(_hp_bar)
		_attach_opp_overheads()
	NetBus.local_opponent_left.connect(_on_opponent_left)
	if Settings.pvp_show_minimap:
		_minimap = Minimap.new()
		_minimap.setup(
			func() -> Vector2: return state._local.global_position if state._local != null else Vector2.INF,
			func() -> Vector2:
				if _remote_replica != null and is_instance_valid(_remote_replica):
					return (_remote_replica as Node2D).global_position
				return Vector2.INF)
		add_child(_minimap)
	_hud = preload("res://ui/hud/pvp_hud.tscn").instantiate() as PvpHud
	add_child(_hud)
	_apply_p2_tint()
	_pause_menu = preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	_pause_menu.is_pvp = true
	_pause_menu.toggled.connect(func(open: bool) -> void:
		state._menu_open = open
		_refresh_input_lock()
		_recheck_disconnect())
	add_child(_pause_menu)
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])






func _on_snapshot_world(world: Dictionary) -> void:
	if state._local == null:
		return
	var tier := int(world.get("tick", 0))
	if tier < state._last_snap_tick:
		return
	state._last_snap_tick = tier
	var players_snap: Dictionary = world["players"]
	var opp_role := 3 - PvpSession.role
	if _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
		var opp: Dictionary = players_snap.get(str(opp_role), {})
		if not opp.is_empty():
			_remote_replica.apply_snapshot(opp, state._local.global_position, tier)
			if _hp_bar != null:
				_hp_bar.ratio = float(opp.get("hp", PlayerParams.player_max_hp)) 						/ float(PlayerParams.player_max_hp)
				_hp_bar.visible = not bool(opp.get("downed", false))





func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(state._names.get(victim, "对手")))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()




func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_duel(_last_round_state, state._names, PvpSession.role)


func _on_opponent_left() -> void:
	if state._match_ended or state._local == null:
		return
	state._match_ended = true
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

func _apply_p2_tint() -> void:
	var body: Node = null
	if PvpSession.role == 2 and state._local != null:
		body = state._local.get_node_or_null("AnimatedSprite2D")
	elif PvpSession.role == 1 and _remote_replica != null:
		body = _remote_replica.get_node_or_null("AnimatedSprite2D")
	if body == null:
		return
	_apply_tint(body, UiFactory.C_TEAM_B)

func _apply_role_colors() -> void:
	_apply_p2_tint()


func _apply_peer_names(names: Dictionary) -> void:
	state._names = names
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
	if state._world == null:
		return
	if _id_self == null:
		_id_self = WorldLabel.new()
		state._world.add_child(_id_self)
	if _id_opp == null:
		_id_opp = WorldLabel.new()
		state._world.add_child(_id_opp)
	_attach_opp_overheads()

func _attach_opp_overheads() -> void:
	if _remote_replica == null or not is_instance_valid(_remote_replica):
		return
	if _id_opp != null:
		_remote_replica.attach_overhead(_id_opp, WorldLabel.HEAD_OFFSET)
	if _hp_bar != null:
		_remote_replica.attach_overhead(_hp_bar, WorldLabel.HP_BAR_OFFSET)

func _process(_delta: float) -> void:
	WorldLabel.follow(_id_self, state._local, WorldLabel.HEAD_OFFSET)

func _replica_for(role: int) -> Node2D:
	return _remote_replica if int(role) != int(PvpSession.role) else null
