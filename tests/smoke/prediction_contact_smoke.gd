extends SceneTree


const EXPECTED_CHECKS := 9
const PredictionContact := preload("res://core/net/prediction_contact.gd")

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(10, 10, 40, 40)), 0.0),
			"rect_gap:相交 = 0")

	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(50, 0, 40, 40)), 10.0),
			"rect_gap:水平间距 10")

	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(43, 44, 40, 40)), 5.0),
			"rect_gap:对角 3-4-5 = 5")

	var h0 := PredictionContact.ghost_horizon_s(0)
	var hmax := PredictionContact.ghost_horizon_s(4000)
	_chk(_eq(h0, 0.5 / 60.0) and _eq(hmax, PredictionContact.MAX_LAG_S),
			"ghost_horizon:ping0=0.5/60、极大 RTT 封顶 %.2fs" % PredictionContact.MAX_LAG_S)

	_chk(_eq(PredictionContact.contact_tol(0.0, 0.0, 0.05), 8.0),
			"contact_tol:两档速度都 0 = 下限 8")

	_chk(_eq(PredictionContact.contact_tol(200.0, 0.0, 0.05), 28.0),
			"contact_tol:相对 200px/s × 0.05s ×2 ⇒ 8+20=28")

	_chk(_eq(PredictionContact.contact_tol(1000.0, 0.0, 0.05), 48.0)
			and PredictionContact.is_contact(12.0)
			and not PredictionContact.is_contact(12.01),
			"contact_tol 封顶 48;贴身边界 gap<=12")

	_chk(_eq(PredictionContact.contact_tol(0.0, 200.0, 0.05), 28.0)
			and _eq(PredictionContact.contact_tol(0.0, 700.0, 0.05), 48.0),
			"contact_tol:锚点速度 200 ⇒ 累加 (28)、700 ⇒ 封顶 48")

	var g := PredictionContact.CONTACT_GRACE_S
	_chk(_eq(PredictionContact.grace_after(0.0, 0.1, true), g)
			and _eq(PredictionContact.grace_after(g, 0.1, false), g - 0.1)
			and _eq(PredictionContact.grace_after(0.05, 0.1, false), 0.0)
			and _eq(PredictionContact.grace_after(0.0, 0.1, true), g),
			"贴身迟滞:贴身刷新 %.2fs、离开按 delta 递减、衰减到 0" % g)

	_finish()


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _eq(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("PREDICTION CONTACT OK(%d 条断言):AABB 间隙 / 滞后封顶 / 动态容差 / 贴身阈值" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("PREDICTION CONTACT FAILED: %d 处" % _fails.size())
		quit(1)
