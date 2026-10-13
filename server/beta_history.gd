class_name BetaHistory
extends RefCounted

var frames: Dictionary = {}
var cursors: Dictionary = {}
var world: Node

func _init(owner_world: Node) -> void:
	world = owner_world

func tick(delta: float) -> void:
	for role in world.players:
		var player: Node2D = world.players[role]
		var src: PlayerInput = player.input_source
		var account: GrainAccount = world.time_economy.accounts[role]
		var want: bool = src.rewind_held() and account.can_spend() and not player.is_downed() and world._round_state == NetEvent.RoundState.PLAYING
		if want and not cursors.has(role) and frames.has(role):
			cursors[role] = 0.0
			player.rewinding = true
		elif not want and cursors.has(role):
			finish(role)
		if cursors.has(role):
			account.spend(delta, world.time_economy.rules.rewind_burn)
			cursors[role] += delta * lerpf(TimeParams.REWIND_START_MULT, 1.0, clampf(cursors[role] / TimeParams.REWIND_RAMP_TIME, 0.0, 1.0))
			var history: Array = frames[role]
			var target: float = history[-1]["tick"] - cursors[role] * 60.0
			var frame: Dictionary = history[0]
			for candidate: Dictionary in history:
				if candidate["tick"] > target:
					break
				frame = candidate
			var shot_serial: int = player.shot_serial
			player.restore_state(frame["player"])
			player.shot_serial = shot_serial
			for bullet: BulletBase in world.live_bullets():
				if bullet.shooter == player:
					if frame["bullets"].has(bullet.entity_id):
						var state: Dictionary = frame["bullets"][bullet.entity_id]
						bullet.position = state["pos"]
						bullet.velocity_vec = state["vel"]
						bullet.apply_rewind_state(state["fuse"])
						bullet.adjudicated_pos = bullet.position
			continue
		if world._snap_tick % 3 == 0:
			var bullets := {}
			for bullet: BulletBase in world.live_bullets():
				if bullet.shooter == player:
					bullets[bullet.entity_id] = {"pos": bullet.position, "vel": bullet.velocity_vec, "fuse": bullet.rewind_state()}
			if not frames.has(role):
				frames[role] = []
			var history: Array = frames[role]
			history.append({"tick": world._snap_tick, "player": player.capture_state(), "bullets": bullets})
			while history.size() > 20 * world.time_economy.rules.rewind_buffer_seconds():
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
