class_name AuthorityWorld
extends Node

signal state_ready(frame: Dictionary)
signal baseline_needed
signal event(kind: int, data: Variant, except_role: int)
var players: Dictionary = {}
var combat_rules: CombatSimulator
var pickups: Dictionary = {}
var terrain: Terrain
var _options: Dictionary = {}
var _enabled_weapons: Array[int]
var _snap_tick := 0
var map_revision: int:
	get: return terrain.revision if terrain != null else 0
var rules := MatchRules.new()
var time_economy: TimeEconomy
var beta: BetaHistory
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
	var map := MapCatalog.random_map() if map_path.is_empty() else MapFormat.load_map(map_path)
	var map_name := "随机地图" if map_path.is_empty() else map_path
	if map.is_empty():
		return "无法读取地图 %s" % map_name
	if mode == PvpSession.MODE_TEAM:
		var problem := MatchRules.validate_team_spawns(map_name, map)
		if not problem.is_empty():
			return problem
	elif mode == PvpSession.MODE_PVP and not map["spawns"].has("player"):
		return "地图 %s 缺少玩家出生点" % map_name

	var spawn_problem := rules.setup(mode, roles, teams, map, options)
	if not spawn_problem.is_empty():
		return spawn_problem
	_options = options
	map_bytes = map["bytes"]
	terrain = Terrain.new(map["grid"], map["descriptors"])
	terrain.authoritative = true
	terrain.changed.connect(_on_terrain_changed)
	terrain.attach(self)
	combat_rules = CombatSimulator.new(terrain, self, true)
	combat_rules.players = players
	combat_rules.team_counts = rules.team_counts
	combat_rules.projectile_ended.connect(func(id: int) -> void: _ended_projectiles.append(id))
	combat_rules.detonated.connect(_detonated)
	combat_rules.player_hit.connect(_on_player_hit)
	if options.get("beta", false):
		time_economy = TimeEconomy.new(options["time"])
		beta = BetaHistory.new(self)
	for role in roles:
		var player: Player = preload("res://scenes/player/player.tscn").instantiate()
		player.role = role
		player.set_team_collision(teams.get(role, 0))
		player.process_mode = Node.PROCESS_MODE_DISABLED
		player.ground_actions = _handle_ground_actions
		player.projectile_count = combat_rules.count_projectiles.bind(player)
		add_child(player)
		player.weapons.enabled_types = _enabled_weapons
		player.position = terrain.cell_center(rules.spawns[role])
		player.sync_collision_geometry()
		players[role] = player
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
		if time_economy != null:
			time_economy.add_role(role)
	_apply_team_hp()
	_setup_ground_weapons()
	return ""

# 团队模式按固定阵容设置角色最大生命；其他模式保持默认满血。
func _apply_team_hp() -> void:
	for role in players:
		var player: ActorBody = players[role]
		var maximum := PlayerParams.player_max_hp
		if not rules.team_counts.is_empty():
			maximum = TeamRules.max_hp(int(rules.teams.get(role, 0)), rules.team_counts)
		player.sim_max_hp = maximum
		player.sim_hp = maximum

func _exit_tree() -> void:
	if terrain != null and terrain.changed.is_connected(_on_terrain_changed):
		terrain.changed.disconnect(_on_terrain_changed)

func _physics_process(_delta: float) -> void:
	var perf_tick := PerformanceStats.begin()
	var perf_simulation := PerformanceStats.begin()
	var delta := ActorStep.DT
	_snap_tick += 1
	combat_rules.tick = _snap_tick
	var playing := rules.phase == NetEvent.RoundState.PLAYING
	for pickup: WeaponPickup in pickups.values():
		pickup.simulate_tick(delta)
	for player: Player in players.values():
		player._controls_locked = not playing
	var stepped := ActorStep.step_players(players, _snap_tick, time_economy)
	if time_economy != null:
		beta.tick(delta)
		time_economy.tick(delta)

	for player: Player in stepped:
		for action: Dictionary in player.step_actions:
			if action["kind"] == "fire":
				broadcast(NetEvent.Kind.FIRE, action.merged({"role": player.role, "tick": _snap_tick}))
		combat_rules.submit(player, player.step_actions)
	combat_rules.step_projectiles(delta)
	if not _ended_projectiles.is_empty():
		broadcast(NetEvent.Kind.BULLET_END, {"tick": _snap_tick, "ids": _ended_projectiles})
		_ended_projectiles = []
	combat_rules.settle_blasts()
	terrain.flush_collisions()
	var terrain_patch := terrain.take_network_changes()
	if not terrain_patch.is_empty():
		broadcast(NetEvent.Kind.TERRAIN, {"tick": _snap_tick, "revision": map_revision, "cells": terrain_patch})
	_advance_round(delta)
	PerformanceStats.end(PerformanceStats.SERVER_SIMULATION, perf_simulation)
	if rules.phase != NetEvent.RoundState.MATCH_OVER and (_snap_tick % 2 == 0 or _impact_tick == _snap_tick):
		state_ready.emit(world_state())
	PerformanceStats.end(PerformanceStats.SERVER_TICK, perf_tick)

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
		player.respawn_tick = _snap_tick + MatchRules.RESPAWN_TICKS
		_drop_all_but_one(player, role)
		var killer := rules.score_down(role, killer_for(player))
		_record_down(role, killer)
		broadcast(NetEvent.Kind.KILL, [killer, role])
		if rules.mode == PvpSession.MODE_PVP and not players[killer].sim_downed:
			respawn(killer, false)
		broadcast_round()
	for role: int in players:
		var player: Player = players[role]
		if player.respawn_tick > 0 and _snap_tick >= player.respawn_tick:
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
			set_physics_process(false)
	broadcast_round()
	if rules.phase == NetEvent.RoundState.MATCH_OVER:
		state_ready.emit(world_state())

func _detonated(id: int, at: Vector2, type_id: int) -> void:
	broadcast(NetEvent.Kind.EXPLOSION, {"id": id, "type_id": type_id, "pos": at, "tick": _snap_tick})

func accept_input(role: int, packet: Array) -> void:
	if rules.phase != NetEvent.RoundState.MATCH_OVER:
		players[role].input_buffer.push(packet, _snap_tick)

func clear_input(role: int) -> void:
	var player: Player = players[role]
	player.input_buffer.reset(player.input_buffer.epoch)

func suicide(role: int) -> void:
	if rules.phase == NetEvent.RoundState.PLAYING:
		var player: Player = players[role]
		player.last_attacker = 0
		player.force_down()

func new_epoch(role: int) -> void:
	var player: Player = players[role]
	player.input_buffer.reset(player.input_buffer.epoch + 1)

func respawn(role: int, heal: bool = true, initial: bool = false) -> bool:
	var player: Player = players[role]
	var cell := rules.spawn_for(players, role, initial)
	if cell.x < 0 or cell.y < 0:
		return false
	player.position = terrain.cell_center(cell)
	player.reset_motion()
	if heal:
		player.apply_authoritative_state(player.sim_max_hp, player.max_waterproof, false)
	else:
		player.sync_collision_geometry()
	player.respawn_tick = 0
	player.last_attacker = 0
	_stats[role]["hits"].clear()
	if beta != null:
		if beta.cursors.has(role):
			beta.finish(role)
		beta.frames.erase(role)
	new_epoch(role)
	return true

func _reset_round() -> void:
	if beta != null:
		beta.reset()
	combat_rules.clear()
	terrain.reset()
	_reset_ground_weapons()
	for role in players:
		respawn(role, true, true)
		_stats[role]["rounds"] = rules.round_number
	baseline_needed.emit()

func remove_role(role: int) -> void:
	for bullet: BulletBody in combat_rules.projectiles.values():
		if bullet.shooter == players[role]:
			combat_rules.erase_projectile(bullet.entity_id)
	if beta != null:
		if beta.cursors.has(role):
			beta.finish(role)
		beta.frames.erase(role)
	_stats[role]["left"] = true
	players[role].queue_free()
	players.erase(role)
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
		var snapshot := player.capture_network_state()
		snapshot["state"]["actor"][PlayerStateSchema.CONTROLS_LOCKED] = rules.phase != NetEvent.RoundState.PLAYING
		if not player.sim_downed or rules.phase != NetEvent.RoundState.PLAYING or player.respawn_tick <= _snap_tick:
			snapshot["respawn_tick"] = 0
		actors[role] = snapshot
	var drops := {}
	for pickup: WeaponPickup in pickups.values():
		drops[pickup.inst] = [pickup.canonical_pos, pickup.velocity, pickup.type_id, pickup.carried]
	var projectiles := {}
	for bullet: BulletBody in combat_rules.projectiles.values():
		projectiles[bullet.entity_id] = {"type_id": bullet.type_id, "pos": bullet.position, "vel": bullet.velocity_vec}
	var frame := {"players": actors, "pickups": drops, "projectiles": projectiles}
	PerformanceStats.end(PerformanceStats.WORLD_CAPTURE, perf_started)
	return frame

func state_for(role: int, frame: Dictionary, accounts: Dictionary) -> Dictionary:
	var input: InputBuffer = players[role].input_buffer
	return {"tick": _snap_tick, "map_revision": map_revision, "world": frame,
			"own": {"timing_seq": input.timing_seq, "lead": input.lead}, "time": accounts}

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
		# 团队赛只在分出胜负后从获胜队选 MVP；平局没有 MVP。
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
		_impact_tick = _snap_tick
	if dealt <= 0 and not knock_changed and force >= 0.0:
		return
	var victim_role := victim.role
	if dealt > 0:
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
	broadcast(NetEvent.Kind.HIT, {"shooter": attacker, "victim": victim_role, "damage": maxi(dealt, 0),
			"tick": _snap_tick, "epoch": victim.input_buffer.epoch, "hp": victim.sim_hp,
			"impulse_mode": int(signf(force)), "pos": victim.global_position,
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
		if attacker != killer and same_team(attacker, killer) and _snap_tick - hits[attacker] <= ATTRIB_WINDOW_TICKS:
			_stats[attacker]["assists"] += 1

func killer_for(player: Player) -> int:
	if players.has(player.last_attacker) and _snap_tick - player.last_hit_tick <= ATTRIB_WINDOW_TICKS:
		return player.last_attacker
	return 0

var _next_pickup_id := 1

func _spawn_ground_weapon(type_id: int, carried: int, pos: Vector2, vel: Vector2, owner_role: int = 0) -> WeaponPickup:
	var pickup: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	pickup.configure(type_id, _next_pickup_id, carried, vel)
	_next_pickup_id += 1
	pickup.locked_role = owner_role
	pickup.unlock_tick = _snap_tick + ceili(PlayerParams.weapon_pickup_self_delay * 60)
	pickup.position = pos
	pickup.canonical_pos = pos
	add_child(pickup)
	pickup.set_physics_process(false)
	pickups[pickup.inst] = pickup
	return pickup

func _remove_ground_weapon(id: int) -> void:
	pickups[id].queue_free()
	pickups.erase(id)

func _handle_ground_actions(player: Player, record: Array) -> void:
	var role := player.role
	var pressed: int = record[ActorInput.PRESSED]
	var spawn := _spawn_ground_weapon.bind(role)
	if pressed & ActorInput.BIT_PICKUP:
		GroundWeaponField.pick_up(pickups, player, terrain.map_size,
				func(item: WeaponPickup) -> bool: return item.locked_role != role or _snap_tick >= item.unlock_tick, spawn)
	if pressed & ActorInput.BIT_DROP:
		var weapon: int = record[ActorInput.WINST]
		if weapon > 0:
			player.weapons.equip_inst(weapon)
			if player.weapons.current_inst() != weapon:
				return
		GroundWeaponField.drop(player, player.weapons.drop_current(), spawn)

func _drop_all_but_one(player: Player, role: int) -> void:
	var items: Array = player.weapons.random_keep_one()
	for i in items.size():
		var angle := TAU * i / items.size()
		_spawn_ground_weapon(items[i]["type"], items[i]["carried"], player.position + Vector2(0, -12),
				Vector2(cos(angle), -absf(sin(angle))) * 380, role)

func _setup_ground_weapons() -> void:
	for player: Player in players.values():
		player.weapons.set_initial_inventory([_enabled_weapons.pick_random()])
	GroundWeaponField.scatter(terrain, rules.floor_cells, _enabled_weapons, _spawn_ground_weapon)

func _reset_ground_weapons() -> void:
	for id in pickups.keys():
		_remove_ground_weapon(id)
	_setup_ground_weapons()
