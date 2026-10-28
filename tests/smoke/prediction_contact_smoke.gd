extends SceneTree

# 预测接触纯函数冒烟(纯逻辑 -s:不读地图、不引 autoload)。
# 最强保证:幽灵体外推滞后上限、贴身判据的 AABB 间隙几何、动态贴身容差的下限/线性/封顶按设计工作;
# 测不到什么:真实联机的接触手感、幽灵体外推在急停/变向时的实际误差(只能真链路 + 人眼/回滚计数)。

const EXPECTED_CHECKS := 7
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

	# ④ 幽灵滞后:RTT=0 时 = 半个 30Hz 间隔(1/60);超大 RTT 封顶 MAX_LAG_S
	var h0 := PredictionContact.ghost_horizon_s(0)
	var hmax := PredictionContact.ghost_horizon_s(4000)
	_chk(_eq(h0, 1.0 / 60.0) and _eq(hmax, PredictionContact.MAX_LAG_S),
			"ghost_horizon:ping0=1/60、极大 RTT 封顶 %.2fs" % PredictionContact.MAX_LAG_S)

	# ⑤ 容差下限:相对速度 0 ⇒ 8px(旧行为)
	_chk(_eq(PredictionContact.contact_tol(0.0, 0.05), 8.0),
			"contact_tol:相对速度 0 = 下限 8")

	# ⑥ 容差随相对速度线性增长:200px/s × 0.05s = 10 ⇒ 18px
	_chk(_eq(PredictionContact.contact_tol(200.0, 0.05), 18.0),
			"contact_tol:200px/s × 0.05s ⇒ 8+10=18")

	# ⑦ 容差封顶 + 贴身阈值边界:1000×0.05=50 ⇒ 钳到 48;间隙 12 算贴身、12.01 不算
	_chk(_eq(PredictionContact.contact_tol(1000.0, 0.05), 48.0)
			and PredictionContact.is_contact(12.0)
			and not PredictionContact.is_contact(12.01),
			"contact_tol 封顶 48;贴身边界 gap<=12")

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
