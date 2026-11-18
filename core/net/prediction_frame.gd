class_name PredictionFrame
extends RefCounted

const Slot := preload("res://core/sim/player_state_schema.gd")
const POSITION_TOLERANCE_PX := 0.1
const DIAGNOSTIC_NAMES := {
	Slot.POS: "pos", Slot.GROUNDED: "floor", Slot.HASTE_MULT: "haste_mult", Slot.VEL: "vel",
	Slot.FACING: "facing", Slot.COYOTE_TIMER: "coyote", Slot.JUMP_BUFFER_TIMER: "jbuf",
	Slot.JUMP_CUT_APPLIED: "jcut", Slot.SQUAT: "squat", Slot.CHARGE: "charge", Slot.CHARGE_TIMER: "ct",
	Slot.LAST_MOVE_DIR: "lmv_d", Slot.LAST_MOVE_TIMER: "lmv_t", Slot.CLIMB_LATCHED: "clatch",
	Slot.IN_WATER: "swim", Slot.KNOCK_VEL: "knock", Slot.SHOT_SERIAL: "shot_serial",
	Slot.WATERPROOF_TIMER: "wp_t", Slot.WAS_SUBMERGED: "wp_s", Slot.DROWN_TIMER: "wp_d",
	Slot.IFRAMES: "ifr", Slot.CONTROLS_LOCKED: "locked", Slot.WEAPON_INST: "winst", Slot.INVENTORY: "inv",
	Slot.WATERPROOF: "wp", Slot.HP: "hp", Slot.DOWNED: "down",
}

var tick: int
var players: Dictionary
var accounts: Dictionary
var projectiles: Dictionary
var shots: Dictionary

static func difference(snapshot: Dictionary, authority: Dictionary, map_size := Vector2.ZERO,
		include_presentation := false) -> String:
	var values: Array = snapshot["actor"]
	var authoritative: Array = authority["actor"]
	if values.size() != Slot.SIZE or authoritative.size() != Slot.SIZE:
		return "missing"
	for slot in Slot.SIZE:
		if values[slot] == authoritative[slot]:
			continue
		if slot == Slot.POS and map_size != Vector2.ZERO \
				and GridPathfinder.toroidal_delta_px(values[slot], authoritative[slot], map_size).length_squared() \
				< POSITION_TOLERANCE_PX * POSITION_TOLERANCE_PX:
			continue
		var field: String = DIAGNOSTIC_NAMES.get(slot, "")
		if not field.is_empty():
			return field
		if include_presentation:
			return "pose"
	return "equipment" if snapshot["equipment"] != authority["equipment"] else ""
