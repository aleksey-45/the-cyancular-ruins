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
var _collision_anchor: ActorCollider
var _remote_inputs: Dictionary = {}
var _bullets: Dictionary = {}
var _bullet_rewind_visuals: Dictionary = {}
var _bullet_rewind_events: Dictionary = {}
var _explosions_shown: Dictionary = {}
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
var _terrain_round := 0
var _future_state: Dictionary = {}
var _authority_state: Dictionary = {}
var _prediction_frame: Dictionary = {}
var _pending_replay := ""
var _pending_replay_tick := 0
var _pending_replay_last_tick := 0
var _authority_process_frame := -1
var _accepting_authority := false
var _deferred_authority: Array[Dictionary] = []
var _authority_applications := 0
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
var _terrain: NativeTerrain

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
	_local.enable_manual_simulation()
	_local.interpolate_prediction = true
	var camera := _world.get_node("Camera2D") as Camera2D
	camera.target = _local.visuals
	camera.process_priority = 100
	_local.role = PvpSession.role
	_collision_anchor = ActorCollider.new(_local, 32)
	_rollback.bind(_local, _replicas, _collision_anchor)
	_bind_prediction_terrain()
	_rollback.combat_prediction.detonated.connect(_present_explosion.bind(true))
	_rollback.tick_finished.connect(_level0.flush_terrain_collision)
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
	NetBus.remote_input_received.connect(_on_remote_input)
	NetBus.event_received.connect(_on_event)
	NetBus.server_disconnected.connect(_begin_reconnect)
	NetBus.connected_to_server.connect(_on_connected)
	NetBus.connection_failed.connect(_on_connection_failed)
	NetBus.protocol_error.connect(_on_protocol_error)
	apply_baseline(baseline)
	for message: Array in PvpSession.match_events:
		_on_event(1, message[0], message[1])
	PvpSession.match_events.clear()
	PvpSession.loading_match = false
	GameLog.record("match_loaded", {"duration_ms": Time.get_ticks_msec() - started, "role": PvpSession.role})

func apply_baseline(payload: Dictionary) -> void:
	_restore_predicted_terrain(-1, false)
	var started := Time.get_ticks_msec()
	GameLog.record("baseline_begin", {"tick": payload["frame"]["tick"], "round": payload["round_state"]["round"],
			"map_bytes": payload["map"].size(), "terrain_cells": payload["sub_hp"].size()})
	phase = Phase.LOADING
	_names = payload["names"]
	_hues = payload["hues"]
	_teams = payload["teams"]
	_tint(_local.animator, PvpSession.role)
	if payload["round_state"]["round"] != _terrain_round:
		_level0.reset_destructibles()
		_terrain_round = payload["round_state"]["round"]
	TileDefs.terrain.apply_values(payload["sub_hp"])
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
	_terrain.revision = _map_revision
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
		if not frame["world"]["players"][id >> 48]["rewind"]:
			_seed_projectile(id, data, frame["tick"])
		if data["fuse_active"] and not frame["world"]["players"][id >> 48]["rewind"]:
			_rollback.combat_prediction.checkpoint_projectile(id, data, frame["tick"], _bullets[id].shooter)
	_local.correct_visual(_local.global_position, true)
	_refresh_input_lock()
	NetBus.send_event(NetEvent.Kind.READY, payload["round_state"]["round"])
	GameLog.record("baseline_ready", {"tick": frame["tick"], "epoch": frame["own"]["epoch"],
			"map_revision": _map_revision, "duration_ms": Time.get_ticks_msec() - started,
			"reconnect_ms": Time.get_ticks_msec() - _retry_started if _retry_started > 0 else 0})
	_retry_started = 0

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	# 本帧已冻结的模拟不能再被迟到事件修改；保持收包顺序，到下个批次一起审核。
	if kind in [NetEvent.Kind.TERRAIN, NetEvent.Kind.ROUND, NetEvent.Kind.BEAM,
			NetEvent.Kind.BULLET_SPAWN, NetEvent.Kind.BULLET_REWIND, NetEvent.Kind.BULLET_END,
			NetEvent.Kind.BULLET_FUSE, NetEvent.Kind.TIME_REWARD, NetEvent.Kind.EXPLOSION, NetEvent.Kind.HIT] \
			and _authority_batch_closed():
		_deferred_authority.append({"peer": _peer, "kind": kind, "data": data})
		return
	if kind in [NetEvent.Kind.FIRE, NetEvent.Kind.HIT, NetEvent.Kind.KILL, NetEvent.Kind.EXPLOSION, NetEvent.Kind.TIME_REWARD, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED]:
		GameLog.record("match_event", {"kind": NetEvent.Kind.keys()[kind], "tick": _last_tick, "payload": data})
	match kind:
		NetEvent.Kind.BASELINE: apply_baseline(data)
		NetEvent.Kind.TERRAIN: apply_terrain(data)
		NetEvent.Kind.ROUND: _on_round_state(data)
		NetEvent.Kind.BEAM:
			var span := _rollback.combat_prediction.receive_beam(data)
			_accept_confirmation("beam", span)
			_on_beam_fired(data)
		NetEvent.Kind.BULLET_SPAWN:
			if not _bullets.has(data["id"]): _create_bullet(data["id"], data)
			var new_identity := not _rollback.combat_prediction.projectiles.has(data["id"])
			var changed := _seed_projectile(data["id"], data.merged({"traveled": 0.0,
					"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}), data["tick"] - 1)
			# STATE 已覆盖出生时，只补身份元数据；不能把快照锚点误当成较晚的预测出生。
			if data["tick"] > _own_tick:
				changed = _rollback.review_projectile_spawn(data["id"], changed, new_identity)
				_count_log("projectile_spawn_kept" if changed == Vector2i.ZERO else "projectile_spawn_changed")
				if changed != Vector2i.ZERO: _request_event_replay(changed.x, changed.y)
		NetEvent.Kind.BULLET_REWIND: _on_bullet_rewind(data)
		NetEvent.Kind.BULLET_END:
			var span := _rollback.combat_prediction.end_projectiles(data)
			var contacted := span != Vector2i.ZERO
			_count_log("projectile_end_contacts" if contacted else "projectile_end_updates")
			if contacted:
				_request_event_replay(span.x, span.y)
			for id in data["ids"]:
				if _bullets.has(id): _bullets[id].finish()
		NetEvent.Kind.BULLET_FUSE:
			var changed := false
			for id in data["projectiles"]:
				var role: int = id >> 48
				if role != PvpSession.role: _ensure_replica(role)
				var owner: Node2D = _local if role == PvpSession.role else _replicas[role]._forecast
				changed = _rollback.confirm_projectile(id, data["projectiles"][id], data["tick"], owner) or changed
			if changed: _request_event_replay(data["tick"])
		NetEvent.Kind.TIME_REWARD:
			_rollback.combat_prediction.receive_reward(data)
		NetEvent.Kind.EXPLOSION: _on_explosion(data)
		NetEvent.Kind.FIRE:
			Sfx.play(data["sound"])
			if _replicas.has(data["role"]):
				_replicas[data["role"]].play_fire(data["type_id"])
		NetEvent.Kind.HIT:
			var span := _rollback.combat_prediction.confirm_hit(data)
			_accept_confirmation("hit", span)
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
			PvpSession.room = data
			if data["in_match"]:
				return
			phase = Phase.OFFLINE
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
	_bind_prediction_terrain()
	_terrain.apply_authority(patch)
	_map_revision = patch["revision"]

func _bind_prediction_terrain() -> void:
	_terrain = TileDefs.terrain
	_terrain.revision = _map_revision
	_rollback.terrain = _terrain

func _restore_predicted_terrain(at_tick: int = -1, flush: bool = true) -> void:
	_bind_prediction_terrain()
	_terrain.reset_prediction(at_tick)
	if flush: _level0.flush_terrain_collision()

func _on_state(frame: Dictionary) -> void:
	if _authority_batch_closed():
		_deferred_authority.append({"frame": frame})
		return
	_count_log("state_callbacks")
	if phase != Phase.ONLINE or frame["tick"] <= _last_tick:
		return
	if frame["map_revision"] > _map_revision:
		_count_log("terrain_wait_states")
		if _future_state.is_empty() or frame["tick"] > _future_state["tick"]:
			_future_state = frame
		return
	if frame["map_revision"] < _map_revision:
		_count_log("old_terrain_states")
		return
	if frame["tick"] > _own_tick:
		if _authority_state.is_empty() or frame["tick"] > _authority_state["tick"]:
			_authority_state = frame
	_last_tick = frame["tick"]
	_playback.push(frame["tick"], frame["world"])

func _on_remote_input(role: int, tick: int, packet: Dictionary) -> void:
	if phase == Phase.ONLINE and _replicas.has(role):
		_count_log("remote_inputs")
		_remote_inputs[role] = {"tick": tick, "packet": packet}
		_replicas[role].receive_input(tick, packet)

func _request_event_replay(tick: int, through: int = 0) -> void:
	var last := maxi(tick, through)
	if last > _own_tick: _queue_replay(maxi(tick, _own_tick + 1), "event", last)

func _accept_confirmation(kind: String, span: Vector2i) -> void:
	_count_log(kind + "_confirmation_" + ("kept" if span == Vector2i.ZERO else "changed"))
	if span != Vector2i.ZERO: _request_event_replay(span.x, span.y)

func _queue_replay(tick: int, reason: String, through: int = 0) -> void:
	if _own_tick < tick and tick <= _rollback._sim_tick:
		if _pending_replay.is_empty() or reason == "event": _pending_replay = reason
		_pending_replay_tick = tick if _pending_replay_tick == 0 else mini(_pending_replay_tick, tick)
		_pending_replay_last_tick = maxi(_pending_replay_last_tick, maxi(tick, through))

func _apply_pending_authority() -> void:
	_accepting_authority = true
	var batch := _deferred_authority
	_deferred_authority = []
	for message: Dictionary in batch:
		if message.has("frame"):
			_on_state(message["frame"])
		else:
			_on_event(message["peer"], message["kind"], message["data"])
	# 远端输入不拥有本地预测状态；这里只审核本地账户和权威事件。
	var reward_tick := _rollback.review_rewards()
	if reward_tick > 0: _request_event_replay(reward_tick)
	_level0.flush_terrain_collision()
	if not _future_state.is_empty() and _future_state["map_revision"] <= _map_revision:
		var frame := _future_state
		_future_state = {}
		_on_state(frame)
	if not _authority_state.is_empty():
		if _authority_state["map_revision"] == _map_revision:
			_apply_authority(_authority_state)
		_authority_state = {}
	if not _pending_replay.is_empty() and not _prediction_frame.is_empty() and _prediction_frame["map_revision"] == _map_revision:
		_apply_authority(_prediction_frame, _pending_replay)
	_accepting_authority = false

func _apply_authority(frame: Dictionary, trigger: String = "state") -> void:
	var trace_started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var previous_map_revision: int = _prediction_frame.get("map_revision", _map_revision)
	_bind_prediction_terrain()
	# 新加入的代理也必须参与原先空查询的复核。
	for role in frame["world"]["players"]:
		if role != PvpSession.role:
			_ensure_replica(role)
			_replicas[role].set_ghost_layer(16 if _teams.get(role, 0) == 2 else 2)
	var dirty_tick := _pending_replay_tick
	var checkpoint: bool = trigger != "state" and _rollback.can_replay_from(dirty_tick)
	var reuse := false
	if trigger == "state":
		# 先比较本地锚点，再复核命令及实际依赖；远端完整状态不拥有本地历史。
		var invalid_from := maxi(dirty_tick, frame["tick"] + 1) if _pending_replay == "event" and _pending_replay_last_tick > frame["tick"] else 0
		reuse = _rollback.reusable_tick(frame, invalid_from) >= 0
	_prediction_frame = frame
	_pending_replay = ""
	_pending_replay_tick = 0
	_pending_replay_last_tick = 0
	if trigger != "state":
		_count_log(trigger + "_replays")
	var previous_own := _log_own
	var previous_players := _latest_players
	var previous_tick := _own_tick
	_log_own = frame["own"]
	_own_tick = frame["tick"]
	_local.rewinding = frame["own"]["rewind"]
	_local.input_buffer.epoch = frame["own"]["epoch"]
	_latest_players = frame["world"]["players"]
	for role in _latest_players:
		if role != PvpSession.role:
			_ensure_replica(role)
			_replicas[role].set_ghost_layer(16 if _teams.get(role, 0) == 2 else 2)
			if trigger != "state": _replicas[role].apply_snapshot(_latest_players[role], _local.position, frame["tick"])
	for role in _replicas:
		if not _latest_players.has(role):
			_replicas[role].set_ghost_layer(0)
	if PvpSession.beta_mode:
		for role in frame["time"]:
			if role != PvpSession.role or (not reuse and not checkpoint):
				_rollback.time_economy.restore_account(role, frame["time"][role])
	var previous: Vector2 = _local.corrected_position()
	var before: Vector2 = _local.global_position
	var before_velocity: Vector2 = _local.velocity
	var before_knock: Vector2 = _local.combat.knock_velocity
	var before_hp: int = _local.hp
	var before_down: bool = _local.is_downed()
	var before_visual_step := GridPathfinder.toroidal_delta_px(_local._visual_from, before,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var predicted_tick := _rollback._sim_tick
	var pending_inputs := _rollback.history
	var pending_actions := _rollback.actions
	_rollback.terrain_revision = _map_revision
	# 显示先恢复锚点，后续预测中的爆炸回调才能最终结束弹丸。
	_sync_bullet_rewind_state(frame)
	var snap := false
	if checkpoint:
		_rollback.replay_from(dirty_tick)
		_count_log("checkpoint_replays")
	else:
		snap = _rollback.reconcile(frame["own"], frame["tick"], NetBus.ping_ms, reuse, frame["world"].get("projectiles"))
	_authority_applications += 1
	_rollback.diagnostics["scope"] = "local"
	_rollback.diagnostics["proxy_count"] = _replicas.size()
	_rollback.diagnostics["dirty_tick"] = dirty_tick
	_rollback.diagnostics["effect_review"] = _rollback.last_effect_review
	if trigger == "state": _rollback.diagnostics["reuse"] = _rollback.reuse_detail
	if reuse:
		_count_log("prefix_reuses" if _rollback.diagnostics["replay_ticks"] > 0 else "history_reuses")
	var error := GridPathfinder.toroidal_delta_px(before, _local.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	_correction_max = maxf(_correction_max, error)
	_replay_max = maxi(_replay_max, _rollback.diagnostics["replay_ticks"])
	_count_log("reconciles")
	if before_down and not _local.is_downed() and not snap:
		_count_log("predicted_death_rejected")
	if _rollback.diagnostics["reason"] not in ["epoch", "rewind"]:
		_count_log("correction_checks")
		for threshold in [8, 32, 128]:
			if error >= threshold:
				_count_log("corrections_%dpx" % threshold)
	if not _rollback.diagnostics["reason"].is_empty():
		_count_log("reset_" + _rollback.diagnostics["reason"])
	if not reuse or _rollback.diagnostics["replay_ticks"] > 0: _local.correct_visual(previous, snap)
	if error >= 32.0 or (error >= 8.0 and Time.get_ticks_msec() - _correction_log_at >= 1000):
		_correction_log_at = Time.get_ticks_msec()
		var detail := {"role": PvpSession.role, "tick": frame["tick"], "trigger": trigger, "error_px": error,
				"before": before, "after": _local.global_position, "authority": frame["own"],
				"before_velocity": before_velocity, "before_knock": before_knock,
				"before_hp": before_hp, "after_hp": _local.hp,
				"before_down": before_down, "after_down": _local.is_downed(),
				"visual_step_before": before_visual_step,
				"visual_step_after": GridPathfinder.toroidal_delta_px(_local._visual_from, _local.position,
						GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT),
				"predicted_tick": predicted_tick, "ping_ms": NetBus.ping_ms,
				"prediction": _rollback.diagnostics, "smoothing_ms": _local._visual_left * 1000.0,
				"map_revision": _map_revision, "before_map_revision": previous_map_revision,
				"weapon": _local.weapons.log_state()}
		if error >= 32.0:
			detail.merge({"previous_tick": previous_tick, "previous_authority": previous_own,
					"previous_players": previous_players, "players": _latest_players,
					"inputs": pending_inputs, "actions": pending_actions, "remote_inputs": _remote_inputs})
		GameLog.record("prediction_correction", detail)
	_make_label(PvpSession.role)
	if FrameTrace.enabled:
		FrameTrace.span(&"authority_apply", trace_started, Time.get_ticks_usec())
		FrameTrace.count(&"authority_applies")
		FrameTrace.event(&"authority", {"tick": frame["tick"], "trigger": trigger,
				"dirty_tick": dirty_tick, "replay_ticks": _rollback.diagnostics["replay_ticks"],
				"reason": _rollback.diagnostics["reason"], "reuse": _rollback.reuse_detail.duplicate(), "error_px": error})

func _ensure_replica(role: int) -> void:
	if _replicas.has(role):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.team = _teams.get(role, 0)
	replica.role = role
	_world.add_child(replica)
	replica.bind_local(_local)
	replica._forecast.weapons.projectile_count = _rollback.combat_prediction.count_projectiles.bind(role)
	if PvpSession.beta_mode:
		_rollback.time_economy.add_role(role)
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
	var anchored := GridPathfinder.anchor_to_nearest(data["pos"], _local.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	bullet.restore_motion(data.merged({"pos": anchored}, true))

func _seed_projectile(id: int, data: Dictionary, tick: int) -> Vector2i:
	var role := id >> 48
	if role != PvpSession.role: _ensure_replica(role)
	var owner: Node2D = _local if role == PvpSession.role else _replicas[role]._forecast
	return _rollback.combat_prediction.seed_projectile(id, data, tick, owner)

func _on_explosion(data: Dictionary) -> void:
	var span := _rollback.combat_prediction.confirm(data)
	_accept_confirmation("explosion", span)
	_present_explosion(data)
	GameLog.record("explosion_confirmed", data)

func _present_explosion(data: Dictionary, predicted: bool = false) -> void:
	if _explosions_shown.has(data["id"]):
		return
	_explosions_shown[data["id"]] = true
	if _bullets.has(data["id"]):
		_bullets[data["id"]].queue_free()
	var profile := WeaponRegistry.projectile_profile(data["type_id"])
	var pos := GridPathfinder.anchor_to_nearest(data["pos"], _local.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	BulletBase.present_explosion(_world, pos, profile["explosion_visual"], profile["explosion_radius"])
	GameLog.record("explosion", {"id": data["id"], "type": data["type_id"], "position": data["pos"],
			"damage": false, "visual": profile["explosion_visual"] != null,
			"shooter": data["id"] >> 48, "server_tick": data["tick"], "predicted": predicted})

func _on_bullet_rewind(data: Dictionary) -> void:
	# 事件 tick 是弹丸恢复锚点，实际变化发生在下一 tick；相等时尚未被 STATE 覆盖。
	if data["tick"] < _own_tick:
		return
	var previous: Dictionary = _bullet_rewind_events.get(data["role"], {})
	if previous == data or data["tick"] < previous.get("tick", -1): return
	_bullet_rewind_events[data["role"]] = data.duplicate(true)
	if _rollback.bullet_rewind_matches(data):
		for id in data["projectiles"]:
			var owner: Node2D = _local if data["role"] == PvpSession.role else _replicas[data["role"]]._forecast
			_rollback.combat_prediction.checkpoint_projectile(id, data["projectiles"][id], data["tick"], owner)
		_bullet_rewind_visuals[data["role"]] = {"tick": data["tick"] + 1, "rewind": data["rewind"]}
		_count_log("rewind_confirmation_kept")
		return
	_rollback.combat_prediction.cancel_role(data["role"])
	_sync_bullet_rewind_visuals(data["role"], data["tick"] + 1, data["rewind"], data["projectiles"])
	if not data["rewind"]:
		for id in data["projectiles"]:
			_seed_projectile(id, data["projectiles"][id], data["tick"])
	_request_event_replay(data["tick"] + 1)

func _sync_bullet_rewind_state(frame: Dictionary) -> void:
	var players: Dictionary = frame["world"]["players"]
	for role in players:
		var previous: Dictionary = _bullet_rewind_visuals.get(role, {})
		# 已收到更新的回溯事件时，旧 STATE 不能改写其显示状态。
		if frame["tick"] < previous.get("tick", -1): continue
		var rewind: bool = players[role]["rewind"]
		if rewind or previous.get("rewind", false):
			_sync_bullet_rewind_visuals(role, frame["tick"], rewind, frame["world"].get("projectiles", {}))
		else:
			_bullet_rewind_visuals[role] = {"tick": frame["tick"], "rewind": false}
	for role in _bullet_rewind_visuals.keys():
		if not players.has(role) and frame["tick"] >= _bullet_rewind_visuals[role]["tick"]:
			_sync_bullet_rewind_visuals(role, frame["tick"], false, {})
			_bullet_rewind_visuals.erase(role)

func _sync_bullet_rewind_visuals(role: int, tick: int, rewind: bool, projectiles: Dictionary) -> void:
	_track_local_bullets()
	for id in _bullets.keys():
		if id >> 48 == role and not projectiles.has(id):
			_bullets[id].queue_free()
	for id in projectiles:
		if id >> 48 != role: continue
		_explosions_shown.erase(id)
		var state: Dictionary = projectiles[id]
		var bullet: BulletBase = _bullets.get(id)
		if bullet != null and bullet.type_id != state["type_id"]:
			bullet.queue_free()
		if bullet == null or bullet.is_queued_for_deletion():
			bullet = _create_bullet(id, state)
		_restore_bullet(bullet, state)
		bullet.set_physics_process(not rewind)
	_bullet_rewind_visuals[role] = {"tick": tick, "rewind": rewind}

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

func _authority_batch_closed() -> bool:
	return phase == Phase.ONLINE and not _accepting_authority \
			and _authority_process_frame == Engine.get_process_frames()

# 物理回调与表现回调共用一个批次；没有物理 tick 的显示帧由 _process 接纳。
# 批次关闭后的模拟消息留到下一帧。本地预测产生的地形碰撞仍须逐 tick 刷新。
func _apply_frame_authority() -> void:
	var frame := Engine.get_process_frames()
	if _authority_process_frame == frame:
		_level0.flush_terrain_collision()
		return
	_authority_process_frame = frame
	_apply_pending_authority()

func _physics_process(delta: float) -> void:
	if phase != Phase.ONLINE:
		_local.begin_visual_step()
		return
	var started := Time.get_ticks_usec()
	var applications_before := _authority_applications
	_apply_frame_authority()
	var restored := Time.get_ticks_usec()
	_local._poll_pickup_drop(delta)
	var src: PlayerInput = _local.input_source
	_rollback.capture(src, _local.get_current_aim_dir(), int(_playback.render_tick),
			_local.weapons.take_uplink_switch(src.get_switch_index_pressed()))
	if not _rollback.actions.is_empty() and _rollback.actions[-1]["seq"] == _rollback.sequence:
		GameLog.record("input_action", {"role": PvpSession.role, "action": _rollback.actions[-1]})
	NetBus.send_input(_rollback.packet())
	_rollback.advance(delta)
	var advanced := Time.get_ticks_usec()
	var finished := Time.get_ticks_usec()
	if FrameTrace.enabled:
		FrameTrace.span(&"physics_authority", started, restored)
		FrameTrace.span(&"prediction_advance", restored, advanced)
	if finished - started > 1000000.0 * ActorStep.DT:
		GameLog.record("client_slow_tick", {"tick": _rollback._sim_tick,
				"authority_tick": _own_tick, "rollback": _rollback.diagnostics if _authority_applications > applications_before else {"replay_ticks": 0},
				"authority_ms": (restored - started) / 1000.0,
				"prediction_ms": (advanced - restored) / 1000.0,
				"presentation_ms": (finished - advanced) / 1000.0, "projectiles": _bullets.size()})

func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	if Time.get_ticks_msec() - _log_at >= 1000:
		_log_sample()
	if phase != Phase.ONLINE:
		return
	# 和物理回调共用接纳点，不能在表现前再次重放同一窗口。
	var authority_started := Time.get_ticks_usec()
	var applications_before := _authority_applications
	_apply_frame_authority()
	var authority_finished := Time.get_ticks_usec()
	_level0.flush_terrain_visuals()
	_track_local_bullets()
	_cull_bullet_contacts()
	_local.present_tick(delta)
	if _post != null: _post.set_downed(_local.is_downed())
	var render_tick := _rollback._clock - _rollback._rate * (1.0 - Engine.get_physics_interpolation_fraction())
	_local.present_prediction(delta, render_tick - _rollback._sim_tick)
	if _playback.frames.is_empty():
		if FrameTrace.enabled: FrameTrace.span(&"client_present", authority_finished, Time.get_ticks_usec())
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
	var elapsed := Time.get_ticks_usec() - started
	if FrameTrace.enabled:
		FrameTrace.span(&"idle_authority", authority_started, authority_finished)
		FrameTrace.span(&"client_present", authority_finished, started + elapsed)
		var age := 0
		var stale := 0
		for replica in _replicas.values():
			age = maxi(age, replica.proxy_age)
			stale += int(replica.proxy_stale)
		FrameTrace.context(&"client", {"role": PvpSession.role, "own_tick": _own_tick,
				"sim_tick": _rollback._sim_tick, "clock": _rollback._clock, "input_seq": _rollback.sequence,
				"input_ack": _log_own.get("ack", 0), "action_ack": _log_own.get("action_ack", 0),
				"projectiles": _bullets.size(), "map_revision": _map_revision,
				"proxy_max_age": age, "proxy_stale": stale})
	if elapsed > 1000000.0 * ActorStep.DT:
		GameLog.record("client_slow_present", {"duration_ms": elapsed / 1000.0,
				"authority_ms": (authority_finished - authority_started) / 1000.0,
				"rollback": _rollback.diagnostics if _authority_applications > applications_before else {"replay_ticks": 0},
				"presentation_ms": (Time.get_ticks_usec() - authority_finished) / 1000.0,
				"tick": _rollback._sim_tick, "players": _replicas.size(), "projectiles": _bullets.size()})

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
	_prediction_frame = {}
	_pending_replay = ""
	_pending_replay_tick = 0
	_pending_replay_last_tick = 0
	_authority_process_frame = -1
	_deferred_authority.clear()
	_remote_inputs.clear()
	_rollback.combat_prediction.clear()
	_bullet_rewind_visuals.clear()
	_bullet_rewind_events.clear()
	_explosions_shown.clear()
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
		while phase == Phase.RECONNECTING and Time.get_ticks_msec() - _retry_started < 60000:
			if not NetBus.can_send_to_server() and (_attempt_started == 0 or Time.get_ticks_msec() - _attempt_started >= 5000):
				break
			await get_tree().create_timer(0.1).timeout
		if phase == Phase.RECONNECTING:
			await get_tree().create_timer(1.0).timeout
	if phase == Phase.RECONNECTING:
		phase = Phase.OFFLINE
		NetBus.stop()
		_banner.set_text("重连超时")
		GameLog.record("reconnect_timeout", {}, true)

func _on_connected() -> void:
	if phase == Phase.RECONNECTING:
		NetBus.send_event(NetEvent.Kind.REJOIN, {"code": PvpSession.room_code, "token": PvpSession.token})

func _on_connection_failed() -> void:
	_attempt_started = 0

func _on_protocol_error(message: String) -> void:
	phase = Phase.OFFLINE
	_refresh_input_lock()
	_banner.set_text(message)

func _exit_tree() -> void:
	_log_sample()
	GameLog.record("match_exit", {"tick": _last_tick, "phase": Phase.keys()[phase]})
	phase = Phase.OFFLINE
	NetBus.state_received.disconnect(_on_state)
	NetBus.remote_input_received.disconnect(_on_remote_input)
	NetBus.event_received.disconnect(_on_event)
	NetBus.server_disconnected.disconnect(_begin_reconnect)
	NetBus.connected_to_server.disconnect(_on_connected)
	NetBus.connection_failed.disconnect(_on_connection_failed)
	NetBus.protocol_error.disconnect(_on_protocol_error)

func _count_log(key: String) -> void:
	_log_counts[key] = _log_counts.get(key, 0) + 1

func _log_sample() -> void:
	var now := Time.get_ticks_msec()
	var motion_cache := {"hits": _local.terrain_motion_hits, "misses": _local.terrain_motion_misses,
			"entries": _local.terrain_motion_cache.size()}
	for replica: Node2D in _replicas.values():
		motion_cache["hits"] += replica._forecast.terrain_motion_hits
		motion_cache["misses"] += replica._forecast.terrain_motion_misses
		motion_cache["entries"] += replica._forecast.terrain_motion_cache.size()
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
			"history": _rollback.history.size(), "actions": _rollback.actions.size(), "motion_cache": motion_cache,
			"reuse_counts": _rollback.reuse_counts, "reuse_totals": _rollback.reuse_totals,
			"effect_checks": _rollback.effect_counts,
			"latest_input": _rollback.sent[-1] if not _rollback.sent.is_empty() else {},
			"input_lead": _rollback._lead, "clock": _rollback._clock, "clock_rate": _rollback._rate,
			"render_tick": _playback.render_tick, "buffer_frames": _playback.frames.size(),
			"headroom_ticks": latest - _playback.render_tick, "extrapolation_capped": latest >= 0 and _playback.render_tick >= latest + SnapshotBuffer.MAX_EXTRAPOLATION,
			"correction_max_px": _correction_max, "replay_max_ticks": _replay_max, "counts": _log_counts,
			"position": _local.position, "velocity": _local.velocity, "hp": _local.hp,
			"weapon": _local.weapons.log_state(), "projectiles": bullets, "pickups": _pickup_nodes.size()})
	_log_at = now
	_log_counts.clear()
	_rollback.reuse_counts.clear()
	_rollback.effect_counts.clear()
	_correction_max = 0.0
	_replay_max = 0

var _time_mirror: GrainAccount
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
	var rules := TimeRules.from_dict(PvpSession.baseline["options"]["time"])
	_rollback.time_economy = TimeEconomy.new(rules, [PvpSession.role])
	_time_mirror = _rollback.time_economy.accounts[PvpSession.role]
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
	for role in payload:
		_rollback.time_economy.restore_account(role, payload[role])

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
		var state: Dictionary = world["players"][role]
		_time_glows[role].visible = state["haste"] and not state["rewind"]
		_replicas[role].material = _time_remote_film if state["rewind"] else null
		if trail and (state["haste"] or state["rewind"]):
			AfterImage.spawn(_world, _replicas[role].animator, UiFactory.C_TEAM_B if state["haste"] else UiFactory.C_TEXT_DIM)
