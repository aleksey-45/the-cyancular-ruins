extends SceneTree
# 服务端输入收口的判据(协议健壮性,不是反作弊:伪造合法范围内包的恶意客户端不在防护目标内)。
# ① 轴值钳位:ax 协议上无界(ax=50 ≈ 35000px/s,全图才 9600px);NAN/INF 必须先判有限性再钳到 0
#    (clampf 对 NaN 的行为不能假设),否则原样穿过。② 队列有界:ρ≈1 的零漂移随机游走没有回复力就会被
#    顶上去永久停住 ⇒ 上限跟实测抖动包络走、能缩回去,丢包还要保住 just_pressed/winst 边沿。纯函数(sanitize_axis /
#    push_pending)⇒ 不碰真服务器/7777,可进默认 headless 批;通过 = SERVER INPUT SANITIZE OK。

var _fails: Array[String] = []
var _checks := 0

func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	_chk(PacketInputSource.sanitize_axis(-1.0) == -1.0, "sanitize_axis(-1) 应原样返回 -1")
	_chk(PacketInputSource.sanitize_axis(0.0) == 0.0, "sanitize_axis(0) 应原样返回 0")
	_chk(PacketInputSource.sanitize_axis(1.0) == 1.0, "sanitize_axis(1) 应原样返回 1")
	_chk(PacketInputSource.sanitize_axis(0.5) == 0.5, "sanitize_axis(0.5) 应原样返回 0.5")
	_chk(PacketInputSource.sanitize_axis(-0.25) == -0.25, "sanitize_axis(-0.25) 应原样返回 -0.25")
	# 越界必须钳到 ±1、非有限值必须变 0(去掉 clampf 或去掉有限性判断 ⇒ 下面这六条红;NaN 会原样穿过去)
	_chk(PacketInputSource.sanitize_axis(50.0) == 1.0, "sanitize_axis(50) 应钳到 1")
	_chk(PacketInputSource.sanitize_axis(-50.0) == -1.0, "sanitize_axis(-50) 应钳到 -1")
	_chk(PacketInputSource.sanitize_axis(1.5) == 1.0, "sanitize_axis(1.5) 应钳到 1")
	_chk(PacketInputSource.sanitize_axis(NAN) == 0.0, "sanitize_axis(NAN) 应变 0")
	_chk(PacketInputSource.sanitize_axis(INF) == 0.0, "sanitize_axis(INF) 应变 0")
	_chk(PacketInputSource.sanitize_axis(-INF) == 0.0, "sanitize_axis(-INF) 应变 0")

	var q: Array = []
	for i in 200:
		PacketInputSource.push_pending(q, {"seq": i, "ax": 0.5, "pressed": 0, "released": 0, "winst": 0})
	_chk(q.size() <= PacketInputSource.QUEUE_CAP_MAX,
			"灌 200 包后队列长度必须 ≤ 上限(实得 %d / 上限 %d)" % [q.size(), PacketInputSource.QUEUE_CAP_MAX])
	while not q.is_empty():
		q.pop_front()
	_chk(q.is_empty(), "停止灌入后队列应能被抽干")
	# ★ 承重:被丢掉的第一包带着边沿 ⇒ 边沿必须并进新队首(pressed 第 0 位)
	var q2: Array = []
	PacketInputSource.push_pending(q2, {"seq": 0, "ax": 0.0, "pressed": 1, "released": 0, "winst": 7})
	for i in range(1, PacketInputSource.QUEUE_CAP_MAX + 1):
		PacketInputSource.push_pending(q2, {"seq": i, "ax": 0.0, "pressed": 0, "released": 0, "winst": 0})
	_chk((int(q2[0].get("pressed", 0)) & 1) == 1,
			"第 0 包的 just_pressed 边沿必须活到队首(丢掉它 = 偶发丢一跳)")
	_chk(int(q2[0].get("winst", 0)) == 7,
			"第 0 包的切枪请求(winst)也必须活到队首(否则那一跳的换枪静默丢失)")
	_chk(q2.size() == PacketInputSource.QUEUE_CAP_MAX,
			"边界:恰好等于上限时不应再丢(实得 %d)" % q2.size())
	var q3: Array = []
	PacketInputSource.push_pending(q3, {"seq": 0, "ax": 0.0, "pressed": 3, "released": 4, "winst": 5})
	_chk(q3.size() == 1 and int(q3[0].get("pressed", 0)) == 3 and int(q3[0].get("released", 0)) == 4,
			"未触发上限时不许动包(pressed/released 原样)")

	# 小抖动:留最小缓冲 + 1 包余量(去掉 clampi 的下界 ⇒ 缩到 0/1,一 tick 到两包就丢)
	_chk(PacketInputSource.adapted_cap(0) == PacketInputSource.QUEUE_CAP_MIN
			and PacketInputSource.adapted_cap(3) == 4,
			"上限 = 包络 + 1,且不低于最小缓冲(0→%d, 3→%d)" % [
					PacketInputSource.adapted_cap(0), PacketInputSource.adapted_cap(3)])
	# 大抖动:不许超硬顶(去掉上界 ⇒ 一次 200 包的突刺把上限顶到 200,回到无界的老问题)
	_chk(PacketInputSource.adapted_cap(99) == PacketInputSource.QUEUE_CAP_MAX,
			"包络再大也不许超硬顶(%d)" % PacketInputSource.QUEUE_CAP_MAX)
	# ★ 承重:返回值必须是丢之前的原始深度(包络靠它学习);返回丢完的深度 ⇒ 上限只降不升(改用 q.size() 就让这条红)。
	var q4: Array = []
	var raw4 := 0
	for i in 4:
		raw4 = PacketInputSource.push_pending(q4, {"seq": i, "ax": 0.0, "pressed": 0, "released": 0, "winst": 0}, 2)
	_chk(raw4 == 3 and raw4 > 2 and q4.size() == 2,
			"返回值是丢之前的原始深度、可以超过上限(实得 %d,队内 %d)" % [raw4, q4.size()])
	# ★ 承重:"上限缩回去"就是那个缺失的回复力 —— 队里堆着 6 包、上限收到 2 ⇒ 必须一次释放 4 包(去掉 cap 参数、退回写死 8 ⇒ 这条红)。
	var q5: Array = []
	for i in 6:
		PacketInputSource.push_pending(q5, {"seq": i, "ax": 0.0, "pressed": 0, "released": 0, "winst": 0}, 8)
	var released := PacketInputSource.push_pending(q5,
			{"seq": 6, "ax": 0.0, "pressed": 0, "released": 0, "winst": 0}, 2)
	_chk(q5.size() == 2 and released == 7,
			"上限收到 2 时积压必须被释放(队内 %d,丢前 %d;堆在队里 = 延迟不恢复)" % [q5.size(), released])

	# ── 输入包线格式(NetCodec.KIND_INPUT):三条,各自的红线写在注释里 ──
	# ① schema 与生产者逐键对齐:去掉什么才红 = 给 pack_record 加字段不登记 / INPUT_SCHEMA 写错键(本仓最贵的病:字段在线上被静默丢掉)
	var src := PacketInputSource.new()   # PlayerInput extends RefCounted ⇒ -s 里可 new
	var pkt := PacketInputSource.pack_record(src, 7, Vector2(0.6, -0.8), 1234, 5678)
	var schema_keys: Array = []
	for f in NetCodec.INPUT_SCHEMA:
		schema_keys.append(f[0])
	var missing: Array = []
	var extra: Array = []
	for k in schema_keys:
		if not pkt.has(k):
			missing.append(k)
	for k in pkt:
		if not schema_keys.has(k):
			extra.append(k)
	_chk(missing.is_empty() and extra.is_empty(),
			"INPUT_SCHEMA 与 pack_record() 逐键对齐(表外未覆盖 %s / 表内多余 %s)" % [str(missing), str(extra)])
	# ② 真实产出往返 + 位宽:去掉什么才红 = held 用 u8(415 截断成 159)/ st、ct 漏进 schema(白丢 4 B 字段)/ 编解码任一侧写错位
	var full := PacketInputSource.pack_record(src, 123456, Vector2(0.6, -0.8), 987654321, 12345678)
	full["held"] = PacketInputSource.BIT_UP | PacketInputSource.BIT_DOWN | PacketInputSource.BIT_CHARGE \
			| PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD \
			| PacketInputSource.BIT_HASTE | PacketInputSource.BIT_REWIND      # 415(含 BIT_REWIND=256 ⇒ u8 必截断)
	var back := NetCodec.decode_input(NetCodec.encode_input(full))
	var rt_ok := not back.is_empty()
	for k in full:
		if not back.has(k):
			rt_ok = false
			continue
		var a: Variant = full[k]
		var b: Variant = back[k]
		if a is Vector2:
			if not (a as Vector2).is_equal_approx(b):
				rt_ok = false
		elif a is float:
			if not is_equal_approx(float(a), float(b)):
				rt_ok = false
		elif a != b:
			rt_ok = false
	_chk(rt_ok and int(back.get("held", 0)) == 415 and int(back.get("st", -1)) == 987654321
			and int(back.get("ct", -1)) == 12345678,
			"真实产出往返逐键一致(held 必须 = 415 —— u8 会截成 159;st/ct 必须原样回来)")
	# ③ 坏包必须返回空:去掉什么才红 = 删版本/长度守卫 ⇒ 错位值被喂进服务器模拟(静默分歧,不报错)
	var fine: PackedByteArray = NetCodec.encode_input(pkt)
	print("[readout] 输入包编码后 %d B/包(改前 7 键 Dictionary ≈164 B,30Hz ⇒ 1.0 KB/s/客户端)" % fine.size())
	var good: PackedByteArray = fine
	var flipped: PackedByteArray = good.duplicate()
	flipped[0] = (int(flipped[0]) + 1) & 0xFF
	var truncated: PackedByteArray = good.duplicate()
	truncated.resize(good.size() - 5)
	var world_bytes := NetCodec.encode_world({"tick": 1, "players": {}})
	_chk(NetCodec.decode_input(flipped).is_empty() and NetCodec.decode_input(truncated).is_empty()
			and NetCodec.decode_input(world_bytes).is_empty(),
			"坏包一律解码为空(翻版本字节 / 截断 5 B / 拿世界包冒充输入包 ⇒ 三条都要 {})")

	# 判词:计数闸 —— 条数不符也红(防断言被静默跳过)。
	if _checks != 24:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED=24 对不上(要么有断言被静默跳过,要么新增没登记)" % _checks)
	if _fails.is_empty():
		print("SERVER INPUT SANITIZE OK(%d 条断言:轴钳位 11 + 队列有界与边沿 6 + 抖动缓冲 4 + 输入线格式 3)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("SERVER INPUT SANITIZE FAILED: %d 处" % _fails.size())
		quit(1)
