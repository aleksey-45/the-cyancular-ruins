class_name AuthorityWorld
extends Node

signal state_ready(frame: Dictionary, targets: Array)
signal baseline_needed
signal event(kind: int, data: Variant, except_role: int)
var players: Dictionary = {}
var _actor_colliders: Dictionary = {}
var projectiles: Dictionary = {}
var pickups: Dictionary = {}
var terrain: NativeTerrain
var grid: Array[Array]:
	get: return terrain.get_grid_snapshot() if terrain != null else []
var _options: Dictionary = {}
var _disabled_weapons: Array[int] = []
var _snap_tick := 0
var map_revision: int:
	get: return terrain.revision if terrain != null else 0
var rules := MatchRules.new()
var time_economy: TimeEconomy
var beta: BetaHistory
var _round_state := NetEvent.RoundState.COUNTDOWN
var _round_num := 1
var _round_timer := 3.0
var _scores: Dictionary = {}
var _rounds_won: Dictionary = {}
var _last_round_winner := 0
var _stats: Dictionary = {}
var _hit_history: Dictionary = {}
var grace_snapshot: Dictionary = {}
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS
const HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS
var _log_at := Time.get_ticks_msec()
var _log_tick := 0
var _tick_max_us := 0
var _queue_max: Dictionary = {}
var _logged_round := ""
var _impact_roles: Dictionary = {}
var _input_arrivals: Dictionary = {}
var _simulation_phase := 0
var _reward_serial := 0
var _pending_time_rewards: Dictionary = {}

func setup(mode: String, map_path: String, roles: Array, teams: Dictionary, options: Dictionary, ai_roles: Array) -> void:
	var started := Time.get_ticks_msec()
	_options = options
	for type_id in options.get("disabled_weapons", []):
		_disabled_weapons.append(type_id)
	MazeGenerator.set_map_file(map_path)
	WorldBuilder.load_grid()
	terrain = TileDefs.terrain
	terrain.set_collision_profiling(FrameTrace.enabled)
	terrain.set_authoritative(true)
	terrain.changed.connect(_on_terrain_changed)
	SpawnPicker.reset_cache()
	rules.setup(mode, roles + ai_roles, teams, options)
	terrain.attach(self)
	CombatComponent.pvp_arena = true
	if options.get("beta", false):
		time_economy = TimeEconomy.new(TimeRules.from_dict(options["time"]))
		time_economy.awarded.connect(_on_time_awarded)
		beta = BetaHistory.new(self)
	for role in roles + ai_roles:
		var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		var src: PlayerInput = AiInputSource.new() if ai_roles.has(role) else PacketInputSource.new()
		player.set_input_source(src)
		player.role = role
		player.team = teams.get(role, 0)
		player.authority_world = self
		add_child(player)
		player.enable_manual_simulation()
		player.collision_layer = 0
		player.collision_mask = 1 | (16 if teams.get(role, 0) == 1 else 2)
		player.weapons.set_enabled_types(_disabled_weapons)
		players[role] = player
		_input_arrivals[role] = InputBuffer.neutral()
		_actor_colliders[role] = ActorCollider.new(player, 16 if player.team == 2 else 2)
		player.position = Vector2(rules.spawn_for(self, role, true)) * GameParameters.TILE_SIZE + Vector2.ONE * GameParameters.TILE_SIZE * 0.5
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
		if src is AiInputSource:
			var nav := AiNavigator.new()
			nav.host = self
			nav.role = role
			nav.src = src
			player.add_child(nav)
		if time_economy != null:
			time_economy.add_role(role)
	_setup_ground_weapons()
	GameLog.record("match_start", {"mode": mode, "map": map_path, "roles": roles, "ai_roles": ai_roles,
			"teams": teams, "beta": beta != null, "disabled_weapons": _disabled_weapons,
			"duration_ms": Time.get_ticks_msec() - started})

func _exit_tree() -> void:
	_log_sample()
	GameLog.record("world_exit", {"tick": _snap_tick, "round": _round_num})
	if terrain != null and terrain.changed.is_connected(_on_terrain_changed):
		terrain.changed.disconnect(_on_terrain_changed)

func _physics_process(_delta: float) -> void:
	var delta := ActorStep.DT
	var started := Time.get_ticks_usec()
	var events_before := NetBus.event_send_profile() if FrameTrace.enabled else PackedInt64Array()
	_snap_tick += 1
	for pickup: WeaponPickup in pickups.values():
		pickup.simulate_tick(delta)
	var roles := players.keys()
	roles.sort()
	for role in roles:
		_simulation_phase = role
		var player: CharacterBody2D = players[role]
		player.set_controls_locked(_round_state != NetEvent.RoundState.PLAYING)
		var src: PlayerInput = player.input_source
		_queue_max[role] = maxi(_queue_max.get(role, 0), player.input_buffer.frames.size())
		var record: Dictionary
		if src is PacketInputSource:
			record = player.input_buffer.take(_snap_tick)
			src.apply_packet(record)
		else:
			record = PacketInputSource.pack_record(src, 0, src.aim)
			record["view_tick"] = _snap_tick
		if time_economy != null:
			time_economy.step_haste(player, record, delta)
		if not player.rewinding:
			_handle_ground_actions(role, src)
		var step_at := Time.get_ticks_usec() if FrameTrace.enabled else 0
		var actions := _step_player(player, record, delta)
		var actions_at := Time.get_ticks_usec() if FrameTrace.enabled else 0
		player.execute_actions(actions)
		var broadcast_at := Time.get_ticks_usec() if FrameTrace.enabled else 0
		for action: Dictionary in actions:
			if action["kind"] == "fire":
				broadcast(NetEvent.Kind.FIRE, {"role": role, "shot": action["serial"],
						"type_id": player.weapons.current_type_id(),
						"sound": player.weapons.current_weapon().shot_sound()}, role)
		if FrameTrace.enabled:
			var fire_at := Time.get_ticks_usec()
			FrameTrace.span(&"server_actor_step", step_at, actions_at)
			FrameTrace.span(&"server_actor_actions", actions_at, broadcast_at)
			FrameTrace.span(&"server_fire_broadcast", broadcast_at, fire_at)
	if time_economy != null:
		beta.tick(delta)
		time_economy.tick(delta)
	_record_hitboxes()
	var actors_at := Time.get_ticks_usec()
	if FrameTrace.enabled: events_before = _trace_event_sends(&"server_actor_events", events_before)
	_simulation_phase = 0
	var bullets := live_bullets()
	bullets.sort_custom(func(a: BulletBase, b: BulletBase) -> bool: return a.entity_id < b.entity_id)
	for bullet: BulletBase in bullets:
		if not bullet.shooter.rewinding:
			bullet.simulate_tick(delta)
	var contacts_at := Time.get_ticks_usec() if FrameTrace.enabled else 0
	_adjudicate_bullets()
	var contacts_end := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var ended: Array[int] = []
	for bullet: BulletBase in bullets:
		if not bullet.explodes and (bullet.finished or bullet.is_queued_for_deletion()):
			ended.append(bullet.entity_id)
			projectiles.erase(bullet.entity_id)
	if not ended.is_empty():
		broadcast(NetEvent.Kind.BULLET_END, {"tick": _snap_tick, "ids": ended})
		GameLog.record("projectile_end", {"tick": _snap_tick, "ids": ended})
	_broadcast_pending_beams()
	var attacks_at := Time.get_ticks_usec()
	if FrameTrace.enabled:
		FrameTrace.span(&"server_projectile_motion", actors_at, contacts_at)
		FrameTrace.span(&"server_projectile_contacts", contacts_at, contacts_end)
		events_before = _trace_event_sends(&"server_attack_events", events_before)
	_simulation_phase = -1
	rules.tick(self, delta)
	_flush_time_rewards()
	terrain.flush_collisions()
	if FrameTrace.enabled:
		var profile := terrain.take_collision_profile()
		FrameTrace.count(&"terrain_collision_us", profile[0])
		FrameTrace.count(&"terrain_chunks", profile[1])
	var terrain_patch := terrain.take_network_changes()
	if not terrain_patch.is_empty():
		broadcast(NetEvent.Kind.TERRAIN, {"tick": _snap_tick, "revision": map_revision, "cells": terrain_patch})
	var fuses := {}
	for bullet: BulletBase in live_bullets():
		if bullet.fuse_started:
			bullet.fuse_started = false
			fuses[bullet.entity_id] = projectile_state(bullet)
	if not fuses.is_empty():
		GameLog.record("projectile_fuse", {"tick": _snap_tick, "projectiles": fuses})
		broadcast(NetEvent.Kind.BULLET_FUSE, {"tick": _snap_tick, "projectiles": fuses})
	var world_at := Time.get_ticks_usec()
	var targets := players.keys() if _snap_tick % 2 == 0 else _impact_roles.keys()
	if not targets.is_empty():
		if not _impact_roles.is_empty():
			GameLog.record("impact_state", {"tick": _snap_tick, "roles": _impact_roles.keys(),
					"extra": _snap_tick % 2 != 0, "map_revision": map_revision})
		state_ready.emit(world_state(), targets)
	_impact_roles.clear()
	var elapsed := Time.get_ticks_usec() - started
	if FrameTrace.enabled:
		FrameTrace.span(&"server_actors", started, actors_at)
		FrameTrace.span(&"server_attacks", actors_at, attacks_at)
		FrameTrace.span(&"server_world", attacks_at, world_at)
		FrameTrace.span(&"server_state", world_at, started + elapsed)
		FrameTrace.context(&"server", {"tick": _snap_tick, "players": players.size(), "projectiles": projectiles.size(), "map_revision": map_revision})
		_trace_event_sends(&"server_tail_events", events_before)
	_tick_max_us = maxi(_tick_max_us, elapsed)
	if elapsed > 1000000.0 * delta:
		GameLog.record("world_slow_tick", {"tick": _snap_tick, "duration_ms": elapsed / 1000.0,
				"actors_ms": (actors_at - started) / 1000.0, "attacks_ms": (attacks_at - actors_at) / 1000.0,
				"world_ms": (world_at - attacks_at) / 1000.0, "state_ms": (Time.get_ticks_usec() - world_at) / 1000.0,
				"players": players.size(), "projectiles": projectiles.size(), "map_revision": map_revision})
	if Time.get_ticks_msec() - _log_at >= 1000:
		_log_sample()

# 阶段内包含广播与记录；累计差值用于区分这些开销，不能与外层 span 相加。
func _trace_event_sends(label: StringName, before: PackedInt64Array) -> PackedInt64Array:
	var after := NetBus.event_send_profile()
	FrameTrace.context(label, {"count": after[0] - before[0],
			"encode_us": after[1] - before[1], "send_us": after[2] - before[2],
			"log_us": after[3] - before[3], "encodes": after[4] - before[4]})
	return after

func _step_player(player: CharacterBody2D, record: Dictionary, delta: float) -> Array:
	player.actor_colliders.assign(_actor_colliders.values())
	return ActorStep.step(player, record, delta)

func add_projectile(bullet: BulletBase) -> void:
	add_child(bullet)
	var id := bullet.entity_id
	projectiles[id] = bullet
	broadcast(NetEvent.Kind.BULLET_SPAWN, {"id": id, "type_id": bullet.type_id,
			"pos": bullet.position, "vel": bullet.velocity_vec, "tick": _snap_tick})
	if bullet.explodes:
		GameLog.record("explosive_spawn", {"tick": _snap_tick, "id": id, "type": bullet.type_id,
				"position": bullet.position, "velocity": bullet.velocity_vec})
	bullet.tree_exiting.connect(func() -> void: projectiles.erase(id))

func accept_input(role: int, packet: Dictionary) -> bool:
	var previous: Dictionary = _input_arrivals[role]
	var buffer: InputBuffer = players[role].input_buffer
	var latest := previous
	for record: Dictionary in packet["frames"]:
		if record["epoch"] == players[role].input_buffer.epoch and record["seq"] > latest["seq"]:
			latest = record
	var changed: bool = latest["ax"] != previous["ax"] or latest["held"] != previous["held"]
	if latest["seq"] > previous["seq"]:
		if changed:
			GameLog.record("input_arrival", {"role": role, "tick": _snap_tick,
					"lead_ticks": latest["target_tick"] - _snap_tick, "input": latest, "frames": packet["frames"]})
		_input_arrivals[role] = latest
	for action: Dictionary in packet["actions"]:
		if action["epoch"] == buffer.epoch and action["seq"] > buffer.action_ack and not buffer.actions.has(action["seq"]):
			changed = true
	buffer.push(packet, _snap_tick)
	return changed

func new_epoch(role: int) -> void:
	var player: CharacterBody2D = players[role]
	player.input_buffer.reset(player.input_buffer.epoch + 1)
	_input_arrivals[role] = InputBuffer.neutral()
	GameLog.record("control_epoch", {"tick": _snap_tick, "role": role, "epoch": player.input_buffer.epoch})
	if player.input_source is PacketInputSource:
		player.input_source.reset_state()

func respawn(role: int, heal: bool = true, initial: bool = false) -> void:
	var player: CharacterBody2D = players[role]
	player.position = Vector2(rules.spawn_for(self, role, initial)) * GameParameters.TILE_SIZE + Vector2.ONE * GameParameters.TILE_SIZE * 0.5
	player.reset_motion()
	if heal:
		player.apply_authoritative_state(player.max_hp, player.max_waterproof, false)
	player.respawn_tick = 0
	player.last_attacker = 0
	_stats[role]["hits"].clear()
	if beta != null:
		if beta.cursors.has(role):
			beta.finish(role)
		beta.frames.erase(role)
	new_epoch(role)
	GameLog.record("respawn", {"tick": _snap_tick, "role": role, "position": player.position, "hp": player.hp})

func start_round() -> void:
	if beta != null:
		beta.reset()
	_hit_history.clear()
	for bullet in live_bullets():
		bullet.queue_free()
	terrain.reset()
	_reset_ground_weapons()
	_round_num += 1
	_scores.clear()
	for role in players:
		respawn(role, true, true)
		_stats[role]["rounds"] = _round_num
	_round_state = NetEvent.RoundState.COUNTDOWN
	_round_timer = 3.0
	baseline_needed.emit()

func remove_role(role: int) -> void:
	for bullet: BulletBase in live_bullets():
		if bullet.shooter == players[role]:
			bullet.queue_free()
	if beta != null:
		if beta.cursors.has(role):
			beta.finish(role)
		beta.frames.erase(role)
	_stats[role]["left"] = true
	players[role].queue_free()
	players.erase(role)
	_actor_colliders.erase(role)
	_input_arrivals.erase(role)
	rules.left(self, role)

func team_of(role: int) -> int:
	return int(rules.teams.get(role, 0))

func same_team(a: int, b: int) -> bool:
	return rules.same_team(a, b)

func is_friendly(a: Node, b: Node) -> bool:
	return same_team(_role_of(a), _role_of(b))

func _role_of(node: Node) -> int:
	return node.role if node != null else 0

func broadcast(kind: int, data: Variant, except_role: int = -1) -> void:
	if kind == NetEvent.Kind.TERRAIN:
		GameLog.record("terrain_patch", data)
	if kind in [NetEvent.Kind.FIRE, NetEvent.Kind.HIT, NetEvent.Kind.KILL, NetEvent.Kind.BEAM, NetEvent.Kind.TIME_REWARD]:
		GameLog.record("combat", {"tick": _snap_tick, "round": _round_num, "kind": NetEvent.Kind.keys()[kind], "payload": data})
	event.emit(kind, data, except_role)

func round_state() -> Dictionary:
	var alive := {}
	var deaths := {}
	for role in players:
		alive[role] = not players[role].is_downed()
	for role in _roster():
		deaths[role] = _stat_entry(role)["deaths"]
	var result := {"state": _round_state, "round": _round_num, "scores": _scores.duplicate(), "rounds_won": _rounds_won.duplicate(),
			"timer": ceilf(rules.match_time) if rules.mode == PvpSession.MODE_ROYALE and _round_state == NetEvent.RoundState.PLAYING else _round_timer,
			"winner": _last_round_winner, "match_winner": rules.winner, "mvp": mvp_role(), "stats": stats_payload(), "left": _stats.keys().filter(func(role: int) -> bool: return _stats[role]["left"]), "grace": grace_snapshot.duplicate(), "alive": alive, "deaths": deaths}
	return result

func broadcast_round() -> void:
	var key := JSON.stringify([_round_num, _round_state, _scores, _rounds_won])
	if key != _logged_round:
		_logged_round = key
		GameLog.record("round_state", round_state())
	broadcast(NetEvent.Kind.ROUND, round_state())

func live_bullets() -> Array:
	return projectiles.values().filter(func(bullet: BulletBase) -> bool: return not bullet.is_queued_for_deletion())

func world_state() -> Dictionary:
	var actors := {}
	for role in players:
		var player: CharacterBody2D = players[role]
		var weapon: WeaponBase = player.weapons.current_weapon()
		var driver: Dictionary = player.capture_driver_state()
		# 回合规则在角色阶段之后切换；快照提供下一步将采用的锁，不能沿用上一角色阶段的值。
		driver["locked"] = _round_state != NetEvent.RoundState.PLAYING
		actors[role] = player.capture_motion_state().merged({"pose": player.state,
				"driver": driver, "input": _prediction_input(player),
				"rewind_path": beta.collision_path(role) if beta != null else [],
				"type_id": player.weapons.current_type_id(), "hp": player.hp, "waterproof": player.waterproof, "downed": player.is_downed(),
				"aim": player.get_current_aim_dir(), "previewing": weapon.is_previewing() if weapon != null else false,
				"haste": player.pvp_haste_mult > 1.0, "rewind": player.rewinding, "epoch": player.input_buffer.epoch,
				"respawn_tick": player.respawn_tick if _round_state == NetEvent.RoundState.PLAYING else 0,
				"input_ack": player.input_buffer.ack, "action_ack": player.input_buffer.action_ack,
				"input_age": mini(_snap_tick - player.input_buffer._last["target_tick"], InputBuffer.HOLD_TICKS + 1) if player.input_source is PacketInputSource else 0,
				"axis": player.step_input.axis,
				"held": player.step_input.held,
				"move_mult": player.weapons.movement_multiplier()})
	var drops := {}
	for pickup: WeaponPickup in pickups.values():
		drops[pickup.inst] = {"type_id": pickup.type_id, "mag": pickup.mag,
				"pos": pickup.canonical_pos, "vel": pickup.velocity}
	return {"players": actors, "pickups": drops, "projectiles": projectile_states()}

func _prediction_input(player: CharacterBody2D) -> Dictionary:
	if player.input_source is PacketInputSource:
		return InputBuffer.neutral().merged(player.input_buffer._last, true)
	return InputBuffer.neutral().merged({"epoch": player.input_buffer.epoch, "target_tick": _snap_tick,
			"view_tick": player.view_tick, "ax": player.step_input.raw_axis,
			"held": player.step_input.raw_held, "aim": player.step_input.aim}, true)

func _on_time_awarded(role: int, amount: int) -> void:
	# 一次爆炸可能摧毁许多子格；同阶段没有再次消费账户，实际入账额可以合批。
	var key := Vector3i(_snap_tick, _simulation_phase, role)
	_pending_time_rewards[key] = _pending_time_rewards.get(key, 0) + amount

func _flush_time_rewards() -> void:
	for key: Vector3i in _pending_time_rewards:
		_reward_serial += 1
		broadcast(NetEvent.Kind.TIME_REWARD, {"tick": key.x, "serial": _reward_serial,
				"phase": key.y, "role": key.z, "amount": _pending_time_rewards[key]})
	_pending_time_rewards.clear()

func state_for(role: int, frame: Dictionary) -> Dictionary:
	var player: CharacterBody2D = players[role]
	var state: Dictionary = player.capture_state()
	state["locked"] = _round_state != NetEvent.RoundState.PLAYING
	return {"tick": _snap_tick, "map_revision": map_revision, "world": frame,
			"own": {"epoch": player.input_buffer.epoch, "ack": player.input_buffer.ack,
			"action_ack": player.input_buffer.action_ack, "timing_seq": player.input_buffer.timing_seq,
			"lead": player.input_buffer.lead, "input": InputBuffer.neutral().merged(player.input_buffer._last, true),
			"state": state, "rewind": player.rewinding},
			"time": time_economy.state_payload() if time_economy != null else {}}

func _on_terrain_changed() -> void:
	var blocks := terrain.take_rewards()
	if time_economy != null:
		for role in blocks: time_economy.award_blocks(role, blocks[role])

func _record_hitboxes() -> void:
	var boxes := {}
	for role in players:
		boxes[role] = CollisionAabb.world_rect(players[role])
	_hit_history[_snap_tick] = boxes
	_hit_history.erase(_snap_tick - 13)

func target_rect_at(target: Node2D, shooter: Node2D) -> Rect2:
	var tick := clampi(shooter.view_tick, _snap_tick - 12, _snap_tick)
	return _hit_history.get(tick, {}).get(_role_of(target), CollisionAabb.world_rect(target))

func _on_bullet_hit(bullet: BulletBase, victim: Node2D, _victim_role: int) -> void:
	damage(bullet.shooter.role, victim.role, bullet.position, bullet.hit_damage, false, bullet.hit_impact, bullet.entity_id)
	bullet.finish()

func _grenade_direct_hit(bullet: BulletBase, victim: Node2D) -> void:
	bullet.direct_hit = true
	damage(bullet.shooter.role, victim.role, bullet.position, bullet.direct_hit_damage, false, bullet.hit_impact, bullet.entity_id)
	bullet.start_player_fuse()

func _broadcast_pending_beams() -> void:
	for role in players:
		var weapon: WeaponBase = players[role].weapons.current_weapon()
		if weapon is LaserWeaponBase:
			var report: Dictionary = weapon.collect_pending_beam_report()
			if not report.is_empty():
				report["shooter_role"] = role
				report.merge({"id": (role << 48) | (players[role].shot_serial << 8),
						"tick": _snap_tick, "type_id": weapon.type_id})
				broadcast(NetEvent.Kind.BEAM, report, role)

func _stat_entry(role: int) -> Dictionary:
	return _stats[role]

func _roster() -> Dictionary:
	return _stats

func stats_payload() -> Dictionary:
	var result := {}
	for role in _stats:
		var s: Dictionary = _stats[role]
		var score := ScoreRules.kscore(s["kills"], s["assists"], s["dealt"], s["deaths"],
				s["team_damage"], s["self_damage"], s["team_kills"])
		result[role] = {"kills": s["kills"], "deaths": s["deaths"], "assists": s["assists"],
				"dealt": s["dealt"], "taken": s["taken"], "kscore": score, "acs": ScoreRules.acs(score, s["rounds"])}
	return result

func mvp_role() -> int:
	var stats := stats_payload()
	var roles := stats.keys()
	roles.sort()
	roles.sort_custom(func(a: int, b: int) -> bool:
		if stats[a]["acs"] != stats[b]["acs"]:
			return stats[a]["acs"] > stats[b]["acs"]
		if stats[a]["kills"] != stats[b]["kills"]:
			return stats[a]["kills"] > stats[b]["kills"]
		return stats[a]["deaths"] < stats[b]["deaths"])
	return roles[0]

func damage(attacker: int, victim_role: int, pos: Vector2, amount: int, ignore_iframes: bool = false, knockback: float = -1,
		impact_id: int = 0, source: int = 0) -> void:
	var victim: Node2D = players[victim_role]
	var before: int = victim.hp
	var before_knock: Vector2 = victim.combat.knock_velocity
	victim.take_hit(pos, amount, ignore_iframes, knockback)
	var dealt: int = before - victim.hp
	if knockback > 0.0 and (dealt > 0 or victim.combat.knock_velocity != before_knock):
		_impact_roles[victim_role] = true
	if dealt <= 0:
		if victim.combat.knock_velocity != before_knock:
			_broadcast_hit(attacker, victim_role, 0, pos, impact_id, source)
		return
	var v: Dictionary = _stats[victim_role]
	if attacker == victim_role:
		v["self_damage"] += dealt
	elif attacker != 0:
		victim.last_attacker = attacker
		victim.last_hit_tick = _snap_tick
		v["hits"][attacker] = _snap_tick
		if same_team(attacker, victim_role):
			_stats[attacker]["team_damage"] += dealt
		else:
			_stats[attacker]["dealt"] += dealt
			v["taken"] += dealt
			if time_economy != null:
				time_economy.award_damage(attacker, victim_role, dealt)
	_broadcast_hit(attacker, victim_role, dealt, pos, impact_id, source)

func _broadcast_hit(attacker: int, victim: int, damage_amount: int, pos: Vector2, id: int, source: int) -> void:
	var hit := {"shooter": attacker, "victim": victim, "damage": damage_amount, "pos": pos,
			"id": id, "tick": _snap_tick, "source": source, "knock": players[victim].combat.knock_velocity,
			"hp": players[victim].hp, "facing": players[victim].facing_direction}
	GameLog.record("combat_impact", hit)
	broadcast(NetEvent.Kind.HIT, hit)

func _record_down(victim_role: int, killer: int) -> void:
	_stats[victim_role]["deaths"] += 1
	if killer == 0:
		return
	if same_team(killer, victim_role):
		_stats[killer]["team_kills"] += 1
		return
	_stats[killer]["kills"] += 1
	if time_economy != null:
		time_economy.award_kill(killer, victim_role)
	var hits: Dictionary = _stats[victim_role]["hits"]
	for attacker in hits:
		if attacker != killer and same_team(attacker, killer) and (_snap_tick - hits[attacker]) * ActorStep.DT * 1000 <= ATTRIB_WINDOW:
			_stats[attacker]["assists"] += 1

func killer_for(player: Node2D) -> int:
	if players.has(player.last_attacker) and (_snap_tick - player.last_hit_tick) * ActorStep.DT * 1000 <= ATTRIB_WINDOW:
		return player.last_attacker
	return 0

var _next_pickup_id := 1

func _spawn_ground_weapon(type_id: int, mag: int, pos: Vector2, vel: Vector2, owner_role: int = 0) -> int:
	var pickup: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	pickup.configure(type_id, _next_pickup_id, mag, vel)
	_next_pickup_id += 1
	pickup.locked_role = owner_role
	pickup.unlock_tick = _snap_tick + ceili(PlayerParams.weapon_pickup_self_delay * 60)
	pickup.position = pos
	pickup.canonical_pos = pos
	add_child(pickup)
	pickup.set_physics_process(false)
	pickups[pickup.inst] = pickup
	return pickup.inst

func _remove_ground_weapon(id: int) -> void:
	pickups[id].queue_free()
	pickups.erase(id)

func _handle_ground_actions(role: int, src: PlayerInput) -> void:
	var player: Node2D = players[role]
	if player.is_downed():
		return
	if src.is_pickup_pressed():
		_try_server_pickup(player, role)
	if src.is_drop_pressed():
		if src is PacketInputSource and src._switch_inst > 0:
			player.weapons.equip_inst(src._switch_inst)
			if player.weapons.current_inst() != src._switch_inst:
				return
		_try_server_drop(player, role)

func _try_server_pickup(player: Node2D, role: int) -> void:
	var nearest: WeaponPickup
	var distance := PlayerParams.weapon_pickup_radius
	for pickup: WeaponPickup in pickups.values():
		if pickup.locked_role == role and _snap_tick < pickup.unlock_tick:
			continue
		var d := GridPathfinder.toroidal_delta_px(player.position, pickup.canonical_pos,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d <= distance:
			distance = d
			nearest = pickup
	if nearest == null:
		return
	var dropped: int = player.weapons.pick_up(nearest.type_id, nearest.mag)
	if dropped < 0:
		return
	GameLog.record("pickup", {"tick": _snap_tick, "role": role, "id": nearest.inst,
			"type": nearest.type_id, "mag": nearest.mag, "replaced_type": dropped})
	_remove_ground_weapon(nearest.inst)
	if dropped > 0:
		_drop_pickup(player, player.weapons.take_last_dropped(), role)

func _drop_pickup(player: Node2D, item: Dictionary, role: int) -> void:
	GameLog.record("drop", {"tick": _snap_tick, "role": role, "item": item})
	_spawn_ground_weapon(item["type"], item["mag"],
			player.position + PlayerParams.weapon_drop_offset * Vector2(player.facing_direction, 1),
			Vector2(PlayerParams.weapon_drop_speed * player.facing_direction, -PlayerParams.weapon_drop_up), role)

func _try_server_drop(player: Node2D, role: int) -> void:
	if player.weapons.current_type_id() != 0:
		_drop_pickup(player, player.weapons.drop_current(), role)

func _drop_all_but_one(player: Node2D, role: int) -> void:
	var items: Array = player.weapons.random_keep_one()
	for i in items.size():
		var angle := TAU * i / items.size()
		_spawn_ground_weapon(items[i]["type"], items[i]["mag"], player.position + Vector2(0, -12),
				Vector2(cos(angle), -absf(sin(angle))) * 380, role)

func _setup_ground_weapons() -> void:
	var types: Array = []
	for id in WeaponRegistry.all_ids():
		if not _disabled_weapons.has(id):
			types.append_array([id, id])
	var cells: Array = []
	for y in grid.size():
		for x in grid[y].size():
			if MazeGenerator.is_floor_cell_with_headroom(grid, Vector2i(x, y)):
				cells.append(Vector2i(x, y))
	var dims := SpawnPicker.grid_dims()
	var points := GridPathfinder.spread_cells(cells, types.size(), 10, dims.x, dims.y)
	for i in points.size():
		_spawn_ground_weapon(types[i], WeaponInventory.MAG_FULL,
				(Vector2(points[i]) + Vector2.ONE * 0.5) * GameParameters.TILE_SIZE, Vector2.ZERO)
	for player in players.values():
		var pickup: WeaponPickup = pickups.values().pick_random()
		player.weapons.set_initial_inventory([pickup.type_id])
		_remove_ground_weapon(pickup.inst)

func _reset_ground_weapons() -> void:
	for id in pickups.keys():
		_remove_ground_weapon(id)
	_setup_ground_weapons()

func _adjudicate_bullets() -> void:
	var bullets := live_bullets()
	bullets.sort_custom(func(a: BulletBase, b: BulletBase) -> bool: return a.entity_id < b.entity_id)
	for bullet: BulletBase in bullets:
		if bullet.finished or bullet.is_queued_for_deletion():
			continue
		if bullet.shooter == null or bullet.shooter.rewinding:
			continue
		var victim := bullet.player_contact(players.values())
		bullet.adjudicated_pos = bullet.global_position
		bullet.adjudicated = true
		if victim != null:
			if bullet.explodes:
				if not bullet.direct_hit:
					_grenade_direct_hit(bullet, victim)
			else:
				_on_bullet_hit(bullet, victim, victim.role)

func projectile_state(bullet: BulletBase) -> Dictionary:
	return bullet.motion_state()

func projectile_states() -> Dictionary:
	var result := {}
	for bullet: BulletBase in live_bullets():
		result[bullet.entity_id] = projectile_state(bullet)
	return result

func _log_sample() -> void:
	var actors := {}
	for role in players:
		var player: CharacterBody2D = players[role]
		var buffer: InputBuffer = player.input_buffer
		actors[role] = {"position": player.position, "velocity": player.velocity, "hp": player.hp,
				"epoch": buffer.epoch, "ack": buffer.ack, "action_ack": buffer.action_ack,
				"lead": buffer.lead, "missing_ticks": buffer._missing, "frames": buffer.frames.size(),
				"last_input": buffer._last,
				"actions": buffer.actions.size(), "queue_max": _queue_max.get(role, 0), "input_totals": buffer.diagnostics,
				"ai": player.input_source is AiInputSource, "rewind": player.rewinding, "weapon": player.weapons.log_state()}
	var now := Time.get_ticks_msec()
	var bullets := {}
	for bullet: BulletBase in live_bullets():
		bullets[bullet.entity_id] = projectile_state(bullet)
	GameLog.record("world_state", {"interval_ms": now - _log_at, "ticks": _snap_tick - _log_tick,
			"tick_max_ms": _tick_max_us / 1000.0, "tick": _snap_tick, "round": _round_num,
			"round_state": NetEvent.RoundState.keys()[_round_state], "map_revision": map_revision,
			"players": actors, "projectiles": bullets, "pickups": pickups.size()})
	_log_at = now
	_log_tick = _snap_tick
	_tick_max_us = 0
	_queue_max.clear()
