class_name MatchSampler
extends RefCounted

const Actor := preload("res://core/sim/player_state_schema.gd")
const KEEP := 32
const CORRECTION_TIME := 0.05
const CFG: PlayerConfig = preload("res://core/config/player_config.tres")
static var _knock_decay := exp(-CFG.player_knock_decay_rate * ActorStep.DT)

enum Pose { POS, VEL, STATE }

var render_tick := 0.0
var _clock := SnapshotClock.new()
var _authority: Array[Dictionary] = []
var _previous: Dictionary
var _current: Dictionary
var _map_size: Vector2
var _role: int
var _last_time := -1.0
var _offset := Vector2.ZERO
var _corrected_at := 0.0
var _replacement: Array = []

func _init(size: Vector2, role: int) -> void:
	_map_size = size
	_role = role

func accept(update: Dictionary) -> void:
	_previous = update["previous"]
	_current = update["current"]
	if update.has("authority"):
		var packet: Dictionary = update["authority"]
		var cp: Dictionary = packet["checkpoint"]
		if _authority.is_empty() or cp["tick"] - _authority[-1]["tick"] > 2 * KEEP:
			_authority.clear()
			render_tick = _clock.start(cp["tick"])
		_authority.append({"tick": cp["tick"], "players": cp["players"], "pickups": cp["pickups"],
			"pickup_tick": cp["pickup_tick"], "projectiles": cp["projectiles"], "beams": cp["beams"],
			"blasts": cp["blasts"], "combat_tick": cp["combat_tick"], "rules": cp["rules"],
			"stats": cp["stats"], "grace": packet["grace"]})
		if _authority.size() > KEEP:
			_authority.pop_front()
			if render_tick < _authority[0]["tick"]:
				render_tick = _clock.start(cp["tick"])
	if update.has("replacement"):
		var changed: Array = update["replacement"]
		if _replacement.is_empty() or changed[4]:
			_replacement = changed
		elif not _replacement[4]:
			_replacement = [_replacement[0], _replacement[1], changed[2], changed[3], false]

func sample(now: float, alpha: float) -> Dictionary:
	var delta := now - _last_time if _last_time >= 0.0 else 0.0
	_last_time = now
	var old: Array = _previous["players"][_role]
	var own: Array = _current["players"][_role]
	var base: Vector2 = own[Actor.POS]
	if old[Actor.LIFE] == own[Actor.LIFE]:
		base = _between(old[Actor.POS], own[Actor.POS], alpha)
	else:
		_offset = Vector2.ZERO
	if not _replacement.is_empty():
		if _replacement[4]:
			_offset = Vector2.ZERO
		else:
			var shown := _between(_replacement[0], _replacement[1], alpha) + _residual(now)
			var corrected := _between(_replacement[2], _replacement[3], alpha)
			_offset = GridPathfinder.toroidal_delta_px(corrected, shown, _map_size)
		_corrected_at = now
		_replacement = []
	var focus := GridPathfinder.wrap_to_range(base + _residual(now), _map_size)
	var projectiles := _sample_projectiles(_current, _previous, _current, alpha, 0.0)
	var pickups: Dictionary = _current["pickups"]
	var beams: Dictionary = _current["beams"]
	var blasts: Dictionary = _current["blasts"]
	var players := {}
	var authoritative := own
	var round := {}
	var pickup_tick: int = _current["pickup_tick"]
	var light_time: float = _current["elapsed"]
	var combat_tick: int = _current["combat_tick"]
	var delayed_tick := float(combat_tick)
	if not _authority.is_empty():
		render_tick = _clock.advance(render_tick, _authority[-1]["tick"], delta)
		while _authority.size() > 2 and _authority[1]["tick"] <= render_tick:
			_authority.pop_front()
		var left := _authority[0]
		var right := _authority[mini(1, _authority.size() - 1)]
		var weight := clampf((render_tick - left["tick"]) / maxf(1.0, right["tick"] - left["tick"]), 0.0, 1.0)
		var ahead := clampf(render_tick - right["tick"], 0.0, SnapshotClock.MAX_EXTRAPOLATION)
		var source := left if weight < 1.0 else right
		players = _sample_players(source, right, weight, ahead)
		projectiles.merge(_sample_projectiles(source, left, right, weight, ahead, true))
		pickups = _sample_pickups(source, right, weight, ahead)
		pickup_tick = source["pickup_tick"]
		beams = _merge_remote(beams, source["beams"])
		blasts = _merge_remote(blasts, source["blasts"])
		authoritative = _authority[-1]["players"][_role]
		if own[Actor.LIFE] != authoritative[Actor.LIFE]:
			own = authoritative
			focus = authoritative[Actor.POS]
		light_time = render_tick * ActorStep.DT
		delayed_tick = render_tick
		round = source
	else:
		players = _sample_players(_current, _current, 0.0, 0.0)
	return {"local": own, "health": authoritative, "focus": focus, "players": players,
		"projectiles": projectiles, "beams": beams, "blasts": blasts, "pickups": pickups,
		"pickup_tick": pickup_tick, "combat_tick": combat_tick, "remote_tick": delayed_tick,
		"time_mode": _current["time_mode"], "account": _current["account"], "elapsed": light_time,
		"enemies": _current["enemies"], "kills": _current["kills"], "round": round}

func _sample_players(source: Dictionary, right: Dictionary, weight: float, ahead: float) -> Dictionary:
	var poses := {}
	for id: int in source["players"]:
		if id == _role:
			continue
		var row: Array = source["players"][id]
		var pos: Vector2 = row[Actor.POS]
		var velocity: Vector2 = row[Actor.VEL]
		var next: Array = right["players"].get(id, [])
		if weight > 0.0 and weight < 1.0 and not next.is_empty() and next[Actor.LIFE] == row[Actor.LIFE]:
			pos = _between(pos, next[Actor.POS], weight)
			velocity = velocity.lerp(next[Actor.VEL], weight)
		elif ahead > 0.0 and not row[Actor.REWIND]:
			var whole := floorf(ahead)
			var decay := pow(_knock_decay, whole)
			var knock_ticks := (1.0 - decay) / (1.0 - _knock_decay) + (ahead - whole) * decay
			pos = GridPathfinder.wrap_to_range(pos + (velocity * ahead + row[Actor.KNOCK_VEL] * knock_ticks) * ActorStep.DT, _map_size)
		poses[id] = [pos, velocity, row]
	return poses

func _sample_projectiles(source: Dictionary, left: Dictionary, right: Dictionary,
		weight: float, ahead: float, remotes_only := false) -> Dictionary:
	var result := {}
	for id: int in source["projectiles"]:
		var role := ShotRules.shooter_role(id)
		if remotes_only and role == _role:
			continue
		var row: Array = source["projectiles"][id]
		var first: Array = left["projectiles"].get(id, [])
		var last: Array = right["projectiles"].get(id, [])
		var pos: Vector2 = row[BulletBody.MOTION_POS]
		var rotation: float = row[BulletBody.ROTATION]
		if not first.is_empty() and not last.is_empty() and first[BulletBody.SNAP_TYPE] == last[BulletBody.SNAP_TYPE]:
			pos = _between(first[BulletBody.MOTION_POS], last[BulletBody.MOTION_POS], weight)
			rotation = lerp_angle(first[BulletBody.ROTATION], last[BulletBody.ROTATION], weight)
		if ahead > 0.0 and not (source["players"].has(role) and source["players"][role][Actor.REWIND]):
			pos = GridPathfinder.wrap_to_range(pos + row[BulletBody.MOTION_VEL] * ahead * ActorStep.DT, _map_size)
		result[id] = [row[BulletBody.SNAP_TYPE], pos, rotation]
	return result

func _sample_pickups(source: Dictionary, right: Dictionary, weight: float, ahead: float) -> Dictionary:
	var result := {}
	for id: int in source["pickups"]:
		var row: Array = source["pickups"][id].duplicate()
		var next: Array = right["pickups"].get(id, [])
		if not next.is_empty() and weight > 0.0 and weight < 1.0:
			row[WeaponPickup.POS] = _between(row[WeaponPickup.POS], next[WeaponPickup.POS], weight)
		elif ahead > 0.0:
			row[WeaponPickup.POS] = GridPathfinder.wrap_to_range(row[WeaponPickup.POS] + row[WeaponPickup.VEL] * ahead * ActorStep.DT, _map_size)
		result[id] = row
	return result

func _merge_remote(owned: Dictionary, others: Dictionary) -> Dictionary:
	var result := owned.duplicate()
	for id: int in others:
		if ShotRules.shooter_role(id) != _role:
			result[id] = others[id]
	return result

func _between(a: Vector2, b: Vector2, weight: float) -> Vector2:
	return GridPathfinder.wrap_to_range(a + GridPathfinder.toroidal_delta_px(a, b, _map_size) * weight, _map_size)

func _residual(now: float) -> Vector2:
	return _offset * clampf(1.0 - (now - _corrected_at) / CORRECTION_TIME, 0.0, 1.0)
