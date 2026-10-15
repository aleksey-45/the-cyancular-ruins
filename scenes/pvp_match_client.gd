class_name PvpMatchClient
extends Node2D

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")
const Tunnel := preload("res://core/net/tunnel.gd")
enum Phase { LOADING, ONLINE, RECONNECTING, OFFLINE }
var phase := Phase.LOADING
var _post: PostProcess
var _local: CharacterBody2D
var _world: SubViewport
var _level0: Level0
var _replicas: Dictionary = {}
var _bullets: Dictionary = {}
var _pickup_nodes: Dictionary = {}
var _id_labels: Dictionary = {}
var _hp_bars: Dictionary = {}
var _names: Dictionary = {}
var _hues: Dictionary = {}
var _teams: Dictionary = {}
var _hud: CanvasLayer
var _pause_menu: PauseMenu
var _banner: StatusBanner
var _result: MatchResult
var _last_round_state := {"state": NetEvent.RoundState.COUNTDOWN}
var _rollback := PredictionRollback.new()
var _playback := SnapshotBuffer.new()
var _last_tick := -1
var _own_tick := -1
var _map_revision := 0
var _future_state: Dictionary = {}
var _authority_state: Dictionary = {}
var _latest_players: Dictionary = {}
var _menu_open := false
var _retry_started := 0
var _attempt_started := 0
var _log_at := Time.get_ticks_msec()
var _correction_log_at := 0
var _log_counts: Dictionary = {}
var _correction_max := 0.0
var _replay_max := 0
var _playback_capped := false
var _log_own: Dictionary = {}

func _ready() -> void:
	var started := Time.get_ticks_msec()
	GameLog.record("match_load", {"role": PvpSession.role, "mode": PvpSession.room_mode, "beta": PvpSession.beta_mode})
	process_priority = 1 # 场景准备之后更新角色表现，摄像机最后跟随。
	var baseline := PvpSession.baseline
	var file := FileAccess.open("user://network_map.cyrm", FileAccess.WRITE)
	file.store_buffer(baseline["map"])
	file.close()
	PvpSession.map_path = "user://network_map.cyrm"
	MazeGenerator.set_map_file(PvpSession.map_path)
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
	_level0 = preload("res://scenes/level_0.tscn").instantiate()
	add_child(_level0)
	_world = _level0.get_node("WorldViewport")
	_local = _world.get_node("Player")
	_local.set_physics_process(false)
	_local.interpolate_prediction = true
	var camera := _world.get_node("Camera2D") as Camera2D
	camera.target = _local.visuals
	camera.process_priority = 100
	_local.role = PvpSession.role
	_rollback.bind(_local)
	_playback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_post = PostProcess.new()
	_post.world_viewport = _world
	add_child(_post)
	var hud_path := "res://ui/hud/pvp_hud.tscn"
	if PvpSession.room_mode == PvpSession.MODE_TEAM:
		hud_path = "res://ui/hud/team_hud.tscn"
	elif PvpSession.room_mode == PvpSession.MODE_ROYALE:
		hud_path = "res://ui/hud/royale_hud.tscn"
	_hud = load(hud_path).instantiate()
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
		var minimap := Minimap.new()
		minimap.setup_multi(func() -> Vector2: return _local.position,
				_minimap_others, _minimap_colors, _minimap_self_color)
		add_child(minimap)
	NetBus.state_received.connect(_on_state)
	NetBus.event_received.connect(_on_event)
	multiplayer.server_disconnected.connect(_begin_reconnect)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	apply_baseline(baseline)
	for message: Array in PvpSession.match_events:
		_on_event(1, message[0], message[1])
	PvpSession.match_events.clear()
	PvpSession.loading_match = false
	GameLog.record("match_loaded", {"duration_ms": Time.get_ticks_msec() - started, "role": PvpSession.role})

func apply_baseline(payload: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	GameLog.record("baseline_begin", {"tick": payload["frame"]["tick"], "round": payload["round_state"]["round"],
			"map_bytes": payload["map"].size(), "terrain_cells": payload["sub_hp"].size()})
	phase = Phase.LOADING
	_names = payload["names"]
	_hues = payload["hues"]
	_teams = payload["teams"]
	_tint(_local.animator, PvpSession.role)
	_level0.reset_destructibles()
	for sub in payload["sub_hp"]:
		TileDefs.apply_sub_hp(sub, payload["sub_hp"][sub])
	_level0.flush_terrain_collision()
	var disabled: Array[int] = []
	for type_id in payload["options"].get("disabled_weapons", []):
		disabled.append(type_id)
	_local.weapons.set_enabled_types(disabled)
	_local.collision_layer = 16 if _teams.get(PvpSession.role, 0) == 2 else 2
	_local.team = _teams.get(PvpSession.role, 0)
	_local.collision_mask = 1 | (16 if _teams.get(PvpSession.role, 0) == 1 else 2)
	if _hud is TeamHud:
		_hud.set_my_team(_teams[PvpSession.role])
	_clear_dynamics()
	var frame: Dictionary = payload["frame"]
	_log_own = frame["own"]
	_local.restore_state(frame["own"]["state"])
	_rollback.reset(frame["own"]["epoch"], frame["own"]["ack"], frame["tick"], NetBus.ping_ms)
	_playback.reset()
	_last_tick = int(frame["tick"]) - 1
	_own_tick = _last_tick
	_map_revision = frame["map_revision"]
	_future_state.clear()
	_authority_state.clear()
	_on_round_state(payload["round_state"])
	phase = Phase.ONLINE
	_banner.set_text("")
	_on_state(frame)
	_process(0.0)
	for id in payload["projectiles"]:
		var data: Dictionary = payload["projectiles"][id]
		_restore_bullet(_create_bullet(id, data), data)
		_bullets[id].set_physics_process(not frame["world"]["players"][id >> 48]["rewind"])
	_local.correct_visual(_local.global_position, true)
	_refresh_input_lock()
	NetBus.send_event(NetEvent.Kind.READY, payload["round_state"]["round"])
	GameLog.record("baseline_ready", {"tick": frame["tick"], "epoch": frame["own"]["epoch"],
			"map_revision": _map_revision, "duration_ms": Time.get_ticks_msec() - started,
			"reconnect_ms": Time.get_ticks_msec() - _retry_started if _retry_started > 0 else 0})
	_retry_started = 0

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	if kind in [NetEvent.Kind.FIRE, NetEvent.Kind.HIT, NetEvent.Kind.KILL, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED]:
		GameLog.record("match_event", {"kind": NetEvent.Kind.keys()[kind], "tick": _last_tick, "payload": data})
	match kind:
		NetEvent.Kind.BASELINE: apply_baseline(data)
		NetEvent.Kind.TERRAIN: apply_terrain(data)
		NetEvent.Kind.ROUND: _on_round_state(data)
		NetEvent.Kind.BEAM: _on_beam_fired(data)
		NetEvent.Kind.BULLET_SPAWN: _create_bullet(data["id"], data)
		NetEvent.Kind.BULLET_REWIND: _on_bullet_rewind(data)
		NetEvent.Kind.FIRE:
			Sfx.play(data["sound"])
			if _replicas.has(data["role"]):
				_replicas[data["role"]].play_fire(data["type_id"])
		NetEvent.Kind.HIT:
			if data["shooter"] == PvpSession.role:
				CombatFeedback.hit_marker()
			if data["damage"] > 0:
				if data["victim"] == PvpSession.role:
					_local.play_hit_feedback(data["damage"])
				elif _replicas.has(data["victim"]):
					_replicas[data["victim"]].play_hit(data["pos"])
		NetEvent.Kind.KILL:
			if data[1] == PvpSession.role:
				CombatFeedback.reset_streak()
			elif data[0] == PvpSession.role:
				CombatFeedback.kill(_names[data[1]])
		NetEvent.Kind.ROOM:
			phase = Phase.OFFLINE
			PvpSession.room = data
			PvpSession.baseline.clear()
			Level0.safe_change_scene(get_tree(), "res://scenes/mp_lobby.tscn")
		NetEvent.Kind.REJOIN_DENIED:
			phase = Phase.OFFLINE
			_banner.set_text(data)
		NetEvent.Kind.ROOM_CLOSED:
			PvpSession.clear_rejoin()
			PvpSession.room.clear()
			phase = Phase.OFFLINE
			NetBus.stop()
			Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")

func apply_terrain(patch: Dictionary) -> void:
	if patch["revision"] <= _map_revision:
		return
	TileDefs.apply_sub_hp(patch["sub"], patch["hp"])
	_level0.flush_terrain_collision()
	_map_revision = patch["revision"]
	if not _future_state.is_empty() and _future_state["map_revision"] <= _map_revision:
		var frame := _future_state
		_future_state = {}
		_on_state(frame)

func _on_state(frame: Dictionary) -> void:
	_count_log("state_callbacks")
	if phase != Phase.ONLINE or frame["tick"] <= _last_tick:
		return
	if frame["tick"] > _own_tick:
		if _authority_state.is_empty() or frame["tick"] > _authority_state["tick"]:
			_authority_state = frame
	if frame["map_revision"] > _map_revision:
		_count_log("terrain_wait_states")
		if _future_state.is_empty() or frame["tick"] > _future_state["tick"]:
			_future_state = frame
		return
	if frame["map_revision"] < _map_revision:
		_count_log("old_terrain_states")
		return
	_last_tick = frame["tick"]
	_playback.push(frame["tick"], frame["world"])

func _apply_pending_authority() -> void:
	if not _authority_state.is_empty():
		_apply_authority(_authority_state)
		_authority_state = {}

func _apply_authority(frame: Dictionary) -> void:
	_log_own = frame["own"]
	_own_tick = frame["tick"]
	_local.rewinding = frame["own"]["rewind"]
	_local.input_buffer.epoch = frame["own"]["epoch"]
	var previous: Vector2 = _local.corrected_position()
	var before: Vector2 = _local.global_position
	var snap := _rollback.reconcile(frame["own"], frame["tick"], NetBus.ping_ms)
	var error := GridPathfinder.toroidal_delta_px(before, _local.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	_correction_max = maxf(_correction_max, error)
	_replay_max = maxi(_replay_max, _rollback.diagnostics["replay_ticks"])
	_count_log("reconciles")
	if not _rollback.diagnostics["reason"].is_empty():
		_count_log("reset_" + _rollback.diagnostics["reason"])
	if _rollback.diagnostics.has("retime_ticks"):
		_count_log("retimes")
	if error >= 8.0 and Time.get_ticks_msec() - _correction_log_at >= 1000:
		_correction_log_at = Time.get_ticks_msec()
		GameLog.record("prediction_correction", {"role": PvpSession.role, "tick": frame["tick"], "error_px": error,
				"before": before, "after": _local.global_position, "authority": frame["own"],
				"prediction": _rollback.diagnostics, "weapon": _local.weapons.log_state()})
	_local.correct_visual(previous, snap)
	_make_label(PvpSession.role)
	_latest_players = frame["world"]["players"]
	for role in _latest_players:
		if role != PvpSession.role:
			_ensure_replica(role)
			_replicas[role].set_ghost_layer(16 if _teams.get(role, 0) == 2 else 2)
			_replicas[role].apply_snapshot(_latest_players[role], _local.position, frame["tick"])
	for role in _replicas:
		if not _latest_players.has(role):
			_replicas[role].set_ghost_layer(0)
	if PvpSession.beta_mode:
		_on_time_state(frame["time"])

func _ensure_replica(role: int) -> void:
	if _replicas.has(role):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.team = _teams.get(role, 0)
	_world.add_child(replica)
	replica.process_priority = 2
	_replicas[role] = replica
	replica.visible = false
	_make_label(role)
	_tint(replica.animator, role)
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar

func _create_bullet(id: int, data: Dictionary) -> BulletBase:
	var role := id >> 48
	if role != PvpSession.role:
		_ensure_replica(role)
	var profile := WeaponRegistry.projectile_profile(data["type_id"])
	var bullet: BulletBase = profile["scene"].instantiate()
	bullet.entity_id = id
	bullet.type_id = data["type_id"]
	bullet.setup(data["vel"].normalized(), data["vel"].length(), profile["range"], profile["size"], profile["color"], null)
	bullet.gravity_factor = profile["gravity"]
	bullet.apply_damage = false
	bullet.position = GridPathfinder.anchor_to_nearest(data["pos"], _local.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	bullet.shooter = _local if role == PvpSession.role else _replicas[role]
	bullet.adjudicated_pos = bullet.position
	_world.add_child(bullet)
	_register_bullet(bullet)
	return bullet

func _restore_bullet(bullet: BulletBase, data: Dictionary) -> void:
	bullet.position = GridPathfinder.anchor_to_nearest(data["pos"], _local.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	bullet.velocity_vec = data["vel"]
	bullet.rotation = bullet.velocity_vec.angle()
	bullet.traveled = data["traveled"]
	bullet._fuse_active = data["fuse_active"]
	bullet._fuse_elapsed = data["fuse_elapsed"]
	bullet._fuse_duration = data["fuse_duration"]
	bullet.adjudicated_pos = bullet.position

func _on_bullet_rewind(data: Dictionary) -> void:
	_track_local_bullets()
	for id in _bullets.keys():
		if id >> 48 == data["role"] and not data["projectiles"].has(id):
			_bullets[id].queue_free()
	for id in data["projectiles"]:
		var state: Dictionary = data["projectiles"][id]
		var bullet: BulletBase = _bullets[id] if _bullets.has(id) else _create_bullet(id, state)
		_restore_bullet(bullet, state)
		bullet.set_physics_process(not data["rewind"])

func _track_local_bullets() -> void:
	for bullet: BulletBase in get_tree().get_nodes_in_group("bullet"):
		if bullet.shooter == _local and not bullet.is_queued_for_deletion() and not _bullets.has(bullet.entity_id):
			_register_bullet(bullet)

func _cull_bullet_contacts() -> void:
	for bullet: BulletBase in _bullets.values():
		if bullet.explodes or bullet.is_queued_for_deletion() or not bullet.is_physics_processing():
			continue
		var shooter_role := bullet.entity_id >> 48
		var from := bullet.adjudicated_pos
		var to := from + GridPathfinder.toroidal_delta_px(from, bullet.position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		bullet.adjudicated_pos = bullet.position
		for role in _latest_players:
			if role == shooter_role or _latest_players[role]["downed"]:
				continue
			if _teams.get(shooter_role, 0) != 0 and _teams[shooter_role] == _teams.get(role, 0):
				continue
			var pos: Vector2 = _local.position if role == PvpSession.role else _replicas[role].position
			var center := GridPathfinder.anchor_to_nearest(pos, from, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			if Geometry2D.get_closest_point_to_segment(center, from, to).distance_to(center) < BulletBase.PLAYER_HIT_RADIUS:
				bullet.queue_free()
				break

func _sync_pickups(world: Dictionary) -> void:
	for id in world["pickups"]:
		var data: Dictionary = world["pickups"][id]
		if not _pickup_nodes.has(id):
			var pickup: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
			pickup.configure(data["type_id"], id, data["mag"], data["vel"])
			_world.add_child(pickup)
			pickup.set_physics_process(false)
			_pickup_nodes[id] = pickup
	for id in _pickup_nodes.keys():
		if not world["pickups"].has(id):
			_pickup_nodes[id].queue_free()
			_pickup_nodes.erase(id)

func _register_bullet(bullet: BulletBase) -> void:
	var id := bullet.entity_id
	_bullets[id] = bullet
	_count_log("projectiles_created")
	bullet.tree_exiting.connect(func() -> void:
		if _bullets.get(id) == bullet:
			_count_log("projectiles_removed")
			if bullet.explodes:
				GameLog.record("explosive_removed", {"id": id, "type": bullet.type_id, "position": bullet.position, "tick": _own_tick})
			_bullets.erase(id))

func _physics_process(delta: float) -> void:
	if phase != Phase.ONLINE:
		_local.begin_visual_step()
		return
	_apply_pending_authority()
	_local._poll_pickup_drop(delta)
	var src: PlayerInput = _local.input_source
	_rollback.capture(src, _local.get_current_aim_dir(), int(_playback.render_tick),
			_local.weapons.take_uplink_switch(src.get_switch_index_pressed()))
	if not _rollback.actions.is_empty() and _rollback.actions[-1]["seq"] == _rollback.sequence:
		GameLog.record("input_action", {"role": PvpSession.role, "action": _rollback.actions[-1]})
	NetBus.send_input(_rollback.packet())
	_rollback.advance(delta)
	_track_local_bullets()
	_cull_bullet_contacts()
	_local.present_tick(delta)
	_post.set_downed(_local.is_downed())

func _process(delta: float) -> void:
	if Time.get_ticks_msec() - _log_at >= 1000:
		_log_sample()
	if phase != Phase.ONLINE:
		return
	var render_tick := _rollback._clock - _rollback._rate * (1.0 - Engine.get_physics_interpolation_fraction())
	_local.present_prediction(delta, render_tick - _rollback._sim_tick)
	if _playback.frames.is_empty():
		return
	var world := _playback.advance(delta)
	var capped: bool = _playback.render_tick >= _playback.frames[-1]["tick"] + SnapshotBuffer.MAX_EXTRAPOLATION
	if capped != _playback_capped:
		GameLog.record("playback_hold", {"held": capped, "latest_tick": _last_tick, "render_tick": _playback.render_tick})
		_playback_capped = capped
	for role in world["players"]:
		if role != PvpSession.role:
			_ensure_replica(role)
			if not _latest_players.has(role):
				_replicas[role].set_ghost_layer(0)
	for role in _replicas.keys():
		var shown: bool = world["players"].has(role)
		_replicas[role].visible = shown
		_id_labels[role].visible = shown
		if _hp_bars.has(role):
			_hp_bars[role].visible = shown
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
			_hp_bars[role].ratio = float(world["players"][role]["hp"]) / PlayerParams.player_max_hp
			_hp_bars[role].position = _replicas[role].position + Vector2(0, -108)
	_sync_pickups(world)
	for id in world["pickups"]:
		if _pickup_nodes.has(id):
			var pickup: WeaponPickup = _pickup_nodes[id]
			pickup.canonical_pos = world["pickups"][id]["pos"]
			pickup.set_anchor(_local.position)
			pickup.sync_render_from_canonical()
			pickup.set_prompt_visible(GridPathfinder.toroidal_delta_px(_local.position, pickup.canonical_pos, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length() <= PlayerParams.weapon_pickup_radius)
	_tick_beta_time(delta, world)
	for role in _id_labels:
		var point: Vector2 = _local.visuals.global_position if role == PvpSession.role else _replicas[role].global_position
		_id_labels[role].position = point + Vector2(0, -78)

func _make_label(role: int) -> void:
	if not _id_labels.has(role):
		var label := preload("res://ui/factory/world_label.gd").new()
		_world.add_child(label)
		_id_labels[role] = label
	_id_labels[role].set_label(_names.get(role, "AI%d" % role), _role_color(role))

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

func _minimap_others() -> Array:
	return _replicas.values().filter(func(replica: Node2D) -> bool: return replica.visible).map(func(replica: Node2D) -> Vector2: return replica.position)

func _minimap_colors() -> Array:
	var colors: Array = []
	for role in _replicas:
		if _replicas[role].visible:
			colors.append(_role_color(role))
	return colors

func _minimap_self_color() -> Color:
	return _role_color(PvpSession.role)

func _role_color(role: int) -> Color:
	if PvpSession.room_mode == PvpSession.MODE_ROYALE:
		var base := UiFactory.C_TEAM_A
		return Color.from_hsv(fposmod(base.h + float(_hues.get(role, 0.0)) / 360.0, 1.0), base.s, base.v)
	return UiFactory.C_TEAM_A if _teams.get(role, role) == 1 else UiFactory.C_TEAM_B

func _on_round_state(data: Dictionary) -> void:
	if data["state"] != _last_round_state["state"] or data.get("round", 1) != _last_round_state.get("round", 0):
		GameLog.record("round_state", data)
	var ended: bool = _last_round_state["state"] == NetEvent.RoundState.MATCH_OVER
	_last_round_state = data
	var hud_data := data.duplicate()
	hud_data["names"] = _names
	_hud._on_round_state(hud_data)
	if data["state"] == NetEvent.RoundState.MATCH_OVER and not ended:
		_result = preload("res://ui/screens/match_result.tscn").instantiate()
		add_child(_result)
		_result.leave_requested.connect(func() -> void:
			_banner.set_text("等待其他玩家返回房间…")
			NetBus.send_event(NetEvent.Kind.LEAVE))
		var payload: Dictionary
		match PvpSession.room_mode:
			PvpSession.MODE_TEAM: payload = MatchResultPayload.for_team(data, _names, _teams, _teams[PvpSession.role])
			PvpSession.MODE_ROYALE: payload = MatchResultPayload.for_royale(data, _names, PvpSession.role)
			_: payload = MatchResultPayload.for_duel(data, _names, PvpSession.role)
		_result.show_result(payload)
	_refresh_input_lock()

func _refresh_input_lock() -> void:
	_local.set_controls_locked(phase != Phase.ONLINE or _menu_open
			or _last_round_state["state"] != NetEvent.RoundState.PLAYING)

func _on_beam_fired(data: Dictionary) -> void:
	var points: PackedVector2Array = data["pts"]
	var anchor: Vector2 = _replicas[data["shooter_role"]].position if _replicas.has(data["shooter_role"]) else _local.position
	for i in points.size():
		points[i] = GridPathfinder.anchor_to_nearest(points[i], anchor, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	LaserVisual.spawn_muzzle_orb(_world, points[0], data["color"], data["half_width"], data["lifetime"])
	LaserVisual.spawn_beam(_world, points, data["half_width"], data["color"], data["lifetime"], data["style"])

func _clear_dynamics() -> void:
	for bullet in get_tree().get_nodes_in_group("bullet"):
		bullet.queue_free()
	_bullets.clear()
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
	GameLog.record("reconnect_begin", {"tick": _last_tick, "role": PvpSession.role}, true)
	_refresh_input_lock()
	_retry_started = Time.get_ticks_msec()
	_retry_loop()

func _retry_loop() -> void:
	while phase == Phase.RECONNECTING and Time.get_ticks_msec() - _retry_started < 60000:
		_banner.set_text("正在重连…")
		NetBus.stop()
		if Tunnel.forward_port() > 0:
			await Tunnel.refresh_forward()
			PvpSession.server_port = Tunnel.forward_port()
		_attempt_started = Time.get_ticks_msec()
		GameLog.record("reconnect_attempt", {"elapsed_ms": _attempt_started - _retry_started})
		NetBus.start_client(PvpSession.server_address, PvpSession.server_port)
		while phase == Phase.RECONNECTING and _attempt_started > 0 and Time.get_ticks_msec() - _attempt_started < 5000:
			await get_tree().create_timer(0.1).timeout
		if phase == Phase.RECONNECTING:
			await get_tree().create_timer(1.0).timeout
	if phase == Phase.RECONNECTING:
		phase = Phase.OFFLINE
		_banner.set_text("重连超时")
		GameLog.record("reconnect_timeout", {}, true)

func _on_connected() -> void:
	if phase == Phase.RECONNECTING:
		NetBus.send_event(NetEvent.Kind.REJOIN, {"code": PvpSession.room_code, "token": PvpSession.token})

func _on_connection_failed() -> void:
	_attempt_started = 0

func _exit_tree() -> void:
	_log_sample()
	GameLog.record("match_exit", {"tick": _last_tick, "phase": Phase.keys()[phase]})
	phase = Phase.OFFLINE
	NetBus.state_received.disconnect(_on_state)
	NetBus.event_received.disconnect(_on_event)
	multiplayer.server_disconnected.disconnect(_begin_reconnect)
	multiplayer.connected_to_server.disconnect(_on_connected)
	multiplayer.connection_failed.disconnect(_on_connection_failed)

func _count_log(key: String) -> void:
	_log_counts[key] = _log_counts.get(key, 0) + 1

func _log_sample() -> void:
	var now := Time.get_ticks_msec()
	var latest: int = _playback.frames[-1]["tick"] if not _playback.frames.is_empty() else -1
	var bullets := {}
	for id in _bullets:
		var bullet: BulletBase = _bullets[id]
		bullets[id] = {"type": bullet.type_id, "position": bullet.position, "velocity": bullet.velocity_vec,
				"physics": bullet.is_physics_processing(), "input_seq": bullet.input_seq, "epoch": bullet.input_epoch}
	GameLog.record("client_state", {"interval_ms": now - _log_at, "role": PvpSession.role,
			"phase": Phase.keys()[phase], "tick": _last_tick, "own_tick": _own_tick, "map_revision": _map_revision,
			"future_revision": _future_state.get("map_revision", -1), "input_seq": _rollback.sequence,
			"epoch": _rollback.epoch, "input_ack": _log_own.get("ack", 0), "action_ack": _log_own.get("action_ack", 0),
			"history": _rollback.history.size(), "actions": _rollback.actions.size(),
			"latest_input": _rollback.sent[-1] if not _rollback.sent.is_empty() else {},
			"input_lead": _rollback._lead, "clock": _rollback._clock, "clock_rate": _rollback._rate,
			"render_tick": _playback.render_tick, "buffer_frames": _playback.frames.size(),
			"headroom_ticks": latest - _playback.render_tick, "extrapolation_capped": latest >= 0 and _playback.render_tick >= latest + SnapshotBuffer.MAX_EXTRAPOLATION,
			"correction_max_px": _correction_max, "replay_max_ticks": _replay_max, "counts": _log_counts,
			"position": _local.position, "velocity": _local.velocity, "hp": _local.hp,
			"weapon": _local.weapons.log_state(), "projectiles": bullets, "pickups": _pickup_nodes.size()})
	_log_at = now
	_log_counts.clear()
	_correction_max = 0.0
	_replay_max = 0

var _time_mirror: GrainAccount
var _time_haste_mult := 3.0
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
	_time_mirror = GrainAccount.new()
	Level0.grain_account = _time_mirror
	var watch := WatchHud.new()
	watch.position = Vector2(24, 124)
	add_child(watch)
	_time_film = ShaderMaterial.new()
	_time_film.shader = preload("res://scenes/effects/time_film.gdshader")
	_time_remote_film = _time_film.duplicate()
	_time_remote_film.set_shader_parameter("coverage", 1.0)
	for target in [Level0.wall_layer, Level0.water_layer, Level0.water_surface_layer, _local]:
		if target != null:
			_time_targets.append(target)
	_time_symbol = UiFactory.label("◁ ◁", 48, UiFactory.C_TEXT)
	_time_symbol.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_time_symbol.offset_top = 60
	_time_symbol.visible = false
	add_child(_time_symbol)
	_time_glows[PvpSession.role] = TimeGlow.attach(_local, Level0.GLOW_PLAYER)
	_time_glows[PvpSession.role].visible = false

func _on_time_state(payload: Dictionary) -> void:
	var state: Dictionary = payload[PvpSession.role]
	_time_haste_mult = state["m"]
	_time_mirror.cap = state["cap"]
	_time_mirror.window = state["win"]
	_time_mirror.balance = state["b"]
	_time_mirror.short_used = state["w"]
	_time_mirror.loan_used = state["l"]
	_time_mirror.locked = state["k"]

func _tick_beta_time(delta: float, world: Dictionary) -> void:
	if not PvpSession.beta_mode:
		return
	var haste: bool = _local.input_source.haste_held() and not _local._controls_locked and _time_mirror.can_spend()
	_local.pvp_haste_mult = _time_haste_mult if haste else 1.0
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
		var state: Dictionary = world["players"][role]
		_time_glows[role].visible = state["haste"] and not state["rewind"]
		_replicas[role].material = _time_remote_film if state["rewind"] else null
		if trail and (state["haste"] or state["rewind"]):
			AfterImage.spawn(_world, _replicas[role].animator, UiFactory.C_TEAM_B if state["haste"] else UiFactory.C_TEXT_DIM)
