class_name ActorInput
extends RefCounted

# 单次步进的输入。锁定只屏蔽本 tick 的动作，原记录由输入缓冲保留。
# 本地和网络输入都先打包，再在这里统一应用控制锁。
const AX: int = 0
const HELD: int = 1
const PRESSED: int = 2
const RELEASED: int = 3
const WINST: int = 4
const AIM: int = 5

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
const BIT_RELOAD := 16
const BIT_PICKUP := 32
const BIT_DROP := 64
const BIT_HASTE := 128
const BIT_REWIND := 256

var axis := 0.0
var vertical_axis := 0.0
var held := 0
var pressed := 0
var released := 0
var weapon_inst := 0
var aim := Vector2.ZERO

func prepare(record: Array, locked: bool) -> void:
	aim = record[AIM]
	axis = 0.0 if locked else float(record[AX])
	held = 0 if locked else int(record[HELD])
	pressed = 0 if locked else int(record[PRESSED])
	released = 0 if locked else int(record[RELEASED])
	weapon_inst = 0 if locked else int(record[WINST])
	vertical_axis = -1.0 if (held & BIT_UP) else (1.0 if (held & BIT_DOWN) else 0.0)
