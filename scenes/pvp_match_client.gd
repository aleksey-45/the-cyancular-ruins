class_name PvpMatchClient
extends Node2D

const LaserVisual := preload("res://core/present/laser_visual.gd")
enum Phase { LOADING, ONLINE, RECONNECTING, OFFLINE }
var phase := Phase.LOADING
var _post: PostProcess
var _local: Player
var _world: SubViewport
var _level0: Level0
var _replicas: Dictionary = {}
var _proxies: Dictionary[int, ActorBody] = {}
var _projectiles: Dictionary[int, ProjectileVisual] = {}
var _projectile_events: Dictionary = {}
var _preview_projectiles: Dictionary[int, ProjectileVisual] = {}
var _preview_beams: Dictionary[int, Node2D] = {}
var _last_confirmed_beam := 0
var _pickup_nodes: Dictionary = {}
var _id_labels: Dictionary = {}
var _hp_bars: Dictionary = {}
var _names: Dictionary = {}
var _hues: Dictionary = {}
var _teams: Dictionary = {}
var _team_counts: Dictionary = {}
var _hud: PvpHud
var _pause_menu: PauseMenu
var _banner: StatusBanner
var _result: MatchResult
var _last_round_state := {"state": NetEvent.RoundState.COUNTDOWN}
var _rollback := PredictionRollback.new()
var _playback := SnapshotBuffer.new()
var _last_tick := -1
var _terrain_round := 0
var _pending_states: Dictionary[int, Dictionary] = {}
var _pending_events: Array = []
var _latest_players: Dictionary = {}
var _menu_open := false
var _terrain: Terrain

func _ready() -> void:
	process_priority = 1 # 场景准备之后更新角色表现，摄像机最后跟随。
	var baseline := PvpSession.baseline
	_level0 = preload("res://scenes/level_0.tscn").instantiate()
	_level0.pvp_mode = true
	_level0.map_info = baseline["map_info"]
	add_child(_level0)
	_world = _level0.get_node("WorldViewport")
	_local = _world.get_node("Player")
	_local.enable_manual_simulation()
	_local.interpolate_prediction = true
	var camera := _world.get_node("Camera2D") as Camera2D
	camera.target = _local.visuals
	camera.process_priority = 100
	_local.role = PvpSession.role
	_terrain = _level0.terrain
	_rollback.bind(_local, _step_proxies, CombatSimulator.new(_terrain, _world, true))
	_local.shot_presented.connect(_present_local_shot)
	_playback.map_px = _terrain.map_size
	_post = PostProcess.new()
	_post.world_viewport = _world
	_local.post_process = _post
	add_child(_post)
	_hud = preload("res://ui/hud/pvp_hud.tscn").instantiate()
	_hud.mode = PvpSession.room_mode
	add_child(_hud)
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock())
	add_child(_pause_menu)
	_banner = preload("res://ui/hud/status_banner.tscn").instantiate()
	add_child(_banner)
	_setup_beta_time_hud()
	if Settings.pvp_show_minimap:
		add_child(Minimap.new(_terrain, _local, _replicas, _role_color))
	NetBus.state_received.connect(_on_state)
	NetBus.event_received.connect(_on_event)
	NetBus.server_disconnected.connect(_begin_reconnect)
	NetBus.protocol_error.connect(_on_protocol_error)
	apply_baseline(baseline)
	for message: Array in PvpSession.match_events:
		_on_event(1, message[0], message[1])
	PvpSession.match_events.clear()
	PvpSession.loading_match = false

func apply_baseline(payload: Dictionary) -> void:
	phase = Phase.LOADING
	_names = payload["names"]
	_hues = payload["hues"]
	_teams = payload["teams"]
	# 阵容在基线到达时冻结，人数只计算一次，供血条与 HUD 复用。
	_team_counts = TeamRules.team_counts(_teams) if PvpSession.room_mode == PvpSession.MODE_TEAM else {}
	_tint(_local.animator, PvpSession.role)
	var round: int = payload["round_state"]["round"]
	if _terrain_round != 0 and round != _terrain_round:
		_terrain.reset()
	_terrain_round = round
	_terrain.apply_values(payload["sub_hp"])
	_terrain.flush_collisions()
	_level0.flush_terrain_visuals()
	_local.weapons.enabled_types = WeaponRegistry.enabled_ids(payload["options"].get("disabled_weapons", []))
	var my_team := int(_teams.get(PvpSession.role, 0))
	_local.collision_layer = CollisionWorld.team_layer(my_team)
	_local.team = my_team
	_local.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.team_layer(3 - my_team)
	_local._apply_layers()
	_hud.local_side = PvpSession.role
	if PvpSession.room_mode == PvpSession.MODE_TEAM:
		_hud.local_side = my_team
		_hud.team_target = TeamRules.kills_to_win(TeamRules.total_players(_team_counts))
	# 团队规则在恢复基线前固定；重连按基线恢复剩余 HP，不重置满血。
	_local.sim_max_hp = _max_hp_for(PvpSession.role)
	_clear_dynamics()
	var frame: Dictionary = payload["frame"]
	_terrain.revision = frame["map_revision"]
	_playback.reset()
	_install_world(frame)
	_rollback.reset(frame, NetBus.ping_ms)
	_on_round_state(payload["round_state"])
	phase = Phase.ONLINE
	_banner.set_text("")
	_local.correct_visual(_local.global_position, true)
	_refresh_input_lock()
	NetBus.send_event(NetEvent.Kind.READY, payload["round_state"]["round"])

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	if kind in NetEvent.MATCH_EVENTS:
		if phase == Phase.ONLINE:
			_pending_events.append([kind, data])
		return
	match kind:
		NetEvent.Kind.BASELINE: apply_baseline(data)
		NetEvent.Kind.ROOM:
			PvpSession.room = data
			if data["in_match"]:
				return
			phase = Phase.OFFLINE
			PvpSession.baseline.clear()
			Level0.safe_change_scene(get_tree(), "res://scenes/mp_lobby.tscn")
		NetEvent.Kind.REJOIN_DENIED:
			PvpSession.clear_rejoin()
			phase = Phase.OFFLINE
			_banner.set_text(data)
		NetEvent.Kind.ROOM_CLOSED:
			PvpSession.room = {}
			phase = Phase.OFFLINE
			NetSession.disconnect_client()
			Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")

func _apply_event(kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.TERRAIN:
			if data["revision"] > _terrain.revision:
				_terrain.apply_values(data["cells"])
				_terrain.revision = data["revision"]
		NetEvent.Kind.ROUND: _on_round_state(data)
		NetEvent.Kind.FIRE: _on_fire(data)
		NetEvent.Kind.BULLET_END:
			for id: int in data["ids"]:
				_rollback.queue_projectile_end(id, data["tick"])
				_projectile_event(id, data["tick"], null)
		NetEvent.Kind.EXPLOSION:
			var blast := CombatSimulator.blast_state(data["type_id"], data["pos"], data["tick"])
			_rollback.queue_projectile_end(data["id"], data["tick"], blast)
			_projectile_event(data["id"], data["tick"], null)
			_present_explosion(data)
		NetEvent.Kind.HIT:
			if data["shooter"] == PvpSession.role:
				CombatFeedback.hit_marker()
			var victim: int = data["victim"]
			if victim == _local.role:
				_rollback.queue_hit(data)
				if data["damage"] > 0:
					_local.play_hit_feedback(data["damage"])
			else:
				if _proxies.has(victim) and (data["hp"] <= 0 or data["impulse_mode"] != 0) \
						and data["epoch"] >= _latest_players[victim][PlayerStateSchema.REMOTE_EPOCH]:
					_rollback.queue_hit(data)
				if data["damage"] > 0 and _replicas.has(victim):
					_replicas[victim].play_hit()
		NetEvent.Kind.KILL:
			if data[1] == PvpSession.role:
				CombatFeedback.reset_streak()
			elif data[0] == PvpSession.role:
				CombatFeedback.kill(_names[data[1]])

func _on_state(frame: Dictionary) -> void:
	if phase == Phase.ONLINE and frame["tick"] > _last_tick:
		var revision: int = frame["map_revision"]
		if not _pending_states.has(revision) or frame["tick"] > _pending_states[revision]["tick"]:
			_pending_states[revision] = frame

func _apply_pending_authority() -> void:
	var started := PerformanceStats.begin()
	for item: Array in _pending_events:
		_apply_event(item[0], item[1])
	_pending_events.clear()
	_terrain.flush_collisions()
	var chosen: Dictionary = {}
	for revision: int in _pending_states.keys():
		var frame := _pending_states[revision]
		if frame["tick"] <= _last_tick:
			_pending_states.erase(revision)
		elif revision <= _terrain.revision:
			_pending_states.erase(revision)
			if chosen.is_empty() or frame["tick"] > chosen["tick"]:
				chosen = frame
	if not chosen.is_empty():
		_install_world(chosen)
	var previous := _local.corrected_position()
	var correction := _rollback.reconcile(chosen, NetBus.ping_ms)
	if correction != PredictionRollback.Correction.KEEP:
		if correction == PredictionRollback.Correction.SNAP:
			_step_proxies(_rollback.tick)
		_discard_beams_after(ShotRules.shot_id(_local.role, _local.shot_serial) | 0xff)
		_local.correct_visual(previous, correction == PredictionRollback.Correction.SNAP)
	PerformanceStats.end(PerformanceStats.CLIENT_AUTHORITY, started)

func _install_world(frame: Dictionary) -> void:
	_last_tick = frame["tick"]
	var world: Dictionary = frame["world"]
	_latest_players = world["players"]
	_playback.push(_last_tick, world)
	_sync_proxies()
	_sync_projectiles(world["projectiles"])
	_make_label(PvpSession.role)

func _sync_proxies() -> void:
	var combat := _rollback.combat
	for role: int in _proxies.keys():
		if not _latest_players.has(role):
			_proxies[role].free()
			_proxies.erase(role)
			if combat != null:
				combat.players.erase(role)
	for role: int in _latest_players:
		if role == _local.role or _proxies.has(role):
			continue
		var proxy: ActorBody = preload("res://core/sim/actor_body.tscn").instantiate()
		proxy.process_mode = Node.PROCESS_MODE_DISABLED
		proxy.role = role
		proxy.team = int(_teams.get(role, 0))
		_world.add_child(proxy)
		_proxies[role] = proxy
		if combat != null:
			combat.players[role] = proxy
	_step_proxies(_rollback.tick, true)

func _step_proxies(tick: int, after_move := false) -> void:
	for role: int in _proxies:
		var proxy := _proxies[role]
		var state: Array = _latest_players[role]
		var hit: Dictionary = _rollback.proxy_motion.get(role, {})
		var at := _last_tick
		var hp: int = state[PlayerStateSchema.REMOTE_HP]
		var facing: int = state[PlayerStateSchema.REMOTE_FACING]
		var downed: bool = state[PlayerStateSchema.REMOTE_DOWNED]
		var squat: bool = state[PlayerStateSchema.REMOTE_SQUAT]
		var respawn_tick: int = state[PlayerStateSchema.REMOTE_RESPAWN_TICK]
		var pos: Vector2 = state[PlayerStateSchema.REMOTE_POS]
		var vel: Vector2 = state[PlayerStateSchema.REMOTE_VEL]
		var knock: Vector2 = state[PlayerStateSchema.REMOTE_KNOCK_VEL]
		proxy.rewinding = state[PlayerStateSchema.REMOTE_REWIND]
		if not hit.is_empty() and _last_tick < hit["tick"] and hit["tick"] < tick \
				and (not proxy.rewinding or hit.has("epoch")):
			at = hit["tick"]
			hp = hit["hp"]
			downed = hp <= 0
			facing = hit["facing"]
			pos = hit["pos"]
			vel = hit["vel"]
			knock = hit["knock"]
			respawn_tick = 0
			proxy.rewinding = false
		var moved_tick := tick - int(not after_move and role > _local.role)
		var elapsed := 0 if proxy.rewinding else clampi(moved_tick - at, 0, SnapshotBuffer.MAX_EXTRAPOLATION)
		pos = SnapshotBuffer.project_position(pos, vel, knock, elapsed, _terrain.map_size)
		proxy.velocity = vel
		proxy.motion_knock_velocity = knock * pow(SnapshotBuffer.KNOCK_DECAY, elapsed)
		proxy.sim_hp = hp
		var shape_changed := proxy.sim_downed != downed or proxy.facing_direction != facing or proxy.is_squat != squat
		if shape_changed:
			proxy.facing_direction = facing
			proxy.is_squat = squat
			proxy.sim_downed = downed
			proxy.rotation = -PI / 2.0 * proxy.facing_direction if proxy.sim_downed else 0.0
		if shape_changed or pos != proxy.global_position:
			proxy.global_position = pos
			proxy.sync_collision_geometry()
		# 服务端在复活 tick 的角色移动结束后才换位置。
		var layer := 0 if respawn_tick > 0 and tick > respawn_tick else CollisionWorld.team_layer(proxy.team)
		if proxy.collision_layer != layer:
			proxy.collision_layer = layer
			proxy._apply_layers()

func _max_hp_for(role: int) -> int:
	if _team_counts.is_empty():
		return PlayerParams.player_max_hp
	return TeamRules.max_hp(int(_teams.get(role, 0)), _team_counts)

func _ensure_replica(role: int) -> void:
	if _replicas.has(role):
		return
	var replica: PlayerReplica = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.team = _teams.get(role, 0)
	replica.role = role
	replica.terrain = _terrain
	_world.add_child(replica)
	_world.move_child(replica, _level0.wall_layer.get_parent().get_index())
	replica.process_priority = 2
	_replicas[role] = replica
	replica.visible = false
	_make_label(role)
	_tint(replica.animator, role)
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar

func _projectile_event(id: int, tick: int, state: Variant) -> void:
	if tick <= _last_tick:
		if state == null:
			_remove_preview_projectile(id)
		return
	if _projectile_events.has(id):
		var previous: Array = _projectile_events[id]
		if tick < previous[0] or (tick == previous[0] and previous[1] == null):
			return
	_projectile_events[id] = [tick, state]
	if state == null:
		_remove_preview_projectile(id)
		_remove_projectile(id)
	else:
		_show_projectile(id, tick, state)

func _sync_projectiles(authoritative: Dictionary) -> void:
	var live := authoritative.duplicate()
	for id: int in _projectile_events.keys():
		var update: Array = _projectile_events[id]
		if update[0] <= _last_tick:
			_projectile_events.erase(id)
		elif update[1] == null:
			live.erase(id)
		else:
			live[id] = update[1]
	for id: int in _projectiles.keys():
		if not live.has(id):
			_remove_projectile(id)
	for id: int in live:
		var at: int = _projectile_events[id][0] if _projectile_events.has(id) else _last_tick
		_show_projectile(id, at, live[id])

func _show_projectile(id: int, tick: int, state: Dictionary) -> void:
	if not _projectiles.has(id):
		var type_id: int = state["type_id"]
		var view := _preview_projectiles.get(id) as ProjectileVisual
		if view != null and view.type_id == type_id:
			_preview_projectiles.erase(id)
		else:
			_remove_preview_projectile(id)
			view = _new_projectile_view(type_id, state["pos"])
		_projectiles[id] = view
	var role := id >> 48
	var rewinding: bool = _latest_players.has(role) and _latest_players[role][PlayerStateSchema.REMOTE_REWIND]
	_projectiles[id].sample(tick, state["pos"], state["vel"], rewinding)

func _new_projectile_view(type_id: int, pos: Vector2) -> ProjectileVisual:
	var view := ProjectileVisual.new()
	view.configure(_terrain, type_id, WeaponRegistry.definition(type_id)["size"])
	view.position = GridPathfinder.anchor_to_nearest(pos, _local.position, _terrain.map_size)
	_world.add_child(view)
	return view

func _remove_preview_projectile(id: int) -> void:
	if _preview_projectiles.has(id):
		_preview_projectiles[id].hide()
		_preview_projectiles[id].queue_free()
		_preview_projectiles.erase(id)

func _remove_projectile(id: int) -> void:
	if _projectiles.has(id):
		_projectiles[id].queue_free()
		_projectiles.erase(id)

func _present_explosion(data: Dictionary) -> void:
	ProjectileVisual.explosion(_world, data["pos"], _local, WeaponRegistry.blast_definition(data["type_id"])["radius"], _terrain)

func _sync_pickups(items: Dictionary) -> void:
	var anchor := _local.global_position
	var size := _terrain.map_size
	for id in items:
		var data: Array = items[id]
		var view: Sprite2D = _pickup_nodes.get(id)
		if view == null:
			view = WeaponPickup.make_view(WeaponRegistry.definition(data[PickupState.TYPE_ID]))
			view.scale = Vector2.ONE * WeaponPickup.WORLD_SCALE
			_world.add_child(view)
			_pickup_nodes[id] = view
		var offset := GridPathfinder.toroidal_delta_px(anchor, data[PickupState.POS], size)
		view.global_position = anchor + offset
		PickupPrompt.show_over(view, offset.length() <= PlayerParams.weapon_pickup_radius)
	for id in _pickup_nodes.keys():
		if not items.has(id):
			_pickup_nodes[id].queue_free()
			_pickup_nodes.erase(id)

func _physics_process(delta: float) -> void:
	if phase != Phase.ONLINE:
		_local.begin_visual_step()
		return
	var perf_started := PerformanceStats.begin()
	_apply_pending_authority()
	_rollback.capture(_local.sample_input(delta))
	var packet := _rollback.packet()
	NetBus.send_input(packet)
	_rollback.advance(delta, packet)
	PerformanceStats.end(PerformanceStats.CLIENT_TICK, perf_started)

func _process(delta: float) -> void:
	if phase != Phase.ONLINE:
		return
	var perf_started := PerformanceStats.begin()
	_level0.flush_terrain_visuals()
	_local.present_tick(delta)
	var render_tick := _rollback._clock - _rollback._rate * (1.0 - Engine.get_physics_interpolation_fraction())
	_local.present_prediction(delta, render_tick - _rollback.tick)
	for view: ProjectileVisual in _projectiles.values():
		view.present(delta, _local.position)
	_present_projectile_previews(delta)
	if _playback.frames.is_empty():
		PerformanceStats.end(PerformanceStats.CLIENT_PRESENT, perf_started)
		return
	var world := _playback.advance(delta)
	for role in world["players"]:
		if role != PvpSession.role:
			_ensure_replica(role)
	for role in _replicas.keys():
		var shown: bool = world["players"].has(role)
		_replicas[role].visible = shown
		_id_labels[role].visible = shown
		if _hp_bars.has(role):
			_hp_bars[role].visible = shown and not world["players"][role][PlayerStateSchema.REMOTE_DOWNED]
		if not shown and not _latest_players.has(role):
			_time_glows.erase(role)
			_replicas[role].queue_free()
			_replicas.erase(role)
			_id_labels[role].queue_free()
			_id_labels.erase(role)
			if _hp_bars.has(role):
				_hp_bars[role].queue_free()
				_hp_bars.erase(role)
	for role in world["players"]:
		if role == PvpSession.role or not _replicas.has(role):
			continue
		_replicas[role].render_snapshot(world["players"][role], _local.position)
		if _hp_bars.has(role):
			_hp_bars[role].ratio = float(world["players"][role][PlayerStateSchema.REMOTE_HP]) / maxf(float(_max_hp_for(role)), 1.0)
			_hp_bars[role].position = _replicas[role].position + Vector2(0, -108)
	_sync_pickups(world["pickups"])
	_tick_beta_time(delta, world)
	for role in _id_labels:
		var point: Vector2 = _local.visuals.global_position if role == PvpSession.role else _replicas[role].global_position
		_id_labels[role].position = point + Vector2(0, -78)
	PerformanceStats.end(PerformanceStats.CLIENT_PRESENT, perf_started)

func _make_label(role: int) -> void:
	if not _id_labels.has(role):
		var label := preload("res://ui/factory/world_label.gd").new()
		_world.add_child(label)
		_id_labels[role] = label
	_id_labels[role].set_label(_names.get(role, "玩家%d" % role), _role_color(role))

func _tint(body: CanvasItem, role: int) -> void:
	if PvpSession.room_mode != PvpSession.MODE_ROYALE:
		var team: int = _teams.get(role, role)
		var color := UiFactory.C_TEAM_A if team == 1 else UiFactory.C_TEAM_B
		body.modulate = Color(color.r / UiFactory.C_TEAM_A.r, color.g / UiFactory.C_TEAM_A.g, color.b / UiFactory.C_TEAM_A.b)
	elif not is_zero_approx(float(_hues.get(role, 0.0))):
		var material := ShaderMaterial.new()
		material.shader = preload("res://scenes/player/player_p2_hue.gdshader")
		material.set_shader_parameter("hue_shift", _hues[role])
		body.material = material

func _role_color(role: int) -> Color:
	if PvpSession.room_mode == PvpSession.MODE_ROYALE:
		var base := UiFactory.C_TEAM_A
		return Color.from_hsv(fposmod(base.h + float(_hues.get(role, 0.0)) / 360.0, 1.0), base.s, base.v)
	return UiFactory.C_TEAM_A if _teams.get(role, role) == 1 else UiFactory.C_TEAM_B

func _on_round_state(data: Dictionary) -> void:
	var ended: bool = _last_round_state["state"] == NetEvent.RoundState.MATCH_OVER
	_last_round_state = data
	_hud.show_round(data, _names)
	if data["state"] == NetEvent.RoundState.MATCH_OVER and not ended:
		_result = preload("res://ui/screens/match_result.tscn").instantiate()
		add_child(_result)
		_result.leave_requested.connect(func() -> void:
			_banner.set_text("等待其他玩家返回房间…")
			NetBus.send_event(NetEvent.Kind.LEAVE))
		var payload: Dictionary
		match PvpSession.room_mode:
			PvpSession.MODE_TEAM: payload = MatchResultPayload.for_team(data, _names, _teams, _teams[PvpSession.role])
			PvpSession.MODE_ROYALE: payload = MatchResultPayload.for_royale(data, _names)
			_: payload = MatchResultPayload.for_duel(data, _names, PvpSession.role)
		_result.show_result(payload)
	_refresh_input_lock()

func _refresh_input_lock() -> void:
	_local.input_frozen = phase != Phase.ONLINE or _menu_open \
			or _last_round_state["state"] != NetEvent.RoundState.PLAYING

func _present_local_shot(shot: Dictionary) -> void:
	var spec := WeaponRegistry.definition(shot["type_id"])
	if spec["attack"] != WeaponRegistry.Attack.BEAM:
		return
	var id := ShotRules.shot_id(_local.role, shot["serial"])
	if id <= _last_confirmed_beam:
		return
	var points: PackedVector2Array = ShotRules.trace_beam(_terrain, shot, spec)["points"]
	if is_instance_valid(_preview_beams.get(id)):
		LaserVisual.correct(_preview_beams[id], points, _local.position, _terrain.map_size)
	else:
		_preview_beams[id] = LaserVisual.play(_world, points, _local.position, _terrain.map_size)
	if _preview_beams.size() > PredictionRollback.KEEP:
		_preview_beams.erase(_preview_beams.keys()[0])

func _present_projectile_previews(delta: float) -> void:
	var live := _rollback.combat.projectiles
	for id: int in _preview_projectiles.keys():
		if not live.has(id) or _projectile_events.has(id) or _projectiles.has(id):
			_remove_preview_projectile(id)
	for bullet: BulletBody in live.values():
		var id := bullet.entity_id
		if bullet.shooter != _local or _projectiles.has(id) or _projectile_events.has(id):
			continue
		var view: ProjectileVisual = _preview_projectiles.get(id)
		if view == null or view.type_id != bullet.type_id:
			_remove_preview_projectile(id)
			view = _new_projectile_view(bullet.type_id, bullet.position)
			_preview_projectiles[id] = view
		view.sample(_rollback.tick, bullet.position, bullet.velocity_vec, _local.rewinding)
		view.present(delta, _local.position)

func _on_fire(shot: Dictionary) -> void:
	_rollback.queue_shot(shot)
	var role: int = shot["role"]
	var type_id: int = shot["type_id"]
	var spec := WeaponRegistry.definition(type_id)
	if role != _local.role:
		Sfx.play(spec["shot_sound"])
		if _replicas.has(role):
			_replicas[role].play_fire(type_id)
	var id := ShotRules.shot_id(role, shot["serial"])
	match spec["attack"]:
		WeaponRegistry.Attack.BEAM:
			_on_beam_fired(shot, id, spec)
		WeaponRegistry.Attack.PROJECTILE:
			var pos := GridPathfinder.wrap_to_range(shot["pos"], _terrain.map_size)
			var velocities := ShotRules.projectile_velocities(role, shot, spec)
			for pellet in velocities.size():
				_projectile_event(id | pellet, shot["tick"], {"type_id": type_id, "pos": pos, "vel": velocities[pellet]})

func _on_beam_fired(shot: Dictionary, id: int, spec: Dictionary) -> void:
	# 复算光束前，让排在它前面的地形补丁生效。
	_terrain.flush_collisions()
	var points: PackedVector2Array = ShotRules.trace_beam(_terrain, shot, spec)["points"]
	if id >> 48 == _local.role:
		_last_confirmed_beam = id
	if _preview_beams.has(id):
		if is_instance_valid(_preview_beams[id]):
			LaserVisual.correct(_preview_beams[id], points, _local.position, _terrain.map_size)
		_preview_beams.erase(id)
	else:
		LaserVisual.play(_world, points, _local.position, _terrain.map_size)

func _discard_beams_after(last_id: int) -> void:
	for id: int in _preview_beams.keys():
		if id > last_id:
			var beam: Variant = _preview_beams[id]
			if is_instance_valid(beam):
				beam.hide()
				beam.queue_free()
			_preview_beams.erase(id)

func _clear_dynamics() -> void:
	_pending_states.clear()
	_pending_events.clear()
	_rollback.proxy_motion.clear()
	_rollback.combat.clear()
	_rollback.combat.players = {_local.role: _local}
	_projectile_events.clear()
	_discard_beams_after(0)
	for id: int in _preview_projectiles.keys():
		_remove_preview_projectile(id)
	_last_confirmed_beam = 0
	for view: ProjectileVisual in _projectiles.values():
		view.queue_free()
	_projectiles.clear()
	for proxy: ActorBody in _proxies.values():
		proxy.free()
	_proxies.clear()
	for pickup in _pickup_nodes.values():
		pickup.queue_free()
	_pickup_nodes.clear()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_K \
			and phase == Phase.ONLINE and _last_round_state["state"] != NetEvent.RoundState.MATCH_OVER:
		NetBus.send_event(NetEvent.Kind.SUICIDE)

func _begin_reconnect() -> void:
	if phase != Phase.ONLINE:
		return
	phase = Phase.RECONNECTING
	_refresh_input_lock()
	_banner.set_text("正在重连…")
	var error := await NetSession.rejoin_room(true)
	if phase == Phase.RECONNECTING and is_inside_tree():
		phase = Phase.OFFLINE
		_banner.set_text("重连超时" if error == ERR_TIMEOUT else NetSession.room_error(error))

func _on_protocol_error(message: String) -> void:
	phase = Phase.OFFLINE
	_refresh_input_lock()
	_banner.set_text(message)

func _exit_tree() -> void:
	if phase == Phase.RECONNECTING:
		NetSession.disconnect_client()
	phase = Phase.OFFLINE
	_replicas.clear()
	NetBus.state_received.disconnect(_on_state)
	NetBus.event_received.disconnect(_on_event)
	NetBus.server_disconnected.disconnect(_begin_reconnect)
	NetBus.protocol_error.disconnect(_on_protocol_error)

var _time_glows: Dictionary = {}
var _time_film: ShaderMaterial
var _time_remote_film: ShaderMaterial
var _time_targets: Array = []
var _time_symbol: Label
var _time_coverage := 0.0
var _time_dim := 0.0
var _time_trail_timer := 0.0

func _setup_beta_time_hud() -> void:
	if not PvpSession.beta_mode:
		return
	var rules: Dictionary = PvpSession.baseline["options"]["time"]
	_rollback.time_economy = TimeEconomy.new(rules, [PvpSession.role])
	var watch := WatchHud.new(_rollback.time_economy.accounts[PvpSession.role])
	watch.position = Vector2(24, 124)
	add_child(watch)
	_time_film = ShaderMaterial.new()
	_time_film.shader = preload("res://scenes/effects/time_film.gdshader")
	_time_remote_film = _time_film.duplicate()
	_time_remote_film.set_shader_parameter("coverage", 1.0)
	for target in [_level0.wall_layer, _level0.water_layer, _level0.water_surface_layer, _local]:
		if target != null:
			_time_targets.append(target)
	_time_symbol = UiFactory.label("◁ ◁", 48, UiFactory.C_TEXT)
	_time_symbol.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_time_symbol.offset_top = 60
	_time_symbol.visible = false
	add_child(_time_symbol)
	_time_glows[PvpSession.role] = TimeGlow.attach(_local, Level0.GLOW_PLAYER)
	_time_glows[PvpSession.role].visible = false

func _tick_beta_time(delta: float, world: Dictionary) -> void:
	if not PvpSession.beta_mode:
		return
	var haste: bool = _local.pvp_haste_mult > 1.0
	_time_dim = move_toward(_time_dim, 1.0 if haste else 0.0, delta / 0.1)
	_time_coverage = move_toward(_time_coverage, 1.0 if _local.rewinding else 0.0, delta / 0.2)
	_post.set_time_effects(0, 0, _time_dim)
	_time_film.set_shader_parameter("coverage", _time_coverage)
	_time_symbol.visible = _local.rewinding
	for target: CanvasItem in _time_targets:
		target.material = _time_film if _time_coverage > 0 else null
	_time_glows[PvpSession.role].visible = haste
	_time_trail_timer -= delta
	var trail := _time_trail_timer <= 0
	if trail:
		_time_trail_timer = 0.06
		if haste:
			AfterImage.spawn(_world, _local.animator, UiFactory.C_TEAM_B)
	for role in world["players"]:
		if role == PvpSession.role:
			continue
		if not _time_glows.has(role):
			_time_glows[role] = TimeGlow.attach(_replicas[role], Level0.GLOW_ENEMY)
		var state: Array = world["players"][role]
		var remote_haste: bool = state[PlayerStateSchema.REMOTE_HASTE]
		var rewinding: bool = state[PlayerStateSchema.REMOTE_REWIND]
		_time_glows[role].visible = remote_haste and not rewinding
		_replicas[role].material = _time_remote_film if rewinding else null
		if trail and (remote_haste or rewinding):
			AfterImage.spawn(_world, _replicas[role].animator, UiFactory.C_TEAM_B if remote_haste else UiFactory.C_TEXT_DIM)
