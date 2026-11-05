class_name ActorInput
extends RefCounted

# 一次共享步进的值输入。锁定只影响本 tick 的已处理字段，持续输入原值保留。
# 本地和网络输入都先打包，再在这里统一应用控制锁。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
const BIT_RELOAD := 16
const BIT_PICKUP := 32
const BIT_DROP := 64
const BIT_HASTE := 128
const BIT_REWIND := 256

var raw_axis := 0.0
var raw_held := 0
var axis := 0.0
var vertical_axis := 0.0
var held := 0
var pressed := 0
var released := 0
var weapon_inst := 0
var aim := Vector2.ZERO

func prepare(record: Dictionary, locked: bool) -> void:
	raw_axis = float(record["ax"])
	raw_held = int(record["held"])
	aim = record["aim"]
	axis = 0.0 if locked else raw_axis
	held = 0 if locked else raw_held
	pressed = 0 if locked else int(record["pressed"])
	released = 0 if locked else int(record["released"])
	weapon_inst = 0 if locked else int(record["winst"])
	vertical_axis = -1.0 if (held & BIT_UP) else (1.0 if (held & BIT_DOWN) else 0.0)
