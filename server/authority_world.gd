class_name AuthorityWorld
extends Node

signal state_ready(frame: Dictionary)
signal baseline_needed
signal event(kind: int, data: Variant, except_role: int)
var players: Dictionary = {}
var projectiles: Dictionary = {}
var pickups: Dictionary = {}
var grid: Array[Array] = []
var _base_grid: Array[Array] = []
var _base_subgrid: Array[Array] = []
var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
var _options: Dictionary = {}
var _disabled_weapons: Array[int] = []
var _snap_tick := 0
var map_revision := 0
var _terrain_hp: Dictionary = {}
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

func setup(mode: String, map_path: String, roles: Array, teams: Dictionary, options: Dictionary, ai_roles: Array) -> void:
	_options = options
	for type_id in options.get("disabled_weapons", []):
		_disabled_weapons.append(type_id)
	MazeGenerator.set_map_file(map_path)
	grid = WorldBuilder.load_grid()
	_base_grid = MazeGenerator.copy_grid(grid)
	_base_subgrid = MazeGenerator.copy_grid(MazeGenerator.current_subgrid)
	SpawnPicker.reset_cache()
	rules.setup(mode, roles + ai_roles, teams, options)
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	TileDefs.on_destroyed = _on_tile_destroyed
	TileDefs.on_sub_destroyed = _on_sub_destroyed
	TileDefs.on_sub_damaged = _on_sub_damaged
	destructible_sub = WorldBuilder.build_sim(self, grid)
	CombatComponent.pvp_arena = true
	if options.get("beta", false):
		time_economy = TimeEconomy.new(TimeRules.from_dict(options["time"]))
		beta = BetaHistory.new(self)
	for role in roles + ai_roles:
		var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		var src: PlayerInput = AiInputSource.new() if ai_roles.has(role) else PacketInputSource.new()
		player.set_input_source(src)
		player.set_physics_process(false)
		player.role = role
		player.authority_world = self
		add_child(player)
		player.collision_layer = 16 if teams.get(role, 0) == 2 else 2
		player.collision_mask = 1 | (16 if teams.get(role, 0) == 1 else 2)
		player.weapons.set_enabled_types(_disabled_weapons)
		players[role] = player
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

func _exit_tree() -> void:
	TileDefs.on_destroyed = Callable()
	TileDefs.on_sub_destroyed = Callable()
	TileDefs.on_sub_damaged = Callable()

func _physics_process(delta: float) -> void:
	_snap_tick += 1
	for pickup: WeaponPickup in pickups.values():
		pickup.simulate_tick(delta)
	for role in players:
		var player: CharacterBody2D = players[role]
		player.set_controls_locked(_round_state != NetEvent.RoundState.PLAYING)
		var src: PlayerInput = player.input_source
		var record: Dictionary
		if src is PacketInputSource:
			record = player.input_buffer.take(_snap_tick)
			src.apply_packet(record)
		else:
			record = PacketInputSource.pack_record(src, 0, src.aim)
			record["view_tick"] = _snap_tick
		if time_economy != null:
			var account: GrainAccount = time_economy.accounts[role]
			var haste: bool = src.haste_held() and account.can_spend() and _round_state == NetEvent.RoundState.PLAYING
			if haste:
				account.spend(delta, time_economy.rules.haste_burn)
			player.pvp_haste_mult = time_economy.rules.haste_mult if haste else 1.0
		if not player.rewinding:
			_handle_ground_actions(role, src)
		var actions := ActorStep.step(player, record, delta)
		player.execute_actions(actions)
		for action: Dictionary in actions:
			if action["kind"] == "fire":
				broadcast(NetEvent.Kind.FIRE, {"role": role, "shot": action["serial"],
						"type_id": player.weapons.current_type_id(),
						"sound": player.weapons.current_weapon().shot_sound()}, role)
	if time_economy != null:
		beta.tick(delta)
		time_economy.tick(delta)
	_record_hitboxes()
	for bullet: BulletBase in live_bullets():
		if not bullet.shooter.rewinding:
			bullet.simulate_tick(delta)
	_adjudicate_bullets()
	_broadcast_pending_beams()
	rules.tick(self, delta)
	for chunk in _dirty_chunks:
		CollisionBuilder.rebuild_chunk(destructible_sub, chunk, self)
	_dirty_chunks.clear()
	if _snap_tick % 2 == 0:
		state_ready.emit(world_state())

func add_projectile(bullet: BulletBase) -> void:
	add_child(bullet)
	var id := bullet.entity_id
	projectiles[id] = bullet
	bullet.tree_exiting.connect(func() -> void: projectiles.erase(id))

func accept_input(role: int, packet: Dictionary) -> void:
	players[role].input_buffer.push(packet, _snap_tick)

func new_epoch(role: int) -> void:
	var player: CharacterBody2D = players[role]
	player.input_buffer.reset(player.input_buffer.epoch + 1)
	if player.input_source is PacketInputSource:
		player.input_source.reset_state()

func respawn(role: int, heal: bool = true, initial: bool = false) -> void:
	var player: CharacterBody2D = players[role]
	player.position = Vector2(rules.spawn_for(self, role, initial)) * GameParameters.TILE_SIZE + Vector2.ONE * GameParameters.TILE_SIZE * 0.5
	player.velocity = Vector2.ZERO
	player.cancel_jump_state()
	player.cancel_charge()
	if heal:
		player.apply_authoritative_state(player.max_hp, player.max_waterproof, false)
	player.respawn_left = 0.0
	player.last_attacker = 0
	_stats[role]["hits"].clear()
	if beta != null:
		if beta.cursors.has(role):
			beta.finish(role)
		beta.frames.erase(role)
	new_epoch(role)

func start_round() -> void:
	if beta != null:
		beta.reset()
	_hit_history.clear()
	for bullet in live_bullets():
		bullet.queue_free()
	grid = MazeGenerator.copy_grid(_base_grid)
	MazeGenerator.current_grid = grid
	MazeGenerator.current_subgrid = MazeGenerator.copy_grid(_base_subgrid)
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	_terrain_hp.clear()
	map_revision += 1
	destructible_sub = WorldBuilder.build_sim(self, grid)
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
	broadcast(NetEvent.Kind.ROUND, round_state())

func live_bullets() -> Array:
	return projectiles.values().filter(func(bullet: BulletBase) -> bool: return not bullet.is_queued_for_deletion())

func world_state() -> Dictionary:
	var actors := {}
	for role in players:
		var player: CharacterBody2D = players[role]
		var weapon: WeaponBase = player.weapons.current_weapon()
		actors[role] = {"pos": player.position, "vel": player.velocity, "facing": player.get_facing(), "pose": player.state,
				"type_id": player.weapons.current_type_id(), "hp": player.hp, "waterproof": player.waterproof, "downed": player.is_downed(),
				"aim": player.get_current_aim_dir(), "previewing": weapon.is_previewing() if weapon != null else false,
				"haste": player.pvp_haste_mult > 1.0, "rewind": player.rewinding, "epoch": player.input_buffer.epoch}
	var bullets := {}
	for bullet: BulletBase in live_bullets():
		bullets[bullet.entity_id] = projectile_state(bullet)
	var drops := {}
	for pickup: WeaponPickup in pickups.values():
		drops[pickup.inst] = {"type_id": pickup.type_id, "mag": pickup.mag,
				"pos": pickup.canonical_pos, "vel": pickup.velocity}
	return {"players": actors, "projectiles": bullets, "pickups": drops}

func state_for(role: int, frame: Dictionary) -> Dictionary:
	var player: CharacterBody2D = players[role]
	return {"tick": _snap_tick, "map_revision": map_revision, "world": frame,
			"own": {"epoch": player.input_buffer.epoch, "ack": player.input_buffer.ack,
			"action_ack": player.input_buffer.action_ack, "timing_seq": player.input_buffer.timing_seq,
			"lead": player.input_buffer.lead, "input": InputBuffer.neutral().merged(player.input_buffer._last, true),
			"state": player.capture_state(), "rewind": player.rewinding},
			"time": time_economy.state_payload() if time_economy != null else {}}

func _on_sub_damaged(sub: Vector2i, hp: int) -> void:
	_terrain_hp[sub] = hp
	map_revision += 1
	broadcast(NetEvent.Kind.TERRAIN, {"revision": map_revision, "sub": sub, "hp": hp})

func _on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	destructible_sub[sub.y][sub.x] = 0
	_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	if time_economy != null and _role_of(owner) > 0:
		time_economy.award_blocks(_role_of(owner), 1)

func _on_tile_destroyed(cell: Vector2i) -> void:
	for y in 4:
		for x in 4:
			TileDefs.apply_sub_hp(cell * 4 + Vector2i(x, y), 0)

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
	damage(bullet.shooter.role, victim.role, bullet.position, bullet.hit_damage, false, bullet.hit_impact)
	bullet.queue_free()

func _grenade_direct_hit(bullet: BulletBase, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
	damage(bullet.shooter.role, victim.role, bullet.position, bullet.direct_hit_damage, false, bullet.hit_impact)
	bullet.start_player_fuse()

func _broadcast_pending_beams() -> void:
	for role in players:
		var weapon: WeaponBase = players[role].weapons.current_weapon()
		if weapon is LaserWeaponBase:
			var report: Dictionary = weapon.collect_pending_beam_report()
			if not report.is_empty():
				report["shooter_role"] = role
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

func damage(attacker: int, victim_role: int, pos: Vector2, amount: int, ignore_iframes: bool = false, knockback: float = -1) -> void:
	var victim: Node2D = players[victim_role]
	var before: int = victim.hp
	victim.take_hit(pos, amount, ignore_iframes, knockback)
	var dealt: int = before - victim.hp
	if dealt <= 0:
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
	broadcast(NetEvent.Kind.HIT, {"shooter": attacker, "victim": victim_role, "damage": dealt, "pos": pos})

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
	_remove_ground_weapon(nearest.inst)
	if dropped > 0:
		_drop_pickup(player, player.weapons.take_last_dropped(), role)

func _drop_pickup(player: Node2D, item: Dictionary, role: int) -> void:
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
	for bullet: BulletBase in live_bullets():
		if bullet.is_queued_for_deletion():
			continue
		if bullet.shooter == null or bullet.shooter.rewinding:
			continue
		var from := bullet.adjudicated_pos if bullet.adjudicated else bullet.global_position
		var to := from + GridPathfinder.toroidal_delta_px(from, bullet.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var best := INF
		var victim_role := 0
		var shooter_role := _role_of(bullet.shooter)
		for role in players:
			var player: Node2D = players[role]
			if player == bullet.shooter or player.is_downed() or same_team(shooter_role, int(role)):
				continue
			var center := GridPathfinder.anchor_to_nearest(player.global_position, from,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			var hit := Geometry2D.get_closest_point_to_segment(center, from, to)
			if hit.distance_to(center) < HIT_RADIUS and from.distance_squared_to(hit) < best:
				best = from.distance_squared_to(hit)
				victim_role = int(role)
		bullet.adjudicated_pos = bullet.global_position
		bullet.adjudicated = true
		if victim_role != 0:
			if bullet.explodes:
				if not bullet.has_meta("grenade_direct_hit"):
					_grenade_direct_hit(bullet, players[victim_role])
			else:
				_on_bullet_hit(bullet, players[victim_role], victim_role)

func projectile_state(bullet: BulletBase) -> Dictionary:
	return {"type_id": bullet.type_id, "input_seq": bullet.input_seq, "input_epoch": bullet.input_epoch,
			"pos": bullet.position, "vel": bullet.velocity_vec}
