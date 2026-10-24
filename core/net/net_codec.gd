class_name NetCodec
extends RefCounted

# 线格式:把载荷从 Dictionary 换成手打包的 PackedByteArray(快照 + 输入共用一套版本字节与 schema 表)。原先每个字段都要在线上带键名字符串(每帧重复)+ 4 字节类型标签 ——
# 实测同一份 8 字段数据:dict(键)= 196 B vs 手打包 = 24 B ⇒ 键 + 类型标签才是大头,不是数值本身;换掉后 N=8 世界包 2.1 KB → 0.27 KB(不再分片)、本人包 588 B → ~114 B。
# ── 本版不做量化(只换编码):只压发送侧会引入永久分歧(Gaffer《State Synchronization》)—— 两端都从量化后的状态起算,必须两端一起量化。本人包的 c2 是 C2 回滚锚点,
# 只量化上行 ⇒ 客户端重放起算点与服务器不一致 ⇒ 每次都判分歧、每次回滚。故本版只去开销、不动数值:字段与今天逐位相同。
# ── 变位数是无损的:Godot 非 double 构建里 encode_variant 已把 FLOAT 收成 32 位、Vector2 收成 2×float32 ⇒ float32 载荷与今天线上字节逐位一致,不是"看上去差不多"。
# ── 版本字节:首字节 = PROTO_VERSION,两端不同版时大声失败(解码返回空字典、调用方不 emit),而不是按错位的偏移读出垃圾值。★ 载荷里每个字节位置都是协议:改字段顺序/类型/宽度 = 改协议,两端必须同版本。
# ── 输入包(KIND_INPUT)也走这里:同一套版本字节 + schema 表。类名保留 NetCodec —— 它现在是**全项目**线格式编解码器(快照 + 输入)。
# ── ★★ 2026-10-24 编码侧性能:解码仍**表驱动**(`_unpack` 按 schema 读,不可信输入必须逐字段守边界),但**编码侧改成手写内联**
#   (`out.encode_float(i,v)` / 直接下标写),不再每字段调一个静态函数、不再经 schema 的 `match`/`dict.get` 双重派发。实测(N=16):
#   表驱动 ~304 µs/包 → 内联 ~47 µs/包(一次性量具 .superpowers/net/encode_profile.gd;同文件还量过「只 resize」= 0.2 µs ⇒ 瓶颈是每字段的
#   GDScript 调用,不是分配)。★ 代价 = 编码侧的字段顺序/宽度与 schema **成了两份**:漂移由 `snapshot_size_probe` 的往返判据 ③ 抓
#   (解码按 schema 读 ⇒ 顺序/宽度错 = 解出来的值必不对,立刻红),容量用 `_schema_bytes()` 预算(少算 ⇒ 越界/尺寸错,④ 最坏包抓)。
#   ⇒ 改 schema 必须同步改三个 encode_*;不改就一定红,不会静默。

const PROTO_VERSION := 2
const KIND_WORLD := 1
const KIND_OWN := 2
const KIND_INPUT := 3

# ── 类型字母 ──
const T_F := "f"      # float32,4 B(见文件头:与旧线上字节一致)
const T_V2 := "v2"    # 向量 = 2×float32,8 B
const T_U8 := "b"     # 0..255
const T_I8 := "c"     # -128..127(朝向这类 ±1 量)
const T_BOOL := "B"   # 1 B
const T_I32 := "i"    # 32 位有符号(inst / seq / tick)
const T_U16 := "h"    # 0..65535(输入 held 位掩码:BIT_REWIND = 256 装不进 u8)
const T_TRAIL := "trail"

# 世界包每人一份(13 字段,顺序 = 线上顺序)。范围按产品常量钳:hp ≤ 50、waterproof ≤ 10、pose ≤ 4。
const WORLD_SCHEMA: Array = [
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["pose", T_U8],
	["type_id", T_U8], ["hp", T_U8], ["waterproof", T_U8], ["downed", T_BOOL],
	["aim", T_V2], ["previewing", T_BOOL], ["haste", T_BOOL], ["rewind", T_BOOL],
	["trail", T_TRAIL],
]

# 本人包的核心整态 = player.capture_state() 的 25 个标量字段(inv 另走 INV_SCHEMA,武器的 8 个字段另走 WEAPON_SCHEMA —— 后者可能不存在,靠 flags 位声明)。
const C2_SCHEMA: Array = [
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["state", T_U8],
	["slock", T_F], ["coyote", T_F], ["jbuf", T_F], ["jcut", T_BOOL],
	["squat", T_BOOL], ["charge", T_BOOL], ["ct", T_F], ["lmv_d", T_I8],
	["lmv_t", T_F], ["wp", T_U8], ["wp_t", T_F], ["wp_s", T_BOOL],
	["wp_d", T_F], ["clatch", T_BOOL], ["swim", T_BOOL], ["hp", T_U8],
	["ifr", T_F], ["down", T_BOOL], ["knock", T_V2], ["wslot", T_U8],
	["winst", T_I32],
]

# 当前武器的 8 个字段(仅 `capture_state()` 里 `w != null` 时存在)。
const WEAPON_SCHEMA: Array = [
	["fire_cd", T_F], ["aiming", T_BOOL], ["fire_buf", T_BOOL], ["aim_f", T_I8],
	["aim_cf", T_I8], ["mag", T_U8], ["rld", T_BOOL], ["rld_t", T_F],
]

# 背包每一条(type/inst/mag —— 与 `weapon_inventory.snapshot()` 同源)。
const INV_SCHEMA: Array = [["type", T_U8], ["inst", T_I32], ["mag", T_U8]]

# 输入上行记录(30Hz 一包一条;发送侧唯一来源 = PacketInputSource.pack_record)。★ held 是位掩码:BIT_HASTE = 128、BIT_REWIND = 256 ⇒ 必须 u16(u8 会截断成 159)。
# st = 本端**最近成功解码**的服务器快照 tick;ct = 本帧客户端物理帧号。这两个字段本批只落位(增量批才有消费者),但线格式只改这一次。
const INPUT_SCHEMA: Array = [
	["seq", T_I32], ["ax", T_F], ["held", T_U16], ["pressed", T_U8], ["released", T_U8],
	["winst", T_I32], ["aim", T_V2], ["st", T_I32], ["ct", T_I32],
]

const FLAG_WEAPON := 1

# 解码侧硬顶:载荷里的长度是不可信输入(一个坏字节不该让解码端循环 255 次分配)。★ 它与发送侧上限 TRAIL_WIRE_MAX 不是同一个东西 —— 那个是"线上只带几点"的取舍。
const TRAIL_MAX := 16

# 线上最多带几个回溯点(取最近的;多余的截断、不报错):世界包必须装进一个 ENet 包,而 trail 是这个包里唯一的变长字段 ——
# 16 人 × 物理上限(10 点)= 1847 B ⇒ 2 片,而快照是 unreliable 分片 ⇒ 丢一片 = 整帧丢。4 点 ⇒ 7 + 16×66 = 1063 B(留 24% 余量),残像只少最老的几个点。★ 判据在 tests/probe/snapshot_size_probe.gd ④(量的是本函数的真实产出),改这个数必须先跑它。
const TRAIL_WIRE_MAX := 4

# 编码容量预算(类加载时算一次,不每包遍历 schema):仍是 `_schema_bytes()` 派生 ⇒ 改 schema 自动跟上,不手抄数字。
static var _W_ENTRY_BYTES := 1 + _schema_bytes(WORLD_SCHEMA)          # role 1 + 世界条目
static var _OWN_BASE_BYTES := 8 + _schema_bytes(C2_SCHEMA) + _schema_bytes(WEAPON_SCHEMA) + 1   # 头 8 + c2 + 武器(可能缺席) + inv 计数
static var _INV_ENTRY_BYTES := _schema_bytes(INV_SCHEMA)
static var _INPUT_BYTES := 2 + _schema_bytes(INPUT_SCHEMA)


# ── 编码(2026-10-24:手写内联)── ★ 一次性按 `_schema_bytes()` 预算容量 `resize`,然后全部就地写(`encode_float`/`encode_u32`/下标),
# 末尾 `resize(i)` 收尾。实测 304 → 47 µs/包(N=16);产出字节与旧实现**逐位不变**(判据:snapshot_size_probe 的尺寸 + 往返 + 最坏包)。

## 世界包:一次广播,含全部玩家的渲染字段。`{"tick": int, "players": {"role": {…13 字段}}}`。
## ★ 字段顺序/宽度必须与 WORLD_SCHEMA 一致(解码按 schema 读;漂移由 snapshot_size_probe ③ 抓)。
static func encode_world(world: Dictionary) -> PackedByteArray:
	var players: Dictionary = world.get("players", {})
	var n: int = mini(players.size(), 200)
	var out := PackedByteArray()
	out.resize(7 + n * _W_ENTRY_BYTES)   # 头 2+tick4+人数1;每人 = role 1 + schema 定长
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_WORLD
	i += 1
	out.encode_u32(i, int(world.get("tick", 0)))
	i += 4
	out[i] = n
	i += 1
	# ★ 依赖 GDScript 字典保持插入序(编码/解码同样保序,不需要额外排序)。
	for key in players:
		var e: Dictionary = players[key]
		out[i] = int(e.get("role", int(key))) & 0xFF
		i += 1
		var pos: Vector2 = e.get("pos", Vector2.ZERO)
		out.encode_float(i, pos.x)
		i += 4
		out.encode_float(i, pos.y)
		i += 4
		var vel: Vector2 = e.get("vel", Vector2.ZERO)
		out.encode_float(i, vel.x)
		i += 4
		out.encode_float(i, vel.y)
		i += 4
		out[i] = int(e.get("facing", 0)) & 0xFF
		i += 1
		out[i] = int(e.get("pose", 0)) & 0xFF
		i += 1
		out[i] = int(e.get("type_id", 0)) & 0xFF
		i += 1
		out[i] = int(e.get("hp", 0)) & 0xFF
		i += 1
		out[i] = int(e.get("waterproof", 0)) & 0xFF
		i += 1
		out[i] = 1 if bool(e.get("downed", false)) else 0
		i += 1
		var aim: Vector2 = e.get("aim", Vector2.ZERO)
		out.encode_float(i, aim.x)
		i += 4
		out.encode_float(i, aim.y)
		i += 4
		out[i] = 1 if bool(e.get("previewing", false)) else 0
		i += 1
		out[i] = 1 if bool(e.get("haste", false)) else 0
		i += 1
		out[i] = 1 if bool(e.get("rewind", false)) else 0
		i += 1
		var trail: Array = e.get("trail", [])
		var tn: int = mini(trail.size(), TRAIL_WIRE_MAX)
		out[i] = tn
		i += 1
		for k in range(trail.size() - tn, trail.size()):
			var p: Variant = trail[k]
			if p is Vector2:
				out.encode_float(i, (p as Vector2).x)
				i += 4
				out.encode_float(i, (p as Vector2).y)
				i += 4
			else:
				var a: Array = p
				out.encode_float(i, float(a[0]))
				i += 4
				out.encode_float(i, float(a[1]))
				i += 4
	out.resize(i)
	return out


## 本人包:定向逐 peer。`{"ack_seq": int, "q": int, "c2": capture_state()}`。
## ★ 字段顺序/宽度必须与 C2_SCHEMA / WEAPON_SCHEMA / INV_SCHEMA 一致(漂移由 snapshot_size_probe ③ 抓)。
static func encode_own(own: Dictionary) -> PackedByteArray:
	var c2: Dictionary = own.get("c2", {})
	var inv: Array = c2.get("inv", [])
	var n_inv: int = mini(inv.size(), 200)
	var out := PackedByteArray()
	# 容量按最坏算(武器块可能缺席):末尾 resize(i) 裁掉没用到的尾巴。
	out.resize(_OWN_BASE_BYTES + n_inv * _INV_ENTRY_BYTES)
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_OWN
	i += 1
	out.encode_u32(i, int(own.get("ack_seq", 0)))
	i += 4
	# 服务器侧该 role 的待消费队列深度(判据用:见 docs/eng/netcode-snapshots.md §6)。
	out[i] = int(own.get("q", 0)) & 0xFF
	i += 1
	var flags := FLAG_WEAPON if c2.has("fire_cd") else 0
	out[i] = flags
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
	out[i] = 1 if bool(c2.get("jcut", false)) else 0
	i += 1
	out[i] = 1 if bool(c2.get("squat", false)) else 0
	i += 1
	out[i] = 1 if bool(c2.get("charge", false)) else 0
	i += 1
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
	out[i] = 1 if bool(c2.get("wp_s", false)) else 0
	i += 1
	out.encode_float(i, float(c2.get("wp_d", 0.0)))
	i += 4
	out[i] = 1 if bool(c2.get("clatch", false)) else 0
	i += 1
	out[i] = 1 if bool(c2.get("swim", false)) else 0
	i += 1
	out[i] = int(c2.get("hp", 0)) & 0xFF
	i += 1
	out.encode_float(i, float(c2.get("ifr", 0.0)))
	i += 4
	out[i] = 1 if bool(c2.get("down", false)) else 0
	i += 1
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
		out.encode_float(i, float(c2.get("fire_cd", 0.0)))
		i += 4
		out[i] = 1 if bool(c2.get("aiming", false)) else 0
		i += 1
		out[i] = 1 if bool(c2.get("fire_buf", false)) else 0
		i += 1
		out[i] = int(c2.get("aim_f", 0)) & 0xFF
		i += 1
		out[i] = int(c2.get("aim_cf", 0)) & 0xFF
		i += 1
		out[i] = int(c2.get("mag", 0)) & 0xFF
		i += 1
		out[i] = 1 if bool(c2.get("rld", false)) else 0
		i += 1
		out.encode_float(i, float(c2.get("rld_t", 0.0)))
		i += 4
	out[i] = n_inv
	i += 1
	for e in inv:
		var w: Dictionary = e
		out[i] = int(w.get("type", 0)) & 0xFF
		i += 1
		out.encode_u32(i, int(w.get("inst", 0)))
		i += 4
		out[i] = int(w.get("mag", 0)) & 0xFF
		i += 1
	out.resize(i)
	return out


## 输入包:30Hz 一条记录。`{"seq","ax","held","pressed","released","winst","aim","st","ct"}`。
## 头 2 B + 记录 32 B = **34 B**(改前:7 键 Dictionary = 164 B/包)。★ 顺序/宽度必须与 INPUT_SCHEMA 一致。
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
	out.encode_float(i, float(pkt.get("ax", 0.0)))
	i += 4
	var held := int(pkt.get("held", 0))
	out[i] = held & 0xFF
	i += 1
	out[i] = (held >> 8) & 0xFF
	i += 1
	out[i] = int(pkt.get("pressed", 0)) & 0xFF
	i += 1
	out[i] = int(pkt.get("released", 0)) & 0xFF
	i += 1
	out.encode_u32(i, int(pkt.get("winst", 0)))
	i += 4
	var aim: Vector2 = pkt.get("aim", Vector2.ZERO)
	out.encode_float(i, aim.x)
	i += 4
	out.encode_float(i, aim.y)
	i += 4
	out.encode_u32(i, int(pkt.get("st", 0)))
	i += 4
	out.encode_u32(i, int(pkt.get("ct", 0)))
	i += 4
	out.resize(i)
	return out


# ── 解码 ── 任一字段越界 ⇒ 返回 {}(调用方据此不 emit):宁可这一帧没有快照,也不要把错位的值喂进预测面。
# ★ 解码保持**表驱动**(`_unpack`):解码侧是不可信输入,逐字段守边界;且 schema 是"字段集合"的单一来源(probe 的逐键对齐判据也读它)。

static func decode_world(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_WORLD):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	var tick := _rd_u32(r)
	var n := _rd_u8(r)
	var players := {}
	for i in n:
		var role := _rd_u8(r)
		# ★ 不再往条目里塞 role:它就是 players 的键(消费方一律 players.get(str(role))),塞进去会让解码结果比原 dict 多一个键 ⇒ "往返逐键一致"那条判据就废了(实测抓到过一次)。
		players[str(role)] = _unpack(r, WORLD_SCHEMA)
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return {"tick": tick, "players": players}


static func decode_own(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_OWN):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	var ack := _rd_u32(r)
	var depth := _rd_u8(r)
	var flags := _rd_u8(r)
	var c2 := _unpack(r, C2_SCHEMA)
	if flags & FLAG_WEAPON != 0:
		var w := _unpack(r, WEAPON_SCHEMA)
		for k in w:
			c2[k] = w[k]
	var n := _rd_u8(r)
	var inv: Array = []
	for i in mini(n, 200):
		inv.append(_unpack(r, INV_SCHEMA))
	c2["inv"] = inv
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return {"ack_seq": ack, "q": depth, "c2": c2}


static func decode_input(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_INPUT):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	var pkt := _unpack(r, INPUT_SCHEMA)
	if bool(r["bad"]) or int(r["o"]) != data.size():
		return {}
	return pkt


# ── 表驱动解包(读侧;写侧见各 encode_*)──

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
			T_U8:
				d[key] = _rd_u8(r)
			T_I8:
				d[key] = _rd_i8(r)
			T_BOOL:
				d[key] = _rd_u8(r) != 0
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
		out.append([_rd_f(r), _rd_f(r)])
	return out


# 每条 schema 记录的线上字节数 —— 编码容量预算的**唯一来源**(改 schema 自动跟着变,不会另抄一份数字漂掉)。
static func _schema_bytes(schema: Array) -> int:
	var n := 0
	for f in schema:
		match f[1]:
			T_F, T_I32:
				n += 4
			T_V2:
				n += 8
			T_U16:
				n += 2
			T_U8, T_I8, T_BOOL:
				n += 1
			T_TRAIL:
				n += 1 + 8 * TRAIL_WIRE_MAX
	return n


# ── 定长读(小端,游标 + 越界守卫)──

static func _rd_u8(r: Dictionary) -> int:
	var d: PackedByteArray = r["d"]
	var o: int = r["o"]
	if o + 1 > d.size():
		r["bad"] = true
		return 0
	r["o"] = o + 1
	return d[o]


static func _rd_i8(r: Dictionary) -> int:
	var v := _rd_u8(r)
	return v - 256 if v >= 128 else v


static func _rd_u16(r: Dictionary) -> int:
	var lo := _rd_u8(r)
	var hi := _rd_u8(r)
	return lo | (hi << 8)


static func _rd_u32(r: Dictionary) -> int:
	var d: PackedByteArray = r["d"]
	var o: int = r["o"]
	if o + 4 > d.size():
		r["bad"] = true
		return 0
	r["o"] = o + 4
	return d.decode_u32(o)


static func _rd_i32(r: Dictionary) -> int:
	var v := _rd_u32(r)
	return v - 4294967296 if v >= 2147483648 else v


static func _rd_f(r: Dictionary) -> float:
	var d: PackedByteArray = r["d"]
	var o: int = r["o"]
	if o + 4 > d.size():
		r["bad"] = true
		return 0.0
	r["o"] = o + 4
	return d.decode_float(o)


static func _header_ok(data: PackedByteArray, kind: int) -> bool:
	return data.size() >= 2 and data[0] == PROTO_VERSION and data[1] == kind
