class_name PredictionActorState
extends RefCounted

# 远端预测域：运动前缀与 ActorBody 共用槽序；后缀是下一步实际读取的控制。
const POSE := PlayerStateSchema.MOTION_SIZE
const LOCKED := 18
const DOWNED := 19
const REWIND := 20
const AXIS := 21
const HELD := 22
const MULTIPLIER := 23
const RESPAWN := 24
static var FIELDS := PlayerStateSchema.NAMES.slice(0, PlayerStateSchema.MOTION_SIZE) + [
	"state", "locked", "down", "rewind", "axis", "held", "move_mult", "respawn_tick"]

static func project(record: Array) -> Array:
	var values: Array = []
	for field in FIELDS:
		values.append(record[PlayerStateSchema.slot(field)])
	values[HELD] = int(values[HELD]) & (ActorInput.BIT_UP | ActorInput.BIT_DOWN)
	return values

static func capture(body: ActorBody, control: Array) -> Array:
	var values := body.capture_motion_state()
	values.append_array([body.state, body._controls_locked, body.sim_downed, body.rewinding])
	values.append_array(control.slice(AXIS))
	return values

static func restore(body: ActorBody, values: Array) -> void:
	body.restore_motion_state(values, values[POSE])
	body._controls_locked = values[LOCKED]
	body.rewinding = values[REWIND]
	body.sim_downed = values[DOWNED]
	body.rotation = -PI / 2.0 * body.facing_direction if body.sim_downed else 0.0
	body.sync_collision_geometry()

static func difference(saved: Array, authoritative: Array) -> String:
	for index in FIELDS.size():
		if FIELDS[index] in PlayerStateSchema.PRESENTATION:
			continue
		if saved[index] != authoritative[index]:
			return FIELDS[index]
	return ""

