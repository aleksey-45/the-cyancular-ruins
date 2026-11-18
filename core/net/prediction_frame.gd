class_name PredictionFrame
extends CombatSnapshot

const Slot := preload("res://core/sim/player_state_schema.gd")
const POSITION_TOLERANCE_PX := 0.1
var accounts: Dictionary
var shots: Dictionary

static func difference(values: Array, authoritative: Array, map_size := Vector2.ZERO,
		include_presentation := false) -> String:
	if values.size() != Slot.SIZE or authoritative.size() != Slot.SIZE:
		return "missing"
	for slot in Slot.SIZE:
		if values[slot] == authoritative[slot]:
			continue
		if slot == Slot.POS and map_size != Vector2.ZERO \
				and GridPathfinder.toroidal_delta_px(values[slot], authoritative[slot], map_size).length_squared() \
				< POSITION_TOLERANCE_PX * POSITION_TOLERANCE_PX:
			continue
		if include_presentation or (slot != Slot.STATE and slot != Slot.STATE_LOCK_TIMER):
			return Slot.names[slot]
	return ""
