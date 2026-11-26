class_name ActorInput
extends RefCounted

# 本地输入与联机输入共用此格式，每个模拟步读取对应的记录。
# 输入锁定时保留瞄准方向，其余字段按空输入处理。
const AX: int = 0
const HELD: int = 1
const PRESSED: int = 2
const RELEASED: int = 3
const WINST: int = 4
const AIM: int = 5

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE_LEFT := 4
const BIT_ATTACK := 8
const BIT_RELOAD := 16
const BIT_PICKUP := 32
const BIT_DROP := 64
const BIT_HASTE := 128
const BIT_REWIND := 256
const BIT_CHARGE_RIGHT := 512

var axis := 0.0
var vertical_axis := 0.0
var charge_direction := 0
var held := 0
var pressed := 0
var released := 0
var weapon_inst := 0
var aim := Vector2.ZERO

static func neutral(direction := Vector2.RIGHT) -> Array:
	return [0.0, 0, 0, 0, 0, direction]

func prepare(record: Array, locked: bool) -> void:
	aim = record[AIM]
	axis = 0.0 if locked else float(record[AX])
	held = 0 if locked else int(record[HELD])
	pressed = 0 if locked else int(record[PRESSED])
	released = 0 if locked else int(record[RELEASED])
	weapon_inst = 0 if locked else int(record[WINST])
	vertical_axis = -1.0 if (held & BIT_UP) else (1.0 if (held & BIT_DOWN) else 0.0)
	charge_direction = int((pressed & BIT_CHARGE_RIGHT) != 0) - int((pressed & BIT_CHARGE_LEFT) != 0)
