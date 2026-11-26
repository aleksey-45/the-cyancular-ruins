class_name PlayerStateSchema
extends RefCounted

# 角色状态以数组传递。枚举值是各字段的索引，SIZE 是数组长度。
# 手持武器状态放在数组最后。发送增量快照时，用独立位掩码标记变化的武器字段。
enum {
	POS, GROUNDED, HASTE_MULT, VEL, FACING, STATE_LOCK_TIMER, COYOTE_TIMER,
	JUMP_BUFFER_TIMER, JUMP_CUT_APPLIED, SQUAT, CHARGE, CHARGE_TIMER,
	CLIMB_LATCHED, IN_WATER, KNOCK_VEL, SHOT_SERIAL, WATERPROOF_TIMER,
	WAS_SUBMERGED, DROWN_TIMER, IFRAMES, CONTROLS_LOCKED, STATE, WATERPROOF, HP, DOWNED,
	AUTO_JUMP, REWIND, RESPAWN_TICK, LIFE, LAST_ATTACKER, LAST_HIT, AIM, SHOT_TYPE,
	WEAPON_NEXT, WEAPON_INST, INVENTORY, EQUIPMENT, SIZE,
}

const REWIND_FIELDS := [POS, GROUNDED, HASTE_MULT, VEL, FACING, STATE_LOCK_TIMER, COYOTE_TIMER,
	JUMP_BUFFER_TIMER, JUMP_CUT_APPLIED, SQUAT, CHARGE, CHARGE_TIMER, CLIMB_LATCHED, IN_WATER,
	KNOCK_VEL, WATERPROOF_TIMER, WAS_SUBMERGED, DROWN_TIMER, IFRAMES, CONTROLS_LOCKED, STATE,
	WATERPROOF, HP, DOWNED, AUTO_JUMP]

const PROPERTIES := [
	&"position", &"_grounded", &"personal_haste_mult", &"velocity", &"facing_direction",
	&"state_lock_timer", &"coyote_timer", &"jump_buffer_timer", &"jump_cut_applied", &"is_squat",
	&"is_charge", &"charge_timer", &"climb_latched", &"in_water", &"motion_knock_velocity",
	&"shot_serial", &"_waterproof_timer", &"_was_submerged", &"_waterproof_drown_timer",
	&"sim_iframes", &"_controls_locked", &"state", &"waterproof", &"sim_hp", &"sim_downed",
	&"_auto_jump_timer", &"rewinding", &"respawn_tick", &"life", &"last_attacker", &"last_hit_tick",
]

static func equipped_type(actor: Array) -> int:
	var inventory: PackedInt32Array = actor[INVENTORY]
	var inst: int = actor[WEAPON_INST]
	for at in range(0, inventory.size(), WeaponInventory.STRIDE):
		if inventory[at + WeaponInventory.INST] == inst:
			return inventory[at + WeaponInventory.TYPE]
	return 0
