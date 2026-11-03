extends SceneTree
# 回滚环内存守卫(PredictionRollback.note_post_step 的淘汰必须连带清 _inputs)。

const EXPECTED_CHECKS := 3

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var rb := PredictionRollback.new()
	# 灌 500 个 seq(超过 KEEP=256),每条都 走 note_input + note_post_step —— 与生产同序。
	for i in 500:
		rb.note_input(i, {"seq": i, "held": 0})
		rb.note_post_step(i, {"hp": 100})

	# ① 环淘汰后 _inputs 必须被截到 ≤ KEEP(去掉 _inputs.erase(old) ⇒ 这里 500 > 256,必红)
	_chk(rb._inputs.size() <= PredictionRollback.KEEP,
			"note_post_step 的淘汰必须连带清 _inputs(note_input 塞入的,环 _seqs 截断时不能留)")
	# ② 淘汰的是最老的 seq,最新一条仍在环里(可重放)
	_chk(rb._inputs.has(499),
			"最新一条输入必须仍在环里(回滚重放需要它)")
	# ③ 最老一条(0 号)已被淘汰 —— 与 _seqs 的弹出一致
	_chk(not rb._inputs.has(0),
			"最老一条输入必须已被淘汰(与 _seqs 同边界)")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("ROLLBACK RING OK(%d 条断言):note_post_step 淘汰连带清 _inputs · 界内保底 · 界外清除" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("ROLLBACK RING FAILED: %d 处" % _fails.size())
		quit(1)