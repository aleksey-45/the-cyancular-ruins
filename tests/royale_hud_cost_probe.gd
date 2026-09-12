extends Node

# 大乱斗排行榜重建成本探针(场景模式):把"每秒卡一下"归因到具体一行代码。
# 跑法:
#   "$GODOT" --headless --path . res://tests/royale_hud_cost_probe.tscn
# 期望:每条 [hudcost] … 通过,末行 "ROYALE HUD COST PROBE: ALL-OK"。
#
# 存在理由:6 人压力跑里,所有客户端**每秒**都卡 50~60ms,时间点严格落在 1.0s 整数倍上 ——
# 正是 RoyaleHost.HUD_SYNC_INTERVAL 的 round_state 广播周期。本探针把相机挪近:
# 单独建一个 RoyaleHud,按真实节奏(每帧一次、帧间让 queue_free 结算)喂 N 行 round_state,
# 量每次 `_on_round_state` 的墙钟耗时。
#
# ⚠ 它量的是 **headless 下**的成本。headless 用 dummy renderer,但 TextServer 照常
#   shape/rasterize 字形 —— 真机的渲染侧开销既可能更大(要画)也可能更小(字形已缓存)。
#   故本探针的结论只能写成"客户端侧确有 N ms 的每秒重建成本",不能写成"真机就卡这么多"。
#
# ⚠ 判据 grep 文本 "ROYALE HUD COST PROBE: ALL-OK"(不只看退出码)。
#
# 两条断言分开看:
#   ① **结构**(硬断言):排行榜行 Label 必须被**复用** —— 每秒重建 N 个 Label 是纯浪费,
#      实测同步成本 2.6/3.8/4.7 ms(4/6/8 行)。判据是"行 Label 的 instance_id 跨多次更新不变"
#      (重建的话每次都是新 id)。这条不看时间,不受机器负载影响,是**可靠的回归守卫**。
#   ② **耗时**(读数 + 宽松门槛):中位必须 < 一帧预算(16.7ms)。门槛刻意不设在 1ms ——
#      本探针是"归因工具",不是"逼这行代码变快"的指标。

const ROWS := [4, 6, 8]
const SAMPLES := 40

var _fail := false


func _ready() -> void:
	print("[hudcost] 逐行数测 `_on_round_state` 的重建耗时(headless;每次调用之间让一帧,与真实 1Hz 节奏同形)")
	for n in ROWS:
		await _measure(n)
	if _fail:
		print("ROYALE HUD COST PROBE: FAIL")
		get_tree().quit(1)
	else:
		print("ROYALE HUD COST PROBE: ALL-OK")
		get_tree().quit(0)


func _measure(n: int) -> void:
	var hud := RoyaleHud.new()
	add_child(hud)
	await get_tree().process_frame
	var payload := _payload(n)
	# 预热 3 次(首次要建字形的缓存,不是稳态成本)
	for _i in range(3):
		hud._on_round_state(payload)
		await get_tree().process_frame
	var ids0 := _row_ids(hud)
	var us: Array = []
	for _i in range(SAMPLES):
		await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		hud._on_round_state(payload)
		us.append(Time.get_ticks_usec() - t0)
	us.sort()
	var median: float = float(us[us.size() / 2]) / 1000.0
	var p95: float = float(us[int(0.95 * float(us.size()))]) / 1000.0
	var worst: float = float(us[-1]) / 1000.0
	print("[hudcost]   %d 行:中位 %.2f ms,p95 %.2f ms,最坏 %.2f ms(%d 次)" % [
			n, median, p95, worst, SAMPLES])
	# ① 结构:行 Label 被复用(重建的话 instance_id 每次都变)
	var ids1 := _row_ids(hud)
	_check(ids0.size() == n and ids1 == ids0,
			"%d 行:排行榜行 Label 被复用而非每次重建(%d 行,id 序列%s)" % [
					n, ids1.size(), "一致" if ids1 == ids0 else "**变了 = 又回到每秒重建**"])
	# 文字仍要跟着数据走:改比分后再喂一次,该行文字必须变
	var p2: Dictionary = payload.duplicate(true)
	(p2["scores"] as Dictionary)[1] = 99
	hud._on_round_state(p2)
	await get_tree().process_frame
	var top: Label = hud._rows[0] if not hud._rows.is_empty() else null
	_check(top != null and top.text.contains("99"),
			"复用行仍然更新文字(榜首文字=%s)" % ("(空)" if top == null else top.text))
	# ② 耗时:稳态中位必须在**一帧预算**内。超了就是"每秒必掉一帧"。
	if median >= 16.7:
		_fail = true
		print("[hudcost]   ✗ %d 行中位耗时已超一帧预算(%.2f ms)" % [n, median])
	hud.queue_free()
	await get_tree().process_frame


func _row_ids(hud) -> Array:
	var out: Array = []
	for l in hud._rows:
		out.append(l.get_instance_id())
	return out


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[hudcost]   ✓ %s" % msg)
	else:
		_fail = true
		print("[hudcost]   ✗ %s" % msg)


func _payload(n: int) -> Dictionary:
	var names := {}
	var scores := {}
	var deaths := {}
	var alive := {}
	for i in range(n):
		var role := i + 1
		names[role] = "BOT%d" % role
		scores[role] = i % 5
		deaths[role] = i % 3
		alive[role] = true
	return {"state": 1, "scores": scores, "names": names, "alive": alive, "left": [],
			"deaths": deaths, "timer": 60.0, "rounds_won": {}}
