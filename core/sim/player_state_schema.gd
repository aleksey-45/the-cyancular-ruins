class_name PlayerStateSchema
extends RefCounted

# 角色检查点按槽位顺序编码。手持装备在最后一个槽位，用独立的增量掩码。
enum {
	POS, GROUNDED, HASTE_MULT, VEL, FACING, STATE_LOCK_TIMER, COYOTE_TIMER,
	JUMP_BUFFER_TIMER, JUMP_CUT_APPLIED, SQUAT, CHARGE, CHARGE_TIMER, LAST_MOVE_DIR,
	LAST_MOVE_TIMER, CLIMB_LATCHED, IN_WATER, KNOCK_VEL, SHOT_SERIAL, WATERPROOF_TIMER,
	WAS_SUBMERGED, DROWN_TIMER, IFRAMES, CONTROLS_LOCKED, STATE, WATERPROOF, HP, DOWNED,
	WEAPON_INST, INVENTORY, EQUIPMENT, SIZE,
}

# 网络记录引用同一份模拟检查点，并附上这名角色的输入与时序。
enum Network { EPOCH, ACTION_ACK, REWIND, RESPAWN_TICK, AIM, INPUT, STATE, SIZE }

enum Equipment { COOLDOWN, AIMING, BUFFERED, SHOT_FACING, RELOAD_LEFT, HOLD }

# 普通字段直接来自角色属性。装备归属和武器内部状态由背包恢复。
const Field := NetEvent.Field
const EQUIPMENT_TYPES := [Field.F64, Field.BOOL, Field.BOOL, Field.I8, Field.F64, Field.F64]
const FIELDS := {
	POS: [&"position", Field.VEC], GROUNDED: [&"_grounded", Field.BOOL],
	HASTE_MULT: [&"personal_haste_mult", Field.F64], VEL: [&"velocity", Field.VEC],
	FACING: [&"facing_direction", Field.I8], STATE_LOCK_TIMER: [&"state_lock_timer", Field.F64],
	COYOTE_TIMER: [&"coyote_timer", Field.F64], JUMP_BUFFER_TIMER: [&"jump_buffer_timer", Field.F64],
	JUMP_CUT_APPLIED: [&"jump_cut_applied", Field.BOOL], SQUAT: [&"is_squat", Field.BOOL],
	CHARGE: [&"is_charge", Field.BOOL], CHARGE_TIMER: [&"charge_timer", Field.F64],
	LAST_MOVE_DIR: [&"_last_move_dir", Field.I8], LAST_MOVE_TIMER: [&"_last_move_timer", Field.F64],
	CLIMB_LATCHED: [&"climb_latched", Field.BOOL], IN_WATER: [&"in_water", Field.BOOL],
	KNOCK_VEL: [&"motion_knock_velocity", Field.VEC], SHOT_SERIAL: [&"shot_serial", Field.U32],
	WATERPROOF_TIMER: [&"_waterproof_timer", Field.F64], WAS_SUBMERGED: [&"_was_submerged", Field.BOOL],
	DROWN_TIMER: [&"_waterproof_drown_timer", Field.F64], IFRAMES: [&"sim_iframes", Field.F64],
	CONTROLS_LOCKED: [&"_controls_locked", Field.BOOL], STATE: [&"state", Field.U8],
	WATERPROOF: [&"waterproof", Field.I32], HP: [&"sim_hp", Field.I32], DOWNED: [&"sim_downed", Field.BOOL],
	WEAPON_INST: [&"weapon_inst", Field.U32], INVENTORY: [&"inventory", Field.INVENTORY],
}
static var names: Array[StringName] = []
static var wire_types: Array[int] = []

static func _static_init() -> void:
	for slot in EQUIPMENT:
		names.append(FIELDS[slot][0])
		wire_types.append(FIELDS[slot][1])
	names.append(&"equipment")

static func equipped_type(actor: Array) -> int:
	var inventory: PackedInt32Array = actor[INVENTORY]
	var inst: int = actor[WEAPON_INST]
	for at in range(0, inventory.size(), WeaponInventory.STRIDE):
		if inventory[at + WeaponInventory.INST] == inst:
			return inventory[at + WeaponInventory.TYPE]
	return 0
