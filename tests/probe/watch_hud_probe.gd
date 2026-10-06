extends Node

# 怀表 HUD + 时间视效探针(场景级):
#   ① 怀表挂载与读数(大数字=余额、表心=短时余额/贷款负数)
#   ② 扣减滚动动画(1 点 1 点,≤0.2s 收敛)
#   ③ 回溯底片化 uniform ramp(≤200ms 到顶)/松开回落
#   ④ 加速压暗 uniform ramp(100ms 到顶)/松开回落
#   ⑤ 贷款深度直传(表心深红负数)
# 用法:godot --headless --path . res://tests/probe/watch_hud_probe.tscn

var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _fail(m: String) -> void:
	_fails.append(m)


## 按真实时间等待(headless 帧率远高于 60fps,按帧等不可靠——ramp/动画都是时间驱动)
func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _mat_param(lvl: Node, key: String) -> float:
	var pp = lvl.get("_post_process")
	if pp == null:
		return -1.0
	var mat = pp.get("_mat")
	if mat == null:
		return -1.0
	return float(mat.get_shader_parameter(key))


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 20:
		await tree.process_frame
	var acc: GrainAccount = Level0.grain_account
	if acc == null:
		print("WATCH HUD PROBE: FAIL(账户未建立)")
		tree.quit(1)
		return

	# ① 怀表挂载与读数
	var found: Array = lvl.find_children("*", "WatchHud", true, false)
	if found.is_empty():
		print("WATCH HUD PROBE: FAIL(找不到 WatchHud 节点)")
		tree.quit(1)
		return
	var watch: Node = found[0]
	if not (watch as Control).visible:
		_fail("怀表未显示(账户已存在)")
	var big: Label = watch.get("_big")
	var center: Label = watch.get("_center")
	if big == null or center == null:
		print("WATCH HUD PROBE: FAIL(怀表内部 Label 缺失)")
		tree.quit(1)
		return
	await _wait_ms(300)   # 等滚动收敛(≤0.2s,留余量)
	if big.text != str(int(acc.balance)):
		_fail("大数字与余额不符(显示 %s 实际 %d)" % [big.text, int(acc.balance)])
	var expect_center := str(int(round(TimeParams.SHORT_WINDOW - acc.short_used)))
	if center.text != expect_center:
		_fail("表心短时余额不符(显示 %s 期望 %s)" % [center.text, expect_center])

	# ② 扣减滚动:花 250 → 20 帧内应显示到位(0.2s ≈ 12 帧)
	acc.spend(2.0, 125.0)
	var target := int(acc.balance)
	await _wait_ms(300)
	if big.text != str(target):
		_fail("扣减动画未收敛(显示 %s 期望 %d)" % [big.text, target])

	# ③ 回溯底片化 ramp
	Input.action_press("rewind")
	await _wait_ms(300)   # 底片 ramp ≤200ms
	var film: float = _mat_param(lvl, "rewind_film")
	if film < 0.6:
		_fail("回溯底片化未 ramp 到位(%.2f)" % film)
	Input.action_release("rewind")
	await _wait_ms(400)
	if _mat_param(lvl, "rewind_film") > 0.2:
		_fail("松开后底片化未回落(%.2f)" % _mat_param(lvl, "rewind_film"))

	# ④ 加速压暗 ramp
	Input.action_press("haste")
	await _wait_ms(200)   # 压暗 ramp 100ms
	var haste: float = _mat_param(lvl, "haste_dim")
	if haste < 0.6:
		_fail("加速压暗未 ramp 到位(%.2f)" % haste)
	Input.action_release("haste")
	await _wait_ms(400)
	if _mat_param(lvl, "haste_dim") > 0.2:
		_fail("松开后压暗未回落(%.2f)" % _mat_param(lvl, "haste_dim"))

	# ⑤ 贷款深度与表心负数
	acc.spend(4.0, 100.0)   # 窗满
	acc.spend(0.5, 100.0)   # 借 50
	await _wait_ms(100)
	var loan_param: float = _mat_param(lvl, "loan_depth")
	if loan_param < 0.4:
		_fail("贷款深度未直传(%.2f)" % loan_param)
	if not center.text.begins_with("-"):
		_fail("贷款中表心应显示负数(现 %s)" % center.text)

	# ⑥ Sfx 全局音调随贷款深度上抬;贷满锁定 → 怀表红闪
	acc.spend(0.5, 100.0)   # 借满 100 → 锁定
	await _wait_ms(150)
	if Sfx.pitch_mult <= 1.0:
		_fail("贷款中 Sfx 音调未上抬(%.2f)" % Sfx.pitch_mult)
	if not acc.locked:
		_fail("借满未锁定")
	if float(watch.get("_lock_flash_t")) <= 0.0:
		_fail("锁定后怀表未红闪")

	if _fails.is_empty():
		print("WATCH HUD PROBE: OK(挂载/读数/滚动收敛/底片ramp/压暗ramp/贷款负数与深度直传/音调上抬/锁定红闪)")
		tree.quit(0)
	else:
		print("WATCH HUD PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
