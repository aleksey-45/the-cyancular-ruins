class_name PvpMatchClient
extends MatchController

const NetPlayer := PlayerStateSchema.Network
const Sample := SnapshotBuffer.Sample

enum Phase { LOADING, ONLINE, RECONNECTING, OFFLINE }
var phase := Phase.LOADING
var _previous_samples: Dictionary = {}
var _projectiles: Dictionary[int, ProjectileTrack] = {}
var _names: Dictionary = {}
var _hues: Dictionary = {}
var _teams: Dictionary = {}
var _team_counts: Dictionary = {}
var _player_collision := false
var _round_state := NetEvent.RoundState.COUNTDOWN
var _rollback := PredictionRollback.new()
var _playback := SnapshotBuffer.new()
var _terrain_round := 0
var _pending_states: Dictionary[int, Dictionary] = {}
var _pending_events: Array = []

func _enter_tree() -> void:
	map = PvpSession.baseline["map"]
	super()

func _ready() -> void:
	var baseline := PvpSession.baseline
	combat_rules = CombatSimulator.new(terrain)
	player = combat_rules.add_player(baseline["role"])
	_rollback.bind(player)
	_rollback.step_advanced.connect(_live_step)
	_playback.map_px = terrain.map_size
	var account: GrainAccount
	if PvpSession.beta_mode:
		_rollback.time_economy = TimeEconomy.new(baseline["options"]["time"], [player.role])
		account = _rollback.time_economy.accounts[player.role]
	var mode: MatchFrame.Mode = {
		PvpSession.MODE_PVP: Mode.DUEL, PvpSession.MODE_TEAM: Mode.TEAM,
		PvpSession.MODE_ROYALE: Mode.ROYALE,
	}.get(PvpSession.room_mode, Mode.DUEL)
	_mount(mode, account, Settings.pvp_show_minimap)
	_view.pvp_hud.leave_requested.connect(_leave_result)
	NetBus.ping_updated.connect(_view.pvp_hud.set_ping)
	NetBus.state_received.connect(_on_state)
	NetBus.event_received.connect(_on_event)
	NetBus.server_disconnected.connect(_begin_reconnect)
	NetBus.protocol_error.connect(_go_offline)
	apply_baseline(baseline)
	_pending_events = PvpSession.match_events
	PvpSession.match_events = []
	PvpSession.baseline = {}

func apply_baseline(payload: Dictionary) -> void:
	phase = Phase.LOADING
	_names = payload["names"]
	_hues = payload["hues"]
	_teams = payload["teams"]
	var team_mode := PvpSession.room_mode == PvpSession.MODE_TEAM
	# 根据房间快照统计每队人数，团队对抗据此计算生命值上限，并在界面显示队伍信息。
	_team_counts = TeamRules.team_counts(_teams) if team_mode else {}
	var round: int = payload["round_state"]["round"]
	if _terrain_round != 0 and round != _terrain_round:
		terrain.reset()
	_terrain_round = round
	terrain.apply_values(payload["sub_hp"])
	terrain.flush_collisions()
	_view.terrain_view.patch(terrain.take_wall_changes())
	var options: Dictionary = payload["options"]
	player.weapons.enabled_types = WeaponRegistry.enabled_ids(options.get("disabled_weapons", []))
	_player_collision = options.get("player_collision", false)
	var my_team := int(_teams.get(player.role, 0))
	player.set_team_collision(my_team, _player_collision)
	# 先设置本地角色的生命值上限，随后用服务器快照恢复当前生命值。
	player.sim_max_hp = TeamRules.max_hp(my_team, _team_counts)
	_clear_dynamics()
	var frame: Dictionary = payload["frame"]
	terrain.revision = frame["map_revision"]
	_playback.reset()
	_install_world(frame)
	_rollback.reset(frame, NetBus.ping_ms)
	_on_round_state(payload["round_state"])
	phase = Phase.ONLINE
	_view.pvp_hud.set_status("")
	_local_motion.correct(player.transform, player.position, terrain.map_size, true)
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
			if data["in_match"]:
				return
			phase = Phase.OFFLINE
			SceneTransition.change(get_tree(), "res://scenes/mp_lobby.tscn")
		NetEvent.Kind.REJOIN_DENIED: _go_offline(data)
		NetEvent.Kind.ROOM_CLOSED:
			phase = Phase.OFFLINE
			NetSession.disconnect_client()
			SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _apply_event(kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.TERRAIN:
			if data["revision"] > terrain.revision:
				terrain.apply_values(data["cells"])
				terrain.revision = data["revision"]
		NetEvent.Kind.ROUND: _on_round_state(data)
		NetEvent.Kind.FIRE: _on_fire(data)
		NetEvent.Kind.BULLET_END:
			for id: int in data["ids"]:
				_end_projectile(id, data["tick"])
		NetEvent.Kind.EXPLOSION:
			var blast := CombatSimulator.blast_state(data["type_id"], data["pos"], data["tick"])
			_end_projectile(data["id"], data["tick"], blast)
			_blast(data["pos"], data["type_id"])
		NetEvent.Kind.HIT:
			if data["shooter"] == player.role:
				_view.feedback.show_hit()
			var victim: int = data["victim"]
			_rollback.queue_hit(data)
			if victim == player.role:
				if data["damage"] > 0:
					_damage(data["damage"])
			elif data["damage"] > 0 and _previous_samples.has(victim):
				_world.remote_hurt(victim, _frame.now)
		NetEvent.Kind.KILL:
			if data[1] == player.role:
				_view.feedback.reset_streak()
			elif data[0] == player.role:
				_view.feedback.show_kill(_names[data[1]])

func _on_state(frame: Dictionary) -> void:
	if phase == Phase.ONLINE and frame["tick"] > _playback.latest_tick:
		var revision: int = frame["map_revision"]
		if not _pending_states.has(revision) or frame["tick"] > _pending_states[revision]["tick"]:
			_pending_states[revision] = frame

func _apply_pending_authority() -> bool:
	var started := PerformanceStats.begin()
	for item: Array in _pending_events:
		_apply_event(item[0], item[1])
	_pending_events.clear()
	terrain.flush_collisions()
	var chosen: Dictionary = {}
	var last_tick := _playback.latest_tick
	for revision: int in _pending_states.keys():
		var frame := _pending_states[revision]
		if frame["tick"] <= last_tick:
			_pending_states.erase(revision)
		elif revision <= terrain.revision:
			_pending_states.erase(revision)
			if chosen.is_empty() or frame["tick"] > chosen["tick"]:
				chosen = frame
	if not chosen.is_empty():
		_install_world(chosen)
	var previous := _local_motion.corrected(player.position)
	var before := player.position
	var was_rewinding := player.rewinding
	var epoch := player.input_buffer.epoch
	var correction := _rollback.reconcile(chosen, NetBus.ping_ms)
	var snap := correction == PredictionRollback.Correction.SNAP
	if player.input_buffer.epoch != epoch:
		_world.clear_motion(player.role)
	# 即时校正模拟位置时，时间回溯造成的位移仍可在画面上用插值过渡。
	# 退出回溯会增加一次输入版本号。如果版本号进一步增加，例如发生了复活，画面直接跳到校正位置。
	var smooth_rewind := snap and (was_rewinding or player.rewinding) \
			and player.input_buffer.epoch <= epoch + int(was_rewinding)
	if correction != PredictionRollback.Correction.KEEP:
		if not snap:
			_local_motion.rebase(player.position, before, terrain.map_size)
		if not smooth_rewind:
			_local_motion.correct(player.transform, previous, terrain.map_size, snap)
	PerformanceStats.end(PerformanceStats.CLIENT_AUTHORITY, started)
	return smooth_rewind

func _install_world(frame: Dictionary) -> void:
	var world: Dictionary = frame["world"]
	_playback.push(frame["tick"], world)
	_sync_proxies(world["players"])
	_sync_projectiles(world["projectiles"])

func _sync_proxies(latest: Dictionary) -> void:
	var players := combat_rules.players
	for role: int in players.keys():
		if role != player.role and not latest.has(role):
			_remove_proxy(role)
	for role: int in latest:
		if players.has(role):
			continue
		var proxy := combat_rules.add_player(role, _teams.get(role, 0), _player_collision)
		proxy.weapons.enabled_types = player.weapons.enabled_types

func _remove_proxy(role: int) -> void:
	combat_rules.remove_player(role)
	if _rollback.time_economy != null:
		_rollback.time_economy.accounts.erase(role)

func _end_projectile(id: int, tick: int, blast: Array = []) -> void:
	_rollback.queue_projectile_end(id, tick, blast)
	var view: ProjectileTrack = _projectiles.get(id)
	if view != null and (view.predicted or (tick > _playback.latest_tick and tick >= view.authority_tick)):
		_projectiles.erase(id)

func _sync_projectiles(authoritative: Dictionary) -> void:
	var last_tick := _playback.latest_tick
	for id: int in _projectiles.keys():
		var view := _projectiles[id]
		if view.authority_tick > last_tick:
			view.update_rewind(_shooter_rewinding(id))
		elif not view.predicted and not authoritative.has(id):
			_projectiles.erase(id)
	for id: int in authoritative:
		if _rollback.projectile_end_tick(id) <= last_tick:
			var state: Array = authoritative[id]
			_show_projectile(id, last_tick, state[BulletBody.Network.TYPE], state[BulletBody.Network.POS], state[BulletBody.Network.VEL])

func _show_projectile(id: int, tick: int, type_id: int, pos: Vector2, vel: Vector2) -> void:
	if _projectiles.has(id) and _projectiles[id].authority_tick > tick:
		return
	var view := _projectile_track(id, type_id)
	view.authority_tick = tick
	view.sample(tick, pos, vel, _shooter_rewinding(id))

func _shooter_rewinding(id: int) -> bool:
	var shooter: Array = _playback.latest_players.get(ShotRules.shooter_role(id), [])
	return not shooter.is_empty() and shooter[NetPlayer.REWIND]

func _projectile_track(id: int, type_id: int) -> ProjectileTrack:
	var shot: ProjectileTrack = _projectiles.get(id)
	if shot == null or shot.type_id != type_id:
		shot = ProjectileTrack.new(type_id, terrain.map_size)
		_projectiles[id] = shot
	return shot

func _draw_pickups(items: Dictionary) -> void:
	for item: Array in items.values():
		_show_pickup(item[WeaponPickup.Network.POS], item[WeaponPickup.Network.TYPE], item[WeaponPickup.Network.LOCKED_ROLE],
				item[WeaponPickup.Network.UNLOCK_TICK], _playback.latest_tick)

func _physics_process(delta: float) -> void:
	if phase != Phase.ONLINE:
		_local_motion.from = player.position
		return
	var perf_started := PerformanceStats.begin()
	var shown := _local_motion.shown(player.transform)
	var smooth_rewind := _apply_pending_authority()
	var input := controls.sample()
	_rollback.capture(_input_record(input, delta))
	var packet := _rollback.packet()
	NetBus.send_input(packet)
	_rollback.advance(delta, packet)
	if smooth_rewind:
		# 模拟完成后，从本帧开始时玩家看到的位置平滑过渡到校正后的位置。
		_local_motion.from = player.position
		_local_motion.correct(player.transform, GridPathfinder.wrap_to_range(shown, terrain.map_size), terrain.map_size, false)
	PerformanceStats.end(PerformanceStats.CLIENT_TICK, perf_started)

func _process(delta: float) -> void:
	if phase != Phase.ONLINE:
		return
	var perf_started := PerformanceStats.begin()
	var anchor := _local_motion.advance(delta, _rollback.render_offset(Engine.get_physics_interpolation_fraction()),
			player.transform, terrain.map_size)
	var haste := player.personal_haste_mult > 1.0
	_begin_frame(delta, anchor, haste, player.rewinding)
	var world := _playback.advance(delta, player.role)
	_frame.day_minute = Daylight.minute_at(_playback.render_tick * ActorStep.DT)
	for id: int in world["beams"]:
		if ShotRules.shooter_role(id) != player.role:
			_frame.sample_beam(world["beams"][id], _playback.render_tick)
	_set_nameplate(_local_pose(haste, player.rewinding), player.role)
	_sample_remotes(world["players"], anchor)
	_draw_pickups(world["pickups"])
	_present_projectiles(delta, anchor)
	for id: int in _projectiles:
		var shot := _projectiles[id]
		_frame.projectiles.append([id, shot.type_id, shot.position, shot.rotation])
	_view.present(delta, _frame)
	PerformanceStats.end(PerformanceStats.CLIENT_PRESENT, perf_started)

func _sample_remotes(samples: Dictionary, anchor: Vector2) -> void:
	for role: int in samples:
		var row: Array = samples[role]
		var sample: Array = row[Sample.SOURCE]
		var state: Array = sample[NetPlayer.STATE]
		_present_remote_motion(role, sample, _previous_samples.get(role, row)[Sample.SOURCE])
		var at := GridPathfinder.anchor_to_nearest(row[Sample.POS], anchor, terrain.map_size)
		var facing: int = state[PlayerStateSchema.FACING]
		var downed: bool = state[PlayerStateSchema.DOWNED]
		var pose := _player_pose(role, at, facing, state[PlayerStateSchema.STATE], downed, sample[NetPlayer.REWIND],
				state[PlayerStateSchema.HASTE_MULT] > 1.0)
		pose.remote = true
		var airborne: bool = not (state[PlayerStateSchema.GROUNDED] or state[PlayerStateSchema.IN_WATER] or state[PlayerStateSchema.CLIMB_LATCHED])
		var velocity: Vector2 = row[Sample.VEL]
		pose.air_speed = velocity.y if airborne else 0.0
		var type_id := PlayerStateSchema.equipped_type(state)
		var equipment: Array = state[PlayerStateSchema.EQUIPMENT]
		var aim: Vector2 = sample[NetPlayer.AIM]
		var draw_elapsed := -1.0
		if type_id == WeaponRegistry.Type.COMPOUND_BOW and equipment[GunBody.StateSlot.AIMING]:
			var serial: int = state[PlayerStateSchema.SHOT_SERIAL]
			var arrow := ShotRules.shot_id(role, serial + 1)
			var latest: Array = _playback.latest_players.get(role, sample)
			# 弹丸可先于插值中的人物更新到出箭帧。此时清除旧快照中的搭箭。
			if serial == latest[NetPlayer.STATE][PlayerStateSchema.SHOT_SERIAL] and not _projectiles.has(arrow) \
					and _rollback.projectile_end_tick(arrow) == -1:
				draw_elapsed = equipment[GunBody.StateSlot.HOLD]
		_weapon_pose(pose, type_id, aim if aim != Vector2.ZERO else Vector2(facing, 0),
				equipment[GunBody.StateSlot.SHOT_FACING] if type_id != 0 and aim != Vector2.ZERO else facing,
				equipment[GunBody.StateSlot.RELOAD_LEFT] if type_id != 0 else 0.0, draw_elapsed)
		_set_nameplate(pose, role)
		pose.health = float(state[PlayerStateSchema.HP]) / TeamRules.max_hp(_teams.get(role, 0), _team_counts) \
				if Settings.pvp_show_enemy_hp and not downed else -1.0
	_previous_samples = samples

func _set_nameplate(pose: MatchFrame.Pose, role: int) -> void:
	pose.name = _names.get(role, "玩家%d" % role)
	pose.team = _teams.get(role, role)
	pose.hue = float(_hues.get(role, 0.0)) / 360.0

func _present_remote_motion(role: int, sample: Array, previous: Array) -> void:
	if sample[NetPlayer.EPOCH] != previous[NetPlayer.EPOCH]:
		_world.clear_motion(role)
		return
	var state: Array = sample[NetPlayer.STATE]
	var before: Array = previous[NetPlayer.STATE]
	if sample[NetPlayer.REWIND] or previous[NetPlayer.REWIND] or state[PlayerStateSchema.DOWNED] or before[PlayerStateSchema.DOWNED]:
		return
	if state[PlayerStateSchema.IN_WATER] or state[PlayerStateSchema.CLIMB_LATCHED]:
		return
	var grounded: bool = state[PlayerStateSchema.GROUNDED]
	var was_grounded: bool = before[PlayerStateSchema.GROUNDED]
	if grounded and not was_grounded:
		var incoming: Vector2 = before[PlayerStateSchema.VEL] + before[PlayerStateSchema.KNOCK_VEL]
		_world.motion(role, &"land", _frame.now, incoming.y)
	elif not grounded and (was_grounded or before[PlayerStateSchema.COYOTE_TIMER] > 0.0):
		var velocity: Vector2 = state[PlayerStateSchema.VEL]
		if velocity.y < 0.0 and state[PlayerStateSchema.COYOTE_TIMER] == 0.0:
			_world.motion(role, &"jump", _frame.now)
	if state[PlayerStateSchema.CHARGE] and not before[PlayerStateSchema.CHARGE]:
		_world.motion(role, &"dash", _frame.now)

func _on_round_state(data: Dictionary) -> void:
	_round_state = data["state"]
	_view.pvp_hud.show_round(RoundProjection.sample(data, _names, _teams, _team_counts, player.role, _mode))
	_refresh_input_lock()

func _leave_result() -> void:
	_view.pvp_hud.set_status("等待其他玩家返回房间…")
	NetBus.send_event(NetEvent.Kind.LEAVE)

func _refresh_input_lock() -> void:
	controls.frozen = phase != Phase.ONLINE or _pause_open \
			or _round_state != NetEvent.RoundState.PLAYING

func _set_pause(open: bool) -> void:
	super(open)
	_refresh_input_lock()

func _present_projectiles(delta: float, anchor: Vector2) -> void:
	var live := combat_rules.projectiles
	var last_tick := _playback.latest_tick
	for id: int in _projectiles.keys():
		if _projectiles[id].predicted and not live.has(id):
			_projectiles.erase(id)
	for bullet: BulletBody in live.values():
		var id := bullet.entity_id
		if bullet.shooter != player or _rollback.projectile_end_tick(id) > last_tick \
				or (_projectiles.has(id) and not _projectiles[id].predicted):
			continue
		var view := _projectile_track(id, bullet.type_id)
		view.sample(_rollback.tick, bullet.position, bullet.velocity, player.rewinding)
	for view: ProjectileTrack in _projectiles.values():
		view.present(delta, anchor)

func _on_fire(shot: Dictionary) -> void:
	var vectors := _rollback.queue_shot(shot)
	var role: int = shot["role"]
	var type_id: int = shot["type_id"]
	if role != player.role:
		_world.fire(role, type_id, _frame.now)
	var at: int = shot["tick"]
	if at <= _playback.latest_tick or WeaponRegistry.definition(type_id)["attack"] != WeaponRegistry.Attack.PROJECTILE:
		return
	var id := ShotRules.shot_id(role, shot["serial"])
	var pos := GridPathfinder.wrap_to_range(shot["pos"], terrain.map_size)
	for pellet in vectors.size():
		var key := ShotRules.pellet_id(id, pellet)
		if _rollback.projectile_end_tick(key) < at:
			_show_projectile(key, at, type_id, pos, vectors[pellet])

func _clear_dynamics() -> void:
	_pending_states.clear()
	_pending_events.clear()
	combat_rules.clear()
	for role: int in combat_rules.players.keys():
		if role != player.role:
			_remove_proxy(role)
	_projectiles.clear()
	_previous_samples.clear()
	_reset_view()

func _unhandled_input(event: InputEvent) -> void:
	super(event)
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_K \
			and phase == Phase.ONLINE and _round_state != NetEvent.RoundState.MATCH_OVER:
		NetBus.send_event(NetEvent.Kind.SUICIDE)

func _begin_reconnect() -> void:
	if phase != Phase.ONLINE:
		return
	phase = Phase.RECONNECTING
	_refresh_input_lock()
	_view.pvp_hud.set_status("正在重连…")
	var error := await NetSession.rejoin_room(true)
	if phase == Phase.RECONNECTING and is_inside_tree():
		_go_offline("重连超时" if error == ERR_TIMEOUT else NetSession.room_error(error))

func _go_offline(message: String) -> void:
	phase = Phase.OFFLINE
	_refresh_input_lock()
	_view.pvp_hud.set_status(message)

func _exit_tree() -> void:
	if phase == Phase.RECONNECTING:
		NetSession.disconnect_client()
	phase = Phase.OFFLINE
	NetBus.ping_updated.disconnect(_view.pvp_hud.set_ping)
	NetBus.state_received.disconnect(_on_state)
	NetBus.event_received.disconnect(_on_event)
	NetBus.server_disconnected.disconnect(_begin_reconnect)
	NetBus.protocol_error.disconnect(_go_offline)
	super()
