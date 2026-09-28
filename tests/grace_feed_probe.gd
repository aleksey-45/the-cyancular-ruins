extends Node

# `grace` 字段进 `round_state` 的**载荷面守卫**(阶段 3,spec §4 的 3.1)。场景模式、headless。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/grace_feed_probe.tscn
# 判据:末行 `GRACE FEED PROBE: ALL-OK`。
#
# ═══ 为什么不能用源码断言代替 ═══
# "三个生产者调了 `_send_round_state`"是**文本**判据(写在 tests/reconnect_status_probe 里),
# 它拦不住"并进去的时机/条件写错了"(比如空表也带键、或者读的是别的字段)。本探针真建一个
# `MatchHost`(**role_peers 传空** —— 同 `match_host_hygiene_probe` 的手法:不建玩家、不排
# peer、所有 rpc_id 静默早退),用**子类覆写 `_rpc_all`** 截获真正要发出去的那份载荷
# (同 `stats_delivery_probe` 的手法),在**调用时刻**深拷贝。
const MAP := "res://maps/factory1v1.cyrm"
const EXPECTED_CHECKS := 6

# 覆写 `_rpc_all` 的宿主:`_send_round_state` 内部调的就是它,故这里的截获是**生产路径上的**,
# 不是探针自己模仿出来的第二份。
class CaptureHost extends MatchHost:
	var last_round_state: Dictionary = {}
	var round_state_count := 0

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			round_state_count += 1
			last_round_state = (args[0] as Dictionary).duplicate(true)
		# 不调 super:本探针不排 peer,rpc 本来也发不出去(调了只是白扫一遍空表)。


var _checks := 0
var _fails: Array[String] = []
var _host: CaptureHost = null


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _ready() -> void:
	_host = CaptureHost.new(MAP, {})
	add_child(_host)
	# ★ 关掉服务器每帧编排:本探针手工驱动,不关的话 `_physics_process` 会自己去广播快照 /
	#   推进回合计时(同 `match_host_hygiene_probe`、`team_disconnect_probe` 的手法)。
	_host.set_physics_process(false)

	# ── ① `_ready` 那条广播:没人掉线 ⇒ **不带** `grace` 键 ──
	_check(_host.round_state_count >= 1, "`_ready` 广播了 round_state(计数 %d)" % _host.round_state_count)
	_check(not _host.last_round_state.has("grace"),
			"★ 空读数**不得**带 `grace` 键(spec 的同款纪律:destroyed/teams/stats 都是非空才带;实得 %s)"
			% str(_host.last_round_state.keys()))
	# ── ② 推入读数 ⇒ 载荷里出现 `grace`,值与推入的**逐字相同** ──
	_host.grace_snapshot = {1: 42.5}
	_host._broadcast_round_state()
	_check(_host.last_round_state.get("grace", {}) == {1: 42.5},
			"★ 非空读数必须进载荷(实得 %s)" % str(_host.last_round_state.get("grace", {})))
	# ── ③ 清空读数 ⇒ 键又消失(不是"带着一个空字典")──
	_host.grace_snapshot = {}
	_host._broadcast_round_state()
	_check(not _host.last_round_state.has("grace"),
			"读数清空后键必须消失(实得 %s)" % str(_host.last_round_state.keys()))
	# ── ④ 源码级:三个生产者都走唯一出口,且生产目录里再没有第二处 round_state 发送 ──
	_check(_funnel_is_the_only_emitter(),
			"★ `round_state` 的唯一出口被绕过:tests 的日志里有逐条读数")
	# ── ⑤ 源码级:每一处 `_broadcast_round_state()` 之前都先刷过宽限读数 ──
	_check(_every_broadcast_precedes_with_grace_sync(),
			"★ 有 `_broadcast_round_state()` 的调用点没先 `_sync_grace_snapshot()`(载荷里的掉线态是旧值)")

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上 —— 要么有断言被静默跳过、"
				% [_checks, EXPECTED_CHECKS]
				+ "要么有新断言没登记进 EXPECTED_CHECKS(helper 里的脚本错误只让那个函数当场结束、"
				+ "调用方照常往下走,`_fails` 不会非空)")
	if _fails.is_empty():
		print("GRACE FEED PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("GRACE FEED PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 生产目录里 `_rpc_all("round_state"` 必须**零命中**(三处都改走了 `_send_round_state`),
# 而三个生产者都必须含 `_send_round_state(`。
func _funnel_is_the_only_emitter() -> bool:
	var ok := true
	for p in ["res://server/match_state.gd", "res://server/match_round.gd",
			"res://server/royale_host.gd", "res://server/team_host.gd"]:
		var c := _code(p)
		if c.is_empty():
			print("    ✗ 读不到 %s" % p)
			ok = false
			continue
		if p != "res://server/match_state.gd" and not c.contains("_send_round_state("):
			print("    ✗ %s 没走 `_send_round_state(`" % p)
			ok = false
	for p in ["res://server/match_round.gd", "res://server/royale_host.gd",
			"res://server/team_host.gd", "res://server/match_state.gd"]:
		var c := _code(p)
		# match_state.gd 里那一处就是出口自身的实现,故放行
		if p == "res://server/match_state.gd":
			continue
		if c.contains("_rpc_all(\"round_state\""):
			print("    ✗ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)
			ok = false
	return ok


# ── ⑤ 的不变量 ────────────────────────────────────────────────────────────────
# **同一个函数体内**,每一处 `_broadcast_round_state()` 之前都必须先调过
# `_sync_grace_snapshot()`。载荷里那个 `grace` 字典是 `MatchState.grace_snapshot` 的**当前值**,
# 而读数只在三处写:`_enter_grace`、`_expire_graces`、以及 `_process` 里每秒一次的保鲜。
# 广播点漏刷的后果(两处都是"删掉不报错"):
#   · `_on_reclaim`:上面刚 `_grace.leave(role)`,不刷 ⇒ 载荷把这个**刚回来的人**继续列成
#     「掉线中(还剩 N 秒)」;而 1v1 / 3v3 的 `round_state` 只在状态跃迁时发、此后**没有任何
#     东西会重发** ⇒ 那个错值会一直挂到下一次击杀 / 换局(2026-09-28 修的正是这一处)。
#   · `_enter_grace`:进宽限后不刷 ⇒ 载荷里**不出现**这个人的掉线态,客户端那行「掉线中」不亮。
# ★ 扫**所有**调用点(不是只钉已修好的那处):将来新增第三处广播同样会被这条咬住。
# ★ 走 `code_only` 视图:注释里提到这两个名字**不算数** —— 这条断言的形状恰恰是"读起来像
#   覆盖、实际被一句注释喂饱"的那一类。
func _every_broadcast_precedes_with_grace_sync() -> bool:
	var c := _code("res://server/server_main.gd")
	if c.is_empty():
		print("    ✗ 读不到 res://server/server_main.gd")
		return false
	var ok := true
	var sites := 0
	for f in _func_blocks(c):
		var body: String = f["body"]
		var at := body.find("_broadcast_round_state()")
		if at < 0:
			continue
		sites += 1
		var sync := body.find("_sync_grace_snapshot()")
		if sync < 0 or sync > at:
			print("    ✗ %s() 里的 `_broadcast_round_state()` 之前没有 `_sync_grace_snapshot()`"
					% f["name"])
			ok = false
	# ★ 反向:一处都没扫到 = 扫描本身失明(比如接收者换了名字),那时上面的循环空转、恒绿。
	if sites == 0:
		print("    ✗ 一处 `_broadcast_round_state()` 都没扫到 —— 这条断言在空转")
		ok = false
	return ok


# 把剥注释后的源码切成 `[{name, body}]`。`code_only` 已 strip_edges,故"列 0 的 `func `"
# 就是函数起点(嵌套类/lambda 的方法也会被切出来,对本断言无害 —— 多扫到不含广播点的块而已)。
func _func_blocks(code: String) -> Array:
	var out := []
	var name := ""
	var buf: Array[String] = []
	for line in code.split("\n"):
		if line.begins_with("func "):
			if name != "":
				out.append({"name": name, "body": "\n".join(buf)})
			name = line.substr(5, line.find("(") - 5)
			buf = []
		elif name != "":
			buf.append(line)
	if name != "":
		out.append({"name": name, "body": "\n".join(buf)})
	return out
