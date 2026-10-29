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

const PROTO_VERSION := 5
const KIND_WORLD := 1
const KIND_OWN := 2
const KIND_INPUT := 3

# ── 世界包两形态(v5):字节 2 = mode ─────────────────────────────────────────
# FULL  0:与 v4 布局同,仅多 mode 字节(头 2+1+tick4+人数1 = 8 B)。全量条目。
# DELTA 1:[tick u32][base u32][n_changed u8][n_gone u8] + 变更条目 + 消失名单。
#   变更条目 = [role u8][mask u16 LE] + mask 置位的字段(按 WORLD_SCHEMA 顺序,bit i ↔ schema[i];
#   新实体 = mask 全 1)。消失 = [role u8]×n_gone。
#   ★ 基线纪律:base 必须是「客户端已成功解码过」的 tick(上行 st);客户端只有 base ≤ 自己
#   已应用 tick 才能套用(覆盖语义收敛,见 wire.gd 的 _asm_* 注释),否则整包丢弃等全量兜底。
const WORLD_FULL := 0
const WORLD_DELTA := 1
# 周期全量兜底间隔(包数):delta 链路丢包/基线过期后最坏这么多包恢复全量。30Hz 下 15 包 = 0.5s。
const DELTA_FULL_EVERY := 15

# ── 类型字母 ──
const T_F := "f"      # float32,4 B(见文件头:与旧线上字节一致)
const T_V2 := "v2"    # 向量 = 2×float32,8 B
const T_U8 := "b"     # 0..255
const T_I8 := "c"     # -128..127(朝向这类 ±1 量)
# T_BOOLS:按记录把一组 bool 打包成 **1 B 标志字节**(bit0..bitN;第三元素 = 子字段名数组)。
# ★ 为什么不是跨字段位流:两者收益等价(世界条目 51→48 B、本人包 102→94 B),但标志字节不需要 bit 游标与 padding 校验,
#   解码也不会因为"尾部 padding 判据"制造误红/误绿;代价只是组内对齐浪费 ≤7 bit。
const T_BOOLS := "flag"
const T_I32 := "i"    # 32 位有符号(inst / seq / tick)
const T_U16 := "h"    # 0..65535(输入 held 位掩码:BIT_REWIND = 256 装不进 u8)
const T_TRAIL := "trail"

# 世界包每人一份(13 字段,顺序 = 线上顺序)。范围按产品常量钳:hp ≤ 50、waterproof ≤ 10、pose ≤ 4。
# ★ bool 组在前:线上 = role(1)+flag(1)+pos8+vel8+facing1+pose1+type_id1+hp1+waterproof1+aim8+trail(1+8n)
#   ⇒ trail 2 点 = **48 B**(改前 51 B);不在回溯 = 32 B。
const WORLD_SCHEMA: Array = [
	["_flags", T_BOOLS, ["downed", "previewing", "haste", "rewind"]],
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["pose", T_U8],
	["type_id", T_U8], ["hp", T_U8], ["waterproof", T_U8],
	["aim", T_V2], ["trail", T_TRAIL],
]

# 本人包的核心整态 = player.capture_state() 的 25 个标量字段(inv 另走 INV_SCHEMA,武器块另走 WEAPON_SCHEMA —— 后者可能不存在,靠 flags 位声明)。
# ★ c2 的 7 个 bool 打包成首字节标志 ⇒ 核心 67 B(改前 73 B)。
const C2_SCHEMA: Array = [
	["_flags", T_BOOLS, ["jcut", "squat", "charge", "wp_s", "clatch", "swim", "down"]],
	["pos", T_V2], ["vel", T_V2], ["facing", T_I8], ["state", T_U8],
	["slock", T_F], ["coyote", T_F], ["jbuf", T_F],
	["ct", T_F], ["lmv_d", T_I8], ["lmv_t", T_F], ["wp", T_U8], ["wp_t", T_F],
	["wp_d", T_F], ["hp", T_U8], ["ifr", T_F], ["knock", T_V2], ["wslot", T_U8],
	["winst", T_I32],
]

# 当前武器的字段(仅 `capture_state()` 里 `w != null` 时存在)。★ 3 个 bool 打包成首字节标志 ⇒ 12 B(改前 14 B)。
const WEAPON_SCHEMA: Array = [
	["_flags", T_BOOLS, ["aiming", "fire_buf", "rld"]],
	["fire_cd", T_F], ["aim_f", T_I8], ["aim_cf", T_I8], ["mag", T_U8], ["rld_t", T_F],
]

# 背包每一条(type/inst/mag —— 与 `weapon_inventory.snapshot()` 同源)。
const INV_SCHEMA: Array = [["type", T_U8], ["inst", T_I32], ["mag", T_U8]]

# 输入上行包(30Hz 一包,**内含连续两个物理 tick 的记录**;发送侧唯一来源 = PacketInputSource.pack_pair)。
# ★ 为什么是两条记录:本地预测按 60Hz 真输入跑(不锁存),服务器必须逐 tick 复现同一输入序列 ⇒ 一条记录 = 1 个 tick。
#   30Hz 包只负责装两 tick(共用 aim/st/ct 与包络),所以比"每 tick 一包"省一半包头/共享字段。
# ★ held 是位掩码:BIT_HASTE = 128、BIT_REWIND = 256 ⇒ 必须 u16(u8 会截断成 159)。
# ★ 低 tick 记录 = 上一包之后的那一 tick(流水线);seq(包级)= 高 tick 记录的 seq,低记录 seq = seq-1。
# st = 本端**最近成功解码**的服务器快照 tick;ct = 高 tick 的客户端物理帧号(低记录 ct = ct-1)。只落位,增量批才有消费者。
const INPUT_SCHEMA: Array = [
	["seq", T_I32],
	["held0", T_U16], ["held1", T_U16],
	["ax0", T_F], ["ax1", T_F],
	["pressed0", T_U8], ["pressed1", T_U8],
	["released0", T_U8], ["released1", T_U8],
	["winst0", T_I32], ["winst1", T_I32],
	["aim", T_V2], ["st", T_I32], ["ct", T_I32],
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

## 世界包(FULL):含(经兴趣管理过滤后的)玩家渲染字段全量。`{"tick": int, "players": {"role": {…}}}`。
## ★ 字段顺序/宽度必须与 WORLD_SCHEMA 一致(解码按 schema 读;漂移由 snapshot_size_probe ③ 抓)。
static func encode_world(world: Dictionary) -> PackedByteArray:
	var players: Dictionary = world.get("players", {})
	var n: int = mini(players.size(), 200)
	var out := PackedByteArray()
	out.resize(8 + n * _W_ENTRY_BYTES)   # 头 2+mode1+tick4+人数1;每人 = role 1 + schema 定长
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_WORLD
	i += 1
	out[i] = WORLD_FULL
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
		# bool 组(bit0 downed / bit1 previewing / bit2 haste / bit3 rewind)—— 见 WORLD_SCHEMA 的 T_BOOLS。
		out[i] = (1 if bool(e.get("downed", false)) else 0) \
				| (2 if bool(e.get("previewing", false)) else 0) \
				| (4 if bool(e.get("haste", false)) else 0) \
				| (8 if bool(e.get("rewind", false)) else 0)
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
		var aim: Vector2 = e.get("aim", Vector2.ZERO)
		out.encode_float(i, aim.x)
		i += 4
		out.encode_float(i, aim.y)
		i += 4
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


## 世界包(DELTA):对 base(= 客户端已解码的那一 tick 的**同口径视图**)求差。
## 返回空数组 = 差不出/基线不可用,调用方回落 FULL。mask 全 1 = 新实体(AOI 进入/刚连上)。
static func encode_world_delta(now: Dictionary, base: Dictionary) -> PackedByteArray:
	var base_players: Dictionary = base.get("players", {})
	var now_players: Dictionary = now.get("players", {})
	if base_players.is_empty() and not now_players.is_empty():
		return PackedByteArray()   # 无基线 ⇒ 全量
	var full_mask := (1 << WORLD_SCHEMA.size()) - 1
	var masks: Dictionary = {}
	for key in now_players:
		var e: Dictionary = now_players[key]
		var b: Dictionary = base_players.get(key, {})
		if b.is_empty():
			masks[key] = full_mask
		else:
			var m := 0
			for fi in WORLD_SCHEMA.size():
				var f: Array = WORLD_SCHEMA[fi]
				if not _field_eq(f, e.get(f[0]), b.get(f[0])):
					m |= 1 << fi
			masks[key] = m
	var gone: Array = []
	for key in base_players:
		if not now_players.has(key):
			gone.append(int(key))
	# 变更体先攒进 body(mask/变长字段拿不准容量),头定长 13 B 最后写死再拼 —— 两段式避免
	# 「按最坏容量 resize 过的数组上 append_array 接到尾巴再被截短」那种错位。
	var body := PackedByteArray()
	var n_changed := 0
	for key in now_players:
		var m: int = masks[key]
		if m == 0:
			continue   # 没变也没消失的实体不上线(tick 仍在头里 ⇒ 客户端播放时钟照常前进)
		n_changed += 1
		body.append(int(key) & 0xFF)
		body.append(m & 0xFF)
		body.append((m >> 8) & 0xFF)
		var e: Dictionary = now_players[key]
		for fi in WORLD_SCHEMA.size():
			if m & (1 << fi) == 0:
				continue
			_pack_field(body, WORLD_SCHEMA[fi], e)
	for r in gone:
		body.append(r & 0xFF)
	var out := PackedByteArray()
	out.resize(13)
	out[0] = PROTO_VERSION
	out[1] = KIND_WORLD
	out[2] = WORLD_DELTA
	out.encode_u32(3, int(now.get("tick", 0)))
	out.encode_u32(7, int(base.get("tick", 0)))
	out[11] = n_changed
	out[12] = gone.size()
	out.append_array(body)
	return out


## 单字段按 schema 打包(mask 置位的那些;bool 组整组一个字节,trail = 计数 + 点)。
static func _pack_field(out: PackedByteArray, f: Array, e: Dictionary) -> void:
	match f[1]:
		T_BOOLS:
			var fb := 0
			var subs: Array = f[2]
			for bi in subs.size():
				fb |= (1 << bi) if bool(e.get(subs[bi], false)) else 0
			out.append(fb)
		T_V2:
			var v: Vector2 = e.get(f[0], Vector2.ZERO)
			out.append_array(_f2b(v))
		T_U8, T_I8:
			out.append(int(e.get(f[0], 0)) & 0xFF)
		T_TRAIL:
			var t: Array = e.get(f[0], [])
			var tn := mini(t.size(), TRAIL_WIRE_MAX)
			out.append(tn)
			for k in range(t.size() - tn, t.size()):
				var p: Variant = t[k]
				if p is Vector2:
					out.append_array(_f2b(p as Vector2))
				else:
					var a: Array = p
					out.append_array(_f2b(Vector2(float(a[0]), float(a[1]))))


static func _f2b(v: Vector2) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_float(0, v.x)
	b.encode_float(4, v.y)
	return b


## 线值等价比较:delta 的"变没变"必须按**线上能表达出的值**比(64 位相等 ⇒ 32 位线值必等 ⇒
## 漏不掉真变化;反之偶尔多发一个本就相等的字段,无害)。trail 两种元素形态(Vector2/[x,y])归一后比。
static func _field_eq(f: Array, a: Variant, b: Variant) -> bool:
	match f[1]:
		T_V2:
			return a is Vector2 and b is Vector2 and (a as Vector2) == (b as Vector2)
		T_TRAIL:
			var ta: Array = a if a is Array else []
			var tb: Array = b if b is Array else []
			if ta.size() != tb.size():
				return false
			for k in ta.size():
				var pa := _pt(ta[k])
				var pb := _pt(tb[k])
				if pa != pb:
					return false
			return true
		_:
			return a == b


static func _pt(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	var a: Array = v
	return Vector2(float(a[0]), float(a[1]))


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
	# c2 的 bool 组(bit0 jcut / 1 squat / 2 charge / 3 wp_s / 4 clatch / 5 swim / 6 down)。
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
	out[i] = int(c2.get("hp", 0)) & 0xFF
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
		# 武器块 bool 组(bit0 aiming / bit1 fire_buf / bit2 rld),后面是其余字段。
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


## 输入包:30Hz 一包,内含连续两个物理 tick 的记录(高 tick 的 seq = 包级 seq,低 tick = seq-1)。
## `{"seq","held0","held1","ax0","ax1","pressed0","pressed1","released0","released1","winst0","winst1","aim","st","ct"}`
## 头 2 B + 记录 44 B = **46 B**(改前:30Hz 单条锁存记录 = 34 B;7 键 Dictionary 时代 = 164 B/包)。
## ★ 顺序/宽度必须与 INPUT_SCHEMA 一致(漂移由 net_wire_smoke 的往返抓)。
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
	var h0 := int(pkt.get("held0", 0))
	out[i] = h0 & 0xFF
	i += 1
	out[i] = (h0 >> 8) & 0xFF
	i += 1
	var h1 := int(pkt.get("held1", 0))
	out[i] = h1 & 0xFF
	i += 1
	out[i] = (h1 >> 8) & 0xFF
	i += 1
	out.encode_float(i, float(pkt.get("ax0", 0.0)))
	i += 4
	out.encode_float(i, float(pkt.get("ax1", 0.0)))
	i += 4
	out[i] = int(pkt.get("pressed0", 0)) & 0xFF
	i += 1
	out[i] = int(pkt.get("pressed1", 0)) & 0xFF
	i += 1
	out[i] = int(pkt.get("released0", 0)) & 0xFF
	i += 1
	out[i] = int(pkt.get("released1", 0)) & 0xFF
	i += 1
	out.encode_u32(i, int(pkt.get("winst0", 0)))
	i += 4
	out.encode_u32(i, int(pkt.get("winst1", 0)))
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

## base = 客户端已应用的整态 {"tick", "players"}(不传 = 无基线 ⇒ DELTA 一律解为空丢弃)。
## DELTA 只有 base["tick"] ≥ 包内 base_tick 时才套用(覆盖语义:同一基线的多次差分,最新一份
## 覆盖出精确的当前整态;base 落后于自己已应用的 tick 也安全,见 wire.gd 的 _asm 注释)。
static func decode_world(data: PackedByteArray, base: Dictionary = {}) -> Dictionary:
	if not _header_ok(data, KIND_WORLD):
		return {}
	var mode := data[2] if data.size() > 2 else -1
	var r := {"d": data, "o": 3, "bad": false}
	if mode == WORLD_DELTA:
		return _decode_world_delta(r, data, base)
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


static func _decode_world_delta(r: Dictionary, data: PackedByteArray, base: Dictionary) -> Dictionary:
	var tick := _rd_u32(r)
	var base_tick := _rd_u32(r)
	var n_changed := _rd_u8(r)
	var n_gone := _rd_u8(r)
	# 基线两拒:没有基线 / 基线比客户端已应用的还新(乱序或错位)⇒ 整包丢弃,等周期全量兜底。
	if base.is_empty() or int(base.get("tick", 0)) < base_tick:
		return {}
	var players: Dictionary = (base.get("players", {}) as Dictionary).duplicate(true)
	for i in n_changed:
		var role := _rd_u8(r)
		var m := _rd_u16(r)
		var entry: Dictionary = players.get(str(role), {})
		for fi in WORLD_SCHEMA.size():
			if m & (1 << fi) == 0:
				continue
			var f: Array = WORLD_SCHEMA[fi]
			match f[1]:
				T_BOOLS:
					var fb := _rd_u8(r)
					var subs: Array = f[2]
					for bi in subs.size():
						entry[subs[bi]] = (fb & (1 << bi)) != 0
				T_V2:
					entry[f[0]] = Vector2(_rd_f(r), _rd_f(r))
				T_U8:
					entry[f[0]] = _rd_u8(r)
				T_I8:
					entry[f[0]] = _rd_i8(r)
				T_TRAIL:
					var tn := mini(_rd_u8(r), TRAIL_MAX)
					var t: Array = []
					for k in tn:
						t.append([_rd_f(r), _rd_f(r)])
					entry[f[0]] = t
		players[str(role)] = entry
	for i in n_gone:
		var g := _rd_u8(r)
		players.erase(str(g))
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
			T_BOOLS:
				# 一组 bool 共用一个标志字节(bit0..bitN;子字段名在 schema 第三元素)。
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
			T_BOOLS:
				n += 1
			T_U8, T_I8:
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
