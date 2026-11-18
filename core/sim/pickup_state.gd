class_name PickupState
extends RefCounted

# 地面武器的权威快照记录。有效锁的高 16 位是角色，低 16 位是解锁 tick。

const POS := 0
const VEL := 1
const TYPE_ID := 2
const LOCK := 3

static func pack_lock(role: int, unlock_at: int, tick: int) -> int:
	return (role << 16) | (unlock_at & 0xffff) if unlock_at > tick else 0

static func unlock_tick(lock: int, tick: int) -> int:
	return tick + (((lock - tick + 0x8000) & 0xffff) - 0x8000)
