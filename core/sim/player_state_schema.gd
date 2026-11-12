class_name PlayerStateSchema
extends RefCounted

const Field := NetEvent.Field

# 槽号与排列顺序属于协议 19。空诊断名表示该槽不触发预测校正。
enum {
	POS, GROUNDED, HASTE_MULT, VEL, FACING, STATE_LOCK_TIMER, COYOTE_TIMER,
	JUMP_BUFFER_TIMER, JUMP_CUT_APPLIED, SQUAT, CHARGE, CHARGE_TIMER, LAST_MOVE_DIR,
	LAST_MOVE_TIMER, CLIMB_LATCHED, IN_WATER, KNOCK_VEL, SHOT_SERIAL, WATERPROOF_TIMER,
	WAS_SUBMERGED, DROWN_TIMER, IFRAMES, CONTROLS_LOCKED, WEAPON_INST, INVENTORY, STATE,
	WATERPROOF, HP, DOWNED, SIZE,
}
const ACTOR_FIELDS := {
	POS: [Field.VEC, "pos"],
	GROUNDED: [Field.BOOL, "floor"],
	HASTE_MULT: [Field.F64, "haste_mult"],
	VEL: [Field.VEC, "vel"],
	FACING: [Field.I8, "facing"],
	STATE_LOCK_TIMER: [Field.F64, ""],
	COYOTE_TIMER: [Field.F64, "coyote"],
	JUMP_BUFFER_TIMER: [Field.F64, "jbuf"],
	JUMP_CUT_APPLIED: [Field.BOOL, "jcut"],
	SQUAT: [Field.BOOL, "squat"],
	CHARGE: [Field.BOOL, "charge"],
	CHARGE_TIMER: [Field.F64, "ct"],
	LAST_MOVE_DIR: [Field.I8, "lmv_d"],
	LAST_MOVE_TIMER: [Field.F64, "lmv_t"],
	CLIMB_LATCHED: [Field.BOOL, "clatch"],
	IN_WATER: [Field.BOOL, "swim"],
	KNOCK_VEL: [Field.VEC, "knock"],
	SHOT_SERIAL: [Field.U32, "shot_serial"],
	WATERPROOF_TIMER: [Field.F64, "wp_t"],
	WAS_SUBMERGED: [Field.BOOL, "wp_s"],
	DROWN_TIMER: [Field.F64, "wp_d"],
	IFRAMES: [Field.F64, "ifr"],
	CONTROLS_LOCKED: [Field.BOOL, "locked"],
	WEAPON_INST: [Field.U32, "winst"],
	INVENTORY: [Field.INVENTORY, "inv"],
	STATE: [Field.U8, ""],
	WATERPROOF: [Field.I32, "wp"],
	HP: [Field.I32, "hp"],
	DOWNED: [Field.BOOL, "down"],
}
static var ACTOR_TYPES := _actor_types()

enum {
	REMOTE_POS, REMOTE_VEL, REMOTE_FACING, REMOTE_SQUAT, REMOTE_STATE, REMOTE_HP,
	REMOTE_DOWNED, REMOTE_AIM, REMOTE_WEAPON_TYPE, REMOTE_EPOCH, REMOTE_HASTE, REMOTE_REWIND, REMOTE_SIZE,
}
const REMOTE_TYPES := [
	Field.VEC, Field.VEC, Field.I8, Field.BOOL, Field.U8, Field.I32,
	Field.BOOL, Field.VEC, Field.U8, Field.U32, Field.BOOL, Field.BOOL,
]
enum Equipment { COOLDOWN, AIMING, BUFFERED, AIM_FACING, SHOT_FACING, RELOADING, RELOAD_LEFT, HOLD }
const EQUIPMENT_TYPES := [Field.F64, Field.BOOL, Field.BOOL, Field.I8, Field.I8, Field.BOOL, Field.F64, Field.F64]

static func _actor_types() -> Array[int]:
	var types: Array[int] = []
	for slot in SIZE:
		types.append(ACTOR_FIELDS[slot][0])
	return types

static func difference(snapshot: Dictionary, authority: Dictionary) -> String:
	var values: Array = snapshot["actor"]
	var authoritative: Array = authority["actor"]
	if values.size() != SIZE or authoritative.size() != SIZE:
		return "missing"
	for slot in SIZE:
		if values[slot] != authoritative[slot]:
			var field: String = ACTOR_FIELDS[slot][1]
			if not field.is_empty():
				return field
	return "equipment" if snapshot["equipment"] != authority["equipment"] else ""
