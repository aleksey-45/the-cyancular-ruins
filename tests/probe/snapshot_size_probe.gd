extends Node

# 快照体积/线格式探针(场景模式):把「一份快照到底多少字节、随人数怎么长」从估算变成实测,
# 并**同时量两种线格式**(Dictionary 直发 → `SnapshotCodec` 手打包)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/probe/snapshot_size_probe.tscn
# 期望:末行 "SNAPSHOT SIZE PROBE: ALL-OK"。
#
# 存在理由:`docs/royale-soak-2026-09-12.md` §2.2 实测「每人每快照 ≈0.96 KB」,但那是**整包**读数。
# 拆包(世界包 / 本人包)之后还需要知道"这 0.96 KB 里多少是 c2 权威整态、多少是渲染散字段",
# 以及**换成手打包线格式后还剩多少**。本探针就量这个,并给 N=2..8 的折算表与分片折算。
#
# ★ 它同时是**线格式的字段表判据**(见末尾 ①②③):`SnapshotCodec` 的 schema 必须与
#   `player.capture_state()` / `match_snapshot` 的字段表**逐键对齐** —— 少一个字段 ⇒
#   那个字段在线上被静默丢掉(客户端拿不到权威值,表现为"某个效果偶发不生效")。
#   ★ 这条判据的**道理**:本仓最大的病是"枚举会过期";编解码两侧共用一张表能防**顺序**漂移,
#     但防不了"表没跟上 producer" ⇒ 这里用**真实 producer** 的输出对表。
#
# ⚠ 判据 grep 文本 "SNAPSHOT SIZE PROBE: ALL-OK"(不只看退出码),并带**条数闸**(见 `_checks`)。
# ⚠ 本探针只量「载荷」,不含 ENet 分片头/RPC 方法名等固定开销(见末尾打印的备注)。

const MTU := 1400          # ENet 默认 MTU
const FRAG_HEADER := 8     # 分片包每片大致头部开销(粗估,用于折算片数)
const SNAP_HZ := 60        # SNAPSHOT_INTERVAL = 1/60

const EXPECTED_CHECKS := 3

var _failures: Array[String] = []
var _checks := 0
var _player: Node = null


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[size]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[size]   ✗ %s" % msg)


func _ready() -> void:
	var ts: PackedScene = load("res://scenes/player/player.tscn")
	_player = ts.instantiate()
	add_child(_player)          # _ready 跑完再取 capture_state
	# ★ 必须**显式装一把枪**:`capture_state()` 的武器块(8 个字段)**只有手持非空时才存在**
	#   (`player.gd` 的 `if w != null`)—— 不装的话本探针量到的本人包少 14 B,而且那 8 个字段的
	#   往返保真**一条都没验到**(实测:不装枪时 `present = 0/8`)。
	#   ★ 先 `inventory.add` 再 `equip_type`:`equip_type` 只从**已有背包**里找,不会凭空加枪(§4.5)。
	_player.weapons.inventory.add(1, 30)
	_player.weapons.equip_type(1)
	await get_tree().physics_frame
	# ★★ 让夹具的值**不是整数**(守卫灵敏度,2026-10-09 实测逼出来的):
	#   "编解码把值写错位/写有损"这一类缺陷,在**静止夹具**上**看不见** —— 位置/速度全是 0 或整数时,
	#   把 float32 载荷改成 0.5 步进(有损)**照样全绿**(变异实验实测)。
	#   这里给一组"丑数",让 ③ 那条往返断言真的能对值说话。
	#   ★ 只影响**值**,不影响**体积**(两边都是 float32)⇒ 探针的体积读数不受影响。
	_player.global_position = Vector2(1234.567, -678.901)
	_player.velocity = Vector2(-120.37, 0.4321)

	# ── 真实字段表(与 server/match/match_snapshot.gd 的 dict 逐字对齐)──
	var trail_pts: Array = [[100.0, 200.0], [101.5, 201.5]]
	var entry := _entry_world(trail_pts)
	var entry_no_trail := _entry_world([])
	var c2: Dictionary = _player.capture_state()

	var sz_old_entry := var_to_bytes(entry).size()
	var sz_old_own := var_to_bytes({"ack_seq": 12345, "c2": c2}).size()
	var wb := SnapshotCodec.encode_world({"tick": 12345, "players": {"1": entry, "2": entry, "3": entry}})
	var ob := SnapshotCodec.encode_own({"ack_seq": 12345, "q": 2, "c2": c2})
	var sz_new_entry := (wb.size() - 7) / 3        # 头 = 版本1 + 种类1 + tick4 + 人数1
	var sz_new_entry_nt := SnapshotCodec.encode_world(
			{"tick": 1, "players": {"1": entry_no_trail}}).size() - 7
	var sz_new_own := ob.size()

	print("[size] 世界包条目(13 字段)  旧(dict) = %d B  →  新(手打包) = %d B" % [sz_old_entry, sz_new_entry])
	print("[size]   ↳ 不在回溯时(空 trail)                        新 = %d B" % sz_new_entry_nt)
	print("[size] 本人包(ack + c2 整态)  旧(dict) = %d B  →  新(手打包) = %d B" % [sz_old_own, sz_new_own])
	print("[size] c2 字段数 = %d, 世界字段数 = %d" % [c2.size(), entry.size()])

	# ① 表必须**恰好**覆盖 `capture_state()` 的产出(少一个 = 该字段在线上被静默丢掉)
	# ② 反向:核心表的键必须**都在** c2 里(多一个 = 表里有 producer 从不产出的死字段)
	var missing: Array[String] = []
	var extra: Array[String] = []
	var weapon_keys := _schema_keys(SnapshotCodec.WEAPON_SCHEMA)
	var known := _schema_keys(SnapshotCodec.C2_SCHEMA)
	known.append("inv")
	for k in known:
		if not c2.has(k):
			extra.append(k)
	for k in c2:
		if not known.has(k) and not weapon_keys.has(k):
			missing.append(k)
	_check(missing.is_empty() and extra.is_empty(),
			"schema 与 capture_state() 逐键对齐(表外未覆盖 %s / 表内多余 %s)" % [str(missing), str(extra)])
	# ② 武器块是**整体存在/整体缺席**的(`capture_state` 里 `w != null` 才加那 8 个字段):
	#    半截存在 = 解码端按 flags 位读、读出来的字段对不上 → 必须红。
	var present := 0
	for k in weapon_keys:
		if c2.has(k):
			present += 1
	_check(present == 0 or present == weapon_keys.size(),
			"武器块必须整体存在或整体缺席(实得 %d/%d)" % [present, weapon_keys.size()])

	# ③ 往返保真:**用真实 producer 的输出**过一遍编解码,键集与值都必须回来
	var od := SnapshotCodec.decode_own(ob)
	var wd := SnapshotCodec.decode_world(wb)
	var d2: Dictionary = od.get("c2", {})
	var we: Dictionary = (wd.get("players", {}) as Dictionary).get("1", {})
	var rt_ok := _dict_same(c2, d2) and _dict_same(entry, we) and int(od.get("ack_seq", -1)) == 12345
	_check(rt_ok, "真实产出的往返逐字段一致(c2 %d/%d 键 · 世界 %d/%d 键 · ack=%s)" % [
			d2.size(), c2.size(), we.size(), entry.size(), str(od.get("ack_seq"))])

	print("[size] ── N 折算(单帧载荷 / 每秒单端下行 / 服务器每秒上行)──")
	print("[size]  N |        旧(dict):单帧  单端下行  服务器上行 |        新(codec):单帧  单端下行  服务器上行")
	# ★ 带上 12/16/24:royale 规模。世界包的分片悬崖现在在 N≈27(7+27×51=1384 < 1400)⇒ 只出这一张表。
	for n in [2, 4, 6, 8, 12, 16, 24]:
		_report(n, sz_old_own, sz_old_entry, sz_new_own, sz_new_entry)

	# ── 量化 / 增量的**上限测算**(★ 这是**算术测算**,不是已实现的代码;字段表直接取自 schema)──
	_report_headroom(trail_pts.size(), c2, entry)
	await _report_change_rate()

	_report_mtu(sz_old_entry, sz_new_entry)

	print("[size] 备注:以上均为**载荷**字节,不含 ENet 分片头与 RPC 方法名等固定开销;分片按 MTU=%d / 每片头 %d B 粗估。" % [MTU, FRAG_HEADER])
	print("[size] 注:退出时 Godot 会报少量 \"leaked at exit\"(在 _ready 里 quit 的探针都这样)。**不要**在这里显式 free。")

	if _checks != EXPECTED_CHECKS:
		_failures.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _failures.is_empty():
		print("SNAPSHOT SIZE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SNAPSHOT SIZE PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


# ── 真实字段表(逐字对照 match_snapshot._broadcast_snapshot 的 world["players"][role])──

func _entry_world(trail: Array) -> Dictionary:
	var p := _player
	# 是否正在预瞄(heavy_aim 蓄力)。★ 服务端仍带此字段,但客户端刻意**不消费**
	#   (用户裁定 2026-09-11:预瞄线只有使用者本人可见)。留着是日后换提示形式的接点。
	var previewing := false
	if p.weapons != null and p.weapons.current_weapon() != null:
		previewing = p.weapons.current_weapon().is_previewing()
	return {
		"pos": p.global_position,
		"vel": p.velocity,
		"facing": p.get_facing(),
		"pose": p.state,
		"type_id": p.weapons.current_type_id(),
		"hp": p.hp,
		"waterproof": p.waterproof,
		"downed": p.is_downed(),
		"aim": p.get_current_aim_dir(),
		"previewing": previewing,
		"haste": p.pvp_haste_mult > 1.0,
		"rewind": false,
		"trail": trail.duplicate(),
	}


# ★★ **`vel` 不是"可以去掉"的字段 —— 它现在是承重的,别照"瘦身版"去削包。**
#   `player_replica` 的补间形变(squash & stretch)整条链都读它:空中连续项直接取 `vel.y`,
#   落地推导还要"上一帧 `vel.y` 大 + 这一帧 `vel.y` ≈ 0"这一**对**值(见 `player_replica.gd`
#   的 `_prev_vel_y` / `LAND_VEL_EPS`)。**把 vel 从载荷里去掉 ⇒ 对手的形变与落地效果
#   一起静默失效**(空中项恒 0、落地项永不触发),不报错、也不会让本探针变红 ——
#   本探针**只打印,不断言** vel 的去留(刻意的:它量的是体积,不是行为)。
#   ⚠ 那条"唯一消费 vel 的是 `player.apply_server_snapshot`,该路径已随 C2 迁移删除"的旧理由
#     在 closeout 批 Task 4 之后**已反转** —— 想削包先读 `player_replica.gd`,不要只读本文件。
# ⇒ 本探针的"新格式"**带上 vel**(与源码同表),`vel` 自己占 8 B(2×float32)。


# ── 折算 ──

func _kb(b: int) -> String:
	return "%.2fKB" % (float(b) / 1024.0)


func _report(n: int, old_own: int, old_entry: int, new_own: int, new_entry: int) -> void:
	# 两种格式都是**同一个拆包结构**(世界包一次广播 + 本人包逐 peer 定向):
	#   服务器上行 = N × 本人包 + 1 × 世界包 ; 单端下行 = 本人包 + 世界包
	var old_world := n * old_entry
	var new_world := 7 + n * new_entry
	var old_up := float((n * old_own + old_world) * SNAP_HZ)
	var old_down := float((old_own + old_world) * SNAP_HZ)
	var new_up := float((n * new_own + new_world) * SNAP_HZ)
	var new_down := float((new_own + new_world) * SNAP_HZ)
	print("[size] %3d | %9s %9s %10s | %9s %9s %10s" % [
			n, _kb(old_own + old_world), _kb(int(old_down)), _kb(int(old_up)),
			_kb(new_own + new_world), _kb(int(new_down)), _kb(int(new_up))])


func _report_mtu(old_entry: int, new_entry: int) -> void:
	print("[size] ── 超 MTU 折算(ENet MTU=%d;超过即**不可靠分片**包,丢一片=整帧丢)──" % MTU)
	for n in [2, 5, 8]:
		var old_world: int = n * old_entry
		var new_world: int = 7 + n * new_entry
		print("[size]  N=%d: 世界包 旧 %s → %d 片 | 新 %s → %d 片" % [
				n, _kb(old_world), _frags(old_world), _kb(new_world), _frags(new_world)])
	for n in [2, 3, 4, 6, 8]:
		var new_world: int = 7 + n * new_entry
		print("[size]  新世界包仍在 1 片内?N=%d → %s" % [n, str(_frags(new_world) == 1)])


func _frags(payload: int) -> int:
	if payload <= MTU:
		return 1
	var usable := MTU - FRAG_HEADER
	return int(ceil(float(payload) / float(usable)))


# ── 量化 / 增量的上限测算 ──
# ★ 全部绑在 `SnapshotCodec` 的 schema 表上算,避免"另抄一份字段表"(那是本仓最贵的病)。
# ★ 这些是**算术上限**,不是实测到的收益;真正落不落地由"值不值得 + 风险"决定,见
#   [`docs/eng/netcode-snapshots.md`](../../docs/eng/netcode-snapshots.md) §5.1。

func _t_bytes(t: String, trail_n: int) -> int:
	match t:
		SnapshotCodec.T_F:
			return 4
		SnapshotCodec.T_V2:
			return 8
		SnapshotCodec.T_I32:
			return 4
		SnapshotCodec.T_TRAIL:
			return 1 + 8 * trail_n
	return 1   # U8 / I8 / BOOL


func _schema_bytes(schema: Array, trail_n: int) -> int:
	var n := 0
	for f in schema:
		n += _t_bytes(f[1], trail_n)
	return n


## 按字段名取字节(找不到返回 0)—— 让"某个字段组多少字节"始终跟着 schema 走。
func _field_bytes(schema: Array, name: String, trail_n: int) -> int:
	for f in schema:
		if f[0] == name:
			return _t_bytes(f[1], trail_n)
	return 0


func _mask_bytes(field_count: int) -> int:
	return int(ceil(float(field_count) / 8.0))


func _report_headroom(trail_n: int, c2: Dictionary, entry: Dictionary) -> void:
	var w := _schema_bytes(SnapshotCodec.WORLD_SCHEMA, trail_n)
	var c2s := _schema_bytes(SnapshotCodec.C2_SCHEMA, 0)
	var wpn := _schema_bytes(SnapshotCodec.WEAPON_SCHEMA, 0)
	var inv := 1 + 6 * (c2.get("inv", []) as Array).size()
	var own := 8 + c2s + wpn + inv          # 8 = 版本+种类+ack+q+flags
	print("[size] ── 上限测算(算术,不是已实现代码)──")
	var w_pv := _field_bytes(SnapshotCodec.WORLD_SCHEMA, "pos", trail_n) \
			+ _field_bytes(SnapshotCodec.WORLD_SCHEMA, "vel", trail_n)
	var w_aim := _field_bytes(SnapshotCodec.WORLD_SCHEMA, "aim", trail_n)
	var w_tr := _field_bytes(SnapshotCodec.WORLD_SCHEMA, "trail", trail_n)
	print("[size] 世界条目 %d B = pos %d + vel %d + aim %d + trail %d + 其余 %d(★ 线上另加 1 B 的 role)" % [
			w, _field_bytes(SnapshotCodec.WORLD_SCHEMA, "pos", trail_n),
			_field_bytes(SnapshotCodec.WORLD_SCHEMA, "vel", trail_n), w_aim, w_tr,
			w - w_pv - w_aim - w_tr])
	print("[size] 本人包 %d B = 头 8 + 核心 %d + 武器 %d + 背包 %d" % [own, c2s, wpn, inv])

	# ① 量化:只对**能安全量化**的量(渲染量)。pos 1/4px(9600px×4=38400<65536 ⇒ 2×u16)、
	#    vel 1/16px/s(2×i16)、aim 1 字节角度(256 向 ≈1.4° 分辨率)。
	var q_pos := 4
	var q_vel := 4
	var q_aim := 1
	var w_q := w - (_field_bytes(SnapshotCodec.WORLD_SCHEMA, "pos", trail_n) - q_pos) \
			- (_field_bytes(SnapshotCodec.WORLD_SCHEMA, "vel", trail_n) - q_vel) \
			- (_field_bytes(SnapshotCodec.WORLD_SCHEMA, "aim", trail_n) - q_aim)
	print("[size] 量化(世界):pos→2×u16、vel→2×i16、aim→1B 角度 ⇒ %d→%d B(−%d%%)" % [
			w, w_q, int(round(100.0 * (w - w_q) / float(w)))])
	# c2 侧只能动 pos/vel/knock(渲染/物理连续量);其余是**回滚锚点**,单方面量化 ⇒ 每次对账都判分歧。
	var c2_q := c2s - (_field_bytes(SnapshotCodec.C2_SCHEMA, "pos", 0) - q_pos) \
			- (_field_bytes(SnapshotCodec.C2_SCHEMA, "vel", 0) - q_vel) \
			- (_field_bytes(SnapshotCodec.C2_SCHEMA, "knock", 0) - q_pos)
	print("[size] 量化(本人):只动 pos/vel/knock ⇒ %d→%d B(−%d%%),★ 且必须**两端一起量化**" % [
			c2s + wpn + inv, c2_q + wpn + inv,
			int(round(100.0 * (c2s + wpn + inv - c2_q - wpn - inv) / float(c2s + wpn + inv)))])

	# ② 增量(变更位 = mask + 只发变了的字段;掩码 1 bit/字段)
	var wm := _mask_bytes(SnapshotCodec.WORLD_SCHEMA.size())
	var cm := _mask_bytes(SnapshotCodec.C2_SCHEMA.size() + SnapshotCodec.WEAPON_SCHEMA.size())
	var pv := w_pv
	print("[size] 增量(世界):掩码 %dB + 只发变了的字段 ⇒ 只 pos/vel 变 = %dB、pos/vel/aim 变 = %dB、全变 = %dB(退回绝对更好)" % [
			wm, wm + pv, wm + pv + w_aim, wm + w])
	var c_lean := 16 + 4 + 4 + 8   # pos/vel + fire_cd/rld_t/aim_f/aim_cf/mag/rld ≈ 4+4+8
	print("[size] 增量(本人):掩码 %dB ⇒ 只 pos/vel 变 = %dB(−%d%%);+ 开火/换弹那几个 = %dB(−%d%%)" % [
			cm, cm + 16, int(round(100.0 * (own - cm - 16) / float(own))),
			cm + c_lean, int(round(100.0 * (own - cm - c_lean) / float(own)))])
	print("[size] ★ 增量的大头在**本人包**:核心 %d B 里 pos/vel(16 B)每帧都变,其余大部分是慢变量;" % c2s)
	print("[size]   而世界包的大头(pos/vel/aim = %d B / %d B)**每帧都变** ⇒ 增量在世界包上省不了多少,量化才是那边的手段。" % [
			pv + _field_bytes(SnapshotCodec.WORLD_SCHEMA, "aim", trail_n), w])


# 变更率读数(**合成输入、不含战斗**):增量的收益取决于"每 tick 有几个字段真的变了",
# 这个数今天没有仪器测 ⇒ 先用真实物理步进 + 注入输入量一次,当作下界/参考。
# ★ 诚实标注:这是**探针里跑出来的玩家**(无关卡、靠重力下落 + 注入按键),不是真对局;
#   要定案得在真链路里读(见 netcode-snapshots.md §6)。
func _report_change_rate() -> void:
	var src := PacketInputSource.new()
	_player.set_input_source(src)
	var prev_c2: Dictionary = _player.capture_state()
	var prev_w := _entry_world([])
	var ticks := 30
	var w_sum := 0
	var c_sum := 0
	var w_max := 0
	var c_max := 0
	var w_fields := prev_w.size()
	var c_fields := prev_c2.size()
	for i in ticks:
		# 注入一串会动的输入:前 15 tick 按右,之后按住开火(边沿/按住都有)
		src.apply_packet({"seq": i, "ax": 1.0, "held": 8 if i >= 15 else 0,
				"pressed": 8 if i == 15 else 0, "released": 0, "winst": 0, "aim": Vector2(1.0, 0.0)})
		await get_tree().physics_frame
		var now_c2: Dictionary = _player.capture_state()
		var now_w := _entry_world([])
		var wc := _count_changed(prev_w, now_w)
		var cc := _count_changed(prev_c2, now_c2)
		w_sum += wc
		c_sum += cc
		w_max = maxi(w_max, wc)
		c_max = maxi(c_max, cc)
		prev_c2 = now_c2
		prev_w = now_w
	print("[size] 变更率(合成输入/无战斗,%d tick):世界 %d/%d 字段均变 %.1f、峰值 %d;本人 %d/%d 字段均变 %.1f、峰值 %d" % [
			ticks, w_sum, w_fields, float(w_sum) / float(ticks), w_max,
			c_sum, c_fields, float(c_sum) / float(ticks), c_max])
	print("[size]   ⇒ 每个 tick 真正变的字段数就是这个数;增量的收益 = 1 − (掩码 + 这些字段) / 全量。")


func _count_changed(a: Dictionary, b: Dictionary) -> int:
	var n := 0
	for k in a:
		if not b.has(k):
			n += 1
			continue
		if not _same(a[k], b[k]):
			n += 1
	return n


# ── 比对工具 ──

func _schema_keys(schema: Array) -> Array:
	var out: Array = []
	for f in schema:
		out.append(f[0])
	return out


# 逐键比:float 只求**近似相等**(GDScript 的 float 是 double,上线收成 float32 后展回来会差
# ~1e-7;这是**今天线上本来就有的**损失,不是本次改动引入的),其余类型求精确相等。
func _dict_same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if not _same(a[k], b[k]):
			return false
	return true


func _same(a: Variant, b: Variant) -> bool:
	if a is Vector2 or b is Vector2:
		return (a as Vector2).is_equal_approx(b)
	if a is float or b is float:
		return is_equal_approx(float(a), float(b))
	if a is Array or b is Array:
		var x: Array = a
		var y: Array = b
		if x.size() != y.size():
			return false
		for i in x.size():
			if not _same(x[i], y[i]):
				return false
		return true
	if a is Dictionary or b is Dictionary:
		return _dict_same(a, b)
	return a == b
