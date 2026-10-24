extends SceneTree
# 输入队列守卫(PacketInputSource 纯逻辑;`-s` 可跑,不碰服务器/7777)。四个判定类别各一条:
#   ① 轴收口:ax 协议上无界(ax=50 ≈ 35000px/s,全图才 9600px),非有限值必须先判有限性再钳到 0 —— 否则原样穿过。
#   ② 有界 + 丢最旧 + 保边沿:队列是带反射壁的随机游走,无界 ⇒ 积压不可恢复;丢包必须把 pressed/released/winst 边沿并进队首。
#   ③ 回复力:上限跟着抖动包络走、能自己缩回 ⇒ 网络安静时把堆着的陈旧记录释放掉(这是原设计缺失的那一环)。
#   ④ 上限钳位:不缩到 1(一 tick 到两包就丢)也不超硬顶(回到无界老问题)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/input_queue_smoke.gd;通过 = INPUT QUEUE OK(n 条断言)。

const EXPECTED_CHECKS := 4

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _pkt(seq: int, pressed: int = 0, winst: int = 0) -> Dictionary:
	return {"seq": seq, "ax": 0.0, "pressed": pressed, "released": 0, "winst": winst}


func _initialize() -> void:
	# ① 轴收口(去掉什么才红:删 clampf ⇒ 越界穿过;删有限性判断 ⇒ NaN 原样穿过)
	var ax_ok := PacketInputSource.sanitize_axis(-1.0) == -1.0 \
			and PacketInputSource.sanitize_axis(0.5) == 0.5 \
			and PacketInputSource.sanitize_axis(50.0) == 1.0 \
			and PacketInputSource.sanitize_axis(-50.0) == -1.0 \
			and PacketInputSource.sanitize_axis(NAN) == 0.0 \
			and PacketInputSource.sanitize_axis(INF) == 0.0
	_chk(ax_ok, "轴收口:合法值原样、越界钳 ±1、NaN/INF → 0")

	# ② 有界/丢最旧/保边沿(去掉什么才红:删 while 上限 ⇒ 灌 200 变 200;删边沿合并 ⇒ 偶发丢一跳/丢换枪)
	var q: Array = []
	var raw := 0
	for i in 200:
		raw = PacketInputSource.push_pending(q, _pkt(i), PacketInputSource.QUEUE_CAP_MAX)
	var bounded := q.size() == PacketInputSource.QUEUE_CAP_MAX and raw > PacketInputSource.QUEUE_CAP_MAX
	var q2: Array = []
	PacketInputSource.push_pending(q2, _pkt(0, 1, 7))
	for i in range(1, PacketInputSource.QUEUE_CAP_MAX + 1):
		PacketInputSource.push_pending(q2, _pkt(i))
	var edges := (int(q2[0].get("pressed", 0)) & 1) == 1 and int(q2[0].get("winst", 0)) == 7
	_chk(bounded and edges,
			"有界:灌 200 后 ≤ 上限且返回值是丢前深度(实得 %d/%d);边沿:被丢包的 pressed/winst 必须活到队首" % [q.size(), raw])

	# ③ 回复力(去掉什么才红:退回写死 cap 8 ⇒ 积压永远不释放)
	var q3: Array = []
	for i in 6:
		PacketInputSource.push_pending(q3, _pkt(i), 8)
	var released := PacketInputSource.push_pending(q3, _pkt(6), 2)
	_chk(q3.size() == 2 and released == 7,
			"回复力:上限收到 2 时 7 条积压必须一次释放到 2(队内 %d,丢前 %d)" % [q3.size(), released])

	# ④ 上限钳位(去掉什么才红:删下界 ⇒ cap=1 一 tick 到两包就丢;删上界 ⇒ 突刺把上限顶到无界)
	_chk(PacketInputSource.adapted_cap(0) == PacketInputSource.QUEUE_CAP_MIN
			and PacketInputSource.adapted_cap(3) == 4
			and PacketInputSource.adapted_cap(99) == PacketInputSource.QUEUE_CAP_MAX,
			"上限钳位:0→%d、3→4、99→%d(包络+1 且夹在 [MIN,MAX])" % [
					PacketInputSource.adapted_cap(0), PacketInputSource.adapted_cap(99)])

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("INPUT QUEUE OK(%d 条断言):轴收口 · 有界+边沿 · 回复力 · 上限钳位" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("INPUT QUEUE FAILED: %d 处" % _fails.size())
		quit(1)
