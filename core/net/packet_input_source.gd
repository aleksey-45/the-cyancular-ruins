class_name PacketInputSource
extends PlayerInput


# ── 线格式转发壳:数值与实现的唯一来源 = InputWire;别名只为保住 `PacketInputSource.BIT_*` 等既有引用 ──
const BIT_UP := InputWire.BIT_UP
const BIT_DOWN := InputWire.BIT_DOWN
const BIT_CHARGE := InputWire.BIT_CHARGE
const BIT_ATTACK := InputWire.BIT_ATTACK
const BIT_RELOAD := InputWire.BIT_RELOAD
const BIT_PICKUP := InputWire.BIT_PICKUP
const BIT_DROP := InputWire.BIT_DROP
const BIT_HASTE := InputWire.BIT_HASTE
const BIT_REWIND := InputWire.BIT_REWIND
const BIT_NEED_FULL := InputWire.BIT_NEED_FULL
const TICKS_PER_RECORD := InputWire.TICKS_PER_RECORD


static func pack_record(src: PlayerInput, seq: int, aim: Vector2, snap_tick: int = 0,
		client_tick: int = 0, need_full: bool = false) -> Dictionary:
	return InputWire.pack_record(src, seq, aim, snap_tick, client_tick, need_full)


var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO
var _switch_inst := 0
var _pressed := 0
var _released := 0


func source_kind() -> int:
	return Kind.PACKET


const QUEUE_CAP_MIN := 4
const QUEUE_CAP_MAX := 16
const QUEUE_CAP_MARGIN := 2


static func adapted_cap(peak: int) -> int:
	return clampi(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)


static func push_pending(q: Array, pkt: Dictionary, cap: int = QUEUE_CAP_MAX) -> int:
	q.append(pkt)
	var raw := q.size()
	while q.size() > cap:
		var old: Dictionary = q.pop_front()
		var nxt: Dictionary = q[0]
		nxt["pressed"] = int(nxt.get("pressed", 0)) | int(old.get("pressed", 0))
		nxt["released"] = int(nxt.get("released", 0)) | int(old.get("released", 0))
		if int(nxt.get("winst", 0)) <= 0 and int(old.get("winst", 0)) > 0:
			nxt["winst"] = int(old.get("winst", 0))
		q[0] = nxt
	return raw


# ★★ 轴是归一体但协议上无界(ax=50 在服务端约等于 35000px/s,全图才 9600px):不可信入口收口为 非有限(NAN/±INF)→ 0,否则钳到 [-1,1]。
# ★ 先判有限性再钳(不能假设 clampf 对 NaN 的行为);动机是协议健壮性、不是反作弊;合法输入(|ax| <= 1)逐位不变 ⇒ 不动手感。
static func sanitize_axis(v: float) -> float:
	if not is_finite(v):
		return 0.0
	return clampf(v, -1.0, 1.0)


func apply_packet(pkt: Dictionary) -> void:
	_axis = sanitize_axis(float(pkt.get("ax", 0.0)))
	_held = pkt.get("held", 0)
	_aim = pkt.get("aim", Vector2.ZERO)
	var inst: int = pkt.get("winst", 0)
	if inst > 0:
		_switch_inst = inst
	_pressed |= pkt.get("pressed", 0)
	_released |= pkt.get("released", 0)

func haste_held() -> bool:
	return (_held & BIT_HASTE) != 0


func rewind_held() -> bool:
	return (_held & BIT_REWIND) != 0


func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_switch_inst = 0

func reset_state() -> void:
	_axis = 0.0
	_held = 0
	_aim = Vector2.ZERO
	_switch_inst = 0
	_pressed = 0
	_released = 0


func _axis_raw(neg: String, pos: String) -> float:
	if neg == "up" and pos == "down":
		if _held & BIT_UP != 0:
			return -1.0
		if _held & BIT_DOWN != 0:
			return 1.0
		return 0.0
	if neg == "down" and pos == "up":
		if _held & BIT_DOWN != 0:
			return -1.0
		if _held & BIT_UP != 0:
			return 1.0
		return 0.0
	return _axis

func _action_pressed_raw(action: String) -> bool:
	return _held & _bit(action) != 0

func _action_just_pressed_raw(action: String) -> bool:
	return _pressed & _bit(action) != 0

func _action_just_released_raw(action: String) -> bool:
	return _released & _bit(action) != 0

func _attack_pressed_raw() -> bool:
	return _held & BIT_ATTACK != 0

func _attack_just_pressed_raw() -> bool:
	return _pressed & BIT_ATTACK != 0

func _attack_just_released_raw() -> bool:
	return _released & BIT_ATTACK != 0

func _switch_index_raw() -> int:
	return 0


func _switch_inst_raw() -> int:
	return _switch_inst


func _pickup_pressed_raw() -> bool:
	return _pressed & BIT_PICKUP != 0


func _drop_pressed_raw() -> bool:
	return _pressed & BIT_DROP != 0


func get_aim_dir_override() -> Vector2:
	return _aim

func is_network_driven() -> bool:
	return true

static func _bit(action: String) -> int:
	match action:
		"up": return BIT_UP
		"down": return BIT_DOWN
		"charge": return BIT_CHARGE
		"attack": return BIT_ATTACK
		"R": return BIT_RELOAD
	return 0
