extends SceneTree
# 线格式守卫(NetCodec,三 kind:world / own / input)。存在理由逐条对应真实缺陷:
#   ① 三个 encode_* 各自写死版本/种类字节 ⇒ 版本号会漂(两份真相) ⇒ 断言①(三 kind 首字节同为 PROTO_VERSION、第二字节互异且正确)。
#   ② 解码守卫写松(不查版本/长度) ⇒ 错位值喂进权威模拟 = 静默分歧 ⇒ 断言②(三 kind 坏包一律空)。
#   ③ 编码侧手写内联、解码侧按 schema 表读 ⇒ 字段顺序/宽度/位打包漂移 ⇒ 断言③(三 kind 往返;含 held u16=415、混合 bool、st/ct 非零)。
#   ④ schema 与生产者脱钩(pack_pair 加字段不登记) ⇒ 该字段线上被静默丢掉 ⇒ 断言④(INPUT_SCHEMA ↔ pack_pair 逐键对齐)。
# ★ 与 snapshot_size_probe 的分工:那边量**体积/最坏包/容量**(场景探针,要真 Player);这里量**协议正确性**(纯逻辑 `-s`)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/net_wire_smoke.gd;通过 = NET WIRE OK(n 条断言)。

const EXPECTED_CHECKS := 4

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

	# ① 版本/种类头(去掉什么才红:某个 encode_* 把版本写成字面量 1/2,或 kind 写错)
	_chk(wb[0] == NetCodec.PROTO_VERSION and ob[0] == NetCodec.PROTO_VERSION and ib[0] == NetCodec.PROTO_VERSION
			and wb[1] == NetCodec.KIND_WORLD and ob[1] == NetCodec.KIND_OWN and ib[1] == NetCodec.KIND_INPUT,
			"三 kind 版本字节必须同为 PROTO_VERSION(%d),种类字节分别为 WORLD/OWN/INPUT" % NetCodec.PROTO_VERSION)

	# ② 三 kind 坏包一律空(去掉什么才红:删 _header_ok 的版本/种类判据,或删尾部长度校验)
	var bad := NetCodec.decode_world(_flip(wb)).is_empty() and NetCodec.decode_world(_cut(wb)).is_empty() \
			and NetCodec.decode_world(ob).is_empty() and NetCodec.decode_world(ib).is_empty() \
			and NetCodec.decode_own(_flip(ob)).is_empty() and NetCodec.decode_own(_cut(ob)).is_empty() \
			and NetCodec.decode_own(wb).is_empty() and NetCodec.decode_own(ib).is_empty() \
			and NetCodec.decode_input(_flip(ib)).is_empty() and NetCodec.decode_input(_cut(ib)).is_empty() \
			and NetCodec.decode_input(wb).is_empty() and NetCodec.decode_input(ob).is_empty()
	_chk(bad, "三 kind 坏包必须一律解码为空(翻版本 / 截断 1 B / 串种)")

	# ③ 三 kind 往返逐字段一致(去掉什么才红:字段顺序/宽度/位打包错位、丢字段;输入还要逐 tick 拆包正确)
	var wd := NetCodec.decode_world(wb)
	var od := NetCodec.decode_own(ob)
	var id := NetCodec.decode_input(ib)
	var recs := PacketInputSource.unpack_pair(id)
	var rt := int(wd.get("tick", -1)) == int(world["tick"]) \
			and _dict_same(world["players"], wd.get("players", {})) \
			and int(od.get("ack_seq", -1)) == int(own["ack_seq"]) \
			and int(od.get("q", -1)) == int(own["q"]) \
			and _dict_same(own["c2"], od.get("c2", {})) \
			and _dict_same(inp, id) \
			and recs.size() == 2 \
			and int(recs[0].get("seq", 0)) == int(inp["seq"]) - 1 \
			and int(recs[1].get("seq", 0)) == int(inp["seq"]) \
			and int(recs[0].get("ct", 0)) == int(inp["ct"]) - 1 \
			and int(recs[1].get("ct", 0)) == int(inp["ct"]) \
			and int(recs[0].get("held", 0)) == 415 and int(recs[1].get("held", 0)) == 257 \
			and int(recs[0].get("st", -1)) == 987654321 and int(recs[1].get("st", -1)) == 987654321
	_chk(rt, "三 kind 往返逐字段一致(世界含混合 bool;本人整态;输入两 tick 记录 + 拆包 seq/ct 连续)")

	# ④ schema↔生产者逐键对齐(去掉什么才红:给 pack_pair 加字段不登记 ⇒ 线上静默丢字段)
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
			"INPUT_SCHEMA 与 pack_pair() 逐键对齐(表外未覆盖 %s / 表内多余 %s)" % [str(missing), str(extra)])

	# 读数(不是断言):协议尺寸
	print("[readout] 输入 %d B/包(内含 2 条 tick 记录);世界 2 人共 %d B;本人包 %d B" % [
			ib.size(), wb.size(), ob.size()])

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET WIRE OK(%d 条断言):版本/种类头 · 坏包空 · 三 kind 往返 · schema 对齐" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("NET WIRE FAILED: %d 处" % _fails.size())
		quit(1)


# ── 夹具(硬编码的"丑数"+混合 bool:防止全 0/全 false 掩盖错位)──

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
	# 25 个 c2 标量 + 武器块 8 个 + inv(与 capture_state() 键集逐字对齐;不含 inv 的其余字段由 schema 决定)。
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
		"inv": [{"type": 1, "inst": 77, "mag": 30}],
	}
	return {"ack_seq": 123456, "q": 5, "c2": c2}


func _fixture_input() -> Dictionary:
	# 两条 tick 记录(值故意不同:held/ax/pressed/released/winst 全错开 ⇒ held0↔held1、ax0↔ax1 之类的错位必红)。
	var src := PacketInputSource.new()
	var lo := PacketInputSource.pack_record(src, 123455, Vector2(0.6, -0.8))
	lo["held"] = PacketInputSource.BIT_UP | PacketInputSource.BIT_DOWN | PacketInputSource.BIT_CHARGE \
			| PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD \
			| PacketInputSource.BIT_HASTE | PacketInputSource.BIT_REWIND   # 415:含 BIT_REWIND=256 ⇒ 必须 u16
	lo["ax"] = -0.5
	lo["pressed"] = 3
	lo["released"] = 1
	lo["winst"] = 77
	var hi := PacketInputSource.pack_record(src, 123456, Vector2(0.6, -0.8))
	hi["held"] = PacketInputSource.BIT_UP | PacketInputSource.BIT_REWIND   # 257
	hi["ax"] = 0.5
	hi["pressed"] = 8
	hi["released"] = 0
	hi["winst"] = 0
	return PacketInputSource.pack_pair(lo, hi, Vector2(0.6, -0.8), 987654321, 12345678)


func _flip(buf: PackedByteArray) -> PackedByteArray:
	var b := buf.duplicate()
	b[0] = (int(b[0]) + 1) & 0xFF
	return b


func _cut(buf: PackedByteArray) -> PackedByteArray:
	var b := buf.duplicate()
	b.resize(buf.size() - 1)
	return b


# ── 比对工具(schema 的 T_BOOLS 组:逻辑字段在第三元素里)──

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
