extends SceneTree

# 死亡带纯逻辑守卫（-s，headless，不实例化 autoload）。
# 守的内容：环形缓冲上限/原点保留、加速曲线的闭式解与末帧落点、帧选择、短局退化。
# 去掉什么会红：
#   ① 把 MAX_FRAMES 调大/不压缩 ⇒ 帧数断言红；
#   ② 压缩时把 i==0 也扔掉 ⇒ 原点断言红；
#   ③ 改 r/STEP0 或把末帧 clamp 掉 ⇒ 落点断言红；
#   ④ pick_index 的二分方向写反 ⇒ 帧选择断言红；
#   ⑤ 去掉 MIN_RUN 闸 ⇒ 短局断言红。

const EXPECTED_CHECKS := 9

const TapeScriptPath := "res://core/present/record/rewind_tape.gd"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var tape_script: GDScript = load(TapeScriptPath)
	if tape_script == null:
		print("RECORD REWIND SMOKE FAILED: load(%s) 为空（-s 空载守卫）" % TapeScriptPath)
		quit(1)
		return

	# ① 空带不崩、不排演出
	var empty = tape_script.new()
	_chk(tape_script.schedule(1.0).is_empty() and empty.size() == 0,
			"① 短局(<%s s)不排倒带且空带 size=0" % str(2.5))

	# ② 压缩上限 + 原点帧保留 + 时间严格递增
	var t = tape_script.new()
	for i in 400:
		t.append(float(i) / 60.0, i)
	var capped: bool = t.size() <= 320
	_chk(capped and t.size() >= 8, "② 400 帧入带后仍 ≤320（实得 %d）" % t.size())
	_chk(is_equal_approx(t.time_at(0), 0.0), "③ 压缩后最老帧（原点）必须保留（t0=%.3f）" % t.time_at(0))
	var monotonic := true
	for i in range(1, t.size()):
		if t.time_at(i) <= t.time_at(i - 1):
			monotonic = false
	_chk(monotonic, "④ 压缩后时间戳严格递增")

	# ⑤ D=10 的调度：帧数/时长/末帧落点
	var s10: Dictionary = tape_script.schedule(10.0)
	var age10: Vector2 = tape_script.age_at(float(s10["total"]) - 0.0001, s10)
	_chk(not s10.is_empty() and absf(age10.x - 10.0) < 0.02,
			"⑤ D=10 末帧落点 ≈10（实得 %.4f / total=%.3f）" % [age10.x, float(s10["total"])])
	var u_n := (1.0 / 60.0) * (pow(float(s10["r"]), int(s10["n"])) - 1.0) / (float(s10["r"]) - 1.0)
	_chk(absf(u_n - float(s10["body"])) < 0.0001,
			"⑥ 反解 r 使几何段覆盖 body（实得 %.6f / body=%.6f）" % [u_n, float(s10["body"])])

	# ⑦ D=300：被 3.5s 上限截断，末帧仍精确落回 300
	var s300: Dictionary = tape_script.schedule(300.0)
	var age300: Vector2 = tape_script.age_at(float(s300["total"]) - 0.0001, s300)
	_chk(int(s300["n"]) == 168 and absf(float(s300["total"]) - 3.5) < 0.0001,
			"⑦ D=300 帧数=168、演出总长=3.5（实得 %d / %.3f）" % [int(s300["n"]), float(s300["total"])])
	_chk(absf(age300.x - 300.0) < 0.05, "⑧ D=300 末帧落点 ≈300（实得 %.4f）" % age300.x)

	# ⑨ 帧选择：ages 递减，找最接近 target 的下标
	var ages := [5.0, 4.0, 3.0, 2.0, 1.0, 0.0]
	var i1 = tape_script.pick_index(ages, 2.4)
	var i2 = tape_script.pick_index(ages, 4.6)
	_chk(i1 == 3 and i2 == 0, "⑨ pick_index 最近邻（2.4→%d 期望3；4.6→%d 期望0）" % [i1, i2])

	if _checks < EXPECTED_CHECKS:
		print("RECORD REWIND SMOKE FAILED: 只跑了 %d 条 < %d（脚本中途中止）" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("RECORD REWIND SMOKE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("RECORD REWIND SMOKE ALL-OK (%d checks)" % _checks)
	quit(0)
