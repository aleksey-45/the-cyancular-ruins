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
			GameLog.record("beta_rewind_begin", {"tick": world._snap_tick, "role": role, "history": frames[role].size()})
			_sync_bullets(role, true)
		elif not want and cursors.has(role):
			finish(role)
		if cursors.has(role):
			account.spend(delta, world.time_economy.rules.rewind_burn)
			cursors[role] = advance_cursor(cursors[role], delta)
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
				if bullet.shooter == player and not bullet.finished:
					if frame["bullets"].has(bullet.entity_id):
						bullet.apply_rewind_state(frame["bullets"][bullet.entity_id])
			if world._snap_tick % 3 == 0 and world.live_bullets().any(func(bullet: BulletBase) -> bool: return bullet.shooter == player):
				_sync_bullets(role, true)
			continue
		if world._snap_tick % 3 == 0:
			var bullets := {}
			for bullet: BulletBase in world.live_bullets():
				if bullet.shooter == player and not bullet.finished:
					bullets[bullet.entity_id] = bullet.rewind_state()
			if not frames.has(role):
				frames[role] = []
			var history: Array = frames[role]
			history.append({"tick": world._snap_tick, "player": player.capture_state(), "bullets": bullets})
			while history.size() > 20 * world.time_economy.rules.rewind_buffer_seconds():
				history.pop_front()

func finish(role: int) -> void:
	GameLog.record("beta_rewind_end", {"tick": world._snap_tick, "role": role, "seconds": cursors[role]})
	var history: Array = frames[role]
	var target: float = history[-1]["tick"] - cursors[role] * 60.0
	while history.size() > 1 and history[-1]["tick"] > target:
		history.pop_back()
	cursors.erase(role)
	world.players[role].rewinding = false
	world.new_epoch(role)
	_sync_bullets(role, false)
	for bullet: BulletBase in world.live_bullets():
		if bullet.shooter == world.players[role] and bullet._fuse_active:
			bullet.fuse_started = true

# 已开始的回溯在历史上移动；给预测窗口提供阻挡轨迹，不能把回溯者冻结在 STATE 位置。
# 只发送位置/姿态发生变化的结点，历史记录仍只保留在服务端。
func collision_path(role: int) -> Array:
	if not cursors.has(role): return []
	var history: Array = frames[role]
	var cursor: float = cursors[role]
	var index := history.size() - 1
	var result: Array = []
	for offset in range(1, PredictionRollback.MAX_REPLAY + 1):
		cursor = advance_cursor(cursor, ActorStep.DT)
		var target: float = history[-1]["tick"] - cursor * 60.0
		while index > 0 and history[index]["tick"] > target: index -= 1
		var state: Dictionary = history[index]["player"]
		var knot := {"pos": state["pos"], "squat": state["squat"], "down": state["down"], "facing": state["facing"]}
		if result.is_empty() or knot != result[-1]["body"]:
			result.append({"tick": world._snap_tick + offset, "body": knot})
	return result

static func advance_cursor(cursor: float, delta: float) -> float:
	return cursor + delta * lerpf(TimeParams.REWIND_START_MULT, 1.0, clampf(cursor / TimeParams.REWIND_RAMP_TIME, 0.0, 1.0))

func _sync_bullets(role: int, rewind: bool) -> void:
	var bullets := {}
	for bullet: BulletBase in world.live_bullets():
		if bullet.shooter == world.players[role] and not bullet.finished:
			bullets[bullet.entity_id] = world.projectile_state(bullet)
	world.broadcast(NetEvent.Kind.BULLET_REWIND, {"role": role, "tick": world._snap_tick - 1,
			"rewind": rewind, "projectiles": bullets})

func reset() -> void:
	for role in cursors.keys():
		finish(role)
	frames.clear()
