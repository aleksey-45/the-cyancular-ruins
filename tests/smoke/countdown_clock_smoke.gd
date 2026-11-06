extends SceneTree

const EXPECTED_CHECKS := 9
const DT := 1.0 / 60.0

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _run(clock: CountdownClock, secs: float) -> Array:
	var seen: Array = []
	var finished := 0
	var n := int(round(secs / DT))
	for i in n:
		var r := clock.tick(DT)
		if r == CountdownClock.TICK_FINISHED:
			finished += 1
		var t := clock.text()
		if seen.is_empty() or seen[seen.size() - 1] != t:
			seen.append(t)
	seen.append("finished:%d" % finished)
	return seen


func _initialize() -> void:
	if load("res://ui/hud/countdown_clock.gd") == null:
		print("COUNTDOWN CLOCK FAILED: load(countdown_clock.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var c := CountdownClock.new()
	_chk(not c.running() and c.text() == "1", "冷启动应不在走秒(显示下限仍是 1),实得 running=%s text=%s" % [
			str(c.running()), c.text()])
	c.start(3.0)
	_chk(c.running() and c.text() == "3" and is_equal_approx(c.remaining(), 3.0),
			"start(3.0) 后应走秒且显示 3(实得 %s / %s)" % [c.text(), str(c.remaining())])

	for i in 30:
		c.tick(DT)
	var before := c.remaining()
	c.start(3.0)
	_chk(c.remaining() <= before + 0.0001,
			"★ 重复 start(3.0) 不得回拨本地时钟(前 %.3f → 后 %.3f;回拨会把走过的数字重新盖回来)" % [
				before, c.remaining()])

	c.start(1.2)
	_chk(is_equal_approx(c.remaining(), 1.2) and c.text() == "2",
			"start(1.2) 必须采纳更短的剩余(实得 %.3f / %s)" % [c.remaining(), c.text()])

	var d := CountdownClock.new()
	d.start(3.0)
	var seq := _run(d, 3.2)
	_chk(seq == ["3", "2", "1", "finished:1"],
			"★ 数字序列必须是 3,2,1 且只结束一次(实得 %s;少了 1 = 最后一秒被截掉)" % str(seq))

	var extra := d.tick(DT)
	_chk(not d.running() and extra == CountdownClock.TICK_IDLE,
			"结束后再 tick 必须是 TICK_IDLE 且不再走秒(实得 %d / running=%s)" % [extra, str(d.running())])

	var e := CountdownClock.new()
	e.start(3.0)
	for i in 120:
		e.tick(DT)
	e.stop()
	e.start(3.0)
	_chk(e.running() and is_equal_approx(e.remaining(), 3.0) and e.text() == "3",
			"stop() 后再 start(3.0) 必须重新采纳(实得 %.3f / %s)" % [e.remaining(), e.text()])

	var f := CountdownClock.new()
	f.start(3.0)
	var last := 99
	var mono := true
	for i in 180:
		f.tick(DT)
		var v := int(f.text())
		if v == 0:
			mono = false
		if v > last:
			mono = false
		last = v
	_chk(mono, "★ 显示值必须单调不增且不出现 0(实得末值 %s)" % f.text())

	var g := CountdownClock.new()
	g.start(0.5)
	for i in 60:
		g.tick(DT)
	_chk(not g.running() and is_equal_approx(g.remaining(), 0.0),
			"走到 0 后剩余必须归零(实得 %.6f)" % g.remaining())

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("COUNTDOWN CLOCK OK(%d 条断言):冷启动 · 重播不回拨 · 更短采纳 · 3→2→1 · 只结束一次 · 换局重置 · 单调 · 归零"
				% _checks)
		quit(0)
	else:
		for f2 in _fails:
			print("  [FAIL] ", f2)
		print("COUNTDOWN CLOCK FAILED: %d 处" % _fails.size())
		quit(1)
