class_name AuthorityWorld
extends RefCounted

signal state_ready(frame: Dictionary)
signal baseline_needed
signal event(kind: int, data: Variant, except_role: int)
var players: Dictionary[int, Player]:
	get: return combat_rules.players
var combat_rules: CombatSimulator
var terrain: Terrain
var _options: Dictionary = {}
var _enabled_weapons: Array[int]
var _weapon_floors: Array[Vector2i]
var map_revision: int:
	get: return terrain.revision if terrain != null else 0
var rules := MatchRules.new()
var time_economy: TimeEconomy
var _rewinds: Dictionary[int, RewindHistory] = {}
var _schedulers: Dictionary[int, InputScheduler] = {}
var map_bytes: PackedByteArray
var _stats: Dictionary = {}
var _final_round: Dictionary = {}

const ATTRIB_WINDOW_TICKS := 180
var _impact_tick := -1
var _ended_projectiles: Array[int] = []

func setup(mode: String, map_path: String, roles: Array, teams: Dictionary, options: Dictionary) -> String:
	_enabled_weapons = WeaponRegistry.enabled_ids(options.get("disabled_weapons", []))
	if _enabled_weapons.is_empty():
		return "请至少启用一种武器"
	var paths: Array[String] = [map_path]
	if map_path.is_empty():
		paths = MapCatalog.shuffled_paths()
	var map: Dictionary
	var problem := "没有可用的联机地图"
	for path in paths:
		map = MapFormat.load_map(path)
		if map.is_empty():
			problem = "无法读取地图 %s" % path
			continue
		problem = rules.setup(mode, roles, teams, map, options)
		if problem.is_empty():
			break
		problem = "地图 %s：%s" % [path, problem]
	if not problem.is_empty():
		return problem
	_options = options
	map_bytes = map["bytes"]
	_weapon_floors = SpawnPicker.floor_cells(map["grid"], map["size"])
	terrain = Terrain.new(map["grid"], map["descriptors"])
	terrain.authoritative = true
	terrain.changed.connect(_on_terrain_changed)
	combat_rules = CombatSimulator.new(terrain)
	combat_rules.team_counts = rules.team_counts
	combat_rules.projectile_ended.connect(_on_projectile_ended)
	combat_rules.detonated.connect(_detonated)
	combat_rules.fired.connect(_on_fired)
	combat_rules.player_hit.connect(_on_player_hit)
	if options.get("beta", false):
		time_economy = TimeEconomy.new(options["time"])
	for role in roles:
		var player := combat_rules.add_player(role, teams.get(role, 0), rules.player_collision)
		player.weapons.enabled_types = _enabled_weapons
		player.sim_max_hp = TeamRules.max_hp(player.team, rules.team_counts)
		player.sim_hp = player.sim_max_hp
		player.position = terrain.cell_center(rules.spawns[role])
		player.sync_collision_geometry()
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
		if time_economy != null:
			time_economy.add_role(role)
	_setup_ground_weapons()
	return ""

func step() -> void:
	if rules.phase == NetEvent.RoundState.MATCH_OVER:
		return
	var perf_tick := PerformanceStats.begin()
	var perf_simulation := PerformanceStats.begin()
	var playing := rules.phase == NetEvent.RoundState.PLAYING
	for player: Player in players.values():
		player._controls_locked = not playing
	var next := combat_rules.tick + 1
	for role: int in _schedulers:
		_schedulers[role].update(next)
	var inputs := ActorStep.buffered_inputs(players, next)
	if time_economy != null:
		_step_rewinds(inputs, next)
		time_economy.advance(players, inputs)
	combat_rules.step(inputs)
	if not _ended_projectiles.is_empty():
		broadcast(NetEvent.Kind.BULLET_END, {"tick": combat_rules.tick, "ids": _ended_projectiles})
		_ended_projectiles = []
	var terrain_patch := terrain.take_network_changes()
	if not terrain_patch.is_empty():
		broadcast(NetEvent.Kind.TERRAIN, {"tick": combat_rules.tick, "revision": map_revision, "cells": terrain_patch})
	_advance_round(ActorStep.DT)
	PerformanceStats.end(PerformanceStats.SERVER_SIMULATION, perf_simulation)
	if rules.phase != NetEvent.RoundState.MATCH_OVER and (combat_rules.tick % 2 == 0 or _impact_tick == combat_rules.tick):
		state_ready.emit(world_state())
	PerformanceStats.end(PerformanceStats.SERVER_TICK, perf_tick)

func _step_rewinds(inputs: Dictionary, at: int) -> void:
	var sample: CombatSnapshot
	var reversing: Array[RewindHistory] = []
	for role: int in players:
		var player := players[role]
		var history: RewindHistory = _rewinds.get(role)
		if history == null:
			history = RewindHistory.new(combat_rules, role, time_economy.rewind_seconds)
			_rewinds[role] = history
		var account := time_economy.accounts[role]
		if int(inputs[role][ActorInput.HELD]) & ActorInput.BIT_REWIND and history.can_rewind() \
				and account.can_spend() and not player._controls_locked and not player.sim_downed:
			player.rewinding = true
			account.spend(ActorStep.DT, time_economy.rules["rewind_burn"])
			reversing.append(history)
		else:
			if player.rewinding:
				player.rewinding = false
				new_epoch(role)
				inputs[role] = player.input_buffer.take(at)
			sample = history.record(ActorStep.DT, sample)
	# 当帧的采样完成后，再恢复各个玩家所选的时刻。
	for history in reversing:
		history.rewind(ActorStep.DT)

func start_countdown() -> void:
	if rules.start_countdown():
		broadcast_round()

func _advance_round(delta: float) -> void:
	var previous := rules.phase
	var seconds := ceili(rules.match_time)
	if previous == NetEvent.RoundState.PLAYING:
		_settle_downs_and_respawns()
	rules.advance(delta)
	if rules.phase != previous:
		_apply_round_transition()
	elif ceili(rules.match_time) != seconds:
		broadcast_round()

func _settle_downs_and_respawns() -> void:
	for role: int in players:
		var player: Player = players[role]
		if not player.sim_downed or player.respawn_tick > 0:
			continue
		player.respawn_tick = combat_rules.tick + MatchRules.RESPAWN_TICKS
		_drop_all_but_one(player, role)
		var killer := rules.score_down(role, killer_for(player))
		_record_down(role, killer)
		broadcast(NetEvent.Kind.KILL, [killer, role])
		if rules.mode == PvpSession.MODE_PVP and not players[killer].sim_downed:
			respawn(killer, false)
		broadcast_round()
	for role: int in players:
		var player: Player = players[role]
		if player.respawn_tick > 0 and combat_rules.tick >= player.respawn_tick:
			respawn(role)

func _apply_round_transition() -> void:
	match rules.phase:
		NetEvent.RoundState.WAITING:
			_reset_round()
			return
		NetEvent.RoundState.PLAYING:
			if _options.get("round_full_heal", false):
				for player: Player in players.values():
					player.apply_authoritative_state(player.sim_max_hp, player.max_waterproof, false)
		NetEvent.RoundState.MATCH_OVER:
			combat_rules.clear_blasts()
			_final_round = _round_payload()
	broadcast_round()
	if rules.phase == NetEvent.RoundState.MATCH_OVER:
		state_ready.emit(world_state())

func _on_fired(shot: Dictionary) -> void:
	broadcast(NetEvent.Kind.FIRE, shot)

func _on_projectile_ended(id: int) -> void:
	_ended_projectiles.append(id)

func _detonated(id: int, at: Vector2, type_id: int) -> void:
	broadcast(NetEvent.Kind.EXPLOSION, {"id": id, "type_id": type_id, "pos": at, "tick": combat_rules.tick})

func accept_input(role: int, packet: Array, received_us: int, input_at_snapshot := 0) -> void:
	if rules.phase == NetEvent.RoundState.MATCH_OVER:
		return
	if not _schedulers.has(role):
		_schedulers[role] = InputScheduler.new()
	if not _schedulers[role].submit(players[role].input_buffer, packet, combat_rules.tick, received_us, input_at_snapshot):
		new_epoch(role)

func clear_input(role: int) -> void:
	_schedulers.erase(role)
	var player: Player = players[role]
	player.input_buffer.reset(player.input_buffer.epoch)

func suicide(role: int) -> void:
	if rules.phase == NetEvent.RoundState.PLAYING:
		var player: Player = players[role]
		player.last_attacker = 0
		player.force_down()

func new_epoch(role: int) -> void:
	_schedulers.erase(role)
	var player: Player = players[role]
	player.input_buffer.reset(player.input_buffer.epoch + 1)

func respawn(role: int, heal: bool = true, initial: bool = false) -> bool:
	var player: Player = players[role]
	var cell := rules.spawn_for(players, role, initial)
	if cell == SpawnPicker.NO_CELL:
		return false
	player.spawn_at(cell, heal)
	player.respawn_tick = 0
	player.last_attacker = 0
	_stats[role]["hits"].clear()
	_rewinds.erase(role)
	player.rewinding = false
	new_epoch(role)
	return true

func _reset_round() -> void:
	combat_rules.clear()
	terrain.reset()
	_reset_ground_weapons()
	for role in players:
		respawn(role, true, true)
		_stats[role]["rounds"] = rules.round_number
	baseline_needed.emit()

func remove_role(role: int) -> void:
	_schedulers.erase(role)
	_rewinds.erase(role)
	_stats[role]["left"] = true
	combat_rules.remove_player(role)
	if time_economy != null:
		time_economy.accounts.erase(role)
	if rules.role_left(players.keys()):
		_apply_round_transition()

func same_team(a: int, b: int) -> bool:
	return rules.same_team(a, b)

func broadcast(kind: int, data: Variant, except_role: int = -1) -> void:
	event.emit(kind, data, except_role)

func round_state() -> Dictionary:
	return _final_round.duplicate() if rules.phase == NetEvent.RoundState.MATCH_OVER else _round_payload()

func _round_payload() -> Dictionary:
	var alive := {}
	for role in players:
		alive[role] = not players[role].sim_downed
	var stats := stats_payload()
	var timer := ceilf(rules.match_time) if rules.mode == PvpSession.MODE_ROYALE \
			and rules.phase == NetEvent.RoundState.PLAYING else rules.round_timer
	return {"state": rules.phase, "round": rules.round_number, "scores": rules.scores.duplicate(),
			"rounds_won": rules.rounds_won.duplicate(), "timer": timer, "winner": rules.round_winner,
			"match_winner": rules.winner, "mvp": _mvp_role(stats), "stats": stats,
			"left": _stats.keys().filter(func(role: int) -> bool: return _stats[role]["left"]),
			"alive": alive}

func broadcast_round() -> void:
	broadcast(NetEvent.Kind.ROUND, round_state())

func world_state() -> Dictionary:
	var perf_started := PerformanceStats.begin()
	var actors := {}
	for role: int in players:
		var player: Player = players[role]
		var snapshot := player.capture_checkpoint()
		snapshot[PlayerStateSchema.Network.STATE][PlayerStateSchema.CONTROLS_LOCKED] = rules.phase != NetEvent.RoundState.PLAYING
		if not player.sim_downed or rules.phase != NetEvent.RoundState.PLAYING or player.respawn_tick <= combat_rules.tick:
			snapshot[PlayerStateSchema.Network.RESPAWN_TICK] = 0
		actors[role] = snapshot
	var projectiles := {}
	for bullet: BulletBody in combat_rules.projectiles.values():
		projectiles[bullet.entity_id] = [bullet.type_id, bullet.position, bullet.velocity]
	var frame := {"players": actors, "pickups": combat_rules.ground.snapshot(), "projectiles": projectiles,
			"beams": combat_rules.beams.duplicate()}
	PerformanceStats.end(PerformanceStats.WORLD_CAPTURE, perf_started)
	return frame

func state_for(role: int, frame: Dictionary, accounts: Dictionary) -> Dictionary:
	var state := {"tick": combat_rules.tick, "map_revision": map_revision, "world": frame,
			"own": InputScheduler.UNBOUND, "time": accounts}
	if _schedulers.has(role):
		state["own"] = _schedulers[role].announcement()
		state["_sent_input"] = Vector2i(players[role].input_buffer.epoch, _schedulers[role].latest_input())
		if _schedulers[role].notice_confirmed():
			state["notice_ack"] = true
	return state

func _on_terrain_changed() -> void:
	var blocks := terrain.take_rewards()
	if time_economy != null:
		for role in blocks: time_economy.award_blocks(role, blocks[role])

func stats_payload() -> Dictionary:
	var result := {}
	for role in _stats:
		var s: Dictionary = _stats[role]
		var score := ScoreRules.kscore(s["kills"], s["assists"], s["dealt"], s["deaths"],
				s["team_damage"], s["self_damage"], s["team_kills"])
		result[role] = {"kills": s["kills"], "deaths": s["deaths"], "assists": s["assists"],
				"dealt": s["dealt"], "taken": s["taken"], "acs": ScoreRules.acs(score, s["rounds"])}
	return result

func mvp_role() -> int:
	return _mvp_role(stats_payload())

func _mvp_role(stats: Dictionary) -> int:
	if stats.is_empty():
		return 0
	var candidates: Array = []
	if rules.mode == PvpSession.MODE_TEAM or not rules.team_counts.is_empty():
		# 只有获胜队伍的队员参与团队赛 MVP 评选。平局时没有 MVP。
		if rules.winner == 0:
			return 0
		for role in stats:
			if int(rules.teams.get(int(role), 0)) == int(rules.winner):
				candidates.append(int(role))
		if candidates.is_empty():
			push_error("AuthorityWorld: 团队结算缺少获胜队 %d 的玩家统计" % int(rules.winner))
			return 0
	else:
		for role in stats:
			candidates.append(int(role))
	candidates.sort_custom(func(a: int, b: int) -> bool: return _mvp_better(stats, a, b))
	return int(candidates[0])

static func _mvp_better(stats: Dictionary, a: int, b: int) -> bool:
	if stats[a]["acs"] != stats[b]["acs"]:
		return stats[a]["acs"] > stats[b]["acs"]
	if stats[a]["kills"] != stats[b]["kills"]:
		return stats[a]["kills"] > stats[b]["kills"]
	if stats[a]["deaths"] != stats[b]["deaths"]:
		return stats[a]["deaths"] < stats[b]["deaths"]
	return a < b

func _on_player_hit(attacker: int, victim: Player, dealt: int, knock_changed: bool, force: float) -> void:
	if force != 0.0 or victim.sim_downed:
		_impact_tick = combat_rules.tick
	if dealt <= 0 and not knock_changed and force >= 0.0:
		return
	var victim_role := victim.role
	if dealt > 0:
		var v: Dictionary = _stats[victim_role]
		if attacker == victim_role:
			v["self_damage"] += dealt
		elif attacker != 0:
			victim.last_attacker = attacker
			victim.last_hit_tick = combat_rules.tick
			v["hits"][attacker] = combat_rules.tick
			if same_team(attacker, victim_role):
				_stats[attacker]["team_damage"] += dealt
			else:
				_stats[attacker]["dealt"] += dealt
				v["taken"] += dealt
				if time_economy != null:
					time_economy.award_damage(attacker, victim_role, dealt)
	broadcast(NetEvent.Kind.HIT, {"shooter": attacker, "victim": victim_role, "damage": maxi(dealt, 0),
			"tick": combat_rules.tick, "epoch": victim.input_buffer.epoch, "hp": victim.sim_hp,
			"impulse_mode": int(signf(force)), "pos": victim.position,
			"facing": victim.facing_direction, "vel": victim.velocity, "knock": victim.motion_knock_velocity})

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
		if attacker != killer and same_team(attacker, killer) and combat_rules.tick - hits[attacker] <= ATTRIB_WINDOW_TICKS:
			_stats[attacker]["assists"] += 1

func killer_for(player: Player) -> int:
	if players.has(player.last_attacker) and combat_rules.tick - player.last_hit_tick <= ATTRIB_WINDOW_TICKS:
		return player.last_attacker
	return 0

func _drop_all_but_one(player: Player, role: int) -> void:
	var items: Array = player.weapons.random_keep_one()
	for i in items.size():
		var angle := TAU * i / items.size()
		combat_rules.ground.spawn(items[i]["type"], items[i]["carried"], player.position + Vector2(0, -12),
				Vector2(cos(angle), -absf(sin(angle))) * 380, role)

func _setup_ground_weapons() -> void:
	for player: Player in players.values():
		player.weapons.set_initial_inventory([_enabled_weapons.pick_random()])
	combat_rules.ground.scatter(_weapon_floors, _enabled_weapons)

func _reset_ground_weapons() -> void:
	combat_rules.ground.clear()
	_setup_ground_weapons()
