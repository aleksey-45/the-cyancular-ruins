extends SceneTree

const EXPECTED_CHECKS := 6

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var world := _fixture_world()
	var own := _fixture_own()
	var inp := _fixture_input()
	var wb := NetCodec.encode_world(world)
	var ob := NetCodec.encode_own(own)
	var ib := NetCodec.encode_input(inp)

	_chk(wb[0] == NetCodec.PROTO_VERSION and ob[0] == NetCodec.PROTO_VERSION and ib[0] == NetCodec.PROTO_VERSION
			and wb[1] == NetCodec.KIND_WORLD and ob[1] == NetCodec.KIND_OWN and ib[1] == NetCodec.KIND_INPUT,
			"三 kind 版本字节必须同为 PROTO_VERSION(%d),种类字节分别为 WORLD/OWN/INPUT" % NetCodec.PROTO_VERSION)

	# ② 三 kind 坏包一律空(去掉什么才红:删 _header_ok 的版本/种类判据,或删尾部长度校验)
	# ★ v7 起 world/own 的 flags 字节必须恰为 FULL(1):把 flags 改坏也必须拒(否则"哪天真有别的形态"会被静默当成 FULL 解)。
	var wf := wb.duplicate()
	wf[2] = 0
	var of := ob.duplicate()
	of[2] = 0
	var bad := NetCodec.decode_world(_flip(wb)).is_empty() and NetCodec.decode_world(_cut(wb)).is_empty() \
			and NetCodec.decode_world(wf).is_empty() and NetCodec.decode_own(of).is_empty() \
			and NetCodec.decode_world(ob).is_empty() and NetCodec.decode_world(ib).is_empty() \
			and NetCodec.decode_own(_flip(ob)).is_empty() and NetCodec.decode_own(_cut(ob)).is_empty() \
			and NetCodec.decode_own(wb).is_empty() and NetCodec.decode_own(ib).is_empty() \
			and NetCodec.decode_input(_flip(ib)).is_empty() and NetCodec.decode_input(_cut(ib)).is_empty() \
			and NetCodec.decode_input(wb).is_empty() and NetCodec.decode_input(ob).is_empty()
	_chk(bad, "三 kind 坏包必须一律解码为空(翻版本 / 截断 1 B / 串种)")

	var wd := NetCodec.decode_world(wb)
	var od := NetCodec.decode_own(ob)
	var id := NetCodec.decode_input(ib)
	var rt := int(wd.get("tick", -1)) == int(world["tick"]) \
			and _world_same(world["players"], wd.get("players", {})) \
			and int(od.get("ack_seq", -1)) == int(own["ack_seq"]) \
			and int(od.get("q", -1)) == int(own["q"]) \
			and _dict_same(own["c2"], od.get("c2", {})) \
			and _input_same(inp, id) \
			and int(id.get("seq", 0)) == 123456 \
			and int(id.get("held", 0)) == 415 \
			and int(id.get("ct", 0)) == 12345678 \
			and int(id.get("st", 0)) == 987654321
	_chk(rt, "三 kind 往返逐字段一致(世界含混合 bool;本人整态;输入单记录 held u16/seq/st/ct)")

	var s5 := PacketInputSource.new()
	var hi5 := PacketInputSource.pack_record(s5, 7001, Vector2(1, 0), 111, 222)
	var d5 := NetCodec.decode_input(NetCodec.encode_input(hi5))
	var slot_ok := int(d5.get("seq", 0)) == 7001 and int(d5.get("st", 0)) == 111 and int(d5.get("ct", 0)) == 222
	_chk(slot_ok, "seq/st/ct 必须落在各自槽位(实得 seq=%d st=%d ct=%d)" % [int(d5.get("seq", 0)), int(d5.get("st", 0)), int(d5.get("ct", 0))])
	# ④ schema↔生产者逐键对齐(去掉什么才红:给 pack_record 加字段不登记 ⇒ 线上静默丢字段)
	var schema_keys := _schema_keys(NetCodec.INPUT_SCHEMA)
	var missing: Array = []
	var extra: Array = []
	for k in schema_keys:
		if not inp.has(k):
			missing.append(k)
	for k in inp:
		if not schema_keys.has(k):
			extra.append(k)
	_chk(missing.is_empty() and extra.is_empty(),
			"INPUT_SCHEMA 与 pack_record() 逐键对齐(表外未覆盖 %s / 表内多余 %s)" % [str(missing), str(extra)])

	var neg_world: Dictionary = (world as Dictionary).duplicate(true)
	var first_role: String = str((neg_world["players"] as Dictionary).keys()[0])
	(neg_world["players"][first_role] as Dictionary)["hp"] = -5
	var neg_rt := NetCodec.decode_world(NetCodec.encode_world(neg_world))
	_chk(int((((neg_rt.get("players", {}) as Dictionary).get(first_role, {}) as Dictionary).get("hp", -1))) == 0,
			"负 hp 编码钳到 0(不回绕 251 → 倒地血条不会变满)")

	print("[readout] 输入 %d B/包(一条 tick 记录,60Hz);世界 2 人共 %d B;本人包 %d B" % [
			ib.size(), wb.size(), ob.size()])

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET WIRE OK(%d 条断言):版本/种类头 · 坏包空 · 三 kind 往返 · 包级 seq/ct · schema 对齐" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("NET WIRE FAILED: %d 处" % _fails.size())
		quit(1)



func _fixture_world() -> Dictionary:
	var e1 := {
		"pos": Vector2(1234.567, -678.901), "vel": Vector2(300.25, -42.125),
		"facing": -1, "pose": 4, "type_id": 7, "hp": 49, "waterproof": 10,
		"downed": true, "aim": Vector2(0.6, -0.8),
		"previewing": true, "haste": false, "rewind": true,
		"trail": [[100.0, 200.0], [101.5, 201.5]],
	}
	var e2 := e1.duplicate(true)
	e2["pos"] = Vector2(5.5, 6.75)
	e2["downed"] = false
	e2["haste"] = true
	e2["rewind"] = false
	e2["trail"] = []
	return {"tick": 123456, "players": {"1": e1, "2": e2}}


func _fixture_own() -> Dictionary:
	var c2 := {
		"pos": Vector2(1234.567, -678.901), "vel": Vector2(-120.37, 0.4321),
		"facing": -1, "state": 4,
		"slock": 0.125, "coyote": 0.0625, "jbuf": 0.09375,
		"jcut": true, "squat": true, "charge": true,
		"ct": 0.5, "lmv_d": 1, "lmv_t": 0.3125,
		"wp": 10, "wp_t": 0.25, "wp_s": true, "wp_d": 0.1875,
		"clatch": true, "swim": true, "hp": 49,
		"ifr": 0.03125, "down": true,
		"knock": Vector2(-123.456, 78.9), "wslot": 3, "winst": 77,
		"fire_cd": 0.25, "aiming": true, "fire_buf": true,
		"aim_f": 1, "aim_cf": -1, "mag": 7, "rld": true, "rld_t": 0.125,
		"chg": 0.625, "trg": 0.1875,
		"inv": [{"type": 1, "inst": 77, "mag": 30}],
	}
	return {"ack_seq": 123456, "q": 5, "c2": c2}


func _fixture_input() -> Dictionary:
	var src := PacketInputSource.new()
	var rec := PacketInputSource.pack_record(src, 123456, Vector2(0.6, -0.8), 987654321, 12345678)
	rec["held"] = PacketInputSource.BIT_UP | PacketInputSource.BIT_DOWN | PacketInputSource.BIT_CHARGE \
			| PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD \
			| PacketInputSource.BIT_HASTE | PacketInputSource.BIT_REWIND
	rec["ax"] = -0.5
	rec["pressed"] = 3
	rec["released"] = 1
	rec["winst"] = 77
	return rec


func _flip(buf: PackedByteArray) -> PackedByteArray:
	var b := buf.duplicate()
	b[0] = (int(b[0]) + 1) & 0xFF
	return b


func _cut(buf: PackedByteArray) -> PackedByteArray:
	var b := buf.duplicate()
	b.resize(buf.size() - 1)
	return b



func _schema_keys(schema: Array) -> Array:
	var out: Array = []
	for f in schema:
		if f.size() > 2:
			for sub in f[2]:
				out.append(sub)
		else:
			out.append(f[0])
	return out


func _dict_same(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	var da: Dictionary = a
	var db: Dictionary = b
	if da.size() != db.size():
		return false
	for k in da:
		if not db.has(k) or not _same(da[k], db[k]):
			return false
	return true


func _world_same(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	var da: Dictionary = a
	var db: Dictionary = b
	if da.size() != db.size():
		return false
	for k in da:
		if not db.has(k):
			return false
		if not _world_field_same(String(k), da[k], db[k]):
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
			var pa2: Array = ta[i]
			var pb2: Array = tb[i]
			if pa2.size() != 2 or pb2.size() != 2:
				return false
			if absf(float(pa2[0]) - float(pb2[0])) > 0.2501 or absf(float(pa2[1]) - float(pb2[1])) > 0.2501:
				return false
		return true
	if k == "aim":
		var pa: Vector2 = a
		var pb: Vector2 = b
		var ua := pa.normalized() if not pa.is_zero_approx() else Vector2.RIGHT
		return absf(pb.length() - 1.0) <= 0.001 and ua.dot(pb) >= 0.9999
	if a is Dictionary and b is Dictionary:
		return _world_same(a, b)
	return _same(a, b)


func _input_same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if k == "aim":
			var pa: Vector2 = a[k]
			var pb: Vector2 = b[k]
			var ua := pa.normalized() if not pa.is_zero_approx() else Vector2.RIGHT
			if absf(pb.length() - 1.0) > 0.001 or ua.dot(pb) < 0.9999:
				return false
		elif not _same(a[k], b[k]):
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
