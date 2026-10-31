extends SceneTree
# 回滚"接触期速度容差"守卫(2026-10-31):同一台机器 3 客户端 soak 实测,回滚里 83~98% 是
# **纯速度分歧**(pos 在容差内、hp 未变、只有 vel 超 20)且 92~98% 发生在贴身 —— 贴身时客户端撞的是
# 按权威速度外推的"幽灵体",服务器撞的是对手此刻的真实身体,碰撞冲量必然不同。故:
#   · 贴身期 vel 容差放宽到 contact_vel_tol(默认 400);
#   · 非接触期仍是严格 VEL_TOL=20;
#   · 位置容差不受影响(仍由 contact_pos_tol / pos_tol 二选一)。
# 去掉什么才红:把 `_within` 的 vel 分支改回恒用 20 ⇒ ②/(④)红;把 position 分支也改成接触期放宽 ⇒ ③红;
#   把 contact_vel_tol 默认值改成 20 ⇒ ②红。
# 测不到什么:真机上"贴身"判据本身(那由 prediction_contact_smoke 钉几何);也不测观感(回滚少了是否手感更好要人眼)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/rollback_contact_vel_smoke.gd;通过 = ROLLBACK CONTACT VEL OK(n 条断言)。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _state(pos: Vector2, vel: Vector2, hp := 50, down := false) -> Dictionary:
	return {"pos": pos, "vel": vel, "hp": hp, "down": down}


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/prediction_rollback.gd") == null:
		print("ROLLBACK CONTACT VEL FAILED: load(prediction_rollback.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var c := PredictionRollback.new()
	var base := _state(Vector2(100, 100), Vector2(300, 0))

	# ① 非接触期:严格 20(不因本次改动放宽)
	c.in_contact = false
	_chk(not c._within("vel", base, _state(Vector2(100, 100), Vector2(400, 0)))
			and c._within("vel", base, _state(Vector2(100, 100), Vector2(310, 0))),
			"非接触期 vel 容差仍是 20(300 vs 400 判分歧 / 300 vs 310 判一致)")

	# ② 贴身期:vel 容差 = contact_vel_tol(400) —— 常规碰撞噪声不再判分歧,>400 仍判
	c.in_contact = true
	_chk(c._within("vel", base, _state(Vector2(100, 100), Vector2(400, 0)))
			and c._within("vel", base, _state(Vector2(100, 100), Vector2(699, 0)))
			and not c._within("vel", base, _state(Vector2(100, 100), Vector2(701, 0))),
			"贴身期 vel 容差 400(300 vs 400/699 判一致,300 vs 701 判分歧)")

	# ③ 贴身期位置容差**不受**速度放宽影响:仍由 contact_pos_tol 决定
	c.contact_pos_tol = 8.0
	var pos8 := c._within("pos", _state(Vector2(100, 100), Vector2.ZERO), _state(Vector2(120, 100), Vector2.ZERO))
	c.contact_pos_tol = 24.0
	var pos24 := c._within("pos", _state(Vector2(100, 100), Vector2.ZERO), _state(Vector2(120, 100), Vector2.ZERO))
	_chk(not pos8 and pos24, "贴身期位置容差与速度容差解耦(20px 在 tol=8 判分歧、tol=24 判一致)")

	# ④ 整态判定:贴身 + hp/down/pos 一致 + vel 差 300 ⇒ 预测被证实(不再白回滚);hp 不同仍判分歧
	c.contact_pos_tol = 8.0
	var claimed := c._close_enough(base, _state(Vector2(100, 100), Vector2(600, 0)))
	var hp_bad := c._close_enough(base, _state(Vector2(100, 100), Vector2(600, 0), 40))
	_chk(claimed and not hp_bad, "整态:贴身期纯速度差 300 不再回滚,但 hp 不同仍回滚")

	# ⑤ 常量口径(单一来源):默认 400、非接触 20、比对集含 vel
	_chk(is_equal_approx(PredictionRollback.DEFAULT_CONTACT_VEL_TOL, 400.0)
			and is_equal_approx(PredictionRollback.VEL_TOL, 20.0)
			and PredictionRollback.PREDICTED_FIELDS.has("vel")
			and is_equal_approx(c.contact_vel_tol, PredictionRollback.DEFAULT_CONTACT_VEL_TOL),
			"常量口径:接触 400 / 非接触 20 / PREDICTED_FIELDS 含 vel")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("ROLLBACK CONTACT VEL OK(%d 条断言):非接触严格 20 · 贴身 400 · 位置容差解耦 · 整态判定 · 常量口径" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("ROLLBACK CONTACT VEL FAILED: %d 处" % _fails.size())
		quit(1)
