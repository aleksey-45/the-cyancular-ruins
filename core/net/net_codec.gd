class_name NetCodec
extends RefCounted


const PROTO_VERSION := 9
const KIND_WORLD := 1
const KIND_OWN := 2
const KIND_INPUT := 3

const W_FULL := 1
const OW_FULL := 1


const T_F := "f"
const T_V2 := "v2"
const T_U8 := "b"
const T_I8 := "c"
const T_BOOLS := "flag"
const T_I32 := "i"
const T_U16 := "h"
const T_TRAIL := "trail"
const T_QV2 := "qv2"
const T_QAIM := "qaim"
const T_FAIM := "faim"

const Q_SCALE := 2.0
const Q_VEL_CLAMP := 6000.0
const Q_AIM_STEPS := 256.0
const AIM_FP := 10000.0

const WORLD_SCHEMA: Array = [
	["_flags", T_BOOLS, ["downed", "previewing", "haste", "rewind"]],
	["pos", T_QV2], ["vel", T_QV2], ["facing", T_I8], ["pose", T_U8],
	["type_id", T_U8], ["hp", T_U8], ["waterproof", T_U8],
	["aim", T_QAIM], ["trail", T_TRAIL],
]

const C2_SCHEMA: Array = [
	["_flags", T_BOOLS, ["jcut", "squat", "charge", "wp_s", "clatch", "swim", "down"]],
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["state", T_U8],
	["slock", T_F], ["coyote", T_F], ["jbuf", T_F],
	["ct", T_F], ["lmv_d", T_I8], ["lmv_t", T_F], ["wp", T_U8], ["wp_t", T_F],
	["wp_d", T_F], ["hp", T_U8], ["ifr", T_F], ["knock", T_V2], ["wslot", T_U8],
	["winst", T_I32],
]

const WEAPON_SCHEMA: Array = [
	["_flags", T_BOOLS, ["aiming", "fire_buf", "rld"]],
	["fire_cd", T_F], ["aim_f", T_I8], ["aim_cf", T_I8], ["mag", T_U8], ["rld_t", T_F],
	["chg", T_F], ["trg", T_F],
]

# 背包每一条(type/inst/mag —— 与 `weapon_inventory.snapshot()` 同源)。
const INV_SCHEMA: Array = [["type", T_U8], ["inst", T_I32], ["mag", T_U8]]

# 输入上行包(60Hz 一包一条记录;发送侧唯一来源 = PacketInputSource.pack_record → InputWire.pack_record)。
const INPUT_SCHEMA: Array = [
	["seq", T_I32],
	["held", T_U16],
	["ax", T_F],
	["pressed", T_U8],
	["released", T_U8],
	["winst", T_I32],
	["aim", T_FAIM], ["st", T_I32], ["ct", T_I32],
]

const FLAG_WEAPON := 1

const TRAIL_MAX := 16

const TRAIL_WIRE_MAX := 4

static var _INV_ENTRY_BYTES := _schema_bytes(INV_SCHEMA)
static var _INPUT_BYTES := 2 + _schema_bytes(INPUT_SCHEMA)
static var _WORLD_ENTRY_BYTES := _schema_bytes(WORLD_SCHEMA)
static var _OWN_BYTES := 12 + 1 + _schema_bytes(C2_SCHEMA) + _schema_bytes(WEAPON_SCHEMA) + 1



static func encode_world(world: Dictionary) -> PackedByteArray:
	var players: Dictionary = world.get("players", {})
	var n: int = mini(players.size(), 200)
	var out := PackedByteArray()
	out.resize(8 + n * (1 + _WORLD_ENTRY_BYTES))
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_WORLD
	i += 1
	out[i] = W_FULL
	i += 1
	out.encode_u32(i, int(world.get("tick", 0)))
	i += 4
	var count_pos := i
	i += 1
	var emitted := 0
	for key in players:
		if emitted >= 200:
			break
		var e: Dictionary = players[key]
		out[i] = int(e.get("role", int(key))) & 0xFF
		i += 1
		i = _write_world_entry_body(out, i, e)
		emitted += 1
	out[count_pos] = emitted
	out.resize(i)
	return out


static func _write_world_entry_body(out: PackedByteArray, i: int, e: Dictionary) -> int:
	out[i] = (1 if bool(e.get("downed", false)) else 0) \
			| (2 if bool(e.get("previewing", false)) else 0) \
			| (4 if bool(e.get("haste", false)) else 0) \
			| (8 if bool(e.get("rewind", false)) else 0)
	i += 1
	var pos: Vector2 = e.get("pos", Vector2.ZERO)
	var qx := clampi(roundi(pos.x * Q_SCALE), -32768, 32767)
	out[i] = qx & 0xFF
	out[i + 1] = (qx >> 8) & 0xFF
	i += 2
	var qy := clampi(roundi(pos.y * Q_SCALE), -32768, 32767)
	out[i] = qy & 0xFF
	out[i + 1] = (qy >> 8) & 0xFF
	i += 2
	var vel: Vector2 = e.get("vel", Vector2.ZERO)
	var vx := clampi(roundi(clampf(vel.x, -Q_VEL_CLAMP, Q_VEL_CLAMP) * Q_SCALE), -32768, 32767)
	out[i] = vx & 0xFF
	out[i + 1] = (vx >> 8) & 0xFF
	i += 2
	var vy := clampi(roundi(clampf(vel.y, -Q_VEL_CLAMP, Q_VEL_CLAMP) * Q_SCALE), -32768, 32767)
	out[i] = vy & 0xFF
	out[i + 1] = (vy >> 8) & 0xFF
	i += 2
	out[i] = int(e.get("facing", 0)) & 0xFF
	i += 1
	out[i] = int(e.get("pose", 0)) & 0xFF
	i += 1
	out[i] = int(e.get("type_id", 0)) & 0xFF
	i += 1
	out[i] = clampi(int(e.get("hp", 0)), 0, 255)
	i += 1
	out[i] = int(e.get("waterproof", 0)) & 0xFF
	i += 1
	var aim: Vector2 = e.get("aim", Vector2.ZERO)
	out[i] = int(roundf(atan2(aim.y, aim.x) / TAU * Q_AIM_STEPS)) & 0xFF
	i += 1
	var trail: Array = e.get("trail", [])
	var tn: int = mini(trail.size(), TRAIL_WIRE_MAX)
	out[i] = tn
	i += 1
	for k in range(trail.size() - tn, trail.size()):
		var p: Variant = trail[k]
		var px: float
		var py: float
		if p is Vector2:
			px = (p as Vector2).x
			py = (p as Vector2).y
		else:
			var a: Array = p
			px = float(a[0])
			py = float(a[1])
		var tqx := clampi(roundi(px * Q_SCALE), -32768, 32767)
		out[i] = tqx & 0xFF
		out[i + 1] = (tqx >> 8) & 0xFF
		i += 2
		var tqy := clampi(roundi(py * Q_SCALE), -32768, 32767)
		out[i] = tqy & 0xFF
		out[i + 1] = (tqy >> 8) & 0xFF
		i += 2
	return i


static func encode_own(own: Dictionary) -> PackedByteArray:
	var c2: Dictionary = own.get("c2", {})
	var inv: Array = c2.get("inv", [])
	var n_inv: int = mini(inv.size(), 200)
	var out := PackedByteArray()
	out.resize(_OWN_BYTES + n_inv * _INV_ENTRY_BYTES)
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_OWN
	i += 1
	out[i] = OW_FULL
	i += 1
	out.encode_u32(i, int(own.get("tick", 0)))
	i += 4
	out.encode_u32(i, int(own.get("ack_seq", 0)))
	i += 4
	# 服务器侧该 role 的待消费队列深度(判据用:见 docs/netcode/protocol/netcode-snapshots.md §6)。
	out[i] = int(own.get("q", 0)) & 0xFF
	i += 1
	i = _write_own_body(out, i, c2)
	out.resize(i)
	return out


static func _write_own_body(out: PackedByteArray, i: int, c2: Dictionary) -> int:
	var flags := FLAG_WEAPON if c2.has("fire_cd") else 0
	out[i] = flags
	i += 1
	out[i] = (1 if bool(c2.get("jcut", false)) else 0) \
			| (2 if bool(c2.get("squat", false)) else 0) \
			| (4 if bool(c2.get("charge", false)) else 0) \
			| (8 if bool(c2.get("wp_s", false)) else 0) \
			| (16 if bool(c2.get("clatch", false)) else 0) \
			| (32 if bool(c2.get("swim", false)) else 0) \
			| (64 if bool(c2.get("down", false)) else 0)
	i += 1
	var pos: Vector2 = c2.get("pos", Vector2.ZERO)
	out.encode_float(i, pos.x)
	i += 4
	out.encode_float(i, pos.y)
	i += 4
	var vel: Vector2 = c2.get("vel", Vector2.ZERO)
	out.encode_float(i, vel.x)
	i += 4
	out.encode_float(i, vel.y)
	i += 4
	out[i] = int(c2.get("facing", 0)) & 0xFF
	i += 1
	out[i] = int(c2.get("state", 0)) & 0xFF
	i += 1
	out.encode_float(i, float(c2.get("slock", 0.0)))
	i += 4
	out.encode_float(i, float(c2.get("coyote", 0.0)))
	i += 4
	out.encode_float(i, float(c2.get("jbuf", 0.0)))
	i += 4
	out.encode_float(i, float(c2.get("ct", 0.0)))
	i += 4
	out[i] = int(c2.get("lmv_d", 0)) & 0xFF
	i += 1
	out.encode_float(i, float(c2.get("lmv_t", 0.0)))
	i += 4
	out[i] = int(c2.get("wp", 0)) & 0xFF
	i += 1
	out.encode_float(i, float(c2.get("wp_t", 0.0)))
	i += 4
	out.encode_float(i, float(c2.get("wp_d", 0.0)))
	i += 4
	out[i] = clampi(int(c2.get("hp", 0)), 0, 255)
	i += 1
	out.encode_float(i, float(c2.get("ifr", 0.0)))
	i += 4
	var knock: Vector2 = c2.get("knock", Vector2.ZERO)
	out.encode_float(i, knock.x)
	i += 4
	out.encode_float(i, knock.y)
	i += 4
	out[i] = int(c2.get("wslot", 0)) & 0xFF
	i += 1
	out.encode_u32(i, int(c2.get("winst", 0)))
	i += 4
	if flags & FLAG_WEAPON != 0:
		out[i] = (1 if bool(c2.get("aiming", false)) else 0) \
				| (2 if bool(c2.get("fire_buf", false)) else 0) \
				| (4 if bool(c2.get("rld", false)) else 0)
		i += 1
		out.encode_float(i, float(c2.get("fire_cd", 0.0)))
		i += 4
		out[i] = int(c2.get("aim_f", 0)) & 0xFF
		i += 1
		out[i] = int(c2.get("aim_cf", 0)) & 0xFF
		i += 1
		out[i] = int(c2.get("mag", 0)) & 0xFF
		i += 1
		out.encode_float(i, float(c2.get("rld_t", 0.0)))
		i += 4
		out.encode_float(i, float(c2.get("chg", 0.0)))
		i += 4
		out.encode_float(i, float(c2.get("trg", 0.0)))
		i += 4
	return _write_inv(out, i, c2.get("inv", []))


static func _write_inv(out: PackedByteArray, i: int, inv: Array) -> int:
	var n_inv: int = mini(inv.size(), 200)
	out[i] = n_inv
	i += 1
	for k in n_inv:
		var w: Dictionary = inv[k]
		out[i] = int(w.get("type", 0)) & 0xFF
		i += 1
		out.encode_u32(i, int(w.get("inst", 0)))
		i += 4
		out[i] = int(w.get("mag", 0)) & 0xFF
		i += 1
	return i


static func _read_inv(r: Dictionary) -> Array:
	var n := _rd_u8(r)
	var inv: Array = []
	for i in mini(n, 200):
		inv.append(_unpack(r, INV_SCHEMA))
	return inv


static func encode_input(pkt: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(_INPUT_BYTES)
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_INPUT
	i += 1
	out.encode_u32(i, int(pkt.get("seq", 0)))
	i += 4
	var held := int(pkt.get("held", 0))
	out[i] = held & 0xFF
	i += 1
	out[i] = (held >> 8) & 0xFF
	i += 1
	out.encode_float(i, float(pkt.get("ax", 0.0)))
	i += 4
	out[i] = int(pkt.get("pressed", 0)) & 0xFF
	i += 1
	out[i] = int(pkt.get("released", 0)) & 0xFF
	i += 1
	out.encode_u32(i, int(pkt.get("winst", 0)))
	i += 4
	var aim: Vector2 = pkt.get("aim", Vector2.ZERO)
	var alim := int(AIM_FP)
	var qax := clampi(roundi(aim.x * AIM_FP), -alim, alim)
	out[i] = qax & 0xFF
	out[i + 1] = (qax >> 8) & 0xFF
	i += 2
	var qay := clampi(roundi(aim.y * AIM_FP), -alim, alim)
	out[i] = qay & 0xFF
	out[i + 1] = (qay >> 8) & 0xFF
	i += 2
	out.encode_u32(i, int(pkt.get("st", 0)))
	i += 4
	out.encode_u32(i, int(pkt.get("ct", 0)))
	i += 4
	out.resize(i)
	return out


# ── 解码 ── 任一字段越界 ⇒ 返回 {}(调用方据此不 emit):宁可这一帧没有快照,也不要把错位的值喂进预测面。
# ★ 解码保持表驱动(`_unpack`):解码侧是不可信输入,逐字段守边界;且 schema 是"字段集合"的单一来源(probe 的逐键对齐判据也读它)。

static func decode_world(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_WORLD):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	if _rd_u8(r) != W_FULL:
		return {}
	var tick := _rd_u32(r)
	var n := _rd_u8(r)
	var players := {}
	for i in n:
		var role := _rd_u8(r)
		players[str(role)] = _unpack(r, WORLD_SCHEMA)
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return {"tick": tick, "players": players}


static func decode_own(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_OWN):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	if _rd_u8(r) != OW_FULL:
		return {}
	var tick := _rd_u32(r)
	var ack := _rd_u32(r)
	var depth := _rd_u8(r)
	var wflags := _rd_u8(r)
	var c2 := _unpack(r, C2_SCHEMA)
	if wflags & FLAG_WEAPON != 0:
		var w := _unpack(r, WEAPON_SCHEMA)
		for k in w:
			c2[k] = w[k]
	c2["inv"] = _read_inv(r)
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return {"ack_seq": ack, "q": depth, "tick": tick, "c2": c2}


static func decode_input(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_INPUT):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	var pkt := _unpack(r, INPUT_SCHEMA)
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return pkt



static func _unpack(r: Dictionary, schema: Array) -> Dictionary:
	var d := {}
	for f in schema:
		var t: String = f[1]
		var key: String = f[0]
		match t:
			T_F:
				d[key] = _rd_f(r)
			T_V2:
				d[key] = Vector2(_rd_f(r), _rd_f(r))
			T_QV2:
				d[key] = Vector2(_rd_i16(r) / Q_SCALE, _rd_i16(r) / Q_SCALE)
			T_QAIM:
				var ang := float(_rd_u8(r)) / Q_AIM_STEPS * TAU
				d[key] = Vector2(cos(ang), sin(ang))
			T_FAIM:
				var fv := Vector2(_rd_i16(r) / AIM_FP, _rd_i16(r) / AIM_FP)
				d[key] = fv.normalized() if not fv.is_zero_approx() else Vector2.RIGHT
			T_U8:
				d[key] = _rd_u8(r)
			T_I8:
				d[key] = _rd_i8(r)
			T_BOOLS:
				var fb := _rd_u8(r)
				var subs: Array = f[2]
				for bi in subs.size():
					d[subs[bi]] = (fb & (1 << bi)) != 0
			T_I32:
				d[key] = _rd_i32(r)
			T_U16:
				d[key] = _rd_u16(r)
			T_TRAIL:
				d[key] = _rd_trail(r)
	return d


static func _rd_trail(r: Dictionary) -> Array:
	var n := mini(_rd_u8(r), TRAIL_MAX)
	var out: Array = []
	for i in n:
		out.append([_rd_i16(r) / Q_SCALE, _rd_i16(r) / Q_SCALE])
	return out


# 每条 schema 记录的线上字节数 —— 编码容量预算的唯一来源(改 schema 自动跟着变,不会另抄一份数字漂掉)。
static func _schema_bytes(schema: Array) -> int:
	var n := 0
	for f in schema:
		match f[1]:
			T_F, T_I32:
				n += 4
			T_V2:
				n += 8
			T_QV2, T_FAIM:
				n += 4
			T_U16:
				n += 2
			T_BOOLS:
				n += 1
			T_QAIM, T_U8, T_I8:
				n += 1
			T_TRAIL:
				n += 1 + 4 * TRAIL_WIRE_MAX
	return n



static func _take(r: Dictionary, n: int) -> int:
	var o: int = r["o"]
	var d: PackedByteArray = r["d"]
	if o + n > d.size():
		r["bad"] = true
		return -1
	r["o"] = o + n
	return o


static func _rd_u8(r: Dictionary) -> int:
	var o := _take(r, 1)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d[o]


static func _rd_i8(r: Dictionary) -> int:
	var o := _take(r, 1)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d.decode_s8(o)


static func _rd_u16(r: Dictionary) -> int:
	var o := _take(r, 2)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d.decode_u16(o)


static func _rd_i16(r: Dictionary) -> int:
	var o := _take(r, 2)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d.decode_s16(o)


static func _rd_u32(r: Dictionary) -> int:
	var o := _take(r, 4)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d.decode_u32(o)


static func _rd_i32(r: Dictionary) -> int:
	var o := _take(r, 4)
	if o < 0:
		return 0
	var d: PackedByteArray = r["d"]
	return d.decode_s32(o)


static func _rd_f(r: Dictionary) -> float:
	var o := _take(r, 4)
	if o < 0:
		return 0.0
	var d: PackedByteArray = r["d"]
	return d.decode_float(o)


static func _header_ok(data: PackedByteArray, kind: int) -> bool:
	return data.size() >= 2 and data[0] == PROTO_VERSION and data[1] == kind