class_name NetCodec
extends RefCounted

# 线格式:把载荷从 Dictionary 换成手打包的 PackedByteArray(快照 + 输入共用一套版本字节与 schema 表)。原先每个字段都要在线上带键名字符串(每帧重复)+ 4 字节类型标签 ——
# 实测同一份 8 字段数据:dict(键)= 196 B vs 手打包 = 24 B ⇒ 键 + 类型标签才是大头,不是数值本身;换掉后 N=8 世界包 2.1 KB → 0.27 KB(不再分片)、本人包 588 B → ~114 B。
# ── 2026-10-26 P1(PROTO_VERSION 4→5)字段定点化:上行 aim → 2×i16(1e-4 定点),下行 pos/vel → 2×i16(0.5px 步长)、aim → u8 角度。
#   量化必须两端**同版一起换**(版本字节守门);本人包 c2 仍是 float32 全量 —— 它是 C2 回滚锚点,单方面量化 ⇒ 每次重放都判分歧。★ 定点常量/误差见 Q_* 与文档 §6。
# ── 2026-10-30 P2(PROTO_VERSION 6→7):① **DELTA 机制整体删除**(生产 2026-10-28 已回退全量,差分只剩探针在养 ⇒ 线格式真相从 3 份回到 1 份);
#   ② **trail 改 2×i16**(Q_SCALE,0.5px 步长):它是唯一没量化、也是世界包里最大的一坨变长字段 —— 4 点 8B→4B,
#   最坏世界包 791→536 B、回溯时 536→408 B。两端必须同版发布(旧客户端被版本字节拒绝)。
# ── 2026-11-01(PROTO_VERSION 7→8):输入上行改 **60Hz 一包一条记录**(原 30Hz 一包两条);下行不变。
# ── 版本字节:首字节 = PROTO_VERSION,两端不同版时大声失败(解码返回空字典、调用方不 emit + 客户端 claim 握手拒绝),而不是按错位的偏移读出垃圾值。
#   ★ 载荷里每个字节位置都是协议:改字段顺序/类型/宽度 = 改协议,两端必须同版本。
# ── 输入包(KIND_INPUT)也走这里:同一套版本字节 + schema 表。类名保留 NetCodec —— 它现在是**全项目**线格式编解码器(快照 + 输入)。
# ── ★★ 2026-10-24 编码侧性能:解码仍**表驱动**(`_unpack` 按 schema 读,不可信输入必须逐字段守边界),但**编码侧改成手写内联**
#   (`out.encode_float(i,v)` / 直接下标写),不再每字段调一个静态函数、不再经 schema 的 `match`/`dict.get` 双重派发。实测(N=16):
#   表驱动 ~304 µs/包 → 内联 ~47 µs/包(一次性量具 .superpowers/net/encode_profile.gd;同文件还量过「只 resize」= 0.2 µs ⇒ 瓶颈是每字段的
#   GDScript 调用,不是分配)。★ 代价 = 编码侧的字段顺序/宽度与 schema **成了两份**:漂移由 `snapshot_size_probe` 的往返判据 ③ 抓
#   (解码按 schema 读 ⇒ 顺序/宽度错 = 解出来的值必不对,立刻红),容量用 `_schema_bytes()` 预算(少算 ⇒ 越界/尺寸错,④ 最坏包抓)。
#   ⇒ 改 schema 必须同步改三个 encode_*;不改就一定红,不会静默。

const PROTO_VERSION := 8   # 2026-11-01:输入上行改 60Hz 单记录包(原 30Hz 一包两条)
const KIND_WORLD := 1
const KIND_OWN := 2
const KIND_INPUT := 3

# flags 字节:世界包 / 本人包各占 1 B,**今天恒 = FULL**(1)。★ 2026-10-30 删掉 DELTA 之后它不再有第二种取值;
# 仍保留这 1 B 是为了不动已稳定的头部布局(v6 的 FULL 包逐字节形状不变),将来要用再定义位(现在**不许**按位读)。
const W_FULL := 1
const OW_FULL := 1


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
const T_TRAIL := "trail"   # 回溯点序列:1 B 点数 + n × 2×i16(Q_SCALE 定点;2026-10-30 从 2×float32 换掉)
# P1 定点类型(尺寸进 _schema_bytes,编解码见 encode_world / encode_input / _unpack)。
const T_QV2 := "qv2"    # 定点向量:2×int16,步长 0.5 px(世界 pos/vel,4 B)
const T_QAIM := "qaim"  # 瞄准方向角:u8(0..255 → 0..2π,世界 aim,1 B)
const T_FAIM := "faim"  # 单位向量定点:2×int16(/10000,输入 aim,4 B)

# ── 定点量化常量(单一来源;真相源 = docs/eng/netcode-delta-and-quantization-details.md §6)──
# ★ 位置/速度的步长不是 0.1px:i16 只有 ±32767,而最宽地图 9600px ×10 = 96000 装不下 ⇒ 取 0.5px(9600×2 = 19200,留 2.4× 余量到 16383px)。
#   两者共用同一步长:速度的视觉敏感度远低于位置,0.25px/s 的误差不可见。★ trail(纯表现)复用同一步长。
const Q_SCALE := 2.0          # 世界 pos/vel/trail:1 单位 = 0.5 px(0.5 px/s);量化误差 ≤0.25
const Q_VEL_CLAMP := 6000.0   # 速度钳 ±6000 px/s(×2 = ±12000,仍在 i16 内;超界钳位不 wrap)
const Q_AIM_STEPS := 256.0    # 世界 aim:u8 角度(方向误差 ≤π/256 ≈0.70°)
const AIM_FP := 10000.0       # 输入 aim:单位向量的 1e-4 定点(误差 ≤1e-4,解码后 normalize)

# 世界包每人一份(13 字段,顺序 = 线上顺序)。范围按产品常量钳:hp ≤ 50、waterproof ≤ 10、pose ≤ 4。
# ★ v7 线上 = role(1)+flag(1)+pos4+vel4+facing1+pose1+type_id1+hp1+waterproof1+aim1+trail(1+4n)
#   ⇒ trail 2 点 = **25 B**(v6 = 33 B)、不在回溯 = 17 B。pos/vel/trail = i16 定点(Q_SCALE)、aim = u8 角度。
const WORLD_SCHEMA: Array = [
	["_flags", T_BOOLS, ["downed", "previewing", "haste", "rewind"]],
	["pos", T_QV2], ["vel", T_QV2], ["facing", T_I8], ["pose", T_U8],
	["type_id", T_U8], ["hp", T_U8], ["waterproof", T_U8],
	["aim", T_QAIM], ["trail", T_TRAIL],
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
# ★ 武器块"整体存在/整体缺席":存在性由本人包头的 FLAG_WEAPON 位声明(包恒为 FULL,不存在"字段消失"的差分包问题)。
const WEAPON_SCHEMA: Array = [
	["_flags", T_BOOLS, ["aiming", "fire_buf", "rld"]],
	["fire_cd", T_F], ["aim_f", T_I8], ["aim_cf", T_I8], ["mag", T_U8], ["rld_t", T_F],
]

# 背包每一条(type/inst/mag —— 与 `weapon_inventory.snapshot()` 同源)。
const INV_SCHEMA: Array = [["type", T_U8], ["inst", T_I32], ["mag", T_U8]]

# 输入上行包(60Hz 一包一条记录;发送侧唯一来源 = PacketInputSource.pack_record → InputWire.pack_record)。
# ★ 为什么是两条记录:本地预测按 60Hz 真输入跑(不锁存),服务器必须逐 tick 复现同一输入序列 ⇒ 一条记录 = 1 个 tick。
#   30Hz 包只负责装两 tick(共用 aim/st/ct 与包络),所以比"每 tick 一包"省一半包头/共享字段。
# ★ held 是位掩码:BIT_HASTE = 128、BIT_REWIND = 256 ⇒ 必须 u16(u8 会截断成 159)。
# ★ 低 tick 记录 = 上一包之后的那一 tick(流水线);seq(包级)= 高 tick 记录的 seq,低记录 seq = seq-1。
# st = 本端**最近成功解码**的服务器快照 tick(命中回放的时间基准,见 match_combat._replay_hurt_rect);ct = 高 tick 的客户端物理帧号(低记录 ct = ct-1;仍只落位)。
# aim = 世界坐标瞄准方向,单位向量 1e-4 定点(2×i16);两条记录共用。
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

# 解码侧硬顶:载荷里的长度是不可信输入(一个坏字节不该让解码端循环 255 次分配)。★ 它与发送侧上限 TRAIL_WIRE_MAX 不是同一个东西 —— 那个是"线上只带几点"的取舍。
const TRAIL_MAX := 16

# 线上最多带几个回溯点(取最近的;多余的截断、不报错):世界包必须装进一个 ENet 包,而 trail 是这个包里唯一的变长字段 ——
# 16 人 × 物理上限(10 点)在 v7 是 8 + 16×73 = 1176 B ⇒ 1 片;v6(float32 trail)同形是 1559 B ⇒ 2 片(分片是 unreliable ⇒ 丢一片 = 整帧丢)。
# 4 点 ⇒ 8 + 16×33 = 536 B(v6 791 B、P1 前 1031 B;留 62% 余量),残像只少最老的几个点。★ 判据在 tests/probe/snapshot_size_probe.gd ④,改这个数必须先跑它。
const TRAIL_WIRE_MAX := 4

# 编码容量预算(类加载时算一次,不每包遍历 schema):仍是 `_schema_bytes()` 派生 ⇒ 改 schema 自动跟上,不手抄数字。
static var _INV_ENTRY_BYTES := _schema_bytes(INV_SCHEMA)
static var _INPUT_BYTES := 2 + _schema_bytes(INPUT_SCHEMA)
# ★ S-24(2026-10-30):世界/本人包的容量预算也缓存一次。原先 `_schema_bytes(WORLD_SCHEMA)` 每包现算(遍历 schema 字典),
#   而它只随 schema 变化 ⇒ 与 _INV_ENTRY_BYTES 同款在类加载时算。
static var _WORLD_ENTRY_BYTES := _schema_bytes(WORLD_SCHEMA)
static var _OWN_BYTES := 12 + 1 + _schema_bytes(C2_SCHEMA) + _schema_bytes(WEAPON_SCHEMA) + 1


# ── 编码(2026-10-24:手写内联)── ★ 一次性按 `_schema_bytes()` 预算容量 `resize`,然后全部就地写(`encode_s16`/`encode_float`/`encode_u32`/下标),
# 末尾 `resize(i)` 收尾。实测 304 → 47 µs/包(N=16)。★ 定点字段的判据是 snapshot_size_probe 的尺寸 + 往返容差 + 最坏包。
# ★ v7 起**没有差分包**了:世界包/本人包都只有一个 encode 路径;flags 字节恒 = FULL。

## 世界包:`{"tick": int, "players": {"role": {…13 字段}}}`。pos/vel/trail 走定点(常量见 Q_*)、aim 走 u8 角度。
## ★ 字段顺序/宽度必须与 WORLD_SCHEMA 一致(解码按 schema 读;漂移由 snapshot_size_probe ③ 抓)。
static func encode_world(world: Dictionary) -> PackedByteArray:
	var players: Dictionary = world.get("players", {})
	var n: int = mini(players.size(), 200)
	var out := PackedByteArray()
	# 头 = 版本1+kind1+flags1+tick4+人数1 = 8(flags 恒 FULL);每人 role1 + 条目体。
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
		# ★ 与容量预算对齐:`resize` 按 `mini(players.size(), 200)` 算,循环**必须**同顶 ——
		#   旧写法只约束 resize、循环不封顶,玩家数 >200 时下标写越界 ⇒ 包被截断、解码端 `o != size` 判死(整帧丢)。
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


# 世界条目全字段(FULL 唯一形态)。返回新游标。
static func _write_world_entry_body(out: PackedByteArray, i: int, e: Dictionary) -> int:
	# bool 组(bit0 downed / bit1 previewing / bit2 haste / bit3 rewind)—— 见 WORLD_SCHEMA 的 T_BOOLS。
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
	# ★ hp 必须钳到 [0,255]:倒地瞬间 hp 可为负(如 -5),& 0xFF 会回绕成 251 ⇒ 血条被钳成满(真实 bug)。
	out[i] = clampi(int(e.get("hp", 0)), 0, 255)
	i += 1
	out[i] = int(e.get("waterproof", 0)) & 0xFF
	i += 1
	# aim 是方向 ⇒ 只存角度(u8):零向量按 RIGHT(atan2(0,0)=0)处理,语义上"无瞄准"本来就会回落到朝向。
	var aim: Vector2 = e.get("aim", Vector2.ZERO)
	out[i] = int(roundf(atan2(aim.y, aim.x) / TAU * Q_AIM_STEPS)) & 0xFF
	i += 1
	# trail:纯表现(他人回溯残像)⇒ 复用 Q_SCALE 定点(0.5px 步长、误差 ≤0.25,视觉不可辨);
	# ★ 2026-10-30 起不再是 float32 —— 它是世界包里最大的一坨变长字段,量化后最坏包 791→536 B。
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


## 本人包:`{"ack_seq": int, "q": int, "c2": capture_state(), "tick": int}`。
## 头 12 B(版本/kind/flags/tick/ack/q)+ 1 B 武器标志 + c2 全字段 + 武器块(可选)+ inv。
## ★ 字段顺序/宽度必须与 C2_SCHEMA / WEAPON_SCHEMA / INV_SCHEMA 一致(漂移由 snapshot_size_probe ③ 抓)。
static func encode_own(own: Dictionary) -> PackedByteArray:
	var c2: Dictionary = own.get("c2", {})
	var inv: Array = c2.get("inv", [])
	var n_inv: int = mini(inv.size(), 200)
	var out := PackedByteArray()
	# 容量按最坏算(头 12 + 武器标志 1 + 全字段 + inv);末尾 resize(i) 裁尾。
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
	# 服务器侧该 role 的待消费队列深度(判据用:见 docs/eng/netcode-snapshots.md §6)。
	out[i] = int(own.get("q", 0)) & 0xFF
	i += 1
	i = _write_own_body(out, i, c2)
	out.resize(i)
	return out


# 本人包体(武器标志 + c2 全字段 + inv,布局 = C2_SCHEMA / WEAPON_SCHEMA / INV_SCHEMA)。
static func _write_own_body(out: PackedByteArray, i: int, c2: Dictionary) -> int:
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
	# 同 world.hp:倒地后 hp 可能为负,& 0xFF 会回绕 ⇒ c2 重放/血条读到 251。钳到 0。
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


## 输入包:60Hz 一包一条 tick 记录(seq/held/ax/pressed/released/winst/aim/st/ct)。
## `{"seq","held0","held1","ax0","ax1","pressed0","pressed1","released0","released1","winst0","winst1","aim","st","ct"}`
## 头 2 B + 记录 40 B = **42 B**(P1 前 46 B;7 键 Dictionary 时代 164 B/包)。
## ★ aim = 单位向量 1e-4 定点(2×i16);顺序/宽度必须与 INPUT_SCHEMA 一致(漂移由 net_wire_smoke 的往返抓)。
static func encode_input(pkt: Dictionary) -> PackedByteArray:
	# 一条 tick 记录 = 2 B 头 + 26 B(PROTO_VERSION 8);60Hz 发包 ⇒ ≈1.68 KB/s/客户端。
	var out := PackedByteArray()
	out.resize(_INPUT_BYTES)
	var i := 0
	out[i] = PROTO_VERSION
	i += 1
	out[i] = KIND_INPUT
	i += 1
	out.encode_u32(i, int(pkt.get("seq", 0)))
	i += 4
	var held := int(pkt.get("held", 0))   # u16:BIT_REWIND=256 必须留高位
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
# ★ 解码保持**表驱动**(`_unpack`):解码侧是不可信输入,逐字段守边界;且 schema 是"字段集合"的单一来源(probe 的逐键对齐判据也读它)。

static func decode_world(data: PackedByteArray) -> Dictionary:
	if not _header_ok(data, KIND_WORLD):
		return {}
	var r := {"d": data, "o": 2, "bad": false}
	# flags 必须恰为 FULL(v7 没有第二种取值;别的位 = 不是本版本载荷 ⇒ 拒)。
	if _rd_u8(r) != W_FULL:
		return {}
	var tick := _rd_u32(r)
	var n := _rd_u8(r)
	var players := {}
	for i in n:
		var role := _rd_u8(r)
		# ★ 不往条目里塞 role:它就是 players 的键(消费方一律 players.get(str(role))),塞进去会让解码结果比原 dict 多一个键。
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
		# 保持 [x, y] 数组形态(客户端按 pt[0]/pt[1] 下标读);值 = i16/Q_SCALE(0.5px 网格)。
		out.append([_rd_i16(r) / Q_SCALE, _rd_i16(r) / Q_SCALE])
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


# ── 定长读(小端,游标 + 越界守卫)──
# ★ 多字节数一律走 PackedByteArray 内置 `decode_*`(内核就是小端,与旧手拼 `lo | hi << 8` 逐字节同值):
#   手拼只留在**编码侧** —— 那是实测 304 → 47 µs/包 的那步优化(见文件头);解码侧没有这个理由。
# ★ 内置 `decode_*` 越界会**引擎报错**(手写版只会安静读出垃圾)⇒ 读之前必须过长度守卫;守卫语义与旧手写版
#   逐字对齐:越界 ⇒ `bad = true` + 返 0(整个包被 decode_* 丢弃,不崩、不刷屏)。

# 统一长度守卫:吃掉 n 字节并返回字段起始下标;越界 ⇒ bad=true + 返 -1(调用方据此返 0)。
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