extends SceneTree

# 命中回放历史环冒烟(纯逻辑 -s:直接 new() 驱动,不读地图、不引 autoload)。

const EXPECTED_CHECKS := 8
const Hist := preload("res://core/sim/hit_lag_history.gd")

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	# ① 空历史:size=0 / latest=0 / nearest=-1 / rect 空
	var empty := Hist.new()
	_chk(empty.size() == 0 and empty.latest_tick() == 0 and empty.nearest_tick(5) == -1
			and empty.rect_for(1, 5).size == Vector2.ZERO, "空历史:size/latest/nearest=-1/rect 空")

	# ② 容量 24 + 丢最老:推 30 tick ⇒ 只留 7..30,latest=30,查 1 被夹到最老 7
	var h := Hist.new()
	for i in range(1, 31):
		h.push(i, {1: {"p": Vector2(i, 0), "r": Rect2(-10, -20, 20, 40)}})
	_chk(h.size() == Hist.CAPACITY and h.latest_tick() == 30 and h.nearest_tick(1) == 7,
			"容量/丢最老:size=%d、latest=30、nearest(1) 夹到 7(实得 %d)" % [h.size(), h.nearest_tick(1)])

	# ③ nearest_tick:向下取整 + 两端夹取
	var h2 := Hist.new()
	for t in [10, 12, 14]:
		h2.push(t, {})
	_chk(h2.nearest_tick(13) == 12 and h2.nearest_tick(10) == 10
			and h2.nearest_tick(9) == 10 and h2.nearest_tick(99) == 14,
			"nearest_tick:13→12(向下取整)、10→10、9→10(夹最老)、99→14(夹最新)")

	# ④ rect_for = 历史位置 p + 相对偏移 r
	var h3 := Hist.new()
	h3.push(5, {42: {"p": Vector2(100, 50), "r": Rect2(-10, -20, 20, 40)}})
	_chk(h3.rect_for(42, 5).is_equal_approx(Rect2(90, 30, 20, 40)), "rect_for:p + 相对偏移 ⇒ (90,30,20,40)")

	# ⑤ pos_for:有数据 / 无该 role
	_chk(h3.pos_for(42, 5) == Vector2(100, 50) and h3.pos_for(7, 5) == Vector2.ZERO,
			"pos_for:有 role 返回历史位置、无 role 返回 ZERO")

	# ⑥ 无数据:未知 role 与空历史都返回空 Rect2
	_chk(h3.rect_for(7, 5).size == Vector2.ZERO and Hist.new().rect_for(1, 1).size == Vector2.ZERO,
			"无数据:rect_for 返回空 Rect2")

	# ⑦ 同 tick 覆盖:size 不变、取最后一次
	h3.push(5, {42: {"p": Vector2(1, 2), "r": Rect2(0, 0, 4, 6)}})
	_chk(h3.size() == 1 and h3.pos_for(42, 5) == Vector2(1, 2), "同 tick 覆盖:size 不变、值更新")

	# ⑧ clear:环与索引一起复位
	h.clear()
	_chk(h.size() == 0 and h.latest_tick() == 0 and h.rect_for(1, 30).size == Vector2.ZERO,
			"clear:size/latest/rect 全部复位")

	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LAG HISTORY OK(%d 条断言):容量/取整/合成/无数据/覆盖/clear" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("LAG HISTORY FAILED: %d 处" % _fails.size())
		quit(1)


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
