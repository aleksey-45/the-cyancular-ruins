class_name NetCodec
extends RefCounted

# 快照线格式:把快照载荷从 Dictionary 换成手打包的 PackedByteArray。原先每个字段都要在线上带键名字符串(每帧重复)+ 4 字节类型标签 ——
# 实测同一份 8 字段数据:dict(键)= 196 B vs 手打包 = 24 B ⇒ 键 + 类型标签才是大头,不是数值本身;换掉后 N=8 世界包 2.1 KB → 0.27 KB(不再分片)、本人包 588 B → ~114 B。
# ── 本版不做量化(只换编码):只压发送侧会引入永久分歧(Gaffer《State Synchronization》)—— 两端都从量化后的状态起算,必须两端一起量化。本人包的 c2 是 C2 回滚锚点,
# 只量化上行 ⇒ 客户端重放起算点与服务器不一致 ⇒ 每次都判分歧、每次回滚。故本版只去开销、不动数值:字段与今天逐位相同。
# ── 变位数是无损的:Godot 非 double 构建里 encode_variant 已把 FLOAT 收成 32 位、Vector2 收成 2×float32 ⇒ float32 载荷与今天线上字节逐位一致,不是"看上去差不多"。
# ── 用一张 schema 表驱动两侧:手写编解码最可能的缺陷是顺序/偏移漂移(加一个字段、两侧改漏一处 ⇒ 静默错位),两侧共表 ⇒ 顺序在构造上不可能分叉(探针 snapshot_size_probe 有"表必须覆盖真实字段"的判据)。
# ── 版本字节:首字节 = PROTO_VERSION,两端不同版时大声失败(解码返回空字典、调用方不 emit),而不是按错位的偏移读出垃圾值。★ 载荷里每个字节位置都是协议:改字段顺序/类型/宽度 = 改协议,两端必须同版本。

const PROTO_VERSION := 1
const KIND_WORLD := 1
const KIND_OWN := 2

# ── 类型字母 ──
const T_F := "f"      # float32,4 B(见文件头:与旧线上字节一致)
const T_V2 := "v2"    # 向量 = 2×float32,8 B
const T_U8 := "b"     # 0..255
const T_I8 := "c"     # -128..127(朝向这类 ±1 量)
const T_BOOL := "B"   # 1 B
const T_I32 := "i"    # 32 位有符号(inst / seq / tick)
const T_TRAIL := "trail"

# 世界包每人一份(13 字段,顺序 = 线上顺序)。范围按产品常量钳:hp ≤ 50、waterproof ≤ 10、pose ≤ 4。
const WORLD_SCHEMA: Array = [
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["pose", T_U8],
	["type_id", T_U8], ["hp", T_U8], ["waterproof", T_U8], ["downed", T_BOOL],
	["aim", T_V2], ["previewing", T_BOOL], ["haste", T_BOOL], ["rewind", T_BOOL],
	["trail", T_TRAIL],
]

# 本人包的核心整态 = player.capture_state() 的 25 个标量字段(inv 另走 T_INV,武器的 8 个字段另走 WEAPON_SCHEMA —— 后者可能不存在,靠 flags 位声明)。
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

const FLAG_WEAPON := 1

# 解码侧硬顶:载荷里的长度是不可信输入(一个坏字节不该让解码端循环 255 次分配)。★ 它与发送侧上限 TRAIL_WIRE_MAX 不是同一个东西 —— 那个是"线上只带几点"的取舍。
const TRAIL_MAX := 16

# 线上最多带几个回溯点(取最近的;多余的截断、不报错):世界包必须装进一个 ENet 包,而 trail 是这个包里唯一的变长字段 ——
# 16 人 × 物理上限(10 点)= 1847 B ⇒ 2 片,而快照是 unreliable 分片 ⇒ 丢一片 = 整帧丢。4 点 ⇒ 7 + 16×66 = 1063 B(留 24% 余量),残像只少最老的几个点。★ 判据在 tests/probe/snapshot_size_probe.gd ④(量的是本函数的真实产出),改这个数必须先跑它。
const TRAIL_WIRE_MAX := 4


# ── 编码 ──

## 世界包:一次广播,含全部玩家的渲染字段。`{"tick": int, "players": {"role": {…13 字段}}}`。
static func encode_world(world: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.append(PROTO_VERSION)
	out.append(KIND_WORLD)
	_put_u32(out, int(world.get("tick", 0)))
	var players: Dictionary = world.get("players", {})
	_put_u8(out, mini(players.size(), 200))
	# ★ 依赖 GDScript 字典保持插入序(编码/解码同样保序,不需要额外排序)。
	for key in players:
		var entry: Dictionary = players[key]
		_put_u8(out, int(entry.get("role", int(str(key)))))
		_pack(out, WORLD_SCHEMA, entry)
	return out


## 本人包:定向逐 peer。`{"ack_seq": int, "q": int, "c2": capture_state()}`。
static func encode_own(own: Dictionary) -> PackedByteArray:
	var c2: Dictionary = own.get("c2", {})
	var out := PackedByteArray()
	out.append(PROTO_VERSION)
	out.append(KIND_OWN)
	_put_u32(out, int(own.get("ack_seq", 0)))
	# 服务器侧该 role 的待消费队列深度(判据用:见 docs/eng/netcode-snapshots.md §6)。
	_put_u8(out, int(own.get("q", 0)))
	var flags := 0
	if c2.has("fire_cd"):
		flags |= FLAG_WEAPON
	_put_u8(out, flags)
	_pack(out, C2_SCHEMA, c2)
	if flags & FLAG_WEAPON != 0:
		_pack(out, WEAPON_SCHEMA, c2)
	var inv: Array = c2.get("inv", [])
	_put_u8(out, mini(inv.size(), 200))
	for e in inv:
		_pack(out, INV_SCHEMA, e as Dictionary)
	return out


# ── 解码 ── 任一字段越界 ⇒ 返回 {}(调用方据此不 emit):宁可这一帧没有快照,也不要把错位的值喂进预测面。

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


# ── 表驱动打包/解包 ──

static func _pack(out: PackedByteArray, schema: Array, d: Dictionary) -> void:
	for f in schema:
		var t: String = f[1]
		var key: String = f[0]
		match t:
			T_F:
				_put_f(out, float(d.get(key, 0.0)))
			T_V2:
				var v: Vector2 = d.get(key, Vector2.ZERO)
				_put_f(out, v.x)
				_put_f(out, v.y)
			T_U8:
				_put_u8(out, int(d.get(key, 0)))
			T_I8:
				_put_i8(out, int(d.get(key, 0)))
			T_BOOL:
				out.append(1 if bool(d.get(key, false)) else 0)
			T_I32:
				_put_i32(out, int(d.get(key, 0)))
			T_TRAIL:
				_put_trail(out, d.get(key, []))


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
			T_TRAIL:
				d[key] = _rd_trail(r)
	return d


# 轨迹 = [[x, y], …](生产者:match_host._tick_beta_rewind,_rw_trail 按时间升序)。★ 线上只带最近 TRAIL_WIRE_MAX 个点(理由见该常量):取尾部(最新那段残像),多余的截断。
static func _put_trail(out: PackedByteArray, trail: Variant) -> void:
	var pts: Array = trail if trail is Array else []
	var n: int = mini(pts.size(), TRAIL_WIRE_MAX)
	_put_u8(out, n)
	for i in range(pts.size() - n, pts.size()):
		var p: Variant = pts[i]
		if p is Vector2:
			_put_f(out, p.x)
			_put_f(out, p.y)
		else:
			var a: Array = p
			_put_f(out, float(a[0]))
			_put_f(out, float(a[1]))


static func _rd_trail(r: Dictionary) -> Array:
	var n := mini(_rd_u8(r), TRAIL_MAX)
	var out: Array = []
	for i in n:
		out.append([_rd_f(r), _rd_f(r)])
	return out


# ── 定长读写(小端)── ★ StreamPeerBuffer 可用,但本仓既有的手打包先例是 map_format_v4 的 append 写法,这里沿用同一套:无额外类依赖(裁剪模板里没有它),变长字段也好写。

static func _put_u8(out: PackedByteArray, v: int) -> void:
	out.append(clampi(v, 0, 255))


static func _put_i8(out: PackedByteArray, v: int) -> void:
	out.append(clampi(v, -128, 127) & 0xFF)


static func _put_u32(out: PackedByteArray, v: int) -> void:
	for i in 4:
		out.append((v >> (i * 8)) & 0xFF)


static func _put_i32(out: PackedByteArray, v: int) -> void:
	_put_u32(out, v)


static func _put_f(out: PackedByteArray, v: float) -> void:
	# ★ 4.7.1 的 PackedByteArray.encode_float() 返回 void(就地写),不是返回新数组(Godot 4.2 的语义)—— 先 resize 再写,然后整段接上去。
	var tmp := PackedByteArray()
	tmp.resize(4)
	tmp.encode_float(0, v)
	out.append_array(tmp)


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
