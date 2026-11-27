extends "res://tests/case.gd"

const Actor := preload("res://core/sim/player_state_schema.gd")
const Mode := WorldSpec.ROYALE
const Neutral := [0.0, 0, 0, 0, 0, Vector2.RIGHT]

func run(tree: SceneTree) -> void:
	_checkpoint_continuation()
	_wait_for_terrain(false)
	_wait_for_terrain(true)
	_position_tolerance()
	_buffered_input()
	_sample_bow_and_death()
	_position_residual()
	await _load_match(tree)

func _beta() -> MatchHost:
	var host := arena(Mode, [1, 2], {}, RoomOptions.normalized(Mode, {"beta": true}))
	host.world.rules.phase = MatchRules.Phase.PLAYING
	return host

func _baseline(host: MatchHost, frame: Dictionary = {}) -> Dictionary:
	var world := host.world
	return {"code": "12345678", "role": 1, "mode": world.spec.mode, "roles": world.spec.roles,
		"teams": world.spec.teams, "options": world.spec.options, "seed": world.spec.seed,
		"names": {1: "A", 2: "B"}, "hues": {1: 0.0, 2: 45.0}, "map": world.spec.map,
		"sub_hp": world.terrain.get_modified(), "frame": host.packet({}) if frame.is_empty() else frame}

func _predict_step(client: PredictedMatch, record: Array = Neutral, ping_ms := 0) -> Dictionary:
	var update := client.reconcile(ping_ms)
	update.merge(client.predict(record))
	return update

func _wall(map: Dictionary) -> Vector2i:
	var tiles: PackedInt32Array = map.layers[CyrmMap.SCENE]
	for index in tiles.size():
		if TileDefs.explosion_destroyable(CyrmMap.tile_material(tiles[index])):
			return Vector2i(index % map.size.x, index / map.size.x)
	return Vector2i.ZERO

func _checkpoint_continuation() -> void:
	var host := _beta()
	var world := host.world
	var one := world.players[1]
	var two := world.players[2]
	one.weapons.set_initial_inventory([WeaponType.GRENADE, WeaponType.PISTOL])
	for at in 12:
		host.fixed_step({1: [1.0, 0, 0, 0, 0, Vector2.RIGHT]})
	var id := ShotRules.shot_id(1, 11)
	var bullet := world.combat.spawn_projectile(id, WeaponType.GRENADE, one,
			one.position + Vector2(72, -48), Vector2(130, -27), 13)
	bullet.traveled = 152.75
	bullet.start_fuse(0.25)
	bullet.fuse_elapsed = 0.1
	bullet.direct_hit = true
	var task := ShotRules.shot_id(2, 1)
	world.combat.submit_blast(task, two.position + Vector2(20, 0), WeaponType.GRENADE)
	var drop := world.combat.ground.spawn(WeaponType.PISTOL, 4, one.position, Vector2(0, -80), 2)
	two.sim_hp = 1
	two.sim_iframes = 0.0
	var cell := _wall(world.spec.map)
	var hp := world.terrain.get_hp(cell)
	world.terrain.apply_at(world.terrain.version, {cell: hp - 1})
	world.terrain.apply_at(world.terrain.version, {cell: hp - 2})
	var raw := host.packet({})
	var encoder := NetCodec.new()
	var wire := encoder.encode_state(PackedByteArray(), NetCodec.StateBatch.new(raw))
	var frame := NetCodec.new().decode_state(NetCodec.Reader.new(wire, 1))
	expect(frame == raw, "a logical STATE alone describes every live and scheduled combat entity")
	var client := PredictedMatch.new(_baseline(host, frame), 0)
	var replica := client.world
	var local_checkpoint: Dictionary = frame["checkpoint"].merged({"terrain": replica.terrain.version}, true)
	expect(replica.capture() == local_checkpoint and replica.terrain.version != frame["checkpoint"]["terrain"]
			and client.latest_authority == frame, "baseline restores the full checkpoint using a local terrain version")
	expect(replica.combat.projectiles[id].direct_hit and replica.combat.projectiles[id].fuse_elapsed == 0.1
			and replica.combat.ground.items[drop.inst].carried == 4, "restore keeps the grenade and dropped ammo")
	var original_position := one.position
	var down_observed := false
	for i in 130:
		var skill := ActorInput.BIT_REWIND if i < 3 else 0
		var inputs := {1: [0.0, skill, 0, 0, 0, Vector2.RIGHT], 2: Neutral}
		host.fixed_step(inputs)
		replica.advance(inputs)
		var authority := world.capture()
		var restored := replica.capture()
		authority.erase("terrain")
		restored.erase("terrain")
		expect(authority == restored and world.terrain.get_modified() == replica.terrain.get_modified(),
				"identical inputs continue the same checkpoint at step %d" % i)
		if i == 0:
			expect(one.rewinding and one.position != original_position, "the incoming Beta history is usable on the first step")
		down_observed = down_observed or two.sim_downed
	expect(down_observed and two.life == 2 and not two.sim_downed, "both worlds resolve the scheduled death and respawn")
	expect(raw["checkpoint"]["projectiles"][id][BulletBody.MOTION_TRAVELED] == 152.75
			and raw["checkpoint"]["players"][2][Actor.HP] == 1, "advancing leaves retained checkpoint values intact")
	client.world.close()
	host.world.close()

func _wait_for_terrain(patch_first: bool) -> void:
	var host := _beta()
	var world := host.world
	var client := PredictedMatch.new(_baseline(host), 0)
	var terrain := client.world.terrain
	var cell := _wall(world.spec.map)
	var hp := world.terrain.get_hp(cell)
	terrain.apply_at(terrain.version, {cell: 0})
	host.fixed_step()
	var root := world.terrain.version
	var damaged := world.terrain.apply_at(root, {cell: hp - 1})
	var patch := {"version": damaged, "cells": world.terrain.changes_since(root)}
	expect(patch["version"] == terrain.version and patch["cells"] == {cell: hp - 1},
			"the authority and local journal positions may have the same number")
	var latest := host.packet({})
	host.fixed_step()
	var same_terrain := host.packet({})
	host.fixed_step()
	world.terrain.reset()
	var next_patch := {"version": world.terrain.version, "cells": world.terrain.changes_since(damaged)}
	var next_state := host.packet({})
	var old := client.latest_authority
	if patch_first:
		client.receive_terrain(patch)
		client.receive_terrain(next_patch)
		_predict_step(client)
		expect(client.latest_authority == old and terrain.get_hp(cell) == 0,
				"queued authority patches leave the predicted terrain in place")
	client.receive_state(latest)
	if not patch_first:
		_predict_step(client)
		expect(client.latest_authority == old and terrain.get_hp(cell) == 0,
				"a matching prediction version does not satisfy the authority terrain dependency")
		client.receive_terrain(patch)
		client.receive_terrain(next_patch)
	_predict_step(client)
	expect(client.latest_authority == latest and terrain.get_hp(cell) == hp - 1,
			"adopting the anchor undoes prediction and applies only patches through its version")
	terrain.apply_at(terrain.version, {cell: 0})
	client.receive_state(same_terrain)
	_predict_step(client)
	expect(client.latest_authority == same_terrain and terrain.get_hp(cell) == hp - 1,
			"a new anchor on the same terrain version still undoes the predicted tail")
	client.receive_state(next_state)
	client.receive_state(latest)
	_predict_step(client)
	expect(client.latest_authority == next_state and terrain.get_hp(cell) == hp,
			"the next anchor consumes the later patch that was left queued")
	client.world.close()
	host.world.close()

func _position_tolerance() -> void:
	for change in ["subpixel", "position", "health", "local_input", "remote_input", "remote_health", "phase"]:
		var host := _beta()
		var client := PredictedMatch.new(_baseline(host), 0)
		_predict_step(client)
		host.fixed_step()
		var packet := host.packet({})
		var actor: Array = packet["checkpoint"]["players"][1]
		actor[Actor.POS] += Vector2(0.2 if change == "position" else 0.05, 0.0)
		if change == "health":
			actor[Actor.HP] -= 1
		if change == "remote_health":
			packet["checkpoint"]["players"][2][Actor.HP] -= 1
		if change == "phase":
			packet["checkpoint"]["rules"][MatchRules.State.PHASE] = MatchRules.Phase.COUNTDOWN
			packet["checkpoint"]["rules"][MatchRules.State.TIMER] = 3.0
		if change == "local_input" or change == "remote_input":
			var meta: Array = packet["inputs"][1 if change == "local_input" else 2]
			meta[2 + InputBuffer.SEQ] = 1
			meta[2 + InputBuffer.TARGET_TICK] = host.world.tick
			meta[2 + InputBuffer.FRAME_AX] = 1.0
		expect(client.world.tick > host.world.tick, "position tolerance is tested with an already predicted suffix")
		client.receive_state(packet)
		var update := _predict_step(client)
		expect(client.latest_authority == packet, "the authority frame is published in every reconciliation case")
		if change in ["position", "health", "phase"]:
			expect(client.replay_ticks > 0, "%s divergence triggers rollback" % change)
		else:
			expect(client.replay_ticks == 0 and not update.has("replacement"),
					"a same-tick local match inside 0.1 px skips rollback with %s" % change)
		if change == "health":
			expect(client.world.players[1].sim_hp == actor[Actor.HP] and update.has("replacement"),
					"health correction applies and any resulting position change can be smoothed")
		client.world.close()
		host.world.close()

func _buffered_input() -> void:
	var host := _beta()
	var world := host.world
	world.players[2].weapons.set_initial_inventory([WeaponType.RIFLE])
	var client := PredictedMatch.new(_baseline(host), 100)
	var max_replay := 0
	var attack := ActorInput.BIT_ATTACK
	for step in range(1, 22):
		var pressed := attack if step == 12 else 0
		var record := [1.0, attack if pressed else 0, pressed, 0, 0, Vector2.RIGHT]
		var update := _predict_step(client, record, 100)
		host.accept_input(1, update["input"], -1)
		var trigger := [0.0, 0, 0, 0, 0, Vector2.RIGHT]
		host.accept_input(2, [[[step, 1, step, 1.0, attack, Vector2.RIGHT]], []], -1)
		host.fixed_step({2: trigger} if step < 4 else {})
		if step == 20:
			world.players[1].sim_hp -= 1
		if step % 4 == 0:
			var anchor := host.packet({})
			anchor["input_feedback"] = host.remote[1].feedback
			client.receive_state(anchor)
		max_replay = maxi(max_replay, client.replay_ticks)
	var confirmed: Array = client.latest_authority["checkpoint"]["players"][2]
	expect(max_replay > 0 and max_replay <= PredictedMatch.MAX_REPLAY, "late confirmed state replays the retained local inputs")
	expect(client.world.players[2].shot_serial == confirmed[Actor.SHOT_SERIAL],
			"remote movement extrapolation does not extrapolate attack")
	var edge_target := client.last_input_target
	for i in 80:
		_predict_step(client, Neutral, 100)
	var at: int = client.latest_authority["checkpoint"]["tick"]
	expect(client.world.tick == at + PredictedMatch.MAX_REPLAY and client.last_input_target > edge_target,
			"without authority, prediction stays bounded while input keeps its own clock")
	expect(client._history.size() == PredictedMatch.KEEP, "the session retains bounded input records")
	client.world.close()
	host.world.close()

func _sample_bow_and_death() -> void:
	var host := _beta()
	var world := host.world
	var bow := world.players[2]
	bow.weapons.set_initial_inventory([WeaponType.COMPOUND_BOW])
	for i in 24:
		host.fixed_step({2: [0.0, ActorInput.BIT_ATTACK, 0, 0, 0, Vector2.RIGHT]})
	var left := host.packet({})
	var view := world.sample(1)
	var sampler := MatchSampler.new(world.terrain.map_size, 1)
	sampler.accept({"authority": left, "previous": view, "current": view})
	host.fixed_step({2: [0.0, 0, 0, ActorInput.BIT_ATTACK, 0, Vector2.RIGHT]})
	var right := host.packet({})
	var own := world.sample(1)
	var local: Array = own["players"][1]
	local[Actor.DOWNED] = true
	local[Actor.HP] = 0
	sampler.accept({"authority": right, "previous": view, "current": own})
	sampler.render_tick = float(world.tick) - 0.5
	var presenter := MatchPresenter.new(world.spec, world.terrain, 1, world.personal_time.accounts[1])
	var details := {"aim": Vector2.RIGHT, "walls": {}, "guide": PackedVector2Array(),
		"drop": 0.0, "bounds": world.players[1].collision_rect()}
	var shown := presenter.compose(sampler.sample(0.0, 1.0), 0.0, details["drop"], details["walls"])
	expect(not shown.downed and not shown.actors[0].downed and shown.health == world.players[1].sim_hp,
			"speculative death does not change the local observed health or down pose")
	expect(shown.actors[1].bow_draw >= 0.0 and shown.projectiles.is_empty(),
			"before the remote release tick the arrow is still on the bow")
	sampler.render_tick = float(world.tick)
	shown = presenter.compose(sampler.sample(0.0, 1.0), 0.01, details["drop"], details["walls"])
	expect(shown.actors[1].bow_draw < 0.0 and shown.projectiles.size() == 1,
			"the arrow flies and the bow clears on the same remote sample")
	world.players[1].apply_hit_health(0)
	host.fixed_step()
	var confirmed := host.packet({})
	var death := world.sample(1)
	sampler.accept({"authority": confirmed, "previous": own, "current": death})
	shown = presenter.compose(sampler.sample(0.0, 1.0), 0.02, details["drop"], details["walls"])
	expect(shown.downed and shown.actors[0].downed and shown.hit_ratio > 0.0, "confirmation starts the down pose and reaction")
	shown = presenter.compose(sampler.sample(0.0, 1.0), 0.03, details["drop"], details["walls"])
	expect(shown.downed and shown.hit_ratio == 0.0, "the same authority state does not repeat a hit reaction")
	var early_respawn := death.duplicate(true)
	early_respawn["players"][1][Actor.LIFE] += 1
	early_respawn["players"][1][Actor.POS] += Vector2(300, 0)
	sampler.accept({"previous": death, "current": early_respawn})
	shown = presenter.compose(sampler.sample(0.0, 1.0), 0.04, details["drop"], details["walls"])
	expect(shown.downed and shown.focus == death["players"][1][Actor.POS],
			"the previous life stays on screen until authority confirms the respawn")
	host.world.close()

func _position_residual() -> void:
	var host := _beta()
	var world := host.world
	var size := world.terrain.map_size
	var view := world.sample(1)
	var old := Vector2(size.x - 4.0, 20)
	var start := Vector2(4, 20)
	view["players"][1][Actor.POS] = old
	var revised := view.duplicate(true)
	revised["players"][1][Actor.POS] = start
	var sampler := MatchSampler.new(size, 1)
	sampler.accept({"previous": view, "current": view})
	expect(sampler.sample(0.0, 1.0)["focus"] == old, "the last display position is the start of a correction")
	sampler.accept({"previous": revised, "current": revised, "replacement": [old, old, start, start, false]})
	expect(sampler.sample(0.0, 1.0)["focus"] == old, "the correction joins continuously across the seam")
	var moving := revised.duplicate(true)
	var next := Vector2(12, 20)
	moving["players"][1][Actor.POS] = next
	sampler.accept({"previous": revised, "current": moving})
	var half: Vector2 = sampler.sample(0.025, 1.0)["focus"]
	expect(half.is_equal_approx(Vector2(8, 20)), "new movement continues while the display residual decays")
	expect(sampler.sample(0.05, 1.0)["focus"] == next, "the residual disappears in elapsed render time")
	host.world.close()

func _load_match(tree: SceneTree) -> void:
	var host := _beta()
	var actor := host.world.players[1]
	host.world.rules.phase = MatchRules.Phase.WAITING
	actor.weapons.set_initial_inventory([WeaponType.PISTOL, WeaponType.RIFLE])
	var payload := _baseline(host)
	PvpSession.begin_match(payload, payload["map"])
	var terrain := host.world.terrain
	var cell := _wall(host.world.spec.map)
	var lamp: Dictionary = payload.map.points.values().filter(func(point: Dictionary) -> bool:
		return point.kind == "lamp" and TileDefs.explosion_destroyable(terrain.sub_texture(point.cell + Vector2i.DOWN))).front()
	var support: Vector2i = lamp.cell + Vector2i.DOWN
	var before := terrain.version
	terrain.apply_at(before, {cell: terrain.get_hp(cell) - 1})
	terrain.damage_beam(support, terrain.get_hp(support))
	terrain.commit()
	var cells := terrain.changes_since(before)
	NetSession._on_event(1, NetEvent.Kind.TERRAIN, {"version": terrain.version, "cells": cells})
	payload = _baseline(host)
	NetSession._on_event(1, NetEvent.Kind.BASELINE, payload)
	PvpSession.begin_match(payload, payload["map"])
	expect(NetSession.match_inbox.is_empty(), "a new loading baseline supersedes earlier terrain patches")
	host.world.rules.phase = MatchRules.Phase.PLAYING
	for i in PredictedMatch.MAX_REPLAY:
		host.fixed_step()
	actor.position += Vector2(96.0, -128.0)
	actor.weapons.set_initial_inventory([WeaponType.PISTOL, WeaponType.GRENADE])
	var newest := host.packet({})
	NetSession._on_state(newest)
	var client: PvpMatchClient = preload("res://scenes/pvp_game.tscn").instantiate()
	tree.root.add_child(client)
	expect(NetSession.match_inbox.size() == 1 and client.phase == PvpMatchClient.Phase.ONLINE,
			"the loading inbox survives until the first network tick")
	var shown: Vector2 = client._sampler.sample(0.0, 0.0)["focus"]
	var weapon := actor.weapons.cycle_instance(1)
	var old_aim := client._aim_direction()
	var window := client.get_window()
	var mouse := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	var aim := LocalInputSource.aim_direction(actor.position, actor.facing_direction, client.terrain.map_size,
			client._camera.base_position, MatchController.CFG.cam_zoom, mouse)
	expect(client.controls.frozen and weapon != client.player.weapons.cycle_instance(1)
			and not aim.is_equal_approx(old_aim), "the incoming snapshot changes the input lock, equipment and aim origin")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	var wheel_switch := Settings.wheel_switch
	Settings.wheel_switch = true
	client._unhandled_input(wheel)
	Settings.wheel_switch = wheel_switch
	var sent: Array = []
	client.input_sampled.connect(func(packet: Array) -> void: sent.append(packet), CONNECT_ONE_SHOT)
	client._physics_process(ActorStep.DT)
	var input: Array = sent[0]
	var actions: Array = input[InputBuffer.PACKET_ACTIONS]
	expect(not client.controls.frozen and actions.size() == 1 and actions[0][InputBuffer.ACTION_WINST] == weapon,
			"the same fixed step unlocks input and binds the queued wheel to the restored inventory")
	expect(input[InputBuffer.PACKET_FRAMES].back()[InputBuffer.FRAME_AIM].is_equal_approx(aim),
			"the outgoing aim uses the corrected player position")
	expect(client._sampler.sample(0.0, 0.0)["focus"].is_equal_approx(shown),
			"an authority ahead of prediction blends from the position already shown")
	await tree.physics_frame
	await tree.process_frame
	# process_frame 在 _process() 前发出，再等一次信号让画面更新完成。
	await tree.process_frame
	expect(client.session.latest_authority == newest and client._presenter.frame.actors.size() == 2,
			"the inbox is consumed by the fixed-step driver and both actors reach the view")
	var stand: Node2D = client._view._canvas.lamps._supports[terrain.sub_index(support)]
	expect(not stand.visible, "a client joining on a fresh baseline sees the broken lamp support")
	var world := client.session.world
	host.world.rules.round_number += 1
	host.world.rules.phase = MatchRules.Phase.WAITING
	terrain.reset()
	var next_round := _baseline(host)
	NetSession._on_event(1, NetEvent.Kind.ROUND, {"sub_hp": next_round["sub_hp"], "frame": next_round["frame"]})
	client._physics_process(ActorStep.DT)
	expect(client.session.world == world and client.session.latest_authority == next_round["frame"]
			and client.terrain.get_modified().is_empty() and client.controls.frozen,
			"the round baseline resets terrain and input on the mounted match")
	client._process(ActorStep.DT)
	expect(stand.visible, "the next round restores the street lamp with its support")
	client.free()
	NetSession.close()
	host.world.close()
