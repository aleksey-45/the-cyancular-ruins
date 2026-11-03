extends SceneTree
# 冲刺 / 下冲倍率与准入判据守卫(2026-11 用户改令:双击左右冲 · 时间加速不改变跳跃高度与冲刺距离 ·
# 武器减速缩短冲刺距离 · 当前速度已超过冲刺 / 下冲时该次冲刺无效)。
# ★ 本守卫钉的是"算式不变式",不是手感数值:速度/时长的基准值本身可以改,改了这里不该红。

const EXPECTED_CHECKS := 9

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	var dr = load("res://core/sim/dash_rule.gd")
	if dr == null:
		print("DASH RULE FAILED: load(dash_rule.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var base_v := 3000.0
	var base_t := 256.0 / 3000.0

	# ① 常速:速度与时长就是基准值
	var v1: float = dr.dash_speed(base_v, 1.0, 1.0)
	var t1: float = dr.dash_wall_time(base_t, 1.0)
	_chk(is_equal_approx(v1, base_v) and is_equal_approx(t1, base_t),
			"① 常速下冲刺速度/时长应等于基准(实得 %.1f / %.6f)" % [v1, t1])

	# ② 时间加速 2×:速度 ×2、时长 ÷2
	var v2: float = dr.dash_speed(base_v, 2.0, 1.0)
	var t2: float = dr.dash_wall_time(base_t, 2.0)
	_chk(is_equal_approx(v2, base_v * 2.0) and is_equal_approx(t2, base_t * 0.5),
			"② 时间加速 2× 时速度应 ×2、时长应 ÷2(实得 %.1f / %.6f)" % [v2, t2])
	# ★ 承重:两者相抵 ⇒ 冲刺距离一字不变(用户 2026-11 的显式要求)
	_chk(absf(v1 * t1 - v2 * t2) < 0.01,
			"② ★ 时间加速不得改变冲刺距离(常速 %.2fpx / 2× %.2fpx)" % [v1 * t1, v2 * t2])

	# ③ 慢速 0.5× 同理
	var v3: float = dr.dash_speed(base_v, 0.5, 1.0)
	var t3: float = dr.dash_wall_time(base_t, 0.5)
	_chk(absf(v1 * t1 - v3 * t3) < 0.01,
			"③ 慢速 0.5× 同样不得改变冲刺距离(实得 %.2fpx)" % (v3 * t3))

	# ④ ★ 承重:武器减速只乘速度 ⇒ 距离按倍率变短
	var v4: float = dr.dash_speed(base_v, 1.0, 0.85)
	var t4: float = dr.dash_wall_time(base_t, 1.0)
	_chk(absf(v4 * t4 - base_v * base_t * 0.85) < 0.01 and v4 * t4 < v1 * t1,
			"④ ★ 武器减速 0.85 必须让冲刺距离缩到 85%%(实得 %.2fpx)" % (v4 * t4))

	# ⑤ 准入:不比冲刺快才允许(正反方向都算)
	_chk(dr.dash_allowed(base_v - 1.0, base_v) and dr.dash_allowed(-base_v, base_v),
			"⑤ 比冲刺慢 / 恰好等于冲刺速度时必须允许")
	_chk(not dr.dash_allowed(base_v + 1.0, base_v) and not dr.dash_allowed(-(base_v + 1.0), base_v),
			"⑤ ★ 已经比冲刺快时必须拒绝(否则冲刺会把他拽慢)")

	# ⑥ 下冲准入:下落速度超过下冲速度就拒绝
	_chk(dr.down_dash_allowed(1500.0, 2000.0) and dr.down_dash_allowed(2000.0, 2000.0)
			and not dr.down_dash_allowed(2000.1, 2000.0),
			"⑥ 下冲:未超速 / 恰好相等必须允许,超过必须拒绝")

	# ⑦ 回溯那一帧 tm=0,不得除零出 inf/NaN
	var t0: float = dr.dash_wall_time(base_t, 0.0)
	_chk(is_finite(t0) and t0 > 0.0, "⑦ tm=0 不得除零(实得 %s)" % str(t0))

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("DASH RULE OK(%d 条断言):常速基准 · 时间加速不改距离 · 慢速不改距离 · 武器减速缩距离 · 冲刺/下冲准入 · tm=0 不除零" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("DASH RULE FAILED: %d 处" % _fails.size())
		quit(1)
