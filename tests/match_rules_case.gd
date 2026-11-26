extends "res://tests/simulation_fixture.gd"

func run(tree: SceneTree) -> void:
	_team_rules()
	_team_health(tree)
	_mvp()
	_duel_spawns()
	_team_setup()
	_team_respawn(tree)
	_sparse_spawn_map(tree)

func _team_health(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var attacker := player(parent, 1)
	var victim := player(parent, 2)
	var friendly := player(parent, 3)
	_place(attacker, Vector2(300, 300), 2)
	_place(victim, Vector2(400, 300), 1)
	_place(friendly, Vector2(200, 300), 2)
	var sim := parent.combat
	sim.team_counts = {1: 4, 2: 1}
	var hp := victim.sim_hp
	sim.resolve_hit(attacker, victim, CombatProfiles.DIRECT, victim.position, 10, 0.0)
	expect(victim.sim_hp == hp - 11, "team compensation increases the disadvantaged player's hit once")
	var previous := victim.sim_hp
	sim.resolve_hit(attacker, victim, CombatProfiles.DIRECT, victim.position, 10, 0.0)
	expect(victim.sim_hp == previous - 11 and not sim.resolve_hit(null, victim, CombatProfiles.BIRD_BOMB_HIT,
			victim.position, 1, 0.0), "consecutive gun hits apply while bird attacks respect active iframes")
	expect(not sim.resolve_hit(attacker, friendly, CombatProfiles.DIRECT, friendly.position, 10, 0.0)
			and friendly.sim_hp == hp, "a direct hit excludes allies")
	sim.resolve_hit(attacker, friendly, CombatProfiles.BLAST, friendly.position, 10, 0.0)
	sim.resolve_hit(attacker, attacker, CombatProfiles.BLAST, attacker.position, 10, 0.0)
	expect(friendly.sim_hp == hp - 10 and attacker.sim_hp == hp - 10,
			"friendly and self blast damage are allowed without compensation")
	cleanup()

func _team_rules() -> void:
	expect(TeamRules.kills_to_win(2) == 5 and TeamRules.kills_to_win(6) == 9,
			"kills target follows total players (2->5, 6->9)")
	expect(TeamRules.kills_to_win(3) == 6 and TeamRules.kills_to_win(4) == 7 and TeamRules.kills_to_win(5) == 8,
			"kills target follows total players (3/4/5)")
	expect(TeamRules.kills_to_win(10) == 13, "5v5 kills target is 13")
	var two_one := TeamRules.team_counts({1: 1, 2: 1, 3: 2})
	expect(two_one == {1: 2, 2: 1}, "team_counts splits A/B")
	expect(TeamRules.disadvantaged_team(two_one) == 2, "the smaller team is disadvantaged")
	expect(TeamRules.score_bonus(2, two_one) == 1 and TeamRules.score_bonus(1, two_one) == 0,
			"score bonus equals the player difference")
	expect(TeamRules.max_hp(2, two_one) == 55 and TeamRules.max_hp(1, two_one) == 50,
			"disadvantaged team starts with 55 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, two_one), 1.0),
			"a one-player difference does not boost damage")
	var four_one := TeamRules.team_counts({1: 1, 2: 1, 3: 1, 4: 1, 5: 2})
	expect(TeamRules.score_bonus(2, four_one) == 3 and TeamRules.max_hp(2, four_one) == 65,
			"4v1 gives 3 points and 65 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, four_one), 1.1), "4v1 damage is x1.1")
	var five_one := TeamRules.team_counts({1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 2})
	expect(TeamRules.score_bonus(2, five_one) == 4 and TeamRules.max_hp(2, five_one) == 70,
			"5v1 gives 4 points and 70 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, five_one), 1.2), "5v1 damage is x1.2")
	expect(is_equal_approx(TeamRules.damage_factor(1, 2, five_one), 1.0),
			"only the disadvantaged side deals extra damage")
	expect(is_equal_approx(TeamRules.damage_factor(2, 2, five_one), 1.0), "friendly damage is not boosted")
	expect(is_equal_approx(TeamRules.damage_factor(0, 1, five_one), 1.0), "unowned damage is not boosted")
	var even := TeamRules.team_counts({1: 1, 2: 2})
	expect(TeamRules.disadvantaged_team(even) == 0 and TeamRules.score_bonus(1, even) == 0,
			"equal teams have no compensation")

func _mvp() -> void:
	var host := arena(WorldSpec.TEAM, [1, 2, 3, 4], {1: 1, 2: 1, 3: 2, 4: 2}, {})
	var world := host.world
	for id: int in world.players:
		world._stats[id]["kills"] = 50 if id == 1 else (20 if id == 3 else 1)
	world.rules.winner = 2
	expect(arena_round(world)["mvp"] == 3, "the team MVP comes from the winning team")
	world._stats[4]["kills"] = 20
	expect(arena_round(world)["mvp"] == 3, "an exact statistical tie is decided by role order")
	world.rules.winner = 0
	expect(arena_round(world)["mvp"] == 0, "a drawn team match has no MVP")
	host.close()

func _duel_spawns() -> void:
	var host := arena(WorldSpec.DUEL, [1, 2], {}, {"player_collision": true})
	var world := host.world
	var sides := SpawnPicker.respawn_cells(world.spec.map)
	expect(world.problem.is_empty(), "the duel loads the multiplayer spawn points")
	expect(players_on_map_points(world, [1], sides[1]) and players_on_map_points(world, [2], sides[2]),
			"duelists open on their respective marked sides")
	world.rules.phase = MatchRules.Phase.PLAYING
	var winner := world.players[1]
	var victim := world.players[2]
	winner.position = Vector2.ZERO
	winner.sim_hp = 13
	victim.position = Vector2.ZERO
	victim.apply_hit_health(0)
	host.fixed_step()
	expect(winner.sim_hp == 13 and players_on_map_points(world, [1], sides[1])
			and victim.sim_downed and victim.respawn_tick == world.tick + MatchRules.RESPAWN_TICKS,
			"the survivor moves to a marked point with current HP while the victim waits")
	for i in MatchRules.RESPAWN_TICKS - 1:
		host.fixed_step()
	victim._auto_jump_timer = 0.35
	host.fixed_step()
	expect(not victim.sim_downed and victim.sim_hp == victim.sim_max_hp and players_on_map_points(world, [2], sides[2]),
			"the victim revives at full HP on the other marked side")
	expect(victim._auto_jump_timer == 0.0, "respawn clears an automatic jump from the previous life")
	world.rules.scores[1] = 5
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()
	expect(world.rules.round_number == 2 and players_on_map_points(world, [1], sides[2])
			and players_on_map_points(world, [2], sides[1]), "duelists use the opposite map sides in round two")
	host.close()

func _team_setup() -> void:
	var disabled := WeaponRegistry.enabled_ids()
	var teams := {1: 1, 2: 1, 3: 2}
	var roles := [1, 2, 3]
	var invalid := arena(WorldSpec.TEAM, roles, teams, {"disabled_weapons": disabled}).world
	expect(not invalid.problem.is_empty() and invalid.combat == null, "disabling all weapons rejects the match")
	disabled.erase(WeaponType.PISTOL)
	var host := arena(WorldSpec.TEAM, roles, teams, {"disabled_weapons": disabled}, "res://maps/demo.cyrm")
	var world := host.world
	expect(world.problem.is_empty(), "the team match loads and validates its map")
	for p: Player in world.players.values():
		expect(p.collision_mask == CombatProfiles.Layer.TERRAIN,
				"players collide with terrain only; NPC contact is damage-only")
		expect(p.equipped != null and p.equipped.type_id == WeaponType.PISTOL,
				"each player starts equipped when only one type is enabled")
	expect(world.rules.phase == MatchRules.Phase.WAITING and is_zero_approx(world.rules.round_timer),
			"setup starts in WAITING with a zero timer")
	expect(world.players[3].sim_max_hp == 55 and world.players[1].sim_max_hp == 50,
			"team max HP follows the fixed roster")
	expect(int(world.rules.scores.get(2, 0)) == 1 and int(world.rules.scores.get(1, 0)) == 0,
			"the smaller team starts with its score bonus")
	expect(world.rules.team_counts == {1: 2, 2: 1}, "the roster counts are frozen at setup")
	var sides := SpawnPicker.respawn_cells(world.spec.map)
	expect(players_on_map_points(world, [1, 2], sides[1]) and players_on_map_points(world, [3], sides[2]),
			"each team opens on distinct points on its own side")
	var actor := world.players[1]
	var drop := _attack(0, ActorInput.BIT_DROP)
	host.fixed_step({1: drop})
	expect(actor.equipped != null, "WAITING blocks a queued drop")
	host.enqueue(MatchWorld.Command.START)
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()
	host.fixed_step({1: drop})
	expect(actor.equipped == null, "PLAYING accepts the same drop")
	_win_team_round(host)
	expect(world.rules.phase == MatchRules.Phase.WAITING and world.rules.round_number == 2
			and players_on_map_points(world, [1, 2], sides[2]) and players_on_map_points(world, [3], sides[1]),
			"the next round opens on opposite sides and waits for readiness")
	expect(int(world.rules.scores.get(2, 0)) == 1 and int(world.rules.scores.get(1, 0)) == 0,
			"the next round reapplies the initial score bonus")
	world.rules.phase = MatchRules.Phase.PLAYING
	_win_team_round(host)
	var result := arena_round(world)
	expect(result["state"] == MatchRules.Phase.MATCH_OVER and result["match_winner"] == 1,
			"the second round win seals the match result")
	var final_tick := world.tick
	host.enqueue(MatchWorld.Command.LEAVE, 3)
	host.fixed_step()
	expect(world.tick == final_tick and arena_round(world) == result, "terminal matches keep their committed result")
	var epoch := host._buffers[1].epoch
	host.accept_input(1, [[], [[1, epoch, final_tick + 1, ActorInput.BIT_DROP, 0, 0, Vector2.RIGHT]]], 0)
	expect(host._buffers[1].actions.is_empty(), "the final result stops accepting input")
	host.close()

func _win_team_round(host: MatchSession) -> void:
	var world := host.world
	for kill in TeamRules.kills_to_win(3):
		world.rules.score_down(3, 1)
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()

## 用固定随机种子验证安全点间的抽选，并检查开启碰撞时阵亡角色会让出占用的点。

func _team_respawn(tree: SceneTree) -> void:
	cleanup()
	var parent := world_from_solid(tree, 125, 75, func(sx: int, sy: int) -> bool: return sy >= 74 * 4)
	var info := CyrmMap.load_file("res://maps/demo.cyrm")
	var respawn := SpawnPicker.respawn_cells(info)
	var rules := MatchRules.new(RandomNumberGenerator.new())
	rules.setup(PvpSession.MODE_TEAM, [1, 2, 3], {1: 1, 2: 1, 3: 2}, info, {"player_collision": true})
	var ally := player(parent, 1)
	ally.team = 1
	ally.position = CyrmMap.world_position(respawn[1][0])
	var enemy := player(parent, 3)
	enemy.team = 2
	enemy.position = CyrmMap.world_position(respawn[1][1])
	var players := {1: ally, 3: enemy}
	var picked := {}
	rules._rng.seed = 1729
	for i in 16:
		picked[rules.spawn_for(players, 2)] = true
	var size: Vector2i = info.size
	expect(picked.size() > 1 and picked.keys().all(func(cell: Vector2i) -> bool:
		var distance := ToroidalGrid.toroidal_dist(cell, respawn[1][1], size.x, size.y)
		return respawn[1].has(cell) and cell != respawn[1][0] and distance >= SpawnPicker.PREFERRED_DISTANCE),
			"team respawn varies among free points at least eight cells from the enemy")
	# 让队友占用所有己方复活点，比较启用和关闭角色碰撞时的选点结果。
	for index in respawn[1].size():
		var mate := player(parent, 10 + index)
		mate.team = 1
		mate.position = CyrmMap.world_position(respawn[1][index])
		mate.sync_collision_geometry()
		players[10 + index] = mate
	expect(rules.spawn_for(players, 2) == SpawnPicker.NO_CELL,
			"a fully occupied team side reports no point instead of overlapping")
	rules.player_collision = false
	expect(respawn[1].has(rules.spawn_for(players, 2)), "without blocking, occupancy never delays a team respawn")
	rules.player_collision = true
	players[10 + respawn[1].size() - 1].force_down()
	expect(rules.spawn_for(players, 2) == respawn[1].back(), "a downed player frees the only available point")
	cleanup()

func _sparse_spawn_map(tree: SceneTree) -> void:
	var size := Vector2i(18, 4)
	var parent := world_from_solid(tree, size.x, size.y, func(_x: int, y: int) -> bool: return y >= 10)
	var info := CyrmMap.create(size * 4)
	var ground: PackedInt32Array = info.layers[CyrmMap.SCENE]
	var wall := CyrmMap.tile_value(wall_texture())
	for i in range(info.size.x * 10, ground.size()): ground[i] = wall
	info.points[0] = {"kind": "player", "cell": Vector2i(2, 6)}
	info.points[1] = {"kind": "player2", "cell": Vector2i(66, 6)}
	for x: int in [2, 10, 66]: info.points[x] = {"kind": "respawn", "side": 1, "cell": Vector2i(x, 6)}
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_PVP, [1, 2], {}, info, {}).is_empty(),
			"a duel with a missing side rejects the map even when both solo markers exist")
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_TEAM, [1, 2], {1: 1, 2: 2}, info, {}).is_empty(),
			"a team match rejects a map with an empty side")
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_ROYALE, [1, 2, 3, 4], {}, info, {}).is_empty(),
			"a Royale with too few marked points rejects the map")
	var rules := MatchRules.new(RandomNumberGenerator.new())
	expect(not rules.setup(PvpSession.MODE_ROYALE, [1], {}, info, {}).is_empty()
			and not rules.setup(PvpSession.MODE_ROYALE, [1, 2, 3], {}, info, {"max_players": 2}).is_empty(),
			"Royale admission respects both the minimum roster and the configured room cap")
	var problem := rules.setup(PvpSession.MODE_ROYALE, [1, 2], {}, info, {"player_collision": true})
	expect(problem.is_empty(), "a Royale can use points that all come from the same side")
	if problem.is_empty():
		var self_player := player(parent, 1)
		var enemy := player(parent, 2)
		self_player.position = CyrmMap.world_position(Vector2i(10, 6))
		enemy.position = CyrmMap.world_position(Vector2i(70, 6))
		expect(rules.spawn_for({1: self_player, 2: enemy}, 1) == Vector2i(10, 6),
				"with no safe point, pick the farthest across the seam and ignore the moving player's own position")
	info.points[75] = {"kind": "respawn", "side": 2, "cell": Vector2i(2, 6)}
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_PVP, [1, 2], {}, info, {}).is_empty(),
			"a point marked on both sides cannot start a duel")
	cleanup()

## 在同一个测试场景中验证摄像机的初始偏移、目标跟随、抖动和跨地图边缘的行为。
