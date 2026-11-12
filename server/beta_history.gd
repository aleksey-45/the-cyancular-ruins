class_name BetaHistory
extends RefCounted

var frames: Dictionary = {}
var cursors: Dictionary = {}
var world: Node

func _init(owner_world: Node) -> void:
	world = owner_world

func tick(delta: float) -> void:
	var by_owner := {}
	for bullet: BulletBody in world.combat_rules.projectiles.values():
		by_owner.get_or_add(bullet.shooter, []).append(bullet)
	for role in world.players:
		var player: Player = world.players[role]
		var bullets: Array = by_owner.get(player, [])
		var account: GrainAccount = world.time_economy.accounts[role]
		var want := (player.step_input.held & ActorInput.BIT_REWIND) != 0 \
				and account.can_spend() and not player.sim_downed
		if want and not cursors.has(role) and frames.has(role):
			cursors[role] = 0.0
			player.rewinding = true
		elif not want and cursors.has(role):
			finish(role)
		if cursors.has(role):
			account.spend(delta, world.time_economy.rules["rewind_burn"])
			cursors[role] = TimeParams.advance_rewind(cursors[role], delta)
			var history: Array = frames[role]
			var target: float = history[-1]["tick"] - cursors[role] * 60.0
			var low := 0
			var high := history.size()
			while low < high:
				var middle := (low + high) / 2
				if history[middle]["tick"] <= target: low = middle + 1
				else: high = middle
			var frame: Dictionary = history[maxi(0, low - 1)]
			var shot_serial: int = player.shot_serial
			player.restore_state(frame["player"], true)
			player.shot_serial = shot_serial
			for bullet: BulletBody in bullets:
				if frame["bullets"].has(bullet.entity_id):
					bullet.restore_motion(frame["bullets"][bullet.entity_id])
			continue
		if world._snap_tick % 3 == 0:
			var states := {}
			for bullet: BulletBody in bullets:
				states[bullet.entity_id] = bullet.motion_state()
			if not frames.has(role):
				frames[role] = []
			var history: Array = frames[role]
			history.append({"tick": world._snap_tick, "player": player.capture_state(), "bullets": states})
			while history.size() > world.time_economy.rewind_frame_limit:
				history.pop_front()

func finish(role: int) -> void:
	var history: Array = frames[role]
	var target: float = history[-1]["tick"] - cursors[role] * 60.0
	while history.size() > 1 and history[-1]["tick"] > target:
		history.pop_back()
	cursors.erase(role)
	world.players[role].rewinding = false
	world.new_epoch(role)

func reset() -> void:
	for role in cursors.keys():
		finish(role)
	frames.clear()
