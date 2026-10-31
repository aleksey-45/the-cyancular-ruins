extends SceneTree

# 预测接触纯函数冒烟(纯逻辑 -s:不读地图、不引 autoload)。
# 最强保证:幽灵体外推滞后上限、贴身判据的 AABB 间隙几何、动态贴身容差的下限/线性/封顶按设计工作;
# 测不到什么:真实联机的接触手感、幽灵体外推在急停/变向时的实际误差(只能真链路 + 人眼/回滚计数)。

const EXPECTED_CHECKS := 9
const PredictionContact := preload("res://core/net/prediction_contact.gd")

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	# ① 相交 AABB 间距 = 0
	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(10, 10, 40, 40)), 0.0),
			"rect_gap:相交 = 0")

	# ② 水平分开 10px
	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(50, 0, 40, 40)), 10.0),
			"rect_gap:水平间距 10")

	# ③ 对角 3-4-5(矩形角对角)
	_chk(_eq(PredictionContact.rect_gap(Rect2(0, 0, 40, 40), Rect2(43, 44, 40, 40)), 5.0),
			"rect_gap:对角 3-4-5 = 5")

	# ④ 幽灵滞后:RTT=0 时 = 半个 60Hz 间隔(0.5/60);超大 RTT 封顶 MAX_LAG_S
	var h0 := PredictionContact.ghost_horizon_s(0)
	var hmax := PredictionContact.ghost_horizon_s(4000)
	_chk(_eq(h0, 0.5 / 60.0) and _eq(hmax, PredictionContact.MAX_LAG_S),
			"ghost_horizon:ping0=0.5/60、极大 RTT 封顶 %.2fs" % PredictionContact.MAX_LAG_S)

	# ⑤ 容差下限:相对速度与锚点速度都为 0 ⇒ 8px(旧行为)
	_chk(_eq(PredictionContact.contact_tol(0.0, 0.0, 0.05), 8.0),
			"contact_tol:两档速度都 0 = 下限 8")

	# ⑥ 容差随相对速度线性增长:200px/s × 0.05s × 模型系数 2 = 20 ⇒ 28px
	_chk(_eq(PredictionContact.contact_tol(200.0, 0.0, 0.05), 28.0),
			"contact_tol:相对 200px/s × 0.05s ×2 ⇒ 8+20=28")

	# ⑦ 容差封顶 + 贴身阈值边界:1000×0.05×2=100 ⇒ 钳到 48;间隙 12 算贴身、12.01 不算
	_chk(_eq(PredictionContact.contact_tol(1000.0, 0.0, 0.05), 48.0)
			and PredictionContact.is_contact(12.0)
			and not PredictionContact.is_contact(12.01),
			"contact_tol 封顶 48;贴身边界 gap<=12")

	# ⑧ 幽灵锚点速度也计入(2026-10-31):两人同速同向(相对速度≈0)但对手跑 200 ⇒ 8 + 200×0.05×2 = 28px;
	#   对手 700 时被 48 封顶。
	#   ★ 去掉什么才红:把 contact_tol 的 drift 改回只看 rel_speed ⇒ 本条实得 8。
	_chk(_eq(PredictionContact.contact_tol(0.0, 200.0, 0.05), 28.0)
			and _eq(PredictionContact.contact_tol(0.0, 700.0, 0.05), 48.0),
			"contact_tol:锚点速度 200 ⇒ 累加 (28)、700 ⇒ 封顶 48")

	# ⑨ 贴身容差迟滞(2026-10-31):贴身当帧刷新为 CONTACT_GRACE_S,离开后按 delta 递减;
	#   ★ 去掉什么才红:把 grace_after 改成就返回 0 ⇒ 本条红;改成就返回 CONTACT_GRACE_S(永不衰减)⇒ 本条红。
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
