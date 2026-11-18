class_name PlayerStateSchema
extends RefCounted

# 角色和装备检查点的内存槽位。线上的顺序由 NetCodec 定义。
enum {
	POS, GROUNDED, HASTE_MULT, VEL, FACING, STATE_LOCK_TIMER, COYOTE_TIMER,
	JUMP_BUFFER_TIMER, JUMP_CUT_APPLIED, SQUAT, CHARGE, CHARGE_TIMER, LAST_MOVE_DIR,
	LAST_MOVE_TIMER, CLIMB_LATCHED, IN_WATER, KNOCK_VEL, SHOT_SERIAL, WATERPROOF_TIMER,
	WAS_SUBMERGED, DROWN_TIMER, IFRAMES, CONTROLS_LOCKED, WEAPON_INST, INVENTORY, STATE,
	WATERPROOF, HP, DOWNED, SIZE,
}

enum Equipment { COOLDOWN, AIMING, BUFFERED, AIM_FACING, SHOT_FACING, RELOADING, RELOAD_LEFT, HOLD }

static func equipped_type(actor: Array) -> int:
	var inventory: PackedInt32Array = actor[INVENTORY]
	var inst: int = actor[WEAPON_INST]
	for at in range(0, inventory.size(), WeaponInventory.STRIDE):
		if inventory[at + WeaponInventory.INST] == inst:
			return inventory[at + WeaponInventory.TYPE]
	return 0
