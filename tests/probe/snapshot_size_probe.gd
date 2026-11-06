extends Node

# 快照体积/线格式探针(场景模式):把「一份快照到底多少字节、随人数怎么长」从估算变成实测,并同时量两种线格式(Dictionary 直发 → NetCodec 手打包)。

const MTU := 1400
const FRAG_HEADER := 8
const SNAP_HZ := 60

const EXPECTED_CHECKS := 5

const WORLD_PACKET_BUDGET := 1400
const TRAIL_PHYSICAL_MAX := 10

var _failures: Array[String] = []
var _checks := 0
var _player: Node = null
var _entry_seq := 0


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
	add_child(_player)
	# ★ 必须显式装一把枪:capture_state() 的武器块(8 个字段)只有手持非空时才存在(player.gd 的 if w != null)—— 不装的话本探针量到的本人包少 14 B,而且那 8 个字段的往返保真一条都没验到(实测:不装枪时 present = 0/8)。
	#   ★ 先 inventory.add 再 equip_type:equip_type 只从已有背包里找,不会凭空加枪。
	_player.weapons.inventory.add(1, 30)
	_player.weapons.equip_type(1)
	await get_tree().physics_frame
	# ★★ 让夹具的值不是整数(守卫灵敏度,实测逼出来的):「编解码把值写错位/写有损」这一类缺陷在静止夹具上看不见 —— 位置/速度全是 0 或整数时,把 float32 载荷改成 0.5 步进(有损)照样全绿(变异实验实测)。
	#   这里给一组「丑数」,让 ③ 那条往返断言真的能对值说话。★ 只影响值、不影响体积(两边都是 float32)⇒ 体积读数不受影响。
	_player.global_position = Vector2(1234.567, -678.901)
	_player.velocity = Vector2(-120.37, 0.4321)

	var trail_pts: Array = [[100.0, 200.0], [101.5, 201.5]]
	var entry := _entry_world(trail_pts)
	var entry_no_trail := _entry_world([])
	var c2: Dictionary = _player.capture_state()
	# ★★ bool 组必须喂混合值(2026-10-24 加):全 false 的夹具下,标志字节的位映射写错也照样"往返一致"(实测 M4 变异抓不住)。
	for bk in ["jcut", "squat", "charge", "wp_s", "clatch", "swim", "down"]:
		if c2.has(bk):
			c2[bk] = true
	for wk in ["aiming", "fire_buf", "rld"]:
		if c2.has(wk):
			c2[wk] = true

	var sz_old_entry := var_to_bytes(entry).size()
	var sz_old_own := var_to_bytes({"ack_seq": 12345, "c2": c2}).size()
	var wb := NetCodec.encode_world({"tick": 12345, "players": {"1": entry, "2": entry, "3": entry}})
	var ob := NetCodec.encode_own({"ack_seq": 12345, "q": 2, "c2": c2})
	var sz_new_entry := (wb.size() - 8) / 3
	var sz_new_entry_nt := NetCodec.encode_world(
			{"tick": 1, "players": {"1": entry_no_trail}}).size() - 8
	var sz_new_own := ob.size()

	print("[size] 世界包条目(13 字段)  旧(dict) = %d B  →  新(手打包) = %d B" % [sz_old_entry, sz_new_entry])
	print("[size]   ↳ 不在回溯时(空 trail)                        新 = %d B" % sz_new_entry_nt)
	print("[size] 本人包(ack + c2 整态)  旧(dict) = %d B  →  新(手打包) = %d B" % [sz_old_own, sz_new_own])
	print("[size] c2 字段数 = %d, 世界字段数 = %d" % [c2.size(), entry.size()])

	# ① 表必须恰好覆盖 capture_state() 的产出(少一个 = 该字段在线上被静默丢掉);② 反向:核心表的键必须都在 c2 里(多一个 = 表里有 producer 从不产出的死字段)。
	var missing: Array[String] = []
	var extra: Array[String] = []
	var weapon_keys := _schema_keys(NetCodec.WEAPON_SCHEMA)
	var known := _schema_keys(NetCodec.C2_SCHEMA)
	known.append("inv")
	for k in known:
		if not c2.has(k):
			extra.append(k)
	for k in c2:
		if not known.has(k) and not weapon_keys.has(k):
			missing.append(k)
	_check(missing.is_empty() and extra.is_empty(),
			"schema 与 capture_state() 逐键对齐(表外未覆盖 %s / 表内多余 %s)" % [str(missing), str(extra)])
	var present := 0
	for k in weapon_keys:
		if c2.has(k):
			present += 1
	_check(present == 0 or present == weapon_keys.size(),
			"武器块必须整体存在或整体缺席(实得 %d/%d)" % [present, weapon_keys.size()])

	var od := NetCodec.decode_own(ob)
	var wd := NetCodec.decode_world(wb)
	var d2: Dictionary = od.get("c2", {})
	var we: Dictionary = (wd.get("players", {}) as Dictionary).get("1", {})
	var rt_ok := _dict_same(c2, d2) and _world_same(entry, we) and int(od.get("ack_seq", -1)) == 12345
	_check(rt_ok, "真实产出的往返逐字段一致(定点字段用容差:pos/vel ≤0.25、aim 点积 ≥0.9999;c2 %d/%d 键 · 世界 %d/%d 键 · ack=%s)" % [
			d2.size(), c2.size(), we.size(), entry.size(), str(od.get("ack_seq"))])

	var cap: int = LobbyRooms.ROYALE_MAX_PLAYERS
	var worst_players := {}
	for i in cap:
		worst_players[str(i + 1)] = _entry_world(_trail_pts(TRAIL_PHYSICAL_MAX))
	var worst_packet := NetCodec.encode_world({"tick": 0, "players": worst_players})
	var worst_bytes := worst_packet.size()
	_check(worst_bytes <= WORLD_PACKET_BUDGET,
			"最坏世界包(N=%d × trail %d 点)必须 ≤ %d B(实得 %d B = %d 片)" % [
					cap, TRAIL_PHYSICAL_MAX, WORLD_PACKET_BUDGET, worst_bytes, _frags(worst_bytes)])
	var worst_dec := NetCodec.decode_world(worst_packet)
	var expected := worst_players.duplicate(true)
	var last_pts := _trail_pts(TRAIL_PHYSICAL_MAX).slice(TRAIL_PHYSICAL_MAX - NetCodec.TRAIL_WIRE_MAX)
	for role in expected:
		(expected[role] as Dictionary)["trail"] = last_pts
	var worst_ok := not worst_dec.is_empty()
	if worst_ok:
		var dp: Dictionary = worst_dec.get("players", {})
		for role in expected:
			if not _world_same(expected[role], dp.get(role, {})):
				worst_ok = false
				break
	_check(worst_ok and (worst_dec.get("players", {}) as Dictionary).size() == cap,
			"最坏世界包必须能逐字段解码回来(N=%d;容量预算算错 = 写越界 + 尾部补 0 = 这里红)" % cap)
	print("[size] 最坏世界包读数:N=%d × trail %d 点 ⇒ %d B(%d 片,预算 %d B)" % [
			cap, TRAIL_PHYSICAL_MAX, worst_bytes, _frags(worst_bytes), WORLD_PACKET_BUDGET])

	print("[size] ── N 折算(单帧载荷 / 每秒单端下行 / 服务器每秒上行)──")
	print("[size]  N |        旧(dict):单帧  单端下行  服务器上行 |        新(codec):单帧  单端下行  服务器上行")
	for n in [2, 4, 6, 8, 12, 16, 24]:
		_report(n, sz_old_own, sz_old_entry, sz_new_own, sz_new_entry)

	_report_headroom(trail_pts.size(), c2, entry)

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


func _trail_pts(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append([1000.0 + float(i) * 3.5, 2000.0 - float(i) * 2.25])
	return out



func _entry_world(trail: Array) -> Dictionary:
	var p := _player
	_entry_seq += 1
	var s := _entry_seq
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
		"downed": s % 2 == 0,
		"aim": p.get_current_aim_dir(),
		"previewing": previewing or s % 3 == 0,
		"haste": s % 4 < 2,
		"rewind": s % 5 == 0,
		"trail": trail.duplicate(),
	}





func _kb(b: int) -> String:
	return "%.2fKB" % (float(b) / 1024.0)


func _report(n: int, old_own: int, old_entry: int, new_own: int, new_entry: int) -> void:
	var old_world := n * old_entry
	var new_world := 8 + n * new_entry
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
		var new_world: int = 8 + n * new_entry
		print("[size]  N=%d: 世界包 旧 %s → %d 片 | 新 %s → %d 片" % [
				n, _kb(old_world), _frags(old_world), _kb(new_world), _frags(new_world)])
	for n in [2, 3, 4, 6, 8]:
		var new_world: int = 8 + n * new_entry
		print("[size]  新世界包仍在 1 片内?N=%d → %s" % [n, str(_frags(new_world) == 1)])


func _frags(payload: int) -> int:
	if payload <= MTU:
		return 1
	var usable := MTU - FRAG_HEADER
	return int(ceil(float(payload) / float(usable)))


# ── 量化 / 体量的上限测算 ── ★ 全部绑在 NetCodec 的 schema 表上算,避免「另抄一份字段表」(那是本仓最贵的病)。
# ★ 这些是算术上限,不是实测到的收益;真正落不落地由「值不值得 + 风险」决定,见 docs/eng/netcode-snapshots.md §5.1。

func _t_bytes(t: String, trail_n: int) -> int:
	match t:
		NetCodec.T_F:
			return 4
		NetCodec.T_V2:
			return 8
		NetCodec.T_I32:
			return 4
		NetCodec.T_QV2:
			return 4
		NetCodec.T_QAIM:
			return 1
		NetCodec.T_FAIM:
			return 4
		NetCodec.T_TRAIL:
			return 1 + 4 * trail_n
	return 1


func _schema_bytes(schema: Array, trail_n: int) -> int:
	var n := 0
	for f in schema:
		n += _t_bytes(f[1], trail_n)
	return n


func _field_bytes(schema: Array, name: String, trail_n: int) -> int:
	for f in schema:
		if f[0] == name:
			return _t_bytes(f[1], trail_n)
	return 0


func _report_headroom(trail_n: int, c2: Dictionary, entry: Dictionary) -> void:
	var w := _schema_bytes(NetCodec.WORLD_SCHEMA, trail_n)
	var c2s := _schema_bytes(NetCodec.C2_SCHEMA, 0)
	var wpn := _schema_bytes(NetCodec.WEAPON_SCHEMA, 0)
	var inv := 1 + 6 * (c2.get("inv", []) as Array).size()
	var own := 13 + c2s + wpn + inv
	print("[size] ── 上限测算(算术;世界侧 P1 已落地、本人侧未落地)──")
	var w_pv := _field_bytes(NetCodec.WORLD_SCHEMA, "pos", trail_n) \
			+ _field_bytes(NetCodec.WORLD_SCHEMA, "vel", trail_n)
	var w_aim := _field_bytes(NetCodec.WORLD_SCHEMA, "aim", trail_n)
	var w_tr := _field_bytes(NetCodec.WORLD_SCHEMA, "trail", trail_n)
	print("[size] 世界条目 %d B = pos %d + vel %d + aim %d + trail %d + 其余 %d(★ 线上另加 1 B 的 role)" % [
			w, _field_bytes(NetCodec.WORLD_SCHEMA, "pos", trail_n),
			_field_bytes(NetCodec.WORLD_SCHEMA, "vel", trail_n), w_aim, w_tr,
			w - w_pv - w_aim - w_tr])
	print("[size] 本人包 %d B = 头 13 + 核心 %d + 武器 %d + 背包 %d" % [own, c2s, wpn, inv])

	var saved := (8 - _field_bytes(NetCodec.WORLD_SCHEMA, "pos", trail_n)) \
			+ (8 - _field_bytes(NetCodec.WORLD_SCHEMA, "vel", trail_n)) \
			+ (8 - _field_bytes(NetCodec.WORLD_SCHEMA, "aim", trail_n))
	print("[size] 量化(世界,**已落地**):pos %d B / vel %d B / aim %d B ⇒ 每条比 v4 省 %d B(方案与误差见 netcode-delta-and-quantization-details.md §6)" % [
			_field_bytes(NetCodec.WORLD_SCHEMA, "pos", trail_n),
			_field_bytes(NetCodec.WORLD_SCHEMA, "vel", trail_n), w_aim, saved])
	var c2_q := c2s - (_field_bytes(NetCodec.C2_SCHEMA, "pos", 0) - 4) \
			- (_field_bytes(NetCodec.C2_SCHEMA, "vel", 0) - 4) \
			- (_field_bytes(NetCodec.C2_SCHEMA, "knock", 0) - 4)
	print("[size] 量化(本人,**未落地**):只动 pos/vel/knock ⇒ %d→%d B(−%d%%),★ 且必须**两端一起量化**" % [
			c2s + wpn + inv, c2_q + wpn + inv,
			int(round(100.0 * (c2s + wpn + inv - c2_q - wpn - inv) / float(c2s + wpn + inv)))])


func _schema_keys(schema: Array) -> Array:
	var out: Array = []
	for f in schema:
		if f.size() > 2:
			for sub in f[2]:
				out.append(sub)
		else:
			out.append(f[0])
	return out


func _world_same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if not _world_field_same(String(k), a[k], b[k]):
			return false
	return true


func _world_field_same(k: String, a: Variant, b: Variant) -> bool:
	if k == "pos" or k == "vel":
		var va: Vector2 = a
		var vb: Vector2 = b
		return absf(va.x - vb.x) <= 0.2501 and absf(va.y - vb.y) <= 0.2501
	if k == "trail":
		if not (a is Array) or not (b is Array):
			return false
		var ta: Array = a
		var tb: Array = b
		if ta.size() != tb.size():
			return false
		for i in ta.size():
			var qa: Array = ta[i]
			var qb: Array = tb[i]
			if qa.size() != 2 or qb.size() != 2:
				return false
			if absf(float(qa[0]) - float(qb[0])) > 0.2501 or absf(float(qa[1]) - float(qb[1])) > 0.2501:
				return false
		return true
	if k == "aim":
		var pa: Vector2 = a
		var pb: Vector2 = b
		var ua := pa.normalized() if not pa.is_zero_approx() else Vector2.RIGHT
		return absf(pb.length() - 1.0) <= 0.001 and ua.dot(pb) >= 0.9999
	return _same(a, b)


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
