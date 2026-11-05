class_name PlayerStateSchema
extends RefCounted

# 玩家记录槽位定义：名字顺序即槽序。
# 本地完整预测用前 37 槽；广播再追加 11 槽，提供远端运动控制与表现。
# 线类型由编码器按同一槽序声明，两边都按下标读写。

const NAMES := ["pos", "floor", "haste_mult", "vel", "facing", "slock", "coyote", "jbuf", "jcut",
		"squat", "charge", "ct", "lmv_d", "lmv_t", "clatch", "swim", "knock", "shot_serial",
		"wp_t", "wp_s", "wp_d", "ifr", "locked", "winst", "inv", "state", "wp", "hp", "down",
		"fire_cd", "aiming", "fire_buf", "aim_f", "aim_cf", "mag", "rld", "rld_t",
		"aim", "type_id", "epoch", "previewing", "haste", "rewind", "axis", "held", "move_mult",
		"respawn_tick", "rewind_path"]

const SIZE := 37
const MOTION_SIZE := 17
const CHARACTER_SIZE := 29
const ACTOR_SIZE := 48

# 动画姿态与停留计时仍随快照保存恢复，但不决定碰撞、武器或玩法结果。
const PRESENTATION := ["slock", "state"]

static var INDEX := _build_index()

static func _build_index() -> Dictionary:
	var map := {}
	for index in NAMES.size():
		map[NAMES[index]] = index
	return map

static func slot(field: String) -> int:
	return int(INDEX[field])

static func difference(values: Array, authoritative: Array) -> String:
	if values.is_empty() or authoritative.size() != values.size():
		return "missing"
	for index in values.size():
		if NAMES[index] in PRESENTATION:
			continue
		if values[index] != authoritative[index]:
			return NAMES[index]
	return ""
