class_name BetaHistory
extends RefCounted

const PLAYER := 1
const PROJECTILES := 2
var frames: Dictionary[int, RewindHistory] = {}
var world: Node

func _init(owner_world: Node) -> void:
	world = owner_world

func tick(delta: float) -> void:
	var by_owner := {}
	for bullet: BulletBody in world.combat_rules.projectiles.values():
		by_owner.get_or_add(bullet.shooter, []).append(bullet)
	for role: int in world.players:
		var player: Player = world.players[role]
		var history: RewindHistory = frames.get(role)
		var account: GrainAccount = world.time_economy.accounts[role]
		var want := (player.step_input.held & ActorInput.BIT_REWIND) != 0 \
				and account.can_spend() and not player.sim_downed
		if want and history != null:
			player.rewinding = true
			account.spend(delta, world.time_economy.rules["rewind_burn"])
			history.rewound = TimeParams.advance_rewind(history.rewound, delta)
			var frame := history.sample(_target(history))
			player.restore_state(frame[PLAYER], true)
			for bullet: BulletBody in by_owner.get(player, []):
				if frame[PROJECTILES].has(bullet.entity_id):
					bullet.restore_motion(frame[PROJECTILES][bullet.entity_id])
			continue
		finish(role)
		if world._snap_tick % 3 == 0:
			var states := {}
			for bullet: BulletBody in by_owner.get(player, []):
				states[bullet.entity_id] = bullet.motion_state()
			if history == null:
				history = RewindHistory.new()
				frames[role] = history
			history.push([world._snap_tick, player.capture_state(), states])
			history.keep_last(world.time_economy.rewind_frame_limit)

func _target(history: RewindHistory) -> float:
	var latest: float = history.frame(history.size() - 1)[RewindHistory.TIME]
	return maxf(history.frame(0)[RewindHistory.TIME], latest - history.rewound * 60.0)

func finish(role: int) -> void:
	var player: Player = world.players[role]
	if not player.rewinding:
		return
	var history := frames[role]
	history.truncate(_target(history))
	history.rewound = 0.0
	player.rewinding = false
	world.new_epoch(role)

func discard(role: int) -> void:
	finish(role)
	frames.erase(role)

func reset() -> void:
	for role: int in frames:
		finish(role)
	frames.clear()
