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

	# 判词:计数闸 —— 条数不符也红(防断言被静默跳过)。
	if _checks != 21:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED=21 对不上(要么有断言被静默跳过,要么新增没登记)" % _checks)
	if _fails.is_empty():
		print("SERVER INPUT SANITIZE OK(%d 条断言:轴钳位 11 + 队列有界与边沿 6 + 抖动缓冲 4)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("SERVER INPUT SANITIZE FAILED: %d 处" % _fails.size())
		quit(1)
